//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from ElevenLabs and plays it via
//  AVAudioEngine + AVAudioPlayerNode. Two modes:
//
//   1. `speakText(...)` — single-shot streaming for short utterances
//      (system responses, completion announcements). PCM bytes feed into
//      the player as they arrive.
//
//   2. `beginStreamingResponse(...)` — sentence-pipelined streaming for
//      LLM voice responses. Caller pushes text deltas as the model
//      generates; the session detects sentence boundaries, fires per-
//      sentence TTS requests in parallel, and schedules audio in order.
//      First audio reaches the speaker after the FIRST SENTENCE of the
//      LLM response, not the whole response.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    private var apiKey: String?
    private(set) var voiceID: String
    private let session: URLSession

    /// Active audio engine for streamed playback. Recreated per request
    /// so a stop/start cycle never replays leftover buffered audio.
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamingTask: Task<Void, Error>?

    /// Active sentence-pipelined session (LLM response path).
    private weak var activeStreamingSession: StreamingTTSSession?

    // System-speech fallback removed by design — we never want a
    // second voice to surface. Failures throw and the caller stays
    // silent.

    /// 22.05 kHz signed-16 mono PCM — ~44 KB/s, low first-byte latency,
    /// quality is fine for spoken-word output.
    nonisolated static let streamSampleRate: Double = 22_050
    nonisolated static let streamOutputFormatQueryValue = "pcm_22050"

    /// Number of Int16 samples to accumulate before scheduling a buffer.
    /// 2048 samples ≈ 93ms at 22.05 kHz — small enough to feel instant,
    /// large enough to avoid scheduler thrash.
    private static let chunkSampleCount = 2_048

    init(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: configuration)
    }

    func updateConfiguration(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pre-establishes a TLS connection to api.elevenlabs.io so the first
    /// streaming TTS request after launch doesn't pay the ~200ms cold-
    /// handshake tax synchronously inside the per-sentence pipeline.
    /// URLSession's connection pool reuses the resulting session for
    /// subsequent POSTs to /stream. Failures are silent — this is purely
    /// an optimization.
    func warmUpConnection() {
        guard let url = URL(string: "https://api.elevenlabs.io/v1") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        session.dataTask(with: request) { _, _, _ in
            // The TLS handshake is the goal; response status is irrelevant.
        }.resume()
    }

    // MARK: - One-shot streaming (short utterances)

    func speakText(
        _ text: String,
        waitUntilFinished: Bool = true,
        onPlaybackStarted: (() -> Void)? = nil
    ) async throws {
        // No fallbacks. ElevenLabs only. If anything is misconfigured
        // or the request fails, throw — the caller logs and stays
        // silent. We never switch to the system speech voice — it's
        // jarring for the user to hear two different voices.
        guard let apiKey, !apiKey.isEmpty else {
            throw Self.makeTTSError(-100, "ElevenLabs API key is not configured")
        }
        guard !voiceID.isEmpty, let apiURL = Self.streamRequestURL(voiceID: voiceID) else {
            throw Self.makeTTSError(-101, "ElevenLabs voice ID is not configured")
        }

        // Tear down any previous playback so we don't bleed audio across
        // overlapping requests.
        stopPlaybackInternal()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = Self.makeStreamFormat() else {
            throw Self.makeTTSError(-102, "Could not build PCM stream format")
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)

        do {
            try engine.start()
        } catch {
            throw Self.makeTTSError(-103, "Audio engine failed to start: \(error.localizedDescription)")
        }

        self.audioEngine = engine
        self.playerNode = player

        let request = Self.makeSpeechRequest(url: apiURL, apiKey: apiKey, text: text)

        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            stopPlaybackInternal()
            throw CancellationError()
        } catch {
            stopPlaybackInternal()
            if Self.isExpectedCancellation(error) { throw CancellationError() }
            throw Self.makeTTSError(-104, "TTS stream request failed: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            stopPlaybackInternal()
            throw Self.makeTTSError(-105, "TTS stream returned an invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = Data()
            do {
                for try await byte in asyncBytes {
                    errorBody.append(byte)
                    if errorBody.count > 4096 { break }
                }
            } catch {
                // Drain failure — we already have the non-2xx status.
            }
            stopPlaybackInternal()
            let bodyText = String(data: errorBody, encoding: .utf8) ?? "Unknown error"
            throw Self.makeTTSError(httpResponse.statusCode, "TTS stream API error \(httpResponse.statusCode): \(bodyText.prefix(500))")
        }

        let playerRef = player
        let engineRef = engine
        let streamFormatRef = streamFormat
        var didFireStartCallback = false
        var pendingByte: UInt8?
        var sampleAccumulator: [Int16] = []
        var scheduledFrameCount: AVAudioFramePosition = 0
        sampleAccumulator.reserveCapacity(Self.chunkSampleCount)

        let task = Task { [weak self] in
            do {
                for try await byte in asyncBytes {
                    try Task.checkCancellation()
                    if let lo = pendingByte {
                        let hi = byte
                        let sample = Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8))
                        sampleAccumulator.append(sample)
                        pendingByte = nil
                    } else {
                        pendingByte = byte
                    }

                    if sampleAccumulator.count >= Self.chunkSampleCount {
                        let chunk = sampleAccumulator
                        sampleAccumulator.removeAll(keepingCapacity: true)
                        let scheduledFrames = await MainActor.run { () -> AVAudioFramePosition in
                            let frames = Self.scheduleSamples(chunk, on: playerRef, format: streamFormatRef)
                            if frames > 0 && !didFireStartCallback {
                                didFireStartCallback = true
                                onPlaybackStarted?()
                            }
                            return frames
                        }
                        scheduledFrameCount += scheduledFrames
                    }
                }

                if !sampleAccumulator.isEmpty {
                    let tail = sampleAccumulator
                    let scheduledFrames = await MainActor.run { () -> AVAudioFramePosition in
                        let frames = Self.scheduleSamples(tail, on: playerRef, format: streamFormatRef)
                        if frames > 0 && !didFireStartCallback {
                            didFireStartCallback = true
                            onPlaybackStarted?()
                        }
                        return frames
                    }
                    scheduledFrameCount += scheduledFrames
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Self.isExpectedCancellation(error) {
                    throw CancellationError()
                }
                throw error
            }

            await Self.waitForPlaybackToDrain(playerRef, scheduledFrameCount: scheduledFrameCount)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.audioEngine === engineRef {
                    self.audioEngine?.stop()
                    self.audioEngine = nil
                    self.playerNode = nil
                }
            }
        }
        self.streamingTask = task

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

    // MARK: - Sentence-pipelined streaming (LLM responses)

    /// Begins a streaming TTS session that accepts text deltas as the LLM
    /// generates and plays back per-sentence audio in order. Per-sentence
    /// TTS fetches run in parallel; playback scheduling is serialized to
    /// preserve sentence order.
    func beginStreamingResponse(onPlaybackStarted: @escaping @MainActor () -> Void) -> StreamingTTSSession {
        // Tear down any prior playback (one-shot or previous streaming
        // session) so audio from a stale request doesn't bleed in.
        stopPlaybackInternal()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = Self.makeStreamFormat() else {
            // Fall back to a session that immediately routes to system speech.
            return StreamingTTSSession(
                fetchSamples: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchSentenceSamples(text)
                },
                playerNode: nil,
                format: nil,
                sampleRate: Self.streamSampleRate,
                onPlaybackStarted: onPlaybackStarted
            )
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)

        do {
            try engine.start()
        } catch {
            print("⚠️ AVAudioEngine failed to start streaming session: \(error)")
            return StreamingTTSSession(
                fetchSamples: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchSentenceSamples(text)
                },
                playerNode: nil,
                format: nil,
                sampleRate: Self.streamSampleRate,
                onPlaybackStarted: onPlaybackStarted
            )
        }

        self.audioEngine = engine
        self.playerNode = player

        let session = StreamingTTSSession(
            fetchSamples: { [weak self] text in
                guard let self else { throw CancellationError() }
                return try await self.fetchSentenceSamples(text)
            },
            playerNode: player,
            format: streamFormat,
            sampleRate: Self.streamSampleRate,
            onPlaybackStarted: onPlaybackStarted
        )
        self.activeStreamingSession = session
        return session
    }

    /// Used by `StreamingTTSSession` to fetch a single sentence's PCM.
    /// Returns the raw 16-bit signed little-endian samples decoded from
    /// ElevenLabs' streaming endpoint. Decoding runs `nonisolated` so the
    /// per-byte loop does not contend with LLM streaming, screenshot
    /// encoding, or UI updates on the main actor — that contention was
    /// the biggest cause of audible stutter.
    func fetchSentenceSamples(_ text: String) async throws -> [Int16] {
        guard let apiKey, !apiKey.isEmpty else {
            throw NSError(domain: "ElevenLabsTTS", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "API key not configured"])
        }
        guard !voiceID.isEmpty,
              let fastURL = Self.streamRequestURL(voiceID: voiceID, optimizeStreamingLatency: "2"),
              let safeURL = Self.streamRequestURL(voiceID: voiceID, optimizeStreamingLatency: "0") else {
            throw NSError(domain: "ElevenLabsTTS", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "Voice ID not configured"])
        }

        // Capture only Sendable values, then jump off the main actor.
        let urlSession = self.session
        let fastRequest = Self.makeSpeechRequest(url: fastURL, apiKey: apiKey, text: text)
        let fastSamples = try await Self.decodePCMSamples(request: fastRequest, session: urlSession)
        guard Self.isSuspiciouslyShortAudio(samples: fastSamples, forText: text) else {
            return fastSamples
        }

        // ElevenLabs can occasionally EOF cleanly with truncated PCM even
        // on latency level 2. Retry once with the safest latency setting
        // before giving the playback pipeline a clipped sentence.
        print("⚠️ ElevenLabs sentence PCM suspiciously short; retrying with optimize_streaming_latency=0")
        let safeRequest = Self.makeSpeechRequest(url: safeURL, apiKey: apiKey, text: text)
        let safeSamples = try await Self.decodePCMSamples(request: safeRequest, session: urlSession)
        return Self.isSuspiciouslyShortAudio(samples: safeSamples, forText: text) ? fastSamples : safeSamples
    }

    /// Off-actor PCM decode. Runs as a `nonisolated` static so the byte
    /// loop never hops back to MainActor between bytes. Returns raw
    /// 16-bit signed little-endian samples.
    nonisolated private static func decodePCMSamples(
        request: URLRequest,
        session: URLSession
    ) async throws -> [Int16] {
        let (asyncBytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "ElevenLabsTTS",
                code: (response as? HTTPURLResponse)?.statusCode ?? -12,
                userInfo: [NSLocalizedDescriptionKey: "TTS HTTP error"]
            )
        }

        var samples: [Int16] = []
        samples.reserveCapacity(8_192)
        var pendingByte: UInt8?
        for try await byte in asyncBytes {
            try Task.checkCancellation()
            if let lo = pendingByte {
                let hi = byte
                samples.append(Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8)))
                pendingByte = nil
            } else {
                pendingByte = byte
            }
        }
        return samples
    }

    nonisolated private static func isSuspiciouslyShortAudio(samples: [Int16], forText text: String) -> Bool {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        guard words >= 6 else { return false }
        let durationSeconds = Double(samples.count) / Self.streamSampleRate
        return durationSeconds < 0.4
    }

    // MARK: - Public lifecycle

    var isPlaying: Bool {
        playerNode?.isPlaying ?? false
    }

    func stopPlayback() {
        activeStreamingSession?.cancel()
        activeStreamingSession = nil
        stopPlaybackInternal()
    }

    // MARK: - Private helpers

    private func stopPlaybackInternal() {
        streamingTask?.cancel()
        streamingTask = nil
        playerNode?.stop()
        playerNode = nil
        audioEngine?.stop()
        audioEngine = nil
    }

    fileprivate static func makeStreamFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: streamSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    fileprivate static func streamRequestURL(
        voiceID: String,
        optimizeStreamingLatency: String = "2"
    ) -> URL? {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)/stream")
        components?.queryItems = [
            URLQueryItem(name: "output_format", value: streamOutputFormatQueryValue),
            // Level 2 ("moderate") instead of 3 ("high"). Level 3 has
            // been observed to truncate mid-stream — the HTTP body
            // closes cleanly partway through the synthesis, so the
            // caller gets fewer samples than expected and no error.
            // If level 2 still returns suspiciously short PCM, sentence
            // fetches retry once at level 0 before playback.
            URLQueryItem(name: "optimize_streaming_latency", value: optimizeStreamingLatency)
        ]
        return components?.url
    }

    fileprivate static func makeSpeechRequest(url: URL, apiKey: String, text: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    @discardableResult
    fileprivate static func scheduleSamples(
        _ samples: [Int16],
        on player: AVAudioPlayerNode,
        format: AVAudioFormat
    ) -> AVAudioFramePosition {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return 0
        }
        let scale: Float = 1.0 / 32_768.0
        for index in samples.indices {
            channel[index] = Float(samples[index]) * scale
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        // The player may have been detached between sentence enqueue
        // and this scheduling pass (e.g. user spoke again, which calls
        // `stopPlayback` → `stopPlaybackInternal` → engine teardown).
        // `AVAudioPlayerNode.engine` is a weak reference; once the
        // engine deallocates, `engine` returns nil. Calling `play()` on
        // an engineless node throws `_engine != nil` and crashes the
        // process — guard before scheduling and starting.
        guard let engine = player.engine else { return 0 }
        // If the engine isn't running, drop this buffer rather than
        // restart mid-stream — restarting AVAudioEngine while samples
        // are queued causes audible skipping/jumping. The streaming
        // session owner is responsible for keeping the engine running
        // for the full response; if it stopped, the response is over.
        guard engine.isRunning else { return 0 }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
        return AVAudioFramePosition(buffer.frameLength)
    }

    fileprivate static func waitForPlaybackToDrain(
        _ player: AVAudioPlayerNode,
        scheduledFrameCount: AVAudioFramePosition,
        sampleRate: Double = ElevenLabsTTSClient.streamSampleRate
    ) async {
        guard scheduledFrameCount > 0 else {
            player.stop()
            return
        }

        // AVAudioPlayerNode can keep reporting `isPlaying` after queued
        // buffers are exhausted. Poll rendered frames, but do not stop
        // merely because the rendered-frame value is temporarily nil or
        // unchanged; that clipped Cartesia/Deepgram playback when their
        // players were started before buffers were queued. The wall-clock
        // deadline remains as a conservative stuck-device guard.
        let expectedDuration = Double(scheduledFrameCount) / sampleRate
        let deadline = Date().addingTimeInterval(max(expectedDuration + 3.0, 3.0))

        while !Task.isCancelled {
            if let renderedFrame = Self.renderedSampleTime(for: player),
               renderedFrame >= scheduledFrameCount {
                break
            }

            if Date() >= deadline {
                break
            }

            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        player.stop()
    }

    private static func renderedSampleTime(for player: AVAudioPlayerNode) -> AVAudioFramePosition? {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return playerTime.sampleTime
    }

    private static func makeTTSError(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "ElevenLabsTTS",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    fileprivate static func isExpectedCancellation(_ error: Error) -> Bool {
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

    fileprivate func tearDownStreamingEngineIfMatches(_ engine: AVAudioEngine) {
        guard audioEngine === engine else { return }
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
    }
}

// MARK: - StreamingTTSSession

/// Sentence-pipelined TTS session. Caller pushes text deltas as the LLM
/// streams; the session detects sentence boundaries, fires per-sentence
/// TTS requests in parallel, and schedules audio onto the shared player
/// node in sentence order.
@MainActor
final class StreamingTTSSession {
    /// Per-sentence PCM fetcher. Provider-agnostic — ElevenLabs and
    /// Cartesia both supply one of these on session creation. The
    /// session itself owns no networking code; it only orchestrates
    /// fetch-in-parallel and schedule-in-order.
    fileprivate let fetchSamples: @Sendable (String) async throws -> [Int16]
    fileprivate let playerNode: AVAudioPlayerNode?
    fileprivate let format: AVAudioFormat?
    fileprivate let sampleRate: Double
    fileprivate let onPlaybackStarted: @MainActor () -> Void

    private var pendingText: String = ""
    /// Serialized chain of sentence-playback tasks. Each new sentence
    /// awaits the previous one before scheduling its own buffers, which
    /// keeps audio in spoken order even though network fetches run in
    /// parallel.
    private var jobChain: Task<Void, Error>?
    private var didFireStartCallback = false
    private var scheduledFrameCount: AVAudioFramePosition = 0
    private(set) var isCancelled = false
    private var sentenceCount = 0
    /// Words required before we'll cut on a punctuation+space. Prevents
    /// "Mr." / "Dr." / "U.S." mid-name splits in normal prose.
    private static let minimumWordsPerSentence = 4
    private static let knownAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "jr", "sr", "st", "vs", "etc", "eg", "ie"
    ]

    fileprivate init(
        fetchSamples: @escaping @Sendable (String) async throws -> [Int16],
        playerNode: AVAudioPlayerNode?,
        format: AVAudioFormat?,
        sampleRate: Double,
        onPlaybackStarted: @escaping @MainActor () -> Void
    ) {
        self.fetchSamples = fetchSamples
        self.playerNode = playerNode
        self.format = format
        self.sampleRate = sampleRate
        self.onPlaybackStarted = onPlaybackStarted
    }

    /// Adds the text the LLM produced since the last call. Sentence
    /// boundaries already present in the buffered text are flushed
    /// immediately. Trailing un-terminated text is held until the next
    /// call or until `finish()`.
    func appendText(_ delta: String) {
        guard !isCancelled, !delta.isEmpty else { return }
        pendingText += delta
        flushCompleteSentences()
    }

    /// Flushes any unterminated tail as a final sentence and waits for
    /// playback to drain. Call once when the LLM stream ends.
    func finish() async throws {
        guard !isCancelled else { throw CancellationError() }
        let remaining = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        if !remaining.isEmpty {
            enqueueSentence(remaining)
        }
        if let chain = jobChain {
            do {
                try await chain.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw error
            }
        }

        if let playerNode {
            await ElevenLabsTTSClient.waitForPlaybackToDrain(
                playerNode,
                scheduledFrameCount: scheduledFrameCount,
                sampleRate: sampleRate
            )
        }
    }

    /// Cancels in-flight fetches and tears down the engine. Safe to call
    /// repeatedly; subsequent appendText calls become no-ops.
    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        jobChain?.cancel()
        jobChain = nil
    }

    // MARK: - Sentence detection

    /// Soft cap on words per TTS request. Sentences longer than this
    /// are clause-split on commas / semicolons / em-dashes, because:
    /// - Each TTS provider's stream truncation risk grows with audio
    ///   length — a 5-second synthesis is more likely to EOF early
    ///   than a 1.5-second one.
    /// - Smaller per-clause requests parallelize better; the chain
    ///   keeps audio queued ahead of playback even on slower turns.
    fileprivate static let maxWordsPerTTSChunk = 25

    private func flushCompleteSentences() {
        while let cutEnd = nextSentenceCut(in: pendingText) {
            let sentence = String(pendingText[..<cutEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pendingText = String(pendingText[cutEnd...])
            guard sentence.count >= 2 else { continue }

            // Long sentence — split on commas / semicolons / em-dashes
            // so individual TTS requests stay short.
            if Self.wordCount(sentence) > Self.maxWordsPerTTSChunk {
                let clauses = Self.splitLongSentenceIntoClauses(sentence)
                for clause in clauses where clause.count >= 2 {
                    enqueueSentence(clause)
                }
            } else {
                enqueueSentence(sentence)
            }
        }
    }

    fileprivate static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }

    /// Splits an over-long sentence into clauses on `,`, `;`, ` — `, ` -- `.
    /// Each clause is ≤ `maxWordsPerTTSChunk` words; if a single
    /// clause-free run exceeds the cap we hard-split on space at the
    /// nearest word boundary so no single TTS request is ever multi-
    /// paragraph long. Punctuation that ended the original sentence
    /// (`.`, `!`, `?`) stays on the final clause.
    fileprivate static func splitLongSentenceIntoClauses(_ sentence: String) -> [String] {
        var clauses: [String] = []
        var buffer = ""

        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { clauses.append(trimmed) }
            buffer = ""
        }

        var index = sentence.startIndex
        while index < sentence.endIndex {
            let ch = sentence[index]
            buffer.append(ch)

            // Clause break on comma / semicolon / em-dash sequence.
            let isBreakChar = (ch == "," || ch == ";")
            if isBreakChar && wordCount(buffer) >= 5 {
                flush()
            }
            index = sentence.index(after: index)
        }
        flush()

        // Defensive hard-split in case a clause is still too long
        // (long stretch with no comma — common in spoken responses).
        var safe: [String] = []
        for clause in clauses {
            if wordCount(clause) <= maxWordsPerTTSChunk {
                safe.append(clause)
            } else {
                let words = clause.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                var chunk: [Substring] = []
                for w in words {
                    chunk.append(w)
                    if chunk.count >= maxWordsPerTTSChunk {
                        safe.append(chunk.joined(separator: " "))
                        chunk.removeAll()
                    }
                }
                if !chunk.isEmpty { safe.append(chunk.joined(separator: " ")) }
            }
        }
        return safe
    }

    /// Returns the index just past a complete sentence (punctuation +
    /// terminating whitespace), or nil if no boundary is present yet.
    private func nextSentenceCut(in text: String) -> String.Index? {
        var index = text.startIndex
        var wordCount = 0
        var inWord = false

        while index < text.endIndex {
            let char = text[index]
            if char.isLetter || char.isNumber {
                inWord = true
            } else if inWord {
                wordCount += 1
                inWord = false
            }

            if char == "." || char == "!" || char == "?" || char == "\n" {
                let nextIndex = text.index(after: index)
                let isNewline = char == "\n"

                // Need at least a few words before we'll cut, except for
                // hard newline boundaries — those are explicit breaks.
                if !isNewline && wordCount < Self.minimumWordsPerSentence {
                    index = nextIndex
                    continue
                }

                guard nextIndex < text.endIndex else {
                    // End of buffer — wait for more text. The LLM may
                    // continue past this punctuation (e.g. a number like
                    // "3.14" or a partial token). `finish()` flushes the
                    // tail when the stream actually ends.
                    return nil
                }

                let nextChar = text[nextIndex]
                let endsSentence = isNewline || nextChar.isWhitespace || nextChar.isNewline
                if !endsSentence {
                    index = nextIndex
                    continue
                }

                // Reject common abbreviations: "Mr.", "Dr.", "etc."
                if char == "." {
                    if let prevWord = lastWord(in: text, before: index),
                       Self.knownAbbreviations.contains(prevWord.lowercased()) {
                        index = nextIndex
                        continue
                    }
                }

                // Walk past trailing whitespace so the next sentence
                // doesn't start with leading spaces.
                var endIndex = nextIndex
                while endIndex < text.endIndex {
                    let c = text[endIndex]
                    guard c.isWhitespace || c.isNewline else { break }
                    endIndex = text.index(after: endIndex)
                }
                return endIndex
            }

            index = text.index(after: index)
        }
        return nil
    }

    private func lastWord(in text: String, before index: String.Index) -> String? {
        var end = index
        while end > text.startIndex {
            let prev = text.index(before: end)
            if text[prev].isLetter {
                end = prev
            } else {
                break
            }
        }
        guard end < index else { return nil }
        return String(text[end..<index])
    }

    // MARK: - Enqueue + playback

    /// Schedules a chunk of pre-decoded PCM at the head of the playback
    /// chain. Used to play cached filler phrases ("let me take a look.")
    /// the instant the streaming session opens — before the LLM has
    /// emitted a single token. Subsequent LLM sentences enqueue behind
    /// this and play in order, buying ~1-2 seconds of perceived latency
    /// against model TTFT.
    func enqueuePrebakedSamples(_ samples: [Int16]) {
        guard !isCancelled, !samples.isEmpty,
              let playerNode, let format else { return }

        let predecessor = jobChain
        let player = playerNode
        let streamFormat = format
        jobChain = Task { [weak self] in
            if let predecessor { _ = try? await predecessor.value }
            try Task.checkCancellation()
            guard let self, !self.isCancelled else { return }

            await MainActor.run {
                guard !self.isCancelled, player.engine != nil else { return }
                let frames = ElevenLabsTTSClient.scheduleSamples(samples, on: player, format: streamFormat)
                if frames > 0 {
                    self.scheduledFrameCount += frames
                }
                if frames > 0 && !self.didFireStartCallback {
                    self.didFireStartCallback = true
                    self.onPlaybackStarted()
                }
            }
        }
    }

    private func enqueueSentence(_ text: String) {
        // No audio engine? Drop the sentence silently — never fall
        // back to a system synthesizer (different voice).
        guard let playerNode, let format else { return }

        sentenceCount += 1
        let sentenceIndex = sentenceCount

        // Fetch immediately — runs in parallel with previous sentences'
        // fetches/playback. The fetch closure is provider-agnostic.
        let fetchClosure = self.fetchSamples
        let fetchTask = Task.detached(priority: .userInitiated) { () -> [Int16] in
            try await fetchClosure(text)
        }

        let predecessor = jobChain
        let player = playerNode
        let streamFormat = format

        jobChain = Task { [weak self] in
            // Order preservation: wait for the previous sentence's
            // scheduling+playback chain before scheduling our own buffers.
            if let predecessor {
                _ = try? await predecessor.value
            }
            try Task.checkCancellation()
            guard let self, !self.isCancelled else { return }

            let samples: [Int16]
            do {
                samples = try await fetchTask.value
            } catch is CancellationError {
                return
            } catch {
                // Drop this sentence — never play a system-voice
                // fallback. The next sentence keeps the response moving.
                print("⚠️ Sentence \(sentenceIndex) TTS fetch failed; skipping: \(error)")
                return
            }

            try Task.checkCancellation()
            guard !samples.isEmpty else { return }

            // Truncation detection: if the decoded PCM is suspiciously
            // short for the text we sent, the stream EOF'd early.
            // Heuristic: ≥6 words of input should produce ≥0.4s of
            // audio (~8800 samples at 22.05 kHz). Below that, log so
            // we can see truncation rate over time.
            let words = Self.wordCount(text)
            let durationSeconds = Double(samples.count) / self.sampleRate
            if words >= 6 && durationSeconds < 0.4 {
                print("⚠️ Sentence \(sentenceIndex) PCM suspiciously short: \(words) words, \(String(format: "%.2f", durationSeconds))s audio — likely upstream truncation")
            }

            await MainActor.run {
                // Re-check cancellation inside the main actor — the
                // session may have been torn down while the fetch was
                // in flight, in which case scheduling onto a detached
                // player would crash with `_engine != nil`.
                guard !self.isCancelled, player.engine != nil else { return }
                let frames = ElevenLabsTTSClient.scheduleSamples(samples, on: player, format: streamFormat)
                if frames > 0 {
                    self.scheduledFrameCount += frames
                }
                if frames > 0 && !self.didFireStartCallback {
                    self.didFireStartCallback = true
                    self.onPlaybackStarted()
                }
            }
            // Do NOT sleep here. AVAudioPlayerNode plays scheduled
            // buffers in the order they were appended, contiguously.
            // The chain is already serialized on `predecessor.value`.
        }
    }
}

// MARK: - FillerPhraseLibrary

/// Pre-renders short neutral fillers ("one moment.") via ElevenLabs
/// and caches the PCM on disk. When a voice response genuinely needs
/// latency cover, the streaming session can schedule one before the
/// LLM has emitted a token.
///
/// Cache keying uses (phrase + voiceID + sample-rate). Switching voices
/// or sample rate naturally invalidates the old cache without a
/// versioning scheme.
@MainActor
final class FillerPhraseLibrary {
    static let shared = FillerPhraseLibrary()

    /// Default fillers — intentionally bland and non-committal. Avoid
    /// greetings, agreement words, and screen-specific claims because
    /// they sound wrong when prepended to short text-only replies.
    static let defaultPhrases: [String] = [
        "one moment.",
        "give me a second.",
        "checking now."
    ]

    private var samplesByPhrase: [String: [Int16]] = [:]
    private var phrases: [String] = FillerPhraseLibrary.defaultPhrases
    private var lastChosenIndex: Int?
    private weak var client: (any OpenClickyTTSClient)?
    private var preparationTask: Task<Void, Never>?
    private var preparedVoiceID: String?

    /// Loads any previously cached fillers from disk and kicks off a
    /// background fetch for any missing ones. Safe to call multiple
    /// times — re-running with a changed voiceID re-fetches.
    func prepare(client: any OpenClickyTTSClient) {
        self.client = client
        let voiceID = client.voiceID
        if preparedVoiceID == voiceID, !samplesByPhrase.isEmpty { return }
        preparedVoiceID = voiceID
        samplesByPhrase.removeAll(keepingCapacity: true)

        // Synchronous disk load — cache hits are tiny (~80KB per file)
        // and we want them ready before the first response.
        for phrase in phrases {
            if let cached = Self.loadCachedSamples(phrase: phrase, voiceID: voiceID) {
                samplesByPhrase[phrase] = cached
            }
        }

        // Fire fetches for missing phrases in the background.
        let missing = phrases.filter { samplesByPhrase[$0] == nil }
        guard !missing.isEmpty else { return }
        preparationTask?.cancel()
        preparationTask = Task { [weak self, weak client] in
            await withTaskGroup(of: (String, [Int16]?).self) { group in
                for phrase in missing {
                    group.addTask {
                        guard let client else { return (phrase, nil) }
                        do {
                            let samples = try await client.fetchSentenceSamples(phrase)
                            Self.writeCachedSamples(samples, phrase: phrase, voiceID: voiceID)
                            return (phrase, samples)
                        } catch {
                            print("⚠️ Filler fetch failed for \(phrase): \(error)")
                            return (phrase, nil)
                        }
                    }
                }
                for await (phrase, samples) in group {
                    if let samples, !samples.isEmpty {
                        await MainActor.run {
                            self?.samplesByPhrase[phrase] = samples
                        }
                    }
                }
            }
        }
    }

    struct FillerSelection {
        let phrase: String
        let samples: [Int16]
    }

    /// Returns a random pre-rendered filler (text + PCM samples), or nil
    /// if the library hasn't finished caching any phrases yet. Avoids
    /// repeating the most-recently-played phrase when at least two
    /// are available. The phrase text is returned alongside the samples
    /// so the LLM can be told exactly which opener was spoken — this is
    /// what binds Haiku's response to the filler ("let me check" → the
    /// reply continues from a checking posture instead of restarting).
    func randomFiller() -> FillerSelection? {
        let available = phrases.enumerated().compactMap { (index, phrase) -> (Int, String, [Int16])? in
            guard let samples = samplesByPhrase[phrase], !samples.isEmpty else { return nil }
            return (index, phrase, samples)
        }
        guard !available.isEmpty else { return nil }

        let candidates: [(Int, String, [Int16])]
        if available.count > 1, let last = lastChosenIndex {
            candidates = available.filter { $0.0 != last }
        } else {
            candidates = available
        }
        let pick = candidates.randomElement() ?? available[0]
        lastChosenIndex = pick.0
        return FillerSelection(phrase: pick.1, samples: pick.2)
    }

    // MARK: - Disk cache

    nonisolated private static func cacheDirectory() -> URL? {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("FillerCache", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            print("⚠️ Filler cache dir error: \(error)")
            return nil
        }
    }

    nonisolated private static func cacheFileURL(phrase: String, voiceID: String) -> URL? {
        guard let dir = cacheDirectory() else { return nil }
        // Format-versioned key: phrase + voice + sample-rate. Bump the
        // version suffix when changing the on-disk encoding.
        let raw = "\(phrase)|\(voiceID)|\(Int(ElevenLabsTTSClient.streamSampleRate))|v1"
        let key = Self.hexFNV1a(raw)
        return dir.appendingPathComponent("\(key).pcm")
    }

    nonisolated private static func loadCachedSamples(phrase: String, voiceID: String) -> [Int16]? {
        guard let url = cacheFileURL(phrase: phrase, voiceID: voiceID),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count % 2 == 0 else {
            return nil
        }
        // Reinterpret raw bytes as Int16 little-endian samples.
        var samples = [Int16](repeating: 0, count: data.count / 2)
        samples.withUnsafeMutableBytes { dest in
            _ = data.copyBytes(to: dest)
        }
        return samples
    }

    nonisolated private static func writeCachedSamples(_ samples: [Int16], phrase: String, voiceID: String) {
        guard let url = cacheFileURL(phrase: phrase, voiceID: voiceID) else { return }
        let data = samples.withUnsafeBufferPointer { buffer -> Data in
            Data(buffer: buffer)
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            print("⚠️ Filler cache write failed: \(error)")
        }
    }

    /// Tiny non-crypto hash for filename keys. We don't need collision
    /// resistance — each input is a known phrase string, never user data.
    nonisolated private static func hexFNV1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - CartesiaTTSClient

/// TTS provider parallel to `ElevenLabsTTSClient`. Posts to Cartesia's
/// `/tts/bytes` endpoint requesting raw PCM_S16LE @ 22.05 kHz so the
/// returned bytes plug directly into the same `StreamingTTSSession`
/// pipeline. Public surface mirrors ElevenLabs (same method names,
/// same signatures) so `CompanionManager` can switch between them via
/// a single `currentTTSClient` reference without provider-specific
/// branching elsewhere.
@MainActor
final class CartesiaTTSClient {
    private var apiKey: String?
    private(set) var voiceID: String
    private let session: URLSession
    // Cartesia-Version pinned to the latest stable. Verified against
    // https://docs.cartesia.ai (2026-04-26). The voice-ID request
    // shape (`{"voice": {"mode": "id", ...}}`) is the supported format
    // on this version; voice embeddings will stop working June 2026.
    nonisolated private static let cartesiaVersionHeader = "2026-03-01"
    nonisolated private static let modelID = "sonic-2"

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamingTask: Task<Void, Error>?
    private weak var activeStreamingSession: StreamingTTSSession?

    nonisolated static let streamSampleRate: Double = 22_050
    private static let chunkSampleCount = 2_048

    init(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: configuration)
    }

    func updateConfiguration(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func warmUpConnection() {
        guard let url = URL(string: "https://api.cartesia.ai") else { return }
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

    // MARK: One-shot streaming

    func speakText(
        _ text: String,
        waitUntilFinished: Bool = true,
        onPlaybackStarted: (() -> Void)? = nil
    ) async throws {
        guard let apiKey, !apiKey.isEmpty else {
            throw Self.makeError(-100, "Cartesia API key is not configured")
        }
        guard !voiceID.isEmpty,
              let url = URL(string: "https://api.cartesia.ai/tts/bytes") else {
            throw Self.makeError(-101, "Cartesia voice ID is not configured")
        }

        stopPlaybackInternal()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = ElevenLabsTTSClient.makeStreamFormat() else {
            throw Self.makeError(-102, "Could not build PCM stream format")
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do { try engine.start() } catch {
            throw Self.makeError(-103, "Audio engine failed to start: \(error.localizedDescription)")
        }
        self.audioEngine = engine
        self.playerNode = player

        let request = Self.makeRequest(url: url, apiKey: apiKey, voiceID: voiceID, text: text)
        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            stopPlaybackInternal()
            throw CancellationError()
        } catch {
            stopPlaybackInternal()
            if Self.isExpectedCancellation(error) { throw CancellationError() }
            throw Self.makeError(-104, "Cartesia request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            stopPlaybackInternal()
            throw Self.makeError(-105, "Cartesia returned an invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            var body = Data()
            do {
                for try await byte in asyncBytes {
                    body.append(byte)
                    if body.count > 4096 { break }
                }
            } catch {}
            stopPlaybackInternal()
            let bodyText = String(data: body, encoding: .utf8) ?? "Unknown error"
            throw Self.makeError(http.statusCode, "Cartesia API error \(http.statusCode): \(bodyText.prefix(500))")
        }

        let playerRef = player
        let engineRef = engine
        let streamFormatRef = streamFormat
        var didFireStartCallback = false
        var pendingByte: UInt8?
        var sampleAccumulator: [Int16] = []
        var scheduledFrameCount: AVAudioFramePosition = 0
        sampleAccumulator.reserveCapacity(Self.chunkSampleCount)

        let task = Task { [weak self] in
            do {
                for try await byte in asyncBytes {
                    try Task.checkCancellation()
                    if let lo = pendingByte {
                        let hi = byte
                        sampleAccumulator.append(Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8)))
                        pendingByte = nil
                    } else {
                        pendingByte = byte
                    }
                    if sampleAccumulator.count >= Self.chunkSampleCount {
                        let chunk = sampleAccumulator
                        sampleAccumulator.removeAll(keepingCapacity: true)
                        let frames = await MainActor.run { () -> AVAudioFramePosition in
                            let f = ElevenLabsTTSClient.scheduleSamples(chunk, on: playerRef, format: streamFormatRef)
                            if f > 0 && !didFireStartCallback {
                                didFireStartCallback = true
                                onPlaybackStarted?()
                            }
                            return f
                        }
                        scheduledFrameCount += frames
                    }
                }
                if !sampleAccumulator.isEmpty {
                    let tail = sampleAccumulator
                    let frames = await MainActor.run { () -> AVAudioFramePosition in
                        let f = ElevenLabsTTSClient.scheduleSamples(tail, on: playerRef, format: streamFormatRef)
                        if f > 0 && !didFireStartCallback {
                            didFireStartCallback = true
                            onPlaybackStarted?()
                        }
                        return f
                    }
                    scheduledFrameCount += frames
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Self.isExpectedCancellation(error) { throw CancellationError() }
                throw error
            }
            await ElevenLabsTTSClient.waitForPlaybackToDrain(playerRef, scheduledFrameCount: scheduledFrameCount)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.audioEngine === engineRef {
                    self.audioEngine?.stop()
                    self.audioEngine = nil
                    self.playerNode = nil
                }
            }
        }
        self.streamingTask = task
        if waitUntilFinished {
            do { try await task.value }
            catch is CancellationError { stopPlaybackInternal(); throw CancellationError() }
            catch { stopPlaybackInternal(); throw error }
        }
    }

    // MARK: Sentence-pipelined streaming

    func beginStreamingResponse(onPlaybackStarted: @escaping @MainActor () -> Void) -> StreamingTTSSession {
        stopPlaybackInternal()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = ElevenLabsTTSClient.makeStreamFormat() else {
            return StreamingTTSSession(
                fetchSamples: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchSentenceSamples(text)
                },
                playerNode: nil,
                format: nil,
                sampleRate: Self.streamSampleRate,
                onPlaybackStarted: onPlaybackStarted
            )
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do { try engine.start() } catch {
            print("⚠️ AVAudioEngine failed to start Cartesia streaming session: \(error)")
            return StreamingTTSSession(
                fetchSamples: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchSentenceSamples(text)
                },
                playerNode: nil,
                format: nil,
                sampleRate: Self.streamSampleRate,
                onPlaybackStarted: onPlaybackStarted
            )
        }
        self.audioEngine = engine
        self.playerNode = player
        let session = StreamingTTSSession(
            fetchSamples: { [weak self] text in
                guard let self else { throw CancellationError() }
                return try await self.fetchSentenceSamples(text)
            },
            playerNode: player,
            format: streamFormat,
            sampleRate: Self.streamSampleRate,
            onPlaybackStarted: onPlaybackStarted
        )
        self.activeStreamingSession = session
        return session
    }

    func fetchSentenceSamples(_ text: String) async throws -> [Int16] {
        guard let apiKey, !apiKey.isEmpty else {
            throw Self.makeError(-10, "Cartesia API key not configured")
        }
        guard !voiceID.isEmpty, let url = URL(string: "https://api.cartesia.ai/tts/bytes") else {
            throw Self.makeError(-11, "Cartesia voice ID not configured")
        }
        let request = Self.makeRequest(url: url, apiKey: apiKey, voiceID: voiceID, text: text)
        let urlSession = self.session
        return try await Self.decodePCMSamples(request: request, session: urlSession)
    }

    nonisolated private static func decodePCMSamples(
        request: URLRequest,
        session: URLSession
    ) async throws -> [Int16] {
        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "CartesiaTTS",
                code: (response as? HTTPURLResponse)?.statusCode ?? -12,
                userInfo: [NSLocalizedDescriptionKey: "Cartesia HTTP error"]
            )
        }
        var samples: [Int16] = []
        samples.reserveCapacity(8_192)
        var pendingByte: UInt8?
        for try await byte in asyncBytes {
            try Task.checkCancellation()
            if let lo = pendingByte {
                samples.append(Int16(bitPattern: UInt16(lo) | (UInt16(byte) << 8)))
                pendingByte = nil
            } else {
                pendingByte = byte
            }
        }
        return samples
    }

    // MARK: Request building

    nonisolated private static func makeRequest(url: URL, apiKey: String, voiceID: String, text: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Verified against https://docs.cartesia.ai (2026-04-26):
        // current auth scheme is `Authorization: Bearer <key>` (the
        // legacy `X-API-Key` header is rejected on `2026-03-01`).
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(cartesiaVersionHeader, forHTTPHeaderField: "Cartesia-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model_id": modelID,
            "transcript": text,
            "voice": ["mode": "id", "id": voiceID],
            "output_format": [
                "container": "raw",
                "encoding": "pcm_s16le",
                "sample_rate": Int(streamSampleRate)
            ],
            "language": "en"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    nonisolated private static func makeError(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "CartesiaTTS",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    nonisolated private static func isExpectedCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return true }
        let desc = String(describing: error).lowercased()
        return desc == "cancellationerror()" || desc.contains("cancelled") || desc.contains("canceled")
    }
}

// MARK: - OpenClickyTTSClient protocol

/// Common surface implemented by all TTS providers (ElevenLabs,
/// Cartesia). Lets `CompanionManager` switch providers at runtime
/// without provider-specific branching anywhere outside the active-
/// client selector.
@MainActor
protocol OpenClickyTTSClient: AnyObject {
    var voiceID: String { get }
    var isPlaying: Bool { get }
    func updateConfiguration(apiKey: String?, voiceID: String)
    func warmUpConnection()
    func speakText(_ text: String, waitUntilFinished: Bool, onPlaybackStarted: (() -> Void)?) async throws
    func beginStreamingResponse(onPlaybackStarted: @escaping @MainActor () -> Void) -> StreamingTTSSession
    func fetchSentenceSamples(_ text: String) async throws -> [Int16]
    func stopPlayback()
}

extension ElevenLabsTTSClient: OpenClickyTTSClient {}
extension CartesiaTTSClient: OpenClickyTTSClient {}

extension OpenClickyTTSClient {
    /// Brief overload for callers that only need to say something with
    /// default options. Works around the protocol's inability to carry
    /// default-arg values through existentials.
    func speakText(_ text: String, onPlaybackStarted: (() -> Void)? = nil) async throws {
        try await speakText(text, waitUntilFinished: true, onPlaybackStarted: onPlaybackStarted)
    }
}

// MARK: - OpenClickyTTSProvider

nonisolated enum OpenClickyTTSProvider: String, CaseIterable, Identifiable {
    case elevenLabs = "elevenlabs"
    case cartesia = "cartesia"
    case deepgram = "deepgram"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .cartesia: return "Cartesia"
        case .deepgram: return "Deepgram Aura"
        }
    }
    static func resolve(_ raw: String?) -> OpenClickyTTSProvider {
        guard let raw, let parsed = OpenClickyTTSProvider(rawValue: raw) else { return .elevenLabs }
        return parsed
    }
}

