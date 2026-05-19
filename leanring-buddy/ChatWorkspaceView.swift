//
//  ChatWorkspaceView.swift
//  OpenClicky
//
//  Three-pane composer: collapsible-to-zero conversation sidebar | chat
//  pane (header bar + embedded CodexHUDView body, no inner header/composer)
//  + ChatGPT-style composer at the bottom | optional memory drawer.
//

import SwiftUI
import UniformTypeIdentifiers

struct ChatWorkspaceView: View {
  private struct ChatDraftAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let kind: Kind

    enum Kind {
      case image
      case document
    }

    var displayName: String {
      url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    var chipTitle: String {
      kind == .image ? "Image attached" : "File attached"
    }

    var systemImage: String {
      kind == .image ? "photo" : "doc.text"
    }
  }

  @ObservedObject var companionManager: CompanionManager
  var openMemory: () -> Void
  var prepareVoiceFollowUp: () -> Void
  var dismiss: () -> Void

  @AppStorage("openClickyAgentHUDSidebarVisible") private var sidebarVisible: Bool = false
  @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
  @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
  @AppStorage(AppBundleConfiguration.userAppLineSpacingDefaultsKey) private var appLineSpacing = 2.0
  @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
  @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0
  @State private var memoryDrawerOpen: Bool = false
  @State private var draft: String = ""
  @State private var droppedAttachments: [ChatDraftAttachment] = []
  @State private var isDropTargeted = false

  // OpenClicky panel palette.
  private static let paneBg = DS.Colors.background
  private static let textPrimary = DS.Colors.textPrimary
  private static let textSecondary = DS.Colors.textSecondary
  private static let accent = DS.Colors.accentText

  private var appFont: OpenClickyResponseCaptionFont {
    OpenClickyResponseCaptionFont.resolved(appFontRawValue)
  }

