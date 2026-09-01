import AppKit
import OCComputerUseCore
import Foundation
import Testing
@testable import OpenClicky

struct OpenClickyVisualGuidanceOverlayTests {
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

    @Test func bridgeHidesGmailStubToolsUnlessFlagEnabled() throws {
        UserDefaults.standard.set(false, forKey: AppBundleConfiguration.userGmailOAuthToolsEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.userGmailOAuthToolsEnabledDefaultsKey) }

        let disabledNames = OpenClickyExternalControlBridgeServer.testMCPToolDescriptors.compactMap { $0["name"] as? String }
        #expect(!disabledNames.contains("gmail_list_messages"))
        #expect(!disabledNames.contains("gmail_read_message"))
        #expect(!disabledNames.contains("gmail_draft_reply"))

        UserDefaults.standard.set(true, forKey: AppBundleConfiguration.userGmailOAuthToolsEnabledDefaultsKey)
        let enabledNames = OpenClickyExternalControlBridgeServer.testMCPToolDescriptors.compactMap { $0["name"] as? String }
        #expect(enabledNames.contains("gmail_list_messages"))
        #expect(enabledNames.contains("gmail_read_message"))
        #expect(enabledNames.contains("gmail_draft_reply"))

        let capabilities = OpenClickyExternalControlBridgeServer.testCapabilityCompatibilityMetadata
        #expect(capabilities.contains { metadata in
            metadata["id"] as? String == "gmail.oauth"
                && metadata["status"] as? String == "gated"
                && metadata["implementation"] as? String == "stub"
        })
    }

    @Test func bridgeReturnsStructuredGatedErrorForGmailStubCalls() throws {
        UserDefaults.standard.set(true, forKey: AppBundleConfiguration.userGmailOAuthToolsEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.userGmailOAuthToolsEnabledDefaultsKey) }

        let command = OpenClickyExternalControlBridgeServer.testCommand(from: [
            "tool": "gmail_list_messages",
            "arguments": ["query": "is:unread", "maxResults": 5],
        ])
        guard case .unavailable(let statusCode, let body) = command else {
            Issue.record("Expected unavailable Gmail stub command")
            return
        }
        #expect(statusCode == 501)
        #expect(body["ok"] as? Bool == false)
        #expect(body["capability"] as? String == "gmail.oauth")
        #expect(body["status"] as? String == "gated")
        #expect(body["implementation"] as? String == "stub")
        #expect(body["tool"] as? String == "gmail_list_messages")
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
        #expect(rectangle.visualOverlay?.duration == 6)
        #expect(rectangle.visualOverlay?.rect == OpenClickyVisualGuidanceRect(x: 10, y: 20, width: 300, height: 140))

        let scribble = CompanionManager.parsePointingCoordinates(
            from: "trace this path here. [SCRIBBLE:1,2; 30,40;50,60:flight path]"
        )
        #expect(scribble.spokenText == "trace this path here.")
        #expect(scribble.coordinate == nil)
        #expect(scribble.elementLabel == "flight path")
        #expect(scribble.visualOverlay?.kind == .scribble)
        #expect(scribble.visualOverlay?.duration == 6)
        #expect(scribble.visualOverlay?.points.map(\.cgPoint) == [
            CGPoint(x: 1, y: 2),
            CGPoint(x: 30, y: 40),
            CGPoint(x: 50, y: 60),
        ])
    }

    @Test func voiceLaneStripsPartialVisualGuidanceTagsFromSpeech() throws {
        #expect(CompanionManager.stripTrailingVisualGuidanceTagFragment("that area there. [RECT:10,20") == "that area there.")
        #expect(CompanionManager.stripTrailingVisualGuidanceTagFragment("trace here. [SCRIBBLE:1,2;") == "trace here.")
        #expect(CompanionManager.stripTrailingVisualGuidanceTagFragment("look there. [POINT:12") == "look there.")
        #expect(CompanionManager.stripTrailingVisualGuidanceTagFragment("literal bracket [note") == "literal bracket [note")
    }

    @Test func voiceLaneRoutesShapeDrawingRequestsToScreenContext() throws {
        #expect(CompanionManager.testShouldAttachScreenContext(to: "draw a circle around that button"))
        #expect(CompanionManager.testShouldAttachScreenContext(to: "can you put a rectangle around the error"))
        #expect(CompanionManager.testShouldAttachScreenContext(to: "box around the login panel"))
        #expect(CompanionManager.testShouldAttachScreenContext(to: "trace around that shape"))
        #expect(CompanionManager.testShouldAttachScreenContext(to: "let's calibrate the screen"))
        #expect(CompanionManager.testShouldAttachScreenContext(to: "can we calibrate our screens"))
        #expect(CompanionManager.testShouldAttachScreenContext(to: "start screen calibration"))
        #expect(CompanionManager.testShouldAttachScreenContext(to: "enter calibration mode"))
        #expect(CompanionManager.testShouldAttachScreenContext(to: "calibrate this display"))
        #expect(CompanionManager.testShouldAttachScreenContext(to: "can you get an agent to do a screen calibration"))
        #expect(CompanionManager.testIsScreenCalibrationRequest("start screen calibration"))
        #expect(CompanionManager.testIsScreenCalibrationRequest("enter calibration mode"))
        #expect(CompanionManager.testIsScreenCalibrationRequest("calibrate this display"))
        #expect(CompanionManager.testIsScreenCalibrationRequest("can you get an agent to do a screen calibration"))

        #expect(!CompanionManager.testShouldAttachScreenContext(to: "draw me a cheerful mascot idea"))
        #expect(!CompanionManager.testShouldAttachScreenContext(to: "mark this task as done later"))
    }

    @Test func automaticCalibrationAnchorsMapToExpectedCorners() throws {
        let screenFrame = CGRect(x: 100, y: 50, width: 1200, height: 800)

        let apple = CompanionManager.testExpectedVisualGuidanceCalibrationCenter(
            caption: "Apple menu calibration anchor",
            predictedRect: CGRect(x: 120, y: 820, width: 40, height: 20),
            screenFrame: screenFrame
        )
        #expect(Int((apple?.x ?? 0).rounded()) == 142)
        #expect(Int((apple?.y ?? 0).rounded()) == 824)

        let trash = CompanionManager.testExpectedVisualGuidanceCalibrationCenter(
            caption: "Trash calibration anchor",
            predictedRect: CGRect(x: 1230, y: 70, width: 32, height: 32),
            screenFrame: screenFrame
        )
        #expect(Int((trash?.x ?? 0).rounded()) == 1258)
        #expect(Int((trash?.y ?? 0).rounded()) == 76)

        let time = CompanionManager.testExpectedVisualGuidanceCalibrationCenter(
            caption: "time calibration anchor",
            predictedRect: CGRect(x: 1180, y: 822, width: 80, height: 20),
            screenFrame: screenFrame
        )
        #expect(Int((time?.x ?? 0).rounded()) == 1248)
        #expect(Int((time?.y ?? 0).rounded()) == 824)

        let nativeWideTime = CompanionManager.testExpectedVisualGuidanceCalibrationCenter(
            caption: "time calibration anchor",
            predictedRect: CGRect(x: 3680, y: 1545, width: 100, height: 24),
            screenFrame: CGRect(x: 0, y: 0, width: 3840, height: 1620),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 540
        )
        #expect(Int((nativeWideTime?.x ?? 0).rounded()) == 3684)
        #expect(Int((nativeWideTime?.y ?? 0).rounded()) == 1568)
    }

    @Test func calibrationAnchorsAveragePerScreenCoordinateOffset() throws {
        let displayFrame = CGRect(x: 10, y: 20, width: 1440, height: 900)
        CompanionManager.testResetVisualGuidanceCalibration(for: displayFrame)
        defer { CompanionManager.testResetVisualGuidanceCalibration(for: displayFrame) }

        #expect(CompanionManager.testIsVisualGuidanceCalibrationCaption("calibration anchor"))
        #expect(CompanionManager.testIsVisualGuidanceCalibrationCaption("window anchor"))
        #expect(CompanionManager.testIsVisualGuidanceCalibrationCaption("Finder icon calibration anchor"))
        #expect(CompanionManager.testIsVisualGuidanceCalibrationCaption("Trash calibration anchor"))
        #expect(CompanionManager.testIsVisualGuidanceCalibrationCaption("Apple menu calibration anchor"))
        #expect(CompanionManager.testIsVisualGuidanceCalibrationCaption("time calibration anchor"))
        #expect(!CompanionManager.testIsVisualGuidanceCalibrationCaption("normal highlight"))

        let firstOffset = CompanionManager.testUpdateVisualGuidanceCalibrationOffset(
            delta: CGSize(width: 12, height: -6),
            for: displayFrame
        )
        #expect(firstOffset == CGSize(width: 12, height: -6))

        let secondOffset = CompanionManager.testUpdateVisualGuidanceCalibrationOffset(
            delta: CGSize(width: 4, height: 2),
            for: displayFrame
        )
        #expect(secondOffset == CGSize(width: 8, height: -2))
        #expect(CompanionManager.testVisualGuidanceCalibrationOffset(for: displayFrame) == CGSize(width: 8, height: -2))
    }

    @Test func calibrationRejectsRawPixelSizedPoisonOffsets() throws {
        let displayFrame = CGRect(x: 0, y: 0, width: 3840, height: 1620)
        CompanionManager.testResetVisualGuidanceCalibration(for: displayFrame)
        defer { CompanionManager.testResetVisualGuidanceCalibration(for: displayFrame) }

        #expect(CompanionManager.testIsPlausibleVisualGuidanceCalibrationDelta(CGSize(width: 77, height: -22), for: displayFrame))
        #expect(!CompanionManager.testIsPlausibleVisualGuidanceCalibrationDelta(CGSize(width: 655, height: -27), for: displayFrame))
        #expect(!CompanionManager.testIsPlausibleVisualGuidanceCalibrationDelta(CGSize(width: 3655, height: 16), for: displayFrame))

        _ = CompanionManager.testUpdateVisualGuidanceCalibrationOffset(
            delta: CGSize(width: 655, height: -27),
            for: displayFrame
        )
        #expect(CompanionManager.testVisualGuidanceCalibrationOffset(for: displayFrame) == .zero)

        let recoveredOffset = CompanionManager.testUpdateVisualGuidanceCalibrationOffset(
            delta: CGSize(width: 12, height: -4),
            for: displayFrame
        )
        #expect(recoveredOffset == CGSize(width: 12, height: -4))
        #expect(CompanionManager.testVisualGuidanceCalibrationOffset(for: displayFrame) == CGSize(width: 12, height: -4))
    }
}
