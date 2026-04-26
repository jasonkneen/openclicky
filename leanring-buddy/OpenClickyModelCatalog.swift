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
    static let defaultVoiceResponseModelID = "claude-sonnet-4-6"
    static let defaultComputerUseModelID = "claude-sonnet-4-6"
    static let defaultCodexActionsModelID = "gpt-5.4"

    static let voiceResponseModels: [OpenClickyModelOption] = [
        OpenClickyModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "claude-opus-4-6", label: "Claude Opus", provider: .anthropic, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "claude-haiku-4-5", label: "Claude Haiku", provider: .anthropic, maxOutputTokens: 64_000),
        OpenClickyModelOption(id: "gpt-5.5", label: "GPT-5.5", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.4", label: "GPT-5.4", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", provider: .openAI, maxOutputTokens: 128_000),
        OpenClickyModelOption(id: "gpt-5.2", label: "GPT-5.2", provider: .openAI, maxOutputTokens: 128_000)
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
