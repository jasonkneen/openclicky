import Foundation

struct ClickyCodexConfigTemplate: Equatable {
    static let defaultModelProviderID = "openclicky"

    var model: String
    var reasoningEffort: String
    var workerBaseURL: URL
    var modelInstructionsFileName: String
    var bundledSkillsDirectoryName: String
    var includeOpenAIDeveloperDocsMCP: Bool

    init(
        model: String = OpenClickyModelCatalog.defaultCodexActionsModelID,
        reasoningEffort: String = "medium",
        workerBaseURL: URL = ClickyCodexBackend.configuredWorkerBaseURL(),
        modelInstructionsFileName: String = "OpenClickyModelInstructions.md",
        bundledSkillsDirectoryName: String = "OpenClickyBundledSkills",
        includeOpenAIDeveloperDocsMCP: Bool = true
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.workerBaseURL = workerBaseURL
        self.modelInstructionsFileName = modelInstructionsFileName
        self.bundledSkillsDirectoryName = bundledSkillsDirectoryName
        self.includeOpenAIDeveloperDocsMCP = includeOpenAIDeveloperDocsMCP
    }

    var openAICompatibleEndpoint: URL {
        if workerBaseURL.lastPathComponent == "v1" {
            return workerBaseURL
        }
        return workerBaseURL.appendingPathComponent("v1", isDirectory: false)
    }

    func render() -> String {
        var lines: [String] = [
            "model = \"\(escape(model))\"",
            "model_reasoning_effort = \"\(escape(reasoningEffort))\"",
            "model_provider = \"\(Self.defaultModelProviderID)\"",
            "preferred_auth_method = \"apikey\"",
            "approval_policy = \"never\"",
            "sandbox_mode = \"danger-full-access\"",
            "personality = \"friendly\"",
            "cli_auth_credentials_store = \"file\"",
            "history.persistence = \"save-all\"",
            "",
            "[analytics]",
            "enabled = false",
            "",
            "[model_providers.\(Self.defaultModelProviderID)]",
            "name = \"OpenClicky\"",
            "env_key = \"OPENAI_API_KEY\"",
            "base_url = \"\(escape(openAICompatibleEndpoint.absoluteString))\"",
            "wire_api = \"responses\"",
            "trust_level = \"trusted\"",
            "hide_full_access_warning = true",
            "fast_mode = true",
            "multi_agent = true"
        ]

        if includeOpenAIDeveloperDocsMCP {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.openaiDeveloperDocs]",
                "url = \"https://developers.openai.com/mcp\""
            ])
        }

        lines.append(contentsOf: [
            "",
            "[[skills.config]]",
            "model_instructions_file = \"\(escape(modelInstructionsFileName))\"",
            "bundled_skills_dir = \"\(escape(bundledSkillsDirectoryName))\"",
            "enabled = true"
        ])

        return lines.joined(separator: "\n") + "\n"
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum ClickyCodexBackend {
    static let defaultOpenAIBaseURL = URL(string: "https://api.openai.com/v1")!

    static func configuredWorkerBaseURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["CLICKY_AGENT_BASE_URL"],
           let url = URL(string: raw),
           url.scheme != nil {
            return url
        }

        if let raw = UserDefaults.standard.string(forKey: "clickyAgentBaseURL"),
           let url = URL(string: raw),
           url.scheme != nil {
            return url
        }

        return defaultOpenAIBaseURL
    }
}
