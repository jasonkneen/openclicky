//
//  AppleFoundationModelsVoiceClient.swift
//  cursor-buddy
//
//  On-device voice responses via Apple Foundation Models (Apple Intelligence).
//  Free local inference — no API key. Text-only; screenshots are described
//  as "not available to this model" rather than uploaded.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
enum AppleFoundationModelsVoiceClient {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Generate a spoken-style reply. Emits a single full-text chunk when complete
    /// (FoundationModels does not expose the same SSE delta path as cloud models).
    static func analyzeVoiceResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                throw NSError(
                    domain: "AppleFoundationModelsVoiceClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Apple Foundation Models are not available on this Mac."]
                )
            }

            var instructions = systemPrompt
            if !images.isEmpty {
                instructions += """


                Note: the user attached \(images.count) screenshot(s) (\(images.map(\.label).joined(separator: ", "))), but this on-device model cannot see images. Answer from the transcript and conversation only; if vision is required, say so briefly.
                """
            }

            let session = LanguageModelSession(instructions: instructions)

            var prompt = ""
            for turn in conversationHistory.suffix(6) {
                prompt += "User: \(turn.userPlaceholder)\nAssistant: \(turn.assistantResponse)\n\n"
            }
            prompt += userPrompt

            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw NSError(
                    domain: "AppleFoundationModelsVoiceClient",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Apple on-device model returned an empty response."]
                )
            }
            onTextChunk(text)
            return text
        }
        #endif

        throw NSError(
            domain: "AppleFoundationModelsVoiceClient",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey: "Apple Foundation Models require macOS 26 with Apple Intelligence."]
        )
    }
}
