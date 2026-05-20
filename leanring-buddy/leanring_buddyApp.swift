//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import AppKit
import Carbon
import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene, while the app menu command below routes to OpenClicky's full
        // custom settings dialog instead of showing this placeholder scene.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showSettingsWindowFromApplicationMenu()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private static let sparkleFeedOverrideDefaultsKey = "OpenClickySparkleFeedURLOverride"
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("OpenClicky: Starting...")
        print("OpenClicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        // Terminate any duplicate running instances of OpenClicky to prevent port (error 48) and permission conflicts
        let currentApp = NSRunningApplication.current
        let runningApps = NSWorkspace.shared.runningApplications
        if let bundleID = currentApp.bundleIdentifier {
            let duplicateApps = runningApps.filter { app in
                app.bundleIdentifier == bundleID && app.processIdentifier != currentApp.processIdentifier
            }
            for app in duplicateApps {
                print("OpenClicky: Terminating duplicate running instance (PID: \(app.processIdentifier)) to free resources/ports.")
                app.terminate()
            }
            if !duplicateApps.isEmpty {
                // Give the system a brief moment to release TCP sockets and file handles
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()
        OpenClickyDesktopNotificationCenter.shared.configure()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        companionManager.scheduleWidgetSnapshotPublish()
        registerAsLoginItemIfNeeded()
        startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { companionManager.handleApplicationOpenURL($0) }
    }

    func showSettingsWindowFromApplicationMenu() {
        companionManager.showSettingsWindow()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("OpenClicky: Registered as login item")
            } catch {
                print("OpenClicky: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.sparkleUpdaterController = updaterController

        if Self.sparkleFeedOverrideURLString() != nil {
            DispatchQueue.main.async {
                updaterController.updater.checkForUpdatesInBackground()
            }
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let override = Self.sparkleFeedOverrideURLString() else { return nil }
        print("OpenClicky: Using Sparkle feed override: \(override)")
        return override
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        NSApp.activate(ignoringOtherApps: true)
        menuBarPanelManager?.showPanelOnLaunch()
    }

    private static func sparkleFeedOverrideURLString() -> String? {
        let override = UserDefaults.standard.string(forKey: sparkleFeedOverrideDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let override, !override.isEmpty else { return nil }
        guard let url = URL(string: override),
              ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") else {
            print("OpenClicky: Ignoring invalid Sparkle feed override: \(override)")
            return nil
        }

        if url.scheme?.lowercased() == "http" {
            let host = url.host?.lowercased() ?? ""
            guard host == "localhost" || host == "127.0.0.1" || host == "::1" else {
                print("OpenClicky: Ignoring non-local HTTP Sparkle feed override: \(override)")
                return nil
            }
        }

        return override
    }
}
