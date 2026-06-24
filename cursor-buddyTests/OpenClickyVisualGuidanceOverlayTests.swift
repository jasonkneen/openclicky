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

    @Test func bridgeDescriptorsExposeNativeComputerUseTools() throws {
        let toolNames = OpenClickyExternalControlBridgeServer.testMCPToolDescriptors.compactMap { descriptor in
            descriptor["name"] as? String
        }

        for expectedTool in [
            "openclicky_native_status",
            "openclicky_native_apps",
            "openclicky_native_windows",
            "openclicky_native_focused_window",
            "openclicky_native_capture_window",
            "openclicky_native_type_text",
            "openclicky_native_press_key",
            "openclicky_workflow",
            "openclicky_click",
            "screenshot",
            "speak",
            "notify",
            "clear",
        ] {
            #expect(toolNames.contains(expectedTool), "Missing tool descriptor: \(expectedTool)")
        }
    }

    @Test func bridgeExposesUTCPManualForNativeToolsAndWorkflow() throws {
        let manual = OpenClickyExternalControlBridgeServer.testUTCPManual(port: 32123)
        #expect(manual["manual_version"] as? String == "1.0.0")
        #expect(manual["utcp_version"] as? String == "1.1.0")

        let auth = try #require(manual["auth"] as? [String: Any])
        #expect(auth["auth_type"] as? String == "api_key")
        #expect(auth["var_name"] as? String == "Authorization")

        let tools = try #require(manual["tools"] as? [[String: Any]])
        let toolNames = tools.compactMap { $0["name"] as? String }
        #expect(toolNames.contains("openclicky_native_type_text"))
        #expect(toolNames.contains("openclicky_native_press_key"))
        #expect(toolNames.contains("openclicky_workflow"))

        let typeText = try #require(tools.first { $0["name"] as? String == "openclicky_native_type_text" })
        let typeTemplate = try #require(typeText["tool_call_template"] as? [String: Any])
        #expect(typeTemplate["call_template_type"] as? String == "http")
        #expect(typeTemplate["http_method"] as? String == "POST")
        #expect((typeTemplate["url"] as? String)?.hasSuffix("/utcp/tools/openclicky_native_type_text") == true)

        let workflow = try #require(tools.first { $0["name"] as? String == "openclicky_workflow" })
        let workflowTemplate = try #require(workflow["tool_call_template"] as? [String: Any])
        #expect((workflowTemplate["url"] as? String)?.hasSuffix("/utcp/workflow") == true)
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

    @Test func bridgeParsesNativeComputerUseToolCalls() throws {
        let typeText = OpenClickyExternalControlBridgeServer.testCommand(from: [
            "tool": "openclicky_native_type_text",
            "arguments": ["text": "hello", "delayMs": 25],
        ])
        if case .nativeTypeText(let text, let delayMilliseconds) = typeText {
            #expect(text == "hello")
            #expect(delayMilliseconds == 25)
        } else {
            Issue.record("Expected native type text command")
        }

        let pressKey = OpenClickyExternalControlBridgeServer.testCommand(from: [
            "tool": "native_press_key",
            "arguments": ["key": "k", "modifiers": ["command", "shift"]],
        ])
        if case .nativePressKey(let key, let modifiers) = pressKey {
            #expect(key == "k")
            #expect(modifiers == ["command", "shift"])
        } else {
            Issue.record("Expected native press key command")
        }

        let workflow = OpenClickyExternalControlBridgeServer.testCommand(from: [
            "tool": "openclicky_workflow",
            "arguments": [
                "steps": [
                    ["tool": "openclicky_native_status", "arguments": [:]],
                    ["tool": "openclicky_native_press_key", "arguments": ["key": "escape"], "delayMs": 25],
                ],
                "stopOnError": true,
            ],
        ])
        if case .workflow(let steps, let stopOnError) = workflow {
            #expect(steps.count == 2)
            #expect(steps[0].name == "openclicky_native_status")
            #expect(steps[1].name == "openclicky_native_press_key")
            #expect(steps[1].delay == 0.025)
            #expect(stopOnError)
        } else {
            Issue.record("Expected workflow command")
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
