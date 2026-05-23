import AppKit
import SwiftUI
import OpenClickyCore
import UniformTypeIdentifiers

struct OpenClickyAgentLiveActivity: Equatable {
    var isActive = false
    var runningCount = 0
    var primaryTitle: String?
    var detail: String?
    var phaseLabel: String?

    var headline: String {
        if runningCount > 1 { return "\(runningCount) agents working" }
        let title = primaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        return isActive ? "Agent working" : ""
    }

    var subtitle: String {
        let phase = phaseLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !phase.isEmpty {
            return phase
        }
        return runningCount > 1 ? "\(runningCount) agents active" : "Agent active"
    }
}

struct OpenClickyNotchContextAction: Equatable, Identifiable {
    var id: String { title }
    var title: String
    var systemImage: String
    var prompt: String
}

struct OpenClickyNotchContextSuggestion: Equatable {
    enum Source: Equatable {
        case app
        case selection
    }

    var source: Source
    var title: String
    var subtitle: String
    var appIcon: NSImage?
    var appName: String
    var actions: [OpenClickyNotchContextAction]
    var primaryPrompt: String

    static func == (lhs: OpenClickyNotchContextSuggestion, rhs: OpenClickyNotchContextSuggestion) -> Bool {
        lhs.source == rhs.source
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.appName == rhs.appName
            && lhs.actions == rhs.actions
            && lhs.primaryPrompt == rhs.primaryPrompt
    }
}

#if canImport(DynamicNotchKit)
import DynamicNotchKit
import Combine

@MainActor
private final class OpenClickyDynamicNotchKitModel: ObservableObject {
    enum Mode {
        case collapsed
        case voice(OpenClickyNotchVoicePhase)
    }

