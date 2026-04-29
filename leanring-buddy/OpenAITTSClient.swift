//
//  OpenAITTSClient.swift
//  leanring-buddy
//
//  OpenAI Text-to-Speech (`/v1/audio/speech`, response_format pcm).
//  PCM is 24 kHz mono little-endian per OpenAI API.
//

import AVFoundation
import Foundation

enum OpenAITTSClient {
    nonisolated static let streamSampleRate: Double = 24_000
    fileprivate static let speechURL = URL(string: "https://api.openai.com/v1/audio/speech")!

    /// Used when another provider’s per-sentence fetch fails. Resamples to `targetSampleRate` when needed (e.g. 22.05 kHz ElevenLabs pipeline).
    nonisolated static func tryFetchSentenceSamplesFallback(text: String, targetSampleRate: Double) async -> [Int16]? {
        guard let apiKey = AppBundleConfiguration.openAIAPIKey(), !apiKey.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            var samples = try await fetchPCM16Samples(apiKey: apiKey, text: trimmed)
            let sourceRate = Self.streamSampleRate
            if abs(targetSampleRate - sourceRate) > 0.5 {
                samples = resampleLinearPCM16(samples, fromRate: sourceRate, toRate: targetSampleRate)
            }
            return samples
        } catch {
            print("⚠️ OpenAI TTS fallback failed: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func fetchPCM16Samples(apiKey: String, text: String) async throws -> [Int16] {
        let model = AppBundleConfiguration.openAITTSModel()
        let voice = AppBundleConfiguration.openAITTSVoice()

        var request = URLRequest(url: Self.speechURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "pcm"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw makeError(-1, "OpenAI TTS returned an invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(600) ?? ""
            throw makeError(http.statusCode, "OpenAI TTS HTTP \(http.statusCode): \(snippet)")
        }
        return pcm16LittleEndianSamples(from: data)
    }

    nonisolated private static func pcm16LittleEndianSamples(from raw: Data) -> [Int16] {
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

    nonisolated private static func makeError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "OpenAITTS", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
final class OpenAITTSSpeechClient {
    private var apiKey: String?
    private(set) var voiceID: String
    private let session: URLSession

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamingTask: Task<Void, Error>?
    private weak var activeStreamingSession: StreamingTTSSession?

    private static let chunkSampleCount = 2_048

    init(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: configuration)
    }

    func updateConfiguration(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func warmUpConnection() {
        guard let url = URL(string: "https://api.openai.com") else { return }
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

    private static func makeStreamFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: OpenAITTSClient.streamSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    func speakText(
        _ text: String,
        waitUntilFinished: Bool = true,
        onPlaybackStarted: (() -> Void)? = nil
    ) async throws {
        guard let apiKey, !apiKey.isEmpty else {
            throw NSError(domain: "OpenAITTS", code: -100, userInfo: [NSLocalizedDescriptionKey: "OpenAI API key is not configured"])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stopPlaybackInternal()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = Self.makeStreamFormat() else {
            throw NSError(domain: "OpenAITTS", code: -102, userInfo: [NSLocalizedDescriptionKey: "Could not build PCM stream format"])
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do {
            try engine.start()
        } catch {
            throw NSError(domain: "OpenAITTS", code: -103, userInfo: [NSLocalizedDescriptionKey: "Audio engine failed: \(error.localizedDescription)"])
        }
        audioEngine = engine
        playerNode = player

        let samples = try await fetchSentenceSamples(trimmed)
        guard !samples.isEmpty else {
            stopPlaybackInternal()
            throw NSError(domain: "OpenAITTS", code: -106, userInfo: [NSLocalizedDescriptionKey: "OpenAI TTS returned no audio"])
        }

        let playerRef = player
        let engineRef = engine
        let formatRef = streamFormat
        var didFire = false
        var scheduled: AVAudioFramePosition = 0
        let task = Task {
            var offset = 0
            while offset < samples.count {
                try Task.checkCancellation()
                let end = min(offset + Self.chunkSampleCount, samples.count)
                let chunk = Array(samples[offset..<end])
                offset = end
                let frames = await MainActor.run { () -> AVAudioFramePosition in
                    let f = ElevenLabsTTSClient.scheduleSamples(chunk, on: playerRef, format: formatRef)
                    if f > 0, !didFire {
                        didFire = true
                        onPlaybackStarted?()
                    }
                    return f
                }
                scheduled += frames
            }
            await ElevenLabsTTSClient.waitForPlaybackToDrain(
                playerRef,
                scheduledFrameCount: scheduled,
                sampleRate: OpenAITTSClient.streamSampleRate
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
                sampleRate: OpenAITTSClient.streamSampleRate,
                onPlaybackStarted: onPlaybackStarted,
                allowsOpenAIFallbackOnFailure: false
            )
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do {
            try engine.start()
        } catch {
            print("⚠️ AVAudioEngine failed to start OpenAI TTS streaming session: \(error)")
            return StreamingTTSSession(
                fetchSamples: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchSentenceSamples(text)
                },
                playerNode: nil,
                format: nil,
                sampleRate: OpenAITTSClient.streamSampleRate,
                onPlaybackStarted: onPlaybackStarted,
                allowsOpenAIFallbackOnFailure: false
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
            sampleRate: OpenAITTSClient.streamSampleRate,
            onPlaybackStarted: onPlaybackStarted,
            allowsOpenAIFallbackOnFailure: false
        )
        activeStreamingSession = session
        return session
    }

    func fetchSentenceSamples(_ text: String) async throws -> [Int16] {
        guard let apiKey, !apiKey.isEmpty else {
            throw NSError(domain: "OpenAITTS", code: -10, userInfo: [NSLocalizedDescriptionKey: "OpenAI API key not configured"])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var request = URLRequest(url: OpenAITTSClient.speechURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": AppBundleConfiguration.openAITTSModel(),
            "input": trimmed,
            "voice": voiceID,
            "response_format": "pcm"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAITTS", code: -13, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(600) ?? ""
            throw NSError(
                domain: "OpenAITTS",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI TTS HTTP \(http.statusCode): \(snippet)"]
            )
        }
        return Self.decodePCM(data: data)
    }

    private nonisolated static func decodePCM(data: Data) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(data.count / 2)
        data.withUnsafeBytes { buf in
            let n = data.count / 2
            for i in 0..<n {
                let lo = UInt16(buf[i * 2])
                let hi = UInt16(buf[i * 2 + 1])
                out.append(Int16(bitPattern: lo | (hi << 8)))
            }
        }
        return out
    }
}

extension OpenAITTSSpeechClient: OpenClickyTTSClient {}
