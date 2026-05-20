//
//  MiniChatPanelManager.swift
//  OpenClicky
//
//  Floating per-session mini-chat NSPanel. One panel per session ID. Dies
//  with the parent HUD via `destroyAll()`.
//

import AppKit
import SwiftUI
import Combine

/// Lightweight UserDefaults-backed store for archived session IDs.
/// Lives here (not in CompanionManager.swift) so the additive patch
/// keeps that file's diff minimal.
enum ChatWorkspaceArchiveStore {
  struct Snapshot: Codable {
    let id: UUID
    let title: String
    let accentThemeRawValue: String
    let entries: [CodexTranscriptEntry]
    let activeThreadID: String?
    let lastSubmittedPrompt: String?
  }

  private static let key = "openClickyArchivedSessions"
  private static let snapshotsKey = "openClickyArchivedSessionSnapshots"
  private static let relaunchableSnapshotsKey = "openClickyRelaunchableAgentSessionSnapshots"

  static func load() -> Set<UUID> {
    guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else { return [] }
    return Set(raw.compactMap { UUID(uuidString: $0) })
  }

  static func save(_ ids: Set<UUID>) {
    UserDefaults.standard.set(ids.map { $0.uuidString }, forKey: key)
  }

  static func loadSnapshots() -> [Snapshot] {
    guard let data = UserDefaults.standard.data(forKey: snapshotsKey) else { return [] }
    return (try? JSONDecoder().decode([Snapshot].self, from: data)) ?? []
  }

  @MainActor
  static func saveSnapshot(for session: CodexAgentSession) {
    var snapshots = loadSnapshots().filter { $0.id != session.id }
    snapshots.append(
      Snapshot(
        id: session.id,
        title: session.title,
        accentThemeRawValue: session.accentTheme.rawValue,
        entries: session.entries,
        activeThreadID: session.activeThreadID,
        lastSubmittedPrompt: session.lastSubmittedPromptText
      )
    )
    saveSnapshots(snapshots)
  }

  static func removeSnapshot(for sessionID: UUID) {
    saveSnapshots(loadSnapshots().filter { $0.id != sessionID })
  }

  static func loadRelaunchableSnapshots() -> [Snapshot] {
    guard let data = UserDefaults.standard.data(forKey: relaunchableSnapshotsKey) else { return [] }
    return (try? JSONDecoder().decode([Snapshot].self, from: data)) ?? []
  }

  @MainActor
  static func saveRelaunchableSnapshots(for sessions: [CodexAgentSession], archivedSessionIDs: Set<UUID>) {
    let snapshots = sessions.compactMap { session -> Snapshot? in
      guard !archivedSessionIDs.contains(session.id),
            session.hasVisibleActivity,
            session.isRelaunchResumeCandidate else {
        return nil
      }
      return Snapshot(
        id: session.id,
        title: session.title,
        accentThemeRawValue: session.accentTheme.rawValue,
        entries: session.entries,
        activeThreadID: session.activeThreadID,
        lastSubmittedPrompt: session.lastSubmittedPromptText
      )
    }
    guard let data = try? JSONEncoder().encode(snapshots) else { return }
    UserDefaults.standard.set(data, forKey: relaunchableSnapshotsKey)
  }

  static func removeRelaunchableSnapshot(for sessionID: UUID) {
    let snapshots = loadRelaunchableSnapshots().filter { $0.id != sessionID }
    guard let data = try? JSONEncoder().encode(snapshots) else { return }
    UserDefaults.standard.set(data, forKey: relaunchableSnapshotsKey)
  }

  private static func saveSnapshots(_ snapshots: [Snapshot]) {
    guard let data = try? JSONEncoder().encode(snapshots) else { return }
    UserDefaults.standard.set(data, forKey: snapshotsKey)
  }
}

@MainActor
final class MiniChatPanelManager: NSObject {
  static let shared = MiniChatPanelManager()
  private var panels: [UUID: NSPanel] = [:]
  private var delegates: [UUID: MiniChatPanelDelegate] = [:]

  override private init() { super.init() }