    @Published var mode: Mode = .collapsed
    @Published var foregroundAppIcon: NSImage?
    @Published var foregroundAppName = "Current app"
    @Published var agentLiveActivity = OpenClickyAgentLiveActivity()
    var hasRunningAgentWork: Bool { agentLiveActivity.isActive }
    var isDoingSomething: Bool {
        switch mode {
        case .collapsed:
            return hasRunningAgentWork
        case .voice(let phase):
            return phase != .idle
        }
    }
    var activityAccentColor: NSColor {
        switch mode {
        case .collapsed:
            return hasRunningAgentWork ? .systemIndigo : accentColor
        case .voice(let phase):
            switch phase {
            case .idle: return accentColor
            case .listening: return .systemCyan
            case .processing: return .systemPurple
            case .responding: return .systemOrange
            }
        }
    }
    var compactActivityTitle: String? {
        switch mode {
        case .collapsed:
            guard hasRunningAgentWork else { return nil }
            let headline = agentLiveActivity.headline.trimmingCharacters(in: .whitespacesAndNewlines)
            return headline.isEmpty ? "Working" : headline
        case .voice(let phase):
            switch phase {
            case .idle: return nil
            case .listening: return "Listening"
            case .processing: return "Thinking"
            case .responding: return "Speaking"
            }
        }
    }
    @Published var accentColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.00, alpha: 1.0)
    @Published var theme: ClickyTheme = .current
    @Published var audioPowerLevel: CGFloat = 0
    var openMainPanel: () -> Void = {}
    var openNotch: () -> Void = {}
    var closeNotch: () -> Void = {}

    // Notch text-input surface (shift+shift "Ask Clicky" prompt). The input row
    // lives inside the expanded notch view; these drive its draft state.
    @Published var draftText: String = ""
    @Published var draftAttachments: [URL] = []
    @Published var isDropTargeted = false
    @Published var isInputFocused = false
    @Published var isNotchHovered = false
    @Published var isExpanded = false
    @Published var contextSuggestion: OpenClickyNotchContextSuggestion?
    var hidesWhenClosed = false
    /// Bumped to ask the expanded input row to take keyboard focus.
    @Published var inputFocusRequest = 0
    var submitText: (String) -> Void = { _ in }

    /// Collapse the notch only when the pointer has left it and the input is
    /// not being typed into — keeps the notch open while the user types.
    func closeNotchIfIdle() {
        guard !isNotchHovered, !isInputFocused, !isDropTargeted else { return }
        closeNotch()
    }

    func runContextAction(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        contextSuggestion = nil
        submitText(trimmed)
        closeNotch()
    }
    

    func dismissContextSuggestion() {
        contextSuggestion = nil
        closeNotchIfIdle()
    }

    func acceptDroppedAttachmentProviders(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = Self.url(from: item) else { return }
                    Task { @MainActor [weak self] in
                        self?.appendDraftAttachment(url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    guard let url = Self.url(from: item) else { return }
                    Task { @MainActor [weak self] in
                        self?.appendDraftAttachment(url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let url = Self.persistClipboardImage(data) else { return }
                    Task { @MainActor [weak self] in
                        self?.appendDraftAttachment(url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                    guard let data, let url = Self.persistClipboardImage(data) else { return }
                    Task { @MainActor [weak self] in
                        self?.appendDraftAttachment(url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { data, _ in
                    guard let data, let url = Self.persistClipboardImage(data) else { return }
                    Task { @MainActor [weak self] in
                        self?.appendDraftAttachment(url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.tiff.identifier) { data, _ in
                    guard let data, let url = Self.persistClipboardImage(data) else { return }
                    Task { @MainActor [weak self] in
                        self?.appendDraftAttachment(url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    guard let url = Self.fileURL(fromTextItem: item) else { return }
                    Task { @MainActor [weak self] in
                        self?.appendDraftAttachment(url)
                    }
                }
            }
        }
        return accepted
    }

    func acceptPasteboardAttachments(_ pasteboard: NSPasteboard = .general) -> Bool {
        let attachments = Self.attachmentURLs(from: pasteboard)
        guard !attachments.isEmpty else { return false }
        for url in attachments {
            appendDraftAttachment(url)
        }
        return true
    }

    private func appendDraftAttachment(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard !draftAttachments.contains(standardized) else { return }
        draftAttachments.append(standardized)
        isInputFocused = true
        openNotch()
    }

    func scrubDroppedFileTextFromDraft() {
        guard !draftText.isEmpty, !draftAttachments.isEmpty else { return }
        var scrubbedText = draftText
        for attachment in draftAttachments {
            for fragment in Self.promptPathFragments(for: attachment) where !fragment.isEmpty {
                scrubbedText = scrubbedText.replacingOccurrences(of: fragment, with: "")
            }
        }
        let normalized = Self.normalizedPromptAfterDroppingPathText(scrubbedText)
        if normalized != draftText {
            draftText = normalized
        }
    }

    nonisolated private static func attachmentURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            let key = standardized.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            urls.append(standardized)
        }

        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in fileURLs where url.isFileURL {
                append(url)
            }
        }

        for item in pasteboard.pasteboardItems ?? [] {
            if let fileURLString = item.string(forType: .fileURL),
               let url = URL(string: fileURLString),
               url.isFileURL {
                append(url)
            }
            if let pathString = item.string(forType: .string), let url = fileURLFromClipboardString(pathString) {
                append(url)
            }
            if let data = item.data(forType: .png) ?? item.data(forType: .tiff),
               let url = persistClipboardImage(data) {
                append(url)
            }
        }

        return urls
    }

    nonisolated private static func fileURLFromClipboardString(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("\n") == false else { return nil }
        if let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL
        }
        let expandedPath: String
        if trimmed.hasPrefix("~/") {
            expandedPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(trimmed.dropFirst(2)))
                .path
        } else {
            expandedPath = trimmed
        }
        var isDirectory: ObjCBool = false
        guard expandedPath.hasPrefix("/"), FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            return nil
        }
        return URL(fileURLWithPath: expandedPath, isDirectory: isDirectory.boolValue).standardizedFileURL
    }

    nonisolated private static func fileURL(fromTextItem item: NSSecureCoding?) -> URL? {
        if let string = item as? String {
            return fileURLFromClipboardString(string)
        }
        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8) {
            return fileURLFromClipboardString(string)
        }
        if let attributed = item as? NSAttributedString {
            return fileURLFromClipboardString(attributed.string)
        }
        return nil
    }

    nonisolated private static func promptPathFragments(for url: URL) -> [String] {
        let standardized = url.standardizedFileURL
        var fragments: [String] = [standardized.path, standardized.absoluteString]
        if let decodedPath = standardized.path.removingPercentEncoding, decodedPath != standardized.path {
            fragments.append(decodedPath)
        }
        if let decodedAbsoluteString = standardized.absoluteString.removingPercentEncoding,
           decodedAbsoluteString != standardized.absoluteString {
            fragments.append(decodedAbsoluteString)
        }
        return Array(Set(fragments))
    }

    nonisolated private static func normalizedPromptAfterDroppingPathText(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    nonisolated private static func persistClipboardImage(_ data: Data) -> URL? {
        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenClicky/AgentMode/DroppedAttachments", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("notch-paste-\(UUID().uuidString).png", isDirectory: false)
            let pngData = pngImageData(from: data) ?? data
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    nonisolated private static func pngImageData(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    nonisolated private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }
}

@MainActor
final class OpenClickyDynamicNotchKitBridge {
    private let model = OpenClickyDynamicNotchKitModel()
    private var targetScreen: NSScreen?
    private lazy var notch: DynamicNotch<OpenClickyDynamicNotchKitExpandedView, OpenClickyDynamicNotchKitCompactLeadingView, OpenClickyDynamicNotchKitCompactTrailingView> = {
        let notch = DynamicNotch(
            hoverBehavior: [.hapticFeedback, .increaseShadow, .keepVisible],
            style: .notch(topCornerRadius: 13, bottomCornerRadius: 20)
        ) {
            OpenClickyDynamicNotchKitExpandedView(model: self.model)
        } compactLeading: {
            OpenClickyDynamicNotchKitCompactLeadingView(model: self.model)
        } compactTrailing: {
            OpenClickyDynamicNotchKitCompactTrailingView(model: self.model)
        }
        notch.transitionConfiguration.skipIntermediateHides = true
        model.openNotch = { [weak self] in
            guard let self else { return }
            self.model.isExpanded = true
            let screen = self.currentTargetScreen()
            Task { await self.expandNotch(on: screen) }
        }
        model.closeNotch = { [weak self] in
            guard let self else { return }
            self.model.isExpanded = false
            let screen = self.currentTargetScreen()
            if self.model.hidesWhenClosed {
                Task { await self.notch.hide() }
            } else {
                Task { await self.compactNotch(on: screen) }
            }
        }
        return notch
    }()

    private func currentTargetScreen() -> NSScreen {
        targetScreen
            ?? notch.windowController?.window?.screen
            ?? NSScreen.openClickyActiveInteractionScreen()
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }

    private func prepareNotchForPresentation(on screen: NSScreen) async {
        targetScreen = screen
        if let currentScreen = notch.windowController?.window?.screen,
           currentScreen.displayID != screen.displayID {
            await notch.hide()
        }
    }

    private func expandNotch(on screen: NSScreen) async {
        await prepareNotchForPresentation(on: screen)
        await notch.expand(on: screen)
    }

    private func compactNotch(on screen: NSScreen) async {
        await prepareNotchForPresentation(on: screen)
        await notch.compact(on: screen)
    }

    func showCollapsed(
        on screen: NSScreen,
        accentColor: NSColor,
        foregroundAppIcon: NSImage?,
        foregroundAppName: String,
        hasRunningAgentWork: Bool,
        agentLiveActivity: OpenClickyAgentLiveActivity? = nil,
        openMainPanel: @escaping () -> Void,
        submitText: @escaping (String) -> Void = { _ in },
        opensExpanded: Bool = false
    ) {
        let liveActivity = agentLiveActivity ?? OpenClickyAgentLiveActivity()
        model.hidesWhenClosed = false
        model.mode = .collapsed
        model.contextSuggestion = nil
        model.accentColor = accentColor
        model.theme = .current
        model.foregroundAppIcon = foregroundAppIcon
        model.foregroundAppName = foregroundAppName
        model.agentLiveActivity = liveActivity.isActive ? liveActivity : OpenClickyAgentLiveActivity(isActive: hasRunningAgentWork, runningCount: hasRunningAgentWork ? 1 : 0)
        model.openMainPanel = openMainPanel
        model.submitText = submitText
        Task {
            if opensExpanded {
                model.isExpanded = true
                await expandNotch(on: screen)
            } else {
                model.isExpanded = false
                await compactNotch(on: screen)
            }
        }
    }

    func showVoice(
        _ phase: OpenClickyNotchVoicePhase,
        audioPowerLevel: CGFloat,
        on screen: NSScreen,
        accentColor: NSColor,
        foregroundAppIcon: NSImage?,
        foregroundAppName: String,
        openMainPanel: @escaping () -> Void,
        submitText: @escaping (String) -> Void = { _ in },
        opensExpanded: Bool = false
    ) {
        model.hidesWhenClosed = false
        model.mode = .voice(phase)
        model.contextSuggestion = nil
        model.accentColor = accentColor
        model.theme = .current
        model.foregroundAppIcon = foregroundAppIcon
        model.foregroundAppName = foregroundAppName
        model.audioPowerLevel = audioPowerLevel
        model.openMainPanel = openMainPanel
        model.submitText = submitText
        Task {
            if opensExpanded {
                model.isExpanded = true
                await expandNotch(on: screen)
            } else {
                model.isExpanded = false
                await compactNotch(on: screen)
            }
        }
    }

    /// Expands the notch and routes keyboard focus into the in-notch "Ask
    /// Clicky" input. Used by the shift+shift shortcut.
    func showTextInput(
        on screen: NSScreen,
        accentColor: NSColor,
        foregroundAppIcon: NSImage?,
        foregroundAppName: String,
        submitText: @escaping (String) -> Void,
        hidesWhenClosed: Bool = false
    ) {
        model.hidesWhenClosed = hidesWhenClosed
        model.contextSuggestion = nil
        model.accentColor = accentColor
        model.theme = .current
        model.foregroundAppIcon = foregroundAppIcon
        model.foregroundAppName = foregroundAppName
        model.submitText = submitText
        model.isExpanded = true
        Task {
            await expandNotch(on: screen)
            notch.windowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Let SwiftUI lay out the expanded view before requesting focus.
            try? await Task.sleep(nanoseconds: 120_000_000)
            model.inputFocusRequest &+= 1
        }
    }

    func showContextSuggestion(
        _ suggestion: OpenClickyNotchContextSuggestion,
        on screen: NSScreen,
        accentColor: NSColor,
        foregroundAppIcon: NSImage?,
        foregroundAppName: String,
        submitText: @escaping (String) -> Void
    ) {
        model.hidesWhenClosed = false
        model.mode = .collapsed
        model.contextSuggestion = nil
        model.accentColor = accentColor
        model.theme = .current
        model.foregroundAppIcon = foregroundAppIcon
        model.foregroundAppName = foregroundAppName
        model.submitText = submitText
        model.contextSuggestion = suggestion
        model.isExpanded = true
        Task { await expandNotch(on: screen) }
    }

    func updateAudioPowerLevel(_ audioPowerLevel: CGFloat) {
        model.audioPowerLevel = audioPowerLevel
    }

    func updateForegroundApp(icon: NSImage?, name: String) {
        model.foregroundAppIcon = icon
        model.foregroundAppName = name
    }

    func updateTheme(accentColor: NSColor, theme: ClickyTheme) {
        model.accentColor = accentColor
        model.theme = theme
    }

    func updateAgentLiveActivity(_ activity: OpenClickyAgentLiveActivity) {
        model.agentLiveActivity = activity
    }

    func open(on screen: NSScreen) {
        model.isExpanded = true
        Task { await expandNotch(on: screen) }
    }

    func close(on screen: NSScreen) {
        model.isExpanded = false
        Task { await compactNotch(on: screen) }
    }

    func hide() {
        model.contextSuggestion = nil
        model.isExpanded = false
        Task { await notch.hide() }
    }
}

private struct OpenClickyDynamicNotchKitCompactLeadingView: View {
    @ObservedObject var model: OpenClickyDynamicNotchKitModel

    var body: some View {
        HStack(spacing: 8) {
            compactAppIcon
            if let appName = compactAppName {
                Text(appName)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.white.opacity(0.94))
            }
        }
        // DynamicNotchKit lays compactLeading/compactTrailing on either side of
        // the real MacBook notch. Compact mode should show the foreground app
        // at a glance, but running-agent details belong in expanded/panel UI,
        // not stretched across the menu bar.
        .frame(width: compactWidth, height: 24, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.openNotch() }
        .onChange(of: model.isDropTargeted) { _, targeted in
            if targeted { model.openNotch() }
        }
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.image.identifier, UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier],
            isTargeted: $model.isDropTargeted,
            perform: model.acceptDroppedAttachmentProviders
        )
        .accessibilityLabel(accessibilityAppName)
    }

    @ViewBuilder
    private var compactAppIcon: some View {
        HStack(spacing: 7) {
            if let icon = model.foregroundAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(nsColor: model.activityAccentColor))
                    .frame(width: 22, height: 22)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.isDoingSomething)
    }

    private var accessibilityAppName: String {
        let name = model.foregroundAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "Current app" ? "Current app" : name
    }

    private var compactAppName: String? {
        let name = accessibilityAppName
        return name == "Current app" ? nil : name
    }

    private var compactWidth: CGFloat {
        model.isExpanded ? 20 : (compactAppName == nil ? 32 : 92)
    }
}

