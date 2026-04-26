//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CursorOverlayState: ObservableObject {
    @Published var voiceState: CompanionVoiceState = .idle
    @Published var currentAudioPowerLevel: CGFloat = 0
    @Published var detectedElementScreenLocation: CGPoint?
    @Published var detectedElementDisplayFrame: CGRect?
    @Published var detectedElementBubbleText: String?
}

enum ClickyAgentDockStatus: Equatable {
    case starting
    case running
    case done
    case failed
}

struct ClickyAgentDockItem: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID?
    var title: String
    var accentTheme: ClickyAccentTheme
    var status: ClickyAgentDockStatus
    var caption: String?
    var createdAt: Date
}

private struct OpenClickyAppOpenRequest {
    let appName: String
    let instruction: String
}

private struct OpenClickyAgentSelectionRequest {
    let agentName: String
    let followUpText: String?
    let instruction: String
}

private struct OpenClickyNativeTypeRequest {
    let text: String
    let targetDescription: String
}

private struct OpenClickyNativeKeyPressRequest {
    let key: String
    let modifiers: [String]
    let targetDescription: String
}

private struct OpenClickyFolderOpenRequest {
    let url: URL
    let displayName: String
    let instruction: String
}

private struct OpenClickyReminderAddRequest {
    let title: String
    let instruction: String
}

private struct OpenClickyReminderCountRequest {
    let instruction: String
}

private struct OpenClickyMessagesSearchRequest {
    let personName: String
    let instruction: String
}

nonisolated private struct OpenClickyLocalAutomationResult: Sendable {
    let output: String
    let errorOutput: String
    let terminationStatus: Int32
}

private struct OpenClickyRequestTiming {
    let requestID: String
    let source: String
    let text: String
    let requestedAt: Date
}

