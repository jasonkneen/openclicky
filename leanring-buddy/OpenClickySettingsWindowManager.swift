import AppKit
import SwiftUI

@MainActor
final class OpenClickySettingsWindowManager {
    private var window: NSWindow?
    private let windowSize = NSSize(width: 900, height: 600)
    private let minimumWindowSize = NSSize(width: 780, height: 520)

    func show(companionManager: CompanionManager, initialSection: OpenClickySettingsSection = .general) {
        if window == nil {
            createWindow(companionManager: companionManager, initialSection: initialSection)
        } else if let hostingView = window?.contentView as? NSHostingView<OpenClickySettingsView> {
            hostingView.rootView = OpenClickySettingsView(companionManager: companionManager, initialSection: initialSection)
        }

        guard let settingsWindow = window else { return }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.center()
        settingsWindow.orderFrontRegardless()
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.makeMain()
    }

    private func createWindow(companionManager: CompanionManager, initialSection: OpenClickySettingsSection) {
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

        let hostingView = NSHostingView(rootView: OpenClickySettingsView(companionManager: companionManager, initialSection: initialSection))
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]
        settingsWindow.contentView = hostingView

        window = settingsWindow
    }
}

enum OpenClickySettingsSection: String, CaseIterable, Identifiable, Hashable {
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
    @AppStorage(AppBundleConfiguration.userAnthropicAPIKeyDefaultsKey) private var userAnthropicAPIKey = ""
    @AppStorage(AppBundleConfiguration.userElevenLabsAPIKeyDefaultsKey) private var userElevenLabsAPIKey = ""
    @AppStorage(AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey) private var userElevenLabsVoiceID = ""
    @AppStorage(AppBundleConfiguration.userCartesiaAPIKeyDefaultsKey) private var userCartesiaAPIKey = ""
    @AppStorage(AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey) private var userCartesiaVoiceID = ""
    @AppStorage(AppBundleConfiguration.userDeepgramTTSVoiceDefaultsKey) private var userDeepgramTTSVoice = "aura-2-thalia-en"
    @AppStorage(AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey) private var userCodexAgentAPIKey = ""
    @AppStorage(AppBundleConfiguration.userAssemblyAIAPIKeyDefaultsKey) private var userAssemblyAIAPIKey = ""
    @AppStorage(AppBundleConfiguration.userDeepgramAPIKeyDefaultsKey) private var userDeepgramAPIKey = ""
    @AppStorage(AppBundleConfiguration.userGeminiAPIKeyDefaultsKey) private var userGeminiAPIKey = ""
    @AppStorage(AppBundleConfiguration.userGeminiTTSVoiceDefaultsKey) private var userGeminiTTSVoice = "Kore"
    @AppStorage(AppBundleConfiguration.userGeminiTTSModelDefaultsKey) private var userGeminiTTSModel = "gemini-2.5-flash-preview-tts"
    @AppStorage(AppBundleConfiguration.userOpenAITTSVoiceDefaultsKey) private var userOpenAITTSVoice = "alloy"
    @AppStorage(AppBundleConfiguration.userOpenAITTSModelDefaultsKey) private var userOpenAITTSModel = "gpt-4o-mini-tts"
    @AppStorage(AppBundleConfiguration.userWidgetsEnabledDefaultsKey) private var widgetsEnabled = false
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeAgentTaskNamesDefaultsKey) private var widgetsIncludeAgentTaskNames = false
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeMemorySnippetsDefaultsKey) private var widgetsIncludeMemorySnippets = false
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeFocusedAppContextDefaultsKey) private var widgetsIncludeFocusedAppContext = false
    @AppStorage(AppBundleConfiguration.userBuddyFadeWhenIdleEnabledKey) private var buddyFadeWhenIdleEnabled = true
    @AppStorage(AppBundleConfiguration.userBuddyFadeWhenIdleSecondsKey) private var buddyFadeWhenIdleSeconds = 15.0
    @State private var selectedSection: OpenClickySettingsSection

    init(companionManager: CompanionManager, initialSection: OpenClickySettingsSection = .general) {
        self.companionManager = companionManager
        self.session = companionManager.codexAgentSession
        self.nativeComputerUseController = companionManager.nativeComputerUseController
        self.backgroundComputerUseController = companionManager.backgroundComputerUseController
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView {
            sidebarListColumn
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detailPane
                .navigationTitle("")
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    private var sidebarListColumn: some View {
        List(selection: $selectedSection) {
            Section {
                ForEach(OpenClickySettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImageName)
                        .tag(section)
                }
            } header: {
                Text("OpenClicky")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.bottom, 2)
                    .textCase(nil)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                sectionHeader
                selectedPanel
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selectedSection.title)
                .font(.largeTitle.weight(.semibold))
            Text(sectionSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .accessibilityElement(children: .combine)
        .padding(.bottom, 2)
    }

    private var sectionSubtitle: String {
        switch selectedSection {
        case .general:
            return "Core behavior, cursor appearance, and everyday companion controls."
        case .voice:
            return "Recognition, response model, text-to-speech playback, and shared API credentials."
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

                toggleRow(
                    title: "Fade buddy after inactivity",
                    subtitle: "Fades OpenClicky’s arrow when keyboard and mouse are idle — similar to the system cursor during video.",
                    systemImageName: "moon.zzz.fill",
                    isOn: Binding(
                        get: { buddyFadeWhenIdleEnabled },
                        set: { buddyFadeWhenIdleEnabled = $0 }
                    )
                )

                if buddyFadeWhenIdleEnabled {
                    HStack(spacing: 12) {
                        rowIcon("timer").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Inactive duration")
                                .font(.body.weight(.medium))
                            Text("Fade after no keyboard/mouse activity for this long.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Picker("Seconds until fade", selection: $buddyFadeWhenIdleSeconds) {
                            ForEach([5.0, 10, 15, 20, 30, 45, 60, 90, 120, 180], id: \.self) { s in
                                Text(secondsLabel(for: s)).tag(s)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .pickerStyle(.menu)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }
            }

            settingsGroup("Cursor color") {
                VStack(spacing: 0) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach([ClickyAccentTheme.rose, .blue, .amber, .mint]) { accentTheme in
                            cursorColorButton(accentTheme)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var voicePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            voiceReplySection
            transcriptionSection
            textToSpeechSection
            speculativeSection
        }
    }

    private var voiceReplySection: some View {
        settingsGroup("Voice response model") {
            VStack(spacing: 0) {
                modelOptionGrid(
                    options: OpenClickyModelCatalog.voiceResponseModels,
                    selectedModelID: companionManager.selectedModel,
                    select: { companionManager.setSelectedModel($0) }
                )
            }
            .padding(.top, 10)
        }
    }

    private var transcriptionSection: some View {
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
                    get: { userAssemblyAIAPIKey },
                    set: { userAssemblyAIAPIKey = $0; companionManager.setAssemblyAIAPIKey($0) }
                )
            )

            secureFieldRow(
                title: "Deepgram API key",
                subtitle: "Used by the Deepgram streaming transcription provider.",
                systemImageName: "key",
                placeholder: "Deepgram key",
                text: Binding(
                    get: { userDeepgramAPIKey },
                    set: { userDeepgramAPIKey = $0; companionManager.setDeepgramAPIKey($0) }
                )
            )
        }
    }

    private var textToSpeechSection: some View {
        let geminiModels = OpenClickyTTSSettingsCatalog.mergedGeminiModelRows(saved: userGeminiTTSModel)
        let geminiVoices = OpenClickyTTSSettingsCatalog.mergedGeminiVoiceRows(saved: userGeminiTTSVoice)
        let openAIVoices = OpenClickyTTSSettingsCatalog.mergedOpenAIVoiceRows(saved: userOpenAITTSVoice)
        let openAIModels = OpenClickyTTSSettingsCatalog.mergedOpenAIModelRows(saved: userOpenAITTSModel)
        let deepgramVoices = OpenClickyTTSSettingsCatalog.mergedDeepgramTTSVoiceRows(saved: userDeepgramTTSVoice)

        return settingsGroup("Text to speech") {
            Text(
                "Choose how spoken replies are synthesized. Playback reuses transcription API keys where noted (for example Deepgram)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            secureFieldRow(
                title: "OpenAI / Codex API key",
                subtitle: "Shared with Codex/OpenAI Agent Mode and with OpenAI Speech presets. Secrets.env OPENAI_API_KEY overrides when present.",
                systemImageName: "key",
                placeholder: "sk-…",
                text: Binding(
                    get: { userCodexAgentAPIKey },
                    set: { userCodexAgentAPIKey = $0; companionManager.setCodexAgentAPIKey($0) }
                )
            )

            Group {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Playback provider")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("Playback provider", selection: Binding(
                        get: { companionManager.selectedTTSProvider },
                        set: { companionManager.setTTSProvider($0) }
                    )) {
                        ForEach(OpenClickyTTSProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Playback provider")
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }

            switch companionManager.selectedTTSProvider {
            case .elevenLabs:
                secureFieldRow(
                    title: "ElevenLabs API key",
                    subtitle: "Used for spoken OpenClicky replies.",
                    systemImageName: "speaker.wave.2",
                    placeholder: "ElevenLabs key",
                    text: Binding(
                        get: { userElevenLabsAPIKey },
                        set: { userElevenLabsAPIKey = $0; companionManager.setElevenLabsAPIKey($0) }
                    )
                )
                textFieldRow(
                    title: "ElevenLabs voice ID",
                    subtitle: "Paste a voice ID from the ElevenLabs dashboard (voices are account-specific).",
                    systemImageName: "person.wave.2",
                    placeholder: "Voice ID",
                    text: Binding(
                        get: { userElevenLabsVoiceID },
                        set: { userElevenLabsVoiceID = $0; companionManager.setElevenLabsVoiceID($0) }
                    )
                )
                Text("Sentence-level Gemini fallback may retry after ElevenLabs failures when `GEMINI_API_KEY` / AI Studio keys exist or when Gemini presets are configured here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            case .cartesia:
                secureFieldRow(
                    title: "Cartesia API key",
                    subtitle: "Used for spoken OpenClicky replies.",
                    systemImageName: "speaker.wave.2",
                    placeholder: "Cartesia key",
                    text: Binding(
                        get: { userCartesiaAPIKey },
                        set: { userCartesiaAPIKey = $0; companionManager.setCartesiaAPIKey($0) }
                    )
                )
                textFieldRow(
                    title: "Cartesia voice ID",
                    subtitle: "Paste a voice UUID from Sonic or your Cartesia project (voices are account-specific).",
                    systemImageName: "person.wave.2",
                    placeholder: "Voice ID",
                    text: Binding(
                        get: { userCartesiaVoiceID },
                        set: { userCartesiaVoiceID = $0; companionManager.setCartesiaVoiceID($0) }
                    )
                )
            case .deepgram:
                Text("Deepgram TTS reuses the Deepgram API key under Transcription above.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                catalogMenuPickerRow(
                    title: "Deepgram TTS voice (Aura)",
                    subtitle: "Preset Aura identifiers; unmatched saved voices appear as Current: ….",
                    systemImageName: "person.wave.2",
                    rows: deepgramVoices,
                    selection: Binding(
                        get: { userDeepgramTTSVoice },
                        set: { userDeepgramTTSVoice = $0; companionManager.setDeepgramTTSVoice($0) }
                    )
                )
            case .gemini:
                Text(
                    "Google AI Studio / Gemini keys drive native speech (generateContent + audio). Applies to Gemini playback; you can also set GEMINI_API_KEY in secrets.env."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)

                secureFieldRow(
                    title: "Gemini API key",
                    subtitle: "From Google AI Studio (or Gemini API keys with speech generation enabled for your project).",
                    systemImageName: "key",
                    placeholder: "AI Studio API key",
                    text: Binding(
                        get: { userGeminiAPIKey },
                        set: {
                            userGeminiAPIKey = $0
                            companionManager.setGeminiAPIKey($0)
                        }
                    )
                )

                catalogMenuPickerRow(
                    title: "Gemini TTS model",
                    subtitle: "Model id used at …/models/{model}:generateContent.",
                    systemImageName: "cpu",
                    rows: geminiModels,
                    selection: Binding(
                        get: { userGeminiTTSModel },
                        set: {
                            userGeminiTTSModel = $0
                            companionManager.setGeminiTTSModel($0)
                        }
                    )
                )

                catalogMenuPickerRow(
                    title: "Gemini TTS voice",
                    subtitle: "Prebuilt Gemini voice name for speech-generation. Saved custom names appear as Current: ….",
                    systemImageName: "person.wave.2",
                    rows: geminiVoices,
                    selection: Binding(
                        get: { userGeminiTTSVoice },
                        set: {
                            userGeminiTTSVoice = $0
                            companionManager.setGeminiTTSVoice($0)
                        }
                    )
                )
            case .openAI:
                catalogMenuPickerRow(
                    title: "OpenAI TTS voice",
                    subtitle: "Speech presets (alloy, echo, fable, onyx, nova, shimmer); unknown saved IDs show as Current: ….",
                    systemImageName: "person.wave.2",
                    rows: openAIVoices,
                    selection: Binding(
                        get: { userOpenAITTSVoice },
                        set: { userOpenAITTSVoice = $0; companionManager.setOpenAITTSVoice($0) }
                    )
                )
                catalogMenuPickerRow(
                    title: "OpenAI TTS model",
                    subtitle: "Prefer gpt-4o-mini-tts; older `tts-*` tiers may be disabled per workspace.",
                    systemImageName: "cpu",
                    rows: openAIModels,
                    selection: Binding(
                        get: { userOpenAITTSModel },
                        set: { userOpenAITTSModel = $0; companionManager.setOpenAITTSModel($0) }
                    )
                )
            }

            if companionManager.selectedTTSProvider != .gemini &&
                companionManager.selectedTTSProvider != .elevenLabs {
                Text("Sentence-level Gemini fallback uses `GEMINI_API_KEY`, Google AI Studio keys inside secrets.env, or the Gemini presets when Gemini playback is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
            }
        }
    }

    private var speculativeSection: some View {
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
                valueRow(
                    title: "OpenAI / Codex API key",
                    subtitle: userCodexAgentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Not saved here. Configure Voice → Text to speech, or OPENAI_API_KEY in secrets.env, or Codex sign-in."
                        : "Configured in Voice → Text to speech (same stored key). Manage it there alongside playback.",
                    systemImageName: "terminal"
                )
                actionRow(title: "Open Voice → Text to speech", systemImageName: "arrow.turn.down.right") {
                    companionManager.showSettingsWindow(initialSection: .voice)
                }

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

    private func catalogMenuPickerRow(
        title: String,
        subtitle: String,
        systemImageName: String,
        rows: [(id: String, label: String)],
        selection: Binding<String>
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon(systemImageName).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                Picker(title, selection: selection) {
                    ForEach(rows, id: \.id) { row in
                        Text(row.label).tag(row.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
    }

    private func toggleRow(title: String, subtitle: String, systemImageName: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            rowIcon(systemImageName).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func valueRow(title: String, subtitle: String, systemImageName: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon(systemImageName).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func warningRow(title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon("exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
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
            rowIcon(systemImageName).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                field()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func actionRow(title: String, systemImageName: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                rowIcon(systemImageName).foregroundStyle(.secondary)
                Text(title)
                    .font(.body.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func permissionRow(title: String, isGranted: Bool, settingsURL: URL) -> some View {
        HStack(spacing: 12) {
            rowIcon(isGranted ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(isGranted ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(isGranted ? "Granted" : "Needs permission")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open Settings") {
                NSWorkspace.shared.open(settingsURL)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func modelOptionGrid(options: [OpenClickyModelOption], selectedModelID: String, select: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(options) { option in
                optionButton(
                    title: option.label,
                    subtitle: option.provider.displayName,
                    isSelected: selectedModelID == option.id,
                    action: { select(option.id) }
                )
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 17)
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
            .font(.body.weight(.medium))
            .frame(width: 22, alignment: .center)
    }

    private func secondsLabel(for seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        return "\(rounded) sec"
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
            Text("Tap a corner or edge. The dock parks where you choose.")
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
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
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