  func show(session: CodexAgentSession, companion: CompanionManager) {
    if let existing = panels[session.id] {
      OpenClickyWindowLevels.applyPanelDialogLevel(to: existing)
      existing.orderFrontRegardless()
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let hosting = NSHostingView(
      rootView: MiniChatPanelView(
        session: session,
        companion: companion,
        close: { [weak self] in self?.close(sessionID: session.id) }
      )
    )

    // Standard window chrome — title bar + traffic lights, just smaller.
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered,
      defer: false
    )
    panel.title = session.title
    panel.titleVisibility = .visible
    panel.titlebarAppearsTransparent = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.isMovableByWindowBackground = false
    OpenClickyWindowLevels.applyPanelDialogLevel(to: panel)
    panel.collectionBehavior = [.fullScreenAuxiliary]
    panel.hasShadow = true
    panel.minSize = NSSize(width: 320, height: 400)
    OpenClickyLiquidGlassWindowSurface.install(
      hostingView: hosting,
      in: panel,
      frame: NSRect(x: 0, y: 0, width: 380, height: 520),
      cornerRadius: 18,
      strength: .expanded
    )

    if let screen = NSScreen.main?.visibleFrame {
      let x = screen.maxX - 380 - 24
      let y = screen.maxY - 520 - 24
      panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    let delegate = MiniChatPanelDelegate { [weak self] in self?.close(sessionID: session.id) }
    panel.delegate = delegate
    panel.isReleasedWhenClosed = false
    delegates[session.id] = delegate
    panels[session.id] = panel
    panel.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
  }

  func close(sessionID: UUID) {
    panels[sessionID]?.close()
    panels.removeValue(forKey: sessionID)
    delegates.removeValue(forKey: sessionID)
  }

  /// Called when the parent HUD is destroyed. Tears down every popout.
  func destroyAll() {
    for (_, panel) in panels { panel.close() }
    panels.removeAll()
    delegates.removeAll()
  }
}

private struct MiniChatPanelView: View {
  @ObservedObject var session: CodexAgentSession
  @ObservedObject var companion: CompanionManager
  var close: () -> Void
  @State private var draft: String = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().background(Color.white.opacity(0.08))
      transcript
      Divider().background(Color.white.opacity(0.08))
      composer
    }
    .glassEffect(
      .regular.tint(DS.Colors.accent.opacity(0.045)),
      in: RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
  }

  private var header: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(DS.Colors.accentText.opacity(0.7))
        .frame(width: 8, height: 8)
      Text(session.title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(DS.Colors.textPrimary)
        .lineLimit(1)
      Spacer()
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(DS.Colors.textSecondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(session.entries) { entry in
            MiniChatBubble(entry: entry).id(entry.id)
          }
        }
        .padding(12)
      }
      .onChange(of: session.entries.count) {
        if let last = session.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
      }
    }
  }

  private var composer: some View {
    HStack(spacing: 8) {
      TextField("Reply…", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundColor(DS.Colors.textPrimary)
        .lineLimit(1...4)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.04))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .onSubmit(send)
      Button(action: send) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 20))
          .foregroundColor(DS.Colors.accentText)
      }
      .buttonStyle(.plain)
      .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
  }

  private func send() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    session.submitPromptFromUI(trimmed, screenContext: nil)
    draft = ""
  }
}

private struct MiniChatBubble: View {
  let entry: CodexTranscriptEntry

  var body: some View {
    HStack {
      if entry.role == .user { Spacer(minLength: 24) }
      Text(entry.text)
        .font(.system(size: 12))
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(entry.role == .user
              ? DS.Colors.accentText.opacity(0.18)
              : Color.white.opacity(0.05))
        )
      if entry.role != .user { Spacer(minLength: 24) }
    }
  }
}

@MainActor
private final class MiniChatPanelDelegate: NSObject, NSWindowDelegate {
  let onClose: () -> Void
  init(onClose: @escaping () -> Void) {
    self.onClose = onClose
    super.init()
  }
  nonisolated func windowWillClose(_ notification: Notification) {
    Task { @MainActor in self.onClose() }
  }
}
