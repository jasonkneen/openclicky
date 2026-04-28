import AppKit
import SwiftUI

@MainActor
final class OpenClickySettingsWindowManager {
    private var window: NSWindow?
    private let windowSize = NSSize(width: 860, height: 580)
    private let minimumWindowSize = NSSize(width: 760, height: 500)

    func show(companionManager: CompanionManager) {
        if window == nil {
            createWindow(companionManager: companionManager)
        } else if let hostingView = window?.contentView as? NSHostingView<OpenClickySettingsView> {
            hostingView.rootView = OpenClickySettingsView(companionManager: companionManager)
        }

        guard let settingsWindow = window else { return }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.center()
        settingsWindow.orderFrontRegardless()
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.makeMain()
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
        settingsWindow.collectionBehavior.insert(.moveToActiveSpace)
        settingsWindow.center()

        let hostingView = NSHostingView(rootView: OpenClickySettingsView(companionManager: companionManager))
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]
        settingsWindow.contentView = hostingView

        window = settingsWindow
    }
}

private enum OpenClickySettingsSection: String, CaseIterable, Identifiable {
    case general
    case voice
    case pointing
    case computerUse
    case agentMode
    case memory
    case app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .voice: return "Voice"
        case .pointing: return "Pointing"
        case .computerUse: return "Computer Use"
        case .agentMode: return "Agent Mode"
        case .memory: return "Memory"
        case .app: return "App"
        }
    }

    var systemImageName: String {
        switch self {
        case .general: return "gearshape"
        case .voice: return "waveform"
        case .pointing: return "cursorarrow.rays"
        case .computerUse: return "macwindow.and.cursorarrow"
        case .agentMode: return "terminal"
        case .memory: return "books.vertical"
        case .app: return "app.badge"
        }
    }
}

