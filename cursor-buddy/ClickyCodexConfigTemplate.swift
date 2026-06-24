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
    var includeComposioConnectMCP: Bool
    var includeOpenClickyControlMCP: Bool
    var cuaDriverMCPCommand: String?
    var freeSpeechMCPCommand: String?
    var preferAPIKeyAuthForDefaultOpenAI: Bool

    init(
        model: String = OpenClickyModelCatalog.defaultCodexActionsModelID,
        reasoningEffort: String = "medium",
        workerBaseURL: URL = ClickyCodexBackend.configuredWorkerBaseURL(),
        modelInstructionsFileName: String = "OpenClickyModelInstructions.md",
        bundledSkillsDirectoryName: String = "OpenClickyBundledSkills",
        learnedSkillsDirectoryName: String = "OpenClickyLearnedSkills",
        includeOpenAIDeveloperDocsMCP: Bool = false,
        includeComposioConnectMCP: Bool = false,
        includeOpenClickyControlMCP: Bool = false,
        cuaDriverMCPCommand: String? = nil,
        freeSpeechMCPCommand: String? = nil,
        preferAPIKeyAuthForDefaultOpenAI: Bool = false
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.workerBaseURL = workerBaseURL
        self.modelInstructionsFileName = modelInstructionsFileName
        self.bundledSkillsDirectoryName = bundledSkillsDirectoryName
        self.learnedSkillsDirectoryName = learnedSkillsDirectoryName
        self.includeOpenAIDeveloperDocsMCP = includeOpenAIDeveloperDocsMCP
        self.includeComposioConnectMCP = includeComposioConnectMCP
        self.includeOpenClickyControlMCP = includeOpenClickyControlMCP
        self.cuaDriverMCPCommand = cuaDriverMCPCommand
        self.freeSpeechMCPCommand = freeSpeechMCPCommand
        self.preferAPIKeyAuthForDefaultOpenAI = preferAPIKeyAuthForDefaultOpenAI
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
            // Local OpenAI-compatible servers serve /chat/completions, not the
            // proprietary Responses API; pick the wire format accordingly.
            let wireAPI = ClickyCodexBackend.isLocalBaseURL(workerBaseURL) ? "chat" : "responses"
            lines.append(contentsOf: [
                "",
                "[model_providers.\(Self.customModelProviderID)]",
                "name = \"OpenClicky\"",
                "env_key = \"OPENAI_API_KEY\"",
                "base_url = \"\(escape(openAICompatibleEndpoint.absoluteString))\"",
                "wire_api = \"\(wireAPI)\"",
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

        if includeComposioConnectMCP {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.composio]",
                "url = \"https://connect.composio.dev/mcp\""
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

        if includeOpenClickyControlMCP {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.openClickyControl]",
                "url = \"http://127.0.0.1:32123/mcp\"",
                "bearer_token_env_var = \"OPENCLICKY_BRIDGE_TOKEN\""
            ])
        }

        if let freeSpeechMCPCommand = normalizedOptionalString(freeSpeechMCPCommand) {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.freeSpeech]",
                "command = \"\(escape(freeSpeechMCPCommand))\""
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
        guard ClickyCodexBackend.isDefaultOpenAIBaseURL(workerBaseURL) else { return "apikey" }
        return preferAPIKeyAuthForDefaultOpenAI ? "apikey" : "chatgpt"
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
            // M19: TOML basic strings cannot contain raw newlines or control
            // chars (U+0000–U+001F); leaving them in made the generated
            // config.toml unparseable on bad input. Replace newlines with a
            // space and strip all other control characters.
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .filter { (" \t".contains($0)) || ($0.unicodeScalars.allSatisfy { $0.value >= 0x20 }) }
    }
}

nonisolated enum CuaDriverMCPConfiguration {
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
    static let openClickyLocalModelBaseURL = URL(string: "http://127.0.0.1:32124")!

    static func configuredWorkerBaseURL() -> URL {
        // Never route Codex agents at the local MLX endpoint: mlx_lm only serves
        // /v1/chat/completions, while Codex requires the Responses API, so that
        // endpoint 404s on /v1/responses. Ignore it wherever it is configured.
        if let raw = ProcessInfo.processInfo.environment["CLICKY_AGENT_BASE_URL"],
           let url = validatedWorkerBaseURL(raw),
           !isOpenClickyLocalModelBaseURL(url) {
            return url
        }

        if let raw = UserDefaults.standard.string(forKey: "clickyAgentBaseURL"),
           let url = validatedWorkerBaseURL(raw),
           !isOpenClickyLocalModelBaseURL(url) {
            return url
        }

        return defaultOpenAIBaseURL
    }

    static func validatedWorkerBaseURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = components.url
        else {
            return nil
        }
        // M15: reject http:// for non-loopback hosts in code (don't lean on ATS).
        // A remote http endpoint would send the OpenAI key over plaintext.
        if scheme == "http", host != "127.0.0.1", host != "localhost" {
            return nil
        }
        return url
    }

    static func isDefaultOpenAIBaseURL(_ url: URL) -> Bool {
        normalizedBaseURL(url) == normalizedBaseURL(defaultOpenAIBaseURL)
    }

    static func isOpenClickyLocalModelBaseURL(_ url: URL) -> Bool {
        normalizedBaseURL(url) == normalizedBaseURL(openClickyLocalModelBaseURL)
    }

    /// True when the endpoint is a local model server (Ollama / LM Studio /
    /// llama.cpp / vLLM). Local servers speak `/chat/completions`, so the
    /// generated Codex provider must use `wire_api = "chat"`, not "responses".
    static func isLocalBaseURL(_ url: URL) -> Bool {
        if let host = url.host?.lowercased() {
            if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" {
                return true
            }
            if host.hasSuffix(".local") {
                return true
            }
        }
        // Common local model server ports as a fallback signal.
        if let port = url.port, port == 11434 || port == 1234 || port == 8080 {
            return true
        }
        return false
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