private struct OpenClickyDynamicNotchKitCompactTrailingView: View {
    @ObservedObject var model: OpenClickyDynamicNotchKitModel

    var body: some View {
        HStack {
            compactIndicator
        }
        .frame(width: compactWidth, height: 24, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { model.openNotch() }
        .onChange(of: model.isDropTargeted) { _, targeted in
            if targeted { model.openNotch() }
        }
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.image.identifier, UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier],
            isTargeted: $model.isDropTargeted,
            perform: model.acceptDroppedAttachmentProviders
        )
        .accessibilityLabel(indicatorLabel)
    }

    @ViewBuilder
    private var compactIndicator: some View {
        let color = Color(nsColor: model.activityAccentColor)
        HStack(spacing: 4) {
            switch model.mode {
            case .voice(let phase):
                if phase == .processing {
                    OpenClickyDynamicNotchKitDots(color: color)
                        .frame(width: 32, height: 14)
                } else {
                    OpenClickyDynamicNotchKitMiniMeter(level: model.audioPowerLevel, color: color)
                        .frame(width: 32, height: 16)
                }
            case .collapsed:
                OpenClickyDynamicNotchKitDots(color: color)
                    .frame(width: 24, height: 12)
            }
        }
        .padding(.horizontal, model.isDoingSomething ? 5 : 0)
        .padding(.vertical, model.isDoingSomething ? 4 : 0)
        .background(alignment: .trailing) {
            if model.isDoingSomething {
                OpenClickyDynamicNotchKitActivityGlow(color: color)
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.isDoingSomething)
    }

    private var indicatorLabel: String {
        switch model.mode {
        case .collapsed:
            return model.hasRunningAgentWork ? "Agent work running" : "OpenClicky ready"
        case .voice(let phase):
            switch phase {
            case .idle: return "Ready"
            case .listening: return "Listening"
            case .processing: return "Thinking"
            case .responding: return "Speaking"
            }
        }
    }

    private var compactWidth: CGFloat {
        model.isExpanded ? 20 : (model.isDoingSomething ? 52 : 28)
    }
}

