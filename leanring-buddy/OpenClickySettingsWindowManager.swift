import AppKit
import SwiftUI

@MainActor
final class OpenClickySettingsWindowManager {
    private var window: NSWindow?
    private var hostingView: NSHostingView<OpenClickySettingsView>?
    private var glassBackdrop: OpenClickyLiquidGlassBackdropView?
    private let windowSize = NSSize(width: 1120, height: 760)
    private let minimumWindowSize = NSSize(width: 1040, height: 660)
    private let settingsWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    func show(companionManager: CompanionManager) {
        if window == nil {
            createWindow(companionManager: companionManager)
        } else if let hostingView {
            hostingView.rootView = OpenClickySettingsView(companionManager: companionManager)
        }

        guard let settingsWindow = window else { return }

        NSApp.activate(ignoringOtherApps: true)
        bringSettingsWindowToFront(settingsWindow, shouldCenter: true)

        DispatchQueue.main.async { [weak self, weak settingsWindow] in
            guard let self, let settingsWindow else { return }
            self.bringSettingsWindowToFront(settingsWindow, shouldCenter: false)
        }
    }

    private func bringSettingsWindowToFront(_ settingsWindow: NSWindow, shouldCenter: Bool) {
        // The main OpenClicky panel uses `.statusBar`, so Settings must sit one
        // level above it instead of the default floating level.
        settingsWindow.level = settingsWindowLevel
        settingsWindow.collectionBehavior.insert(.moveToActiveSpace)
        settingsWindow.collectionBehavior.insert(.fullScreenAuxiliary)
        ensureSettingsWindowFitsContent(settingsWindow, shouldCenter: shouldCenter)
        if shouldCenter {
            settingsWindow.center()
        }
        settingsWindow.deminiaturize(nil)
        settingsWindow.orderFrontRegardless()
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.makeMain()
    }

    private func ensureSettingsWindowFitsContent(_ settingsWindow: NSWindow, shouldCenter: Bool) {
        let visibleFrame = settingsWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let currentFrame = settingsWindow.frame
        let targetWidth = max(currentFrame.width, windowSize.width)
        let targetHeight = max(currentFrame.height, windowSize.height)
        let fittedWidth = visibleFrame.map { min(targetWidth, $0.width - 32) } ?? targetWidth
        let fittedHeight = visibleFrame.map { min(targetHeight, $0.height - 32) } ?? targetHeight
        guard fittedWidth > currentFrame.width || fittedHeight > currentFrame.height else { return }

        let targetSize = NSSize(width: fittedWidth, height: fittedHeight)
        if shouldCenter {
            settingsWindow.setContentSize(targetSize)
        } else {
            var targetFrame = currentFrame
            targetFrame.size = targetSize
            if let visibleFrame {
                targetFrame.origin.x = min(max(targetFrame.origin.x, visibleFrame.minX + 16), visibleFrame.maxX - targetSize.width - 16)
                targetFrame.origin.y = min(max(targetFrame.origin.y, visibleFrame.minY + 16), visibleFrame.maxY - targetSize.height - 16)
            }
            settingsWindow.setFrame(targetFrame, display: true, animate: false)
        }
    }

    private func createWindow(companionManager: CompanionManager) {
        let settingsWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = ""
        settingsWindow.titleVisibility = .hidden
        settingsWindow.minSize = minimumWindowSize
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.toolbarStyle = .unified
        settingsWindow.isOpaque = false
        settingsWindow.backgroundColor = .clear
        settingsWindow.hasShadow = true
        settingsWindow.level = settingsWindowLevel
        settingsWindow.collectionBehavior.insert(.moveToActiveSpace)
        settingsWindow.collectionBehavior.insert(.fullScreenAuxiliary)
        settingsWindow.center()

        let containerView = OpenClickyGlassContainerView(frame: NSRect(origin: .zero, size: windowSize))
        containerView.autoresizingMask = [.width, .height]
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor

        let backdrop = OpenClickyLiquidGlassBackdropView(cornerRadius: 22)
        backdrop.frame = containerView.bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.configure(
            cornerRadius: 22,
            roundsTopCorners: true,
            accentColor: OpenClickyNotchCaptureWindowManager.nsAccentColor(for: nil),
            strength: .expanded
        )
        containerView.addSubview(backdrop)

        let hostingView = NSHostingView(rootView: OpenClickySettingsView(companionManager: companionManager))
        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)

        settingsWindow.contentView = containerView
        self.hostingView = hostingView
        glassBackdrop = backdrop

        window = settingsWindow
    }
}

private enum OpenClickySettingsSection: String, CaseIterable, Identifiable {
    case general
    case voice
    case apiKeys
    case computerUse
    case permissions
    case agents
    case automations
    case connections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .voice: return "Voice"
        case .apiKeys: return "AI Providers"
        case .computerUse: return "Computer Use"
        case .permissions: return "Permissions"
        case .agents: return "Agents"
        case .automations: return "Automations"
        case .connections: return "System & Logs"
        }
    }

    var systemImageName: String {
        switch self {
        case .general: return "gearshape"
        case .voice: return "waveform"
        case .apiKeys: return "key"
        case .computerUse: return "macwindow.and.cursorarrow"
        case .permissions: return "hand.raised"
        case .agents: return "person.2"
        case .automations: return "calendar.badge.clock"
        case .connections: return "server.rack"
        }
    }
}

