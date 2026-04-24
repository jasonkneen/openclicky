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
}