nonisolated private enum OpenClickyLocalAutomationRunner {
    static func runAppleScript(_ script: String) -> OpenClickyLocalAutomationResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-ss", "-e", script]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return OpenClickyLocalAutomationResult(
                output: "",
                errorOutput: error.localizedDescription,
                terminationStatus: -1
            )
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return OpenClickyLocalAutomationResult(
            output: output.trimmingCharacters(in: .whitespacesAndNewlines),
            errorOutput: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            terminationStatus: process.terminationStatus
        )
    }

    static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    let cursorOverlayState = CursorOverlayState()
    @Published private(set) var voiceState: CompanionVoiceState = .idle {
        didSet {
            cursorOverlayState.voiceState = voiceState
        }
    }
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0 {
        didSet {
            cursorOverlayState.currentAudioPowerLevel = currentAudioPowerLevel
        }
    }
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var hasFullDiskAccessPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint? {
        didSet {
            cursorOverlayState.detectedElementScreenLocation = detectedElementScreenLocation
        }
    }
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect? {
        didSet {
            cursorOverlayState.detectedElementDisplayFrame = detectedElementDisplayFrame
        }
    }
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String? {
        didSet {
            cursorOverlayState.detectedElementBubbleText = detectedElementBubbleText
        }
    }

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?
    private var onboardingMusicFadeStepsRemaining = 0
    private var onboardingMusicFadeVolumeDecrement: Float = 0

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let textModeWindowManager = ClickyTextModeWindowManager()
    let agentDockWindowManager = ClickyAgentDockWindowManager()
    let settingsWindowManager = OpenClickySettingsWindowManager()
    let logViewerWindowManager = OpenClickyLogViewerWindowManager()
    let widgetStateStore = OpenClickyWidgetStateStore()
    let codexHomeManager = CodexHomeManager()
    let nativeComputerUseController = OpenClickyNativeComputerUseController()
    let backgroundComputerUseController = OpenClickyBackgroundComputerUseController()
    @Published private(set) var codexAgentSessions: [CodexAgentSession]
    @Published private(set) var activeCodexAgentSessionID: UUID
    let codexHUDWindowManager = CodexHUDWindowManager()
    let wikiViewerPanelManager = WikiViewerPanelManager()
    @Published private(set) var bundledKnowledgeIndex = WikiManager.Index.empty
    @Published private(set) var latestVoiceResponseCard: ClickyResponseCard?
    @Published private(set) var handoffQueue: [HandoffQueuedRegionScreenshot] = []
    @Published private(set) var agentDockItems: [ClickyAgentDockItem] = []
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Anthropic API key for direct Claude requests.
    /// Environment fallback supports Xcode schemes and local launch scripts.
    private static let anthropicAPIKey = AppBundleConfiguration.anthropicAPIKey()
    private static let openAIAPIKey = AppBundleConfiguration.openAIAPIKey()
    private static let elevenLabsAPIKey = AppBundleConfiguration.elevenLabsAPIKey()
    private static let elevenLabsVoiceID = AppBundleConfiguration.elevenLabsVoiceID()
    private static let tutorModeDefaultsKey = "isTutorModeEnabled"

    private static func initialTutorModeEnabled() -> Bool {
        UserDefaults.standard.object(forKey: tutorModeDefaultsKey) as? Bool ?? true
    }

    private lazy var claudeAPI: ClaudeAPI = {
        let modelOption = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        return ClaudeAPI(
            apiKey: Self.anthropicAPIKey,
            model: modelOption.id,
            maxOutputTokens: modelOption.maxOutputTokens
        )
    }()

    private lazy var openAIAPI: OpenAIAPI = {
        let modelOption = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        return OpenAIAPI(
            apiKey: Self.openAIAPIKey,
            model: modelOption.id,
            maxOutputTokens: modelOption.maxOutputTokens
        )
    }()

    private lazy var claudeAgentSDKAPI: ClaudeAgentSDKAPI? = {
        let modelOption = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        return ClaudeAgentSDKAPI(model: modelOption.id, maxOutputTokens: modelOption.maxOutputTokens)
    }()

    private lazy var codexVoiceSession: CodexVoiceSession = {
        return CodexVoiceSession(model: selectedModel, homeManager: codexHomeManager)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(
            apiKey: Self.elevenLabsAPIKey,
            voiceID: Self.elevenLabsVoiceID
        )
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    private var fallbackSpeechSynthesizer: AVSpeechSynthesizer?
    private var pendingAgentVoiceFollowUpSessionID: UUID?
    private var pendingAgentVoiceFollowUpCreatedAt: Date?
    private var lastAgentContextSessionID: UUID?
    private var announcedAgentFileURLs: Set<String> = []
    private var liveHandledComputerUseFingerprints: Set<String> = []
    private var lastAgentProgressNarrationAt: Date?
    private var currentFolderContextURL: URL?
    private var activeRequestTiming: OpenClickyRequestTiming?
    private var agentRequestTimingsBySessionID: [UUID: OpenClickyRequestTiming] = [:]
    private var agentExecutionStartDatesBySessionID: [UUID: Date] = [:]

    private var shortcutTransitionCancellable: AnyCancellable?
    private var controlDoubleTapCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var agentStatusCancellables: [UUID: AnyCancellable] = [:]
    private var agentActivityCancellables: [UUID: AnyCancellable] = [:]
    private var agentTitleCancellables: [UUID: AnyCancellable] = [:]
    private var pendingAgentActivityRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var tutorIdleCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    private var voiceFollowUpStopTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    var permissionSnapshot: PermissionSnapshot {
        PermissionSnapshot(
            accessibility: hasAccessibilityPermission ? .granted : .missing,
            screenRecording: hasScreenRecordingPermission ? .granted : .missing,
            microphone: hasMicrophonePermission ? .granted : .missing,
            screenContent: hasScreenContentPermission ? .granted : .missing
        )
    }

    var permissionGuideViewState: PermissionGuideAssistant.ViewState {
        PermissionGuideAssistant.viewState(
            for: permissionSnapshot,
            entryContext: hasCompletedOnboarding ? .returningUser : .onboarding
        )
    }

    var latestResponseCard: ClickyResponseCard? {
        codexAgentSession.latestResponseCard ?? latestVoiceResponseCard
    }

    var codexAgentSession: CodexAgentSession {
        codexAgentSessions.first { $0.id == activeCodexAgentSessionID } ?? codexAgentSessions[0]
    }

    init() {
        let initialAgentSession = CodexAgentSession(title: "Agent 1", accentTheme: .blue)
        codexAgentSessions = [initialAgentSession]
        activeCodexAgentSessionID = initialAgentSession.id
        OpenClickyMessageLogStore.shared.append(
            lane: "system",
            direction: "outgoing",
            event: "openclicky.runtime.started",
            fields: [
                "nativeCUARouterVersion": "direct-cua-explicit-agent-v4",
                "agentAssignment": "explicit-only",
                "computerUseBackend": selectedComputerUseBackendID
            ]
        )
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = OpenClickyModelCatalog.voiceResponseModel(
        withID: UserDefaults.standard.string(forKey: "selectedVoiceResponseModel")
            ?? UserDefaults.standard.string(forKey: "selectedClaudeModel")
            ?? OpenClickyModelCatalog.defaultVoiceResponseModelID
    ).id
    @Published var selectedComputerUseModel: String = OpenClickyModelCatalog.computerUseModel(
        withID: UserDefaults.standard.string(forKey: "selectedComputerUseModel") ?? OpenClickyModelCatalog.defaultComputerUseModelID
    ).id
    @Published var selectedComputerUseBackendID: String = OpenClickyComputerUseBackendID.resolving(
        UserDefaults.standard.string(forKey: AppBundleConfiguration.userComputerUseBackendDefaultsKey)
    ).rawValue
    @Published var isTutorModeEnabled: Bool = CompanionManager.initialTutorModeEnabled()
    @Published var isAdvancedModeEnabled: Bool = UserDefaults.standard.bool(forKey: AppBundleConfiguration.userAdvancedModeDefaultsKey)
    private let userActivityIdleDetector = UserActivityIdleDetector()
    private var isTutorObservationInFlight = false

    func setSelectedModel(_ model: String) {
        let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: model)
        let resolvedModel = selectedVoiceResponseModel.id
        selectedModel = resolvedModel
        UserDefaults.standard.set(resolvedModel, forKey: "selectedVoiceResponseModel")
        applyVoiceResponseModelSettings(selectedVoiceResponseModel)
        switch selectedVoiceResponseModel.provider {
        case .anthropic:
            claudeAgentSDKAPI?.warmUp(systemPrompt: currentVoiceResponseSystemPrompt())
        case .openAI, .codex:
            codexVoiceSession.warmUp(systemPrompt: currentVoiceResponseSystemPrompt())
        }
    }

    func setSelectedComputerUseModel(_ model: String) {
        let resolvedModel = OpenClickyModelCatalog.computerUseModel(withID: model).id
        selectedComputerUseModel = resolvedModel
        UserDefaults.standard.set(resolvedModel, forKey: "selectedComputerUseModel")
    }

    var selectedComputerUseBackend: OpenClickyComputerUseBackendID {
        OpenClickyComputerUseBackendID.resolving(selectedComputerUseBackendID)
    }

    private func applyVoiceResponseModelSettings(_ modelOption: OpenClickyModelOption) {
        claudeAPI.model = modelOption.id
        claudeAPI.maxOutputTokens = modelOption.maxOutputTokens
        openAIAPI.model = modelOption.id
        openAIAPI.maxOutputTokens = modelOption.maxOutputTokens
        claudeAgentSDKAPI?.model = modelOption.id
        claudeAgentSDKAPI?.maxOutputTokens = modelOption.maxOutputTokens
        codexVoiceSession.model = modelOption.id
    }

    func setSelectedComputerUseBackend(_ backendID: String) {
        let backend = OpenClickyComputerUseBackendID.resolving(backendID)
        selectedComputerUseBackendID = backend.rawValue
        UserDefaults.standard.set(backend.rawValue, forKey: AppBundleConfiguration.userComputerUseBackendDefaultsKey)
        if backend == .backgroundComputerUse {
            backgroundComputerUseController.refreshStatus()
        }
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "internal",
            event: "computer_use.backend_selected",
            fields: [
                "backend": backend.rawValue,
                "executor": backend.executorID
            ]
        )
    }

    func setNativeComputerUseEnabled(_ enabled: Bool) {
        nativeComputerUseController.setEnabled(enabled)
    }

    func refreshNativeComputerUseStatus() {
        nativeComputerUseController.refreshStatus()
    }

    func refreshNativeComputerUseFocusedTarget() {
        _ = nativeComputerUseController.refreshFocusedTarget()
    }

    func refreshBackgroundComputerUseStatus() {
        backgroundComputerUseController.refreshStatus()
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "internal",
            event: "background_computer_use.status_refreshed",
            fields: [
                "status": backgroundComputerUseController.status.summary,
                "manifestPath": backgroundComputerUseController.status.manifestPath
            ]
        )
    }

    func startBackgroundComputerUseRuntime() {
        backgroundComputerUseController.startRuntime()
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "background_computer_use.start_requested",
            fields: [
                "sourceRoot": backgroundComputerUseController.status.sourceRootPath,
                "manifestPath": backgroundComputerUseController.status.manifestPath
            ]
        )
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(OpenClickyMacPrivacyPermissionProbe.fullDiskAccessSettingsURL)
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(OpenClickyMacPrivacyPermissionProbe.automationSettingsURL)
    }

    func requestRemindersAutomationPermission() {
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "native_cua.automation_probe.started",
            fields: [
                "target": "Reminders"
            ]
        )

        Task.detached(priority: .userInitiated) {
            let result = OpenClickyLocalAutomationRunner.runAppleScript("""
            tell application "Reminders"
                count reminders
            end tell
            """)

            await MainActor.run {
                if result.terminationStatus == 0 {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "outgoing",
                        event: "native_cua.automation_probe.ready",
                        fields: [
                            "target": "Reminders"
                        ]
                    )
                    self.speakShortSystemResponse("Reminders automation is ready.")
                } else {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "native_cua.automation_probe.blocked",
                        fields: [
                            "target": "Reminders",
                            "error": result.errorOutput.isEmpty ? result.output : result.errorOutput
                        ]
                    )
                    self.openAutomationSettings()
                    self.speakShortSystemResponse(Self.nativeAutomationErrorMessage(appName: "Reminders", result: result))
                }
            }
        }
    }

    func showSettingsWindow() {
        settingsWindowManager.show(companionManager: self)
    }

    func showLogViewerWindow() {
        logViewerWindowManager.show()
    }

    func publishWidgetSnapshot() {
        widgetStateStore.publishSnapshot(from: self)
    }

    func scheduleWidgetSnapshotPublish() {
        widgetStateStore.scheduleSnapshotPublish(from: self)
    }

    func handleWidgetDeepLink(_ url: URL) {
        guard url.scheme == "openclicky" else { return }

        switch url.host {
        case "agents":
            showCodexHUD()
        case "agent":
            if let sessionIDString = url.pathComponents.dropFirst().first,
               let sessionID = UUID(uuidString: sessionIDString) {
                selectCodexAgentSession(sessionID)
            }
            showCodexHUD()
        case "settings":
            showSettingsWindow()
        case "logs":
            showLogViewerWindow()
        case "memory":
            showMemoryWindow()
        default:
            showSettingsWindow()
        }
    }

    func setTutorModeEnabled(_ enabled: Bool) {
        isTutorModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.tutorModeDefaultsKey)
        if enabled {
            ensureCursorOverlayVisibleForAgentTask()
            startTutorIdleObservation()
        } else {
            stopTutorIdleObservation()
        }
    }

    func setAdvancedModeEnabled(_ enabled: Bool) {
        isAdvancedModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppBundleConfiguration.userAdvancedModeDefaultsKey)
        if !enabled {
            codexHUDWindowManager.hide()
        }
    }

    func setAnthropicAPIKey(_ apiKey: String) {
        persistOptionalSecret(apiKey, defaultsKey: AppBundleConfiguration.userAnthropicAPIKeyDefaultsKey)
        claudeAPI.setAPIKey(AppBundleConfiguration.anthropicAPIKey())
    }

    func setElevenLabsAPIKey(_ apiKey: String) {
        persistOptionalSecret(apiKey, defaultsKey: AppBundleConfiguration.userElevenLabsAPIKeyDefaultsKey)
        elevenLabsTTSClient.updateConfiguration(
            apiKey: AppBundleConfiguration.elevenLabsAPIKey(),
            voiceID: AppBundleConfiguration.elevenLabsVoiceID()
        )
    }

    func setElevenLabsVoiceID(_ voiceID: String) {
        persistOptionalSecret(voiceID, defaultsKey: AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey)
        elevenLabsTTSClient.updateConfiguration(
            apiKey: AppBundleConfiguration.elevenLabsAPIKey(),
            voiceID: AppBundleConfiguration.elevenLabsVoiceID()
        )
    }

    func setAssemblyAIAPIKey(_ apiKey: String) {
        persistOptionalSecret(apiKey, defaultsKey: AppBundleConfiguration.userAssemblyAIAPIKeyDefaultsKey)
        buddyDictationManager.setTranscriptionProvider(buddyDictationManager.transcriptionProviderID)
    }

    func setDeepgramAPIKey(_ apiKey: String) {
        persistOptionalSecret(apiKey, defaultsKey: AppBundleConfiguration.userDeepgramAPIKeyDefaultsKey)
        buddyDictationManager.setTranscriptionProvider(buddyDictationManager.transcriptionProviderID)
    }

    func setVoiceTranscriptionProvider(_ providerID: String) {
        buddyDictationManager.setTranscriptionProvider(providerID)
    }

    func setCodexAgentAPIKey(_ apiKey: String) {
        persistOptionalSecret(apiKey, defaultsKey: AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey)
        openAIAPI.setAPIKey(AppBundleConfiguration.openAIAPIKey())
        codexAgentSessions.forEach { $0.stop() }
    }

    private func persistOptionalSecret(_ value: String, defaultsKey: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(trimmedValue, forKey: defaultsKey)
        }
    }

    /// User preference for whether the OpenClicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        loadBundledKnowledgeIndex()
        refreshAllPermissions()
        if !hasCompletedOnboarding {
            hasCompletedOnboarding = true
        }
        print("OpenClicky runtime identity - bundleID: \(Bundle.main.bundleIdentifier ?? "unknown"), appPath: \(Bundle.main.bundleURL.path)")
        print("OpenClicky start - accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), fullDiskAccess: \(hasFullDiskAccessPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindAgentSessionObservation()
        if isTutorModeEnabled {
            startTutorIdleObservation()
        }
        if let claudeAgentSDKAPI {
            claudeAgentSDKAPI.warmUp(systemPrompt: currentVoiceResponseSystemPrompt())
        } else if AppBundleConfiguration.anthropicAPIKey() != nil {
            _ = claudeAPI
        }
        let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        if selectedVoiceResponseModel.provider == .openAI || selectedVoiceResponseModel.provider == .codex {
            codexVoiceSession.model = selectedVoiceResponseModel.id
            codexVoiceSession.warmUp(systemPrompt: currentVoiceResponseSystemPrompt())
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Completes the old onboarding entry path and shows the cursor without
    /// any welcome, video, or demo sequence.
    func triggerOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Onboarding replay is disabled. Keep this as a no-op for old call sites.
    func replayOnboarding() {
        tearDownOnboardingVideo()
        stopOnboardingMusic()
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ OpenClicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.fadeOutOnboardingMusic()
                }
            }
        } catch {
            print("⚠️ OpenClicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        onboardingMusicFadeStepsRemaining = fadeSteps
        onboardingMusicFadeVolumeDecrement = player.volume / Float(fadeSteps)

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceOnboardingMusicFade()
            }
        }
    }

    private func advanceOnboardingMusicFade() {
        guard let player = onboardingMusicPlayer else {
            onboardingMusicFadeTimer?.invalidate()
            onboardingMusicFadeTimer = nil
            return
        }

        onboardingMusicFadeStepsRemaining -= 1
        player.volume -= onboardingMusicFadeVolumeDecrement

        if onboardingMusicFadeStepsRemaining <= 0 {
            onboardingMusicFadeTimer?.invalidate()
            player.stop()
            onboardingMusicPlayer = nil
            onboardingMusicFadeTimer = nil
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        claudeAgentSDKAPI?.stop()
        codexVoiceSession.stop()
        pendingAgentActivityRefreshTasks.values.forEach { $0.cancel() }
        pendingAgentActivityRefreshTasks.removeAll()
        agentTitleCancellables.removeAll()
        shortcutTransitionCancellable?.cancel()
        stopTutorIdleObservation()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadFullDiskAccess = hasFullDiskAccessPermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Screen content permission is persisted after the ScreenCaptureKit
        // picker approves it, but it is only useful when real Screen Recording
        // permission is also present.
        let persistedScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        hasScreenContentPermission = hasScreenRecordingPermission && persistedScreenContentPermission
        hasFullDiskAccessPermission = OpenClickyMacPrivacyPermissionProbe.hasLikelyFullDiskAccess()

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission
            || previouslyHadFullDiskAccess != hasFullDiskAccessPermission {
            print("Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), fullDiskAccess: \(hasFullDiskAccessPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        if !previouslyHadFullDiskAccess && hasFullDiskAccessPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "full_disk_access")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("Screen content capture result - width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("Screen content permission request failed: \(error)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    hasScreenContentPermission = false
                    UserDefaults.standard.set(false, forKey: "hasScreenContentPermission")
                }
            }
        }
    }

    // MARK: - Private

    private func loadBundledKnowledgeIndex() {
        let bundledIndex = WikiManager.Index.loadForAppBundle()
        let memoriesDirectory = codexHomeManager.memoriesDirectory
        let learnedSkillsDirectory = codexHomeManager.learnedSkillsDirectory

        do {
            try FileManager.default.createDirectory(at: memoriesDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: learnedSkillsDirectory, withIntermediateDirectories: true)
            let memoryIndex = try WikiManager.Index.load(articleRoots: [memoriesDirectory], skillRoots: [learnedSkillsDirectory])
            bundledKnowledgeIndex = bundledIndex.combined(with: memoryIndex)
        } catch {
            print("⚠️ OpenClicky memory index load failed: \(error)")
            bundledKnowledgeIndex = bundledIndex
        }
    }

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        controlDoubleTapCancellable = globalPushToTalkShortcutMonitor
            .controlDoubleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.showTextModeInputAtCursor()
            }
    }

    private func bindAgentSessionObservation() {
        codexAgentSessions.forEach { observeCodexAgentSession($0) }
    }

    private func observeCodexAgentSession(_ session: CodexAgentSession) {
        guard agentStatusCancellables[session.id] == nil else { return }

        session.onOpenableFileFound = { [weak self, weak session] fileURL in
            guard let self, let session else { return }
            self.handleAgentFoundOpenableFile(fileURL, session: session)
        }

        agentStatusCancellables[session.id] = session.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] status in
                guard let self else { return }
                self.updateAgentDockItem(for: sessionID, status: status)
                self.scheduleWidgetSnapshotPublish()
                self.updateAgentProgressNarration()
            }

        agentActivityCancellables[session.id] = session.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] _ in
                self?.scheduleAgentActivityRefresh(for: sessionID)
            }

        agentTitleCancellables[session.id] = session.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] title in
                self?.updateAgentDockTitle(for: sessionID, title: title)
            }
    }

    private func updateAgentDockTitle(for sessionID: UUID, title: String) {
        guard let itemIndex = agentDockItems.lastIndex(where: { $0.sessionID == sessionID }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, agentDockItems[itemIndex].title != trimmedTitle else { return }
        agentDockItems[itemIndex].title = trimmedTitle
        scheduleWidgetSnapshotPublish()
    }

    private func scheduleAgentActivityRefresh(for sessionID: UUID) {
        guard pendingAgentActivityRefreshTasks[sessionID] == nil else { return }

        pendingAgentActivityRefreshTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            await MainActor.run {
                guard let self else { return }
                self.pendingAgentActivityRefreshTasks[sessionID] = nil
                guard let session = self.codexAgentSessions.first(where: { $0.id == sessionID }) else { return }
                self.updateAgentDockItem(for: sessionID, status: session.status)
                self.scheduleWidgetSnapshotPublish()
                self.updateAgentProgressNarration()
            }
        }
    }

    @discardableResult
    func createAndSelectNewCodexAgentSession(title: String? = nil, accentTheme: ClickyAccentTheme? = nil) -> CodexAgentSession {
        let nextIndex = codexAgentSessions.count + 1
        let resolvedAccentTheme = accentTheme ?? Self.nextAgentDockAccentTheme(existingCount: codexAgentSessions.count)
        let session = CodexAgentSession(
            title: title ?? "Agent \(nextIndex)",
            accentTheme: resolvedAccentTheme
        )
        codexAgentSessions.append(session)
        observeCodexAgentSession(session)
        activeCodexAgentSessionID = session.id
        lastAgentContextSessionID = session.id
        scheduleWidgetSnapshotPublish()
        return session
    }

    private func handleAgentFoundOpenableFile(_ fileURL: URL, session: CodexAgentSession) {
        let standardizedURL = fileURL.standardizedFileURL
        let eventKey = "\(session.id.uuidString)|\(standardizedURL.path)"
        guard !announcedAgentFileURLs.contains(eventKey) else { return }

        announcedAgentFileURLs.insert(eventKey)
        NSWorkspace.shared.open(standardizedURL)
        speakShortSystemResponse("\(session.spokenAgentSentenceName) says it found \(Self.spokenFileName(for: standardizedURL)), showing it now.")
    }

    private static func spokenFileName(for fileURL: URL) -> String {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let cleanedName = name
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return cleanedName.isEmpty ? "the file" : cleanedName
    }

    func selectCodexAgentSession(_ sessionID: UUID) {
        guard codexAgentSessions.contains(where: { $0.id == sessionID }) else { return }
        activeCodexAgentSessionID = sessionID
        lastAgentContextSessionID = sessionID
    }

    private func beginRequestTiming(source: String, text: String) -> OpenClickyRequestTiming {
        let timing = OpenClickyRequestTiming(
            requestID: UUID().uuidString,
            source: source,
            text: text,
            requestedAt: Date()
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "request",
            direction: "incoming",
            event: "openclicky.request.received",
            fields: requestTimingFields(
                timing,
                extra: [
                    "textLength": text.count,
                    "textPreview": Self.truncatedLogText(text, maxLength: 240)
                ]
            )
        )
        return timing
    }

    private func withActiveRequestTiming<T>(_ timing: OpenClickyRequestTiming, perform work: () -> T) -> T {
        let previousTiming = activeRequestTiming
        activeRequestTiming = timing
        defer { activeRequestTiming = previousTiming }
        return work()
    }

    private func markRequestExecutionStarted(
        route: String,
        timing: OpenClickyRequestTiming? = nil,
        extra: [String: Any] = [:]
    ) -> Date {
        let startedAt = Date()
        var fields = extra
        fields["executionStartedAt"] = startedAt
        OpenClickyMessageLogStore.shared.append(
            lane: "request",
            direction: "outgoing",
            event: "openclicky.request.execution_started",
            fields: requestTimingFields(
                timing ?? activeRequestTiming,
                route: route,
                at: startedAt,
                extra: fields
            )
        )
        return startedAt
    }

    private func markRequestStageCompleted(
        route: String,
        stage: String,
        stageStartedAt: Date,
        timing: OpenClickyRequestTiming? = nil,
        status: String = "success",
        extra: [String: Any] = [:]
    ) {
        let completedAt = Date()
        var fields = extra
        fields["stage"] = stage
        fields["status"] = status
        fields["stageStartedAt"] = stageStartedAt
        fields["stageCompletedAt"] = completedAt
        fields["stageDurationMs"] = Self.elapsedMilliseconds(from: stageStartedAt, to: completedAt)
        OpenClickyMessageLogStore.shared.append(
            lane: "request",
            direction: "outgoing",
            event: "openclicky.request.stage_completed",
            fields: requestTimingFields(
                timing ?? activeRequestTiming,
                route: route,
                status: status,
                at: completedAt,
                extra: fields
            )
        )
    }

    private func markRequestCompleted(
        route: String,
        executionStartedAt: Date? = nil,
        timing: OpenClickyRequestTiming? = nil,
        status: String = "success",
        extra: [String: Any] = [:]
    ) {
        let completedAt = Date()
        var fields = extra
        fields["status"] = status
        fields["completedAt"] = completedAt
        if let executionStartedAt {
            fields["executionStartedAt"] = executionStartedAt
            fields["executionDurationMs"] = Self.elapsedMilliseconds(from: executionStartedAt, to: completedAt)
        }
        OpenClickyMessageLogStore.shared.append(
            lane: "request",
            direction: status == "success" ? "outgoing" : "error",
            event: "openclicky.request.completed",
            fields: requestTimingFields(
                timing ?? activeRequestTiming,
                route: route,
                status: status,
                at: completedAt,
                extra: fields
            )
        )
    }

    private func requestTimingFields(
        _ timing: OpenClickyRequestTiming?,
        route: String? = nil,
        status: String? = nil,
        at: Date = Date(),
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var fields = extra
        fields["timingEventAt"] = at
        if let route {
            fields["route"] = route
        }
        if let status {
            fields["status"] = status
        }
        guard let timing else {
            fields["requestID"] = "none"
            return fields
        }

        fields["requestID"] = timing.requestID
        fields["requestSource"] = timing.source
        fields["requestReceivedAt"] = timing.requestedAt
        fields["requestAgeMs"] = Self.elapsedMilliseconds(from: timing.requestedAt, to: at)
        return fields
    }

    private static func elapsedMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private static func truncatedLogText(_ value: String, maxLength: Int) -> String {
        let flattened = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > maxLength else { return flattened }
        return String(flattened.prefix(maxLength))
    }

    private func voiceResponseExecutionFields() -> [String: Any] {
        let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        var fields: [String: Any] = [
            "executor": "voice_response",
            "model": selectedVoiceResponseModel.id,
            "modelProvider": selectedVoiceResponseModel.provider.rawValue,
            "maxOutputTokens": selectedVoiceResponseModel.maxOutputTokens
        ]

        switch selectedVoiceResponseModel.provider {
        case .anthropic:
            if claudeAgentSDKAPI != nil {
                fields["executionMethod"] = "ClaudeAgentSDKAPI.analyzeImageStreaming"
                fields["authMode"] = "local_claude_agent_sdk_primary"
                fields["transport"] = "agent_sdk_query"
                fields["streamingMethod"] = "claude_agent_sdk_query"
                fields["apiKeyFallback"] = AppBundleConfiguration.anthropicAPIKey() != nil
            } else if AppBundleConfiguration.anthropicAPIKey() != nil {
                fields["executionMethod"] = "ClaudeAPI.analyzeImageStreaming"
                fields["authMode"] = "anthropic_api_key_fallback"
                fields["transport"] = "sse"
                fields["streamingMethod"] = "URLSession.bytes"
            } else {
                fields["executionMethod"] = "ClaudeAgentSDKAPI.analyzeImageStreaming"
                fields["authMode"] = "local_claude_agent_sdk_missing"
                fields["transport"] = "agent_sdk_query"
                fields["streamingMethod"] = "claude_agent_sdk_query"
            }
        case .openAI:
            fields["executionMethod"] = "CodexVoiceSession.analyzeImageStreaming"
            fields["authMode"] = "local_codex_chatgpt_primary"
            fields["transport"] = "codex_app_server_stdio"
            fields["streamingMethod"] = "codex_app_server_agentMessage_delta"
            fields["apiKeyFallback"] = AppBundleConfiguration.openAIAPIKey() != nil
        case .codex:
            fields["executionMethod"] = "CodexVoiceSession.analyzeImageStreaming"
            fields["authMode"] = "local_codex_chatgpt_primary"
            fields["transport"] = "codex_app_server_stdio"
            fields["streamingMethod"] = "codex_app_server_agentMessage_delta"
            fields["apiKeyFallback"] = AppBundleConfiguration.openAIAPIKey() != nil
        }

        return fields
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            interruptCurrentVoiceResponse()
            clearDetectedElementLocation()
            liveHandledComputerUseFingerprints.removeAll()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { [weak self] partialTranscript in
                        self?.handleLiveComputerUseTranscript(partialTranscript)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.handleFinalVoiceTranscript(finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    private func handleFinalVoiceTranscript(_ finalTranscript: String) {
        lastTranscript = finalTranscript
        let requestTiming = beginRequestTiming(source: "voice_final_transcript", text: finalTranscript)
        activeRequestTiming = requestTiming
        defer { activeRequestTiming = nil }
        print("Companion received transcript: \(finalTranscript)")
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: "voice.transcript",
            fields: [
                "text": finalTranscript,
                "requestID": requestTiming.requestID
            ]
        )
        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
        if handleAgentCancellationRequestIfNeeded(from: finalTranscript) {
            return
        }
        if handleAgentStatusQuestionIfNeeded(from: finalTranscript) {
            return
        }
        if handleAgentSelectionRequestIfNeeded(from: finalTranscript, source: "voice_final_transcript") {
            return
        }
        if startExplicitAgentTaskIfRequested(from: finalTranscript) {
            return
        }
        if handleDirectComputerUseRequest(from: finalTranscript, source: "final_transcript") {
            return
        }
        if submitPendingAgentVoiceFollowUp(finalTranscript) {
            return
        }
        if submitContextualAgentFollowUp(finalTranscript, source: "voice") {
            return
        }
        sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
    }

    // MARK: - Companion Prompt

    private func handleLiveComputerUseTranscript(_ partialTranscript: String) {
        let trimmedTranscript = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let isShortKnownAppRequest = Self.bareLocalAppOpenRequest(from: trimmedTranscript) != nil
        guard trimmedTranscript.count >= 8 || isShortKnownAppRequest else { return }

        let shouldTraceMiss = Self.isPotentialDirectComputerUseTranscript(trimmedTranscript)
        if Self.shouldDeferLiveComputerUseForAgentRoute(trimmedTranscript) {
            if shouldTraceMiss {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "incoming",
                    event: "native_cua.live_partial.deferred_agent_route",
                    fields: [
                        "partialTranscript": trimmedTranscript
                    ]
                )
            }
            return
        }

        if let folderRequest = folderOpenRequest(from: trimmedTranscript) {
            let fingerprint = Self.directComputerUseFingerprint(kind: "folder", value: folderRequest.url.path)
            guard !liveHandledComputerUseFingerprints.contains(fingerprint) else { return }
            liveHandledComputerUseFingerprints.insert(fingerprint)
            let requestTiming = beginRequestTiming(source: "voice_live_partial", text: trimmedTranscript)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.live_partial.folder_detected",
                fields: [
                    "partialTranscript": trimmedTranscript,
                    "executor": "native_cua",
                    "route": "native_cua.open_folder",
                    "executionMethod": "NSWorkspace.open",
                    "path": folderRequest.url.path,
                    "requestID": requestTiming.requestID
                ]
            )
            withActiveRequestTiming(requestTiming) {
                openRequestedFolder(folderRequest, shouldSpeak: false)
            }
            return
        }

        if let appOpenRequest = Self.localAppOpenRequest(from: trimmedTranscript) {
            let fingerprint = Self.directComputerUseFingerprint(kind: "app", value: appOpenRequest.appName)
            guard !liveHandledComputerUseFingerprints.contains(fingerprint) else { return }
            liveHandledComputerUseFingerprints.insert(fingerprint)
            let requestTiming = beginRequestTiming(source: "voice_live_partial", text: trimmedTranscript)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.live_partial.app_detected",
                fields: [
                    "partialTranscript": trimmedTranscript,
                    "executor": "native_cua",
                    "route": "native_cua.open_app",
                    "executionMethod": "launchApplication(named:)",
                    "appName": appOpenRequest.appName,
                    "requestID": requestTiming.requestID
                ]
            )
            withActiveRequestTiming(requestTiming) {
                _ = openRequestedApplication(appOpenRequest, shouldSpeak: false)
            }
            return
        }

        if let keyPressRequest = Self.nativeKeyPressRequest(from: trimmedTranscript) {
            let backend = selectedComputerUseBackend
            let fingerprint = Self.directComputerUseFingerprint(
                kind: "key",
                value: "\(keyPressRequest.modifiers.joined(separator: "+"))+\(keyPressRequest.key)"
            )
            guard !liveHandledComputerUseFingerprints.contains(fingerprint) else { return }
            liveHandledComputerUseFingerprints.insert(fingerprint)
            let requestTiming = beginRequestTiming(source: "voice_live_partial", text: trimmedTranscript)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "\(backend.executorID).live_partial.key_detected",
                fields: [
                    "partialTranscript": trimmedTranscript,
                    "executor": backend.executorID,
                    "route": "\(backend.executorID).press_key",
                    "executionMethod": backend == .backgroundComputerUse
                        ? "BackgroundComputerUse /v1/press_key"
                        : "OpenClickyNativeComputerUseController.pressKey",
                    "key": keyPressRequest.key,
                    "modifiers": keyPressRequest.modifiers.joined(separator: ","),
                    "requestID": requestTiming.requestID
                ]
            )
            withActiveRequestTiming(requestTiming) {
                pressKeyUsingSelectedComputerUse(keyPressRequest, shouldSpeak: false)
            }
            return
        }

        if shouldTraceMiss {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.live_partial.no_direct_match",
                fields: [
                    "partialTranscript": trimmedTranscript
                ]
            )
        }
    }

    private func handleDirectComputerUseRequest(from transcript: String, source: String) -> Bool {
        if let folderRequest = folderOpenRequest(from: transcript) {
            let fingerprint = Self.directComputerUseFingerprint(kind: "folder", value: folderRequest.url.path)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.folder_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.open_folder",
                    "executionMethod": "NSWorkspace.open",
                    "path": folderRequest.url.path,
                    "alreadyHandledLive": liveHandledComputerUseFingerprints.contains(fingerprint),
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            if liveHandledComputerUseFingerprints.contains(fingerprint) {
                let executionStartedAt = markRequestExecutionStarted(
                    route: "native_cua.open_folder.already_handled_live",
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "live_partial_preexecuted",
                        "path": folderRequest.url.path
                    ]
                )
                speakShortSystemResponse("opening \(folderRequest.displayName).")
                markRequestCompleted(
                    route: "native_cua.open_folder.already_handled_live",
                    executionStartedAt: executionStartedAt,
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "live_partial_preexecuted",
                        "path": folderRequest.url.path
                    ]
                )
            } else {
                openRequestedFolder(folderRequest)
            }
            return true
        }

        if let appOpenRequest = Self.localAppOpenRequest(from: transcript) {
            let fingerprint = Self.directComputerUseFingerprint(kind: "app", value: appOpenRequest.appName)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.app_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.open_app",
                    "executionMethod": "launchApplication(named:)",
                    "appName": appOpenRequest.appName,
                    "alreadyHandledLive": liveHandledComputerUseFingerprints.contains(fingerprint),
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            if liveHandledComputerUseFingerprints.contains(fingerprint) {
                let executionStartedAt = markRequestExecutionStarted(
                    route: "native_cua.open_app.already_handled_live",
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "live_partial_preexecuted",
                        "appName": appOpenRequest.appName
                    ]
                )
                speakShortSystemResponse("opening \(appOpenRequest.appName).")
                markRequestCompleted(
                    route: "native_cua.open_app.already_handled_live",
                    executionStartedAt: executionStartedAt,
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "live_partial_preexecuted",
                        "appName": appOpenRequest.appName
                    ]
                )
            } else {
                _ = openRequestedApplication(appOpenRequest)
            }
            return true
        }

        if let reminderAddRequest = Self.reminderAddRequest(from: transcript) {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.reminder_add_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.reminder_add",
                    "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                    "title": reminderAddRequest.title,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            addReminderUsingNativeAutomation(reminderAddRequest)
            return true
        }

        if let reminderCountRequest = Self.reminderCountRequest(from: transcript) {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.reminder_count_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.reminder_count",
                    "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            countRemindersUsingNativeAutomation(reminderCountRequest)
            return true
        }

        if let messagesSearchRequest = Self.messagesSearchRequest(from: transcript) {
            let backend = selectedComputerUseBackend
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "\(backend.executorID).direct_request.messages_search_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": backend.executorID,
                    "route": "\(backend.executorID).messages_search",
                    "executionMethod": backend == .backgroundComputerUse
                        ? "BackgroundComputerUse /v1/press_key + /v1/type_text"
                        : "OpenClickyNativeComputerUseController.pressKey/typeText",
                    "personName": messagesSearchRequest.personName,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            searchMessagesUsingSelectedComputerUse(messagesSearchRequest)
            return true
        }

        if let typeRequest = Self.nativeTypeRequest(from: transcript) {
            let backend = selectedComputerUseBackend
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "\(backend.executorID).direct_request.type_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": backend.executorID,
                    "route": "\(backend.executorID).type_text",
                    "executionMethod": backend == .backgroundComputerUse
                        ? "BackgroundComputerUse /v1/type_text"
                        : "OpenClickyNativeComputerUseController.typeText",
                    "textLength": typeRequest.text.count,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            typeTextUsingSelectedComputerUse(typeRequest)
            return true
        }

        if let keyPressRequest = Self.nativeKeyPressRequest(from: transcript) {
            let backend = selectedComputerUseBackend
            let fingerprint = Self.directComputerUseFingerprint(
                kind: "key",
                value: "\(keyPressRequest.modifiers.joined(separator: "+"))+\(keyPressRequest.key)"
            )
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "\(backend.executorID).direct_request.key_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": backend.executorID,
                    "route": "\(backend.executorID).press_key",
                    "executionMethod": backend == .backgroundComputerUse
                        ? "BackgroundComputerUse /v1/press_key"
                        : "OpenClickyNativeComputerUseController.pressKey",
                    "key": keyPressRequest.key,
                    "modifiers": keyPressRequest.modifiers.joined(separator: ","),
                    "alreadyHandledLive": liveHandledComputerUseFingerprints.contains(fingerprint),
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            if liveHandledComputerUseFingerprints.contains(fingerprint) {
                let modifierText = keyPressRequest.modifiers.isEmpty ? "" : keyPressRequest.modifiers.joined(separator: " ") + " "
                let executionStartedAt = markRequestExecutionStarted(
                    route: "\(backend.executorID).press_key.already_handled_live",
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": "live_partial_preexecuted",
                        "key": keyPressRequest.key,
                        "modifiers": keyPressRequest.modifiers.joined(separator: ",")
                    ]
                )
                speakShortSystemResponse("pressed \(modifierText)\(keyPressRequest.key).")
                markRequestCompleted(
                    route: "\(backend.executorID).press_key.already_handled_live",
                    executionStartedAt: executionStartedAt,
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": "live_partial_preexecuted",
                        "key": keyPressRequest.key,
                        "modifiers": keyPressRequest.modifiers.joined(separator: ",")
                    ]
                )
            } else {
                pressKeyUsingSelectedComputerUse(keyPressRequest)
            }
            return true
        }

        return false
    }

    @discardableResult
    private func openRequestedApplication(
        _ request: OpenClickyAppOpenRequest,
        shouldSpeak: Bool = true,
        logTiming: Bool = true
    ) -> Bool {
        let executionStartedAt = logTiming
            ? markRequestExecutionStarted(
                route: "native_cua.open_app",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "launchApplication(named:)",
                    "controller": "NSWorkspace.openApplication_or_open_a",
                    "appName": request.appName,
                    "shouldSpeak": shouldSpeak
                ]
            )
            : Date()
        if launchApplication(named: request.appName) {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "native_cua.open_app",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "launchApplication(named:)",
                    "controller": "NSWorkspace.openApplication_or_open_a",
                    "appName": request.appName,
                    "instruction": request.instruction
                ]
            )
            if shouldSpeak {
                speakShortSystemResponse("opening \(request.appName).")
            }
            if logTiming {
                markRequestCompleted(
                    route: "native_cua.open_app",
                    executionStartedAt: executionStartedAt,
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "launchApplication(named:)",
                        "controller": "NSWorkspace.openApplication_or_open_a",
                        "appName": request.appName
                    ]
                )
            }
            return true
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "native_cua.open_app.failed",
            fields: [
                "executor": "native_cua",
                "executionMethod": "launchApplication(named:)",
                "controller": "NSWorkspace.openApplication_or_open_a",
                "appName": request.appName,
                "instruction": request.instruction
            ]
        )

        if shouldSpeak {
            speakShortSystemResponse("i couldn't open \(request.appName) through native CUA.")
        }
        if logTiming {
            markRequestCompleted(
                route: "native_cua.open_app",
                executionStartedAt: executionStartedAt,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "launchApplication(named:)",
                    "controller": "NSWorkspace.openApplication_or_open_a",
                    "appName": request.appName
                ]
            )
        }
        return false
    }

    private func openRequestedFolder(_ request: OpenClickyFolderOpenRequest, shouldSpeak: Bool = true) {
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.open_folder",
            extra: [
                "executor": "native_cua",
                "executionMethod": "NSWorkspace.open",
                "controller": "NSWorkspace",
                "path": request.url.path,
                "shouldSpeak": shouldSpeak
            ]
        )
        NSWorkspace.shared.open(request.url)
        currentFolderContextURL = request.url.standardizedFileURL
        OpenClickyDirectActionMemoryStore.shared.recordFolderShortcut(
            instruction: request.instruction,
            url: request.url,
            displayName: request.displayName
        )
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "opening \(request.displayName).",
            contextTitle: request.instruction
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "native_cua.open_folder",
            fields: [
                "executor": "native_cua",
                "executionMethod": "NSWorkspace.open",
                "controller": "NSWorkspace",
                "path": request.url.path,
                "instruction": request.instruction
            ]
        )
        if shouldSpeak {
            speakShortSystemResponse("opening \(request.displayName).")
        }
        markRequestCompleted(
            route: "native_cua.open_folder",
            executionStartedAt: executionStartedAt,
            extra: [
                "executor": "native_cua",
                "executionMethod": "NSWorkspace.open",
                "controller": "NSWorkspace",
                "path": request.url.path
            ]
        )
    }

    private func folderOpenRequest(from transcript: String) -> OpenClickyFolderOpenRequest? {
        if let request = Self.localFolderOpenRequest(from: transcript) {
            return request
        }

        guard let currentFolderContextURL,
              let relativeRequest = Self.relativeFolderOpenRequest(
                from: transcript,
                baseURL: currentFolderContextURL
              ) else {
            return nil
        }

        return relativeRequest
    }

    private func addReminderUsingNativeAutomation(_ request: OpenClickyReminderAddRequest) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.reminder_add",
            timing: timing,
            extra: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                "controller": "/usr/bin/osascript",
                "automationTarget": "Reminders",
                "title": request.title
            ]
        )
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "adding \(request.title) to Reminders.",
            contextTitle: "Native CUA"
        )

        let title = request.title
        let instruction = request.instruction
        Task.detached(priority: .userInitiated) {
            let titleLiteral = OpenClickyLocalAutomationRunner.appleScriptStringLiteral(title)
            let script = """
            tell application "Reminders"
                set targetList to default list
                make new reminder at end of reminders of targetList with properties {name:\(titleLiteral)}
            end tell
            """
            let result = OpenClickyLocalAutomationRunner.runAppleScript(script)

            await MainActor.run {
                if result.terminationStatus == 0 {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "outgoing",
                        event: "native_cua.reminder_added",
                        fields: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "title": title,
                            "instruction": instruction
                        ]
                    )
                    self.speakShortSystemResponse("added \(title) to Reminders.")
                    self.markRequestCompleted(
                        route: "native_cua.reminder_add",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        extra: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "title": title
                        ]
                    )
                } else {
                    let message = Self.nativeAutomationErrorMessage(
                        appName: "Reminders",
                        result: result
                    )
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "native_cua.reminder_add_error",
                        fields: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "title": title,
                            "instruction": instruction,
                            "error": result.errorOutput.isEmpty ? result.output : result.errorOutput
                        ]
                    )
                    self.speakShortSystemResponse(message)
                    self.markRequestCompleted(
                        route: "native_cua.reminder_add",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "title": title,
                            "error": result.errorOutput.isEmpty ? result.output : result.errorOutput
                        ]
                    )
                }
            }
        }
    }

    private func countRemindersUsingNativeAutomation(_ request: OpenClickyReminderCountRequest) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.reminder_count",
            timing: timing,
            extra: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                "controller": "/usr/bin/osascript",
                "automationTarget": "Reminders"
            ]
        )
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "checking Reminders directly.",
            contextTitle: "Native CUA"
        )

        let instruction = request.instruction
        Task.detached(priority: .userInitiated) {
            let script = """
            tell application "Reminders"
                set openReminderCount to count of (reminders whose completed is false)
            end tell
            return openReminderCount as text
            """
            let result = OpenClickyLocalAutomationRunner.runAppleScript(script)

            await MainActor.run {
                if result.terminationStatus == 0 {
                    let rawCount = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let count = Int(rawCount) ?? 0
                    let noun = count == 1 ? "open reminder" : "open reminders"
                    let response = "you have \(count) \(noun)."
                    self.latestVoiceResponseCard = ClickyResponseCard(
                        source: .voice,
                        rawText: response,
                        contextTitle: "Reminders"
                    )
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "outgoing",
                        event: "native_cua.reminder_count",
                        fields: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "count": count,
                            "instruction": instruction
                        ]
                    )
                    self.speakShortSystemResponse(response)
                    self.markRequestCompleted(
                        route: "native_cua.reminder_count",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        extra: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "count": count
                        ]
                    )
                } else {
                    let message = Self.nativeAutomationErrorMessage(
                        appName: "Reminders",
                        result: result
                    )
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "native_cua.reminder_count_error",
                        fields: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "instruction": instruction,
                            "error": result.errorOutput.isEmpty ? result.output : result.errorOutput
                        ]
                    )
                    self.speakShortSystemResponse(message)
                    self.markRequestCompleted(
                        route: "native_cua.reminder_count",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: [
                            "executor": "native_cua",
                            "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                            "controller": "/usr/bin/osascript",
                            "automationTarget": "Reminders",
                            "error": result.errorOutput.isEmpty ? result.output : result.errorOutput
                        ]
                    )
                }
            }
        }
    }

    private func searchMessagesUsingSelectedComputerUse(_ request: OpenClickyMessagesSearchRequest) {
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            searchMessagesUsingBackgroundComputerUse(request)
        case .nativeSwift:
            searchMessagesUsingNativeComputerUse(request)
        }
    }

    private func typeTextUsingSelectedComputerUse(_ request: OpenClickyNativeTypeRequest) {
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            typeTextUsingBackgroundComputerUse(request)
        case .nativeSwift:
            typeTextUsingNativeComputerUse(request)
        }
    }

    private func pressKeyUsingSelectedComputerUse(_ request: OpenClickyNativeKeyPressRequest, shouldSpeak: Bool = true) {
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            pressKeyUsingBackgroundComputerUse(request, shouldSpeak: shouldSpeak)
        case .nativeSwift:
            pressKeyUsingNativeComputerUse(request, shouldSpeak: shouldSpeak)
        }
    }

    private func searchMessagesUsingBackgroundComputerUse(_ request: OpenClickyMessagesSearchRequest) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "background_computer_use.messages_search",
            timing: timing,
            extra: [
                "executor": "background_computer_use",
                "executionMethod": "BackgroundComputerUse /v1/press_key + /v1/type_text",
                "controller": "OpenClickyBackgroundComputerUseController",
                "appName": "Messages",
                "personName": request.personName,
                "runtimeStatus": backgroundComputerUseController.status.summary
            ]
        )
        let appRequest = OpenClickyAppOpenRequest(appName: "Messages", instruction: "Open Messages.")
        _ = openRequestedApplication(appRequest, shouldSpeak: false, logTiming: false)
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "searching Messages for \(request.personName).",
            contextTitle: "Background Computer Use"
        )

        let personName = request.personName
        let instruction = request.instruction
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "background_computer_use.messages_search_started",
            fields: [
                "executor": "background_computer_use",
                "executionMethod": "BackgroundComputerUse /v1/press_key + /v1/type_text",
                "controller": "OpenClickyBackgroundComputerUseController",
                "appName": "Messages",
                "personName": personName,
                "instruction": instruction,
                "runtimeStatus": backgroundComputerUseController.status.summary
            ]
        )

        Task { @MainActor in
            do {
                try? await Task.sleep(nanoseconds: 650_000_000)
                Self.activateRunningApplication(named: "Messages")
                try? await Task.sleep(nanoseconds: 200_000_000)
                let openSearch = try await backgroundComputerUseController.pressKey(
                    "f",
                    modifiers: ["command"],
                    targetAppName: "Messages"
                )
                try? await Task.sleep(nanoseconds: 150_000_000)
                let selectAll = try await backgroundComputerUseController.pressKey(
                    "a",
                    modifiers: ["command"],
                    targetAppName: "Messages"
                )
                let typed = try await backgroundComputerUseController.typeText(
                    personName,
                    targetAppName: "Messages"
                )
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "background_computer_use.messages_search",
                    fields: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key + /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "instruction": instruction,
                        "openSearch": openSearch.summary,
                        "selectAll": selectAll.summary,
                        "typed": typed.summary,
                        "windowID": typed.windowID
                    ]
                )
                speakShortSystemResponse("searching Messages for \(personName).")
                markRequestCompleted(
                    route: "background_computer_use.messages_search",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key + /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "windowID": typed.windowID
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "background_computer_use.messages_search_error",
                    fields: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key + /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "instruction": instruction,
                        "runtimeStatus": backgroundComputerUseController.status.summary,
                        "error": error.localizedDescription
                    ]
                )
                speakShortSystemResponse("Background Computer Use hit a blocker searching Messages: \(error.localizedDescription)")
                markRequestCompleted(
                    route: "background_computer_use.messages_search",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key + /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func typeTextUsingBackgroundComputerUse(_ request: OpenClickyNativeTypeRequest) {
        interruptCurrentVoiceResponse()
        let executionStartedAt = markRequestExecutionStarted(
            route: "background_computer_use.type_text",
            extra: [
                "executor": "background_computer_use",
                "executionMethod": "BackgroundComputerUse /v1/type_text",
                "controller": "OpenClickyBackgroundComputerUseController",
                "textLength": request.text.count,
                "runtimeStatus": backgroundComputerUseController.status.summary
            ]
        )

        Task { @MainActor in
            do {
                let result = try await backgroundComputerUseController.typeText(request.text)
                let acknowledgement = "typed that with Background Computer Use."
                latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: acknowledgement,
                    contextTitle: request.targetDescription
                )
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "background_computer_use.type_text",
                    fields: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "windowID": result.windowID,
                        "summary": result.summary,
                        "textLength": request.text.count
                    ]
                )
                speakShortSystemResponse(acknowledgement)
                markRequestCompleted(
                    route: "background_computer_use.type_text",
                    executionStartedAt: executionStartedAt,
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "windowID": result.windowID,
                        "textLength": request.text.count
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "background_computer_use.type_text_error",
                    fields: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "runtimeStatus": backgroundComputerUseController.status.summary,
                        "error": error.localizedDescription
                    ]
                )
                speakShortSystemResponse("Background Computer Use typing hit a blocker: \(error.localizedDescription)")
                markRequestCompleted(
                    route: "background_computer_use.type_text",
                    executionStartedAt: executionStartedAt,
                    status: "failed",
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/type_text",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func pressKeyUsingBackgroundComputerUse(_ request: OpenClickyNativeKeyPressRequest, shouldSpeak: Bool = true) {
        if shouldSpeak {
            interruptCurrentVoiceResponse()
        }
        let executionStartedAt = markRequestExecutionStarted(
            route: "background_computer_use.press_key",
            extra: [
                "executor": "background_computer_use",
                "executionMethod": "BackgroundComputerUse /v1/press_key",
                "controller": "OpenClickyBackgroundComputerUseController",
                "key": request.key,
                "modifiers": request.modifiers.joined(separator: ","),
                "shouldSpeak": shouldSpeak,
                "runtimeStatus": backgroundComputerUseController.status.summary
            ]
        )

        Task { @MainActor in
            do {
                let result = try await backgroundComputerUseController.pressKey(
                    request.key,
                    modifiers: request.modifiers
                )
                let modifierText = request.modifiers.isEmpty ? "" : request.modifiers.joined(separator: " ") + " "
                let acknowledgement = "pressed \(modifierText)\(request.key) with Background Computer Use."
                latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: acknowledgement,
                    contextTitle: request.targetDescription
                )
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "background_computer_use.press_key",
                    fields: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "windowID": result.windowID,
                        "summary": result.summary,
                        "key": request.key,
                        "modifiers": request.modifiers.joined(separator: ",")
                    ]
                )
                if shouldSpeak {
                    speakShortSystemResponse(acknowledgement)
                }
                markRequestCompleted(
                    route: "background_computer_use.press_key",
                    executionStartedAt: executionStartedAt,
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "windowID": result.windowID,
                        "key": request.key,
                        "modifiers": request.modifiers.joined(separator: ",")
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "background_computer_use.press_key_error",
                    fields: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "runtimeStatus": backgroundComputerUseController.status.summary,
                        "key": request.key,
                        "error": error.localizedDescription
                    ]
                )
                if shouldSpeak {
                    speakShortSystemResponse("Background Computer Use key press hit a blocker: \(error.localizedDescription)")
                }
                markRequestCompleted(
                    route: "background_computer_use.press_key",
                    executionStartedAt: executionStartedAt,
                    status: "failed",
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "BackgroundComputerUse /v1/press_key",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "key": request.key,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func searchMessagesUsingNativeComputerUse(_ request: OpenClickyMessagesSearchRequest) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.messages_search",
            timing: timing,
            extra: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyNativeComputerUseController.pressKey/typeText",
                "controller": "OpenClickyNativeComputerUseController",
                "appName": "Messages",
                "personName": request.personName
            ]
        )
        let appRequest = OpenClickyAppOpenRequest(appName: "Messages", instruction: "Open Messages.")
        _ = openRequestedApplication(appRequest, shouldSpeak: false, logTiming: false)
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "searching Messages for \(request.personName).",
            contextTitle: "Native CUA"
        )

        let personName = request.personName
        let instruction = request.instruction
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "native_cua.messages_search_started",
            fields: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyNativeComputerUseController.pressKey/typeText",
                "controller": "OpenClickyNativeComputerUseController",
                "appName": "Messages",
                "personName": personName,
                "instruction": instruction
            ]
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            Self.activateRunningApplication(named: "Messages")

            if !nativeComputerUseController.isEnabled {
                nativeComputerUseController.setEnabled(true)
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let targetWindow = nativeComputerUseController.refreshFocusedTarget() else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "native_cua.messages_search_error",
                    fields: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.refreshFocusedTarget",
                        "controller": "OpenClickyNativeComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "instruction": instruction,
                        "error": "No focused Messages window"
                    ]
                )
                speakShortSystemResponse("opened Messages, but I couldn't focus its search field.")
                markRequestCompleted(
                    route: "native_cua.messages_search",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.refreshFocusedTarget",
                        "controller": "OpenClickyNativeComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "error": "No focused Messages window"
                    ]
                )
                return
            }

            do {
                try nativeComputerUseController.pressKey("f", modifiers: ["command"], toPid: targetWindow.pid)
                try? await Task.sleep(nanoseconds: 150_000_000)
                try nativeComputerUseController.pressKey("a", modifiers: ["command"], toPid: targetWindow.pid)
                try nativeComputerUseController.typeText(personName, delayMilliseconds: 8, toPid: targetWindow.pid)
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "native_cua.messages_search",
                    fields: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "controller": "OpenClickyNativeComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "target": targetWindow.agentContextNote,
                        "instruction": instruction
                    ]
                )
                speakShortSystemResponse("searching Messages for \(personName).")
                markRequestCompleted(
                    route: "native_cua.messages_search",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "controller": "OpenClickyNativeComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "target": targetWindow.agentContextNote
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "native_cua.messages_search_error",
                    fields: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "controller": "OpenClickyNativeComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "target": targetWindow.agentContextNote,
                        "instruction": instruction,
                        "error": error.localizedDescription
                    ]
                )
                speakShortSystemResponse("Messages search hit a native CUA blocker: \(error.localizedDescription)")
                markRequestCompleted(
                    route: "native_cua.messages_search",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "controller": "OpenClickyNativeComputerUseController",
                        "appName": "Messages",
                        "personName": personName,
                        "target": targetWindow.agentContextNote,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func typeTextUsingNativeComputerUse(_ request: OpenClickyNativeTypeRequest) {
        interruptCurrentVoiceResponse()
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.type_text",
            extra: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyNativeComputerUseController.typeText",
                "controller": "OpenClickyNativeComputerUseController",
                "textLength": request.text.count
            ]
        )

        if !nativeComputerUseController.isEnabled {
            nativeComputerUseController.setEnabled(true)
        }

        guard let targetWindow = nativeComputerUseController.refreshFocusedTarget() else {
            speakShortSystemResponse("i don't have a target window to type into.")
            markRequestCompleted(
                route: "native_cua.type_text",
                executionStartedAt: executionStartedAt,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.refreshFocusedTarget",
                    "controller": "OpenClickyNativeComputerUseController",
                    "error": "No focused target window"
                ]
            )
            return
        }

        do {
            try nativeComputerUseController.typeText(request.text, delayMilliseconds: 10, toPid: targetWindow.pid)
            let target = targetWindow.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            let acknowledgement = target.isEmpty ? "typed that into the focused window." : "typed that into \(target)."
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: acknowledgement,
                contextTitle: request.targetDescription
            )
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "native_cua.type_text",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.typeText",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "textLength": request.text.count
                ]
            )
            speakShortSystemResponse(acknowledgement)
            markRequestCompleted(
                route: "native_cua.type_text",
                executionStartedAt: executionStartedAt,
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.typeText",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "textLength": request.text.count
                ]
            )
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "native_cua.type_text_error",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.typeText",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "error": error.localizedDescription
                ]
            )
            speakShortSystemResponse("native typing hit a blocker: \(error.localizedDescription)")
            markRequestCompleted(
                route: "native_cua.type_text",
                executionStartedAt: executionStartedAt,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.typeText",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private func pressKeyUsingNativeComputerUse(_ request: OpenClickyNativeKeyPressRequest, shouldSpeak: Bool = true) {
        if shouldSpeak {
            interruptCurrentVoiceResponse()
        }
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.press_key",
            extra: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyNativeComputerUseController.pressKey",
                "controller": "OpenClickyNativeComputerUseController",
                "key": request.key,
                "modifiers": request.modifiers.joined(separator: ","),
                "shouldSpeak": shouldSpeak
            ]
        )

        if !nativeComputerUseController.isEnabled {
            nativeComputerUseController.setEnabled(true)
        }

        guard let targetWindow = nativeComputerUseController.refreshFocusedTarget() else {
            if shouldSpeak {
                speakShortSystemResponse("i don't have a target window for that key press.")
            }
            markRequestCompleted(
                route: "native_cua.press_key",
                executionStartedAt: executionStartedAt,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.refreshFocusedTarget",
                    "controller": "OpenClickyNativeComputerUseController",
                    "key": request.key,
                    "error": "No focused target window"
                ]
            )
            return
        }

        do {
            try nativeComputerUseController.pressKey(request.key, modifiers: request.modifiers, toPid: targetWindow.pid)
            let modifierText = request.modifiers.isEmpty ? "" : request.modifiers.joined(separator: " ") + " "
            let target = targetWindow.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            let acknowledgement = target.isEmpty
                ? "pressed \(modifierText)\(request.key) in the focused window."
                : "pressed \(modifierText)\(request.key) in \(target)."
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: acknowledgement,
                contextTitle: request.targetDescription
            )
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "native_cua.press_key",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.pressKey",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "key": request.key,
                    "modifiers": request.modifiers.joined(separator: ",")
                ]
            )
            if shouldSpeak {
                speakShortSystemResponse(acknowledgement)
            }
            markRequestCompleted(
                route: "native_cua.press_key",
                executionStartedAt: executionStartedAt,
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.pressKey",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "key": request.key,
                    "modifiers": request.modifiers.joined(separator: ",")
                ]
            )
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "native_cua.press_key_error",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.pressKey",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "key": request.key,
                    "error": error.localizedDescription
                ]
            )
            if shouldSpeak {
                speakShortSystemResponse("native key press hit a blocker: \(error.localizedDescription)")
            }
            markRequestCompleted(
                route: "native_cua.press_key",
                executionStartedAt: executionStartedAt,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.pressKey",
                    "controller": "OpenClickyNativeComputerUseController",
                    "target": targetWindow.agentContextNote,
                    "key": request.key,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private func launchApplication(named appName: String) -> Bool {
        for bundleIdentifier in Self.applicationBundleIdentifiers(for: appName) {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                Self.openApplication(at: appURL, appName: appName)
                return true
            }
        }

        if let appURL = Self.standardApplicationURL(named: appName) {
            Self.openApplication(at: appURL, appName: appName)
            return true
        }

        return runOpenApplication(arguments: ["-a", appName])
    }

    private static func openApplication(at appURL: URL, appName: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "native_cua.open_app.activation_failed",
                    fields: [
                        "appName": appName,
                        "path": appURL.path,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func runOpenApplication(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments

        do {
            try process.run()
            return true
        } catch {
            print("OpenClicky app open failed for arguments \(arguments): \(error)")
            return false
        }
    }

    private func showTextModeInputAtCursor() {
        guard allPermissionsGranted else { return }
        guard !buddyDictationManager.isKeyboardShortcutSessionActiveOrFinalizing else { return }

        if !isClickyCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        textModeWindowManager.show(
            at: NSEvent.mouseLocation,
            submitText: { [weak self] submittedText in
                self?.submitTextModePrompt(submittedText)
            }
        )
    }

    private func submitTextModePrompt(_ submittedText: String) {
        let trimmedText = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let requestTiming = beginRequestTiming(source: "text_mode", text: trimmedText)
        activeRequestTiming = requestTiming
        defer { activeRequestTiming = nil }
        lastTranscript = trimmedText
        ClickyAnalytics.trackUserMessageSent(transcript: trimmedText)
        interruptCurrentVoiceResponse()
        clearDetectedElementLocation()

        if handleAgentCancellationRequestIfNeeded(from: trimmedText) {
            return
        }

        if handleAgentSelectionRequestIfNeeded(from: trimmedText, source: "text_mode") {
            return
        }

        if handleDirectComputerUseRequest(from: trimmedText, source: "text_mode") {
            return
        }

        if handleAgentStatusQuestionIfNeeded(from: trimmedText) {
            return
        }

        if startExplicitAgentTaskIfRequested(from: trimmedText) {
            return
        }

        if submitContextualAgentFollowUp(trimmedText, source: "text") {
            return
        }

        sendTranscriptToClaudeWithScreenshot(transcript: trimmedText)
    }

    private func submitPendingAgentVoiceFollowUp(_ transcript: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }
        guard let sessionID = pendingAgentVoiceFollowUpSessionID else { return false }
        pendingAgentVoiceFollowUpSessionID = nil
        pendingAgentVoiceFollowUpCreatedAt = nil
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "pending_voice_followup",
                "sessionID": sessionID.uuidString,
                "instructionLength": trimmedTranscript.count
            ]
        )

        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else {
            speakShortSystemResponse("i lost track of that agent. open the agent dock and try again.")
            markRequestCompleted(
                route: "agent.followup",
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "agent_mode",
                    "executionMethod": "CodexAgentSession.lookup",
                    "controller": "CompanionManager",
                    "source": "pending_voice_followup",
                    "sessionID": sessionID.uuidString,
                    "error": "Missing agent session"
                ]
            )
            return true
        }

        selectCodexAgentSession(sessionID)
        submitAgentPrompt(trimmedTranscript, to: session)
        lastAgentContextSessionID = sessionID
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "pending_voice_followup",
                "sessionID": sessionID.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
        speakShortSystemResponse("sent that to \(session.spokenAgentName).")
        return true
    }

    private func submitContextualAgentFollowUp(_ transcript: String, source: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }
        guard !Self.isExplicitNewTaskRequest(trimmedTranscript) else { return false }
        guard let session = latestSteerableAgentSession() else { return false }
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "instructionLength": trimmedTranscript.count
            ]
        )

        selectCodexAgentSession(session.id)
        submitAgentPrompt(trimmedTranscript, to: session)
        lastAgentContextSessionID = session.id
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_followup.steered",
            fields: [
                "sessionID": session.id.uuidString,
                "title": session.title,
                "source": source,
                "instruction": trimmedTranscript
            ]
        )
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
        speakShortSystemResponse("sent that to \(session.spokenAgentName).")
        return true
    }

    private func handleAgentSelectionRequestIfNeeded(from transcript: String, source: String) -> Bool {
        guard let request = Self.agentSelectionRequest(from: transcript) else { return false }
        let timing = activeRequestTiming
        let route = request.followUpText == nil ? "agent.select" : "agent.select_and_followup"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.selectCodexAgentSession",
                "controller": "CompanionManager",
                "source": source,
                "agentName": request.agentName,
                "hasFollowUpText": request.followUpText != nil
            ]
        )

        guard let session = agentSession(matchingSpokenName: request.agentName) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "error",
                event: "openclicky.agent_select.not_found",
                fields: [
                    "source": source,
                    "agentName": request.agentName,
                    "instruction": request.instruction
                ]
            )
            speakShortSystemResponse("i couldn't find an agent called \(request.agentName).")
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "agent_mode",
                    "executionMethod": "CompanionManager.agentSession",
                    "controller": "CompanionManager",
                    "source": source,
                    "agentName": request.agentName,
                    "error": "No matching agent session"
                ]
            )
            return true
        }

        selectCodexAgentSession(session.id)
        if isAdvancedModeEnabled {
            showCodexHUD()
        } else {
            showAgentDockWindowNearCurrentScreen()
        }

        var extra: [String: String] = [
            "source": source,
            "agentName": request.agentName,
            "sessionID": session.id.uuidString,
            "title": session.title
        ]
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_select.selected",
            fields: extra.merging([
                "instruction": request.instruction
            ]) { current, _ in current }
        )

        if let followUpText = request.followUpText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !followUpText.isEmpty {
            submitAgentPrompt(followUpText, to: session)
            extra["followUpTextLength"] = "\(followUpText.count)"
            speakShortSystemResponse("sent that to \(session.spokenAgentName).")
        } else {
            speakShortSystemResponse("switched to \(session.spokenAgentName).")
        }

        markRequestCompleted(
            route: route,
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: extra.merging([
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.selectCodexAgentSession",
                "controller": "CompanionManager"
            ]) { current, _ in current }
        )
        return true
    }

    private func agentSession(matchingSpokenName name: String) -> CodexAgentSession? {
        let needle = Self.normalizedAgentLookupText(name)
        guard !needle.isEmpty else { return nil }

        for dockItem in agentDockItems.reversed() {
            let title = Self.normalizedAgentLookupText(dockItem.title)
            guard title == needle || title.contains(needle) || needle.contains(title) else { continue }
            if let sessionID = dockItem.sessionID,
               let session = codexAgentSessions.first(where: { $0.id == sessionID }) {
                return session
            }
        }

        return codexAgentSessions.reversed().first { session in
            let title = Self.normalizedAgentLookupText(session.title)
            return title == needle || title.contains(needle) || needle.contains(title)
        }
    }

    private func latestSteerableAgentSession() -> CodexAgentSession? {
        if let activeSession = codexAgentSessions.first(where: { $0.id == activeCodexAgentSessionID }),
           Self.isSteerableAgentStatus(activeSession.status),
           activeSession.hasVisibleActivity {
            return activeSession
        }

        if let lastAgentContextSessionID,
           let lastContextSession = codexAgentSessions.first(where: { $0.id == lastAgentContextSessionID }),
           Self.isSteerableAgentStatus(lastContextSession.status),
           lastContextSession.hasVisibleActivity {
            return lastContextSession
        }

        for dockItem in agentDockItems.reversed() {
            guard let sessionID = dockItem.sessionID,
                  let session = codexAgentSessions.first(where: { $0.id == sessionID }),
                  Self.isSteerableAgentStatus(session.status),
                  session.hasVisibleActivity else {
                continue
            }
            return session
        }

        return nil
    }

    private static func isSteerableAgentStatus(_ status: CodexAgentSessionStatus) -> Bool {
        switch status {
        case .stopped:
            return false
        case .starting, .ready, .running, .failed:
            return true
        }
    }

    private func handleAgentCancellationRequestIfNeeded(from transcript: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }

        if Self.isCancelAllAgentTasksRequest(trimmedTranscript) {
            cancelAllAgentTasks()
            return true
        }

        if Self.isCancelCurrentAgentTaskRequest(trimmedTranscript) {
            cancelCurrentAgentTask()
            return true
        }

        return false
    }

    private func cancelAllAgentTasks() {
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.cancel_all",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.stop",
                "controller": "CodexAgentSession"
            ]
        )
        let sessionIDsToCancel = Set(agentDockItems.compactMap(\.sessionID))
        var cancelledCount = 0

        for session in codexAgentSessions {
            guard sessionIDsToCancel.contains(session.id) || Self.isSteerableAgentStatus(session.status) else {
                continue
            }
            session.stop()
            cancelledCount += 1
        }

        agentDockItems.removeAll()
        agentDockWindowManager.hide()
        pendingAgentVoiceFollowUpSessionID = nil
        pendingAgentVoiceFollowUpCreatedAt = nil
        lastAgentContextSessionID = nil
        scheduleWidgetSnapshotPublish()

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_tasks.cancelled_all",
            fields: [
                "count": cancelledCount
            ]
        )
        markRequestCompleted(
            route: "agent.cancel_all",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.stop",
                "controller": "CodexAgentSession",
                "cancelledCount": cancelledCount
            ]
        )

        let response: String
        if cancelledCount == 0 {
            response = "there aren't any active agent tasks to cancel."
        } else if cancelledCount == 1 {
            response = "cancelled the agent task."
        } else {
            response = "cancelled all agent tasks."
        }
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: response,
            contextTitle: "Agent tasks"
        )
        speakShortSystemResponse(response)
    }

    private func cancelCurrentAgentTask() {
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.cancel_current",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.stop",
                "controller": "CodexAgentSession"
            ]
        )
        guard let session = latestSteerableAgentSession() else {
            speakShortSystemResponse("there isn't an active agent task to cancel.")
            markRequestCompleted(
                route: "agent.cancel_current",
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "agent_mode",
                    "executionMethod": "latestSteerableAgentSession",
                    "controller": "CompanionManager",
                    "error": "No active agent task"
                ]
            )
            return
        }

        cancelAgentTask(sessionID: session.id, removeDockItems: true)
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.cancelled",
            fields: [
                "sessionID": session.id.uuidString,
                "title": session.title
            ]
        )
        markRequestCompleted(
            route: "agent.cancel_current",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.stop",
                "controller": "CodexAgentSession",
                "sessionID": session.id.uuidString,
                "title": session.title
            ]
        )
        speakShortSystemResponse("cancelled \(session.spokenAgentName).")
    }

    private func cancelAgentTask(sessionID: UUID, removeDockItems: Bool) {
        codexAgentSessions.first(where: { $0.id == sessionID })?.stop()
        completeAgentRequestTimingIfNeeded(sessionID: sessionID, status: "cancelled")
        if removeDockItems {
            agentDockItems.removeAll { $0.sessionID == sessionID }
        }
        if pendingAgentVoiceFollowUpSessionID == sessionID {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
        }
        if lastAgentContextSessionID == sessionID {
            lastAgentContextSessionID = nil
        }
        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }
        scheduleWidgetSnapshotPublish()
    }

    private func startExplicitAgentTaskIfRequested(from transcript: String) -> Bool {
        if let newTaskInstruction = Self.explicitNewTaskInstruction(from: transcript) {
            guard !newTaskInstruction.isEmpty else {
                speakShortSystemResponse("what should the new task be?")
                return true
            }

            startVoiceAgentTask(instruction: newTaskInstruction)
            return true
        }

        if Self.isIncompleteExplicitNewTaskRequest(from: transcript) {
            speakShortSystemResponse("what should the new task be?")
            return true
        }

        if let taskCreationInstruction = Self.agentTaskCreationInstruction(from: transcript) {
            guard !taskCreationInstruction.isEmpty else {
                speakShortSystemResponse("what should the agent do?")
                return true
            }

            if let typeRequest = Self.nativeTypeRequest(from: taskCreationInstruction) {
                typeTextUsingSelectedComputerUse(typeRequest)
                return true
            }

            if let keyPressRequest = Self.nativeKeyPressRequest(from: taskCreationInstruction) {
                pressKeyUsingSelectedComputerUse(keyPressRequest)
                return true
            }

            if let folderRequest = folderOpenRequest(from: taskCreationInstruction) {
                openRequestedFolder(folderRequest)
                return true
            }

            print("OpenClicky agent task creation request detected: \(taskCreationInstruction)")
            startVoiceAgentTask(instruction: taskCreationInstruction)
            return true
        }

        if Self.isIncompleteAgentTaskCreationRequest(from: transcript) {
            speakShortSystemResponse("what should the agent do?")
            return true
        }

        guard let explicitInstruction = Self.clickyAgentInstruction(from: transcript) else {
            return false
        }

        guard !explicitInstruction.isEmpty else {
            print("OpenClicky agent trigger detected without an instruction.")
            speakShortSystemResponse("say what you want the agent to do after the agent trigger.")
            return true
        }

        let instruction = Self.normalizedAgentTaskInstruction(from: explicitInstruction)
        if let typeRequest = Self.nativeTypeRequest(from: instruction) {
            typeTextUsingSelectedComputerUse(typeRequest)
            return true
        }

        if let keyPressRequest = Self.nativeKeyPressRequest(from: instruction) {
            pressKeyUsingSelectedComputerUse(keyPressRequest)
            return true
        }

        if let folderRequest = folderOpenRequest(from: instruction) {
            openRequestedFolder(folderRequest)
            return true
        }

        if let appOpenRequest = Self.localAppOpenRequest(from: instruction) {
            _ = openRequestedApplication(appOpenRequest)
            return true
        }
        if Self.isIncompleteLocalAppOpenRequest(from: instruction) {
            speakShortSystemResponse("what app should I open?")
            return true
        }

        print("OpenClicky agent task detected; starting agent task: \(instruction)")
        startVoiceAgentTask(instruction: instruction)
        return true
    }

    private static func isCancelAllAgentTasksRequest(_ transcript: String) -> Bool {
        let normalizedTranscript = normalizedSpokenCommandText(transcript)
        let phrases = [
            "cancel all tasks",
            "cancel all task",
            "cancel all agents",
            "cancel all agent tasks",
            "stop all tasks",
            "stop all agents",
            "stop all agent tasks",
            "kill all tasks",
            "kill all agents",
            "dismiss all tasks",
            "dismiss all agents",
            "clear all tasks",
            "clear all agents",
            "cancel everything",
            "stop everything",
            "kill everything"
        ]
        return phrases.contains { normalizedTranscript.contains($0) }
    }

    private static func isCancelCurrentAgentTaskRequest(_ transcript: String) -> Bool {
        let normalizedTranscript = normalizedSpokenCommandText(transcript)
        let phrases = [
            "cancel that",
            "cancel this",
            "cancel it",
            "cancel task",
            "cancel the task",
            "cancel current task",
            "cancel current agent",
            "cancel the agent",
            "cancel that agent",
            "stop that",
            "stop this",
            "stop it",
            "stop task",
            "stop the task",
            "stop current task",
            "stop current agent",
            "stop the agent",
            "kill that",
            "kill this",
            "kill it",
            "kill task",
            "kill the task",
            "done with that",
            "done with this"
        ]
        return phrases.contains { normalizedTranscript == $0 || normalizedTranscript.contains($0) }
    }

    private static func explicitNewTaskInstruction(from transcript: String) -> String? {
        let candidate = normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\s*(?:this\s+is\s+)?(?:a\s+)?(?:new|separate|different)\s+(?:agent\s+|codex\s+)?task\s*[:,-]?\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:start|create|spin\s+up|kick\s+off|launch)\s+(?:a\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+task\s*(?:to|for|that)?\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:new|separate|different)\s+(?:agent|codex)\s*(?:task|job|session)?\s*[:,-]?\s+(.+?)\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let instructionRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }
            let instruction = cleanedAgentTaskInstruction(String(candidate[instructionRange]))
            return isAgentTaskPlaceholderInstruction(instruction) ? nil : instruction
        }

        return nil
    }

    private static func isExplicitNewTaskRequest(_ transcript: String) -> Bool {
        explicitNewTaskInstruction(from: transcript) != nil || isIncompleteExplicitNewTaskRequest(from: transcript)
    }

    private static func isIncompleteExplicitNewTaskRequest(from transcript: String) -> Bool {
        let candidate = normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return false }

        let patterns = [
            #"(?i)^\s*(?:this\s+is\s+)?(?:a\s+)?(?:new|separate|different)\s+(?:agent\s+|codex\s+)?task[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:start|create|spin\s+up|kick\s+off|launch)\s+(?:a\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+task[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:new|separate|different)\s+(?:agent|codex)\s*(?:task|job|session)?[\s\.\!\?]*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            if regex.firstMatch(in: candidate, range: range) != nil {
                return true
            }
        }

        return false
    }

    private static func normalizedSpokenCommandText(_ transcript: String) -> String {
        transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func handleAgentStatusQuestionIfNeeded(from transcript: String) -> Bool {
        guard Self.isAgentStatusQuestion(transcript) else { return false }
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.status",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "agentStatusSpokenSummary",
                "controller": "CompanionManager"
            ]
        )

        let summary = agentStatusSpokenSummary()
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: summary,
            contextTitle: "Agent status"
        )
        if codexAgentSessions.contains(where: { $0.hasVisibleActivity }) {
            ensureCursorOverlayVisibleForAgentTask()
            showAgentDockWindowNearCurrentScreen()
        }
        speakShortSystemResponse(summary)
        markRequestCompleted(
            route: "agent.status",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "agentStatusSpokenSummary",
                "controller": "CompanionManager",
                "visibleAgentCount": codexAgentSessions.filter(\.hasVisibleActivity).count
            ]
        )
        return true
    }

    private func agentStatusSpokenSummary() -> String {
        let visibleSessions = codexAgentSessions.filter(\.hasVisibleActivity)
        guard !visibleSessions.isEmpty else {
            return "no agents are running yet."
        }

        let runningCount = visibleSessions.filter { session in
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }.count
        let failedCount = visibleSessions.filter { session in
            if case .failed = session.status { return true }
            return false
        }.count
        let readyCount = visibleSessions.filter { session in
            if case .ready = session.status { return true }
            return false
        }.count

        let headline: String
        if runningCount > 0 {
            headline = "\(Self.spokenCount(runningCount, singular: "agent", plural: "agents")) running"
        } else if failedCount > 0 {
            headline = "\(Self.spokenCount(failedCount, singular: "agent", plural: "agents")) needing attention"
        } else {
            headline = "\(Self.spokenCount(readyCount, singular: "agent", plural: "agents")) ready"
        }

        let details = visibleSessions
            .suffix(3)
            .map(\.statusSummaryLine)
            .joined(separator: " ")

        return "you have \(Self.spokenCount(visibleSessions.count, singular: "agent", plural: "agents")): \(headline). \(details)"
    }

    private func updateAgentProgressNarration() {
        let now = Date()
        if let lastAgentProgressNarrationAt,
           now.timeIntervalSince(lastAgentProgressNarrationAt) < 30 {
            return
        }

        speakAgentProgressUpdateIfAppropriate(now: now)
    }

    private func speakAgentProgressUpdateIfAppropriate(now: Date = Date()) {
        let runningSessions = codexAgentSessions.filter { session in
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }

        guard !runningSessions.isEmpty else { return }
        guard voiceState == .idle, !elevenLabsTTSClient.isPlaying else { return }

        let updateText: String
        if runningSessions.count == 1, let session = runningSessions.first {
            updateText = "\(session.spokenAgentSentenceName) says \(Self.agentProgressPhrase(for: session))."
        } else {
            let details = runningSessions
                .prefix(3)
                .map { "\($0.spokenAgentSentenceName) says \(Self.agentProgressPhrase(for: $0))" }
                .joined(separator: ". ")
            let remainingCount = runningSessions.count - min(runningSessions.count, 3)
            if remainingCount > 0 {
                updateText = "\(details). \(remainingCount) more running."
            } else {
                updateText = details + "."
            }
        }

        lastAgentProgressNarrationAt = now
        speakShortSystemResponse(updateText)
    }

    private static func agentProgressPhrase(for session: CodexAgentSession) -> String {
        if let activity = session.latestActivitySummary?.lowercased() {
            if activity.contains("matching files") || activity.contains("looking for") {
                return "we're checking the files"
            }
            if activity.contains("focusing") || activity.contains("showing") {
                return "we're opening what we found"
            }
            if activity.contains("checking the work") {
                return "we're checking the work"
            }
            if activity.contains("working") {
                return "we're working through it"
            }
            return "we're \(activity)"
        }

        switch session.status {
        case .starting:
            return "we're starting"
        case .running:
            return "we're working"
        case .ready:
            return "we're done"
        case .failed:
            return "we need attention"
        case .stopped:
            return "we're stopped"
        }
    }

    private static func isAgentStatusQuestion(_ transcript: String) -> Bool {
        let normalizedTranscript = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let mentionsAgent = normalizedTranscript.contains("agent") || normalizedTranscript.contains("agents") || normalizedTranscript.contains("codex")
        guard mentionsAgent else { return false }

        let statusPhrases = [
            "how are",
            "how is",
            "how's",
            "status",
            "progress",
            "doing",
            "running",
            "finished",
            "done",
            "up to",
            "working on",
            "what are",
            "what's"
        ]

        return statusPhrases.contains { normalizedTranscript.contains($0) }
    }

    private static func spokenCount(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? "one \(singular)" : "\(count) \(plural)"
    }

    private static func clickyAgentInstruction(from transcript: String) -> String? {
        struct TranscriptToken {
            let normalizedText: String
            let originalRange: Range<String.Index>
        }

        let foldedTranscript = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokenMatches = foldedTranscript.matches(of: /[A-Za-z0-9]+/)
        let tokens = tokenMatches.map { match in
            TranscriptToken(
                normalizedText: String(foldedTranscript[match.range]).lowercased(),
                originalRange: match.range
            )
        }

        guard !tokens.isEmpty else { return nil }

        for tokenIndex in tokens.indices {
            var scanningIndex = tokenIndex
            var sawHeyPrefix = false

            if tokens[scanningIndex].normalizedText == "hey" {
                sawHeyPrefix = true
                scanningIndex += 1
                guard scanningIndex < tokens.count else { continue }
            }

            if tokens[scanningIndex].normalizedText == "open" {
                scanningIndex += 1
                guard scanningIndex < tokens.count else { continue }
            }

            if tokens[scanningIndex].normalizedText == "agent", sawHeyPrefix {
                let rawInstruction = String(transcript[tokens[scanningIndex].originalRange.upperBound...])
                let trimmedInstruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanedInstruction = trimmedInstruction.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
                return cleanedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard isClickyInvocationToken(tokens[scanningIndex].normalizedText) else { continue }

            let agentTokenIndex = scanningIndex + 1
            guard agentTokenIndex < tokens.count else { continue }
            guard tokens[agentTokenIndex].normalizedText == "agent" else { continue }

            let rawInstruction = String(transcript[tokens[agentTokenIndex].originalRange.upperBound...])
            let trimmedInstruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedInstruction = trimmedInstruction.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
            return cleanedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private static func isClickyInvocationToken(_ normalizedText: String) -> Bool {
        switch normalizedText {
        case "clicky", "klicky", "openclicky":
            return true
        default:
            return false
        }
    }

    private static func normalizedAgentTaskInstruction(from instruction: String) -> String {
        let trimmedInstruction = normalizedCommandCandidate(from: instruction)
        guard !trimmedInstruction.isEmpty else { return trimmedInstruction }

        let pattern = #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+|please\s+|(?:ask|tell)\s+(?:an?\s+|the\s+)?agent\s+to\s+)(.+?)[\.\!\?]*\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmedInstruction,
                range: NSRange(trimmedInstruction.startIndex..<trimmedInstruction.endIndex, in: trimmedInstruction)
              ),
              let taskRange = Range(match.range(at: 1), in: trimmedInstruction) else {
            return trimmedInstruction
        }

        return String(trimmedInstruction[taskRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
    }

    static func agentTaskCreationInstruction(from transcript: String) -> String? {
        let candidate = normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:create|start|spin\s+up|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?\s+(?:to|for|that|which|who)?\s*(.+?)\s*$"#,
            #"(?i)^\s*(?:the\s+)?(?:agent|agenty|codex)\s+(?:create|start|spin\s+up|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|agenty|codex)?\s*(?:task|job|session)?\s*(?:to|for|that|which|who)?\s*(.+?)\s*$"#,
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:ask|tell|have|get)\s+(?:an?\s+|the\s+)?(?:agent|agenty|codex)\s+to\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:an?\s+|the\s+)?(?:new\s+|background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?\s+(?:to|for|that|which|who)\s+(.+?)\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let instructionRange = Range(match.range(at: 1), in: candidate) else { continue }
            let instruction = cleanedAgentTaskInstruction(String(candidate[instructionRange]))
            return isAgentTaskPlaceholderInstruction(instruction) ? nil : instruction
        }

        if let noisyInstruction = noisyAgentTaskCreationInstruction(from: candidate) {
            return noisyInstruction
        }

        return misheardQuestionAgentInstruction(from: candidate)
    }

    private static func misheardQuestionAgentInstruction(from candidate: String) -> String? {
        let pattern = #"(?i)^\s*(?:question|agent\s+question)\s*[:,-]?\s+(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        guard let match = regex.firstMatch(in: candidate, range: range),
              let instructionRange = Range(match.range(at: 1), in: candidate) else {
            return nil
        }

        let instruction = normalizedAgentTaskInstruction(
            from: cleanedAgentTaskInstruction(String(candidate[instructionRange]))
        )
        guard !instruction.isEmpty,
              !isAgentTaskPlaceholderInstruction(instruction),
              isLikelyAgentToolWorkInstruction(instruction) else {
            return nil
        }
        return instruction
    }

    private static func isLikelyAgentToolWorkInstruction(_ instruction: String) -> Bool {
        let normalized = normalizedSpokenCommandText(instruction)
        let toolWorkSignals = [
            "desktop",
            "download",
            "downloads",
            "document",
            "documents",
            "folder",
            "folders",
            "file",
            "files",
            "code",
            "repo",
            "repository",
            "diff",
            "changes",
            "log",
            "logs",
            "conversation logs",
            "clean up",
            "cleanup",
            "review",
            "inspect",
            "audit",
            "look at",
            "take a look",
            "find",
            "search"
        ]
        return toolWorkSignals.contains { normalized.contains($0) }
    }

    private static func noisyAgentTaskCreationInstruction(from candidate: String) -> String? {
        guard !isMetaAgentRoutingQuestion(candidate) else { return nil }

        let patterns = [
            #"(?i)(?:^|[\s,;:—–\-]+)(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:ask|tell|have|get)\s+(?:an?\s+|the\s+)?(?:new\s+|background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?\s+(?:to|for|that|which|who)\s+(.+?)\s*$"#,
            #"(?i)(?:^|[\s,;:—–\-]+)(?:send|route|hand|pass)\s+(?:this|that|it|the\s+(?:task|request|context|screen|file|code|change|changes))\s+(?:over\s+)?to\s+(?:an?\s+|the\s+)?(?:new\s+|background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?(?:\s+to)?\s+(.+?)\s*$"#,
            #"(?i)^\s*[\.…,;:—–\-]*\s*(?:an?\s+|the\s+)?(?:new\s+|background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?\s+(?:to|for|that|which|who)\s+(.+?)\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let instructionRange = Range(match.range(at: 1), in: candidate) else { continue }
            let instruction = cleanedAgentTaskInstruction(String(candidate[instructionRange]))
            return isAgentTaskPlaceholderInstruction(instruction) ? nil : instruction
        }

        return nil
    }

    private static func isMetaAgentRoutingQuestion(_ candidate: String) -> Bool {
        let normalized = normalizedSpokenCommandText(candidate)
        let prefixes = [
            "how do i ask",
            "how can i ask",
            "how should i ask",
            "what do i say",
            "what should i say",
            "why did",
            "why didnt",
            "why didn t",
            "why didn't",
            "why doesnt",
            "why doesn t",
            "why doesn't",
            "when i asked",
            "when i ask"
        ]
        return prefixes.contains { normalized.hasPrefix($0) }
    }

    private static func isIncompleteAgentTaskCreationRequest(from transcript: String) -> Bool {
        let candidate = normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return false }

        let patterns = [
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:create|start|spin\s+up|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|codex)\s*(?:task|job|session)?[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:the\s+)?(?:agent|codex)\s+(?:create|start|spin\s+up|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|codex)?\s*(?:task|job|session)?[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:ask|tell|have|get)\s+(?:an?\s+|the\s+)?(?:agent|codex)(?:\s+to)?[\s\.\!\?]*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            if regex.firstMatch(in: candidate, range: range) != nil {
                return true
            }
        }

        return false
    }

    private static func cleanedAgentTaskInstruction(_ instruction: String) -> String {
        instruction
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAgentTaskPlaceholderInstruction(_ instruction: String) -> Bool {
        let normalized = instruction
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ["agent", "task", "job", "session", "agent task", "agent job", "codex task"].contains(normalized)
    }

    private static func agentSelectionRequest(from transcript: String) -> OpenClickyAgentSelectionRequest? {
        let candidate = normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let typedFollowUpPatterns = [
            #"(?i)^\s*(?:open|show|select|switch\s+to|go\s+to|bring\s+up)\s+(?:the\s+)?(.+?)\s+agent\s+and\s+(?:type|write|enter)\s+(.+?)(?:\s+(?:in|into)\s+(?:the\s+)?(?:prompt|input)(?:\s+area|box|field)?)?[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:open|show|select|switch\s+to|go\s+to|bring\s+up)\s+(?:agent\s+)?(.+?)\s+and\s+(?:type|write|enter)\s+(.+?)(?:\s+(?:in|into)\s+(?:the\s+)?(?:prompt|input)(?:\s+area|box|field)?)?[\.\!\?]*\s*$"#
        ]

        for pattern in typedFollowUpPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let nameRange = Range(match.range(at: 1), in: candidate),
                  let textRange = Range(match.range(at: 2), in: candidate) else {
                continue
            }

            let agentName = cleanedAgentSelectionName(String(candidate[nameRange]))
            let followUpText = cleanedAgentSelectionFollowUp(String(candidate[textRange]))
            guard !agentName.isEmpty, !followUpText.isEmpty else { continue }
            return OpenClickyAgentSelectionRequest(
                agentName: agentName,
                followUpText: followUpText,
                instruction: candidate
            )
        }

        let selectionPatterns = [
            #"(?i)^\s*(?:open|show|select|switch\s+to|go\s+to|bring\s+up)\s+(?:the\s+)?(.+?)\s+agent[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:open|show|select|switch\s+to|go\s+to|bring\s+up)\s+agent\s+(.+?)[\.\!\?]*\s*$"#
        ]

        for pattern in selectionPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let nameRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }

            let agentName = cleanedAgentSelectionName(String(candidate[nameRange]))
            guard !agentName.isEmpty else { continue }
            return OpenClickyAgentSelectionRequest(
                agentName: agentName,
                followUpText: nil,
                instruction: candidate
            )
        }

        return nil
    }

    private static func cleanedAgentSelectionName(_ rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
        name = stripMatchingQuotes(from: name)
        name = name.replacingOccurrences(
            of: #"(?i)^(?:the|a|an)\s+"#,
            with: "",
            options: .regularExpression
        )
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
        return isAgentTaskPlaceholderInstruction(name) ? "" : name
    }

    private static func cleanedAgentSelectionFollowUp(_ rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
        text = text.replacingOccurrences(
            of: #"(?i)\s+(?:in|into)\s+(?:the\s+)?(?:prompt|input)(?:\s+area|box|field)?$"#,
            with: "",
            options: .regularExpression
        )
        text = stripMatchingQuotes(from: text)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
    }

    private static func normalizedAgentLookupText(_ value: String) -> String {
        normalizedSpokenCommandText(value)
            .replacingOccurrences(of: #"\b(?:agent|task|session)\b"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func localAppOpenRequest(from transcript: String) -> OpenClickyAppOpenRequest? {
        let trimmedTranscript = normalizedCommandCandidate(from: transcript)
        guard !trimmedTranscript.isEmpty else { return nil }
        guard !isAgentRoutingCandidate(trimmedTranscript) else { return nil }

        let pattern = #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:(?:ask|tell)\s+(?:an?\s+|the\s+)?agent\s+to\s+)?(?:open|launch|start|switch\s+to)\s+(?:up\s+)?(.+?)(?:\s+for\s+me)?[\.\!\?]*\s*$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(
            in: trimmedTranscript,
            range: NSRange(trimmedTranscript.startIndex..<trimmedTranscript.endIndex, in: trimmedTranscript)
           ),
           let targetRange = Range(match.range(at: 1), in: trimmedTranscript) {
            let rawTarget = String(trimmedTranscript[targetRange])
            let normalizedTarget = normalizedApplicationName(from: rawTarget)
            guard !normalizedTarget.isEmpty,
                  !isReservedAgentOpenTarget(rawTarget),
                  !isLocalAppOpenPlaceholder(normalizedTarget),
                  !isLikelyFileOrFolderOpenTarget(rawTarget),
                  !isLikelyWebOpenTarget(rawTarget) else {
                return nil
            }

            return OpenClickyAppOpenRequest(
                appName: normalizedTarget,
                instruction: "Open \(normalizedTarget)."
            )
        }

        return bareLocalAppOpenRequest(fromNormalizedCandidate: trimmedTranscript)
    }

    private static func bareLocalAppOpenRequest(from transcript: String) -> OpenClickyAppOpenRequest? {
        let candidate = normalizedCommandCandidate(from: transcript)
        return bareLocalAppOpenRequest(fromNormalizedCandidate: candidate)
    }

    private static func bareLocalAppOpenRequest(fromNormalizedCandidate candidate: String) -> OpenClickyAppOpenRequest? {
        let rawTarget = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
        guard !rawTarget.isEmpty,
              !isAgentRoutingCandidate(rawTarget),
              !isReservedAgentOpenTarget(rawTarget),
              !isLikelyFileOrFolderOpenTarget(rawTarget),
              !isLikelyWebOpenTarget(rawTarget) else {
            return nil
        }

        let normalizedTarget = normalizedApplicationName(from: rawTarget)
        guard isKnownBareLocalApplicationName(normalizedTarget),
              !isLocalAppOpenPlaceholder(normalizedTarget) else {
            return nil
        }

        return OpenClickyAppOpenRequest(
            appName: normalizedTarget,
            instruction: "Open \(normalizedTarget)."
        )
    }

    private static func isKnownBareLocalApplicationName(_ appName: String) -> Bool {
        switch appName {
        case "Google Chrome",
            "Safari",
            "Xcode",
            "Terminal",
            "Finder",
            "System Settings",
            "Mail",
            "Messages",
            "Notes",
            "Reminders",
            "Calendar",
            "Slack",
            "Cursor",
            "Codex":
            return true
        default:
            return false
        }
    }

    private static func reminderAddRequest(from transcript: String) -> OpenClickyReminderAddRequest? {
        let candidate = normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let normalizedCandidate = normalizedSpokenCommandText(candidate)
        let mentionsReminders = normalizedCandidate.contains("reminder")
            || normalizedCandidate.contains("reminders")
            || normalizedCandidate.contains("todo")
            || normalizedCandidate.contains("to do")
            || normalizedCandidate.contains("task")
        guard mentionsReminders else { return nil }

        let hasAddAction = normalizedCandidate.contains("add")
            || normalizedCandidate.contains("create")
            || normalizedCandidate.contains("make")
            || normalizedCandidate.contains("set")
            || normalizedCandidate.hasPrefix("remind me")
        guard hasAddAction else { return nil }

        let titlePatterns = [
            #"(?i)\b(?:just\s+)?(?:call\s+it|called|named|saying|that\s+says|with\s+title)\s+(.+?)\s*$"#,
            #"(?i)^\s*remind\s+me\s+to\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:add|create|make|set)\s+(?:a\s+|an\s+|the\s+)?(?:new\s+|test\s+)?(?:reminder|task|todo|to-do)(?:\s+(?:in|to|on)\s+(?:my\s+)?(?:apple\s+)?reminders?(?:\s+app)?)?(?:\s+(?:to|for)\s+)?(.+?)\s*$"#,
            #"(?i)^\s*(?:add|create|make)\s+(.+?)\s+(?:to|in|on)\s+(?:my\s+)?(?:apple\s+)?reminders?(?:\s+app)?\s*$"#
        ]

        for pattern in titlePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let titleRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }

            let title = cleanedReminderTitle(String(candidate[titleRange]))
            guard !title.isEmpty, !isReminderTitlePlaceholder(title) else { continue }
            return OpenClickyReminderAddRequest(title: title, instruction: candidate)
        }

        return nil
    }

    private static func reminderCountRequest(from transcript: String) -> OpenClickyReminderCountRequest? {
        let candidate = normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let normalizedCandidate = normalizedSpokenCommandText(candidate)
        guard normalizedCandidate.contains("reminder")
            || normalizedCandidate.contains("reminders")
            || normalizedCandidate.contains("todo")
            || normalizedCandidate.contains("to do")
            || normalizedCandidate.contains("tasks") else {
            return nil
        }

        let countSignals = [
            "how many",
            "count",
            "number of",
            "what reminders",
            "what tasks",
            "what todos",
            "do i have"
        ]
        guard countSignals.contains(where: { normalizedCandidate.contains($0) }) else { return nil }

        return OpenClickyReminderCountRequest(instruction: candidate)
    }

    private static func messagesSearchRequest(from transcript: String) -> OpenClickyMessagesSearchRequest? {
        let candidate = normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let normalizedCandidate = normalizedSpokenCommandText(candidate)
        guard normalizedCandidate.contains("message") || normalizedCandidate.contains("messages") else {
            return nil
        }
        guard normalizedCandidate.contains("from") || normalizedCandidate.contains("with") else {
            return nil
        }

        let patterns = [
            #"(?i)\bmessages?\s+from\s+(.+?)(?:\s+(?:today|this\s+morning|this\s+afternoon|this\s+evening|tonight|yesterday))?[\.\!\?]*\s*$"#,
            #"(?i)\bmessages?\s+with\s+(.+?)(?:\s+(?:today|this\s+morning|this\s+afternoon|this\s+evening|tonight|yesterday))?[\.\!\?]*\s*$"#,
            #"(?i)\bfrom\s+(.+?)\s+(?:in|on)\s+messages?[\.\!\?]*\s*$"#,
            #"(?i)\bfrom\s+(.+?)(?:\s+(?:today|this\s+morning|this\s+afternoon|this\s+evening|tonight|yesterday))[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let personRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }

            let personName = cleanedMessagesSearchName(String(candidate[personRange]))
            guard !personName.isEmpty, !isMessagesSearchPlaceholder(personName) else { continue }
            return OpenClickyMessagesSearchRequest(personName: personName, instruction: candidate)
        }

        return nil
    }

    private static func localFolderOpenRequest(from transcript: String) -> OpenClickyFolderOpenRequest? {
        let trimmedTranscript = normalizedCommandCandidate(from: transcript)
        guard !trimmedTranscript.isEmpty else { return nil }

        let normalizedTranscript = trimmedTranscript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard Self.containsFolderOpenVerb(normalizedTranscript) else {
            return nil
        }

        let sourceFolderTerms = [
            "source code folder",
            "source folder",
            "code folder",
            "project folder",
            "openclicky folder",
            "open clicky folder",
            "clicky folder",
            "repo folder",
            "repository folder",
            "openclicky source",
            "open clicky source"
        ]

        if sourceFolderTerms.contains(where: { normalizedTranscript.contains($0) }),
           let sourceURL = existingOpenClickySourceDirectoryURL() {
            return OpenClickyFolderOpenRequest(
                url: sourceURL,
                displayName: "the source code folder",
                instruction: trimmedTranscript
            )
        }

        if let rememberedShortcut = OpenClickyDirectActionMemoryStore.shared.folderShortcut(matching: normalizedTranscript) {
            return OpenClickyFolderOpenRequest(
                url: rememberedShortcut.url,
                displayName: rememberedShortcut.displayName,
                instruction: trimmedTranscript
            )
        }

        return nil
    }

    private static func containsFolderOpenVerb(_ normalizedTranscript: String) -> Bool {
        let openSignals = [
            "open",
            "show",
            "reveal",
            "switch to",
            "bring up",
            "pull up",
            "go into",
            "go in",
            "go to",
            "navigate to",
            "inside"
        ]

        return openSignals.contains { normalizedTranscript.contains($0) }
    }

    private static func relativeFolderOpenRequest(
        from transcript: String,
        baseURL: URL,
        fileManager: FileManager = .default
    ) -> OpenClickyFolderOpenRequest? {
        let trimmedTranscript = normalizedCommandCandidate(from: transcript)
        guard !trimmedTranscript.isEmpty else { return nil }

        let normalizedTranscript = normalizedFolderCommandText(trimmedTranscript)
        guard containsFolderOpenVerb(normalizedTranscript) else { return nil }

        let targetName = relativeFolderTargetName(from: normalizedTranscript)
        guard !targetName.isEmpty else { return nil }

        let directCandidate = baseURL.appendingPathComponent(targetName, isDirectory: true)
        if existingDirectoryURL(directCandidate, fileManager: fileManager) != nil {
            return OpenClickyFolderOpenRequest(
                url: directCandidate,
                displayName: "\(targetName) folder",
                instruction: trimmedTranscript
            )
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let normalizedTargetName = normalizedFolderName(targetName)
        for child in children {
            guard existingDirectoryURL(child, fileManager: fileManager) != nil else { continue }
            let childName = child.lastPathComponent
            if normalizedFolderName(childName) == normalizedTargetName {
                return OpenClickyFolderOpenRequest(
                    url: child,
                    displayName: "\(childName) folder",
                    instruction: trimmedTranscript
                )
            }
        }

        return nil
    }

    private static func relativeFolderTargetName(from normalizedTranscript: String) -> String {
        if let namedFolder = namedFolderTarget(from: normalizedTranscript) {
            return namedFolder
        }

        var target = normalizedTranscript
        let prefixes = [
            "can you",
            "could you",
            "would you",
            "will you",
            "please",
            "now"
        ]
        for prefix in prefixes where target.hasPrefix(prefix + " ") {
            target.removeFirst(prefix.count)
            target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let commandPrefixes = [
            "go into the",
            "go into",
            "go in the",
            "go in",
            "go to the",
            "go to",
            "navigate to the",
            "navigate to",
            "open the",
            "open",
            "show the",
            "show",
            "reveal the",
            "reveal",
            "inside the",
            "inside"
        ]

        for prefix in commandPrefixes where target.hasPrefix(prefix + " ") {
            target.removeFirst(prefix.count)
            target = target.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        let suffixes = [
            "folder",
            "directory",
            "in there",
            "there",
            "please"
        ]
        var didStripSuffix = true
        while didStripSuffix {
            didStripSuffix = false
            for suffix in suffixes where target == suffix || target.hasSuffix(" " + suffix) {
                target.removeLast(suffix.count)
                target = target.trimmingCharacters(in: .whitespacesAndNewlines)
                didStripSuffix = true
            }
        }

        return target
    }

    private static func namedFolderTarget(from normalizedTranscript: String) -> String? {
        let patterns = [
            #"(?i)(?:go into|go in|go to|navigate to|open|show|reveal)\s+(?:the\s+)?(.+?)\s+(?:folder|directory)(?:\s+(?:open|open up|please|there|in there))*$"#,
            #"(?i)(?:in|inside)\s+(?:that|this|the)\s+folder\s+(?:there(?:'s| is)?\s+)?(?:a\s+|an\s+|the\s+)?(.+?)\s+(?:folder|directory)(?:\s+(?:open|open up|please|there|in there))*$"#,
            #"(?i)(?:there(?:'s| is)?\s+)?(?:a\s+|an\s+|the\s+)?(.+?)\s+(?:folder|directory)\s+(?:open|open up)(?:\s+please)?$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalizedTranscript.startIndex..<normalizedTranscript.endIndex, in: normalizedTranscript)
            guard let match = regex.firstMatch(in: normalizedTranscript, range: range),
                  let targetRange = Range(match.range(at: 1), in: normalizedTranscript) else {
                continue
            }

            let target = String(normalizedTranscript[targetRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty {
                return folderSpeechAlias(for: target)
            }
        }

        return nil
    }

    private static func normalizedFolderCommandText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s_-]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedFolderName(_ value: String) -> String {
        folderSpeechAlias(for: normalizedFolderCommandText(value))
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func folderSpeechAlias(for value: String) -> String {
        let normalized = normalizedFolderCommandText(value)
        switch normalized {
        case "script", "scripps":
            return "scripts"
        default:
            return normalized
        }
    }

    private static func existingDirectoryURL(_ url: URL, fileManager: FileManager) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private static func existingOpenClickySourceDirectoryURL(fileManager: FileManager = .default) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Users/jkneen/Documents/GitHub/openclicky",
            "\(home)/Documents/GitHub/openclicky"
        ]

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: candidate, isDirectory: true)
            }
        }

        return nil
    }

    private static func directComputerUseFingerprint(kind: String, value: String) -> String {
        let normalizedValue = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(kind):\(normalizedValue)"
    }

    private static func shouldDeferLiveComputerUseForAgentRoute(_ transcript: String) -> Bool {
        isAgentRoutingCandidate(transcript)
    }

    private static func isAgentRoutingCandidate(_ transcript: String) -> Bool {
        explicitNewTaskInstruction(from: transcript) != nil
            || isIncompleteExplicitNewTaskRequest(from: transcript)
            || agentTaskCreationInstruction(from: transcript) != nil
            || isIncompleteAgentTaskCreationRequest(from: transcript)
            || clickyAgentInstruction(from: transcript) != nil
    }

    private static func isPotentialDirectComputerUseTranscript(_ transcript: String) -> Bool {
        let normalizedTranscript = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let directSignals = [
            "open",
            "show",
            "reveal",
            "switch",
            "press",
            "hit",
            "tap",
            "type",
            "write",
            "enter",
            "paste",
            "folder",
            "source",
            "code",
            "clicky",
            "openclicky"
        ]

        return directSignals.contains { normalizedTranscript.contains($0) }
    }

    private static func isIncompleteLocalAppOpenRequest(from transcript: String) -> Bool {
        let candidate = normalizedCommandCandidate(from: transcript)
        let pattern = #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:(?:ask|tell)\s+(?:an?\s+|the\s+)?agent\s+to\s+)?(?:open|launch|start|switch\s+to)(?:\s+up)?[\s\.\!\?]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return regex.firstMatch(in: candidate, range: range) != nil
    }

    private static func normalizedCommandCandidate(from transcript: String) -> String {
        var candidate = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixPatterns = [
            #"(?i)^\s*(?:hey|ok|okay|right|so)[\s,]+"#,
            #"(?i)^\s*(?:clicky|openclicky)[\s,]+"#,
            #"(?i)^\s*i\s+(?:said|asked|told)\s+(?:for\s+you\s+to|you\s+to|to)\s+"#,
            #"(?i)^\s*(?:let's|lets)\s+try\s+(?:that|this)\s+again[\s,]+"#
        ]

        var didStripPrefix = true
        while didStripPrefix {
            didStripPrefix = false
            for pattern in prefixPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
                guard let match = regex.firstMatch(in: candidate, range: range),
                      let matchRange = Range(match.range, in: candidate) else { continue }
                candidate.removeSubrange(matchRange)
                candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                didStripPrefix = true
            }
        }

        return candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-–—…"))
    }

    private static func normalizedApplicationName(from rawTarget: String) -> String {
        var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        target = target.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?-–— "))
        target = target.replacingOccurrences(
            of: #"(?i)^(?:my|the|a|an)\s+"#,
            with: "",
            options: .regularExpression
        )
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)

        let removableSuffixes = [" app", " application"]
        for suffix in removableSuffixes where target.localizedCaseInsensitiveContains(suffix) {
            if target.lowercased().hasSuffix(suffix) {
                target.removeLast(suffix.count)
                target = target.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let lowered = target.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        switch lowered {
        case "chrome", "google chrome":
            return "Google Chrome"
        case "safari":
            return "Safari"
        case "xcode":
            return "Xcode"
        case "terminal":
            return "Terminal"
        case "finder":
            return "Finder"
        case "settings", "system settings":
            return "System Settings"
        case "mail":
            return "Mail"
        case "messages":
            return "Messages"
        case "notes":
            return "Notes"
        case "reminders":
            return "Reminders"
        case "calendar":
            return "Calendar"
        case "slack":
            return "Slack"
        case "cursor":
            return "Cursor"
        case "codex":
            return "Codex"
        default:
            return target
        }
    }

    private static func cleanedReminderTitle(_ rawTitle: String) -> String {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
        title = stripMatchingQuotes(from: title)
        title = title.replacingOccurrences(
            of: #"(?i)^(?:a\s+|an\s+|the\s+)?(?:reminder|task|todo|to-do)\s+(?:to|for)\s+"#,
            with: "",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)[,\s]+(?:please|thanks|thank\s+you)$"#,
            with: "",
            options: .regularExpression
        )
        return title.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
    }

    private static func isReminderTitlePlaceholder(_ value: String) -> Bool {
        let normalized = normalizedSpokenCommandText(value)
        return [
            "",
            "it",
            "this",
            "that",
            "something",
            "a reminder",
            "a task",
            "test"
        ].contains(normalized)
    }

    private static func cleanedMessagesSearchName(_ rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
        name = stripMatchingQuotes(from: name)
        name = name.replacingOccurrences(
            of: #"(?i)[,\s]+(?:please|okay|ok|thanks|thank\s+you)$"#,
            with: "",
            options: .regularExpression
        )
        return name.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
    }

    private static func isMessagesSearchPlaceholder(_ value: String) -> Bool {
        let normalized = normalizedSpokenCommandText(value)
        return ["", "someone", "somebody", "anyone", "people", "them", "him", "her"].contains(normalized)
    }

    private static func nativeAutomationErrorMessage(
        appName: String,
        result: OpenClickyLocalAutomationResult
    ) -> String {
        let detail = result.errorOutput.isEmpty ? result.output : result.errorOutput
        let normalizedDetail = detail
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        if normalizedDetail.contains("not authorized")
            || normalizedDetail.contains("not permitted")
            || normalizedDetail.contains("not allowed")
            || normalizedDetail.contains("errAEEventNotPermitted".lowercased()) {
            return "macOS blocked \(appName) automation. enable OpenClicky for \(appName) in System Settings."
        }

        let shortDetail = detail
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
        return "\(appName) automation hit a blocker: \(shortDetail)"
    }

    private static func isLocalAppOpenPlaceholder(_ value: String) -> Bool {
        let normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenNormalized = normalizedSpokenCommandText(value)
        return ["", "my", "the", "a", "an", "it", "that", "this"].contains(normalized)
            || ["", "my", "the", "a", "an", "it", "that", "this"].contains(spokenNormalized)
    }

    private static func isReservedAgentOpenTarget(_ value: String) -> Bool {
        let normalized = normalizedSpokenCommandText(value)
        let stripped = normalized.replacingOccurrences(
            of: #"^(?:my|the|a|an)\s+"#,
            with: "",
            options: .regularExpression
        )

        if ["", "agent", "agents", "agent task", "agent job", "agent session"].contains(stripped) {
            return true
        }
        return stripped.hasPrefix("agent ")
            || stripped.hasPrefix("agents ")
            || stripped.hasSuffix(" agent")
            || stripped.hasSuffix(" agents")
            || stripped.hasSuffix(" agent task")
            || stripped.hasSuffix(" agent job")
            || stripped.hasSuffix(" agent session")
            || stripped.hasPrefix("codex task ")
            || stripped.hasPrefix("codex job ")
            || stripped.hasPrefix("codex session ")
    }

    private static func isLikelyFileOrFolderOpenTarget(_ value: String) -> Bool {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains(".") {
            return true
        }

        let normalized = normalizedFolderCommandText(value)
        if normalized.contains(" folder") || normalized.contains(" directory") {
            return true
        }
        if normalized.contains(" file") || normalized.contains(" in ") || normalized.contains(" inside ") {
            return true
        }
        return false
    }

    private static func isLikelyWebOpenTarget(_ value: String) -> Bool {
        let raw = value.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-–—"))
        guard !raw.isEmpty else { return false }

        let lowered = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("www.") {
            return true
        }
        if lowered.range(of: #"\b[a-z0-9-]+(?:\.[a-z0-9-]+)+\b"#, options: .regularExpression) != nil {
            return true
        }

        let normalized = normalizedSpokenCommandText(raw)
        let navigationSignals = [
            " go to ",
            " browse to ",
            " navigate to ",
            " visit ",
            " website",
            " webpage",
            " web page",
            " url"
        ]
        return navigationSignals.contains { " \(normalized) ".contains($0) }
    }

    private static func nativeTypeRequest(from transcript: String) -> OpenClickyNativeTypeRequest? {
        let candidate = normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:type|write|enter|input)\s+(?:into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field|text\s+field)\s+(.+?)[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:type|write|enter|input)\s+(.+?)(?:\s+(?:into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field|text\s+field))?[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?paste\s+(?:into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field|text\s+field)\s+(.+?)[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?paste\s+(.+?)(?:\s+(?:into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field|text\s+field))?[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let textRange = Range(match.range(at: 1), in: candidate) else { continue }

            var text = String(candidate[textRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!? "))

            text = stripMatchingQuotes(from: text)
            guard !text.isEmpty, !isTypePlaceholder(text) else { return nil }

            return OpenClickyNativeTypeRequest(
                text: text,
                targetDescription: candidate
            )
        }

        return nil
    }

    private static func stripMatchingQuotes(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last else {
            return trimmed
        }

        let quotePairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("“", "”"),
            ("‘", "’")
        ]

        for pair in quotePairs where first == pair.0 && last == pair.1 {
            return String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    private static func isTypePlaceholder(_ value: String) -> Bool {
        let normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return [
            "something",
            "text",
            "this",
            "that",
            "into the window",
            "in the window",
            "into the field",
            "in the field"
        ].contains(normalized)
    }

    private static func nativeKeyPressRequest(from transcript: String) -> OpenClickyNativeKeyPressRequest? {
        let candidate = normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:press|hit|tap)\s+(.+?)(?:\s+(?:in|into)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field))?[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:send)\s+(?:the\s+)?(.+?)\s+key(?:\s+(?:to|into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field))?[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let keyRange = Range(match.range(at: 1), in: candidate) else { continue }

            let rawKeySpec = String(candidate[keyRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?"))
            guard let parsed = parsedNativeKeySpec(from: rawKeySpec) else { return nil }

            return OpenClickyNativeKeyPressRequest(
                key: parsed.key,
                modifiers: parsed.modifiers,
                targetDescription: candidate
            )
        }

        return nil
    }

    private static func parsedNativeKeySpec(from rawKeySpec: String) -> (key: String, modifiers: [String])? {
        let normalizedKeySpec = rawKeySpec
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: " plus ", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard !normalizedKeySpec.isEmpty else { return nil }

        var modifiers: [String] = []
        var keyTokens: [String] = []
        for token in normalizedKeySpec {
            switch token {
            case "cmd", "command":
                modifiers.append("command")
            case "ctrl", "control":
                modifiers.append("control")
            case "option", "alt":
                modifiers.append("option")
            case "shift":
                modifiers.append("shift")
            case "the", "key":
                break
            default:
                keyTokens.append(token)
            }
        }

        let key = keyTokens.joined()
        guard !key.isEmpty, !["key", "button"].contains(key) else { return nil }
        return (key: normalizedNativeKeyName(key), modifiers: modifiers)
    }

    private static func normalizedNativeKeyName(_ key: String) -> String {
        switch key {
        case "return":
            return "enter"
        case "spacebar":
            return "space"
        case "backspace":
            return "delete"
        case "leftarrow":
            return "left"
        case "rightarrow":
            return "right"
        case "uparrow":
            return "up"
        case "downarrow":
            return "down"
        default:
            return key
        }
    }

    private static func applicationBundleIdentifiers(for appName: String) -> [String] {
        switch appName {
        case "Google Chrome":
            return ["com.google.Chrome"]
        case "Safari":
            return ["com.apple.Safari"]
        case "Xcode":
            return ["com.apple.dt.Xcode"]
        case "Terminal":
            return ["com.apple.Terminal"]
        case "Finder":
            return ["com.apple.finder"]
        case "System Settings":
            return ["com.apple.SystemSettings", "com.apple.systempreferences"]
        case "Mail":
            return ["com.apple.mail"]
        case "Messages":
            return ["com.apple.MobileSMS"]
        case "Notes":
            return ["com.apple.Notes"]
        case "Reminders":
            return ["com.apple.reminders"]
        case "Calendar":
            return ["com.apple.iCal"]
        case "Slack":
            return ["com.tinyspeck.slackmacgap"]
        default:
            return []
        }
    }

    private static func activateRunningApplication(named appName: String) {
        for bundleIdentifier in applicationBundleIdentifiers(for: appName) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }

    private static func standardApplicationURL(named appName: String) -> URL? {
        let applicationDirectories = [
            "/Applications",
            "/System/Applications",
            "\(NSHomeDirectory())/Applications"
        ]

        return applicationDirectories
            .map { URL(fileURLWithPath: $0).appendingPathComponent("\(appName).app", isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func legacyClickyAgentInstruction(from transcript: String) -> String? {
        let triggerPattern = #"\b(?:hey[\s,]+)?(?:open[\s,.-]*)?clicky[\s,.-]+agent\b"#
        guard let triggerRange = transcript.range(
            of: triggerPattern,
            options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]
        ) else {
            return nil
        }

        let rawInstruction = String(transcript[triggerRange.upperBound...])
        let trimmedInstruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedInstruction = trimmedInstruction.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
        return cleanedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startVoiceAgentTask(instruction: String, acknowledgement: String? = nil) {
        if handleDirectComputerUseRequest(from: instruction, source: "agent_task_boundary") {
            let cueText = directComputerUseAgentBoundaryCueText()
            ensureCursorOverlayVisibleForAgentTask()
            showDirectComputerUseDockCue(caption: cueText)
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: cueText,
                contextTitle: "OpenClicky Direct Control"
            )
            flyBuddyTowardAgentDock(acknowledgement: cueText)
            showAgentDockWindowNearCurrentScreen()
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.intercepted_direct_computer_use",
                fields: [
                    "instruction": instruction,
                    "selectedComputerUseBackend": selectedComputerUseBackend.rawValue,
                    "selectedComputerUseExecutor": selectedComputerUseBackend.executorID,
                    "selectedComputerUseLabel": selectedComputerUseBackend.label
                ]
            )
            return
        }

        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.start",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "instructionLength": instruction.count
            ]
        )
        interruptCurrentVoiceResponse()
        ensureCursorOverlayVisibleForAgentTask()

        let dockItemID = UUID()
        let acknowledgement = acknowledgement ?? "got it. i started an agent for \(Self.shortAgentInstructionSummary(instruction))."
        let accentTheme = Self.nextAgentDockAccentTheme(existingCount: codexAgentSessions.count)
        let agentSession = createAndSelectNewCodexAgentSession(
            title: Self.shortAgentInstructionSummary(instruction),
            accentTheme: accentTheme
        )
        if let timing {
            agentRequestTimingsBySessionID[agentSession.id] = timing
        }
        agentExecutionStartDatesBySessionID[agentSession.id] = executionStartedAt
        let dockItem = ClickyAgentDockItem(
            id: dockItemID,
            sessionID: agentSession.id,
            title: Self.shortAgentInstructionSummary(instruction),
            accentTheme: accentTheme,
            status: .starting,
            caption: acknowledgement,
            createdAt: Date()
        )

        agentDockItems.append(dockItem)
        if agentDockItems.count > 6 {
            agentDockItems.removeFirst(agentDockItems.count - 6)
        }
        scheduleWidgetSnapshotPublish()
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "openclicky.agent_task.created",
            fields: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "model": agentSession.model,
                "sessionID": agentSession.id.uuidString,
                "title": agentSession.title,
                "instruction": instruction,
                "requestID": timing?.requestID ?? "none"
            ]
        )
        markRequestStageCompleted(
            route: "agent.start",
            stage: "agent_created",
            stageStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "createAndSelectNewCodexAgentSession",
                "controller": "CompanionManager",
                "model": agentSession.model,
                "sessionID": agentSession.id.uuidString,
                "title": agentSession.title
            ]
        )

        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: acknowledgement,
            contextTitle: "OpenClicky Agent"
        )

        flyBuddyTowardAgentDock(acknowledgement: acknowledgement)
        showAgentDockWindowNearCurrentScreen()
        submitAgentPrompt(instruction, to: agentSession)

        currentResponseTask = Task {
            self.voiceState = .processing
            do {
                try await elevenLabsTTSClient.speakText(acknowledgement) {
                    self.voiceState = .responding
                }
            } catch {
                guard !Self.isExpectedCancellation(error) else { return }
                ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                print("ElevenLabs TTS error: \(error)")
                speakResponseFailureFallback(error)
            }

            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                clearAgentDockCaption(for: dockItemID)
                if !Task.isCancelled {
                    self.voiceState = .idle
                    scheduleTransientHideIfNeeded()
                }
            }
        }
    }

    private func ensureCursorOverlayVisibleForAgentTask() {
        guard !isOverlayVisible || !overlayWindowManager.isShowingOverlay() else { return }
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func directComputerUseAgentBoundaryCueText() -> String {
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            return "routing that through Background Computer Use."
        case .nativeSwift:
            return "routing that through OpenClicky's native CUA path."
        }
    }

    private func showDirectComputerUseDockCue(caption: String) {
        let dockItemID = UUID()
        let dockItem = ClickyAgentDockItem(
            id: dockItemID,
            sessionID: nil,
            title: selectedComputerUseBackend.label,
            accentTheme: Self.nextAgentDockAccentTheme(existingCount: agentDockItems.count),
            status: .done,
            caption: caption,
            createdAt: Date()
        )
        agentDockItems.append(dockItem)
        if agentDockItems.count > 6 {
            agentDockItems.removeFirst(agentDockItems.count - 6)
        }
        scheduleWidgetSnapshotPublish()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self else { return }
            self.agentDockItems.removeAll { $0.id == dockItemID && $0.sessionID == nil }
            if self.agentDockItems.isEmpty {
                self.agentDockWindowManager.hide()
            }
            self.scheduleWidgetSnapshotPublish()
        }
    }

    private static func shortAgentInstructionSummary(_ instruction: String) -> String {
        let flattenedInstruction = instruction
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard flattenedInstruction.count > 44 else {
            return flattenedInstruction
        }

        let endIndex = flattenedInstruction.index(flattenedInstruction.startIndex, offsetBy: 44)
        let prefix = String(flattenedInstruction[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace])
        }
        return prefix
    }

    private static func nextAgentDockAccentTheme(existingCount: Int) -> ClickyAccentTheme {
        let accentThemes: [ClickyAccentTheme] = [.blue, .mint, .rose, .blue, .amber]
        return accentThemes[existingCount % accentThemes.count]
    }

    private func updateAgentDockItem(for sessionID: UUID, status: CodexAgentSessionStatus) {
        guard let itemIndex = agentDockItems.lastIndex(where: { $0.sessionID == sessionID }) else { return }
        let activitySummary = codexAgentSessions
            .first(where: { $0.id == sessionID })?
            .latestActivitySummary

        switch status {
        case .starting:
            agentDockItems[itemIndex].status = .starting
            agentDockItems[itemIndex].caption = activitySummary ?? "Starting the agent task."
        case .running:
            agentDockItems[itemIndex].status = .running
            agentDockItems[itemIndex].caption = activitySummary ?? "Working through the task."
        case .ready:
            if agentDockItems[itemIndex].status == .running || agentDockItems[itemIndex].status == .starting {
                agentDockItems[itemIndex].status = .done
                agentDockItems[itemIndex].caption = activitySummary ?? "Done. Use voice or text to follow up."
            }
            completeAgentRequestTimingIfNeeded(sessionID: sessionID, status: "success")
        case .failed:
            agentDockItems[itemIndex].status = .failed
            agentDockItems[itemIndex].caption = activitySummary ?? "Needs attention. Ask for agent status to hear the error."
            completeAgentRequestTimingIfNeeded(
                sessionID: sessionID,
                status: "failed",
                extra: [
                    "activitySummary": activitySummary ?? ""
                ]
            )
        case .stopped:
            completeAgentRequestTimingIfNeeded(sessionID: sessionID, status: "cancelled")
            break
        }
        scheduleWidgetSnapshotPublish()
    }

    private func completeAgentRequestTimingIfNeeded(
        sessionID: UUID,
        status: String,
        extra: [String: Any] = [:]
    ) {
        let timing = agentRequestTimingsBySessionID.removeValue(forKey: sessionID)
        let executionStartedAt = agentExecutionStartDatesBySessionID.removeValue(forKey: sessionID)
        guard timing != nil || executionStartedAt != nil else { return }

        var fields = extra
        fields["sessionID"] = sessionID.uuidString
        fields["executor"] = "agent_mode"
        fields["executionMethod"] = "CodexAgentSession.status"
        fields["controller"] = "CodexAgentSession"
        markRequestCompleted(
            route: "agent.start",
            executionStartedAt: executionStartedAt,
            timing: timing,
            status: status,
            extra: fields
        )
    }

    func openAgentDockItem(_ itemID: UUID) {
        guard isAdvancedModeEnabled else {
            prepareVoiceFollowUpForAgentDockItem(itemID)
            return
        }
        if let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID {
            selectCodexAgentSession(sessionID)
        }
        showCodexHUD()
    }

    func dismissAgentDockItem(_ itemID: UUID) {
        let dismissedSessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID
        if let dismissedSessionID {
            cancelAgentTask(sessionID: dismissedSessionID, removeDockItems: false)
        }

        agentDockItems.removeAll { $0.id == itemID }
        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }
        scheduleWidgetSnapshotPublish()
    }

    func prepareVoiceFollowUpForAgentDockItem(_ itemID: UUID) {
        guard let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID else {
            prepareForVoiceFollowUp()
            return
        }
        pendingAgentVoiceFollowUpSessionID = sessionID
        pendingAgentVoiceFollowUpCreatedAt = Date()
        selectCodexAgentSession(sessionID)
        prepareForVoiceFollowUp()
    }

    func showTextFollowUpForAgentDockItem(_ itemID: UUID) {
        guard let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID else { return }
        selectCodexAgentSession(sessionID)
        let submitText: (String) -> Void = { [weak self] submittedText in
            self?.submitTextFollowUpForActiveAgent(submittedText)
        }

        if let textFollowUpOrigin = agentDockWindowManager.textFollowUpOrigin() {
            textModeWindowManager.show(origin: textFollowUpOrigin, submitText: submitText)
        } else {
            textModeWindowManager.show(at: NSEvent.mouseLocation, submitText: submitText)
        }
    }

    private func submitTextFollowUpForActiveAgent(_ submittedText: String) {
        let trimmedText = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let timing = beginRequestTiming(source: "agent_text_followup", text: trimmedText)
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_text_followup",
                "sessionID": codexAgentSession.id.uuidString,
                "title": codexAgentSession.title,
                "instructionLength": trimmedText.count
            ]
        )
        submitAgentPrompt(trimmedText, to: codexAgentSession)
        lastAgentContextSessionID = codexAgentSession.id
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_text_followup",
                "sessionID": codexAgentSession.id.uuidString,
                "title": codexAgentSession.title,
                "model": codexAgentSession.model
            ]
        )
        if isAdvancedModeEnabled {
            showCodexHUD()
        }
    }

    func submitAgentPromptFromUI(_ prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        let timing = beginRequestTiming(source: "agent_hud_prompt", text: trimmedPrompt)
        activeRequestTiming = timing
        defer { activeRequestTiming = nil }
        if handleAgentSelectionRequestIfNeeded(from: trimmedPrompt, source: "agent_hud_prompt") {
            return
        }

        if handleDirectComputerUseRequest(from: trimmedPrompt, source: "agent_hud_prompt") {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_prompt.intercepted_native_cua",
                fields: [
                    "source": "agent_hud_prompt",
                    "instruction": trimmedPrompt,
                    "requestID": timing.requestID
                ]
            )
            return
        }

        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_hud_prompt",
                "sessionID": codexAgentSession.id.uuidString,
                "title": codexAgentSession.title,
                "instructionLength": trimmedPrompt.count
            ]
        )
        submitAgentPrompt(trimmedPrompt, to: codexAgentSession)
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_hud_prompt",
                "sessionID": codexAgentSession.id.uuidString,
                "title": codexAgentSession.title,
                "model": codexAgentSession.model
            ]
        )
    }

    private func submitAgentPrompt(_ prompt: String, to session: CodexAgentSession) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        lastAgentContextSessionID = session.id
        activeCodexAgentSessionID = session.id
        Task {
            let screenContext = await prepareAgentScreenContextForNextTurn()
            session.submitPromptFromUI(trimmedPrompt, screenContext: screenContext)
        }
    }

    private func interruptCurrentVoiceResponse() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        codexVoiceSession.cancelActiveTurn(reason: "voice_response_interrupted")
        elevenLabsTTSClient.stopPlayback()
        fallbackSpeechSynthesizer?.stopSpeaking(at: .immediate)
        fallbackSpeechSynthesizer = nil
    }

    private func prepareAgentScreenContextForNextTurn() async -> CodexAgentScreenContext? {
        if !handoffQueue.isEmpty {
            let queuedRegions = handoffQueue
            do {
                let context = try writeQueuedHandoffScreenContext(queuedRegions)
                handoffQueue.removeAll { queued in
                    queuedRegions.contains { $0.id == queued.id }
                }
                return context
            } catch {
                print("OpenClicky Agent Mode: failed to write queued screen context: \(error)")
            }
        }

        do {
            if selectedComputerUseBackend == .backgroundComputerUse {
                do {
                    let capture = try await backgroundComputerUseController.captureFrontmostWindowAsJPEG()
                    return try writeBackgroundComputerUseScreenContext(capture)
                } catch {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "background_computer_use.screen_context_error",
                        fields: [
                            "backend": selectedComputerUseBackend.rawValue,
                            "error": error.localizedDescription,
                            "status": backgroundComputerUseController.status.summary
                        ]
                    )
                    print("OpenClicky Agent Mode: Background Computer Use context unavailable: \(error)")
                }
            } else if nativeComputerUseController.isEnabled {
                do {
                    let capture = try await nativeComputerUseController.captureFocusedWindowAsJPEG()
                    return try writeNativeComputerUseScreenContext(capture)
                } catch {
                    print("OpenClicky Agent Mode: native CUA Swift focused-window context unavailable: \(error)")
                }
            }

            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            return try writeCapturedScreenContext(captures)
        } catch {
            print("OpenClicky Agent Mode: current screen context unavailable: \(error)")
            return nil
        }
    }

    private func writeQueuedHandoffScreenContext(_ queuedRegions: [HandoffQueuedRegionScreenshot]) throws -> CodexAgentScreenContext {
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let attachments = try queuedRegions.enumerated().map { index, queuedRegion in
            let fileURL = directory.appendingPathComponent("\(batchID)-handoff-\(index + 1).jpg", isDirectory: false)
            try queuedRegion.imageData.write(to: fileURL, options: .atomic)

            let rect = queuedRegion.selection.captureRect
            let comment = queuedRegion.selection.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            let noteParts = [
                "Selected region x:\(Int(rect.minX)) y:\(Int(rect.minY)) width:\(Int(rect.width)) height:\(Int(rect.height)).",
                comment.isEmpty ? nil : "User note: \(comment)"
            ].compactMap { $0 }

            return CodexAgentScreenContextAttachment(
                label: "Queued handoff region \(index + 1)",
                fileURL: fileURL,
                note: noteParts.joined(separator: " ")
            )
        }

        return CodexAgentScreenContext(
            source: "queued screen handoff",
            capturedAt: Date(),
            attachments: attachments
        )
    }

    private func writeNativeComputerUseScreenContext(_ capture: OpenClickyComputerUseWindowCapture) throws -> CodexAgentScreenContext {
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let fileURL = directory.appendingPathComponent("\(batchID)-cua-swift-window.jpg", isDirectory: false)
        try capture.imageData.write(to: fileURL, options: .atomic)

        return CodexAgentScreenContext(
            source: "native CUA Swift focused-window context",
            capturedAt: Date(),
            attachments: [
                CodexAgentScreenContextAttachment(
                    label: capture.label,
                    fileURL: fileURL,
                    note: capture.agentContextNote
                )
            ]
        )
    }

    private func writeBackgroundComputerUseScreenContext(_ capture: OpenClickyBackgroundComputerUseWindowCapture) throws -> CodexAgentScreenContext {
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let fileURL = directory.appendingPathComponent("\(batchID)-background-computer-use-window.jpg", isDirectory: false)
        try capture.imageData.write(to: fileURL, options: .atomic)

        return CodexAgentScreenContext(
            source: "Background Computer Use focused-window context",
            capturedAt: Date(),
            attachments: [
                CodexAgentScreenContextAttachment(
                    label: capture.label,
                    fileURL: fileURL,
                    note: capture.agentContextNote
                )
            ]
        )
    }

    private func writeCapturedScreenContext(_ captures: [CompanionScreenCapture]) throws -> CodexAgentScreenContext {
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let attachments = try captures.enumerated().map { index, capture in
            let suffix = capture.isCursorScreen ? "primary" : "secondary-\(index + 1)"
            let fileURL = directory.appendingPathComponent("\(batchID)-\(suffix).jpg", isDirectory: false)
            try capture.imageData.write(to: fileURL, options: .atomic)

            let note = "Image dimensions \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels; display frame x:\(Int(capture.displayFrame.minX)) y:\(Int(capture.displayFrame.minY)) width:\(capture.displayWidthInPoints) height:\(capture.displayHeightInPoints)."

            return CodexAgentScreenContextAttachment(
                label: capture.label,
                fileURL: fileURL,
                note: note
            )
        }

        return CodexAgentScreenContext(
            source: "current desktop screenshot",
            capturedAt: Date(),
            attachments: attachments
        )
    }

    private func createAgentScreenContextDirectory() throws -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("AgentMode", isDirectory: true)
            .appendingPathComponent("ScreenContext", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func agentContextBatchID(date: Date = Date()) -> String {
        let rawID = ISO8601DateFormatter().string(from: date)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = rawID.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return sanitized + "-" + String(UUID().uuidString.prefix(8))
    }

    private func clearAgentDockCaption(for itemID: UUID) {
        guard let itemIndex = agentDockItems.firstIndex(where: { $0.id == itemID }) else { return }
        agentDockItems[itemIndex].caption = nil
    }

    private func flyBuddyTowardAgentDock(acknowledgement: String) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let targetScreen else { return }

        let screenFrame = targetScreen.frame
        let visibleFrame = targetScreen.visibleFrame
        detectedElementBubbleText = acknowledgement
        detectedElementDisplayFrame = screenFrame
        detectedElementScreenLocation = CGPoint(
            x: visibleFrame.maxX - 58,
            y: visibleFrame.maxY - 92
        )
    }

    func pointAtPermissionDragAssistant() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let targetScreen else { return }

        let visibleFrame = targetScreen.visibleFrame
        let assistantCenterY = visibleFrame.minY + max(70, visibleFrame.height * 0.22) + 70
        detectedElementBubbleText = WindowPositionManager.permissionDragAssistantMessage
        detectedElementDisplayFrame = targetScreen.frame
        detectedElementScreenLocation = CGPoint(
            x: visibleFrame.midX - 285,
            y: assistantCenterY
        )
    }

    private func showAgentDockWindowNearCurrentScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let targetScreen else { return }
        agentDockWindowManager.show(companionManager: self, onScreen: targetScreen)
    }

    private func speakShortSystemResponse(_ text: String) {
        interruptCurrentVoiceResponse()
        currentResponseTask = Task {
            self.voiceState = .processing
            do {
                try await elevenLabsTTSClient.speakText(text) {
                    self.voiceState = .responding
                }
            } catch {
                guard !Self.isExpectedCancellation(error) else { return }
                speakResponseFailureFallback(error)
            }

            if !Task.isCancelled {
                self.voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - for audio, voice playback, or "why are you not speaking" questions, give a short diagnosis or next check. do not summarize the screen unless the visible screen directly explains the audio problem.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - OpenClicky can open apps, type text, and press keys through its selected direct computer-use backend, either native CUA Swift or Background Computer Use. simple focused-window control should be instant and should not become an Agent Mode task.
    - Agent Mode is explicit-only. Do not start, request, or imply a background agent unless the user explicitly asks for an agent, a new agent task, or an existing active agent follow-up.
    - If a request needs files, code, research, durable memory, or broader tools and the user did not explicitly ask for an agent, say what OpenClicky voice or direct computer use can do now and name the exact agent request phrase they can use.
    - Voice responses must not run terminal commands, shell commands, Python, find, ls, or other local filesystem tools. Use only the attached screenshots and visible context in this lane. For local file or folder inspection that direct computer use did not handle, tell the user the exact "start an agent to..." phrase instead.
    - OpenClicky can inspect, create, edit, and organize local files through explicit Agent Mode. Agents run with full local read/write capability when explicitly started; do not claim filesystem access is unavailable.
    - OpenClicky has durable local storage for logs, memory, learned skills, widget state, sessions, and config. if the user asks where those live, answer from the runtime storage context included below.
    - OpenClicky has a SOUL.md persona file. if the user asks who OpenClicky is or how it should behave, answer from runtime storage. for edits, tell them the explicit agent phrase to use.
    - if the user asks to view, edit, review, tune, fix, or inspect OpenClicky's logs, memory, learned skills, widget state, sessions, config, or review comments, do not auto-start an agent; tell them to say "start an agent to..." if they want background work.
    - if the user asks to optimize skills, audit skills, review logs for learnings, or see what OpenClicky can learn from logs, do not auto-start an agent; tell them the explicit agent phrase to use.
    - old OpenClicky artifacts should be archived as backups before replacement. do not suggest deleting old logs, memory, skills, prompts, or notes unless the user explicitly asks for destructive deletion.
    - never output hidden agent-start directives. The app handles explicit agent starts before this voice model sees the request.
    - for current weather, live news, prices, schedules, or anything time-sensitive that is not visible on screen, do not invent current information and do not start Agent Mode automatically. tell the user the exact explicit agent request phrase if live lookup is needed.
    - if the right answer would be "i can't do that from voice", explain the smallest explicit next step instead of starting an agent automatically.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. be proactive with it. if the user's question has anything to do with the visible screen, current app, current file, visible text, a button, a menu, a panel, a window, a setting, a permission prompt, code on screen, or "this/that/here", you should usually point. don't wait for the user to explicitly ask you to point.

    your default should be: if there is a relevant visible target, point at it. if the user asks "what is this", "where is that", "how do i do this", "what should i click", "what's on my screen", "what file is this", or anything involving the current UI, pick the best visible target and point.

    only use [POINT:none] when the answer is truly unrelated to the screen, like a general knowledge question, brainstorming, or a topic where no visible UI target would help. if you're unsure but there is a plausible relevant visible area, point at the best candidate.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    private func runtimeStorageContextForVoicePrompt() -> String {
        let logs = OpenClickyMessageLogStore.shared
        return """
        OpenClicky runtime storage:
        - runtime map: \(codexHomeManager.runtimeMapFile.path)
        - soul/persona: \(codexHomeManager.soulFile.path)
        - codex home: \(codexHomeManager.codexHomeDirectory.path)
        - persistent memory: \(codexHomeManager.persistentMemoryFile.path)
        - memory articles: \(codexHomeManager.memoriesDirectory.path)
        - learned skills: \(codexHomeManager.learnedSkillsDirectory.path)
        - bundled skills: \(codexHomeManager.codexHomeDirectory.appendingPathComponent(codexHomeManager.bundledSkillsDirectoryName, isDirectory: true).path)
        - archives: \(codexHomeManager.archivesDirectory.path)
        - logs directory: \(logs.logDirectory.path)
        - current message log: \(logs.currentLogFile.path)
        - log review comments: \(logs.agentReviewCommentsFile.path)
        - log review jsonl: \(logs.reviewCommentsFile.path)
        - widget snapshot: \(OpenClickyWidgetStateStore.snapshotURL.path)
        """
    }

    private func currentVoiceResponseSystemPrompt() -> String {
        let memoryContext = codexHomeManager.persistentMemoryContext()
        return """
        \(Self.companionVoiceResponseSystemPrompt)

        \(runtimeStorageContextForVoicePrompt())

        persistent memory:
        read this as durable user/project context. do not say you cannot remember outside the conversation; use this memory.

        \(memoryContext)
        """
    }

    private static let tutorModeSystemPrompt = """
    you're OpenClicky in tutor mode. the user wants to learn the app or workflow currently on screen, and you can see their focused window.

    your job:
    - proactively guide them one step at a time when they pause.
    - point at the button, menu, field, panel, or visible area they should use next.
    - know that OpenClicky can open apps and use the computer through Agent Mode when the user gives a direct action request.
    - simple open, type, and key-press actions use OpenClicky's selected direct computer-use backend instead of Agent Mode.
    - if they completed a step, acknowledge it briefly and give the next step.
    - if they appear off track, gently redirect.
    - teach concepts only when they are useful for the next action.
    - avoid repeating prior tutor observations; use the conversation history to continue.

    style:
    - short spoken response, lowercase, casual, no markdown, no emojis.
    - do not claim you clicked or controlled anything in tutor observations. you can guide and point; simple direct action requests use OpenClicky's selected direct computer-use backend, and broader tool work can use Agent Mode when explicitly routed there.

    element pointing:
    append exactly one [POINT:x,y:label] tag at the end when a visible target would help. use [POINT:none] only when pointing would not help.
    the screenshot labels include pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    if a screen number is present in the image label and the target is not the primary screen, append :screenN.
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        var executionFields = voiceResponseExecutionFields()
        executionFields["transcriptLength"] = transcript.count
        let executionStartedAt = markRequestExecutionStarted(
            route: "voice.response",
            timing: timing,
            extra: executionFields
        )

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            self.voiceState = .processing
            var didCompleteRequest = false

            func completeRequest(status: String = "success", extra: [String: Any] = [:]) async {
                await MainActor.run {
                    guard !didCompleteRequest else { return }
                    didCompleteRequest = true
                    var completionFields = self.voiceResponseExecutionFields()
                    extra.forEach { completionFields[$0.key] = $0.value }
                    self.markRequestCompleted(
                        route: "voice.response",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: status,
                        extra: completionFields
                    )
                }
            }

            do {
                // Capture all connected screens so the AI has full context.
                let captureStartedAt = Date()
                let screenCaptures = try await captureAllScreensForVoiceResponseIfAvailable()
                self.markRequestStageCompleted(
                    route: "voice.response",
                    stage: "screen_capture",
                    stageStartedAt: captureStartedAt,
                    timing: timing,
                    extra: [
                        "executor": "screen_capture",
                        "executionMethod": "captureAllScreensForVoiceResponseIfAvailable",
                        "controller": "ScreenCaptureKit",
                        "screenCount": screenCaptures.count,
                        "imageBytes": screenCaptures.reduce(0) { $0 + $1.imageData.count }
                    ]
                )

                guard !Task.isCancelled else {
                    await completeRequest(status: "cancelled", extra: ["cancelledAt": "after_screen_capture"])
                    return
                }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = self.conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let userPromptForClaude: String
                if labeledImages.isEmpty {
                    userPromptForClaude = "\(transcript)\n\nNo screenshot is available. Answer from the transcript only and use [POINT:none]."
                } else {
                    userPromptForClaude = transcript
                }
                let voiceSystemPrompt = currentVoiceResponseSystemPrompt()

                let modelStartedAt = Date()
                var modelResponseFields = self.voiceResponseExecutionFields()
                let fullResponseText = try await analyzeVoiceResponse(
                    images: labeledImages,
                    systemPrompt: voiceSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: userPromptForClaude,
                    onTextChunk: { accumulatedText in
                        let visibleText = Self.parsePointingCoordinates(from: accumulatedText)
                            .spokenText
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !visibleText.isEmpty else { return }
                        self.latestVoiceResponseCard = ClickyResponseCard(
                            source: .voice,
                            rawText: visibleText,
                            contextTitle: transcript
                        )
                    }
                )
                self.markRequestStageCompleted(
                    route: "voice.response",
                    stage: "model_response",
                    stageStartedAt: modelStartedAt,
                    timing: timing,
                    extra: {
                        modelResponseFields["responseLength"] = fullResponseText.count
                        modelResponseFields["imageCount"] = labeledImages.count
                        return modelResponseFields
                    }()
                )

                guard !Task.isCancelled else {
                    await completeRequest(status: "cancelled", extra: ["cancelledAt": "after_model_response"])
                    return
                }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    self.voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    detectedElementBubbleText = Self.pointingBubbleText(for: parseResult.elementLabel)
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                    await attemptProactiveElementPointingIfUseful(
                        transcript: transcript,
                        spokenText: spokenText,
                        screenCaptures: screenCaptures
                    )
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                self.conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if self.conversationHistory.count > 10 {
                    self.conversationHistory.removeFirst(self.conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(self.conversationHistory.count) exchanges")
                do {
                    try codexHomeManager.appendPersistentMemoryEvent(
                        userRequest: transcript,
                        agentResponse: spokenText
                    )
                } catch {
                    print("⚠️ OpenClicky memory update failed: \(error)")
                }

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)
                self.latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: spokenText,
                    contextTitle: transcript
                )
                self.scheduleWidgetSnapshotPublish()

                // Play the full response via TTS. Mark OpenClicky responsive as
                // soon as audio starts, but keep this task alive until playback
                // finishes so the response is not cut off.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let ttsStartedAt = Date()
                    var didMarkAudioStarted = false
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText) {
                            guard !didMarkAudioStarted else { return }
                            didMarkAudioStarted = true
                            self.voiceState = .responding
                            self.markRequestStageCompleted(
                                route: "voice.response",
                                stage: "tts_audio_started",
                                stageStartedAt: ttsStartedAt,
                                timing: timing,
                                extra: [
                                    "executor": "tts",
                                    "executionMethod": "ElevenLabsTTSClient.speakText",
                                    "controller": "ElevenLabsTTSClient",
                                    "spokenTextLength": spokenText.count
                                ]
                            )
                            var completionFields = self.voiceResponseExecutionFields()
                            completionFields["spokenTextLength"] = spokenText.count
                            completionFields["pointed"] = parseResult.coordinate != nil
                            completionFields["audioPlaybackState"] = "started"
                            Task { await completeRequest(extra: completionFields) }
                        }
                        self.markRequestStageCompleted(
                            route: "voice.response",
                            stage: "tts_playback_finished",
                            stageStartedAt: ttsStartedAt,
                            timing: timing,
                            extra: [
                                "executor": "tts",
                                "executionMethod": "ElevenLabsTTSClient.speakText",
                                "controller": "ElevenLabsTTSClient",
                                "spokenTextLength": spokenText.count
                            ]
                        )
                    } catch {
                        guard !Self.isExpectedCancellation(error) else {
                            await completeRequest(status: "cancelled", extra: ["cancelledAt": "tts"])
                            return
                        }
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakResponseFailureFallback(error)
                        self.markRequestStageCompleted(
                            route: "voice.response",
                            stage: didMarkAudioStarted ? "tts_playback_finished" : "tts_audio_started",
                            stageStartedAt: ttsStartedAt,
                            timing: timing,
                            status: "failed",
                            extra: [
                                "executor": "tts",
                                "executionMethod": "ElevenLabsTTSClient.speakText",
                                "controller": "ElevenLabsTTSClient",
                                "error": error.localizedDescription
                            ]
                        )
                    }
                }
                var completionFields = self.voiceResponseExecutionFields()
                completionFields["spokenTextLength"] = spokenText.count
                completionFields["pointed"] = parseResult.coordinate != nil
                completionFields["audioPlaybackState"] = spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "empty" : "finished"
                await completeRequest(extra: completionFields)
            } catch is CancellationError {
                // User spoke again — response was interrupted
                await completeRequest(status: "cancelled", extra: ["cancelledAt": "task"])
            } catch where Self.isExpectedCancellation(error) {
                // User spoke again — URLSession/AVFoundation surfaced cancellation as NSError.
                await completeRequest(status: "cancelled", extra: ["cancelledAt": "task"])
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "incoming",
                    event: "voice.response_error",
                    fields: [
                        "transcript": transcript,
                        "error": error.localizedDescription
                    ]
                )
                speakResponseFailureFallback(error)
                await completeRequest(
                    status: "failed",
                    extra: [
                        "error": error.localizedDescription
                    ]
                )
            }

            if !Task.isCancelled {
                self.voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private func startTutorIdleObservation() {
        userActivityIdleDetector.start()
        bindTutorIdleObservation()
    }

    private func stopTutorIdleObservation() {
        tutorIdleCancellable?.cancel()
        tutorIdleCancellable = nil
        userActivityIdleDetector.stop()
        isTutorObservationInFlight = false
    }

    private func bindTutorIdleObservation() {
        tutorIdleCancellable?.cancel()
        tutorIdleCancellable = userActivityIdleDetector.$isUserIdle
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self,
                      self.isTutorModeEnabled,
                      self.voiceState == .idle,
                      !self.elevenLabsTTSClient.isPlaying,
                      !self.isTutorObservationInFlight else { return }

                self.isTutorObservationInFlight = true
                Task {
                    await self.performTutorObservation()
                    self.userActivityIdleDetector.observationDidComplete()
                    self.isTutorObservationInFlight = false
                }
            }
    }

    private func performTutorObservation() async {
        do {
            ensureCursorOverlayVisibleForAgentTask()
            voiceState = .processing

            let screenCaptures = try await CompanionScreenCaptureUtility.captureFocusedWindowAsJPEG()
            let labeledImages = screenCaptures.map { capture in
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                return (data: capture.imageData, label: capture.label + dimensionInfo)
            }
            let historyForAPI = conversationHistory.map { entry in
                (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
            }

            let fullResponseText = try await analyzeVoiceResponse(
                images: labeledImages,
                systemPrompt: Self.tutorModeSystemPrompt,
                conversationHistory: historyForAPI,
                userPrompt: "observe the focused window and guide me to the next useful learning step.",
                onTextChunk: { _ in }
            )

            let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
            let spokenText = parseResult.spokenText

            if let pointCoordinate = parseResult.coordinate,
               let targetScreenCapture = tutorTargetScreenCapture(from: screenCaptures, screenNumber: parseResult.screenNumber) {
                let globalLocation = globalPoint(
                    fromScreenshotPoint: pointCoordinate,
                    in: targetScreenCapture
                )
                voiceState = .idle
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = targetScreenCapture.displayFrame
                detectedElementBubbleText = Self.pointingBubbleText(for: parseResult.elementLabel)
                ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                print("Tutor pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y)))")
            }

            conversationHistory.append((
                userTranscript: "[tutor observation]",
                assistantResponse: spokenText
            ))
            if conversationHistory.count > 10 {
                conversationHistory.removeFirst(conversationHistory.count - 10)
            }

            if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await elevenLabsTTSClient.speakText(spokenText) {
                    self.voiceState = .responding
                }
            }
        } catch is CancellationError {
            // A normal voice interaction interrupted the tutor observation.
        } catch where Self.isExpectedCancellation(error) {
            // A normal voice interaction interrupted the tutor observation.
        } catch {
            print("Tutor observation error: \(error)")
        }

        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func tutorTargetScreenCapture(from screenCaptures: [CompanionScreenCapture], screenNumber: Int?) -> CompanionScreenCapture? {
        if let screenNumber,
           screenNumber >= 1,
           screenNumber <= screenCaptures.count {
            return screenCaptures[screenNumber - 1]
        }

        return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
    }

    private func globalPoint(fromScreenshotPoint point: CGPoint, in capture: CompanionScreenCapture) -> CGPoint {
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let clampedX = max(0, min(point.x, screenshotWidth))
        let clampedY = max(0, min(point.y, screenshotHeight))
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        return CGPoint(
            x: displayLocalX + capture.displayFrame.origin.x,
            y: (displayHeight - displayLocalY) + capture.displayFrame.origin.y
        )
    }

    private func analyzeVoiceResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        applyVoiceResponseModelSettings(selectedVoiceResponseModel)

        switch selectedVoiceResponseModel.provider {
        case .anthropic:
            return try await analyzeClaudeResponse(
                images: images,
                model: selectedVoiceResponseModel.id,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        case .openAI:
            return try await analyzeOpenAIOrCodexVoiceResponse(
                images: images,
                model: selectedVoiceResponseModel.id,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        case .codex:
            return try await analyzeCodexVoiceResponse(
                images: images,
                model: selectedVoiceResponseModel.id,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        }
    }

    private func analyzeClaudeResponse(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        if let claudeAgentSDKAPI {
            do {
                let modelOption = OpenClickyModelCatalog.voiceResponseModel(withID: model)
                claudeAgentSDKAPI.model = modelOption.id
                claudeAgentSDKAPI.maxOutputTokens = modelOption.maxOutputTokens
                let (text, _) = try await claudeAgentSDKAPI.analyzeImageStreaming(
                    images: images,
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: userPrompt,
                    onTextChunk: onTextChunk
                )
                return text
            } catch {
                guard AppBundleConfiguration.anthropicAPIKey() != nil else {
                    throw error
                }
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "error",
                    event: "voice.response_fallback",
                    fields: [
                        "from": "claude_agent_sdk",
                        "to": "anthropic_api_key",
                        "error": error.localizedDescription
                    ]
                )
            }
        }

        if AppBundleConfiguration.anthropicAPIKey() != nil {
            let modelOption = OpenClickyModelCatalog.voiceResponseModel(withID: model)
            claudeAPI.model = modelOption.id
            claudeAPI.maxOutputTokens = modelOption.maxOutputTokens
            let (text, _) = try await claudeAPI.analyzeImageStreaming(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
            return text
        }

        throw NSError(
            domain: "ClaudeAgentSDKAPI",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Claude is not configured. Sign in to Claude Code locally or set an Anthropic API key."]
        )
    }

    private func analyzeOpenAIOrCodexVoiceResponse(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        do {
            return try await analyzeCodexVoiceResponse(
                images: images,
                model: model,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        } catch {
            guard AppBundleConfiguration.openAIAPIKey() != nil else {
                throw error
            }
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "error",
                event: "voice.response_fallback",
                fields: [
                    "from": "codex_voice_session",
                    "to": "openai_api_key",
                    "error": error.localizedDescription
                ]
            )
        }

        let modelOption = OpenClickyModelCatalog.voiceResponseModel(withID: model)
        openAIAPI.model = modelOption.id
        openAIAPI.maxOutputTokens = modelOption.maxOutputTokens
        let (text, _) = try await openAIAPI.analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
        return text
    }

    private func analyzeCodexVoiceResponse(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        codexVoiceSession.model = model
        let (text, _) = try await codexVoiceSession.analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
        return text
    }

    private func captureAllScreensForVoiceResponseIfAvailable() async throws -> [CompanionScreenCapture] {
        try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
    }

    private func analyzeComputerUsePointingResponse(
        image: (data: Data, label: String),
        capture: CompanionScreenCapture,
        systemPrompt: String,
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let selectedPointingModel = OpenClickyModelCatalog.computerUseModel(withID: selectedComputerUseModel)

        switch selectedPointingModel.provider {
        case .anthropic:
            return try await analyzeClaudeResponse(
                images: [image],
                model: selectedPointingModel.id,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        case .codex:
            let detector = CodexPointDetector(model: selectedPointingModel.id)
            let text = try await detector.detectPointTag(
                screenshotData: image.data,
                screenshotLabel: image.label,
                userQuestion: userPrompt,
                systemPrompt: systemPrompt,
                displayWidthInPixels: capture.screenshotWidthInPixels,
                displayHeightInPixels: capture.screenshotHeightInPixels
            )
            onTextChunk(text)
            return text
        case .openAI:
            openAIAPI.model = selectedPointingModel.id
            let (text, _) = try await openAIAPI.analyzeImage(
                images: [image],
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
            onTextChunk(text)
            return text
        }
    }

    private func attemptProactiveElementPointingIfUseful(
        transcript: String,
        spokenText: String,
        screenCaptures: [CompanionScreenCapture]
    ) async {
        guard Self.shouldAttemptProactivePointing(for: transcript) else { return }
        guard let targetScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first else { return }

        let selectedPointingModel = OpenClickyModelCatalog.computerUseModel(withID: selectedComputerUseModel)
        let userQuestion = "\(transcript)\n\nOpenClicky's answer: \(spokenText)"
        let displayLocalLocation: CGPoint?

        switch selectedPointingModel.provider {
        case .anthropic:
            guard let anthropicAPIKey = AppBundleConfiguration.anthropicAPIKey() else { return }
            let detector = ElementLocationDetector(apiKey: anthropicAPIKey, model: selectedPointingModel.id)
            displayLocalLocation = await detector.detectElementLocation(
                screenshotData: targetScreenCapture.imageData,
                userQuestion: userQuestion,
                displayWidthInPoints: targetScreenCapture.displayWidthInPoints,
                displayHeightInPoints: targetScreenCapture.displayHeightInPoints
            )
        case .codex:
            let detector = CodexPointDetector(model: selectedPointingModel.id)
            displayLocalLocation = await detector.detectDisplayLocalPoint(
                screenshotData: targetScreenCapture.imageData,
                screenshotLabel: targetScreenCapture.label,
                userQuestion: userQuestion,
                displayWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
                displayHeightInPixels: targetScreenCapture.screenshotHeightInPixels,
                displayWidthInPoints: targetScreenCapture.displayWidthInPoints,
                displayHeightInPoints: targetScreenCapture.displayHeightInPoints
            )
        case .openAI:
            return
        }

        guard let displayLocalLocation else { return }

        let displayFrame = targetScreenCapture.displayFrame
        let globalLocation = CGPoint(
            x: displayLocalLocation.x + displayFrame.origin.x,
            y: displayLocalLocation.y + displayFrame.origin.y
        )

        voiceState = .idle
        detectedElementBubbleText = Self.shortPointingCaption(from: spokenText)
        detectedElementDisplayFrame = displayFrame
        detectedElementScreenLocation = globalLocation
        ClickyAnalytics.trackElementPointed(elementLabel: "proactive")
        print("🎯 Proactive element pointing: (\(Int(displayLocalLocation.x)), \(Int(displayLocalLocation.y)))")
    }

    private static func shouldAttemptProactivePointing(for transcript: String) -> Bool {
        let normalizedTranscript = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let normalizedCommandText = normalizedSpokenCommandText(transcript)

        let voiceStatusPhrases = [
            "can you hear",
            "hear me",
            "mic",
            "microphone",
            "not speaking",
            "speaking",
            "voice",
            "audio",
            "responding",
            "response",
            "slow",
            "taking so long",
            "lag"
        ]
        if voiceStatusPhrases.contains(where: { normalizedCommandText.contains($0) }) {
            return false
        }

        let screenRelatedPhrases = [
            "screen",
            "window",
            "button",
            "menu",
            "setting",
            "permission",
            "file",
            "folder",
            "tab",
            "click",
            "open",
            "where",
            "how do i",
            "what is this",
            "what's this",
            "this screen",
            "this window",
            "this button",
            "this menu",
            "this file",
            "this folder",
            "this tab",
            "this setting",
            "that screen",
            "that window",
            "that button",
            "that menu",
            "that file",
            "that folder",
            "that tab",
            "that setting",
            "right here",
            "over here",
            "up here",
            "down here",
            "what am i looking at",
            "show me",
            "point",
            "cursor"
        ]

        return screenRelatedPhrases.contains { normalizedTranscript.contains($0) }
    }

    private static func pointingBubbleText(for elementLabel: String?) -> String {
        let trimmedLabel = elementLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedLabel.isEmpty else {
            return "right here"
        }
        return "right here: \(trimmedLabel)"
    }

    private static func shortPointingCaption(from spokenText: String) -> String {
        let flattenedText = spokenText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard flattenedText.count > 76 else {
            return flattenedText.isEmpty ? "right here" : flattenedText
        }

        let endIndex = flattenedText.index(flattenedText.startIndex, offsetBy: 76)
        let prefix = String(flattenedText[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "..."
        }
        return prefix + "..."
    }

    /// If the cursor is in transient mode (user toggled "Show OpenClicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a neutral error message using macOS system TTS so failures in
    /// Claude or the configured voice provider report the correct source.
    private func speakResponseFailureFallback(_ error: Error) {
        guard !Self.isExpectedCancellation(error) else { return }

        let utterance = AVSpeechUtterance(string: userFacingResponseFailureMessage(for: error))
        let synthesizer = AVSpeechSynthesizer()
        fallbackSpeechSynthesizer?.stopSpeaking(at: .immediate)
        fallbackSpeechSynthesizer = synthesizer
        synthesizer.speak(utterance)
        voiceState = .responding
    }

    private static func isExpectedCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return true
        }

        let description = String(describing: error).lowercased()
        return description == "cancellationerror()" || description.contains("cancelled") || description.contains("canceled")
    }

    private func userFacingResponseFailureMessage(for error: Error) -> String {
        let nsError = error as NSError

        switch nsError.domain {
        case "ClaudeAPI":
            if nsError.code == -1000 {
                return "Anthropic is not configured. Set the Anthropic API key and relaunch."
            }
            return "Claude returned an error. Check the app log for the exact response."
        case "ElevenLabsTTS":
            return "Voice playback failed, but the Claude response completed. Check the app log for the TTS error."
        case "CompanionScreenCapture":
            return "Screen capture failed. Grant Screen Recording to this exact app, then quit and reopen."
        default:
            return "Something went wrong. Check the app log for the exact error."
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Onboarding video playback is disabled.
    func setupOnboardingVideo() {
        tearDownOnboardingVideo()
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        showOnboardingPrompt = false
        onboardingPromptText = ""
        onboardingPromptOpacity = 0.0
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        Task { @MainActor [weak self] in
            for character in message {
                guard let self else { return }
                self.onboardingPromptText.append(character)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }

            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.showOnboardingPrompt else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.onboardingPromptOpacity = 0.0
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.showOnboardingPrompt = false
            self.onboardingPromptText = ""
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await captureAllScreensForVoiceResponseIfAvailable()

                guard !screenCaptures.isEmpty else {
                    print("Onboarding demo skipped because no screenshot is available.")
                    return
                }

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let fullResponseText = try await analyzeComputerUsePointingResponse(
                    image: labeledImages[0],
                    capture: cursorScreenCapture,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }

    func showCodexHUD() {
        guard isAdvancedModeEnabled else { return }
        codexHUDWindowManager.show(
            companionManager: self,
            openMemory: { [weak self] in
                self?.showMemoryWindow()
            },
            prepareVoiceFollowUp: { [weak self] in
                guard let self else { return }
                self.pendingAgentVoiceFollowUpSessionID = self.activeCodexAgentSessionID
                self.pendingAgentVoiceFollowUpCreatedAt = Date()
                self.prepareForVoiceFollowUp()
            }
        )
    }

    func showMemoryWindow() {
        wikiViewerPanelManager.show(
            index: bundledKnowledgeIndex,
            sourceRootURL: codexHomeManager.memoriesDirectory,
            onCreateMemory: { [weak self] title, body in
                guard let self else {
                    throw NSError(domain: "OpenClicky.Memory", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "OpenClicky couldn't reach the memory manager."
                    ])
                }
                return try self.createMemory(title: title, body: body)
            }
        )
    }

    func createMemory(title: String, body: String) throws -> WikiManager.Article {
        let article = try codexHomeManager.saveMemory(title: title, body: body)
        loadBundledKnowledgeIndex()
        return article
    }

    func dismissLatestResponseCard() {
        if codexAgentSession.latestResponseCard != nil {
            let sessionID = codexAgentSession.id
            codexAgentSession.dismissLatestResponseCard()
            cancelAgentTask(sessionID: sessionID, removeDockItems: true)
        } else {
            latestVoiceResponseCard = nil
        }
    }

    func runSuggestedNextAction(_ actionTitle: String) {
        let trimmedActionTitle = actionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedActionTitle.isEmpty else { return }
        let timing = beginRequestTiming(source: "agent_suggested_action", text: trimmedActionTitle)
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_suggested_action",
                "sessionID": codexAgentSession.id.uuidString,
                "title": codexAgentSession.title,
                "instructionLength": trimmedActionTitle.count
            ]
        )
        submitAgentPrompt(trimmedActionTitle, to: codexAgentSession)
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_suggested_action",
                "sessionID": codexAgentSession.id.uuidString,
                "title": codexAgentSession.title,
                "model": codexAgentSession.model
            ]
        )
        if isAdvancedModeEnabled {
            showCodexHUD()
        }
    }

    func prepareForVoiceFollowUp() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        if !isClickyCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        beginVoiceFollowUpCapture()
    }

    private func beginVoiceFollowUpCapture() {
        guard !buddyDictationManager.isDictationInProgress else { return }

        transientHideTask?.cancel()
        transientHideTask = nil
        voiceFollowUpStopTask?.cancel()
        interruptCurrentVoiceResponse()
        clearDetectedElementLocation()
        ClickyAnalytics.trackPushToTalkStarted()

        Task {
            await buddyDictationManager.startAutoSubmittingDictationFromMicrophoneButton(
                currentDraftText: "",
                updateDraftText: { _ in
                    // Partial transcripts stay hidden; the cursor waveform is the active state.
                },
                submitDraftText: { [weak self] finalTranscript in
                    self?.handleFinalVoiceTranscript(finalTranscript)
                }
            )
        }

        voiceFollowUpStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                guard let self else { return }
                self.voiceFollowUpStopTask = nil
                ClickyAnalytics.trackPushToTalkReleased()
                self.buddyDictationManager.stopPersistentDictationFromMicrophoneButton()
            }
        }
    }

    func queueHandoffRegion(selection: HandoffRegionSelection, imageData: Data) {
        let queued = HandoffQueuedRegionScreenshot(selection: selection, imageData: imageData)
        handoffQueue.append(queued)
        latestVoiceResponseCard = ClickyResponseCard(
            source: .handoff,
            rawText: selection.comment.isEmpty ? "Screen region queued for Agent Mode." : selection.comment,
            contextTitle: "Screen region"
        )
    }

    func clearHandoffQueue() {
        handoffQueue.removeAll()
    }

    func warmUpCodexAgentMode() {
        guard isAdvancedModeEnabled else { return }
        codexAgentSession.warmUp()
        showCodexHUD()
    }

    #if DEBUG
    func debugTestCursorFlight() {
        ensureCursorOverlayVisibleForAgentTask()
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        detectedElementScreenLocation = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        detectedElementDisplayFrame = screen.frame
        detectedElementBubbleText = "Developer test"
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "Developer cursor flight test armed at the center of the main screen.",
            contextTitle: "Developer"
        )
    }

    func debugShowResponseCard() {
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "This is a developer smoke test for OpenClicky's compact response card. Suggested actions and dismiss behavior should remain usable from the panel and HUD.",
            contextTitle: "Developer"
        )
    }

    func debugCaptureAgentScreenContext() {
        Task {
            do {
                let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                let context = try writeCapturedScreenContext(captures)
                let fileSummary = context.attachments
                    .map { $0.fileURL.lastPathComponent }
                    .joined(separator: ", ")

                latestVoiceResponseCard = ClickyResponseCard(
                    source: .handoff,
                    rawText: "Captured \(context.attachments.count) screen context file(s): \(fileSummary)",
                    contextTitle: "Developer"
                )
            } catch {
                latestVoiceResponseCard = ClickyResponseCard(
                    source: .handoff,
                    rawText: "Screen context capture failed: \(error.localizedDescription)",
                    contextTitle: "Developer"
                )
            }
        }
    }

    func debugResetTransientUI() {
        interruptCurrentVoiceResponse()
        clearDetectedElementLocation()
        dismissLatestResponseCard()
        clearHandoffQueue()
        voiceState = .idle

        if !isClickyCursorEnabled {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }
    #endif
}

private final class ClickyTextModePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClickyTextModeWindowManager {
    private var panel: NSPanel?
    private let panelSize = NSSize(width: 340, height: 54)

    func show(at cursorLocation: CGPoint, submitText: @escaping (String) -> Void) {
        preparePanel(submitText: submitText)
        positionPanel(near: cursorLocation)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    func show(origin: CGPoint, submitText: @escaping (String) -> Void) {
        preparePanel(submitText: submitText)
        positionPanel(at: origin)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func createPanel(submitText: @escaping (String) -> Void) {
        let textModePanel = ClickyTextModePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        textModePanel.isFloatingPanel = true
        textModePanel.level = .floating
        textModePanel.isOpaque = false
        textModePanel.backgroundColor = .clear
        textModePanel.hasShadow = false
        textModePanel.hidesOnDeactivate = false
        textModePanel.isReleasedWhenClosed = false
        textModePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(
            rootView: ClickyTextModeInputView(submitText: submitText) { [weak self] in
                self?.hide()
            }
        )
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]
        textModePanel.contentView = hostingView

        panel = textModePanel
    }

    private func preparePanel(submitText: @escaping (String) -> Void) {
        if panel == nil {
            createPanel(submitText: submitText)
        } else if let hostingView = panel?.contentView as? NSHostingView<ClickyTextModeInputView> {
            hostingView.rootView = ClickyTextModeInputView(submitText: submitText) { [weak self] in
                self?.hide()
            }
        }
    }

    private func positionPanel(near cursorLocation: CGPoint) {
        guard let panel else { return }

        let targetScreen = NSScreen.screens.first { $0.frame.contains(cursorLocation) } ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let proposedOrigin = CGPoint(
            x: cursorLocation.x + 18,
            y: cursorLocation.y - panelSize.height - 12
        )
        let clampedOrigin = CGPoint(
            x: min(max(proposedOrigin.x, visibleFrame.minX + 10), visibleFrame.maxX - panelSize.width - 10),
            y: min(max(proposedOrigin.y, visibleFrame.minY + 10), visibleFrame.maxY - panelSize.height - 10)
        )

        panel.setFrame(NSRect(origin: clampedOrigin, size: panelSize), display: true)
    }

    private func positionPanel(at origin: CGPoint) {
        guard let panel else { return }

        let targetScreen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let clampedOrigin = CGPoint(
            x: min(max(origin.x, visibleFrame.minX + 10), visibleFrame.maxX - panelSize.width - 10),
            y: min(max(origin.y, visibleFrame.minY + 10), visibleFrame.maxY - panelSize.height - 10)
        )

        panel.setFrame(NSRect(origin: clampedOrigin, size: panelSize), display: true)
    }
}

private struct ClickyTextModeInputView: View {
    @State private var text = ""
    @FocusState private var isFocused: Bool
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue

    let submitText: (String) -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.cursor")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(controlColor)

            TextField("", text: $text, prompt: Text("Ask OpenClicky or say Hey OpenClicky Agent...")
                .foregroundColor(placeholderColor)
            )
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(textColor)
                .focused($isFocused)
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(controlColor)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(controlColor.opacity(0.7))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .frame(width: 340, height: 54)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: accentTheme.cursorColor.opacity(0.32), radius: 18, x: 0, y: 0)
        .shadow(color: Color.black.opacity(0.28), radius: 14, x: 0, y: 8)
        .onAppear {
            DispatchQueue.main.async {
                isFocused = true
            }
        }
    }

    private func submit() {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        submitText(trimmedText)
        text = ""
        dismiss()
    }

    private var accentTheme: ClickyAccentTheme {
        ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue
    }

    private var backgroundColor: Color {
        accentTheme.cursorColor
    }

    private var borderColor: Color {
        switch accentTheme {
        case .amber:
            return Color.white.opacity(0.62)
        default:
            return Color.white.opacity(0.26)
        }
    }

    private var textColor: Color {
        switch accentTheme {
        case .amber:
            return Color(hex: "#211B05")
        default:
            return Color.white
        }
    }

    private var placeholderColor: Color {
        textColor.opacity(accentTheme == .amber ? 0.66 : 0.72)
    }

    private var controlColor: Color {
        switch accentTheme {
        case .amber:
            return Color(hex: "#3A3006")
        default:
            return Color.white.opacity(0.88)
        }
    }
}

@MainActor
private final class UserActivityIdleDetector: ObservableObject {
    static let idleThresholdSeconds: TimeInterval = 3.0

    @Published private(set) var isUserIdle = false

    private var lastUserInputTimestamp = Date()
    private var hasUserActedSinceLastObservation = true
    private var globalEventMonitor: Any?
    private var idleCheckTimer: Timer?

    func start() {
        stop()
        lastUserInputTimestamp = Date()
        hasUserActedSinceLastObservation = true

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel, .leftMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordUserActivity()
            }
        }

        idleCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateIdleState()
            }
        }
    }

    func stop() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
        isUserIdle = false
    }

    func observationDidComplete() {
        hasUserActedSinceLastObservation = false
        isUserIdle = false
    }

    private func recordUserActivity() {
        lastUserInputTimestamp = Date()
        hasUserActedSinceLastObservation = true
        isUserIdle = false
    }

    private func evaluateIdleState() {
        let secondsSinceLastInput = Date().timeIntervalSince(lastUserInputTimestamp)
        let isNowIdle = secondsSinceLastInput >= Self.idleThresholdSeconds && hasUserActedSinceLastObservation
        if isNowIdle != isUserIdle {
            isUserIdle = isNowIdle
        }
    }
}

nonisolated private struct OpenClickyDirectActionStoredMemory: Codable, Sendable {
    var folderShortcuts: [OpenClickyDirectActionStoredFolderShortcut]
}

nonisolated private struct OpenClickyDirectActionStoredFolderShortcut: Codable, Sendable {
    var aliases: [String]
    var path: String
    var displayName: String
    var lastUsedAt: Date
}

private final class OpenClickyDirectActionMemoryStore: @unchecked Sendable {
    static let shared = OpenClickyDirectActionMemoryStore()

    struct FolderShortcut {
        let url: URL
        let displayName: String
    }

    private let fileManager: FileManager
    private let memoryFile: URL
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.jkneen.openclicky.direct-action-memory-writes", qos: .utility)
    private var cachedMemory: OpenClickyDirectActionStoredMemory?

    init(fileManager: FileManager = .default, memoryFile: URL? = nil) {
        self.fileManager = fileManager
        self.memoryFile = memoryFile ?? Self.defaultMemoryFile(fileManager: fileManager)
    }

    func folderShortcut(matching normalizedTranscript: String) -> FolderShortcut? {
        lock.lock()
        defer { lock.unlock() }

        let memory = loadMemoryLocked()
        for shortcut in memory.folderShortcuts {
            guard fileManager.fileExists(atPath: shortcut.path) else { continue }
            guard shortcut.aliases.contains(where: { alias in
                !alias.isEmpty && normalizedTranscript.contains(alias)
            }) else { continue }

            return FolderShortcut(
                url: URL(fileURLWithPath: shortcut.path, isDirectory: true),
                displayName: shortcut.displayName
            )
        }

        return nil
    }

    func recordFolderShortcut(instruction: String, url: URL, displayName: String) {
        lock.lock()
        defer { lock.unlock() }

        let path = url.standardizedFileURL.path
        var memory = loadMemoryLocked()
        let aliases = Self.aliases(forInstruction: instruction, displayName: displayName, path: path)
        guard !aliases.isEmpty else { return }

        if let index = memory.folderShortcuts.firstIndex(where: { $0.path == path }) {
            let mergedAliases = Array(Set(memory.folderShortcuts[index].aliases + aliases)).sorted()
            memory.folderShortcuts[index].aliases = mergedAliases
            memory.folderShortcuts[index].displayName = displayName
            memory.folderShortcuts[index].lastUsedAt = Date()
        } else {
            memory.folderShortcuts.append(
                OpenClickyDirectActionStoredFolderShortcut(
                    aliases: aliases,
                    path: path,
                    displayName: displayName,
                    lastUsedAt: Date()
                )
            )
        }

        cachedMemory = memory
        saveMemoryLocked(memory)
    }

    private func loadMemoryLocked() -> OpenClickyDirectActionStoredMemory {
        if let cachedMemory {
            return cachedMemory
        }

        var memory: OpenClickyDirectActionStoredMemory
        if let data = try? Data(contentsOf: memoryFile),
           let decoded = try? JSONDecoder().decode(OpenClickyDirectActionStoredMemory.self, from: data) {
            memory = decoded
        } else {
            memory = OpenClickyDirectActionStoredMemory(folderShortcuts: [])
        }

        if seedBuiltInShortcutsIfNeeded(&memory) {
            cachedMemory = memory
            saveMemoryLocked(memory)
            return memory
        }

        cachedMemory = memory
        return memory
    }

    private func saveMemoryLocked(_ memory: OpenClickyDirectActionStoredMemory) {
        cachedMemory = memory
        let fileManager = fileManager
        let memoryFile = memoryFile
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(memory)
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "native_cua.direct_action_memory.write_failed",
                fields: [
                    "path": memoryFile.path,
                    "error": error.localizedDescription
                ]
            )
            return
        }

        writeQueue.async {
            do {
                try fileManager.createDirectory(at: memoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: memoryFile, options: [.atomic])
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "native_cua.direct_action_memory.write_failed",
                    fields: [
                        "path": memoryFile.path,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    @discardableResult
    private func seedBuiltInShortcutsIfNeeded(_ memory: inout OpenClickyDirectActionStoredMemory) -> Bool {
        let sourcePath = "/Users/jkneen/Documents/GitHub/openclicky"
        guard fileManager.fileExists(atPath: sourcePath) else { return false }
        guard !memory.folderShortcuts.contains(where: { $0.path == sourcePath }) else { return false }

        memory.folderShortcuts.append(
            OpenClickyDirectActionStoredFolderShortcut(
                aliases: [
                    "clicky folder",
                    "code folder",
                    "open clicky folder",
                    "open clicky source",
                    "openclicky folder",
                    "openclicky source",
                    "project folder",
                    "repo folder",
                    "repository folder",
                    "source code folder",
                    "source folder"
                ],
                path: sourcePath,
                displayName: "the source code folder",
                lastUsedAt: Date()
            )
        )
        return true
    }

    private static func aliases(forInstruction instruction: String, displayName: String, path: String) -> [String] {
        var aliases = Set<String>()

        for candidate in [instruction, displayName] {
            let normalized = normalize(candidate)
            if normalized.count >= 4 {
                aliases.insert(normalized)
            }

            let withoutOpenVerbs = normalized
                .replacingOccurrences(of: "open ", with: "")
                .replacingOccurrences(of: "show ", with: "")
                .replacingOccurrences(of: "reveal ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if withoutOpenVerbs.count >= 4 {
                aliases.insert(withoutOpenVerbs)
            }
        }

        let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
        let normalizedName = normalize(lastPathComponent)
        if normalizedName.count >= 4 {
            aliases.insert(normalizedName)
            aliases.insert("\(normalizedName) folder")
            aliases.insert("\(normalizedName) source")
        }

        return Array(aliases).sorted()
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func defaultMemoryFile(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("direct-computer-use-shortcuts.json", isDirectory: false)
    }
}
