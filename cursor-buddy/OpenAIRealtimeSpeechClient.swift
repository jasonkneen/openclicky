//
//  OpenAIRealtimeSpeechClient.swift
//  cursor-buddy
//

import AVFoundation
import Foundation

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

    nonisolated static func realtimeReasoningConfiguration(for modelID: String) -> [String: String]? {
        let normalizedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedModel.hasPrefix("gpt-realtime-2") else { return nil }
        // OpenAI's Realtime 2 guidance recommends starting production voice
        // agents at low reasoning effort, then increasing only for workflows
        // where deeper planning beats latency.
        return ["effort": "low"]
    }

    private nonisolated static func addRealtimeReasoningConfiguration(to session: inout [String: Any], modelID: String) {
        guard let reasoning = realtimeReasoningConfiguration(for: modelID) else { return }
        session["reasoning"] = reasoning
    }

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
        do {
            try engine.start()
        } catch {
            guard Self.isRecoverableAudioEngineStartError(error) else { throw error }
            Self.prepareEngineForRetry(engine)
            try engine.start()
        }
        audioEngine = engine
        playerNode = player

        let task = Task { [weak self, weak player] in
            guard let self, let player else { throw CancellationError() }
            let samples = try await self.fetchSentenceSamples(trimmed)
            try Task.checkCancellation()
            let scheduledFrameCount = await MainActor.run {
                TTSStreamingPlaybackEngine.scheduleSamples(samples, on: player, format: streamFormat)
            }
            await MainActor.run { onPlaybackStarted?() }
            await TTSStreamingPlaybackEngine.waitForPlaybackToDrain(
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
                onPlaybackStarted: onPlaybackStarted,
                startupError: NSError(
                    domain: "OpenAIRealtimeSpeechClient",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Could not build OpenAI Realtime PCM stream format."]
                )
            )
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do {
            try engine.start()
        } catch {
            if Self.isRecoverableAudioEngineStartError(error) {
                Self.prepareEngineForRetry(engine)
                do {
                    try engine.start()
                } catch {
                    print("⚠️ AVAudioEngine retry failed for OpenAI Realtime speech session: \(error)")
                    return StreamingTTSSession(
                        fetchSamples: { [weak self] text in
                            guard let self else { throw CancellationError() }
                            return try await self.fetchSentenceSamples(text)
                        },
                        playerNode: nil,
                        format: nil,
                        sampleRate: Self.streamSampleRate,
                        onPlaybackStarted: onPlaybackStarted,
                        startupError: error
                    )
                }
            }
            print("⚠️ AVAudioEngine failed to start OpenAI Realtime speech session: \(error)")
            return StreamingTTSSession(
                fetchSamples: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchSentenceSamples(text)
                },
                playerNode: nil,
                format: nil,
                sampleRate: Self.streamSampleRate,
                onPlaybackStarted: onPlaybackStarted,
                startupError: error
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

            var sessionConfiguration: [String: Any] = [
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
            Self.addRealtimeReasoningConfiguration(to: &sessionConfiguration, modelID: model)
            try await sendJSON([
                "type": "session.update",
                "session": sessionConfiguration
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
        guard let turn = activeBidirectionalVoiceTurn else {
            throw CancellationError()
        }
        do {
            let result = try await turn.finish(
                routeUserTranscriptBeforeAssistantResponse: routeUserTranscriptBeforeAssistantResponse,
                routeRealtimeToolCallBeforeAssistantResponse: routeRealtimeToolCallBeforeAssistantResponse
            )
            if activeBidirectionalVoiceTurn === turn {
                activeBidirectionalVoiceTurn = nil
            }
            stopPlayback(for: turn)
            return result
        } catch {
            turn.cancel()
            if activeBidirectionalVoiceTurn === turn {
                activeBidirectionalVoiceTurn = nil
            }
            stopPlayback(for: turn)
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
        TTSStreamingPlaybackEngine.stopPlayerIfAttached(turn.playerNode)
        turn.outputEngine.stop()
        turn.outputEngine.reset()
        if playerNode === turn.playerNode {
            playerNode = nil
        }
        if audioEngine === turn.outputEngine {
            audioEngine = nil
        }
    }

    private static func isRecoverableAudioEngineStartError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == -10877 {
            return true
        }
        return nsError.localizedDescription.contains("-10877")
    }

    private static func prepareEngineForRetry(_ engine: AVAudioEngine) {
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
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
        do {
            try engine.start()
        } catch {
            guard Self.isRecoverableAudioEngineStartError(error) else { throw error }
            Self.prepareEngineForRetry(engine)
            try engine.start()
        }
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
        var sessionConfiguration: [String: Any] = [
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
        Self.addRealtimeReasoningConfiguration(to: &sessionConfiguration, modelID: model)
        try await sendJSON([
            "type": "session.update",
            "session": sessionConfiguration
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
                    TTSStreamingPlaybackEngine.scheduleSamples(
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
            await TTSStreamingPlaybackEngine.waitForPlaybackToDrain(
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
        var sessionConfiguration: [String: Any] = [
            "type": "realtime",
            "model": requestModel,
            "output_modalities": ["text"]
        ]
        Self.addRealtimeReasoningConfiguration(to: &sessionConfiguration, modelID: requestModel)
        try await sendJSON([
            "type": "session.update",
            "session": sessionConfiguration
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

        var sessionConfiguration: [String: Any] = [
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
        Self.addRealtimeReasoningConfiguration(to: &sessionConfiguration, modelID: model)
        try await sendJSON([
            "type": "session.update",
            "session": sessionConfiguration
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
            do {
                try installTapAndStartEngine()
            } catch {
                guard OpenAIRealtimeSpeechClient.isRecoverableAudioEngineStartError(error) else {
                    stop()
                    throw error
                }
                stop()
                OpenAIRealtimeSpeechClient.prepareEngineForRetry(inputEngine)
                try installTapAndStartEngine()
            }
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
            inputEngine.reset()
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

        private func installTapAndStartEngine() throws {
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
        private var responseFallbackTask: Task<Void, Never>?
        private var routeUserTranscriptBeforeAssistantResponse: (@MainActor @Sendable (String) -> Bool)?
        private var routeRealtimeToolCallBeforeAssistantResponse: (@MainActor @Sendable (String, String) -> Bool)?
        private var didStartPlayback = false
        private var didCommitInput = false
        private var didRequestAssistantResponse = false
        private var didRouteByClient = false
        private var isCancelled = false

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
            do {
                try outputEngine.start()
            } catch {
                guard OpenAIRealtimeSpeechClient.isRecoverableAudioEngineStartError(error) else {
                    throw error
                }
                OpenAIRealtimeSpeechClient.prepareEngineForRetry(outputEngine)
                try outputEngine.start()
            }
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
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
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
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }

            // Let the Realtime transcription event reach OpenClicky's app
            // router before asking the model to speak. Pointing, direct
            // computer-use, and agent-start requests must become real app
            // actions, not spoken "[POINT:...]" / "Done" audio.
            responseFallbackTask?.cancel()
            responseFallbackTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                try? await self?.requestAssistantResponseIfNeeded()
            }

            do {
                guard let receiveTask else { throw CancellationError() }
                let result = try await receiveTask.value
                responseFallbackTask?.cancel()
                responseFallbackTask = nil
                webSocket.cancel(with: .normalClosure, reason: nil)
                return result
            } catch {
                responseFallbackTask?.cancel()
                responseFallbackTask = nil
                throw error
            }
        }

        private func requestAssistantResponseIfNeeded() async throws {
            guard didCommitInput,
                  !isCancelled,
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
            isCancelled = true
            stopInputCapture()
            receiveTask?.cancel()
            receiveTask = nil
            responseFallbackTask?.cancel()
            responseFallbackTask = nil
            TTSStreamingPlaybackEngine.stopPlayerIfAttached(playerNode)
            outputEngine.stop()
            outputEngine.reset()
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
                        TTSStreamingPlaybackEngine.scheduleSamples(
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
                await TTSStreamingPlaybackEngine.waitForPlaybackToDrain(
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
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return isLikelyRealtimeMetadataString(trimmed) ? nil : trimmed
        }
        if let dictionary = value as? [String: Any] {
            for key in ["transcript", "text", "content"] {
                if let string = dictionary[key] as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !isLikelyRealtimeMetadataString(trimmed) { return trimmed }
                }
            }

            let metadataKeys: Set<String> = [
                "event_id", "id", "item_id", "call_id", "previous_item_id", "response_id",
                "type", "object", "status", "role", "name", "model", "modalities"
            ]
            for (key, nested) in dictionary where !metadataKeys.contains(key) {
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

    private nonisolated static func isLikelyRealtimeMetadataString(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        if value.range(of: #"^(?:event|resp|msg|item|call)_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
            return true
        }
        if value.range(of: #"^(?:response|conversation|input_audio_buffer|session)\."#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    #if DEBUG
    nonisolated static func testFirstTranscriptString(in value: Any) -> String? {
        firstTranscriptString(in: value)
    }
    #endif

    func stopPlayback() {
        stopPlaybackInternal()
    }

    private func stopPlaybackInternal() {
        streamingTask?.cancel()
        streamingTask = nil
        if let playerNode {
            TTSStreamingPlaybackEngine.stopPlayerIfAttached(playerNode)
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
