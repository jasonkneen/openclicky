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
        #expect(rendered.contains("model_provider = \"openclicky\""))
        #expect(ClickyCodexConfigTemplate.defaultModelProviderID == "openclicky")
        #expect(rendered.contains("base_url = \"https://api.openai.com/v1\""))
        #expect(rendered.contains("name = \"OpenClicky\""))
        #expect(rendered.contains("wire_api = \"responses\""))
        #expect(rendered.contains("multi_agent = true"))
        #expect(rendered.contains("model_instructions_file = \"OpenClickyModelInstructions.md\""))
        #expect(rendered.contains("bundled_skills_dir = \"OpenClickyBundledSkills\""))
        #expect(rendered.contains("enabled = true"))
        #expect(rendered.contains("https://developers.openai.com/mcp"))
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
