//
//  ChatWorkspaceView.swift
//  OpenClicky
//
//  Three-pane composer: collapsible-to-zero conversation sidebar | chat
//  pane (header bar + embedded CodexHUDView body, no inner header/composer)
//  + ChatGPT-style composer at the bottom | optional memory drawer.
//

import SwiftUI

struct ChatWorkspaceView: View {
  @ObservedObject var companionManager: CompanionManager
  var openMemory: () -> Void
  var prepareVoiceFollowUp: () -> Void
  var dismiss: () -> Void

  @AppStorage("openClickyAgentHUDSidebarVisible") private var sidebarVisible: Bool = false
  @State private var memoryDrawerOpen: Bool = false
  @State private var draft: String = ""

  // ChatGPT chat-pane palette
  private static let paneBg = Color(red: 0.117, green: 0.117, blue: 0.117)        // #1e1e1e
  private static let composerBg = Color(red: 0.133, green: 0.133, blue: 0.133)    // #222222
  private static let composerStroke = Color.white.opacity(0.10)
  private static let textPrimary = Color(red: 0.92, green: 0.92, blue: 0.93)
  private static let textSecondary = Color(red: 0.62, green: 0.62, blue: 0.64)
  private static let accent = Color(red: 0.30, green: 0.55, blue: 0.95)

  var body: some View {
    HStack(spacing: 0) {
      if sidebarVisible {
        ConversationSidebarView(companion: companionManager)
          .transition(.move(edge: .leading).combined(with: .opacity))
        Divider().background(Color.black.opacity(0.4)).frame(width: 1)
      }

      VStack(spacing: 0) {
        ChatHeaderBar(
          companion: companionManager,
          session: companionManager.codexAgentSession,
          sidebarVisible: $sidebarVisible,
          memoryDrawerOpen: $memoryDrawerOpen,
          openMemory: openMemory
        )

        CodexHUDView(
          companionManager: companionManager,
          openMemory: openMemory,
          prepareVoiceFollowUp: prepareVoiceFollowUp,
          close: dismiss,
          chromeMode: .embedded
        )

        composer
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Self.paneBg)

      if memoryDrawerOpen {
        Divider().background(Color.black.opacity(0.4)).frame(width: 1)
        MemoryDrawerView(
          companion: companionManager,
          isOpen: $memoryDrawerOpen
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .background(Self.paneBg)
    .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
    .animation(.easeInOut(duration: 0.18), value: memoryDrawerOpen)
  }

  // MARK: ChatGPT-style composer

  private var composer: some View {
    HStack(spacing: 10) {
      Button(action: {}) {
        Image(systemName: "plus")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(Self.textSecondary)
          .frame(width: 28, height: 28)
          .background(
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 1)
          )
      }
      .buttonStyle(.plain)
      .help("Attach")

      TextField("Ask anything", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundColor(Self.textPrimary)
        .lineLimit(1...6)
        .onSubmit(send)

      Button(action: prepareVoiceFollowUp) {
        Image(systemName: "waveform")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(Self.textSecondary)
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help("Voice")

      // model pill (mirrors header picker, smaller)
      modelPill

      Button(action: send) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 22))
          .foregroundColor(canSend ? Self.accent : Self.textSecondary.opacity(0.5))
      }
      .buttonStyle(.plain)
      .disabled(!canSend)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Self.composerBg)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(Self.composerStroke, lineWidth: 1)
    )
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
    .padding(.top, 4)
  }

  private var modelPill: some View {
    let label = currentModelLabel
    return Text(label)
      .font(.system(size: 11, weight: .medium))
      .foregroundColor(Self.textSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        Capsule().fill(Color.white.opacity(0.05))
      )
  }

  private var currentModelLabel: String {
    let id = companionManager.codexAgentSession.model
    let pool = OpenClickyModelCatalog.voiceResponseModels + OpenClickyModelCatalog.codexActionsModels
    return pool.first(where: { $0.id == id })?.label ?? id
  }

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func send() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    companionManager.submitNewAgentTaskFromUI(trimmed, source: "chat_workspace_prompt")
    draft = ""
  }
}