  private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
  private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }
  private var appTextLineSpacing: CGFloat { CGFloat(appLineSpacing) }

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
          openMemory: openMemory,
          dismissHUD: dismiss
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
    .lineSpacing(appTextLineSpacing)
    .overlay(alignment: .center) {
      if isDropTargeted {
        dropTargetOverlay
          .padding(18)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .onDrop(
      of: [UTType.fileURL.identifier, UTType.image.identifier, UTType.png.identifier, UTType.jpeg.identifier],
      isTargeted: $isDropTargeted,
      perform: handleDrop
    )
    .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
    .animation(.easeInOut(duration: 0.18), value: memoryDrawerOpen)
    .animation(.easeOut(duration: 0.16), value: droppedAttachments)
  }

  // MARK: ChatGPT-style composer

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !droppedAttachments.isEmpty {
        attachmentChipRow
      }

      HStack(spacing: 10) {
        Image(systemName: droppedAttachments.isEmpty ? "plus" : "paperclip")
          .font(appUIFont(size: max(13, subtextFontSize + 1), weight: .semibold))
          .foregroundColor(Self.textSecondary)
          .frame(width: 28, height: 28)
          .background(
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 1)
          )
          .help("Drop files into the HUD to attach")

        TextField(droppedAttachments.isEmpty ? "Ask anything" : "Ask about the attachment…", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .font(appUIFont(size: max(13, bodyFontSize), weight: .medium))
          .foregroundColor(Self.textPrimary)
          .lineLimit(1...6)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .onSubmit(send)

        Button(action: prepareVoiceFollowUp) {
          Image(systemName: "waveform")
            .font(appUIFont(size: max(14, subtextFontSize + 2), weight: .medium))
            .foregroundColor(Self.textSecondary)
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Voice")

        // model pill (mirrors header picker, smaller)
        modelPill

        Button(action: send) {
          Image(systemName: "arrow.up.circle.fill")
            .font(appUIFont(size: max(22, bodyFontSize + 9), weight: .medium))
            .foregroundColor(canSend ? Self.accent : Self.textSecondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
    .padding(.top, 4)
  }

  private var attachmentChipRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 7) {
        ForEach(droppedAttachments) { attachment in
          HStack(spacing: 7) {
            Image(systemName: attachment.systemImage)
              .font(appUIFont(size: max(10, subtextFontSize), weight: .bold))
              .foregroundColor(attachment.kind == .image ? Self.accent : Self.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
              Text(attachment.chipTitle)
                .font(appUIFont(size: max(10, subtextFontSize), weight: .bold))
                .foregroundColor(Self.textPrimary)
                .lineLimit(1)
              Text(attachment.displayName)
                .font(appUIFont(size: max(8, subtextFontSize - 3), weight: .semibold))
                .foregroundColor(Self.textSecondary.opacity(0.75))
                .lineLimit(1)
            }
            Button(action: { removeAttachment(attachment) }) {
              Image(systemName: "xmark")
                .font(appUIFont(size: max(8, subtextFontSize - 3), weight: .semibold))
                .foregroundColor(Self.textSecondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Remove attachment")
          }
          .padding(.leading, max(8, subtextFontSize * 0.72))
          .padding(.trailing, max(7, subtextFontSize * 0.64))
          .padding(.vertical, max(6, subtextFontSize * 0.50))
          .background(Capsule(style: .continuous).fill(DS.Colors.surface2))
          .overlay(Capsule(style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 0.6))
        }
      }
    }
  }

  private var dropTargetOverlay: some View {
    RoundedRectangle(cornerRadius: 16, style: .continuous)
      .fill(Self.paneBg.opacity(0.92))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Self.accent.opacity(0.50), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
      )
      .overlay(
        VStack(spacing: 7) {
          Image(systemName: "plus.rectangle.on.folder")
            .font(appUIFont(size: max(22, bodyFontSize + 9), weight: .bold))
            .foregroundColor(Self.accent)
          Text("Drop images or docs into OpenClicky")
            .font(appUIFont(size: max(12, bodyFontSize - 1), weight: .bold))
            .foregroundColor(Self.textPrimary)
          Text("They’ll attach as chips before sending")
            .font(appUIFont(size: max(10, subtextFontSize - 1), weight: .semibold))
            .foregroundColor(Self.textSecondary)
        }
      )
  }

  private var modelPill: some View {
    let label = currentModelLabel
    return Text(label)
      .font(appUIFont(size: max(11, subtextFontSize), weight: .medium))
      .foregroundColor(Self.textSecondary)
      .padding(.horizontal, max(8, subtextFontSize * 0.72))
      .padding(.vertical, max(4, subtextFontSize * 0.40))
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
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !droppedAttachments.isEmpty
  }

  private func send() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = droppedAttachments
    guard !trimmed.isEmpty || !attachments.isEmpty else { return }
    companionManager.submitNewAgentTaskFromUI(promptWithAttachments(trimmed, attachments: attachments), source: "chat_workspace_prompt")
    draft = ""
    droppedAttachments.removeAll()
  }

  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    var acceptedDrop = false

    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        acceptedDrop = true
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
          guard let url = Self.fileURL(from: item) else { return }
          Task { @MainActor in
            addAttachment(url)
          }
        }
        continue
      }

      if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        acceptedDrop = true
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
          guard let data, let url = Self.persistDroppedImage(data) else { return }
          Task { @MainActor in
            addAttachment(url, forcedKind: .image)
          }
        }
      }
    }

    return acceptedDrop
  }

  private func addAttachment(_ url: URL, forcedKind: ChatDraftAttachment.Kind? = nil) {
    let standardizedURL = url.standardizedFileURL
    guard droppedAttachments.contains(where: { $0.url.standardizedFileURL == standardizedURL }) == false else { return }
    droppedAttachments.append(ChatDraftAttachment(url: standardizedURL, kind: forcedKind ?? Self.attachmentKind(for: standardizedURL)))
  }

  private func removeAttachment(_ attachment: ChatDraftAttachment) {
    droppedAttachments.removeAll { $0.id == attachment.id }
  }

  private func promptWithAttachments(_ prompt: String, attachments: [ChatDraftAttachment]) -> String {
    guard !attachments.isEmpty else { return prompt }
    let request = prompt.isEmpty ? "Please review the attached file(s)." : prompt
    let attachmentLines = attachments.enumerated().map { index, attachment in
      "\(index + 1). \(attachment.kind == .image ? "Image" : "Document"): \(attachment.url.path)"
    }.joined(separator: "\n")

    return """
    \(request)

    OpenClicky chat attachments:
    These attachments are task context/reference material. Use them to understand and complete the request; do not treat them as files the user is asking you to find or show back unless the request explicitly says so.
    \(attachmentLines)
    """.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func fileURL(from item: Any?) -> URL? {
    if let url = item as? URL {
      return url.isFileURL ? url : nil
    }
    if let data = item as? Data {
      return URL(dataRepresentation: data, relativeTo: nil)?.standardizedFileURL
    }
    if let data = item as? NSData {
      return URL(dataRepresentation: data as Data, relativeTo: nil)?.standardizedFileURL
    }
    if let string = item as? String {
      return URL(string: string)?.standardizedFileURL
    }
    return nil
  }

  private static func attachmentKind(for url: URL) -> ChatDraftAttachment.Kind {
    if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
       type.conforms(to: .image) {
      return .image
    }

    let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
    if imageExtensions.contains(url.pathExtension.lowercased()) {
      return .image
    }

    return .document
  }

  private static func persistDroppedImage(_ data: Data) -> URL? {
    let directory = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/OpenClicky/AgentMode/DroppedAttachments", isDirectory: true)

    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("chat-image-\(UUID().uuidString).png", isDirectory: false)
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }
}