// MARK: - DeepgramTTSClient

/// Deepgram Aura TTS client. Posts to `https://api.deepgram.com/v1/speak`
/// with `encoding=linear16&sample_rate=22050&container=none` so the
/// returned bytes are raw Int16 LE PCM and feed straight into the same
/// `StreamingTTSSession` pipeline used by ElevenLabs/Cartesia.
///
/// Auth header `Authorization: Token <key>` matches the existing
/// Deepgram STT path — the same API key works for both. Verified
/// against https://developers.deepgram.com (2026-04-26).
@MainActor
final class DeepgramTTSClient {
    private var apiKey: String?
    /// `voiceID` carries the Deepgram model/voice identifier (e.g.
    /// `aura-2-thalia-en`). Property name kept as `voiceID` to match
    /// the protocol surface.
    private(set) var voiceID: String
    private let session: URLSession

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamingTask: Task<Void, Error>?
    private weak var activeStreamingSession: StreamingTTSSession?

    /// Deepgram's supported `sample_rate` values for `encoding=linear16`
    /// are 8000, 16000, 24000, 32000, 44100, 48000 (verified empirically:
    /// `Unsupported audio format: sample_rate must be 8000, 16000, 24000,
    /// 32000, 44100, or 48000 when encoding=linear16`). 22050 — used by
    /// the ElevenLabs path — is rejected. We pick 24000 for Deepgram.
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
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: configuration)
    }

    func updateConfiguration(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func warmUpConnection() {
        guard let url = URL(string: "https://api.deepgram.com") else { return }
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

    // MARK: One-shot streaming

    func speakText(
        _ text: String,
        waitUntilFinished: Bool = true,
        onPlaybackStarted: (() -> Void)? = nil
    ) async throws {
        guard let apiKey, !apiKey.isEmpty else {
            throw Self.makeError(-100, "Deepgram API key is not configured")
        }
        guard !voiceID.isEmpty, let url = Self.streamRequestURL(model: voiceID) else {
            throw Self.makeError(-101, "Deepgram TTS voice/model is not configured")
        }

        stopPlaybackInternal()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = Self.makeStreamFormat() else {
            throw Self.makeError(-102, "Could not build PCM stream format")
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do { try engine.start() } catch {
            throw Self.makeError(-103, "Audio engine failed to start: \(error.localizedDescription)")
        }
        self.audioEngine = engine
        self.playerNode = player

        let request = Self.makeRequest(url: url, apiKey: apiKey, text: text)
        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            stopPlaybackInternal()
            throw CancellationError()
        } catch {
            stopPlaybackInternal()
            if Self.isExpectedCancellation(error) { throw CancellationError() }
            throw Self.makeError(-104, "Deepgram request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            stopPlaybackInternal()
            throw Self.makeError(-105, "Deepgram returned an invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            var body = Data()
            do {
                for try await byte in asyncBytes {
                    body.append(byte)
                    if body.count > 4096 { break }
                }
            } catch {}
            stopPlaybackInternal()
            let bodyText = String(data: body, encoding: .utf8) ?? "Unknown error"
            throw Self.makeError(http.statusCode, "Deepgram API error \(http.statusCode): \(bodyText.prefix(500))")
        }

        let playerRef = player
        let engineRef = engine
        let streamFormatRef = streamFormat
        var didFireStartCallback = false
        var pendingByte: UInt8?
        var sampleAccumulator: [Int16] = []
        var scheduledFrameCount: AVAudioFramePosition = 0
        sampleAccumulator.reserveCapacity(Self.chunkSampleCount)

        let task = Task { [weak self] in
            do {
                for try await byte in asyncBytes {
                    try Task.checkCancellation()
                    if let lo = pendingByte {
                        let hi = byte
                        sampleAccumulator.append(Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8)))
                        pendingByte = nil
                    } else {
                        pendingByte = byte
                    }
                    if sampleAccumulator.count >= Self.chunkSampleCount {
                        let chunk = sampleAccumulator
                        sampleAccumulator.removeAll(keepingCapacity: true)
                        let frames = await MainActor.run { () -> AVAudioFramePosition in
                            let f = ElevenLabsTTSClient.scheduleSamples(chunk, on: playerRef, format: streamFormatRef)
                            if f > 0 && !didFireStartCallback {
                                didFireStartCallback = true
                                onPlaybackStarted?()
                            }
                            return f
                        }
                        scheduledFrameCount += frames
                    }
                }
                if !sampleAccumulator.isEmpty {
                    let tail = sampleAccumulator
                    let frames = await MainActor.run { () -> AVAudioFramePosition in
                        let f = ElevenLabsTTSClient.scheduleSamples(tail, on: playerRef, format: streamFormatRef)
                        if f > 0 && !didFireStartCallback {
                            didFireStartCallback = true
                            onPlaybackStarted?()
                        }
                        return f
                    }
                    scheduledFrameCount += frames
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Self.isExpectedCancellation(error) { throw CancellationError() }
                throw error
            }
            await ElevenLabsTTSClient.waitForPlaybackToDrain(
                playerRef,
                scheduledFrameCount: scheduledFrameCount,
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
        self.streamingTask = task
        if waitUntilFinished {
            do { try await task.value }
            catch is CancellationError { stopPlaybackInternal(); throw CancellationError() }
            catch { stopPlaybackInternal(); throw error }
        }
    }

    // MARK: Sentence-pipelined streaming

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
                onPlaybackStarted: onPlaybackStarted
            )
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do { try engine.start() } catch {
            print("⚠️ AVAudioEngine failed to start Deepgram streaming session: \(error)")
            return StreamingTTSSession(
                fetchSamples: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchSentenceSamples(text)
                },
                playerNode: nil,
                format: nil,
                sampleRate: Self.streamSampleRate,
                onPlaybackStarted: onPlaybackStarted
            )
        }
        self.audioEngine = engine
        self.playerNode = player
        let session = StreamingTTSSession(
            fetchSamples: { [weak self] text in
                guard let self else { throw CancellationError() }
                return try await self.fetchSentenceSamples(text)
            },
            playerNode: player,
            format: streamFormat,
            sampleRate: Self.streamSampleRate,
            onPlaybackStarted: onPlaybackStarted
        )
        self.activeStreamingSession = session
        return session
    }

    func fetchSentenceSamples(_ text: String) async throws -> [Int16] {
        guard let apiKey, !apiKey.isEmpty else {
            throw Self.makeError(-10, "Deepgram API key not configured")
        }
        guard !voiceID.isEmpty, let url = Self.streamRequestURL(model: voiceID) else {
            throw Self.makeError(-11, "Deepgram TTS voice/model not configured")
        }
        let request = Self.makeRequest(url: url, apiKey: apiKey, text: text)
        let urlSession = self.session
        return try await Self.decodePCMSamples(request: request, session: urlSession)
    }

    nonisolated private static func decodePCMSamples(
        request: URLRequest,
        session: URLSession
    ) async throws -> [Int16] {
        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            // Drain a chunk of the body so the error surfaces with the
            // server's actual message instead of a bare "HTTP error".
            var body = Data()
            do {
                for try await byte in asyncBytes {
                    body.append(byte)
                    if body.count > 4096 { break }
                }
            } catch {}
            let bodyText = String(data: body, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DeepgramTTS",
                code: (response as? HTTPURLResponse)?.statusCode ?? -12,
                userInfo: [NSLocalizedDescriptionKey: "Deepgram HTTP error \((response as? HTTPURLResponse)?.statusCode ?? 0): \(bodyText.prefix(500))"]
            )
        }

        // Deepgram returns a WAV file: 12-byte RIFF header, then chunks.
        // The "fmt " chunk is 24 bytes total (8 header + 16 body for
        // standard PCM). The "data" chunk header is 8 bytes ("data" +
        // 4-byte size). After that, samples begin. We scan for the
        // "data" tag rather than assuming a fixed 44-byte offset, because
        // some TTS engines insert extra metadata chunks (e.g., "LIST",
        // "fact") between the format and data chunks.
        var samples: [Int16] = []
        samples.reserveCapacity(8_192)

        var headerBuffer: [UInt8] = []
        headerBuffer.reserveCapacity(64)
        var pastHeader = false
        var pendingByte: UInt8?
        // Once we know the WAV "data" chunk's declared size, we stop
        // reading after that many bytes — anything beyond is padding
        // or trailing metadata that's not PCM.
        var dataBytesRemaining: Int = .max

        for try await byte in asyncBytes {
            try Task.checkCancellation()

            if !pastHeader {
                headerBuffer.append(byte)
                // Need at least 12 bytes to validate RIFF+WAVE.
                if headerBuffer.count == 12 {
                    let isRIFF = headerBuffer[0] == 0x52 && headerBuffer[1] == 0x49
                                && headerBuffer[2] == 0x46 && headerBuffer[3] == 0x46
                    let isWAVE = headerBuffer[8] == 0x57 && headerBuffer[9] == 0x41
                                && headerBuffer[10] == 0x56 && headerBuffer[11] == 0x45
                    if !(isRIFF && isWAVE) {
                        // Not a WAV — treat the whole buffer as raw PCM
                        // and continue. Defensive in case Deepgram ever
                        // returns headerless bytes.
                        for b in headerBuffer {
                            if let lo = pendingByte {
                                samples.append(Int16(bitPattern: UInt16(lo) | (UInt16(b) << 8)))
                                pendingByte = nil
                            } else {
                                pendingByte = b
                            }
                        }
                        pastHeader = true
                        headerBuffer.removeAll()
                    }
                }
                // Walk forward looking for the "data" tag once we have
                // enough bytes. The minimum offset is 12 (RIFF/WAVE).
                if headerBuffer.count >= 16 && !pastHeader {
                    var index = 12
                    while index + 8 <= headerBuffer.count {
                        let chunkID = String(bytes: headerBuffer[index..<index+4], encoding: .ascii) ?? ""
                        let chunkSize = Int(headerBuffer[index+4])
                            | (Int(headerBuffer[index+5]) << 8)
                            | (Int(headerBuffer[index+6]) << 16)
                            | (Int(headerBuffer[index+7]) << 24)
                        if chunkID == "data" {
                            // PCM samples start immediately after this
                            // chunk's 8-byte header.
                            let pcmStart = index + 8
                            if headerBuffer.count > pcmStart {
                                // Carry over any bytes already read past
                                // the header.
                                for b in headerBuffer[pcmStart...] {
                                    if let lo = pendingByte {
                                        samples.append(Int16(bitPattern: UInt16(lo) | (UInt16(b) << 8)))
                                        pendingByte = nil
                                    } else {
                                        pendingByte = b
                                    }
                                }
                                let consumedFromData = headerBuffer.count - pcmStart
                                dataBytesRemaining = max(0, chunkSize - consumedFromData)
                            } else {
                                dataBytesRemaining = chunkSize
                            }
                            pastHeader = true
                            headerBuffer.removeAll()
                            break
                        }
                        // Not the data chunk — skip past it. If we
                        // don't have all of the chunk yet, stop and
                        // wait for more bytes.
                        let nextIndex = index + 8 + chunkSize
                        // RIFF chunks have a pad byte when their size
                        // is odd. Account for that.
                        let padded = chunkSize % 2 == 1 ? nextIndex + 1 : nextIndex
                        if padded > headerBuffer.count { break }
                        index = padded
                    }
                }
                continue
            }

            if dataBytesRemaining == 0 { break }
            if let lo = pendingByte {
                samples.append(Int16(bitPattern: UInt16(lo) | (UInt16(byte) << 8)))
                pendingByte = nil
            } else {
                pendingByte = byte
            }
            if dataBytesRemaining != .max { dataBytesRemaining -= 1 }
        }
        return samples
    }

    // MARK: Request building

    nonisolated private static func streamRequestURL(model: String) -> URL? {
        var components = URLComponents(string: "https://api.deepgram.com/v1/speak")
        // Verified against https://developers.deepgram.com/docs/tts-media-output-settings
        // (2026-04-26): for `encoding=linear16` the REST endpoint requires
        // `container=wav` (or omits container, which defaults to wav).
        // `container=none` is NOT a valid value for linear16 here. The
        // body therefore starts with a 44-byte RIFF/WAVE header — the
        // PCM decoder strips it before yielding samples.
        components?.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "\(Int(streamSampleRate))"),
            URLQueryItem(name: "container", value: "wav")
        ]
        return components?.url
    }

    nonisolated private static func makeRequest(url: URL, apiKey: String, text: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Deepgram auth (verified against developers.deepgram.com,
        // 2026-04-26): `Authorization: Token <key>` for both STT and TTS.
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = ["text": text]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    nonisolated private static func makeError(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "DeepgramTTS",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    nonisolated private static func isExpectedCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return true }
        let desc = String(describing: error).lowercased()
        return desc == "cancellationerror()" || desc.contains("cancelled") || desc.contains("canceled")
    }
}

extension DeepgramTTSClient: OpenClickyTTSClient {}
