//
//  ChatHeaderBar.swift
//  OpenClicky
//
//  ChatGPT-style top bar: ONE sidebar toggle (the only one in the app),
//  inline title + model picker dropdown ("ChatGPT 5.5 Instant >" pattern),
//  popout / archive / memory / more icons on the right.
//

import SwiftUI

struct ChatHeaderBar: View {
  @ObservedObject var companion: CompanionManager
  @ObservedObject var session: CodexAgentSession
  @Binding var sidebarVisible: Bool
  @Binding var memoryDrawerOpen: Bool
  var openMemory: () -> Void

  // ChatGPT header palette
  static let bg = Color(red: 0.137, green: 0.137, blue: 0.137)        // #232323
  static let textPrimary = Color(red: 0.92, green: 0.92, blue: 0.93)
  static let textSecondary = Color(red: 0.62, green: 0.62, blue: 0.64)

  var body: some View {
    HStack(spacing: 6) {
      Button(action: { sidebarVisible.toggle() }) {
        Image(systemName: "sidebar.left")
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(Self.textSecondary)
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help(sidebarVisible ? "Hide sidebar" : "Show sidebar")

      archiveToggleButton

      modelMenu

      Spacer()

      iconButton(systemName: "rectangle.on.rectangle", help: "Pop out mini chat") {
        companion.popoutCurrentSession()
      }
      iconButton(systemName: "brain", help: "Memory") {
        memoryDrawerOpen.toggle()
        openMemory()
      }
      Menu {
        Button("Rename") {}
        Button("Duplicate") {}
        Divider()
        Button("Close conversation", role: .destructive) {
          companion.closeCodexAgentSession(session.id)
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(Self.textSecondary)
          .frame(width: 28, height: 28)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Self.bg)
  }

  private var archiveToggleButton: some View {
    let isArchived = companion.archivedSessionIDs.contains(session.id)
    return iconButton(
      systemName: isArchived ? "tray.and.arrow.up" : "archivebox",
      help: isArchived ? "Unarchive conversation" : "Archive conversation"
    ) {
      if isArchived {
        companion.unarchiveSession(session.id)
      } else {
        companion.archiveSession(session.id)
      }
    }
  }

  private var modelMenu: some View {
    Menu {
      Section("Claude Agent SDK") {
        ForEach(claudeOptions, id: \.id) { opt in modelButton(opt) }
      }
      Section("Codex / OpenAI") {
        ForEach(codexOptions, id: \.id) { opt in modelButton(opt) }
      }
    } label: {
      HStack(spacing: 4) {
        Text(headerTitle)
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(Self.textPrimary)
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(Self.textSecondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  private var headerTitle: String {
    "OpenClicky " + currentModelLabel
  }

  private func modelButton(_ opt: OpenClickyModelOption) -> some View {
    Button(action: { selectModel(opt.id) }) {
      HStack {
        Text(opt.label)
        if opt.id == session.model {
          Spacer()
          Image(systemName: "checkmark")
        }
      }
    }
  }

  private var currentModelLabel: String {
    let id = session.model
    if let match = (claudeOptions + codexOptions).first(where: { $0.id == id }) {
      return match.label
    }
    return id
  }

  private var claudeOptions: [OpenClickyModelOption] {
    OpenClickyModelCatalog.voiceResponseModels.filter { $0.provider == .anthropic }
  }

  private var codexOptions: [OpenClickyModelOption] {
    OpenClickyModelCatalog.codexActionsModels
  }

  private func selectModel(_ id: String) {
    session.model = id
    UserDefaults.standard.set(id, forKey: "clickyCodexModel")
  }

  private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(Self.textSecondary)
        .frame(width: 28, height: 28)
    }
    .buttonStyle(.plain)
    .help(help)
  }
}
