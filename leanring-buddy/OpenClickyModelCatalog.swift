import Foundation

enum OpenClickyModelProvider: String, Equatable {
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

struct OpenClickyModelOption: Identifiable, Equatable {
    let id: String
    let label: String
    let provider: OpenClickyModelProvider
}

enum OpenClickyModelCatalog {
    static let defaultVoiceResponseModelID = "claude-sonnet-4-6"
    static let defaultComputerUseModelID = "claude-sonnet-4-6"
    static let defaultCodexActionsModelID = "gpt-5.4"

    static let voiceResponseModels: [OpenClickyModelOption] = [
        OpenClickyModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet", provider: .anthropic),
        OpenClickyModelOption(id: "claude-opus-4-6", label: "Claude Opus", provider: .anthropic),
        OpenClickyModelOption(id: "claude-haiku-4-5", label: "Claude Haiku", provider: .anthropic),
        OpenClickyModelOption(id: "gpt-5.5", label: "GPT-5.5", provider: .openAI),
        OpenClickyModelOption(id: "gpt-5.4", label: "GPT-5.4", provider: .openAI),
        OpenClickyModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", provider: .openAI),
        OpenClickyModelOption(id: "gpt-5.2", label: "GPT-5.2", provider: .openAI)
    ]

    static let computerUseModels: [OpenClickyModelOption] = [
        OpenClickyModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet", provider: .anthropic),
        OpenClickyModelOption(id: "claude-opus-4-6", label: "Claude Opus", provider: .anthropic),
        OpenClickyModelOption(id: "gpt-5.5", label: "GPT-5.5", provider: .codex),
        OpenClickyModelOption(id: "gpt-5.4", label: "GPT-5.4", provider: .codex),
        OpenClickyModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", provider: .codex),
        OpenClickyModelOption(id: "gpt-5.2", label: "GPT-5.2", provider: .codex)
    ]

    static let codexActionsModels: [OpenClickyModelOption] = [
        OpenClickyModelOption(id: "gpt-5.5", label: "GPT-5.5", provider: .openAI),
        OpenClickyModelOption(id: "gpt-5.4", label: "GPT-5.4", provider: .openAI),
        OpenClickyModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", provider: .openAI),
        OpenClickyModelOption(id: "gpt-5.3-codex", label: "GPT-5.3 Codex", provider: .openAI),
        OpenClickyModelOption(id: "gpt-5.2-codex", label: "GPT-5.2 Codex", provider: .openAI),
        OpenClickyModelOption(id: "gpt-5.2", label: "GPT-5.2", provider: .openAI)
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