private struct OpenClickyDynamicNotchKitExpandedView: View {
    @ObservedObject var model: OpenClickyDynamicNotchKitModel
    @Environment(\.colorScheme) private var colorScheme

    private var expandedWidth: CGFloat {
        model.contextSuggestion == nil ? 560 : 760
    }

    var body: some View {
        VStack(spacing: 9) {
            if let suggestion = model.contextSuggestion {
                contextSuggestionView(suggestion)
            } else {
                defaultExpandedView
            }
        }
        .frame(width: expandedWidth, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .onHover { isHovering in
            model.isNotchHovered = isHovering
            if !isHovering {
                model.closeNotchIfIdle()
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.image.identifier, UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier],
            isTargeted: $model.isDropTargeted,
            perform: model.acceptDroppedAttachmentProviders
        )
    }

    private var defaultExpandedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                expandedAppIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ask OpenClicky")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(primaryTextColor.opacity(0.96))
                        .lineLimit(1)
                    Text(expandedSubtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(primaryTextColor.opacity(0.56))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 34, alignment: .center)

            quickActionChips

            OpenClickyDynamicNotchKitInputRow(model: model)
        }
    }

    private var quickActionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                OpenClickyDynamicNotchKitChip(
                    title: "Open",
                    systemImage: "rectangle.inset.filled",
                    accentColor: Color(nsColor: model.activityAccentColor)
                ) {
                    model.openMainPanel()
                    model.closeNotch()
                }

                OpenClickyDynamicNotchKitChip(
                    title: "Agent",
                    systemImage: "terminal.fill",
                    accentColor: Color(nsColor: model.activityAccentColor)
                ) {
                    runQuickPrompt("Start an OpenClicky agent using the current screen as context.")
                }

                OpenClickyDynamicNotchKitChip(
                    title: "Screen",
                    systemImage: "rectangle.and.text.magnifyingglass",
                    accentColor: Color(nsColor: model.activityAccentColor)
                ) {
                    runQuickPrompt("Summarise what is visible on my screen.")
                }

                OpenClickyDynamicNotchKitChip(
                    title: "Skills",
                    systemImage: "hammer.fill",
                    accentColor: Color(nsColor: model.activityAccentColor)
                ) {
                    runQuickPrompt("OpenClicky, suggest useful skills or connections for the active app and current workflow.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runQuickPrompt(_ prompt: String) {
        model.submitText(prompt)
        model.closeNotch()
    }

    private func contextSuggestionView(_ suggestion: OpenClickyNotchContextSuggestion) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                contextIcon(suggestion)

                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.title)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(primaryTextColor.opacity(0.98))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(suggestion.subtitle)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(primaryTextColor.opacity(0.62))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    OpenClickyDynamicNotchKitDecisionButton(title: "No", systemImage: "xmark", tint: .white.opacity(0.18)) {
                        model.dismissContextSuggestion()
                    }
                    OpenClickyDynamicNotchKitDecisionButton(title: "Not now", systemImage: "clock", tint: .white.opacity(0.18)) {
                        model.dismissContextSuggestion()
                    }
                    OpenClickyDynamicNotchKitDecisionButton(title: "Yes", systemImage: "link", tint: Color(nsColor: model.activityAccentColor).opacity(0.86)) {
                        model.runContextAction(suggestion.primaryPrompt)
                    }
                }
            }
            .frame(height: 46, alignment: .center)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestion.actions) { action in
                        OpenClickyDynamicNotchKitWideChip(
                            title: action.title,
                            systemImage: action.systemImage,
                            accentColor: Color(nsColor: model.activityAccentColor)
                        ) {
                            model.runContextAction(action.prompt)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func contextIcon(_ suggestion: OpenClickyNotchContextSuggestion) -> some View {
        if let icon = suggestion.appIcon ?? model.foregroundAppIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: suggestion.source == .selection ? "text.cursor" : "app.fill")
                .font(.system(size: 21, weight: .heavy))
                .foregroundStyle(Color(nsColor: model.activityAccentColor))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var primaryTextColor: Color {
        usesLightTheme ? .black : .white
    }

    private var usesLightTheme: Bool {
        model.theme == .light || (model.theme == .system && colorScheme == .light)
    }

    @ViewBuilder
    private var expandedAppIcon: some View {
        if let icon = model.foregroundAppIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color(nsColor: model.activityAccentColor))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var expandedTitle: String {
        switch model.mode {
        case .collapsed:
            if model.hasRunningAgentWork { return model.agentLiveActivity.headline }
            let name = model.foregroundAppName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || name == "Current app" ? "Current app" : name
        case .voice(let phase):
            switch phase {
            case .idle: return "OpenClicky ready"
            case .listening: return "Listening"
            case .processing: return "Thinking"
            case .responding: return "Speaking"
            }
        }
    }

    private var expandedSubtitle: String {
        if model.hasRunningAgentWork, case .collapsed = model.mode {
            return model.agentLiveActivity.subtitle
        }
        let name = model.foregroundAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "Current app" {
            return "Choose a control or open the panel"
        }
        return "Focused in \(name)"
    }
}

/// The "Ask Clicky" prompt input embedded in the expanded notch. Carries a
/// text field, drafted file attachments, and a send action. Submitting routes
/// the composed prompt through `model.submitText`.
private struct OpenClickyDynamicNotchKitInputRow: View {
    @ObservedObject var model: OpenClickyDynamicNotchKitModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var fieldFocused: Bool

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.draftAttachments.isEmpty {
                attachmentChips
            }

            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color(nsColor: model.activityAccentColor))

                TextField("Ask OpenClicky…", text: $model.draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryTextColor.opacity(0.95))
                    .lineLimit(1...5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            insertDraftNewline()
                            return .handled
                        }
                        submit()
                        return .handled
                    }
                    .onKeyPress("v", phases: .down) { keyPress in
                        guard keyPress.modifiers.contains(.command) else { return .ignored }
                        return model.acceptPasteboardAttachments() ? .handled : .ignored
                    }
                    .onDrop(
                        of: Self.attachmentDropTypeIdentifiers,
                        isTargeted: $model.isDropTargeted,
                        perform: model.acceptDroppedAttachmentProviders
                    )

                Button(action: pickAttachments) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(primaryTextColor.opacity(0.66))
                }
                .buttonStyle(.plain)
                .help("Attach files")

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color(nsColor: model.activityAccentColor))
                }
                .buttonStyle(.plain)
                .help("Send to OpenClicky")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(inputBackgroundColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(primaryTextColor.opacity(0.10), lineWidth: 1)
            )
            .onDrop(
                of: Self.attachmentDropTypeIdentifiers,
                isTargeted: $model.isDropTargeted,
                perform: model.acceptDroppedAttachmentProviders
            )
        }
        .onChange(of: model.inputFocusRequest) { _, _ in
            fieldFocused = true
        }
        .onChange(of: model.draftText) { _, _ in
            model.scrubDroppedFileTextFromDraft()
        }
        .onChange(of: model.draftAttachments) { _, _ in
            model.scrubDroppedFileTextFromDraft()
        }
        .onChange(of: fieldFocused) { _, focused in
            model.isInputFocused = focused
            if !focused {
                model.closeNotchIfIdle()
            }
        }
        .onExitCommand {
            fieldFocused = false
            model.closeNotch()
        }
        .onDrop(
            of: Self.attachmentDropTypeIdentifiers,
            isTargeted: $model.isDropTargeted,
            perform: model.acceptDroppedAttachmentProviders
        )
    }

    private static let attachmentDropTypeIdentifiers = [
        UTType.fileURL.identifier,
        UTType.url.identifier,
        UTType.image.identifier,
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.tiff.identifier
    ]

    private var primaryTextColor: Color {
        usesLightTheme ? .black : .white
    }

    private var inputBackgroundColor: Color {
        usesLightTheme ? .white.opacity(0.34) : .black.opacity(0.28)
    }

    private var usesLightTheme: Bool {
        model.theme == .light || (model.theme == .system && colorScheme == .light)
    }

    private var attachmentChips: some View {
        HStack(spacing: 6) {
            ForEach(model.draftAttachments, id: \.self) { url in
                Button {
                    model.draftAttachments.removeAll { $0 == url }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: Self.isImage(url) ? "photo" : "doc")
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "xmark")
                    }
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Remove \(url.lastPathComponent)")
            }
        }
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !model.draftAttachments.contains(url) {
                model.draftAttachments.append(url)
            }
        }
        fieldFocused = true
    }

    private func insertDraftNewline() {
        model.draftText.append("\n")
    }

    private func submit() {
        let trimmed = model.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !model.draftAttachments.isEmpty else { return }
        let prompt = Self.composePrompt(trimmed, attachments: model.draftAttachments)
        let send = model.submitText
        model.draftText = ""
        model.draftAttachments = []
        fieldFocused = false
        model.isInputFocused = false
        send(prompt)
        model.closeNotch()
    }

    private static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Folds attachment paths into the prompt text so the existing
    /// `(String) -> Void` submit closure carries them without an API change.
    private static func composePrompt(_ text: String, attachments: [URL]) -> String {
        guard !attachments.isEmpty else { return text }
        let request = text.isEmpty ? "Please review the attached file(s)." : text
        let lines = attachments.enumerated().map { index, url in
            "\(index + 1). \(isImage(url) ? "Image" : "Document"): \(url.path)"
        }.joined(separator: "\n")
        return "\(request)\n\nOpenClicky notch input attachments:\n\(lines)"
    }
}

