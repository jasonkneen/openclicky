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
    private let session: URLSession

    init(apiKey: String?, model: String = OpenClickyModelCatalog.defaultVoiceResponseModelID) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiURL = URL(string: "https://api.openai.com/v1/responses")!
        self.model = model

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
        input.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "instructions": systemPrompt,
            "max_output_tokens": 1024,
            "input": input
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
}
