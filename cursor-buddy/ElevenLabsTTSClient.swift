//
//  ElevenLabsTTSClient.swift
//  cursor-buddy
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
import CryptoKit
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
        guard let playerNode, playerNode.engine != nil else { return false }
        return playerNode.isPlaying
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
        if let playerNode {
            Self.stopPlayerIfAttached(playerNode)
        }
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
        format: AVAudioFormat,
        startPlaybackIfNeeded: Bool = true
    ) -> AVAudioFramePosition {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return 0
        }
        let scale: Float = (1.0 / 32_768.0) * Float(AppBundleConfiguration.voicePlaybackVolume())
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
        if startPlaybackIfNeeded && !player.isPlaying {
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
            stopPlayerIfAttached(player)
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

        stopPlayerIfAttached(player)
    }

    fileprivate nonisolated static func stopPlayerIfAttached(_ player: AVAudioPlayerNode) {
        guard player.engine != nil else { return }
        player.stop()
    }

    private static func renderedSampleTime(for player: AVAudioPlayerNode) -> AVAudioFramePosition? {
        guard player.engine != nil,
              let nodeTime = player.lastRenderTime,
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
    /// Sentence-by-sentence TTS fetches can complete just-in-time. Keep
    /// only a tiny PCM cushion before starting normal streamed speech:
    /// the voice path is supposed to start speaking as soon as the first
    /// sentence is synthesised, not wait for most of the model response.
    /// Explicit pre-baked fillers still play immediately because they
    /// exist to cover latency.
    private static let minimumBufferedSecondsBeforePlayback: Double = 0.25
    /// Cached filler should not fire instantly. A short thinking beat makes
    /// the exchange feel conversational, while still covering real model or
    /// screenshot latency before the substantive follow-up arrives.
    static let preResponseFillerDelayMilliseconds = 400
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
            maybeStartBufferedPlaybackIfReady(force: true)
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

    /// Defensive hard cap on words per TTS request when no useful spoken
    /// pause arrives. OpenClicky should prefer full stops / periods, then
    /// comma-like pauses once a clause is getting long, rather than cutting
    /// every short phrase on a fixed word count.
    static let maxWordsPerTTSChunk = 32
    /// Minimum words before a comma/colon/semicolon is treated as an
    /// early spoken pause during streaming. This lets long sentences start
    /// speaking naturally without chopping short asides.
    private static let minimumWordsBeforePauseCut = 15

    private func flushCompleteSentences() {
        while let cutEnd = Self.nextSentenceCut(in: pendingText) {
            let sentence = String(pendingText[..<cutEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pendingText = String(pendingText[cutEnd...])
            guard sentence.count >= 2 else { continue }

            // Long sentence — split on commas / colons / semicolons / em-dashes
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

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }

    /// Splits an over-long sentence into clauses on `,`, `:`, `;`, ` — `, ` -- `.
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

            // Clause break on comma / colon / semicolon. Colon is common
            // in OpenClicky's spoken diagnostic replies ("the fix was: ...")
            // and was previously making the first TTS request wait for a
            // much longer sentence tail.
            let isBreakChar = (ch == "," || ch == ":" || ch == ";")
            if isBreakChar && wordCount(buffer) >= minimumWordsBeforePauseCut {
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

    static func testChunksForStreaming(_ text: String) -> [String] {
        var remaining = text
        var chunks: [String] = []
        while let cutEnd = nextSentenceCut(in: remaining) {
            let sentence = String(remaining[..<cutEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            remaining = String(remaining[cutEnd...])
            guard sentence.count >= 2 else { continue }
            if wordCount(sentence) > maxWordsPerTTSChunk {
                chunks.append(contentsOf: splitLongSentenceIntoClauses(sentence))
            } else {
                chunks.append(sentence)
            }
        }
        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            if wordCount(tail) > maxWordsPerTTSChunk {
                chunks.append(contentsOf: splitLongSentenceIntoClauses(tail))
            } else {
                chunks.append(tail)
            }
        }
        return chunks
    }

    /// Returns the index just past a complete sentence (punctuation +
    /// terminating whitespace), or nil if no boundary is present yet.
    fileprivate static func nextSentenceCut(in text: String) -> String.Index? {
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

            if char == "," || char == ":" || char == ";" {
                let nextIndex = text.index(after: index)
                if wordCount >= Self.minimumWordsBeforePauseCut {
                    guard nextIndex < text.endIndex else { return nextIndex }
                    let nextChar = text[nextIndex]
                    if nextChar.isWhitespace || nextChar.isNewline {
                        var endIndex = nextIndex
                        while endIndex < text.endIndex {
                            let c = text[endIndex]
                            guard c.isWhitespace || c.isNewline else { break }
                            endIndex = text.index(after: endIndex)
                        }
                        return endIndex
                    }
                }
            }

            // Do not wait indefinitely if there is no full stop or comma-like
            // pause at all. This is a last-resort safety cut, deliberately
            // later than the natural comma threshold.
            if wordCount >= Self.maxWordsPerTTSChunk,
               (char.isWhitespace || char.isNewline) {
                var endIndex = text.index(after: index)
                while endIndex < text.endIndex {
                    let c = text[endIndex]
                    guard c.isWhitespace || c.isNewline else { break }
                    endIndex = text.index(after: endIndex)
                }
                return endIndex
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

                // Reject common abbreviations: "Mr.", "Dr.", "etc."
                if char == "." {
                    if let prevWord = Self.lastWord(in: text, before: index),
                       Self.knownAbbreviations.contains(prevWord.lowercased()) {
                        index = nextIndex
                        continue
                    }
                }

                guard nextIndex < text.endIndex else {
                    // A streamed LLM often emits terminal punctuation as
                    // the last character of the current delta. Treat that
                    // as a real boundary now so the TTS request can start
                    // before `response.done` and before the full response
                    // is logged. The minimum-word + abbreviation checks
                    // above still protect common false positives.
                    return nextIndex
                }

                let nextChar = text[nextIndex]
                let endsSentence = isNewline || nextChar.isWhitespace || nextChar.isNewline
                if !endsSentence {
                    index = nextIndex
                    continue
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

    private static func lastWord(in text: String, before index: String.Index) -> String? {
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
    /// after a natural 300-500ms thinking beat. Subsequent LLM sentences
    /// enqueue behind this and play in order, buying perceived latency
    /// against model TTFT without sounding like an instant interruption.
    func enqueuePrebakedSamples(_ samples: [Int16]) {
        guard !isCancelled, !samples.isEmpty,
              let playerNode, let format else { return }

        let predecessor = jobChain
        let player = playerNode
        let streamFormat = format
        jobChain = Task { [weak self] in
            if let predecessor { _ = try? await predecessor.value }
            try await Task.sleep(
                nanoseconds: UInt64(Self.preResponseFillerDelayMilliseconds) * 1_000_000
            )
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
                let frames = ElevenLabsTTSClient.scheduleSamples(
                    samples,
                    on: player,
                    format: streamFormat,
                    startPlaybackIfNeeded: false
                )
                if frames > 0 {
                    self.scheduledFrameCount += frames
                }
                self.maybeStartBufferedPlaybackIfReady()
            }
            // Do NOT sleep here. AVAudioPlayerNode plays scheduled
            // buffers in the order they were appended, contiguously.
            // The chain is already serialized on `predecessor.value`.
        }
    }

    private func maybeStartBufferedPlaybackIfReady(force: Bool = false) {
        guard let playerNode,
              !isCancelled,
              scheduledFrameCount > 0,
              playerNode.engine?.isRunning == true,
              !playerNode.isPlaying else {
            return
        }

        let bufferedSeconds = Double(scheduledFrameCount) / sampleRate
        guard force || bufferedSeconds >= Self.minimumBufferedSecondsBeforePlayback else {
            return
        }

        playerNode.play()
        if !didFireStartCallback {
            didFireStartCallback = true
            onPlaybackStarted()
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

    /// Default fillers — short, natural delay-cover phrases. These are
    /// pre-rendered because generating an opener on the critical path
    /// would add exactly the latency the filler is meant to hide.
    static let defaultPhrases: [String] = [
        "one moment.",
        "give me a second.",
        "checking now.",
        "let me check.",
        "working on that."
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
        chooseFiller(preferredPhrases: phrases)
    }

    /// Picks a cached filler that matches the user's turn well enough to
    /// sound intentional, while still falling back to a neutral cached
    /// opener if the exact phrase is not prepared yet.
    func contextualFiller(for transcript: String, screenContextNeeded: Bool) -> FillerSelection? {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let preferred: [String]
        if screenContextNeeded || normalized.contains("look at") || normalized.contains("take a look") {
            preferred = [
                "checking now.",
                "let me check.",
                "give me a second."
            ]
        } else if normalized.contains("do we")
                    || normalized.contains("should we")
                    || normalized.contains("does that")
                    || normalized.contains("is that")
                    || normalized.contains("what i'm interested")
                    || normalized.contains("what i’m interested") {
            preferred = [
                "give me a second.",
                "working on that.",
                "let me check."
            ]
        } else if normalized.contains("check")
                    || normalized.contains("find")
                    || normalized.contains("search")
                    || normalized.contains("research")
                    || normalized.contains("look into") {
            preferred = [
                "checking now.",
                "let me check.",
                "give me a second."
            ]
        } else {
            preferred = [
                "give me a second.",
                "one moment."
            ]
        }

        return chooseFiller(preferredPhrases: preferred)
    }

    private func chooseFiller(preferredPhrases: [String]) -> FillerSelection? {
        let available = phrases.enumerated().compactMap { (index, phrase) -> (Int, String, [Int16])? in
            guard let samples = samplesByPhrase[phrase], !samples.isEmpty else { return nil }
            return (index, phrase, samples)
        }
        guard !available.isEmpty else { return nil }

        let preferredSet = Set(preferredPhrases)
        var candidates = available.filter { preferredSet.contains($0.1) }
        if candidates.isEmpty {
            candidates = available
        }
        if candidates.count > 1, let last = lastChosenIndex {
            let nonRepeats = candidates.filter { $0.0 != last }
            if !nonRepeats.isEmpty {
                candidates = nonRepeats
            }
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
    nonisolated private static let modelID = "sonic-turbo"

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

    var isPlaying: Bool {
        guard let playerNode, playerNode.engine != nil else { return false }
        return playerNode.isPlaying
    }

    func stopPlayback() {
        activeStreamingSession?.cancel()
        activeStreamingSession = nil
        stopPlaybackInternal()
    }

    private func stopPlaybackInternal() {
        streamingTask?.cancel()
        streamingTask = nil
        if let playerNode {
            ElevenLabsTTSClient.stopPlayerIfAttached(playerNode)
        }
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

        let task = Task<Void, Error> { [weak self] in
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

// MARK: - MicrosoftEdgeTTSClient

/// Uses the free Microsoft Edge Read Aloud online voices via the same
/// WebSocket service used by Edge's built-in reader. No Azure key is
/// required; users choose one of the Edge voice identifiers such as
/// `en-US-EmmaMultilingualNeural` or `en-GB-RyanNeural`.
@MainActor
final class MicrosoftEdgeTTSClient: OpenClickyTTSClient {
    nonisolated static let streamSampleRate: Double = 24_000
    private nonisolated static let defaultVoiceID = "en-US-EmmaMultilingualNeural"
    private nonisolated static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private nonisolated static let chromiumFullVersion = "143.0.3650.75"
    private nonisolated static let secMSGECVersion = "1-\(chromiumFullVersion)"
    private nonisolated static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"
    private static let chunkSampleCount = 2_048

    private(set) var voiceID: String
    private let session: URLSession
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamingTask: Task<Void, Error>?
    private weak var activeStreamingSession: StreamingTTSSession?

    init(voiceID: String) {
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.voiceID.isEmpty { self.voiceID = Self.defaultVoiceID }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: configuration)
    }

    func updateConfiguration(apiKey: String?, voiceID: String) {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = trimmed.isEmpty ? Self.defaultVoiceID : trimmed
    }

    func warmUpConnection() {
        guard let url = URL(string: "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list?trustedclienttoken=\(Self.trustedClientToken)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        Self.applyEdgeHeaders(to: &request)
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    var isPlaying: Bool {
        guard let playerNode, playerNode.engine != nil else { return false }
        return playerNode.isPlaying
    }

    func stopPlayback() {
        activeStreamingSession?.cancel()
        activeStreamingSession = nil
        stopPlaybackInternal()
    }

    private func stopPlaybackInternal() {
        streamingTask?.cancel()
        streamingTask = nil
        if let playerNode {
            ElevenLabsTTSClient.stopPlayerIfAttached(playerNode)
        }
        playerNode = nil
        audioEngine?.stop()
        audioEngine = nil
    }

    func speakText(
        _ text: String,
        waitUntilFinished: Bool = true,
        onPlaybackStarted: (() -> Void)? = nil
    ) async throws {
        stopPlaybackInternal()
        let samples = try await fetchSentenceSamples(text)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = Self.makeStreamFormat() else {
            throw Self.makeError(-102, "Could not build Microsoft Edge PCM stream format")
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do { try engine.start() } catch {
            throw Self.makeError(-103, "Audio engine failed to start: \(error.localizedDescription)")
        }
        self.audioEngine = engine
        self.playerNode = player

        let playerRef = player
        let engineRef = engine
        let scheduledFrames = ElevenLabsTTSClient.scheduleSamples(samples, on: playerRef, format: streamFormat)
        if scheduledFrames > 0 { onPlaybackStarted?() }

        let task = Task<Void, Error> { [weak self] in
            await ElevenLabsTTSClient.waitForPlaybackToDrain(
                playerRef,
                scheduledFrameCount: scheduledFrames,
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
            print("⚠️ AVAudioEngine failed to start Microsoft Edge streaming session: \(error)")
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
        let streaming = StreamingTTSSession(
            fetchSamples: { [weak self] text in
                guard let self else { throw CancellationError() }
                return try await self.fetchSentenceSamples(text)
            },
            playerNode: player,
            format: streamFormat,
            sampleRate: Self.streamSampleRate,
            onPlaybackStarted: onPlaybackStarted
        )
        self.activeStreamingSession = streaming
        return streaming
    }

    func fetchSentenceSamples(_ text: String) async throws -> [Int16] {
        let selectedVoice = voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultVoiceID : voiceID
        let mp3Data = try await Self.fetchMP3Data(
            text: text,
            voiceID: selectedVoice,
            session: session
        )
        return try Self.decodeMP3DataToSamples(mp3Data)
    }

    private static func makeStreamFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: streamSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    nonisolated private static func fetchMP3Data(
        text: String,
        voiceID: String,
        session: URLSession
    ) async throws -> Data {
        guard let url = websocketURL() else {
            throw makeError(-10, "Could not build Microsoft Edge TTS WebSocket URL")
        }
        var request = URLRequest(url: url)
        applyEdgeHeaders(to: &request)
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("muid=\(UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased());", forHTTPHeaderField: "Cookie")

        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
        }

        try await socket.send(.string(speechConfigMessage()))
        try await socket.send(.string(ssmlMessage(text: text, voiceID: voiceID)))

        var audioData = Data()
        while true {
            try Task.checkCancellation()
            let message = try await socket.receive()
            switch message {
            case .data(let data):
                let parsed = parseBinaryMessage(data)
                if parsed.path == "audio", !parsed.payload.isEmpty {
                    audioData.append(parsed.payload)
                }
            case .string(let string):
                let parsed = parseTextMessage(string)
                if parsed.path == "turn.end" {
                    if audioData.isEmpty {
                        throw makeError(-11, "Microsoft Edge TTS returned no audio")
                    }
                    return audioData
                }
            @unknown default:
                continue
            }
        }
    }

    nonisolated private static func websocketURL() -> URL? {
        let connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let secMSGEC = generateSecMSGEC()
        return URL(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(trustedClientToken)&ConnectionId=\(connectionID)&Sec-MS-GEC=\(secMSGEC)&Sec-MS-GEC-Version=\(secMSGECVersion)")
    }

    nonisolated private static func speechConfigMessage() -> String {
        """
        X-Timestamp:\(edgeTimestamp())\r
        Content-Type:application/json; charset=utf-8\r
        Path:speech.config\r
        \r
        {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"\(outputFormat)"}}}}\r
        """
    }

    nonisolated private static func ssmlMessage(text: String, voiceID: String) -> String {
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let escaped = xmlEscaped(cleanedText(text))
        let ssml = """
        <speak version='1.0' xml:lang='en-US'><voice name='\(voiceID)'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(escaped)</prosody></voice></speak>
        """
        return """
        X-RequestId:\(requestID)\r
        Content-Type:application/ssml+xml\r
        X-Timestamp:\(edgeTimestamp())Z\r
        Path:ssml\r
        \r
        \(ssml)
        """
    }

    nonisolated private static func parseTextMessage(_ string: String) -> (path: String?, payload: Data) {
        guard let separator = string.range(of: "\r\n\r\n") else {
            return (nil, Data(string.utf8))
        }
        let headerText = String(string[..<separator.lowerBound])
        let payloadText = String(string[separator.upperBound...])
        return (pathFromHeaders(headerText), Data(payloadText.utf8))
    }

    nonisolated private static func parseBinaryMessage(_ data: Data) -> (path: String?, payload: Data) {
        guard data.count >= 2 else { return (nil, Data()) }
        let headerLength = (Int(data[data.startIndex]) << 8) | Int(data[data.index(after: data.startIndex)])
        let headerStart = data.index(data.startIndex, offsetBy: 2)
        guard headerLength > 0,
              let headerEnd = data.index(headerStart, offsetBy: headerLength, limitedBy: data.endIndex) else {
            return (nil, Data())
        }
        let headerData = data[headerStart..<headerEnd]
        let payload = data.suffix(from: headerEnd)
        let headerText = String(data: headerData, encoding: .utf8) ?? ""
        return (pathFromHeaders(headerText), payload)
    }

    nonisolated static func testParseMicrosoftEdgeBinaryMessage(_ data: Data) -> (path: String?, payload: Data) {
        parseBinaryMessage(data)
    }

    nonisolated private static func pathFromHeaders(_ headerText: String) -> String? {
        for line in headerText.components(separatedBy: "\r\n") {
            if let range = line.range(of: "Path:", options: [.caseInsensitive]) {
                return line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            if pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "path" {
                return pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    nonisolated private static func decodeMP3DataToSamples(_ data: Data) throws -> [Int16] {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-edge-tts-\(UUID().uuidString)")
            .appendingPathExtension("mp3")
        try data.write(to: tempURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let file = try AVAudioFile(forReading: tempURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw makeError(-12, "Could not allocate Microsoft Edge audio buffer")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw makeError(-13, "Could not decode Microsoft Edge MP3 audio")
        }
        let channelCount = max(1, Int(format.channelCount))
        let frames = Int(buffer.frameLength)
        var samples: [Int16] = []
        samples.reserveCapacity(frames)
        for frame in 0..<frames {
            var mixed: Float = 0
            for channel in 0..<channelCount {
                mixed += channels[channel][frame]
            }
            let clamped = max(-1, min(1, mixed / Float(channelCount)))
            samples.append(Int16(clamped * Float(Int16.max)))
        }
        return samples
    }

    nonisolated private static func cleanedText(_ text: String) -> String {
        String(text.map { character in
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
                return character
            }
            switch scalar.value {
            case 0...8, 11...12, 14...31:
                return " "
            default:
                return character
            }
        })
    }

    nonisolated private static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    nonisolated private static func edgeTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    nonisolated private static func generateSecMSGEC() -> String {
        let windowsEpochOffset: Double = 11_644_473_600
        let unixSeconds = Date().timeIntervalSince1970 + windowsEpochOffset
        let roundedSeconds = unixSeconds - unixSeconds.truncatingRemainder(dividingBy: 300)
        let ticks = roundedSeconds * 10_000_000
        let source = "\(String(format: "%.0f", ticks))\(trustedClientToken)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    nonisolated private static func applyEdgeHeaders(to request: inout URLRequest) {
        let major = chromiumFullVersion.split(separator: ".", maxSplits: 1).first ?? "143"
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36 Edg/\(major).0.0.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    }

    nonisolated private static func makeError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "MicrosoftEdgeTTS", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - OpenAIRealtimeSpeechClient

/// Speaks text through OpenAI's Realtime model over WebSocket. This is
/// deliberately treated as a playback engine, not as a TTS provider:
/// when selected, OpenClicky should not also route the same response
/// through ElevenLabs, Cartesia, or Deepgram.
@MainActor
final class OpenAIRealtimeSpeechClient: OpenClickyTTSClient {
    nonisolated static let streamSampleRate: Double = 24_000
    private nonisolated static let defaultVoiceID = "cedar"
    private nonisolated static let minimumInputAudioBytes = Int(streamSampleRate * 2 * 0.18)
    private nonisolated static let minimumInputPeakPower = 0.003

    struct BidirectionalVoiceTurnResult {
        let userTranscript: String
        let assistantTranscript: String
        let didCreateAssistantResponse: Bool
        let wasRoutedByClient: Bool
    }

    private var apiKey: String?
    private(set) var voiceID: String
    var model: String
    private let session: URLSession

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamingTask: Task<Void, Error>?
    private var activeBidirectionalVoiceTurn: BidirectionalVoiceTurn?
    private static let realtimeRoutingTools: [[String: Any]] = [
        [
            "type": "function",
            "name": "openclicky_use_computer",
            "description": "Route a direct Mac control request through OpenClicky's selected computer-use backend. Use this for opening apps, app-plus-action requests such as opening an app and doing something inside it, focused-window typing, key presses, clicking, or other direct computer actions. Do not use this for temporary visual guidance such as pointing, highlighting, rectangles, circling, scribbling, tracing, marking, or drawing around visible screen content; OpenClicky's screen-aware voice-response path handles those directly. Do not use the background-agent tool for ordinary app control just because it has more than one step.",
            "parameters": [
                "type": "object",
                "properties": [
                    "transcript": [
                        "type": "string",
                        "description": "The user's exact spoken request to execute through OpenClicky's computer-use path."
                    ]
                ],
                "required": ["transcript"],
                "additionalProperties": false
            ]
        ],
        [
            "type": "function",
            "name": "openclicky_use_screen_context",
            "description": "Route a screen-aware voice request back to OpenClicky's app so it can take a fresh screenshot and inspect the visible screen before answering. Use this for anything about what is on screen, the current window, visible UI, screenshots, pointing, highlighting, drawing rectangles/circles/scribbles, screen calibration, layout, icons, buttons, fields, menus, pages, or visible objects. Do not answer these requests from Realtime audio alone; this tool lets the voice lane see the screen.",
            "parameters": [
                "type": "object",
                "properties": [
                    "transcript": [
                        "type": "string",
                        "description": "The user's exact spoken request that needs OpenClicky's screenshot-aware voice path."
                    ]
                ],
                "required": ["transcript"],
                "additionalProperties": false
            ]
        ],
        [
            "type": "function",
            "name": "openclicky_start_background_agent",
            "description": "Route deeper work to OpenClicky's background Agent Mode full model. Use this for code, files, research, settings, logs, memory, builds, installs, refactors, or long-running work. Do not use this for ordinary app control; use openclicky_use_computer instead.",
            "parameters": [
                "type": "object",
                "properties": [
                    "transcript": [
                        "type": "string",
                        "description": "The user's exact spoken request to hand to the background agent."
                    ]
                ],
                "required": ["transcript"],
                "additionalProperties": false
            ]
        ]
    ]

    init(apiKey: String?, model: String, voiceID: String = "cedar") {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultVoiceID
            : voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = URLSession(configuration: .default)
    }

    var isPlaying: Bool {
        guard let playerNode, playerNode.engine != nil else { return false }
        return playerNode.isPlaying
    }

    func updateConfiguration(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVoice = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVoice.isEmpty {
            self.voiceID = trimmedVoice
        }
    }

    func warmUpConnection() {
        guard let url = URL(string: "https://api.openai.com/v1/realtime") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    func speakText(
        _ text: String,
        waitUntilFinished: Bool = true,
        onPlaybackStarted: (() -> Void)? = nil
    ) async throws {
        stopPlaybackInternal()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = Self.makeStreamFormat() else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        try engine.start()
        audioEngine = engine
        playerNode = player

        let task = Task { [weak self, weak player] in
            guard let self, let player else { throw CancellationError() }
            let samples = try await self.fetchSentenceSamples(trimmed)
            try Task.checkCancellation()
            let scheduledFrameCount = await MainActor.run {
                ElevenLabsTTSClient.scheduleSamples(samples, on: player, format: streamFormat)
            }
            await MainActor.run { onPlaybackStarted?() }
            await ElevenLabsTTSClient.waitForPlaybackToDrain(
                player,
                scheduledFrameCount: scheduledFrameCount,
                sampleRate: Self.streamSampleRate
            )
        }
        streamingTask = task

        if waitUntilFinished {
            do { try await task.value }
            catch {
                stopPlaybackInternal()
                throw error
            }
            stopPlaybackInternal()
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
                onPlaybackStarted: onPlaybackStarted
            )
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do { try engine.start() } catch {
            print("⚠️ AVAudioEngine failed to start OpenAI Realtime speech session: \(error)")
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
        audioEngine = engine
        playerNode = player
        return StreamingTTSSession(
            fetchSamples: { [weak self] text in
                guard let self else { throw CancellationError() }
                return try await self.fetchSentenceSamples(text)
            },
            playerNode: player,
            format: streamFormat,
            sampleRate: Self.streamSampleRate,
            onPlaybackStarted: onPlaybackStarted
        )
    }

    func beginBidirectionalVoiceTurn(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        onUserTranscript: @escaping @MainActor @Sendable (String) -> Void,
        onAssistantTextChunk: @escaping @MainActor @Sendable (String) -> Void,
        onPlaybackStarted: @escaping @MainActor @Sendable () -> Void,
        onInputPowerLevel: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        stopPlaybackInternal()
        activeBidirectionalVoiceTurn?.cancel()
        activeBidirectionalVoiceTurn = nil

        guard let apiKey, !apiKey.isEmpty else {
            throw NSError(
                domain: "OpenAIRealtimeSpeechClient",
                code: -1000,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime voice needs a Codex/OpenAI API key in Settings or OPENAI_API_KEY in the launch environment."]
            )
        }
        try await ensureMicrophonePermission()
        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            throw NSError(domain: "OpenAIRealtimeSpeechClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime WebSocket URL is invalid."])
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw NSError(domain: "OpenAIRealtimeSpeechClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime WebSocket URL could not be created."])
        }
        guard let streamFormat = Self.makeStreamFormat() else {
            throw NSError(domain: "OpenAIRealtimeSpeechClient", code: -3, userInfo: [NSLocalizedDescriptionKey: "Could not build OpenAI Realtime PCM stream format."])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let inputCapture = RealtimeInputCapture(
            targetSampleRate: Self.streamSampleRate,
            onInputPowerLevel: onInputPowerLevel
        )
        try inputCapture.start()

        let webSocket = session.webSocketTask(with: request)
        webSocket.resume()
        do {
            try await waitForRealtimeConnection(on: webSocket)

            let historyText = conversationHistory.suffix(8).map { entry in
                "User: \(entry.userPlaceholder)\nOpenClicky: \(entry.assistantResponse)"
            }.joined(separator: "\n\n")
            let instructions = [
                systemPrompt,
                historyText.isEmpty ? nil : "Recent conversation:\n\(historyText)",
                "You are in OpenClicky's bidirectional Realtime voice mode. Listen to the user's live microphone audio directly and reply out loud as OpenClicky in one concise spoken answer. Do not claim you will start background work, take care of a task, or start an agent unless the app already routed the turn before you receive it. You cannot see the user's screen inside this live Realtime turn; for any request about what is on screen, the current window, visible UI, screenshots, pointing, highlighting, drawing, or screen calibration, call openclicky_use_screen_context with the exact transcript instead of answering from audio alone. Do not mention transcription, Whisper, markdown, or [POINT:] tags."
            ].compactMap { $0 }.joined(separator: "\n\n")

            try await sendJSON([
                "type": "session.update",
                "session": [
                    "type": "realtime",
                    "model": model,
                    "instructions": instructions,
                    "output_modalities": ["audio"],
                    "tools": Self.realtimeRoutingTools,
                    "tool_choice": "auto",
                    "audio": [
                        "input": [
                            "format": [
                                "type": "audio/pcm",
                                "rate": Int(Self.streamSampleRate)
                            ],
                            "transcription": [
                                "model": "gpt-4o-mini-transcribe"
                            ],
                            "turn_detection": NSNull()
                        ],
                        "output": [
                            "voice": voiceID,
                            "format": [
                                "type": "audio/pcm",
                                "rate": Int(Self.streamSampleRate)
                            ]
                        ]
                    ]
                ]
            ], to: webSocket)

            let turn = try BidirectionalVoiceTurn(
                client: self,
                webSocket: webSocket,
                inputCapture: inputCapture,
                streamFormat: streamFormat,
                onUserTranscript: onUserTranscript,
                onAssistantTextChunk: onAssistantTextChunk,
                onPlaybackStarted: onPlaybackStarted
            )
            activeBidirectionalVoiceTurn = turn
            audioEngine = turn.outputEngine
            playerNode = turn.playerNode
            turn.startInputCapture()
            turn.startReceiving()
        } catch {
            inputCapture.stop()
            webSocket.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    func finishBidirectionalVoiceTurn(
        routeUserTranscriptBeforeAssistantResponse: (@MainActor @Sendable (String) -> Bool)? = nil,
        routeRealtimeToolCallBeforeAssistantResponse: (@MainActor @Sendable (String, String) -> Bool)? = nil
    ) async throws -> BidirectionalVoiceTurnResult {
        guard let activeBidirectionalVoiceTurn else {
            throw CancellationError()
        }
        self.activeBidirectionalVoiceTurn = nil
        do {
            let result = try await activeBidirectionalVoiceTurn.finish(
                routeUserTranscriptBeforeAssistantResponse: routeUserTranscriptBeforeAssistantResponse,
                routeRealtimeToolCallBeforeAssistantResponse: routeRealtimeToolCallBeforeAssistantResponse
            )
            stopPlayback(for: activeBidirectionalVoiceTurn)
            return result
        } catch {
            activeBidirectionalVoiceTurn.cancel()
            stopPlayback(for: activeBidirectionalVoiceTurn)
            throw error
        }
    }

    func cancelBidirectionalVoiceTurn() {
        if let activeBidirectionalVoiceTurn {
            activeBidirectionalVoiceTurn.cancel()
            stopPlayback(for: activeBidirectionalVoiceTurn)
        }
        activeBidirectionalVoiceTurn = nil
    }

    /// Stops only the given turn's output engine. The shared
    /// `audioEngine`/`playerNode` slot may already hold the streaming TTS
    /// engine of a response the app routed out of this turn — that engine
    /// must keep playing, so the slot is released only if it still points
    /// at the turn's own engine.
    private func stopPlayback(for turn: BidirectionalVoiceTurn) {
        ElevenLabsTTSClient.stopPlayerIfAttached(turn.playerNode)
        turn.outputEngine.stop()
        if playerNode === turn.playerNode {
            playerNode = nil
        }
        if audioEngine === turn.outputEngine {
            audioEngine = nil
        }
    }

    private func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                throw Self.microphoneInputError("Microphone permission was not granted. OpenClicky could not listen to that voice turn.")
            }
        case .denied, .restricted:
            throw Self.microphoneInputError("Microphone permission is blocked in macOS Privacy settings. OpenClicky could not listen to that voice turn.")
        @unknown default:
            throw Self.microphoneInputError("Microphone permission is unavailable. OpenClicky could not listen to that voice turn.")
        }
    }


    func speakResponse(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void,
        onPlaybackStarted: @escaping @MainActor () -> Void
    ) async throws -> String {
        stopPlaybackInternal()
        guard let apiKey, !apiKey.isEmpty else {
            throw NSError(
                domain: "OpenAIRealtimeSpeechClient",
                code: -1000,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime response needs a Codex/OpenAI API key in Settings or OPENAI_API_KEY in the launch environment."]
            )
        }
        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            throw NSError(domain: "OpenAIRealtimeSpeechClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime WebSocket URL is invalid."])
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw NSError(domain: "OpenAIRealtimeSpeechClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime WebSocket URL could not be created."])
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = Self.makeStreamFormat() else {
            throw NSError(domain: "OpenAIRealtimeSpeechClient", code: -3, userInfo: [NSLocalizedDescriptionKey: "Could not build OpenAI Realtime PCM stream format."])
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        try engine.start()
        audioEngine = engine
        playerNode = player

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let webSocket = session.webSocketTask(with: request)
        webSocket.resume()
        defer {
            webSocket.cancel(with: .normalClosure, reason: nil)
            Task { @MainActor in self.stopPlaybackInternal() }
        }

        try await waitForRealtimeConnection(on: webSocket)
        try await sendJSON([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "output_modalities": ["audio"],
                "audio": [
                    "output": [
                        "voice": voiceID,
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(Self.streamSampleRate)
                        ]
                    ]
                ]
            ]
        ], to: webSocket)

        let historyText = conversationHistory.suffix(8).map { entry in
            "User: \(entry.userPlaceholder)\nOpenClicky: \(entry.assistantResponse)"
        }.joined(separator: "\n\n")
        let instructions = [
            systemPrompt,
            historyText.isEmpty ? nil : "Recent conversation:\n\(historyText)",
            "Current user request:\n\(userPrompt)",
            "Reply out loud as OpenClicky in one concise spoken answer. Do not include markdown. Do not include [POINT:] tags."
        ].compactMap { $0 }.joined(separator: "\n\n")

        try await sendJSON([
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                "instructions": instructions
            ]
        ], to: webSocket)

        var transcript = ""
        var scheduledFrameCount: AVAudioFramePosition = 0
        var didStartPlayback = false
        let playbackStartThresholdFrames = AVAudioFramePosition(Self.streamSampleRate * 0.12)

        while true {
            try Task.checkCancellation()
            let event = try await receiveRealtimeEvent(from: webSocket)
            let type = event["type"] as? String ?? ""
            if (type == "response.output_audio.delta" || type == "response.audio.delta"),
               let delta = event["delta"] as? String,
               let chunk = Data(base64Encoded: delta) {
                let samples = Self.int16Samples(fromLittleEndianPCM: chunk)
                let frames = await MainActor.run {
                    ElevenLabsTTSClient.scheduleSamples(
                        samples,
                        on: player,
                        format: streamFormat,
                        startPlaybackIfNeeded: false
                    )
                }
                scheduledFrameCount += frames
                if frames > 0,
                   !didStartPlayback,
                   scheduledFrameCount >= playbackStartThresholdFrames,
                   player.engine?.isRunning == true {
                    didStartPlayback = true
                    await MainActor.run { player.play() }
                    await MainActor.run { onPlaybackStarted() }
                }
            } else if (type == "response.output_audio_transcript.delta" || type == "response.audio_transcript.delta"),
                      let delta = event["delta"] as? String {
                transcript += delta
                let snapshot = transcript
                await MainActor.run { onTextChunk(snapshot) }
            } else if type == "response.output_audio_transcript.done" || type == "response.audio_transcript.done" {
                if let doneTranscript = event["transcript"] as? String, !doneTranscript.isEmpty {
                    transcript = doneTranscript
                    let snapshot = transcript
                    await MainActor.run { onTextChunk(snapshot) }
                }
            } else if type == "response.done" {
                if transcript.isEmpty, let extracted = Self.firstTranscriptString(in: event), !extracted.isEmpty {
                    transcript = extracted
                    let snapshot = transcript
                    await MainActor.run { onTextChunk(snapshot) }
                }
                break
            } else if type == "error" {
                throw realtimeError(from: event)
            }
        }

        if scheduledFrameCount > 0 {
            if !didStartPlayback, player.engine?.isRunning == true {
                didStartPlayback = true
                await MainActor.run { player.play() }
                await MainActor.run { onPlaybackStarted() }
            }
            await ElevenLabsTTSClient.waitForPlaybackToDrain(
                player,
                scheduledFrameCount: scheduledFrameCount,
                sampleRate: Self.streamSampleRate
            )
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func analyzeImageResponse(
        images: [(data: Data, label: String)],
        modelID: String? = nil,
        systemPrompt: String,
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else {
            throw NSError(
                domain: "OpenAIRealtimeSpeechClient",
                code: -1000,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime image analysis needs a Codex/OpenAI API key in Settings or OPENAI_API_KEY in the launch environment."]
            )
        }
        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            throw NSError(domain: "OpenAIRealtimeSpeechClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime WebSocket URL is invalid."])
        }
        let requestModel = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? modelID! : model
        components.queryItems = [URLQueryItem(name: "model", value: requestModel)]
        guard let url = components.url else {
            throw NSError(domain: "OpenAIRealtimeSpeechClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime WebSocket URL could not be created."])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let webSocket = session.webSocketTask(with: request)
        webSocket.resume()
        defer {
            webSocket.cancel(with: .normalClosure, reason: nil)
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "outgoing",
            event: "openai_realtime.image_analysis.request",
            fields: [
                "model": requestModel,
                "imageCount": images.count,
                "transport": "realtime_websocket",
                "streamingMethod": "conversation.item.create + response.output_text.delta"
            ]
        )

        try await waitForRealtimeConnection(on: webSocket)
        try await sendJSON([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": requestModel,
                "output_modalities": ["text"]
            ]
        ], to: webSocket)

        var content: [[String: Any]] = []
        for image in images {
            content.append([
                "type": "input_text",
                "text": image.label
            ])
            content.append([
                "type": "input_image",
                "image_url": Self.imageDataURI(for: image.data)
            ])
        }
        content.append([
            "type": "input_text",
            "text": userPrompt
        ])

        try await sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": content
            ]
        ], to: webSocket)

        try await sendJSON([
            "type": "response.create",
            "response": [
                "output_modalities": ["text"],
                "max_output_tokens": 512,
                "instructions": systemPrompt
            ]
        ], to: webSocket)

        var accumulatedText = ""
        while true {
            try Task.checkCancellation()
            let event = try await receiveRealtimeEvent(from: webSocket)
            let type = event["type"] as? String ?? ""
            if type == "response.output_text.delta",
               let delta = event["delta"] as? String {
                accumulatedText += delta
                let snapshot = accumulatedText
                await MainActor.run { onTextChunk(snapshot) }
            } else if type == "response.output_text.done",
                      let text = event["text"] as? String,
                      !text.isEmpty {
                accumulatedText = text
                let snapshot = accumulatedText
                await MainActor.run { onTextChunk(snapshot) }
            } else if type == "response.content_part.done",
                      accumulatedText.isEmpty,
                      let extracted = Self.firstTranscriptString(in: event),
                      !extracted.isEmpty {
                accumulatedText = extracted
                await MainActor.run { onTextChunk(extracted) }
            } else if type == "response.done" {
                if accumulatedText.isEmpty,
                   let extracted = Self.firstTranscriptString(in: event),
                   !extracted.isEmpty {
                    accumulatedText = extracted
                    await MainActor.run { onTextChunk(extracted) }
                }
                break
            } else if type == "error" {
                throw realtimeError(from: event)
            }
        }

        let trimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "OpenAIRealtimeSpeechClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime image analysis returned an empty response."]
            )
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "incoming",
            event: "openai_realtime.image_analysis.response",
            fields: [
                "model": requestModel,
                "responseLength": trimmed.count,
                "transport": "realtime_websocket"
            ]
        )
        return trimmed
    }

    func fetchSentenceSamples(_ text: String) async throws -> [Int16] {
        guard let apiKey, !apiKey.isEmpty else {
            throw NSError(
                domain: "OpenAIRealtimeSpeechClient",
                code: -1000,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime playback needs a Codex/OpenAI API key in Settings or OPENAI_API_KEY in the launch environment."]
            )
        }

        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            throw NSError(domain: "OpenAIRealtimeSpeechClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime WebSocket URL is invalid."])
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw NSError(domain: "OpenAIRealtimeSpeechClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI Realtime WebSocket URL could not be created."])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // GPT Realtime 2 is GA-only. The old beta header makes the server reject
        // gpt-realtime-2 with "only available on the GA API", so keep this
        // connection on the GA Realtime WebSocket interface.

        let webSocket = session.webSocketTask(with: request)
        webSocket.resume()
        defer { webSocket.cancel(with: .normalClosure, reason: nil) }

        try await waitForRealtimeConnection(on: webSocket)

        try await sendJSON([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "output_modalities": ["audio"],
                "audio": [
                    "output": [
                        "voice": voiceID,
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(Self.streamSampleRate)
                        ]
                    ]
                ]
            ]
        ], to: webSocket)

        try await sendJSON([
            "type": "response.create",
            "response": [
                "conversation": "none",
                "output_modalities": ["audio"],
                "instructions": "Speak exactly this text in a natural OpenClicky voice. Do not add, remove, summarize, or preface anything: \(text)"
            ]
        ], to: webSocket)

        var bytes = Data()
        while true {
            try Task.checkCancellation()
            let event = try await receiveRealtimeEvent(from: webSocket)
            let type = event["type"] as? String ?? ""
            if (type == "response.output_audio.delta" || type == "response.audio.delta"),
               let delta = event["delta"] as? String,
               let chunk = Data(base64Encoded: delta) {
                bytes.append(chunk)
            } else if type == "response.done" || type == "response.output_audio.done" || type == "response.audio.done" {
                break
            } else if type == "error" {
                throw realtimeError(from: event)
            }
        }

        return Self.int16Samples(fromLittleEndianPCM: bytes)
    }

    private final class RealtimeInputCapture {
        private let inputEngine = AVAudioEngine()
        private let inputConverter: BuddyPCM16AudioConverter
        private let lock = NSLock()
        private let maxBufferedBytes: Int
        private let onInputPowerLevel: @MainActor @Sendable (Double) -> Void
        private var bufferedChunks: [Data] = []
        private var bufferedByteCount = 0
        private var sender: ((Data) -> Void)?
        private var hasInstalledInputTap = false
        private var capturedByteCount = 0
        private var peakPowerLevel = 0.0

        init(
            targetSampleRate: Double,
            onInputPowerLevel: @escaping @MainActor @Sendable (Double) -> Void
        ) {
            self.inputConverter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)
            self.maxBufferedBytes = Int(targetSampleRate * 2 * 3)
            self.onInputPowerLevel = onInputPowerLevel
        }

        func start() throws {
            let inputNode = inputEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 256, format: inputFormat) { [weak self] buffer, _ in
                guard let self,
                      let pcmData = self.inputConverter.convertToPCM16Data(from: buffer),
                      !pcmData.isEmpty else { return }
                let powerLevel = Self.audioPowerLevel(from: buffer)
                Task { @MainActor [onInputPowerLevel] in
                    onInputPowerLevel(powerLevel)
                }
                self.handle(pcmData, powerLevel: powerLevel)
            }
            hasInstalledInputTap = true
            inputEngine.prepare()
            try inputEngine.start()
        }

        func setSender(_ sender: @escaping (Data) -> Void) {
            let chunksToFlush: [Data]
            lock.lock()
            self.sender = sender
            chunksToFlush = bufferedChunks
            bufferedChunks.removeAll(keepingCapacity: false)
            bufferedByteCount = 0
            lock.unlock()

            for chunk in chunksToFlush {
                sender(chunk)
            }
        }

        func stop() {
            lock.lock()
            sender = nil
            bufferedChunks.removeAll(keepingCapacity: false)
            bufferedByteCount = 0
            lock.unlock()

            if hasInstalledInputTap {
                inputEngine.inputNode.removeTap(onBus: 0)
                hasInstalledInputTap = false
            }
            if inputEngine.isRunning {
                inputEngine.stop()
            }
        }

        func captureStats() -> (byteCount: Int, peakPower: Double) {
            lock.lock()
            let stats = (capturedByteCount, peakPowerLevel)
            lock.unlock()
            return stats
        }

        private static func audioPowerLevel(from audioBuffer: AVAudioPCMBuffer) -> Double {
            guard let channelData = audioBuffer.floatChannelData else { return 0 }
            let channelCount = Int(audioBuffer.format.channelCount)
            let frameLength = Int(audioBuffer.frameLength)
            guard channelCount > 0, frameLength > 0 else { return 0 }

            var sum: Float = 0
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in 0..<frameLength {
                    let sample = samples[frame]
                    sum += sample * sample
                }
            }

            let meanSquare = sum / Float(channelCount * frameLength)
            let rootMeanSquare = sqrt(meanSquare)
            return min(1, max(0, Double(rootMeanSquare) * 12))
        }

        private func handle(_ pcmData: Data, powerLevel: Double) {
            let activeSender: ((Data) -> Void)?
            lock.lock()
            activeSender = sender
            capturedByteCount += pcmData.count
            peakPowerLevel = max(peakPowerLevel, powerLevel)
            if activeSender == nil {
                bufferedChunks.append(pcmData)
                bufferedByteCount += pcmData.count
                while bufferedByteCount > maxBufferedBytes, !bufferedChunks.isEmpty {
                    bufferedByteCount -= bufferedChunks.removeFirst().count
                }
            }
            lock.unlock()
            activeSender?(pcmData)
        }
    }

    private final class BidirectionalVoiceTurn {
        private weak var client: OpenAIRealtimeSpeechClient?
        private let webSocket: URLSessionWebSocketTask
        let outputEngine: AVAudioEngine
        let playerNode: AVAudioPlayerNode
        private let inputCapture: RealtimeInputCapture
        private let streamFormat: AVAudioFormat
        private let onUserTranscript: @MainActor @Sendable (String) -> Void
        private let onAssistantTextChunk: @MainActor @Sendable (String) -> Void
        private let onPlaybackStarted: @MainActor @Sendable () -> Void
        private var receiveTask: Task<BidirectionalVoiceTurnResult, Error>?
        private var routeUserTranscriptBeforeAssistantResponse: (@MainActor @Sendable (String) -> Bool)?
        private var routeRealtimeToolCallBeforeAssistantResponse: (@MainActor @Sendable (String, String) -> Bool)?
        private var didStartPlayback = false
        private var didCommitInput = false
        private var didRequestAssistantResponse = false
        private var didRouteByClient = false

        init(
            client: OpenAIRealtimeSpeechClient,
            webSocket: URLSessionWebSocketTask,
            inputCapture: RealtimeInputCapture,
            streamFormat: AVAudioFormat,
            onUserTranscript: @escaping @MainActor @Sendable (String) -> Void,
            onAssistantTextChunk: @escaping @MainActor @Sendable (String) -> Void,
            onPlaybackStarted: @escaping @MainActor @Sendable () -> Void
        ) throws {
            self.client = client
            self.webSocket = webSocket
            self.inputCapture = inputCapture
            self.streamFormat = streamFormat
            self.onUserTranscript = onUserTranscript
            self.onAssistantTextChunk = onAssistantTextChunk
            self.onPlaybackStarted = onPlaybackStarted

            let outputEngine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            outputEngine.attach(playerNode)
            outputEngine.connect(playerNode, to: outputEngine.mainMixerNode, format: streamFormat)
            try outputEngine.start()
            self.outputEngine = outputEngine
            self.playerNode = playerNode
        }

        func startInputCapture() {
            inputCapture.setSender { [weak self] pcmData in
                let base64Audio = pcmData.base64EncodedString()
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.sendJSON([
                        "type": "input_audio_buffer.append",
                        "audio": base64Audio
                    ])
                }
            }
        }

        func startReceiving() {
            receiveTask = Task { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.receiveUntilDone()
            }
        }

        func finish(
            routeUserTranscriptBeforeAssistantResponse: (@MainActor @Sendable (String) -> Bool)? = nil,
            routeRealtimeToolCallBeforeAssistantResponse: (@MainActor @Sendable (String, String) -> Bool)? = nil
        ) async throws -> BidirectionalVoiceTurnResult {
            stopInputCapture()
            let inputStats = inputCapture.captureStats()
            guard inputStats.byteCount >= OpenAIRealtimeSpeechClient.minimumInputAudioBytes,
                  inputStats.peakPower >= OpenAIRealtimeSpeechClient.minimumInputPeakPower else {
                throw OpenAIRealtimeSpeechClient.microphoneInputError(
                    "OpenClicky could not detect usable microphone audio. Check the microphone input or macOS microphone permission and try again."
                )
            }
            self.routeUserTranscriptBeforeAssistantResponse = routeUserTranscriptBeforeAssistantResponse
            self.routeRealtimeToolCallBeforeAssistantResponse = routeRealtimeToolCallBeforeAssistantResponse
            didCommitInput = true
            try await sendJSON(["type": "input_audio_buffer.commit"])

            // Let the Realtime transcription event reach OpenClicky's app
            // router before asking the model to speak. Pointing, direct
            // computer-use, and agent-start requests must become real app
            // actions, not spoken "[POINT:...]" / "Done" audio.
            let responseFallbackTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                try? await self?.requestAssistantResponseIfNeeded()
            }

            do {
                guard let receiveTask else { throw CancellationError() }
                let result = try await receiveTask.value
                responseFallbackTask.cancel()
                webSocket.cancel(with: .normalClosure, reason: nil)
                return result
            } catch {
                responseFallbackTask.cancel()
                throw error
            }
        }

        private func requestAssistantResponseIfNeeded() async throws {
            guard didCommitInput,
                  !didRequestAssistantResponse,
                  !didRouteByClient else {
                return
            }
            didRequestAssistantResponse = true
            try await sendJSON([
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"]
                ]
            ])
        }

        func cancel() {
            stopInputCapture()
            receiveTask?.cancel()
            receiveTask = nil
            ElevenLabsTTSClient.stopPlayerIfAttached(playerNode)
            outputEngine.stop()
            webSocket.cancel(with: .goingAway, reason: nil)
        }

        private func stopInputCapture() {
            inputCapture.stop()
        }

        private func receiveUntilDone() async throws -> BidirectionalVoiceTurnResult {
            var userTranscript = ""
            var assistantTranscript = ""
            var scheduledFrameCount: AVAudioFramePosition = 0
            let playbackStartThresholdFrames = AVAudioFramePosition(OpenAIRealtimeSpeechClient.streamSampleRate * 0.12)

            while true {
                try Task.checkCancellation()
                guard let event = try await client?.receiveRealtimeEvent(from: webSocket) else {
                    throw CancellationError()
                }
                let type = event["type"] as? String ?? ""
                if (type == "response.output_audio.delta" || type == "response.audio.delta"),
                   let delta = event["delta"] as? String,
                   let chunk = Data(base64Encoded: delta) {
                    let samples = OpenAIRealtimeSpeechClient.int16Samples(fromLittleEndianPCM: chunk)
                    let frames = await MainActor.run {
                        ElevenLabsTTSClient.scheduleSamples(
                            samples,
                            on: playerNode,
                            format: streamFormat,
                            startPlaybackIfNeeded: false
                        )
                    }
                    scheduledFrameCount += frames
                    if frames > 0,
                       !didStartPlayback,
                       scheduledFrameCount >= playbackStartThresholdFrames,
                       playerNode.engine?.isRunning == true {
                        didStartPlayback = true
                        await MainActor.run { playerNode.play() }
                        await MainActor.run { onPlaybackStarted() }
                    }
                } else if (type == "response.output_audio_transcript.delta" || type == "response.audio_transcript.delta"),
                          let delta = event["delta"] as? String {
                    assistantTranscript += delta
                    let snapshot = assistantTranscript
                    await MainActor.run { onAssistantTextChunk(snapshot) }
                } else if type == "response.output_audio_transcript.done" || type == "response.audio_transcript.done" {
                    if let doneTranscript = event["transcript"] as? String, !doneTranscript.isEmpty {
                        assistantTranscript = doneTranscript
                        let snapshot = assistantTranscript
                        await MainActor.run { onAssistantTextChunk(snapshot) }
                    }
                } else if type == "response.function_call_arguments.done",
                          let name = event["name"] as? String {
                    let arguments = event["arguments"] as? String
                    let routedTranscript = Self.transcriptArgument(from: arguments) ?? userTranscript
                    if !routedTranscript.isEmpty {
                        userTranscript = routedTranscript
                        await MainActor.run { onUserTranscript(routedTranscript) }
                    }
                    let routed = await MainActor.run {
                        routeRealtimeToolCallBeforeAssistantResponse?(
                            name,
                            routedTranscript
                        ) ?? false
                    }
                    if routed {
                        didRouteByClient = true
                        break
                    }
                } else if type == "conversation.item.input_audio_transcription.completed",
                          let transcript = event["transcript"] as? String {
                    let snapshot = recordUserTranscript(transcript, completed: true)
                    userTranscript = snapshot
                    await MainActor.run { onUserTranscript(snapshot) }
                    if didCommitInput, !didRequestAssistantResponse, !didRouteByClient {
                        let routed = await MainActor.run {
                            routeUserTranscriptBeforeAssistantResponse?(snapshot) ?? false
                        }
                        if routed {
                            didRouteByClient = true
                            break
                        }
                        try await requestAssistantResponseIfNeeded()
                    }
                } else if (type == "conversation.item.input_audio_transcription.delta" || type == "conversation.item.input_audio_transcription.updated"),
                          let delta = event["delta"] as? String,
                          !delta.isEmpty {
                    let snapshot = recordUserTranscript(userTranscript + delta, completed: false)
                    userTranscript = snapshot
                    await MainActor.run { onUserTranscript(snapshot) }
                } else if type == "response.done" {
                    if let functionCall = Self.firstFunctionCall(in: event) {
                        let routedTranscript = Self.transcriptArgument(from: functionCall.arguments) ?? userTranscript
                        if !routedTranscript.isEmpty {
                            userTranscript = routedTranscript
                            await MainActor.run { onUserTranscript(routedTranscript) }
                        }
                        let routed = await MainActor.run {
                            routeRealtimeToolCallBeforeAssistantResponse?(
                                functionCall.name,
                                routedTranscript
                            ) ?? false
                        }
                        if routed {
                            didRouteByClient = true
                            break
                        }
                    }
                    if assistantTranscript.isEmpty,
                       let extracted = OpenAIRealtimeSpeechClient.firstTranscriptString(in: event),
                       !extracted.isEmpty {
                        assistantTranscript = extracted
                        let snapshot = assistantTranscript
                        await MainActor.run { onAssistantTextChunk(snapshot) }
                    }
                    break
                } else if type == "error" {
                    guard let error = client?.realtimeError(from: event) else { throw CancellationError() }
                    throw error
                }
            }

            if scheduledFrameCount > 0 {
                if !didStartPlayback, playerNode.engine?.isRunning == true {
                    didStartPlayback = true
                    await MainActor.run { playerNode.play() }
                    await MainActor.run { onPlaybackStarted() }
                }
                await ElevenLabsTTSClient.waitForPlaybackToDrain(
                    playerNode,
                    scheduledFrameCount: scheduledFrameCount,
                    sampleRate: OpenAIRealtimeSpeechClient.streamSampleRate
                )
            }
            return BidirectionalVoiceTurnResult(
                userTranscript: userTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                assistantTranscript: assistantTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                didCreateAssistantResponse: didRequestAssistantResponse,
                wasRoutedByClient: didRouteByClient
            )
        }

        private func recordUserTranscript(_ transcript: String, completed _: Bool) -> String {
            transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func transcriptArgument(from arguments: String?) -> String? {
            guard let arguments,
                  let data = arguments.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let transcript = json["transcript"] as? String else {
                return nil
            }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func firstFunctionCall(in event: [String: Any]) -> (name: String, arguments: String?)? {
            guard let response = event["response"] as? [String: Any],
                  let output = response["output"] as? [[String: Any]] else {
                return nil
            }
            for item in output where item["type"] as? String == "function_call" {
                guard let name = item["name"] as? String else { continue }
                return (name, item["arguments"] as? String)
            }
            return nil
        }

        private func sendJSON(_ payload: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let string = String(data: data, encoding: .utf8) else { return }
            try await webSocket.send(.string(string))
        }
    }


    private nonisolated static func firstTranscriptString(in value: Any) -> String? {
        if let string = value as? String { return string }
        if let dictionary = value as? [String: Any] {
            for key in ["transcript", "text"] {
                if let string = dictionary[key] as? String, !string.isEmpty { return string }
            }
            for nested in dictionary.values {
                if let string = firstTranscriptString(in: nested), !string.isEmpty { return string }
            }
        }
        if let array = value as? [Any] {
            for nested in array {
                if let string = firstTranscriptString(in: nested), !string.isEmpty { return string }
            }
        }
        return nil
    }

    func stopPlayback() {
        stopPlaybackInternal()
    }

    private func stopPlaybackInternal() {
        streamingTask?.cancel()
        streamingTask = nil
        if let playerNode {
            ElevenLabsTTSClient.stopPlayerIfAttached(playerNode)
        }
        playerNode = nil
        audioEngine?.stop()
        audioEngine = nil
    }

    private static func makeStreamFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: streamSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    private func waitForRealtimeConnection(on webSocket: URLSessionWebSocketTask) async throws {
        while true {
            try Task.checkCancellation()
            let event = try await receiveRealtimeEvent(from: webSocket)
            let type = event["type"] as? String ?? ""
            if type == "session.created" || type == "session.updated" {
                return
            }
            if type == "error" {
                throw realtimeError(from: event)
            }
        }
    }

    private func receiveRealtimeEvent(from webSocket: URLSessionWebSocketTask) async throws -> [String: Any] {
        while true {
            let message = try await webSocket.receive()
            let data: Data
            switch message {
            case .data(let messageData):
                data = messageData
            case .string(let string):
                data = Data(string.utf8)
            @unknown default:
                continue
            }
            if let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return event
            }
        }
    }

    private func sendJSON(_ payload: [String: Any], to webSocket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let string = String(data: data, encoding: .utf8) else { return }
        try await webSocket.send(.string(string))
    }

    private nonisolated func realtimeError(from event: [String: Any]) -> NSError {
        let errorPayload = event["error"] as? [String: Any]
        let message = errorPayload?["message"] as? String ?? "OpenAI Realtime playback failed."
        return NSError(domain: "OpenAIRealtimeSpeechClient", code: -2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private nonisolated static func imageDataURI(for imageData: Data) -> String {
        let mimeType = imageData.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        return "data:\(mimeType);base64,\(imageData.base64EncodedString())"
    }

    private nonisolated static func microphoneInputError(_ message: String) -> NSError {
        NSError(domain: "OpenAIRealtimeSpeechClient", code: -2000, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private nonisolated static func int16Samples(fromLittleEndianPCM data: Data) -> [Int16] {
        var samples: [Int16] = []
        samples.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let low = UInt16(data[index])
            let high = UInt16(data[index + 1]) << 8
            samples.append(Int16(bitPattern: high | low))
            index += 2
        }
        return samples
    }
}


// MARK: - DeepgramVoiceAgentClient

/// Bidirectional Deepgram Voice Agent client. Deepgram owns the live
/// listen/think/speak loop over one WebSocket: OpenClicky streams PCM
/// microphone audio, receives `ConversationText` events, and plays raw
/// binary PCM audio chunks back as they arrive.
@MainActor
final class DeepgramVoiceAgentClient {
    nonisolated static let streamSampleRate: Double = 24_000
    private static let voiceAgentEndpoint = "wss://agent.deepgram.com/v1/agent/converse"

    struct BidirectionalVoiceTurnResult {
        let userTranscript: String
        let assistantTranscript: String
        let didCreateAssistantResponse: Bool
        let wasRoutedByClient: Bool
    }

    private var apiKey: String?
    private(set) var voiceID: String
    var thinkModel: String
    private let listenModel: String
    private let session: URLSession

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var activeTurn: BidirectionalVoiceTurn?

    init(apiKey: String?, voiceID: String, thinkModel: String, listenModel: String = "nova-3") {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVoice = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = trimmedVoice.isEmpty ? "aura-2-thalia-en" : trimmedVoice
        self.thinkModel = Self.normalizedThinkModel(thinkModel)
        self.listenModel = Self.normalizedListenModel(listenModel)
        self.session = URLSession(configuration: .default)
    }

    var isPlaying: Bool {
        guard let playerNode, playerNode.engine != nil else { return false }
        return playerNode.isPlaying
    }

    private nonisolated static func normalizedThinkModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "gpt-4o-mini" : trimmed.lowercased()
    }

    private nonisolated static func normalizedListenModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        // Flux owns end-of-turn detection for the Voice Agent API. It is less
        // prone to cutting users off mid-thought than the older Nova listen
        // defaults when OpenClicky is used as a live realtime conversation.
        return trimmed.isEmpty ? "flux-general-en" : trimmed.lowercased()
    }

    func updateConfiguration(apiKey: String?, voiceID: String, thinkModel: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVoice = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVoice.isEmpty { self.voiceID = trimmedVoice }
        let normalizedThinkModel = Self.normalizedThinkModel(thinkModel)
        if !normalizedThinkModel.isEmpty { self.thinkModel = normalizedThinkModel }
    }

    func warmUpConnection() {
        guard let url = URL(string: Self.voiceAgentEndpoint.replacingOccurrences(of: "wss://", with: "https://")) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    func beginBidirectionalVoiceTurn(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        onUserTranscript: @escaping @MainActor @Sendable (String) -> Void,
        onAssistantTextChunk: @escaping @MainActor @Sendable (String) -> Void,
        onPlaybackStarted: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        stopPlaybackInternal()
        activeTurn?.cancel()
        activeTurn = nil

        guard let apiKey, !apiKey.isEmpty else {
            throw NSError(
                domain: "DeepgramVoiceAgentClient",
                code: -1000,
                userInfo: [NSLocalizedDescriptionKey: "Deepgram Voice Agent needs a Deepgram API key in Settings or DEEPGRAM_API_KEY in the launch environment."]
            )
        }
        guard let url = URL(string: Self.voiceAgentEndpoint) else {
            throw NSError(domain: "DeepgramVoiceAgentClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Deepgram Voice Agent WebSocket URL is invalid."])
        }
        guard let streamFormat = Self.makeStreamFormat() else {
            throw NSError(domain: "DeepgramVoiceAgentClient", code: -3, userInfo: [NSLocalizedDescriptionKey: "Could not build Deepgram Voice Agent PCM stream format."])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let webSocket = session.webSocketTask(with: request)
        webSocket.resume()
        try await waitForEvent("Welcome", on: webSocket)

        let historyMessages: [[String: String]] = conversationHistory.suffix(8).flatMap { entry in
            [
                ["type": "History", "role": "user", "content": entry.userPlaceholder],
                ["type": "History", "role": "assistant", "content": entry.assistantResponse]
            ]
        }
        let instructions = [
            systemPrompt,
            "You are in OpenClicky's Deepgram Voice Agent realtime mode. Listen to the user's live microphone audio directly and reply out loud as OpenClicky in one concise spoken answer. Do not claim you will start background work, take care of a task, or start an agent unless the app already routed the turn before you receive it. Do not mention transcription, Whisper, markdown, or [POINT:] tags."
        ].compactMap { $0 }.joined(separator: "\n\n")

        var listenProvider: [String: Any] = [
            "type": "deepgram",
            "model": listenModel
        ]
        if listenModel.hasPrefix("flux-") {
            listenProvider["version"] = "v2"
            // Higher confidence means Deepgram waits for stronger evidence that
            // the user is actually done, trading a little latency for fewer
            // premature cutoffs in OpenClicky's realtime voice mode.
            listenProvider["eot_threshold"] = 0.9
        } else {
            listenProvider["smart_format"] = true
        }

        var agent: [String: Any] = [
            "language": "en",
            "listen": [
                "provider": listenProvider
            ],
            "think": [
                "provider": [
                    "type": "open_ai",
                    "model": thinkModel,
                    "temperature": 0.6
                ],
                "prompt": instructions
            ],
            "speak": [
                "provider": [
                    "type": "deepgram",
                    "model": voiceID
                ]
            ]
        ]
        if !historyMessages.isEmpty {
            agent["context"] = ["messages": historyMessages]
        }

        try await sendJSON([
            "type": "Settings",
            "tags": ["openclicky", "voice_agent"],
            "audio": [
                "input": [
                    "encoding": "linear16",
                    "sample_rate": Int(Self.streamSampleRate)
                ],
                "output": [
                    "encoding": "linear16",
                    "sample_rate": Int(Self.streamSampleRate),
                    "container": "none"
                ]
            ],
            "agent": agent
        ], to: webSocket)
        try await waitForEvent("SettingsApplied", on: webSocket)

        let turn = try BidirectionalVoiceTurn(
            client: self,
            webSocket: webSocket,
            streamFormat: streamFormat,
            onUserTranscript: onUserTranscript,
            onAssistantTextChunk: onAssistantTextChunk,
            onPlaybackStarted: onPlaybackStarted
        )
        activeTurn = turn
        audioEngine = turn.outputEngine
        playerNode = turn.playerNode
        try turn.startInputCapture()
        turn.startReceiving()
    }

    func finishBidirectionalVoiceTurn(
        routeUserTranscriptBeforeAssistantResponse: (@MainActor @Sendable (String) -> Bool)? = nil
    ) async throws -> BidirectionalVoiceTurnResult {
        guard let activeTurn else { throw CancellationError() }
        self.activeTurn = nil
        do {
            let result = try await activeTurn.finish(routeUserTranscriptBeforeAssistantResponse: routeUserTranscriptBeforeAssistantResponse)
            stopPlayback(for: activeTurn)
            return result
        } catch {
            activeTurn.cancel()
            stopPlayback(for: activeTurn)
            throw error
        }
    }

    func cancelBidirectionalVoiceTurn() {
        if let activeTurn {
            activeTurn.cancel()
            stopPlayback(for: activeTurn)
        }
        activeTurn = nil
    }

    /// Stops only the given turn's output engine. The shared
    /// `audioEngine`/`playerNode` slot may already hold the streaming TTS
    /// engine of a response the app routed out of this turn — that engine
    /// must keep playing, so the slot is released only if it still points
    /// at the turn's own engine.
    private func stopPlayback(for turn: BidirectionalVoiceTurn) {
        ElevenLabsTTSClient.stopPlayerIfAttached(turn.playerNode)
        turn.outputEngine.stop()
        if playerNode === turn.playerNode {
            playerNode = nil
        }
        if audioEngine === turn.outputEngine {
            audioEngine = nil
        }
    }

    private final class BidirectionalVoiceTurn {
        private weak var client: DeepgramVoiceAgentClient?
        private let webSocket: URLSessionWebSocketTask
        let outputEngine: AVAudioEngine
        let playerNode: AVAudioPlayerNode
        private let inputEngine = AVAudioEngine()
        private let inputConverter = BuddyPCM16AudioConverter(targetSampleRate: DeepgramVoiceAgentClient.streamSampleRate)
        private let streamFormat: AVAudioFormat
        private let onUserTranscript: @MainActor @Sendable (String) -> Void
        private let onAssistantTextChunk: @MainActor @Sendable (String) -> Void
        private let onPlaybackStarted: @MainActor @Sendable () -> Void
        private var receiveTask: Task<BidirectionalVoiceTurnResult, Error>?
        private var keepAliveTask: Task<Void, Never>?
        private var routeUserTranscriptBeforeAssistantResponse: (@MainActor @Sendable (String) -> Bool)?
        private var hasInstalledInputTap = false
        private var didStartPlayback = false
        private var didCreateAssistantResponse = false
        private var didRouteByClient = false
        private var didStopInput = false

        init(
            client: DeepgramVoiceAgentClient,
            webSocket: URLSessionWebSocketTask,
            streamFormat: AVAudioFormat,
            onUserTranscript: @escaping @MainActor @Sendable (String) -> Void,
            onAssistantTextChunk: @escaping @MainActor @Sendable (String) -> Void,
            onPlaybackStarted: @escaping @MainActor @Sendable () -> Void
        ) throws {
            self.client = client
            self.webSocket = webSocket
            self.streamFormat = streamFormat
            self.onUserTranscript = onUserTranscript
            self.onAssistantTextChunk = onAssistantTextChunk
            self.onPlaybackStarted = onPlaybackStarted

            let outputEngine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            outputEngine.attach(playerNode)
            outputEngine.connect(playerNode, to: outputEngine.mainMixerNode, format: streamFormat)
            try outputEngine.start()
            self.outputEngine = outputEngine
            self.playerNode = playerNode
        }

        func startInputCapture() throws {
            let inputNode = inputEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 256, format: inputFormat) { [weak self] buffer, _ in
                guard let self,
                      let pcmData = self.inputConverter.convertToPCM16Data(from: buffer),
                      !pcmData.isEmpty else { return }
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.webSocket.send(.data(pcmData))
                }
            }
            hasInstalledInputTap = true
            inputEngine.prepare()
            try inputEngine.start()
        }

        func startReceiving() {
            keepAliveTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    try? await self.sendJSON(["type": "KeepAlive"])
                }
            }
            receiveTask = Task { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.receiveUntilDone()
            }
        }

        func finish(
            routeUserTranscriptBeforeAssistantResponse: (@MainActor @Sendable (String) -> Bool)? = nil
        ) async throws -> BidirectionalVoiceTurnResult {
            stopInputCapture()
            self.routeUserTranscriptBeforeAssistantResponse = routeUserTranscriptBeforeAssistantResponse
            do {
                guard let receiveTask else { throw CancellationError() }
                let result = try await withThrowingTaskGroup(of: BidirectionalVoiceTurnResult.self) { group in
                    group.addTask { try await receiveTask.value }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                        throw NSError(
                            domain: "DeepgramVoiceAgentClient",
                            code: -30,
                            userInfo: [NSLocalizedDescriptionKey: "Deepgram Voice Agent did not finish the realtime turn before timeout."]
                        )
                    }
                    guard let first = try await group.next() else { throw CancellationError() }
                    group.cancelAll()
                    return first
                }
                webSocket.cancel(with: .normalClosure, reason: nil)
                keepAliveTask?.cancel()
                keepAliveTask = nil
                return result
            } catch {
                keepAliveTask?.cancel()
                keepAliveTask = nil
                throw error
            }
        }

        func cancel() {
            stopInputCapture()
            receiveTask?.cancel()
            receiveTask = nil
            keepAliveTask?.cancel()
            keepAliveTask = nil
            ElevenLabsTTSClient.stopPlayerIfAttached(playerNode)
            outputEngine.stop()
            webSocket.cancel(with: .goingAway, reason: nil)
        }

        private func sendJSON(_ payload: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let string = String(data: data, encoding: .utf8) else { return }
            try await webSocket.send(.string(string))
        }

        private func stopInputCapture() {
            didStopInput = true
            if hasInstalledInputTap {
                inputEngine.inputNode.removeTap(onBus: 0)
                hasInstalledInputTap = false
            }
            if inputEngine.isRunning {
                inputEngine.stop()
            }
        }

        private func receiveUntilDone() async throws -> BidirectionalVoiceTurnResult {
            var userTranscript = ""
            var assistantTranscript = ""
            var scheduledFrameCount: AVAudioFramePosition = 0

            receiveLoop: while true {
                try Task.checkCancellation()
                guard let message = try await client?.receiveMessage(from: webSocket) else { throw CancellationError() }
                switch message {
                case .audio(let data):
                    let samples = DeepgramVoiceAgentClient.int16Samples(fromLittleEndianPCM: data)
                    let frames = await MainActor.run {
                        ElevenLabsTTSClient.scheduleSamples(samples, on: playerNode, format: streamFormat)
                    }
                    scheduledFrameCount += frames
                    if frames > 0, !didStartPlayback {
                        didStartPlayback = true
                        await MainActor.run { onPlaybackStarted() }
                    }
                case .event(let event):
                    let type = event["type"] as? String ?? ""
                    if type == "ConversationText" {
                        let role = event["role"] as? String ?? ""
                        let content = (event["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !content.isEmpty else { continue }
                        if role == "user" {
                            userTranscript = content
                            await MainActor.run { onUserTranscript(content) }
                            if didStopInput, !didRouteByClient, !didCreateAssistantResponse {
                                let routed = await MainActor.run {
                                    routeUserTranscriptBeforeAssistantResponse?(content) ?? false
                                }
                                if routed {
                                    didRouteByClient = true
                                    break receiveLoop
                                }
                            }
                        } else if role == "assistant" {
                            didCreateAssistantResponse = true
                            assistantTranscript = content
                            await MainActor.run { onAssistantTextChunk(content) }
                        }
                    } else if type == "UserStartedSpeaking" {
                        ElevenLabsTTSClient.stopPlayerIfAttached(playerNode)
                    } else if type == "AgentAudioDone" {
                        break receiveLoop
                    } else if type == "Error" || type == "error" {
                        guard let error = client?.voiceAgentError(from: event) else { throw CancellationError() }
                        throw error
                    }
                }
            }

            if scheduledFrameCount > 0 {
                await ElevenLabsTTSClient.waitForPlaybackToDrain(
                    playerNode,
                    scheduledFrameCount: scheduledFrameCount,
                    sampleRate: DeepgramVoiceAgentClient.streamSampleRate
                )
            }
            return BidirectionalVoiceTurnResult(
                userTranscript: userTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                assistantTranscript: assistantTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                didCreateAssistantResponse: didCreateAssistantResponse,
                wasRoutedByClient: didRouteByClient
            )
        }
    }

    private enum IncomingMessage {
        case event([String: Any])
        case audio(Data)
    }

    private func waitForEvent(_ expectedType: String, on webSocket: URLSessionWebSocketTask) async throws {
        while true {
            try Task.checkCancellation()
            let message = try await receiveMessage(from: webSocket)
            if case .event(let event) = message {
                let type = event["type"] as? String ?? ""
                if type == expectedType { return }
                if type == "Error" || type == "error" { throw voiceAgentError(from: event) }
            }
        }
    }

    private func receiveMessage(from webSocket: URLSessionWebSocketTask) async throws -> IncomingMessage {
        let message = try await webSocket.receive()
        switch message {
        case .data(let data):
            if let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return .event(event)
            }
            return .audio(data)
        case .string(let string):
            if let data = string.data(using: .utf8),
               let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return .event(event)
            }
            return .event(["type": "Warning", "description": string])
        @unknown default:
            return .event(["type": "Warning", "description": "Unknown Deepgram WebSocket message"])
        }
    }

    private func sendJSON(_ payload: [String: Any], to webSocket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let string = String(data: data, encoding: .utf8) else { return }
        try await webSocket.send(.string(string))
    }

    private nonisolated func voiceAgentError(from event: [String: Any]) -> NSError {
        let message = event["description"] as? String
            ?? event["message"] as? String
            ?? (event["error"] as? [String: Any])?["message"] as? String
            ?? "Deepgram Voice Agent failed."
        return NSError(domain: "DeepgramVoiceAgentClient", code: -2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func stopPlayback() {
        stopPlaybackInternal()
    }

    private func stopPlaybackInternal() {
        activeTurn?.cancel()
        activeTurn = nil
        if let playerNode {
            ElevenLabsTTSClient.stopPlayerIfAttached(playerNode)
        }
        playerNode = nil
        audioEngine?.stop()
        audioEngine = nil
    }

    private static func makeStreamFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: streamSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    private nonisolated static func int16Samples(fromLittleEndianPCM data: Data) -> [Int16] {
        var samples: [Int16] = []
        samples.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let low = UInt16(data[index])
            let high = UInt16(data[index + 1]) << 8
            samples.append(Int16(bitPattern: high | low))
            index += 2
        }
        return samples
    }
}

// MARK: - OpenClickyTTSProvider

nonisolated enum OpenClickyTTSProvider: String, CaseIterable, Identifiable {
    case openAIRealtime = "openai_realtime"
    case elevenLabs = "elevenlabs"
    case cartesia = "cartesia"
    case deepgram = "deepgram"
    case microsoftEdge = "microsoft_edge"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .openAIRealtime: return "GPT Realtime"
        case .elevenLabs: return "ElevenLabs"
        case .cartesia: return "Cartesia"
        case .deepgram: return "Deepgram Aura"
        case .microsoftEdge: return "Microsoft Edge"
        }
    }
    static func resolve(_ raw: String?) -> OpenClickyTTSProvider {
        guard let raw, let parsed = OpenClickyTTSProvider(rawValue: raw) else { return .openAIRealtime }
        return parsed
    }
}