struct OpenClickySettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var session: CodexAgentSession
    @ObservedObject private var nativeComputerUseController: OpenClickyNativeComputerUseController
    @ObservedObject private var backgroundComputerUseController: OpenClickyBackgroundComputerUseController
    @ObservedObject private var petLibrary = ClickyBuddyPetLibrary.shared
    @StateObject private var openPetsCatalog = OpenPetsCatalogStore()
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    @AppStorage(ClickyCursorAvatarStyle.userDefaultsKey) private var avatarStyleRawValue = ClickyCursorAvatarStyle.default.storageValue
    @AppStorage(AppBundleConfiguration.userAnthropicAPIKeyDefaultsKey) private var userAnthropicAPIKey = ""
    @AppStorage(AppBundleConfiguration.userElevenLabsAPIKeyDefaultsKey) private var userElevenLabsAPIKey = ""
    @AppStorage(AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey) private var userElevenLabsVoiceID = ""
    @AppStorage(AppBundleConfiguration.userCartesiaAPIKeyDefaultsKey) private var userCartesiaAPIKey = ""
    @AppStorage(AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey) private var userCartesiaVoiceID = ""
    @AppStorage(AppBundleConfiguration.userOpenAIRealtimeVoiceIDDefaultsKey) private var userOpenAIRealtimeVoiceID = "marin"
    @AppStorage(AppBundleConfiguration.userMicrosoftEdgeVoiceIDDefaultsKey) private var userMicrosoftEdgeVoiceID = "en-US-EmmaMultilingualNeural"
    @AppStorage(AppBundleConfiguration.userDeepgramTTSVoiceDefaultsKey) private var userDeepgramTTSVoice = "aura-2-thalia-en"
    @AppStorage(AppBundleConfiguration.userDeepgramVoiceAgentThinkModelDefaultsKey) private var userDeepgramVoiceAgentThinkModel = "gpt-4o-mini"
    @AppStorage(AppBundleConfiguration.userVoiceResponseCaptionsEnabledDefaultsKey) private var voiceResponseCaptionsEnabled = false
    @AppStorage(AppBundleConfiguration.userVoiceResponseCaptionFontDefaultsKey) private var voiceResponseCaptionFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userVoiceResponseCaptionOpacityDefaultsKey) private var voiceResponseCaptionOpacity = AppBundleConfiguration.defaultVoiceResponseCaptionOpacity
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppTitleFontSizeDefaultsKey) private var appTitleFontSize = 26.0
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0
    @AppStorage(AppBundleConfiguration.userAppLineSpacingDefaultsKey) private var appLineSpacing = 2.0
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @AppStorage(AppBundleConfiguration.openClickyVoicePlaybackVolumeDefaultsKey) private var openClickyVoicePlaybackVolume = AppBundleConfiguration.voicePlaybackVolume()
    @AppStorage(AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey) private var userCodexAgentAPIKey = ""
    @AppStorage(AppBundleConfiguration.userAssemblyAIAPIKeyDefaultsKey) private var userAssemblyAIAPIKey = ""
    @AppStorage(AppBundleConfiguration.userDeepgramAPIKeyDefaultsKey) private var userDeepgramAPIKey = ""
    @AppStorage(AppBundleConfiguration.userMCPDeveloperDocsEnabledDefaultsKey) private var mcpDeveloperDocsEnabled = false
    @AppStorage(AppBundleConfiguration.userMCPComputerUseEnabledDefaultsKey) private var mcpComputerUseEnabled = false
    @AppStorage(AppBundleConfiguration.userMCPCuaDriverCommandDefaultsKey) private var mcpCuaDriverCommand = CuaDriverMCPConfiguration.resolvedCommandPath() ?? ""
    @AppStorage(AppBundleConfiguration.userWidgetsEnabledDefaultsKey) private var widgetsEnabled = false
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeAgentTaskNamesDefaultsKey) private var widgetsIncludeAgentTaskNames = false
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeMemorySnippetsDefaultsKey) private var widgetsIncludeMemorySnippets = false
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeFocusedAppContextDefaultsKey) private var widgetsIncludeFocusedAppContext = false
    @AppStorage(AppBundleConfiguration.userGlassOpacityDefaultsKey) private var glassOpacity = 0.75
    @AppStorage(AppBundleConfiguration.userGlassFrostingDefaultsKey) private var glassFrosting = 0.20
    @AppStorage(AppBundleConfiguration.userThemeDefaultsKey) private var clickyTheme = ClickyTheme.system.rawValue
    @State private var selectedSection: OpenClickySettingsSection = .general
    @State private var gogCLIStatus = OpenClickyGogCLIStatus.unknown
    @State private var isRefreshingGogCLIStatus = false
    @State private var codexConfigSyncMessage = "MCP servers are written into Codex config.toml for new Agent Mode sessions."
    private static let openAIRealtimeVoiceIDs = [
        "marin", "cedar", "alloy", "ash", "ballad",
        "coral", "echo", "sage", "shimmer", "verse"
    ]

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.session = companionManager.codexAgentSession
        self.nativeComputerUseController = companionManager.nativeComputerUseController
        self.backgroundComputerUseController = companionManager.backgroundComputerUseController
    }

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(appFontRawValue)
    }

    private var titleFontSize: CGFloat { CGFloat(appTitleFontSize) }
    private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
    private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }
    private var appTextLineSpacing: CGFloat { CGFloat(appLineSpacing) }

    private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
    }

    private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        if appBoldTextEnabled {
            switch weight {
            case .light, .regular:
                return .medium
            case .medium:
                return .semibold
            case .semibold:
                return .bold
            case .bold, .heavy, .black:
                return .black
            default:
                return weight
            }
        } else {
            switch weight {
            case .black, .heavy:
                return .semibold
            case .bold:
                return .medium
            case .semibold:
                return .medium
            case .medium:
                return .regular
            case .regular:
                return .regular
            default:
                return weight
            }
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 0) {
                sidebar

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionHeader
                        selectedPanel
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.03))
            }
        }
        .frame(minWidth: 1040, minHeight: 660)
        .font(appUIFont(size: bodyFontSize, weight: .regular))
        .lineSpacing(appTextLineSpacing)
        .background(Color.clear)
        .onChange(of: selectedSection) { _, newSection in
            if newSection == .connections, !gogCLIStatus.isInstalled, !isRefreshingGogCLIStatus {
                refreshGogCLIStatus()
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OpenClicky")
                .font(appUIFont(size: bodyFontSize + 5, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ForEach(OpenClickySettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImageName)
                            .font(appUIFont(size: bodyFontSize + 1, weight: .medium))
                            .frame(width: 20)
                        Text(section.title)
                            .font(appUIFont(size: bodyFontSize, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(selectedSection == section ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedSection == section ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .frame(width: 190)
        .glassEffect(
            .regular.tint(DS.Colors.accent.opacity(0.06)),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .padding(8)
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedSection.title)
                .font(appUIFont(size: titleFontSize, weight: .semibold))
            Text(sectionSubtitle)
                .font(appUIFont(size: bodyFontSize, weight: .regular))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectionSubtitle: String {
        switch selectedSection {
        case .general:
            return "Core behavior, cursor appearance, and everyday companion controls."
        case .voice:
            return "Speech input, spoken response model, playback voice, and captions."
        case .apiKeys:
            return "Provider credentials and default model settings for OpenAI, Anthropic, ElevenLabs, Cartesia, and Deepgram."
        case .computerUse:
            return "In-app Native Computer Use, pointing models, and cuaDriver configuration."
        case .permissions:
            return "macOS access permissions for voice, screen content, pointing, and system automation."
        case .agents:
            return "Specialist agents with their own soul, memory, instructions, and inherited or custom skills and tools."
        case .automations:
            return "Scheduled prompts and workflows. Interval (every N minutes) or 5-field cron, optionally bound to a specialist agent."
        case .connections:
            return "Google Workspace, persistent memory folders, logs, widgets, and utilities."
        }
    }

    private var liquidGlassPreview: some View {
        ZStack {
            LinearGradient(
                colors: [
                    DS.Colors.accent.opacity(0.34),
                    Color.white.opacity(0.16 + glassFrosting * 0.18),
                    Color.black.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blur(radius: 0.4 + glassFrosting * 2.4)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill((DS.Colors.isDarkMode ? Color.black : Color.white).opacity(glassOpacity * 0.18))

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10 + glassFrosting * 0.30), lineWidth: 1)

            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(appUIFont(size: bodyFontSize + 3, weight: .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live glass preview")
                        .font(appUIFont(size: bodyFontSize, weight: .semibold))
                    Text("Opacity and frosting update immediately here and on OpenClicky panels.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(14)
        }
        .frame(height: 78)
        .glassEffect(
            .regular.tint(DS.Colors.accent.opacity(0.04 + glassOpacity * 0.04 + glassFrosting * 0.10)),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var selectedPanel: some View {
        switch selectedSection {
        case .general:
            generalPanel
        case .voice:
            voicePanel
        case .apiKeys:
            apiKeysPanel
        case .computerUse:
            computerUsePanel
        case .permissions:
            permissionsPanel
        case .agents:
            agentsPanel
        case .automations:
            automationsPanel
        case .connections:
            connectionsPanel
        }
    }

    private var generalPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Companion") {
                toggleRow(
                    title: "Show OpenClicky cursor",
                    subtitle: "Keeps the cursor companion visible and ready for push-to-talk.",
                    systemImageName: "cursorarrow",
                    isOn: Binding(
                        get: { companionManager.isClickyCursorEnabled },
                        set: { companionManager.setClickyCursorEnabled($0) }
                    )
                )

                toggleRow(
                    title: "Tutor mode",
                    subtitle: "Watches for short pauses and offers small next-step guidance.",
                    systemImageName: "graduationcap",
                    isOn: Binding(
                        get: { companionManager.isTutorModeEnabled },
                        set: { companionManager.setTutorModeEnabled($0) }
                    )
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 14))
                            .foregroundColor(DS.Colors.accentText)
                            .frame(width: 20, alignment: .center)
                        
                        Text("Appearance theme")
                            .font(appUIFont(size: bodyFontSize, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                        
                        Spacer()
                        
                        Picker("", selection: $clickyTheme) {
                            ForEach(ClickyTheme.allCases) { theme in
                                Text(theme.title).tag(theme.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    Text("Choose between light glass, dark glass, or match system appearance.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.leading, 28)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                editableFieldRow(
                    title: "Glass tint strength",
                    subtitle: "Adjusts the native Liquid Glass tint without fading the system refraction layer.",
                    systemImageName: "eyedropper"
                ) {
                    HStack(spacing: 10) {
                        Slider(value: $glassOpacity, in: 0.1...1.0, step: 0.05)
                        Text("\(Int((glassOpacity * 100).rounded()))%")
                            .font(appUIFont(size: subtextFontSize, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                editableFieldRow(
                    title: "Glass frosting",
                    subtitle: "Adjusts the native Liquid Glass tint intensity used by OpenClicky glass surfaces.",
                    systemImageName: "sparkles"
                ) {
                    HStack(spacing: 10) {
                        Slider(value: $glassFrosting, in: 0.0...1.0, step: 0.05)
                        Text("\(Int((glassFrosting * 100).rounded()))%")
                            .font(appUIFont(size: subtextFontSize, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                liquidGlassPreview
            }

            settingsGroup("Typography") {
                Picker("App font", selection: $appFontRawValue) {
                    ForEach(OpenClickyResponseCaptionFont.allCases) { appFont in
                        Text(appFont.label).tag(appFont.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                toggleRow(
                    title: "Bold interface text",
                    subtitle: "Makes normal OpenClicky labels and messages use a stronger weight.",
                    systemImageName: "bold",
                    isOn: $appBoldTextEnabled
                )
            }

            settingsGroup("Cursor appearance") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pick OpenClicky’s cursor buddy and accent color. Pets ignore the color tint, but the accent still drives glows, buttons, and task badges.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        cursorAvatarButton(.triangleFilled, label: "Triangle")
                        cursorAvatarButton(.triangleOutline, label: "Outline")
                        ForEach(petLibrary.pets) { pet in
                            cursorPetButton(pet)
                        }
                        if petLibrary.pets.isEmpty {
                            emptyPetLibraryTile
                        }
                    }

                    Divider()
                        .opacity(0.45)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach([ClickyAccentTheme.rose, .blue, .amber, .mint, .white]) { accentTheme in
                            cursorColorButton(accentTheme)
                        }
                    }

                    Divider()
                        .opacity(0.45)

                    openPetsCatalogSection
                }
            }
        }
    }

    private var voicePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            voiceRouteOverview

            settingsGroup("Response voice model") {
                Text("Pick Realtime when one model should listen and speak live, or use a normal model when OpenClicky should think first and hand the reply to a playback engine.")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                modelOptionGrid(
                    options: OpenClickyModelCatalog.responseVoiceModels,
                    selectedModelID: companionManager.selectedModel,
                    columns: 3,
                    select: { companionManager.setSelectedModel($0) }
                )

                if OpenClickyModelCatalog.voiceResponseModel(withID: companionManager.selectedModel).provider == .openAI,
                   OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel) {
                    Picker("Realtime voice", selection: Binding(
                        get: {
                            userOpenAIRealtimeVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "marin"
                                : userOpenAIRealtimeVoiceID
                        },
                        set: {
                            userOpenAIRealtimeVoiceID = $0
                            companionManager.setOpenAIRealtimeVoiceID($0)
                        }
                    )) {
                        ForEach(Self.openAIRealtimeVoiceIDs, id: \.self) { voiceID in
                            Text(voiceID.capitalized).tag(voiceID)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }

                if OpenClickyModelCatalog.voiceResponseModel(withID: companionManager.selectedModel).provider == .deepgram {
                    Text("Deepgram Voice Agent uses one WebSocket for listening, thinking, and speaking; it reuses the Deepgram key under API Keys.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    textFieldRow(
                        title: "Deepgram voice",
                        subtitle: "Aura model identifier for the speak stage.",
                        systemImageName: "person.wave.2",
                        placeholder: "aura-2-thalia-en",
                        text: Binding(
                            get: { userDeepgramTTSVoice },
                            set: { userDeepgramTTSVoice = $0; companionManager.setDeepgramTTSVoice($0) }
                        )
                    )
                    textFieldRow(
                        title: "Deepgram think model",
                        subtitle: "LLM model Deepgram should use inside the Voice Agent.",
                        systemImageName: "brain.head.profile",
                        placeholder: "gpt-4o-mini",
                        text: Binding(
                            get: { userDeepgramVoiceAgentThinkModel },
                            set: { userDeepgramVoiceAgentThinkModel = $0; companionManager.setDeepgramVoiceAgentThinkModel($0) }
                        )
                    )
                }
            }

            settingsGroup("Listening / transcription") {
                if OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel) {
                    valueRow(
                        title: "Current input path",
                        subtitle: "GPT Realtime is selected, so OpenClicky streams microphone audio directly to Realtime instead of using Whisper or another speech-to-text provider.",
                        systemImageName: "waveform.badge.mic"
                    )
                }

                valueRow(
                    title: "Current provider",
                    subtitle: OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel)
                        ? "Bypassed while GPT Realtime is the response voice model"
                        : companionManager.buddyDictationManager.transcriptionProviderDisplayName,
                    systemImageName: "waveform"
                )

                if let transcriptionError = companionManager.buddyDictationManager.lastErrorMessage,
                   !transcriptionError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    warningRow(
                        title: "Transcription error",
                        subtitle: transcriptionError
                    )
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(BuddyTranscriptionProviderID.allCases) { provider in
                        optionButton(
                            title: provider.label,
                            subtitle: provider.subtitle,
                            isSelected: companionManager.buddyDictationManager.transcriptionProviderID == provider.rawValue,
                            action: { companionManager.setVoiceTranscriptionProvider(provider.rawValue) }
                        )
                    }
                }
            }

            settingsGroup("Response captions") {
                toggleRow(
                    title: "Caption every spoken response",
                    subtitle: "Shows OpenClicky's spoken reply beside the cursor while voice playback runs.",
                    systemImageName: "captions.bubble",
                    isOn: $voiceResponseCaptionsEnabled
                )

                Picker("Caption font", selection: $voiceResponseCaptionFontRawValue) {
                    ForEach(OpenClickyResponseCaptionFont.allCases) { captionFont in
                        Text(captionFont.label).tag(captionFont.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                LazyVGrid(columns: settingsOptionColumns(3), spacing: 8) {
                    ForEach(OpenClickyResponseCaptionFont.allCases) { captionFont in
                        optionButton(
                            title: captionFont.label,
                            subtitle: captionFont.subtitle,
                            isSelected: voiceResponseCaptionFontRawValue == captionFont.rawValue,
                            action: { voiceResponseCaptionFontRawValue = captionFont.rawValue }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 11)

                HStack(spacing: 12) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Caption bubble opacity")
                            .font(appUIFont(size: bodyFontSize, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("\(Int(voiceResponseCaptionOpacity * 100))%")
                            .font(appUIFont(size: subtextFontSize, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $voiceResponseCaptionOpacity, in: 0.55...1.0, step: 0.05)
                        .frame(maxWidth: 180)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 11)

                actionRow(title: "Test caption playback", systemImageName: "play.circle") {
                    companionManager.testVoiceResponseCaptionPlayback()
                }
            }

            settingsGroup("Speculative pre-fire") {
                toggleRow(
                    title: "Pre-fire on stable speech",
                    subtitle: "Starts the AI response while you're still talking when a partial is stable, no screen reference, and looks like a question. Saves up to 1s of TTFT but costs ~1.5–2× input tokens per turn for cancelled fires. Off by default.",
                    systemImageName: "bolt.horizontal",
                    isOn: Binding(
                        get: { companionManager.speculativePreFireEnabled },
                        set: { companionManager.setSpeculativePreFireEnabled($0) }
                    )
                )
            }

            settingsGroup("Playback") {
                Text(OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel)
                    ? "GPT Realtime is selected as the response voice model, so it owns playback for voice replies."
                    : "Choose the separate TTS provider used when a normal text model generates OpenClicky's reply.")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel) {
                    Picker("Playback engine", selection: Binding(
                        get: { companionManager.selectedTTSProvider },
                        set: { companionManager.setTTSProvider($0) }
                    )) {
                        ForEach(OpenClickyTTSProvider.allCases.filter { $0 != .openAIRealtime }) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 4)
                }

                editableFieldRow(
                    title: "OpenClicky volume",
                    subtitle: "Controls spoken reply playback without changing macOS system volume.",
                    systemImageName: "speaker.wave.2"
                ) {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { openClickyVoicePlaybackVolume },
                                set: { openClickyVoicePlaybackVolume = min(max($0, 0.0), 1.0) }
                            ),
                            in: 0...1
                        )
                        Text("\(Int((openClickyVoicePlaybackVolume * 100).rounded()))%")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                switch companionManager.selectedTTSProvider {
                case .openAIRealtime:
                    EmptyView()
                case .elevenLabs:
                    textFieldRow(
                        title: "ElevenLabs voice ID",
                        subtitle: "Optional custom voice override.",
                        systemImageName: "person.wave.2",
                        placeholder: "Voice ID",
                        text: Binding(
                            get: { userElevenLabsVoiceID },
                            set: { userElevenLabsVoiceID = $0; companionManager.setElevenLabsVoiceID($0) }
                        )
                    )
                case .cartesia:
                    textFieldRow(
                        title: "Cartesia voice ID",
                        subtitle: "Optional custom voice override.",
                        systemImageName: "person.wave.2",
                        placeholder: "Voice ID",
                        text: Binding(
                            get: { userCartesiaVoiceID },
                            set: { userCartesiaVoiceID = $0; companionManager.setCartesiaVoiceID($0) }
                        )
                    )
                case .deepgram:
                    Text("Deepgram TTS reuses the Deepgram API key set under API Keys.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    textFieldRow(
                        title: "Deepgram TTS voice",
                        subtitle: "Aura model identifier — e.g. aura-2-thalia-en, aura-2-orion-en, aura-2-luna-en.",
                        systemImageName: "person.wave.2",
                        placeholder: "aura-2-thalia-en",
                        text: Binding(
                            get: { userDeepgramTTSVoice },
                            set: { userDeepgramTTSVoice = $0; companionManager.setDeepgramTTSVoice($0) }
                        )
                    )
                case .microsoftEdge:
                    Text("Microsoft Edge voices are the free online Read Aloud voices and do not need an API key.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                        ForEach(MicrosoftEdgeVoiceOption.recommended) { voice in
                            optionButton(
                                title: voice.label,
                                subtitle: voice.subtitle,
                                isSelected: AppBundleConfiguration.microsoftEdgeVoiceID() == voice.id,
                                action: {
                                    userMicrosoftEdgeVoiceID = voice.id
                                    companionManager.setMicrosoftEdgeVoiceID(voice.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 4)

                    textFieldRow(
                        title: "Microsoft Edge voice ID",
                        subtitle: "Optional override for any Edge voice, e.g. en-US-AriaNeural.",
                        systemImageName: "person.wave.2",
                        placeholder: "en-US-EmmaMultilingualNeural",
                        text: Binding(
                            get: { userMicrosoftEdgeVoiceID },
                            set: { userMicrosoftEdgeVoiceID = $0; companionManager.setMicrosoftEdgeVoiceID($0) }
                        )
                    )
                }
            }
        }
    }

    private var voiceRouteOverview: some View {
        settingsGroup("Voice route") {
            LazyVGrid(columns: settingsOptionColumns(3), spacing: 8) {
                voiceRouteStep(
                    title: "Listen",
                    value: OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel)
                        ? "Realtime audio"
                        : companionManager.buddyDictationManager.transcriptionProviderDisplayName,
                    systemImageName: "mic"
                )
                voiceRouteStep(
                    title: "Think",
                    value: selectedResponseVoiceModelLabel,
                    systemImageName: "brain.head.profile"
                )
                voiceRouteStep(
                    title: "Speak",
                    value: OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel)
                        ? "Realtime voice"
                        : companionManager.selectedTTSProvider.displayName,
                    systemImageName: "speaker.wave.2"
                )
            }
            .padding(14)
        }
    }

    private var selectedResponseVoiceModelLabel: String {
        OpenClickyModelCatalog.responseVoiceModels.first { $0.id == companionManager.selectedModel }?.label
            ?? companionManager.selectedModel
    }

    private var apiKeysPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("OpenAI and Claude") {
                secureFieldRow(
                    title: "Codex/OpenAI API key",
                    subtitle: "Used for Agent Mode overrides and GPT Realtime voice when a key is needed.",
                    systemImageName: "key",
                    placeholder: "OpenAI key",
                    text: Binding(
                        get: { userCodexAgentAPIKey },
                        set: { userCodexAgentAPIKey = $0; companionManager.setCodexAgentAPIKey($0) }
                    )
                )

                secureFieldRow(
                    title: "Anthropic API key",
                    subtitle: "Optional key for Claude voice and pointing providers.",
                    systemImageName: "key",
                    placeholder: "Anthropic key",
                    text: Binding(
                        get: { userAnthropicAPIKey },
                        set: { userAnthropicAPIKey = $0; companionManager.setAnthropicAPIKey($0) }
                    )
                )
            }

            settingsGroup("Listening providers") {
                secureFieldRow(
                    title: "AssemblyAI listening key",
                    subtitle: "Used by the AssemblyAI streaming transcription provider.",
                    systemImageName: "key",
                    placeholder: "AssemblyAI key",
                    text: Binding(
                        get: { userAssemblyAIAPIKey },
                        set: { userAssemblyAIAPIKey = $0; companionManager.setAssemblyAIAPIKey($0) }
                    )
                )

                secureFieldRow(
                    title: "Deepgram listening key",
                    subtitle: "Used by Deepgram streaming transcription, Aura TTS, and Deepgram Voice Agent.",
                    systemImageName: "key",
                    placeholder: "Deepgram key",
                    text: Binding(
                        get: { userDeepgramAPIKey },
                        set: { userDeepgramAPIKey = $0; companionManager.setDeepgramAPIKey($0) }
                    )
                )
            }

            settingsGroup("Playback providers") {
                secureFieldRow(
                    title: "ElevenLabs API key",
                    subtitle: "Used for spoken OpenClicky replies when ElevenLabs is selected.",
                    systemImageName: "key",
                    placeholder: "ElevenLabs key",
                    text: Binding(
                        get: { userElevenLabsAPIKey },
                        set: { userElevenLabsAPIKey = $0; companionManager.setElevenLabsAPIKey($0) }
                    )
                )

                secureFieldRow(
                    title: "Cartesia API key",
                    subtitle: "Used for spoken OpenClicky replies when Cartesia is selected.",
                    systemImageName: "key",
                    placeholder: "Cartesia key",
                    text: Binding(
                        get: { userCartesiaAPIKey },
                        set: { userCartesiaAPIKey = $0; companionManager.setCartesiaAPIKey($0) }
                    )
                )
            }

            settingsGroup("Agent Mode Model") {
                modelOptionGrid(
                    options: OpenClickyModelCatalog.codexActionsModels,
                    selectedModelID: session.model,
                    select: { session.setModel($0) }
                )

                textFieldRow(
                    title: "Working directory",
                    subtitle: "Default folder used by new agent turns.",
                    systemImageName: "folder",
                    placeholder: FileManager.default.homeDirectoryForCurrentUser.path,
                    text: Binding(
                        get: { session.workingDirectoryPath },
                        set: { newValue in
                            session.workingDirectoryPath = newValue
                            UserDefaults.standard.set(newValue, forKey: "clickyCodexWorkingDirectory")
                        }
                    ),
                    openPath: { session.workingDirectoryPath }
                )
            }

            settingsGroup("Agent dock position") {
                AgentParkingPositionPicker(
                    selection: Binding(
                        get: { companionManager.agentParkingPosition },
                        set: { companionManager.setAgentParkingPosition($0) }
                    ),
                    calibrationChanged: { position, offset in
                        companionManager.setAgentParkingCalibrationOffset(offset, for: position)
                    }
                )
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
            }

            if companionManager.isAdvancedModeEnabled {
                settingsGroup("Agent tools") {
                    actionRow(title: "Warm up Agent Mode", systemImageName: "bolt") {
                        companionManager.warmUpCodexAgentMode()
                    }
                }

                #if DEBUG
                settingsGroup("Developer tools") {
                    actionRow(title: "Open Agent HUD", systemImageName: "message") {
                        companionManager.showDeveloperCodexHUD()
                    }
                    actionRow(title: "Test cursor flight", systemImageName: "arrow.up.right") {
                        companionManager.debugTestCursorFlight()
                    }
                    actionRow(title: "Show response card", systemImageName: "text.bubble") {
                        companionManager.debugShowResponseCard()
                    }
                    actionRow(title: "Capture screen context", systemImageName: "camera") {
                        companionManager.debugCaptureAgentScreenContext()
                    }
                    actionRow(title: "Reset transient UI", systemImageName: "xmark.circle", role: .destructive) {
                        companionManager.debugResetTransientUI()
                    }
                }
                #endif
            }
        }
    }

    private var permissionsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Core permissions") {
                permissionRow(
                    title: "Accessibility",
                    isGranted: companionManager.hasAccessibilityPermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
                permissionRow(
                    title: "Screen Recording",
                    isGranted: companionManager.hasScreenRecordingPermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                )
                permissionRow(
                    title: "Screen Content",
                    isGranted: companionManager.hasScreenContentPermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                )
                permissionRow(
                    title: "Microphone",
                    isGranted: companionManager.hasMicrophonePermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                )
                permissionRow(
                    title: "Full Disk Access",
                    isGranted: companionManager.hasFullDiskAccessPermission,
                    settingsURL: OpenClickyMacPrivacyPermissionProbe.fullDiskAccessSettingsURL
                )
            }

            settingsGroup("Actions") {
                actionRow(title: "Refresh permission status", systemImageName: "checklist") {
                    companionManager.refreshAllPermissions()
                }
                actionRow(title: "Open Accessibility settings", systemImageName: "hand.raised") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                actionRow(title: "Open Screen Recording settings", systemImageName: "rectangle.on.rectangle") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                actionRow(title: "Open Microphone settings", systemImageName: "mic") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                actionRow(title: "Open Full Disk Access settings", systemImageName: "externaldrive.badge.checkmark") {
                    companionManager.openFullDiskAccessSettings()
                }
            }
        }
    }

    private var computerUsePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Screen pointing model") {
                modelOptionGrid(
                    options: OpenClickyModelCatalog.computerUseModels,
                    selectedModelID: companionManager.selectedComputerUseModel,
                    select: { companionManager.setSelectedComputerUseModel($0) }
                )
            }

            settingsGroup("Computer use backend") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(OpenClickyComputerUseBackendID.allCases) { backend in
                        optionButton(
                            title: backend.label,
                            subtitle: backend.subtitle,
                            isSelected: companionManager.selectedComputerUseBackendID == backend.rawValue,
                            action: { companionManager.setSelectedComputerUseBackend(backend.rawValue) }
                        )
                    }
                }
                .padding(14)
            }

            settingsGroup("Native CUA Swift") {
                toggleRow(
                    title: "Enable in-app computer use",
                    subtitle: "Uses OpenClicky's own signed app permissions for focused-window context and targeted keyboard actions.",
                    systemImageName: "macwindow.and.cursorarrow",
                    isOn: Binding(
                        get: { nativeComputerUseController.isEnabled },
                        set: { companionManager.setNativeComputerUseEnabled($0) }
                    )
                )

                valueRow(
                    title: "Runtime status",
                    subtitle: nativeComputerUseController.status.summary,
                    systemImageName: nativeComputerUseController.status.isReadyForComputerUse ? "checkmark.circle" : "exclamationmark.triangle"
                )

                valueRow(
                    title: "Focused target",
                    subtitle: nativeComputerUseController.status.focusedTargetSummary,
                    systemImageName: "scope"
                )
            }

            if companionManager.isAdvancedModeEnabled {
                settingsGroup("Experimental Background Computer Use") {
                    valueRow(
                        title: "Experimental runtime",
                        subtitle: "Dev-only external runtime. Native CUA is the supported OpenClicky path.",
                        systemImageName: "exclamationmark.triangle"
                    )
                    valueRow(
                        title: "Runtime status",
                        subtitle: backgroundComputerUseController.status.summary,
                        systemImageName: backgroundComputerUseController.status.isRuntimeReady ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    valueRow(
                        title: "Manifest",
                        subtitle: backgroundComputerUseController.status.manifestPath,
                        systemImageName: "doc.text.magnifyingglass"
                    )
                    actionRow(title: "Start Experimental Background Computer Use", systemImageName: "play.circle") {
                        companionManager.startBackgroundComputerUseRuntime()
                    }
                    actionRow(title: "Refresh experimental status", systemImageName: "arrow.clockwise") {
                        companionManager.refreshBackgroundComputerUseStatus()
                    }
                }
            }

            settingsGroup("Actions") {
                actionRow(title: "Refresh focused target", systemImageName: "arrow.clockwise") {
                    companionManager.refreshNativeComputerUseFocusedTarget()
                }
                actionRow(title: "Refresh permission status", systemImageName: "checklist") {
                    companionManager.refreshNativeComputerUseStatus()
                }
                actionRow(title: "Open Accessibility settings", systemImageName: "hand.raised") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                actionRow(title: "Open Screen Recording settings", systemImageName: "rectangle.on.rectangle") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }

            settingsGroup("Automation access") {
                valueRow(
                    title: "Automation",
                    subtitle: "macOS grants Automation per target app when OpenClicky first sends an Apple Event.",
                    systemImageName: "terminal"
                )
            }
        }
    }

    private var connectionsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Google Workspace") {
                googleConnectionHeader

                valueRow(
                    title: "gogcli",
                    subtitle: gogCLIStatus.isInstalled
                        ? "\(gogCLIStatus.version ?? "Installed") — \(gogCLIStatus.executablePath ?? "gog")"
                        : "Not installed. Install with Homebrew: brew install gogcli",
                    systemImageName: gogCLIStatus.isInstalled ? "checkmark.circle" : "exclamationmark.triangle"
                )

                valueRow(
                    title: "OAuth credentials",
                    subtitle: gogCLIStatus.credentialsExist
                        ? "Desktop OAuth client is stored locally in gogcli."
                        : "Add a Google Cloud Desktop OAuth client JSON with gog auth credentials.",
                    systemImageName: gogCLIStatus.credentialsExist ? "checkmark.seal" : "key"
                )

                valueRow(
                    title: "Account",
                    subtitle: gogCLIStatus.accountEmail ?? "No default Google account authorized yet.",
                    systemImageName: gogCLIStatus.isReadyForUserAccount ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark"
                )

                valueRow(
                    title: "Storage",
                    subtitle: gogCLIStatus.configPath ?? "gogcli manages its own local config and keyring.",
                    systemImageName: "externaldrive.badge.person.crop",
                    openPath: gogCLIStatus.configPath
                )
            }

            settingsGroup("MCP servers") {
                toggleRow(
                    title: "OpenAI developer docs",
                    subtitle: "Optional. Adds official OpenAI docs to new agents, but can slow agent startup.",
                    systemImageName: "book.pages",
                    isOn: Binding(
                        get: { mcpDeveloperDocsEnabled },
                        set: { newValue in
                            mcpDeveloperDocsEnabled = newValue
                            syncCodexMCPSettings()
                        }
                    )
                )

                toggleRow(
                    title: "OpenClicky computer-use MCP",
                    subtitle: "Optional. Exposes the local cuaDriver bridge to new agents when installed.",
                    systemImageName: "cursorarrow.motionlines",
                    isOn: Binding(
                        get: { mcpComputerUseEnabled },
                        set: { newValue in
                            mcpComputerUseEnabled = newValue
                            syncCodexMCPSettings()
                        }
                    )
                )

                textFieldRow(
                    title: "cuaDriver command",
                    subtitle: mcpCuaDriverStatusText,
                    systemImageName: "terminal",
                    placeholder: CuaDriverMCPConfiguration.resolvedCommandPath() ?? "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
                    text: Binding(
                        get: { mcpCuaDriverCommand },
                        set: { newValue in
                            mcpCuaDriverCommand = newValue
                            syncCodexMCPSettings()
                        }
                    ),
                    openPath: { mcpCuaDriverEffectiveCommand }
                )

                valueRow(
                    title: "Codex config",
                    subtitle: companionManager.codexHomeManager.codexHomeDirectory.appendingPathComponent("config.toml", isDirectory: false).path,
                    systemImageName: "doc.text",
                    openPath: companionManager.codexHomeManager.codexHomeDirectory.appendingPathComponent("config.toml", isDirectory: false).path
                )

                valueRow(
                    title: "Sync status",
                    subtitle: codexConfigSyncMessage,
                    systemImageName: "checkmark.circle"
                )
            }

            settingsGroup("Workspace Actions") {
                actionRow(title: isRefreshingGogCLIStatus ? "Refresh Google status…" : "Refresh Google status", systemImageName: "arrow.clockwise") {
                    refreshGogCLIStatus()
                }
                actionRow(title: "Sync MCP config", systemImageName: "arrow.clockwise") {
                    syncCodexMCPSettings()
                }
                if !gogCLIStatus.isInstalled || !gogCLIStatus.credentialsExist {
                    actionRow(title: "Copy Google setup commands", systemImageName: "doc.on.doc") {
                        copyGoogleWorkspaceSetupCommands()
                    }
                }
            }

            settingsGroup("Persistent memory") {
                valueRow(
                    title: "Memory file",
                    subtitle: companionManager.codexHomeManager.persistentMemoryFile.path,
                    systemImageName: "doc.text",
                    openPath: companionManager.codexHomeManager.persistentMemoryFile.path
                )
                valueRow(
                    title: "Learned skills",
                    subtitle: companionManager.codexHomeManager.learnedSkillsDirectory.path,
                    systemImageName: "wand.and.stars",
                    openPath: companionManager.codexHomeManager.learnedSkillsDirectory.path
                )
                valueRow(
                    title: "Knowledge index",
                    subtitle: "\(companionManager.bundledKnowledgeIndex.articles.count) articles, \(companionManager.bundledKnowledgeIndex.skills.count) skills",
                    systemImageName: "books.vertical"
                )
            }

            settingsGroup("Memory tools") {
                actionRow(title: "Open memory browser", systemImageName: "books.vertical") {
                    companionManager.showMemoryWindow()
                }
                actionRow(title: "Open memory file", systemImageName: "doc.text") {
                    companionManager.openOpenClickyDocument(companionManager.codexHomeManager.persistentMemoryFile)
                }
                actionRow(title: "Open memory archive folder", systemImageName: "archivebox") {
                    NSWorkspace.shared.open(companionManager.codexHomeManager.persistentMemoryArchivesDirectory)
                }
                actionRow(title: "Open learned skills folder", systemImageName: "folder") {
                    NSWorkspace.shared.open(companionManager.codexHomeManager.learnedSkillsDirectory)
                }
            }

            settingsGroup("Widgets") {
                toggleRow(
                    title: "Enable desktop widgets",
                    subtitle: "Publishes a compact OpenClicky snapshot for WidgetKit.",
                    systemImageName: "rectangle.grid.1x2",
                    isOn: Binding(
                        get: { widgetsEnabled },
                        set: { newValue in
                            widgetsEnabled = newValue
                            companionManager.publishWidgetSnapshot()
                        }
                    )
                )
                toggleRow(
                    title: "Show agent task names",
                    subtitle: "Allows widgets to display task titles and short captions.",
                    systemImageName: "text.alignleft",
                    isOn: Binding(
                        get: { widgetsIncludeAgentTaskNames },
                        set: { newValue in
                            widgetsIncludeAgentTaskNames = newValue
                            companionManager.publishWidgetSnapshot()
                        }
                    )
                )
                toggleRow(
                    title: "Show memory snippets",
                    subtitle: "Allows widgets to show a compact recent memory summary.",
                    systemImageName: "brain.head.profile",
                    isOn: Binding(
                        get: { widgetsIncludeMemorySnippets },
                        set: { newValue in
                            widgetsIncludeMemorySnippets = newValue
                            companionManager.publishWidgetSnapshot()
                        }
                    )
                )
                toggleRow(
                    title: "Show focused-app context",
                    subtitle: "Reserved for future focus widgets. Keep off unless you want desktop context shown.",
                    systemImageName: "macwindow",
                    isOn: Binding(
                        get: { widgetsIncludeFocusedAppContext },
                        set: { newValue in
                            widgetsIncludeFocusedAppContext = newValue
                            companionManager.publishWidgetSnapshot()
                        }
                    )
                )
                actionRow(title: "Open widget snapshot", systemImageName: "doc.text.magnifyingglass") {
                    companionManager.publishWidgetSnapshot()
                    NSWorkspace.shared.open(OpenClickyWidgetStateStore.snapshotURL)
                }
            }

            settingsGroup("Logs") {
                valueRow(
                    title: "Message log",
                    subtitle: OpenClickyMessageLogStore.shared.currentLogFile.path,
                    systemImageName: "doc.text.magnifyingglass",
                    openPath: OpenClickyMessageLogStore.shared.currentLogFile.path
                )
                actionRow(title: "Open log viewer", systemImageName: "list.bullet.rectangle") {
                    companionManager.showLogViewerWindow()
                }
                actionRow(title: "Open raw message log", systemImageName: "doc.text") {
                    openMessageLog()
                }
                actionRow(title: "Open logs folder", systemImageName: "folder") {
                    openLogsFolder()
                }
            }

            settingsGroup("Onboarding") {
                actionRow(title: "Show OpenClicky cursor now", systemImageName: "cursorarrow.rays") {
                    companionManager.triggerOnboarding()
                }
                actionRow(title: "Replay onboarding cleanup", systemImageName: "play.circle") {
                    companionManager.replayOnboarding()
                }
            }

            settingsGroup("Support") {
                actionRow(title: "Report issues and star on GitHub", systemImageName: "star.bubble") {
                    openFeedbackInbox()
                }
            }

            settingsGroup("App") {
                actionRow(title: "Quit OpenClicky", systemImageName: "power", role: .destructive) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private var googleConnectionHeader: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        Circle()
                            .stroke(
                                AngularGradient(
                                    colors: [.blue, .red, .yellow, .green, .blue],
                                    center: .center
                                ),
                                lineWidth: 3
                            )
                    )
                Text("G")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(gogCLIStatus.readinessTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text(gogCLIStatus.readinessDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var agentsPanel: some View {
        OpenClickyAgentsSettingsSection(companion: companionManager)
    }

    private var automationsPanel: some View {
        OpenClickyAutomationsSettingsSection(companion: companionManager)
    }

    private var mcpCuaDriverEffectiveCommand: String {
        let trimmed = mcpCuaDriverCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return CuaDriverMCPConfiguration.resolvedCommandPath() ?? ""
    }

    private var mcpCuaDriverStatusText: String {
        guard mcpComputerUseEnabled else {
            return "Disabled. Turn this on to expose OpenClicky's computer-use path to Agent Mode."
        }

        let command = mcpCuaDriverEffectiveCommand
        guard !command.isEmpty else {
            return "No cuaDriver command found. Install cuaDriver or paste the command path."
        }

        if FileManager.default.fileExists(atPath: normalizedSettingsPath(command)) {
            return "Ready: \(command)"
        }

        return "Command will be written to config.toml, but the path was not found yet."
    }

    private func syncCodexMCPSettings() {
        do {
            let configFile = try companionManager.codexHomeManager.writeCodexConfigFromSettings()
            codexConfigSyncMessage = "Synced MCP settings to \(configFile.path). Restart active agents to pick up changes."
        } catch {
            codexConfigSyncMessage = "Could not sync MCP settings: \(error.localizedDescription)"
        }
    }

    private func refreshGogCLIStatus() {
        guard !isRefreshingGogCLIStatus else { return }
        isRefreshingGogCLIStatus = true
        Task {
            let status = await OpenClickyGogCLIStatusResolver.refresh()
            gogCLIStatus = status
            isRefreshingGogCLIStatus = false
        }
    }

    private func copyGoogleWorkspaceSetupCommands() {
        let commands = """
        # Install gogcli if needed
        brew install gogcli

        # Store a Google Cloud Desktop OAuth client JSON locally in gogcli
        gog auth credentials ~/Downloads/client_secret_....json

        # Authorize least-privilege scopes for common agent reads
        gog auth add you@example.com --services gmail,drive --gmail-scope readonly --drive-scope readonly
        gog auth add you@example.com --services calendar,tasks --readonly

        # Optional Workspace alias
        gog auth alias set work you@example.com
        gog auth status --json
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands, forType: .string)
    }

    private func openURL(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSettingsPath(_ rawPath: String) {
        let path = normalizedSettingsPath(rawPath)
        guard !path.isEmpty else { return }

        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.open(url)
            return
        }

        openSettingsFile(url)
    }

    private func normalizedSettingsPath(_ rawPath: String) -> String {
        let path = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\ ", with: " ")
            .replacingOccurrences(of: "file://", with: "")

        return (path as NSString).expandingTildeInPath
    }

    private func openSettingsFile(_ url: URL) {
        if ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()) {
            companionManager.openOpenClickyDocument(url)
            return
        }

        let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        guard FileManager.default.fileExists(atPath: textEditURL.path) else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: textEditURL, configuration: configuration) { _, error in
            if error != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(appUIFont(size: bodyFontSize, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.025))
            )
            .glassEffect(
                .regular.tint(DS.Colors.accent.opacity(0.035)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func fontSizeSliderRow(
        title: String,
        subtitle: String,
        systemImageName: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String = " pt"
    ) -> some View {
        editableFieldRow(title: title, subtitle: subtitle, systemImageName: systemImageName) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: 1)
                Text("\(Int(value.wrappedValue.rounded()))\(suffix)")
                    .font(appUIFont(size: subtextFontSize, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    private func settingsOptionColumns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private func voiceRouteStep(title: String, value: String, systemImageName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: systemImageName)
                    .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 16)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(0.6)
            }

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
    }

    private func toggleRow(title: String, subtitle: String, systemImageName: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(subtitle).font(appUIFont(size: subtextFontSize, weight: .regular)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func valueRow(title: String, subtitle: String, systemImageName: String, openPath: String? = nil) -> some View {
        HStack(spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(subtitle)
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            if let openPath, !openPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settingsPathOpenButton(openPath)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func warningRow(title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon("exclamationmark.triangle")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(subtitle)
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func textFieldRow(
        title: String,
        subtitle: String,
        systemImageName: String,
        placeholder: String,
        text: Binding<String>,
        openPath: (() -> String)? = nil
    ) -> some View {
        editableFieldRow(title: title, subtitle: subtitle, systemImageName: systemImageName) {
            HStack(spacing: 8) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .regular))
                if let openPath {
                    settingsPathOpenButton(openPath())
                }
            }
        }
    }

    private func secureFieldRow(title: String, subtitle: String, systemImageName: String, placeholder: String, text: Binding<String>) -> some View {
        editableFieldRow(title: title, subtitle: subtitle, systemImageName: systemImageName) {
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .regular))
        }
    }

    private func editableFieldRow<Field: View>(
        title: String,
        subtitle: String,
        systemImageName: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(subtitle).font(appUIFont(size: subtextFontSize, weight: .regular)).foregroundColor(.secondary)
                field()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func actionRow(title: String, systemImageName: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                rowIcon(systemImageName)
                Text(title)
                    .font(appUIFont(size: bodyFontSize, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsPathOpenButton(_ rawPath: String) -> some View {
        Button {
            openSettingsPath(rawPath)
        } label: {
            Image(systemName: settingsPathOpenIconName(for: rawPath))
                .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(settingsPathOpenHelpText(for: rawPath))
        .accessibilityLabel(settingsPathOpenHelpText(for: rawPath))
    }

    private func settingsPathOpenIconName(for rawPath: String) -> String {
        var isDirectory: ObjCBool = false
        let path = normalizedSettingsPath(rawPath)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "folder"
        }
        if ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return "doc.richtext"
        }
        return "square.and.pencil"
    }

    private func settingsPathOpenHelpText(for rawPath: String) -> String {
        var isDirectory: ObjCBool = false
        let path = normalizedSettingsPath(rawPath)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "Open folder"
        }
        if ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return "Open in OpenClicky Markdown viewer"
        }
        return "Open in TextEdit"
    }

    private func permissionRow(title: String, isGranted: Bool, settingsURL: URL) -> some View {
        HStack(spacing: 12) {
            rowIcon(isGranted ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundColor(isGranted ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(isGranted ? "Granted" : "Needs permission")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(settingsURL)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func modelOptionGrid(
        options: [OpenClickyModelOption],
        selectedModelID: String,
        columns: Int = 2,
        select: @escaping (String) -> Void
    ) -> some View {
        LazyVGrid(columns: settingsOptionColumns(columns), spacing: 8) {
            ForEach(options) { option in
                optionButton(
                    title: option.label,
                    subtitle: option.provider.displayName,
                    isSelected: selectedModelID == option.id,
                    action: { select(option.id) }
                )
            }
        }
        .padding(14)
    }

    private func optionButton(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(appUIFont(size: max(9, subtextFontSize - 1), weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }


    private var currentCursorAvatarStyle: ClickyCursorAvatarStyle {
        ClickyCursorAvatarStyle(storageValue: avatarStyleRawValue)
    }

    private func cursorColorButton(_ accentTheme: ClickyAccentTheme) -> some View {
        let isSelected = selectedAccentThemeID == accentTheme.rawValue
        return Button {
            selectedAccentThemeID = accentTheme.rawValue
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(accentTheme.cursorColor.opacity(0.15))
                    Triangle()
                        .fill(accentTheme.cursorColor)
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(-25))
                }
                .frame(width: 46, height: 46)

                Text(accentTheme.title)
                    .font(appUIFont(size: max(10, subtextFontSize), weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? accentTheme.cursorColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? accentTheme.cursorColor.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }


    private func cursorAvatarButton(_ style: ClickyCursorAvatarStyle, label: String) -> some View {
        let isSelected = currentCursorAvatarStyle == style
        let accent = (ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor

        return Button {
            avatarStyleRawValue = style.storageValue
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? accent.opacity(0.16) : Color.primary.opacity(0.045))
                        .frame(width: 46, height: 46)

                    switch style {
                    case .triangleFilled:
                        Triangle()
                            .fill(accent)
                            .frame(width: 19, height: 19)
                            .rotationEffect(.degrees(-25))
                            .shadow(color: accent.opacity(0.55), radius: 7)
                    case .triangleOutline:
                        Triangle()
                            .stroke(accent, lineWidth: 2.2)
                            .frame(width: 19, height: 19)
                            .rotationEffect(.degrees(-25))
                    case .pet:
                        EmptyView()
                    }
                }

                Text(label)
                    .font(appUIFont(size: max(10, subtextFontSize), weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func cursorPetButton(_ pet: ClickyBuddyPet) -> some View {
        let style = ClickyCursorAvatarStyle.pet(id: pet.id)
        let isSelected = currentCursorAvatarStyle == style
        let accent = (ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor

        return Button {
            avatarStyleRawValue = style.storageValue
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? accent.opacity(0.16) : Color.primary.opacity(0.045))
                        .frame(width: 46, height: 46)
                    ClickyPetThumbnailView(pet: pet)
                        .frame(width: 34, height: 36)
                }

                Text(pet.displayName)
                    .font(appUIFont(size: max(10, subtextFontSize), weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(pet.petDescription)
    }

    private var openPetsCatalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("OpenPets gallery")
                        .font(appUIFont(size: bodyFontSize, weight: .semibold))
                    Text("Browse installable pets from openpets.dev. Installed packs land in the same local pet library OpenClicky already watches.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button(openPetsCatalog.isLoading ? "Loading…" : "Refresh") {
                    openPetsCatalog.refreshCatalog()
                }
                .disabled(openPetsCatalog.isLoading)
                .controlSize(.small)
            }

            TextField("Search loaded OpenPets", text: $openPetsCatalog.searchText)
                .textFieldStyle(.roundedBorder)
                .font(appUIFont(size: bodyFontSize, weight: .regular))

            if let error = openPetsCatalog.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(openPetsCatalog.visiblePets) { pet in
                    openPetsCatalogCard(pet)
                }
            }

            HStack {
                let loaded = max(openPetsCatalog.pets.count, openPetsCatalog.visiblePets.count)
                Text(openPetsCatalog.totalCount > 0 ? "\(loaded) of \(openPetsCatalog.totalCount) OpenPets loaded" : "OpenPets catalog")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)

                Spacer()

                if openPetsCatalog.loadedPageCount < openPetsCatalog.pageCount {
                    Button(openPetsCatalog.isLoading ? "Loading…" : "Load more") {
                        openPetsCatalog.loadMore()
                    }
                    .disabled(openPetsCatalog.isLoading)
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            openPetsCatalog.loadInitialCatalogIfNeeded()
        }
    }

    private func openPetsCatalogCard(_ pet: OpenPetsCatalogPet) -> some View {
        let isInstalled = petLibrary.pet(withID: pet.id) != nil
        let isInstalling = openPetsCatalog.installingPetIDs.contains(pet.id)
        let accent = (ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor

        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .frame(height: 76)

                if let url = pet.previewURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                        case .failure:
                            Image(systemName: "pawprint")
                                .foregroundColor(.secondary)
                        case .empty:
                            ProgressView()
                                .controlSize(.small)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(width: 58, height: 62)
                } else {
                    Image(systemName: "pawprint")
                        .foregroundColor(.secondary)
                }
            }

            Text(pet.displayName)
                .font(appUIFont(size: max(10, subtextFontSize), weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(pet.description)
                .font(appUIFont(size: max(9, subtextFontSize - 1), weight: .regular))
                .foregroundColor(.secondary)
                .lineLimit(2)

            Button {
                if isInstalled {
                    avatarStyleRawValue = ClickyCursorAvatarStyle.pet(id: pet.id).storageValue
                } else {
                    openPetsCatalog.install(pet, into: petLibrary)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                    Text(isInstalled ? "Use" : isInstalling ? "Installing…" : "Install")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isInstalled ? accent : DS.Colors.accent)
            .controlSize(.small)
            .disabled(isInstalling)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .help(pet.description)
    }

    private var emptyPetLibraryTile: some View {
        VStack(spacing: 7) {
            Image(systemName: "pawprint")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.secondary)
            Text("No pets")
                .font(appUIFont(size: max(10, subtextFontSize), weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private func rowIcon(_ systemImageName: String) -> some View {
        Image(systemName: systemImageName)
            .font(appUIFont(size: bodyFontSize + 1, weight: .medium))
    }

    private func openFeedbackInbox() {
        guard let url = URL(string: "https://github.com/jasonkneen/openclicky/issues") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openMessageLog() {
        OpenClickyMessageLogStore.shared.append(
            lane: "app",
            direction: "internal",
            event: "settings.open_message_log"
        )
        NSWorkspace.shared.open(OpenClickyMessageLogStore.shared.currentLogFile)
    }

    private func openLogsFolder() {
        OpenClickyMessageLogStore.shared.append(
            lane: "app",
            direction: "internal",
            event: "settings.open_logs_folder"
        )
        NSWorkspace.shared.open(OpenClickyMessageLogStore.shared.logDirectory)
    }
}

// MARK: - AgentParkingPositionPicker

/// A screen-shaped preview with eight tappable anchor points. Tapping
/// any dot selects that parking position and updates the binding.
struct AgentParkingPositionPicker: View {
    @Binding var selection: AgentParkingPosition
    var calibrationChanged: (AgentParkingPosition, CGSize) -> Void = { _, _ in }
    @State private var activeDragPosition: AgentParkingPosition?
    @State private var dragPreviewOffsets: [AgentParkingPosition: CGSize] = [:]

    private let dotSize: CGFloat = 18
    private let hitTargetSize: CGFloat = 36
    private let outlineColor = Color.secondary.opacity(0.55)
    private let selectedColor = Color.accentColor
    private let coordinateSpaceName = "AgentParkingPositionPreview"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where agents park")
                .font(.headline)

            Text("Pick where the agent dock parks, or drag a dot to fine-tune the corner.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                let frame = previewRect(in: proxy.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(outlineColor, lineWidth: 1.5)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    Rectangle()
                        .fill(outlineColor.opacity(0.25))
                        .frame(width: frame.width, height: 6)
                        .position(x: frame.midX, y: frame.minY + 3)

                    ForEach(AgentParkingPosition.allCases) { position in
                        let dotPosition = absolutePoint(for: position, in: frame)
                        Button {
                            selection = position
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.primary.opacity(0.001))
                                    .frame(width: hitTargetSize, height: hitTargetSize)

                                Circle()
                                    .fill(position == selection ? selectedColor : Color.clear)
                                    .overlay(
                                        Circle().stroke(
                                            position == selection ? selectedColor : outlineColor,
                                            lineWidth: position == selection ? 0 : 1.5
                                        )
                                    )
                                    .frame(width: dotSize, height: dotSize)

                                if position == selection || position == activeDragPosition {
                                    ParkingCornerDragIndicator(
                                        tint: position == activeDragPosition ? selectedColor : outlineColor.opacity(0.82),
                                        isActive: position == activeDragPosition
                                    )
                                }
                            }
                            .frame(width: hitTargetSize, height: hitTargetSize)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(position.label)
                        .position(x: dotPosition.x, y: dotPosition.y)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpaceName))
                                .onChanged { value in
                                    let clampedLocation = CGPoint(
                                        x: min(max(value.location.x, frame.minX), frame.maxX),
                                        y: min(max(value.location.y, frame.minY), frame.maxY)
                                    )
                                    let basePoint = baseAbsolutePoint(for: position, in: frame)
                                    let previewOffset = CGSize(
                                        width: clampedLocation.x - basePoint.x,
                                        height: clampedLocation.y - basePoint.y
                                    )
                                    selection = position
                                    activeDragPosition = position
                                    dragPreviewOffsets[position] = previewOffset
                                    calibrationChanged(
                                        position,
                                        screenOffset(from: previewOffset, previewFrame: frame)
                                    )
                                }
                                .onEnded { _ in
                                    activeDragPosition = nil
                                }
                        )
                    }
                }
                .coordinateSpace(name: coordinateSpaceName)
            }
            .frame(height: 176)
            .padding(.vertical, 6)

            Text(activeDragPosition == selection ? "\(selection.label) — drag to correct placement" : selection.label)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    private var mainScreenAspectRatio: CGFloat {
        guard let frame = NSScreen.main?.frame, frame.width > 0, frame.height > 0 else {
            return 16.0 / 10.0
        }
        return frame.width / frame.height
    }

    private func previewRect(in size: CGSize) -> CGRect {
        let availableHeight = size.height
        let availableWidth = size.width
        let aspectRatio = mainScreenAspectRatio
        let widthFromHeight = availableHeight * aspectRatio
        let heightFromWidth = availableWidth / aspectRatio
        let width: CGFloat
        let height: CGFloat
        if widthFromHeight <= availableWidth {
            width = widthFromHeight
            height = availableHeight
        } else {
            width = availableWidth
            height = heightFromWidth
        }
        let originX = (availableWidth - width) / 2
        let originY = (availableHeight - height) / 2
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func absolutePoint(for position: AgentParkingPosition, in frame: CGRect) -> CGPoint {
        let basePoint = baseAbsolutePoint(for: position, in: frame)
        let previewOffset = dragPreviewOffsets[position]
            ?? previewOffset(from: AgentParkingPosition.calibrationOffset(for: position), previewFrame: frame)
        return CGPoint(
            x: min(max(basePoint.x + previewOffset.width, frame.minX), frame.maxX),
            y: min(max(basePoint.y + previewOffset.height, frame.minY), frame.maxY)
        )
    }

    private func baseAbsolutePoint(for position: AgentParkingPosition, in frame: CGRect) -> CGPoint {
        let anchor = position.normalizedAnchor
        return CGPoint(
            x: frame.minX + anchor.x * frame.width,
            y: frame.minY + anchor.y * frame.height
        )
    }

    private func previewOffset(from screenOffset: CGSize, previewFrame frame: CGRect) -> CGSize {
        CGSize(
            width: screenOffset.width * frame.width / max(mainScreenSize.width, 1),
            height: -screenOffset.height * frame.height / max(mainScreenSize.height, 1)
        )
    }

    private func screenOffset(from previewOffset: CGSize, previewFrame frame: CGRect) -> CGSize {
        CGSize(
            width: previewOffset.width / max(frame.width, 1) * mainScreenSize.width,
            height: -previewOffset.height / max(frame.height, 1) * mainScreenSize.height
        )
    }

    private var mainScreenSize: CGSize {
        guard let frame = NSScreen.main?.frame, frame.width > 0, frame.height > 0 else {
            return CGSize(width: 1600, height: 1000)
        }
        return frame.size
    }
}

private struct ParkingCornerDragIndicator: View {
    let tint: Color
    let isActive: Bool

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                ParkingCornerBracket()
                    .stroke(tint, style: StrokeStyle(lineWidth: isActive ? 2.2 : 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(Double(index) * 90))
                    .offset(x: index == 0 || index == 3 ? -13 : 13, y: index < 2 ? -13 : 13)
            }
        }
        .frame(width: 44, height: 44)
        .opacity(isActive ? 1 : 0.72)
    }
}

private struct ParkingCornerBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}
