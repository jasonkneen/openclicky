//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Sends text-to-speech requests directly to ElevenLabs and plays the
//  resulting audio through the system audio output.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    private var apiKey: String?
    private var voiceID: String
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?
    private var speechSynthesizer: AVSpeechSynthesizer?
    private let audioOutputWarmupDelayNanoseconds: UInt64 = 180_000_000

    init(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    func updateConfiguration(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends `text` directly to ElevenLabs and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String, onPlaybackStarted: (() -> Void)? = nil) async throws {
        guard let apiKey, !apiKey.isEmpty else {
            try await speakWithSystemSpeech(
                text,
                reason: "ElevenLabs API key is not configured",
                onPlaybackStarted: onPlaybackStarted
            )
            return
        }

        guard !voiceID.isEmpty,
              let apiURL = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)") else {
            try await speakWithSystemSpeech(
                text,
                reason: "ElevenLabs voice ID is not configured",
                onPlaybackStarted: onPlaybackStarted
            )
            return
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !Self.isExpectedCancellation(error) else {
                throw CancellationError()
            }

            try await speakWithSystemSpeech(
                text,
                reason: "TTS request failed: \(error.localizedDescription)",
                onPlaybackStarted: onPlaybackStarted
            )
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            try await speakWithSystemSpeech(
                text,
                reason: "TTS returned an invalid response",
                onPlaybackStarted: onPlaybackStarted
            )
            return
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            let truncatedErrorBody = String(errorBody.prefix(500))
            try await speakWithSystemSpeech(
                text,
                reason: "TTS API error \(httpResponse.statusCode): \(truncatedErrorBody)",
                onPlaybackStarted: onPlaybackStarted
            )
            return
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.prepareToPlay()
        player.volume = 0
        guard player.play() else {
            throw NSError(
                domain: "ElevenLabsTTS",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to start audio playback"]
            )
        }

        try await Task.sleep(nanoseconds: audioOutputWarmupDelayNanoseconds)
        try Task.checkCancellation()

        guard audioPlayer === player else {
            throw CancellationError()
        }

        player.currentTime = 0
        player.volume = 1
        guard player.play() else {
            throw NSError(
                domain: "ElevenLabsTTS",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to restart audio playback after warmup"]
            )
        }

        onPlaybackStarted?()
        print("ElevenLabs TTS: playing \(data.count / 1024)KB audio")

        while player.isPlaying {
            try await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
            guard audioPlayer === player else {
                throw CancellationError()
            }
        }

        if audioPlayer === player {
            audioPlayer = nil
        }
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        (audioPlayer?.isPlaying ?? false) || (speechSynthesizer?.isSpeaking ?? false)
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        speechSynthesizer?.stopSpeaking(at: .immediate)
        speechSynthesizer = nil
    }

    private func speakWithSystemSpeech(
        _ text: String,
        reason: String,
        onPlaybackStarted: (() -> Void)?
    ) async throws {
        print("System speech fallback: \(reason)")
        audioPlayer?.stop()
        audioPlayer = nil

        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        speechSynthesizer = synthesizer
        synthesizer.speak(utterance)
        onPlaybackStarted?()

        while synthesizer.isSpeaking {
            try await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
            guard speechSynthesizer === synthesizer else {
                throw CancellationError()
            }
        }

        if speechSynthesizer === synthesizer {
            speechSynthesizer = nil
        }
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
}
