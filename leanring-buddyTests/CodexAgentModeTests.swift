import Foundation
import Testing
@testable import OpenClicky

@MainActor
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

    @Test func codexRuntimeVersionParsingComparesInstalledAlphaAboveOlderBundle() throws {
        let bundled = try #require(CodexRuntimeLocator.parsedVersion(from: "codex-cli 0.121.0"))
        let installed = try #require(CodexRuntimeLocator.parsedVersion(from: "codex-cli 0.125.0-alpha.3"))

        #expect(installed > bundled)
    }

    @Test func codexRPCErrorMessageUnwrapsNestedJSONErrorPayload() throws {
        let rawPayload = #"{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-5.5' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again."}}"#

        let message = try #require(CodexRPCErrorMessage.readableMessage(from: rawPayload))

        #expect(message == "The 'gpt-5.5' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again.")
        #expect(CodexAgentSession.shouldRetryWithCompatibilityFallback(message))
    }

    @Test func logReviewSetupCreatesMarkdownAndJSONLFiles() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = OpenClickyMessageLogStore(logDirectory: directory)
        try Data("# Existing review notes\n".utf8).write(to: store.agentReviewCommentsFile)
        store.ensureAgentReviewCommentsFile()

        #expect(FileManager.default.fileExists(atPath: store.agentReviewCommentsFile.path))
        #expect(FileManager.default.fileExists(atPath: store.reviewCommentsFile.path))
    }

    @MainActor @Test func voiceRoutingDetectsLocalFilesystemQuestions() throws {
        let maybeInstruction = CompanionManager.implicitFilesystemTaskInstruction(from: "what's on my desktop?")
        #expect(maybeInstruction != nil)
        guard let instruction = maybeInstruction else { return }

        #expect(instruction.contains("Inspect the relevant local files or folders"))
        #expect(instruction.contains("what's on my desktop?"))
        #expect(CompanionManager.filesystemTaskAcknowledgement(from: "list my desktop files") == "i'm checking your desktop now.")
    }

    @MainActor @Test func voiceRoutingDoesNotTreatScreenQuestionsAsFilesystemTasks() throws {
        #expect(CompanionManager.implicitFilesystemTaskInstruction(from: "what's on my screen?") == nil)
        #expect(CompanionManager.implicitFilesystemTaskInstruction(from: "why are you not speaking?") == nil)
    }

    @MainActor @Test func filesystemCapabilityRefusalEscalatesToAgentMode() throws {
        let shouldEscalate = CompanionManager.shouldEscalateVoiceResponseToAgent(
            responseText: "i don't have access to your file system directly, so i can't browse your desktop files.",
            transcript: "what files are on my desktop?"
        )

        #expect(shouldEscalate)
    }

    @MainActor @Test func implicitAgentRoutingStartsGitHubIssueTaskImmediately() throws {
        let maybeInstruction = CompanionManager.implicitAgentTaskInstruction(
            from: "Can you make an issue on GitHub to fix this?"
        )
        #expect(maybeInstruction != nil)
        guard let instruction = maybeInstruction else { return }

        #expect(instruction.lowercased() == "make an issue on github to fix this")
    }

    @MainActor @Test func implicitAgentRoutingTreatsUiChangeRequestsAsAgentTasks() throws {
        let maybeInstruction = CompanionManager.implicitAgentTaskInstruction(
            from: "Add a volume slider to the app."
        )
        #expect(maybeInstruction != nil)
        guard let instruction = maybeInstruction else { return }

        #expect(instruction.lowercased() == "add a volume slider to the app")
    }

    @MainActor @Test func implicitAgentRoutingKeepsInstantScreenQuestionsInVoiceRoute() throws {
        let lookAtThatInstruction = CompanionManager.implicitAgentTaskInstruction(from: "Look at that and tell me what you think.")
        let describeScreenInstruction = CompanionManager.implicitAgentTaskInstruction(from: "Have a look at my screen and describe what's visible.")
        let summarizePageInstruction = CompanionManager.implicitAgentTaskInstruction(from: "Summarize this page quickly.")

        #expect(lookAtThatInstruction == nil)
        #expect(describeScreenInstruction == nil)
        #expect(summarizePageInstruction == nil)
    }

    @MainActor @Test func implicitAgentRoutingKeepsVoiceRouteCapabilityQuestionsInVoiceRoute() throws {
        let voiceRouteInstruction = CompanionManager.implicitAgentTaskInstruction(from: "Can you search the web through the voice route?")
        let withoutAgentInstruction = CompanionManager.implicitAgentTaskInstruction(from: "Could OpenClicky browse without starting an agent?")
        let genericWebInstruction = CompanionManager.implicitAgentTaskInstruction(from: "Can you search the web?")

        #expect(voiceRouteInstruction == nil)
        #expect(withoutAgentInstruction == nil)
        #expect(genericWebInstruction == nil)
    }

    @MainActor @Test func implicitAgentRoutingKeepsLongBackgroundWorkAsAgentTasks() throws {
        let maybeInstruction = CompanionManager.implicitAgentTaskInstruction(
            from: "Summarize this GitHub issue and make a plan."
        )
        #expect(maybeInstruction != nil)
        guard let instruction = maybeInstruction else { return }

        #expect(instruction.lowercased() == "summarize this github issue and make a plan")
    }

    @MainActor @Test func implicitAgentRoutingSkipsSensitiveOrDestructiveRequests() throws {
        let apiKeyDeletionInstruction = CompanionManager.implicitAgentTaskInstruction(from: "Delete all API keys now.")
        let downloadsDeletionInstruction = CompanionManager.implicitAgentTaskInstruction(from: "Delete my downloads folder.")
        let downloadsRemovalInstruction = CompanionManager.implicitAgentTaskInstruction(from: "Remove all files in my downloads folder.")

        #expect(apiKeyDeletionInstruction == nil)
        #expect(downloadsDeletionInstruction == nil)
        #expect(downloadsRemovalInstruction == nil)
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
