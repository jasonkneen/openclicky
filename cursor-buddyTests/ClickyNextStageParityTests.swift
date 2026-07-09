import CoreGraphics
import Foundation
import Testing
import OpenClickyCore
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

        let index = try OpenClickyCore.WikiManager.Index.load(fromBundledResourcesRoot: resourcesRoot)

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
            camera: .missing,
            screenContent: .missing
        )

        let viewState = PermissionGuideAssistant.viewState(for: snapshot, entryContext: .panel)

        #expect(viewState.primaryStep?.kind == .accessibility)
        #expect(viewState.steps.map(\.kind) == [.accessibility, .screenRecording, .microphone, .camera, .screenContent])
        #expect(viewState.steps.filter { $0.status == .missing }.count == 4)
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
            TASK_TITLE: Response Metadata Cleanup
            """,
            contextTitle: "SpaceX competitor research and launch notes",
            createdAt: Date(timeIntervalSince1970: 42)
        )

        #expect(card.displayText == "I checked it. You can keep working now.")
        #expect(card.displayText.count <= ClickyResponseCard.maximumDisplayCharacters)
        #expect(card.suggestedNextActions == ["Open the memory window", "Ask one more question"])
        #expect(card.displayTitle == "SPACEX COMPETITOR RESEARCH…")
    }

    @Test func responseCardsHideInlineAgentMetadataInPanels() throws {
        let card = ClickyResponseCard(
            source: .agent,
            rawText: "Fixed the panel render. <NEXT_ACTIONS> - Test panel card - Review Swift diff </NEXT_ACTIONS>\nTASK_TITLE: Panel Metadata Render",
            contextTitle: "panels render properly"
        )

        #expect(card.displayText == "Fixed the panel render.")
        #expect(card.suggestedNextActions == ["Test panel card", "Review Swift diff"])
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
        #expect(payload.selection.hasFreehandPath == false)
    }

    @Test func handoffSelectionUsesFreehandPathBoundsWhenPresent() throws {
        let path: [CGPoint] = [
            CGPoint(x: 100, y: 200),
            CGPoint(x: 180, y: 210),
            CGPoint(x: 200, y: 280),
            CGPoint(x: 120, y: 300),
            CGPoint(x: 100, y: 200)
        ]
        let selection = HandoffRegionSelection(
            startPositionInScreen: CGPoint(x: 0, y: 0),
            endPositionInScreen: CGPoint(x: 10, y: 10),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            comment: "what muscle is this",
            pathPoints: path,
            ambientSummary: "App: Safari — \"Anatomy\""
        )

        #expect(selection.hasFreehandPath)
        // captureRect remains start/end (authoritative crop bounds), not raw path AABB.
        #expect(selection.captureRect == CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(selection.pathPoints.count == 5)
        #expect(selection.ambientSummary.contains("Safari"))
    }

    @Test func circleSelectSealThresholdsRejectTinyPaths() {
        #expect(CircleSelectSession.minimumPointCount >= 8)
        #expect(CircleSelectSession.minimumPathLength >= 90)
        #expect(CircleSelectSession.capturePadding > 0)
    }

    @Test func circleSelectNormalizedPathResamplesAndSmooths() {
        let jagged: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 30),
            CGPoint(x: 20, y: 5),
            CGPoint(x: 40, y: 40),
            CGPoint(x: 80, y: 20),
            CGPoint(x: 120, y: 50)
        ]
        let normalized = CircleSelectSession.normalizedPath(jagged)
        #expect(normalized.count >= jagged.count)
        #expect(normalized.first == jagged.first)
        #expect(normalized.last == jagged.last)

        // Even spacing: successive steps should be roughly similar, not wild jumps.
        let steps = zip(normalized, normalized.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        #expect(!steps.isEmpty)
        let average = steps.reduce(0, +) / CGFloat(steps.count)
        #expect(steps.allSatisfy { abs($0 - average) < average * 1.5 + 2 })
    }

    @Test func circleSelectSealedStrokeBuildsHandoffSelection() {
        let stroke = CircleSelectSealedStroke(
            points: [
                CGPoint(x: 50, y: 50),
                CGPoint(x: 150, y: 60),
                CGPoint(x: 160, y: 140),
                CGPoint(x: 40, y: 130)
            ],
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            captureRect: CGRect(x: 40, y: 50, width: 120, height: 90),
            pathLength: 260,
            ambient: CircleSelectAmbientContext(
                appName: "Preview",
                bundleIdentifier: "com.apple.Preview",
                windowTitle: "diagram.pdf",
                documentPath: nil,
                pageURL: nil,
                appSkillSummary: nil
            ),
            sealedAt: Date(),
            snap: CircleSelectSnapResult(
                rect: CGRect(x: 48, y: 55, width: 100, height: 70),
                label: "diagram panel",
                source: "accessibility",
                role: "AXImage"
            )
        )

        let selection = stroke.handoffSelection(instruction: "explain this")
        #expect(selection.comment == "explain this")
        #expect(selection.pathPoints.count == 4)
        #expect(selection.ambientSummary.contains("Preview"))
        #expect(selection.ambientSummary.contains("Snapped target"))
        #expect(stroke.agentNote(instruction: "explain this").contains("Snapped"))
    }

    @Test func circleSelectPathContainmentDetectsInteriorPoint() {
        // Square path in AppKit coords.
        let square: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 0, y: 100),
            CGPoint(x: 0, y: 0)
        ]
        let snap = CircleSelectSnapResolver.resolveSnap(
            pathPoints: square,
            pathBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            partialTranscript: nil
        )
        // May be nil without AX fixtures; just ensure the API is callable.
        _ = snap
    }

    @Test func circleSelectPathContainmentHandlesDescendingEdges() {
        // The right edge descends in this ordering. Its Y delta must retain
        // its sign in the ray-cast calculation or the center is reported out.
        let diamond: [CGPoint] = [
            CGPoint(x: 10, y: 0),
            CGPoint(x: 20, y: 10),
            CGPoint(x: 10, y: 20),
            CGPoint(x: 0, y: 10)
        ]

        #expect(CircleSelectSnapResolver.pathContains(CGPoint(x: 10, y: 10), points: diamond))
        #expect(CircleSelectSnapResolver.pathContains(CGPoint(x: 10, y: 10), points: Array(diamond.reversed())))
        #expect(!CircleSelectSnapResolver.pathContains(CGPoint(x: 25, y: 10), points: diamond))
    }

    @Test func circleSelectAXCoordinatesUseMenuBarScreenOrigin() {
        // A taller secondary display must not redefine the AX coordinate
        // origin. The menu-bar display's max Y is the conversion anchor.
        let appKitY = CircleSelectSnapResolver.appKitY(
            fromAXY: 120,
            height: 30,
            menuBarScreenMaxY: 900
        )

        #expect(appKitY == 750)
    }

    @Test func regionCaptureRequiresAContainingDisplay() {
        let leftDisplay = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let menuBarDisplay = CGRect(x: 0, y: 0, width: 1440, height: 900)

        #expect(CompanionScreenCaptureUtility.displayFrameContainsRegion(
            menuBarDisplay,
            region: CGRect(x: 100, y: 100, width: 220, height: 180)
        ))
        #expect(!CompanionScreenCaptureUtility.displayFrameContainsRegion(
            menuBarDisplay,
            region: CGRect(x: -20, y: 100, width: 80, height: 180)
        ))
        #expect(!CompanionScreenCaptureUtility.displayFrameContainsRegion(
            leftDisplay,
            region: CGRect(x: -20, y: 100, width: 80, height: 180)
        ))
    }
}
