import Foundation

struct ClickyCodexConfigTemplate: Equatable {
    static let defaultModelProviderID = "openai"
    static let customModelProviderID = "openclicky"

    var model: String
    var reasoningEffort: String
    var workerBaseURL: URL
    var modelInstructionsFileName: String
    var bundledSkillsDirectoryName: String
    var learnedSkillsDirectoryName: String
    var includeOpenAIDeveloperDocsMCP: Bool
    var cuaDriverMCPCommand: String?

    init(
        model: String = OpenClickyModelCatalog.defaultCodexActionsModelID,
        reasoningEffort: String = "medium",
        workerBaseURL: URL = ClickyCodexBackend.configuredWorkerBaseURL(),
        modelInstructionsFileName: String = "OpenClickyModelInstructions.md",
        bundledSkillsDirectoryName: String = "OpenClickyBundledSkills",
        learnedSkillsDirectoryName: String = "OpenClickyLearnedSkills",
        includeOpenAIDeveloperDocsMCP: Bool = true,
        cuaDriverMCPCommand: String? = CuaDriverMCPConfiguration.resolvedCommandPath()
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.workerBaseURL = workerBaseURL
        self.modelInstructionsFileName = modelInstructionsFileName
        self.bundledSkillsDirectoryName = bundledSkillsDirectoryName
        self.learnedSkillsDirectoryName = learnedSkillsDirectoryName
        self.includeOpenAIDeveloperDocsMCP = includeOpenAIDeveloperDocsMCP
        self.cuaDriverMCPCommand = cuaDriverMCPCommand
    }

    var openAICompatibleEndpoint: URL {
        if workerBaseURL.lastPathComponent == "v1" {
            return workerBaseURL
        }
        return workerBaseURL.appendingPathComponent("v1", isDirectory: false)
    }

    var modelProviderID: String {
        ClickyCodexBackend.isDefaultOpenAIBaseURL(workerBaseURL) ? Self.defaultModelProviderID : Self.customModelProviderID
    }

    func render() -> String {
        var lines: [String] = [
            "model = \"\(escape(model))\"",
            "model_reasoning_effort = \"\(escape(reasoningEffort))\"",
            "model_provider = \"\(modelProviderID)\"",
            "preferred_auth_method = \"\(preferredAuthMethod)\"",
            "approval_policy = \"never\"",
            "sandbox_mode = \"danger-full-access\"",
            "personality = \"friendly\"",
            "cli_auth_credentials_store = \"file\"",
            "history.persistence = \"save-all\"",
            "",
            "[analytics]",
            "enabled = false"
        ]

        if !ClickyCodexBackend.isDefaultOpenAIBaseURL(workerBaseURL) {
            lines.append(contentsOf: [
                "",
                "[model_providers.\(Self.customModelProviderID)]",
                "name = \"OpenClicky\"",
                "env_key = \"OPENAI_API_KEY\"",
                "base_url = \"\(escape(openAICompatibleEndpoint.absoluteString))\"",
                "wire_api = \"responses\"",
                "trust_level = \"trusted\"",
                "hide_full_access_warning = true",
                "fast_mode = true",
                "multi_agent = true"
            ])
        }

        if includeOpenAIDeveloperDocsMCP {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.openaiDeveloperDocs]",
                "url = \"https://developers.openai.com/mcp\""
            ])
        }

        if let cuaDriverMCPCommand = normalizedOptionalString(cuaDriverMCPCommand) {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.cuaDriver]",
                "command = \"\(escape(cuaDriverMCPCommand))\"",
                "args = [\"mcp\"]",
                "",
                "[mcp_servers.cuaDriver.env]",
                "CUA_DRIVER_TELEMETRY_ENABLED = \"false\"",
                "CUA_TELEMETRY_ENABLED = \"false\""
            ])
        }

        lines.append(contentsOf: [
            "",
            "[[skills.config]]",
            "model_instructions_file = \"\(escape(modelInstructionsFileName))\"",
            "bundled_skills_dir = \"\(escape(bundledSkillsDirectoryName))\"",
            "enabled = true",
            "",
            "[[skills.config]]",
            "model_instructions_file = \"\(escape(modelInstructionsFileName))\"",
            "bundled_skills_dir = \"\(escape(learnedSkillsDirectoryName))\"",
            "enabled = true"
        ])

        return lines.joined(separator: "\n") + "\n"
    }

    private var preferredAuthMethod: String {
        ClickyCodexBackend.isDefaultOpenAIBaseURL(workerBaseURL) ? "chatgpt" : "apikey"
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum CuaDriverMCPConfiguration {
    static let environmentOverrideKey = "OPENCLICKY_CUA_DRIVER_MCP_COMMAND"
    static let knownCommandPaths = [
        "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
        "/usr/local/bin/cua-driver",
        "/opt/homebrew/bin/cua-driver"
    ]

    static func resolvedCommandPath(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let override = normalized(environment[environmentOverrideKey]) {
            return override
        }

        return knownCommandPaths.first { fileManager.isExecutableFile(atPath: $0) || fileManager.fileExists(atPath: $0) }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    static func isDefaultOpenAIBaseURL(_ url: URL) -> Bool {
        normalizedBaseURL(url) == normalizedBaseURL(defaultOpenAIBaseURL)
    }

    private static func normalizedBaseURL(_ url: URL) -> String {
        var normalized = url.absoluteString
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if !normalized.hasSuffix("/v1") {
            normalized += "/v1"
        }
        return normalized.lowercased()
    }
}