struct OpenClickySettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var session: CodexAgentSession
    @ObservedObject private var nativeComputerUseController: OpenClickyNativeComputerUseController
    @ObservedObject private var backgroundComputerUseController: OpenClickyBackgroundComputerUseController
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    // API keys live in the Keychain via `ClickyAPIKeyStore`. The store
    // publishes its values so SecureField bindings re-render whenever a
    // setter on `companionManager` writes a new value.
    @ObservedObject private var apiKeyStore: ClickyAPIKeyStore = .shared
    @AppStorage(AppBundleConfiguration.userDeepgramTTSVoiceDefaultsKey) private var userDeepgramTTSVoice = "aura-2-thalia-en"
    @AppStorage(AppBundleConfiguration.userWidgetsEnabledDefaultsKey) private var widgetsEnabled = false
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeAgentTaskNamesDefaultsKey) private var widgetsIncludeAgentTaskNames = false
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeMemorySnippetsDefaultsKey) private var widgetsIncludeMemorySnippets = false
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeFocusedAppContextDefaultsKey) private var widgetsIncludeFocusedAppContext = false
    @State private var selectedSection: OpenClickySettingsSection = .general

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.session = companionManager.codexAgentSession
        self.nativeComputerUseController = companionManager.nativeComputerUseController
        self.backgroundComputerUseController = companionManager.backgroundComputerUseController
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionHeader
                    selectedPanel
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 500)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OpenClicky")
                .font(.system(size: 18, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ForEach(OpenClickySettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImageName)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20)
                        Text(section.title)
                            .font(.system(size: 13, weight: .medium))
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
        .background(.regularMaterial)
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedSection.title)
                .font(.system(size: 26, weight: .semibold))
            Text(sectionSubtitle)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectionSubtitle: String {
        switch selectedSection {
        case .general:
            return "Core behavior, cursor appearance, and everyday companion controls."
        case .voice:
            return "Speech input, spoken response model, playback voice, and provider keys."
        case .pointing:
            return "Screen capture permissions and the model used for cursor pointing."
        case .computerUse:
            return "Choose the computer-use backend for focused-window context and targeted actions."
        case .agentMode:
            return "Background agents, Codex configuration, model, working directory, and dashboard access."
        case .memory:
            return "Persistent memory, learned workflow skills, and local knowledge tools."
        case .app:
            return "Onboarding, support, and app-level actions."
        }
    }

    @ViewBuilder
    private var selectedPanel: some View {
        switch selectedSection {
        case .general:
            generalPanel
        case .voice:
            voicePanel
        case .pointing:
            pointingPanel
        case .computerUse:
            computerUsePanel
        case .agentMode:
            agentModePanel
        case .memory:
            memoryPanel
        case .app:
            appPanel
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

                toggleRow(
                    title: "Advanced mode",
                    subtitle: "Shows Agent Mode dashboard controls, inline agent input, model controls, and memory tools.",
                    systemImageName: "slider.horizontal.3",
                    isOn: Binding(
                        get: { companionManager.isAdvancedModeEnabled },
                        set: { companionManager.setAdvancedModeEnabled($0) }
                    )
                )
            }

            settingsGroup("Cursor color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach([ClickyAccentTheme.rose, .blue, .amber, .mint]) { accentTheme in
                        cursorColorButton(accentTheme)
                    }
                }
            }
        }
    }

    private var voicePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Voice response model") {
                modelOptionGrid(
                    options: OpenClickyModelCatalog.voiceResponseModels,
                    selectedModelID: companionManager.selectedModel,
                    select: { companionManager.setSelectedModel($0) }
                )
            }

            settingsGroup("Transcription") {
                valueRow(
                    title: "Current provider",
                    subtitle: companionManager.buddyDictationManager.transcriptionProviderDisplayName,
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

                secureFieldRow(
                    title: "AssemblyAI API key",
                    subtitle: "Used by the AssemblyAI streaming transcription provider.",
                    systemImageName: "key",
                    placeholder: "AssemblyAI key",
                    text: Binding(
                        get: { apiKeyStore.assemblyAIAPIKey },
                        set: { companionManager.setAssemblyAIAPIKey($0) }
                    )
                )

                secureFieldRow(
                    title: "Deepgram API key",
                    subtitle: "Used by the Deepgram streaming transcription provider.",
                    systemImageName: "key",
                    placeholder: "Deepgram key",
                    text: Binding(
                        get: { apiKeyStore.deepgramAPIKey },
                        set: { companionManager.setDeepgramAPIKey($0) }
                    )
                )
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
                Picker("TTS provider", selection: Binding(
                    get: { companionManager.selectedTTSProvider },
                    set: { companionManager.setTTSProvider($0) }
                )) {
                    ForEach(OpenClickyTTSProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 4)

                switch companionManager.selectedTTSProvider {
                case .elevenLabs:
                    secureFieldRow(
                        title: "ElevenLabs API key",
                        subtitle: "Used for spoken OpenClicky replies.",
                        systemImageName: "speaker.wave.2",
                        placeholder: "ElevenLabs key",
                        text: Binding(
                            get: { apiKeyStore.elevenLabsAPIKey },
                            set: { companionManager.setElevenLabsAPIKey($0) }
                        )
                    )
                    textFieldRow(
                        title: "ElevenLabs voice ID",
                        subtitle: "Optional custom voice override.",
                        systemImageName: "person.wave.2",
                        placeholder: "Voice ID",
                        text: Binding(
                            get: { apiKeyStore.elevenLabsVoiceID },
                            set: { companionManager.setElevenLabsVoiceID($0) }
                        )
                    )
                case .cartesia:
                    secureFieldRow(
                        title: "Cartesia API key",
                        subtitle: "Used for spoken OpenClicky replies.",
                        systemImageName: "speaker.wave.2",
                        placeholder: "Cartesia key",
                        text: Binding(
                            get: { apiKeyStore.cartesiaAPIKey },
                            set: { companionManager.setCartesiaAPIKey($0) }
                        )
                    )
                    textFieldRow(
                        title: "Cartesia voice ID",
                        subtitle: "Optional custom voice override.",
                        systemImageName: "person.wave.2",
                        placeholder: "Voice ID",
                        text: Binding(
                            get: { apiKeyStore.cartesiaVoiceID },
                            set: { companionManager.setCartesiaVoiceID($0) }
                        )
                    )
                case .deepgram:
                    Text("Deepgram TTS reuses the Deepgram API key set under Transcription.")
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
                }
            }
        }
    }

    private var pointingPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Screen pointing model") {
                modelOptionGrid(
                    options: OpenClickyModelCatalog.computerUseModels,
                    selectedModelID: companionManager.selectedComputerUseModel,
                    select: { companionManager.setSelectedComputerUseModel($0) }
                )
            }

            settingsGroup("Permissions") {
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
            }
        }
    }

    private var computerUsePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            settingsGroup("Additional macOS access") {
                permissionRow(
                    title: "Full Disk Access",
                    isGranted: companionManager.hasFullDiskAccessPermission,
                    settingsURL: OpenClickyMacPrivacyPermissionProbe.fullDiskAccessSettingsURL
                )
                valueRow(
                    title: "Automation",
                    subtitle: "macOS grants Automation per target app. OpenClicky can trigger the prompt for an app the first time it sends an Apple Event.",
                    systemImageName: "terminal"
                )
                actionRow(title: "Open Automation settings", systemImageName: "slider.horizontal.3") {
                    companionManager.openAutomationSettings()
                }
                actionRow(title: "Prime Reminders automation prompt", systemImageName: "checklist") {
                    companionManager.requestRemindersAutomationPermission()
                }
            }

            settingsGroup("Agent Mode behavior") {
                valueRow(
                    title: "Screen context source",
                    subtitle: companionManager.selectedComputerUseBackend == .backgroundComputerUse
                        ? "Agent Mode first asks Background Computer Use for the focused window screenshot, then falls back if unavailable."
                        : nativeComputerUseController.isEnabled
                            ? "Agent Mode first captures the focused target window through the native CUA Swift path, then falls back if unavailable."
                            : "Agent Mode uses the existing all-screen capture path until native computer use is enabled.",
                    systemImageName: "photo.on.rectangle"
                )
                valueRow(
                    title: "Selected backend",
                    subtitle: companionManager.selectedComputerUseBackend.label,
                    systemImageName: "switch.2"
                )
                valueRow(
                    title: "Existing CUA Driver MCP",
                    subtitle: CuaDriverMCPConfiguration.resolvedCommandPath()
                        ?? "Not installed locally. OpenClicky will auto-register upstream Cua Driver MCP when /Applications/CuaDriver.app or cua-driver is available.",
                    systemImageName: "point.3.connected.trianglepath.dotted"
                )
                valueRow(
                    title: "Bundled implementation",
                    subtitle: "Embedded Swift adapted from CUA Driver's MIT app/window discovery, ScreenCaptureKit, and pid-keyboard patterns — no external MCP server required.",
                    systemImageName: "shippingbox"
                )
            }
        }
    }

    private var agentModePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Agent Mode") {
                toggleRow(
                    title: "Advanced mode",
                    subtitle: "Keeps the dashboard and agent controls available.",
                    systemImageName: "slider.horizontal.3",
                    isOn: Binding(
                        get: { companionManager.isAdvancedModeEnabled },
                        set: { companionManager.setAdvancedModeEnabled($0) }
                    )
                )

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
                    )
                )
            }

            settingsGroup("Agent dock position") {
                AgentParkingPositionPicker(
                    selection: Binding(
                        get: { companionManager.agentParkingPosition },
                        set: { companionManager.setAgentParkingPosition($0) }
                    )
                )
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }

            settingsGroup("Agent authentication") {
                secureFieldRow(
                    title: "Codex/OpenAI API key",
                    subtitle: "Optional override. Leave blank to use local Codex ChatGPT sign-in where available.",
                    systemImageName: "terminal",
                    placeholder: "OpenAI key",
                    text: Binding(
                        get: { apiKeyStore.openAIAPIKey },
                        set: { companionManager.setCodexAgentAPIKey($0) }
                    )
                )

                secureFieldRow(
                    title: "Anthropic API key",
                    subtitle: "Optional key for Claude voice and pointing providers.",
                    systemImageName: "key",
                    placeholder: "Anthropic key",
                    text: Binding(
                        get: { apiKeyStore.anthropicAPIKey },
                        set: { companionManager.setAnthropicAPIKey($0) }
                    )
                )
            }

            if companionManager.isAdvancedModeEnabled {
                settingsGroup("Agent tools") {
                    actionRow(title: "Open Agent dashboard", systemImageName: "rectangle.grid.2x2") {
                        companionManager.showCodexHUD()
                    }
                    actionRow(title: "Warm up Agent Mode", systemImageName: "bolt") {
                        companionManager.warmUpCodexAgentMode()
                    }
                }
            }
        }
    }

    private var memoryPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Persistent memory") {
                valueRow(
                    title: "Memory file",
                    subtitle: companionManager.codexHomeManager.persistentMemoryFile.path,
                    systemImageName: "doc.text"
                )
                valueRow(
                    title: "Learned skills",
                    subtitle: companionManager.codexHomeManager.learnedSkillsDirectory.path,
                    systemImageName: "wand.and.stars"
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
                    NSWorkspace.shared.open(companionManager.codexHomeManager.persistentMemoryFile)
                }
                actionRow(title: "Open memory archive folder", systemImageName: "archivebox") {
                    NSWorkspace.shared.open(companionManager.codexHomeManager.persistentMemoryArchivesDirectory)
                }
                actionRow(title: "Open learned skills folder", systemImageName: "folder") {
                    NSWorkspace.shared.open(companionManager.codexHomeManager.learnedSkillsDirectory)
                }
            }
        }
    }

    private var appPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Support") {
                actionRow(title: "Report issues and star on GitHub", systemImageName: "star.bubble") {
                    openFeedbackInbox()
                }
            }

            settingsGroup("Logs") {
                valueRow(
                    title: "Message log",
                    subtitle: OpenClickyMessageLogStore.shared.currentLogFile.path,
                    systemImageName: "doc.text.magnifyingglass"
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

            settingsGroup("Onboarding") {
                actionRow(title: "Show OpenClicky cursor now", systemImageName: "cursorarrow.rays") {
                    companionManager.triggerOnboarding()
                }
                actionRow(title: "Replay onboarding cleanup", systemImageName: "play.circle") {
                    companionManager.replayOnboarding()
                }
            }

            settingsGroup("App") {
                actionRow(title: "Quit OpenClicky", systemImageName: "power", role: .destructive) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func toggleRow(title: String, subtitle: String, systemImageName: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func valueRow(title: String, subtitle: String, systemImageName: String) -> some View {
        HStack(spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
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
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func textFieldRow(title: String, subtitle: String, systemImageName: String, placeholder: String, text: Binding<String>) -> some View {
        editableFieldRow(title: title, subtitle: subtitle, systemImageName: systemImageName) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    private func secureFieldRow(title: String, subtitle: String, systemImageName: String, placeholder: String, text: Binding<String>) -> some View {
        editableFieldRow(title: title, subtitle: subtitle, systemImageName: systemImageName) {
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
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
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary)
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
                    .font(.system(size: 13, weight: .medium))
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

    private func permissionRow(title: String, isGranted: Bool, settingsURL: URL) -> some View {
        HStack(spacing: 12) {
            rowIcon(isGranted ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundColor(isGranted ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(isGranted ? "Granted" : "Needs permission")
                    .font(.system(size: 11))
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

    private func modelOptionGrid(options: [OpenClickyModelOption], selectedModelID: String, select: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
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
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.system(size: 10))
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
                        .rotationEffect(.degrees(-35))
                }
                .frame(width: 46, height: 46)

                Text(accentTheme.title)
                    .font(.system(size: 11, weight: .medium))
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

    private func rowIcon(_ systemImageName: String) -> some View {
        Image(systemName: systemImageName)
            .font(.system(size: 14, weight: .medium))
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

    private let aspectRatio: CGFloat = 16.0 / 10.0
    private let dotSize: CGFloat = 18
    private let outlineColor = Color.secondary.opacity(0.55)
    private let selectedColor = Color.accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where agents park")
                .font(.headline)

            Text("Pick the corner of the screen where the agent dock should appear.")
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
                            Circle()
                                .fill(position == selection ? selectedColor : Color.clear)
                                .overlay(
                                    Circle().stroke(
                                        position == selection ? selectedColor : outlineColor,
                                        lineWidth: position == selection ? 0 : 1.5
                                    )
                                )
                                .frame(width: dotSize, height: dotSize)
                        }
                        .buttonStyle(.plain)
                        .help(position.label)
                        .position(x: dotPosition.x, y: dotPosition.y)
                    }
                }
            }
            .frame(height: 160)

            Text(selection.label)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    private func previewRect(in size: CGSize) -> CGRect {
        let availableHeight = size.height
        let availableWidth = size.width
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
        let anchor = position.normalizedAnchor
        return CGPoint(
            x: frame.minX + anchor.x * frame.width,
            y: frame.minY + anchor.y * frame.height
        )
    }
}