private struct OpenClickyDynamicNotchKitChip: View {
    let title: String
    let systemImage: String
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .bold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white.opacity(0.94))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(accentColor.opacity(0.22), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct OpenClickyDynamicNotchKitWideChip: View {
    let title: String
    let systemImage: String
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .heavy))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white.opacity(0.94))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct OpenClickyDynamicNotchKitDecisionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .heavy))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white.opacity(0.96))
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
                .background(tint, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}


private struct OpenClickyDynamicNotchKitActivityGlow: View {
    let color: Color

    var body: some View {
        ZStack(alignment: .trailing) {
            Capsule()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.00),
                            .init(color: .clear, location: 0.32),
                            .init(color: color.opacity(0.18), location: 0.52),
                            .init(color: color.opacity(0.70), location: 0.74),
                            .init(color: .white.opacity(0.12), location: 0.88),
                            .init(color: .clear, location: 1.00)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            Ellipse()
                .fill(color.opacity(0.92))
                .frame(width: 54, height: 36)
                .blur(radius: 14)
                .offset(x: 16)
            Ellipse()
                .fill(.white.opacity(0.20))
                .frame(width: 20, height: 15)
                .blur(radius: 8)
                .offset(x: -4, y: -6)
        }
        .frame(width: 78, height: 32)
        .clipShape(Capsule())
    }
}

