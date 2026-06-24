import Foundation

/// Streaming client for OpenAI-compatible local servers (Ollama / LM Studio /
/// MLX-server / llama.cpp / vLLM). Speaks `POST {baseURL}/chat/completions`
/// with SSE streaming and optional vision (base64 `image_url` parts).
///
/// This is a deliberately separate client from `OpenAIAPI` (which targets the
/// proprietary cloud Responses API) so the billed cloud path carries no risk.
struct LocalChatCompletionsAPI {
    let baseURL: URL
    let apiKey: String?
    let model: String
    let maxOutputTokens: Int

    init(baseURL: URL, apiKey: String?, model: String, maxOutputTokens: Int) {
        self.baseURL = baseURL
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    /// Extracts the streamed token from one SSE line, or nil for
    /// `[DONE]`, keep-alive, or non-data lines. Pure and unit-tested.
    static func deltaContent(fromSSELine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        return content
    }

    static func requestBody(model: String, maxOutputTokens: Int, messages: [[String: Any]]) -> [String: Any] {
        ["model": model, "max_tokens": maxOutputTokens, "stream": true, "messages": messages]
    }

    private func buildMessages(systemPrompt: String,
                               history: [(userPlaceholder: String, assistantResponse: String)],
                               userPrompt: String,
                               images: [(data: Data, label: String)]) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for turn in history {
            messages.append(["role": "user", "content": turn.userPlaceholder])
            messages.append(["role": "assistant", "content": turn.assistantResponse])
        }
        if images.isEmpty {
            // Plain string content maximizes compatibility with text-only servers.
            messages.append(["role": "user", "content": userPrompt])
        } else {
            var parts: [[String: Any]] = [["type": "text", "text": userPrompt]]
            for image in images {
                let b64 = image.data.base64EncodedString()
                parts.append(["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b64)"]])
            }
            messages.append(["role": "user", "content": parts])
        }
        return messages
    }

    func streamResponse(systemPrompt: String,
                        history: [(userPlaceholder: String, assistantResponse: String)],
                        userPrompt: String,
                        images: [(data: Data, label: String)],
                        onTextChunk: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let messages = buildMessages(systemPrompt: systemPrompt,
                                     history: history,
                                     userPrompt: userPrompt,
                                     images: images)
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.requestBody(model: model, maxOutputTokens: maxOutputTokens, messages: messages))

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        // Local models can be slow on first load (cold start); allow plenty of room.
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LocalModelError.serverUnreachable(baseURL)
            }
            guard http.statusCode == 200 else {
                var body = ""
                for try await line in bytes.lines { body += line }
                throw LocalModelError.badResponse(http.statusCode, body)
            }
            var full = ""
            for try await line in bytes.lines {
                if let chunk = Self.deltaContent(fromSSELine: line) {
                    full += chunk
                    let piece = chunk
                    await MainActor.run { onTextChunk(piece) }
                }
            }
            return full
        } catch let error as URLError where
            error.code == .cannotConnectToHost || error.code == .cannotFindHost {
            throw LocalModelError.serverUnreachable(baseURL)
        }
    }
}
