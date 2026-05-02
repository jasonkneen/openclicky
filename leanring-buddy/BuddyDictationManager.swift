//
//  BuddyDictationManager.swift
//  leanring-buddy
//
//  Shared push-to-talk dictation manager for the help chat and brainstorm buddy.
//  Captures microphone audio with AVAudioEngine, routes it into the active
//  transcription provider, and hands the final draft back to the active input bar.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

enum BuddyPushToTalkShortcut {
    enum ShortcutOption {
        case shiftFunction
        case controlOption
        case shiftControl
        case controlOptionSpace
        case shiftControlSpace

        var displayText: String {
            switch self {
            case .shiftFunction:
                return "shift + fn"
            case .controlOption:
                return "ctrl + option"
            case .shiftControl:
                return "shift + control"
            case .controlOptionSpace:
                return "ctrl + option + space"
            case .shiftControlSpace:
                return "shift + control + space"
            }
        }

        var keyCapsuleLabels: [String] {
            switch self {
            case .shiftFunction:
                return ["shift", "fn"]
            case .controlOption:
                return ["ctrl", "option"]
            case .shiftControl:
                return ["shift", "control"]
            case .controlOptionSpace:
                return ["ctrl", "option", "space"]
            case .shiftControlSpace:
                return ["shift", "control", "space"]
            }
        }

        fileprivate var modifierOnlyFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return [.shift, .function]
            case .controlOption:
                return [.control, .option]
            case .shiftControl:
                return [.shift, .control]
            case .controlOptionSpace, .shiftControlSpace:
                return nil
            }
        }

        fileprivate var spaceShortcutModifierFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return nil
            case .controlOption:
                return nil
            case .shiftControl:
                return nil
            case .controlOptionSpace:
                return [.control, .option]
            case .shiftControlSpace:
                return [.shift, .control]
            }
        }
    }

    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    static let currentShortcutOption: ShortcutOption = .controlOption
    static let pushToTalkKeyCode: UInt16 = 49 // Space
    static let pushToTalkDisplayText = currentShortcutOption.displayText
    static let pushToTalkTooltipText = "push to talk (\(pushToTalkDisplayText))"

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: event.type) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    private static func shortcutEventType(for eventType: NSEvent.EventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        if let modifierOnlyFlags = currentShortcutOption.modifierOnlyFlags {
            guard shortcutEventType == .flagsChanged else { return .none }

            let isShortcutCurrentlyPressed = modifierFlags.contains(modifierOnlyFlags)

            if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
                return .pressed
            }

            if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
                return .released
            }

            return .none
        }

        guard let pushToTalkModifierFlags = currentShortcutOption.spaceShortcutModifierFlags else {
            return .none
        }

        let matchesModifierFlags = modifierFlags.isSuperset(of: pushToTalkModifierFlags)

        if shortcutEventType == .keyDown
            && keyCode == pushToTalkKeyCode
            && matchesModifierFlags
            && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if shortcutEventType == .keyUp
            && keyCode == pushToTalkKeyCode
            && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}

enum BuddyDictationPermissionProblem {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

private enum BuddyDictationStartSource {
    case microphoneButton
    case keyboardShortcut
}

private struct BuddyDictationDraftCallbacks {
    let updateDraftText: (String) -> Void
    let submitDraftText: (String) -> Void
}

@MainActor
final class BuddyDictationManager: NSObject, ObservableObject {
    private static let defaultFinalTranscriptFallbackDelaySeconds: TimeInterval = 2.4
    private static let recordedAudioPowerHistoryLength = 44
    private static let recordedAudioPowerHistoryBaselineLevel: CGFloat = 0.02
    private static let recordedAudioPowerHistorySampleIntervalSeconds: TimeInterval = 0.03

    @Published private(set) var isRecordingFromMicrophoneButton = false
    @Published private(set) var isRecordingFromKeyboardShortcut = false
    @Published private(set) var isKeyboardShortcutSessionActiveOrFinalizing = false
    @Published private(set) var isFinalizingTranscript = false
    @Published private(set) var isPreparingToRecord = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var recordedAudioPowerHistory = Array(
        repeating: BuddyDictationManager.recordedAudioPowerHistoryBaselineLevel,
        count: BuddyDictationManager.recordedAudioPowerHistoryLength
    )
    @Published private(set) var microphoneButtonRecordingStartedAt: Date?
    @Published private(set) var transcriptionProviderDisplayName = ""
    @Published private(set) var transcriptionProviderID = BuddyTranscriptionProviderID.automatic.rawValue
    @Published var lastErrorMessage: String?
    @Published private(set) var currentPermissionProblem: BuddyDictationPermissionProblem?

