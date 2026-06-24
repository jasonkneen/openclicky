import Foundation

nonisolated enum OpenClickyModelProvider: String, Equatable {
    case anthropic
    case openAI
    case codex
    case deepgram
    case cartesia
    case localOpenAICompatible
    case appleFoundation

    var displayName: String {
        switch self {
        case .anthropic:
            return "Anthropic"
        case .openAI:
            return "OpenAI"
        case .codex:
            return "Codex"
        case .deepgram:
            return "Deepgram"
        case .cartesia:
            return "Cartesia"
        case .localOpenAICompatible:
            return "Local (OpenAI-compatible)"
        case .appleFoundation:
            return "Apple On-Device"
        }
    }

    /// True for providers that run on the user's machine (no billed cloud call).
    var isLocal: Bool { self == .localOpenAICompatible || self == .appleFoundation }
}

nonisolated struct OpenClickyModelOption: Identifiable, Equatable {
    let id: String
    let label: String
    let provider: OpenClickyModelProvider
    /// Published maximum generated output tokens for this model.
    /// For Anthropic this maps to `max_tokens`; for OpenAI Responses this maps to `max_output_tokens`.
    ///
    /// Voice responses must not carry a short-form cap here: the prompt
    /// already asks for concise spoken replies by default, but if the user
    /// asks for a deeper answer the TTS pipeline should be allowed to keep
    /// generating rather than truncating at an artificial "spoken" budget.
    let maxOutputTokens: Int
}

