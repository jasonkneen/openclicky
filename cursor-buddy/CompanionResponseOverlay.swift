//
//  CompanionResponseOverlay.swift
//  cursor-buddy
//
//  Cursor-following overlay that displays streaming AI response text plus a
//  compact Apple / Codex / Claude provider selector. Uses a non-activating
//  NSPanel so it floats without stealing focus. Mouse events are enabled so
//  the selector chips remain tappable; the panel is small and near the cursor.
//

import AppKit
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class CompanionResponseOverlayViewModel: ObservableObject {
    @Published var streamingResponseText: String = ""
    @Published var isShowingResponse: Bool = false
    @Published var providerFamily: OpenClickyVoiceBackendFamily?
    weak var companion: CompanionManager?
}

// MARK: - Overlay Manager

@MainActor
final class CompanionResponseOverlayManager {
    private let overlayViewModel = CompanionResponseOverlayViewModel()
    private var overlayPanel: NSPanel?
    private var cursorTrackingTimer: Timer?
    private var lastCursorTrackingOrigin: NSPoint?
    private var autoHideWorkItem: DispatchWorkItem?
    /// Pure cancel-before-reschedule policy — same type unit tests drive.
    private var autoHidePolicy = ResponseOverlayAutoHidePolicy()
    /// True while the panel is ordered in (including the post-stream hold).
    private(set) var isVisible: Bool = false
    /// Optional callback when the bubble fully hides (auto-fade or explicit).
    var onHidden: (() -> Void)?

    /// The horizontal offset from the cursor to the left edge of the overlay panel.
    private let cursorOffsetX: CGFloat = 22
    /// The vertical offset from the cursor downward to the top edge of the overlay panel.
    private let cursorOffsetY: CGFloat = 6
    /// Maximum width of the overlay panel.
    private let overlayMaxWidth: CGFloat = 360

    func bind(companion: CompanionManager) {
        overlayViewModel.companion = companion
        overlayViewModel.providerFamily = companion.selectedVoiceBackendFamily
    }

    func showOverlayAndBeginStreaming(clearText: Bool = true) {
        cancelPendingAutoHide()

        if clearText {
            overlayViewModel.streamingResponseText = ""
        }
        overlayViewModel.isShowingResponse = true
        if let companion = overlayViewModel.companion {
            overlayViewModel.providerFamily = companion.selectedVoiceBackendFamily
        }
        createOverlayPanelIfNeeded()
        startCursorTracking()
        isVisible = true
        overlayPanel?.alphaValue = 1
        overlayPanel?.orderFrontRegardless()
    }

    func updateStreamingText(_ accumulatedText: String) {
        // Mid-stream updates must cancel any pending auto-hide so an earlier
        // chunk's timer cannot fade the bubble while text is still arriving.
        cancelPendingAutoHide()
        overlayViewModel.streamingResponseText = accumulatedText
        if let companion = overlayViewModel.companion {
            overlayViewModel.providerFamily = companion.selectedVoiceBackendFamily
        }
        resizePanelToFitContent()
    }

    /// Schedule hide after `holdSeconds` of inactivity. Always cancels any
    /// previous pending hide first so only the latest schedule can fire.
    func finishStreaming(holdSeconds: TimeInterval = ResponseOverlayAutoHidePolicy.defaultHoldSeconds) {
        scheduleAutoHide(after: holdSeconds)
    }

    func hideOverlay() {
        cancelPendingAutoHide()
        stopCursorTracking()
        overlayViewModel.isShowingResponse = false
        overlayViewModel.streamingResponseText = ""
        overlayPanel?.orderOut(nil)
        let wasVisible = isVisible
        isVisible = false
        if wasVisible {
            onHidden?()
        }
    }

