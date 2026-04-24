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

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

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
    let codexHomeManager = CodexHomeManager()
    let nativeComputerUseController = OpenClickyNativeComputerUseController()
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
        return ClaudeAPI(
            apiKey: Self.anthropicAPIKey,
            model: selectedModel
        )
    }()

    private lazy var openAIAPI: OpenAIAPI = {
        return OpenAIAPI(
            apiKey: Self.openAIAPIKey,
            model: selectedModel
        )
    }()

    private lazy var claudeAgentSDKAPI: ClaudeAgentSDKAPI? = {
        return ClaudeAgentSDKAPI(model: selectedModel)
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
    private var announcedAgentFileURLs: Set<String> = []

    private var shortcutTransitionCancellable: AnyCancellable?
    private var controlDoubleTapCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var agentStatusCancellables: [UUID: AnyCancellable] = [:]
    private var agentActivityCancellables: [UUID: AnyCancellable] = [:]
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
    @Published var isTutorModeEnabled: Bool = CompanionManager.initialTutorModeEnabled()
    @Published var isAdvancedModeEnabled: Bool = UserDefaults.standard.bool(forKey: AppBundleConfiguration.userAdvancedModeDefaultsKey)
    private let userActivityIdleDetector = UserActivityIdleDetector()
    private var isTutorObservationInFlight = false

    func setSelectedModel(_ model: String) {
        let resolvedModel = OpenClickyModelCatalog.voiceResponseModel(withID: model).id
        selectedModel = resolvedModel
        UserDefaults.standard.set(resolvedModel, forKey: "selectedVoiceResponseModel")
        claudeAPI.model = resolvedModel
        claudeAgentSDKAPI?.model = resolvedModel
        openAIAPI.model = resolvedModel
    }

    func setSelectedComputerUseModel(_ model: String) {
        let resolvedModel = OpenClickyModelCatalog.computerUseModel(withID: model).id
        selectedComputerUseModel = resolvedModel
        UserDefaults.standard.set(resolvedModel, forKey: "selectedComputerUseModel")
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

    func showSettingsWindow() {
        settingsWindowManager.show(companionManager: self)
    }

    func showLogViewerWindow() {
        logViewerWindowManager.show()
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
        print("OpenClicky start - accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindAgentSessionObservation()
        if isTutorModeEnabled {
            startTutorIdleObservation()
        }
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // before the first voice interaction.
        _ = claudeAPI
        if AppBundleConfiguration.anthropicAPIKey() == nil {
            print("CompanionManager: Anthropic is not configured. Set AnthropicAPIKey in Info.plist or ANTHROPIC_API_KEY in the launch environment.")
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

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
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
                self?.updateAgentDockItem(for: sessionID, status: status)
            }

        agentActivityCancellables[session.id] = session.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id, weak session] _ in
                guard let session else { return }
                self?.updateAgentDockItem(for: sessionID, status: session.status)
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
        return session
    }

    private func handleAgentFoundOpenableFile(_ fileURL: URL, session: CodexAgentSession) {
        let standardizedURL = fileURL.standardizedFileURL
        let eventKey = "\(session.id.uuidString)|\(standardizedURL.path)"
        guard !announcedAgentFileURLs.contains(eventKey) else { return }

        announcedAgentFileURLs.insert(eventKey)
        NSWorkspace.shared.open(standardizedURL)
        speakShortSystemResponse("hey, \(session.title) found \(Self.spokenFileName(for: standardizedURL)), showing it now.")
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
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
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
        print("Companion received transcript: \(finalTranscript)")
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: "voice.transcript",
            fields: [
                "text": finalTranscript
            ]
        )
        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
        if submitPendingAgentVoiceFollowUp(finalTranscript) {
            return
        }
        if handleAgentStatusQuestionIfNeeded(from: finalTranscript) {
            return
        }
        if startAgentTaskIfRequested(from: finalTranscript) {
            return
        }
        sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
    }

    // MARK: - Companion Prompt

    private func startAgentTaskIfRequested(from transcript: String) -> Bool {
        if let taskCreationInstruction = Self.agentTaskCreationInstruction(from: transcript) {
            guard !taskCreationInstruction.isEmpty else {
                speakShortSystemResponse("what should the agent do?")
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

        let explicitInstruction = Self.clickyAgentInstruction(from: transcript)

        if let explicitInstruction {
            guard !explicitInstruction.isEmpty else {
                print("OpenClicky agent trigger detected without an instruction.")
                speakShortSystemResponse("say what you want the agent to do after the agent trigger.")
                return true
            }

            let instruction = Self.normalizedAgentTaskInstruction(from: explicitInstruction)
            if let appOpenRequest = Self.localAppOpenRequest(from: instruction) {
                openRequestedApplication(appOpenRequest)
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

        if let appOpenRequest = Self.localAppOpenRequest(from: transcript) {
            openRequestedApplication(appOpenRequest)
            return true
        }

        if Self.isIncompleteLocalAppOpenRequest(from: transcript) {
            speakShortSystemResponse("what app should I open?")
            return true
        }

        guard let instruction = Self.implicitComputerUseInstruction(from: transcript) else {
            print("OpenClicky agent trigger not detected; routing transcript to voice companion.")
            return false
        }

        guard !instruction.isEmpty else {
            print("OpenClicky agent trigger detected without an instruction.")
            speakShortSystemResponse("say what you want the agent to do after the agent trigger.")
            return true
        }

        let normalizedInstruction = Self.normalizedAgentTaskInstruction(from: instruction)
        if let appOpenRequest = Self.localAppOpenRequest(from: normalizedInstruction) {
            openRequestedApplication(appOpenRequest)
            return true
        }
        if Self.isIncompleteLocalAppOpenRequest(from: normalizedInstruction) {
            speakShortSystemResponse("what app should I open?")
            return true
        }

        print("OpenClicky agent task detected; starting agent task: \(normalizedInstruction)")
        startVoiceAgentTask(instruction: normalizedInstruction)
        return true
    }

    private func openRequestedApplication(_ request: OpenClickyAppOpenRequest) {
        if launchApplication(named: request.appName) {
            speakShortSystemResponse("opening \(request.appName).")
            return
        }

        print("OpenClicky app open fallback to Agent Mode: \(request.instruction)")
        startVoiceAgentTask(instruction: request.instruction)
    }

    private func launchApplication(named appName: String) -> Bool {
        if let bundleIdentifier = Self.applicationBundleIdentifier(for: appName),
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.open(appURL)
        }

        if let appURL = Self.standardApplicationURL(named: appName) {
            return NSWorkspace.shared.open(appURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            print("OpenClicky app open failed for \(appName): \(error)")
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

        lastTranscript = trimmedText
        ClickyAnalytics.trackUserMessageSent(transcript: trimmedText)
        interruptCurrentVoiceResponse()
        clearDetectedElementLocation()

        if handleAgentStatusQuestionIfNeeded(from: trimmedText) {
            return
        }

        if startAgentTaskIfRequested(from: trimmedText) {
            return
        }

        sendTranscriptToClaudeWithScreenshot(transcript: trimmedText)
    }

    private func submitPendingAgentVoiceFollowUp(_ transcript: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }
        guard let sessionID = pendingAgentVoiceFollowUpSessionID else { return false }
        if let createdAt = pendingAgentVoiceFollowUpCreatedAt,
           Date().timeIntervalSince(createdAt) > 90 {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            return false
        }
        pendingAgentVoiceFollowUpSessionID = nil
        pendingAgentVoiceFollowUpCreatedAt = nil

        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else {
            speakShortSystemResponse("i lost track of that agent. open the agent dock and try again.")
            return true
        }

        selectCodexAgentSession(sessionID)
        submitAgentPrompt(trimmedTranscript, to: session)
        speakShortSystemResponse("sent that to \(session.title).")
        return true
    }

    private func handleAgentStatusQuestionIfNeeded(from transcript: String) -> Bool {
        guard Self.isAgentStatusQuestion(transcript) else { return false }

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

    private static func agentTaskCreationInstruction(from transcript: String) -> String? {
        let candidate = normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:create|start|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|codex)\s*(?:task|job|session)?\s+(?:to|for|that|which|who)?\s*(.+?)\s*$"#,
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:ask|tell|have|get)\s+(?:an?\s+|the\s+)?(?:agent|codex)\s+to\s+(.+?)\s*$"#
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

    private static func isIncompleteAgentTaskCreationRequest(from transcript: String) -> Bool {
        let candidate = normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return false }

        let patterns = [
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:create|start|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|codex)\s*(?:task|job|session)?[\s\.\!\?]*$"#,
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

    private static func agentTaskDirective(from responseText: String) -> String? {
        let pattern = #"(?is)\[AGENT_TASK:\s*(.+?)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(responseText.startIndex..<responseText.endIndex, in: responseText)
        guard let match = regex.firstMatch(in: responseText, range: range),
              let instructionRange = Range(match.range(at: 1), in: responseText) else {
            return nil
        }

        let instruction = cleanedAgentTaskInstruction(String(responseText[instructionRange]))
        return instruction.isEmpty ? nil : instruction
    }

    private static func localAppOpenRequest(from transcript: String) -> OpenClickyAppOpenRequest? {
        let trimmedTranscript = normalizedCommandCandidate(from: transcript)
        guard !trimmedTranscript.isEmpty else { return nil }

        let pattern = #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:(?:ask|tell)\s+(?:an?\s+|the\s+)?agent\s+to\s+)?(?:open|launch|start|switch\s+to)\s+(?:up\s+)?(.+?)(?:\s+for\s+me)?[\.\!\?]*\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmedTranscript,
                range: NSRange(trimmedTranscript.startIndex..<trimmedTranscript.endIndex, in: trimmedTranscript)
              ),
              let targetRange = Range(match.range(at: 1), in: trimmedTranscript) else {
            return nil
        }

        let rawTarget = String(trimmedTranscript[targetRange])
        let normalizedTarget = normalizedApplicationName(from: rawTarget)
        guard !normalizedTarget.isEmpty else { return nil }

        return OpenClickyAppOpenRequest(
            appName: normalizedTarget,
            instruction: "Open \(normalizedTarget)."
        )
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

        return candidate
    }

    private static func normalizedApplicationName(from rawTarget: String) -> String {
        var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        target = target.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

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

    private static func applicationBundleIdentifier(for appName: String) -> String? {
        switch appName {
        case "Google Chrome":
            return "com.google.Chrome"
        case "Safari":
            return "com.apple.Safari"
        case "Xcode":
            return "com.apple.dt.Xcode"
        case "Terminal":
            return "com.apple.Terminal"
        case "Finder":
            return "com.apple.finder"
        case "System Settings":
            return "com.apple.systempreferences"
        case "Mail":
            return "com.apple.mail"
        case "Messages":
            return "com.apple.MobileSMS"
        case "Notes":
            return "com.apple.Notes"
        case "Calendar":
            return "com.apple.iCal"
        case "Slack":
            return "com.tinyspeck.slackmacgap"
        default:
            return nil
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

    private static func implicitComputerUseInstruction(from transcript: String) -> String? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return nil }

        let foldedTranscript = trimmedTranscript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokenMatches = foldedTranscript.matches(of: /[A-Za-z0-9]+/)
        let tokens = tokenMatches.map { match in
            String(foldedTranscript[match.range]).lowercased()
        }
        guard !tokens.isEmpty else { return nil }

        if beginsWithInstructionQuestion(tokens) {
            return nil
        }

        if hasPoliteComputerUseRequest(tokens) || startsWithComputerUseAction(tokens) {
            return trimmedTranscript
        }

        return nil
    }

    private static func beginsWithInstructionQuestion(_ tokens: [String]) -> Bool {
        guard let firstToken = tokens.first else { return false }
        switch firstToken {
        case "how", "where", "what", "why", "when":
            return true
        default:
            return false
        }
    }

    private static func hasPoliteComputerUseRequest(_ tokens: [String]) -> Bool {
        for index in tokens.indices {
            let token = tokens[index]
            let nextIndex = index + 1
            let secondNextIndex = index + 2

            if token == "please",
               nextIndex < tokens.count,
               isComputerUseActionVerb(tokens[nextIndex]) {
                return true
            }

            if ["can", "could", "would", "will"].contains(token),
               nextIndex < tokens.count,
               tokens[nextIndex] == "you",
               secondNextIndex < tokens.count,
               isComputerUseActionVerb(tokens[secondNextIndex]) {
                return true
            }
        }

        return false
    }

    private static func startsWithComputerUseAction(_ tokens: [String]) -> Bool {
        var index = 0
        while index < tokens.count, ["hey", "ok", "okay", "please"].contains(tokens[index]) {
            index += 1
        }
        guard index < tokens.count else { return false }
        return isComputerUseActionVerb(tokens[index])
    }

    private static func isComputerUseActionVerb(_ token: String) -> Bool {
        switch token {
        case "open", "launch", "start", "switch", "close", "quit", "click", "press", "type", "scroll", "drag", "move", "select", "choose", "use", "search", "browse", "research", "find":
            return true
        default:
            return false
        }
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

    private func startVoiceAgentTask(instruction: String) {
        interruptCurrentVoiceResponse()
        ensureCursorOverlayVisibleForAgentTask()

        let dockItemID = UUID()
        let acknowledgement = "got it. i started an agent for \(Self.shortAgentInstructionSummary(instruction))."
        let accentTheme = Self.nextAgentDockAccentTheme(existingCount: codexAgentSessions.count)
        let agentSession = createAndSelectNewCodexAgentSession(
            title: Self.shortAgentInstructionSummary(instruction),
            accentTheme: accentTheme
        )
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
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "openclicky.agent_task.created",
            fields: [
                "sessionID": agentSession.id.uuidString,
                "title": agentSession.title,
                "instruction": instruction
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
        case .failed:
            agentDockItems[itemIndex].status = .failed
            agentDockItems[itemIndex].caption = activitySummary ?? "Needs attention. Ask for agent status to hear the error."
        case .stopped:
            break
        }
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
        agentDockItems.removeAll { $0.id == itemID }
        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }
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
        submitAgentPrompt(trimmedText, to: codexAgentSession)
        if isAdvancedModeEnabled {
            showCodexHUD()
        }
    }

    func submitAgentPromptFromUI(_ prompt: String) {
        submitAgentPrompt(prompt, to: codexAgentSession)
    }

    private func submitAgentPrompt(_ prompt: String, to session: CodexAgentSession) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        Task {
            let screenContext = await prepareAgentScreenContextForNextTurn()
            session.submitPromptFromUI(trimmedPrompt, screenContext: screenContext)
        }
    }

    private func interruptCurrentVoiceResponse() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
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
            if nativeComputerUseController.isEnabled {
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
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - OpenClicky can open apps and use the computer through Agent Mode. direct action requests like "open chrome", "click that", "type this", "scroll down", or "switch to safari" are normally routed to Agent Mode before you answer. if the user asks whether you can do those things, say yes: OpenClicky can do that through Agent Mode.
    - if the user asks you to create, start, spawn, run, launch, or set up an agent task and that request reaches this voice model, do not say you will do it in normal prose. return exactly [AGENT_TASK: the task the agent should do] and no other text. OpenClicky will create the background agent from that directive.
    - you do not have live web, search, or weather tools in this voice path. for current weather, live news, prices, schedules, or anything time-sensitive that is not visible on screen, say that live lookup is not wired into voice yet and suggest using agent mode for a live research task. do not invent current weather.
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

    private static let tutorModeSystemPrompt = """
    you're OpenClicky in tutor mode. the user wants to learn the app or workflow currently on screen, and you can see their focused window.

    your job:
    - proactively guide them one step at a time when they pause.
    - point at the button, menu, field, panel, or visible area they should use next.
    - know that OpenClicky can open apps and use the computer through Agent Mode when the user gives a direct action request.
    - if they completed a step, acknowledge it briefly and give the next step.
    - if they appear off track, gently redirect.
    - teach concepts only when they are useful for the next action.
    - avoid repeating prior tutor observations; use the conversation history to continue.

    style:
    - short spoken response, lowercase, casual, no markdown, no emojis.
    - do not claim you clicked or controlled anything in tutor observations. you can guide and point; direct action requests are handled by Agent Mode.

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

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            self.voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context.
                let screenCaptures = try await captureAllScreensForVoiceResponseIfAvailable()

                guard !Task.isCancelled else { return }

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
                let memoryContext = codexHomeManager.persistentMemoryContext()
                let voiceSystemPrompt = """
                \(Self.companionVoiceResponseSystemPrompt)

                persistent memory:
                read this as durable user/project context. do not say you cannot remember outside the conversation; use this memory.

                \(memoryContext)
                """

                let fullResponseText = try await analyzeVoiceResponse(
                    images: labeledImages,
                    systemPrompt: voiceSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: userPromptForClaude,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                if let agentInstruction = Self.agentTaskDirective(from: fullResponseText) {
                    startVoiceAgentTask(instruction: agentInstruction)
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

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText) {
                            self.voiceState = .responding
                        }
                    } catch {
                        guard !Self.isExpectedCancellation(error) else { return }
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakResponseFailureFallback(error)
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch where Self.isExpectedCancellation(error) {
                // User spoke again — URLSession/AVFoundation surfaced cancellation as NSError.
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
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)

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
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        if AppBundleConfiguration.anthropicAPIKey() != nil {
            claudeAPI.model = model
            let (text, _) = try await claudeAPI.analyzeImageStreaming(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
            return text
        }

        guard let claudeAgentSDKAPI else {
            throw NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Claude is not configured. Sign in to Claude Code locally or set an Anthropic API key."]
            )
        }

        claudeAgentSDKAPI.model = model
        let (text, _) = try await claudeAgentSDKAPI.analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
        return text
    }

    private func analyzeOpenAIOrCodexVoiceResponse(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        if AppBundleConfiguration.openAIAPIKey() != nil {
            openAIAPI.model = model
            let (text, _) = try await openAIAPI.analyzeImage(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )
            onTextChunk(text)
            return text
        }

        return try await analyzeCodexVoiceResponse(
            images: images,
            model: model,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
    }

    private func analyzeCodexVoiceResponse(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let detector = CodexPointDetector(model: model)
        return try await detector.analyzeImageResponse(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
    }

    private func captureAllScreensForVoiceResponseIfAvailable() async throws -> [CompanionScreenCapture] {
        try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
    }

    private func analyzeComputerUsePointingResponse(
        image: (data: Data, label: String),
        capture: CompanionScreenCapture,
        systemPrompt: String,
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
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

        let screenRelatedPhrases = [
            "this",
            "that",
            "here",
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
            codexAgentSession.dismissLatestResponseCard()
        } else {
            latestVoiceResponseCard = nil
        }
    }

    func runSuggestedNextAction(_ actionTitle: String) {
        let trimmedActionTitle = actionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedActionTitle.isEmpty else { return }
        submitAgentPrompt(trimmedActionTitle, to: codexAgentSession)
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