nonisolated struct MicrosoftEdgeVoiceOption: Identifiable, Hashable {
    let id: String
    let label: String
    let subtitle: String

    static let recommended: [MicrosoftEdgeVoiceOption] = [
        .init(id: "en-US-EmmaMultilingualNeural", label: "Emma", subtitle: "US English, multilingual female"),
        .init(id: "en-US-BrianMultilingualNeural", label: "Brian", subtitle: "US English, multilingual male"),
        .init(id: "en-US-AriaNeural", label: "Aria", subtitle: "US English female"),
        .init(id: "en-US-JennyNeural", label: "Jenny", subtitle: "US English female"),
        .init(id: "en-US-GuyNeural", label: "Guy", subtitle: "US English male"),
        .init(id: "en-US-AvaMultilingualNeural", label: "Ava", subtitle: "US English, multilingual female"),
        .init(id: "en-GB-SoniaNeural", label: "Sonia", subtitle: "British English female"),
        .init(id: "en-GB-RyanNeural", label: "Ryan", subtitle: "British English male"),
        .init(id: "en-AU-NatashaNeural", label: "Natasha", subtitle: "Australian English female"),
        .init(id: "en-AU-WilliamNeural", label: "William", subtitle: "Australian English male"),
        .init(id: "en-CA-ClaraNeural", label: "Clara", subtitle: "Canadian English female"),
        .init(id: "en-CA-LiamNeural", label: "Liam", subtitle: "Canadian English male"),
        .init(id: "en-IN-NeerjaNeural", label: "Neerja", subtitle: "Indian English female"),
        .init(id: "en-IN-PrabhatNeural", label: "Prabhat", subtitle: "Indian English male")
    ]

    static func option(for id: String) -> MicrosoftEdgeVoiceOption? {
        recommended.first { $0.id == id }
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

    var isPlaying: Bool {
        guard let playerNode, playerNode.engine != nil else { return false }
        return playerNode.isPlaying
    }

    func stopPlayback() {
        activeStreamingSession?.cancel()
        activeStreamingSession = nil
        stopPlaybackInternal()
    }

    private func stopPlaybackInternal() {
        streamingTask?.cancel()
        streamingTask = nil
        if let playerNode {
            ElevenLabsTTSClient.stopPlayerIfAttached(playerNode)
        }
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
