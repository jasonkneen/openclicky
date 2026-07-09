//
//  CompanionManager.swift
//  cursor-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreAudio
import Foundation
import os
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import OpenClickyCore
import OpenClickyUI
@preconcurrency import OpenClickyBrowser
import OpenClickyMarkdown
import OpenClickyMemory

enum CompanionVoiceState: String {
    case idle
    case listening
    case processing
    case responding
}

enum OpenClickyCompanionRuntimeMode {
    case menuBar
    case embeddedWindow
}

struct OpenClickyExternalProxyCursor: Identifiable {
    let id: UUID
    var screenLocation: CGPoint
    var caption: String?
    var accentHex: String?
}

private struct OpenClickyPendingVisualGuidanceCalibrationAnchor {
    let overlayID: UUID
    let caption: String
    let predictedRect: CGRect
    let screenFrame: CGRect
    let screenshotWidthInPixels: Int?
    let screenshotHeightInPixels: Int?
    let displayNativeWidthInPixels: Int?
    let displayNativeHeightInPixels: Int?
    let createdAt: Date
}

@MainActor
final class CursorOverlayState: ObservableObject {
    @Published var voiceState: CompanionVoiceState = .idle
    @Published var currentAudioPowerLevel: CGFloat = 0
    @Published var detectedElementScreenLocation: CGPoint?
    @Published var detectedElementDisplayFrame: CGRect?
    @Published var detectedElementBubbleText: String?
    @Published var detectedElementReturnsImmediately: Bool = false
    @Published var agentTaskBubbleText: String?
    @Published var externalPrimaryCaptionText: String?
    @Published var externalPrimaryCaptionAccentHex: String?
    @Published var externalSecondaryCursors: [OpenClickyExternalProxyCursor] = []
    @Published var visualGuidanceOverlays: [OpenClickyVisualGuidanceOverlay] = []
    /// Live freehand trail while push-to-talk circle-select is active (AppKit screen coords).
    @Published var circleSelectLivePoints: [CGPoint] = []
    /// Intelligent snap rect locked after a completed circle (AppKit screen coords).
    @Published var circleSelectSnappedRect: CGRect?
    @Published var circleSelectSnapLabel: String?
    @Published var activeControlGlowRect: CGRect?
    @Published var activeControlGlowLabel: String?
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
    /// Full, untruncated instruction the user gave the agent. Used by the
    /// conversation preview's YOU bubble so the user can see exactly what was
    /// requested (the short `title` is reserved for compact dock labels).
    var userInstruction: String
    var accentTheme: ClickyAccentTheme
    var status: ClickyAgentDockStatus
    var progressStageLabel: String
    var progressStepText: String?
    var activityStatusLines: [String]
    var caption: String?
    var suggestedNextActions: [String]
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

private struct OpenClickyNativeClickRequest {
    let targetDescription: String
    let targetPhrase: String?
    let prefersLastPointedElement: Bool
}

private struct OpenClickyFolderOpenRequest {
    let url: URL
    let displayName: String
    let instruction: String
}

private struct OpenClickyWebOpenRequest {
    let url: URL
    let displayName: String
    let instruction: String
    let browserAppName: String?
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

private struct OpenClickyCompositeAppActionRequest {
    let appName: String
    let actionText: String
    let instruction: String
}

private struct OpenClickyCompositeAppSearchActionRequest {
    let appName: String
    let query: String
    let instruction: String
}

private struct OpenClickySpotifyPlaybackControlAction {
    enum Kind: String {
        case play
        case pause
        case playPause
        case next
        case previous
        case shuffleOn
        case shuffleOff
        case repeatOn
        case repeatOff
        case volumeUp
        case volumeDown
        case volumeMute
        case volumeSet
    }

    let kind: Kind
    let volumePercent: Int?

    var rawValue: String {
        if kind == .volumeSet, let volumePercent {
            return "\(kind.rawValue):\(volumePercent)"
        }
        return kind.rawValue
    }

    init(_ kind: Kind, volumePercent: Int? = nil) {
        self.kind = kind
        self.volumePercent = volumePercent
    }
}

private struct OpenClickySystemVolumeControlAction {
    enum Kind: String {
        case volumeUp
        case volumeDown
        case mute
        case setVolume
    }

    let kind: Kind
    let volumePercent: Int?

    var rawValue: String {
        if kind == .setVolume, let volumePercent {
            return "\(kind.rawValue):\(volumePercent)"
        }
        return kind.rawValue
    }

    init(_ kind: Kind, volumePercent: Int? = nil) {
        self.kind = kind
        self.volumePercent = volumePercent
    }
}

enum OpenClickyComputerUsePointingResolver: String {
    case openAIRealtime = "openai_realtime"
    case anthropicAPI = "anthropic_api"
    case codexCLI = "codex_cli"
    case openAIResponses = "openai_responses"
    case unsupported = "unsupported"
}

nonisolated private struct OpenClickyLocalAutomationResult: Sendable {
    let output: String
    let errorOutput: String
    let terminationStatus: Int32
}

struct OpenClickyRequestTiming {
    let requestID: String
    let source: String
    let text: String
    let requestedAt: Date
}

// M1: previously this was `@unchecked Sendable` with an unsynchronised `var
// didComplete` — safe only because all access happened to land on the main
// actor, with nothing enforcing that. Now the flag is guarded by an
// OSAllocatedUnfairLock so the invariant holds regardless of caller context.
final class OpenClickyRequestCompletionState: @unchecked Sendable {
    private let didCompleteStorage = OSAllocatedUnfairLock(initialState: false)
    var didComplete: Bool {
        get { didCompleteStorage.withLock { $0 } }
        set { didCompleteStorage.withLock { $0 = newValue } }
    }
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

nonisolated private enum OpenClickySystemOutputVolume {
    static func currentScalar() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        if let master = scalar(for: deviceID, element: kAudioObjectPropertyElementMain) {
            return master
        }

        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
            .compactMap { scalar(for: deviceID, element: $0) }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Float(channels.count)
    }

    @discardableResult
    static func setScalar(_ scalar: Float) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }
        let clampedScalar = min(max(scalar, 0), 1)
        if setScalar(clampedScalar, for: deviceID, element: kAudioObjectPropertyElementMain) {
            return true
        }

        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
        return channels
            .map { setScalar(clampedScalar, for: deviceID, element: $0) }
            .contains(true)
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == 0, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private static func scalar(for deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == 0 else { return nil }
        return Float(value)
    }

    private static func setScalar(
        _ scalar: Float,
        for deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == 0,
              settable.boolValue else {
            return false
        }

        var value = Float32(scalar)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == 0
    }

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }
}

@MainActor
private final class OpenClickyWakeWordAudioDucker {
    private let duckedVolume: Float = 0.08
    private var restoreVolume: Float?
    private var isDucked = false
    private var outputVolumeUnavailableLogged = false

    func duck(reason: String) {
        guard !isDucked else {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.wake_word.audio_duck_unchanged",
                fields: ["reason": reason]
            )
            return
        }

        guard let currentVolume = OpenClickySystemOutputVolume.currentScalar() else {
            if !outputVolumeUnavailableLogged {
                outputVolumeUnavailableLogged = true
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "internal",
                    event: "voice.wake_word.audio_duck_skipped",
                    fields: [
                        "reason": reason,
                        "skipReason": "default_output_volume_unavailable"
                    ]
                )
            }
            return
        }
        outputVolumeUnavailableLogged = false

        let targetVolume = min(currentVolume, duckedVolume)
        guard currentVolume <= duckedVolume || OpenClickySystemOutputVolume.setScalar(targetVolume) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.wake_word.audio_duck_failed",
                fields: [
                    "reason": reason,
                    "previousVolume": currentVolume,
                    "targetVolume": targetVolume,
                    "error": "output_volume_not_settable"
                ]
            )
            return
        }

        restoreVolume = currentVolume
        isDucked = true
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.wake_word.audio_ducked",
            fields: [
                "reason": reason,
                "previousVolume": currentVolume,
                "targetVolume": targetVolume
            ]
        )
    }

    func restore(reason: String) {
        guard isDucked else { return }
        let previousVolume = restoreVolume
        restoreVolume = nil
        isDucked = false

        guard let previousVolume else { return }
        let didRestore = OpenClickySystemOutputVolume.setScalar(previousVolume)
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: didRestore ? "internal" : "error",
            event: didRestore ? "voice.wake_word.audio_restored" : "voice.wake_word.audio_restore_failed",
            fields: [
                "reason": reason,
                "restoredVolume": previousVolume
            ]
        )
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    let cursorOverlayState = CursorOverlayState()
    @Published var voiceState: CompanionVoiceState = .idle {
        didSet {
            cursorOverlayState.voiceState = voiceState
            notchCaptureWindowManager.updateVoiceState(Self.notchVoicePhase(for: voiceState), audioPowerLevel: currentAudioPowerLevel)
            if voiceState == .idle, oldValue != .idle {
                scheduleVoiceResponseCaptionClear(after: 1.2)
                wakeWordAudioDucker.restore(reason: "voice_idle")
                scheduleWakeWordListeningResumeIfNeeded(reason: "voice_idle")
            }
            // Cancel any existing watchdog and reschedule when entering
            // .processing — any subsequent state change cancels it.
            processingWatchdogTask?.cancel()
            processingWatchdogTask = nil
            if voiceState == .processing {
                processingWatchdogTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.processingWatchdogTimeout * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    self.recoverFromStuckProcessingStateIfNeeded()
                }
            }
        }
    }
    @Published private(set) var lastTranscript: String?
    private(set) var currentAudioPowerLevel: CGFloat = 0 {
        didSet {
            cursorOverlayState.currentAudioPowerLevel = currentAudioPowerLevel
            notchCaptureWindowManager.updateAudioPowerLevel(currentAudioPowerLevel)
        }
    }
    private static func notchVoicePhase(for voiceState: CompanionVoiceState) -> OpenClickyNotchVoicePhase {
        switch voiceState {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return .processing
        case .responding: return .responding
        }
    }

    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var hasFullDiskAccessPermission = false
    @Published private(set) var hasSystemEventsAutomationPermission = false
    @Published private(set) var hasCameraPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    var detectedElementScreenLocation: CGPoint? {
        didSet {
            updateCursorOverlayState { [detectedElementScreenLocation] overlayState in
                overlayState.detectedElementScreenLocation = detectedElementScreenLocation
            }
        }
    }
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    var detectedElementDisplayFrame: CGRect? {
        didSet {
            updateCursorOverlayState { [detectedElementDisplayFrame] overlayState in
                overlayState.detectedElementDisplayFrame = detectedElementDisplayFrame
            }
        }
    }
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    var detectedElementBubbleText: String? {
        didSet {
            updateCursorOverlayState { [detectedElementBubbleText] overlayState in
                overlayState.detectedElementBubbleText = detectedElementBubbleText
            }
        }
    }
    /// True for task-start handoff flights that should tag the corner briefly
    /// and come straight back instead of holding a pointing caption.
    var detectedElementReturnsImmediately: Bool = false {
        didSet {
            updateCursorOverlayState { [detectedElementReturnsImmediately] overlayState in
                overlayState.detectedElementReturnsImmediately = detectedElementReturnsImmediately
            }
        }
    }
    private var lastPointedElementScreenLocation: CGPoint?
    private var lastPointedElementDisplayFrame: CGRect?
    private var lastPointedElementLabel: String?
    private var lastPointedElementAt: Date?

    private func updateCursorOverlayState(_ apply: @escaping @MainActor (CursorOverlayState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            apply(self.cursorOverlayState)
        }
    }

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    var onboardingVideoEndObserver: NSObjectProtocol?
    var onboardingDemoTimeObserver: Any?

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
    let wakeWordManager = OpenClickyWakeWordManager()
    private let wakeWordAudioDucker = OpenClickyWakeWordAudioDucker()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let notchCaptureWindowManager = OpenClickyNotchCaptureWindowManager()
    let agentDockWindowManager = ClickyAgentDockWindowManager()
    let agentMenuBarStatusManager = AgentMenuBarStatusManager()
    let settingsWindowManager = OpenClickySettingsWindowManager()
    let visualIntelligenceWindowManager = OpenClickyVisualIntelligenceWindowManager()
    let logViewerWindowManager = OpenClickyLogViewerWindowManager()
    let markdownViewerWindowManager = OpenClickyMarkdownViewerWindowManager()
    let widgetStateStore = OpenClickyWidgetStateStore()
    let codexHomeManager = CodexHomeManager()
    let nativeComputerUseController = OpenClickyNativeComputerUseController()
    let backgroundComputerUseController = OpenClickyBackgroundComputerUseController()
    @Published private(set) var codexAgentSessions: [CodexAgentSession]
    @Published private(set) var activeCodexAgentSessionID: UUID
    /// Session IDs the user has archived from the chat sidebar. Persisted to UserDefaults.
    /// Archived sessions remain in `codexAgentSessions` so transcripts/state are preserved;
    /// the sidebar simply hides them under an Archived section.
    @Published private(set) var archivedSessionIDs: Set<UUID> = ChatWorkspaceArchiveStore.load()
    let codexHUDWindowManager = CodexHUDWindowManager()
    let wikiViewerPanelManager = WikiViewerPanelManager()
    @Published private(set) var bundledKnowledgeIndex = OpenClickyCore.WikiManager.Index.empty
    @Published var latestVoiceResponseCard: ClickyResponseCard?
    @Published private(set) var homeChatEntries: [CodexTranscriptEntry] = []
    @Published private(set) var isHomeChatModeActive = false
    @Published var handoffQueue: [HandoffQueuedRegionScreenshot] = []
    /// Sealed circle-while-talking stroke from the most recent PTT hold, awaiting voice/agent attach.
    private(set) var pendingCircleSelectStroke: CircleSelectSealedStroke?
    /// Crop capture started at PTT release so the final transcript can attach without extra latency.
    private var pendingCircleSelectCaptureTask: Task<HandoffQueuedRegionScreenshot?, Never>?
    /// A sealed circle belongs to one just-finished voice hold. It must not
    /// survive indefinitely and become context for a later, unrelated task.
    private var pendingCircleSelectExpiryTask: Task<Void, Never>?
    /// Live partial transcript while PTT is held — used to bias circle snap to spoken items.
    private var circleSelectLivePartialTranscript: String = ""
    let circleSelectSession = CircleSelectSession()
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

    lazy var claudeAPI: ClaudeAPI = {
        let modelOption = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        return ClaudeAPI(
            apiKey: Self.anthropicAPIKey,
            model: modelOption.id,
            maxOutputTokens: modelOption.maxOutputTokens
        )
    }()

    lazy var openAIAPI: OpenAIAPI = {
        let modelOption = OpenClickyModelCatalog.voiceAnalysisModel(withID: selectedModel)
        return OpenAIAPI(
            apiKey: Self.openAIAPIKey,
            model: modelOption.id,
            maxOutputTokens: modelOption.maxOutputTokens
        )
    }()

    lazy var claudeAgentSDKAPI: ClaudeAgentSDKAPI? = {
        let modelOption = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        return ClaudeAgentSDKAPI(model: modelOption.id, maxOutputTokens: modelOption.maxOutputTokens)
    }()

    lazy var codexVoiceSession: CodexVoiceSession = {
        let modelOption = OpenClickyModelCatalog.codexVoiceSessionModel(withID: selectedModel)
        return CodexVoiceSession(model: modelOption.id, homeManager: codexHomeManager)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(
            apiKey: Self.elevenLabsAPIKey,
            voiceID: Self.elevenLabsVoiceID
        )
    }()

    private lazy var cartesiaTTSClient: CartesiaTTSClient = {
        return CartesiaTTSClient(
            apiKey: AppBundleConfiguration.cartesiaAPIKey(),
            voiceID: AppBundleConfiguration.cartesiaVoiceID()
        )
    }()

    struct DeepgramTTSConfigurationSnapshot: Equatable {
        let apiKey: String?
        let voiceID: String

        var hasAPIKey: Bool {
            guard let apiKey else { return false }
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        static func current() -> Self {
            Self(
                apiKey: AppBundleConfiguration.deepgramAPIKey(),
                voiceID: AppBundleConfiguration.deepgramTTSVoice()
            )
        }
    }

    private var cachedDeepgramTTSClient: DeepgramTTSClient?
    var cachedDeepgramTTSSnapshot: DeepgramTTSConfigurationSnapshot?
    /// Mirrors `DeepgramTTSClient.makeError(-100, "Deepgram API key is not configured")`.
    /// Used for explicit missing-key diagnostics in `voice.response_failure_silent`.
    static let deepgramNotConfiguredErrorCode = -100

    private var activeDeepgramTTSClient: DeepgramTTSClient {
        getOrBuildDeepgramTTSClient(reason: "access")
    }

    @MainActor
    private func getOrBuildDeepgramTTSClient(reason: String) -> DeepgramTTSClient {
        let currentSnapshot = DeepgramTTSConfigurationSnapshot.current()
        if let cachedDeepgramTTSClient, cachedDeepgramTTSSnapshot == currentSnapshot {
            return cachedDeepgramTTSClient
        }

        let previousSnapshot = cachedDeepgramTTSSnapshot
        cachedDeepgramTTSClient?.stopPlayback()
        let refreshedClient = DeepgramTTSClient(
            apiKey: currentSnapshot.apiKey,
            voiceID: currentSnapshot.voiceID
        )
        cachedDeepgramTTSClient = refreshedClient
        cachedDeepgramTTSSnapshot = currentSnapshot

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.tts_client_refreshed",
            fields: [
                "provider": OpenClickyTTSProvider.deepgram.rawValue,
                "reason": previousSnapshot == nil ? "initial" : reason,
                "keyConfigured": currentSnapshot.hasAPIKey,
                "voiceID": currentSnapshot.voiceID,
                "snapshotChanged": previousSnapshot != currentSnapshot
            ]
        )
        return refreshedClient
    }

    @MainActor
    private func invalidateDeepgramTTSClient(reason: String) {
        let snapshotBeforeInvalidate = cachedDeepgramTTSSnapshot
        let liveSnapshot = DeepgramTTSConfigurationSnapshot.current()
        cachedDeepgramTTSClient?.stopPlayback()
        cachedDeepgramTTSClient = nil
        cachedDeepgramTTSSnapshot = nil
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.tts_client_invalidated",
            fields: [
                "provider": OpenClickyTTSProvider.deepgram.rawValue,
                "reason": reason,
                "keyConfigured": snapshotBeforeInvalidate?.hasAPIKey ?? liveSnapshot.hasAPIKey,
                "voiceID": snapshotBeforeInvalidate?.voiceID ?? liveSnapshot.voiceID,
                "snapshotSource": snapshotBeforeInvalidate == nil ? "live_defaults" : "cached_client"
            ]
        )
    }

    @MainActor
    private func warmDeepgramTTSClientIfActive() {
        guard selectedTTSProvider == .deepgram else { return }
        // Accessing `activeDeepgramTTSClient` rebuilds only when the config
        // snapshot changed; otherwise it returns the cached active client.
        // In either case, warm the active client to avoid cold-start delay.
        let currentClient = activeDeepgramTTSClient
        currentClient.warmUpConnection()
        FillerPhraseLibrary.shared.prepare(client: currentClient)
    }

    @MainActor
    private func warmRealtimeVoiceInputIfNeeded(reason: String) {
        guard !hasCompletedRealtimeVoiceInputWarmupThisLaunch,
              realtimeVoiceInputWarmupTask == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        guard selectedVoiceResponseModel.provider == .openAI,
              OpenClickyModelCatalog.isSpeechModelID(selectedVoiceResponseModel.id) else { return }

        realtimeVoiceInputWarmupTask = Task.detached(priority: .utility) {
            let startedAt = Date()
            do {
                let engine = AVAudioEngine()
                _ = engine.inputNode.outputFormat(forBus: 0)
                engine.prepare()
                try engine.start()
                engine.stop()
                engine.reset()
                await MainActor.run {
                    self.hasCompletedRealtimeVoiceInputWarmupThisLaunch = true
                    self.realtimeVoiceInputWarmupTask = nil
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice",
                        direction: "internal",
                        event: "voice.realtime_bidirectional.input_warmed",
                        fields: [
                            "reason": reason,
                            "startupDurationMs": Self.elapsedMilliseconds(since: startedAt)
                        ]
                    )
                }
            } catch {
                await MainActor.run {
                    self.realtimeVoiceInputWarmupTask = nil
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice",
                        direction: "internal",
                        event: "voice.realtime_bidirectional.input_warmup_failed",
                        fields: [
                            "reason": reason,
                            "error": error.localizedDescription
                        ]
                    )
                }
            }
        }
    }

    private lazy var microsoftEdgeTTSClient: MicrosoftEdgeTTSClient = {
        return MicrosoftEdgeTTSClient(
            voiceID: AppBundleConfiguration.microsoftEdgeVoiceID()
        )
    }()

    lazy var openAIRealtimeSpeechClient: OpenAIRealtimeSpeechClient = {
        return OpenAIRealtimeSpeechClient(
            apiKey: AppBundleConfiguration.openAIAPIKey(),
            model: selectedSpeechModel,
            voiceID: AppBundleConfiguration.openAIRealtimeVoiceID()
        )
    }()

    private lazy var deepgramVoiceAgentClient: DeepgramVoiceAgentClient = {
        return DeepgramVoiceAgentClient(
            apiKey: AppBundleConfiguration.deepgramAPIKey(),
            voiceID: AppBundleConfiguration.deepgramTTSVoice(),
            thinkModel: AppBundleConfiguration.deepgramVoiceAgentThinkModel()
        )
    }()

    /// Currently selected playback engine. Persisted to UserDefaults under
    /// `openClickyTTSProvider` for compatibility with earlier builds.
    @Published var selectedTTSProvider: OpenClickyTTSProvider = {
        let migrationKey = "openClickyRealtimeSpeechPlaybackMigrationV1"
        let explicitSpeechModel = UserDefaults.standard.string(forKey: "openClickySpeechModel")
        let rawPlaybackEngine = UserDefaults.standard.string(forKey: AppBundleConfiguration.userTTSProviderDefaultsKey)
        if explicitSpeechModel != nil,
           rawPlaybackEngine != OpenClickyTTSProvider.openAIRealtime.rawValue,
           !UserDefaults.standard.bool(forKey: migrationKey) {
            UserDefaults.standard.set(OpenClickyTTSProvider.openAIRealtime.rawValue, forKey: AppBundleConfiguration.userTTSProviderDefaultsKey)
            UserDefaults.standard.set(true, forKey: migrationKey)
            return .openAIRealtime
        }
        return OpenClickyTTSProvider.resolve(AppBundleConfiguration.ttsProviderRaw())
    }()

    /// Realtime speech/audio model selection. This is deliberately separate
    /// from `selectedModel`, which chooses the text reasoning model for
    /// OpenClicky's spoken replies.
    @Published var selectedSpeechModel: String = OpenClickyModelCatalog.speechModel(
        withID: UserDefaults.standard.string(forKey: "openClickySpeechModel")
    ).id

    /// Active TTS client for the current provider. All voice playback
    /// paths route through this — voice response, completion narration,
    /// short system responses, filler library. Switching providers in
    /// Settings takes effect on the next utterance.
    var voiceTTSClient: any OpenClickyTTSClient {
        switch selectedTTSProvider {
        case .openAIRealtime: return openAIRealtimeSpeechClient
        case .elevenLabs: return elevenLabsTTSClient
        case .cartesia:   return cartesiaTTSClient
        case .deepgram:   return activeDeepgramTTSClient
        case .microsoftEdge: return microsoftEdgeTTSClient
        }
    }

    /// Logging label for the active TTS provider — used in
    /// `markRequestStageCompleted` so request logs report the provider
    /// that actually handled the audio (not a hardcoded "ElevenLabs").
    var activeTTSControllerName: String {
        switch selectedTTSProvider {
        case .openAIRealtime: return "OpenAIRealtimeSpeechClient"
        case .elevenLabs: return "ElevenLabsTTSClient"
        case .cartesia:   return "CartesiaTTSClient"
        case .deepgram:   return "DeepgramTTSClient"
        case .microsoftEdge: return "MicrosoftEdgeTTSClient"
        }
    }

    private var activeTTSExecutionMethodSpeakText: String {
        switch selectedTTSProvider {
        case .openAIRealtime: return "OpenAIRealtimeSpeechClient.speakText"
        case .elevenLabs: return "ElevenLabsTTSClient.speakText"
        case .cartesia:   return "CartesiaTTSClient.speakText"
        case .deepgram:   return "DeepgramTTSClient.speakText"
        case .microsoftEdge: return "MicrosoftEdgeTTSClient.speakText"
        }
    }

    var activeTTSExecutionMethodBeginStreaming: String {
        switch selectedTTSProvider {
        case .openAIRealtime: return "OpenAIRealtimeSpeechClient.beginStreamingResponse"
        case .elevenLabs: return "ElevenLabsTTSClient.beginStreamingResponse"
        case .cartesia:   return "CartesiaTTSClient.beginStreamingResponse"
        case .deepgram:   return "DeepgramTTSClient.beginStreamingResponse"
        case .microsoftEdge: return "MicrosoftEdgeTTSClient.beginStreamingResponse"
        }
    }

    func setDeepgramTTSVoice(_ voice: String) {
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.userDeepgramTTSVoiceDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: AppBundleConfiguration.userDeepgramTTSVoiceDefaultsKey)
        }
        invalidateDeepgramTTSClient(reason: "deepgram_voice_updated")
        deepgramVoiceAgentClient.updateConfiguration(
            apiKey: AppBundleConfiguration.deepgramAPIKey(),
            voiceID: AppBundleConfiguration.deepgramTTSVoice(),
            thinkModel: AppBundleConfiguration.deepgramVoiceAgentThinkModel()
        )
        warmDeepgramTTSClientIfActive()
    }

    func setMicrosoftEdgeVoiceID(_ voiceID: String) {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.userMicrosoftEdgeVoiceIDDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: AppBundleConfiguration.userMicrosoftEdgeVoiceIDDefaultsKey)
        }
        microsoftEdgeTTSClient.updateConfiguration(
            apiKey: nil,
            voiceID: AppBundleConfiguration.microsoftEdgeVoiceID()
        )
        if selectedTTSProvider == .microsoftEdge {
            FillerPhraseLibrary.shared.prepare(client: microsoftEdgeTTSClient)
        }
    }

    func setTTSProvider(_ provider: OpenClickyTTSProvider) {
        guard selectedTTSProvider != provider else { return }
        // Defer the @Published mutation to the next runloop tick — the
        // SwiftUI Picker invokes this from within a view update, and
        // setting `selectedTTSProvider` synchronously triggers a publish
        // mid-render ("Publishing changes from within view updates...").
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.voiceTTSClient.stopPlayback()
            self.selectedTTSProvider = provider
            UserDefaults.standard.set(provider.rawValue, forKey: AppBundleConfiguration.userTTSProviderDefaultsKey)
            if provider == .deepgram {
                self.invalidateDeepgramTTSClient(reason: "tts_provider_switched")
            }
            self.voiceTTSClient.warmUpConnection()
            FillerPhraseLibrary.shared.prepare(client: self.voiceTTSClient)
        }
    }

    func setSelectedSpeechModel(_ model: String) {
        let resolvedModel = OpenClickyModelCatalog.speechModel(withID: model).id
        guard selectedSpeechModel != resolvedModel else {
            setTTSProvider(.openAIRealtime)
            warmRealtimeVoiceInputIfNeeded(reason: "speech_model_selected")
            return
        }
        selectedSpeechModel = resolvedModel
        openAIRealtimeSpeechClient.model = resolvedModel
        UserDefaults.standard.set(resolvedModel, forKey: "openClickySpeechModel")
        setTTSProvider(.openAIRealtime)
        warmRealtimeVoiceInputIfNeeded(reason: "speech_model_selected")
    }

    func setOpenAIRealtimeVoiceID(_ voiceID: String) {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.userOpenAIRealtimeVoiceIDDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: AppBundleConfiguration.userOpenAIRealtimeVoiceIDDefaultsKey)
        }
        openAIRealtimeSpeechClient.updateConfiguration(
            apiKey: AppBundleConfiguration.openAIAPIKey(),
            voiceID: AppBundleConfiguration.openAIRealtimeVoiceID()
        )
        if selectedTTSProvider == .openAIRealtime {
            FillerPhraseLibrary.shared.prepare(client: openAIRealtimeSpeechClient)
        }
    }

    func setSpeculativePreFireEnabled(_ enabled: Bool) {
        speculativePreFireEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppBundleConfiguration.userSpeculativePreFireDefaultsKey)
        if !enabled { discardActiveSpeculativeFire(reason: "disabled") }
    }

    func setCartesiaAPIKey(_ apiKey: String) {
        persistOptionalSecret(apiKey, defaultsKey: AppBundleConfiguration.userCartesiaAPIKeyDefaultsKey)
        cartesiaTTSClient.updateConfiguration(
            apiKey: AppBundleConfiguration.cartesiaAPIKey(),
            voiceID: AppBundleConfiguration.cartesiaVoiceID()
        )
        if selectedTTSProvider == .cartesia {
            FillerPhraseLibrary.shared.prepare(client: cartesiaTTSClient)
        }
    }

    func setCartesiaVoiceID(_ voiceID: String) {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey)
        }
        cartesiaTTSClient.updateConfiguration(
            apiKey: AppBundleConfiguration.cartesiaAPIKey(),
            voiceID: AppBundleConfiguration.cartesiaVoiceID()
        )
        if selectedTTSProvider == .cartesia {
            FillerPhraseLibrary.shared.prepare(client: cartesiaTTSClient)
        }
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []
    private var compactedVoiceConversationArchive: String?
    private static let activeVoiceConversationHistoryLimit = 8
    private static let compactedVoiceConversationArchiveCharacterLimit = 2_400
    private static let compactedVoiceConversationArchiveDefaultsKey = "openClickyCompactedVoiceConversationArchive"

    func setHomeChatModeActive(_ isActive: Bool, source: String) {
        guard isHomeChatModeActive != isActive else { return }
        isHomeChatModeActive = isActive
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "openclicky.home_chat.mode_changed",
            fields: [
                "source": source,
                "isActive": isActive
            ]
        )
    }

    func submitHomeChatPromptFromUI(_ prompt: String, source: String = "open_clicky_panel_chat") {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        setHomeChatModeActive(true, source: source)
        submitHomeChatPromptToAskAgent(trimmedPrompt, source: source)
    }

    @discardableResult
    private func submitHomeChatVoiceTranscriptIfNeeded(_ transcript: String, source: String) -> Bool {
        guard isHomeChatModeActive else { return false }
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }
        submitHomeChatPromptToAskAgent(trimmedTranscript, source: source)
        return true
    }

    private func submitHomeChatPromptToAskAgent(_ prompt: String, source: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        let session = codexAgentSession
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.home_chat.ask_agent_prompt",
            fields: [
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "instructionLength": trimmedPrompt.count
            ]
        )
        if session.isTurnActiveForChatQueue {
            session.submitPromptFromUI(trimmedPrompt, screenContext: nil)
        } else {
            stageDashboardAgentSubmission(prompt: trimmedPrompt, session: session)
            submitAgentPrompt(trimmedPrompt, to: session)
        }
    }

    private func appendHomeChatEntry(role: CodexTranscriptEntry.Role, text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        if let last = homeChatEntries.last,
           last.role == role,
           SpokenText.normalizedSpokenCommandText(last.text) == SpokenText.normalizedSpokenCommandText(trimmedText),
           Date().timeIntervalSince(last.createdAt) < 4 {
            return
        }
        homeChatEntries.append(CodexTranscriptEntry(role: role, text: trimmedText))
        if homeChatEntries.count > 24 {
            homeChatEntries.removeFirst(homeChatEntries.count - 24)
        }
    }

    func rememberVoiceExchange(userTranscript: String, assistantResponse: String, reason: String) {
        let trimmedUserTranscript = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssistantResponse = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserTranscript.isEmpty, !trimmedAssistantResponse.isEmpty else { return }

        // 3D generation: scan both sides of the exchange for `/3d <prompt>` or
        // `[OPENCLICKY_3D] prompt: "…"` markers. Matches dispatch a generation
        // job (ThreeDGenerationService) and the floating viewer auto-opens.
        let scanned = ThreeDGenerationDispatcher.scanAndDispatch(trimmedUserTranscript)
            + ThreeDGenerationDispatcher.scanAndDispatch(trimmedAssistantResponse)
        if !scanned.isEmpty {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "three_d.dispatcher.matched",
                fields: [
                    "reason": reason,
                    "matchCount": scanned.count,
                    "firstPrompt": scanned.first?.prompt ?? "",
                    "firstStyle": scanned.first?.style.rawValue ?? ""
                ]
            )
        }

        appendHomeChatEntry(role: .user, text: trimmedUserTranscript)
        appendHomeChatEntry(role: .assistant, text: trimmedAssistantResponse)

        conversationHistory.append((
            userTranscript: trimmedUserTranscript,
            assistantResponse: trimmedAssistantResponse
        ))
        compactVoiceConversationHistoryIfNeeded(reason: reason)
        OpenClickyMessageLogStore.shared.appendConversationTurn(
            lane: "voice",
            direction: "incoming",
            role: "user",
            text: trimmedUserTranscript,
            source: reason,
            title: "Voice conversation",
            extraFields: [
                "historyCount": conversationHistory.count,
                "archiveSummaryLength": compactedVoiceConversationArchive?.count ?? 0
            ]
        )
        OpenClickyMessageLogStore.shared.appendConversationTurn(
            lane: "voice",
            direction: "outgoing",
            role: "assistant",
            text: trimmedAssistantResponse,
            source: reason,
            title: "Voice conversation",
            extraFields: [
                "historyCount": conversationHistory.count,
                "archiveSummaryLength": compactedVoiceConversationArchive?.count ?? 0
            ]
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.conversation_history.updated",
            fields: [
                "reason": reason,
                "historyCount": conversationHistory.count,
                "archiveSummaryLength": compactedVoiceConversationArchive?.count ?? 0,
                "userTranscriptLength": trimmedUserTranscript.count,
                "assistantResponseLength": trimmedAssistantResponse.count
            ]
        )
    }

    private func rememberSilentAgentHandoff(userTranscript: String, instruction: String, reason: String) {
        let trimmedUserTranscript = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserTranscript.isEmpty, !trimmedInstruction.isEmpty else { return }

        let contextResponse = Self.agentHandoffVoiceContextResponse(instruction: trimmedInstruction)
        conversationHistory.append((
            userTranscript: trimmedUserTranscript,
            assistantResponse: contextResponse
        ))
        compactVoiceConversationHistoryIfNeeded(reason: reason)
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.agent_handoff_context_preserved",
            fields: [
                "reason": reason,
                "historyCount": conversationHistory.count,
                "archiveSummaryLength": compactedVoiceConversationArchive?.count ?? 0,
                "instructionPreview": Self.voiceArchiveSnippet(trimmedInstruction, limit: 180)
            ]
        )
    }

    func voiceConversationHistoryForAPI() -> [(userPlaceholder: String, assistantResponse: String)] {
        var history: [(userPlaceholder: String, assistantResponse: String)] = []
        if let compactedVoiceConversationArchive,
           !compactedVoiceConversationArchive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            history.append((
                userPlaceholder: "[earlier OpenClicky voice context]",
                assistantResponse: compactedVoiceConversationArchive
            ))
        }
        history.append(contentsOf: conversationHistory.map { entry in
            (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
        })
        return Self.voiceConversationHistoryIncludingRecentUnpairedPrompts(
            baseHistory: history,
            lastPrompt: lastVoiceUserTranscript,
            lastPromptAt: lastVoiceUserTranscriptAt,
            previousPrompt: previousVoiceUserTranscript,
            previousPromptAt: previousVoiceUserTranscriptAt
        )
    }

    static func voiceConversationHistoryIncludingRecentUnpairedPrompts(
        baseHistory: [(userPlaceholder: String, assistantResponse: String)],
        lastPrompt: String?,
        lastPromptAt: Date?,
        previousPrompt: String?,
        previousPromptAt: Date?,
        now: Date = Date()
    ) -> [(userPlaceholder: String, assistantResponse: String)] {
        var history = baseHistory
        var seenPrompts = Set(history.map { SpokenText.normalizedSpokenCommandText($0.userPlaceholder) })
        let candidates: [(String?, Date?)] = [
            (previousPrompt, previousPromptAt),
            (lastPrompt, lastPromptAt)
        ]

        for (candidate, candidateAt) in candidates {
            guard let candidate,
                  let candidateAt,
                  now.timeIntervalSince(candidateAt) <= pendingAgentVoiceFollowUpTTL else {
                continue
            }
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedCandidate = SpokenText.normalizedSpokenCommandText(trimmedCandidate)
            guard !trimmedCandidate.isEmpty,
                  !seenPrompts.contains(normalizedCandidate),
                  !isReferentialAgentInstruction(trimmedCandidate) else {
                continue
            }
            history.append((
                userPlaceholder: trimmedCandidate,
                assistantResponse: "OpenClicky routed that voice request into the app or Agent Mode, so keep it as the current conversation topic."
            ))
            seenPrompts.insert(normalizedCandidate)
        }

        return history
    }

    private func compactVoiceConversationHistoryIfNeeded(reason: String) {
        let activeLimit = Self.activeVoiceConversationHistoryLimit
        guard conversationHistory.count > activeLimit else { return }

        let archiveCount = conversationHistory.count - activeLimit
        let archivedEntries = Array(conversationHistory.prefix(archiveCount))
        conversationHistory.removeFirst(archiveCount)

        let archiveChunk = archivedEntries.map { entry in
            "User: \(Self.voiceArchiveSnippet(entry.userTranscript))\nOpenClicky: \(Self.voiceArchiveSnippet(entry.assistantResponse))"
        }.joined(separator: "\n")

        let mergedArchive: String
        if let existing = compactedVoiceConversationArchive,
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mergedArchive = existing + "\n" + archiveChunk
        } else {
            mergedArchive = archiveChunk
        }
        compactedVoiceConversationArchive = Self.trailingCharacters(
            of: mergedArchive,
            limit: Self.compactedVoiceConversationArchiveCharacterLimit
        )
        persistCompactedVoiceConversationArchive(
            archiveChunk: archiveChunk,
            reason: reason,
            archivedExchangeCount: archivedEntries.count
        )

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.conversation_history.compacted",
            fields: [
                "reason": reason,
                "archivedExchangeCount": archivedEntries.count,
                "activeHistoryCount": conversationHistory.count,
                "archiveSummaryLength": compactedVoiceConversationArchive?.count ?? 0
            ]
        )
    }

    private func persistCompactedVoiceConversationArchive(archiveChunk: String, reason: String, archivedExchangeCount: Int) {
        let savedArchive = compactedVoiceConversationArchive?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !savedArchive.isEmpty else { return }

        UserDefaults.standard.set(savedArchive, forKey: Self.compactedVoiceConversationArchiveDefaultsKey)

        let trimmedChunk = archiveChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChunk.isEmpty else { return }

        do {
            try codexHomeManager.appendPersistentMemoryEvent(
                userRequest: "Automatically compact OpenClicky voice context",
                agentResponse: "Compacted \(archivedExchangeCount) older exchange\(archivedExchangeCount == 1 ? "" : "s") during \(reason): \(trimmedChunk)"
            )
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.conversation_history.compaction_memory_failed",
                fields: [
                    "reason": reason,
                    "archivedExchangeCount": archivedExchangeCount,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private static func voiceArchiveSnippet(_ text: String, limit: Int = 220) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func trailingCharacters(of text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return "…\n" + String(text.suffix(limit))
    }

    func rememberMainConversationUserPrompt(_ transcript: String, source: String) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty,
              trimmedTranscript != "Realtime voice input",
              !Self.isReferentialAgentInstruction(trimmedTranscript) else {
            return
        }
        if let lastVoiceUserTranscript,
           let lastVoiceUserTranscriptAt,
           Date().timeIntervalSince(lastVoiceUserTranscriptAt) < 2,
           SpokenText.normalizedSpokenCommandText(lastVoiceUserTranscript) == SpokenText.normalizedSpokenCommandText(trimmedTranscript) {
            return
        }

        if let lastVoiceUserTranscript {
            previousVoiceUserTranscript = lastVoiceUserTranscript
            previousVoiceUserTranscriptAt = lastVoiceUserTranscriptAt
        }
        lastVoiceUserTranscript = trimmedTranscript
        lastVoiceUserTranscriptAt = Date()
        appendHomeChatEntry(role: .user, text: trimmedTranscript)

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.main_conversation_context.updated",
            fields: [
                "source": source,
                "promptLength": trimmedTranscript.count,
                "promptPreview": String(trimmedTranscript.prefix(160))
            ]
        )
    }

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    var currentResponseTask: Task<Void, Never>?
    var currentResponseTaskToken: UUID?

    func clearCurrentResponseTask(ifMatches token: UUID) {
        guard currentResponseTaskToken == token else { return }
        currentResponseTask = nil
        currentResponseTaskToken = nil
    }
    var currentVoiceResponseRequestID: String?
    var currentVoiceResponseCompletionToken: UUID?
    var currentVoiceResponseCancellationHandler: ((String) -> Void)?
    // System-voice fallback removed. We never speak through
    // AVSpeechSynthesizer — failures stay silent and surface only in
    // the response card and logs.
    private var pendingAgentVoiceFollowUpSessionID: UUID?
    private var pendingAgentVoiceFollowUpCreatedAt: Date?
    private var pendingAgentVoiceFollowUpSource: String?
    /// Set when Haiku's last response offered to spin up an agent
    /// ("want me to spin up an agent to X?"). On the next transcript,
    /// a confirmation ("yes", "okay then", "sure") spawns an agent with
    /// this instruction. Without this glue Haiku's offer dead-ended —
    /// the harness only spawns when the transcript itself says "agent".
    var pendingAgentOfferInstruction: String?
    var pendingAgentOfferAt: Date?
    private var deferredLiveAgentRoutePartial: String?
    private var deferredLiveAgentRoutePartialAt: Date?
    /// Most recent user prompt in the shared instant/voice conversation.
    /// This lets a later referential agent request ("on it", "do that")
    /// resolve to what the user was just talking about, regardless of
    /// whether the prior turn came from push-to-talk, Realtime voice, or
    /// the panel's instant text entry.
    private var lastVoiceUserTranscript: String?
    private var lastVoiceUserTranscriptAt: Date?
    private var previousVoiceUserTranscript: String?
    private var previousVoiceUserTranscriptAt: Date?
    private static let pendingAgentVoiceFollowUpTTL: TimeInterval = 90
    private static let pendingAgentOfferTTL: TimeInterval = 90
    private static let deferredLiveAgentRoutePartialTTL: TimeInterval = 20

    /// Guards against a single voice utterance launching the same agent
    /// task twice when overlapping routes both resolve to an agent start.
    private var lastVoiceAgentStartFingerprint: String?
    private var lastVoiceAgentStartAt: Date?
    private var lastVoiceAgentStartSessionID: UUID?
    private var suppressNextVoiceAgentStartAcknowledgement = false
    private static let voiceAgentStartDuplicateTTL: TimeInterval = 8

    /// Guards against the realtime final-transcript callback and the
    /// realtime tool-route callback both firing for the same utterance,
    /// producing two near-identical requests ~1s apart.
    private var lastRealtimeVoiceRouteFingerprint: String?
    private var lastRealtimeVoiceRouteAt: Date?
    private static let realtimeVoiceRouteDuplicateTTL: TimeInterval = 5

    // MARK: Speculative pre-fire state
    //
    // While the user is still talking, Deepgram emits interim
    // transcripts every ~200ms. When a partial is "stable" (unchanged
    // for ~1.5s) and looks like a pure question with no screen
    // dependency, we kick off a speculative Claude call against that
    // partial. Tokens stream into `speculativeBufferedDelta` but DO NOT
    // play yet — we wait for the user to release the key. If the final
    // transcript matches the partial we fired against, we commit the
    // buffered tokens straight into the TTS pipeline (instant audio).
    // If the final diverges, we cancel and fall through to the normal
    // path. All speculative work runs on its own Task — this never
    // blocks the main actor's cursor tracking, audio capture, or any
    // in-flight Cartesia/ElevenLabs playback.

    /// Whether speculative pre-fire is enabled (Settings → Voice).
    @Published var speculativePreFireEnabled: Bool =
        UserDefaults.standard.bool(forKey: AppBundleConfiguration.userSpeculativePreFireDefaultsKey)

    private var voiceResponseCaptionsEnabled: Bool {
        UserDefaults.standard.object(forKey: AppBundleConfiguration.userVoiceResponseCaptionsEnabledDefaultsKey) as? Bool ?? false
    }

    private struct SpeculativeFire {
        let partialTranscript: String
        let firedAt: Date
        let task: Task<String, Error>
        /// Tokens accumulated from the streaming response. NOT pushed
        /// to TTS yet — held until commit (final matches) or discard.
        var bufferedContinuation: String
        let assistantPrefillText: String?
        let imagesUsed: Int
        let chosenFiller: FillerPhraseLibrary.FillerSelection?
    }
    private var activeSpeculativeFire: SpeculativeFire?
    /// Counter to prevent runaway re-fires when the user keeps
    /// extending a partial across many stability windows.
    private var speculativeFireCountThisUtterance: Int = 0
    private static let speculativeMaxFiresPerUtterance = 2
    private static let speculativeMinWordCount = 4
    /// Last-seen partial text + arrival time, used to detect stability.
    private var lastObservedPartial: String?
    private var lastObservedPartialAt: Date?
    /// Scheduled re-evaluation of stability after the dwell window.
    private var speculativeStabilityDwellTask: Task<Void, Never>?
    private var lastAgentContextSessionID: UUID?
    private var announcedAgentFileURLs: Set<String> = []
    private var pendingSystemAnnouncementTask: Task<Void, Never>?
    private var pendingSystemAnnouncementSessionID: UUID?
    private var speakingSystemAnnouncementSessionID: UUID?
    private var silencedAgentSpeechSessionIDs: Set<UUID> = []
    private var liveHandledComputerUseFingerprints: Set<String> = []
    private var lastAgentProgressNarrationAt: Date?
    /// The phrase last spoken for each running agent session, keyed by
    /// session ID. Used to suppress duplicate progress narrations — we
    /// only speak when the *content* of the activity changed, never just
    /// because a polling tick fired.
    private var lastAgentProgressNarrationSignatures: [UUID: String] = [:]
    private static let agentProgressVoiceUpdatesDefaultsKey = "agentProgressVoiceUpdatesEnabled"
    private var currentFolderContextURL: URL?
    var activeRequestTiming: OpenClickyRequestTiming?
    private var agentRequestTimingsBySessionID: [UUID: OpenClickyRequestTiming] = [:]
    private var agentExecutionStartDatesBySessionID: [UUID: Date] = [:]
    /// Sessions whose terminal outcome (success, failure, cancellation) has
    /// already been narrated — so we don't re-announce on every Combine republish.
    /// Stores outcome labels like "success", "failed", "cancelled".
    private var lastNarratedAgentOutcomeBySessionID: [UUID: String] = [:]

    private var processingWatchdogTask: Task<Void, Never>?
    private static let processingWatchdogTimeout: TimeInterval = 30

    private var shortcutTransitionCancellable: AnyCancellable?
    private var shiftDoubleTapCancellable: AnyCancellable?
    private var escapeKeyCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var externalControlBridgeServer: OpenClickyExternalControlBridgeServer?
    private var externalProxyClearTask: Task<Void, Never>?
    private var agentTaskBubbleClearTask: Task<Void, Never>?
    private var externalPrimaryCursorMoveTask: Task<Void, Never>?
    private var externalSecondaryCursorClearTasks: [UUID: Task<Void, Never>] = [:]
    private var visualGuidanceOverlayClearTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingVisualGuidanceCalibrationAnchor: OpenClickyPendingVisualGuidanceCalibrationAnchor?
    private var activeControlGlowClearTask: Task<Void, Never>?
    private var agentStatusCancellables: [UUID: AnyCancellable] = [:]
    private var agentActivityCancellables: [UUID: AnyCancellable] = [:]
    private var agentLoopActivityCancellables: [UUID: AnyCancellable] = [:]
    private var agentProgressStageCancellables: [UUID: AnyCancellable] = [:]
    private var agentTitleCancellables: [UUID: AnyCancellable] = [:]
    private var pendingAgentActivityRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRelaunchableSnapshotPersistTask: Task<Void, Never>?
    private var pendingRelaunchableAgentResumeTask: Task<Void, Never>?
    private var relaunchableAgentResumeTimer: Timer?
    private var autoResumedRelaunchSessionIDs: Set<UUID> = []
    var tutorIdleCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var pendingAgentDockItemRemovalTasks: [UUID: DispatchWorkItem] = [:]
    private var realtimeVoiceInputWarmupTask: Task<Void, Never>?
    private var hasCompletedRealtimeVoiceInputWarmupThisLaunch = false

    /// Screenshot captured in parallel with audio recording. Started the
    /// instant push-to-talk is pressed so capture latency overlaps with
    /// the user actually speaking instead of running serially after the
    /// final transcript arrives. Consumed by the voice response path and
    /// reset after every request.
    var prewarmedScreenshotTask: Task<[CompanionScreenCapture], Error>?
    var prewarmedScreenshotStartedAt: Date?
    /// Maximum age before a prewarmed screenshot is considered stale.
    /// Push-to-talk plus model latency rarely exceeds this; if it does,
    /// we fall back to a fresh capture so the AI sees current screen state.
    static let prewarmedScreenshotMaxAge: TimeInterval = 8.0
    /// Duration to keep a cancelled dock item visible so users can see
    /// explicit completion text before it auto-dismisses.
    private let cancelledDockItemHoldDuration: TimeInterval = 0.45
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    var transientHideTask: Task<Void, Never>?
    var voiceFollowUpStopTask: Task<Void, Never>?
    private var pendingWakeWordRestartTask: Task<Void, Never>?
    private var isWakeWordPausedByShortcut = false

    /// True when the base OpenClicky experience is ready. Camera access is
    /// deliberately excluded because Visual Intelligence and meeting notes are
    /// opt-in features, not prerequisites for voice, screen, or Agent Mode.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
    }

    var permissionSnapshot: PermissionSnapshot {
        PermissionSnapshot(
            accessibility: hasAccessibilityPermission ? .granted : .missing,
            screenRecording: hasScreenRecordingPermission ? .granted : .missing,
            microphone: hasMicrophonePermission ? .granted : .missing,
            camera: hasCameraPermission ? .granted : .missing,
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
        codexAgentSessions.first { $0.id == activeCodexAgentSessionID }
            ?? codexAgentSessions.first
            ?? CodexAgentSession(title: "Ask Agent", accentTheme: .blue)
    }

    private static func restoredArchivedSessions(from archivedSessionIDs: Set<UUID>) -> [CodexAgentSession] {
        ChatWorkspaceArchiveStore.loadSnapshots().compactMap { snapshot in
            guard archivedSessionIDs.contains(snapshot.id) else { return nil }
            let accentTheme = ClickyAccentTheme(rawValue: snapshot.accentThemeRawValue) ?? .blue
            let session = CodexAgentSession(id: snapshot.id, title: snapshot.title, accentTheme: accentTheme)
            session.restoreArchivedState(
                entries: snapshot.entries,
                activeThreadID: snapshot.activeThreadID,
                lastSubmittedPrompt: snapshot.lastSubmittedPrompt
            )
            return session
        }
    }

    private static func restoredInterruptedSessions(archivedSessionIDs: Set<UUID>) -> [CodexAgentSession] {
        ChatWorkspaceArchiveStore.loadRelaunchableSnapshots().compactMap { snapshot in
            guard !archivedSessionIDs.contains(snapshot.id) else { return nil }
            let accentTheme = ClickyAccentTheme(rawValue: snapshot.accentThemeRawValue) ?? .blue
            let session = CodexAgentSession(id: snapshot.id, title: snapshot.title, accentTheme: accentTheme)
            session.restoreInterruptedRelaunchState(
                entries: snapshot.entries,
                activeThreadID: snapshot.activeThreadID,
                lastSubmittedPrompt: snapshot.lastSubmittedPrompt,
                canResume: snapshot.wasRelaunchResumeCandidate ?? false
            )
            return session
        }
    }

    private static func restoredInterruptedDockItems(from sessions: [CodexAgentSession]) -> [ClickyAgentDockItem] {
        sessions.map { session in
            let prompt = session.lastSubmittedPromptText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resumeCaption = session.canResumeAfterRelaunch
                ? "Open to resume this task after relaunch."
                : "Restored after relaunch."
            return ClickyAgentDockItem(
                id: session.id,
                sessionID: session.id,
                title: session.title,
                userInstruction: prompt?.isEmpty == false ? (prompt ?? session.title) : session.title,
                accentTheme: session.accentTheme,
                status: .failed,
                progressStageLabel: session.canResumeAfterRelaunch ? "Interrupted" : session.progressStage.label,
                progressStepText: session.latestActivityDisplaySummary ?? session.latestActivitySummary ?? resumeCaption,
                activityStatusLines: session.activityStatusLines.isEmpty ? [resumeCaption] : session.activityStatusLines,
                caption: session.latestActivityDisplaySummary ?? session.latestActivitySummary ?? resumeCaption,
                suggestedNextActions: session.latestResponseCard?.suggestedNextActions ?? [],
                createdAt: session.createdAt
            )
        }
    }

    private let runtimeMode: OpenClickyCompanionRuntimeMode

    init(runtimeMode: OpenClickyCompanionRuntimeMode = .menuBar) {
        self.runtimeMode = runtimeMode
        let restoredVoiceArchive = UserDefaults.standard
            .string(forKey: Self.compactedVoiceConversationArchiveDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let restoredVoiceArchive, !restoredVoiceArchive.isEmpty {
            compactedVoiceConversationArchive = restoredVoiceArchive
        }

        let initialAgentSession = CodexAgentSession(title: "Ask Agent", accentTheme: .blue)
        let restoredArchiveIDs = ChatWorkspaceArchiveStore.load()
        archivedSessionIDs = restoredArchiveIDs
        let restoredArchivedSessions = Self.restoredArchivedSessions(from: restoredArchiveIDs)
        let restoredInterruptedSessions = Self.restoredInterruptedSessions(archivedSessionIDs: restoredArchiveIDs)
        codexAgentSessions = restoredInterruptedSessions + [initialAgentSession] + restoredArchivedSessions
        agentDockItems = Self.restoredInterruptedDockItems(from: restoredInterruptedSessions)
        activeCodexAgentSessionID = restoredInterruptedSessions.first?.id ?? initialAgentSession.id
        OpenClickyMessageLogStore.shared.append(
            lane: "system",
            direction: "outgoing",
            event: "openclicky.runtime.started",
            fields: [
                "nativeCUARouterVersion": "direct-cua-explicit-agent-v4",
                "agentAssignment": "explicit-only",
                "computerUseBackend": selectedComputerUseBackendID,
                "restoredInterruptedAgentTasks": restoredInterruptedSessions.count,
                "restoredInterruptedDockItems": agentDockItems.count
            ]
        )
        wakeWordManager.onWakeWordDetected = { [weak self] transcript in
            self?.handleWakeWordDetected(transcript)
        }
        // Bind the automation scheduler so cron / interval prompts can fire
        // through this CompanionManager while the app is running.
        OpenClickyAutomationStore.shared.bind(companion: self)
        // Seed bundled built-in specialist agents on first launch.
        OpenClickyAgentStore.shared.seedBuiltinsFromBundleIfNeeded()
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published var isOverlayVisible: Bool = false

    /// The model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = CompanionManager.initialVoiceResponseModelID()
    @Published var selectedComputerUseModel: String = OpenClickyModelCatalog.computerUseModel(
        withID: UserDefaults.standard.string(forKey: "selectedComputerUseModel") ?? OpenClickyModelCatalog.defaultComputerUseModelID
    ).id
    @Published var selectedComputerUseBackendID: String = OpenClickyComputerUseBackendID.resolving(
        UserDefaults.standard.string(forKey: AppBundleConfiguration.userComputerUseBackendDefaultsKey)
    ).rawValue
    @Published var isTutorModeEnabled: Bool = CompanionManager.initialTutorModeEnabled()
    /// Advanced-mode concept retired — the visible "Ask Agent" panel and the
    /// settings toggle were removed. Hard-coded true so dependent code paths
    /// (agent dashboard, memory icon, computer-use entry points) keep working
    /// for everyone, including users who previously had the toggle off.
    @Published var isAdvancedModeEnabled: Bool = true

    /// Where the agent dock parks itself on the active screen. Persisted
    /// to UserDefaults; defaults to `.topRight`.
    @Published var agentParkingPosition: AgentParkingPosition = {
        if let raw = UserDefaults.standard.string(forKey: AgentParkingPosition.userDefaultsKey),
           let parsed = AgentParkingPosition(rawValue: raw) {
            return parsed
        }
        return .default
    }()

    func setAgentParkingPosition(_ position: AgentParkingPosition) {
        guard agentParkingPosition != position else { return }
        agentParkingPosition = position
        UserDefaults.standard.set(position.rawValue, forKey: AgentParkingPosition.userDefaultsKey)
        // Re-park the dock immediately if it's already on screen so the
        // user sees the change without having to spawn a new agent.
        showAgentDockWindowNearCurrentScreenIfShowing()
    }

    func setAgentParkingCalibrationOffset(_ offset: CGSize, for position: AgentParkingPosition) {
        AgentParkingPosition.setCalibrationOffset(offset, for: position)
        showAgentDockWindowNearCurrentScreenIfShowing()
    }

    private func showAgentDockWindowNearCurrentScreenIfShowing() {
        guard !agentDockItems.isEmpty else { return }
        showAgentDockWindowNearCurrentScreen()
    }

    private func refreshAgentDockFollowBehavior() {
        let shouldAutoFollowCursor = agentDockItems.contains { item in
            item.status == .starting || item.status == .running
        }
        if shouldAutoFollowCursor {
            if agentDockFollowTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard !self.agentDockItems.isEmpty else { return }
                        guard !self.agentDockWindowManager.hasUserPinnedFrame else { return }
                        self.showAgentDockWindowNearCurrentScreen()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                agentDockFollowTimer = timer
            }
        } else {
            agentDockFollowTimer?.invalidate()
            agentDockFollowTimer = nil
        }
    }
    let userActivityIdleDetector = UserActivityIdleDetector()
    let tutorTargetClickTracker = TutorTargetClickTracker()
    var isTutorObservationInFlight = false
    var lastVoiceInteractionCompletedAt: Date = .distantPast
    static let tutorObservationVoiceCooldown: TimeInterval = 90
    private var agentDockFollowTimer: Timer?
    private var isRealtimeBidirectionalVoiceCaptureActive = false
    private var isRealtimeBidirectionalVoiceInputReady = false
    private var pendingRealtimeBidirectionalFinishSource: String?
    private var realtimeBidirectionalVoiceCaptureStartedAt: Date?
    private var realtimeBidirectionalVoiceTask: Task<Void, Never>?
    private var realtimeBidirectionalVoiceStartedAsInterrupt = false
    private static let quickShortcutInterruptSilenceThreshold: TimeInterval = 1.25
    private var realtimeBidirectionalVoiceTurnGeneration: UInt64 = 0

    private static func initialVoiceResponseModelID() -> String {
        let defaults = UserDefaults.standard
        let storedModel = defaults.string(forKey: "selectedVoiceResponseModel")
        let storedSpeechModel = defaults.string(forKey: "openClickySpeechModel")

        let requestedModel = storedModel
            ?? defaults.string(forKey: "selectedClaudeModel")
            ?? OpenClickyModelCatalog.defaultVoiceResponseModelID
        let resolvedModel = OpenClickyModelCatalog.voiceResponseModel(withID: requestedModel).id

        // Persist alias migrations (e.g. gpt-realtime-2 → gpt-realtime-2.1-mini)
        // so Settings and speech paths stop carrying retired IDs.
        if storedModel != resolvedModel {
            defaults.set(resolvedModel, forKey: "selectedVoiceResponseModel")
        }
        if OpenClickyModelCatalog.isSpeechModelID(resolvedModel),
           storedSpeechModel != resolvedModel {
            defaults.set(resolvedModel, forKey: "openClickySpeechModel")
        }

        return resolvedModel
    }

    func setSelectedModel(_ model: String) {
        let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: model)
        let resolvedModel = selectedVoiceResponseModel.id
        selectedModel = resolvedModel
        UserDefaults.standard.set(resolvedModel, forKey: "selectedVoiceResponseModel")

        if OpenClickyModelCatalog.isSpeechModelID(resolvedModel) {
            selectedSpeechModel = resolvedModel
            UserDefaults.standard.set(resolvedModel, forKey: "openClickySpeechModel")
            if selectedVoiceResponseModel.provider == .openAI {
                openAIRealtimeSpeechClient.model = resolvedModel
                setTTSProvider(.openAIRealtime)
                openAIRealtimeSpeechClient.warmUpConnection()
                warmRealtimeVoiceInputIfNeeded(reason: "voice_model_selected")
            } else if selectedVoiceResponseModel.provider == .deepgram {
                deepgramVoiceAgentClient.updateConfiguration(
                    apiKey: AppBundleConfiguration.deepgramAPIKey(),
                    voiceID: AppBundleConfiguration.deepgramTTSVoice(),
                    thinkModel: AppBundleConfiguration.deepgramVoiceAgentThinkModel()
                )
                deepgramVoiceAgentClient.warmUpConnection()
            }
            return
        }

        if selectedTTSProvider == .openAIRealtime {
            setTTSProvider(.cartesia)
        }

        applyVoiceResponseModelSettings(selectedVoiceResponseModel)
        switch selectedVoiceResponseModel.provider {
        case .anthropic:
            // SDK is the primary Claude path — warm it whenever available.
            claudeAgentSDKAPI?.warmUp(systemPrompt: currentVoiceResponseSystemPrompt())
        case .openAI, .codex:
            if selectedVoiceResponseModel.provider == .codex || AppBundleConfiguration.openAIAPIKey() == nil {
                codexVoiceSession.warmUp(systemPrompt: currentVoiceResponseSystemPrompt())
            }
        case .deepgram:
            deepgramVoiceAgentClient.warmUpConnection()
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

    func applyVoiceResponseModelSettings(_ modelOption: OpenClickyModelOption) {
        switch modelOption.provider {
        case .anthropic:
            claudeAPI.model = modelOption.id
            claudeAPI.maxOutputTokens = modelOption.maxOutputTokens
            claudeAgentSDKAPI?.model = modelOption.id
            claudeAgentSDKAPI?.maxOutputTokens = modelOption.maxOutputTokens
        case .openAI:
            let analysisModel = OpenClickyModelCatalog.voiceAnalysisModel(withID: modelOption.id)
            openAIAPI.model = analysisModel.id
            openAIAPI.maxOutputTokens = analysisModel.maxOutputTokens
            codexVoiceSession.model = OpenClickyModelCatalog.codexVoiceSessionModel(withID: analysisModel.id).id
        case .codex:
            codexVoiceSession.model = OpenClickyModelCatalog.codexVoiceSessionModel(withID: modelOption.id).id
        case .deepgram:
            deepgramVoiceAgentClient.updateConfiguration(
                apiKey: AppBundleConfiguration.deepgramAPIKey(),
                voiceID: AppBundleConfiguration.deepgramTTSVoice(),
                thinkModel: AppBundleConfiguration.deepgramVoiceAgentThinkModel()
            )
        }
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

    func requestSystemEventsAutomationPermission() {
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "native_cua.automation_probe.started",
            fields: [
                "target": "System Events"
            ]
        )

        let isGranted = OpenClickyMacPrivacyPermissionProbe.hasSystemEventsAutomationPermission(prompt: true)
        hasSystemEventsAutomationPermission = isGranted

        if isGranted {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "native_cua.automation_probe.ready",
                fields: [
                    "target": "System Events"
                ]
            )
            speakShortSystemResponse("System Events automation is ready.")
        } else {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "native_cua.automation_probe.blocked",
                fields: [
                    "target": "System Events",
                    "error": "Automation permission is missing or denied for com.apple.systemevents"
                ]
            )
            openAutomationSettings()
            speakShortSystemResponse("System Events automation needs approval in Privacy & Security, Automation.")
        }
    }

    func showSettingsWindow() {
        settingsWindowManager.show(companionManager: self)
    }

    func showVisualIntelligenceWorkspace() {
        visualIntelligenceWindowManager.show(companionManager: self)
    }

    func showLogViewerWindow() {
        logViewerWindowManager.show()
    }

    func openOpenClickyDocument(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        if Self.isMarkdownDocument(standardizedURL) {
            markdownViewerWindowManager.show(fileURL: standardizedURL)
        } else {
            NSWorkspace.shared.open(standardizedURL)
        }
    }

    func handleApplicationOpenURL(_ url: URL) {
        if url.isFileURL {
            openOpenClickyDocument(url)
            return
        }

        handleWidgetDeepLink(url)
    }

    func publishWidgetSnapshot() {
        agentMenuBarStatusManager.scheduleSync(companionManager: self)
        widgetStateStore.publishSnapshot(from: self)
    }

    func scheduleWidgetSnapshotPublish() {
        agentMenuBarStatusManager.scheduleSync(companionManager: self)
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
        case "visual", "camera", "meeting":
            showVisualIntelligenceWorkspace()
        default:
            showSettingsWindow()
        }
    }

    func setTutorModeEnabled(_ enabled: Bool) {
        isTutorModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.tutorModeDefaultsKey)
        if enabled {
            showCursorOverlayIfAvailable()
            if runtimeMode == .menuBar {
                startTutorIdleObservation()
            }
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
        invalidateDeepgramTTSClient(reason: "deepgram_key_updated")
        deepgramVoiceAgentClient.updateConfiguration(
            apiKey: AppBundleConfiguration.deepgramAPIKey(),
            voiceID: AppBundleConfiguration.deepgramTTSVoice(),
            thinkModel: AppBundleConfiguration.deepgramVoiceAgentThinkModel()
        )
        warmDeepgramTTSClientIfActive()
    }

    func setDeepgramVoiceAgentThinkModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.userDeepgramVoiceAgentThinkModelDefaultsKey)
        } else {
            UserDefaults.standard.set(AppBundleConfiguration.normalizeDeepgramVoiceAgentThinkModel(trimmed), forKey: AppBundleConfiguration.userDeepgramVoiceAgentThinkModelDefaultsKey)
        }
        deepgramVoiceAgentClient.updateConfiguration(
            apiKey: AppBundleConfiguration.deepgramAPIKey(),
            voiceID: AppBundleConfiguration.deepgramTTSVoice(),
            thinkModel: AppBundleConfiguration.deepgramVoiceAgentThinkModel()
        )
    }

    func setVoiceTranscriptionProvider(_ providerID: String) {
        buddyDictationManager.setTranscriptionProvider(providerID)
    }

    func setCodexAgentAPIKey(_ apiKey: String) {
        persistOptionalSecret(apiKey, defaultsKey: AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey)
        openAIAPI.setAPIKey(AppBundleConfiguration.openAIAPIKey())
        openAIRealtimeSpeechClient.updateConfiguration(
            apiKey: AppBundleConfiguration.openAIAPIKey(),
            voiceID: openAIRealtimeSpeechClient.voiceID
        )
        codexAgentSessions.forEach { $0.stop(reason: "api_key_reconfigured") }
    }

    private func persistOptionalSecret(_ value: String, defaultsKey: String) {
        AppBundleConfiguration.persistSecret(value, defaultsKey: defaultsKey)
    }

    /// User preference for whether the OpenClicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    @Published var isActivationShortcutEnabled: Bool = true
    @Published var voiceActivationMode: OpenClickyVoiceActivationMode = OpenClickyVoiceActivationMode.resolved(
        rawValue: UserDefaults.standard.string(forKey: AppBundleConfiguration.userVoiceActivationModeDefaultsKey)
    )

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            showCursorOverlayIfAvailable()
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    func setActivationShortcutEnabled(_ enabled: Bool) {
        isActivationShortcutEnabled = enabled
        globalPushToTalkShortcutMonitor.setActivationShortcutEnabled(enabled)
        if !enabled {
            isWakeWordPausedByShortcut = true
            wakeWordManager.stop(reason: "activation_shortcut_disabled")
        } else {
            isWakeWordPausedByShortcut = false
            startWakeWordListeningIfNeeded(reason: "activation_shortcut_enabled")
        }
    }

    func setVoiceActivationMode(_ mode: OpenClickyVoiceActivationMode) {
        guard voiceActivationMode != mode else { return }
        voiceActivationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: AppBundleConfiguration.userVoiceActivationModeDefaultsKey)
        if mode.usesWakeWord {
            isWakeWordPausedByShortcut = false
            startWakeWordListeningIfNeeded(reason: "mode_changed")
        } else {
            isWakeWordPausedByShortcut = false
            wakeWordManager.stop(reason: "push_to_talk_mode")
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        loadBundledKnowledgeIndex()
        refreshAllPermissions()
        // Warm ScreenCaptureKit's window enumeration so the first
        // screenshot after a key press doesn't pay the cold-start tax.
        CompanionScreenCaptureUtility.prewarmShareableContent()
        print("OpenClicky runtime identity - bundleID: \(Bundle.main.bundleIdentifier ?? "unknown"), appPath: \(Bundle.main.bundleURL.path)")
        print("OpenClicky start - accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), camera: \(hasCameraPermission), screenContent: \(hasScreenContentPermission), fullDiskAccess: \(hasFullDiskAccessPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        if runtimeMode == .menuBar {
            notchCaptureWindowManager.showPersistentPill(
                companionManager: self,
                submitText: { [weak self] submittedText in
                    self?.submitTextModePrompt(submittedText)
                }
            )
        }
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        if voiceActivationMode == .alwaysWakeWord {
            isWakeWordPausedByShortcut = false
            startWakeWordListeningIfNeeded(reason: "startup")
        }
        bindAgentSessionObservation()
        startRelaunchableAgentAutoResumeChecks()
        if runtimeMode == .menuBar, !agentDockItems.isEmpty {
            showAgentDockWindowNearCurrentScreen()
        }
        startExternalControlBridgeIfNeeded()
        if runtimeMode == .menuBar && isTutorModeEnabled {
            startTutorIdleObservation()
        }
        let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        switch selectedVoiceResponseModel.provider {
        case .anthropic:
            // SDK is the primary Claude path — warm it whenever available.
            if let claudeAgentSDKAPI {
                claudeAgentSDKAPI.warmUp(systemPrompt: currentVoiceResponseSystemPrompt())
            }
            // Pre-init the HTTP ClaudeAPI client as fallback-only TLS warm-up
            // when a key is present. Its initializer kicks off a background
            // HEAD to api.anthropic.com which caches the TLS session ticket,
            // so a fallback request avoids the ~150-300ms cold-handshake tax.
            if AppBundleConfiguration.anthropicAPIKey() != nil {
                _ = claudeAPI
            }
        case .openAI where OpenClickyModelCatalog.isSpeechModelID(selectedVoiceResponseModel.id):
            selectedSpeechModel = selectedVoiceResponseModel.id
            openAIRealtimeSpeechClient.model = selectedVoiceResponseModel.id
            selectedTTSProvider = .openAIRealtime
            UserDefaults.standard.set(OpenClickyTTSProvider.openAIRealtime.rawValue, forKey: AppBundleConfiguration.userTTSProviderDefaultsKey)
            UserDefaults.standard.set(selectedVoiceResponseModel.id, forKey: "openClickySpeechModel")
            openAIRealtimeSpeechClient.warmUpConnection()
            warmRealtimeVoiceInputIfNeeded(reason: "startup")
        case .deepgram:
            selectedSpeechModel = selectedVoiceResponseModel.id
            UserDefaults.standard.set(selectedVoiceResponseModel.id, forKey: "openClickySpeechModel")
            deepgramVoiceAgentClient.updateConfiguration(
                apiKey: AppBundleConfiguration.deepgramAPIKey(),
                voiceID: AppBundleConfiguration.deepgramTTSVoice(),
                thinkModel: AppBundleConfiguration.deepgramVoiceAgentThinkModel()
            )
            deepgramVoiceAgentClient.warmUpConnection()
        case .openAI, .codex:
            codexVoiceSession.model = selectedVoiceResponseModel.id
            if selectedVoiceResponseModel.provider == .codex || AppBundleConfiguration.openAIAPIKey() == nil {
                codexVoiceSession.warmUp(systemPrompt: currentVoiceResponseSystemPrompt())
            }
        }
        // Force-init the active TTS provider and prime its TLS
        // handshake. The first sentence's TTS request would otherwise
        // pay the cold-connect tax synchronously inside the streaming
        // pipeline. We warm the active provider only — switching
        // providers in Settings re-warms.
        voiceTTSClient.warmUpConnection()
        // Generate (or load from disk) the pre-baked filler phrases
        // for the active provider's voice. Switching providers
        // re-prepares the cache.
        FillerPhraseLibrary.shared.prepare(client: voiceTTSClient)

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && isClickyCursorEnabled {
            showCursorOverlayIfAvailable()
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

        if runtimeMode == .menuBar {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
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
        detectedElementReturnsImmediately = false
    }

    func rememberPointedElement(at point: CGPoint, displayFrame: CGRect?, label: String?) {
        lastPointedElementScreenLocation = point
        lastPointedElementDisplayFrame = displayFrame
        lastPointedElementLabel = label
        lastPointedElementAt = Date()
    }

    private func startExternalControlBridgeIfNeeded() {
        guard externalControlBridgeServer == nil else { return }
        let server = OpenClickyExternalControlBridgeServer { [weak self] command in
            guard let self else {
                return .error(503, "OpenClicky is not ready")
            }
            return await self.handleExternalControlCommand(command)
        }
        externalControlBridgeServer = server
        server.start()
    }

    private func handleExternalControlCommand(_ command: OpenClickyExternalControlCommand) async -> OpenClickyExternalControlResponse {
        switch command {
        case .showCursor(let point, let caption, let duration, let accentHex, let mode, let travelDuration):
            switch mode {
            case .primary:
                showExternalPrimaryCursor(at: point, caption: caption, duration: duration, accentHex: accentHex, travelDuration: travelDuration)
                return .ok(["displayed": "primary_cursor", "durationMs": Int(duration * 1000), "travelMs": Int(travelDuration * 1000)])
            case .secondary:
                showExternalSecondaryCursor(at: point, caption: caption, duration: duration, accentHex: accentHex)
                return .ok(["displayed": "secondary_cursor", "durationMs": Int(duration * 1000)])
            }
        case .showCursors(let specs):
            for spec in specs {
                showExternalSecondaryCursor(at: spec.point, caption: spec.caption, duration: spec.duration, accentHex: spec.accentHex)
            }
            return .ok(["displayed": "secondary_cursors", "count": specs.count])
        case .showVisualGuidanceOverlay(let overlay):
            showVisualGuidanceOverlay(overlay)
            return .ok(["displayed": overlay.kind.rawValue, "id": overlay.id.uuidString, "durationMs": Int(overlay.duration * 1000)])
        case .showCaption(let text, let point, let duration, let accentHex):
            let resolvedPoint = point ?? NSEvent.mouseLocation
            showExternalPrimaryCursor(at: resolvedPoint, caption: text, duration: duration, accentHex: accentHex, travelDuration: 0.35)
            return .ok(["displayed": "primary_caption", "durationMs": Int(duration * 1000)])
        case .captureScreenshot(let focused):
            return await captureExternalControlScreenshots(focused: focused)
        case .click(let point, let caption):
            return clickExternalControlPoint(point, caption: caption)
        case .clear:
            clearExternalProxyOverlay()
            return .ok(["cleared": true])
        case .speak(let text, let interrupt):
            return speakExternalProxyText(text, interrupt: interrupt)
        case .notify(let title, let body, let threadID, let sound):
            let identifier = OpenClickyDesktopNotificationCenter.shared.post(
                title: title,
                body: body,
                threadID: threadID ?? "openclicky.external",
                playSound: sound,
                userInfo: ["source": "external_control_bridge"]
            )
            return .accepted(["notified": true, "identifier": identifier])
        case .unavailable(let statusCode, let body):
            return OpenClickyExternalControlResponse(statusCode: statusCode, body: body)
        }
    }

    private func showExternalPrimaryCursor(at point: CGPoint, caption: String?, duration: TimeInterval, accentHex: String?, travelDuration: TimeInterval) {
        let targetPoint = Self.clampedExternalCursorPoint(point)
        // Use OpenClicky's existing smooth pointing choreography — the same
        // path used when voice asks "show me the Apple menu". This makes the
        // little OpenClicky triangle detach, zip to the target, caption it, and
        // fly back to the user's real pointer. Do not warp the system pointer
        // here and do not draw a duplicate primary cursor icon.
        detectedElementScreenLocation = targetPoint
        detectedElementDisplayFrame = NSScreen.screen(containingOrNearestTo: targetPoint)?.frame
            ?? CGRect(origin: targetPoint, size: .zero)
        detectedElementBubbleText = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        detectedElementReturnsImmediately = false
        cursorOverlayState.externalPrimaryCaptionText = nil
        cursorOverlayState.externalPrimaryCaptionAccentHex = nil
        showCursorOverlayIfAvailable()
    }

    private func showExternalSecondaryCursor(at point: CGPoint, caption: String?, duration: TimeInterval, accentHex: String?) {
        let targetPoint = Self.clampedExternalCursorPoint(point)
        let id = UUID()
        let cursor = OpenClickyExternalProxyCursor(
            id: id,
            screenLocation: targetPoint,
            caption: caption?.trimmingCharacters(in: .whitespacesAndNewlines),
            accentHex: accentHex
        )
        cursorOverlayState.externalSecondaryCursors.append(cursor)
        showCursorOverlayIfAvailable()

        externalSecondaryCursorClearTasks[id]?.cancel()
        externalSecondaryCursorClearTasks[id] = Task { [weak self] in
            let nanoseconds = UInt64(max(0.2, duration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                self?.removeExternalSecondaryCursor(id)
            }
        }
    }

    private func animateAgentSpawnProxyFromCursorToDock(accentTheme: ClickyAccentTheme, caption: String? = nil, dockItemID: UUID? = nil) {
        let startPoint = Self.clampedExternalCursorPoint(NSEvent.mouseLocation)
        let targetPoint = dockItemID
            .flatMap { agentDockWindowManager.dockIconCenter(for: $0, in: agentDockItems) }
            .map(Self.clampedExternalCursorPoint)
            ?? agentDockSpawnProxyTargetPoint(from: startPoint)

        // For agent starts, use the primary OpenClicky buddy itself rather
        // than a disposable proxy cursor: it should visibly fly to the agent
        // corner, tag the handoff, and immediately return to the user's real
        // pointer so the working cursor never feels abandoned.
        detectedElementDisplayFrame = NSScreen.screens.first { $0.frame.contains(targetPoint) }?.frame
            ?? NSScreen.screens.first { $0.frame.contains(startPoint) }?.frame
            ?? NSScreen.main?.frame
            ?? CGRect(origin: targetPoint, size: .zero)
        detectedElementBubbleText = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        detectedElementReturnsImmediately = true
        detectedElementScreenLocation = targetPoint
        showCursorOverlayIfAvailable()
    }

    private func moveExternalSecondaryCursor(_ id: UUID, to point: CGPoint) {
        guard let index = cursorOverlayState.externalSecondaryCursors.firstIndex(where: { $0.id == id }) else { return }
        var cursors = cursorOverlayState.externalSecondaryCursors
        cursors[index].screenLocation = Self.clampedExternalCursorPoint(point)
        cursorOverlayState.externalSecondaryCursors = cursors
    }

    private func agentDockSpawnProxyTargetPoint(from startPoint: CGPoint) -> CGPoint {
        let screen = agentDockTargetScreen()
            ?? NSScreen.screen(containingOrNearestTo: startPoint)

        guard let screen else { return startPoint }

        let dockSize = NSSize(width: 760, height: 500)
        let edgeInset: CGFloat
        switch agentParkingPosition {
        case .topLeft, .topCenter, .topRight:
            edgeInset = max(56, screen.frame.maxY - screen.visibleFrame.maxY + 56)
        default:
            edgeInset = 16
        }

        var origin = agentParkingPosition.originForWindow(size: dockSize, on: screen, edgeInset: edgeInset)
        if agentParkingPosition == .topRight {
            origin.x += 70
            origin.y += 70
        }

        let approximateDockIconCenter = CGPoint(
            x: origin.x + dockSize.width - 50,
            y: origin.y + dockSize.height - 50
        )
        return Self.clampedExternalCursorPoint(approximateDockIconCenter)
    }


    private static func clampedExternalCursorPoint(_ point: CGPoint) -> CGPoint {
        NSScreen.pointClampedToDesktop(point)
    }

    private static func quartzCursorPoint(fromAppKitScreenPoint point: CGPoint) -> CGPoint {
        let targetScreen = NSScreen.screen(containingOrNearestTo: point)
        guard let frame = targetScreen?.frame else { return point }

        // Public bridge coordinates use AppKit/NSEvent space (global desktop,
        // origin at bottom-left). CGWarpMouseCursorPosition expects Quartz
        // display coordinates for the target display (Y axis flipped). Convert
        // here so /cursor x/y matches what agents read from screenshots/AppKit.
        let localY = point.y - frame.minY
        let quartzY = frame.minY + (frame.height - localY)
        return CGPoint(x: point.x, y: quartzY)
    }

    private func clearExternalPrimaryCaption() {
        externalProxyClearTask?.cancel()
        externalProxyClearTask = nil
        externalPrimaryCursorMoveTask?.cancel()
        externalPrimaryCursorMoveTask = nil
        cursorOverlayState.externalPrimaryCaptionText = nil
        cursorOverlayState.externalPrimaryCaptionAccentHex = nil
    }

    private func removeExternalSecondaryCursor(_ id: UUID) {
        externalSecondaryCursorClearTasks[id]?.cancel()
        externalSecondaryCursorClearTasks[id] = nil
        cursorOverlayState.externalSecondaryCursors.removeAll { $0.id == id }
    }

    func showVisualGuidanceOverlay(
        _ overlay: OpenClickyVisualGuidanceOverlay,
        sourceCapture: CompanionScreenCapture? = nil
    ) {
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        var clampedOverlay = overlay.clamped(to: desktopBounds)
        if clampedOverlay.kind == .rectangle {
            clampedOverlay.duration = max(clampedOverlay.duration, 30)
        } else {
            clampedOverlay.duration = max(clampedOverlay.duration, 20)
        }
        if let calibrationAnchor = Self.pendingCalibrationAnchor(from: clampedOverlay, sourceCapture: sourceCapture) {
            clampedOverlay.duration = max(clampedOverlay.duration, 120)
            clampedOverlay.style.accentHex = "#34D399"
            pendingVisualGuidanceCalibrationAnchor = calibrationAnchor
            sampleAutomaticVisualGuidanceCalibrationAnchor(calibrationAnchor)
        }
        guard clampedOverlay.isRenderable else { return }
        cursorOverlayState.visualGuidanceOverlays.removeAll { $0.id == clampedOverlay.id }
        cursorOverlayState.visualGuidanceOverlays.append(clampedOverlay)
        showCursorOverlayIfAvailable()

        visualGuidanceOverlayClearTasks[clampedOverlay.id]?.cancel()
        visualGuidanceOverlayClearTasks[clampedOverlay.id] = Task { [weak self] in
            let nanoseconds = UInt64(max(0.2, clampedOverlay.duration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                self?.removeVisualGuidanceOverlay(clampedOverlay.id)
            }
        }
    }

    private func removeVisualGuidanceOverlay(_ id: UUID) {
        visualGuidanceOverlayClearTasks[id]?.cancel()
        visualGuidanceOverlayClearTasks[id] = nil
        cursorOverlayState.visualGuidanceOverlays.removeAll { $0.id == id }
    }

    private static func pendingCalibrationAnchor(
        from overlay: OpenClickyVisualGuidanceOverlay,
        sourceCapture: CompanionScreenCapture? = nil
    ) -> OpenClickyPendingVisualGuidanceCalibrationAnchor? {
        guard overlay.kind == .rectangle,
              isVisualGuidanceCalibrationCaption(overlay.style.caption),
              let rect = overlay.rect?.normalized.cgRect,
              !rect.isNull,
              rect.width > 1,
              rect.height > 1 else {
            return nil
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let screenFrame = NSScreen.screen(containingOrNearestTo: center)?.frame ?? rect
        return OpenClickyPendingVisualGuidanceCalibrationAnchor(
            overlayID: overlay.id,
            caption: overlay.style.caption ?? "calibration anchor",
            predictedRect: rect,
            screenFrame: screenFrame,
            screenshotWidthInPixels: sourceCapture?.screenshotWidthInPixels,
            screenshotHeightInPixels: sourceCapture?.screenshotHeightInPixels,
            displayNativeWidthInPixels: sourceCapture?.displayNativeWidthInPixels,
            displayNativeHeightInPixels: sourceCapture?.displayNativeHeightInPixels,
            createdAt: Date()
        )
    }

    private func sampleAutomaticVisualGuidanceCalibrationAnchor(_ anchor: OpenClickyPendingVisualGuidanceCalibrationAnchor) {
        guard let expectedCenter = Self.expectedVisualGuidanceCalibrationCenter(
            for: anchor.caption,
            predictedRect: anchor.predictedRect,
            screenFrame: anchor.screenFrame,
            screenshotWidthInPixels: anchor.screenshotWidthInPixels,
            screenshotHeightInPixels: anchor.screenshotHeightInPixels
        ) else { return }

        let predictedCenter = CGPoint(
            x: anchor.predictedRect.midX,
            y: anchor.predictedRect.midY
        )
        let delta = CGSize(
            width: expectedCenter.x - predictedCenter.x,
            height: expectedCenter.y - predictedCenter.y
        )
        guard Self.isPlausibleVisualGuidanceCalibrationDelta(delta, for: anchor.screenFrame) else {
            let maxDelta = Self.maximumVisualGuidanceCalibrationDelta(for: anchor.screenFrame)
            OpenClickyMessageLogStore.shared.append(
                lane: "visual_guidance",
                direction: "incoming",
                event: "openclicky.visual_guidance.auto_calibration_rejected",
                fields: [
                    "overlayID": anchor.overlayID.uuidString,
                    "label": anchor.caption,
                    "reason": "implausible_delta",
                    "predictedX": Int(predictedCenter.x.rounded()),
                    "predictedY": Int(predictedCenter.y.rounded()),
                    "expectedX": Int(expectedCenter.x.rounded()),
                    "expectedY": Int(expectedCenter.y.rounded()),
                    "sampleDeltaX": Int(delta.width.rounded()),
                    "sampleDeltaY": Int(delta.height.rounded()),
                    "maxDeltaX": Int(maxDelta.width.rounded()),
                    "maxDeltaY": Int(maxDelta.height.rounded()),
                    "mapKind": "screenshot_to_display_warp_map"
                ]
            )
            return
        }
        let calibration = Self.updatedVisualGuidanceCalibrationOffset(
            delta: delta,
            for: anchor.screenFrame
        )

        OpenClickyMessageLogStore.shared.append(
            lane: "visual_guidance",
            direction: "incoming",
            event: "openclicky.visual_guidance.auto_calibration_sampled",
            fields: [
                "overlayID": anchor.overlayID.uuidString,
                "label": anchor.caption,
                "screenKey": calibration.screenKey,
                "predictedX": Int(predictedCenter.x.rounded()),
                "predictedY": Int(predictedCenter.y.rounded()),
                "expectedX": Int(expectedCenter.x.rounded()),
                "expectedY": Int(expectedCenter.y.rounded()),
                "sampleDeltaX": Int(delta.width.rounded()),
                "sampleDeltaY": Int(delta.height.rounded()),
                "offsetX": Int(calibration.offset.width.rounded()),
                "offsetY": Int(calibration.offset.height.rounded()),
                "sampleCount": calibration.count,
                "mapKind": "screenshot_to_display_warp_map",
                "screenshotWidthInPixels": anchor.screenshotWidthInPixels ?? 0,
                "screenshotHeightInPixels": anchor.screenshotHeightInPixels ?? 0,
                "displayWidthInPoints": Int(anchor.screenFrame.width.rounded()),
                "displayHeightInPoints": Int(anchor.screenFrame.height.rounded()),
                "displayNativeWidthInPixels": anchor.displayNativeWidthInPixels ?? 0,
                "displayNativeHeightInPixels": anchor.displayNativeHeightInPixels ?? 0
            ]
        )
    }

    private static func expectedVisualGuidanceCalibrationCenter(
        for caption: String,
        predictedRect: CGRect,
        screenFrame: CGRect,
        screenshotWidthInPixels: Int? = nil,
        screenshotHeightInPixels: Int? = nil
    ) -> CGPoint? {
        let normalized = caption
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        // Calibration compares the model's detected anchor in the actual
        // screenshot it saw (for example 1280x540 after downsampling a
        // 3840x1620 display) to the expected screen-corner anchor, then
        // converts that expected pixel back into AppKit display points.
        let screenshotSize = CGSize(
            width: CGFloat(screenshotWidthInPixels ?? Int(screenFrame.width.rounded())),
            height: CGFloat(screenshotHeightInPixels ?? Int(screenFrame.height.rounded()))
        )
        let scaleX = screenFrame.width / max(1, screenshotSize.width)
        let scaleY = screenFrame.height / max(1, screenshotSize.height)
        let insetPixelX = max(18, min(64, screenshotSize.width * 0.035))
        let insetPixelY = max(12, min(42, screenshotSize.height * 0.032))
        let predictedCenter = CGPoint(x: predictedRect.midX, y: predictedRect.midY)
        let predictedPixelCenter = CGPoint(
            x: (predictedCenter.x - screenFrame.minX) / max(0.0001, scaleX),
            y: (screenFrame.maxY - predictedCenter.y) / max(0.0001, scaleY)
        )
        let predictedIsTopHalf = predictedPixelCenter.y <= screenshotSize.height / 2

        func displayPoint(fromScreenshotPixel pixel: CGPoint) -> CGPoint {
            CGPoint(
                x: screenFrame.minX + (pixel.x * scaleX),
                y: screenFrame.maxY - (pixel.y * scaleY)
            )
        }

        if normalized.contains("time") || normalized.contains("clock") {
            return displayPoint(fromScreenshotPixel: CGPoint(x: screenshotSize.width - max(52, insetPixelX), y: insetPixelY))
        }
        if normalized.contains("trash") || normalized.contains("dustbin") || normalized.contains("bin") {
            return displayPoint(fromScreenshotPixel: CGPoint(x: screenshotSize.width - insetPixelX, y: screenshotSize.height - insetPixelY))
        }
        if normalized.contains("apple") {
            return displayPoint(fromScreenshotPixel: CGPoint(x: insetPixelX, y: insetPixelY))
        }
        if normalized.contains("finder") {
            if normalized.contains("label") || normalized.contains("menu") || predictedIsTopHalf {
                return displayPoint(fromScreenshotPixel: CGPoint(x: max(52, insetPixelX), y: insetPixelY))
            }
            return displayPoint(fromScreenshotPixel: CGPoint(x: insetPixelX, y: screenshotSize.height - insetPixelY))
        }
        return nil
    }

    private func handleVisualGuidanceCalibrationCursorSampleIfNeeded(from transcript: String) -> Bool {
        guard let pendingVisualGuidanceCalibrationAnchor else { return false }
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let confirmsSample = [
            "mark it", "mark this", "highlight it", "highlight this",
            "lined up", "line up", "anchor it", "save anchor",
            "got it", "done", "that's it", "thats it",
            "i'm pointing", "im pointing", "pointing at it", "pointing at this",
            "i am going to point", "can you do the same", "do the same",
            "this one", "right here", "it's here", "its here", "here"
        ].contains { normalized.contains($0) }
        guard confirmsSample else { return false }

        let cursorPoint = NSEvent.mouseLocation
        guard pendingVisualGuidanceCalibrationAnchor.screenFrame.contains(cursorPoint) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "visual_guidance",
                direction: "incoming",
                event: "openclicky.visual_guidance.cursor_calibration_rejected",
                fields: [
                    "overlayID": pendingVisualGuidanceCalibrationAnchor.overlayID.uuidString,
                    "label": pendingVisualGuidanceCalibrationAnchor.caption,
                    "reason": "cursor_on_different_screen",
                    "cursorX": Int(cursorPoint.x.rounded()),
                    "cursorY": Int(cursorPoint.y.rounded()),
                    "screenKey": Self.visualGuidanceCalibrationScreenKey(for: pendingVisualGuidanceCalibrationAnchor.screenFrame)
                ]
            )
            self.pendingVisualGuidanceCalibrationAnchor = nil
            return true
        }
        let predictedCenter = CGPoint(
            x: pendingVisualGuidanceCalibrationAnchor.predictedRect.midX,
            y: pendingVisualGuidanceCalibrationAnchor.predictedRect.midY
        )
        let delta = CGSize(
            width: cursorPoint.x - predictedCenter.x,
            height: cursorPoint.y - predictedCenter.y
        )
        guard Self.isPlausibleVisualGuidanceCalibrationDelta(delta, for: pendingVisualGuidanceCalibrationAnchor.screenFrame) else {
            let maxDelta = Self.maximumVisualGuidanceCalibrationDelta(for: pendingVisualGuidanceCalibrationAnchor.screenFrame)
            OpenClickyMessageLogStore.shared.append(
                lane: "visual_guidance",
                direction: "incoming",
                event: "openclicky.visual_guidance.cursor_calibration_rejected",
                fields: [
                    "overlayID": pendingVisualGuidanceCalibrationAnchor.overlayID.uuidString,
                    "label": pendingVisualGuidanceCalibrationAnchor.caption,
                    "reason": "implausible_delta",
                    "predictedX": Int(predictedCenter.x.rounded()),
                    "predictedY": Int(predictedCenter.y.rounded()),
                    "cursorX": Int(cursorPoint.x.rounded()),
                    "cursorY": Int(cursorPoint.y.rounded()),
                    "sampleDeltaX": Int(delta.width.rounded()),
                    "sampleDeltaY": Int(delta.height.rounded()),
                    "maxDeltaX": Int(maxDelta.width.rounded()),
                    "maxDeltaY": Int(maxDelta.height.rounded()),
                    "screenKey": Self.visualGuidanceCalibrationScreenKey(for: pendingVisualGuidanceCalibrationAnchor.screenFrame)
                ]
            )
            self.pendingVisualGuidanceCalibrationAnchor = nil
            return true
        }
        let calibration = Self.updatedVisualGuidanceCalibrationOffset(
            delta: delta,
            for: pendingVisualGuidanceCalibrationAnchor.screenFrame
        )
        let caption = pendingVisualGuidanceCalibrationAnchor.caption
        self.pendingVisualGuidanceCalibrationAnchor = nil

        OpenClickyMessageLogStore.shared.append(
            lane: "visual_guidance",
            direction: "incoming",
            event: "openclicky.visual_guidance.cursor_calibration_sampled",
            fields: [
                "overlayID": pendingVisualGuidanceCalibrationAnchor.overlayID.uuidString,
                "label": caption,
                "screenKey": calibration.screenKey,
                "predictedX": Int(predictedCenter.x.rounded()),
                "predictedY": Int(predictedCenter.y.rounded()),
                "cursorX": Int(cursorPoint.x.rounded()),
                "cursorY": Int(cursorPoint.y.rounded()),
                "sampleDeltaX": Int(delta.width.rounded()),
                "sampleDeltaY": Int(delta.height.rounded()),
                "offsetX": Int(calibration.offset.width.rounded()),
                "offsetY": Int(calibration.offset.height.rounded()),
                "sampleCount": calibration.count
            ]
        )

        speakShortSystemResponse(Self.visualGuidanceCalibrationSampleAcknowledgement(for: caption))
        return true
    }

    private func showActiveControlGlow(
        around rect: CGRect?,
        label: String? = nil,
        duration: TimeInterval = 2.4
    ) {
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        let fallbackRect = NSScreen.screen(containingOrNearestTo: NSEvent.mouseLocation)?.frame
            ?? NSScreen.main?.frame
        let candidateRect = (rect?.isNull == false ? rect : fallbackRect) ?? .null
        let clampedRect = candidateRect.intersection(desktopBounds)
        guard !clampedRect.isNull,
              clampedRect.width > 8,
              clampedRect.height > 8 else {
            return
        }

        cursorOverlayState.activeControlGlowRect = clampedRect
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cursorOverlayState.activeControlGlowLabel = trimmedLabel.isEmpty ? nil : trimmedLabel
        showCursorOverlayIfAvailable()

        activeControlGlowClearTask?.cancel()
        activeControlGlowClearTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0.4, min(duration, 12)) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.clearActiveControlGlow()
            }
        }
    }

    private func showActiveControlGlowForFocusedWindowOrScreen(
        label: String? = nil,
        duration: TimeInterval = 2.4
    ) {
        let focusedWindow = OpenClickyComputerUseWindowEnumerator.frontmostTargetWindow()
        showActiveControlGlow(
            around: focusedWindow.flatMap { Self.appKitScreenRect(fromComputerUseWindowBounds: $0.bounds) },
            label: label ?? focusedWindow?.displayTitle,
            duration: duration
        )
    }

    private func clearActiveControlGlow() {
        activeControlGlowClearTask?.cancel()
        activeControlGlowClearTask = nil
        cursorOverlayState.activeControlGlowRect = nil
        cursorOverlayState.activeControlGlowLabel = nil
    }

    private static func appKitScreenRect(fromComputerUseWindowBounds bounds: OpenClickyComputerUseWindowBounds) -> CGRect? {
        let quartzRect = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        guard !quartzRect.isNull,
              quartzRect.width > 1,
              quartzRect.height > 1 else {
            return nil
        }

        let matchedScreen = NSScreen.screens.first { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayBounds(displayID).intersects(quartzRect)
        } ?? NSScreen.screens.first { screen in
            screen.frame.intersects(quartzRect)
        }

        guard let screen = matchedScreen else {
            return quartzRect
        }

        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return quartzRect
        }

        let quartzFrame = CGDisplayBounds(displayID)
        let localX = quartzRect.minX - quartzFrame.minX
        let localYFromTop = quartzRect.minY - quartzFrame.minY
        return CGRect(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localYFromTop - quartzRect.height,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    private static func controlTargetGlowRect(centeredOn point: CGPoint, within displayFrame: CGRect?) -> CGRect {
        let sidePaddingRect = CGRect(
            x: point.x - 70,
            y: point.y - 45,
            width: 140,
            height: 90
        )
        guard let displayFrame,
              !displayFrame.isNull else {
            return sidePaddingRect
        }

        return sidePaddingRect.intersection(displayFrame)
    }

    private func clearExternalProxyOverlay() {
        clearExternalPrimaryCaption()
        externalSecondaryCursorClearTasks.values.forEach { $0.cancel() }
        externalSecondaryCursorClearTasks.removeAll()
        cursorOverlayState.externalSecondaryCursors.removeAll()
        visualGuidanceOverlayClearTasks.values.forEach { $0.cancel() }
        visualGuidanceOverlayClearTasks.removeAll()
        cursorOverlayState.visualGuidanceOverlays.removeAll()
        clearActiveControlGlow()
    }

    private func captureExternalControlScreenshots(focused: Bool) async -> OpenClickyExternalControlResponse {
        do {
            let captures = try await (focused
                ? CompanionScreenCaptureUtility.captureFocusedWindowAsJPEG()
                : CompanionScreenCaptureUtility.captureAllScreensAsJPEG())
            let rootDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenClickyExternalControlScreenshots", isDirectory: true)
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

            // External callers receive paths so they can consume the image,
            // but those paths must not become an unbounded screenshot archive.
            let now = Date()
            if let oldEntries = try? FileManager.default.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for entry in oldEntries {
                    let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                    if let modifiedAt = values?.contentModificationDate,
                       now.timeIntervalSince(modifiedAt) > 600 {
                        try? FileManager.default.removeItem(at: entry)
                    }
                }
            }

            let directory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let screens: [[String: Any]] = try captures.enumerated().map { index, capture in
                let fileURL = directory.appendingPathComponent("screen-\(timestamp)-\(index + 1).jpg")
                try capture.imageData.write(to: fileURL, options: .atomic)
                return [
                    "label": capture.label,
                    "path": fileURL.path,
                    "isCursorScreen": capture.isCursorScreen,
                    "displayFrame": [
                        "x": capture.displayFrame.origin.x,
                        "y": capture.displayFrame.origin.y,
                        "width": capture.displayFrame.width,
                        "height": capture.displayFrame.height
                    ],
                    "displayWidthInPoints": capture.displayWidthInPoints,
                    "displayHeightInPoints": capture.displayHeightInPoints,
                    "screenshotWidthInPixels": capture.screenshotWidthInPixels,
                    "screenshotHeightInPixels": capture.screenshotHeightInPixels
                ]
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                try? FileManager.default.removeItem(at: directory)
            }
            return .ok(["screens": screens, "count": screens.count, "focused": focused])
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    private func clickExternalControlPoint(_ point: CGPoint, caption: String?) -> OpenClickyExternalControlResponse {
        let targetPoint = Self.clampedExternalCursorPoint(point)
        // H3/M10: previously this force-enabled native CUA (`setEnabled(true)`)
        // and always called `nativeComputerUseController.click` regardless of
        // the selected backend — so a user who selected Background Computer Use
        // still got a cursor-warping native click, and a user who *disabled* CUA
        // had their preference silently overridden. Now: honor the selector, and
        // treat "disabled" as authoritative (return an error, let the caller
        // decide) instead of flipping it back on.
        if !nativeComputerUseController.isEnabled && selectedComputerUseBackend == .nativeSwift {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "external_control.click_disabled",
                fields: [
                    "executor": "openClickyControl",
                    "reason": "Native computer use is disabled. Enable it in Settings to allow bridge clicks."
                ]
            )
            return .error(409, "Computer use is disabled")
        }
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            return clickExternalControlPointViaBackgroundComputerUse(targetPoint, caption: caption)
        case .nativeSwift:
            return clickExternalControlPointViaNativeComputerUse(targetPoint, caption: caption)
        }
    }

    private func clickExternalControlPointViaNativeComputerUse(_ targetPoint: CGPoint, caption: String?) -> OpenClickyExternalControlResponse {
        do {
            try nativeComputerUseController.click(at: targetPoint)
            detectedElementScreenLocation = targetPoint
            detectedElementDisplayFrame = NSScreen.screen(containingOrNearestTo: targetPoint)?.frame
            detectedElementBubbleText = Self.pointingBubbleText(for: caption)
            rememberPointedElement(at: targetPoint, displayFrame: detectedElementDisplayFrame, label: caption)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "external_control.click",
                fields: [
                    "executor": "openClickyControl",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "backend": "nativeSwift",
                    "x": Int(targetPoint.x),
                    "y": Int(targetPoint.y),
                    "caption": caption ?? ""
                ]
            )
            return .ok([
                "clicked": true,
                "x": targetPoint.x,
                "y": targetPoint.y,
                "caption": caption ?? ""
            ])
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "external_control.click_error",
                fields: [
                    "executor": "openClickyControl",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "backend": "nativeSwift",
                    "x": Int(targetPoint.x),
                    "y": Int(targetPoint.y),
                    "caption": caption ?? "",
                    "error": error.localizedDescription
                ]
            )
            return .error(500, error.localizedDescription)
        }
    }

    private func clickExternalControlPointViaBackgroundComputerUse(_ targetPoint: CGPoint, caption: String?) -> OpenClickyExternalControlResponse {
        // The bridge caller gave us a GLOBAL display point. BCU clicks in
        // window-screenshot pixel space, so we capture the frontmost window
        // (which also yields the stateToken BCU requires — H4), convert the
        // global point into the window's local screenshot space using the AX
        // window bounds, and post the click through the selected backend. This
        // keeps the bridge honest about the user's backend choice (no cursor
        // warp when BCU is selected). Coordinate conversion: localPoint =
        // (globalPoint - windowOrigin) * (screenshotPixels / windowPoints).
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let capture = try await self.backgroundComputerUseController.captureFrontmostWindowAsJPEG()
                guard let window = OpenClickyComputerUseWindowEnumerator.frontmostTargetWindow() else {
                    throw OpenClickyComputerUseError.noTargetWindow
                }
                // AX bounds use AppKit bottom-left origin; BCU screenshot is
                // top-left. Convert: flip Y, subtract window origin, scale by
                // retina factor derived from screenshot pixels vs window points.
                let screenFrame = (NSScreen.screen(containingOrNearestTo: targetPoint) ?? NSScreen.main)?.frame ?? .zero
                let globalTopLeftY = screenFrame.height - targetPoint.y
                let localX = (targetPoint.x - window.bounds.x)
                let localY = (globalTopLeftY - (screenFrame.height - window.bounds.y))
                let pointsW = max(window.bounds.width, 1)
                let pointsH = max(window.bounds.height, 1)
                let scaleX = Double(capture.screenshotWidthInPixels) / pointsW
                let scaleY = Double(capture.screenshotHeightInPixels) / pointsH
                let scaled = CGPoint(x: localX * scaleX, y: localY * scaleY)
                _ = try await self.backgroundComputerUseController.click(
                    at: scaled,
                    window: capture.windowID,
                    targetAppName: caption,
                    stateToken: capture.stateToken
                )
                self.detectedElementScreenLocation = targetPoint
                self.detectedElementDisplayFrame = NSScreen.screen(containingOrNearestTo: targetPoint)?.frame
                self.detectedElementBubbleText = Self.pointingBubbleText(for: caption)
                self.rememberPointedElement(at: targetPoint, displayFrame: self.detectedElementDisplayFrame, label: caption)
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "external_control.click",
                    fields: [
                        "executor": "openClickyControl",
                        "executionMethod": "OpenClickyBackgroundComputerUseController.click",
                        "backend": "backgroundComputerUse",
                        "x": Int(targetPoint.x),
                        "y": Int(targetPoint.y),
                        "caption": caption ?? ""
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "external_control.click_error",
                    fields: [
                        "executor": "openClickyControl",
                        "executionMethod": "OpenClickyBackgroundComputerUseController.click",
                        "backend": "backgroundComputerUse",
                        "x": Int(targetPoint.x),
                        "y": Int(targetPoint.y),
                        "caption": caption ?? "",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
        return .ok([
            "clicked": true,
            "x": targetPoint.x,
            "y": targetPoint.y,
            "caption": caption ?? "",
            "backend": "backgroundComputerUse"
        ])
    }

    private func speakExternalProxyText(_ text: String, interrupt: Bool) -> OpenClickyExternalControlResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .error(400, "Missing text") }
        if voiceTTSClient.isPlaying {
            guard interrupt else {
                return .error(409, "OpenClicky voice is already playing; retry or pass interrupt=true")
            }
            voiceTTSClient.stopPlayback()
        }

        Task { @MainActor [weak self] in
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "outgoing",
                event: "external_control.speak.started",
                fields: ["textLength": trimmed.count]
            )
            do {
                try await self?.voiceTTSClient.speakText(trimmed)
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "error",
                    event: "external_control.speak.failed",
                    fields: ["error": error.localizedDescription]
                )
            }
        }
        return .accepted(["speaking": true, "textLength": trimmed.count])
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        wakeWordManager.stop(reason: "companion_stop")
        buddyDictationManager.cancelCurrentDictation()
        cancelCircleSelectSession()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        pendingWakeWordRestartTask?.cancel()
        pendingWakeWordRestartTask = nil

        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentResponseTaskToken = nil
        realtimeBidirectionalVoiceTask?.cancel()
        realtimeBidirectionalVoiceTask = nil
        realtimeBidirectionalVoiceTurnGeneration &+= 1
        openAIRealtimeSpeechClient.cancelBidirectionalVoiceTurn()
        voiceTTSClient.cancelBidirectionalVoiceTurn()
        claudeAgentSDKAPI?.stop()
        codexVoiceSession.stop()
        codexAgentSessions.forEach { $0.stop(reason: "companion_stop") }
        // M11: tear down the Background Computer Use runtime too. Previously
        // stop() killed the external bridge, voice, and timers but never the
        // spawned BCU helper, orphaning it across app restarts.
        backgroundComputerUseController.stopRuntime()
        externalControlBridgeServer?.stop()
        externalControlBridgeServer = nil
        externalProxyClearTask?.cancel()
        externalProxyClearTask = nil
        agentTaskBubbleClearTask?.cancel()
        agentTaskBubbleClearTask = nil
        cursorOverlayState.agentTaskBubbleText = nil
        externalPrimaryCursorMoveTask?.cancel()
        externalPrimaryCursorMoveTask = nil
        externalSecondaryCursorClearTasks.values.forEach { $0.cancel() }
        externalSecondaryCursorClearTasks.removeAll()
        pendingAgentActivityRefreshTasks.values.forEach { $0.cancel() }
        pendingAgentActivityRefreshTasks.removeAll()
        pendingRelaunchableSnapshotPersistTask?.cancel()
        pendingRelaunchableSnapshotPersistTask = nil
        pendingRelaunchableAgentResumeTask?.cancel()
        pendingRelaunchableAgentResumeTask = nil
        relaunchableAgentResumeTimer?.invalidate()
        relaunchableAgentResumeTimer = nil
        autoResumedRelaunchSessionIDs.removeAll()
        pendingAgentDockItemRemovalTasks.values.forEach { $0.cancel() }
        pendingAgentDockItemRemovalTasks.removeAll()
        agentStatusCancellables.removeAll()
        agentActivityCancellables.removeAll()
        agentLoopActivityCancellables.removeAll()
        agentProgressStageCancellables.removeAll()
        agentTitleCancellables.removeAll()
        shortcutTransitionCancellable?.cancel()
        shiftDoubleTapCancellable?.cancel()
        escapeKeyCancellable?.cancel()
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
        let previouslyHadCamera = hasCameraPermission
        let previouslyHadFullDiskAccess = hasFullDiskAccessPermission
        let previouslyHadSystemEventsAutomation = hasSystemEventsAutomationPermission
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

        let cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
        hasCameraPermission = cameraAuthStatus == .authorized

        // Screen content permission is persisted after the ScreenCaptureKit
        // picker approves it, but it is only useful when real Screen Recording
        // permission is also present.
        let persistedScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        hasScreenContentPermission = hasScreenRecordingPermission && persistedScreenContentPermission
        hasFullDiskAccessPermission = OpenClickyMacPrivacyPermissionProbe.hasLikelyFullDiskAccess()
        hasSystemEventsAutomationPermission = OpenClickyMacPrivacyPermissionProbe.hasSystemEventsAutomationPermission(prompt: false)

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission
            || previouslyHadCamera != hasCameraPermission
            || previouslyHadFullDiskAccess != hasFullDiskAccessPermission
            || previouslyHadSystemEventsAutomation != hasSystemEventsAutomationPermission {
            print("Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), camera: \(hasCameraPermission), screenContent: \(hasScreenContentPermission), fullDiskAccess: \(hasFullDiskAccessPermission), systemEventsAutomation: \(hasSystemEventsAutomationPermission)")
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
            warmRealtimeVoiceInputIfNeeded(reason: "microphone_permission_granted")
        }
        if !previouslyHadCamera && hasCameraPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "camera")
        }
        if !previouslyHadFullDiskAccess && hasFullDiskAccessPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "full_disk_access")
        }
        if !previouslyHadSystemEventsAutomation && hasSystemEventsAutomationPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "system_events_automation")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }

        if hasMicrophonePermission, voiceActivationMode == .alwaysWakeWord {
            startWakeWordListeningIfNeeded(reason: "permissions_refreshed")
        } else if !hasMicrophonePermission {
            wakeWordManager.stop(reason: "microphone_permission_missing")
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
                    if hasCompletedOnboarding && !isOverlayVisible && isClickyCursorEnabled {
                        showCursorOverlayIfAvailable()
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

    func loadBundledKnowledgeIndex() {
        let memoriesDirectory = codexHomeManager.memoriesDirectory
        let learnedSkillsDirectory = codexHomeManager.learnedSkillsDirectory

        Task.detached(priority: .utility) {
            let bundledIndex = OpenClickyCore.WikiManager.Index.loadForAppBundle()
            let resolvedIndex: OpenClickyCore.WikiManager.Index

            do {
                try FileManager.default.createDirectory(at: memoriesDirectory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: learnedSkillsDirectory, withIntermediateDirectories: true)
                let memoryIndex = try OpenClickyCore.WikiManager.Index.load(articleRoots: [memoriesDirectory], skillRoots: [learnedSkillsDirectory])
                resolvedIndex = bundledIndex.combined(with: memoryIndex)
            } catch {
                print("⚠️ OpenClicky memory index load failed: \(error)")
                resolvedIndex = bundledIndex
            }

            await MainActor.run {
                self.bundledKnowledgeIndex = resolvedIndex
            }
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

    /// Triggers the system camera prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForCameraIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasCameraPermission = granted
            }
        }
    }

    /// Public entry point used by the permission guide and first-run onboarding
    /// to surface the native camera prompt. If the user has already responded,
    /// fall back to opening System Settings so they can flip the toggle.
    func requestCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .notDetermined:
            promptForCameraIfNotDetermined()
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        case .authorized:
            hasCameraPermission = true
        @unknown default:
            break
        }
    }

    /// Called when the permission guide or first-run onboarding becomes visible
    /// to request the base voice permission. Camera is requested only when the
    /// user enables a camera-specific feature.
    func requestPendingPermissionPrompts() {
        promptForMicrophoneIfNotDetermined()
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
                buddyDictationManager.$isRecordingFromMicrophoneButton,
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isKeyboardRecording, isMicrophoneButtonRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Realtime/Voice Agent microphone capture bypasses
                // BuddyDictationManager, so its recording flags stay false
                // while macOS is genuinely using the mic. Do not let this
                // observer flip the cursor back to idle during that direct
                // capture path.
                if self.isRealtimeBidirectionalVoiceCaptureActive {
                    if self.voiceState != .responding {
                        self.voiceState = .listening
                    }
                    return
                }

                // Don't let an old speaking state mask a real microphone
                // capture. Push-to-talk can interrupt speech and immediately
                // start listening; in that case the cursor must switch to the
                // waveform instead of staying in the response indicator.
                if self.voiceState == .responding,
                   !isKeyboardRecording,
                   !isMicrophoneButtonRecording,
                   !isFinalizing,
                   !isPreparing {
                    return
                }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isKeyboardRecording || isMicrophoneButtonRecording {
                    // Agent overlay / HUD Voice buttons use the microphone-
                    // button path, not the global keyboard shortcut path.
                    // Treat both as active listening so the cursor swaps to
                    // the recording waveform in every voice-capture entry.
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

        shiftDoubleTapCancellable = globalPushToTalkShortcutMonitor
            .shiftDoubleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.showMainOpenClickyPanelFromShortcut()
            }

        escapeKeyCancellable = globalPushToTalkShortcutMonitor
            .escapeKeyPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleEscapeKeyPressed()
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
                if status != .stopped {
                    self.cancelPendingAgentDockItemRemoval(for: sessionID)
                }
                self.updateAgentDockItem(for: sessionID, status: status)
                self.refreshNotchAgentLiveActivity()
                self.scheduleWidgetSnapshotPublish()
                self.scheduleRelaunchableAgentSessionsPersist()
                self.updateAgentProgressNarration()
            }

        agentActivityCancellables[session.id] = session.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] _ in
                self?.scheduleAgentActivityRefresh(for: sessionID)
                self?.scheduleRelaunchableAgentSessionsPersist()
            }

        agentLoopActivityCancellables[session.id] = session.$activityStatusLines
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] _ in
                self?.scheduleAgentActivityRefresh(for: sessionID)
            }

        agentProgressStageCancellables[session.id] = session.$progressStage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshNotchAgentLiveActivity()
                self?.scheduleRelaunchableAgentSessionsPersist()
            }

        agentTitleCancellables[session.id] = session.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self, sessionID = session.id] title in
                self?.updateAgentDockTitle(for: sessionID, title: title)
                self?.refreshNotchAgentLiveActivity()
                self?.scheduleRelaunchableAgentSessionsPersist()
            }
    }

    private func refreshNotchAgentLiveActivity() {
        notchCaptureWindowManager.updateAgentLiveActivity(companionManager: self)
    }

    private func persistRelaunchableAgentSessions() {
        pendingRelaunchableSnapshotPersistTask?.cancel()
        pendingRelaunchableSnapshotPersistTask = nil
        ChatWorkspaceArchiveStore.saveRelaunchableSnapshots(
            for: codexAgentSessions,
            archivedSessionIDs: archivedSessionIDs
        )
    }

    private func scheduleRelaunchableAgentSessionsPersist() {
        pendingRelaunchableSnapshotPersistTask?.cancel()
        pendingRelaunchableSnapshotPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.persistRelaunchableAgentSessions()
            }
        }
    }

    private func startRelaunchableAgentAutoResumeChecks() {
        relaunchableAgentResumeTimer?.invalidate()
        scheduleRelaunchableAgentAutoResumeCheck(trigger: "startup")

        let timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRelaunchableAgentAutoResumeCheck(trigger: "periodic")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        relaunchableAgentResumeTimer = timer
    }

    private func scheduleRelaunchableAgentAutoResumeCheck(trigger: String) {
        pendingRelaunchableAgentResumeTask?.cancel()
        pendingRelaunchableAgentResumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(trigger == "startup" ? 1500 : 250))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.resumeRestoredAgentTasksIfNeeded(trigger: trigger)
            }
        }
    }

    private func resumeRestoredAgentTasksIfNeeded(trigger: String) {
        pendingRelaunchableAgentResumeTask = nil
        let sessionsToResume = codexAgentSessions.filter { session in
            session.canResumeAfterRelaunch
                && !archivedSessionIDs.contains(session.id)
                && !autoResumedRelaunchSessionIDs.contains(session.id)
        }
        guard !sessionsToResume.isEmpty else { return }

        let ids = sessionsToResume.map(\.id)
        autoResumedRelaunchSessionIDs.formUnion(ids)
        activeCodexAgentSessionID = ids.first ?? activeCodexAgentSessionID
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "openclicky.agent_task.auto_resume",
            fields: [
                "trigger": trigger,
                "count": sessionsToResume.count,
                "sessionIDs": ids.map(\.uuidString),
                "titles": sessionsToResume.map(\.title)
            ]
        )

        sessionsToResume.forEach { session in
            updateAgentDockItem(for: session.id, status: session.status)
            session.resumeInterruptedTaskAfterRelaunch()
        }
        refreshNotchAgentLiveActivity()
        scheduleWidgetSnapshotPublish()
        scheduleRelaunchableAgentSessionsPersist()
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

        // Short debounce so streaming assistant deltas feel real-time in the
        // dock caption. The old 450ms interval batched too aggressively and
        // produced visibly "stalled" updates while tokens were arriving.
        pendingAgentActivityRefreshTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            await MainActor.run {
                guard let self else { return }
                self.pendingAgentActivityRefreshTasks[sessionID] = nil
                guard let session = self.codexAgentSessions.first(where: { $0.id == sessionID }) else { return }
                self.updateAgentDockItem(for: sessionID, status: session.status)
                self.refreshNotchAgentLiveActivity()
                self.scheduleWidgetSnapshotPublish()
                self.updateAgentProgressNarration()
            }
        }
    }

    @discardableResult
    func createAndSelectNewCodexAgentSession(title: String? = nil, accentTheme: ClickyAccentTheme? = nil) -> CodexAgentSession {
        let resolvedAccentTheme = accentTheme ?? Self.nextAgentDockAccentTheme(existingCount: codexAgentSessions.count)
        // Inject the persistent Claude Agent SDK bridge so title generation
        // follows the money rule (SDK first, direct REST fallback). See
        // CodexAgentSession.fastFriendlyTitle.
        let session = CodexAgentSession(
            title: title ?? "Ask Agent",
            accentTheme: resolvedAccentTheme,
            claudeAgentSDKAPI: claudeAgentSDKAPI
        )
        codexAgentSessions.append(session)
        observeCodexAgentSession(session)
        activeCodexAgentSessionID = session.id
        lastAgentContextSessionID = session.id
        scheduleWidgetSnapshotPublish()
        scheduleRelaunchableAgentSessionsPersist()
        return session
    }

    private func resolvedNewAgentTaskPrompt(from prompt: String) -> String {
        let explicitInstruction = Self.agentTaskCreationInstruction(from: prompt)
            ?? Self.permissiveAgentInstruction(from: prompt)
            ?? Self.clickyAgentInstruction(from: prompt)
        guard let explicitInstruction else { return prompt }

        var instruction = SpokenText.normalizedAgentTaskInstruction(from: explicitInstruction)
        if Self.isReferentialAgentInstruction(instruction),
           let resolvedInstruction = referentialAgentInstructionContext(excluding: prompt) {
            instruction = resolvedInstruction
        }

        instruction = SpokenText.cleanedAgentTaskInstruction(instruction)
        guard !instruction.isEmpty,
              !Self.isAgentTaskPlaceholderInstruction(instruction) else {
            return prompt
        }
        return instruction
    }

    /// Creates a brand-new agent session, stages it into the same dock/menu
    /// surfaces as a normal agent task, then submits the initial prompt.
    @discardableResult
    func createAndLaunchCodexAgentSession(
        title: String? = nil,
        prompt: String,
        accentTheme: ClickyAccentTheme? = nil,
        includeScreenContext: Bool = true,
        restrictedExecutionPolicy: Bool = false
    ) -> CodexAgentSession {
        let session = createAndSelectNewCodexAgentSession(title: title, accentTheme: accentTheme)
        if restrictedExecutionPolicy {
            session.configureRestrictedExecutionPolicy()
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return session }
        stageDashboardAgentSubmission(prompt: trimmedPrompt, session: session)
        submitAgentPrompt(trimmedPrompt, to: session, includeScreenContext: includeScreenContext)
        return session
    }

    private func handleAgentFoundOpenableFile(_ fileURL: URL, session: CodexAgentSession) {
        let standardizedURL = fileURL.standardizedFileURL
        let eventKey = "\(session.id.uuidString)|\(standardizedURL.path)"
        guard !announcedAgentFileURLs.contains(eventKey) else { return }

        announcedAgentFileURLs.insert(eventKey)
        openOpenClickyDocument(standardizedURL)
        speakShortSystemResponse("\(session.spokenAgentSentenceName) says it found \(Self.spokenFileName(for: standardizedURL)), showing it now.")
    }

    private static func isMarkdownDocument(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
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

    /// Mark a session as archived. Keeps the session alive so its transcript and state
    /// are preserved; the sidebar groups archived sessions under a separate header.
    func archiveSession(_ sessionID: UUID, allowIncomplete: Bool = false) {
        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else { return }
        let isActivelyRunning: Bool = {
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }()
        guard !isActivelyRunning, !session.isTurnActiveForChatQueue else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.archive_blocked_running",
                fields: [
                    "sessionID": sessionID.uuidString,
                    "title": session.title
                ]
            )
            return
        }
        guard allowIncomplete || session.isFinishedForArchive else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.archive_blocked_incomplete",
                fields: [
                    "sessionID": sessionID.uuidString,
                    "title": session.title,
                    "progressStage": session.progressStage.label
                ]
            )
            return
        }
        var updatedArchivedSessionIDs = archivedSessionIDs
        updatedArchivedSessionIDs.insert(sessionID)
        archivedSessionIDs = updatedArchivedSessionIDs
        ChatWorkspaceArchiveStore.save(archivedSessionIDs)
        ChatWorkspaceArchiveStore.saveSnapshot(for: session)
        ChatWorkspaceArchiveStore.removeRelaunchableSnapshot(for: sessionID)
        cancelPendingAgentDockItemRemoval(for: sessionID)
        silenceAgentSpeech(for: sessionID, reason: "agent_session_archived")
        agentDockItems.removeAll { $0.sessionID == sessionID }
        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }
        refreshAgentDockFollowBehavior()
        refreshNotchAgentLiveActivity()
        if activeCodexAgentSessionID == sessionID {
            if let next = codexAgentSessions.first(where: { !archivedSessionIDs.contains($0.id) }) {
                selectCodexAgentSession(next.id)
            } else {
                _ = createAndSelectNewCodexAgentSession()
            }
        }
        scheduleWidgetSnapshotPublish()
    }

    /// Restore a previously archived session.
    func unarchiveSession(_ sessionID: UUID) {
        guard archivedSessionIDs.contains(sessionID) else { return }
        var updatedArchivedSessionIDs = archivedSessionIDs
        updatedArchivedSessionIDs.remove(sessionID)
        archivedSessionIDs = updatedArchivedSessionIDs
        ChatWorkspaceArchiveStore.save(archivedSessionIDs)
        ChatWorkspaceArchiveStore.removeSnapshot(for: sessionID)
        persistRelaunchableAgentSessions()
        scheduleWidgetSnapshotPublish()
    }

    /// Pop the currently active session into a floating mini-chat NSPanel scoped to that session.
    /// The mini-chat dies with the parent HUD via `MiniChatPanelManager.shared.destroyAll()`.
    func popoutCurrentSession() {
        let session = codexAgentSession
        MiniChatPanelManager.shared.show(session: session, companion: self)
    }

    /// Launch a new chat session pre-configured as a specialist OpenClicky
    /// agent. The agent's soul/instructions/memory are layered into the
    /// session's system prompt via `prependedSystemContext`.
    @discardableResult
    func createAndSelectNewCodexAgentSession(asAgent agent: OpenClickyAgentDefinition) -> CodexAgentSession {
        let session = createAndSelectNewCodexAgentSession(title: agent.metadata.displayName)
        session.prependedSystemContext = agent.renderedSystemContext()
        session.specialistAgentSlug = agent.slug
        return session
    }

    func closeCodexAgentSession(_ sessionID: UUID) {
        guard let closingIndex = codexAgentSessions.firstIndex(where: { $0.id == sessionID }) else { return }

        let closingSession = codexAgentSessions[closingIndex]
        closingSession.stop(reason: "chat_session_closed")
        closingSession.onOpenableFileFound = nil

        cancelPendingAgentDockItemRemoval(for: sessionID)
        pendingAgentActivityRefreshTasks[sessionID]?.cancel()
        pendingAgentActivityRefreshTasks.removeValue(forKey: sessionID)
        pendingAgentDockItemRemovalTasks.removeValue(forKey: sessionID)
        agentStatusCancellables.removeValue(forKey: sessionID)
        agentActivityCancellables.removeValue(forKey: sessionID)
        agentLoopActivityCancellables.removeValue(forKey: sessionID)
        agentProgressStageCancellables.removeValue(forKey: sessionID)
        agentTitleCancellables.removeValue(forKey: sessionID)
        agentRequestTimingsBySessionID.removeValue(forKey: sessionID)
        agentExecutionStartDatesBySessionID.removeValue(forKey: sessionID)
        lastNarratedAgentOutcomeBySessionID.removeValue(forKey: sessionID)

        var updatedArchivedSessionIDs = archivedSessionIDs
        updatedArchivedSessionIDs.remove(sessionID)
        archivedSessionIDs = updatedArchivedSessionIDs
        ChatWorkspaceArchiveStore.save(archivedSessionIDs)
        ChatWorkspaceArchiveStore.removeSnapshot(for: sessionID)
        ChatWorkspaceArchiveStore.removeRelaunchableSnapshot(for: sessionID)

        codexAgentSessions.remove(at: closingIndex)
        agentDockItems.removeAll { $0.sessionID == sessionID }

        if pendingAgentVoiceFollowUpSessionID == sessionID {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            pendingAgentVoiceFollowUpSource = nil
        }
        if lastAgentContextSessionID == sessionID {
            lastAgentContextSessionID = nil
        }

        if codexAgentSessions.isEmpty {
            _ = createAndSelectNewCodexAgentSession()
        } else if activeCodexAgentSessionID == sessionID {
            let fallbackIndex = min(closingIndex, codexAgentSessions.count - 1)
            selectCodexAgentSession(codexAgentSessions[fallbackIndex].id)
        }

        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_session.closed",
            fields: [
                "sessionID": sessionID.uuidString,
                "title": closingSession.title
            ]
        )
        refreshNotchAgentLiveActivity()
        scheduleWidgetSnapshotPublish()
        persistRelaunchableAgentSessions()
    }

    func beginRequestTiming(source: String, text: String) -> OpenClickyRequestTiming {
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

    func markRequestExecutionStarted(
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

    func markRequestStageCompleted(
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

    func markRequestCompleted(
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

    private static func elapsedMilliseconds(since startDate: Date?) -> Int {
        guard let startDate else { return -1 }
        return elapsedMilliseconds(from: startDate, to: Date())
    }

    static func voiceResponseCompletionAudioPlaybackState(
        spokenText: String,
        playbackFinished: Bool,
        audioStarted: Bool = true
    ) -> String {
        guard !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "empty"
        }
        // A TTS session whose engine was torn down still resolves finish()
        // successfully — "finished" is only honest if audio actually
        // reached the speaker.
        guard audioStarted else {
            return "never_started"
        }
        return playbackFinished ? "finished" : "interrupted"
    }

    private static func truncatedLogText(_ value: String, maxLength: Int) -> String {
        let flattened = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > maxLength else { return flattened }
        return String(flattened.prefix(maxLength))
    }

    func voiceResponseExecutionFields(effectiveModelID: String? = nil) -> [String: Any] {
        let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        let executionModel = effectiveModelID.map { OpenClickyModelCatalog.voiceResponseModel(withID: $0) }
            ?? selectedVoiceResponseModel
        var fields: [String: Any] = [
            "executor": "voice_response",
            "model": executionModel.id,
            "modelProvider": executionModel.provider.rawValue,
            "maxOutputTokens": executionModel.maxOutputTokens,
            "playbackEngine": selectedTTSProvider.rawValue,
            "playbackController": activeTTSControllerName,
            "speechModel": selectedSpeechModel,
            "speechVoice": activeRealtimeSpeechVoiceID
        ]

        if executionModel.id != selectedVoiceResponseModel.id {
            fields["selectedVoiceResponseModel"] = selectedVoiceResponseModel.id
            fields["visualAnalysisModel"] = executionModel.id
            fields["realtimeVisualPathOverride"] = OpenClickyModelCatalog.isSpeechModelID(selectedVoiceResponseModel.id)
        }

        switch executionModel.provider {
        case .anthropic:
            if AppBundleConfiguration.anthropicAPIKey() != nil {
                fields["executionMethod"] = "ClaudeAPI.analyzeImageStreaming"
                fields["authMode"] = "anthropic_api_key_primary"
                fields["transport"] = "sse"
                fields["streamingMethod"] = "URLSession.bytes"
                fields["agentSDKFallbackAvailable"] = claudeAgentSDKAPI != nil
            } else if claudeAgentSDKAPI != nil {
                fields["executionMethod"] = "ClaudeAgentSDKAPI.analyzeImageStreaming"
                fields["authMode"] = "local_claude_agent_sdk_primary"
                fields["transport"] = "agent_sdk_query"
                fields["streamingMethod"] = "claude_agent_sdk_query"
                fields["apiKeyFallback"] = false
            } else {
                fields["executionMethod"] = "ClaudeAgentSDKAPI.analyzeImageStreaming"
                fields["authMode"] = "local_claude_agent_sdk_missing"
                fields["transport"] = "agent_sdk_query"
                fields["streamingMethod"] = "claude_agent_sdk_query"
            }
        case .openAI:
            if OpenClickyModelCatalog.isSpeechModelID(executionModel.id) {
                fields["executionMethod"] = "OpenAIRealtimeSpeechClient.beginBidirectionalVoiceTurn"
                fields["authMode"] = "openai_api_key_primary"
                fields["transport"] = "realtime_websocket"
                fields["streamingMethod"] = "input_audio_buffer.append + response.output_audio.delta"
                fields["inputPath"] = "realtime_input_audio_buffer"
                fields["bypassesWhisper"] = true
                fields["playbackEngine"] = OpenClickyTTSProvider.openAIRealtime.rawValue
                fields["speechModel"] = executionModel.id
            } else if AppBundleConfiguration.openAIAPIKey() != nil {
                fields["executionMethod"] = "OpenAIAPI.analyzeImageStreaming"
                fields["authMode"] = "openai_api_key_primary"
                fields["transport"] = "responses_api_sse"
                fields["streamingMethod"] = "URLSession.bytes"
                fields["codexFallbackAvailable"] = true
            } else {
                fields["executionMethod"] = "CodexVoiceSession.analyzeImageStreaming"
                fields["authMode"] = "local_codex_chatgpt_primary"
                fields["transport"] = "codex_app_server_stdio"
                fields["streamingMethod"] = "codex_app_server_agentMessage_delta"
                fields["apiKeyFallback"] = false
            }
        case .deepgram:
            fields["executionMethod"] = "DeepgramVoiceAgentClient.beginBidirectionalVoiceTurn"
            fields["authMode"] = "deepgram_api_key_primary"
            fields["transport"] = "deepgram_voice_agent_websocket"
            fields["streamingMethod"] = "binary PCM in/out + ConversationText"
            fields["inputPath"] = "deepgram_voice_agent_pcm_stream"
            fields["bypassesWhisper"] = true
            fields["playbackEngine"] = "deepgram_voice_agent"
            fields["speechVoice"] = deepgramVoiceAgentClient.voiceID
            fields["thinkModel"] = deepgramVoiceAgentClient.thinkModel
        case .codex:
            fields["executionMethod"] = "CodexVoiceSession.analyzeImageStreaming"
            fields["authMode"] = "local_codex_chatgpt_primary"
            fields["transport"] = "codex_app_server_stdio"
            fields["streamingMethod"] = "codex_app_server_agentMessage_delta"
            fields["apiKeyFallback"] = AppBundleConfiguration.openAIAPIKey() != nil
        }

        return fields
    }

    private func handleEscapeKeyPressed() {
        let isVoiceActive = voiceTTSClient.isPlaying
            || openAIRealtimeSpeechClient.isPlaying
            || deepgramVoiceAgentClient.isPlaying
            || voiceState == .responding
            || voiceState == .processing
            || currentResponseTask != nil
            || realtimeBidirectionalVoiceTask != nil

        guard isVoiceActive else { return }

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: "voice.escape_stop_requested",
            fields: [
                "voiceState": voiceState.rawValue,
                "ttsPlaying": voiceTTSClient.isPlaying,
                "openAIRealtimePlaying": openAIRealtimeSpeechClient.isPlaying,
                "deepgramVoiceAgentPlaying": deepgramVoiceAgentClient.isPlaying
            ]
        )
        cancelCircleSelectSession(clearPending: true)
        interruptCurrentVoiceResponse()
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            if voiceActivationMode.usesWakeWord {
                guard !showOnboardingVideo else { return }
                toggleWakeWordListeningFromShortcut()
                return
            }
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

            // Reset speculative-fire counters so this utterance starts
            // with a clean budget. The previous turn's state cannot
            // influence this one.
            resetSpeculativeFireForNewUtterance()

            // Kick off the screenshot the moment the key goes down so it
            // captures in parallel with audio recording instead of blocking
            // the response path after the final transcript arrives.
            startPrewarmedScreenshotCaptureIfPossible()
            beginCircleSelectSessionIfEnabled()

            pendingKeyboardShortcutStartTask?.cancel()
            if shouldUseBidirectionalRealtimeVoiceInput {
                startBidirectionalRealtimeVoiceCapture(source: "keyboardShortcut")
                return
            }

            clearDetectedElementLocation()
            liveHandledComputerUseFingerprints.removeAll()

            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { [weak self] partialTranscript in
                        self?.circleSelectLivePartialTranscript = partialTranscript
                        self?.circleSelectSession.refreshSnapUsingLatestTranscript()
                        self?.handleLiveComputerUseTranscript(partialTranscript)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.handleFinalVoiceTranscript(finalTranscript)
                    },
                    onWillStartRecording: { [weak self] in
                        // Only cut playback once the non-Realtime dictation
                        // path is actually going to capture audio. A quick
                        // press/release during provider or permission startup
                        // should not skip the current spoken reply.
                        self?.interruptCurrentVoiceResponse()
                    }
                )
            }
        case .released:
            if voiceActivationMode.usesWakeWord {
                return
            }
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            finishCircleSelectSessionForVoiceTurn()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            if finishBidirectionalRealtimeVoiceCaptureIfNeeded(source: "keyboardShortcut") {
                return
            }
            // Keep the prewarmed screenshot — even on a quick press the user
            // may still produce a final transcript (e.g. wake-word). The
            // freshness check in the consumer discards stale captures.
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    func beginCircleSelectSessionIfEnabled() {
        guard AppBundleConfiguration.isCircleWhileTalkingEnabled() else {
            cancelCircleSelectSession(clearPending: false)
            return
        }
        pendingCircleSelectCaptureTask?.cancel()
        pendingCircleSelectCaptureTask = nil
        pendingCircleSelectExpiryTask?.cancel()
        pendingCircleSelectExpiryTask = nil
        pendingCircleSelectStroke = nil
        circleSelectLivePartialTranscript = ""
        clearCircleSelectOverlay()
        // Drop prior circle handoffs so a new hold never reuses a stale region.
        handoffQueue.removeAll { $0.selection.hasFreehandPath }

        let requireClick = AppBundleConfiguration.isCircleWhileTalkingRequireClickEnabled()
        circleSelectSession.start(
            requireClick: requireClick,
            partialTranscriptProvider: { [weak self] in
                guard let self else { return nil }
                let live = self.circleSelectLivePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !live.isEmpty { return live }
                let last = self.lastTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return last.isEmpty ? nil : last
            },
            onPointsChanged: { [weak self] points in
                self?.cursorOverlayState.circleSelectLivePoints = points
            },
            onSnapChanged: { [weak self] snap in
                self?.cursorOverlayState.circleSelectSnappedRect = snap?.rect
                self?.cursorOverlayState.circleSelectSnapLabel = snap?.label
            }
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.circle_select.started",
            fields: [
                "requireClick": requireClick
            ]
        )
    }

    func finishCircleSelectSessionForVoiceTurn() {
        guard AppBundleConfiguration.isCircleWhileTalkingEnabled() || circleSelectSession.isActive else {
            clearCircleSelectOverlay()
            return
        }

        let sealed = circleSelectSession.stop()
        // Keep snapped rect visible briefly after seal so the handoff feels deliberate.
        if let snap = sealed?.snap {
            cursorOverlayState.circleSelectSnappedRect = snap.rect
            cursorOverlayState.circleSelectSnapLabel = snap.label
        }
        cursorOverlayState.circleSelectLivePoints = sealed?.points ?? []
        pendingCircleSelectStroke = sealed

        if let sealed {
            // Keep the trail / snap visible briefly so the user sees the sealed region.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self else { return }
                if self.pendingCircleSelectStroke?.sealedAt == sealed.sealedAt {
                    self.clearCircleSelectOverlay()
                }
            }
            pendingCircleSelectCaptureTask?.cancel()
            pendingCircleSelectCaptureTask = Task { @MainActor in
                do {
                    let crop = try await CompanionScreenCaptureUtility.captureRegionAsJPEG(sealed.captureRect)
                    let selection = sealed.handoffSelection(instruction: "")
                    let queued = HandoffQueuedRegionScreenshot(selection: selection, imageData: crop.imageData)
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice",
                        direction: "internal",
                        event: "voice.circle_select.sealed",
                        fields: [
                            "pointCount": sealed.points.count,
                            "pathLength": Int(sealed.pathLength.rounded()),
                            "width": Int(sealed.captureRect.width.rounded()),
                            "height": Int(sealed.captureRect.height.rounded()),
                            "imageBytes": crop.imageData.count
                        ]
                    )
                    return queued
                } catch {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice",
                        direction: "error",
                        event: "voice.circle_select.capture_failed",
                        fields: ["error": error.localizedDescription]
                    )
                    return nil
                }
            }
            pendingCircleSelectExpiryTask?.cancel()
            pendingCircleSelectExpiryTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard let self,
                      self.pendingCircleSelectStroke?.sealedAt == sealed.sealedAt else {
                    return
                }
                self.cancelCircleSelectSession()
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "internal",
                    event: "voice.circle_select.expired",
                    fields: ["reason": "no_matching_voice_turn"]
                )
            }
        } else {
            clearCircleSelectOverlay()
            pendingCircleSelectCaptureTask = nil
            pendingCircleSelectExpiryTask?.cancel()
            pendingCircleSelectExpiryTask = nil
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.circle_select.discarded",
                fields: ["reason": "below_threshold_or_disabled"]
            )
        }
    }

    func cancelCircleSelectSession(clearPending: Bool = true) {
        circleSelectSession.cancel()
        clearCircleSelectOverlay()
        if clearPending {
            pendingCircleSelectStroke = nil
            pendingCircleSelectCaptureTask?.cancel()
            pendingCircleSelectCaptureTask = nil
            pendingCircleSelectExpiryTask?.cancel()
            pendingCircleSelectExpiryTask = nil
        }
    }

    private func clearCircleSelectOverlay() {
        cursorOverlayState.circleSelectLivePoints = []
        cursorOverlayState.circleSelectSnappedRect = nil
        cursorOverlayState.circleSelectSnapLabel = nil
    }

    /// Consumes a sealed circle-select capture for the current voice/agent turn.
    /// Returns crop attachment data plus ambient note when the user circled while talking.
    func consumePendingCircleSelectHandoff(instruction: String) async -> HandoffQueuedRegionScreenshot? {
        let sealed = pendingCircleSelectStroke
        let captureTask = pendingCircleSelectCaptureTask
        pendingCircleSelectStroke = nil
        pendingCircleSelectCaptureTask = nil
        pendingCircleSelectExpiryTask?.cancel()
        pendingCircleSelectExpiryTask = nil
        clearCircleSelectOverlay()

        guard sealed != nil || captureTask != nil else { return nil }

        let queued = await captureTask?.value
        if var existing = queued {
            existing.selection.comment = instruction
            if let sealed {
                existing.selection.pathPoints = sealed.points
                existing.selection.ambientSummary = sealed.ambient.summaryLine
                existing.selection.startPositionInScreen = sealed.startPositionInScreen
                existing.selection.endPositionInScreen = sealed.endPositionInScreen
                existing.selection.screenFrame = sealed.screenFrame
            }
            return existing
        }

        guard let sealed else { return nil }
        do {
            let crop = try await CompanionScreenCaptureUtility.captureRegionAsJPEG(sealed.captureRect)
            return HandoffQueuedRegionScreenshot(
                selection: sealed.handoffSelection(instruction: instruction),
                imageData: crop.imageData
            )
        } catch {
            return nil
        }
    }

    var shouldUseBidirectionalRealtimeVoiceInput: Bool {
        OpenClickyModelCatalog.isSpeechModelID(selectedModel)
    }

    private var activeRealtimeSpeechVoiceID: String {
        let model = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        return model.provider == .deepgram ? deepgramVoiceAgentClient.voiceID : openAIRealtimeSpeechClient.voiceID
    }

    private var activeRealtimeInputPath: String {
        let model = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        return model.provider == .deepgram ? "deepgram_voice_agent_pcm_stream" : "realtime_input_audio_buffer"
    }

    private var activeRealtimeThinkModel: String {
        let model = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        return model.provider == .deepgram ? deepgramVoiceAgentClient.thinkModel : openAIRealtimeSpeechClient.model
    }

    private func toggleWakeWordListeningFromShortcut() {
        guard isActivationShortcutEnabled else { return }
        if wakeWordManager.isListening || wakeWordManager.isStarting {
            isWakeWordPausedByShortcut = true
            wakeWordManager.stop(reason: "activation_shortcut_toggle_off")
            return
        }
        isWakeWordPausedByShortcut = false
        startWakeWordListeningIfNeeded(reason: "activation_shortcut_toggle_on")
    }

    private func startWakeWordListeningIfNeeded(reason: String) {
        guard voiceActivationMode.usesWakeWord,
              isActivationShortcutEnabled,
              !isWakeWordPausedByShortcut,
              voiceState == .idle,
              !buddyDictationManager.isDictationInProgress,
              !isRealtimeBidirectionalVoiceCaptureActive,
              !voiceTTSClient.isPlaying,
              !openAIRealtimeSpeechClient.isPlaying,
              !deepgramVoiceAgentClient.isPlaying,
              !wakeWordManager.isListening,
              !wakeWordManager.isStarting else {
            return
        }

        pendingWakeWordRestartTask?.cancel()
        pendingWakeWordRestartTask = nil
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.wake_listener.start_requested",
            fields: [
                "reason": reason,
                "mode": voiceActivationMode.rawValue
            ]
        )
        Task { [weak self] in
            await self?.wakeWordManager.start()
        }
    }

    private func scheduleWakeWordListeningResumeIfNeeded(reason: String) {
        guard voiceActivationMode.usesWakeWord else { return }
        pendingWakeWordRestartTask?.cancel()
        pendingWakeWordRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            await MainActor.run {
                guard let self else { return }
                self.pendingWakeWordRestartTask = nil
                self.startWakeWordListeningIfNeeded(reason: reason)
            }
        }
    }

    private func handleWakeWordDetected(_ transcript: String) {
        guard voiceActivationMode.usesWakeWord else { return }

        transientHideTask?.cancel()
        transientHideTask = nil
        voiceFollowUpStopTask?.cancel()
        voiceFollowUpStopTask = nil
        wakeWordAudioDucker.duck(reason: "wake_word_detected")
        resetSpeculativeFireForNewUtterance()
        startPrewarmedScreenshotCaptureIfPossible()
        showCursorOverlayIfAvailable()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.wake_word.turn_started",
            fields: [
                "mode": voiceActivationMode.rawValue,
                "wakeTranscriptLength": transcript.count
            ]
        )

        if shouldUseBidirectionalRealtimeVoiceInput {
            startBidirectionalRealtimeVoiceCapture(source: "wakeWord")
            voiceFollowUpStopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    self.voiceFollowUpStopTask = nil
                    _ = self.finishBidirectionalRealtimeVoiceCaptureIfNeeded(source: "wakeWord")
                }
            }
            return
        }

        clearDetectedElementLocation()
        liveHandledComputerUseFingerprints.removeAll()
        Task { [weak self] in
            guard let self else { return }
            await self.buddyDictationManager.startAutoSubmittingDictationFromMicrophoneButton(
                currentDraftText: "",
                updateDraftText: { _ in },
                submitDraftText: { [weak self] finalTranscript in
                    self?.wakeWordAudioDucker.restore(reason: "wake_word_dictation_completed")
                    self?.handleFinalVoiceTranscript(finalTranscript)
                },
                onWillStartRecording: { [weak self] in
                    self?.interruptCurrentVoiceResponse()
                }
            )
        }
        voiceFollowUpStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                guard let self else { return }
                self.voiceFollowUpStopTask = nil
                self.buddyDictationManager.stopPersistentDictationFromMicrophoneButton()
                self.wakeWordAudioDucker.restore(reason: "wake_word_dictation_timeout")
            }
        }
    }

    private struct BidirectionalRealtimeVoiceResult {
        let userTranscript: String
        let assistantTranscript: String
        let didCreateAssistantResponse: Bool
        let wasRoutedByClient: Bool
    }

    func startBidirectionalRealtimeVoiceCapture(source: String) {
        guard !isRealtimeBidirectionalVoiceCaptureActive else {
            wakeWordAudioDucker.restore(reason: "realtime_start_already_active")
            return
        }
        let audioPlaybackActive = voiceTTSClient.isPlaying || openAIRealtimeSpeechClient.isPlaying || deepgramVoiceAgentClient.isPlaying
        if voiceState == .responding, !audioPlaybackActive {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.state.stale_responding_recovered",
                fields: [
                    "source": source,
                    "speechModel": selectedModel,
                    "speechVoice": activeRealtimeSpeechVoiceID,
                    "inputPath": activeRealtimeInputPath
                ]
            )
            clearVoiceResponseCaption()
            currentAudioPowerLevel = 0
            voiceState = .idle
        }
        let isPlayingResponse = audioPlaybackActive
        let startedAsInterrupt = isPlayingResponse || voiceState == .processing
        if startedAsInterrupt {
            let priorVoiceState = voiceState
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.realtime_bidirectional.previous_turn_interrupted",
                fields: [
                    "source": source,
                    "speechModel": selectedModel,
                    "speechVoice": activeRealtimeSpeechVoiceID,
                    "inputPath": activeRealtimeInputPath,
                    "voiceState": priorVoiceState.rawValue,
                    "ttsPlaying": voiceTTSClient.isPlaying,
                    "openAIRealtimePlaying": openAIRealtimeSpeechClient.isPlaying,
                    "deepgramVoiceAgentPlaying": deepgramVoiceAgentClient.isPlaying,
                    "reason": isPlayingResponse ? "previous_voice_turn_still_speaking" : "previous_voice_turn_still_processing"
                ]
            )
            interruptCurrentVoiceResponse()
        }

        clearDetectedElementLocation()
        liveHandledComputerUseFingerprints.removeAll()
        isRealtimeBidirectionalVoiceCaptureActive = true
        isRealtimeBidirectionalVoiceInputReady = false
        pendingRealtimeBidirectionalFinishSource = nil
        realtimeBidirectionalVoiceCaptureStartedAt = Date()
        realtimeBidirectionalVoiceStartedAsInterrupt = startedAsInterrupt
        voiceState = .listening
        currentAudioPowerLevel = 0
        latestVoiceResponseCard = nil
        showCursorOverlayIfAvailable()

        realtimeBidirectionalVoiceTurnGeneration &+= 1
        let turnGeneration = realtimeBidirectionalVoiceTurnGeneration
        let startedAt = Date()
        let historyForAPI = voiceConversationHistoryForAPI()
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.realtime_bidirectional.start_requested",
            fields: [
                "source": source,
                "speechModel": selectedModel,
                "speechVoice": activeRealtimeSpeechVoiceID,
                "inputPath": activeRealtimeInputPath,
                "thinkModel": activeRealtimeThinkModel,
                "bypassesWhisper": true,
                "historyCount": historyForAPI.count
            ]
        )

        realtimeBidirectionalVoiceTask?.cancel()
        realtimeBidirectionalVoiceTask = Task { [weak self] in
            do {
                guard let self else { return }
                let onUserTranscript: @MainActor @Sendable (String) -> Void = { [weak self] transcript in
                    guard self?.realtimeBidirectionalVoiceTurnGeneration == turnGeneration else { return }
                    self?.lastTranscript = transcript
                    self?.circleSelectLivePartialTranscript = transcript
                    self?.circleSelectSession.refreshSnapUsingLatestTranscript()
                }
                let onAssistantTextChunk: @MainActor @Sendable (String) -> Void = { [weak self] accumulatedText in
                    guard self?.realtimeBidirectionalVoiceTurnGeneration == turnGeneration else { return }
                    let trimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    self?.latestVoiceResponseCard = ClickyResponseCard(
                        source: .voice,
                        rawText: trimmed,
                        contextTitle: "Realtime voice input"
                    )
                    self?.updateVoiceResponseCaption(trimmed)
                }
                let onPlaybackStarted: @MainActor @Sendable () -> Void = { [weak self] in
                    guard self?.realtimeBidirectionalVoiceTurnGeneration == turnGeneration else { return }
                    self?.voiceState = .responding
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice",
                        direction: "internal",
                        event: "voice.realtime_bidirectional.audio_started",
                        fields: [
                            "source": source,
                            "speechModel": self?.selectedModel ?? "unknown",
                            "speechVoice": self?.activeRealtimeSpeechVoiceID ?? "unknown",
                            "startupDurationMs": Self.elapsedMilliseconds(since: startedAt)
                        ]
                    )
                }
                let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: self.selectedModel)
                if selectedVoiceResponseModel.provider == .deepgram {
                    try await self.deepgramVoiceAgentClient.beginBidirectionalVoiceTurn(
                        systemPrompt: self.currentRealtimeVoiceSystemPrompt(),
                        conversationHistory: historyForAPI,
                        onUserTranscript: onUserTranscript,
                        onAssistantTextChunk: onAssistantTextChunk,
                        onPlaybackStarted: onPlaybackStarted
                    )
                } else {
                    try await self.openAIRealtimeSpeechClient.beginBidirectionalVoiceTurn(
                        systemPrompt: self.currentRealtimeVoiceSystemPrompt(),
                        conversationHistory: historyForAPI,
                        onUserTranscript: onUserTranscript,
                        onAssistantTextChunk: onAssistantTextChunk,
                        onPlaybackStarted: onPlaybackStarted,
                        onInputPowerLevel: { [weak self] powerLevel in
                            self?.currentAudioPowerLevel = CGFloat(powerLevel)
                        }
                    )
                }
                await MainActor.run {
                    guard self.realtimeBidirectionalVoiceTurnGeneration == turnGeneration,
                          self.isRealtimeBidirectionalVoiceCaptureActive,
                          !Task.isCancelled else {
                        return
                    }
                    self.isRealtimeBidirectionalVoiceInputReady = true
                    self.voiceState = .listening
                    let pendingFinishSource = self.pendingRealtimeBidirectionalFinishSource
                    self.pendingRealtimeBidirectionalFinishSource = nil
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice",
                        direction: "internal",
                        event: "voice.realtime_bidirectional.input_ready",
                        fields: [
                            "source": source,
                            "pendingFinish": pendingFinishSource != nil,
                            "startupDurationMs": Self.elapsedMilliseconds(since: startedAt)
                        ]
                    )
                    if let pendingFinishSource {
                        OpenClickyMessageLogStore.shared.append(
                            lane: "voice",
                            direction: "internal",
                            event: "voice.realtime_bidirectional.pending_finish_committed",
                            fields: [
                                "source": pendingFinishSource,
                                "startupDurationMs": Self.elapsedMilliseconds(since: startedAt),
                                "captureDurationMs": Self.elapsedMilliseconds(since: self.realtimeBidirectionalVoiceCaptureStartedAt)
                            ]
                        )
                        _ = self.finishBidirectionalRealtimeVoiceCaptureIfNeeded(source: pendingFinishSource)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.handleBidirectionalRealtimeVoiceFailure(error, source: source, stage: "start")
                }
            }
        }
    }

    @discardableResult
    func finishBidirectionalRealtimeVoiceCaptureIfNeeded(source: String) -> Bool {
        guard isRealtimeBidirectionalVoiceCaptureActive else { return false }
        if !isRealtimeBidirectionalVoiceInputReady {
            pendingRealtimeBidirectionalFinishSource = source
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.realtime_bidirectional.finish_deferred_until_ready",
                fields: [
                    "source": source,
                    "speechModel": selectedModel,
                    "speechVoice": activeRealtimeSpeechVoiceID,
                    "inputPath": activeRealtimeInputPath,
                    "captureDurationMs": Self.elapsedMilliseconds(since: realtimeBidirectionalVoiceCaptureStartedAt)
                ]
            )
            return true
        }

        isRealtimeBidirectionalVoiceCaptureActive = false
        isRealtimeBidirectionalVoiceInputReady = false
        pendingRealtimeBidirectionalFinishSource = nil
        voiceState = .processing
        wakeWordAudioDucker.restore(reason: "realtime_capture_finished")

        let finishedAt = Date()
        let captureStartedAt = realtimeBidirectionalVoiceCaptureStartedAt
        let turnGeneration = realtimeBidirectionalVoiceTurnGeneration
        realtimeBidirectionalVoiceTask = Task { [weak self] in
            do {
                guard let self else { return }
                let routeBeforeAssistant: @MainActor @Sendable (String) -> Bool = { [weak self] transcript in
                    guard let self else { return false }
                    return self.routeCompletedRealtimeVoiceTranscriptIfNeeded(transcript)
                }
                let routeRealtimeToolCall: @MainActor @Sendable (String, String) -> Bool = { [weak self] toolName, transcript in
                    guard let self else { return false }
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice",
                        direction: "internal",
                        event: "voice.realtime_bidirectional.tool_route_requested",
                        fields: [
                            "toolName": toolName,
                            "transcript": transcript,
                            "speechModel": self.selectedModel,
                            "computerUseBackend": self.selectedComputerUseBackend.rawValue,
                            "computerUseModel": self.selectedComputerUseModel,
                            "backgroundAgentModel": self.codexAgentSession.model
                        ]
                    )
                    // Honor the realtime model's own IT-vs-agent decision. The
                    // model already classified this turn by picking a tool, so
                    // try the deterministic cascade first; but when the model
                    // explicitly chose background Agent Mode and no heuristic
                    // route claims the turn, force the agent dispatch instead of
                    // dropping the decision and letting the model just talk
                    // (previously the tool name was logged here and discarded).
                    // Tool-routed realtime turns can already have produced a
                    // spoken assistant acknowledgement before the app sees the
                    // function call. If the normal deterministic cascade turns
                    // that same transcript into an agent start, keep the
                    // app-level handoff silent so OpenClicky does not say the
                    // background acknowledgement twice.
                    self.suppressNextVoiceAgentStartAcknowledgement = true
                    if self.routeCompletedRealtimeVoiceTranscriptIfNeeded(transcript) {
                        if self.suppressNextVoiceAgentStartAcknowledgement {
                            self.suppressNextVoiceAgentStartAcknowledgement = false
                        }
                        return true
                    }
                    self.suppressNextVoiceAgentStartAcknowledgement = false
                    if toolName == "openclicky_use_screen_context" {
                        let instruction = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !instruction.isEmpty else { return false }
                        OpenClickyMessageLogStore.shared.append(
                            lane: "voice",
                            direction: "internal",
                            event: "voice.realtime_bidirectional.visual_tool_route_recovered",
                            fields: [
                                "transcript": instruction,
                                "toolName": toolName,
                                "executor": "voice_response",
                                "route": "voice.response",
                                "requestID": self.activeRequestTiming?.requestID ?? "none"
                            ]
                        )
                        self.sendTranscriptToClaudeWithScreenshot(transcript: instruction)
                        self.recordRealtimeVoiceRouteFingerprint(Self.realtimeVoiceRouteFingerprint(instruction))
                        return true
                    }
                    guard toolName == "openclicky_start_background_agent" else {
                        return false
                    }
                    let instruction = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !instruction.isEmpty else { return false }
                    OpenClickyMessageLogStore.shared.append(
                        lane: "agent",
                        direction: "incoming",
                        event: "openclicky.agent_task.realtime_tool_route",
                        fields: [
                            "transcript": transcript,
                            "instruction": instruction,
                            "toolName": toolName,
                            "executor": "agent_mode",
                            "route": "agent.realtime_tool",
                            "requestID": self.activeRequestTiming?.requestID ?? "none"
                        ]
                    )
                    self.startVoiceAgentTaskPlan(
                        instruction: instruction,
                        acknowledgement: "i’ll take care of that in the background.",
                        speakAcknowledgement: false,
                        voiceContextUserTranscript: transcript
                    )
                    self.recordRealtimeVoiceRouteFingerprint(Self.realtimeVoiceRouteFingerprint(instruction))
                    return true
                }
                let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: self.selectedModel)
                let result: BidirectionalRealtimeVoiceResult
                if selectedVoiceResponseModel.provider == .deepgram {
                    let deepgramResult = try await self.deepgramVoiceAgentClient.finishBidirectionalVoiceTurn(
                        routeUserTranscriptBeforeAssistantResponse: routeBeforeAssistant
                    )
                    result = BidirectionalRealtimeVoiceResult(
                        userTranscript: deepgramResult.userTranscript,
                        assistantTranscript: deepgramResult.assistantTranscript,
                        didCreateAssistantResponse: deepgramResult.didCreateAssistantResponse,
                        wasRoutedByClient: deepgramResult.wasRoutedByClient
                    )
                } else {
                    let openAIResult = try await self.openAIRealtimeSpeechClient.finishBidirectionalVoiceTurn(
                        routeUserTranscriptBeforeAssistantResponse: routeBeforeAssistant,
                        routeRealtimeToolCallBeforeAssistantResponse: routeRealtimeToolCall
                    )
                    result = BidirectionalRealtimeVoiceResult(
                        userTranscript: openAIResult.userTranscript,
                        assistantTranscript: openAIResult.assistantTranscript,
                        didCreateAssistantResponse: openAIResult.didCreateAssistantResponse,
                        wasRoutedByClient: openAIResult.wasRoutedByClient
                    )
                }
                let assistantText = result.assistantTranscript.isEmpty
                    ? (result.didCreateAssistantResponse ? "Done." : "Routed to OpenClicky.")
                    : result.assistantTranscript
                let userTranscript = result.userTranscript.isEmpty ? "Realtime voice input" : result.userTranscript
                var wasRoutedByApp = result.wasRoutedByClient
                var didApplyRealtimeResult = false

                await MainActor.run {
                    guard self.realtimeBidirectionalVoiceTurnGeneration == turnGeneration,
                          !Task.isCancelled else {
                        let canRecoverStaleProcessingState = self.voiceState == .processing
                            && !self.isRealtimeBidirectionalVoiceCaptureActive
                            && !self.voiceTTSClient.isPlaying
                            && !self.openAIRealtimeSpeechClient.isPlaying
                            && !self.deepgramVoiceAgentClient.isPlaying
                        if canRecoverStaleProcessingState {
                            self.voiceState = .idle
                            self.currentAudioPowerLevel = 0
                            self.clearVoiceResponseCaption()
                        }
                        OpenClickyMessageLogStore.shared.append(
                            lane: "voice",
                            direction: "internal",
                            event: "voice.realtime_bidirectional.stale_finish_ignored",
                            fields: [
                                "source": source,
                                "speechModel": self.selectedModel,
                                "speechVoice": self.activeRealtimeSpeechVoiceID,
                                "inputPath": self.activeRealtimeInputPath,
                                "recoveredProcessingState": canRecoverStaleProcessingState,
                                "captureDurationMs": Self.elapsedMilliseconds(since: captureStartedAt),
                                "responseDurationMs": Self.elapsedMilliseconds(since: finishedAt)
                            ]
                        )
                        return
                    }
                    didApplyRealtimeResult = true
                    self.lastTranscript = userTranscript
                    let routedByApp = wasRoutedByApp || self.routeCompletedRealtimeVoiceTranscriptIfNeeded(userTranscript)
                    wasRoutedByApp = routedByApp
                    if !routedByApp,
                       self.autoEscalateVoiceResponseToAgentIfNeeded(
                        responseText: assistantText,
                        transcript: userTranscript,
                        source: "realtime_bidirectional"
                       ) {
                        self.recordRealtimeVoiceRouteFingerprint(Self.realtimeVoiceRouteFingerprint(userTranscript))
                        self.releaseRealtimeVoiceConversationMode(reason: "routed_by_app")
                        self.lastVoiceInteractionCompletedAt = Date()
                        self.scheduleWidgetSnapshotPublish()
                        return
                    }
                    if !routedByApp {
                        self.rememberVoiceExchange(
                            userTranscript: userTranscript,
                            assistantResponse: assistantText,
                            reason: "realtime_bidirectional"
                        )
                        if Self.responseOffersAgentSpawn(assistantText) {
                            self.pendingAgentOfferInstruction = userTranscript
                            self.pendingAgentOfferAt = Date()
                        } else {
                            self.pendingAgentOfferInstruction = nil
                            self.pendingAgentOfferAt = nil
                        }
                        self.latestVoiceResponseCard = ClickyResponseCard(
                            source: .voice,
                            rawText: assistantText,
                            contextTitle: userTranscript
                        )
                        self.updateVoiceResponseCaption(assistantText)
                        self.voiceState = .idle
                    }
                    if routedByApp {
                        // App-routed realtime turns (for example “get an agent on it”)
                        // intentionally skip assistant playback, so no playback
                        // callback will reset the notch/cursor out of the active
                        // voice phase. Explicitly release the realtime capture
                        // UI back to idle once the route has been handed off.
                        self.releaseRealtimeVoiceConversationMode(reason: "routed_by_app")
                    }
                    self.lastVoiceInteractionCompletedAt = Date()
                    self.scheduleWidgetSnapshotPublish()
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice",
                        direction: "internal",
                        event: "voice.realtime_bidirectional.finished",
                        fields: [
                            "source": source,
                            "speechModel": self.selectedModel,
                            "speechVoice": self.activeRealtimeSpeechVoiceID,
                            "inputPath": self.activeRealtimeInputPath,
                            "bypassesWhisper": true,
                            "routedByApp": routedByApp,
                            "appRouteChecked": true,
                            "createdRealtimeAssistantResponse": result.didCreateAssistantResponse,
                            "userTranscriptLength": result.userTranscript.count,
                            "assistantTranscriptLength": result.assistantTranscript.count,
                            "captureDurationMs": Self.elapsedMilliseconds(since: captureStartedAt),
                            "responseDurationMs": Self.elapsedMilliseconds(since: finishedAt)
                        ]
                    )
                }

                guard didApplyRealtimeResult else { return }

                if result.didCreateAssistantResponse && !result.userTranscript.isEmpty && !wasRoutedByApp {
                    do {
                        try self.codexHomeManager.appendPersistentMemoryEvent(
                            userRequest: userTranscript,
                            agentResponse: assistantText
                        )
                    } catch {
                        print("⚠️ OpenClicky memory update failed: \(error)")
                    }
                    ClickyAnalytics.trackAIResponseReceived(response: assistantText)
                }
            } catch {
                await MainActor.run {
                    self?.handleBidirectionalRealtimeVoiceFailure(
                        error,
                        source: source,
                        stage: "finish",
                        captureStartedAt: captureStartedAt,
                        startedAsInterrupt: self?.realtimeBidirectionalVoiceStartedAsInterrupt ?? false
                    )
                }
            }
        }
        realtimeBidirectionalVoiceCaptureStartedAt = nil
        return true
    }

    private func releaseRealtimeVoiceConversationMode(reason: String) {
        isRealtimeBidirectionalVoiceCaptureActive = false
        isRealtimeBidirectionalVoiceInputReady = false
        pendingRealtimeBidirectionalFinishSource = nil
        realtimeBidirectionalVoiceCaptureStartedAt = nil
        realtimeBidirectionalVoiceStartedAsInterrupt = false
        clearVoiceResponseCaption()
        currentAudioPowerLevel = 0
        wakeWordAudioDucker.restore(reason: "realtime_released_\(reason)")
        voiceState = .idle
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.realtime_bidirectional.released",
            fields: [
                "reason": reason,
                "speechModel": selectedModel,
                "speechVoice": activeRealtimeSpeechVoiceID,
                "inputPath": activeRealtimeInputPath
            ]
        )
    }


    /// Fires from the processing watchdog when voiceState has been stuck
    /// at .processing for longer than processingWatchdogTimeout seconds.
    /// Resets UI state only — does NOT cancel in-flight tasks so a late
    /// response can still arrive and transition to .responding normally.
    private func recoverFromStuckProcessingStateIfNeeded() {
        guard voiceState == .processing,
              !isRealtimeBidirectionalVoiceCaptureActive,
              !voiceTTSClient.isPlaying,
              !openAIRealtimeSpeechClient.isPlaying,
              !deepgramVoiceAgentClient.isPlaying else { return }
        voiceState = .idle
        currentAudioPowerLevel = 0
        clearVoiceResponseCaption()
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.state.processing_watchdog_recovered",
            fields: [
                "timeoutSeconds": Int(Self.processingWatchdogTimeout),
                "speechModel": selectedModel,
                "inputPath": activeRealtimeInputPath
            ]
        )
    }

    static func shouldSilenceQuickRealtimeShortcutFailure(
        _ error: Error,
        source: String,
        stage: String,
        captureStartedAt: Date?,
        startedAsInterrupt: Bool
    ) -> Bool {
        guard source == "keyboardShortcut",
              stage == "finish",
              startedAsInterrupt,
              let captureStartedAt else {
            return false
        }
        let errorMessage = error.localizedDescription.lowercased()
        guard errorMessage.contains("could not detect usable microphone audio") else {
            return false
        }
        return Date().timeIntervalSince(captureStartedAt) <= quickShortcutInterruptSilenceThreshold
    }

    private func routeCompletedRealtimeVoiceTranscriptIfNeeded(_ transcript: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty,
              trimmedTranscript != "Realtime voice input" else {
            return false
        }

        // Suppress a duplicate routing event (final-transcript callback and
        // tool-route callback can both fire for the same utterance ~1s apart).
        let routeFingerprint = Self.realtimeVoiceRouteFingerprint(trimmedTranscript)
        if let last = lastRealtimeVoiceRouteFingerprint,
           let lastAt = lastRealtimeVoiceRouteAt,
           Date().timeIntervalSince(lastAt) <= Self.realtimeVoiceRouteDuplicateTTL,
           Self.isDuplicateRealtimeVoiceRouteFingerprint(routeFingerprint, last) {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.response.duplicate_suppressed",
                fields: [
                    "transcript": trimmedTranscript,
                    "ageMs": Int(Date().timeIntervalSince(lastAt) * 1000),
                    "inputPath": activeRealtimeInputPath
                ]
            )
            return true
        }

        rememberMainConversationUserPrompt(trimmedTranscript, source: "realtime_final_transcript")

        let requestTiming = beginRequestTiming(source: "realtime_voice_final_transcript", text: trimmedTranscript)
        activeRequestTiming = requestTiming
        defer {
            activeRequestTiming = nil
            clearDeferredLiveAgentRoutePartial()
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: "voice.transcript",
            fields: [
                "text": trimmedTranscript,
                "inputPath": activeRealtimeInputPath,
                "voiceInferenceModel": selectedModel,
                "computerUseBackend": selectedComputerUseBackend.rawValue,
                "computerUseModel": selectedComputerUseModel,
                "backgroundAgentModel": codexAgentSession.model,
                "requestID": requestTiming.requestID
            ]
        )

        if submitHomeChatVoiceTranscriptIfNeeded(trimmedTranscript, source: "realtime_home_chat") {
            recordRealtimeVoiceRouteFingerprint(routeFingerprint)
            return true
        }

        if routeFinalVoiceTranscriptActionIfNeeded(
            trimmedTranscript,
            source: "realtime_voice",
            selectionSource: "realtime_voice_final_transcript",
            directComputerUseSource: "realtime_final_transcript",
            includeQuickLocalResponses: true,
            hybridAgentStartCountsAsHandled: true
        ) {
            recordRealtimeVoiceRouteFingerprint(routeFingerprint)
            return true
        }

        if Self.shouldAttachScreenContext(to: trimmedTranscript) {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.realtime_bidirectional.visual_route_recovered",
                fields: [
                    "transcript": trimmedTranscript,
                    "executor": "voice_response",
                    "route": "voice.response",
                    "requestID": requestTiming.requestID
                ]
            )
            sendTranscriptToClaudeWithScreenshot(transcript: trimmedTranscript)
            recordRealtimeVoiceRouteFingerprint(routeFingerprint)
            return true
        }

        return false
    }

    private func recordRealtimeVoiceRouteFingerprint(_ fingerprint: String) {
        lastRealtimeVoiceRouteFingerprint = fingerprint
        lastRealtimeVoiceRouteAt = Date()
    }

    private func handleBidirectionalRealtimeVoiceFailure(
        _ error: Error,
        source: String,
        stage: String,
        captureStartedAt: Date? = nil,
        startedAsInterrupt: Bool = false
    ) {
        openAIRealtimeSpeechClient.cancelBidirectionalVoiceTurn()
        deepgramVoiceAgentClient.cancelBidirectionalVoiceTurn()
        let shouldFailSilently = Self.shouldSilenceQuickRealtimeShortcutFailure(
            error,
            source: source,
            stage: stage,
            captureStartedAt: captureStartedAt,
            startedAsInterrupt: startedAsInterrupt
        )
        releaseRealtimeVoiceConversationMode(reason: shouldFailSilently ? "quick_interrupt_\(stage)" : "failure_\(stage)")
        let errorMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shouldFailSilently else {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.realtime_bidirectional.quick_interrupt_silenced",
                fields: [
                    "source": source,
                    "stage": stage,
                    "speechModel": selectedModel,
                    "speechVoice": activeRealtimeSpeechVoiceID,
                    "inputPath": activeRealtimeInputPath,
                    "startedAsInterrupt": startedAsInterrupt,
                    "captureDurationMs": Self.elapsedMilliseconds(since: captureStartedAt),
                    "error": error.localizedDescription
                ]
            )
            return
        }
        let userFacingMessage = errorMessage.isEmpty
            ? "OpenClicky could not capture microphone audio. Check the microphone input and try again."
            : errorMessage
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: userFacingMessage,
            contextTitle: "Voice input fault"
        )
        updateVoiceResponseCaption(userFacingMessage, force: true)
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.realtime_bidirectional.failed",
            fields: [
                "source": source,
                "stage": stage,
                "speechModel": selectedModel,
                "speechVoice": activeRealtimeSpeechVoiceID,
                "inputPath": activeRealtimeInputPath,
                "error": error.localizedDescription
            ]
        )
    }

    func handleFinalVoiceTranscript(_ finalTranscript: String) {
        lastTranscript = finalTranscript
        let requestTiming = beginRequestTiming(source: "voice_final_transcript", text: finalTranscript)
        activeRequestTiming = requestTiming
        defer {
            activeRequestTiming = nil
            clearDeferredLiveAgentRoutePartial()
        }
        print("Companion received transcript: \(finalTranscript)")
        lastVoiceInteractionCompletedAt = Date()
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

        // The final transcript ends the live-partial window for every
        // route, including local/direct routes that return before the
        // normal voice-response path. Cancel the dwell timer here so it
        // cannot fire a stale speculative model request after a quick
        // local response has already completed.
        speculativeStabilityDwellTask?.cancel()
        speculativeStabilityDwellTask = nil
        lastObservedPartial = nil
        lastObservedPartialAt = nil

        if submitHomeChatVoiceTranscriptIfNeeded(finalTranscript, source: "voice_home_chat") {
            return
        }

        if routeFinalVoiceTranscriptActionIfNeeded(
            finalTranscript,
            source: "voice",
            selectionSource: "voice_final_transcript",
            directComputerUseSource: "final_transcript",
            includeQuickLocalResponses: true
        ) {
            return
        }
        // Remember this prompt in the same shared conversation context used
        // by instant text and Realtime voice, so later "on it" / "do that"
        // agent handoffs can resolve to the actual previous message.
        rememberMainConversationUserPrompt(finalTranscript, source: "voice_final_transcript")

        // Speculative pre-fire commit path. If the partial we fired
        // against matches the final, hand the in-flight Claude task
        // straight to the TTS pipeline — saves the entire model TTFT
        // window. Otherwise fall through to the normal capture+fire.
        if let committed = consumeSpeculativeFireIfMatches(finalTranscript) {
            commitSpeculativeFire(committed, transcript: finalTranscript)
            return
        }

        sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
    }

    private func routeFinalVoiceTranscriptActionIfNeeded(
        _ transcript: String,
        source: String,
        selectionSource: String,
        directComputerUseSource: String,
        includeQuickLocalResponses: Bool,
        hybridAgentStartCountsAsHandled: Bool = false
    ) -> Bool {
        if handleAgentCancellationRequestIfNeeded(from: transcript) {
            return true
        }
        if handleAgentStatusQuestionIfNeeded(from: transcript) {
            return true
        }
        if handleClearOverlayAnnotationsRequestIfNeeded(from: transcript) {
            return true
        }
        if handleVisualGuidanceCalibrationCursorSampleIfNeeded(from: transcript) {
            return true
        }
        // Screen calibration is a voice visual-guidance flow, not Agent Mode.
        // Keep it in the screenshot-aware voice lane even when the user
        // phrases a retry as "get an agent to do a screen calibration."
        if Self.isScreenCalibrationRequest(transcript) {
            return false
        }
        if handleAgentSelectionRequestIfNeeded(from: transcript, source: selectionSource) {
            return true
        }
        if acceptPendingAgentOfferIfConfirmed(from: transcript) {
            return true
        }
        if submitPendingAgentVoiceFollowUp(transcript) {
            return true
        }
        if startHybridAgentTaskIfNeeded(from: transcript) {
            return hybridAgentStartCountsAsHandled
        }
        if startExplicitAgentTaskIfRequested(from: transcript) {
            return true
        }
        if startAgentTaskFromDeferredLiveAgentRouteIfNeeded(transcript) {
            return true
        }
        if handleDirectComputerUseRequest(from: transcript, source: directComputerUseSource) {
            return true
        }
        if includeQuickLocalResponses, handleQuickLocalVoiceResponseIfNeeded(from: transcript) {
            return true
        }
        if submitContextualAgentFollowUp(transcript, source: source) {
            return true
        }
        if startSmartAgentTaskIfNeeded(from: transcript) {
            return true
        }
        if startImplicitAgentTaskIfNeeded(from: transcript) {
            return true
        }
        return false
    }

    // MARK: - Companion Prompt

    private func handleLiveComputerUseTranscript(_ partialTranscript: String) {
        let trimmedTranscript = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        // Independent of CUA: track this partial for the speculative
        // pre-fire path. Fires its own background Task when stable.
        observePartialForSpeculativePreFire(trimmedTranscript)

        let isShortKnownAppRequest = Self.bareLocalAppOpenRequest(from: trimmedTranscript) != nil
        guard trimmedTranscript.count >= 8 || isShortKnownAppRequest else { return }

        let shouldTraceMiss = Self.isPotentialDirectComputerUseTranscript(trimmedTranscript)
        if Self.shouldDeferLiveComputerUseForAgentRoute(trimmedTranscript) {
            recordDeferredLiveAgentRoutePartial(trimmedTranscript)
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

        if Self.compositeAppActionRequest(from: trimmedTranscript) != nil {
            // Composite app commands need the final transcript so the
            // action is complete. Do not let the live-partial open-app
            // shortcut swallow the action as just "Open <app>."
            return
        }

        if let appOpenRequest = Self.localAppOpenRequest(from: trimmedTranscript) {
            let fingerprint = Self.directComputerUseFingerprint(kind: "app", value: appOpenRequest.appName)
            guard !liveHandledComputerUseFingerprints.contains(fingerprint) else { return }
            guard Self.canResolveApplicationWithoutShellOpen(named: appOpenRequest.appName) else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "incoming",
                    event: "native_cua.live_partial.app_candidate_unresolved",
                    fields: [
                        "partialTranscript": trimmedTranscript,
                        "executor": "native_cua",
                        "route": "native_cua.open_app",
                        "executionMethod": "launchApplication(named:)",
                        "appName": appOpenRequest.appName
                    ]
                )
                return
            }
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
                if openRequestedApplication(appOpenRequest, shouldSpeak: false) {
                    liveHandledComputerUseFingerprints.insert(fingerprint)
                }
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

    private func recordDeferredLiveAgentRoutePartial(_ partialTranscript: String) {
        deferredLiveAgentRoutePartial = partialTranscript
        deferredLiveAgentRoutePartialAt = Date()
    }

    private func clearDeferredLiveAgentRoutePartial() {
        deferredLiveAgentRoutePartial = nil
        deferredLiveAgentRoutePartialAt = nil
    }

    private func startAgentTaskFromDeferredLiveAgentRouteIfNeeded(_ finalTranscript: String) -> Bool {
        let trimmedTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty,
              let partialTranscript = deferredLiveAgentRoutePartial,
              let partialAt = deferredLiveAgentRoutePartialAt else {
            return false
        }

        let partialAge = Date().timeIntervalSince(partialAt)
        guard partialAge <= Self.deferredLiveAgentRoutePartialTTL,
              let instruction = Self.deferredLiveAgentRouteInstruction(
                partialTranscript: partialTranscript,
                finalTranscript: trimmedTranscript
              ) else {
            return false
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "incoming",
            event: "native_cua.final_transcript.deferred_agent_route_recovered",
            fields: [
                "partialTranscript": partialTranscript,
                "finalTranscript": trimmedTranscript,
                "partialAgeMs": Int(partialAge * 1000),
                "executor": "agent_mode",
                "route": "agent.start",
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )
        startVoiceAgentTaskPlan(instruction: instruction)
        return true
    }

    private func startImplicitAgentTaskIfNeeded(from finalTranscript: String) -> Bool {
        guard let instruction = Self.implicitAgentTaskInstruction(from: finalTranscript) else {
            return false
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.implicit_route",
            fields: [
                "transcript": finalTranscript,
                "instruction": instruction,
                "executor": "agent_mode",
                "route": "agent.start",
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )
        startVoiceAgentTaskPlan(
            instruction: instruction,
            acknowledgement: "i’ll take care of that in the background.",
            voiceContextUserTranscript: finalTranscript
        )
        return true
    }

    private func startSmartAgentTaskIfNeeded(from finalTranscript: String) -> Bool {
        guard let decision = Self.smartAgentRouteDecision(from: finalTranscript) else {
            return false
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.smart_route",
            fields: [
                "transcript": finalTranscript,
                "instruction": decision.instruction,
                "reason": decision.reason,
                "confidence": decision.confidence,
                "executor": "agent_mode",
                "route": "agent.start",
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )
        startVoiceAgentTaskPlan(
            instruction: decision.instruction,
            acknowledgement: decision.acknowledgement,
            voiceContextUserTranscript: finalTranscript
        )
        return true
    }

    private func startHybridAgentTaskIfNeeded(from transcript: String) -> Bool {
        guard let instruction = Self.hybridAgentTaskInstruction(from: transcript) else {
            return false
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.hybrid_route",
            fields: [
                "transcript": transcript,
                "instruction": instruction,
                "executor": "agent_mode",
                "route": "agent.hybrid_start",
                "foregroundRoute": "voice.response",
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )
        startVoiceAgentTaskPlan(
            instruction: instruction,
            acknowledgement: "i’ll handle the background part too.",
            route: "agent.hybrid_start",
            interruptVoiceResponse: false,
            voiceContextUserTranscript: transcript
        )
        return true
    }

    func autoEscalateVoiceResponseToAgentIfNeeded(
        responseText: String,
        transcript: String,
        source: String,
        route: String = "agent.auto_escalate"
    ) -> Bool {
        guard Self.shouldEscalateVoiceResponseToAgent(
            responseText: responseText,
            transcript: transcript
        ) else {
            return false
        }

        let acknowledgement: String
        let instruction: String
        let reason: String
        if let decision = Self.smartAgentRouteDecision(from: transcript) {
            acknowledgement = decision.acknowledgement
            instruction = decision.instruction
            reason = "smart_\(decision.reason)"
        } else if let filesystemInstruction = Self.implicitFilesystemTaskInstruction(from: transcript) {
            acknowledgement = Self.filesystemTaskAcknowledgement(from: transcript)
            instruction = filesystemInstruction
            reason = "filesystem_refusal_recovery"
        } else if let implicitInstruction = Self.implicitAgentTaskInstruction(from: transcript) {
            acknowledgement = "i’ll take care of that in the background."
            instruction = implicitInstruction
            reason = "implicit_refusal_recovery"
        } else {
            return false
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.voice_auto_escalated",
            fields: [
                "source": source,
                "transcript": transcript,
                "responseText": responseText,
                "instruction": instruction,
                "reason": reason,
                "executor": "agent_mode",
                "route": route,
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )

        pendingAgentOfferInstruction = nil
        pendingAgentOfferAt = nil
        startVoiceAgentTaskPlan(
            instruction: instruction,
            acknowledgement: acknowledgement,
            route: route,
            speakAcknowledgement: false,
            interruptVoiceResponse: true,
            voiceContextUserTranscript: transcript
        )
        return true
    }

    private func handleDirectComputerUseRequest(from transcript: String, source: String) -> Bool {
        guard Self.logEvidenceAnalysisInstruction(from: transcript) == nil else {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "internal",
                event: "native_cua.direct_request.skipped_log_evidence",
                fields: [
                    "source": source,
                    "transcriptLength": transcript.count,
                    "executor": "agent_mode",
                    "route": "agent.start",
                    "reason": "pasted_log_evidence"
                ]
            )
            return false
        }

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

        if let webOpenRequest = Self.webOpenRequest(from: transcript) {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.web_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.open_url",
                    "executionMethod": "NSWorkspace.open",
                    "url": webOpenRequest.url.absoluteString,
                    "browserAppName": webOpenRequest.browserAppName ?? "",
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            openRequestedWebsite(webOpenRequest)
            return true
        }

        if let compositeRequest = Self.compositeAppActionRequest(from: transcript) {
            let backend = selectedComputerUseBackend
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "\(backend.executorID).direct_request.composite_app_action_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": backend.executorID,
                    "route": "\(backend.executorID).composite_app_action",
                    "executionMethod": "live_voice_computer_use_router",
                    "appName": compositeRequest.appName,
                    "actionText": compositeRequest.actionText,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            if handleSupportedCompositeAppActionRequest(compositeRequest, backend: backend) {
                return true
            }

            let executionStartedAt = markRequestExecutionStarted(
                route: "\(backend.executorID).composite_app_action.unsupported",
                extra: [
                    "executor": backend.executorID,
                    "executionMethod": "live_voice_computer_use_router",
                    "appName": compositeRequest.appName,
                    "actionText": compositeRequest.actionText
                ]
            )
            pendingAgentOfferInstruction = Self.compositeAppActionAgentInstruction(from: compositeRequest)
            pendingAgentOfferAt = Date()
            let response = "that app action needs Agent Mode. Say: start an agent to \(compositeRequest.instruction)."
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: response,
                contextTitle: compositeRequest.instruction
            )
            speakShortSystemResponse(response)
            markRequestCompleted(
                route: "\(backend.executorID).composite_app_action.unsupported",
                executionStartedAt: executionStartedAt,
                status: "failed",
                extra: [
                    "executor": backend.executorID,
                    "executionMethod": "live_voice_computer_use_router",
                    "appName": compositeRequest.appName,
                    "actionText": compositeRequest.actionText,
                    "error": "No supported live composite app-action executor matched"
                ]
            )
            return true
        }

        if let spotifyPlaybackRequest = Self.standaloneSpotifyPlaybackRequest(from: transcript) {
            let backend = selectedComputerUseBackend
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "\(backend.executorID).direct_request.spotify_playback_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": backend.executorID,
                    "route": "\(backend.executorID).spotify_search_play",
                    "executionMethod": "live_voice_computer_use_router",
                    "appName": spotifyPlaybackRequest.appName,
                    "actionText": spotifyPlaybackRequest.actionText,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            if handleSpotifyCompositeAppActionRequest(spotifyPlaybackRequest, backend: backend) {
                return true
            }
        }

        if let systemVolumeAction = Self.systemVolumeControlAction(from: transcript) {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.system_volume_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.system_volume",
                    "executionMethod": "CoreAudio default output volume",
                    "action": systemVolumeAction.rawValue,
                    "requiresAccessibility": false,
                    "requiresSystemEventsAutomation": false,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            runSystemVolumeControl(systemVolumeAction, instruction: transcript)
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

        if let clickRequest = Self.nativeClickRequest(from: transcript) {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "incoming",
                event: "native_cua.direct_request.click_detected",
                fields: [
                    "source": source,
                    "transcript": transcript,
                    "executor": "native_cua",
                    "route": "native_cua.click",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "targetPhrase": clickRequest.targetPhrase ?? "",
                    "prefersLastPointedElement": clickRequest.prefersLastPointedElement,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            clickUsingSelectedComputerUse(clickRequest)
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

    private func openRequestedWebsite(_ request: OpenClickyWebOpenRequest, shouldSpeak: Bool = true) {
        let executionMethod = request.browserAppName == nil
            ? "NSWorkspace.open"
            : "NSWorkspace.open_withApplication"
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.open_url",
            extra: [
                "executor": "native_cua",
                "executionMethod": executionMethod,
                "controller": "NSWorkspace",
                "url": request.url.absoluteString,
                "browserAppName": request.browserAppName ?? "",
                "shouldSpeak": shouldSpeak
            ]
        )
        var openedInRequestedBrowser = false
        if let browserAppName = request.browserAppName,
           let browserURL = Self.resolvedApplicationURL(named: browserAppName) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [request.url],
                withApplicationAt: browserURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "native_cua.open_url.browser_activation_failed",
                        fields: [
                            "browserAppName": browserAppName,
                            "path": browserURL.path,
                            "url": request.url.absoluteString,
                            "error": error.localizedDescription
                        ]
                    )
                }
            }
            openedInRequestedBrowser = true
        }
        if !openedInRequestedBrowser {
            NSWorkspace.shared.open(request.url)
        }
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "opening \(request.displayName).",
            contextTitle: request.instruction
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "native_cua.open_url",
            fields: [
                "executor": "native_cua",
                "executionMethod": openedInRequestedBrowser ? "NSWorkspace.open_withApplication" : "NSWorkspace.open",
                "controller": "NSWorkspace",
                "url": request.url.absoluteString,
                "browserAppName": request.browserAppName ?? "",
                "instruction": request.instruction
            ]
        )
        if shouldSpeak {
            speakShortSystemResponse("opening \(request.displayName).")
        }
        markRequestCompleted(
            route: "native_cua.open_url",
            executionStartedAt: executionStartedAt,
            extra: [
                "executor": "native_cua",
                "executionMethod": openedInRequestedBrowser ? "NSWorkspace.open_withApplication" : "NSWorkspace.open",
                "controller": "NSWorkspace",
                "url": request.url.absoluteString,
                "browserAppName": request.browserAppName ?? ""
            ]
        )
    }

    private func handleSupportedCompositeAppActionRequest(
        _ request: OpenClickyCompositeAppActionRequest,
        backend: OpenClickyComputerUseBackendID
    ) -> Bool {
        if request.appName == "Spotify",
           handleSpotifyCompositeAppActionRequest(request, backend: backend) {
            return true
        }

        if let searchQuery = Self.compositeAppSearchQuery(from: request.actionText) {
            searchInApplicationUsingSelectedComputerUse(
                OpenClickyCompositeAppSearchActionRequest(
                    appName: request.appName,
                    query: searchQuery,
                    instruction: request.instruction
                ),
                backend: backend
            )
            return true
        }

        if let keyPressRequest = Self.nativeKeyPressRequest(from: request.actionText) {
            pressKeyInApplicationUsingSelectedComputerUse(
                keyPressRequest,
                appName: request.appName,
                instruction: request.instruction,
                backend: backend
            )
            return true
        }

        return false
    }

    private func handleSpotifyCompositeAppActionRequest(
        _ request: OpenClickyCompositeAppActionRequest,
        backend: OpenClickyComputerUseBackendID
    ) -> Bool {
        if let controlAction = Self.spotifyPlaybackControlAction(from: request.actionText) {
            runSpotifyPlaybackControl(controlAction, request: request, backend: backend)
            return true
        }

        if let query = Self.spotifyPlaybackQuery(from: request.actionText) {
            openSpotifySearchAndPlayTopResult(query: query, request: request, backend: backend)
            return true
        }

        return false
    }

    private func openSpotifySearchAndPlayTopResult(
        query: String,
        request: OpenClickyCompositeAppActionRequest,
        backend: OpenClickyComputerUseBackendID
    ) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let route = "\(backend.executorID).spotify_search_play"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": backend.executorID,
                "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                "controller": backend == .backgroundComputerUse
                    ? "OpenClickyBackgroundComputerUseController"
                    : "OpenClickyNativeComputerUseController",
                "appName": request.appName,
                "actionText": request.actionText,
                "query": query
            ]
        )

        guard let spotifyURL = Self.spotifySearchURL(for: query),
              NSWorkspace.shared.open(spotifyURL) else {
            speakShortSystemResponse("i couldn't open Spotify search for \(query).")
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": backend.executorID,
                    "executionMethod": "NSWorkspace.open_spotify_uri",
                    "appName": request.appName,
                    "query": query,
                    "error": "Spotify search URL could not be opened"
                ]
            )
            return
        }

        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "searching Spotify for \(query).",
            contextTitle: request.instruction
        )
        speakShortSystemResponse("searching Spotify for \(query).")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                try await pressKeyInApplication(
                    "enter",
                    modifiers: [],
                    appName: "Spotify",
                    backend: backend
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let verification = await Task.detached(priority: .userInitiated) {
                    OpenClickyLocalAutomationRunner.runAppleScript("""
                    tell application "Spotify"
                        return player state as string
                    end tell
                    """)
                }.value
                let playerState = verification.output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let verificationError = verification.errorOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard verification.terminationStatus == 0, playerState == "playing" else {
                    if verification.terminationStatus == 0, playerState != "playing" {
                        let retry = await Task.detached(priority: .userInitiated) {
                            OpenClickyLocalAutomationRunner.runAppleScript("""
                            tell application "Spotify"
                                activate
                                play
                                delay 0.2
                                return player state as string
                            end tell
                            """)
                        }.value
                        let retryPlayerState = retry.output
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        if retry.terminationStatus == 0, retryPlayerState == "playing" {
                            latestVoiceResponseCard = ClickyResponseCard(
                                source: .voice,
                                rawText: "playing \(query) on Spotify.",
                                contextTitle: request.instruction
                            )
                            speakShortSystemResponse("playing \(query) on Spotify.")
                            OpenClickyMessageLogStore.shared.append(
                                lane: "computer-use",
                                direction: "outgoing",
                                event: "\(backend.executorID).spotify_search_play_voice_retry",
                                fields: [
                                    "executor": backend.executorID,
                                    "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                                    "appName": request.appName,
                                    "query": query,
                                    "initialPlayerState": playerState,
                                    "playerState": retryPlayerState,
                                    "instruction": request.instruction
                                ]
                            )
                            markRequestCompleted(
                                route: route,
                                executionStartedAt: executionStartedAt,
                                timing: timing,
                                extra: [
                                    "executor": backend.executorID,
                                    "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                                    "appName": request.appName,
                                    "query": query,
                                    "initialPlayerState": playerState,
                                    "playerState": retryPlayerState,
                                    "voicePathRetry": true
                                ]
                            )
                            return
                        }
                    }
                    let errorText = verification.terminationStatus == 0
                        ? "Spotify stayed \(playerState.isEmpty ? "unknown" : playerState) after search selection."
                        : (verificationError.isEmpty ? "Spotify playback verification failed." : verificationError)
                    speakShortSystemResponse("i opened Spotify search, but it didn't start playing.")
                    OpenClickyMessageLogStore.shared.append(
                        lane: "computer-use",
                        direction: "error",
                        event: "\(backend.executorID).spotify_search_play_not_playing",
                        fields: [
                            "executor": backend.executorID,
                            "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                            "appName": request.appName,
                            "query": query,
                            "playerState": playerState,
                            "error": errorText
                        ]
                    )
                    markRequestCompleted(
                        route: route,
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: [
                            "executor": backend.executorID,
                            "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                            "appName": request.appName,
                            "query": query,
                            "playerState": playerState,
                            "error": errorText
                        ]
                    )
                    return
                }
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "\(backend.executorID).spotify_search_play",
                    fields: [
                        "executor": backend.executorID,
                        "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                        "appName": request.appName,
                        "query": query,
                        "playerState": playerState,
                        "instruction": request.instruction
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                        "appName": request.appName,
                        "query": query,
                        "playerState": playerState
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "\(backend.executorID).spotify_search_play_error",
                    fields: [
                        "executor": backend.executorID,
                        "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                        "appName": request.appName,
                        "query": query,
                        "error": error.localizedDescription
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": Self.spotifySearchPlayExecutionMethod(for: backend),
                        "appName": request.appName,
                        "query": query,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func runSystemVolumeControl(_ action: OpenClickySystemVolumeControlAction, instruction: String) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let route = "native_cua.system_volume"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": "native_cua",
                "executionMethod": "CoreAudio default output volume",
                "controller": "OpenClickySystemOutputVolume",
                "action": action.rawValue,
                "requiresAccessibility": false,
                "requiresSystemEventsAutomation": false
            ]
        )

        let currentVolume = OpenClickySystemOutputVolume.currentScalar()
        let targetVolume: Float
        let acknowledgement: String
        switch action.kind {
        case .volumeUp:
            targetVolume = min((currentVolume ?? 0.5) + 0.1, 1.0)
            acknowledgement = "turned system volume up."
        case .volumeDown:
            targetVolume = max((currentVolume ?? 0.5) - 0.1, 0.0)
            acknowledgement = "turned system volume down."
        case .mute:
            targetVolume = 0
            acknowledgement = "muted system volume."
        case .setVolume:
            let percent = min(100, max(0, action.volumePercent ?? 50))
            targetVolume = Float(percent) / 100
            acknowledgement = "set system volume to \(percent) percent."
        }

        let didApply = OpenClickySystemOutputVolume.setScalar(targetVolume)
        if didApply {
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: acknowledgement,
                contextTitle: instruction
            )
            speakShortSystemResponse(acknowledgement)
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "native_cua.system_volume",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "CoreAudio default output volume",
                    "controller": "OpenClickySystemOutputVolume",
                    "action": action.rawValue,
                    "previousVolume": currentVolume.map { Double($0) } ?? -1,
                    "targetVolume": Double(targetVolume),
                    "requiresAccessibility": false,
                    "requiresSystemEventsAutomation": false
                ]
            )
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "CoreAudio default output volume",
                    "action": action.rawValue,
                    "targetVolume": Double(targetVolume)
                ]
            )
        } else {
            let errorText = "default output volume is unavailable or not settable for the current audio device"
            speakShortSystemResponse("System volume hit a blocker: \(errorText).")
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "native_cua.system_volume_error",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "CoreAudio default output volume",
                    "controller": "OpenClickySystemOutputVolume",
                    "action": action.rawValue,
                    "error": errorText,
                    "requiresAccessibility": false,
                    "requiresSystemEventsAutomation": false
                ]
            )
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "CoreAudio default output volume",
                    "action": action.rawValue,
                    "error": errorText
                ]
            )
        }
    }

    private func runSpotifyPlaybackControl(
        _ action: OpenClickySpotifyPlaybackControlAction,
        request: OpenClickyCompositeAppActionRequest,
        backend: OpenClickyComputerUseBackendID
    ) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let route = "\(backend.executorID).spotify_playback_control"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": backend.executorID,
                "selectedComputerUseBackend": backend.rawValue,
                "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                "controller": "/usr/bin/osascript",
                "appName": request.appName,
                "action": action.rawValue
            ]
        )

        let appleScriptCommand: String
        let acknowledgement: String
        switch action.kind {
        case .play:
            appleScriptCommand = "play"
            acknowledgement = "playing Spotify."
        case .pause:
            appleScriptCommand = "pause"
            acknowledgement = "paused Spotify."
        case .playPause:
            appleScriptCommand = "playpause"
            acknowledgement = "toggled Spotify playback."
        case .next:
            appleScriptCommand = "next track"
            acknowledgement = "skipped Spotify."
        case .previous:
            appleScriptCommand = "previous track"
            acknowledgement = "went back in Spotify."
        case .shuffleOn:
            appleScriptCommand = "set shuffling to true"
            acknowledgement = "turned shuffle on in Spotify."
        case .shuffleOff:
            appleScriptCommand = "set shuffling to false"
            acknowledgement = "turned shuffle off in Spotify."
        case .repeatOn:
            appleScriptCommand = "set repeating to true"
            acknowledgement = "turned repeat on in Spotify."
        case .repeatOff:
            appleScriptCommand = "set repeating to false"
            acknowledgement = "turned repeat off in Spotify."
        case .volumeUp:
            appleScriptCommand = """
            set currentVolume to sound volume
            if currentVolume > 90 then
                set sound volume to 100
            else
                set sound volume to currentVolume + 10
            end if
            """
            acknowledgement = "turned Spotify volume up."
        case .volumeDown:
            appleScriptCommand = """
            set currentVolume to sound volume
            if currentVolume < 10 then
                set sound volume to 0
            else
                set sound volume to currentVolume - 10
            end if
            """
            acknowledgement = "turned Spotify volume down."
        case .volumeMute:
            appleScriptCommand = "set sound volume to 0"
            acknowledgement = "muted Spotify."
        case .volumeSet:
            let volumePercent = min(100, max(0, action.volumePercent ?? 50))
            appleScriptCommand = "set sound volume to \(volumePercent)"
            acknowledgement = "set Spotify volume to \(volumePercent) percent."
        }

        let script = """
        tell application "Spotify"
            activate
            \(appleScriptCommand)
        end tell
        """

        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                OpenClickyLocalAutomationRunner.runAppleScript(script)
            }.value
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorOutput = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.terminationStatus == 0 {
                latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: acknowledgement,
                    contextTitle: request.instruction
                )
                speakShortSystemResponse(acknowledgement)
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "\(backend.executorID).spotify_playback_control",
                    fields: [
                        "executor": backend.executorID,
                        "selectedComputerUseBackend": backend.rawValue,
                        "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                        "controller": "/usr/bin/osascript",
                        "appName": request.appName,
                        "action": action.rawValue,
                        "output": output
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": backend.executorID,
                        "selectedComputerUseBackend": backend.rawValue,
                        "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                        "controller": "/usr/bin/osascript",
                        "appName": request.appName,
                        "action": action.rawValue
                    ]
                )
            } else {
                let errorText = errorOutput.isEmpty ? "Spotify automation failed." : errorOutput
                speakShortSystemResponse("Spotify hit a blocker: \(errorText)")
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "\(backend.executorID).spotify_playback_control_error",
                    fields: [
                        "executor": backend.executorID,
                        "selectedComputerUseBackend": backend.rawValue,
                        "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                        "controller": "/usr/bin/osascript",
                        "appName": request.appName,
                        "action": action.rawValue,
                        "error": errorText
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": backend.executorID,
                        "selectedComputerUseBackend": backend.rawValue,
                        "executionMethod": "OpenClickyLocalAutomationRunner.runAppleScript",
                        "controller": "/usr/bin/osascript",
                        "appName": request.appName,
                        "action": action.rawValue,
                        "error": errorText
                    ]
                )
            }
        }
    }

    private func searchInApplicationUsingSelectedComputerUse(
        _ request: OpenClickyCompositeAppSearchActionRequest,
        backend: OpenClickyComputerUseBackendID
    ) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let route = "\(backend.executorID).composite_app_search"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": backend.executorID,
                "executionMethod": backend == .backgroundComputerUse
                    ? "BackgroundComputerUse /v1/press_key + /v1/type_text"
                    : "OpenClickyNativeComputerUseController.pressKey/typeText",
                "controller": backend == .backgroundComputerUse
                    ? "OpenClickyBackgroundComputerUseController"
                    : "OpenClickyNativeComputerUseController",
                "appName": request.appName,
                "query": request.query
            ]
        )

        let appRequest = OpenClickyAppOpenRequest(
            appName: request.appName,
            instruction: "Open \(request.appName)."
        )
        guard openRequestedApplication(appRequest, shouldSpeak: false, logTiming: false) else {
            speakShortSystemResponse("i couldn't open \(request.appName) for that search.")
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": backend.executorID,
                    "executionMethod": "launchApplication(named:)",
                    "appName": request.appName,
                    "query": request.query,
                    "error": "Application could not be opened"
                ]
            )
            return
        }

        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: "searching \(request.appName) for \(request.query).",
            contextTitle: request.instruction
        )
        speakShortSystemResponse("searching \(request.appName) for \(request.query).")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            do {
                try await pressKeyInApplication("f", modifiers: ["command"], appName: request.appName, backend: backend)
                try? await Task.sleep(nanoseconds: 150_000_000)
                try await pressKeyInApplication("a", modifiers: ["command"], appName: request.appName, backend: backend)
                try await typeTextInApplication(request.query, appName: request.appName, backend: backend)
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "\(backend.executorID).composite_app_search",
                    fields: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key + /v1/type_text"
                            : "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "appName": request.appName,
                        "query": request.query,
                        "instruction": request.instruction
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key + /v1/type_text"
                            : "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "appName": request.appName,
                        "query": request.query
                    ]
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "\(backend.executorID).composite_app_search_error",
                    fields: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key + /v1/type_text"
                            : "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "appName": request.appName,
                        "query": request.query,
                        "error": error.localizedDescription
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key + /v1/type_text"
                            : "OpenClickyNativeComputerUseController.pressKey/typeText",
                        "appName": request.appName,
                        "query": request.query,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func pressKeyInApplicationUsingSelectedComputerUse(
        _ request: OpenClickyNativeKeyPressRequest,
        appName: String,
        instruction: String,
        backend: OpenClickyComputerUseBackendID
    ) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let route = "\(backend.executorID).composite_app_key"
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": backend.executorID,
                "executionMethod": backend == .backgroundComputerUse
                    ? "BackgroundComputerUse /v1/press_key"
                    : "OpenClickyNativeComputerUseController.pressKey",
                "controller": backend == .backgroundComputerUse
                    ? "OpenClickyBackgroundComputerUseController"
                    : "OpenClickyNativeComputerUseController",
                "appName": appName,
                "key": request.key,
                "modifiers": request.modifiers.joined(separator: ",")
            ]
        )

        let appRequest = OpenClickyAppOpenRequest(
            appName: appName,
            instruction: "Open \(appName)."
        )
        guard openRequestedApplication(appRequest, shouldSpeak: false, logTiming: false) else {
            speakShortSystemResponse("i couldn't open \(appName) for that key press.")
            markRequestCompleted(
                route: route,
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": backend.executorID,
                    "executionMethod": "launchApplication(named:)",
                    "appName": appName,
                    "key": request.key,
                    "error": "Application could not be opened"
                ]
            )
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            do {
                try await pressKeyInApplication(
                    request.key,
                    modifiers: request.modifiers,
                    appName: appName,
                    backend: backend
                )
                let modifierText = request.modifiers.isEmpty ? "" : request.modifiers.joined(separator: " ") + " "
                let acknowledgement = "pressed \(modifierText)\(request.key) in \(appName)."
                latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: acknowledgement,
                    contextTitle: instruction
                )
                speakShortSystemResponse(acknowledgement)
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "outgoing",
                    event: "\(backend.executorID).composite_app_key",
                    fields: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key"
                            : "OpenClickyNativeComputerUseController.pressKey",
                        "appName": appName,
                        "key": request.key,
                        "modifiers": request.modifiers.joined(separator: ",")
                    ]
                )
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key"
                            : "OpenClickyNativeComputerUseController.pressKey",
                        "appName": appName,
                        "key": request.key,
                        "modifiers": request.modifiers.joined(separator: ",")
                    ]
                )
            } catch {
                speakShortSystemResponse("\(appName) key press hit a blocker: \(error.localizedDescription)")
                markRequestCompleted(
                    route: route,
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": backend.executorID,
                        "executionMethod": backend == .backgroundComputerUse
                            ? "BackgroundComputerUse /v1/press_key"
                            : "OpenClickyNativeComputerUseController.pressKey",
                        "appName": appName,
                        "key": request.key,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func pressKeyInApplication(
        _ key: String,
        modifiers: [String],
        appName: String,
        backend: OpenClickyComputerUseBackendID
    ) async throws {
        switch backend {
        case .backgroundComputerUse:
            _ = try await backgroundComputerUseController.pressKey(
                key,
                modifiers: modifiers,
                targetAppName: appName
            )
        case .nativeSwift:
            guard ensureNativeComputerUseEnabledOrRefuse(spokenAction: "press that key") else {
                throw NSError(
                    domain: "OpenClickyComputerUse",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Native computer use is disabled."]
                )
            }
            Self.activateRunningApplication(named: appName)
            guard let targetWindow = await waitForNativeComputerUseWindow(for: appName) else {
                throw NSError(
                    domain: "OpenClickyCompositeAppAction",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No \(appName) window available"]
                )
            }
            try nativeComputerUseController.pressKey(key, modifiers: modifiers, toPid: targetWindow.pid)
        }
    }

    private func typeTextInApplication(
        _ text: String,
        appName: String,
        backend: OpenClickyComputerUseBackendID
    ) async throws {
        switch backend {
        case .backgroundComputerUse:
            _ = try await backgroundComputerUseController.typeText(text, targetAppName: appName)
        case .nativeSwift:
            guard ensureNativeComputerUseEnabledOrRefuse(spokenAction: "type that") else {
                throw NSError(
                    domain: "OpenClickyComputerUse",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Native computer use is disabled."]
                )
            }
            Self.activateRunningApplication(named: appName)
            guard let targetWindow = await waitForNativeComputerUseWindow(for: appName) else {
                throw NSError(
                    domain: "OpenClickyCompositeAppAction",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No \(appName) window available"]
                )
            }
            try nativeComputerUseController.typeText(text, delayMilliseconds: 8, toPid: targetWindow.pid)
        }
    }

    private func nativeComputerUseWindow(for appName: String) -> OpenClickyComputerUseWindowInfo? {
        let windows = nativeComputerUseController.visibleWindows()
        if let matchingWindow = windows.first(where: { Self.applicationOwner($0.owner, matches: appName) }) {
            return matchingWindow
        }
        if let focusedWindow = nativeComputerUseController.refreshFocusedTarget(),
           Self.applicationOwner(focusedWindow.owner, matches: appName) {
            return focusedWindow
        }
        return nil
    }

    private func waitForNativeComputerUseWindow(
        for appName: String,
        timeout: TimeInterval = 3.0,
        pollIntervalNanoseconds: UInt64 = 150_000_000
    ) async -> OpenClickyComputerUseWindowInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let targetWindow = nativeComputerUseWindow(for: appName) {
                return targetWindow
            }
            guard Date() < deadline else { break }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        } while !Task.isCancelled
        return nativeComputerUseWindow(for: appName)
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
        showActiveControlGlowForFocusedWindowOrScreen(label: "Typing", duration: 3.0)
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            typeTextUsingBackgroundComputerUse(request)
        case .nativeSwift:
            typeTextUsingNativeComputerUse(request)
        }
    }

    private func pressKeyUsingSelectedComputerUse(_ request: OpenClickyNativeKeyPressRequest, shouldSpeak: Bool = true) {
        showActiveControlGlowForFocusedWindowOrScreen(label: "Key press", duration: 1.8)
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            pressKeyUsingBackgroundComputerUse(request, shouldSpeak: shouldSpeak)
        case .nativeSwift:
            pressKeyUsingNativeComputerUse(request, shouldSpeak: shouldSpeak)
        }
    }

    private func clickUsingSelectedComputerUse(_ request: OpenClickyNativeClickRequest) {
        showActiveControlGlowForFocusedWindowOrScreen(label: request.targetPhrase ?? "Click target", duration: 2.2)
        switch selectedComputerUseBackend {
        case .backgroundComputerUse:
            clickUsingBackgroundComputerUse(request)
        case .nativeSwift:
            clickUsingNativeComputerUse(request)
        }
    }

    /// M10: native computer use "disabled" is the user's authoritative choice.
    /// Previously every action path force-enabled it (`setEnabled(true)`),
    /// silently overriding the preference and persisting the override. Now
    /// action paths call this and bail with a spoken prompt when disabled.
    /// Returns true when enabled (action may proceed).
    @discardableResult
    private func ensureNativeComputerUseEnabledOrRefuse(spokenAction: String) -> Bool {
        if nativeComputerUseController.isEnabled { return true }
        speakShortSystemResponse("computer use is turned off. turn it on in settings if you want me to \(spokenAction).")
        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "error",
            event: "native_cua.refused_disabled",
            fields: [
                "executor": "native_cua",
                "reason": "Native computer use is disabled; action refused instead of force-enabling."
            ]
        )
        return false
    }

    private func clickUsingBackgroundComputerUse(_ request: OpenClickyNativeClickRequest) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "background_computer_use.click",
            timing: timing,
            extra: [
                "executor": "background_computer_use",
                "executionMethod": "OpenClickyBackgroundComputerUseController.click",
                "controller": "OpenClickyBackgroundComputerUseController",
                "targetPhrase": request.targetPhrase ?? ""
            ]
        )

        Task { @MainActor in
            do {
                // Background Computer Use clicks in WINDOW-SCREENSHOT pixel
                // space, not global display points. Capture the BCU window,
                // point against THAT screenshot, then send the raw screenshot
                // coordinate straight to /v1/click.
                let capture = try await backgroundComputerUseController.captureFrontmostWindowAsJPEG()
                let pointingCapture = CompanionScreenCapture(
                    imageData: capture.imageData,
                    label: capture.displayTitle,
                    appName: request.targetPhrase,
                    bundleIdentifier: capture.bundleID,
                    isCursorScreen: false,
                    displayWidthInPoints: capture.screenshotWidthInPixels,
                    displayHeightInPoints: capture.screenshotHeightInPixels,
                    displayNativeWidthInPixels: capture.screenshotWidthInPixels,
                    displayNativeHeightInPixels: capture.screenshotHeightInPixels,
                    displayFrame: .zero,
                    screenshotWidthInPixels: capture.screenshotWidthInPixels,
                    screenshotHeightInPixels: capture.screenshotHeightInPixels
                )
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                let response = try await analyzeComputerUsePointingResponse(
                    image: (data: capture.imageData, label: pointingCapture.label + dimensionInfo),
                    capture: pointingCapture,
                    systemPrompt: Self.nativeClickPointingSystemPrompt,
                    userPrompt: request.targetDescription,
                    onTextChunk: { _ in }
                )
                let parseResult = Self.parsePointingCoordinates(from: response)
                guard let pointCoordinate = parseResult.coordinate else {
                    speakShortSystemResponse("i couldn't find that to click.")
                    markRequestCompleted(
                        route: "background_computer_use.click",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: [
                            "executor": "background_computer_use",
                            "executionMethod": "analyzeComputerUsePointingResponse",
                            "targetPhrase": request.targetPhrase ?? "",
                            "error": "No click coordinate"
                        ]
                    )
                    return
                }

                let result = try await backgroundComputerUseController.click(
                    at: pointCoordinate,
                    window: capture.windowID,
                    targetAppName: request.targetPhrase,
                    stateToken: capture.stateToken
                )
                let spokenLabel = parseResult.elementLabel ?? request.targetPhrase
                speakShortSystemResponse(spokenLabel.map { "clicked \($0)." } ?? "clicked that.")
                markRequestCompleted(
                    route: "background_computer_use.click",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "OpenClickyBackgroundComputerUseController.click",
                        "controller": "OpenClickyBackgroundComputerUseController",
                        "window": capture.windowID,
                        "x": Int(pointCoordinate.x),
                        "y": Int(pointCoordinate.y),
                        "summary": result.summary
                    ]
                )
            } catch {
                speakShortSystemResponse("i couldn't click that through background computer use.")
                markRequestCompleted(
                    route: "background_computer_use.click",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": "background_computer_use",
                        "executionMethod": "OpenClickyBackgroundComputerUseController.click",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func clickUsingNativeComputerUse(_ request: OpenClickyNativeClickRequest) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let pointingResolver = Self.computerUsePointingResolver(
            selectedVoiceModelID: selectedModel,
            selectedComputerUseModelID: selectedComputerUseModel
        )
        let executionStartedAt = markRequestExecutionStarted(
            route: "native_cua.click",
            timing: timing,
            extra: [
                "executor": "native_cua",
                "executionMethod": "OpenClickyNativeComputerUseController.click",
                "controller": "OpenClickyNativeComputerUseController",
                "targetPhrase": request.targetPhrase ?? "",
                "prefersLastPointedElement": request.prefersLastPointedElement,
                "pointingResolver": pointingResolver.rawValue,
                "pointingModel": pointingResolver == .openAIRealtime ? selectedModel : selectedComputerUseModel
            ]
        )

        if !ensureNativeComputerUseEnabledOrRefuse(spokenAction: "click that") {
            return
        }

        if request.prefersLastPointedElement,
           let point = lastPointedElementScreenLocation,
           let pointedAt = lastPointedElementAt,
           Date().timeIntervalSince(pointedAt) <= 120 {
            performNativeClick(
                at: point,
                displayFrame: lastPointedElementDisplayFrame,
                label: lastPointedElementLabel,
                request: request,
                executionStartedAt: executionStartedAt,
                timing: timing
            )
            return
        }

        Task { @MainActor in
            do {
                let screenCaptures = try await captureAllScreensForVoiceResponseIfAvailable()
                let liveMouseLocation = NSEvent.mouseLocation
                let targetScreenCapture = screenCaptures.first { $0.displayFrame.contains(liveMouseLocation) }
                    ?? screenCaptures.first(where: { $0.isCursorScreen })
                    ?? screenCaptures.first

                guard let targetScreenCapture else {
                    throw NSError(
                        domain: "OpenClickyNativeClick",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No screen capture available"]
                    )
                }

                let dimensionInfo = " (image dimensions: \(targetScreenCapture.screenshotWidthInPixels)x\(targetScreenCapture.screenshotHeightInPixels) pixels)"
                let response = try await analyzeComputerUsePointingResponse(
                    image: (data: targetScreenCapture.imageData, label: targetScreenCapture.label + dimensionInfo),
                    capture: targetScreenCapture,
                    systemPrompt: Self.nativeClickPointingSystemPrompt,
                    userPrompt: request.targetDescription,
                    onTextChunk: { _ in }
                )
                let parseResult = Self.parsePointingCoordinates(from: response)
                guard let pointCoordinate = parseResult.coordinate else {
                    speakShortSystemResponse("i couldn't find that to click.")
                    markRequestCompleted(
                        route: "native_cua.click",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: [
                            "executor": "native_cua",
                            "executionMethod": "analyzeComputerUsePointingResponse",
                            "controller": "OpenClickyNativeComputerUseController",
                            "targetPhrase": request.targetPhrase ?? "",
                            "error": "No click coordinate"
                        ]
                    )
                    return
                }

                let globalLocation = globalPoint(fromScreenshotPoint: pointCoordinate, in: targetScreenCapture)
                performNativeClick(
                    at: globalLocation,
                    displayFrame: targetScreenCapture.displayFrame,
                    label: parseResult.elementLabel ?? request.targetPhrase,
                    request: request,
                    executionStartedAt: executionStartedAt,
                    timing: timing
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "native_cua.click_error",
                    fields: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.click",
                        "controller": "OpenClickyNativeComputerUseController",
                        "targetPhrase": request.targetPhrase ?? "",
                        "error": error.localizedDescription
                    ]
                )
                speakShortSystemResponse("clicking hit a blocker: \(error.localizedDescription)")
                markRequestCompleted(
                    route: "native_cua.click",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: "failed",
                    extra: [
                        "executor": "native_cua",
                        "executionMethod": "OpenClickyNativeComputerUseController.click",
                        "controller": "OpenClickyNativeComputerUseController",
                        "targetPhrase": request.targetPhrase ?? "",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func performNativeClick(
        at point: CGPoint,
        displayFrame: CGRect?,
        label: String?,
        request: OpenClickyNativeClickRequest,
        executionStartedAt: Date,
        timing: OpenClickyRequestTiming?
    ) {
        do {
            try nativeComputerUseController.click(at: point)
            detectedElementScreenLocation = point
            detectedElementDisplayFrame = displayFrame
            detectedElementBubbleText = Self.pointingBubbleText(for: label)
            showActiveControlGlow(
                around: Self.controlTargetGlowRect(centeredOn: point, within: displayFrame),
                label: label ?? request.targetPhrase,
                duration: 2.4
            )
            rememberPointedElement(at: point, displayFrame: displayFrame, label: label)
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: "clicked \(label ?? request.targetPhrase ?? "that").",
                contextTitle: request.targetDescription
            )
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "native_cua.click",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "controller": "OpenClickyNativeComputerUseController",
                    "targetPhrase": request.targetPhrase ?? "",
                    "label": label ?? "",
                    "x": Int(point.x),
                    "y": Int(point.y)
                ]
            )
            speakShortSystemResponse("clicked \(label ?? request.targetPhrase ?? "that").")
            markRequestCompleted(
                route: "native_cua.click",
                executionStartedAt: executionStartedAt,
                timing: timing,
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "controller": "OpenClickyNativeComputerUseController",
                    "targetPhrase": request.targetPhrase ?? "",
                    "label": label ?? "",
                    "x": Int(point.x),
                    "y": Int(point.y)
                ]
            )
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "native_cua.click_error",
                fields: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "controller": "OpenClickyNativeComputerUseController",
                    "targetPhrase": request.targetPhrase ?? "",
                    "error": error.localizedDescription
                ]
            )
            speakShortSystemResponse("native clicking hit a blocker: \(error.localizedDescription)")
            markRequestCompleted(
                route: "native_cua.click",
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "failed",
                extra: [
                    "executor": "native_cua",
                    "executionMethod": "OpenClickyNativeComputerUseController.click",
                    "controller": "OpenClickyNativeComputerUseController",
                    "targetPhrase": request.targetPhrase ?? "",
                    "error": error.localizedDescription
                ]
            )
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

            if !ensureNativeComputerUseEnabledOrRefuse(spokenAction: "search messages") {
                return
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

        if !ensureNativeComputerUseEnabledOrRefuse(spokenAction: "type that") {
            return
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

        if !ensureNativeComputerUseEnabledOrRefuse(spokenAction: "press that key") {
            return
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
        if let appURL = Self.resolvedApplicationURL(named: appName) {
            Self.openApplication(at: appURL, appName: appName)
            return true
        }

        return runOpenApplication(arguments: ["-a", appName])
    }

    private static func resolvedApplicationURL(named appName: String) -> URL? {
        for bundleIdentifier in applicationBundleIdentifiers(for: appName) {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return appURL
            }
        }

        return standardApplicationURL(named: appName)
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
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            print("OpenClicky app open failed for arguments \(arguments): \(error)")
            return false
        }
    }

    func showQuickTextInputFromMenuBar() {
        showNotchTextInput { [weak self] submittedText in
            self?.submitNewAgentTaskFromUI(submittedText, source: "menu_bar_quick_task_prompt")
        }
    }

    private func showMainOpenClickyPanelFromShortcut() {
        guard allPermissionsGranted else { return }
        guard !buddyDictationManager.isKeyboardShortcutSessionActiveOrFinalizing else { return }

        startPrewarmedScreenshotCaptureIfPossible()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        notchCaptureWindowManager.showTextInput { [weak self] submittedText in
            self?.submitNewAgentTaskFromUI(submittedText, source: "notch_shortcut_task_prompt")
        }
    }

    private func showTextModeInputAtCursor(activationPoint: CGPoint? = nil) {
        showNotchTextInput()
    }

    private func showNotchTextInput(
        accentTheme: ClickyAccentTheme? = nil,
        submitText: ((String) -> Void)? = nil
    ) {
        guard allPermissionsGranted else { return }
        guard !buddyDictationManager.isKeyboardShortcutSessionActiveOrFinalizing else { return }

        startPrewarmedScreenshotCaptureIfPossible()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        notchCaptureWindowManager.showTextInput(
            accentTheme: accentTheme,
            submitText: submitText ?? { [weak self] submittedText in
                self?.submitTextModePrompt(submittedText)
            }
        )
    }

    func submitTextPrompt(_ submittedText: String) {
        submitTextModePrompt(submittedText)
    }

    private func submitTextModePrompt(_ submittedText: String) {
        let trimmedText = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let requestTiming = beginRequestTiming(source: "text_mode", text: trimmedText)
        activeRequestTiming = requestTiming
        defer { activeRequestTiming = nil }
        lastTranscript = trimmedText
        rememberMainConversationUserPrompt(trimmedText, source: "text_mode")
        ClickyAnalytics.trackUserMessageSent(transcript: trimmedText)
        interruptCurrentVoiceResponse()
        clearDetectedElementLocation()

        if routeFinalVoiceTranscriptActionIfNeeded(
            trimmedText,
            source: "text",
            selectionSource: "text_mode",
            directComputerUseSource: "text_mode",
            includeQuickLocalResponses: false
        ) {
            return
        }

        sendTranscriptToClaudeWithScreenshot(transcript: trimmedText)
    }

    private func submitPendingAgentVoiceFollowUp(_ transcript: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }
        guard let sessionID = pendingAgentVoiceFollowUpSessionID else { return false }
        let pendingSource = pendingAgentVoiceFollowUpSource ?? "pending_voice_followup"
        if let createdAt = pendingAgentVoiceFollowUpCreatedAt,
           Date().timeIntervalSince(createdAt) > Self.pendingAgentVoiceFollowUpTTL {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            pendingAgentVoiceFollowUpSource = nil
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "internal",
                event: "openclicky.agent_followup.voice_target_expired",
                fields: [
                    "source": pendingSource,
                    "sessionID": sessionID.uuidString,
                    "ageMs": Int(Date().timeIntervalSince(createdAt) * 1000)
                ]
            )
            return false
        }
        if Self.shouldStartNewAgentInsteadOfPendingFollowUp(trimmedTranscript) {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            pendingAgentVoiceFollowUpSource = nil
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "internal",
                event: "openclicky.agent_followup.bypassed_for_new_agent_request",
                fields: [
                    "source": pendingSource,
                    "sessionID": sessionID.uuidString,
                    "instructionPreview": String(trimmedTranscript.prefix(160)),
                    "requestID": activeRequestTiming?.requestID ?? ""
                ]
            )
            return false
        }
        if Self.isProbablyIncompleteAgentVoiceFollowUp(trimmedTranscript) {
            let timing = activeRequestTiming
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "outgoing",
                event: "openclicky.agent_followup.deferred_incomplete_voice",
                fields: [
                    "source": pendingSource,
                    "sessionID": sessionID.uuidString,
                    "requestID": timing?.requestID ?? "",
                    "instructionLength": trimmedTranscript.count,
                    "instructionPreview": String(trimmedTranscript.prefix(120))
                ]
            )
            speakShortSystemResponse("i only caught part of that. try the agent follow-up again.")
            return true
        }
        // The user explicitly targeted an agent from the dock/HUD — either by
        // opening its overlay or pressing Voice — so the next utterance belongs
        // to that agent even if it sounds like a normal local OpenClicky
        // command such as “open Clicky.” Keep this ahead of new-task, direct
        // computer-use, and quick local routing.
        pendingAgentVoiceFollowUpSessionID = nil
        pendingAgentVoiceFollowUpCreatedAt = nil
        pendingAgentVoiceFollowUpSource = nil
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": pendingSource,
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
                    "source": pendingSource,
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
                "source": pendingSource,
                "sessionID": sessionID.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
        speakShortSystemResponse("sent that to \(session.spokenAgentName).")
        return true
    }

    private static func isProbablyIncompleteAgentVoiceFollowUp(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

        guard !normalized.isEmpty else { return true }

        let danglingSuffixes = [
            "where the agent",
            "where the agents",
            "when the agent",
            "when the agents",
            "that the agent",
            "that the agents",
            "because the agent",
            "because the agents",
            "where it",
            "when it",
            "because it",
            "so it",
            "and it",
            "but it",
            "where",
            "when",
            "because",
            "that",
            "so",
            "and",
            "but"
        ]
        if danglingSuffixes.contains(where: { normalized.hasSuffix($0) }) {
            return true
        }

        let trailingFunctionWords: Set<String> = [
            "the", "a", "an", "to", "for", "with", "of", "in", "on", "at", "from",
            "by", "as", "into", "about", "around", "through", "over", "under"
        ]
        if let lastWord = normalized.split(separator: " ").last,
           trailingFunctionWords.contains(String(lastWord)) {
            return true
        }

        if isMostlySpokenTimestampOrLogNoise(normalized) {
            return true
        }

        return false
    }

    private static func isMostlySpokenTimestampOrLogNoise(_ normalizedTranscript: String) -> Bool {
        let words = normalizedTranscript.split(separator: " ").map(String.init)
        guard words.count >= 5 else { return false }

        let timestampTokens: Set<String> = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
            "oh", "o", "t", "z", "am", "pm"
        ]
        let timestampTokenCount = words.filter { timestampTokens.contains($0) }.count
        let timestampTokenRatio = Double(timestampTokenCount) / Double(words.count)

        let hasSpokenDateShape = normalizedTranscript.contains("zero five one zero")
            || normalizedTranscript.contains("zero two six")
            || normalizedTranscript.contains("two zero two six")
            || normalizedTranscript.contains("t one four")
            || normalizedTranscript.contains("t fourteen")

        let usefulWorkPattern = #"\b(?:fix|change|update|add|remove|make|create|build|open|show|find|review|test|run|check|look|inspect|capture|move|point|write|send)\b"#
        let hasUsefulWorkVerb = normalizedTranscript.range(of: usefulWorkPattern, options: .regularExpression) != nil

        return hasSpokenDateShape
            && timestampTokenRatio >= 0.35
            && !hasUsefulWorkVerb
    }

    private static func shouldStartNewAgentInsteadOfPendingFollowUp(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard normalized.contains("agent") || normalized.contains("agents") else { return false }
        if explicitNewTaskInstruction(from: transcript) != nil { return true }
        if agentTaskCreationInstruction(from: transcript) != nil { return true }

        let delegationPattern = #"\b(?:get|put|start|spin\s+up|spawn|create|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+|another\s+|new\s+|background\s+)*(?:agent|agents|codex)\b"#
        return normalized.range(of: delegationPattern, options: .regularExpression) != nil
    }

    private func submitContextualAgentFollowUp(_ transcript: String, source: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return false }
        guard !Self.isExplicitNewTaskRequest(trimmedTranscript) else { return false }
        // Require an actual follow-up cue — a connector word, the literal
        // word "agent", or a clearly-imperative micro-utterance. Without
        // this gate, any random question (e.g. "can you search the web?")
        // gets eaten by a still-running agent purely because it exists.
        guard Self.isLikelyAgentFollowUpPhrasing(trimmedTranscript) else { return false }
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

    /// Detects whether Haiku's response offered to spin up an agent.
    /// Triggers on phrases like "want me to spin up an agent", "should I
    /// start an agent", "i'd need to spin up an agent", or "I can hand that
    /// to an agent". Used to arm the pending-offer slot so the user's next
    /// "yes" / "okay then" can actually launch the agent.
    static func responseOffersAgentSpawn(_ spokenText: String) -> Bool {
        let normalized = spokenText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let offerPatterns = [
            "spin up an agent",
            "spin one up",
            "start an agent",
            "kick off an agent",
            "launch an agent",
            "spawn an agent",
            "have an agent",
            "agent mode",
            "want me to spin",
            "want me to start",
            "should i spin",
            "should i start"
        ]
        if offerPatterns.contains(where: { normalized.contains($0) }) {
            return true
        }

        let handoffPattern = #"\b(?:hand|send|route|pass|delegate|give)\b.{0,48}\b(?:agent|codex)\b"#
        return normalized.range(of: handoffPattern, options: .regularExpression) != nil
    }

    /// If Haiku's last reply offered an agent and the current transcript
    /// is a confirmation, spawn an agent with the remembered instruction.
    /// Returns true when the offer was accepted (caller should not route
    /// further). Falls through (returns false) when there's no pending
    /// offer, the offer expired, or the transcript isn't a confirmation.
    private func acceptPendingAgentOfferIfConfirmed(from transcript: String) -> Bool {
        guard let instruction = pendingAgentOfferInstruction,
              let offeredAt = pendingAgentOfferAt,
              Date().timeIntervalSince(offeredAt) <= Self.pendingAgentOfferTTL else {
            // Stale or absent — clear it so a fresh offer can land later.
            pendingAgentOfferInstruction = nil
            pendingAgentOfferAt = nil
            return false
        }

        guard Self.isAffirmativeConfirmation(transcript) else { return false }

        pendingAgentOfferInstruction = nil
        pendingAgentOfferAt = nil
        let acknowledgement = "on it, starting an agent for that."
        startVoiceAgentTaskPlan(instruction: instruction, acknowledgement: acknowledgement)
        return true
    }

    /// Recognizes a short affirmative response. Only matches when the
    /// entire transcript is a confirmation — we don't want "yes, but
    /// also do X" being treated as a bare yes.
    private static func isAffirmativeConfirmation(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

        let affirmatives: Set<String> = [
            "yes", "yeah", "yep", "yup", "yes please", "ok", "okay",
            "okay then", "ok then", "alright", "all right", "sure",
            "sure thing", "go", "go ahead", "go for it", "do it",
            "do that", "let's do it", "lets do it", "let's go",
            "spin it up", "spin one up", "fire it up", "fine", "please do",
            "please", "absolutely", "definitely",
            "can you do that", "could you do that", "would you do that",
            "can you do it", "could you do it", "would you do it",
            "please do that", "please do it"
        ]
        return affirmatives.contains(normalized)
    }

    /// Recognizes phrases that clearly mean "speak to the active agent"
    /// rather than "answer this question yourself". Used to gate
    /// `submitContextualAgentFollowUp` so an idle running agent doesn't
    /// silently absorb every subsequent voice turn.
    // MARK: - Speculative pre-fire

    private func resetSpeculativeFireForNewUtterance() {
        discardActiveSpeculativeFire(reason: "new_utterance")
        speculativeFireCountThisUtterance = 0
        lastObservedPartial = nil
        lastObservedPartialAt = nil
        speculativeStabilityDwellTask?.cancel()
        speculativeStabilityDwellTask = nil
    }

    /// Tracks the latest interim transcript and re-arms a stability
    /// dwell timer. When the partial holds steady for 1.5s and passes
    /// the eligibility predicate, fires a speculative Claude call on
    /// its own background Task. Multi-threaded by design — the fire's
    /// HTTP request, screenshot use, and token buffering all run
    /// outside the main actor.
    private func observePartialForSpeculativePreFire(_ partialTranscript: String) {
        guard speculativePreFireEnabled else { return }
        guard !partialTranscript.isEmpty else { return }
        // If a fire is already running for the SAME partial prefix
        // we're still extending, leave it alone — the extension may
        // simply finish the same sentence and the running call will
        // commit cleanly. Only re-fire when the partial has changed
        // its meaning (i.e., extended past the fired-against prefix
        // by enough words to be a different question).
        if let active = activeSpeculativeFire,
           partialTranscript.hasPrefix(active.partialTranscript),
           SpokenText.wordCount(in: partialTranscript) - SpokenText.wordCount(in: active.partialTranscript) < 4 {
            lastObservedPartial = partialTranscript
            lastObservedPartialAt = Date()
            return
        }

        // Partial diverged — discard any in-flight fire so the next
        // stable window can produce a fresh one.
        if let active = activeSpeculativeFire,
           !partialTranscript.hasPrefix(active.partialTranscript) {
            discardActiveSpeculativeFire(reason: "partial_diverged")
        }

        lastObservedPartial = partialTranscript
        lastObservedPartialAt = Date()

        speculativeStabilityDwellTask?.cancel()
        let snapshot = partialTranscript
        speculativeStabilityDwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                guard let self else { return }
                guard self.speculativePreFireEnabled else { return }
                guard self.lastObservedPartial == snapshot else { return }
                guard self.activeSpeculativeFire == nil else { return }
                guard self.speculativeFireCountThisUtterance < Self.speculativeMaxFiresPerUtterance else { return }
                guard Self.partialIsEligibleForSpeculativeFire(snapshot) else { return }
                self.fireSpeculativePreFire(forPartial: snapshot)
            }
        }
    }

    /// Predicate gating which partials are worth a speculative fire.
    /// Conservative — must look like a pure standalone question with
    /// no screen reference, no correction, no agent intent.
    private static func partialIsEligibleForSpeculativeFire(_ partialTranscript: String) -> Bool {
        let normalized = partialTranscript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        guard SpokenText.wordCount(in: normalized) >= speculativeMinWordCount else { return false }
        if quickLocalVoiceResponseText(for: partialTranscript) != nil { return false }

        // Reject anything that already routes elsewhere.
        if isAgentRoutingCandidate(partialTranscript) { return false }
        if explicitNewTaskInstruction(from: partialTranscript) != nil { return false }
        if agentTaskCreationInstruction(from: partialTranscript) != nil { return false }
        if clickyAgentInstruction(from: partialTranscript) != nil { return false }
        if permissiveAgentInstruction(from: partialTranscript) != nil { return false }
        if isCancelAllAgentTasksRequest(partialTranscript) { return false }
        if isCancelCurrentAgentTaskRequest(partialTranscript) { return false }

        // Reject deictic / correction phrasings — these almost always
        // depend on screen state or imply the user is mid-revision.
        let deicticBlocklist = [
            " this", " that", " here", " these", " those",
            " no,", " no.", " actually", " wait", " scratch", " i mean",
            " click", " press", " type", " open ", " close ",
            " switch ", " show me", " hide ", " select ",
            " screen", " can you see", " do you see", " looking at",
            " the file", " the button",
            " the window", " the panel", " the menu", " this app",
            " that app", " that file", " this tab"
        ]
        for needle in deicticBlocklist where normalized.contains(needle) {
            return false
        }

        // Require the partial to start with a question/conversational lead.
        let allowedLeads = [
            "what ", "what's ", "whats ", "who ", "who's ", "whos ",
            "why ", "when ", "where ", "how ", "is ", "are ", "do ",
            "does ", "can you ", "could you ", "would you ", "should i ",
            "tell me ", "explain ", "summarize ", "describe ",
            "give me ", "help me understand "
        ]
        for lead in allowedLeads where normalized.hasPrefix(lead) {
            return true
        }
        return false
    }


    /// Fires the speculative Claude call. Tokens stream into the
    /// active fire's buffer but are NOT pushed through TTS yet — the
    /// audio path waits for `commitSpeculativeFire`.
    private func fireSpeculativePreFire(forPartial partialTranscript: String) {
        speculativeFireCountThisUtterance += 1
        let firedAt = Date()

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "outgoing",
            event: "speculative.fire",
            fields: [
                "partialTranscript": partialTranscript,
                "fireOrdinal": speculativeFireCountThisUtterance,
                "voiceModel": selectedModel
            ]
        )

        // Speculative pre-fire already hides model latency by starting
        // while the user is still talking. Do not add a filler; it makes
        // committed text-only responses sound stitched together.
        let chosenFiller: FillerPhraseLibrary.FillerSelection? = nil
        let assistantPrefillText: String? = nil

        // Track buffered text on the actor; the streaming closure pushes
        // appends here. The Task runs detached for the HTTP work.
        let speculativeBufferRef = SpeculativeBufferRef()
        let speculativeFireForCapture = partialTranscript
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw CancellationError() }

            // Use the prewarmed screenshot if it's fresh — don't
            // recapture mid-utterance. Stale = falls back to no image.
            let labeledImages: [(data: Data, label: String)] = await MainActor.run {
                guard self.prewarmedScreenshotTask != nil,
                      let started = self.prewarmedScreenshotStartedAt,
                      Date().timeIntervalSince(started) <= Self.prewarmedScreenshotMaxAge else {
                    return [(data: Data, label: String)]()
                }
                // Don't consume the prewarmed task here — the final
                // path may still need it. Leave it in place; we just
                // peek at its current value via a separate await.
                return []
            }

            let history = await MainActor.run {
                self.voiceConversationHistoryForAPI()
            }

            let voiceSystemPrompt = await MainActor.run { self.currentVoiceResponseSystemPrompt() }

            let userPromptForClaude: String = {
                if labeledImages.isEmpty {
                    return "\(speculativeFireForCapture)\n\nNo screenshot is available. Answer from the transcript only and use [POINT:none]."
                }
                return speculativeFireForCapture
            }()

            do {
                return try await self.analyzeVoiceResponse(
                    images: labeledImages,
                    systemPrompt: voiceSystemPrompt,
                    conversationHistory: history,
                    userPrompt: userPromptForClaude,
                    assistantPrefill: assistantPrefillText,
                    onTextChunk: { accumulatedText in
                        speculativeBufferRef.value = accumulatedText
                    }
                )
            } catch {
                throw error
            }
        }

        activeSpeculativeFire = SpeculativeFire(
            partialTranscript: partialTranscript,
            firedAt: firedAt,
            task: task,
            bufferedContinuation: "",
            assistantPrefillText: assistantPrefillText,
            imagesUsed: 0,
            chosenFiller: chosenFiller
        )
        // Watch the buffer ref so we can update bufferedContinuation
        // — it's a class so the closure mutates the same storage.
        Task { [weak self] in
            while !(self?.activeSpeculativeFireTaskIsDone ?? true) {
                try? await Task.sleep(nanoseconds: 50_000_000)
                await MainActor.run {
                    self?.activeSpeculativeFire?.bufferedContinuation = speculativeBufferRef.value
                }
            }
            await MainActor.run {
                self?.activeSpeculativeFire?.bufferedContinuation = speculativeBufferRef.value
            }
        }
    }

    /// True only when there is no active fire OR the fire's task has
    /// completed. Used by the buffer-mirror loop to know when to stop.
    private var activeSpeculativeFireTaskIsDone: Bool {
        guard let task = activeSpeculativeFire?.task else { return true }
        return task.isCancelled
    }

    /// Cancel + drop any in-flight speculative fire. Called when the
    /// partial diverges, the user disables the feature, or the final
    /// transcript doesn't match.
    private func discardActiveSpeculativeFire(reason: String) {
        guard let active = activeSpeculativeFire else { return }
        active.task.cancel()
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "speculative.discard",
            fields: [
                "reason": reason,
                "firedPartial": active.partialTranscript,
                "bufferedChars": active.bufferedContinuation.count
            ]
        )
        activeSpeculativeFire = nil
    }

    /// If the final transcript matches (prefix-equal to) the partial
    /// we speculatively fired against, return the active fire so the
    /// caller can commit its buffered tokens straight to TTS. Returns
    /// nil otherwise; caller falls through to the normal response path.
    private func consumeSpeculativeFireIfMatches(_ finalTranscript: String) -> SpeculativeFire? {
        guard let active = activeSpeculativeFire else { return nil }
        let normalized = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let firedNormalized = active.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept exact match OR final extends the partial by ≤4 words
        // (Deepgram often delivers a slightly longer final after the
        // last interim — punctuation, smart-format additions).
        let isExactMatch = normalized == firedNormalized
        let extensionWords = SpokenText.wordCount(in: normalized) - SpokenText.wordCount(in: firedNormalized)
        let isCleanExtension = normalized.hasPrefix(firedNormalized) && extensionWords >= 0 && extensionWords <= 4
        guard isExactMatch || isCleanExtension else {
            discardActiveSpeculativeFire(reason: "final_diverged")
            return nil
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "speculative.commit",
            fields: [
                "firedPartial": active.partialTranscript,
                "finalTranscript": normalized,
                "extensionWords": extensionWords,
                "bufferedChars": active.bufferedContinuation.count,
                "elapsedSeconds": Date().timeIntervalSince(active.firedAt)
            ]
        )
        activeSpeculativeFire = nil
        return active
    }

    /// Mutable container for token-stream buffering across the actor
    /// boundary. The streaming `onTextChunk` closure runs on the main
    /// actor; the Task that polls the buffer also runs on main, so
    /// access is serialized. We use a class so the captured reference
    /// in the closure points to the same storage as the polling loop.
    private final class SpeculativeBufferRef: @unchecked Sendable {
        var value: String = ""
    }

    /// Hands a matched speculative fire to the live TTS pipeline.
    /// Schedules the filler PCM head-of-queue, then pumps any tokens
    /// already buffered through the sentence streamer, then awaits the
    /// in-flight Claude task for the tail. Mirrors the late half of
    /// `sendTranscriptToClaudeWithScreenshot`.
    private func commitSpeculativeFire(_ fire: SpeculativeFire, transcript: String) {
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: "voice.response",
            timing: timing,
            extra: voiceResponseExecutionFields()
        )
        let ttsStartedAt = Date()
        var didMarkAudioStarted = false

        let responseTaskToken = UUID()
        currentResponseTaskToken = responseTaskToken
        currentResponseTask = Task {
            defer { self.clearCurrentResponseTask(ifMatches: responseTaskToken) }
            self.voiceState = .processing
            var didCompleteRequest = false
            func completeRequest(status: String = "success", extra: [String: Any] = [:]) async {
                await MainActor.run {
                    guard !didCompleteRequest else { return }
                    didCompleteRequest = true
                    var fields = self.voiceResponseExecutionFields()
                    extra.forEach { fields[$0.key] = $0.value }
                    fields["speculativeCommit"] = true
                    self.markRequestCompleted(
                        route: "voice.response",
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: status,
                        extra: fields
                    )
                }
            }

            do {
                let streamingTTSSession = self.voiceTTSClient.beginStreamingResponse {
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
                            "executionMethod": "voiceTTSClient.beginStreamingResponse",
                            "controller": "voiceTTSClient",
                            "speculativeCommit": true
                        ]
                    )
                }

                if let chosenFiller = fire.chosenFiller {
                    streamingTTSSession.enqueuePrebakedSamples(chosenFiller.samples)
                }

                // Push whatever tokens have already accumulated. The
                // speculative call may have completed already, in
                // which case fire.task.value returns immediately;
                // otherwise we drain the live continuation as it
                // arrives.
                var emittedSpokenSoFar = ""
                let pushDelta: (String) -> Void = { parsedSpoken in
                    let safeSpoken = Self.stripTrailingVisualGuidanceTagFragment(parsedSpoken)
                    guard safeSpoken.hasPrefix(emittedSpokenSoFar),
                          safeSpoken.count > emittedSpokenSoFar.count else { return }
                    let delta = String(safeSpoken.dropFirst(emittedSpokenSoFar.count))
                    emittedSpokenSoFar = safeSpoken
                    streamingTTSSession.appendText(delta)
                }

                // Drain the buffered continuation already collected
                // before the task finishes.
                let preTaskBuffer = fire.bufferedContinuation
                if !preTaskBuffer.isEmpty {
                    let parsed = Self.parsePointingCoordinates(from: preTaskBuffer).spokenText
                    pushDelta(parsed)
                }

                // Wait for the speculative task to finish — it may
                // already be done. Then push any tail tokens.
                let continuationText: String
                do {
                    continuationText = try await fire.task.value
                } catch is CancellationError {
                    streamingTTSSession.cancel()
                    await completeRequest(status: "cancelled", extra: ["cancelledAt": "speculative_task"])
                    return
                } catch {
                    print("⚠️ Speculative commit failed: \(error)")
                    streamingTTSSession.cancel()
                    speakResponseFailureFallback(error)
                    await completeRequest(status: "failed", extra: ["error": error.localizedDescription])
                    return
                }

                let finalParsed = Self.parsePointingCoordinates(from: continuationText).spokenText
                pushDelta(finalParsed)

                let fullResponseText: String = {
                    if let prefill = fire.assistantPrefillText, !prefill.isEmpty {
                        return Self.combinedVoiceResponseText(
                            prefill: prefill,
                            continuation: continuationText
                        )
                    }
                    return continuationText
                }()
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                self.rememberVoiceExchange(
                    userTranscript: transcript,
                    assistantResponse: spokenText,
                    reason: "speculative_commit"
                )

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)
                self.latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: spokenText,
                    contextTitle: transcript
                )

                if Self.responseOffersAgentSpawn(spokenText) {
                    self.pendingAgentOfferInstruction = transcript
                    self.pendingAgentOfferAt = Date()
                } else {
                    self.pendingAgentOfferInstruction = nil
                    self.pendingAgentOfferAt = nil
                }

                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await streamingTTSSession.finish()
                    } catch {
                        guard !Self.isExpectedCancellation(error) else {
                            await completeRequest(status: "cancelled", extra: ["cancelledAt": "tts"])
                            return
                        }
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        speakResponseFailureFallback(error)
                    }
                } else {
                    streamingTTSSession.cancel()
                }

                await completeRequest(extra: ["speculativeCommit": true])
            }
        }
    }

    private static func isLikelyAgentFollowUpPhrasing(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

        guard !normalized.isEmpty else { return false }

        // Explicit "agent" / "agents" mention always counts as a steer.
        if permissiveAgentInstruction(from: transcript) != nil { return true }

        // Connector words that imply "continue what the agent was doing".
        let connectorPrefixes = [
            "and ", "also ", "now ", "then ", "next ", "after that ",
            "plus ", "as well ", "while you're at it ",
            "keep going", "carry on", "continue", "go on"
        ]
        for prefix in connectorPrefixes where normalized.hasPrefix(prefix) {
            return true
        }

        // Short imperatives like "do that", "yes", "stop", "go".
        let shortImperatives: Set<String> = [
            "do that", "do it", "yes", "yeah", "yep", "ok", "okay",
            "go", "go ahead", "go on", "fine", "sure", "no", "nope", "stop"
        ]
        if shortImperatives.contains(normalized) { return true }

        if isReferentialAgentWorkFollowUp(transcript) { return true }

        return false
    }

    /// Catches follow-ups like "update the form you made earlier" without
    /// routing ordinary questions such as "do you remember what we did earlier"
    /// into Agent Mode.
    private static func isReferentialAgentWorkFollowUp(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))

        guard !normalized.isEmpty else { return false }

        let referenceSignals = [
            "you did earlier",
            "you made earlier",
            "you created earlier",
            "you built earlier",
            "that you did",
            "that you made",
            "that you created",
            "that you built",
            "from earlier",
            "earlier one",
            "previous one",
            "last one",
            "that file",
            "that page",
            "that form",
            "that site",
            "that app",
            "that project",
            "it again"
        ]
        guard referenceSignals.contains(where: normalized.contains) else { return false }

        let workVerbPattern = #"\b(?:update|change|edit|modify|fix|tweak|adjust|add|remove|delete|make|turn|convert|open|reopen|show|preview|run|test|save|export|publish)\b"#
        return normalized.range(of: workVerbPattern, options: .regularExpression) != nil
    }

    private static func isSteerableAgentStatus(_ status: CodexAgentSessionStatus) -> Bool {
        switch status {
        case .stopped:
            return false
        case .starting, .ready, .running, .failed:
            return true
        }
    }

    // MARK: - Clear-overlays local intent

    /// Returns true when the transcript is a request to clear overlay
    /// annotations (boxes, highlights, cursor markers).
    /// - Parameter hasActiveOverlayAnnotation: pass `hasActiveOverlayAnnotation`
    ///   to gate pronoun-only forms ("clear those") on a live annotation.
    static func isClearOverlayAnnotationsRequest(
        _ transcript: String,
        hasActiveOverlayAnnotation: Bool
    ) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard !normalized.isEmpty else { return false }

        // Reject if agent-related words appear — keep agent-cancel priority.
        let agentWords = ["agent", "task", "job", "background", "session"]
        if agentWords.contains(where: normalized.contains) { return false }

        let clearVerbs = ["clear", "remove", "hide", "dismiss", "get rid of"]
        let hasVerb = clearVerbs.contains(where: normalized.contains)
        guard hasVerb else { return false }

        let annotationNouns = [
            "rectangle", "rectangles",
            "box", "boxes",
            "highlight", "highlights", "highlighting",
            "overlay", "overlays",
            "drawing", "drawings",
            "annotation", "annotations",
            "marker", "markers"
        ]
        if annotationNouns.contains(where: normalized.contains) {
            return true
        }

        // Pronoun-only form ("clear those", "hide them") — require an active annotation.
        let pronouns = ["those", "that", "them", "these"]
        if pronouns.contains(where: normalized.contains) {
            return hasActiveOverlayAnnotation
        }

        return false
    }

    private var hasActiveOverlayAnnotation: Bool {
        detectedElementScreenLocation != nil
            || detectedElementDisplayFrame != nil
            || !cursorOverlayState.visualGuidanceOverlays.isEmpty
            || !cursorOverlayState.externalSecondaryCursors.isEmpty
    }

    private func handleClearOverlayAnnotationsRequestIfNeeded(from transcript: String) -> Bool {
        guard Self.isClearOverlayAnnotationsRequest(
            transcript,
            hasActiveOverlayAnnotation: hasActiveOverlayAnnotation
        ) else { return false }

        let timing = activeRequestTiming
        let logFields: [String: Any] = [
            "executor": "local_fast_path",
            "executionMethod": "CompanionManager.clearOverlayAnnotations",
            "controller": "CompanionManager",
            "screenCaptureSkipped": true,
            "modelSkipped": true
        ]
        let executionStartedAt = markRequestExecutionStarted(
            route: "voice.clear_overlays",
            timing: timing,
            extra: logFields
        )

        // Clear all active overlay annotations.
        clearDetectedElementLocation()
        externalSecondaryCursorClearTasks.values.forEach { $0.cancel() }
        externalSecondaryCursorClearTasks.removeAll()
        cursorOverlayState.externalSecondaryCursors.removeAll()
        visualGuidanceOverlayClearTasks.values.forEach { $0.cancel() }
        visualGuidanceOverlayClearTasks.removeAll()
        cursorOverlayState.visualGuidanceOverlays.removeAll()
        clearVoiceResponseCaption()
        latestVoiceResponseCard = nil

        speakShortSystemResponse(
            "cleared.",
            route: "voice.clear_overlays",
            timing: timing,
            executionStartedAt: executionStartedAt,
            extra: logFields
        )
        return true
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

    private func cancelAllAgentTasks(reason: String = "agent.cancel_all") {
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
            cancelAgentTask(sessionID: session.id, removeDockItems: true, reason: reason)
            cancelledCount += 1
        }

        pendingAgentVoiceFollowUpSessionID = nil
        pendingAgentVoiceFollowUpCreatedAt = nil
        pendingAgentVoiceFollowUpSource = nil
        lastAgentContextSessionID = nil

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

        cancelAgentTask(sessionID: session.id, removeDockItems: true, reason: "agent.cancel_current")
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

    func stopCodexAgentSession(_ sessionID: UUID, reason: String = "agent.stop_button") {
        cancelAgentTask(sessionID: sessionID, removeDockItems: true, reason: reason)
    }

    func cancelAgentTask(sessionID: UUID, removeDockItems: Bool, reason: String = "agent.cancel") {
        cancelPendingAgentDockItemRemoval(for: sessionID)
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetSession = codexAgentSessions.first(where: { $0.id == sessionID })
        targetSession?.stop(reason: normalizedReason.isEmpty ? nil : normalizedReason)
        completeAgentRequestTimingIfNeeded(
            sessionID: sessionID,
            status: "cancelled",
            extra: [
                "cancelReason": normalizedReason.isEmpty ? "unknown" : normalizedReason
            ]
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.cancelled",
            fields: [
                "sessionID": sessionID.uuidString,
                "title": targetSession?.title ?? "Agent",
                "reason": normalizedReason.isEmpty ? "unknown" : normalizedReason
            ]
        )
        let announcementReason = Self.prettyCancelReason(for: normalizedReason)
        announceAgentCompletionIfNeeded(
            sessionID: sessionID,
            outcome: "cancelled",
            summary: announcementReason,
            cancelReason: normalizedReason
        )
        if removeDockItems {
            scheduleAgentDockItemRemoval(for: sessionID)
        }
        if pendingAgentVoiceFollowUpSessionID == sessionID {
            pendingAgentVoiceFollowUpSessionID = nil
            pendingAgentVoiceFollowUpCreatedAt = nil
            pendingAgentVoiceFollowUpSource = nil
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

            startVoiceAgentTaskPlan(instruction: newTaskInstruction)
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

            if let clickRequest = Self.nativeClickRequest(from: taskCreationInstruction) {
                clickUsingSelectedComputerUse(clickRequest)
                return true
            }

            if let systemVolumeAction = Self.systemVolumeControlAction(from: taskCreationInstruction) {
                runSystemVolumeControl(systemVolumeAction, instruction: taskCreationInstruction)
                return true
            }

            if let folderRequest = folderOpenRequest(from: taskCreationInstruction),
               Self.shouldInlineDirectFolderOpenFromAgentInstruction(taskCreationInstruction) {
                openRequestedFolder(folderRequest)
                return true
            }

            print("OpenClicky agent task creation request detected: \(taskCreationInstruction)")
            startVoiceAgentTaskPlan(instruction: taskCreationInstruction)
            return true
        }

        if Self.isIncompleteAgentTaskCreationRequest(from: transcript) {
            speakShortSystemResponse("what should the agent do?")
            return true
        }

        let explicitInstructionFromCliky = Self.clickyAgentInstruction(from: transcript)
        let permissiveInstruction = explicitInstructionFromCliky == nil
            ? Self.permissiveAgentInstruction(from: transcript)
            : nil

        guard let explicitInstruction = explicitInstructionFromCliky ?? permissiveInstruction else {
            return false
        }

        guard !explicitInstruction.isEmpty else {
            print("OpenClicky agent trigger detected without an instruction.")
            speakShortSystemResponse("what should the agent do?")
            return true
        }

        var instruction = SpokenText.normalizedAgentTaskInstruction(from: explicitInstruction)
        if Self.isReferentialAgentInstruction(instruction) {
            guard let resolvedInstruction = referentialAgentInstructionContext(excluding: transcript) else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.referential_instruction_unresolved",
                    fields: [
                        "transcript": transcript,
                        "explicitInstruction": explicitInstruction,
                        "requestID": activeRequestTiming?.requestID ?? "none"
                    ]
                )
                speakShortSystemResponse("what should the agent do?")
                return true
            }

            instruction = resolvedInstruction
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.referential_instruction_resolved",
                fields: [
                    "transcript": transcript,
                    "explicitInstruction": explicitInstruction,
                    "resolvedInstruction": instruction,
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
        }
        if let typeRequest = Self.nativeTypeRequest(from: instruction) {
            typeTextUsingSelectedComputerUse(typeRequest)
            return true
        }

        if let keyPressRequest = Self.nativeKeyPressRequest(from: instruction) {
            pressKeyUsingSelectedComputerUse(keyPressRequest)
            return true
        }

        if let clickRequest = Self.nativeClickRequest(from: instruction) {
            clickUsingSelectedComputerUse(clickRequest)
            return true
        }

        if let systemVolumeAction = Self.systemVolumeControlAction(from: instruction) {
            runSystemVolumeControl(systemVolumeAction, instruction: instruction)
            return true
        }

        if let folderRequest = folderOpenRequest(from: instruction),
           Self.shouldInlineDirectFolderOpenFromAgentInstruction(instruction) {
            openRequestedFolder(folderRequest)
            return true
        }

        if let compositeRequest = Self.compositeAppActionRequest(from: instruction) {
            startVoiceAgentTask(
                instruction: Self.compositeAppActionAgentInstruction(from: compositeRequest),
                acknowledgement: "i’ll do the app action, not just open the app.",
                route: "agent.composite_app_action",
                voiceContextUserTranscript: instruction
            )
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
        startVoiceAgentTaskPlan(instruction: instruction)
        return true
    }

    private func referentialAgentInstructionContext(excluding transcript: String) -> String? {
        let now = Date()
        if let pendingInstruction = pendingAgentOfferInstruction,
           let offeredAt = pendingAgentOfferAt,
           now.timeIntervalSince(offeredAt) <= Self.pendingAgentOfferTTL {
            pendingAgentOfferInstruction = nil
            pendingAgentOfferAt = nil
            return pendingInstruction
        }

        if let offeredAt = pendingAgentOfferAt,
           now.timeIntervalSince(offeredAt) > Self.pendingAgentOfferTTL {
            pendingAgentOfferInstruction = nil
            pendingAgentOfferAt = nil
        }

        let candidates: [(String?, Date?)] = [
            (lastVoiceUserTranscript, lastVoiceUserTranscriptAt),
            (previousVoiceUserTranscript, previousVoiceUserTranscriptAt)
        ]
        for (candidate, candidateAt) in candidates {
            guard let candidate,
                  let candidateAt,
                  now.timeIntervalSince(candidateAt) <= Self.pendingAgentOfferTTL else {
                continue
            }
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCandidate.isEmpty,
                  SpokenText.normalizedSpokenCommandText(trimmedCandidate) != SpokenText.normalizedSpokenCommandText(transcript),
                  !Self.isReferentialAgentInstruction(trimmedCandidate) else {
                continue
            }
            return trimmedCandidate
        }

        return nil
    }

    static func isCancelAllAgentTasksRequest(_ transcript: String) -> Bool {
        let normalizedTranscript = SpokenText.normalizedSpokenCommandText(transcript)
        if isAgentDelegationRequest(normalizedTranscript) {
            return false
        }
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

    static func isCancelCurrentAgentTaskRequest(_ transcript: String) -> Bool {
        let normalizedTranscript = SpokenText.normalizedSpokenCommandText(transcript)
        if isAgentDelegationRequest(normalizedTranscript) {
            return false
        }
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
        if phrases.contains(normalizedTranscript) {
            return true
        }

        let explicitAgentStopPattern = #"\b(?:cancel|stop|kill|dismiss)\b.{0,28}\b(?:agent|task|codex|background\s+task)\b"#
        return normalizedTranscript.range(of: explicitAgentStopPattern, options: .regularExpression) != nil
    }

    private static func isAgentDelegationRequest(_ normalizedTranscript: String) -> Bool {
        let delegationPhrases = [
            "get another agent",
            "start another agent",
            "spin up another agent",
            "launch another agent",
            "get an agent",
            "start an agent",
            "spin up an agent",
            "launch an agent",
            "have an agent",
            "ask an agent",
            "new agent",
            "another agent to",
            "agent to look",
            "agent look at",
            "agent to check",
            "agent to investigate",
            "agent to fix"
        ]
        return delegationPhrases.contains { normalizedTranscript.contains($0) }
    }

    private static func explicitNewTaskInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\s*(?:this\s+is\s+)?(?:a\s+)?(?:new|separate|different)\s+(?:agent\s+|codex\s+)?task\s*[:,-]?\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:start|create|spin\s+up|kick\s+off|launch|set\s+off)\s+(?:a\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+task\s*(?:to|for|that)?\s+(.+?)\s*$"#,
            #"(?i)^\s*set\s+(?:an?\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+(?:off|going)\s+(?:to|for|that)?\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:new|separate|different)\s+(?:agent|codex)\s*(?:task|job|session)?\s*[:,-]?\s+(.+?)\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let instructionRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }
            let instruction = SpokenText.cleanedAgentTaskInstruction(String(candidate[instructionRange]))
            return isAgentTaskPlaceholderInstruction(instruction) ? nil : instruction
        }

        return nil
    }

    private static func isExplicitNewTaskRequest(_ transcript: String) -> Bool {
        explicitNewTaskInstruction(from: transcript) != nil || isIncompleteExplicitNewTaskRequest(from: transcript)
    }

    private static func isIncompleteExplicitNewTaskRequest(from transcript: String) -> Bool {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return false }

        let patterns = [
            #"(?i)^\s*(?:this\s+is\s+)?(?:a\s+)?(?:new|separate|different)\s+(?:agent\s+|codex\s+)?task[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:start|create|spin\s+up|kick\s+off|launch|set\s+off)\s+(?:a\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+task[\s\.\!\?]*$"#,
            #"(?i)^\s*set\s+(?:an?\s+)?(?:new|separate|different)\s+(?:agent|codex)\s+(?:off|going)[\s\.\!\?]*$"#,
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


    static func quickLocalVoiceResponseText(for transcript: String) -> String? {
        let candidate = normalizedQuickLocalVoiceResponseCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let acknowledgementChecks = [
            "yes", "yeah", "yep", "no", "nope", "ok", "okay",
            "ok then", "okay then",
            "alright", "all right", "yeah alright", "yeah all right",
            "sounds good", "fair enough"
        ]
        if acknowledgementChecks.contains(candidate) {
            return "okay."
        }

        let hearingChecks = [
            "can you hear me",
            "can you hear us",
            "do you hear me",
            "do you hear us",
            "are you hearing me",
            "are you hearing us"
        ]
        if hearingChecks.contains(candidate) {
            return "yes, i can hear you."
        }

        let availabilityChecks = [
            "are you there",
            "are you still there",
            "are you listening",
            "are you awake",
            "you there",
            "hello",
            "hello there",
            "hi"
        ]
        if availabilityChecks.contains(candidate) {
            return "i'm here."
        }

        let connectionChecks = [
            "are you connected",
            "are we connected",
            "am i connected",
            "are you online",
            "are you working",
            "checking connection",
            "checking connection 123",
            "checking connection one two three",
            "connection check",
            "connection check 123",
            "connection check one two three"
        ]
        if connectionChecks.contains(candidate) {
            return "connection is working."
        }

        let capabilityChecks = [
            "what can you do",
            "what can you do for me",
            "what do you do",
            "what are you able to do",
            "what can openclicky do",
            "what can clicky do"
        ]
        if capabilityChecks.contains(candidate) {
            return "i can answer quick questions, look at your screen when needed, open apps and control your Mac, and hand bigger jobs to Agent Mode."
        }

        let voiceControlChecks = [
            "checking voice",
            "checking voice control",
            "just checking voice",
            "just checking voice control",
            "test test",
            "test 123",
            "test one two three",
            "testing",
            "testing 123",
            "testing one two three",
            "testing testing",
            "testing testing 123",
            "testing testing testing",
            "testing voice",
            "testing voice control",
            "testing out voice",
            "testing out voice control",
            "i am testing voice control",
            "i am testing out voice control",
            "im testing voice control",
            "im testing out voice control"
        ]
        if voiceControlChecks.contains(candidate) {
            return "voice control is working."
        }

        let slowResponseChecks = [
            "nothing is happening",
            "nothing happening",
            "why is nothing happening"
        ]
        if slowResponseChecks.contains(candidate) {
            return "i'm here. that last response was taking longer than expected."
        }

        return nil
    }

    private static func normalizedQuickLocalVoiceResponseCandidate(from transcript: String) -> String {
        var candidate = SpokenText.normalizedSpokenCommandText(transcript)
        let fillerPrefixes = ["hey", "ok", "okay", "right", "so"]
        let invocationPrefixes = [
            "learning buddy",
            "cursor buddy",
            "leaning buddy",
            "open clicky",
            "openclicky",
            "clicky",
            "buddy"
        ]

        var didStripPrefix = true
        while didStripPrefix {
            didStripPrefix = false
            for prefix in fillerPrefixes + invocationPrefixes {
                if candidate == prefix {
                    return ""
                }
                if candidate.hasPrefix(prefix + " ") {
                    candidate.removeFirst(prefix.count)
                    candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    didStripPrefix = true
                }
            }
        }

        return candidate
    }

    private func handleQuickLocalVoiceResponseIfNeeded(from transcript: String) -> Bool {
        guard let responseText = Self.quickLocalVoiceResponseText(for: transcript) else { return false }

        let timing = activeRequestTiming
        let logFields: [String: Any] = [
            "executor": "local_fast_path",
            "executionMethod": "CompanionManager.quickLocalVoiceResponseText",
            "controller": "CompanionManager",
            "screenCaptureSkipped": true,
            "modelSkipped": true,
            "transcriptLength": transcript.count,
            "spokenTextLength": responseText.count
        ]
        let executionStartedAt = markRequestExecutionStarted(
            route: "voice.quick_local_response",
            timing: timing,
            extra: logFields
        )

        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: responseText,
            contextTitle: transcript
        )
        speakShortSystemResponse(
            responseText,
            route: "voice.quick_local_response",
            timing: timing,
            executionStartedAt: executionStartedAt,
            extra: logFields
        )
        return true
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
        if codexAgentSessions.contains(where: { $0.hasVisibleActivity && !archivedSessionIDs.contains($0.id) }) {
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
                "visibleAgentCount": codexAgentSessions.filter { session in
                    session.hasVisibleActivity && !archivedSessionIDs.contains(session.id)
                }.count
            ]
        )
        return true
    }

    private func agentStatusSpokenSummary() -> String {
        let visibleSessions = codexAgentSessions.filter { session in
            session.hasVisibleActivity && !archivedSessionIDs.contains(session.id)
        }
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
        // Default OFF: users asked to stop automatic "working on it"
        // style voice updates while agents are still in flight.
        let progressVoiceEnabled = UserDefaults.standard.object(forKey: Self.agentProgressVoiceUpdatesDefaultsKey) as? Bool ?? false
        guard progressVoiceEnabled else { return }

        let runningSessions = codexAgentSessions.filter { session in
            switch session.status {
            case .starting, .running:
                return true
            case .stopped, .ready, .failed:
                return false
            }
        }

        guard !runningSessions.isEmpty else { return }
        guard voiceState == .idle, !voiceTTSClient.isPlaying else { return }

        // Only narrate sessions that have substantively new activity since
        // the last time we spoke about them. No filler — "we're working"
        // / "we're starting" no longer counts. If nothing meaningful has
        // changed, stay silent. This replaces the old behavior of
        // speaking "the agent says we're working" every 30 seconds.
        let updates: [(session: CodexAgentSession, phrase: String, signature: String)] =
            runningSessions.compactMap { session in
                guard let phrase = Self.agentProgressPhrase(for: session) else { return nil }
                let signature = "\(session.id.uuidString)|\(phrase)"
                if lastAgentProgressNarrationSignatures[session.id] == phrase {
                    return nil
                }
                return (session, phrase, signature)
            }

        guard !updates.isEmpty else { return }

        let updateText: String
        if updates.count == 1, let only = updates.first {
            updateText = "\(only.session.spokenAgentSentenceName) says \(only.phrase)."
        } else {
            let details = updates
                .prefix(3)
                .map { "\($0.session.spokenAgentSentenceName) says \($0.phrase)" }
                .joined(separator: ". ")
            let remainingCount = updates.count - min(updates.count, 3)
            if remainingCount > 0 {
                updateText = "\(details). \(remainingCount) more running."
            } else {
                updateText = details + "."
            }
        }

        for update in updates {
            lastAgentProgressNarrationSignatures[update.session.id] = update.phrase
        }
        lastAgentProgressNarrationAt = now
        speakShortSystemResponse(updateText)
    }

    /// Build the spoken phrase for an in-flight agent. Returns `nil` when
    /// there is nothing substantive to say — never returns filler like
    /// "we're working" or "we're starting", because the narration policy
    /// is now silence-by-default.
    private static func agentProgressPhrase(for session: CodexAgentSession) -> String? {
        guard let activity = session.latestActivitySummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !activity.isEmpty else {
            return nil
        }

        // Map a few well-known activity shapes to natural-sounding phrases.
        // For anything else, just speak the raw activity verbatim.
        if activity.contains("matching files") || activity.contains("looking for") {
            return "we're checking the files"
        }
        if activity.contains("focusing") || activity.contains("showing") {
            return "we're opening what we found"
        }
        if activity.contains("checking the work") {
            return "we're checking the work"
        }
        // Suppress the "we're working" / "still working" filler — we want
        // silence when nothing concrete has happened. If the activity is
        // genuinely just a "working" word with no detail, return nil.
        if activity == "working" || activity == "still working"
            || activity == "running" || activity == "in progress" {
            return nil
        }
        return "we're \(activity)"
    }

    private static func isAgentStatusQuestion(_ transcript: String) -> Bool {
        let normalizedTranscript = SpokenText.normalizedSpokenCommandText(transcript)

        let mentionsAgent = normalizedTranscript.contains("agent") || normalizedTranscript.contains("agents") || normalizedTranscript.contains("codex")
        guard mentionsAgent else { return false }

        let statusPatterns = [
            #"\b(?:agent|agents|codex)\s+(?:status|progress)\b"#,
            #"\b(?:status|progress)\s+(?:of|on|for)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\b"#,
            #"\b(?:how\s+(?:are|is|s))\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\b"#,
            #"\bwhat\s+(?:are|is|s)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\s+(?:doing|up\s+to|working\s+on)\b"#,
            #"\bwhat\s+(?:is|s)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\s+status\b"#,
            #"\bwhat\s+(?:is|s)\s+(?:the\s+)?(?:status|progress)\s+(?:of|on|for)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\b"#,
            #"\b(?:is|are)\s+(?:my\s+|the\s+)?(?:agent|agents|codex)\s+(?:still\s+)?(?:running|finished|done|working)\b"#,
            #"\b(?:agent|agents|codex)\s+(?:still\s+)?(?:doing|running|finished|done|working)\b"#,
            #"\b(?:agent|agents|codex)\s+up\s+to\b"#,
            #"\b(?:your|the)\s+(?:agent|agents|codex)\s+(?:status|progress)\b"#
        ]

        return statusPatterns.contains { pattern in
            normalizedTranscript.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func spokenCount(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? "one \(singular)" : "\(count) \(plural)"
    }

    private static func alphanumericTokenRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var currentStart: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if currentStart == nil {
                    currentStart = index
                }
            } else if let start = currentStart {
                ranges.append(start..<index)
                currentStart = nil
            }
            index = text.index(after: index)
        }

        if let start = currentStart {
            ranges.append(start..<text.endIndex)
        }
        return ranges
    }

    private static func clickyAgentInstruction(from transcript: String) -> String? {
        struct TranscriptToken {
            let normalizedText: String
            let originalRange: Range<String.Index>
        }

        let foldedTranscript = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokens = alphanumericTokenRanges(in: foldedTranscript).map { range in
            TranscriptToken(
                normalizedText: String(foldedTranscript[range]).lowercased(),
                originalRange: range
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

            // Apple Speech can also insert "the" into the wake phrase:
            // "Hey, the agent ..." should be treated like "Hey agent ...".
            if tokens[scanningIndex].normalizedText == "the", sawHeyPrefix {
                let agentTokenIndex = scanningIndex + 1
                if agentTokenIndex < tokens.count,
                   tokens[agentTokenIndex].normalizedText == "agent" {
                    let rawInstruction = String(transcript[tokens[agentTokenIndex].originalRange.upperBound...])
                    let trimmedInstruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanedInstruction = trimmedInstruction.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
                    return cleanedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // Apple Speech often hears "Clicky agent" as "click the agent".
            // Treat that exact token sequence as the product wake phrase so
            // long-form live partials can still be deferred to Agent Mode.
            if tokens[scanningIndex].normalizedText == "click" {
                let theTokenIndex = scanningIndex + 1
                let agentTokenIndex = scanningIndex + 2
                if theTokenIndex < tokens.count,
                   agentTokenIndex < tokens.count,
                   tokens[theTokenIndex].normalizedText == "the",
                   tokens[agentTokenIndex].normalizedText == "agent" {
                    let rawInstruction = String(transcript[tokens[agentTokenIndex].originalRange.upperBound...])
                    let trimmedInstruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanedInstruction = trimmedInstruction.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
                    return cleanedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                }
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
        case "clicky", "klicky", "openclicky", "cookie", "quick":
            return true
        default:
            return false
        }
    }

    /// Permissive fallback: if the user says anything containing the word
    /// "agent" (e.g. "ask an agent to...", "have an agent...", "tell the agent..."),
    /// route to delegation. Cancellation/status/selection branches run first in
    /// `handleFinalVoiceTranscript`, so this only triggers for actual task
    /// creation. Returns nil if "agent" appears only as part of another word
    /// like "agency", or if the remaining instruction would be empty.
    static func permissiveAgentInstruction(from transcript: String) -> String? {
        let folded = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokenRanges = alphanumericTokenRanges(in: folded)
        guard !tokenRanges.isEmpty else { return nil }

        // Prefer the last exact "agent" / "agents" token, but fall back to
        // earlier ones. Dictation can append trailing phrases like "agent
        // work"; using only the last token can hide the real delegation.
        var agentTokenRanges: [Range<String.Index>] = []
        for range in tokenRanges {
            let token = String(folded[range]).lowercased()
            if token == "agent" || token == "agents" {
                agentTokenRanges.append(range)
            }
        }
        guard !agentTokenRanges.isEmpty else { return nil }

        for agentTokenRange in agentTokenRanges.reversed() {
            if let instruction = permissiveAgentInstructionCandidate(
                from: transcript,
                folded: folded,
                agentTokenRange: agentTokenRange
            ) {
                return instruction
            }
        }

        return nil
    }

    private static func permissiveAgentInstructionCandidate(
        from transcript: String,
        folded: String,
        agentTokenRange: Range<String.Index>
    ) -> String? {
        let afterAgent = String(transcript[agentTokenRange.upperBound...])
        let cleaned = afterAgent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a leading connector
        // ("ask an agent to X" -> "X", "task an agent with X" -> "X").
        let lowercased = cleaned.lowercased()
        let connectors = ["to ", "for ", "with ", "that ", "which ", "who ", "and ", "please ", "could you ", "can you "]
        var instruction = cleaned
        var strippedLeadingConnector = false
        for connector in connectors where lowercased.hasPrefix(connector) {
            instruction = String(cleaned.dropFirst(connector.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            strippedLeadingConnector = true
            break
        }

        guard !instruction.isEmpty else { return nil }
        let beforeAgent = String(folded[..<agentTokenRange.lowerBound])
        let normalizedBeforeAgent = SpokenText.normalizedSpokenCommandText(beforeAgent)
        let normalizedInstruction = SpokenText.normalizedSpokenCommandText(instruction)

        let delegationCuePattern = #"\b(?:ask|tell|have|get|task|use|start|create|spin\s+up|spawn|run|launch|kick\s+off|set\s+up|send|route|hand|pass)\b"#
        let hasDelegationCueBefore = normalizedBeforeAgent.range(
            of: delegationCuePattern,
            options: .regularExpression
        ) != nil

        let afterAgentImperativePattern = #"^(?:find|search|look|inspect|review|open|create|make|build|update|fix|change|edit|check|run|test|summarize|analyse|analyze|clean|audit)\b"#
        let hasImperativeAfterAgent = normalizedInstruction.range(
            of: afterAgentImperativePattern,
            options: .regularExpression
        ) != nil
        let hasAgentTaskShape = hasDelegationCueBefore
            || strippedLeadingConnector
            || hasImperativeAfterAgent
            || isLikelyAgentToolWorkInstruction(instruction)
        guard hasAgentTaskShape else { return nil }

        let beforeTokens = normalizedBeforeAgent.split(separator: " ")
        if let lastBeforeAgent = beforeTokens.last,
           (lastBeforeAgent == "ai" || lastBeforeAgent == "openai"),
           !hasDelegationCueBefore,
           !strippedLeadingConnector {
            return nil
        }

        return instruction
    }

    private static func shouldInlineDirectFolderOpenFromAgentInstruction(_ instruction: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(instruction)
        guard !normalized.isEmpty else { return false }

        let agentWorkSignals = [
            "look at",
            "take a look",
            "review",
            "inspect",
            "audit",
            "go through",
            "check",
            "improve",
            "improvement",
            "recommend",
            "make any",
            "find",
            "search",
            "read",
            "analyze",
            "analyse"
        ]
        if agentWorkSignals.contains(where: { normalized.contains($0) }) {
            return false
        }

        let directFolderPrefixes = [
            "open ",
            "show ",
            "reveal ",
            "bring up ",
            "pull up ",
            "go into ",
            "go in ",
            "go to ",
            "navigate to ",
            "switch to ",
            "inside "
        ]
        return directFolderPrefixes.contains { normalized.hasPrefix($0) }
    }


    private static func isReferentialAgentInstruction(_ instruction: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(instruction)
        guard !normalized.isEmpty else { return false }

        let referentialInstructions: Set<String> = [
            "that",
            "it",
            "this",
            "do that",
            "do it",
            "do this",
            "on it",
            "get on it",
            "take care of it",
            "that one",
            "the thing",
            "the task",
            "the previous thing",
            "the previous task"
        ]
        return referentialInstructions.contains(normalized)
    }

    static func agentTaskCreationInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        if let diagnosticInstruction = diagnosticPasteAgentInstruction(from: candidate) {
            return diagnosticInstruction
        }

        let patterns = [
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:create|start|spin\s+up|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?\s+(?:to|for|that|which|who)?\s*(.+?)\s*$"#,
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?set\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?\s+(?:off|going)\s+(?:to|for|that|which|who)?\s*(.+?)\s*$"#,
            #"(?i)^\s*(?:the\s+)?(?:agent|agenty|codex)\s+(?:create|start|spin\s+up|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|agenty|codex)?\s*(?:task|job|session)?\s*(?:to|for|that|which|who)?\s*(.+?)\s*$"#,
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:ask|tell|have|get|task)\s+(?:an?\s+|the\s+)?(?:agent|agenty|codex)\s+(?:to|for|with)\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:agent|agenty|codex)\s+(?:with|for)\s+(.+?)\s*$"#,
            #"(?i)^\s*(?:an?\s+|the\s+)?(?:new\s+|background\s+)?(?:agent|agenty|codex)\s*(?:task|job|session)?\s+(?:to|for|that|which|who)\s+(.+?)\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let instructionRange = Range(match.range(at: 1), in: candidate) else { continue }
            let instruction = SpokenText.cleanedAgentTaskInstruction(String(candidate[instructionRange]))
            return isAgentTaskPlaceholderInstruction(instruction) ? nil : instruction
        }

        if let noisyInstruction = noisyAgentTaskCreationInstruction(from: candidate) {
            return noisyInstruction
        }

        return misheardQuestionAgentInstruction(from: candidate)
    }

    private static func diagnosticPasteAgentInstruction(from candidate: String) -> String? {
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard normalized.hasPrefix("see issue here")
            || normalized.hasPrefix("see the issue here")
            || normalized.hasPrefix("look at this")
            || normalized.hasPrefix("look at these")
            || normalized.hasPrefix("fix this")
            || normalized.hasPrefix("what is this")
            || normalized.hasPrefix("whats this")
            || normalized.hasPrefix("what's this")
        else {
            return nil
        }

        let rawLogSignals = [
            "[OpenClickyLog]",
            "openclicky.",
            "NSXPCDecoder",
            "NSXPCInterface",
            "NSXPCConnection",
            "ViewBridge",
            "NSViewBridgeError",
            "unifiedReasons",
            "Unable to obtain a task name port right",
            "nw_protocol_instance",
            "agent_sdk_query",
            "_sdk_query",
            "Bridge SDK Message",
            "kDragIPC",
            "Reentrant message",
            "stack trace",
            "traceback",
            "exception",
            "error domain="
        ]

        guard candidate.count > 240 || rawLogSignals.contains(where: { candidate.localizedCaseInsensitiveContains($0) }) else {
            return nil
        }

        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func misheardQuestionAgentInstruction(from candidate: String) -> String? {
        let pattern = #"(?i)^\s*(?:question|agent\s+question)\s*[:,-]?\s+(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        guard let match = regex.firstMatch(in: candidate, range: range),
              let instructionRange = Range(match.range(at: 1), in: candidate) else {
            return nil
        }

        let instruction = SpokenText.normalizedAgentTaskInstruction(
            from: SpokenText.cleanedAgentTaskInstruction(String(candidate[instructionRange]))
        )
        guard !instruction.isEmpty,
              !isAgentTaskPlaceholderInstruction(instruction),
              isLikelyAgentToolWorkInstruction(instruction) else {
            return nil
        }
        return instruction
    }

    private static func isLikelyAgentToolWorkInstruction(_ instruction: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(instruction)
        let toolWorkSignals = [
            "github",
            "issue",
            "issues",
            "pull request",
            "pr",
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
            "research",
            "summarize",
            "summary",
            "voice",
            "realtime",
            "computer use",
            "tool",
            "tools",
            "tooling",
            "model",
            "models",
            "routing",
            "background",
            "agent mode",
            "slider",
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
            let instruction = SpokenText.cleanedAgentTaskInstruction(String(candidate[instructionRange]))
            return isAgentTaskPlaceholderInstruction(instruction) ? nil : instruction
        }

        return nil
    }

    private static func isMetaAgentRoutingQuestion(_ candidate: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
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
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return false }

        let patterns = [
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:create|start|spin\s+up|spawn|run|launch|kick\s+off|set\s+up)\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|codex)\s*(?:task|job|session)?[\s\.\!\?]*$"#,
            #"(?i)^\s*(?:(?:clicky|openclicky)\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?set\s+(?:an?\s+|the\s+)?(?:new\s+)?(?:background\s+)?(?:agent|codex)\s*(?:task|job|session)?\s+(?:off|going)[\s\.\!\?]*$"#,
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


    private static func isAgentTaskPlaceholderInstruction(_ instruction: String) -> Bool {
        let normalized = instruction
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ["agent", "task", "job", "session", "agent task", "agent job", "codex task"].contains(normalized)
    }

    private static func agentSelectionRequest(from transcript: String) -> OpenClickyAgentSelectionRequest? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
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
        SpokenText.normalizedSpokenCommandText(value)
            .replacingOccurrences(of: #"\b(?:agent|task|session)\b"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func webOpenRequest(from transcript: String) -> OpenClickyWebOpenRequest? {
        let trimmedTranscript = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !trimmedTranscript.isEmpty else { return nil }

        let browserNavigationPatterns: [(pattern: String, browserGroup: Int, targetGroup: Int)] = [
            (
                #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:open|launch|start|switch\s+to)\s+(?:the\s+)?((?:google\s+)?chrome|safari)\s*(?:,|\band\b|\bthen\b)?\s*(?:go\s+to|visit|browse\s+to|navigate\s+to|pull\s+up|show|open)\s+(?:the\s+)?(.+?)(?:\s+(?:website|web\s+site|webpage|web\s+page|url|site))?(?:\s+for\s+me)?[\.\!\?]*\s*$"#,
                1,
                2
            ),
            (
                #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:go\s+to|visit|browse\s+to|navigate\s+to|pull\s+up|show|open)\s+(?:the\s+)?(.+?)(?:\s+(?:website|web\s+site|webpage|web\s+page|url|site))?\s+(?:in|on|using|with)\s+(?:the\s+)?((?:google\s+)?chrome|safari)(?:\s+for\s+me)?[\.\!\?]*\s*$"#,
                2,
                1
            )
        ]

        for browserNavigationPattern in browserNavigationPatterns {
            guard let regex = try? NSRegularExpression(pattern: browserNavigationPattern.pattern) else { continue }
            let range = NSRange(trimmedTranscript.startIndex..<trimmedTranscript.endIndex, in: trimmedTranscript)
            guard let match = regex.firstMatch(in: trimmedTranscript, range: range),
                  let browserRange = Range(match.range(at: browserNavigationPattern.browserGroup), in: trimmedTranscript),
                  let targetRange = Range(match.range(at: browserNavigationPattern.targetGroup), in: trimmedTranscript) else {
                continue
            }

            let rawBrowser = String(trimmedTranscript[browserRange])
            let browserAppName = normalizedApplicationName(from: rawBrowser)
            guard ["Google Chrome", "Safari"].contains(browserAppName) else { continue }

            let rawTarget = String(trimmedTranscript[targetRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,!?"))
            guard let url = normalizedWebOpenURL(from: rawTarget) else { continue }
            return OpenClickyWebOpenRequest(
                url: url,
                displayName: displayNameForWebOpenTarget(rawTarget, url: url),
                instruction: trimmedTranscript,
                browserAppName: browserAppName
            )
        }

        let patterns = [
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:open|go\s+to|visit|browse\s+to|navigate\s+to|pull\s+up|show)\s+(?:the\s+)?(.+?)(?:\s+(?:website|web\s+site|webpage|web\s+page|url|site))?(?:\s+for\s+me)?[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:the\s+)?(.+?)\s+(?:website|web\s+site|webpage|web\s+page|url|site)[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(trimmedTranscript.startIndex..<trimmedTranscript.endIndex, in: trimmedTranscript)
            guard let match = regex.firstMatch(in: trimmedTranscript, range: range),
                  let targetRange = Range(match.range(at: 1), in: trimmedTranscript) else {
                continue
            }

            let rawTarget = String(trimmedTranscript[targetRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,!?"))
            guard let url = normalizedWebOpenURL(from: rawTarget) else { continue }
            return OpenClickyWebOpenRequest(
                url: url,
                displayName: displayNameForWebOpenTarget(rawTarget, url: url),
                instruction: trimmedTranscript,
                browserAppName: nil
            )
        }

        return nil
    }

    private static func normalizedWebOpenURL(from rawTarget: String) -> URL? {
        let trimmed = rawTarget.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,!?"))
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if lowered.hasPrefix("www.") {
            return URL(string: "https://\(trimmed)")
        }
        if lowered.range(of: #"\b[a-z0-9-]+(?:\.[a-z0-9-]+)+\b"#, options: .regularExpression) != nil {
            return URL(string: "https://\(lowered)")
        }

        return nil
    }

    private static func displayNameForWebOpenTarget(_ rawTarget: String, url: URL) -> String {
        let cleaned = rawTarget.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,!?"))
        if !cleaned.isEmpty {
            return cleaned
        }
        return url.host ?? url.absoluteString
    }

    private static func compositeAppActionRequest(from transcript: String) -> OpenClickyCompositeAppActionRequest? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }
        guard !isExplicitAgentRoutingCandidate(candidate) else { return nil }

        let patterns: [(pattern: String, requiresKnownApp: Bool, requiresActionVerb: Bool)] = [
            (
                #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:open|launch|start|switch\s+to)\s+(?:up\s+)?(.+?)\s+(?:and|then)\s+(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(.+?)(?:\s+for\s+me)?[\.\!\?]*\s*$"#,
                false,
                false
            ),
            (
                #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:open|launch|start|switch\s+to)\s+(?:up\s+)?(.+?)\s+to\s+(.+?)(?:\s+for\s+me)?[\.\!\?]*\s*$"#,
                false,
                false
            ),
            (
                #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(.+?)\s+(?:and|then)\s+(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(.+?)(?:\s+for\s+me)?[\.\!\?]*\s*$"#,
                true,
                true
            )
        ]

        for compositePattern in patterns {
            let pattern = compositePattern.pattern
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let appRange = Range(match.range(at: 1), in: candidate),
                  let actionRange = Range(match.range(at: 2), in: candidate) else {
                continue
            }

            let rawAppName = String(candidate[appRange])
            let actionText = cleanedCompositeAppActionText(String(candidate[actionRange]))
            let appName = normalizedApplicationName(from: rawAppName)
            guard !appName.isEmpty,
                  !actionText.isEmpty,
                  !isContaminatedCompositeAppName(rawAppName),
                  (!compositePattern.requiresKnownApp || isKnownBareLocalApplicationName(appName)),
                  (!compositePattern.requiresActionVerb || hasDirectCompositeActionVerb(actionText)),
                  !isReservedAgentOpenTarget(rawAppName),
                  !isLocalAppOpenPlaceholder(appName),
                  !isLikelyFileOrFolderOpenTarget(rawAppName),
                  !isLikelyWebOpenTarget(rawAppName),
                  !isLikelyBrowserNavigationAction(actionText) else {
                continue
            }

            return OpenClickyCompositeAppActionRequest(
                appName: appName,
                actionText: actionText,
                instruction: candidate
            )
        }

        return nil
    }

    private static func cleanedCompositeAppActionText(_ rawActionText: String) -> String {
        var actionText = rawActionText.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?"))
        actionText = actionText.replacingOccurrences(
            of: #"(?i)^(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?"#,
            with: "",
            options: .regularExpression
        )
        return actionText.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?"))
    }

    private static func isLikelyBrowserNavigationAction(_ actionText: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(actionText)
        let pattern = #"\b(?:go\s+to|navigate\s+to|browse\s+to|visit|open\s+(?:the\s+)?(?:website|web\s*site|webpage|web\s*page|url|site))\b"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isContaminatedCompositeAppName(_ rawAppName: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(rawAppName)
        let pattern = #"\b(?:and|then)\s+(?:go|navigate|browse|visit|open|play|search|find|look\s+up|type|write|enter|press|hit|click|tap|select|choose)\b"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    private static func hasDirectCompositeActionVerb(_ actionText: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(actionText)
        let pattern = #"^(?:play|pause|resume|skip|next|previous|search|find|look\s+up|type|write|enter|press|hit|click|tap|select|choose|go\s+to|navigate\s+to|browse\s+to|visit)\b"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    private static func compositeAppSearchQuery(from actionText: String) -> String? {
        let candidate = cleanedCompositeAppActionText(actionText)
        let patterns = [
            #"(?i)^\s*(?:search|find|look\s+up)\s+(?:for\s+)?(.+?)(?:\s+in\s+(?:the\s+)?(?:app|application|window))?[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let queryRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }
            let query = cleanedCompositeActionPayload(String(candidate[queryRange]))
            guard !query.isEmpty else { continue }
            return query
        }

        return nil
    }

    private static func spotifyPlaybackQuery(from actionText: String) -> String? {
        let candidate = cleanedCompositeAppActionText(actionText)
        let patterns = [
            #"(?i)^\s*(?:play|put\s+on)\s+(?:the\s+)?(?:(?:song|track|album|artist)\s+)?(.+?)(?:\s+on\s+spotify)?[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let queryRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }
            let query = cleanedCompositeActionPayload(String(candidate[queryRange]))
            let normalized = SpokenText.normalizedSpokenCommandText(query)
            guard !query.isEmpty,
                  !["something", "music", "a song", "the song", "anything", "spotify"].contains(normalized) else {
                continue
            }
            return query
        }

        return nil
    }

    private static func standaloneSpotifyPlaybackRequest(from transcript: String) -> OpenClickyCompositeAppActionRequest? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty,
              !isExplicitAgentRoutingCandidate(candidate),
              compositeAppActionRequest(from: candidate) == nil else {
            return nil
        }

        let actionText = cleanedCompositeAppActionText(candidate)
        if let controlAction = spotifyPlaybackControlAction(from: actionText),
           !spotifyPlaybackControlRequiresExplicitSpotifyContext(controlAction) || hasSpotifyContext(candidate) {
            return OpenClickyCompositeAppActionRequest(
                appName: "Spotify",
                actionText: actionText,
                instruction: candidate
            )
        }

        if let query = spotifyPlaybackQuery(from: actionText),
           !isAmbiguousStandaloneSpotifyPlaybackQuery(query) {
            return OpenClickyCompositeAppActionRequest(
                appName: "Spotify",
                actionText: actionText,
                instruction: candidate
            )
        }

        return nil
    }

    private static func isAmbiguousStandaloneSpotifyPlaybackQuery(_ query: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(query)
        let ambiguousTargets: Set<String> = [
            "it",
            "that",
            "this",
            "video",
            "the video",
            "movie",
            "the movie",
            "episode",
            "the episode",
            "clip",
            "the clip",
            "youtube",
            "youtube video"
        ]
        return ambiguousTargets.contains(normalized)
    }

    private static func systemVolumeControlAction(from transcript: String) -> OpenClickySystemVolumeControlAction? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty,
              !isExplicitAgentRoutingCandidate(candidate),
              !hasSpotifyContext(candidate),
              compositeAppActionRequest(from: candidate) == nil else {
            return nil
        }

        let normalized = SpokenText.normalizedSpokenCommandText(cleanedCompositeAppActionText(candidate))
        if let volumePercent = systemVolumePercent(fromNormalizedControlText: normalized) {
            return OpenClickySystemVolumeControlAction(.setVolume, volumePercent: volumePercent)
        }

        switch normalized {
        case "volume up", "system volume up", "turn volume up", "turn system volume up",
             "increase volume", "increase system volume", "raise volume", "raise system volume",
             "turn it up", "louder", "make it louder":
            return OpenClickySystemVolumeControlAction(.volumeUp)
        case "volume down", "system volume down", "turn volume down", "turn system volume down",
             "decrease volume", "decrease system volume", "lower volume", "lower system volume",
             "turn it down", "quieter", "make it quieter":
            return OpenClickySystemVolumeControlAction(.volumeDown)
        case "mute", "mute volume", "mute system volume", "mute the volume", "mute the system volume",
             "turn mute on", "turn system mute on":
            return OpenClickySystemVolumeControlAction(.mute)
        default:
            return nil
        }
    }

    private static func systemVolumePercent(fromNormalizedControlText normalized: String) -> Int? {
        let patterns = [
            #"^(?:set\s+)?(?:system\s+)?volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#,
            #"^(?:turn\s+)?(?:system\s+)?volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#,
            #"^(?:set\s+)?(?:system\s+)?sound\s+volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            guard let match = regex.firstMatch(in: normalized, range: range),
                  let percentRange = Range(match.range(at: 1), in: normalized),
                  let value = Int(normalized[percentRange]) else {
                continue
            }
            return min(100, max(0, value))
        }
        return nil
    }

    private static func spotifyPlaybackControlRequiresExplicitSpotifyContext(_ action: OpenClickySpotifyPlaybackControlAction) -> Bool {
        switch action.kind {
        case .volumeUp, .volumeDown, .volumeMute, .volumeSet:
            return true
        default:
            return false
        }
    }

    private static func hasSpotifyContext(_ transcript: String) -> Bool {
        SpokenText.normalizedSpokenCommandText(transcript).range(
            of: #"\bspotify\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func spotifyPlaybackControlAction(from actionText: String) -> OpenClickySpotifyPlaybackControlAction? {
        var normalized = SpokenText.normalizedSpokenCommandText(cleanedCompositeAppActionText(actionText))
        normalized = normalized.replacingOccurrences(
            of: #"\s+(?:(?:in|on)\s+)?spotify$"#,
            with: "",
            options: .regularExpression
        )
        if let volumePercent = spotifyVolumePercent(fromNormalizedControlText: normalized) {
            return OpenClickySpotifyPlaybackControlAction(.volumeSet, volumePercent: volumePercent)
        }
        switch normalized {
        case "play", "resume", "start playing", "keep playing",
             "play music", "play some music", "play something", "play anything",
             "put on music", "put some music on", "put anything on":
            return OpenClickySpotifyPlaybackControlAction(.play)
        case "pause", "stop", "stop playing":
            return OpenClickySpotifyPlaybackControlAction(.pause)
        case "play pause", "playpause", "toggle playback":
            return OpenClickySpotifyPlaybackControlAction(.playPause)
        case "skip", "next", "next song", "next track":
            return OpenClickySpotifyPlaybackControlAction(.next)
        case "back", "go back", "previous", "previous song", "previous track", "last song", "last track":
            return OpenClickySpotifyPlaybackControlAction(.previous)
        case "shuffle", "shuffle on", "turn shuffle on", "enable shuffle", "shuffle music":
            return OpenClickySpotifyPlaybackControlAction(.shuffleOn)
        case "shuffle off", "turn shuffle off", "disable shuffle":
            return OpenClickySpotifyPlaybackControlAction(.shuffleOff)
        case "repeat", "repeat on", "repeat track", "repeat song", "repeat one", "turn repeat on", "enable repeat", "loop", "loop on":
            return OpenClickySpotifyPlaybackControlAction(.repeatOn)
        case "repeat off", "turn repeat off", "disable repeat", "loop off":
            return OpenClickySpotifyPlaybackControlAction(.repeatOff)
        case "volume up", "spotify volume up", "turn volume up", "turn spotify volume up", "increase volume", "increase spotify volume", "raise volume", "raise spotify volume", "turn it up", "louder", "make it louder":
            return OpenClickySpotifyPlaybackControlAction(.volumeUp)
        case "volume down", "spotify volume down", "turn volume down", "turn spotify volume down", "decrease volume", "decrease spotify volume", "lower volume", "lower spotify volume", "turn it down", "quieter", "make it quieter":
            return OpenClickySpotifyPlaybackControlAction(.volumeDown)
        case "mute", "mute volume", "mute spotify":
            return OpenClickySpotifyPlaybackControlAction(.volumeMute)
        default:
            return nil
        }
    }

    private static func spotifyVolumePercent(fromNormalizedControlText normalized: String) -> Int? {
        let patterns = [
            #"^(?:set\s+)?(?:spotify\s+)?volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#,
            #"^(?:turn\s+)?(?:spotify\s+)?volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#,
            #"^(?:set\s+)?(?:spotify\s+)?sound\s+volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            guard let match = regex.firstMatch(in: normalized, range: range),
                  let percentRange = Range(match.range(at: 1), in: normalized),
                  let value = Int(normalized[percentRange]) else {
                continue
            }
            return min(100, max(0, value))
        }
        return nil
    }

    private static func spotifySearchURL(for query: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        guard !encoded.isEmpty else { return nil }
        return URL(string: "spotify:search:\(encoded)")
    }

    private static func spotifySearchPlayExecutionMethod(for backend: OpenClickyComputerUseBackendID) -> String {
        switch backend {
        case .backgroundComputerUse:
            return "NSWorkspace.open_spotify_uri + BackgroundComputerUse /v1/press_key + AppleScript play retry + playback verification"
        case .nativeSwift:
            return "NSWorkspace.open_spotify_uri + OpenClickyNativeComputerUseController.pressKey + AppleScript play retry + playback verification"
        }
    }

    private static func cleanedCompositeActionPayload(_ rawPayload: String) -> String {
        var payload = rawPayload.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?"))
        payload = stripMatchingQuotes(from: payload)
        payload = payload.replacingOccurrences(
            of: #"(?i)\s+(?:please|for\s+me)$"#,
            with: "",
            options: .regularExpression
        )
        return payload.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?"))
    }

    private static func compositeAppActionAgentInstruction(from request: OpenClickyCompositeAppActionRequest) -> String {
        "Use OpenClicky's available app automation, installed skills/connectors, or selected computer-use path to complete this full app action. Open \(request.appName) if needed, then perform this action in \(request.appName): \(request.actionText). Do not report success after only opening the app. Original request: \(request.instruction)"
    }

    private static func localAppOpenRequest(from transcript: String) -> OpenClickyAppOpenRequest? {
        let trimmedTranscript = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !trimmedTranscript.isEmpty else { return nil }
        guard !isExplicitAgentRoutingCandidate(trimmedTranscript) else { return nil }
        guard compositeAppActionRequest(from: trimmedTranscript) == nil else { return nil }

        let pattern = #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+|you\s+)?(?:please\s+)?(?:(?:ask|tell)\s+(?:an?\s+|the\s+)?agent\s+to\s+)?(?:open|launch|start|switch\s+to)\s+(?:up\s+)?(.+?)(?:\s+for\s+me)?[\.\!\?]*\s*$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(
            in: trimmedTranscript,
            range: NSRange(trimmedTranscript.startIndex..<trimmedTranscript.endIndex, in: trimmedTranscript)
           ),
           let targetRange = Range(match.range(at: 1), in: trimmedTranscript) {
            let rawTarget = String(trimmedTranscript[targetRange])
            let cleanedTarget = cleanedApplicationOpenTarget(rawTarget)
            let normalizedTarget = normalizedApplicationName(from: cleanedTarget)
            guard !normalizedTarget.isEmpty,
                  !isReservedAgentOpenTarget(cleanedTarget),
                  !isLocalAppOpenPlaceholder(normalizedTarget),
                  !isLikelyFileOrFolderOpenTarget(cleanedTarget),
                  !isLikelyWebOpenTarget(cleanedTarget) else {
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
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        return bareLocalAppOpenRequest(fromNormalizedCandidate: candidate)
    }

    private static func bareLocalAppOpenRequest(fromNormalizedCandidate candidate: String) -> OpenClickyAppOpenRequest? {
        let rawTarget = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
        guard !rawTarget.isEmpty,
              !isExplicitAgentRoutingCandidate(rawTarget),
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
            "Ghostty",
            "Finder",
            "System Settings",
            "Mail",
            "Messages",
            "Notes",
            "Reminders",
            "Calendar",
            "Slack",
            "Spotify",
            "Cursor",
            "GitHub Desktop",
            "Codex":
            return true
        default:
            return false
        }
    }

    private static func reminderAddRequest(from transcript: String) -> OpenClickyReminderAddRequest? {
        guard logEvidenceAnalysisInstruction(from: transcript) == nil else { return nil }

        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let normalizedCandidate = SpokenText.normalizedSpokenCommandText(candidate)
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
        guard logEvidenceAnalysisInstruction(from: transcript) == nil else { return nil }

        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let normalizedCandidate = SpokenText.normalizedSpokenCommandText(candidate)
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
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let normalizedCandidate = SpokenText.normalizedSpokenCommandText(candidate)
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
        let trimmedTranscript = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !trimmedTranscript.isEmpty else { return nil }

        let normalizedTranscript = trimmedTranscript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard Self.containsFolderOpenVerb(normalizedTranscript),
              !Self.isBlockedFolderOpenShortcutContext(normalizedTranscript) else {
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
        let commandPattern = #"^(?:(?:can|could|would|will)\s+you\s+|you\s+|please\s+|now\s+)*(?:open|show|reveal|switch\s+to|bring\s+up|pull\s+up|go\s+into|go\s+in|go\s+to|navigate\s+to|inside)\b"#
        return normalizedTranscript.range(of: commandPattern, options: .regularExpression) != nil
    }

    private static func isBlockedFolderOpenShortcutContext(_ normalizedTranscript: String) -> Bool {
        // Structural only: questions, planning verbs, and "take a look" review
        // language must not become Finder opens. Avoid product-specific phrase
        // denylists that only cover today's transcripts.
        let planningOrQuestionPattern = #"^(?:(?:can|could|would|will)\s+you\s+|please\s+)?(?:look\s+into|take\s+a\s+look(?:\s+at)?|research|investigate|propose|design|plan|think\s+about|tell\s+me|explain|is|are|was|were|do|does|did|what|where|why|how)\b"#
        return normalizedTranscript.range(of: planningOrQuestionPattern, options: .regularExpression) != nil
    }

    private static func relativeFolderOpenRequest(
        from transcript: String,
        baseURL: URL,
        fileManager: FileManager = .default
    ) -> OpenClickyFolderOpenRequest? {
        let trimmedTranscript = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !trimmedTranscript.isEmpty else { return nil }

        let normalizedTranscript = normalizedFolderCommandText(trimmedTranscript)
        guard containsFolderOpenVerb(normalizedTranscript),
              !isBlockedFolderOpenShortcutContext(normalizedTranscript) else { return nil }

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

    private struct SmartAgentRouteDecision {
        let instruction: String
        let acknowledgement: String
        let reason: String
        let confidence: Double
    }

    private static func parallelAgentInstructions(from instruction: String) -> [String] {
        let cleanedInstruction = SpokenText.cleanedAgentTaskInstruction(instruction)
        guard !cleanedInstruction.isEmpty else { return [] }
        guard shouldSplitAgentInstruction(cleanedInstruction) else { return [cleanedInstruction] }

        let pieces = splitAgentInstructionClauses(cleanedInstruction)
            .map(SpokenText.cleanedAgentTaskInstruction)
            .filter { !$0.isEmpty && !isAgentTaskPlaceholderInstruction($0) }

        guard pieces.count >= 2 else { return [cleanedInstruction] }
        guard pieces.allSatisfy({ isLikelySpecificAgentInstruction($0) || hasAgentWorkVerbAndArtifact($0) }) else {
            return [cleanedInstruction]
        }

        return Array(pieces.prefix(4))
    }

    private static func shouldSplitAgentInstruction(_ instruction: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(instruction)
        let explicitSplitPattern = #"\b(?:multiple|several|separate|parallel|independent)\s+(?:background\s+)?(?:agents?|tasks?|workstreams?)\b|\bsplit\b.{0,48}\b(?:agents?|tasks?|workstreams?)\b|\b(?:agents?|tasks?)\b.{0,48}\b(?:separately|in\s+parallel|side\s+by\s+side)\b"#
        if normalized.range(of: explicitSplitPattern, options: .regularExpression) != nil {
            return true
        }

        let enumeratedPattern = #"(?:^|[\n;,.]\s*)(?:first|second|third|fourth|1[.)]|2[.)]|3[.)]|4[.)])\b"#
        return instruction.range(of: enumeratedPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func splitAgentInstructionClauses(_ instruction: String) -> [String] {
        let markerPattern = #"(?i)(?:^|[\n;]\s+|\s+)(?:first(?:ly)?|second(?:ly)?|third(?:ly)?|fourth(?:ly)?|1[.)]|2[.)]|3[.)]|4[.)]|also|separately|another\s+agent\s+(?:to|for)|and\s+another\s+(?:agent\s+)?(?:to|for))[:,]?\s+"#
        let markerRegex = try? NSRegularExpression(pattern: markerPattern)
        let fullRange = NSRange(instruction.startIndex..<instruction.endIndex, in: instruction)
        let matches = markerRegex?.matches(in: instruction, range: fullRange) ?? []
        guard matches.count >= 2 else {
            return instruction
                .components(separatedBy: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        var pieces: [String] = []
        for (index, match) in matches.enumerated() {
            guard let start = Range(match.range, in: instruction)?.upperBound else { continue }
            let end: String.Index
            if index + 1 < matches.count,
               let nextStart = Range(matches[index + 1].range, in: instruction)?.lowerBound {
                end = nextStart
            } else {
                end = instruction.endIndex
            }
            pieces.append(String(instruction[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return pieces
    }

    private static func shouldDeferLiveComputerUseForAgentRoute(_ transcript: String) -> Bool {
        isAgentRoutingCandidate(transcript)
    }

    private static func isAgentRoutingCandidate(_ transcript: String) -> Bool {
        isExplicitAgentRoutingCandidate(transcript)
            || implicitAgentTaskInstruction(from: transcript) != nil
    }

    private static func isExplicitAgentRoutingCandidate(_ transcript: String) -> Bool {
        explicitNewTaskInstruction(from: transcript) != nil
            || isIncompleteExplicitNewTaskRequest(from: transcript)
            || agentTaskCreationInstruction(from: transcript) != nil
            || isIncompleteAgentTaskCreationRequest(from: transcript)
            || clickyAgentInstruction(from: transcript) != nil
            || permissiveAgentInstruction(from: transcript) != nil
            || isReferentialAgentWorkFollowUp(transcript)
    }

    static func implicitAgentTaskInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedAgentTaskInstruction(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard SpokenText.wordCount(in: normalized) >= 3 else { return nil }
        if let logInstruction = logEvidenceAnalysisInstruction(from: candidate) {
            return logInstruction
        }
        guard !isRawTransportDiagnosticEvent(candidate) else { return nil }
        guard !isMetaAgentRoutingQuestion(candidate) else { return nil }
        guard !isVoiceRouteCapabilityQuestion(candidate) else { return nil }
        guard !isGenericWebSearchCapabilityQuestion(candidate) else { return nil }
        guard !isConversationalPreferenceOrDesignReflection(candidate) else { return nil }
        guard !isLikelyPureConversation(candidate) else { return nil }
        guard !isInstantVoiceScreenContextRequest(candidate) else { return nil }
        guard !VoiceRouter.isSensitiveOrDestructiveAgentTaskRequest(normalized) else { return nil }

        let hasAction = VoiceRouter.containsAgentWorkAction(normalized)
        let hasCodingImplementationCue = containsCodingImplementationCue(candidate)
        let hasToolContext = isLikelyAgentToolWorkInstruction(candidate)
            || hasAgentWorkVerbAndArtifact(candidate)
            || VoiceRouter.containsDurableWorkTarget(normalized)
            || hasCodingImplementationCue
        let asksForFreshInfo = VoiceRouter.containsFreshResearchRequest(normalized)

        guard (hasAction && hasToolContext) || hasCodingImplementationCue || asksForFreshInfo else { return nil }
        guard !isLikelyDirectLocalOnlyRequest(candidate) else { return nil }

        return SpokenText.cleanedAgentTaskInstruction(candidate)
    }

    private static func logEvidenceAnalysisInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let logEvidenceSignals = [
            "[OpenClickyLog]",
            #""event":"#,
            #""lane":"#,
            "openclicky.",
            "native_cua.",
            "voice.realtime",
            "codex.rpc",
            "messages-",
            "Transcription: using",
            "requestID",
            "executionMethod",
            "route"
        ]
        let hasLogEvidence = logEvidenceSignals.contains {
            candidate.localizedCaseInsensitiveContains($0)
        }
        guard hasLogEvidence else { return nil }

        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        let intentPattern = #"\b(?:logs?|issue|issues|error|errors|why|fix|analyse|analyze|review|inspect|look\s+at|look\s+into|find\s+out|debug|diagnose|what\s+happened|what'?s\s+wrong|make\s+a\s+note|note\s+that)\b"#
        let hasAnalysisIntent = normalized.range(of: intentPattern, options: .regularExpression) != nil

        guard hasAnalysisIntent || candidate.count >= 500 else { return nil }

        return """
        Analyze the pasted OpenClicky logs as evidence, identify the issue, and make the smallest safe fix or durable note needed. Do not route the pasted log text as a direct local app command. Original request and log evidence: \(candidate)
        """
    }

    private static func smartAgentRouteDecision(from transcript: String) -> SmartAgentRouteDecision? {
        let candidate = SpokenText.normalizedAgentTaskInstruction(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard SpokenText.wordCount(in: normalized) >= 3 else { return nil }
        guard !isRawTransportDiagnosticEvent(candidate) else { return nil }
        guard !isMetaAgentRoutingQuestion(candidate) else { return nil }
        guard !isVoiceRouteCapabilityQuestion(candidate) else { return nil }
        guard !isGenericWebSearchCapabilityQuestion(candidate) else { return nil }
        guard !VoiceRouter.isSensitiveOrDestructiveAgentTaskRequest(normalized) else { return nil }
        guard !isLikelyDirectLocalOnlyRequest(candidate) else { return nil }

        if let filesystemInstruction = implicitFilesystemTaskInstruction(from: candidate) {
            return SmartAgentRouteDecision(
                instruction: filesystemInstruction,
                acknowledgement: filesystemTaskAcknowledgement(from: candidate),
                reason: "local_filesystem_task",
                confidence: 0.94
            )
        }

        guard let instruction = naturalBackgroundTaskInstruction(from: candidate) else {
            return nil
        }

        return SmartAgentRouteDecision(
            instruction: instruction,
            acknowledgement: "i’ll take care of that in the background.",
            reason: "natural_background_task",
            confidence: 0.86
        )
    }

    private static func naturalBackgroundTaskInstruction(from transcript: String) -> String? {
        let candidate = cleanedNaturalBackgroundInstruction(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard SpokenText.wordCount(in: normalized) >= 3 else { return nil }
        guard VoiceRouter.containsNaturalBackgroundWorkCue(normalized) else { return nil }

        let hasWorkTarget = VoiceRouter.containsDurableWorkTarget(normalized)
            || VoiceRouter.containsReferentialWorkTarget(normalized)
            || isLikelyAgentToolWorkInstruction(candidate)
            || hasAgentWorkVerbAndArtifact(candidate)
            || VoiceRouter.containsFreshResearchRequest(normalized)
        guard hasWorkTarget else { return nil }
        guard !isAgentTaskPlaceholderInstruction(candidate) else { return nil }

        return candidate
    }

    private static func cleanedNaturalBackgroundInstruction(from transcript: String) -> String {
        var instruction = SpokenText.cleanedAgentTaskInstruction(SpokenText.normalizedAgentTaskInstruction(from: transcript))
        let removablePrefixes = [
            #"(?i)^\s*(?:can|could|would|will)\s+we\s+"#,
            #"(?i)^\s*(?:i\s+)?(?:want|need)\s+(?:you\s+)?to\s+"#,
            #"(?i)^\s*let'?s\s+"#
        ]
        for pattern in removablePrefixes {
            instruction = instruction.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return SpokenText.cleanedAgentTaskInstruction(instruction)
    }


    static func hybridAgentTaskInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard SpokenText.wordCount(in: normalized) >= 5 else { return nil }
        guard !isRawTransportDiagnosticEvent(candidate) else { return nil }
        guard !isMetaAgentRoutingQuestion(candidate) else { return nil }
        guard !VoiceRouter.isSensitiveOrDestructiveAgentTaskRequest(normalized) else { return nil }
        guard !isLikelyDirectLocalOnlyRequest(candidate) else { return nil }
        guard VoiceRouter.containsHybridForegroundCue(normalized) else { return nil }
        guard VoiceRouter.containsHybridBackgroundCue(normalized) else { return nil }

        let explicitInstruction = explicitAgentRouteInstruction(from: candidate)
            .map { SpokenText.normalizedAgentTaskInstruction(from: $0) }
            .map(SpokenText.cleanedAgentTaskInstruction)
        let implicitInstruction = implicitAgentTaskInstruction(from: candidate)
        let instruction = explicitInstruction ?? implicitInstruction ?? SpokenText.cleanedAgentTaskInstruction(candidate)
        guard !instruction.isEmpty,
              !isAgentTaskPlaceholderInstruction(instruction),
              isLikelySpecificAgentInstruction(instruction) || VoiceRouter.containsFreshResearchRequest(normalized) else {
            return nil
        }
        return instruction
    }

    private static func isRawTransportDiagnosticEvent(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let rawTransportPrefixes = [
            "/incoming]",
            "/outgoing]",
            "[incoming]",
            "[outgoing]"
        ]
        let hasRawTransportPrefix = rawTransportPrefixes.contains { prefix in
            trimmed.localizedCaseInsensitiveContains(prefix)
        }

        let rawCodexRPCSignals = [
            "codex.rpc.message",
            "codex.rpc.notification",
            "codex.rpc.request",
            #""method":"account/rateLimits/updated""#,
            "account/rateLimits/updated"
        ]
        let hasRawCodexRPCSignal = rawCodexRPCSignals.contains { signal in
            trimmed.localizedCaseInsensitiveContains(signal)
        }
        let hasRPCSummaryPayload = trimmed.localizedCaseInsensitiveContains(#""method":"#)
            && trimmed.localizedCaseInsensitiveContains(#""paramsSummary""#)

        guard hasRawTransportPrefix || hasRawCodexRPCSignal || hasRPCSummaryPayload else { return false }

        let normalized = SpokenText.normalizedSpokenCommandText(trimmed)
        let userIntentSignals = [
            "check for errors",
            "check this error",
            "check these errors",
            "fix this error",
            "fix these errors",
            "fix this",
            "fix that",
            "fix it",
            "look at this",
            "look into this",
            "review this",
            "what is this",
            "whats this",
            "what's this",
            "see issue here",
            "see the issue here"
        ]
        return !userIntentSignals.contains { normalized.hasPrefix($0) }
    }

    static func shouldEscalateVoiceResponseToAgent(responseText: String, transcript: String) -> Bool {
        let normalizedTranscript = SpokenText.normalizedSpokenCommandText(transcript)
        let isAgentSuitableTask = isLocalFilesystemInspectionRequest(normalizedTranscript)
            || implicitAgentTaskInstruction(from: transcript) != nil
            || smartAgentRouteDecision(from: transcript) != nil
        guard isAgentSuitableTask else { return false }

        let normalizedResponse = SpokenText.normalizedSpokenCommandText(responseText)
        let filesystemRefusalPattern = #"\b(?:i\s+(?:do\s+not|don't|dont)\s+have\s+access|i\s+(?:can't|cannot)|unable\s+to|not\s+able\s+to)\b.{0,96}\b(?:file\s*system|files?|folders?|desktop|downloads?|documents?|browse|inspect|read)\b"#
        let agentRouteRefusalPatterns = [
            #"\bthat\s+needs\s+openclicky(?:'s)?\s+agent\s+route\b"#,
            #"\bit\s+did(?:n\s*'?t| not)\s+start\s+from\s+this\s+voice\s+turn\b"#,
            #"\bneeds\s+agent\s+mode\b"#,
            #"\bstart\s+an\s+agent\b"#
        ]
        if normalizedResponse.range(of: filesystemRefusalPattern, options: .regularExpression) != nil {
            return true
        }
        return agentRouteRefusalPatterns.contains {
            normalizedResponse.range(of: $0, options: .regularExpression) != nil
        }
    }

    static func implicitFilesystemTaskInstruction(from transcript: String) -> String? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        guard SpokenText.wordCount(in: normalized) >= 3 else { return nil }
        guard isLocalFilesystemInspectionRequest(normalized) else { return nil }
        guard !isInstantVoiceScreenContextRequest(candidate) else { return nil }

        return """
        Inspect the relevant local files or folders for this request, then answer succinctly: \(candidate)
        """
    }

    static func filesystemTaskAcknowledgement(from transcript: String) -> String {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        if normalized.range(of: #"\bdesktop\b"#, options: .regularExpression) != nil {
            return "i'm checking your desktop now."
        }
        if normalized.range(of: #"\bdownloads?\b"#, options: .regularExpression) != nil {
            return "i'm checking your downloads now."
        }
        if normalized.range(of: #"\bdocuments?\b"#, options: .regularExpression) != nil {
            return "i'm checking your documents now."
        }
        return "i'm checking those files now."
    }

    private static func isLocalFilesystemInspectionRequest(_ normalized: String) -> Bool {
        let actionPattern = #"\b(?:what'?s\s+on|what\s+is\s+on|list|show|check|inspect|review|find|search|look\s+at|read|summari[sz]e)\b"#
        let filesystemTargetPattern = #"\b(?:desktop|downloads?|documents?|folder|folders|file|files|directory|directories)\b"#
        return normalized.range(of: actionPattern, options: .regularExpression) != nil
            && normalized.range(of: filesystemTargetPattern, options: .regularExpression) != nil
    }

    private static func isVoiceRouteCapabilityQuestion(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard !normalized.isEmpty else { return false }

        let routePattern = #"\b(?:voice\s+(?:route|lane|path)|realtime\s+(?:route|voice|path)|without\s+(?:starting\s+)?an?\s+agent|without\s+agent\s+mode|instead\s+of\s+(?:starting\s+)?an?\s+agent)\b"#
        guard normalized.range(of: routePattern, options: .regularExpression) != nil else { return false }

        let questionPattern = #"^(?:can|could|would|will)\s+you\b|^(?:can|could|would)\s+openclicky\b|^is\s+it\s+possible\b|^do\s+you\b|^does\s+openclicky\b"#
        return normalized.range(of: questionPattern, options: .regularExpression) != nil
    }

    private static func isGenericWebSearchCapabilityQuestion(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        let pattern = #"^(?:can|could|would|will)\s+you\s+(?:search\s+(?:the\s+)?web|browse\s+(?:the\s+)?web|google|look\s+things?\s+up|look\s+up\s+things?)$"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isConversationalPreferenceOrDesignReflection(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard !normalized.isEmpty else { return true }

        let conversationStarters = [
            "i like",
            "i love",
            "i dont like",
            "i don t like",
            "i don't like",
            "i want",
            "i only want",
            "i think",
            "i feel",
            "it feels",
            "it would be",
            "that would be",
            "would be",
            "could we",
            "can we",
            "could you talk",
            "can you talk",
            "lets talk",
            "let s talk",
            "let's talk"
        ]
        guard conversationStarters.contains(where: { normalized.hasPrefix($0) }) else {
            return false
        }

        let explicitExecutionPattern = #"\b(?:agent|start\s+(?:an?\s+)?agent|spin\s+up|get\s+(?:an?\s+)?agent|implement|patch|change\s+the\s+code|edit\s+the\s+file|write\s+the\s+file|make\s+the\s+change|do\s+the\s+change|fix\s+it\s+now)\b"#
        let naturalWorkPattern = #"\b(?:make\s+sure|ensure|verify|validate|look\s+into|sort\s+out|deal\s+with|take\s+care\s+of|get\s+(?:this|that|it|.+?)\s+working|wire\s+(?:up|in)|hook\s+(?:up|in)|diagnose|investigate)\b"#
        return !containsCodingImplementationCue(transcript)
            && normalized.range(of: explicitExecutionPattern, options: .regularExpression) == nil
            && normalized.range(of: naturalWorkPattern, options: .regularExpression) == nil
    }

    private static func isLikelyPureConversation(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard !normalized.isEmpty else { return true }

        let conversationPrefixes = [
            "what is", "what are", "what does", "what do", "why", "how do", "how does",
            "how would", "can you explain", "explain", "tell me about", "walk me through",
            "do you think", "should i", "is it", "are we", "am i"
        ]
        let hasConversationPrefix = conversationPrefixes.contains { normalized.hasPrefix($0) }
        guard hasConversationPrefix else { return false }

        return !VoiceRouter.containsAgentWorkAction(normalized)
            && !isLikelyAgentToolWorkInstruction(transcript)
            && !VoiceRouter.containsDurableWorkTarget(normalized)
            && !VoiceRouter.containsFreshResearchRequest(normalized)
    }

    private static func isInstantVoiceScreenContextRequest(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard !normalized.isEmpty else { return false }

        let visualReferencePatterns = [
            #"\b(?:look at|take a look at|have a look at|check|inspect|review|summari[sz]e|describe)\s+(?:this|that|it|here|my screen|the screen|what'?s on screen|the current screen|the visible screen|the current page|this page|that page|this tab|that tab|the browser|this window|that window)\b"#,
            #"\b(?:what do you think|what'?s this|what is this|what'?s that|what is that|can you see|do you see|are you seeing)\b"#
        ]
        let hasVisualReference = visualReferencePatterns.contains { pattern in
            normalized.range(of: pattern, options: .regularExpression) != nil
        }
        guard hasVisualReference else { return false }

        let longRunningSignals = #"\b(?:background|agent|task|later|keep working|while i|overnight|long|implement|patch|edit|write|code|repo|repository|github|issue|pull request|pr|file|files|folder|folders|desktop|downloads|email|gmail|calendar|research|browse|latest|web search|look up)\b"#
        return normalized.range(of: longRunningSignals, options: .regularExpression) == nil
    }

    private static func containsCodingImplementationCue(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        guard SpokenText.wordCount(in: normalized) >= 3 else { return false }

        let conceptualQuestionPattern = #"^(?:what|why|how\s+(?:do|does|would|should)|can\s+you\s+explain|explain|tell\s+me\s+about)\b"#
        if normalized.range(of: conceptualQuestionPattern, options: .regularExpression) != nil,
           normalized.range(of: #"\b(?:make\s+the\s+change|do\s+the\s+change|change\s+the\s+code|edit\s+the\s+file|patch|implement|apply|fix\s+it\s+now)\b"#, options: .regularExpression) == nil {
            return false
        }

        let implementationVerbPattern = #"\b(?:fix|patch|implement|change|update|edit|modify|add|remove|wire|hook|route|make|build|repair|polish|improve)\b"#
        let codeTargetPattern = #"\b(?:openclicky|clicky|code|codebase|repo|repository|swift|xcode|companionmanager|app|routing|route|voice\s+(?:path|lane|route)|agent\s+(?:mode|routing|route)|computer\s+use)\b"#
        let changeRequestPattern = #"\b(?:asking\s+for|ask\s+for|requested?|need|needs|want|wants)\b.{0,80}\b(?:changes?|fixes?|code\s+fixes?|code\s+changes?)\b"#

        let hasImplementationVerb = normalized.range(of: implementationVerbPattern, options: .regularExpression) != nil
        let hasCodeTarget = normalized.range(of: codeTargetPattern, options: .regularExpression) != nil
        let hasChangeRequest = normalized.range(of: changeRequestPattern, options: .regularExpression) != nil

        return (hasImplementationVerb && hasCodeTarget) || hasChangeRequest
    }

    private static func isLikelyDirectLocalOnlyRequest(_ transcript: String) -> Bool {
        nativeTypeRequest(from: transcript) != nil
            || nativeKeyPressRequest(from: transcript) != nil
            || nativeClickRequest(from: transcript) != nil
            || localAppOpenRequest(from: transcript) != nil
            || localFolderOpenRequest(from: transcript) != nil
            || webOpenRequest(from: transcript) != nil
            || isIncompleteLocalAppOpenRequest(from: transcript)
    }

    private static func deferredLiveAgentRouteInstruction(
        partialTranscript: String,
        finalTranscript: String
    ) -> String? {
        guard isAgentRoutingCandidate(partialTranscript) else { return nil }

        let normalizedFinal = SpokenText.normalizedSpokenCommandText(finalTranscript)
        guard !normalizedFinal.isEmpty else { return nil }

        let cancellationSignals = [
            "never mind",
            "nevermind",
            "ignore that",
            "forget that",
            "cancel that",
            "stop that"
        ]
        if cancellationSignals.contains(where: { normalizedFinal.contains($0) }) {
            return nil
        }

        let partialInstruction = explicitAgentRouteInstruction(from: partialTranscript)
            .map { SpokenText.normalizedAgentTaskInstruction(from: $0) }
            .map(SpokenText.cleanedAgentTaskInstruction)
        let finalInstruction = SpokenText.normalizedAgentTaskInstruction(from: finalTranscript)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))

        let finalLooksRecoverable = isLikelyAgentFollowUpPhrasing(finalTranscript)
            || isLikelyAgentToolWorkInstruction(finalTranscript)
            || hasAgentWorkVerbAndArtifact(finalTranscript)

        if finalLooksRecoverable,
           !finalInstruction.isEmpty,
           !isAgentTaskPlaceholderInstruction(finalInstruction),
           isLikelySpecificAgentInstruction(finalInstruction) {
            return finalInstruction
        }

        // If Apple Speech's final result drops the wake phrase or rewrites the
        // beginning of a long utterance, keep the last live partial that was
        // confidently classified as an agent request. This is the path for
        // "Clicky agent ..." being heard live as "click the agent ..." while
        // the final transcript only contains the trailing correction/noise.
        if let partialInstruction,
           !partialInstruction.isEmpty,
           !isAgentTaskPlaceholderInstruction(partialInstruction),
           isLikelySpecificAgentInstruction(partialInstruction) {
            return partialInstruction
        }

        return finalLooksRecoverable && !finalInstruction.isEmpty ? finalInstruction : nil
    }

    private static func explicitAgentRouteInstruction(from transcript: String) -> String? {
        if let instruction = explicitNewTaskInstruction(from: transcript) { return instruction }
        if let instruction = agentTaskCreationInstruction(from: transcript) { return instruction }
        if let instruction = clickyAgentInstruction(from: transcript) { return instruction }
        if let instruction = permissiveAgentInstruction(from: transcript) { return instruction }
        return nil
    }

    private static func hasAgentWorkVerbAndArtifact(_ transcript: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(transcript)
        let workVerbPattern = #"\b(?:create|make|build|update|change|edit|fix|design|redesign|open|show|preview|pull\s+up|find|save|export|write|review|test|run|stop|ensure|verify|validate|diagnose|investigate|repair|polish|improve|finish|wire|route)\b"#
        let artifactPattern = #"\b(?:form|page|site|website|app|file|document|report|code|repo|repository|github|issue|issues|pull\s+request|pr|folder|version|style|design|panel|overlay|status|progress|comments|logs?|tests?|thinking|calls|ui|volume|slider|control|voice|realtime|computer\s+use|tool|tools|tooling|model|models|routing|route|background|agent\s+mode)\b"#
        return normalized.range(of: workVerbPattern, options: .regularExpression) != nil
            && normalized.range(of: artifactPattern, options: .regularExpression) != nil
    }

    private static func isLikelySpecificAgentInstruction(_ instruction: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(instruction)
        guard SpokenText.wordCount(in: normalized) >= 3 else { return false }
        return isLikelyAgentToolWorkInstruction(instruction)
            || isReferentialAgentWorkFollowUp(instruction)
            || hasAgentWorkVerbAndArtifact(instruction)
            || normalized.contains("overlay")
            || normalized.contains("panel")
            || normalized.contains("progress")
            || normalized.contains("status")
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
            "click",
            "select",
            "choose",
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
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        let pattern = #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:(?:ask|tell)\s+(?:an?\s+|the\s+)?agent\s+to\s+)?(?:open|launch|start|switch\s+to)(?:\s+up)?[\s\.\!\?]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return regex.firstMatch(in: candidate, range: range) != nil
    }


    private static func cleanedApplicationOpenTarget(_ rawTarget: String) -> String {
        var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingActionPatterns = [
            #"(?i)\s+(?:and|then)\s+(?:(?:can|could|would|will)\s+you\s+)?(?:play|search|find|look\s+up|type|write|enter|press|hit|click|tap|select|choose|go\s+to|navigate\s+to|browse\s+to|visit)\b.*$"#,
            #"(?i)\s+to\s+(?:(?:can|could|would|will)\s+you\s+)?(?:play|search|find|look\s+up|type|write|enter|press|hit|click|tap|select|choose)\b.*$"#
        ]
        for pattern in trailingActionPatterns {
            target = target.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return target.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-–—…"))
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
        case "ghostty", "ghost tty", "ghostie", "ghosty":
            return "Ghostty"
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
        case "spotify":
            return "Spotify"
        case "cursor":
            return "Cursor"
        case "codex":
            return "Codex"
        case "github desktop",
             "git hub desktop",
             "gate hub desktop",
             "get hub desktop",
             "github",
             "git hub",
             "gate hub",
             "get hub":
            return "GitHub Desktop"
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
        let normalized = SpokenText.normalizedSpokenCommandText(value)
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
        let normalized = SpokenText.normalizedSpokenCommandText(value)
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
        let spokenNormalized = SpokenText.normalizedSpokenCommandText(value)
        return ["", "my", "the", "a", "an", "it", "that", "this"].contains(normalized)
            || ["", "my", "the", "a", "an", "it", "that", "this"].contains(spokenNormalized)
    }

    private static func isReservedAgentOpenTarget(_ value: String) -> Bool {
        let normalized = SpokenText.normalizedSpokenCommandText(value)
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

        let normalized = SpokenText.normalizedSpokenCommandText(raw)
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
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:type|write|enter|input)\s+(?:into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field|text\s+field)\s+(.+?)[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:type|write|enter|input)\s+(.+?)\s+(?:into|in)\s+(?:the\s+)?(?:[a-z0-9\s-]+?\s+)?(?:input|pin|code|box|search|field|text\s+field|browser|page|window|app)[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:type|write|enter|input)\s+(.+?)(?:\s+(?:into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field|text\s+field))?[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?paste\s+(?:into|in)\s+(?:the\s+)?(?:focused\s+)?(?:window|app|field|text\s+field)\s+(.+?)[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?paste\s+(.+?)\s+(?:into|in)\s+(?:the\s+)?(?:[a-z0-9\s-]+?\s+)?(?:input|pin|code|box|search|field|text\s+field|browser|page|window|app)[\.\!\?]*\s*$"#,
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

    private static func nativeClickRequest(from transcript: String) -> OpenClickyNativeClickRequest? {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        guard !candidate.isEmpty else { return nil }

        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        let referentialTargets: Set<String> = [
            "it",
            "that",
            "this",
            "that one",
            "this one",
            "the thing",
            "the button",
            "the link",
            "the tile"
        ]

        let patterns = [
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:click|tap|select|choose)\s+(?:on\s+)?(.+?)[\.\!\?]*\s*$"#,
            #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:open|play)\s+(?:the\s+)?(.+?)\s+(?:tile|button|link|item|profile|show|movie|episode)[\.\!\?]*\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let targetRange = Range(match.range(at: 1), in: candidate) else { continue }
            let target = String(candidate[targetRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?"))
            let targetNormalized = SpokenText.normalizedSpokenCommandText(target)
            let isTapKeyCommand = normalized.hasPrefix("tap ")
                && [
                    "escape", "esc", "enter", "return", "tab", "space", "spacebar",
                    "delete", "backspace", "left", "right", "up", "down",
                    "left arrow", "right arrow", "up arrow", "down arrow"
                ].contains(targetNormalized)
            if isTapKeyCommand { return nil }
            guard !target.isEmpty,
                  !["something", "somewhere", "anything"].contains(targetNormalized) else { return nil }

            return OpenClickyNativeClickRequest(
                targetDescription: candidate,
                targetPhrase: referentialTargets.contains(targetNormalized) ? nil : target,
                prefersLastPointedElement: referentialTargets.contains(targetNormalized)
            )
        }

        if [
            "can you click it",
            "could you click it",
            "click it",
            "tap it",
            "select it",
            "choose it",
            "click that",
            "tap that",
            "select that",
            "choose that"
        ].contains(normalized) {
            return OpenClickyNativeClickRequest(
                targetDescription: candidate,
                targetPhrase: nil,
                prefersLastPointedElement: true
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
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
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

            let rawKeySpec = cleanedNativeKeySpecTargetContext(String(candidate[keyRange]))
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

    private static func cleanedNativeKeySpecTargetContext(_ rawKeySpec: String) -> String {
        rawKeySpec
            .replacingOccurrences(
                of: #"(?i)\s+(?:in|inside|within|to)\s+(?:the\s+)?[a-z0-9][a-z0-9\s&'’.-]*(?:\s+(?:app|application|window))?\s*$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            case "the", "key", "button":
                break
            default:
                keyTokens.append(token)
            }
        }

        let key = keyTokens.joined()
        guard !key.isEmpty, !["key", "button"].contains(key) else { return nil }
        let normalizedKey = normalizedNativeKeyName(key)
        guard isSupportedNativeKeyName(normalizedKey) else { return nil }
        return (key: normalizedKey, modifiers: modifiers)
    }

    private static func normalizedNativeKeyName(_ key: String) -> String {
        switch key {
        case "play", "pause", "playpause", "playorpause":
            return "space"
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

    private static func isSupportedNativeKeyName(_ key: String) -> Bool {
        if key.count == 1,
           let scalar = key.unicodeScalars.first,
           CharacterSet.alphanumerics.contains(scalar) {
            return true
        }

        let supportedNames: Set<String> = [
            "return", "enter",
            "tab",
            "space",
            "delete", "backspace",
            "forwarddelete", "del",
            "escape", "esc",
            "left", "leftarrow",
            "right", "rightarrow",
            "down", "downarrow",
            "up", "uparrow",
            "home", "end",
            "pageup", "pagedown",
            "f1", "f2", "f3", "f4",
            "f5", "f6", "f7", "f8",
            "f9", "f10", "f11", "f12"
        ]
        return supportedNames.contains(key)
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
        case "Ghostty":
            return ["com.mitchellh.ghostty"]
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
        case "Spotify":
            return ["com.spotify.client"]
        case "GitHub Desktop":
            return ["com.github.GitHubClient"]
        default:
            return []
        }
    }

    private static func canResolveApplicationWithoutShellOpen(named appName: String) -> Bool {
        resolvedApplicationURL(named: appName) != nil
    }

    private static func activateRunningApplication(named appName: String) {
        for bundleIdentifier in applicationBundleIdentifiers(for: appName) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }

    private static func applicationOwner(_ owner: String, matches appName: String) -> Bool {
        let normalizedOwner = normalizedApplicationName(from: owner)
        if normalizedOwner == appName { return true }
        let foldedOwner = owner.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        let foldedApp = appName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        return foldedOwner == foldedApp
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

    private func startVoiceAgentTaskPlan(
        instruction: String,
        acknowledgement: String? = nil,
        route: String = "agent.start",
        speakAcknowledgement: Bool = true,
        interruptVoiceResponse: Bool = false,
        voiceContextUserTranscript: String? = nil
    ) {
        let effectiveSpeakAcknowledgement: Bool
        if suppressNextVoiceAgentStartAcknowledgement {
            effectiveSpeakAcknowledgement = false
            suppressNextVoiceAgentStartAcknowledgement = false
        } else {
            effectiveSpeakAcknowledgement = speakAcknowledgement
        }

        let plannedInstructions = Self.parallelAgentInstructions(from: instruction)
        guard plannedInstructions.count > 1 else {
            startVoiceAgentTask(
                instruction: instruction,
                acknowledgement: acknowledgement,
                route: route,
                speakAcknowledgement: effectiveSpeakAcknowledgement,
                interruptVoiceResponse: interruptVoiceResponse,
                voiceContextUserTranscript: voiceContextUserTranscript
            )
            return
        }

        let splitAcknowledgement = acknowledgement ?? "i’ll split that into \(plannedInstructions.count) background agents."
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.split_route",
            fields: [
                "originalInstruction": instruction,
                "taskCount": plannedInstructions.count,
                "executor": "agent_mode",
                "route": "\(route).split",
                "requestID": activeRequestTiming?.requestID ?? "none"
            ]
        )

        for (index, plannedInstruction) in plannedInstructions.enumerated() {
            startVoiceAgentTask(
                instruction: plannedInstruction,
                acknowledgement: index == 0 ? splitAcknowledgement : nil,
                route: "\(route).split",
                speakAcknowledgement: effectiveSpeakAcknowledgement && index == 0,
                interruptVoiceResponse: interruptVoiceResponse && index == 0,
                voiceContextUserTranscript: voiceContextUserTranscript ?? instruction
            )
        }
    }

    private func startVoiceAgentTask(
        instruction: String,
        acknowledgement: String? = nil,
        route: String = "agent.start",
        speakAcknowledgement: Bool = true,
        interruptVoiceResponse: Bool = false,
        voiceContextUserTranscript: String? = nil
    ) {
        // Note: when the user explicitly said "agent" we do NOT route
        // through `handleDirectComputerUseRequest` here — that path
        // tries to hijack the request into Background Computer Use /
        // native CUA and fails silently when the BCU runtime isn't
        // running. Agent invocation always means "delegate to the
        // coder agent". Inline shortcuts (open-app / type / press /
        // open-folder) are still handled in `startExplicitAgentTaskIfRequested`
        // before we reach this function.
        var instruction = instruction
        if Self.isRawTransportDiagnosticEvent(instruction) {
            // A prompt that carries log evidence plus user intent is a
            // real task ("find out why these logs..."), not transport echo
            // — refuse only when no analysis instruction can be derived.
            guard let logInstruction = Self.logEvidenceAnalysisInstruction(from: instruction) else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.raw_transport_event_ignored",
                    fields: [
                        "source": "voice_agent_task",
                        "instructionPreview": Self.voiceArchiveSnippet(instruction, limit: 240),
                        "requestID": activeRequestTiming?.requestID ?? "none"
                    ]
                )
                speakShortSystemResponse("that looks like an internal OpenClicky runtime event, not a task.")
                return
            }
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.log_evidence_rescued",
                fields: [
                    "source": "voice_agent_task",
                    "instructionPreview": Self.voiceArchiveSnippet(instruction, limit: 240),
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            instruction = logInstruction
        }

        let startFingerprint = Self.voiceAgentStartFingerprint(
            instruction: instruction,
            route: route
        )
        let now = Date()
        if lastVoiceAgentStartFingerprint == startFingerprint,
           let previousStart = lastVoiceAgentStartAt,
           now.timeIntervalSince(previousStart) <= Self.voiceAgentStartDuplicateTTL {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.duplicate_start_suppressed",
                fields: [
                    "route": route,
                    "instruction": instruction,
                    "ageMs": Int(now.timeIntervalSince(previousStart) * 1000),
                    "requestID": activeRequestTiming?.requestID ?? "none"
                ]
            )
            return
        }
        lastVoiceAgentStartFingerprint = startFingerprint
        lastVoiceAgentStartAt = now

        let timing = activeRequestTiming
        let executionStartedAt = markRequestExecutionStarted(
            route: route,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "instructionLength": instruction.count
            ]
        )
        if interruptVoiceResponse && !voiceTTSClient.isPlaying && !openAIRealtimeSpeechClient.isPlaying && !deepgramVoiceAgentClient.isPlaying {
            interruptCurrentVoiceResponse()
        }
        ensureCursorOverlayVisibleForAgentTask()

        let dockItemID = UUID()
        // Keep the spoken handoff intentionally generic. The dock still gets
        // the compact task title, but voice should not read the task name
        // back when launching an agent.
        let acknowledgement = acknowledgement ?? Self.acknowledgementForAgentInstruction(instruction)
        let dockScreen = agentDockTargetScreen()
        let voiceContextTranscript = voiceContextUserTranscript?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceContextUserTranscript = (voiceContextTranscript?.isEmpty == false)
            ? voiceContextTranscript!
            : instruction

        if speakAcknowledgement {
            latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: acknowledgement,
                contextTitle: "OpenClicky Agent"
            )
            rememberVoiceExchange(
                userTranscript: voiceContextUserTranscript,
                assistantResponse: acknowledgement,
                reason: "agent_start"
            )
        } else {
            rememberSilentAgentHandoff(
                userTranscript: voiceContextUserTranscript,
                instruction: instruction,
                reason: "agent_start_silent"
            )
        }

        // Spawn the dock representation while the live OpenClicky buddy makes
        // a short handoff flight to the corner and then returns to the user's
        // cursor, so the task start feels intentional without leaving the
        // working position abandoned.
        clearDetectedElementLocation()

        Task { @MainActor in
            let accentTheme = Self.nextAgentDockAccentTheme(existingCount: codexAgentSessions.count)
            let agentSession = createAndSelectNewCodexAgentSession(
                title: Self.shortAgentInstructionSummary(instruction),
                accentTheme: accentTheme
            )
            if let timing {
                agentRequestTimingsBySessionID[agentSession.id] = timing
            }
            lastVoiceAgentStartSessionID = agentSession.id
            agentExecutionStartDatesBySessionID[agentSession.id] = executionStartedAt
            let dockItem = ClickyAgentDockItem(
                id: dockItemID,
                sessionID: agentSession.id,
                title: Self.shortAgentInstructionSummary(instruction),
                userInstruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
                accentTheme: accentTheme,
                status: .starting,
                progressStageLabel: "Starting",
                progressStepText: acknowledgement,
                activityStatusLines: [acknowledgement],
                caption: acknowledgement,
                suggestedNextActions: [],
                createdAt: Date()
            )

            agentDockItems.append(dockItem)
            if agentDockItems.count > 6 {
                agentDockItems.removeFirst(agentDockItems.count - 6)
            }
            refreshAgentDockFollowBehavior()
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
                    "requestID": timing?.requestID ?? "none",
                    "spawnChoreography": "cursor_to_dock_and_back",
                    "spokenAcknowledgement": speakAcknowledgement
                ]
            )
            markRequestStageCompleted(
                route: route,
                stage: "agent_created",
                stageStartedAt: executionStartedAt,
                timing: timing,
                extra: [
                    "executor": "agent_mode",
                    "executionMethod": "createAndSelectNewCodexAgentSession",
                    "controller": "CompanionManager",
                    "model": agentSession.model,
                    "sessionID": agentSession.id.uuidString,
                    "title": agentSession.title,
                    "spawnChoreography": "cursor_to_dock_and_back",
                    "spokenAcknowledgement": speakAcknowledgement
                ]
            )

            if let dockScreen {
                agentDockWindowManager.show(
                    companionManager: self,
                    onScreen: dockScreen,
                    position: agentParkingPosition
                )
            } else {
                showAgentDockWindowNearCurrentScreen()
            }
            animateAgentSpawnProxyFromCursorToDock(accentTheme: accentTheme, dockItemID: dockItem.id)
            submitAgentPrompt(
                instruction,
                to: agentSession,
                includeScreenContext: Self.shouldAttachScreenContext(to: instruction)
                    || pendingCircleSelectStroke != nil,
                attachPendingVoiceCircle: true
            )

            guard speakAcknowledgement else { return }

            // Give the dock item a short settle window before speaking.
            // The cursor remains in place while the separate agent
            // representation appears in the dock.
            try? await Task.sleep(nanoseconds: 350_000_000)

            let responseTaskToken = UUID()
            currentResponseTaskToken = responseTaskToken
            currentResponseTask = Task { [acknowledgement, dockItemID] in
                defer { self.clearCurrentResponseTask(ifMatches: responseTaskToken) }
                guard await self.waitForSystemAnnouncementSlot(sessionID: nil, maxWaitSeconds: 8.0) else { return }
                await MainActor.run { self.voiceState = .processing }
                do {
                    try await voiceTTSClient.speakText(acknowledgement) {
                        Task { @MainActor in self.voiceState = .responding }
                    }
                } catch {
                    guard !Self.isExpectedCancellation(error) else { return }
                    ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                    print("ElevenLabs TTS error: \(error)")
                    await MainActor.run { self.speakResponseFailureFallback(error) }
                }

                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run {
                    self.clearAgentDockCaption(for: dockItemID)
                    if !Task.isCancelled {
                        self.voiceState = .idle
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
        }
    }

    private static func voiceAgentStartFingerprint(instruction: String, route: String) -> String {
        let normalizedInstruction = instruction
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRoute = route
            .replacingOccurrences(of: #"\.split$"#, with: "", options: .regularExpression)
        return "\(normalizedRoute)|\(normalizedInstruction)"
    }

    /// Returns a normalized fingerprint for deduplicating realtime voice
    /// route events: strips leading filler then fully normalizes.
    static func realtimeVoiceRouteFingerprint(_ transcript: String) -> String {
        SpokenText.normalizedSpokenCommandText(
            SpokenText.normalizedCommandCandidate(from: transcript)
        )
    }

    /// Returns true when two realtime-route fingerprints represent the same
    /// utterance: exact match OR one is a prefix of the other (minimum 3
    /// words in the shorter side, to avoid collapsing unrelated short commands).
    static func isDuplicateRealtimeVoiceRouteFingerprint(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        guard SpokenText.wordCount(in: shorter) >= 3 else { return false }
        return longer.hasPrefix(shorter)
    }

    func ensureCursorOverlayVisibleForAgentTask() {
        showCursorOverlayIfAvailable()
    }

    func showCursorOverlayIfAvailable() {
        guard hasAccessibilityPermission else { return }
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
            userInstruction: caption,
            accentTheme: Self.nextAgentDockAccentTheme(existingCount: agentDockItems.count),
            status: .done,
            progressStageLabel: "Completed",
            progressStepText: caption,
            activityStatusLines: [caption],
            caption: caption,
            suggestedNextActions: [],
            createdAt: Date()
        )
        agentDockItems.append(dockItem)
        if agentDockItems.count > 6 {
            agentDockItems.removeFirst(agentDockItems.count - 6)
        }
        refreshAgentDockFollowBehavior()
        scheduleWidgetSnapshotPublish()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self else { return }
            self.agentDockItems.removeAll { $0.id == dockItemID && $0.sessionID == nil }
            if self.agentDockItems.isEmpty {
                self.agentDockWindowManager.hide()
            }
            self.refreshAgentDockFollowBehavior()
            self.scheduleWidgetSnapshotPublish()
        }
    }

    private func cancelPendingAgentDockItemRemoval(for sessionID: UUID) {
        pendingAgentDockItemRemovalTasks[sessionID]?.cancel()
        pendingAgentDockItemRemovalTasks.removeValue(forKey: sessionID)
    }

    private func scheduleAgentDockItemRemoval(for sessionID: UUID, delay: TimeInterval? = nil) {
        cancelPendingAgentDockItemRemoval(for: sessionID)
        guard agentDockItems.contains(where: { $0.sessionID == sessionID }) else { return }

        let effectiveDelay = delay ?? cancelledDockItemHoldDuration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.agentDockItems.removeAll { $0.sessionID == sessionID }
            if self.agentDockItems.isEmpty {
                self.agentDockWindowManager.hide()
            }
            self.pendingAgentDockItemRemovalTasks[sessionID] = nil
            self.refreshAgentDockFollowBehavior()
            self.scheduleWidgetSnapshotPublish()
        }
        pendingAgentDockItemRemovalTasks[sessionID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDelay, execute: workItem)
    }

    private static func shortAgentInstructionSummary(_ instruction: String) -> String {
        var title = instruction
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " `\"'.,:;!?-–—[](){}<>"))

        if isRawTransportDiagnosticEvent(instruction) {
            return "Runtime Event Filter"
        }

        let directTitleRules: [(pattern: String, title: String)] = [
            (#"(?i)\b(?:see\s+(?:the\s+)?issue\s+here|look\s+at\s+this|fix\s+this)\b.*\b(?:OpenClickyLog|NSXPCDecoder|ViewBridge|unifiedReasons|NSXPCConnection|agent_sdk_query|_sdk_query|kDragIPC|Reentrant\s+message)\b"#, "Log Issue Review"),
            (#"(?i)\b(?:OpenClickyLog|NSXPCDecoder|NSXPCInterface|NSXPCConnection|ViewBridge|NSViewBridgeError|Unable to obtain a task name port right|nw_protocol_instance|nw_read_request_report|unifiedReasons|agent_sdk_query|_sdk_query|Bridge SDK Message|kDragIPC|Reentrant\s+message)\b"#, "Log Issue Review"),
            (#"(?i)\b(?:lozenge|pill|caption|label)\b.*\b(?:too\s+long|wide|overflow|cut\s*off|trim|shorter|shorten|compact)\b"#, "Lozenge Sizing"),
            (#"(?i)\b(?:too\s+long|wide|overflow|cut\s*off|trim|shorter|shorten|compact)\b.*\b(?:lozenge|pill|caption|label)\b"#, "Lozenge Sizing"),
            (#"(?i)\b(?:whole|full)\s+(?:task\s+)?names?\b"#, "Task Status Wording"),
            (#"(?i)\bshort\s+(?:version|task\s+name|name)\b"#, "Task Status Wording"),
            (#"(?i)\b(?:read(?:ing)?\s+out|speak(?:ing)?|say(?:ing)?)\b.*\b(?:whole|full|long|raw)\b.*\b(?:task\s+)?(?:name|title|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:whole|full|long|raw)\b.*\b(?:task\s+)?(?:name|title|request)\b.*\b(?:read(?:ing)?\s+out|speak(?:ing)?|say(?:ing)?)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:short|compact)\s+(?:version|label|title|name)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:proper|better|concise|short|compact)\s+(?:task\s+)?titles?\b"#, "Task Title Cleanup"),
            (#"(?i)\btask\s+titles?\b.*\b(?:read(?:ing)?\s+out|raw|asked\s+for|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:read(?:ing)?\s+out|raw)\b.*\b(?:asked\s+for|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:titles?|task\s+titles?)\b.*\b(?:out\s+of\s+order|wrong\s+order|scrambl(?:ed|ing)|jumbled)\b"#, "Task Title Ordering"),
            (#"(?i)\b(?:out\s+of\s+order|wrong\s+order|scrambl(?:ed|ing)|jumbled)\b.*\b(?:titles?|task\s+titles?)\b"#, "Task Title Ordering"),
            (#"(?i)\b(?:titles?|task\s+titles?)\b.*\b(?:mix(?:ed|ing)?|backwards?|forwards?|flip(?:ping)?|jump(?:ing)?|changing)\b"#, "Task Title Stability"),
            (#"(?i)\b(?:mix(?:ed|ing)?|backwards?|forwards?|flip(?:ping)?|jump(?:ing)?|changing)\b.*\b(?:titles?|task\s+titles?)\b"#, "Task Title Stability")
        ]
        for rule in directTitleRules where title.range(of: rule.pattern, options: .regularExpression) != nil {
            return rule.title
        }

        let attachmentPathPatterns = [
            #"(?i)^/.*?\.(?:png|jpe?g|jpeg|heic|webp|gif|pdf|mov|mp4|m4v)\b"#,
            #"(?i)(?:^|\s)/(?:Users|var|tmp|private|Applications|Volumes)/\S+"#
        ]
        for pattern in attachmentPathPatterns {
            title = title.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        let fillerPatterns = [
            #"(?i)^hey\s+(?:clicky\s+)?agent[,\s]+"#,
            #"(?i)^clicky\s+agent[,\s]+"#,
            #"(?i)^(?:can|could|would)\s+you\s+"#,
            #"(?i)^(?:please\s+)?(?:help\s+me\s+)?(?:do|make|handle|sort|take\s+care\s+of)\s+"#,
            #"(?i)^the\s+(?:updates?|changes?)\s+(?:we(?:'|’)ve|we\s+have|we\s+were)\s+(?:just\s+)?(?:been\s+)?talking\s+about[,\s]+"#,
            #"(?i)^(?:we(?:'|’)ve|we\s+have|we\s+were)\s+(?:just\s+)?(?:been\s+)?talking\s+about[,\s]+"#,
            #"(?i)^(?:to|for|about)\s+"#
        ]
        for pattern in fillerPatterns {
            title = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        title = title.replacingOccurrences(
            of: #"(?i)\b(?:please|just|maybe|basically|actually|kind\s+of|sort\s+of|you\s+know|everything\s+else)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:can\s+you|could\s+you|would\s+you|we(?:'|’)ve|we\s+have|we\s+were|talking\s+about)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:so\s+that|and\s+then|which\s+is\s+to|that\s+you)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:shorten|remove|make|making|sound|sounding|turn|change|update|fix|clean\s+up)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:the|a|an|this|that|it|them|you|your|then|also|with|from|into|and|or|but|for|of|to|in|on|as|is|are|be|have|has|had|asked)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:find|out|why|when|sure|use|uses?|using|start|starts|started|starting|speak|speaks|speaking|say|says|saying|read|reads|reading|whole|full|long|name|version|words?|thing|stuff|phrases?|responses?)\b"#,
            with: " ",
            options: .regularExpression
        )

        let words = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { word in
                guard !word.isEmpty else { return false }
                return word.count > 1 || word.rangeOfCharacter(from: .decimalDigits) != nil
            }
            .prefix(5)

        let cleaned = words
            .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "Agent Task" }
        guard cleaned.count > 44 else { return cleaned }
        let endIndex = cleaned.index(cleaned.startIndex, offsetBy: 44)
        let prefix = String(cleaned[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the spoken/displayed acknowledgement for a freshly invoked
    /// agent task. Keep it generic so OpenClicky does not speak the task
    /// name back to the user; the compact title remains visual-only in the
    /// dock and task history.
    private static func acknowledgementForAgentInstruction(_ _: String) -> String {
        "got it — i’ll get on with that in the background."
    }

    /// Record silent/hybrid agent launches as real voice context so the
    /// primary voice conversation can answer follow-ups like “what were we
    /// talking about?” and “get an agent on it” without losing the topic.
    private static func agentHandoffVoiceContextResponse(instruction: String) -> String {
        let snippet = voiceArchiveSnippet(instruction, limit: 180)
        return "OpenClicky started a background agent for: \(snippet). Keep this as part of the current voice conversation context."
    }

    private static func nextAgentDockAccentTheme(existingCount: Int) -> ClickyAccentTheme {
        let accentThemes: [ClickyAccentTheme] = [.blue, .mint, .rose, .amber, .white]
        return accentThemes[existingCount % accentThemes.count]
    }

    private func updateAgentDockItem(for sessionID: UUID, status: CodexAgentSessionStatus) {
        defer { refreshCursorAgentTaskLabel() }

        guard let itemIndex = agentDockItems.lastIndex(where: { $0.sessionID == sessionID }) else { return }
        let session = codexAgentSessions.first(where: { $0.id == sessionID })
        let activitySummary = session?.latestActivitySummary
        let activityDisplaySummary = session?.latestActivityDisplaySummary ?? activitySummary
        let stageLabel = session?.progressStage.label ?? (status == .starting ? "Starting" : "Working")
        let suggestedNextActions = session?.latestResponseCard?.suggestedNextActions ?? []
        let activityStatusLines = Self.agentDockActivityStatusLines(for: session, fallback: activitySummary)
        let responseDisplaySummary = Self.agentDockResponseDisplaySummary(for: session)
        let displayActivity = responseDisplaySummary ?? activityDisplaySummary ?? activityStatusLines.last ?? activitySummary
        let trimmedActivitySummary = displayActivity?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasActivitySummary = trimmedActivitySummary?.isEmpty == false

        agentDockItems[itemIndex].progressStageLabel = stageLabel
        agentDockItems[itemIndex].progressStepText = hasActivitySummary ? trimmedActivitySummary : nil
        agentDockItems[itemIndex].activityStatusLines = activityStatusLines
        agentDockItems[itemIndex].suggestedNextActions = suggestedNextActions

        switch status {
        case .starting:
            agentDockItems[itemIndex].status = .starting
            // Only overwrite the caption when we actually have real assistant
            // activity. Otherwise preserve the existing caption (the user's
            // acknowledgement message) instead of replacing it with the
            // generic "An agent is getting ready." placeholder. When neither
            // is present, leave caption nil so the view can render its own
            // streaming "thinking" affordance.
            if let displayActivity, hasActivitySummary {
                agentDockItems[itemIndex].caption = displayActivity
            }
        case .running:
            agentDockItems[itemIndex].status = .running
            // Same rationale as .starting — never replace the caption with
            // "An agent is working on this." Leave nil to surface the
            // animated thinking indicator until real tokens stream in.
            if let displayActivity, hasActivitySummary {
                agentDockItems[itemIndex].caption = displayActivity
            }
        case .ready:
            // Codex briefly reports `.ready` after thread startup and before
            // the actual turn starts. Do not turn that preflight ready state
            // into "done"; assigning/queueing an agent is not task completion.
            let isCompletedTurn = session?.progressStage == .completed || responseDisplaySummary != nil
            guard isCompletedTurn else {
                // Preflight ready, even with the acknowledgement/activity text
                // we seeded at assignment time, should stay visibly queued or
                // working until a real completed turn arrives.
                return
            }
            if agentDockItems[itemIndex].status == .running
                || agentDockItems[itemIndex].status == .starting
                || (agentDockItems[itemIndex].status == .failed && isCompletedTurn) {
                agentDockItems[itemIndex].status = .done
                agentDockItems[itemIndex].caption = "The agent has completed the task — \(displayActivity ?? activitySummary ?? "open the agent for details")"
                agentDockItems[itemIndex].progressStageLabel = "Completed"
                agentDockItems[itemIndex].progressStepText = displayActivity ?? activitySummary
            }
            completeAgentRequestTimingIfNeeded(sessionID: sessionID, status: "success")
            let completionSpeechSummary = Self.completionSpeechSummary(for: session, fallback: activitySummary)
            announceAgentCompletionIfNeeded(sessionID: sessionID, outcome: "success", summary: completionSpeechSummary)
        case .failed:
            agentDockItems[itemIndex].status = .failed
            agentDockItems[itemIndex].caption = activityDisplaySummary ?? "The agent stopped. Open the agent for details."
            agentDockItems[itemIndex].progressStageLabel = "Stopped"
            agentDockItems[itemIndex].progressStepText = activityDisplaySummary ?? activitySummary
            completeAgentRequestTimingIfNeeded(
                sessionID: sessionID,
                status: "failed",
                extra: [
                    "activitySummary": activitySummary ?? ""
                ]
            )
            let completionSpeechSummary = Self.completionSpeechSummary(for: session, fallback: activitySummary)
            announceAgentCompletionIfNeeded(sessionID: sessionID, outcome: "failed", summary: completionSpeechSummary)
        case .stopped:
            if session?.status != .stopped {
                break
            }
            let stopReason = session?.stopReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasExplicitStopReason = stopReason?.isEmpty == false
            if agentDockItems[itemIndex].status == .starting,
               !hasExplicitStopReason {
                // New sessions publish their initial `.stopped` value once
                // the Combine observer is attached. That delivery can arrive
                // after the prompt has been queued, so `hasVisibleActivity`
                // is already true even though the agent has not actually
                // stopped. Do not convert that preflight value into an
                // immediate cancellation; wait for `.starting` / `.running`,
                // or for an explicit stop reason from a real stop action.
                break
            }
            let normalizedStopReason = stopReason?.isEmpty == false ? (stopReason ?? "") : "session_stopped"
            agentDockItems[itemIndex].status = .failed
            if let summary = activitySummary,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                agentDockItems[itemIndex].caption = "Cancelled while: \(summary)"
                agentDockItems[itemIndex].progressStepText = summary
            } else {
                agentDockItems[itemIndex].caption = "The agent was cancelled (\(Self.prettyCancelReason(for: normalizedStopReason)))."
                agentDockItems[itemIndex].progressStepText = Self.prettyCancelReason(for: normalizedStopReason)
            }
            agentDockItems[itemIndex].progressStageLabel = "Stopped"
            completeAgentRequestTimingIfNeeded(
                sessionID: sessionID,
                status: "cancelled",
                extra: [
                    "activitySummary": activitySummary ?? "",
                    "cancelledAt": Date().ISO8601Format(),
                    "cancelReason": normalizedStopReason
                ]
            )
            announceAgentCompletionIfNeeded(
                sessionID: sessionID,
                outcome: "cancelled",
                summary: Self.prettyCancelReason(for: normalizedStopReason),
                cancelReason: normalizedStopReason
            )
            break
        }
        scheduleWidgetSnapshotPublish()
    }

    private static func agentDockActivityStatusLines(for session: CodexAgentSession?, fallback: String?) -> [String] {
        var lines: [String] = []
        for line in session?.activityStatusLines ?? [] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if lines.last != trimmed {
                lines.append(trimmed)
            }
        }
        if let fallback {
            let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedFallback.isEmpty, lines.last != trimmedFallback {
                lines.append(trimmedFallback)
            }
        }
        return Array(lines.suffix(8))
    }

    private static func agentDockResponseDisplaySummary(for session: CodexAgentSession?) -> String? {
        guard let raw = session?.latestResponseCard?.rawText else { return nil }
        let displayText = ClickyResponseCard.sanitizedDisplayText(from: raw, maximumCharacters: 1_200)
            .replacingOccurrences(
                of: #"(?im)^\s*TASK_TITLE\s*:\s*.*$"#,
                with: " ",
                options: .regularExpression
            )
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return displayText.isEmpty ? nil : displayText
    }

    private func refreshCursorAgentTaskLabel() {
        guard let item = agentDockItems.reversed().first(where: { dockItem in
            dockItem.status == .starting || dockItem.status == .running
        }) else {
            clearAgentTaskBubbleText()
            return
        }

        let session = item.sessionID.flatMap { sessionID in
            codexAgentSessions.first(where: { $0.id == sessionID })
        }
        let nextLabel = Self.cursorAgentTaskLabel(for: item, session: session)
        guard !nextLabel.isEmpty else {
            clearAgentTaskBubbleText()
            return
        }

        cursorOverlayState.agentTaskBubbleText = nextLabel
        scheduleAgentTaskBubbleClear(matching: nextLabel)
    }

    private func clearAgentTaskBubbleText() {
        agentTaskBubbleClearTask?.cancel()
        agentTaskBubbleClearTask = nil
        cursorOverlayState.agentTaskBubbleText = nil
    }

    private func scheduleAgentTaskBubbleClear(matching label: String, after delay: TimeInterval = 3.0) {
        agentTaskBubbleClearTask?.cancel()
        agentTaskBubbleClearTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0.2, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self, self.cursorOverlayState.agentTaskBubbleText == label else { return }
                self.cursorOverlayState.agentTaskBubbleText = nil
                self.agentTaskBubbleClearTask = nil
            }
        }
    }

    private static func cursorAgentTaskLabel(for item: ClickyAgentDockItem, session: CodexAgentSession?) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? "Agent task" : title
        let stageLabel = session?.progressStage.label ?? (item.status == .starting ? "Starting" : "Working")

        // The cursor bubble is only a transient cue; the dock/HUD owns detailed progress.
        // Keeping it title-based prevents long streamed status lines from wrapping into
        // clipped, ellipsis-heavy captions beside the cursor.
        return shortCursorAgentTaskLabel("\(stageLabel): \(fallbackTitle)")
    }

    private static func shortCursorAgentTaskLabel(_ text: String) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let maxCharacters = 64
        guard flattened.count > maxCharacters else { return flattened }

        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxCharacters)
        let prefix = String(flattened[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func completeAgentRequestTimingIfNeeded(
        sessionID: UUID,
        status: String,
        extra: [String: Any] = [:]
    ) {
        let timing = agentRequestTimingsBySessionID.removeValue(forKey: sessionID)
        let executionStartedAt = agentExecutionStartDatesBySessionID.removeValue(forKey: sessionID)
        // Drop the dedup signature for terminal sessions so the map can't
        // grow without bound across long-running OpenClicky sessions.
        lastAgentProgressNarrationSignatures.removeValue(forKey: sessionID)
        guard timing != nil || executionStartedAt != nil else { return }

        var fields = extra
        if status == "cancelled" {
            if fields["cancelledAt"] == nil {
                fields["cancelledAt"] = Date().ISO8601Format()
            }
            if fields["cancelReason"] == nil,
               let stoppedSession = codexAgentSessions.first(where: { $0.id == sessionID })?.stopReason,
               !stoppedSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fields["cancelReason"] = stoppedSession
            }
            fields["executionMethod"] = "CodexAgentSession.status"
            fields["executionStatus"] = "cancelled"
        }

        fields["sessionID"] = sessionID.uuidString
        fields["executor"] = "agent_mode"
        fields["executionMethod"] = fields["executionMethod"] as? String ?? "CodexAgentSession.status"
        fields["controller"] = "CodexAgentSession"
        markRequestCompleted(
            route: "agent.start",
            executionStartedAt: executionStartedAt,
            timing: timing,
            status: status,
            extra: fields
        )
    }

    /// Speaks a short completion line the first time a delegated agent
    /// reaches a terminal outcome. Suppresses duplicate announcements
    /// when Combine republishes, and avoids stepping on a voice response
    /// that's already mid-flight.
    private func announceAgentCompletionIfNeeded(
        sessionID: UUID,
        outcome: String,
        summary: String?,
        cancelReason: String? = nil
    ) {
        if lastNarratedAgentOutcomeBySessionID[sessionID] == outcome { return }
        lastNarratedAgentOutcomeBySessionID[sessionID] = outcome

        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else { return }
        let taskTitle = Self.agentCompletionSpokenTaskTitle(for: session)

        // User-initiated cancellation: the user just clicked Stop / said
        // "cancel" — they already know what happened. Don't narrate it back.
        // Only system-initiated cancellations get spoken/notified (those would
        // otherwise be invisible to the user).
        if outcome == "cancelled", Self.isUserInitiatedCancelReason(cancelReason) {
            return
        }

        let trimmedSummary = summary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let line: String
        switch outcome {
        case "cancelled":
            line = trimmedSummary.isEmpty
                ? "\(taskTitle) was cancelled"
                : "\(taskTitle) was cancelled \(Self.briefCompletionSummary(trimmedSummary))"
        case "failed":
            line = trimmedSummary.isEmpty
                ? "\(taskTitle) stopped"
                : "\(taskTitle) stopped \(Self.briefCompletionSummary(trimmedSummary))"
        default:
            line = trimmedSummary.isEmpty
                ? "\(taskTitle) is done"
                : "\(taskTitle) is done \(Self.briefCompletionSummary(trimmedSummary))"
        }

        let notificationTitle: String
        switch outcome {
        case "cancelled": notificationTitle = "OpenClicky task cancelled"
        case "failed": notificationTitle = "OpenClicky task stopped"
        default: notificationTitle = "OpenClicky task done"
        }
        OpenClickyDesktopNotificationCenter.shared.post(
            title: notificationTitle,
            body: line,
            threadID: "openclicky.agent.\(sessionID.uuidString)",
            playSound: outcome == "success",
            userInfo: [
                "source": "agent_completion",
                "sessionID": sessionID.uuidString,
                "outcome": outcome
            ]
        )

        guard AppBundleConfiguration.agentCompletionVoiceEnabled() else { return }

        // Skip narration if the user is mid-conversation with the voice
        // responder — the dock item still updates visually, and the desktop
        // notification now carries the update without talking over them.
        if voiceState == .listening { return }

        // Sequence behind any in-flight TTS or voice capture instead of
        // cutting in. The queued path is important: an agent can finish
        // while the user has already started the next push-to-talk turn,
        // and completion speech must not feed back into the microphone.
        // Previously this called `speakShortSystemResponse(line)` directly,
        // whose `interruptCurrentVoiceResponse()` would chop the
        // acknowledgement TTS mid-sentence when fast tasks completed
        // before the acknowledgement finished playing. Now we wait for
        // the audio device to go idle, then play the chime (success
        // only), then speak the announcement — so the success line is
        // always heard, never elided, and never overlaps prior audio.
        let playChime = (outcome == "success")
        speakSystemAnnouncementAfterCurrentTTS(line, for: sessionID, withChime: playChime)
    }

    private static func agentCompletionSpokenTaskTitle(for session: CodexAgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != "Agent" else {
            return "the agent task"
        }
        return title
    }

    /// Queue a system announcement to play *after* any currently-playing
    /// TTS finishes. Polls `voiceTTSClient.isPlaying` rather than awaiting
    /// a Task, because the relevant signal is "audio device idle", not
    /// "Swift Task completed" — TTS playback can outlive its dispatching
    /// task by a few hundred milliseconds while audio buffers drain.
    ///
    /// When `withChime` is true, the agent-done chime is played first,
    /// followed by a settle gap, then the announcement. This is how
    /// success completion announces — chime, then the spoken summary.
    /// Play an agent-completion announcement. Chime first (if requested),
    /// then the spoken line. Anything currently playing is cut so the
    /// chime never overlaps speech and never gets cut by speech.
    private func speakSystemAnnouncementAfterCurrentTTS(
        _ line: String,
        for sessionID: UUID?,
        withChime: Bool = false
    ) {
        let previousTask = pendingSystemAnnouncementTask
        pendingSystemAnnouncementSessionID = sessionID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let previousTask {
                _ = await previousTask.result
            }
            if let sessionID, self.silencedAgentSpeechSessionIDs.contains(sessionID) { return }
            if Task.isCancelled { return }
            guard await self.waitForSystemAnnouncementSlot(sessionID: sessionID) else { return }
            if let sessionID, self.silencedAgentSpeechSessionIDs.contains(sessionID) { return }
            if withChime {
                let chimeDuration = self.playAgentDoneChime()
                let settleSeconds = max(0.12, chimeDuration + 0.08)
                try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                if let sessionID, self.silencedAgentSpeechSessionIDs.contains(sessionID) { return }
                guard await self.waitForSystemAnnouncementSlot(sessionID: sessionID) else { return }
            }
            self.speakingSystemAnnouncementSessionID = sessionID
            self.speakShortSystemResponse(line, interruptExisting: false)
            await self.waitForVoicePlaybackToIdle()
            if self.speakingSystemAnnouncementSessionID == sessionID {
                self.speakingSystemAnnouncementSessionID = nil
            }
            if self.pendingSystemAnnouncementSessionID == sessionID {
                self.pendingSystemAnnouncementTask = nil
                self.pendingSystemAnnouncementSessionID = nil
            }
        }
        pendingSystemAnnouncementTask = task
    }

    private func silenceAgentSpeech(for sessionID: UUID, reason: String) {
        var didSilenceSpeech = false
        silencedAgentSpeechSessionIDs.insert(sessionID)
        if pendingSystemAnnouncementSessionID == sessionID {
            pendingSystemAnnouncementTask?.cancel()
            pendingSystemAnnouncementTask = nil
            pendingSystemAnnouncementSessionID = nil
            didSilenceSpeech = true
        }
        if speakingSystemAnnouncementSessionID == sessionID {
            interruptCurrentVoiceResponse()
            speakingSystemAnnouncementSessionID = nil
            didSilenceSpeech = true
        }
        guard didSilenceSpeech else { return }
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_task.speech_silenced",
            fields: [
                "sessionID": sessionID.uuidString,
                "reason": reason
            ]
        )
    }

    @MainActor
    private func waitForVoicePlaybackToIdle(maxWaitSeconds: TimeInterval = 8.0) async {
        let start = Date()
        while voiceTTSClient.isPlaying || openAIRealtimeSpeechClient.isPlaying || deepgramVoiceAgentClient.isPlaying {
            if Task.isCancelled { return }
            if Date().timeIntervalSince(start) >= maxWaitSeconds { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    private func waitForSystemAnnouncementSlot(
        sessionID: UUID?,
        maxWaitSeconds: TimeInterval = 30.0
    ) async -> Bool {
        let start = Date()
        while systemAnnouncementAudioWouldCollideWithVoiceInput {
            if Task.isCancelled { return false }
            if let sessionID, silencedAgentSpeechSessionIDs.contains(sessionID) { return false }
            if Date().timeIntervalSince(start) >= maxWaitSeconds {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "internal",
                    event: "openclicky.agent_completion.speech_deferred_timeout",
                    fields: [
                        "sessionID": sessionID?.uuidString ?? "",
                        "voiceState": String(describing: voiceState),
                        "dictationInProgress": buddyDictationManager.isDictationInProgress,
                        "realtimeCaptureActive": isRealtimeBidirectionalVoiceCaptureActive,
                        "ttsPlaying": voiceTTSClient.isPlaying
                    ]
                )
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    @MainActor
    private var systemAnnouncementAudioWouldCollideWithVoiceInput: Bool {
        if voiceTTSClient.isPlaying || openAIRealtimeSpeechClient.isPlaying || deepgramVoiceAgentClient.isPlaying { return true }
        if buddyDictationManager.isDictationInProgress { return true }
        if isRealtimeBidirectionalVoiceCaptureActive { return true }
        switch voiceState {
        case .listening, .processing, .responding:
            return true
        case .idle:
            return false
        }
    }

    /// Play the bundled "agent-done" chime via NSSound on a system
    /// audio channel separate from TTS. Caller is responsible for
    /// timing this so it doesn't overlap in-flight TTS.
    @discardableResult
    private func playAgentDoneChime() -> TimeInterval {
        guard let url = Bundle.main.url(forResource: "agent-done", withExtension: "mp3") else {
            return 0.55
        }
        guard let sound = NSSound(contentsOf: url, byReference: false) else {
            return 0.55
        }
        sound.play()
        return sound.duration > 0 ? sound.duration : 0.55
    }

    /// Trims an agent activity summary to a sentence-length spoken line.
    /// Activity summaries can be multi-line tool output; we want one
    /// short clause for TTS.
    private static func prettyCancelReason(for reason: String) -> String {
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "", "unknown", "session_stopped":
            return "session was stopped"
        case "agent.cancel_current", "agent.cancel":
            return "the user requested cancellation"
        case "agent.cancel_all":
            return "all agents were cancelled"
        case "agent_dock_stop":
            return "dock stop"
        case "response_card_dismissed":
            return "response card dismissed"
        case "api_key_reconfigured":
            return "API configuration changed"
        case "model_changed":
            return "model changed"
        default:
            return reason
        }
    }

    /// Whether a cancellation reason was *initiated by the user* (Stop
    /// click, "cancel" voice command, dismiss response card). Those
    /// cancellations should be silent — the user already knows. Only
    /// system-initiated cancellations (API key changed, model changed,
    /// session externally stopped with no other context) get spoken.
    private static func isUserInitiatedCancelReason(_ reason: String?) -> Bool {
        guard let reason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !reason.isEmpty else {
            return false
        }
        switch reason {
        case "agent_dock_stop",
             "agent.cancel",
             "agent.cancel_current",
             "agent.cancel_all",
             "response_card_dismissed":
            return true
        case "api_key_reconfigured",
             "model_changed",
             "session_stopped",
             "unknown":
            return false
        default:
            // For anything else, default to "system" — user-initiated
            // reasons are explicit and known. Unknown reasons get a
            // narration so the user can find out what happened.
            return false
        }
    }

    private static func briefCompletionSummary(_ summary: String) -> String {
        cleanedNaturalSpeech(summary, maxLength: 180)
    }

    /// For completion TTS, use a short cleaned final-response summary after
    /// the compact task title. Do not read the whole task or result aloud.
    private static func completionSpeechSummary(
        for session: CodexAgentSession?,
        fallback: String?
    ) -> String? {
        if let raw = session?.latestResponseCard?.rawText {
            var text = ClickyResponseCard.sanitizedDisplayText(from: raw, maximumCharacters: 10_000)
            text = text.replacingOccurrences(
                of: #"(?im)^\s*TASK_TITLE\s*:\s*.*$"#,
                with: " ",
                options: .regularExpression
            )
            text = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let maxSpokenLength = 180
                let cleaned = cleanedNaturalSpeech(text, maxLength: maxSpokenLength)
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "outgoing",
                    event: "openclicky.agent_completion.speech_budget",
                    fields: [
                        "rawLength": raw.count,
                        "sanitizedLength": text.count,
                        "spokenLength": cleaned.count,
                        "maxLength": maxSpokenLength
                    ]
                )
                return cleaned.isEmpty ? nil : cleaned
            }
        }
        if let fallback {
            let maxSpokenLength = 180
            let cleaned = cleanedNaturalSpeech(fallback, maxLength: maxSpokenLength)
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "outgoing",
                event: "openclicky.agent_completion.speech_budget",
                fields: [
                    "rawLength": fallback.count,
                    "sanitizedLength": fallback.count,
                    "spokenLength": cleaned.count,
                    "maxLength": maxSpokenLength,
                    "source": "fallback"
                ]
            )
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    /// Sanitizes assistant text into short, natural spoken English for TTS.
    /// Removes paths/filenames and punctuation-heavy fragments that sound
    /// robotic when read aloud.
    private static func cleanedNaturalSpeech(_ text: String, maxLength: Int) -> String {
        var value = text
        value = trimmedCompletionSpeechBeforeTechnicalTail(value)
        value = value.replacingOccurrences(
            of: #"(?is)\s+(?:in|at|under|inside)\s+`?(?:/Users|/Volumes|~)/[^\s,;:()\[\]{}<>"]+`?"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: #"(?i)\b(?:/Users|/Volumes|~)/[^\s,;:()\[\]{}<>"]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\b\S+\.(swift|md|json|jsonl|toml|yaml|yml|txt|csv|ts|tsx|js|jsx|py|sh)\b"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"`[^`]*`"#, with: " ", options: .regularExpression)
        value = Self.naturallyBoundedCompletionSpeech(value, maxLength: maxLength)
        value = value.replacingOccurrences(of: #"[#*_>\[\]\(\)\{\}:;|\\/]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[-–—]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[.!?,]+"#, with: " ", options: .regularExpression)
        value = value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard value.count > maxLength else { return value }
        let endIndex = value.index(value.startIndex, offsetBy: maxLength)
        let prefix = String(value[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps spoken task-completion summaries from sounding like the
    /// audio was cut off. Prefer a real sentence boundary; when the
    /// only available text is long, end with a deliberate handoff to
    /// the on-screen task transcript instead of stopping mid-thought.
    private static func naturallyBoundedCompletionSpeech(_ text: String, maxLength: Int) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > maxLength else { return flattened }

        let limitIndex = flattened.index(flattened.startIndex, offsetBy: maxLength)
        let prefix = String(flattened[..<limitIndex])
        let minimumBoundary = flattened.index(
            flattened.startIndex,
            offsetBy: min(70, max(0, flattened.count - 1))
        )
        if let sentenceBreak = prefix.lastIndex(where: { ".!?".contains($0) }),
           sentenceBreak >= minimumBoundary {
            return String(prefix[...sentenceBreak]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let suffix = " Details are in the task."
        let allowedPrefixLength = max(40, maxLength - suffix.count)
        let allowedIndex = prefix.index(prefix.startIndex, offsetBy: min(prefix.count, allowedPrefixLength))
        let boundedPrefix = String(prefix[..<allowedIndex])
        if let lastComma = boundedPrefix.lastIndex(where: { ",;".contains($0) }),
           lastComma > boundedPrefix.startIndex {
            return String(boundedPrefix[..<lastComma]).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
        }
        if let lastSpace = boundedPrefix.lastIndex(of: " "), lastSpace > boundedPrefix.startIndex {
            return String(boundedPrefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
        }
        return boundedPrefix.trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }

    /// Agent final replies often include useful transcript detail like
    /// "Verified with `swiftc -parse` and `git diff --check`". That is good
    /// on-screen, but TTS used to read up to "verified with" and then lose the
    /// code-like command names. Stop before those verification tails so the
    /// spoken completion stays natural.
    private static func trimmedCompletionSpeechBeforeTechnicalTail(_ text: String) -> String {
        var value = text
        let technicalTailPatterns = [
            #"(?is)\s*(?:[,.]\s*)?(?:and\s+)?(?:I\s+)?verified\s+(?:it\s+)?with\s+`?(?:swiftc|git|xcodebuild|swift|npm|pnpm|yarn|pytest|python|cargo)\b.*$"#,
            #"(?is)\s*(?:[,.]\s*)?(?:and\s+)?verified\s+with\s+`?(?:swiftc|git|xcodebuild|swift|npm|pnpm|yarn|pytest|python|cargo)\b.*$"#,
            #"(?is)\s*(?:[,.]\s*)?(?:and\s+)?(?:I\s+)?(?:checked|tested)\s+(?:it\s+)?with\s+`?(?:swiftc|git|xcodebuild|swift|npm|pnpm|yarn|pytest|python|cargo)\b.*$"#,
            #"(?is)\s*(?:[,.]\s*)?(?:and\s+)?(?:I\s+)?verified\b[^.!?]*(?:swiftc|git\s+diff|diff\s+--check|xcodebuild|npm|pnpm|yarn|pytest|python|cargo)\b.*$"#
        ]
        for pattern in technicalTailPatterns {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func openAgentDockItem(_ itemID: UUID) {
        guard isAdvancedModeEnabled else {
            prepareVoiceFollowUpForAgentDockItem(itemID)
            return
        }
        if let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID {
            selectCodexAgentSession(sessionID)
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "internal",
                event: "openclicky.agent_overlay.opened_selection_only",
                fields: [
                    "source": "agent_overlay_open",
                    "sessionID": sessionID.uuidString
                ]
            )
            notchCaptureWindowManager.showMainInterfacePanel(companionManager: self, focusedAgentSessionID: sessionID)
            return
        }
        notchCaptureWindowManager.showMainInterfacePanel(companionManager: self)
    }

    func closeAgentDockPanel() {
        agentDockWindowManager.hide()
    }

    func dismissAgentDockItem(_ itemID: UUID) {
        // The dock/menu "Archive" affordance should archive the underlying
        // task, not just hide its visual parked/menu item. Menu-bar task
        // items may be synthesized directly from Codex sessions, so their
        // item ID is the session ID and there may be no matching dock item.
        if let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID
            ?? codexAgentSessions.first(where: { $0.id == itemID })?.id {
            cancelPendingAgentDockItemRemoval(for: sessionID)
            archiveSession(sessionID, allowIncomplete: true)
            return
        }

        // Unsessioned completed cues are visual-only; remove those directly.
        agentDockItems.removeAll { $0.id == itemID }
        if agentDockItems.isEmpty {
            agentDockWindowManager.hide()
        }
        scheduleWidgetSnapshotPublish()
    }

    func stopAgentDockItem(_ itemID: UUID) {
        if let stoppedSessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID
            ?? codexAgentSessions.first(where: { $0.id == itemID })?.id {
            cancelAgentTask(sessionID: stoppedSessionID, removeDockItems: true, reason: "agent_dock_stop")
            lastNarratedAgentOutcomeBySessionID.removeValue(forKey: stoppedSessionID)
        } else {
            agentDockItems.removeAll { $0.id == itemID }
            if agentDockItems.isEmpty {
                agentDockWindowManager.hide()
            }
            scheduleWidgetSnapshotPublish()
        }
    }

    func prepareVoiceFollowUpForAgentDockItem(_ itemID: UUID) {
        guard let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID else {
            prepareForVoiceFollowUp()
            return
        }
        armVoiceFollowUpTarget(sessionID, source: "agent_overlay_voice_button")
        prepareForVoiceFollowUp()
    }

    func armVoiceFollowUpTarget(_ sessionID: UUID, source: String) {
        pendingAgentVoiceFollowUpSessionID = sessionID
        pendingAgentVoiceFollowUpCreatedAt = Date()
        pendingAgentVoiceFollowUpSource = source
        selectCodexAgentSession(sessionID)
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "internal",
            event: "openclicky.agent_followup.voice_target_armed",
            fields: [
                "source": source,
                "sessionID": sessionID.uuidString,
                "ttlSeconds": Int(Self.pendingAgentVoiceFollowUpTTL)
            ]
        )
    }

    func showTextFollowUpForAgentDockItem(_ itemID: UUID) {
        guard let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID else { return }
        showTextFollowUpForAgentSession(sessionID)
    }

    func showTextFollowUpForAgentSession(_ sessionID: UUID) {
        selectCodexAgentSession(sessionID)
        showNotchTextInput { [weak self] submittedText in
            self?.submitTextFollowUp(submittedText, toAgentSessionID: sessionID)
        }
    }

    func beginAgentDockDrag() {
        agentDockWindowManager.beginDrag()
    }

    func dragAgentDock(by translation: CGSize) {
        agentDockWindowManager.drag(by: translation)
    }

    func endAgentDockDrag() {
        agentDockWindowManager.endDrag()
    }

    private func submitTextFollowUp(_ submittedText: String, toAgentSessionID sessionID: UUID) {
        let trimmedText = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        guard let session = codexAgentSessions.first(where: { $0.id == sessionID }) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "error",
                event: "openclicky.agent_followup.missing_session",
                fields: [
                    "source": "agent_text_followup",
                    "sessionID": sessionID.uuidString,
                    "instructionLength": trimmedText.count
                ]
            )
            return
        }
        let timing = beginRequestTiming(source: "agent_text_followup", text: trimmedText)
        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.followup",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_text_followup",
                "sessionID": session.id.uuidString,
                "title": session.title,
                "instructionLength": trimmedText.count
            ]
        )
        submitAgentPrompt(trimmedText, to: session)
        lastAgentContextSessionID = session.id
        markRequestCompleted(
            route: "agent.followup",
            executionStartedAt: executionStartedAt,
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CodexAgentSession.submitPromptFromUI",
                "controller": "CodexAgentSession",
                "source": "agent_text_followup",
                "sessionID": session.id.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
        if isAdvancedModeEnabled {
            notchCaptureWindowManager.showMainInterfacePanel(companionManager: self, focusedAgentSessionID: session.id)
        }
    }

    func attachDroppedAgentFiles(_ urls: [URL], toAgentDockItem itemID: UUID, source: String) {
        let standardizedURLs = urls
            .map(\.standardizedFileURL)
            .filter(\.isFileURL)
        guard !standardizedURLs.isEmpty else { return }
        guard let sessionID = agentDockItems.first(where: { $0.id == itemID })?.sessionID,
              let session = codexAgentSessions.first(where: { $0.id == sessionID }) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "error",
                event: "openclicky.agent_attachment_drop.missing_session",
                fields: [
                    "source": source,
                    "itemID": itemID.uuidString,
                    "attachmentCount": standardizedURLs.count
                ]
            )
            return
        }

        let prompt = Self.agentAttachmentPrompt(for: standardizedURLs)
        let timing = beginRequestTiming(source: source, text: prompt)
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
                "attachmentCount": standardizedURLs.count
            ]
        )

        selectCodexAgentSession(session.id)
        submitAgentPrompt(prompt, to: session)
        lastAgentContextSessionID = session.id

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
                "model": session.model,
                "attachmentCount": standardizedURLs.count
            ]
        )

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "openclicky.agent_attachment_drop.received",
            fields: [
                "source": source,
                "sessionID": session.id.uuidString,
                "attachmentCount": standardizedURLs.count
            ]
        )
    }

    private static func agentAttachmentPrompt(for urls: [URL]) -> String {
        let attachmentLines = urls.enumerated().map { index, url in
            "\(index + 1). \(agentAttachmentKindLabel(for: url)): \(url.path)"
        }.joined(separator: "\n")

        return """
        Please review the attached file(s).

        OpenClicky dropped attachments:
        \(attachmentLines)
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func agentAttachmentKindLabel(for url: URL) -> String {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
        return imageExtensions.contains(url.pathExtension.lowercased()) ? "Image" : "Document"
    }

    @discardableResult
    func submitNewAgentTaskFromUI(_ prompt: String, source: String = "agent_new_task_prompt") -> BrowserWorkspaceAgentSessionProtocol? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }
        var taskPrompt = trimmedPrompt
        if Self.isRawTransportDiagnosticEvent(trimmedPrompt) {
            // Typed/pasted prompts that mix user intent with log evidence
            // are real tasks; only refuse pure transport echo that yields
            // no analysis instruction.
            guard let logInstruction = Self.logEvidenceAnalysisInstruction(from: trimmedPrompt) else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.raw_transport_event_ignored",
                    fields: [
                        "source": source,
                        "instructionPreview": Self.voiceArchiveSnippet(trimmedPrompt, limit: 240)
                    ]
                )
                speakShortSystemResponse("that looks like an internal OpenClicky runtime event, not a task.")
                return nil
            }
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.log_evidence_rescued",
                fields: [
                    "source": source,
                    "instructionPreview": Self.voiceArchiveSnippet(trimmedPrompt, limit: 240)
                ]
            )
            taskPrompt = logInstruction
        }

        let timing = beginRequestTiming(source: source, text: trimmedPrompt)
        activeRequestTiming = timing
        defer { activeRequestTiming = nil }

        let executionStartedAt = markRequestExecutionStarted(
            route: "agent.new_task",
            timing: timing,
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.createAndLaunchCodexAgentSession",
                "controller": "CompanionManager",
                "source": source,
                "instructionLength": trimmedPrompt.count
            ]
        )

        let launchPrompt = resolvedNewAgentTaskPrompt(from: taskPrompt)

        let session = createAndLaunchCodexAgentSession(
            title: Self.shortAgentInstructionSummary(launchPrompt),
            prompt: launchPrompt,
            includeScreenContext: Self.shouldAttachScreenContext(to: launchPrompt),
            restrictedExecutionPolicy: source == "browser_workspace_untrusted_context"
        )
        agentRequestTimingsBySessionID[session.id] = timing
        agentExecutionStartDatesBySessionID[session.id] = executionStartedAt

        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "openclicky.agent_task.created",
            fields: [
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.createAndLaunchCodexAgentSession",
                "controller": "CompanionManager",
                "model": session.model,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "instruction": launchPrompt,
                "originalInstruction": trimmedPrompt,
                "requestID": timing.requestID,
                "source": source
            ]
        )

        markRequestStageCompleted(
            route: "agent.new_task",
            stage: "agent_queued",
            stageStartedAt: executionStartedAt,
            timing: timing,
            status: "queued",
            extra: [
                "executor": "agent_mode",
                "executionMethod": "CompanionManager.createAndLaunchCodexAgentSession",
                "controller": "CompanionManager",
                "source": source,
                "sessionID": session.id.uuidString,
                "title": session.title,
                "model": session.model
            ]
        )
        return session
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

        if !Self.shouldSendAgentHUDPromptStraightToAgent(trimmedPrompt),
           handleDirectComputerUseRequest(from: trimmedPrompt, source: "agent_hud_prompt") {
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
        if codexAgentSession.isTurnActiveForChatQueue {
            codexAgentSession.submitPromptFromUI(trimmedPrompt, screenContext: nil)
        } else {
            stageDashboardAgentSubmission(prompt: trimmedPrompt, session: codexAgentSession)
            submitAgentPrompt(trimmedPrompt, to: codexAgentSession)
        }
        markRequestStageCompleted(
            route: "agent.followup",
            stage: "prompt_queued",
            stageStartedAt: executionStartedAt,
            timing: timing,
            status: "queued",
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

    private static func shouldSendAgentHUDPromptStraightToAgent(_ prompt: String) -> Bool {
        let lineBreakCount = prompt.reduce(0) { partial, character in
            partial + (character.isNewline ? 1 : 0)
        }
        guard lineBreakCount > 0 else { return false }

        let normalized = prompt.lowercased()
        let pastedDiagnosticSignals = [
            "[openclickylog]",
            "openclicky:",
            "voice.realtime_bidirectional",
            "codex.rpc",
            "nw_read_request_report",
            "error domain=",
            "throwing -",
            "failed!"
        ]
        return pastedDiagnosticSignals.contains { normalized.contains($0) }
    }

    /// Keeps chat-driven turns aligned with the same corner-dock UX as
    /// voice starts: hoverable dock card and a quick buddy flight to the
    /// parking corner before returning to the user's cursor.
    private func stageDashboardAgentSubmission(prompt: String, session: CodexAgentSession) {
        let summary = Self.shortAgentInstructionSummary(prompt)
        let activity = "Starting \(summary)"
        let screen = agentDockTargetScreen()
        clearDetectedElementLocation()

        let spawnAccentTheme: ClickyAccentTheme
        let spawnDockItemID: UUID
        if let itemIndex = agentDockItems.lastIndex(where: { $0.sessionID == session.id }) {
            agentDockItems[itemIndex].title = summary
            agentDockItems[itemIndex].userInstruction = prompt
            agentDockItems[itemIndex].status = .starting
            agentDockItems[itemIndex].progressStageLabel = "Starting"
            agentDockItems[itemIndex].progressStepText = activity
            agentDockItems[itemIndex].activityStatusLines = [activity]
            agentDockItems[itemIndex].caption = "on it."
            spawnAccentTheme = agentDockItems[itemIndex].accentTheme
            spawnDockItemID = agentDockItems[itemIndex].id
        } else {
            let accentTheme = Self.nextAgentDockAccentTheme(existingCount: agentDockItems.count)
            let dockItem = ClickyAgentDockItem(
                id: UUID(),
                sessionID: session.id,
                title: summary,
                userInstruction: prompt,
                accentTheme: accentTheme,
                status: .starting,
                progressStageLabel: "Starting",
                progressStepText: activity,
                activityStatusLines: [activity],
                caption: "on it.",
                suggestedNextActions: [],
                createdAt: Date()
            )
            agentDockItems.append(dockItem)
            if agentDockItems.count > 6 {
                agentDockItems.removeFirst(agentDockItems.count - 6)
            }
            spawnAccentTheme = accentTheme
            spawnDockItemID = dockItem.id
        }

        refreshAgentDockFollowBehavior()
        scheduleWidgetSnapshotPublish()

        if let screen {
            agentDockWindowManager.show(
                companionManager: self,
                onScreen: screen,
                position: agentParkingPosition
            )
        } else {
            showAgentDockWindowNearCurrentScreen()
        }
        animateAgentSpawnProxyFromCursorToDock(accentTheme: spawnAccentTheme, dockItemID: spawnDockItemID)
    }

    func submitAgentPrompt(
        _ prompt: String,
        to session: CodexAgentSession,
        includeScreenContext: Bool = true,
        attachPendingVoiceCircle: Bool = false
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        lastAgentContextSessionID = session.id
        activeCodexAgentSessionID = session.id
        let baselinePasteboardChangeCount = NSPasteboard.general.changeCount
        let forceClipboardSelection = Self.shouldForceAgentClipboardSelection(for: trimmedPrompt)
        OpenClickyApplicationUsageLogStore.shared.recordFrontmostApplication(source: "agent_prompt")
        Task {
            // Agent allocation should not make the main OpenClicky panel feel
            // frozen. Stage the dock card synchronously, then let the run loop
            // render pending panel/window changes before screen-context capture
            // and Codex process startup begin.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))

            // A freehand selection is scoped to the voice turn that explicitly
            // requested it. Typed HUD and delayed background prompts must never
            // inherit a prior sensitive crop.
            if attachPendingVoiceCircle,
               includeScreenContext,
               handoffQueue.allSatisfy({ !$0.selection.hasFreehandPath }),
               let circleHandoff = await consumePendingCircleSelectHandoff(instruction: trimmedPrompt) {
                queueHandoffRegion(selection: circleHandoff.selection, imageData: circleHandoff.imageData)
            }

            let screenContext = includeScreenContext ? await prepareAgentScreenContextForNextTurn(
                minimumPasteboardChangeCount: baselinePasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ) : nil
            if !includeScreenContext {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "internal",
                    event: "openclicky.agent_screen_context.skipped",
                    fields: [
                        "reason": "text_only_agent_turn",
                        "sessionID": session.id.uuidString,
                        "instructionLength": trimmedPrompt.count
                    ]
                )
            }
            session.submitPromptFromUI(trimmedPrompt, screenContext: screenContext)
        }
    }

    func interruptCurrentVoiceResponse() {
        currentVoiceResponseCancellationHandler?("interrupted")
        currentVoiceResponseCancellationHandler = nil
        currentVoiceResponseRequestID = nil
        currentVoiceResponseCompletionToken = nil
        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentResponseTaskToken = nil
        realtimeBidirectionalVoiceTask?.cancel()
        realtimeBidirectionalVoiceTask = nil
        realtimeBidirectionalVoiceTurnGeneration &+= 1
        isRealtimeBidirectionalVoiceCaptureActive = false
        isRealtimeBidirectionalVoiceInputReady = false
        pendingRealtimeBidirectionalFinishSource = nil
        codexVoiceSession.cancelActiveTurn(reason: "voice_response_interrupted")
        openAIRealtimeSpeechClient.cancelBidirectionalVoiceTurn()
        voiceTTSClient.cancelBidirectionalVoiceTurn()
        openAIRealtimeSpeechClient.stopPlayback()
        deepgramVoiceAgentClient.stopPlayback()
        voiceTTSClient.stopPlayback()
        clearVoiceResponseCaption()
        if !buddyDictationManager.isDictationInProgress {
            currentAudioPowerLevel = 0
            voiceState = .idle
        }
    }

    private func prepareAgentScreenContextForNextTurn(
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) async -> CodexAgentScreenContext? {
        // Drop stale circle-while-talking regions so an older hold cannot
        // leak into an unrelated agent turn.
        let circleHandoffMaxAge: TimeInterval = 45
        let now = Date()
        handoffQueue.removeAll { queued in
            queued.selection.hasFreehandPath
                && now.timeIntervalSince(queued.queuedAt) > circleHandoffMaxAge
        }

        if !handoffQueue.isEmpty {
            let queuedRegions = handoffQueue
            do {
                let context = try writeQueuedHandoffScreenContext(
                    queuedRegions,
                    minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                    forceClipboardSelection: forceClipboardSelection
                )
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
                    return try writeBackgroundComputerUseScreenContext(
                        capture,
                        minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                        forceClipboardSelection: forceClipboardSelection
                    )
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
                    return try writeNativeComputerUseScreenContext(
                        capture,
                        minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                        forceClipboardSelection: forceClipboardSelection
                    )
                } catch {
                    print("OpenClicky Agent Mode: native CUA Swift focused-window context unavailable: \(error)")
                }
            }

            let captures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
            return try writeCapturedScreenContext(
                captures,
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            )
        } catch {
            print("OpenClicky Agent Mode: current screen context unavailable: \(error)")
            return nil
        }
    }

    private func writeQueuedHandoffScreenContext(
        _ queuedRegions: [HandoffQueuedRegionScreenshot],
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) throws -> CodexAgentScreenContext {
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let attachments = try queuedRegions.enumerated().map { index, queuedRegion in
            let fileURL = directory.appendingPathComponent("\(batchID)-handoff-\(index + 1).jpg", isDirectory: false)
            try queuedRegion.imageData.write(to: fileURL, options: .atomic)

            let rect = queuedRegion.selection.captureRect
            let comment = queuedRegion.selection.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            var noteParts: [String] = [
                "Selected region x:\(Int(rect.minX)) y:\(Int(rect.minY)) width:\(Int(rect.width)) height:\(Int(rect.height))."
            ]
            if queuedRegion.selection.hasFreehandPath {
                noteParts.append(
                    "User freehand-circled this region while speaking (\(queuedRegion.selection.pathPoints.count) path points)."
                )
            }
            let ambient = queuedRegion.selection.ambientSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ambient.isEmpty {
                noteParts.append(ambient)
            }
            if !comment.isEmpty {
                noteParts.append("User note / instruction: \(comment)")
            }

            return CodexAgentScreenContextAttachment(
                label: queuedRegion.selection.hasFreehandPath
                    ? "Circled handoff region \(index + 1)"
                    : "Queued handoff region \(index + 1)",
                fileURL: fileURL,
                note: noteParts.joined(separator: " ")
            )
        }

        let queuedNotes = queuedRegions
            .compactMap { $0.selection.comment.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return CodexAgentScreenContext(
            source: queuedRegions.contains(where: { $0.selection.hasFreehandPath })
                ? "circled screen handoff"
                : "queued screen handoff",
            capturedAt: Date(),
            selectedText: resolveSelectedText(
                from: queuedNotes,
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ),
            attachments: attachments
        )
    }

    private func writeNativeComputerUseScreenContext(
        _ capture: OpenClickyComputerUseWindowCapture,
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) throws -> CodexAgentScreenContext {
        OpenClickyApplicationUsageLogStore.shared.recordApplication(
            name: capture.window.owner,
            bundleIdentifier: capture.window.bundleIdentifier,
            source: "native_cua_agent_context"
        )
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let fileURL = directory.appendingPathComponent("\(batchID)-cua-swift-window.jpg", isDirectory: false)
        try capture.imageData.write(to: fileURL, options: .atomic)

        return CodexAgentScreenContext(
            source: "native CUA Swift focused-window context",
            capturedAt: Date(),
            selectedText: readSelectedTextForAgentContext(
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ),
            attachments: [
                CodexAgentScreenContextAttachment(
                    label: capture.label,
                    fileURL: fileURL,
                    note: capture.agentContextNote
                )
            ]
        )
    }

    private func writeBackgroundComputerUseScreenContext(
        _ capture: OpenClickyBackgroundComputerUseWindowCapture,
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) throws -> CodexAgentScreenContext {
        OpenClickyApplicationUsageLogStore.shared.recordApplication(
            name: capture.appName,
            bundleIdentifier: capture.bundleID,
            source: "background_computer_use_agent_context"
        )
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let fileURL = directory.appendingPathComponent("\(batchID)-background-computer-use-window.jpg", isDirectory: false)
        try capture.imageData.write(to: fileURL, options: .atomic)

        return CodexAgentScreenContext(
            source: "Background Computer Use focused-window context",
            capturedAt: Date(),
            selectedText: readSelectedTextForAgentContext(
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ),
            attachments: [
                CodexAgentScreenContextAttachment(
                    label: capture.label,
                    fileURL: fileURL,
                    note: capture.agentContextNote
                )
            ]
        )
    }

    func writeCapturedScreenContext(
        _ captures: [CompanionScreenCapture],
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) throws -> CodexAgentScreenContext {
        let directory = try createAgentScreenContextDirectory()
        let batchID = Self.agentContextBatchID()
        let attachments = try captures.enumerated().map { index, capture in
            let suffix = capture.isCursorScreen ? "primary" : "secondary-\(index + 1)"
            let fileURL = directory.appendingPathComponent("\(batchID)-\(suffix).jpg", isDirectory: false)
            try capture.imageData.write(to: fileURL, options: .atomic)
            OpenClickyApplicationUsageLogStore.shared.recordApplication(
                name: capture.appName,
                bundleIdentifier: capture.bundleIdentifier,
                source: "agent_screen_context"
            )

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
            selectedText: readSelectedTextForAgentContext(
                minimumPasteboardChangeCount: minimumPasteboardChangeCount,
                forceClipboardSelection: forceClipboardSelection
            ),
            attachments: attachments
        )
    }

    private func readSelectedTextForAgentContext(
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) -> String? {
        let selection = readSelectedTextFromPasteboard(
            minimumChangeCount: minimumPasteboardChangeCount,
            allowUnchangedPasteboard: forceClipboardSelection
        )
        guard let selection else { return nil }
        return selection
    }

    private func resolveSelectedText(
        from notes: [String],
        minimumPasteboardChangeCount: Int,
        forceClipboardSelection: Bool = false
    ) -> String? {
        let cleanedNotes = notes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let first = cleanedNotes.first {
            return first
        }

        return readSelectedTextForAgentContext(
            minimumPasteboardChangeCount: minimumPasteboardChangeCount,
            forceClipboardSelection: forceClipboardSelection
        )
    }

    private func readSelectedTextFromPasteboard(
        minimumChangeCount: Int,
        allowUnchangedPasteboard: Bool = false
    ) -> String? {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        guard allowUnchangedPasteboard || currentChangeCount > minimumChangeCount else { return nil }
        guard let rawText = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty else {
            return nil
        }

        let compact = rawText.replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(1_500))
    }

    static func shouldForceAgentClipboardSelection(for prompt: String) -> Bool {
        let normalized = prompt
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        guard normalized.contains("clipboard") || normalized.contains("pasteboard") else {
            return false
        }

        let explicitClipboardUsePattern = #"\b(?:take|pull|use|read|get|grab|fetch|bring|copy|paste|include|attach)\b.{0,40}\b(?:my|the)?\s*(?:clipboard|pasteboard)\b|\bfrom\s+(?:my|the)\s+(?:clipboard|pasteboard)\b"#
        return normalized.range(of: explicitClipboardUsePattern, options: .regularExpression) != nil
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

    private func agentDockTargetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screen(containingOrNearestTo: mouseLocation)
    }

    func pointAtPermissionDragAssistant() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screen(containingOrNearestTo: mouseLocation)
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
        let targetScreen = NSScreen.screen(containingOrNearestTo: mouseLocation)
        guard let targetScreen else { return }
        agentDockWindowManager.show(
            companionManager: self,
            onScreen: targetScreen,
            position: agentParkingPosition
        )
    }

    func testVoiceResponseCaptionPlayback() {
        let line = "This is OpenClicky's caption playback test. The selected caption font should show beside the cursor."
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: line,
            contextTitle: "Caption playback test"
        )
        speakShortSystemResponse(line)
        updateVoiceResponseCaption(line, force: true)
        let currentCaption = cursorOverlayState.externalPrimaryCaptionText
        externalProxyClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_500_000_000)
            await MainActor.run {
                guard let self, self.cursorOverlayState.externalPrimaryCaptionText == currentCaption else { return }
                self.clearVoiceResponseCaption()
            }
        }
    }

    func updateVoiceResponseCaption(_ text: String, force: Bool = false) {
        guard force || voiceResponseCaptionsEnabled else { return }
        let caption = Self.voiceResponseCaptionText(from: text)
        guard !caption.isEmpty else { return }
        externalProxyClearTask?.cancel()
        externalProxyClearTask = nil
        showCursorOverlayIfAvailable()
        cursorOverlayState.externalPrimaryCaptionText = caption
        cursorOverlayState.externalPrimaryCaptionAccentHex = nil
    }

    private func clearVoiceResponseCaption() {
        externalProxyClearTask?.cancel()
        externalProxyClearTask = nil
        cursorOverlayState.externalPrimaryCaptionText = nil
        cursorOverlayState.externalPrimaryCaptionAccentHex = nil
    }

    func scheduleVoiceResponseCaptionClear(after delay: TimeInterval = 2.2) {
        let currentCaption = cursorOverlayState.externalPrimaryCaptionText
        guard currentCaption?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        externalProxyClearTask?.cancel()
        externalProxyClearTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0.1, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self, self.cursorOverlayState.externalPrimaryCaptionText == currentCaption else { return }
                self.clearVoiceResponseCaption()
            }
        }
    }

    private static func voiceResponseCaptionText(from text: String) -> String {
        let parsed = parsePointingCoordinates(from: text).spokenText
        let singleLine = parsed
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxCharacters = 260
        guard singleLine.count > maxCharacters else { return singleLine }

        let endIndex = singleLine.index(singleLine.startIndex, offsetBy: maxCharacters)
        let prefix = String(singleLine[..<endIndex])
        if let sentenceBreak = prefix.lastIndex(where: { ".!?".contains($0) }), sentenceBreak > prefix.startIndex {
            return String(prefix[...sentenceBreak]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func speakShortSystemResponse(
        _ text: String,
        interruptExisting: Bool = true,
        route: String? = nil,
        timing: OpenClickyRequestTiming? = nil,
        executionStartedAt: Date? = nil,
        extra: [String: Any] = [:]
    ) {
        if interruptExisting {
            interruptCurrentVoiceResponse()
        }
        let responseTaskToken = UUID()
        currentResponseTaskToken = responseTaskToken
        currentResponseTask = Task {
            defer { self.clearCurrentResponseTask(ifMatches: responseTaskToken) }
            self.voiceState = .processing
            let ttsStartedAt = Date()
            var didMarkAudioStarted = false
            do {
                try await voiceTTSClient.speakText(text) {
                    self.voiceState = .responding
                    guard let route, !didMarkAudioStarted else { return }
                    didMarkAudioStarted = true
                    var fields = extra
                    fields["executor"] = "tts"
                    fields["executionMethod"] = self.activeTTSExecutionMethodSpeakText
                    fields["controller"] = self.activeTTSControllerName
                    fields["spokenTextLength"] = text.count
                    self.markRequestStageCompleted(
                        route: route,
                        stage: "tts_audio_started",
                        stageStartedAt: ttsStartedAt,
                        timing: timing,
                        extra: fields
                    )
                }

                self.scheduleVoiceResponseCaptionClear()

                if let route {
                    var stageFields = extra
                    stageFields["executor"] = "tts"
                    stageFields["executionMethod"] = self.activeTTSExecutionMethodSpeakText
                    stageFields["controller"] = self.activeTTSControllerName
                    stageFields["spokenTextLength"] = text.count
                    self.markRequestStageCompleted(
                        route: route,
                        stage: "tts_playback_finished",
                        stageStartedAt: ttsStartedAt,
                        timing: timing,
                        extra: stageFields
                    )
                    var completionFields = extra
                    completionFields["spokenTextLength"] = text.count
                    completionFields["audioPlaybackState"] = Self.voiceResponseCompletionAudioPlaybackState(
                        spokenText: text,
                        playbackFinished: true
                    )
                    self.markRequestCompleted(
                        route: route,
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        extra: completionFields
                    )
                }
            } catch {
                guard !Self.isExpectedCancellation(error) else {
                    if let route {
                        var fields = extra
                        fields["cancelledAt"] = "tts"
                        fields["spokenTextLength"] = text.count
                        fields["audioPlaybackState"] = Self.voiceResponseCompletionAudioPlaybackState(
                            spokenText: text,
                            playbackFinished: false
                        )
                        self.markRequestCompleted(
                            route: route,
                            executionStartedAt: executionStartedAt,
                            timing: timing,
                            status: "cancelled",
                            extra: fields
                        )
                    }
                    self.clearVoiceResponseCaption()
                    return
                }
                self.clearVoiceResponseCaption()
                speakResponseFailureFallback(error)
                if let route {
                    var stageFields = extra
                    stageFields["executor"] = "tts"
                    stageFields["executionMethod"] = self.activeTTSExecutionMethodSpeakText
                    stageFields["controller"] = self.activeTTSControllerName
                    stageFields["error"] = error.localizedDescription
                    self.markRequestStageCompleted(
                        route: route,
                        stage: didMarkAudioStarted ? "tts_playback_finished" : "tts_audio_started",
                        stageStartedAt: ttsStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: stageFields
                    )
                    var completionFields = extra
                    completionFields["error"] = error.localizedDescription
                    self.markRequestCompleted(
                        route: route,
                        executionStartedAt: executionStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: completionFields
                    )
                }
            }

            if !Task.isCancelled {
                self.lastVoiceInteractionCompletedAt = Date()
                self.voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s), and when the user has enabled camera context you may also receive a camera image labeled as such. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    YOUR JOB IS NARROW. you only do these things:
    1. POINT, HIGHLIGHT, and ANNOTATE things on the user's screen using OpenClicky's private visual-guidance control output.
    2. GIVE ADVICE, EXPLAIN, and ANSWER QUESTIONS conversationally — including conceptual coding questions, walkthroughs, "what does this mean", "how would i", etc.
    3. SEARCH THE WEB conversationally when the user asks. answer from your own general knowledge; if the user explicitly wants live/current data (today's weather, latest price, breaking news), give a brief handoff-style acknowledgement; OpenClicky routes that kind of task to Agent Mode.
    4. ROUTE WORK NATURALLY — simple conversational help stays in voice, direct computer-control is handled by OpenClicky's computer-use path, and concrete file/code/research/settings/log work is handed to Agent Mode only when the user is asking for real tool work rather than talking through an idea.

    YOU DO NOT, EVER:
    - run code, run commands, run shell, run terminal, run python, run scripts
    - read, write, edit, create, move, delete, rename, organize, or inspect files or folders on disk
    - modify settings, config, memory, skills, logs, soul.md, or any OpenClicky state
    - perform any filesystem, git, build, install, or refactor work
    - take any local action beyond pointing at or drawing temporary guidance overlays on things on screen

    keep the user's normal conversation in this voice lane. if they are reflecting, brainstorming, asking whether something is possible, saying "i like this", "i want it to feel like this", "could we", or "can we make sure", answer conversationally first. don't turn that into background work unless they clearly ask for an agent, a direct computer action, or a concrete change that truly needs tools.

    if the user asks you to do anything in the "DO NOT" list and OpenClicky has not already routed it before you see the turn, be honest that no action has started. do not say "i’ll take care of that in the background", "on it", or "starting an agent" unless the app has actually routed the turn to Agent Mode or direct computer-use before it reaches you. say briefly: "that needs OpenClicky's agent route, but it didn't start from this voice turn."

    when the user clearly mentions "agent" / "start an agent" / "spin up an agent" / "ask an agent", or when the app has already decided the task needs Agent Mode, your job is just to confirm briefly: "on it, starting an agent for that."

    response style:
    - default to one or two sentences. be direct and dense. sound like a capable coworker over the user's shoulder, not a formal report. if the user asks you to explain more or go deeper, give a thorough explanation with no length cap — but still no file edits, no commands, just words.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullets, markdown, headings, tables, or code blocks.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what code does conversationally.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize it for spoken context, but do not silently reuse that screen for visual guidance if the target is in a different image.
    - if you receive a camera image, use it for real visual understanding: describe objects, people, scene context, visible text, labels, products, documents, warnings, and important information when relevant. for lookup-style requests, identify likely names and useful search terms from the image; do not claim live web browsing happened unless OpenClicky routed the task to Agent Mode.
    - don't end with dead-end yes/no questions ("want me to explain more?"). when it fits, plant a seed — mention something bigger or related they could try.

    visual guidance:
    you have a small blue triangle cursor that can fly to and point at things on screen, and temporary drawing overlays that can highlight rectangles or draw short freehand scribbles. use them only when the user is asking for guidance on the current visible screen, the target is visibly present, and the target is directly relevant to the user's current question, instruction, or next step. if the user is merely discussing OpenClicky's behavior, routing, prompts, or how highlighting should work, answer conversationally and use [POINT:none].

    screen calibration:
    if the user says "start screen calibration", "enter calibration mode", "calibrate this display", "calibrate the screen", "calibrate our screens", "let's calibrate", or similar, run an automatic calibration-and-validation sequence instead of picking a random target. first, inspect the screenshot and locate stable known anchors near the screen corners: Finder/Dock or menu Finder at the left, Trash/Dustbin at the lower right when visible, Apple menu at the upper left, and time/clock at the upper right. draw a small rectangle around the current anchor with a label containing both the target name and "calibration anchor", for example "Finder icon calibration anchor". keep the spoken wording brief: say which anchor OpenClicky is sampling automatically and which anchor is next. do not ask the user to move OpenClicky's square, move the calibration anchor, put their pointer anywhere, or say "mark it"; emitting the calibration rectangle is the sample, and OpenClicky records the screenshot-to-display warp-map sample automatically for future POINT, RECT, and SCRIBBLE overlays. after the initial anchors, continue in interactive voice validation mode: choose a real visible UI target, point or rectangle it, announce what OpenClicky thinks it selected, and ask in a concrete "THIS" form, such as "okay, is THIS the Xcode icon?", "is THIS the close button of the Xcode window?", or "is THIS the search field?". also support paired-pointing checks: the user may say "i am going to point to the Finder button, can you do the same"; in that case OpenClicky should point to its predicted Finder button too, then compare the user's real cursor/buddy point with OpenClicky's predicted point as a warp-map validation sample. build the map across the screen, not from one corner only: after one corner anchor, choose another stable target on the opposite corner or opposite side, then sample a few interior anchors between them. cover both axes deliberately — left-to-right / right-to-left for horizontal scale and top-to-bottom / bottom-to-top for vertical scale — and store the samples in the screenshot coordinate space OpenClicky actually captured at its current resolution, then map them back to display points for overlays, so the warp map can correct translation, scale, skew, and local drift. once enough horizontal and vertical samples are collected, apply that calibrated transform to future pointing regardless of what app or content is currently on screen. the user's real cursor/buddy position is the ground-truth pointer: if they say it is wrong, ask them to point at the correct item and say "this one" or "i'm pointing at it", then use that cursor position as another warp-map correction sample. if the user says no or says it is off, use the next validation target or correction turn rather than ending calibration.

    your default should be: point at the exact visible target only when it clearly helps answer what the user is asking now, such as a named button, visible text, current file, prompt, setting, menu, error, or UI region they are referring to. do not point at generic, nearby, decorative, stale, or merely available UI.

    use [POINT:none] when the answer is conceptual, the user is brainstorming, no visible target helps, the requested item is not visible, or you are not confident the target is the right one. if you're unsure, do not guess; answer briefly in words or ask for the missing context.

    if visual guidance is needed, append exactly one private control tag at the very end of your response, AFTER the natural spoken sentence. this tag is not speech; OpenClicky strips it and emits the actual cursor or overlay as a separate visual-guidance action. never describe the tag, never say the coordinates aloud, and never include a visual tag in the middle of normal conversation. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward. when more than one screen image is attached, every POINT, RECT, and SCRIBBLE tag must include the exact :screenN suffix for the image you measured from, even if it is screen one or the primary focus screen. if you cannot tell which screen image contains the exact target, use [POINT:none] instead of guessing.

    point format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). with a single screen image, you may omit the screen number. with multiple screen images, always append :screenN where N is the screen number from the image label, for example [POINT:420,310:save button:screen2]. this is important — without the screen number, the cursor can point at the wrong display.

    rectangle format: [RECT:x,y,width,height:label] to draw a temporary rectangle around a visible region. use this when the user asks to highlight, box, outline, show the area, or when a region is clearer than a single point. x,y,width,height are integer screenshot pixels with top-left origin. with multiple screen images, always append :screenN, for example [RECT:120,80,300,140:error panel:screen2].

    scribble format: [SCRIBBLE:x1,y1;x2,y2;x3,y3:label] to draw a short temporary freehand path over visible content. use this when the user asks you to draw, circle loosely, trace, or mark a non-rectangular path. use at least two points. with multiple screen images, always append :screenN.

    append at most one private visual control tag at the very end of your response. choose POINT, RECT, or SCRIBBLE — never combine them in the same response. treat this as a separate tool/control output, not as wording for the user.

    if visual guidance wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks to highlight an error visible on screen: "that's the error block you're looking for — it starts in the terminal output on the right. [RECT:760,115,420,190:error block]"
    - user asks to draw over a visible path: "that flight path arcs across the top of the scene here. [SCRIBBLE:430,160;500,135;570,145;640,190:flight path]"
    - user discusses how OpenClicky should highlight things: "right — highlights should be emitted as a separate visual action, not spoken as rectangle instructions. [POINT:none]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    private static let companionRealtimeVoiceSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you through OpenClicky's realtime voice path. your reply is spoken directly as audio, so write only the natural words the user should hear. this is an ongoing conversation — you remember everything they've said before.

    YOUR JOB IS NARROW. you only do these things:
    1. GIVE ADVICE, EXPLAIN, and ANSWER QUESTIONS conversationally — including conceptual coding questions, walkthroughs, "what does this mean", "how would i", etc.
    2. SEARCH THE WEB conversationally when the user asks. answer from your own general knowledge; if the user explicitly wants live/current data (today's weather, latest price, breaking news), give a brief handoff-style acknowledgement; OpenClicky routes that kind of task to Agent Mode.
    3. ROUTE WORK NATURALLY — simple conversational help stays in voice, direct computer-control is handled by OpenClicky's computer-use path, and concrete file/code/research/settings/log work should be handed to Agent Mode when the user is asking OpenClicky to actually carry it out rather than merely talking through an idea.

    YOU DO NOT, EVER:
    - run code, run commands, run shell, run terminal, run python, run scripts
    - read, write, edit, create, move, delete, rename, organize, or inspect files or folders on disk
    - modify settings, config, memory, skills, logs, soul.md, or any OpenClicky state
    - perform any filesystem, git, build, install, or refactor work
    - include any control tags, point tags, coordinate tags, markdown, brackets, or hidden routing markers in your answer

    keep the user's normal conversation in this voice lane. if they are reflecting, brainstorming, or asking a pure capability question, answer conversationally first. but if they are asking OpenClicky to actually do deeper tool work — for example fix code, inspect logs, change settings, research something current, or work on files — call the background-agent tool even if they did not explicitly say the word "agent".

    if the user asks you to do anything in the "DO NOT" list and it is concrete tool work, do not explain that an agent would be needed — call the background-agent tool. only stay conversational when the user is discussing whether something is possible, reflecting on design, or otherwise not asking you to execute the work yet.

    when the user clearly mentions "agent" / "start an agent" / "spin up an agent" / "ask an agent", or when you decide the task needs Agent Mode, call the background-agent tool instead of talking about the route. if you do speak after routing, keep it to a brief acknowledgement like "on it."

    response style:
    - default to one or two sentences. be direct and dense. sound like a capable coworker over the user's shoulder, not a formal report. if the user asks you to explain more or go deeper, give a thorough explanation with no length cap — but still no file edits, no commands, just words.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullets, markdown, headings, tables, or code blocks.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what code does conversationally.
    - don't end with dead-end yes/no questions ("want me to explain more?"). when it fits, plant a seed — mention something bigger or related they could try.

    realtime output rule:
    because this path speaks audio directly, never say or output OpenClicky's internal point-control syntax. do not say "point none", "point control", "open bracket point", coordinates, or anything resembling [POINT:none]. if a visual target would help, describe it naturally in words instead.
    """

    private func runtimeStorageContextForVoicePrompt() -> String {
        let logs = OpenClickyMessageLogStore.shared
        return """
        OpenClicky runtime storage:
        - runtime map: \(codexHomeManager.runtimeMapFile.path)
        - soul/persona: \(codexHomeManager.soulFile.path)
        - codex home: \(codexHomeManager.codexHomeDirectory.path)
        - persistent memory (current): \(codexHomeManager.persistentMemoryFile.path)
        - persistent memory archives: \(codexHomeManager.persistentMemoryArchivesDirectory.path)
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

    private func currentAppSkillContextPrompt() -> String {
        guard let context = OpenClickyAppSkillContext.contextForFrontmostApplication() else {
            return "No app-specific skill context is active."
        }
        return context.promptFragment
    }

    func currentVoiceResponseSystemPrompt() -> String {
        let memoryContext = codexHomeManager.persistentMemoryContext()
        return """
        \(Self.companionVoiceResponseSystemPrompt)
        \(inlineWebSearchCapabilityPromptIfAvailable())
        \(currentAppSkillContextPrompt())
        \(visualGuidanceCorrectionLearningPrompt())

        \(runtimeStorageContextForVoicePrompt())

        persistent memory:
        read this as durable user/project context. do not say you cannot remember outside the conversation; use this memory.

        \(memoryContext)
        """
    }

    private func visualGuidanceCorrectionLearningPrompt() -> String {
        let calibrationSummary = Self.visualGuidanceCalibrationPromptSummary()
        guard !calibrationSummary.isEmpty else { return "" }
        return """

        visual guidance calibration memory:
        calibration is automatic: when a calibration rectangle is emitted for a known screen anchor, OpenClicky compares that detected anchor with the expected corner position and records a screenshot-to-display warp-map sample. Do not ask the user to move OpenClicky's square, move the calibration anchor, put their pointer anywhere, or say "mark it". After anchors are sampled, continue with voice validation by selecting visible UI targets and asking concrete "THIS" confirmation questions, for example "is THIS the Xcode icon?" or "is THIS the close button?". The user's cursor/buddy location is the ground-truth pointer when they point at the correct item and say "this one" or "I'm pointing at it", adding another warp-map correction sample. Paired-pointing checks like "I am going to point to the Finder button, can you do the same" mean OpenClicky should point to its predicted target too, then compare both points. The warp-map validation should include opposite-side/corner targets plus interior anchors, not just one corner; sample horizontally and vertically in OpenClicky's captured screenshot coordinate space at its current resolution, then map back to display points so OpenClicky can correct scale, skew, and local drift; once calibrated, future pointing should use that transform regardless of the current app/content. Existing learned coordinate calibration may still be applied. \(calibrationSummary)
        """
    }

    private static let visualGuidanceCalibrationDefaultsPrefix = "openclicky.visualGuidance.coordinateCalibration"

    static func isVisualGuidanceCalibrationCaption(_ caption: String?) -> Bool {
        guard let caption else { return false }
        let normalized = caption
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return normalized.contains("calibration")
            || normalized.contains("calibrate")
            || normalized.contains("anchor")
    }

    private static func visualGuidanceCalibrationScreenKey(for displayFrame: CGRect) -> String {
        [
            Int(displayFrame.minX.rounded()),
            Int(displayFrame.minY.rounded()),
            Int(displayFrame.width.rounded()),
            Int(displayFrame.height.rounded())
        ]
        .map(String.init)
        .joined(separator: "_")
    }

    private static func visualGuidanceCalibrationDefaultsKey(for displayFrame: CGRect, suffix: String) -> String {
        "\(visualGuidanceCalibrationDefaultsPrefix).\(visualGuidanceCalibrationScreenKey(for: displayFrame)).\(suffix)"
    }

    static func visualGuidanceCalibrationOffset(for displayFrame: CGRect) -> CGSize {
        let defaults = UserDefaults.standard
        let countKey = visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: "count")
        guard defaults.integer(forKey: countKey) > 0 else { return .zero }
        let offset = CGSize(
            width: defaults.double(forKey: visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: "offsetX")),
            height: defaults.double(forKey: visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: "offsetY"))
        )
        guard isPlausibleVisualGuidanceCalibrationDelta(offset, for: displayFrame) else {
            return .zero
        }
        return offset
    }

    private static func maximumVisualGuidanceCalibrationDelta(for displayFrame: CGRect) -> CGSize {
        CGSize(
            width: max(48, min(160, displayFrame.width * 0.08)),
            height: max(48, min(160, displayFrame.height * 0.08))
        )
    }

    private static func isPlausibleVisualGuidanceCalibrationDelta(_ delta: CGSize, for displayFrame: CGRect) -> Bool {
        let maximum = maximumVisualGuidanceCalibrationDelta(for: displayFrame)
        return abs(delta.width) <= maximum.width
            && abs(delta.height) <= maximum.height
    }

    @discardableResult
    private static func updatedVisualGuidanceCalibrationOffset(
        delta: CGSize,
        for displayFrame: CGRect
    ) -> (screenKey: String, offset: CGSize, count: Int) {
        let defaults = UserDefaults.standard
        let countKey = visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: "count")
        let offsetXKey = visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: "offsetX")
        let offsetYKey = visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: "offsetY")
        let storedCount = defaults.integer(forKey: countKey)
        let storedOffset = CGSize(
            width: defaults.double(forKey: offsetXKey),
            height: defaults.double(forKey: offsetYKey)
        )
        let oldCount = isPlausibleVisualGuidanceCalibrationDelta(storedOffset, for: displayFrame)
            ? storedCount
            : 0
        let oldOffset = oldCount > 0 ? storedOffset : .zero
        let newCount = oldCount + 1
        let newOffset = CGSize(
            width: ((oldOffset.width * Double(oldCount)) + delta.width) / Double(newCount),
            height: ((oldOffset.height * Double(oldCount)) + delta.height) / Double(newCount)
        )
        defaults.set(newCount, forKey: countKey)
        defaults.set(newOffset.width, forKey: offsetXKey)
        defaults.set(newOffset.height, forKey: offsetYKey)
        return (visualGuidanceCalibrationScreenKey(for: displayFrame), newOffset, newCount)
    }

    private static func visualGuidanceCalibrationPromptSummary() -> String {
        let defaults = UserDefaults.standard
        let summaries = NSScreen.screens.compactMap { screen -> String? in
            let count = defaults.integer(forKey: visualGuidanceCalibrationDefaultsKey(for: screen.frame, suffix: "count"))
            guard count > 0 else { return nil }
            let offset = visualGuidanceCalibrationOffset(for: screen.frame)
            return " screen \(visualGuidanceCalibrationScreenKey(for: screen.frame)) has \(count) calibration sample\(count == 1 ? "" : "s") and applies an offset of x \(Int(offset.width.rounded())), y \(Int(offset.height.rounded())) points."
        }
        guard !summaries.isEmpty else { return "" }
        return " coordinate calibration is active:\(summaries.joined())"
    }

    private static func visualGuidanceCalibrationSampleAcknowledgement(for caption: String) -> String {
        let normalized = caption
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        if normalized.contains("finder") {
            return "got the Finder anchor. next, ask OpenClicky to calibrate the Trash or Dustbin anchor."
        }
        if normalized.contains("trash") || normalized.contains("dustbin") || normalized.contains("bin") {
            return "got the Trash anchor. next, ask OpenClicky to calibrate the Apple menu anchor."
        }
        if normalized.contains("apple") {
            return "got the Apple menu anchor. next, ask OpenClicky to calibrate the time or clock anchor."
        }
        if normalized.contains("time") || normalized.contains("clock") {
            return "got the time anchor. that gives OpenClicky the four screen anchors."
        }
        return "got that calibration anchor. repeat with the next screen anchor when you're ready."
    }

    /// Lane-aware web-search capability note. Only the Claude Agent SDK voice
    /// lane has the WebSearch/WebFetch tools enabled (see bridge.mjs), so only
    /// that lane should be told it can search inline. Every other lane keeps
    /// the shared prompt's hand-off-to-Agent-Mode behavior for live data.
    private func inlineWebSearchCapabilityPromptIfAvailable() -> String {
        let voiceModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        guard voiceModel.provider == .anthropic,
              claudeAgentSDKAPI != nil else {
            return ""
        }
        return """

        web search is available to you on this turn. when the user needs live or current information (today's weather, latest price, recent news, scores, anything past your training), search the web yourself and answer inline in a sentence or two with what you found. do not hand this off to Agent Mode and do not say a background agent will do it — you can answer it now.
        """
    }


    func currentRealtimeVoiceSystemPrompt() -> String {
        let memoryContext = codexHomeManager.persistentMemoryContext()
        return """
        \(Self.companionRealtimeVoiceSystemPrompt)

        \(currentRealtimeRoutingContextPrompt())

        \(currentAppSkillContextPrompt())

        \(runtimeStorageContextForVoicePrompt())

        persistent memory:
        read this as durable user/project context. do not say you cannot remember outside the conversation; use this memory.

        \(memoryContext)
        """
    }

    private func currentRealtimeRoutingContextPrompt() -> String {
        let voiceModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        let computerUseModel = OpenClickyModelCatalog.computerUseModel(withID: selectedComputerUseModel)
        let backend = selectedComputerUseBackend
        return """
        OpenClicky realtime routing:
        - voice inference model: \(voiceModel.id) (\(voiceModel.label))
        - realtime audio input path: \(activeRealtimeInputPath)
        - selected computer-use backend: \(backend.rawValue) (\(backend.label))
        - selected computer-use model: \(computerUseModel.id) (\(computerUseModel.provider.rawValue), \(computerUseModel.label))
        - background Agent Mode model: \(codexAgentSession.model)
        - keep spoken voice inference on the realtime model. for direct computer-control requests, including app-plus-action commands like "open Spotify and play a track", call OpenClicky's computer-use tool so the app can execute through the selected backend. do not route ordinary app control to Agent Mode just because it has more than one step. for deeper file, code, research, settings, logs, builds, installs, refactors, or long-running work, call the background-agent tool so Agent Mode can run on the full configured model, even when the user did not explicitly say "agent".
        - when background work has several parts, choose the agent shape deliberately: keep tightly coupled work in one background agent, but split into multiple background-agent calls when the user explicitly asks for multiple/separate/parallel agents or the request clearly contains independent workstreams that can run safely side by side.
        - temporary visual guidance is not computer-use and not Agent Mode. if the user asks OpenClicky to point, highlight, draw a rectangle, box an area, circle something, draw around something, scribble, trace, mark, or put a shape around visible screen content, do not say you'll get another system to do it and do not call a routing tool. let OpenClicky's screen-aware voice-response path handle it directly.
        """
    }

    func currentTutorModeSystemPrompt() -> String {
        """
        \(Self.tutorModeSystemPrompt)

        \(currentAppSkillContextPrompt())
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
    append exactly one [POINT:x,y:label] tag at the end only when a visible target is directly relevant to the current coaching step. use [POINT:none] when pointing would not help, the target is not visible, or relevance is uncertain.
    the screenshot labels include pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    if a screen number is present in the image label and the target is not the primary screen, append :screenN.
    """


}

#if DEBUG
extension CompanionManager {
    func setTestAgentDockItems(_ items: [ClickyAgentDockItem]) {
        self.agentDockItems = items
    }
    
    func setTestCodexAgentSessions(_ sessions: [CodexAgentSession]) {
        self.codexAgentSessions = sessions
    }
    
    func setTestHasMicrophonePermission(_ status: Bool) {
        self.hasMicrophonePermission = status
    }
    
    func setTestHasScreenContentPermission(_ status: Bool) {
        self.hasScreenContentPermission = status
    }

    static func testLocalAppOpenTarget(from transcript: String) -> String? {
        localAppOpenRequest(from: transcript)?.appName
    }

    static func testLocalFolderOpenTarget(from transcript: String) -> String? {
        localFolderOpenRequest(from: transcript)?.url.path
    }

    static func testLogEvidenceAnalysisInstruction(from transcript: String) -> String? {
        logEvidenceAnalysisInstruction(from: transcript)
    }

    static func testReminderCountInstruction(from transcript: String) -> String? {
        reminderCountRequest(from: transcript)?.instruction
    }

    static func testNativeKeyPress(from transcript: String) -> (key: String, modifiers: [String])? {
        guard let request = nativeKeyPressRequest(from: transcript) else { return nil }
        return (request.key, request.modifiers)
    }

    static func testWebOpenTarget(from transcript: String) -> (url: String, browserAppName: String?)? {
        guard let request = webOpenRequest(from: transcript) else { return nil }
        return (request.url.absoluteString, request.browserAppName)
    }

    static func testCompositeAppAction(from transcript: String) -> (appName: String, actionText: String)? {
        guard let request = compositeAppActionRequest(from: transcript) else { return nil }
        return (request.appName, request.actionText)
    }

    static func testSpotifyPlaybackQuery(from transcript: String) -> String? {
        guard let request = compositeAppActionRequest(from: transcript),
              request.appName == "Spotify" else { return nil }
        return spotifyPlaybackQuery(from: request.actionText)
    }

    static func testStandaloneSpotifyPlaybackQuery(from transcript: String) -> String? {
        guard let request = standaloneSpotifyPlaybackRequest(from: transcript),
              request.appName == "Spotify" else { return nil }
        return spotifyPlaybackQuery(from: request.actionText)
    }

    static func testSpotifyPlaybackControlAction(from transcript: String) -> String? {
        guard let request = standaloneSpotifyPlaybackRequest(from: transcript),
              request.appName == "Spotify" else { return nil }
        return spotifyPlaybackControlAction(from: request.actionText)?.rawValue
    }

    static func testSystemVolumeControlAction(from transcript: String) -> String? {
        systemVolumeControlAction(from: transcript)?.rawValue
    }

    static func testSpotifySearchPlayExecutionMethods(
        for backend: OpenClickyComputerUseBackendID
    ) -> (started: String, completed: String) {
        let method = spotifySearchPlayExecutionMethod(for: backend)
        return (method, method)
    }

    static func testComputerUsePointingResolver(
        selectedVoiceModelID: String,
        selectedComputerUseModelID: String
    ) -> String {
        computerUsePointingResolver(
            selectedVoiceModelID: selectedVoiceModelID,
            selectedComputerUseModelID: selectedComputerUseModelID
        ).rawValue
    }

    static func testShouldAttachScreenContext(to transcript: String) -> Bool {
        shouldAttachScreenContext(to: transcript)
    }

    static func testIsScreenCalibrationRequest(_ transcript: String) -> Bool {
        isScreenCalibrationRequest(transcript)
    }

    static func testIsVisualGuidanceCalibrationCaption(_ caption: String?) -> Bool {
        isVisualGuidanceCalibrationCaption(caption)
    }

    static func testResetVisualGuidanceCalibration(for displayFrame: CGRect) {
        let defaults = UserDefaults.standard
        ["count", "offsetX", "offsetY"].forEach { suffix in
            defaults.removeObject(forKey: visualGuidanceCalibrationDefaultsKey(for: displayFrame, suffix: suffix))
        }
    }

    static func testUpdateVisualGuidanceCalibrationOffset(delta: CGSize, for displayFrame: CGRect) -> CGSize {
        updatedVisualGuidanceCalibrationOffset(delta: delta, for: displayFrame).offset
    }

    static func testVisualGuidanceCalibrationOffset(for displayFrame: CGRect) -> CGSize {
        visualGuidanceCalibrationOffset(for: displayFrame)
    }

    static func testIsPlausibleVisualGuidanceCalibrationDelta(_ delta: CGSize, for displayFrame: CGRect) -> Bool {
        isPlausibleVisualGuidanceCalibrationDelta(delta, for: displayFrame)
    }

    static func testExpectedVisualGuidanceCalibrationCenter(
        caption: String,
        predictedRect: CGRect,
        screenFrame: CGRect,
        screenshotWidthInPixels: Int? = nil,
        screenshotHeightInPixels: Int? = nil
    ) -> CGPoint? {
        expectedVisualGuidanceCalibrationCenter(
            for: caption,
            predictedRect: predictedRect,
            screenFrame: screenFrame,
            screenshotWidthInPixels: screenshotWidthInPixels,
            screenshotHeightInPixels: screenshotHeightInPixels
        )
    }

    static func testParallelAgentInstructions(from instruction: String) -> [String] {
        parallelAgentInstructions(from: instruction)
    }

    static func testVoiceAgentStartFingerprint(instruction: String, route: String) -> String {
        voiceAgentStartFingerprint(instruction: instruction, route: route)
    }
}
#endif

// MARK: - Extracted voice-routing types
//
// VoiceRouter and SpokenText are top-level `nonisolated` enums extracted out of
// the CompanionManager class so the routing brain is decoupled from the view
// model's @MainActor state and is unit-testable. They live here (rather than in
// their own files) only because this project's Xcode file-system-synchronized
// group does not ingest .swift files created outside Xcode; move them into
// VoiceRouter.swift / SpokenText.swift once those files are added via Xcode's
// New File dialog (which registers them with the target).

/// Pure, side-effect-free classification vocabulary for the voice routing
/// cascade. Everything here operates purely on its `String` arguments.
nonisolated enum VoiceRouter {

    // MARK: Agent-work vocabulary

    static func containsAgentWorkAction(_ normalized: String) -> Bool {
        let actionPattern = #"\b(?:check|look\s+at|take\s+a\s+look|inspect|review|audit|fix|modify|change|update|edit|build|create|make|write|draft|research|search|find|summari[sz]e|organize|clean\s+up|cleanup|test|run|install|compare|read|move|rename|delete|prune|optimi[sz]e|wire|implement|add|remove|route|delegate|ensure|verify|validate|confirm|diagnose|investigate|repair|polish|improve|finish|sort\s+out|deal\s+with|take\s+care\s+of|make\s+sure|look\s+into|figure\s+out)\b"#
        return normalized.range(of: actionPattern, options: .regularExpression) != nil
    }

    static func containsDurableWorkTarget(_ normalized: String) -> Bool {
        let targetPattern = #"\b(?:openclicky|clicky|github|repo|repository|codebase|project|app|settings|preference|preferences|log|logs|memory|skill|skills|desktop|download|downloads|document|documents|folder|folders|file|files|code|diff|git|branch|pull\s+request|pr|issue|issues|bug|test|tests|build|swift|xcode|email|gmail|calendar|spreadsheet|sheet|doc|slides|voice|realtime|computer\s+use|tool|tools|tooling|model|models|routing|route|background|agent\s+mode)\b"#
        return normalized.range(of: targetPattern, options: .regularExpression) != nil
    }

    static func containsFreshResearchRequest(_ normalized: String) -> Bool {
        let researchPattern = #"\b(?:latest|live|price|news|weather|schedule|standings|research|look\s+up|search\s+(?:the\s+)?web|google|browse)\b"#
        return normalized.range(of: researchPattern, options: .regularExpression) != nil
    }

    static func isSensitiveOrDestructiveAgentTaskRequest(_ normalized: String) -> Bool {
        let destructivePattern = #"\b(?:delete|remove|erase|wipe|destroy|drop|revoke|reset|nuke|clear|purge|uninstall|terminate|kill)\b"#
        let broadScopePattern = #"\b(?:all|everything|entire|whole)\b"#
        let destructiveTargetPattern = #"\b(?:file|files|folder|folders|directory|directories|repo|repository|branch|branches|commit|commits|tag|tags|history|database|databases|keychain|account|accounts)\b"#
        let sensitiveTargetsPattern = #"\b(?:account|accounts|credential|credentials|password|passwords|token|tokens|api\s*key|secret|secrets|permission|permissions|auth|ssh|private\s+key|keychain|database|databases|prod|production|system\s+settings)\b"#

        let hasDestructiveVerb = normalized.range(of: destructivePattern, options: .regularExpression) != nil
        let hasBroadScope = normalized.range(of: broadScopePattern, options: .regularExpression) != nil
        let hasDestructiveTarget = normalized.range(of: destructiveTargetPattern, options: .regularExpression) != nil
        let hasSensitiveTarget = normalized.range(of: sensitiveTargetsPattern, options: .regularExpression) != nil

        // Safety policy:
        // - credential/permission/auth targets are always confirmation-worthy.
        // - destructive verbs are confirmation-worthy when aimed at a destructive target
        //   or broad-scope operation.
        return hasSensitiveTarget || (hasDestructiveVerb && (hasBroadScope || hasDestructiveTarget))
    }

    // MARK: Hybrid (do-now + fix-in-background) cues

    static func containsHybridForegroundCue(_ normalized: String) -> Bool {
        let foregroundPattern = #"\b(?:what|why|how|who|when|where|explain|tell\s+me|describe|summari[sz]e|answer|quick\s+(?:answer|thought|view)|what\s+do\s+you\s+think|do\s+you\s+think)\b"#
        return normalized.range(of: foregroundPattern, options: .regularExpression) != nil
    }

    static func containsHybridBackgroundCue(_ normalized: String) -> Bool {
        let backgroundPattern = #"\b(?:background|agent|agents|agent\s+mode|codex|do\s+the\s+work|work\s+on\s+it|take\s+care\s+of\s+it|also\s+(?:fix|implement|patch|research|find|check|review|update|change|build|create)|while\s+you(?:'re|re)?\s+(?:at\s+it|doing\s+that)|combination\s+of\s+the\s+two)\b"#
        return normalized.range(of: backgroundPattern, options: .regularExpression) != nil
    }

    // MARK: Natural / referential background-work cues

    static func containsNaturalBackgroundWorkCue(_ normalized: String) -> Bool {
        let cuePattern = #"\b(?:make\s+sure|ensure|verify|validate|confirm|look\s+into|figure\s+out|sort\s+out|deal\s+with|take\s+care\s+of|get\s+(?:this|that|it|.+?)\s+working|wire\s+(?:up|in)|hook\s+(?:up|in)|set\s+up|finish|polish|improve|repair|diagnose|investigate)\b"#
        if normalized.range(of: cuePattern, options: .regularExpression) != nil {
            return true
        }

        let makeUsePattern = #"\b(?:make|have)\b.{1,80}\b(?:use|using|route|routing|send|sending|call|calling)\b"#
        return normalized.range(of: makeUsePattern, options: .regularExpression) != nil
    }

    static func containsReferentialWorkTarget(_ normalized: String) -> Bool {
        let referencePattern = #"\b(?:this|that|it|here|current\s+(?:file|screen|window|page|repo|repository|project|app)|visible\s+(?:file|code|screen|window|page)|selected\s+(?:text|file|code|region)|the\s+(?:current|visible|selected)\s+(?:thing|part|file|code|screen|window|page)|what\s+we\s+(?:just\s+)?(?:talked|discussed)\s+about|the\s+thing\s+from\s+before)\b"#
        return normalized.range(of: referencePattern, options: .regularExpression) != nil
    }
}

/// Spoken-transcript normalization utilities shared by the routing brain and
/// the rest of the app. Pure, `nonisolated`, side-effect-free. These form a
/// closed cluster: the only functions they call are each other.
nonisolated enum SpokenText {

    /// Lowercased, diacritic-folded, punctuation-stripped, single-spaced form
    /// of a transcript — the canonical surface the routing predicates match.
    static func normalizedSpokenCommandText(_ transcript: String) -> String {
        transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }

    /// Strips leading filler ("hey", "ok clicky", "i said to", "let's try that
    /// again") and trailing punctuation so a raw transcript becomes a clean
    /// command candidate.
    static func normalizedCommandCandidate(from transcript: String) -> String {
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

    /// Reduces a polite agent request ("can you...", "please...", "tell an
    /// agent to...") down to the bare instruction.
    static func normalizedAgentTaskInstruction(from instruction: String) -> String {
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

    static func cleanedAgentTaskInstruction(_ instruction: String) -> String {
        instruction
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
