import Combine
import SwiftUI

/// Public execution mode for an embedded OpenClicky runtime.
///
/// Use ``embeddedWindow`` for SwiftUI integrations where you want a local,
/// app-owned OpenClicky surface that is independent from any menu-bar experience.
public enum OpenClickySDKMode: Equatable {
    /// Keep the existing menu-bar runtime.
    case menuBar
    /// Run OpenClicky in an in-window runtime suitable for SDK embedding.
    case embeddedWindow
}

/// Optional callbacks for panel controls used by a host app.
///
/// Defaults are no-ops so host apps must decide whether they want to route
/// actions like Settings/HUD/memory into their own surfaces.
public struct OpenClickySDKPanelActions {
    /// Called when the close affordance in the panel UI is activated.
    public var onPanelDismiss: () -> Void
    /// Called when the user taps the "Quit OpenClicky" action.
    public var onQuit: () -> Void
    /// Opens the OpenClicky HUD surface in the host environment.
    public var onOpenHUD: () -> Void
    /// Opens the OpenClicky memory window in the host environment.
    public var onOpenMemory: () -> Void
    /// Opens the OpenClicky feedback/inbox link.
    public var onOpenFeedback: () -> Void
    /// Opens the settings surface in the host environment.
    public var onShowSettings: () -> Void

    public init(
        onPanelDismiss: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {},
        onOpenHUD: @escaping () -> Void = {},
        onOpenMemory: @escaping () -> Void = {},
        onOpenFeedback: @escaping () -> Void = {},
        onShowSettings: @escaping () -> Void = {}
    ) {
        self.onPanelDismiss = onPanelDismiss
        self.onQuit = onQuit
        self.onOpenHUD = onOpenHUD
        self.onOpenMemory = onOpenMemory
        self.onOpenFeedback = onOpenFeedback
        self.onShowSettings = onShowSettings
    }
}

/// Small host-facing session wrapper that starts and configures a
/// self-contained OpenClicky runtime for app embedding.
@MainActor
public final class OpenClickySDKSession: ObservableObject {
    private let manager: CompanionManager
    public let mode: OpenClickySDKMode

    @Published public private(set) var isStarted = false

    public init(mode: OpenClickySDKMode = .embeddedWindow) {
        self.mode = mode
        let runtimeMode: OpenClickyCompanionRuntimeMode = mode == .embeddedWindow ? .embeddedWindow : .menuBar
        self.manager = CompanionManager(runtimeMode: runtimeMode)
    }

    public func start() {
        guard !isStarted else { return }
        manager.start()
        isStarted = true
    }

    public func restart() {
        stop()
        start()
    }

    public func stop() {
        guard isStarted else { return }
        manager.stop()
        isStarted = false
    }

    // MARK: - Prompt + voice entry points

    /// Submit a raw text prompt through the standard text-mode path.
    public func submitTextPrompt(_ prompt: String) {
        manager.submitTextPrompt(prompt)
    }

    /// Submit a prompt into Agent Mode from a panel/HUD-like input.
    public func submitAgentPrompt(_ prompt: String) {
        manager.submitAgentPromptFromUI(prompt)
    }

    /// Begin microphone voice capture for follow-up input.
    public func startVoiceCapture() {
        manager.startSDKVoiceCapture()
    }

    /// End microphone voice capture early.
    public func stopVoiceCapture() {
        manager.stopSDKVoiceCapture()
    }

    // MARK: - Key/secret configuration passthroughs

    public func setAnthropicAPIKey(_ key: String) {
        manager.setAnthropicAPIKey(key)
    }

    public func setCodexAgentAPIKey(_ key: String) {
        // OpenClicky currently routes this through the same API client path.
        manager.setCodexAgentAPIKey(key)
    }

    public func setElevenLabsAPIKey(_ key: String) {
        manager.setElevenLabsAPIKey(key)
    }

    public func setCartesiaAPIKey(_ key: String) {
        manager.setCartesiaAPIKey(key)
    }

    /// Build an embedded panel view pre-wired to this session.
    public func makePanelView(
        isPanelPinned: Bool = false,
        actions: OpenClickySDKPanelActions,
        setPanelPinned: @escaping (Bool) -> Void = { _ in }
    ) -> OpenClickySDKPanel {
        MainActor.assumeIsolated {
            OpenClickySDKPanel(
                companionManager: manager,
                isPanelPinned: isPanelPinned,
                setPanelPinned: setPanelPinned,
                onPanelDismiss: actions.onPanelDismiss,
                onQuit: actions.onQuit,
                onOpenHUD: actions.onOpenHUD,
                onOpenMemory: actions.onOpenMemory,
                onOpenFeedback: actions.onOpenFeedback,
                onShowSettings: actions.onShowSettings
            )
        }
    }

    public func makePanelView(
        isPanelPinned: Bool = false,
        setPanelPinned: @escaping (Bool) -> Void = { _ in }
    ) -> OpenClickySDKPanel {
        makePanelView(
            isPanelPinned: isPanelPinned,
            actions: OpenClickySDKPanelActions(),
            setPanelPinned: setPanelPinned
        )
    }
}

/// A lightweight SwiftUI wrapper around ``CompanionPanelView`` that is safe to
/// embed inside any host NSWindow/NSPanel from a SwiftUI app.
public struct OpenClickySDKPanel: View {
    @ObservedObject private var companionManager: CompanionManager
    @State private var isPanelPinned: Bool

    private let setPanelPinned: (Bool) -> Void
    private let onPanelDismiss: () -> Void
    private let onQuit: () -> Void
    private let onOpenHUD: () -> Void
    private let onOpenMemory: () -> Void
    private let onOpenFeedback: () -> Void
    private let onShowSettings: () -> Void

    init(
        companionManager: CompanionManager,
        isPanelPinned: Bool,
        setPanelPinned: @escaping (Bool) -> Void,
        onPanelDismiss: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onOpenHUD: @escaping () -> Void,
        onOpenMemory: @escaping () -> Void,
        onOpenFeedback: @escaping () -> Void,
        onShowSettings: @escaping () -> Void
    ) {
        self.companionManager = companionManager
        self._isPanelPinned = State(initialValue: isPanelPinned)
        self.setPanelPinned = setPanelPinned
        self.onPanelDismiss = onPanelDismiss
        self.onQuit = onQuit
        self.onOpenHUD = onOpenHUD
        self.onOpenMemory = onOpenMemory
        self.onOpenFeedback = onOpenFeedback
        self.onShowSettings = onShowSettings
    }

    public var body: some View {
        CompanionPanelView(
            companionManager: companionManager,
            isPanelPinned: isPanelPinned,
            setPanelPinned: { pinned in
                isPanelPinned = pinned
                setPanelPinned(pinned)
            },
            onPanelDismiss: onPanelDismiss,
            onQuit: onQuit,
            onOpenHUD: onOpenHUD,
            onOpenMemory: onOpenMemory,
            onOpenFeedback: onOpenFeedback,
            onShowSettings: onShowSettings
        )
    }
}
