import Foundation

nonisolated enum OpenClickyModelProvider: String, Equatable {
    case apple
    case anthropic
    case openAI
    case codex
    case deepgram

    var displayName: String {
        switch self {
        case .apple:
            return "Apple"
        case .anthropic:
            return "Anthropic"
        case .openAI:
            return "OpenAI"
        case .codex:
            return "Codex"
        case .deepgram:
            return "Deepgram"
        }
    }

    /// Coarse family used by the bubble / notch provider selector.
    /// Realtime speech and Deepgram stay outside this three-way switch.
    var voiceBackendFamily: OpenClickyVoiceBackendFamily? {
        switch self {
        case .apple:
            return .apple
        case .anthropic:
            return .claude
        case .codex:
            return .codex
        case .openAI:
            return .codex
        case .deepgram:
            return nil
        }
    }
}

/// Terminal-first voice backend family: Apple on-device, local Codex, or Claude Agent SDK.
nonisolated enum OpenClickyVoiceBackendFamily: String, CaseIterable, Equatable, Sendable {
    case apple
    case codex
    case claude

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var shortLabel: String {
        switch self {
        case .apple: return "A"
        case .codex: return "X"
        case .claude: return "C"
        }
    }

    /// Default catalog model id when the user picks this family in the bubble selector.
    var defaultModelID: String {
        switch self {
        case .apple:
            return OpenClickyModelCatalog.appleFoundationModelID
        case .codex:
            return OpenClickyModelCatalog.defaultCodexActionsModelID
        case .claude:
            return "claude-haiku-4-5"
        }
    }
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
    static let defaultSpeechModelID = "gpt-realtime-2.1-mini"
    /// Fast conversational responder. Used for the always-on voice loop —
    /// hears the user, routes direct computer-use locally, and delegates
    /// background work to the configured Codex model.
    static let defaultVoiceResponseModelID = defaultSpeechModelID
    static let defaultCodexActionsModelID = "gpt-5.5"
    /// On-device Apple Foundation Models (macOS 26+ / Apple Intelligence).
    static let appleFoundationModelID = "apple-foundation"
    /// Text/vision model used when a live speech model needs screenshots,
    /// attachments, or Codex fallback. Realtime IDs stay on the audio path.
    static let defaultVoiceAnalysisModelID = defaultCodexActionsModelID
    /// Heavier model used when the voice responder delegates a coding/agent task.
    /// Coding work goes here; the voice path stays on the fast model.
    static let defaultDelegationModelID = "claude-sonnet-4-6"
    static let defaultComputerUseModelID = defaultCodexActionsModelID

    /// Resolves the delegation model — falls back to a sensible coder
    /// when the user hasn't picked one explicitly.
    static func delegationModel(withID modelID: String?) -> OpenClickyModelOption {
        if let modelID {
            let resolved = normalizedModelID(modelID)
            if let match = voiceResponseModels.first(where: { $0.id == resolved }) {
                return match
            }
        }
        return voiceResponseModel(withID: defaultDelegationModelID)
    }

    static let voiceResponseModels: [OpenClickyModelOption] = [
        // Voice turns should still be concise by prompt, but never by a
        // hard generation ceiling. Long spoken explanations can stream
        // sentence-by-sentence through TTS without being cut off.
        OpenClickyModelOption(id: appleFoundationModelID, label: "Apple On-Device", provider: .apple, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-haiku-4-5", label: "Claude Haiku", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-opus-4-6", label: "Claude Opus", provider: .anthropic, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.5", label: "GPT-5.5", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.4", label: "GPT-5.4", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.2", label: "GPT-5.2", provider: .openAI, maxOutputTokens: 128_000)
    ]

    static let speechModels: [OpenClickyModelOption] = [
        // Realtime models are speech-to-speech response models. When one
        // is selected as the response voice model, it owns both the spoken
        // reply generation and the audio playback path instead of chaining
        // a separate text model into TTS.
        // Default stays on mini for lower latency and cost; full 2.1 is
        // available when stronger realtime reasoning is worth the spend.
        OpenClickyModelOption(id: "gpt-realtime-2.1-mini", label: "GPT Realtime 2.1 mini", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-realtime-2.1", label: "GPT Realtime 2.1", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-realtime-1.5", label: "GPT Realtime 1.5", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "deepgram-voice-agent", label: "Deepgram Voice Agent", provider: .deepgram, maxOutputTokens: 128_000)
    ]

    static let responseVoiceModels: [OpenClickyModelOption] = speechModels + voiceResponseModels

    static let computerUseModels: [OpenClickyModelOption] = [
        OpenClickyModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-opus-4-6", label: "Claude Opus", provider: .anthropic, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-realtime-2.1-mini", label: "GPT Realtime 2.1 mini", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-realtime-2.1", label: "GPT Realtime 2.1", provider: .openAI, maxOutputTokens: 128_000),
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

    /// Maps retired / alias model IDs onto the currently offered catalog IDs.
    /// Keep legacy `gpt-realtime-2` pointed at the new mini default so existing
    /// installs do not fall through to a text model.
    static func normalizedModelID(_ modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultVoiceResponseModelID }
        switch trimmed.lowercased() {
        case "gpt-realtime-2", "gpt-realtime-2.0", "gpt-realtime-2-mini":
            return defaultSpeechModelID
        default:
            return trimmed
        }
    }

    static func voiceResponseModel(withID modelID: String) -> OpenClickyModelOption {
        let resolved = normalizedModelID(modelID)
        if let match = responseVoiceModels.first(where: { $0.id == resolved }) {
            return match
        }
        // Unknown IDs reset to the product default (speech-to-speech), not the
        // first text model in the list (which used to silently become Haiku).
        return responseVoiceModels.first { $0.id == defaultVoiceResponseModelID }
            ?? speechModels.first
            ?? voiceResponseModels[0]
    }

    static func voiceAnalysisModel(withID modelID: String?) -> OpenClickyModelOption {
        if let modelID {
            let resolved = normalizedModelID(modelID)
            if !isSpeechModelID(resolved),
               let match = voiceResponseModels.first(where: { $0.id == resolved }) {
                return match
            }
        }
        if let match = voiceResponseModels.first(where: { $0.id == defaultVoiceAnalysisModelID }) {
            return match
        }
        return voiceResponseModels[0]
    }

    static func codexVoiceSessionModel(withID modelID: String?) -> OpenClickyModelOption {
        if let modelID {
            let resolved = normalizedModelID(modelID)
            if !isSpeechModelID(resolved),
               let match = codexActionsModels.first(where: { $0.id == resolved }) {
                return match
            }
        }

        let analysisModel = voiceAnalysisModel(withID: modelID)
        if let match = codexActionsModels.first(where: { $0.id == analysisModel.id }) {
            return match
        }

        return codexActionsModels.first { $0.id == defaultCodexActionsModelID } ?? codexActionsModels[0]
    }

    static func isSpeechModelID(_ modelID: String) -> Bool {
        let resolved = normalizedModelID(modelID)
        return speechModels.contains { $0.id == resolved }
    }

    static func speechModel(withID modelID: String?) -> OpenClickyModelOption {
        if let modelID {
            let resolved = normalizedModelID(modelID)
            if let match = speechModels.first(where: { $0.id == resolved }) {
                return match
            }
        }
        return speechModels.first { $0.id == defaultSpeechModelID } ?? speechModels[0]
    }

    static func computerUseModel(withID modelID: String) -> OpenClickyModelOption {
        let resolved = normalizedModelID(modelID)
        return computerUseModels.first { $0.id == resolved }
            ?? computerUseModels.first { $0.id == defaultComputerUseModelID }
            ?? computerUseModels[0]
    }

    static func codexActionsModel(withID modelID: String) -> OpenClickyModelOption {
        let resolved = normalizedModelID(modelID)
        return codexActionsModels.first { $0.id == resolved }
            ?? codexActionsModels.first { $0.id == defaultCodexActionsModelID }
            ?? codexActionsModels[0]
    }
}