private struct OpenClickyDynamicNotchKitDots: View {
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                .white.opacity(0.98),
                                color.opacity(index == 1 ? 1.0 : 0.86)
                            ],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 5
                        )
                    )
                    .frame(width: 5, height: 5)
                    .shadow(color: color.opacity(0.82), radius: 3.5, x: 0, y: 0)
                    .shadow(color: .white.opacity(index == 1 ? 0.34 : 0.22), radius: 1, x: 0, y: -0.5)
            }
        }
    }
}

private struct OpenClickyDynamicNotchKitMiniMeter: View {
    let level: CGFloat
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(0.55 + Double(index) * 0.10))
                    .frame(width: 3, height: max(4, min(14, 4 + (level * CGFloat(index + 1) * 10))))
            }
        }
    }
}
#else
@MainActor
final class OpenClickyDynamicNotchKitBridge {
    func showCollapsed(on screen: NSScreen, accentColor: NSColor, foregroundAppIcon: NSImage?, foregroundAppName: String, hasRunningAgentWork: Bool, agentLiveActivity: OpenClickyAgentLiveActivity = OpenClickyAgentLiveActivity(), openMainPanel: @escaping () -> Void, submitText: @escaping (String) -> Void = { _ in }, opensExpanded: Bool = false) {}
    func showVoice(_ phase: OpenClickyNotchVoicePhase, audioPowerLevel: CGFloat, on screen: NSScreen, accentColor: NSColor, foregroundAppIcon: NSImage?, foregroundAppName: String, openMainPanel: @escaping () -> Void, submitText: @escaping (String) -> Void = { _ in }, opensExpanded: Bool = false) {}
    func showTextInput(on screen: NSScreen, accentColor: NSColor, foregroundAppIcon: NSImage?, foregroundAppName: String, submitText: @escaping (String) -> Void, hidesWhenClosed: Bool = false) {}
    func showContextSuggestion(_ suggestion: OpenClickyNotchContextSuggestion, on screen: NSScreen, accentColor: NSColor, foregroundAppIcon: NSImage?, foregroundAppName: String, submitText: @escaping (String) -> Void) {}
    func open(on screen: NSScreen) {}
    func close(on screen: NSScreen) {}
    func updateAudioPowerLevel(_ audioPowerLevel: CGFloat) {}
    func updateForegroundApp(icon: NSImage?, name: String) {}
    func updateTheme(accentColor: NSColor, theme: ClickyTheme) {}
    func updateAgentLiveActivity(_ activity: OpenClickyAgentLiveActivity) {}
    func hide() {}
}
#endif
