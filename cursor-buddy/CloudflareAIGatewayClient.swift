import AVFoundation
import Foundation

nonisolated enum CloudflareAIGatewayRoute {
    static let defaultGatewayID = "x"
    static let textGeneration = "dynamic/text_gen"
    static let researchGeneration = "dynamic/research_gen"
    static let embeddings = "dynamic/ai_embed"
    static let imageGeneration = "dynamic/image_gen"
    static let audioGeneration = "dynamic/audio_gen"
    static let transcription = "dynamic/stt_gen"
    static let videoGeneration = "dynamic/video_gen"
}

nonisolated struct CloudflareAIGatewayConfiguration: Equatable {
    var isEnabled: Bool
    var accountID: String
    var gatewayID: String
    var token: String
    var textRoute: String
    var transcriptionRoute: String
    var zeroDataRetention: Bool

    var isConfigured: Bool {
        isEnabled
            && !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !gatewayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var chatCompletionsURL: URL? {
        let account = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let gateway = gatewayID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !gateway.isEmpty else { return nil }
        return URL(string: "https://gateway.ai.cloudflare.com/v1/\(account)/\(gateway)/compat/chat/completions")
    }

    static var current: CloudflareAIGatewayConfiguration {
        CloudflareAIGatewayConfiguration(
            isEnabled: AppBundleConfiguration.cloudflareAIGatewayEnabled(),
            accountID: AppBundleConfiguration.cloudflareAIGatewayAccountID() ?? "",
            gatewayID: AppBundleConfiguration.cloudflareAIGatewayID(),
            token: AppBundleConfiguration.cloudflareAIGatewayToken() ?? "",
            textRoute: AppBundleConfiguration.cloudflareAIGatewayTextRoute(),
            transcriptionRoute: AppBundleConfiguration.cloudflareAIGatewayTranscriptionRoute(),
            zeroDataRetention: AppBundleConfiguration.cloudflareAIGatewayZeroDataRetentionEnabled()
        )
    }
}

nonisolated final class CloudflareAIGatewayClient: @unchecked Sendable {
    enum GatewayError: LocalizedError {
        case notConfigured
        case invalidURL
        case httpError(statusCode: Int, body: String)
        case invalidResponse
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Cloudflare AI Gateway is not configured. Add account ID, gateway ID, and token in Settings."
            case .invalidURL:
                return "Cloudflare AI Gateway URL could not be built from the configured account and gateway IDs."
            case .httpError(let statusCode, let body):
                return "Cloudflare AI Gateway error (\(statusCode)): \(body)"
            case .invalidResponse:
                return "Cloudflare AI Gateway returned an invalid response."
            case .emptyResponse:
                return "Cloudflare AI Gateway returned an empty response."
            }
        }
    }

    private let configuration: CloudflareAIGatewayConfiguration
    private let session: URLSession

    init(configuration: CloudflareAIGatewayConfiguration = .current) {
        self.configuration = configuration

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    static var isConfigured: Bool {
        CloudflareAIGatewayConfiguration.current.isConfigured
    }

    func streamChatCompletion(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        images: [(data: Data, label: String)] = [],
        route: String? = nil,
        maxOutputTokens: Int,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let requestRoute = normalizedRoute(route ?? configuration.textRoute, fallback: CloudflareAIGatewayRoute.textGeneration)
        let request = try makeRequest(
            body: makeChatCompletionsBody(
                route: requestRoute,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                images: images,
                maxOutputTokens: maxOutputTokens,
                stream: true
            ),
            accept: "text/event-stream"
        )

        let (byteStream, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GatewayError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var chunks: [String] = []
            for try await line in byteStream.lines {
                chunks.append(line)
            }
            throw GatewayError.httpError(statusCode: httpResponse.statusCode, body: chunks.joined(separator: "\n"))
        }

        var accumulatedText = ""
        var sawStreamingDelta = false
        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }
            guard let jsonData = jsonString.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }
            if let error = Self.errorMessage(from: payload) {
                throw GatewayError.httpError(statusCode: httpResponse.statusCode, body: error)
            }
            if let delta = Self.extractStreamingDelta(from: payload), !delta.isEmpty {
                sawStreamingDelta = true
                accumulatedText += delta
                let currentText = accumulatedText
                await MainActor.run {
                    onTextChunk(currentText)
                }
            } else if !sawStreamingDelta {
                let wholeText = Self.extractChatCompletionText(from: payload)
                if !wholeText.isEmpty {
                    accumulatedText = wholeText
                    await MainActor.run {
                        onTextChunk(wholeText)
                    }
                }
            }
        }

        guard !accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayError.emptyResponse
        }
        return (text: accumulatedText, duration: Date().timeIntervalSince(startTime))
    }

    func transcribeAudio(wavAudioData: Data, prompt: String? = nil) async throws -> String {
        let requestRoute = normalizedRoute(configuration.transcriptionRoute, fallback: CloudflareAIGatewayRoute.transcription)
        let audioPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userText = audioPrompt?.isEmpty == false
            ? "Transcribe this audio. Return only the transcript. Context terms: \(audioPrompt!)"
            : "Transcribe this audio. Return only the transcript."
        let body: [String: Any] = [
            "model": requestRoute,
            "temperature": 0,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": userText
                        ],
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": wavAudioData.base64EncodedString(),
                                "format": "wav"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let request = try makeRequest(body: body, accept: "application/json")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GatewayError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GatewayError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayError.invalidResponse
        }
        if let error = Self.errorMessage(from: payload) {
            throw GatewayError.httpError(statusCode: httpResponse.statusCode, body: error)
        }
        let text = Self.extractChatCompletionText(from: payload)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw GatewayError.emptyResponse
        }
        return text
    }

    private func makeRequest(body: [String: Any], accept: String) throws -> URLRequest {
        guard configuration.isConfigured else { throw GatewayError.notConfigured }
        guard let url = configuration.chatCompletionsURL else { throw GatewayError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "cf-aig-authorization")
        request.setValue(configuration.zeroDataRetention ? "true" : "false", forHTTPHeaderField: "cf-aig-zdr")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func makeChatCompletionsBody(
        route: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        images: [(data: Data, label: String)],
        maxOutputTokens: Int,
        stream: Bool
    ) -> [String: Any] {
        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": systemPrompt
            ]
        ]

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)])
        }

        if images.isEmpty {
            messages.append(["role": "user", "content": userPrompt])
        } else {
            var content: [[String: Any]] = []
            for image in images {
                content.append(["type": "text", "text": image.label])
                content.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:\(Self.mediaType(for: image.data));base64,\(image.data.base64EncodedString())"
                    ]
                ])
            }
            content.append(["type": "text", "text": userPrompt])
            messages.append(["role": "user", "content": content])
        }

        return [
            "model": route,
            "messages": messages,
            "max_tokens": maxOutputTokens,
            "stream": stream
        ]
    }

    private func normalizedRoute(_ route: String, fallback: String) -> String {
        let trimmed = route.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func mediaType(for data: Data) -> String {
        if data.count >= 4 {
            let signature = [UInt8](data.prefix(4))
            if signature == [0x89, 0x50, 0x4E, 0x47] {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    private static func extractStreamingDelta(from payload: [String: Any]) -> String? {
        guard let choices = payload["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }
        if let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String {
                return content
            }
            if let contentItems = delta["content"] as? [[String: Any]] {
                return contentItems.compactMap { $0["text"] as? String }.joined()
            }
        }
        return nil
    }

    private static func extractChatCompletionText(from payload: [String: Any]) -> String {
        guard let choices = payload["choices"] as? [[String: Any]] else { return "" }
        return choices.compactMap { choice in
            if let message = choice["message"] as? [String: Any] {
                if let content = message["content"] as? String {
                    return content
                }
                if let contentItems = message["content"] as? [[String: Any]] {
                    return contentItems.compactMap { item in
                        item["text"] as? String
                    }.joined()
                }
            }
            if let text = choice["text"] as? String {
                return text
            }
            return nil
        }.joined()
    }

    private static func errorMessage(from payload: [String: Any]) -> String? {
        if let error = payload["error"] as? String {
            return error
        }
        if let error = payload["error"] as? [String: Any] {
            if let message = error["message"] as? String {
                return message
            }
            if let code = error["code"] as? String {
                return code
            }
        }
        return nil
    }
}

final class CloudflareAIGatewayTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Cloudflare Gateway"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        CloudflareAIGatewayClient.isConfigured
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "Cloudflare AI Gateway transcription is not configured. Add account ID, gateway ID, and token."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard isConfigured else {
            throw CloudflareAIGatewayClient.GatewayError.notConfigured
        }
        return CloudflareAIGatewayTranscriptionSession(
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class CloudflareAIGatewayTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0

    private static let targetSampleRate = 16_000
    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.cloudflare-gateway.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: Double(targetSampleRate))
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void
    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
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
    }

    private func transcribe(_ audioData: Data) async {
        guard !Task.isCancelled else { return }
        let shouldSkip = stateQueue.sync { isCancelled || audioData.isEmpty }
        guard !shouldSkip else {
            onFinalTranscriptReady("")
            return
        }
        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: audioData,
            sampleRate: Self.targetSampleRate
        )
        do {
            let prompt = keyterms.joined(separator: ", ")
            let transcript = try await CloudflareAIGatewayClient().transcribeAudio(
                wavAudioData: wavAudioData,
                prompt: prompt.isEmpty ? nil : prompt
            )
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            if !transcript.isEmpty {
                onTranscriptUpdate(transcript)
            }
            onFinalTranscriptReady(transcript)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            onError(error)
        }
    }
}
