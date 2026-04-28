//
//  GeminiTTSClient.swift
//  leanring-buddy
//
//  Text-to-speech via Google Gemini speech-generation (generateContent + AUDIO).
//  Docs: https://ai.google.dev/gemini-api/docs/speech-generation
//

import AVFoundation
import Foundation

/// TTS using `generativelanguage.googleapis.com` v1beta `generateContent`
/// with `responseModalities: ["AUDIO"]`.
@MainActor
final class GeminiTTSClient {
    private var apiKey: String?
    /// Prebuilt voice name (e.g. `Kore`, `Puck`). Maps to `prebuiltVoiceConfig.voiceName`.
    private(set) var voiceID: String
    private let session: URLSession

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamingTask: Task<Void, Error>?
    private weak var activeStreamingSession: StreamingTTSSession?

    /// Gemini returns linear PCM; playback matches Deepgram’s 24 kHz pipeline.
    nonisolated static let streamSampleRate: Double = 24_000
    private static let chunkSampleCount = 2_048

    fileprivate static func makeStreamFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: streamSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    init(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: configuration)
    }

    func updateConfiguration(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func warmUpConnection() {
        guard let url = URL(string: "https://generativelanguage.googleapis.com") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    var isPlaying: Bool { playerNode?.isPlaying ?? false }

    func stopPlayback() {
        activeStreamingSession?.cancel()
        activeStreamingSession = nil
        stopPlaybackInternal()
    }

    private func stopPlaybackInternal() {
        streamingTask?.cancel()
        streamingTask = nil
        playerNode?.stop()
        playerNode = nil
        audioEngine?.stop()
        audioEngine = nil
    }

    func speakText(
        _ text: String,
        waitUntilFinished: Bool = true,
        onPlaybackStarted: (() -> Void)? = nil
    ) async throws {
        guard let apiKey, !apiKey.isEmpty else {
            throw Self.makeError(-100, "Gemini API key is not configured")
        }
        guard !voiceID.isEmpty else {
            throw Self.makeError(-101, "Gemini TTS voice name is not configured")
        }

        stopPlaybackInternal()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = Self.makeStreamFormat() else {
            throw Self.makeError(-102, "Could not build PCM stream format")
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do {
            try engine.start()
        } catch {
            throw Self.makeError(-103, "Audio engine failed to start: \(error.localizedDescription)")
        }
        self.audioEngine = engine
        self.playerNode = player

        let samples = try await fetchSentenceSamples(text)
        guard !samples.isEmpty else {
            stopPlaybackInternal()
            throw Self.makeError(-106, "Gemini TTS returned no audio samples")
        }

        let playerRef = player
        let engineRef = engine
        let streamFormatRef = streamFormat
        var didFireStart = false
        var scheduled: AVAudioFramePosition = 0

        let task = Task {
            var offset = 0
            while offset < samples.count {
                try Task.checkCancellation()
                let end = min(offset + Self.chunkSampleCount, samples.count)
                let chunk = Array(samples[offset..<end])
                offset = end
                let frames = await MainActor.run { () -> AVAudioFramePosition in
                    let f = ElevenLabsTTSClient.scheduleSamples(chunk, on: playerRef, format: streamFormatRef)
                    if f > 0, !didFireStart {
                        didFireStart = true
                        onPlaybackStarted?()
                    }
                    return f
                }
                scheduled += frames
            }
            await ElevenLabsTTSClient.waitForPlaybackToDrain(
                playerRef,
                scheduledFrameCount: scheduled,
                sampleRate: Self.streamSampleRate
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.audioEngine === engineRef {
                    self.audioEngine?.stop()
                    self.audioEngine = nil
                    self.playerNode = nil
                }
            }
        }
        streamingTask = task
        if waitUntilFinished {
            do {
                try await task.value
            } catch is CancellationError {
                stopPlaybackInternal()
                throw CancellationError()
            } catch {
                stopPlaybackInternal()
                throw error
            }
        }
    }

    func beginStreamingResponse(onPlaybackStarted: @escaping @MainActor () -> Void) -> StreamingTTSSession {
        stopPlaybackInternal()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = Self.makeStreamFormat() else {
            return StreamingTTSSession(
                fetchSamples: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchSentenceSamples(text)
                },
                playerNode: nil,
                format: nil,
                sampleRate: Self.streamSampleRate,
                onPlaybackStarted: onPlaybackStarted,
                allowsGeminiFallbackOnFailure: false
            )
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do {
            try engine.start()
        } catch {
            print("⚠️ AVAudioEngine failed to start Gemini streaming session: \(error)")
            return StreamingTTSSession(
                fetchSamples: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchSentenceSamples(text)
                },
                playerNode: nil,
                format: nil,
                sampleRate: Self.streamSampleRate,
                onPlaybackStarted: onPlaybackStarted,
                allowsGeminiFallbackOnFailure: false
            )
        }
        audioEngine = engine
        playerNode = player
        let session = StreamingTTSSession(
            fetchSamples: { [weak self] text in
                guard let self else { throw CancellationError() }
                return try await self.fetchSentenceSamples(text)
            },
            playerNode: player,
            format: streamFormat,
            sampleRate: Self.streamSampleRate,
            onPlaybackStarted: onPlaybackStarted,
            allowsGeminiFallbackOnFailure: false
        )
        activeStreamingSession = session
        return session
    }

    func fetchSentenceSamples(_ text: String) async throws -> [Int16] {
        guard let apiKey, !apiKey.isEmpty else {
            throw Self.makeError(-10, "Gemini API key not configured")
        }
        guard !voiceID.isEmpty else {
            throw Self.makeError(-11, "Gemini TTS voice not configured")
        }
        let model = AppBundleConfiguration.geminiTTSModel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw Self.makeError(-12, "Invalid Gemini TTS URL")
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": trimmed]]
                ]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": voiceID
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Self.makeError(-13, "Gemini TTS returned an invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(800) ?? ""
            throw Self.makeError(http.statusCode, "Gemini TTS HTTP \(http.statusCode): \(snippet)")
        }

        return try Self.decodeInlineAudioPCM(data: data)
    }

    /// Used when primary and OpenAI speech fallbacks fail. Reads `GEMINI_API_KEY` / `GOOGLE_GEMINI_API_KEY` and TTS voice/model from configuration (same as Settings).
    nonisolated static func tryFetchSentenceSamplesFallback(text: String, targetSampleRate: Double) async -> [Int16]? {
        guard let apiKey = AppBundleConfiguration.geminiAPIKey(), !apiKey.isEmpty else { return nil }
        let voiceID = AppBundleConfiguration.geminiTTSVoice().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voiceID.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let model = AppBundleConfiguration.geminiTTSModel()
        do {
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            guard let url = components.url else { return nil }
            let body: [String: Any] = [
                "contents": [
                    [
                        "role": "user",
                        "parts": [["text": trimmed]]
                    ]
                ],
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": [
                                "voiceName": voiceID
                            ]
                        ]
                    ]
                ]
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            let urlSession = URLSession(configuration: configuration)
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let snippet = String(data: data, encoding: .utf8)?.prefix(400) ?? ""
                print("⚠️ Gemini TTS fallback failed: HTTP \(code): \(snippet)")
                return nil
            }
            var samples = try decodeInlineAudioPCM(data: data)
            let sourceRate = Self.streamSampleRate
            if abs(targetSampleRate - sourceRate) > 0.5 {
                samples = resampleLinearPCM16(samples, fromRate: sourceRate, toRate: targetSampleRate)
            }
            return samples
        } catch {
            print("⚠️ Gemini TTS fallback failed: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func resampleLinearPCM16(_ samples: [Int16], fromRate: Double, toRate: Double) -> [Int16] {
        guard fromRate > 0, toRate > 0, abs(fromRate - toRate) > 0.5, !samples.isEmpty else { return samples }
        let ratio = fromRate / toRate
        let outCount = max(1, Int((Double(samples.count) / ratio).rounded(.down)))
        var out: [Int16] = []
        out.reserveCapacity(outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) * ratio
            let j = Int(srcPos)
            let frac = srcPos - Double(j)
            if j + 1 < samples.count {
                let a = Double(samples[j])
                let b = Double(samples[j + 1])
                let v = a + (b - a) * frac
                out.append(Int16(clamping: Int(v.rounded())))
            } else if j < samples.count {
                out.append(samples[j])
            }
        }
        return out
    }

    /// Walks `candidates` / `parts` for `inlineData` with PCM audio (base64).
    private nonisolated static func decodeInlineAudioPCM(data: Data) throws -> [Int16] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw makeError(-20, "Gemini TTS: not a JSON object")
        }
        if let err = root["error"] as? [String: Any],
           let msg = err["message"] as? String {
            throw makeError(-21, "Gemini API: \(msg)")
        }
        guard let candidates = root["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw makeError(-22, "Gemini TTS: missing candidates/content/parts")
        }

        for part in parts {
            if let inline = part["inlineData"] as? [String: Any] ?? part["inline_data"] as? [String: Any],
               let b64 = inline["data"] as? String,
               let raw = Data(base64Encoded: b64) {
                return pcm16LittleEndianSamples(from: raw)
            }
        }
        throw makeError(-23, "Gemini TTS: no inline audio part in response")
    }

    /// Treats `raw` as raw PCM s16le mono (Gemini speech-generation PCM).
    private nonisolated static func pcm16LittleEndianSamples(from raw: Data) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(raw.count / 2)
        raw.withUnsafeBytes { buf in
            let count = raw.count / 2
            for i in 0..<count {
                let lo = UInt16(buf[i * 2])
                let hi = UInt16(buf[i * 2 + 1])
                out.append(Int16(bitPattern: lo | (hi << 8)))
            }
        }
        return out
    }

    nonisolated private static func makeError(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "GeminiTTS",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

extension GeminiTTSClient: OpenClickyTTSClient {}

