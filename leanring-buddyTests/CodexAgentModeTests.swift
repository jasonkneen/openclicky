import Foundation
import Testing
@testable import OpenClicky

struct CodexAgentModeTests {
    @Test func codexConfigRendersOpenAIResponsesContract() throws {
        let template = ClickyCodexConfigTemplate(
            model: "gpt-5.4",
            reasoningEffort: "medium",
            workerBaseURL: URL(string: "https://api.openai.com/v1")!,
            includeOpenAIDeveloperDocsMCP: true
        )

        let rendered = template.render()

        #expect(rendered.contains("model = \"gpt-5.4\""))
        #expect(rendered.contains("model_provider = \"openai\""))
        #expect(rendered.contains("preferred_auth_method = \"chatgpt\""))
        #expect(ClickyCodexConfigTemplate.defaultModelProviderID == "openai")
        #expect(!rendered.contains("[model_providers.openclicky]"))
        #expect(rendered.contains("model_instructions_file = \"OpenClickyModelInstructions.md\""))
        #expect(rendered.contains("bundled_skills_dir = \"OpenClickyBundledSkills\""))
        #expect(rendered.contains("enabled = true"))
        #expect(rendered.contains("https://developers.openai.com/mcp"))
    }

    @Test func codexConfigKeepsCustomResponsesBackendAPIKeyBackcompat() throws {
        let template = ClickyCodexConfigTemplate(
            model: "gpt-5.4",
            reasoningEffort: "medium",
            workerBaseURL: URL(string: "https://worker.example.test/openai")!,
            includeOpenAIDeveloperDocsMCP: false
        )

        let rendered = template.render()

        #expect(rendered.contains("model_provider = \"openclicky\""))
        #expect(rendered.contains("preferred_auth_method = \"apikey\""))
        #expect(rendered.contains("[model_providers.openclicky]"))
        #expect(rendered.contains("base_url = \"https://worker.example.test/openai/v1\""))
        #expect(rendered.contains("wire_api = \"responses\""))
        #expect(rendered.contains("multi_agent = true"))
    }

    @Test func codexConfigRendersExistingCuaDriverMCPServerWhenAvailable() throws {
        let template = ClickyCodexConfigTemplate(
            model: "gpt-5.5",
            reasoningEffort: "medium",
            workerBaseURL: URL(string: "https://api.openai.com/v1")!,
            includeOpenAIDeveloperDocsMCP: false,
            cuaDriverMCPCommand: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
        )

        let rendered = template.render()

        #expect(rendered.contains("[mcp_servers.cuaDriver]"))
        #expect(rendered.contains("command = \"/Applications/CuaDriver.app/Contents/MacOS/cua-driver\""))
        #expect(rendered.contains("args = [\"mcp\"]"))
        #expect(rendered.contains("[mcp_servers.cuaDriver.env]"))
        #expect(rendered.contains("CUA_DRIVER_TELEMETRY_ENABLED = \"false\""))
        #expect(rendered.contains("CUA_TELEMETRY_ENABLED = \"false\""))
    }

    @Test func codexConfigOmitsCuaDriverMCPServerWhenUnavailable() throws {
        let template = ClickyCodexConfigTemplate(
            model: "gpt-5.5",
            reasoningEffort: "medium",
            workerBaseURL: URL(string: "https://api.openai.com/v1")!,
            includeOpenAIDeveloperDocsMCP: false,
            cuaDriverMCPCommand: nil
        )

        let rendered = template.render()

        #expect(!rendered.contains("[mcp_servers.cuaDriver]"))
        #expect(!rendered.contains("CUA_DRIVER_TELEMETRY_ENABLED"))
    }

    @Test func cuaDriverMCPConfigurationPrefersExplicitOpenClickyOverride() throws {
        let command = CuaDriverMCPConfiguration.resolvedCommandPath(
            environment: [CuaDriverMCPConfiguration.environmentOverrideKey: "/tmp/custom-cua-driver"]
        )

        #expect(command == "/tmp/custom-cua-driver")
    }

    @Test func codexHomeManagerUsesOpenClickyResourceNames() throws {
        let manager = CodexHomeManager(
            fileManager: .default,
            applicationSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true),
            workerBaseURL: URL(string: "https://api.openai.com/v1")!
        )

        #expect(manager.modelInstructionsFileName == "OpenClickyModelInstructions.md")
        #expect(manager.bundledSkillsDirectoryName == "OpenClickyBundledSkills")
        #expect(manager.bundledWikiSeedDirectoryName == "OpenClickyBundledWikiSeed")
        #expect(manager.codexHomeDirectory.lastPathComponent == "CodexHome")
    }

    @Test func jsonRPCRequestEncodingMatchesCodexAppServer() throws {
        let request = CodexRPCRequest(id: 7, method: "thread/start", params: [
            "experimentalRawEvents": false,
            "persistExtendedHistory": false,
            "sessionStartSource": "startup"
        ])

        let line = try request.encodedLine()

        #expect(line.hasSuffix("\n"))
        #expect(line.contains("\"id\":7"))
        #expect(line.contains("\"method\":\"thread/start\""))
        #expect(line.contains("\"sessionStartSource\":\"startup\""))
    }

    @Test func codexInitializeRequestOptsIntoExperimentalAPIForResponsesClientMetadata() throws {
        let request = CodexProcessManager.makeInitializeRequest(clientName: "openclicky", title: "OpenClicky", version: "1.0.0")
        let params = try #require(request.params as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])

        #expect((capabilities["experimentalApi"] as? Bool) == true)
    }
}
