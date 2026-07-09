//
//  OpenClickyWakeWordManager.swift
//  cursor-buddy
//
//  Local-only wake-word listener for hands-free OpenClicky voice activation.
//  This first implementation uses Apple's on-device Speech recognizer so the
//  room audio gate stays local until the wake phrase is detected.
//

import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
enum OpenClickyVoiceActivationMode: String, CaseIterable, Identifiable {
    case pushToTalk = "push_to_talk"
    case toggleWakeWord = "toggle_wake_word"
    case alwaysWakeWord = "always_wake_word"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pushToTalk: return "Push to talk"
        case .toggleWakeWord: return "Toggle listening"
        case .alwaysWakeWord: return "Always listening"
        }
    }

    var subtitle: String {
        switch self {
        case .pushToTalk:
            return "Hold the activation keys"
        case .toggleWakeWord:
            return "Keys arm Hey Clicky"
        case .alwaysWakeWord:
            return "Hey Clicky stays armed"
        }
    }

    var usesWakeWord: Bool {
        self != .pushToTalk
    }

    static func resolved(rawValue: String?) -> OpenClickyVoiceActivationMode {
        guard let rawValue else { return .pushToTalk }
        return OpenClickyVoiceActivationMode(rawValue: rawValue) ?? .pushToTalk
    }
}

@MainActor
final class OpenClickyWakeWordManager: NSObject, ObservableObject {
    static let wakePhraseDisplayText = "Hey Clicky"

    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var latestTranscript = ""

    var onWakeWordDetected: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInstalledInputTap = false
    private var sessionID = UUID()

    func start() async {
        guard !isListening, !isStarting else { return }

        isStarting = true
        lastErrorMessage = nil
        latestTranscript = ""
        let nextSessionID = UUID()
        sessionID = nextSessionID

        do {
            guard await requestMicrophonePermission() else {
                throw WakeWordError("Microphone permission is required for Hey Clicky listening.")
            }
            guard isCurrentStart(nextSessionID) else { return }
            guard await requestSpeechPermission() else {
                throw WakeWordError("Speech Recognition permission is required for Hey Clicky listening.")
            }
            guard isCurrentStart(nextSessionID) else { return }
            guard let speechRecognizer = Self.makeBestAvailableSpeechRecognizer() else {
                throw WakeWordError("On-device wake-word listening is not available on this Mac.")
            }
            guard speechRecognizer.supportsOnDeviceRecognition else {
                throw WakeWordError("This Mac does not expose on-device Speech recognition for the current locale, so OpenClicky will not run an always-listening remote gate.")
            }
            guard isCurrentStart(nextSessionID) else { return }

            try startRecognitionSession(speechRecognizer: speechRecognizer, sessionID: nextSessionID)
            guard isCurrentStart(nextSessionID) else {
                tearDownRecognition(cancelTask: true)
                return
            }
            isStarting = false
            isListening = true
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "internal",
                event: "voice.wake_listener.started",
                fields: [
                    "engine": "apple_speech_on_device",
                    "wakePhrase": Self.wakePhraseDisplayText
                ]
            )
        } catch {
            // Stop may have happened while macOS was showing a permission
            // prompt. That invalidates this start; it must not tear down or
            // overwrite a newer session when the prompt finally returns.
            guard sessionID == nextSessionID else { return }
            isStarting = false
            isListening = false
            lastErrorMessage = error.localizedDescription
            tearDownRecognition(cancelTask: true)
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "error",
                event: "voice.wake_listener.start_failed",
                fields: ["error": error.localizedDescription]
            )
        }
    }

    func stop(reason: String = "stopped") {
        let hadActiveSession = isListening || isStarting || recognitionTask != nil || audioEngine.isRunning
        // Invalidate an in-flight async permission/start sequence before
        // changing the visible state. Without this, granting a permission
        // after Stop would start the microphone listener again.
        sessionID = UUID()
        isStarting = false
        isListening = false
        tearDownRecognition(cancelTask: true)
        guard hadActiveSession else { return }
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "voice.wake_listener.stopped",
            fields: ["reason": reason]
        )
    }

    private func startRecognitionSession(
        speechRecognizer: SFSpeechRecognizer,
        sessionID: UUID
    ) throws {
        tearDownRecognition(cancelTask: true)

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true
        recognitionRequest.addsPunctuation = false
        recognitionRequest.taskHint = .search
        self.recognitionRequest = recognitionRequest

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognitionEvent(result: result, error: error, sessionID: sessionID)
            }
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak recognitionRequest] buffer, _ in
            recognitionRequest?.append(buffer)
        }
        hasInstalledInputTap = true
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func handleRecognitionEvent(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        sessionID: UUID
    ) {
        guard self.sessionID == sessionID else { return }

        if let result {
            let transcript = result.bestTranscription.formattedString
            latestTranscript = transcript
            if Self.containsWakePhrase(transcript) {
                handleWakeDetected(transcript)
                return
            }
        }

        guard let error else { return }
        let message = error.localizedDescription
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastErrorMessage = message
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "error",
            event: "voice.wake_listener.recognition_error",
            fields: ["error": message]
        )
    }

    private func handleWakeDetected(_ transcript: String) {
        let callback = onWakeWordDetected
        // Suppress any queued recognition callbacks from the completed
        // listener before handing control back to the app.
        sessionID = UUID()
        isListening = false
        tearDownRecognition(cancelTask: true)
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: "voice.wake_word.detected",
            fields: [
                "wakePhrase": Self.wakePhraseDisplayText,
                "transcriptLength": transcript.count
            ]
        )
        callback?(transcript)
    }

    private func isCurrentStart(_ candidateSessionID: UUID) -> Bool {
        sessionID == candidateSessionID && isStarting && !isListening
    }

    private func tearDownRecognition(cancelTask: Bool) {
        if hasInstalledInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledInputTap = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if cancelTask {
            recognitionTask?.cancel()
        } else {
            recognitionRequest?.endAudio()
        }
        recognitionTask = nil
        recognitionRequest = nil
    }

    private static func makeBestAvailableSpeechRecognizer() -> SFSpeechRecognizer? {
        let preferredLocales = [Locale.autoupdatingCurrent, Locale(identifier: "en-US")]
        for locale in preferredLocales {
            if let speechRecognizer = SFSpeechRecognizer(locale: locale), speechRecognizer.supportsOnDeviceRecognition {
                return speechRecognizer
            }
        }
        return SFSpeechRecognizer()
    }

    private static func containsWakePhrase(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return normalized.contains("hey clicky")
            || normalized.contains("hay clicky")
            || normalized.contains("hey cliquey")
            || normalized.contains("hay cliquey")
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

private struct WakeWordError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
