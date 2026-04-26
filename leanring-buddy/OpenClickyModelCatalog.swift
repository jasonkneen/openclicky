import Foundation

nonisolated enum OpenClickyModelProvider: String, Equatable {
    case anthropic
    case openAI
    case codex

    var displayName: String {
        switch self {
        case .anthropic:
            return "Anthropic"
        case .openAI:
            return "OpenAI"
        case .codex:
            return "Codex"
        }
    }
}

nonisolated struct OpenClickyModelOption: Identifiable, Equatable {
    let id: String
    let label: String
    let provider: OpenClickyModelProvider
    /// Published maximum generated output tokens for this model.
    /// For Anthropic this maps to `max_tokens`; for OpenAI Responses this maps to `max_output_tokens`.
    let maxOutputTokens: Int
}

nonisolated enum OpenClickyModelCatalog {
    /// Fast conversational responder. Used for the always-on voice loop —
    /// hears you, decides whether to delegate, narrates progress.
    /// Haiku 4.5 has ~150-250ms TTFT vs ~400-600ms for Sonnet.
    static let defaultVoiceResponseModelID = "claude-haiku-4-5"
    /// Heavier model used when the voice responder delegates a coding/agent task.
    /// Coding work goes here; the voice path stays on the fast model.
    static let defaultDelegationModelID = "claude-sonnet-4-6"
    static let defaultComputerUseModelID = "claude-sonnet-4-6"
    static let defaultCodexActionsModelID = "gpt-5.4"

    /// Resolves the delegation model — falls back to a sensible coder
    /// when the user hasn't picked one explicitly.
    static func delegationModel(withID modelID: String?) -> OpenClickyModelOption {
        if let modelID, let match = voiceResponseModels.first(where: { $0.id == modelID }) {
            return match
        }
        return voiceResponseModel(withID: defaultDelegationModelID)
    }

    static let voiceResponseModels: [OpenClickyModelOption] = [
        // Voice turns should be short, stream quickly, and hand off deep work
        // to Agent Mode. Large 64k/128k generation budgets add latency risk
        // and are unnecessary for spoken responses.
        OpenClickyModelOption(id: "claude-haiku-4-5", label: "Claude Haiku", provider: .anthropic, maxOutputTokens: 1_200),
        OpenClickyModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet", provider: .anthropic, maxOutputTokens: 1_200),
        OpenClickyModelOption(id: "claude-opus-4-6", label: "Claude Opus", provider: .anthropic, maxOutputTokens: 1_200),
        OpenClickyModelOption(id: "gpt-5.5", label: "GPT-5.5", provider: .openAI, maxOutputTokens: 1_200),
        OpenClickyModelOption(id: "gpt-5.4", label: "GPT-5.4", provider: .openAI, maxOutputTokens: 1_200),
        OpenClickyModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", provider: .openAI, maxOutputTokens: 1_200),
        OpenClickyModelOption(id: "gpt-5.2", label: "GPT-5.2", provider: .openAI, maxOutputTokens: 1_200)
    ]

    static let computerUseModels: [OpenClickyModelOption] = [
        OpenClickyModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-opus-4-6", label: "Claude Opus", provider: .anthropic, maxOutputTokens: 128_000),
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

    static func voiceResponseModel(withID modelID: String) -> OpenClickyModelOption {
        voiceResponseModels.first { $0.id == modelID } ?? voiceResponseModels[0]
    }

    static func computerUseModel(withID modelID: String) -> OpenClickyModelOption {
        computerUseModels.first { $0.id == modelID } ?? computerUseModels[0]
    }

    static func codexActionsModel(withID modelID: String) -> OpenClickyModelOption {
        codexActionsModels.first { $0.id == modelID } ?? codexActionsModels[0]
    }
}
