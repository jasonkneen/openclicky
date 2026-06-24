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
        #expect(!rendered.contains("[mcp_servers.composio]"))
        #expect(!rendered.contains("https://connect.composio.dev/mcp"))
        #expect(!rendered.contains("[mcp_servers.openClickyControl]"))
        #expect(!rendered.contains("http://127.0.0.1:32123/mcp"))
    }

    @Test func codexConfigCanPreferAPIKeyForDefaultOpenAIWhenConfigured() throws {
        let template = ClickyCodexConfigTemplate(
            model: "gpt-5.4",
            reasoningEffort: "medium",
            workerBaseURL: URL(string: "https://api.openai.com/v1")!,
            includeOpenAIDeveloperDocsMCP: false,
            preferAPIKeyAuthForDefaultOpenAI: true
        )

        let rendered = template.render()

        #expect(rendered.contains("model_provider = \"openai\""))
        #expect(rendered.contains("preferred_auth_method = \"apikey\""))
        #expect(!rendered.contains("[model_providers.openclicky]"))
    }

    @Test func staleCodexRefreshTokenErrorGetsActionableCopy() throws {
        let raw = "Your access token could not be refreshed because your refresh token was already used. Please log out and sign in again."

        let message = CodexRPCErrorMessage.readableMessage(from: raw)

        #expect(message == "OpenClicky found a stale Codex ChatGPT sign-in. Sign into Codex again, or add a Codex/OpenAI API key in OpenClicky Settings.")
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

    @Test func codexConfigUsesResponsesWireAPIForOpenClickyLocalEndpoint() throws {
        // Codex removed support for `wire_api = "chat"` (Feb 2026); custom providers
        // must declare `responses` or the whole config.toml fails to load.
        let template = ClickyCodexConfigTemplate(
            model: "openclicky-local-mlx-community-llama-3.2-3b-instruct-4bit",
            reasoningEffort: "medium",
            workerBaseURL: ClickyCodexBackend.openClickyLocalModelBaseURL,
            includeOpenAIDeveloperDocsMCP: false
        )

        let rendered = template.render()

        #expect(rendered.contains("model_provider = \"openclicky\""))
        #expect(rendered.contains("base_url = \"http://127.0.0.1:32124/v1\""))
        #expect(rendered.contains("wire_api = \"responses\""))
        #expect(!rendered.contains("wire_api = \"chat\""))
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

    @Test func codexConfigCanDisableComposioConnectMCPServer() throws {
        let template = ClickyCodexConfigTemplate(
            model: "gpt-5.5",
            reasoningEffort: "medium",
            workerBaseURL: URL(string: "https://api.openai.com/v1")!,
            includeOpenAIDeveloperDocsMCP: false,
            includeComposioConnectMCP: false
        )

        let rendered = template.render()

        #expect(!rendered.contains("[mcp_servers.composio]"))
        #expect(!rendered.contains("https://connect.composio.dev/mcp"))
    }

    @Test func codexConfigCanEnableComposioConnectMCPServer() throws {
        let template = ClickyCodexConfigTemplate(
            model: "gpt-5.5",
            reasoningEffort: "medium",
            workerBaseURL: URL(string: "https://api.openai.com/v1")!,
            includeOpenAIDeveloperDocsMCP: false,
            includeComposioConnectMCP: true
        )

        let rendered = template.render()

        #expect(rendered.contains("[mcp_servers.composio]"))
        #expect(rendered.contains("https://connect.composio.dev/mcp"))
    }

    @Test func codexConfigCanEnableOpenClickyControlMCPServer() throws {
        let template = ClickyCodexConfigTemplate(
            model: "gpt-5.5",
            reasoningEffort: "medium",
            workerBaseURL: URL(string: "https://api.openai.com/v1")!,
            includeOpenAIDeveloperDocsMCP: false,
            includeOpenClickyControlMCP: true
        )

        let rendered = template.render()

        #expect(rendered.contains("[mcp_servers.openClickyControl]"))
        #expect(rendered.contains("http://127.0.0.1:32123/mcp"))
        #expect(rendered.contains("bearer_token_env_var = \"OPENCLICKY_BRIDGE_TOKEN\""))
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

    @Test func codexToolRouterClosedStdinDiagnosticIsNonFatal() throws {
        let diagnostic = "ERROR codex_core::tools::router: write_stdin failed: stdin is closed"

        #expect(CodexAgentSession.testIsNonFatalCodexRuntimeStderrLine(diagnostic))
        #expect(!CodexAgentSession.testIsNonFatalCodexRuntimeStderrLine("ERROR codex_core::main: process exited with error status 1"))
    }

    @Test func codexMemoryWriterSetupDiagnosticIsNonFatal() throws {
        let diagnostic = "\u{1B}[31mERROR\u{1B}[0m codex_memories_write::phase2::job: failed to claim job: error returned from database: (code: 1) no such table: jobs"

        #expect(CodexAgentSession.testIsNonFatalCodexRuntimeStderrLine(diagnostic))
        #expect(!CodexAgentSession.testIsNonFatalCodexRuntimeStderrLine("ERROR codex_core::main: process exited with error status 1"))
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

    @MainActor @Test func implicitAgentRoutingTreatsOpenClickyCodeFixRequestsAsAgentTasks() throws {
        let maybeInstruction = CompanionManager.implicitAgentTaskInstruction(
            from: "I think we need to fix OpenClicky so coding tasks always go to Agent Mode."
        )
        #expect(maybeInstruction != nil)
        guard let instruction = maybeInstruction else { return }

        #expect(instruction.lowercased() == "i think we need to fix openclicky so coding tasks always go to agent mode")
    }

    @MainActor @Test func implicitAgentRoutingKeepsConceptualCodingQuestionsInVoiceRoute() throws {
        let maybeInstruction = CompanionManager.implicitAgentTaskInstruction(
            from: "How would I fix this Swift error conceptually?"
        )

        #expect(maybeInstruction == nil)
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

    @MainActor @Test func implicitAgentRoutingIgnoresRawCodexRPCEvents() throws {
        let rateLimitNotification = #"/incoming] codex.rpc.message {"method":"account/rateLimits/updated","paramsSummary":{"keys":["rateLimits"]}}"#
        let genericNotification = #"[incoming] codex.rpc.notification {"method":"thread/session/updated","paramsSummary":{"keys":["session"]}}"#

        #expect(CompanionManager.implicitAgentTaskInstruction(from: rateLimitNotification) == nil)
        #expect(CompanionManager.implicitAgentTaskInstruction(from: genericNotification) == nil)
    }

    @MainActor @Test func pastedOpenClickyLogsRouteToAgentAnalysis() throws {
        let pastedLogs = """
        find out why we're having issues
        [OpenClickyLog][2026-06-09T11:22:08Z][computer-use/incoming] native_cua.direct_request.reminder_count_detected {"route":"native_cua.reminder_count","transcript":"find out why we're having issues [OpenClickyLog] openclicky.agent_task.created count reminders"}
        """

        let maybeInstruction = CompanionManager.implicitAgentTaskInstruction(from: pastedLogs)

        #expect(maybeInstruction != nil)
        #expect(maybeInstruction?.contains("Analyze the pasted OpenClicky logs as evidence") == true)
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


    @MainActor @Test func hybridAgentRoutingAllowsForegroundAnswerAndBackgroundWork() throws {
        let maybeInstruction = CompanionManager.hybridAgentTaskInstruction(
            from: "Can you explain what is happening here and get an agent to review the logs in the background?"
        )
        #expect(maybeInstruction != nil)
        guard let instruction = maybeInstruction else { return }

        #expect(instruction.lowercased() == "review the logs in the background")
    }

    @MainActor @Test func hybridAgentRoutingDoesNotStealPureQuestions() throws {
        #expect(CompanionManager.hybridAgentTaskInstruction(from: "Can you explain what agent mode does?") == nil)
        #expect(CompanionManager.hybridAgentTaskInstruction(from: "What do you think is on my screen?") == nil)
    }

    @MainActor @Test func agentRoutingSplitsOnlyExplicitIndependentWorkstreams() throws {
        let splitInstructions = CompanionManager.testParallelAgentInstructions(
            from: "Use separate agents: first review the logs for routing failures; second patch the voice route in the app; third update the tests for agent routing."
        )

        #expect(splitInstructions.count == 3)
        #expect(splitInstructions[0].lowercased().contains("review the logs"))
        #expect(splitInstructions[1].lowercased().contains("patch the voice route"))
        #expect(splitInstructions[2].lowercased().contains("update the tests"))

        let combinedInstructions = CompanionManager.testParallelAgentInstructions(
            from: "Patch the voice route and update the tests for the same behavior."
        )
        #expect(combinedInstructions.count == 1)
    }

    @MainActor @Test func agentDelegationPhrasesDoNotCancelCurrentAgent() throws {
        #expect(!CompanionManager.isCancelCurrentAgentTaskRequest("Can you start another agent to inspect the logs?"))
        #expect(!CompanionManager.isCancelCurrentAgentTaskRequest("Please get an agent to look at what just happened."))
        #expect(!CompanionManager.isCancelAllAgentTasksRequest("Can you start another agent to inspect the logs?"))

        #expect(CompanionManager.isCancelCurrentAgentTaskRequest("cancel the agent"))
        #expect(CompanionManager.isCancelAllAgentTasksRequest("cancel all agents"))
    }

    @MainActor @Test func voiceContextKeepsRecentRoutedAgentPromptForFollowUps() throws {
        let now = Date()
        let history = CompanionManager.voiceConversationHistoryIncludingRecentUnpairedPrompts(
            baseHistory: [
                (
                    userPlaceholder: "Fix the external monitor notch issue.",
                    assistantResponse: "OpenClicky is handling that in the background."
                )
            ],
            lastPrompt: "Can you get an agent to find out why agent launch fails halfway through a message?",
            lastPromptAt: now,
            previousPrompt: nil,
            previousPromptAt: nil,
            now: now
        )

        #expect(history.count == 2)
        #expect(history.last?.userPlaceholder == "Can you get an agent to find out why agent launch fails halfway through a message?")
        #expect(history.last?.assistantResponse.contains("current conversation topic") == true)
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

    @MainActor @Test func streamingTTSUsesCommaPauseAfterLongClause() throws {
        let chunks = StreamingTTSSession.testChunksForStreaming(
            "OpenClicky should keep speaking to the natural sentence boundary when the opening clause is short, but once a long clause has enough words to sound like a proper spoken unit, it can pause on that comma and continue."
        )

        #expect(chunks.count >= 2)
        #expect(chunks[0].hasSuffix(","))
        #expect(StreamingTTSSession.wordCount(chunks[0]) >= 15)
    }

    @MainActor @Test func streamingTTSKeepsShortCommaClauseWithSentence() throws {
        let chunks = StreamingTTSSession.testChunksForStreaming(
            "OpenClicky checks the comma, then waits for the full stop."
        )

        #expect(chunks == ["OpenClicky checks the comma, then waits for the full stop."])
    }

    @Test func microsoftEdgeBinaryTTSFrameSkipsLengthPrefixBeforeHeaders() throws {
        let header = """
        X-RequestId:edge-test\r
        Content-Type:audio/mpeg\r
        X-StreamId:stream-test\r
        Path:audio\r

        """
        let payload = Data([0x49, 0x44, 0x33, 0x04, 0x00])
        let headerData = Data(header.utf8)
        var frame = Data([
            UInt8((headerData.count >> 8) & 0xff),
            UInt8(headerData.count & 0xff)
        ])
        frame.append(headerData)
        frame.append(payload)

        let parsed = MicrosoftEdgeTTSClient.testParseMicrosoftEdgeBinaryMessage(frame)

        #expect(parsed.path == "audio")
        #expect(parsed.payload == payload)
    }

    @MainActor @Test func streamingTTSUsesDefensiveCutForVeryLongUnpunctuatedSentence() throws {
        let chunks = StreamingTTSSession.testChunksForStreaming(
            "OpenClicky found the cause in the live path because the first assistant sentence was extremely long and still streaming without punctuation while the visible transcript had already advanced so the voice pipeline still needs one defensive escape hatch for uninterrupted model output"
        )

        #expect(chunks.count >= 2)
        #expect(StreamingTTSSession.wordCount(chunks[0]) <= StreamingTTSSession.maxWordsPerTTSChunk)
    }

    @MainActor @Test func streamingTTSTreatsTerminalPunctuationAsReadyDuringStreaming() throws {
        let chunks = StreamingTTSSession.testChunksForStreaming(
            "OpenClicky can speak this sentence as soon as the full stop arrives."
        )

        #expect(chunks == ["OpenClicky can speak this sentence as soon as the full stop arrives."])
    }

    @MainActor @Test func preResponseFillerUsesNaturalThinkingBeat() throws {
        #expect(StreamingTTSSession.preResponseFillerDelayMilliseconds >= 300)
        #expect(StreamingTTSSession.preResponseFillerDelayMilliseconds <= 500)
    }
}
