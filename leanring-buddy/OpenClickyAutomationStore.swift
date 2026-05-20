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

import AppKit
import Combine
import Foundation

@MainActor
final class OpenClickyAutomationStore: ObservableObject {
  static let shared = OpenClickyAutomationStore()
  static let skillDiscoveryAutomationName = "App skill discovery"

  static var skillDiscoverySuggestionsURL: URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    return appSupport
      .appendingPathComponent("OpenClicky", isDirectory: true)
      .appendingPathComponent("skill-discovery-suggestions.json", isDirectory: false)
  }

  static var skillDiscoveryAutomationPrompt: String {
    """
    OpenClicky scheduled skill discovery pass.

    Goal: find useful Agent Mode skills for the apps and workflows the user is actively using, then surface install/connect options in the OpenClicky Connect tab.

    Be efficient:
    1. Identify likely active apps/workflows from recent OpenClicky logs, current screen/window context if provided, and obvious local project folders. Keep OpenClicky's default suggestions available, but when an active app is visible, include suggestions tailored to that app using known skills, MCP/connectors, gog routes, browser automation, or screen-context workflows. Do not scan huge folders blindly.
    2. Search local skills first under ~/Library/Application Support/OpenClicky/AgentMode/CodexHome/OpenClickyBundledSkills, ~/Library/Application Support/OpenClicky/AgentMode/CodexHome/OpenClickyLearnedSkills, ~/.codex/skills, ~/.agents/skills, ~/Documents/GitHub/*/skills, and any directly relevant repo skill folders. Prefer `find`/metadata over reading every large file.
    3. Only then do targeted web research for public skills or official app integrations that match those apps. Use current sources and avoid broad marketplace scraping.
    4. Recommend only practical, low-risk options that OpenClicky can install locally or connect through existing app/tool routes.

    Write a compact JSON array to:
    \(Self.skillDiscoverySuggestionsURL.path)

    Schema:
    [
      {
        "id": "stable-slug",
        "title": "Skill or integration name",
        "detail": "Why it matches the current apps/workflow",
        "source": "local|online|installed",
        "installPrompt": "Exact OpenClicky Agent Mode prompt to install or connect it"
      }
    ]

    Keep at most 8 suggestions, deduplicate installed skills, and prefer local matches over online ones.
    """
  }

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
    ensureSkillDiscoveryAutomationInstalled()
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
    guard !isProtectedSystemAutomation(automations[idx]) else { return }
    var a = automation
    a.nextRun = a.computingNextRun(after: Date())
    automations[idx] = a
    save()
  }

  func remove(id: UUID) {
    automations.removeAll { $0.id == id && !isProtectedSystemAutomation($0) }
    save()
  }

  func setEnabled(id: UUID, enabled: Bool) {
    guard let idx = automations.firstIndex(where: { $0.id == id }) else { return }
    automations[idx].enabled = enabled
    automations[idx].nextRun = enabled ? automations[idx].computingNextRun(after: Date()) : nil
    save()
  }

  @discardableResult
  func ensureSkillDiscoveryAutomationInstalled() -> OpenClickyAutomation {
    _ = OpenClickyAgentStore.shared.ensureSkillDiscoveryAgentInstalled()

    if let idx = automations.firstIndex(where: { isProtectedSystemAutomation($0) || $0.name == Self.skillDiscoveryAutomationName }) {
      let existing = automations[idx]
      if existing.name != Self.skillDiscoveryAutomationName ||
          existing.prompt != Self.skillDiscoveryAutomationPrompt ||
          existing.agentSlug != OpenClickyAgentStore.skillDiscoveryAgentSlug {
        var repaired = existing
        repaired.name = Self.skillDiscoveryAutomationName
        repaired.prompt = Self.skillDiscoveryAutomationPrompt
        repaired.agentSlug = OpenClickyAgentStore.skillDiscoveryAgentSlug
        repaired.nextRun = repaired.enabled ? repaired.computingNextRun(after: Date()) : nil
        automations[idx] = repaired
        save()
        return repaired
      }
      return existing
    }

    let automation = OpenClickyAutomation(
      name: Self.skillDiscoveryAutomationName,
      schedule: .interval(seconds: 6 * 60 * 60),
      prompt: Self.skillDiscoveryAutomationPrompt,
      agentSlug: OpenClickyAgentStore.skillDiscoveryAgentSlug,
      enabled: true
    )
    add(automation)
    return automation
  }

  var skillDiscoveryAutomation: OpenClickyAutomation? {
    automations.first(where: { isProtectedSystemAutomation($0) })
  }

  func isProtectedSystemAutomation(_ automation: OpenClickyAutomation) -> Bool {
    automation.name == Self.skillDiscoveryAutomationName || automation.agentSlug == OpenClickyAgentStore.skillDiscoveryAgentSlug
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

struct OpenClickySkillDiscoverySuggestion: Codable, Identifiable, Equatable {
  var id: String
  var title: String
  var detail: String
  var source: String
  var installPrompt: String

  var sourceLabel: String {
    switch source.lowercased() {
    case "app": return "App"
    case "local": return "Local"
    case "mcp": return "MCP"
    case "installed": return "Installed"
    case "online": return "Online"
    default: return source.isEmpty ? "Suggested" : source.capitalized
    }
  }

  var actionLabel: String {
    switch source.lowercased() {
    case "online", "local": return "Install"
    default: return "Connect"
    }
  }
}

@MainActor
final class OpenClickySkillDiscoveryStore: ObservableObject {
  static let shared = OpenClickySkillDiscoveryStore()

  @Published private(set) var suggestions: [OpenClickySkillDiscoverySuggestion] = []
  @Published private(set) var activeApplicationName: String?

  private let storeURL = OpenClickyAutomationStore.skillDiscoverySuggestionsURL

  private init() {
    reload()
  }

  func reload() {
    let savedSuggestions = loadSavedSuggestions()
    let appContext = currentApplicationContext()
    activeApplicationName = appContext?.name

    suggestions = mergeSuggestions(
      appSuggestions(for: appContext),
      savedSuggestions.isEmpty ? Self.defaultSuggestions : savedSuggestions
    )
  }

  private func loadSavedSuggestions() -> [OpenClickySkillDiscoverySuggestion] {
    guard let data = try? Data(contentsOf: storeURL),
          let decoded = try? JSONDecoder().decode([OpenClickySkillDiscoverySuggestion].self, from: data) else {
      return []
    }
    return decoded
  }

  private func mergeSuggestions(_ prioritized: [OpenClickySkillDiscoverySuggestion],
                                _ defaults: [OpenClickySkillDiscoverySuggestion]) -> [OpenClickySkillDiscoverySuggestion] {
    var seen: Set<String> = []
    var merged: [OpenClickySkillDiscoverySuggestion] = []

    for suggestion in prioritized + defaults {
      let key = suggestion.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !key.isEmpty, !seen.contains(key) else { continue }
      seen.insert(key)
      merged.append(suggestion)
      if merged.count == 8 { break }
    }

    return merged
  }

  private struct ApplicationContext {
    var name: String
    var bundleIdentifier: String?
  }

  private func currentApplicationContext() -> ApplicationContext? {
    let ownBundleIdentifier = Bundle.main.bundleIdentifier
    if let app = NSWorkspace.shared.frontmostApplication,
       app.bundleIdentifier != ownBundleIdentifier,
       let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !name.isEmpty {
      return ApplicationContext(name: name, bundleIdentifier: app.bundleIdentifier)
    }

    return mostRecentRecordedApplication(excluding: ownBundleIdentifier)
  }

  private func mostRecentRecordedApplication(excluding ownBundleIdentifier: String?) -> ApplicationContext? {
    let logURL = OpenClickyApplicationUsageLogStore.shared.logURL
    guard let data = try? Data(contentsOf: logURL),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let apps = root["applications"] as? [[String: Any]] else {
      return nil
    }

    let sortedApps = apps.sorted {
      ($0["lastSeenAt"] as? String ?? "") > ($1["lastSeenAt"] as? String ?? "")
    }

    for entry in sortedApps {
      let bundleIdentifier = (entry["bundleIdentifier"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let ownBundleIdentifier, bundleIdentifier == ownBundleIdentifier {
        continue
      }
      let name = (entry["name"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let name, !name.isEmpty else { continue }
      if name.localizedCaseInsensitiveContains("OpenClicky") {
        continue
      }
      return ApplicationContext(
        name: name,
        bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
      )
    }

    return nil
  }

  private func appSuggestions(for context: ApplicationContext?) -> [OpenClickySkillDiscoverySuggestion] {
    guard let context else { return [] }

    let appName = context.name
    let haystack = "\(context.name) \(context.bundleIdentifier ?? "")".lowercased()

    if context.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("X") == .orderedSame ||
        haystack.contains("twitter") ||
        haystack.contains(".x") {
      return [
        appSuggestion(
          id: "active-x-screen-summary",
          title: "Summarize X from screen",
          detail: "OpenClicky can use the focused X window as screen context to summarize a post, thread, profile, or visible feed without needing an X API key.",
          prompt: "Use OpenClicky's screen context to summarize the active X window, capture the useful links or claims, and suggest the next action."
        ),
        appSuggestion(
          id: "active-x-draft-reply",
          title: "Draft X replies",
          detail: "Useful for X: OpenClicky can read the visible context, draft a reply or post, and leave final posting to you.",
          prompt: "Draft a concise X reply or post based on the active X window. Do not post it; show the draft for approval."
        )
      ]
    }

    if matchesAny(haystack, ["chrome", "safari", "firefox", "arc", "edge", "browser"]) {
      return [
        appSuggestion(
          id: "active-browser-page-brief",
          title: "Summarize current page",
          detail: "OpenClicky can use browser automation or screen context to summarize the active page, extract links, and turn it into an Agent task.",
          prompt: "Summarize the current browser page with OpenClicky's browser/screen context, then list the important links and recommended next action."
        ),
        appSuggestion(
          id: "active-browser-web-research",
          title: "Research from this page",
          detail: "Starts from the active page and uses live web search when the answer needs current sources.",
          prompt: "Use the active browser page as context, then do current web research and cite the sources OpenClicky relies on."
        )
      ]
    }

    if matchesAny(haystack, ["gmail", "mail"]) {
      return [
        mcpSuggestion(
          id: "active-mail-unread-triage",
          title: "Unread email triage",
          detail: "OpenClicky can use the local gog Gmail route for short unread summaries, stopping cleanly if auth or keyring access is blocked.",
          prompt: "Use OpenClicky's gog Gmail workflow to summarize unread inbox items briefly, with sender, subject, date, and likely action."
        ),
        mcpSuggestion(
          id: "active-mail-draft-reply",
          title: "Draft safe replies",
          detail: "For Mail or Gmail, OpenClicky drafts first and requires explicit approval before sending.",
          prompt: "Draft a reply to the active email using OpenClicky's Gmail/Mail-safe send guard. Do not send until I approve recipient, subject, body, and attachments."
        )
      ]
    }

    if matchesAny(haystack, ["calendar"]) {
      return [
        mcpSuggestion(
          id: "active-calendar-day-plan",
          title: "Plan around calendar",
          detail: "OpenClicky can use gog Calendar to inspect events and produce a compact day plan.",
          prompt: "Use OpenClicky's gog Calendar workflow to summarize today's schedule and suggest a practical day plan."
        )
      ]
    }

    if matchesAny(haystack, ["slack", "teams"]) {
      return [
        mcpSuggestion(
          id: "active-chat-thread-summary",
          title: "Summarize chat thread",
          detail: "OpenClicky can connect through available chat integrations or use screen context to summarize the active conversation.",
          prompt: "Summarize the active chat conversation using the available OpenClicky integration route or screen context, then identify decisions and follow-ups."
        )
      ]
    }

    if matchesAny(haystack, ["xcode", "cursor", "code", "terminal", "iterm"]) {
      return [
        appSuggestion(
          id: "active-dev-focused-patch",
          title: "Focused code patch",
          detail: "OpenClicky can turn the active developer app into a narrow Agent Mode implementation task with dirty-worktree safety and lightweight checks.",
          prompt: "Use the active developer app context to make a narrow code patch. Check git status first and verify with lightweight checks."
        ),
        appSuggestion(
          id: "active-dev-debug-loop",
          title: "Debug current failure",
          detail: "Good for Terminal, Xcode, Cursor, or VS Code: inspect the visible error, trace the repo, patch, and verify.",
          prompt: "Debug the failure visible in the active developer app, patch the smallest safe fix, and report the exact verification result."
        )
      ]
    }

    if matchesAny(haystack, ["finder", "desktop"]) {
      return [
        appSuggestion(
          id: "active-finder-file-organization",
          title: "Organize visible files",
          detail: "OpenClicky can file screenshots, images, and Desktop items using the known archive workflows and exact output paths.",
          prompt: "Organize the visible Finder/Desktop files with OpenClicky's existing filing workflow, preserving exact output paths in the summary."
        )
      ]
    }

    if matchesAny(haystack, ["notes"]) {
      return [
        appSuggestion(
          id: "active-notes-lookup",
          title: "Find and summarize notes",
          detail: "OpenClicky has a local Apple Notes lookup workflow for finding a note and summarizing the relevant content.",
          prompt: "Use OpenClicky's Apple Notes workflow to find and summarize the active or relevant note."
        )
      ]
    }

    if matchesAny(haystack, ["github"]) {
      return [
        mcpSuggestion(
          id: "active-github-pr-workflow",
          title: "GitHub PR workflow",
          detail: "OpenClicky can use GitHub-connected tooling or local git context to inspect issues, PRs, branches, and push-readiness.",
          prompt: "Use OpenClicky's GitHub workflow to inspect the active repository or PR context and summarize what needs action."
        )
      ]
    }

    if matchesAny(haystack, ["figma", "canva", "notion", "linear"]) {
      return [
        mcpSuggestion(
          id: "active-\(slug(for: appName))-connector",
          title: "\(appName) connector",
          detail: "OpenClicky can route \(appName) work through connector/MCP-style integrations when available, instead of relying on manual browser steps.",
          prompt: "Connect OpenClicky to \(appName) for the active workflow, using the available connector or MCP route if installed."
        )
      ]
    }

    return [
      appSuggestion(
        id: "active-\(slug(for: appName))-screen-context",
        title: "\(appName) screen context",
        detail: "OpenClicky can use the active \(appName) window as visual context and suggest the safest available automation route.",
        prompt: "Use OpenClicky's screen context for the active \(appName) window and suggest the best available skill, MCP, or agent workflow."
      )
    ]
  }

  private func appSuggestion(id: String, title: String, detail: String, prompt: String) -> OpenClickySkillDiscoverySuggestion {
    OpenClickySkillDiscoverySuggestion(
      id: id,
      title: title,
      detail: detail,
      source: "app",
      installPrompt: prompt
    )
  }

  private func mcpSuggestion(id: String, title: String, detail: String, prompt: String) -> OpenClickySkillDiscoverySuggestion {
    OpenClickySkillDiscoverySuggestion(
      id: id,
      title: title,
      detail: detail,
      source: "mcp",
      installPrompt: prompt
    )
  }

  private func matchesAny(_ haystack: String, _ needles: [String]) -> Bool {
    needles.contains { haystack.contains($0) }
  }

  private func slug(for value: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let parts = value
      .lowercased()
      .unicodeScalars
      .map { allowed.contains($0) ? Character($0) : "-" }
    return String(parts)
      .split(separator: "-")
      .joined(separator: "-")
  }

  private static let defaultSuggestions: [OpenClickySkillDiscoverySuggestion] = [
    OpenClickySkillDiscoverySuggestion(
      id: "openclicky-source-change",
      title: "OpenClicky source-change workflow",
      detail: "Default installed workflow for focused OpenClicky repo edits, dirty-worktree safety, narrow patches, and lightweight verification.",
      source: "installed",
      installPrompt: "Use the installed openclicky-source-change skill for the next OpenClicky repo patch."
    ),
    OpenClickySkillDiscoverySuggestion(
      id: "openclicky-overlay-ui",
      title: "OpenClicky overlay UI workflow",
      detail: "Default installed workflow for HUD, panel, notch, caption, parked-agent, resizing, and Connect-tab UI issues.",
      source: "installed",
      installPrompt: "Use the installed openclicky-overlay-ui skill to audit and fix the next OpenClicky panel or HUD layout issue."
    ),
    OpenClickySkillDiscoverySuggestion(
      id: "openclicky-voice-routing",
      title: "OpenClicky voice routing workflow",
      detail: "Default installed workflow for Realtime, transcription, task-title speech, completion summaries, and spoken-status behavior.",
      source: "installed",
      installPrompt: "Use the installed openclicky-voice-routing skill to debug the next voice or Realtime routing issue."
    ),
    OpenClickySkillDiscoverySuggestion(
      id: "openclicky-log-learning",
      title: "OpenClicky log-learning workflow",
      detail: "Default maintenance workflow for bounded log review, durable learnings, review notes, and archive-first updates.",
      source: "installed",
      installPrompt: "Run OpenClicky's bounded conversation-log learning pass and make only evidence-backed durable updates."
    ),
    OpenClickySkillDiscoverySuggestion(
      id: "github-pr-workflow",
      title: "GitHub PR workflow",
      detail: "Default connector-style workflow for repository, issue, PR, and branch checks when OpenClicky has GitHub access.",
      source: "mcp",
      installPrompt: "Use OpenClicky's GitHub workflow to inspect the active repository or PR and summarize what needs action."
    )
  ]
}
