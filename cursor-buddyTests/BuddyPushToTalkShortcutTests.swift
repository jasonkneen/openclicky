import AppKit
import XCTest
@testable import OpenClicky

final class BuddyPushToTalkShortcutTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.userVoicePushToTalkShortcutDefaultsKey)
        super.tearDown()
    }

    func testDefaultShortcutIsCommandOption() {
        UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.userVoicePushToTalkShortcutDefaultsKey)

        XCTAssertEqual(BuddyPushToTalkShortcut.currentShortcutOption, .commandOption)
        XCTAssertEqual(BuddyPushToTalkShortcut.pushToTalkDisplayText, "command + option")
    }

    func testCommandOptionTransitionsOnModifierPressAndRelease() {
        UserDefaults.standard.set(
            BuddyPushToTalkShortcut.ShortcutOption.commandOption.rawValue,
            forKey: AppBundleConfiguration.userVoicePushToTalkShortcutDefaultsKey
        )

        let modifierFlags = NSEvent.ModifierFlags([.command, .option]).rawValue
        assertTransition(
            BuddyPushToTalkShortcut.shortcutTransition(
                for: .flagsChanged,
                keyCode: 0,
                modifierFlagsRawValue: UInt64(modifierFlags),
                wasShortcutPreviouslyPressed: false
            ),
            is: .pressed
        )
        assertTransition(
            BuddyPushToTalkShortcut.shortcutTransition(
                for: .flagsChanged,
                keyCode: 0,
                modifierFlagsRawValue: 0,
                wasShortcutPreviouslyPressed: true
            ),
            is: .released
        )
    }

    func testCommandOptionPeriodTransitionsOnKeyDownAndKeyUp() {
        UserDefaults.standard.set(
            BuddyPushToTalkShortcut.ShortcutOption.commandOptionPeriod.rawValue,
            forKey: AppBundleConfiguration.userVoicePushToTalkShortcutDefaultsKey
        )

        let modifierFlags = NSEvent.ModifierFlags([.command, .option]).rawValue
        assertTransition(
            BuddyPushToTalkShortcut.shortcutTransition(
                for: .keyDown,
                keyCode: 47,
                modifierFlagsRawValue: UInt64(modifierFlags),
                wasShortcutPreviouslyPressed: false
            ),
            is: .pressed
        )
        assertTransition(
            BuddyPushToTalkShortcut.shortcutTransition(
                for: .keyUp,
                keyCode: 47,
                modifierFlagsRawValue: UInt64(modifierFlags),
                wasShortcutPreviouslyPressed: true
            ),
            is: .released
        )
    }

    func testLegacyControlOptionModifierOnlyShortcutStillWorksWhenSelected() {
        UserDefaults.standard.set(
            BuddyPushToTalkShortcut.ShortcutOption.controlOption.rawValue,
            forKey: AppBundleConfiguration.userVoicePushToTalkShortcutDefaultsKey
        )

        let modifierFlags = NSEvent.ModifierFlags([.control, .option]).rawValue
        assertTransition(
            BuddyPushToTalkShortcut.shortcutTransition(
                for: .flagsChanged,
                keyCode: 0,
                modifierFlagsRawValue: UInt64(modifierFlags),
                wasShortcutPreviouslyPressed: false
            ),
            is: .pressed
        )
    }

    private func assertTransition(
        _ actual: BuddyPushToTalkShortcut.ShortcutTransition,
        is expected: BuddyPushToTalkShortcut.ShortcutTransition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.none, .none), (.pressed, .pressed), (.released, .released):
            return
        default:
            XCTFail("Expected \(expected), got \(actual)", file: file, line: line)
        }
    }
}
