//
//  OpenClickyAutomationStore.swift
//  OpenClicky
//
//  JSON-backed automation registry + a single 30-second tick scheduler.
//  Persists to ~/Library/Application Support/OpenClicky/automations.json.
//  Uses CompanionManager.submitAgentPromptFromUI(_:) to fire prompts;
//  routes through createAndSelectNewCodexAgentSession(asAgent:) when an
//  automation is bound to a specialist agent slug.
//

import Foundation
import Combine

@MainActor
final class OpenClickyAutomationStore: ObservableObject {
  static let shared = OpenClickyAutomationStore()

  @Published private(set) var automations: [OpenClickyAutomation] = []

  private let storeURL: URL
  private var timer: Timer?
  private weak var companion: CompanionManager?

  private init() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    let dir = appSupport.appendingPathComponent("OpenClicky", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.storeURL = dir.appendingPathComponent("automations.json")
    load()
  }

  // MARK: lifecycle

  func bind(companion: CompanionManager) {
    self.companion = companion
    startTimer()
  }

  func startTimer() {
    timer?.invalidate()
    let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor [self] in
        self.tick()
      }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  // MARK: CRUD

  func add(_ automation: OpenClickyAutomation) {
    var a = automation
    a.nextRun = a.computingNextRun(after: Date())
    automations.append(a)
    save()
  }

  func update(_ automation: OpenClickyAutomation) {
    guard let idx = automations.firstIndex(where: { $0.id == automation.id }) else { return }
    var a = automation
    a.nextRun = a.computingNextRun(after: Date())
    automations[idx] = a
    save()
  }

  func remove(id: UUID) {
    automations.removeAll { $0.id == id }
    save()
  }

  func setEnabled(id: UUID, enabled: Bool) {
    guard let idx = automations.firstIndex(where: { $0.id == id }) else { return }
    automations[idx].enabled = enabled
    automations[idx].nextRun = enabled ? automations[idx].computingNextRun(after: Date()) : nil
    save()
  }

  // MARK: tick

  private func tick() {
    let now = Date()
    var didMutate = false
    for i in automations.indices {
      guard automations[i].enabled else { continue }
      if let next = automations[i].nextRun, next <= now {
        fire(automation: automations[i])
        automations[i].lastRun = now
        automations[i].nextRun = automations[i].computingNextRun(after: now)
        didMutate = true
      } else if automations[i].nextRun == nil {
        automations[i].nextRun = automations[i].computingNextRun(after: now)
        didMutate = true
      }
    }
    if didMutate { save() }
  }

  private func fire(automation: OpenClickyAutomation) {
    guard let companion else { return }
    let prompt = automation.prompt
    if let slug = automation.agentSlug, let agent = OpenClickyAgentStore.shared.agent(slug: slug) {
      let session = companion.createAndSelectNewCodexAgentSession(asAgent: agent)
      session.submitPromptFromUI(prompt, screenContext: nil)
    } else {
      companion.submitAgentPromptFromUI(prompt)
    }
  }

  // MARK: persistence

  private func load() {
    guard let data = try? Data(contentsOf: storeURL) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let list = try? decoder.decode([OpenClickyAutomation].self, from: data) {
      self.automations = list
    }
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    do {
      let data = try encoder.encode(automations)
      try data.write(to: storeURL, options: [.atomic])
    } catch {
      print("automation save failed: \(error)")
    }
  }
}
