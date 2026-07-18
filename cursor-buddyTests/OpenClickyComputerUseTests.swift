import Foundation
import Testing
@testable import OpenClicky

struct OpenClickyComputerUseTests {
    @Test func nativeComputerUseStatusSummarizesReadiness() throws {
        let permissions = OpenClickyComputerUsePermissionStatus(
            accessibilityGranted: true,
            screenRecordingGranted: true,
            skyLightKeyboardPathAvailable: true
        )
        let focusedWindow = OpenClickyComputerUseWindowInfo(
            id: 42,
            pid: 1234,
            owner: "Safari",
            name: "OpenClicky Test",
            bounds: OpenClickyComputerUseWindowBounds(x: 10, y: 20, width: 800, height: 600),
            zIndex: 9,
            isOnScreen: true,
            layer: 0
        )

        let status = OpenClickyComputerUseStatus(
            enabled: true,
            permissions: permissions,
            runningAppCount: 4,
            visibleWindowCount: 7,
            focusedWindow: focusedWindow,
            lastErrorMessage: nil
        )

        #expect(status.isReadyForComputerUse)
        #expect(status.summary == "Enabled · AX ready · screen ready · SkyLight keyboard ready · Safari")
        #expect(status.focusedTargetSummary == "Safari — OpenClicky Test · pid 1234 · window 42")
    }

    @Test func nativeComputerUseStatusCallsOutDisabledMode() throws {
        let status = OpenClickyComputerUseStatus(
            enabled: false,
            permissions: OpenClickyComputerUsePermissionStatus(
                accessibilityGranted: true,
                screenRecordingGranted: true,
                skyLightKeyboardPathAvailable: false
            ),
            runningAppCount: 0,
            visibleWindowCount: 0,
            focusedWindow: nil,
            lastErrorMessage: nil
        )

        #expect(!status.isReadyForComputerUse)
        #expect(status.summary == "Disabled · enable in OpenClicky settings")
    }

    @Test func nativeComputerUseWindowNotesIncludeStableAgentMetadata() throws {
        let window = OpenClickyComputerUseWindowInfo(
            id: 77,
            pid: 2468,
            owner: "Xcode",
            name: "ContentView.swift",
            bounds: OpenClickyComputerUseWindowBounds(x: 12.5, y: 40.0, width: 900.0, height: 700.0),
            zIndex: 20,
            isOnScreen: true,
            layer: 0
        )

        #expect(window.agentContextNote == "CUA Swift target window id 77, pid 2468, owner Xcode, title ContentView.swift, bounds x:12 y:40 width:900 height:700, z-index 20.")
        #expect(window.captureLabel == "CUA Swift focused window (Xcode - ContentView.swift)")
    }

    @Test func nativeComputerUseCaptureNoteExplainsDownsampleMapping() throws {
        let window = OpenClickyComputerUseWindowInfo(
            id: 77,
            pid: 2468,
            owner: "Xcode",
            name: "ContentView.swift",
            bounds: OpenClickyComputerUseWindowBounds(x: 12.5, y: 40.0, width: 1606.0, height: 1089.0),
            zIndex: 20,
            isOnScreen: true,
            layer: 0
        )
        let capture = OpenClickyComputerUseWindowCapture(
            imageData: Data(),
            window: window,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 867
        )

        #expect(capture.agentContextNote.contains("Screenshot is a proportional downsample of the focused window, not full native display pixels"))
        #expect(capture.agentContextNote.contains("xScale 1.2547"))
        #expect(capture.agentContextNote.contains("yScale 1.2550"))
    }