nonisolated enum OpenClickyModelCatalog {
    static let defaultSpeechModelID = "gpt-realtime-2"
    /// Fast conversational responder. Used for the always-on voice loop —
    /// hears the user, routes direct computer-use locally, and delegates
    /// background work to the configured Codex model.
    static let defaultVoiceResponseModelID = defaultSpeechModelID
    static let defaultCodexActionsModelID = "gpt-5.4"
    /// Text/vision model used when a live speech model needs screenshots,
    /// attachments, or Codex fallback. Realtime IDs stay on the audio path.
    static let defaultVoiceAnalysisModelID = defaultCodexActionsModelID
    /// Heavier model used when the voice responder delegates a coding/agent task.
    /// Coding work goes here; the voice path stays on the fast model.
    static let defaultDelegationModelID = "claude-sonnet-4-6"
    static let defaultComputerUseModelID = defaultCodexActionsModelID
    static let cartesiaVoiceAgentModelID = "cartesia-voice-agent"

    // MARK: - Local models

    /// Fixed id for Apple's on-device Foundation model.
    static let appleFoundationModelID = "apple-foundation"
    static let appleFoundationLabel = "Apple On-Device"
    /// Prefix used to namespace dynamic, user-configured local model ids
    /// (e.g. `local:qwen2.5:7b`) so they survive persistence in the same
    /// `selectedVoiceResponseModel` string the cloud models use.
    static let localModelIDPrefix = "local:"

    static func isLocalModelID(_ id: String) -> Bool {
        id == appleFoundationModelID || id.hasPrefix(localModelIDPrefix)
    }

    /// Synthesizes an option for a namespaced local id; returns nil for cloud ids.
    static func localModelOption(forID id: String) -> OpenClickyModelOption? {
        if id == appleFoundationModelID {
            return OpenClickyModelOption(id: id, label: appleFoundationLabel, provider: .appleFoundation, maxOutputTokens: 4_096)
        }
        if id.hasPrefix(localModelIDPrefix) {
            let raw = String(id.dropFirst(localModelIDPrefix.count))
            return OpenClickyModelOption(id: id, label: raw, provider: .localOpenAICompatible, maxOutputTokens: LocalModelSettingsStore.maxOutputTokens)
        }
        return nil
    }

    /// Strips the `local:` prefix to recover the raw model id the server expects.
    static func rawLocalModelID(forID id: String) -> String {
        id.hasPrefix(localModelIDPrefix) ? String(id.dropFirst(localModelIDPrefix.count)) : id
    }

    /// Resolves the delegation model — falls back to a sensible coder
    /// when the user hasn't picked one explicitly.
    static func delegationModel(withID modelID: String?) -> OpenClickyModelOption {
        if let modelID, let match = voiceResponseModels.first(where: { $0.id == modelID }) {
            return match
        }
        return voiceResponseModel(withID: defaultDelegationModelID)
    }

    static let voiceResponseModels: [OpenClickyModelOption] = [
        // Voice turns should still be concise by prompt, but never by a
        // hard generation ceiling. Long spoken explanations can stream
        // sentence-by-sentence through TTS without being cut off.
        OpenClickyModelOption(id: "claude-haiku-4-5", label: "Claude Haiku", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-opus-4-6", label: "Claude Opus", provider: .anthropic, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.5", label: "GPT-5.5", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.4", label: "GPT-5.4", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.2", label: "GPT-5.2", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: cartesiaVoiceAgentModelID, label: "Cartesia Voice Agent", provider: .cartesia, maxOutputTokens: 128_000)
    ]

    static let speechModels: [OpenClickyModelOption] = [
        // Realtime models are speech-to-speech response models. When one
        // is selected as the response voice model, it owns both the spoken
        // reply generation and the audio playback path instead of chaining
        // a separate text model into TTS.
        OpenClickyModelOption(id: "gpt-realtime-2", label: "GPT Realtime 2", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-realtime-1.5", label: "GPT Realtime 1.5", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "deepgram-voice-agent", label: "Deepgram Voice Agent", provider: .deepgram, maxOutputTokens: 128_000)
    ]

    static let responseVoiceModels: [OpenClickyModelOption] = speechModels + voiceResponseModels

    static let computerUseModels: [OpenClickyModelOption] = [
        OpenClickyModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-opus-4-6", label: "Claude Opus", provider: .anthropic, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-realtime-2", label: "GPT Realtime 2", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.5", label: "GPT-5.5", provider: .codex, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.4", label: "GPT-5.4", provider: .codex, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", provider: .codex, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.2", label: "GPT-5.2", provider: .codex, maxOutputTokens: 128_000)
    ]

    static let codexActionsModels: [OpenClickyModelOption] = [
        OpenClickyModelOption(id: "gpt-5.5", label: "GPT-5.5", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.4", label: "GPT-5.4", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.3-codex", label: "GPT-5.3 Codex", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.2-codex", label: "GPT-5.2 Codex", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.2", label: "GPT-5.2", provider: .openAI, maxOutputTokens: 128_000)
    ]
    // Local MLX models are intentionally NOT offered for Agent Mode: the local
    // endpoint (mlx_lm at 127.0.0.1:32124) only speaks /v1/chat/completions,
    // but Codex requires the Responses API, so routing agents there 404s on
    // /v1/responses. Keep agents on real cloud providers.

    static func voiceResponseModel(withID modelID: String) -> OpenClickyModelOption {
        if let local = localModelOption(forID: modelID) { return local }
        return responseVoiceModels.first { $0.id == modelID } ?? voiceResponseModels[0]
    }

    static func voiceAnalysisModel(withID modelID: String?) -> OpenClickyModelOption {
        if let modelID, let local = localModelOption(forID: modelID) { return local }
        if let modelID,
           !isSpeechModelID(modelID),
           let match = voiceResponseModels.first(where: { $0.id == modelID }) {
            return match
        }
        if let match = voiceResponseModels.first(where: { $0.id == defaultVoiceAnalysisModelID }) {
            return match
        }
        return voiceResponseModels[0]
    }

    static func codexVoiceSessionModel(withID modelID: String?) -> OpenClickyModelOption {
        if let modelID,
           !isSpeechModelID(modelID),
           let match = codexActionsModels.first(where: { $0.id == modelID }) {
            return match
        }

        let analysisModel = voiceAnalysisModel(withID: modelID)
        if let match = codexActionsModels.first(where: { $0.id == analysisModel.id }) {
            return match
        }

        return codexActionsModels.first { $0.id == defaultCodexActionsModelID } ?? codexActionsModels[0]
    }

    static func isSpeechModelID(_ modelID: String) -> Bool {
        speechModels.contains { $0.id == modelID }
    }

    static func speechModel(withID modelID: String?) -> OpenClickyModelOption {
        if let modelID, let match = speechModels.first(where: { $0.id == modelID }) {
            return match
        }
        return speechModels.first { $0.id == defaultSpeechModelID } ?? speechModels[0]
    }

    static func computerUseModel(withID modelID: String) -> OpenClickyModelOption {
        return computerUseModels.first { $0.id == modelID } ?? computerUseModels[0]
    }

    static func codexActionsModel(withID modelID: String) -> OpenClickyModelOption {
        codexActionsModels.first { $0.id == modelID } ?? codexActionsModels[0]
    }
}
