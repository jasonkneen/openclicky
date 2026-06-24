//
//  FreeSpeechParakeetTranscriptionProvider.swift
//  cursor-buddy
//
//  Local Parakeet MLX transcription through the installed Free Speech app's
//  local API.
//

import AppKit
import AVFoundation
import Foundation

struct FreeSpeechParakeetTranscriptionError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class FreeSpeechParakeetTranscriptionProvider: BuddyTranscriptionProvider {
    static let modelID = "mlx-community/parakeet-tdt-0.6b-v3"
    private static let appURL = URL(fileURLWithPath: "/Applications/Free Speech.app")

    let displayName = "Parakeet MLX"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        Self.isLocallyAvailable
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "Parakeet MLX needs Free Speech installed in /Applications."
    }

    static var isLocallyAvailable: Bool {
        FileManager.default.fileExists(atPath: appURL.path)
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard isConfigured else {
            throw FreeSpeechParakeetTranscriptionError(
                message: unavailableExplanation ?? "Parakeet MLX is not configured."
            )
        }

        return FreeSpeechParakeetTranscriptionSession(
            modelID: Self.modelID,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class FreeSpeechParakeetTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 180.0

    private struct TranscriptionResponse: Decodable {
        let ok: Bool?
        let model: String?
        let text: String?
        let error: String?
    }

    private static let targetSampleRate = 16_000
    private static let baseURL = URL(string: "http://127.0.0.1:56874")!
    private static let freeSpeechAppURL = URL(fileURLWithPath: "/Applications/Free Speech.app")

    private let modelID: String
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void
    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.parakeet.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: Double(targetSampleRate))
    private let urlSession: URLSession

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        modelID: String,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.modelID = modelID
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: configuration)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true
            let audioData = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribe(audioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }
        transcriptionTask?.cancel()
        urlSession.invalidateAndCancel()
    }

    private func transcribe(_ audioData: Data) async {
        guard !Task.isCancelled else { return }

        let shouldSkip = stateQueue.sync {
            isCancelled || audioData.isEmpty
        }
        if shouldSkip {
            deliverFinalTranscript("")
            return
        }

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: audioData,
            sampleRate: Self.targetSampleRate
        )

        do {
            try await ensureFreeSpeechServerReady()
            let transcriptText = try await requestTranscription(for: wavAudioData)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }
            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            onError(error)
        }
    }

    private func ensureFreeSpeechServerReady() async throws {
        if await isServerHealthy() {
            return
        }

        guard FileManager.default.fileExists(atPath: Self.freeSpeechAppURL.path) else {
            throw FreeSpeechParakeetTranscriptionError(
                message: "Free Speech is not installed in /Applications, so Parakeet MLX is unavailable."
            )
        }

        await MainActor.run {
            _ = NSWorkspace.shared.open(Self.freeSpeechAppURL)
        }

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if await isServerHealthy() {
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        throw FreeSpeechParakeetTranscriptionError(
            message: "Free Speech did not start its local Parakeet server at 127.0.0.1:56874."
        )
    }

    private func isServerHealthy() async -> Bool {
        var request = URLRequest(url: Self.baseURL.appending(path: "health"))
        request.timeoutInterval = 0.7

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            let stt = payload["stt"] as? [String: Any]
            return payload["api_version"] as? Int == 1
                && stt?["provider"] as? String == "parakeet-mlx"
        } catch {
            return false
        }
    }

    private func requestTranscription(for wavAudioData: Data) async throws -> String {
        var request = URLRequest(url: Self.baseURL.appending(path: "transcribe"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "audio_base64": wavAudioData.base64EncodedString(),
            "audio_format": "wav",
            "model": modelID
        ])

        let (data, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500

        if (200...299).contains(statusCode) {
            let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            let transcriptText = (decoded.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if transcriptText.isEmpty, let error = decoded.error, !error.isEmpty {
                throw FreeSpeechParakeetTranscriptionError(message: error)
            }
            return transcriptText
        }

        let message = Self.errorMessage(from: data)
        throw FreeSpeechParakeetTranscriptionError(
            message: message.isEmpty ? "Parakeet MLX transcription failed with HTTP \(statusCode)." : message
        )
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        onFinalTranscriptReady(transcriptText)
    }

    private static func errorMessage(from data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["error"] as? String
        else {
            return String(data: data, encoding: .utf8) ?? ""
        }

        return message
    }

    deinit {
        transcriptionTask?.cancel()
        urlSession.invalidateAndCancel()
    }
}
