//
//  OpenClickyAutomation.swift
//  OCAutomation
//
//  Scheduled prompt model + a self-contained 5-field cron evaluator.
//  Cron supports: number, list (1,3,5), range (1-5), step (*/5), wildcard.
//  Fields: minute (0-59), hour (0-23), day-of-month (1-31), month (1-12),
//  day-of-week (0-7, both 0 and 7 mean Sunday).
//

import Foundation

public enum OpenClickyAutomationSchedule: Codable, Equatable, Sendable {
  case interval(seconds: TimeInterval)
  case cron(String)

  enum CodingKeys: String, CodingKey { case kind, value }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try c.decode(String.self, forKey: .kind)
    switch kind {
    case "interval":
      let s = try c.decode(TimeInterval.self, forKey: .value)
      self = .interval(seconds: s)
    case "cron":
      let s = try c.decode(String.self, forKey: .value)
      self = .cron(s)
    default:
      throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown schedule kind \(kind)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .interval(let s):
      try c.encode("interval", forKey: .kind)
      try c.encode(s, forKey: .value)
    case .cron(let s):
      try c.encode("cron", forKey: .kind)
      try c.encode(s, forKey: .value)
    }
  }

  public var displayString: String {
    switch self {
    case .interval(let s):
      let minutes = Int(s) / 60
      if minutes < 60 { return "every \(minutes)m" }
      let hours = minutes / 60
      let leftover = minutes % 60
      return leftover == 0 ? "every \(hours)h" : "every \(hours)h \(leftover)m"
    case .cron(let s):
      return "cron \(s)"
    }
  }
}

public struct OpenClickyAutomation: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var schedule: OpenClickyAutomationSchedule
  public var prompt: String
  /// Optional specialist-agent slug. Nil = run via the default chat session.
  public var agentSlug: String?
  public var enabled: Bool
  public var lastRun: Date?
  public var nextRun: Date?

  public init(id: UUID = UUID(), name: String, schedule: OpenClickyAutomationSchedule, prompt: String, agentSlug: String? = nil, enabled: Bool = true, lastRun: Date? = nil, nextRun: Date? = nil) {
    self.id = id
    self.name = name
    self.schedule = schedule
    self.prompt = prompt
    self.agentSlug = agentSlug
    self.enabled = enabled
    self.lastRun = lastRun
    self.nextRun = nextRun
  }

  public func computingNextRun(after reference: Date) -> Date? {
    switch schedule {
    case .interval(let s):
      let base = lastRun ?? reference
      let candidate = base.addingTimeInterval(s)
      return candidate > reference ? candidate : reference.addingTimeInterval(s)
    case .cron(let expr):
      return CronExpression(expr)?.nextFireDate(after: reference)
    }
  }
}

// MARK: - Cron evaluator

public struct CronExpression: Sendable {
  let minutes: Set<Int>
  let hours: Set<Int>
  let days: Set<Int>
  let months: Set<Int>
  let weekdays: Set<Int> // 1-7 (Sunday = 1, matches Calendar.weekday)

  public init?(_ raw: String) {
    let parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard parts.count == 5 else { return nil }
    guard let m = Self.parse(parts[0], min: 0, max: 59),
          let h = Self.parse(parts[1], min: 0, max: 23),
          let d = Self.parse(parts[2], min: 1, max: 31),
          let mo = Self.parse(parts[3], min: 1, max: 12),
          let dow = Self.parse(parts[4], min: 0, max: 7) else { return nil }
    self.minutes = m
    self.hours = h
    self.days = d
    self.months = mo
    // Map cron 0..7 (both Sunday) → Calendar.weekday 1..7 (Sunday = 1)
    self.weekdays = Set(dow.map { ($0 % 7) + 1 })
  }

  public func nextFireDate(after reference: Date) -> Date? {
    let calendar = Calendar(identifier: .gregorian)
    var candidate = calendar.date(byAdding: .minute, value: 1, to: reference) ?? reference
    candidate = calendar.date(bySetting: .second, value: 0, of: candidate) ?? candidate
    let limit = calendar.date(byAdding: .day, value: 366, to: reference) ?? reference

    while candidate < limit {
      let comps = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
      let m = comps.minute ?? -1
      let h = comps.hour ?? -1
      let d = comps.day ?? -1
      let mo = comps.month ?? -1
      let wd = comps.weekday ?? -1
      guard minutes.contains(m), hours.contains(h), months.contains(mo) else {
        candidate = calendar.date(byAdding: .minute, value: 1, to: candidate) ?? candidate
        continue
      }
      // M12: standard Vixie cron semantics — when BOTH day-of-month and
      // day-of-week are restricted, fire when EITHER matches (OR); when only
      // one is restricted, match that one. Previously this required BOTH
      // (AND), so `0 0 1 * 1` fired only when the 1st happened to be a Monday.
      let daysRestricted = days.count != 31
      let weekdaysRestricted = weekdays.count != 7
      let dayMatches: Bool
      switch (daysRestricted, weekdaysRestricted) {
      case (true, true):
        dayMatches = days.contains(d) || weekdays.contains(wd)
      default:
        dayMatches = days.contains(d) && weekdays.contains(wd)
      }
      guard dayMatches else {
        candidate = calendar.date(byAdding: .minute, value: 1, to: candidate) ?? candidate
        continue
      }
      return candidate
    }
    return nil
  }

  private static let monthNames: [String: Int] = [
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
  ]
  private static let weekdayNames: [String: Int] = [
    "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6
  ]

  /// Resolves a token that may be a number, a 3-letter name (`MON`, `JAN`),
  /// or — for day-of-week — extends to common synonyms.
  private static func resolveToken(_ token: String, lo: Int, hi: Int) -> Int? {
    if let n = Int(token) { return n }
    let key = token.lowercased()
    if hi == 12, let m = monthNames[key] { return m }
    if hi == 7, let w = weekdayNames[key] { return w }
    return nil
  }

  private static func parse(_ field: String, min lo: Int, max hi: Int) -> Set<Int>? {
    var out: Set<Int> = []
    for piece in field.split(separator: ",") {
      var step = 1
      var range = String(piece)
      if let slash = range.firstIndex(of: "/") {
        guard let s = Int(range[range.index(after: slash)...]), s >= 1 else { return nil }
        step = s
        range = String(range[..<slash])
      }
      var start = lo
      var end = hi
      if range == "*" {
        // already lo...hi
      } else if let dash = range.firstIndex(of: "-") {
        guard let a = resolveToken(String(range[..<dash]), lo: lo, hi: hi),
              let b = resolveToken(String(range[range.index(after: dash)...]), lo: lo, hi: hi) else { return nil }
        start = a
        end = b
      } else if let n = resolveToken(range, lo: lo, hi: hi) {
        start = n
        end = n
      } else {
        return nil
      }
      guard start >= lo, end <= hi, start <= end else { return nil }
      var v = start
      while v <= end {
        out.insert(v)
        v += step
      }
    }
    return out.isEmpty ? nil : out
  }
}