    var isDictationInProgress: Bool {
        isPreparingToRecord || isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut || isFinalizingTranscript
    }

    var isActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut
    }

    var isMicrophoneButtonActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton
    }

    var isMicrophoneButtonSessionBusy: Bool {
        activeStartSource == .microphoneButton
            && (isPreparingToRecord || isRecordingFromMicrophoneButton || isFinalizingTranscript)
    }

    var needsInitialPermissionPrompt: Bool {
        if transcriptionProvider.requiresSpeechRecognitionPermission {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        }

        return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    private var transcriptionProvider: any BuddyTranscriptionProvider
    private let audioEngine = AVAudioEngine()
    private var hasInstalledInputTap = false
    private var activeTranscriptionSession: (any BuddyStreamingTranscriptionSession)?
    private var activeStartSource: BuddyDictationStartSource?
    private var draftCallbacks: BuddyDictationDraftCallbacks?
    private var draftTextBeforeCurrentDictation = ""
    private var latestRecognizedText = ""
    private var latestNonEmptyRecognizedText = ""
    private var shouldAutomaticallySubmitFinalDraft = false
    private var hasFinishedCurrentDictationSession = false
    private var finalizeFallbackWorkItem: DispatchWorkItem?
    private var pendingStartRequestIdentifier = UUID()
    private var contextualKeyterms: [String] = []
    private var lastRecordedAudioPowerSampleDate = Date.distantPast
    private var activePermissionRequestTask: Task<Bool, Never>?
    private var activeDictationSessionID: UUID?
    private var activeDictationRequestedAt: Date?
    private var activeDictationRecordingStartedAt: Date?
    private var activeTranscriptionProviderOpenStartedAt: Date?
    /// Timestamp of the last completed permission request, used to debounce
    /// rapid follow-up requests that arrive before macOS updates its cache.
    private var lastPermissionRequestCompletedAt: Date?

    override init() {
        let transcriptionProviderID = BuddyTranscriptionProviderFactory.selectedProviderID().rawValue
        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionProviderID = transcriptionProviderID
        self.transcriptionProviderDisplayName = transcriptionProvider.displayName
        super.init()
    }

    func setTranscriptionProvider(_ providerID: String) {
        guard !isDictationInProgress else { return }
        let resolvedProviderID = BuddyTranscriptionProviderID(rawValue: providerID)?.rawValue
            ?? BuddyTranscriptionProviderID.automatic.rawValue
        UserDefaults.standard.set(resolvedProviderID, forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey)
        transcriptionProviderID = resolvedProviderID
        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeProvider(preferredProviderID: resolvedProviderID)
        self.transcriptionProvider = transcriptionProvider
        transcriptionProviderDisplayName = transcriptionProvider.displayName
    }

    func updateContextualKeyterms(_ contextualKeyterms: [String]) {
        self.contextualKeyterms = contextualKeyterms
    }

    func startPersistentDictationFromMicrophoneButton(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .microphoneButton,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: false
        )
    }

    func startAutoSubmittingDictationFromMicrophoneButton(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .microphoneButton,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: true
        )
    }

    func startPushToTalkFromKeyboardShortcut(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .keyboardShortcut,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: currentDraftText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    func stopPersistentDictationFromMicrophoneButton() {
        stopPushToTalk(expectedStartSource: .microphoneButton)
    }

    func stopPushToTalkFromKeyboardShortcut() {
        stopPushToTalk(expectedStartSource: .keyboardShortcut)
    }

    func cancelCurrentDictation(preserveDraftText: Bool = true) {
        pendingStartRequestIdentifier = UUID()

        guard isDictationInProgress else { return }

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        if preserveDraftText {
            let currentDraftText = composeDraftText(withTranscribedText: bestRecognizedTextForFinalization)
            draftCallbacks?.updateDraftText(currentDraftText)
        }

        tearDownAudioCapture(cancelTranscriptionSession: true)

        resetSessionState()
    }

    func requestInitialPushToTalkPermissionsIfNeeded() async {
        guard needsInitialPermissionPrompt else { return }
        guard !isDictationInProgress else { return }

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        NSApplication.shared.activate(ignoringOtherApps: true)

        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            // If the task is cancelled while we are waiting for macOS to bring
            // the app forward, we can safely continue into the permission check.
        }

        let hasPermissions = await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts()
        isPreparingToRecord = false

        if hasPermissions {
            lastErrorMessage = nil
        }
    }

    private func startPushToTalk(
        startSource: BuddyDictationStartSource,
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void,
        shouldAutomaticallySubmitFinalDraftOnStop: Bool
    ) async {
        guard !isDictationInProgress else {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.dictation.start_ignored_busy",
                fields: [
                    "source": String(describing: startSource),
                    "provider": transcriptionProvider.displayName,
                    "providerID": transcriptionProviderID,
                    "isPreparing": isPreparingToRecord,
                    "isRecording": isActivelyRecordingAudio,
                    "isFinalizing": isFinalizingTranscript
                ]
            )
            return
        }

        print("🎙️ BuddyDictationManager: start requested (\(startSource))")
        activeDictationSessionID = UUID()
        activeDictationRequestedAt = Date()
        activeDictationRecordingStartedAt = nil
        activeTranscriptionProviderOpenStartedAt = nil
        logDictationEvent(
            "voice.dictation.start_requested",
            fields: [
                "source": String(describing: startSource),
                "autoSubmitOnStop": shouldAutomaticallySubmitFinalDraftOnStop
            ]
        )

        let startRequestIdentifier = UUID()
        pendingStartRequestIdentifier = startRequestIdentifier

        if needsInitialPermissionPrompt {
            print("🎙️ BuddyDictationManager: requesting initial permissions")
            logDictationEvent(
                "voice.dictation.permission_check_started",
                fields: [
                    "source": String(describing: startSource)
                ]
            )
            NSApplication.shared.activate(ignoringOtherApps: true)

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                // If the task is cancelled while the app is being activated,
                // we can safely continue into the permission request.
            }
        }

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        guard await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() else {
            print("🎙️ BuddyDictationManager: permissions missing or denied")
            logDictationEvent(
                "voice.dictation.permission_check_failed",
                fields: [
                    "source": String(describing: startSource)
                ]
            )
            isPreparingToRecord = false
            return
        }
        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released during permission check)")
            logDictationEvent(
                "voice.dictation.start_cancelled",
                fields: [
                    "source": String(describing: startSource),
                    "reason": "shortcut_released_during_permission_check"
                ]
            )
            isPreparingToRecord = false
            return
        }
        guard pendingStartRequestIdentifier == startRequestIdentifier else {
            print("🎙️ BuddyDictationManager: start request superseded")
            logDictationEvent(
                "voice.dictation.start_cancelled",
                fields: [
                    "source": String(describing: startSource),
                    "reason": "superseded"
                ]
            )
            isPreparingToRecord = false
            return
        }

        draftTextBeforeCurrentDictation = currentDraftText
        latestRecognizedText = ""
        draftCallbacks = BuddyDictationDraftCallbacks(
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText
        )
        activeStartSource = startSource
        shouldAutomaticallySubmitFinalDraft = shouldAutomaticallySubmitFinalDraftOnStop
        hasFinishedCurrentDictationSession = false
        isFinalizingTranscript = false
        isRecordingFromMicrophoneButton = startSource == .microphoneButton
        isRecordingFromKeyboardShortcut = startSource == .keyboardShortcut
        isKeyboardShortcutSessionActiveOrFinalizing = startSource == .keyboardShortcut
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast

        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released before recording began)")
            logDictationEvent(
                "voice.dictation.start_cancelled",
                fields: [
                    "source": String(describing: startSource),
                    "reason": "shortcut_released_before_recording"
                ]
            )
            resetSessionState()
            return
        }

        do {
            try await startRecognitionSession()
            guard pendingStartRequestIdentifier == startRequestIdentifier else {
                print("🎙️ BuddyDictationManager: start request superseded during session start")
                logDictationEvent(
                    "voice.dictation.start_cancelled",
                    fields: [
                        "source": String(describing: startSource),
                        "reason": "superseded_during_session_start"
                    ]
                )
                tearDownAudioCapture(cancelTranscriptionSession: true)
                resetSessionState()
                return
            }
            guard !Task.isCancelled else {
                print("🎙️ BuddyDictationManager: start cancelled (shortcut released during session start)")
                logDictationEvent(
                    "voice.dictation.start_cancelled",
                    fields: [
                        "source": String(describing: startSource),
                        "reason": "shortcut_released_during_session_start"
                    ]
                )
                tearDownAudioCapture(cancelTranscriptionSession: true)
                resetSessionState()
                return
            }
            if startSource == .microphoneButton {
                microphoneButtonRecordingStartedAt = Date()
            }
            activeDictationRecordingStartedAt = Date()
            isPreparingToRecord = false
            print("🎙️ BuddyDictationManager: recognition session started")
            logDictationEvent(
                "voice.dictation.recording_started",
                fields: [
                    "source": String(describing: startSource),
                    "startupDurationMs": Self.elapsedMilliseconds(since: activeDictationRequestedAt)
                ]
            )
        } catch {
            isPreparingToRecord = false
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't start voice input. try again."
            )
            print("❌ BuddyDictationManager: failed to start recognition session (\(transcriptionProvider.displayName)): \(error)")
            logDictationEvent(
                "voice.dictation.start_failed",
                fields: [
                    "source": String(describing: startSource),
                    "error": error.localizedDescription,
                    "startupDurationMs": Self.elapsedMilliseconds(since: activeDictationRequestedAt)
                ]
            )
            resetSessionState()
        }
    }

    private func stopPushToTalk(expectedStartSource: BuddyDictationStartSource) {
        pendingStartRequestIdentifier = UUID()

        guard activeStartSource == expectedStartSource else {
            if isPreparingToRecord {
                logDictationEvent(
                    "voice.dictation.start_cancelled",
                    fields: [
                        "source": String(describing: expectedStartSource),
                        "reason": "stop_requested_before_recording_started"
                    ]
                )
                resetSessionState()
            } else {
                isPreparingToRecord = false
            }
            return
        }
        guard !isFinalizingTranscript else { return }

        print("🎙️ BuddyDictationManager: stop requested (\(expectedStartSource))")
        logDictationEvent(
            "voice.dictation.stop_requested",
            fields: [
                "source": String(describing: expectedStartSource),
                "recordingDurationMs": Self.elapsedMilliseconds(since: activeDictationRecordingStartedAt),
                "latestTranscriptLength": bestRecognizedTextForFinalization.trimmingCharacters(in: .whitespacesAndNewlines).count
            ]
        )

        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isFinalizingTranscript = true

        let finalTranscriptFallbackDelaySeconds = activeTranscriptionSession?.finalTranscriptFallbackDelaySeconds
            ?? Self.defaultFinalTranscriptFallbackDelaySeconds

        tearDownAudioCapture(cancelTranscriptionSession: false)
        activeTranscriptionSession?.requestFinalTranscript()

        finalizeFallbackWorkItem?.cancel()
        let shouldSubmitFinalDraftWhenFallbackTriggers = shouldAutomaticallySubmitFinalDraft
        let fallbackWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.logDictationEvent(
                    "voice.dictation.final_transcript_fallback",
                    fields: [
                        "fallbackDelaySeconds": finalTranscriptFallbackDelaySeconds,
                        "latestTranscriptLength": self?.bestRecognizedTextForFinalization.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
                    ]
                )
                self?.finishCurrentDictationSessionIfNeeded(
                    shouldSubmitFinalDraft: shouldSubmitFinalDraftWhenFallbackTriggers,
                    completionReason: "fallback"
                )
            }
        }
        finalizeFallbackWorkItem = fallbackWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + finalTranscriptFallbackDelaySeconds,
            execute: fallbackWorkItem
        )
    }

    private func tearDownAudioCapture(cancelTranscriptionSession: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeInputTapIfNeeded()
        if cancelTranscriptionSession {
            activeTranscriptionSession?.cancel()
            activeTranscriptionSession = nil
        }
    }

    private func removeInputTapIfNeeded() {
        guard hasInstalledInputTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        hasInstalledInputTap = false
    }

    private func startRecognitionSession() async throws {
        tearDownAudioCapture(cancelTranscriptionSession: true)

        print("🎙️ BuddyDictationManager: opening transcription provider \(transcriptionProvider.displayName)")
        activeTranscriptionProviderOpenStartedAt = Date()
        logDictationEvent("voice.dictation.provider_opening")

        let activeTranscriptionSession = try await transcriptionProvider.startStreamingSession(
            keyterms: buildTranscriptionKeyterms(),
            onTranscriptUpdate: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self else { return }
                    self.updateRecognizedText(transcriptText)
                    self.draftCallbacks?.updateDraftText(
                        self.composeDraftText(withTranscribedText: transcriptText)
                    )
                }
            },
            onFinalTranscriptReady: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self else { return }
                    let finalTranscriptText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fallbackTranscriptText = self.latestNonEmptyRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let usedPartialFallback = finalTranscriptText.isEmpty && !fallbackTranscriptText.isEmpty
                    let resolvedTranscriptText = usedPartialFallback ? self.latestNonEmptyRecognizedText : transcriptText
                    self.updateRecognizedText(resolvedTranscriptText)
                    self.logDictationEvent(
                        "voice.dictation.final_transcript_ready",
                        fields: [
                            "transcriptLength": resolvedTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).count,
                            "rawTranscriptLength": finalTranscriptText.count,
                            "usedPartialFallback": usedPartialFallback,
                            "finalizeLatencyMs": Self.elapsedMilliseconds(since: self.activeDictationRecordingStartedAt)
                        ]
                    )

                    if self.isFinalizingTranscript {
                        self.finishCurrentDictationSessionIfNeeded(
                            shouldSubmitFinalDraft: self.shouldAutomaticallySubmitFinalDraft,
                            completionReason: usedPartialFallback ? "provider_final_with_partial_fallback" : "provider_final"
                        )
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.handleRecognitionError(error)
                }
            }
        )

        self.activeTranscriptionSession = activeTranscriptionSession
        print("🎙️ BuddyDictationManager: provider ready, starting audio engine")
        logDictationEvent(
            "voice.dictation.provider_ready",
            fields: [
                "providerOpenDurationMs": Self.elapsedMilliseconds(since: activeTranscriptionProviderOpenStartedAt)
            ]
        )

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        removeInputTapIfNeeded()
        // Smaller tap buffers lower capture-to-provider handoff latency.
        inputNode.installTap(onBus: 0, bufferSize: 256, format: inputFormat) { [weak self] buffer, _ in
            self?.activeTranscriptionSession?.appendAudioBuffer(buffer)
            self?.updateAudioPowerLevel(from: buffer)
        }
        hasInstalledInputTap = true

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func handleRecognitionError(_ error: Error) {
        guard isDictationInProgress || activeTranscriptionSession != nil else {
            return
        }

        if hasFinishedCurrentDictationSession {
            return
        }

        if isNoSpeechDetectedError(error), bestRecognizedTextForFinalization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("BuddyDictationManager: no speech detected; treating as cancelled interaction")
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft,
                completionReason: "no_speech_detected"
            )
            return
        }

        if isFinalizingTranscript && !bestRecognizedTextForFinalization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft,
                completionReason: "error_with_partial_transcript"
            )
        } else {
            print("❌ Buddy dictation error (\(transcriptionProvider.displayName)): \(error)")
            logDictationEvent(
                "voice.dictation.error",
                fields: [
                    "error": error.localizedDescription,
                    "isFinalizing": isFinalizingTranscript,
                    "latestTranscriptLength": bestRecognizedTextForFinalization.trimmingCharacters(in: .whitespacesAndNewlines).count
                ]
            )
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't transcribe that. try again."
            )
            cancelCurrentDictation(preserveDraftText: false)
        }
    }

    private func finishCurrentDictationSessionIfNeeded(
        shouldSubmitFinalDraft: Bool,
        completionReason: String = "unspecified"
    ) {
        guard !hasFinishedCurrentDictationSession else { return }
        hasFinishedCurrentDictationSession = true

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        let finalRecognizedText = bestRecognizedTextForFinalization
        let finalDraftText = composeDraftText(withTranscribedText: finalRecognizedText)
        let finalTranscriptText = finalRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDraftCallbacks = draftCallbacks
        let submittedFinalDraft = shouldSubmitFinalDraft && !finalTranscriptText.isEmpty

        logDictationEvent(
            "voice.dictation.finished",
            fields: [
                "reason": completionReason,
                "transcriptLength": finalTranscriptText.count,
                "finalDraftLength": finalDraftText.trimmingCharacters(in: .whitespacesAndNewlines).count,
                "shouldSubmitFinalDraft": shouldSubmitFinalDraft,
                "submittedFinalDraft": submittedFinalDraft,
                "recordingDurationMs": Self.elapsedMilliseconds(since: activeDictationRecordingStartedAt)
            ]
        )

        if !shouldSubmitFinalDraft && !finalDraftText.isEmpty {
            currentDraftCallbacks?.updateDraftText(finalDraftText)
        }

        tearDownAudioCapture(cancelTranscriptionSession: true)

        resetSessionState()

        guard shouldSubmitFinalDraft else { return }
        guard !finalTranscriptText.isEmpty else { return }

        currentDraftCallbacks?.submitDraftText(finalDraftText)
    }

    private func composeDraftText(withTranscribedText transcribedText: String) -> String {
        let trimmedTranscriptText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscriptText.isEmpty else {
            return draftTextBeforeCurrentDictation
        }

        let trimmedExistingDraftText = draftTextBeforeCurrentDictation
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedExistingDraftText.isEmpty else {
            return trimmedTranscriptText
        }

        if draftTextBeforeCurrentDictation.hasSuffix(" ") || draftTextBeforeCurrentDictation.hasSuffix("\n") {
            return draftTextBeforeCurrentDictation + trimmedTranscriptText
        }

        return draftTextBeforeCurrentDictation + " " + trimmedTranscriptText
    }

    private var bestRecognizedTextForFinalization: String {
        let trimmedLatestText = latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLatestText.isEmpty {
            return latestRecognizedText
        }

        return latestNonEmptyRecognizedText
    }

    private func updateRecognizedText(_ transcriptText: String) {
        latestRecognizedText = transcriptText

        if !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            latestNonEmptyRecognizedText = transcriptText
        }
    }

    private func resetSessionState() {
        pendingStartRequestIdentifier = UUID()
        activeTranscriptionSession = nil
        draftCallbacks = nil
        activeStartSource = nil
        draftTextBeforeCurrentDictation = ""
        latestRecognizedText = ""
        latestNonEmptyRecognizedText = ""
        shouldAutomaticallySubmitFinalDraft = false
        hasFinishedCurrentDictationSession = false
        isPreparingToRecord = false
        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isKeyboardShortcutSessionActiveOrFinalizing = false
        isFinalizingTranscript = false
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast
        activeDictationSessionID = nil
        activeDictationRequestedAt = nil
        activeDictationRecordingStartedAt = nil
        activeTranscriptionProviderOpenStartedAt = nil
    }

    private func logDictationEvent(_ event: String, fields: [String: Any] = [:]) {
        var enrichedFields = fields
        enrichedFields["provider"] = transcriptionProvider.displayName
        enrichedFields["providerID"] = transcriptionProviderID
        if let activeDictationSessionID {
            enrichedFields["sessionID"] = activeDictationSessionID.uuidString
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: event,
            fields: enrichedFields
        )
    }

    private static func elapsedMilliseconds(since startDate: Date?) -> Int {
        guard let startDate else { return -1 }
        return max(0, Int(Date().timeIntervalSince(startDate) * 1_000))
    }

    private func buildTranscriptionKeyterms() -> [String] {
        let baseKeyterms = [
            "makesomething",
            "Learning Buddy",
            "Codex",
            "Claude",
            "Anthropic",
            "OpenAI",
            "SwiftUI",
            "Xcode",
            "Vercel",
            "Next.js",
            "localhost"
        ]

        let combinedKeyterms = baseKeyterms + contextualKeyterms
        var uniqueNormalizedKeyterms = Set<String>()
        var orderedKeyterms: [String] = []

        for keyterm in combinedKeyterms {
            let trimmedKeyterm = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKeyterm.isEmpty else { continue }

            let normalizedKeyterm = trimmedKeyterm.lowercased()
            if uniqueNormalizedKeyterms.contains(normalizedKeyterm) {
                continue
            }

            uniqueNormalizedKeyterms.insert(normalizedKeyterm)
            orderedKeyterms.append(trimmedKeyterm)
        }

        return orderedKeyterms
    }

    private func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let smoothedAudioPowerLevel = max(
                CGFloat(boostedLevel),
                self.currentAudioPowerLevel * 0.5
            )
            self.currentAudioPowerLevel = smoothedAudioPowerLevel

            let now = Date()
            if now.timeIntervalSince(self.lastRecordedAudioPowerSampleDate)
                >= Self.recordedAudioPowerHistorySampleIntervalSeconds {
                self.lastRecordedAudioPowerSampleDate = now
                self.appendRecordedAudioPowerSample(
                    max(CGFloat(boostedLevel), Self.recordedAudioPowerHistoryBaselineLevel)
                )
            }
        }
    }

    private func appendRecordedAudioPowerSample(_ audioPowerSample: CGFloat) {
        var updatedRecordedAudioPowerHistory = recordedAudioPowerHistory
        updatedRecordedAudioPowerHistory.append(audioPowerSample)

        if updatedRecordedAudioPowerHistory.count > Self.recordedAudioPowerHistoryLength {
            updatedRecordedAudioPowerHistory.removeFirst(
                updatedRecordedAudioPowerHistory.count - Self.recordedAudioPowerHistoryLength
            )
        }

        recordedAudioPowerHistory = updatedRecordedAudioPowerHistory
    }

    private func requestMicrophoneAndSpeechPermissionsIfNeeded() async -> Bool {
        let hasMicrophonePermission = await requestMicrophonePermissionIfNeeded()
        guard hasMicrophonePermission else {
            lastErrorMessage = "microphone permission is required for push to talk."
            return false
        }

        guard transcriptionProvider.requiresSpeechRecognitionPermission else {
            return true
        }

        let hasSpeechRecognitionPermission = await requestSpeechRecognitionPermissionIfNeeded()
        guard hasSpeechRecognitionPermission else {
            lastErrorMessage = "speech recognition permission is required for push to talk."
            return false
        }

        return true
    }

    /// macOS can show the microphone/speech sheet again if we accidentally fan out
    /// multiple permission requests before the first one finishes. We keep exactly
    /// one in-flight request task so rapid repeat presses all await the same result.
    ///
    /// After the task completes, we skip re-requesting for a short cooldown period
    /// so macOS has time to update its authorization cache. This prevents the
    /// permission dialog from popping up again on rapid follow-up presses.
    private func requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() async -> Bool {
        // If a permission request is already in-flight, reuse it.
        if let activePermissionRequestTask {
            return await activePermissionRequestTask.value
        }

        // If we just finished a permission request very recently, skip re-requesting.
        // macOS can briefly report .notDetermined even after the user tapped Allow,
        // so we trust the cached result for a short window.
        if let lastPermissionRequestCompletedAt,
           Date().timeIntervalSince(lastPermissionRequestCompletedAt) < 1.0 {
            return AVCaptureDevice.authorizationStatus(for: .audio) != .denied
                && AVCaptureDevice.authorizationStatus(for: .audio) != .restricted
        }

        let permissionRequestTask = Task { @MainActor in
            await self.requestMicrophoneAndSpeechPermissionsIfNeeded()
        }

        activePermissionRequestTask = permissionRequestTask

        let hasPermissions = await permissionRequestTask.value
        activePermissionRequestTask = nil
        lastPermissionRequestCompletedAt = Date()
        return hasPermissions
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
            currentPermissionProblem = isGranted ? nil : .microphoneAccessDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        @unknown default:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        }
    }

    private func requestSpeechRecognitionPermissionIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus == .authorized)
                }
            }
            currentPermissionProblem = isGranted ? nil : .speechRecognitionDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        @unknown default:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        }
    }

    func openRelevantPrivacySettings() {
        let settingsURLString: String

        switch currentPermissionProblem {
        case .microphoneAccessDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognitionDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case nil:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security"
        }

        guard let settingsURL = URL(string: settingsURLString) else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    private func userFacingErrorMessage(from error: Error, fallback: String) -> String {
        if let localizedError = error as? LocalizedError,
           let errorDescription = localizedError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !errorDescription.isEmpty {
            return errorDescription
        }

        let errorDescription = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorDescription.isEmpty,
           errorDescription != "The operation couldn’t be completed." {
            return errorDescription
        }

        return fallback
    }

    private func isNoSpeechDetectedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain", nsError.code == 1110 {
            return true
        }

        let localizedDescription = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return localizedDescription.contains("no speech detected")
    }
}