    @Test func realtimeCompositeAppCommandIsNotReducedToOpenApp() throws {
        #expect(
            CompanionManager.testLocalAppOpenTarget(
                from: "Can you open Spotify and play AC/DC Back to Black?"
            ) == nil
        )
        #expect(
            CompanionManager.testLocalAppOpenTarget(
                from: "Can you open Spotify and can you play AC/DC Back to Black?"
            ) == nil
        )
        #expect(
            CompanionManager.testLocalAppOpenTarget(
                from: "Open Chrome and go to amazon.co.uk"
            ) == nil
        )
        #expect(CompanionManager.testCompositeAppAction(from: "Open Chrome and go to amazon.co.uk") == nil)
        #expect(CompanionManager.testWebOpenTarget(from: "Open Chrome and go to amazon.co.uk")?.url == "https://amazon.co.uk")
        #expect(CompanionManager.testWebOpenTarget(from: "Open Chrome and go to amazon.co.uk")?.browserAppName == "Google Chrome")
    }

    @Test func directRequestRoutersDoNotStealQuestionsOrDesignTasks() throws {
        #expect(CompanionManager.testLocalAppOpenTarget(from: "You open GitHub.") == "GitHub Desktop")
        #expect(CompanionManager.testLocalFolderOpenTarget(from: "Is your working folder currently the OpenClicky folder?") == nil)
        #expect(CompanionManager.testLocalFolderOpenTarget(from: "look into introducing workspaces or project folders in OpenClicky so I can configure named workspaces") == nil)
        #expect(CompanionManager.testLocalFolderOpenTarget(from: "Take a look at /Users/jkneen/clawd/github/hf-realtime-voice — how could we integrate this into OpenClicky?") == nil)
    }

    @Test func realtimeDoneTranscriptExtractionIgnoresTransportIds() throws {
        let responseDone: [String: Any] = [
            "type": "response.done",
            "event_id": "event_DygDZLewDHSIBzmCqbYFv",
            "response": [
                "id": "resp_123",
                "output": [
                    [
                        "type": "message",
                        "content": [
                            ["type": "output_text", "text": "Opening GitHub Desktop."]
                        ]
                    ]
                ]
            ]
        ]
        #expect(OpenAIRealtimeSpeechClient.testFirstTranscriptString(in: responseDone) == "Opening GitHub Desktop.")
    }

    @Test func pastedLogsDoNotBecomeReminderCountCommands() throws {
        let pastedLogs = """
        find out why we're having issues
        [OpenClickyLog][2026-06-09T11:22:08Z][computer-use/incoming] native_cua.direct_request.reminder_count_detected {"route":"native_cua.reminder_count","transcript":"count tasks reminders"}
        """

        #expect(CompanionManager.testLogEvidenceAnalysisInstruction(from: pastedLogs) != nil)
        #expect(CompanionManager.testReminderCountInstruction(from: pastedLogs) == nil)
    }

    @Test func spokenPlayButtonRequestsMapToARealKey() throws {
        #expect(CompanionManager.testNativeKeyPress(from: "Press play in Spotify.")?.key == "space")
        #expect(CompanionManager.testNativeKeyPress(from: "Press the play button in Spotify.")?.key == "space")
        #expect(CompanionManager.testNativeKeyPress(from: "Press play in Spotify.")?.modifiers == [])
        #expect(CompanionManager.testNativeKeyPress(from: "Press command k in Spotify.")?.key == "k")
        #expect(CompanionManager.testNativeKeyPress(from: "Press command k in Spotify.")?.modifiers == ["command"])
    }

    @MainActor @Test func compositeAppCommandsPreserveTheFollowUpAction() throws {
        let spotifyAction = CompanionManager.testCompositeAppAction(
            from: "Open Spotify and play AC/DC Back in Black."
        )
        #expect(spotifyAction?.appName == "Spotify")
        #expect(spotifyAction?.actionText == "play AC/DC Back in Black")

        let politeSpotifyAction = CompanionManager.testCompositeAppAction(
            from: "Open Spotify and can you play AC/DC Back in Black?"
        )
        #expect(politeSpotifyAction?.appName == "Spotify")
        #expect(politeSpotifyAction?.actionText == "play AC/DC Back in Black")

        let mailAction = CompanionManager.testCompositeAppAction(
            from: "Open Mail and search for invoices."
        )
        #expect(mailAction?.appName == "Mail")
        #expect(mailAction?.actionText == "search for invoices")

        let bareSpotifyAction = CompanionManager.testCompositeAppAction(
            from: "Spotify and play Back in Black."
        )
        #expect(bareSpotifyAction?.appName == "Spotify")
        #expect(bareSpotifyAction?.actionText == "play Back in Black")
        #expect(CompanionManager.testSpotifyPlaybackQuery(from: "Spotify and play Back in Black.") == "Back in Black")
        #expect(CompanionManager.testStandaloneSpotifyPlaybackQuery(from: "Can you play Back in Black?") == "Back in Black")
        #expect(CompanionManager.testStandaloneSpotifyPlaybackQuery(from: "play the video") == nil)
        #expect(CompanionManager.testStandaloneSpotifyPlaybackQuery(from: "Can you play Spotify?") == nil)
        #expect(CompanionManager.testStandaloneSpotifyPlaybackQuery(from: "play anything in Spotify") == nil)
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "Can you play Spotify?") == "play")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "play anything in Spotify") == "play")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "play music") == "play")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "pause Spotify") == "pause")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "skip in Spotify") == "next")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "go back in Spotify") == "previous")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn shuffle on in Spotify") == "shuffleOn")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn shuffle off in Spotify") == "shuffleOff")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn repeat on in Spotify") == "repeatOn")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn repeat off in Spotify") == "repeatOff")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn Spotify volume up") == "volumeUp")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn Spotify volume down") == "volumeDown")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "increase Spotify volume") == "volumeUp")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "lower Spotify volume") == "volumeDown")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "set Spotify volume to 35 percent") == "volumeSet:35")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "set Spotify volume to 150") == "volumeSet:100")
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "turn volume up") == nil)
        #expect(CompanionManager.testSpotifyPlaybackControlAction(from: "mute volume") == nil)
    }

    @Test func standaloneSystemVolumeCommandsUseSystemAudioRoute() throws {
        #expect(CompanionManager.testSystemVolumeControlAction(from: "turn volume up") == "volumeUp")
        #expect(CompanionManager.testSystemVolumeControlAction(from: "turn volume down") == "volumeDown")
        #expect(CompanionManager.testSystemVolumeControlAction(from: "mute") == "mute")
        #expect(CompanionManager.testSystemVolumeControlAction(from: "mute volume") == "mute")
        #expect(CompanionManager.testSystemVolumeControlAction(from: "set volume to 35 percent") == "setVolume:35")
        #expect(CompanionManager.testSystemVolumeControlAction(from: "set volume to 150") == "setVolume:100")
        #expect(CompanionManager.testSystemVolumeControlAction(from: "turn Spotify volume up") == nil)
        #expect(CompanionManager.testSystemVolumeControlAction(from: "open Spotify and turn volume up") == nil)
    }

    @MainActor @Test func spotifySearchPlayRouteStaysOnComputerUseExecution() throws {
        let nativeMethods = CompanionManager.testSpotifySearchPlayExecutionMethods(for: .nativeSwift)
        #expect(nativeMethods.started == "NSWorkspace.open_spotify_uri + OpenClickyNativeComputerUseController.pressKey + AppleScript playback verification")
        #expect(nativeMethods.completed == "NSWorkspace.open_spotify_uri + OpenClickyNativeComputerUseController.pressKey + AppleScript playback verification")
        #expect(nativeMethods.completed.localizedCaseInsensitiveContains("AppleScript"))
        #expect(nativeMethods.completed.localizedCaseInsensitiveContains("verification"))

        let backgroundMethods = CompanionManager.testSpotifySearchPlayExecutionMethods(for: .backgroundComputerUse)
        #expect(backgroundMethods.started == "NSWorkspace.open_spotify_uri + BackgroundComputerUse /v1/press_key + AppleScript playback verification")
        #expect(backgroundMethods.completed == "NSWorkspace.open_spotify_uri + BackgroundComputerUse /v1/press_key + AppleScript playback verification")
        #expect(backgroundMethods.completed.localizedCaseInsensitiveContains("AppleScript"))
        #expect(backgroundMethods.completed.localizedCaseInsensitiveContains("verification"))
    }

    @MainActor @Test func voiceAgentStartFingerprintNormalizesDuplicateRealtimeRoutes() throws {
        let first = CompanionManager.testVoiceAgentStartFingerprint(
            instruction: "Figure out why our background computer-use path, C U A, is reporting background agent not started yet.",
            route: "agent.hybrid_start"
        )
        let repeated = CompanionManager.testVoiceAgentStartFingerprint(
            instruction: "figure out why our background computer use path c u a is reporting background agent not started yet",
            route: "agent.hybrid_start"
        )
        #expect(first == repeated)
    }

    @Test func realtimeTwoIsTheDefaultVoiceInteractionModel() throws {
        #expect(OpenClickyModelCatalog.defaultVoiceResponseModelID == "gpt-realtime-2.1-mini")
        #expect(OpenClickyModelCatalog.defaultCodexActionsModelID != OpenClickyModelCatalog.defaultVoiceResponseModelID)
        #expect(OpenClickyModelCatalog.speechModels.contains { $0.id == "gpt-realtime-2.1" })
        #expect(OpenClickyModelCatalog.speechModels.contains { $0.id == "gpt-realtime-2.1-mini" })
    }

    @Test func appleFoundationModelIsInVoiceCatalog() throws {
        let apple = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyModelCatalog.appleFoundationModelID)
        #expect(apple.id == OpenClickyModelCatalog.appleFoundationModelID)
        #expect(apple.provider == .apple)
        #expect(apple.provider.voiceBackendFamily == .apple)
        #expect(apple.maxOutputTokens >= 64_000)
        #expect(OpenClickyVoiceBackendFamily.apple.defaultModelID == OpenClickyModelCatalog.appleFoundationModelID)
        #expect(OpenClickyVoiceBackendFamily.claude.defaultModelID == "claude-haiku-4-5")
        #expect(OpenClickyVoiceBackendFamily.codex.defaultModelID == OpenClickyModelCatalog.defaultCodexActionsModelID)
        #expect(OpenClickyVoiceBackendFamily.allCases.count == 3)

        let claudeDefault = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyVoiceBackendFamily.claude.defaultModelID)
        #expect(claudeDefault.provider == .anthropic)
        #expect(claudeDefault.provider.voiceBackendFamily == .claude)

        let codexDefault = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyVoiceBackendFamily.codex.defaultModelID)
        #expect(codexDefault.provider.voiceBackendFamily == .codex)

        // Apple is offered in the settings response grid via responseVoiceModels.
        #expect(OpenClickyModelCatalog.responseVoiceModels.contains { $0.id == OpenClickyModelCatalog.appleFoundationModelID })
        #expect(!OpenClickyModelCatalog.isSpeechModelID(OpenClickyModelCatalog.appleFoundationModelID))
    }

    @Test func providerDiscoveryReturnsThreeFamilies() throws {
        let rows = OpenClickyProviderDiscovery.availability()
        #expect(rows.map(\.family) == [.apple, .codex, .claude])
        for row in rows {
            #expect(!row.statusLabel.isEmpty)
            #expect(!row.detail.isEmpty)
            #expect(OpenClickyProviderDiscovery.isAvailable(row.family) == row.isAvailable)
        }
    }

    @Test func responseOverlayAutoHideCancelsPriorScheduleBeforeReschedule() throws {
        var policy = ResponseOverlayAutoHidePolicy()
        let first = policy.schedule(now: 0, holdSeconds: 6)
        #expect(policy.isCurrent(first))
        #expect(policy.shouldHide(now: 6, generation: first))

        // Mid-stream chunk: cancel-before-schedule must invalidate the first hide.
        let second = policy.schedule(now: 1.5, holdSeconds: 6)
        #expect(second != first)
        #expect(!policy.isCurrent(first))
        #expect(!policy.shouldHide(now: 6, generation: first), "stale first-chunk hide must not fire")
        #expect(policy.shouldHide(now: 7.5, generation: second))
        #expect(!policy.shouldHide(now: 7.4, generation: second))

        // updateStreamingText path: cancel alone keeps bubble open with no pending hide.
        policy.cancel()
        #expect(policy.scheduledHideAt == nil)
        #expect(!policy.shouldHide(now: 100, generation: second))
    }

    @Test func responseOverlayAutoHideDefaultHoldIsLongerThanIdleCaptionClear() throws {
        // Cursor caption clears at ~1.2s on voice idle; interactive bubble must
        // outlive that so the provider selector remains usable (criterion 3).
        #expect(ResponseOverlayAutoHidePolicy.defaultHoldSeconds > 1.2)
        #expect(ResponseOverlayAutoHidePolicy.defaultHoldSeconds >= 6)
    }

    @Test func retiredRealtimeTwoAliasMigratesToCurrentMiniDefault() throws {
        #expect(OpenClickyModelCatalog.normalizedModelID("gpt-realtime-2") == "gpt-realtime-2.1-mini")
        #expect(OpenClickyModelCatalog.voiceResponseModel(withID: "gpt-realtime-2").id == "gpt-realtime-2.1-mini")
        #expect(OpenClickyModelCatalog.speechModel(withID: "gpt-realtime-2").id == "gpt-realtime-2.1-mini")
        #expect(OpenClickyModelCatalog.isSpeechModelID("gpt-realtime-2"))
        #expect(OpenClickyModelCatalog.computerUseModel(withID: "gpt-realtime-2").id == "gpt-realtime-2.1-mini")
    }

    @Test func unknownVoiceModelIDsFallBackToSpeechDefaultNotHaiku() throws {
        let resolved = OpenClickyModelCatalog.voiceResponseModel(withID: "definitely-not-a-real-model-id")
        #expect(resolved.id == OpenClickyModelCatalog.defaultVoiceResponseModelID)
        #expect(OpenClickyModelCatalog.isSpeechModelID(resolved.id))
        #expect(resolved.id != "claude-haiku-4-5")
    }

    @Test func realtimeTwoUsesLowReasoningEffortForVoiceLatency() throws {
        #expect(OpenAIRealtimeSpeechClient.realtimeReasoningConfiguration(for: "gpt-realtime-2.1-mini")?["effort"] == "low")
        #expect(OpenAIRealtimeSpeechClient.realtimeReasoningConfiguration(for: "gpt-realtime-2.1")?["effort"] == "low")
        #expect(OpenAIRealtimeSpeechClient.realtimeReasoningConfiguration(for: "gpt-realtime-2")?["effort"] == "low")
        #expect(OpenAIRealtimeSpeechClient.realtimeReasoningConfiguration(for: "gpt-realtime-1.5") == nil)
    }

    @Test func voiceResponseModelsDoNotUseShortTTSGenerationCap() throws {
        let responseBudgets = OpenClickyModelCatalog.responseVoiceModels.map(\.maxOutputTokens)
        #expect(responseBudgets.allSatisfy { $0 >= 64_000 })
    }

    @Test func realtimeModelsResolveToNonSpeechModelsOutsideRealtimeTransport() throws {
        let analysisModel = OpenClickyModelCatalog.voiceAnalysisModel(withID: "gpt-realtime-2.1-mini")
        #expect(analysisModel.id == OpenClickyModelCatalog.defaultVoiceAnalysisModelID)
        #expect(!OpenClickyModelCatalog.isSpeechModelID(analysisModel.id))

        let codexModel = OpenClickyModelCatalog.codexVoiceSessionModel(withID: "gpt-realtime-2.1-mini")
        #expect(codexModel.id == OpenClickyModelCatalog.defaultCodexActionsModelID)
        #expect(!OpenClickyModelCatalog.isSpeechModelID(codexModel.id))
    }

    @Test func nonSpeechModelsRemainSelectedForVoiceAnalysis() throws {
        #expect(OpenClickyModelCatalog.voiceAnalysisModel(withID: "gpt-5.5").id == "gpt-5.5")
        #expect(OpenClickyModelCatalog.codexVoiceSessionModel(withID: "gpt-5.5").id == "gpt-5.5")
    }

    @Test func realtimeVoiceUsesRealtimeForComputerUsePointing() throws {
        #expect(
            CompanionManager.testComputerUsePointingResolver(
                selectedVoiceModelID: "gpt-realtime-2.1-mini",
                selectedComputerUseModelID: "gpt-5.5"
            ) == "openai_realtime"
        )
    }

    @Test func realtimeComputerUseModelUsesRealtimeAPIInsteadOfCodex() throws {
        let model = OpenClickyModelCatalog.computerUseModel(withID: "gpt-realtime-2.1-mini")
        #expect(model.provider == .openAI)
        #expect(
            CompanionManager.testComputerUsePointingResolver(
                selectedVoiceModelID: "gpt-5.5",
                selectedComputerUseModelID: "gpt-realtime-2.1-mini"
            ) == "openai_realtime"
        )
    }

    @Test func nonRealtimeVoiceKeepsSelectedComputerUsePointingResolver() throws {
        #expect(
            CompanionManager.testComputerUsePointingResolver(
                selectedVoiceModelID: "gpt-5.5",
                selectedComputerUseModelID: "gpt-5.5"
            ) == "codex_cli"
        )
        #expect(
            CompanionManager.testComputerUsePointingResolver(
                selectedVoiceModelID: "claude-haiku-4-5",
                selectedComputerUseModelID: "gpt-5.5"
            ) == "codex_cli"
        )
        #expect(
            CompanionManager.testComputerUsePointingResolver(
                selectedVoiceModelID: "claude-haiku-4-5",
                selectedComputerUseModelID: "claude-sonnet-4-6"
            ) == "anthropic_api"
        )
    }

    @Test func codexPointDetectorDoesNotUseRemovedApprovalFlag() throws {
        let arguments = CodexPointDetector.testCodexExecArguments()
        #expect(!arguments.contains("--ask-for-approval"))
        #expect(arguments.contains("-c"))
        #expect(arguments.contains("approval_policy=\"never\""))
    }
}