    /// Cancel a pending auto-hide without hiding. Used while streaming continues.
    func cancelPendingAutoHide() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        autoHidePolicy.cancel()
    }

    /// Test seam: generation from the shared auto-hide policy.
    var autoHideGeneration: UInt64 { autoHidePolicy.generation }
    /// Test seam: true while a non-cancelled hide work item is outstanding.
    var hasPendingAutoHide: Bool {
        guard let autoHideWorkItem else { return false }
        return !autoHideWorkItem.isCancelled && autoHidePolicy.scheduledHideAt != nil
    }

    private func scheduleAutoHide(after holdSeconds: TimeInterval) {
        // Drop any prior DispatchWorkItem first, then advance policy generation
        // via schedule (which cancels-then-schedules).
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        let now = Date().timeIntervalSinceReferenceDate
        let generation = autoHidePolicy.schedule(now: now, holdSeconds: holdSeconds)
        let hideWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Drop stale work items if a newer schedule/cancel happened.
            guard self.autoHidePolicy.isCurrent(generation) else { return }
            self.autoHideWorkItem = nil
            self.autoHidePolicy.cancel()
            self.fadeOutAndHide()
        }
        autoHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, holdSeconds), execute: hideWork)
    }

    // MARK: - Private

    private func createOverlayPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: overlayMaxWidth, height: 56)
        let responseOverlayPanel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        responseOverlayPanel.level = .statusBar
        responseOverlayPanel.isOpaque = false
        responseOverlayPanel.backgroundColor = .clear
        responseOverlayPanel.hasShadow = false
        // Selector chips need clicks. The panel is tiny and only visible while
        // a response is on-screen, so this does not block normal desktop work.
        responseOverlayPanel.ignoresMouseEvents = false
        responseOverlayPanel.hidesOnDeactivate = false
        responseOverlayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        responseOverlayPanel.isExcludedFromWindowsMenu = true

        let hostingView = NSHostingView(
            rootView: CompanionResponseOverlayView(viewModel: overlayViewModel)
                .frame(maxWidth: overlayMaxWidth)
        )
        OpenClickyLiquidGlassWindowSurface.install(
            hostingView: hostingView,
            in: responseOverlayPanel,
            frame: initialFrame,
            cornerRadius: 14,
            strength: .compact
        )

        overlayPanel = responseOverlayPanel
    }

    private func startCursorTracking() {
        guard cursorTrackingTimer == nil else { return }
        lastCursorTrackingOrigin = nil

        // Keep the response bubble glued to the cursor during drags/menus, but
        // avoid queueing extra MainActor tasks every frame. The timer already
        // fires on the main run loop (`.common`), so the closure is already
        // main-thread / main-actor-isolated.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionPanelNearCursor()
            }
        }
        cursorTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopCursorTracking() {
        cursorTrackingTimer?.invalidate()
        cursorTrackingTimer = nil
        lastCursorTrackingOrigin = nil
    }

    private func repositionPanelNearCursor() {
        guard let overlayPanel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let panelSize = overlayPanel.frame.size

        // Position the panel to the right of and slightly below the cursor.
        // In macOS screen coordinates, Y increases upward, so "below" means
        // subtracting from the cursor Y.
        var panelOriginX = mouseLocation.x + cursorOffsetX
        var panelOriginY = mouseLocation.y - cursorOffsetY - panelSize.height

        // Clamp to the visible frame of the screen containing the cursor
        // so the panel never goes off-screen.
        if let currentScreen = NSScreen.screen(containingOrNearestTo: mouseLocation) {
            let visibleFrame = currentScreen.visibleFrame

            // If the panel would go off the right edge, flip it to the left of the cursor
            if panelOriginX + panelSize.width > visibleFrame.maxX {
                panelOriginX = mouseLocation.x - cursorOffsetX - panelSize.width
            }

            // If the panel would go below the bottom edge, push it above the cursor
            if panelOriginY < visibleFrame.minY {
                panelOriginY = mouseLocation.y + cursorOffsetY
            }

            // Final clamp
            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelSize.width))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelSize.height))
        }

        let nextOrigin = CGPoint(x: panelOriginX.rounded(.toNearestOrAwayFromZero), y: panelOriginY.rounded(.toNearestOrAwayFromZero))
        if let lastCursorTrackingOrigin,
           abs(lastCursorTrackingOrigin.x - nextOrigin.x) < 0.5,
           abs(lastCursorTrackingOrigin.y - nextOrigin.y) < 0.5 {
            return
        }
        lastCursorTrackingOrigin = nextOrigin
        overlayPanel.setFrameOrigin(nextOrigin)
    }

    private func resizePanelToFitContent() {
        guard let overlayPanel, let contentView = overlayPanel.contentView else { return }

        let fittingSize = contentView.fittingSize
        let newWidth = min(fittingSize.width, overlayMaxWidth)
        let newHeight = fittingSize.height

        // Keep the panel origin relative to the cursor (the timer handles that),
        // but update the frame size so the content fits.
        var frame = overlayPanel.frame
        let heightDelta = newHeight - frame.height
        frame.size = CGSize(width: newWidth, height: newHeight)
        // Adjust origin Y so the panel grows upward (toward the cursor), not downward
        frame.origin.y -= heightDelta
        overlayPanel.setFrame(frame, display: true)
        contentView.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func fadeOutAndHide() {
        guard let overlayPanel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            overlayPanel.animator().alphaValue = 0
        }, completionHandler: { [self] in
            Task { @MainActor in
                hideOverlay()
            }
        })
    }

}

// MARK: - SwiftUI View

private struct CompanionResponseOverlayView: View {
    @ObservedObject var viewModel: CompanionResponseOverlayViewModel

    var body: some View {
        if viewModel.isShowingResponse {
            VStack(alignment: .leading, spacing: 6) {
                if let companion = viewModel.companion {
                    OpenClickyVoiceBackendSelector(companion: companion, style: .compact)
                } else if let family = viewModel.providerFamily {
                    Text(family.displayName)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Text(viewModel.streamingResponseText.isEmpty ? "..." : viewModel.streamingResponseText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
            )
        }
    }
}
