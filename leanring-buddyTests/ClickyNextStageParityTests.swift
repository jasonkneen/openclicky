import CoreGraphics
import Foundation
import Testing
@testable import OpenClicky

@MainActor
struct ClickyNextStageParityTests {
    @Test func debugDevModeUsesOpenClickyIdentityAndDisablesSideEffects() throws {
        #expect(Bundle.main.bundleIdentifier == "com.jkneen.openclicky")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "OpenClicky")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "OpenClicky")
        #expect(OpenClickyRuntimeMode.isDevelopmentBuild == true)
        #expect(ClickyAnalytics.isEnabled == false)
    }


    @Test func wikiManagerIndexesBundledWikiSeedAndSkills() throws {
        let resourcesRoot = URL(fileURLWithPath: "/Users/jkneen/Documents/GitHub/openclicky/AppResources/OpenClicky", isDirectory: true)

        let index = try WikiManager.Index.load(fromBundledResourcesRoot: resourcesRoot)

        #expect(index.articles.contains { $0.relativePath == "wiki/_index.md" && $0.title == "Index" })
        #expect(index.articles.contains { $0.relativePath == "wiki/projects/openclicky.md" && $0.title.localizedCaseInsensitiveContains("OpenClicky") })
        #expect(index.skills.contains { $0.identifier == "polish" && $0.title.localizedCaseInsensitiveContains("polish") })
        #expect(index.skills.contains { $0.identifier == "frontend-design" })
        #expect(index.article(containingTitle: "OpenClicky")?.body.isEmpty == false)
    }

    @Test func permissionGuidePrioritizesSetupOrder() throws {
        let snapshot = PermissionSnapshot(
            accessibility: .missing,
            screenRecording: .granted,
            microphone: .missing,
            screenContent: .missing
        )

        let viewState = PermissionGuideAssistant.viewState(for: snapshot, entryContext: .panel)

        #expect(viewState.primaryStep?.kind == .accessibility)
        #expect(viewState.steps.map(\.kind) == [.accessibility, .screenRecording, .microphone, .screenContent])
        #expect(viewState.steps.filter { $0.status == .missing }.count == 3)
        #expect(viewState.primaryStep?.settingsURL.absoluteString.contains("Privacy_Accessibility") == true)
        #expect(viewState.headline == "Permissions needed")
    }

    @Test func responseCardsSanitizeAgentFinalMessagesForCursorBubble() throws {
        let card = ClickyResponseCard(
            source: .agent,
            rawText: """
            # Done

            I checked it.
            ```swift
            print(1)
            ```
            You can keep working now.
            <NEXT_ACTIONS>
            - Open the memory window
            - Ask one more question
            </NEXT_ACTIONS>
            """,
            contextTitle: "SpaceX competitor research and launch notes",
            createdAt: Date(timeIntervalSince1970: 42)
        )

        #expect(card.displayText == "I checked it. You can keep working now.")
        #expect(card.displayText.count <= ClickyResponseCard.maximumDisplayCharacters)
        #expect(card.suggestedNextActions == ["Open the memory window", "Ask one more question"])
        #expect(card.displayTitle == "SPACEX COMPETITOR RESEARCH…")
    }

    @Test func handoffSelectionBuildsRegionPayloadMetadata() throws {
        let selection = HandoffRegionSelection(
            startPositionInScreen: CGPoint(x: 40, y: 120),
            endPositionInScreen: CGPoint(x: 260, y: 320),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            comment: "send this to agent"
        )

        let payload = HandoffQueuedRegionScreenshot(selection: selection, imageData: Data([0xFF, 0xD8, 0xFF]))

        #expect(payload.selection.captureRect == CGRect(x: 40, y: 120, width: 220, height: 200))
        #expect(abs(payload.selection.normalizedCaptureRect.width - CGFloat(220.0 / 1440.0)) < 0.000001)
        #expect(payload.imageByteCount == 3)
        #expect(payload.commentSource == .typed)
    }
}
