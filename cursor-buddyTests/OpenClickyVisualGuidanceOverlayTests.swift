import AppKit
import Foundation
import Testing
@testable import OpenClicky

struct OpenClickyVisualGuidanceOverlayTests {
    @Test func rectangleNormalizesClampsAndSerializes() throws {
        let overlay = OpenClickyVisualGuidanceOverlay.rectangle(
            rect: CGRect(x: 120, y: 90, width: -80, height: 60),
            accentHex: "#60A5FA",
            lineWidth: 200,
            fillOpacity: 2,
            caption: "  Target  ",
            duration: 120
        )

        #expect(overlay.rect == OpenClickyVisualGuidanceRect(x: 40, y: 90, width: 80, height: 60))
        #expect(overlay.style.lineWidth == 48)
        #expect(overlay.style.fillOpacity == 0.65)
        #expect(overlay.style.caption == "Target")
        #expect(overlay.duration == 60)
        #expect(overlay.isRenderable)

        let encoded = try JSONEncoder().encode(overlay)
        let decoded = try JSONDecoder().decode(OpenClickyVisualGuidanceOverlay.self, from: encoded)
        #expect(decoded == overlay)

        let clamped = overlay.clamped(to: CGRect(x: 50, y: 100, width: 40, height: 40))
        #expect(clamped.rect == OpenClickyVisualGuidanceRect(x: 50, y: 100, width: 40, height: 40))
    }

    @Test func scribbleRequiresAtLeastTwoPointsAndClampsPoints() throws {
        let overlay = OpenClickyVisualGuidanceOverlay.scribble(
            points: [CGPoint(x: -10, y: 20), CGPoint(x: 100, y: 120), CGPoint(x: 300, y: 10)],
            accentHex: "#F59E0B",
            lineWidth: 0,
            duration: 0.01
        )

        #expect(overlay.isRenderable)
        #expect(overlay.style.lineWidth == 1)
        #expect(overlay.duration == 0.2)

        let clamped = overlay.clamped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(clamped.points.map(\.cgPoint) == [
            CGPoint(x: 0, y: 20),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 200, y: 10),
        ])

        let singlePoint = OpenClickyVisualGuidanceOverlay.scribble(points: [CGPoint(x: 1, y: 1)])
        #expect(!singlePoint.isRenderable)
    }

    @Test func bridgeDescriptorsExposeImplementedVisualTools() throws {
        UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.userVisualDrawingOverlayToolsEnabledDefaultsKey)

        let toolNames = OpenClickyExternalControlBridgeServer.testMCPToolDescriptors.compactMap { descriptor in
            descriptor["name"] as? String
        }

        #expect(toolNames.contains("show_scribble"))
        #expect(toolNames.contains("show_highlight"))
        #expect(toolNames.contains("show_rectangle"))

        let capabilityIDs = OpenClickyExternalControlBridgeServer.testCapabilityCompatibilityMetadata.compactMap { metadata in
            metadata["id"] as? String
        }
        #expect(capabilityIDs.contains("visual_guidance.scribble"))
        #expect(capabilityIDs.contains("visual_guidance.rectangle"))
    }

    @Test func bridgeGatesVisualDrawingToolExposureWhenDisabled() throws {
        UserDefaults.standard.set(false, forKey: AppBundleConfiguration.userVisualDrawingOverlayToolsEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.userVisualDrawingOverlayToolsEnabledDefaultsKey) }

        let toolNames = OpenClickyExternalControlBridgeServer.testMCPToolDescriptors.compactMap { descriptor in
            descriptor["name"] as? String
        }

        #expect(!toolNames.contains("show_scribble"))
        #expect(!toolNames.contains("show_highlight"))
        #expect(!toolNames.contains("show_rectangle"))

        let capabilities = OpenClickyExternalControlBridgeServer.testCapabilityCompatibilityMetadata
        #expect(capabilities.contains { metadata in
            metadata["id"] as? String == "visual_guidance.scribble" && metadata["status"] as? String == "gated"
        })
        #expect(capabilities.contains { metadata in
            metadata["id"] as? String == "visual_guidance.rectangle" && metadata["status"] as? String == "gated"
        })
    }

    @Test func bridgeParsesScribbleAndRectangleToolCalls() throws {
        let scribble = OpenClickyExternalControlBridgeServer.testCommand(from: [
            "tool": "show_scribble",
            "arguments": [
                "points": [["x": 10, "y": 20], [30, 40], ["x": "50", "y": "60"]],
                "accentHex": "#34D399",
                "durationMs": 1500,
                "lineWidth": 6,
            ],
        ])
        if case .showVisualGuidanceOverlay(let overlay) = scribble {
            #expect(overlay.kind == .scribble)
            #expect(overlay.points.count == 3)
            #expect(overlay.duration == 1.5)
            #expect(overlay.style.lineWidth == 6)
        } else {
            Issue.record("Expected scribble overlay command")
        }

        let rectangle = OpenClickyExternalControlBridgeServer.testCommand(from: [
            "tool": "show_highlight",
            "arguments": ["x1": 100, "y1": 200, "x2": 150, "y2": 260, "fillOpacity": 0.25],
        ])
        if case .showVisualGuidanceOverlay(let overlay) = rectangle {
            #expect(overlay.kind == .rectangle)
            #expect(overlay.rect == OpenClickyVisualGuidanceRect(x: 100, y: 200, width: 50, height: 60))
            #expect(overlay.style.fillOpacity == 0.25)
        } else {
            Issue.record("Expected rectangle overlay command")
        }
    }

    @Test func voiceLaneParsesRectangleAndScribbleGuidanceTags() throws {
        let rectangle = CompanionManager.parsePointingCoordinates(
            from: "that is the block to focus on. [RECT:10,20,300,140:error block:screen2]"
        )
        #expect(rectangle.spokenText == "that is the block to focus on.")
        #expect(rectangle.coordinate == nil)
        #expect(rectangle.elementLabel == "error block")
        #expect(rectangle.screenNumber == 2)
        #expect(rectangle.visualOverlay?.kind == .rectangle)
        #expect(rectangle.visualOverlay?.rect == OpenClickyVisualGuidanceRect(x: 10, y: 20, width: 300, height: 140))

        let scribble = CompanionManager.parsePointingCoordinates(
            from: "trace this path here. [SCRIBBLE:1,2; 30,40;50,60:flight path]"
        )
        #expect(scribble.spokenText == "trace this path here.")
        #expect(scribble.coordinate == nil)
        #expect(scribble.elementLabel == "flight path")
        #expect(scribble.visualOverlay?.kind == .scribble)
        #expect(scribble.visualOverlay?.points.map(\.cgPoint) == [
            CGPoint(x: 1, y: 2),
            CGPoint(x: 30, y: 40),
            CGPoint(x: 50, y: 60),
        ])
    }

    @Test func voiceLaneRoutesShapeDrawingRequestsToScreenContext() throws {
        #expect(CompanionManager.testShouldAttachScreenContext(to: "draw a circle around that button"))
        #expect(CompanionManager.testShouldAttachScreenContext(to: "can you put a rectangle around the error"))
        #expect(CompanionManager.testShouldAttachScreenContext(to: "box around the login panel"))
        #expect(CompanionManager.testShouldAttachScreenContext(to: "trace around that shape"))

        #expect(!CompanionManager.testShouldAttachScreenContext(to: "draw me a cheerful mascot idea"))
        #expect(!CompanionManager.testShouldAttachScreenContext(to: "mark this task as done later"))
    }
}
