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

    @Test func spokenPlayButtonRequestsMapToARealKey() throws {
        #expect(CompanionManager.testNativeKeyPress(from: "Press play in Spotify.")?.key == "space")
        #expect(CompanionManager.testNativeKeyPress(from: "Press the play button in Spotify.")?.key == "space")
        #expect(CompanionManager.testNativeKeyPress(from: "Press play in Spotify.")?.modifiers == [])
        #expect(CompanionManager.testNativeKeyPress(from: "Press command k in Spotify.")?.key == "k")
        #expect(CompanionManager.testNativeKeyPress(from: "Press command k in Spotify.")?.modifiers == ["command"])
    }

    @Test func compositeAppCommandsPreserveTheFollowUpAction() throws {
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
        #expect(CompanionManager.testStandaloneSpotifyPlaybackQuery(from: "play anything in Spotify") == nil)
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
    }

    @Test func spotifySearchPlayRouteStaysOnComputerUseExecution() throws {
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

    @Test func voiceAgentStartFingerprintNormalizesDuplicateRealtimeRoutes() throws {
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
        #expect(OpenClickyModelCatalog.defaultVoiceResponseModelID == "gpt-realtime-2")
        #expect(OpenClickyModelCatalog.defaultCodexActionsModelID != OpenClickyModelCatalog.defaultVoiceResponseModelID)
    }

    @Test func voiceResponseModelsDoNotUseShortTTSGenerationCap() throws {
        let responseBudgets = OpenClickyModelCatalog.responseVoiceModels.map(\.maxOutputTokens)
        #expect(responseBudgets.allSatisfy { $0 >= 64_000 })
    }

    @Test func realtimeModelsResolveToNonSpeechModelsOutsideRealtimeTransport() throws {
        let analysisModel = OpenClickyModelCatalog.voiceAnalysisModel(withID: "gpt-realtime-2")
        #expect(analysisModel.id == OpenClickyModelCatalog.defaultVoiceAnalysisModelID)
        #expect(!OpenClickyModelCatalog.isSpeechModelID(analysisModel.id))

        let codexModel = OpenClickyModelCatalog.codexVoiceSessionModel(withID: "gpt-realtime-2")
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
                selectedVoiceModelID: "gpt-realtime-2",
                selectedComputerUseModelID: "gpt-5.5"
            ) == "openai_realtime"
        )
    }

    @Test func realtimeComputerUseModelUsesRealtimeAPIInsteadOfCodex() throws {
        let model = OpenClickyModelCatalog.computerUseModel(withID: "gpt-realtime-2")
        #expect(model.provider == .openAI)
        #expect(
            CompanionManager.testComputerUsePointingResolver(
                selectedVoiceModelID: "gpt-5.5",
                selectedComputerUseModelID: "gpt-realtime-2"
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
                selectedComputerUseModelID: "gpt-5.4"
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
