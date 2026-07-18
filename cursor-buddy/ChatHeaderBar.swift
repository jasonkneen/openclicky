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
  var dismissHUD: () -> Void
  @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
  @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
  @AppStorage(AppBundleConfiguration.userAppTitleFontSizeDefaultsKey) private var appTitleFontSize = 26.0
  @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
  @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0

  // OpenClicky panel palette.
  static let bg = DS.Colors.surface1
  static let textPrimary = DS.Colors.textPrimary
  static let textSecondary = DS.Colors.textSecondary

  private var appFont: OpenClickyResponseCaptionFont {
    OpenClickyResponseCaptionFont.resolved(appFontRawValue)
  }

  private var titleFontSize: CGFloat { CGFloat(appTitleFontSize) }
  private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
  private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }

  private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
    appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
  }

  private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
    guard appBoldTextEnabled else { return weight }
    switch weight {
    case .regular, .medium:
      return .semibold
    case .semibold:
      return .bold
    default:
      return weight
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      Button(action: { sidebarVisible.toggle() }) {
        Image(systemName: "sidebar.left")
          .font(appUIFont(size: max(13, subtextFontSize + 1), weight: .medium))
          .foregroundColor(Self.textSecondary)
          .frame(width: max(28, subtextFontSize + 17), height: max(28, subtextFontSize + 17))
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
        let isArchived = companion.archivedSessionIDs.contains(session.id)
        Button(isArchived ? "Unarchive conversation" : "Archive conversation") {
          if isArchived {
            companion.unarchiveSession(session.id)
          } else {
            companion.archiveSession(session.id)
          }
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(appUIFont(size: max(13, subtextFontSize + 1), weight: .medium))
          .foregroundColor(Self.textSecondary)
          .frame(width: max(28, subtextFontSize + 17), height: max(28, subtextFontSize + 17))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()

      iconButton(systemName: "xmark", help: "Close OpenClicky HUD") {
        dismissHUD()
      }
      .background(Circle().fill(DS.Colors.surface2.opacity(0.92)))
      .overlay(Circle().stroke(DS.Colors.borderSubtle, lineWidth: 1))
      .fixedSize()
      .accessibilityLabel("Close OpenClicky HUD")
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
      Section("Apple") {
        ForEach(appleOptions, id: \.id) { opt in modelButton(opt) }
      }
      Section("Claude Agent SDK") {
        ForEach(claudeOptions, id: \.id) { opt in modelButton(opt) }
      }
      Section("Codex / OpenAI") {
        ForEach(codexOptions, id: \.id) { opt in modelButton(opt) }
      }
    } label: {
      HStack(spacing: 4) {
        Text(headerTitle)
          .font(appUIFont(size: max(14, titleFontSize * 0.54), weight: .semibold))
          .foregroundColor(Self.textPrimary)
        Image(systemName: "chevron.down")
          .font(appUIFont(size: max(10, subtextFontSize - 1), weight: .semibold))
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
    if let match = (appleOptions + claudeOptions + codexOptions).first(where: { $0.id == id }) {
      return match.label
    }
    return id
  }

  private var appleOptions: [OpenClickyModelOption] {
    OpenClickyModelCatalog.voiceResponseModels.filter { $0.provider == .apple }
  }

  private var claudeOptions: [OpenClickyModelOption] {
    OpenClickyModelCatalog.voiceResponseModels.filter { $0.provider == .anthropic }
  }

  private var codexOptions: [OpenClickyModelOption] {
    OpenClickyModelCatalog.codexActionsModels
  }

  private func selectModel(_ id: String) {
    // Agent Mode stays Codex-only for task execution; chat header model still
    // updates the HUD session label. Voice backend family is set separately
    // via the bubble / notch selector.
    session.model = id
    UserDefaults.standard.set(id, forKey: "clickyCodexModel")
    if OpenClickyModelCatalog.voiceResponseModel(withID: id).provider == .apple
        || OpenClickyModelCatalog.voiceResponseModel(withID: id).provider == .anthropic {
      companion.setSelectedModel(id)
    }
  }

  private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(appUIFont(size: max(13, subtextFontSize + 1), weight: .medium))
        .foregroundColor(Self.textSecondary)
        .frame(width: max(28, subtextFontSize + 17), height: max(28, subtextFontSize + 17))
    }
    .buttonStyle(.plain)
    .help(help)
  }
}
