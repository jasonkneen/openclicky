//
//  OpenAIAPI.swift
//  OpenAI API Implementation
//

import Foundation

/// OpenAI API helper for screen-aware responses through the Responses API.
class OpenAIAPI {
    private var apiKey: String?
    private let apiURL: URL
    var model: String
    var maxOutputTokens: Int
    private let session: URLSession

    init(apiKey: String?, model: String = "gpt-5.4", maxOutputTokens: Int = 128_000) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiURL = URL(string: "https://api.openai.com/v1/responses")!
        self.model = model
        self.maxOutputTokens = maxOutputTokens

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        warmUpTLSConnection()
    }

    func setAPIKey(_ apiKey: String?) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func warmUpTLSConnection() {
        var warmupRequest = URLRequest(url: apiURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in }.resume()
    }

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        guard let apiKey, !apiKey.isEmpty else {
            throw NSError(
                domain: "OpenAIAPI",
                code: -1000,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI is not configured. Set Codex/OpenAI key in Settings or OPENAI_API_KEY in the launch environment."]
            )
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var input: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            input.append([
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": userPlaceholder
                ]]
            ])
            input.append([
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": assistantResponse
                ]]
            ])
        }

        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "input_text",
                "text": image.label
            ])
            contentBlocks.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(image.data.base64EncodedString())"
            ])
        }
        contentBlocks.append([
            "type": "input_text",
            "text": userPrompt
        ])

        let body: [String: Any] = [
            "model": model,
            "instructions": systemPrompt,
            "max_output_tokens": maxOutputTokens,
            "input": input + [[
                "role": "user",
                "content": contentBlocks
            ]]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("OpenAI request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model=\(model), url=\(apiURL.absoluteString)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OpenAIAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "OpenAIAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let text = Self.extractOutputText(from: json)
        guard !text.isEmpty else {
            throw NSError(
                domain: "OpenAIAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI returned an empty response."]
            )
        }

        return (text: text, duration: Date().timeIntervalSince(startTime))
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        guard let apiKey, !apiKey.isEmpty else {
            throw NSError(
                domain: "OpenAIAPI",
                code: -1000,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI is not configured. Set Codex/OpenAI key in Settings or OPENAI_API_KEY in the launch environment."]
            )
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body = makeResponsesBody(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            stream: true
        )
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("OpenAI streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model=\(model), url=\(apiURL.absoluteString)")
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "outgoing",
            event: "openai.streaming.request",
            fields: [
                "model": model,
                "url": apiURL.absoluteString,
                "payloadBytes": bodyData.count,
                "transport": "sse",
                "streamingMethod": "URLSession.bytes",
                "images": images.map {
                    [
                        "label": $0.label,
                        "bytes": $0.data.count
                    ]
                }
            ]
        )

        let (byteStream, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenAIAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        let connectedAt = Date()
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: "openai.streaming.connected",
            fields: [
                "model": model,
                "statusCode": httpResponse.statusCode,
                "contentType": contentType,
                "payloadBytes": bodyData.count,
                "connectionLatencyMs": Self.elapsedMilliseconds(from: startTime, to: connectedAt),
                "transport": "sse",
                "streamingMethod": "URLSession.bytes"
            ]
        )

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "OpenAIAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode), content-type: \(contentType)): \(errorBody)"]
            )
        }

        var accumulatedResponseText = ""
        var textDeltaCount = 0
        var firstTextDeltaAt: Date?

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }
            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            if eventType == "response.output_text.delta",
               let textChunk = eventPayload["delta"] as? String {
                textDeltaCount += 1
                if firstTextDeltaAt == nil {
                    firstTextDeltaAt = Date()
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice",
                        direction: "incoming",
                        event: "openai.streaming.first_text_delta",
                        fields: [
                            "model": model,
                            "transport": "sse",
                            "streamingMethod": "URLSession.bytes",
                            "firstTokenLatencyMs": Self.elapsedMilliseconds(from: startTime, to: firstTextDeltaAt!),
                            "connectionToFirstTokenMs": Self.elapsedMilliseconds(from: connectedAt, to: firstTextDeltaAt!),
                            "chunkLength": textChunk.count
                        ]
                    )
                }
                accumulatedResponseText += textChunk
                let currentAccumulatedText = accumulatedResponseText
                await MainActor.run {
                    onTextChunk(currentAccumulatedText)
                }
            } else if eventType == "response.output_text.done",
                      accumulatedResponseText.isEmpty,
                      let text = eventPayload["text"] as? String {
                accumulatedResponseText = text
                await MainActor.run {
                    onTextChunk(text)
                }
            } else if eventType == "error" {
                let message = Self.extractErrorMessage(from: eventPayload)
                throw NSError(
                    domain: "OpenAIAPI",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        }

        guard !accumulatedResponseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "OpenAIAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI streaming returned an empty response."]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: "openai.streaming.response",
            fields: [
                "model": model,
                "duration": duration,
                "durationMs": Self.elapsedMilliseconds(from: startTime, to: Date()),
                "textDeltaCount": textDeltaCount,
                "firstTokenLatencyMs": firstTextDeltaAt.map { Self.elapsedMilliseconds(from: startTime, to: $0) } ?? -1,
                "transport": "sse",
                "streamingMethod": "URLSession.bytes",
                "text": accumulatedResponseText
            ]
        )
        return (text: accumulatedResponseText, duration: duration)
    }

    private static func extractOutputText(from json: [String: Any]) -> String {
        if let outputText = json["output_text"] as? String {
            return outputText
        }

        guard let outputItems = json["output"] as? [[String: Any]] else {
            return ""
        }

        var textParts: [String] = []
        for outputItem in outputItems {
            guard let contentItems = outputItem["content"] as? [[String: Any]] else { continue }
            for contentItem in contentItems {
                if let text = contentItem["text"] as? String {
                    textParts.append(text)
                }
            }
        }

        return textParts.joined()
    }

    private func makeResponsesBody(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        stream: Bool
    ) -> [String: Any] {
        var input: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            input.append([
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": userPlaceholder
                ]]
            ])
            input.append([
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": assistantResponse
                ]]
            ])
        }

        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "input_text",
                "text": image.label
            ])
            contentBlocks.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(image.data.base64EncodedString())"
            ])
        }
        contentBlocks.append([
            "type": "input_text",
            "text": userPrompt
        ])

        return [
            "model": model,
            "instructions": systemPrompt,
            "max_output_tokens": maxOutputTokens,
            "stream": stream,
            "input": input + [[
                "role": "user",
                "content": contentBlocks
            ]]
        ]
    }

    private static func extractErrorMessage(from eventPayload: [String: Any]) -> String {
        if let message = eventPayload["message"] as? String {
            return message
        }
        if let error = eventPayload["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return "OpenAI streaming returned an error event."
    }

    private static func elapsedMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }
}
