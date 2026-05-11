// ThreeDViewerWindowManager.swift
// Floating macOS window that surfaces in-flight + recent 3D-generation jobs
// from ThreeDGenerationService. Opens automatically when a job starts; can be
// shown/hidden via OpenClicky's menu or a keyboard shortcut.

import AppKit
import Combine
import SwiftUI

@MainActor
final class ThreeDViewerWindowManager: ObservableObject {

    static let shared = ThreeDViewerWindowManager()

    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var autoOpenedForJob: UUID?

    init() {
        // Observe the service so the window pops open when a job starts.
        let service = ThreeDGenerationService.shared
        service.$jobs
            .sink { [weak self] jobs in
                guard let self else { return }
                if let latest = jobs.last,
                   latest.status == .queued || latest.status == .running,
                   self.autoOpenedForJob != latest.id {
                    self.autoOpenedForJob = latest.id
                    self.showWindow()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public

    func toggle() {
        if let window, window.isVisible {
            window.close()
        } else {
            showWindow()
        }
    }

    func showWindow() {
        if window == nil {
            window = makeWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    // MARK: - Construction

    private func makeWindow() -> NSWindow {
        let content = ThreeDViewerWindowContent()
            .frame(minWidth: 380, minHeight: 480)
        let hosting = NSHostingController(rootView: content)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "Generated 3D Models"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.setFrameAutosaveName("OpenClicky.ThreeDViewerWindow")
        return window
    }
}

// MARK: - SwiftUI content

private struct ThreeDViewerWindowContent: View {
    @ObservedObject private var service = ThreeDGenerationService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if service.jobs.isEmpty && service.assets.isEmpty {
                        empty
                    }

                    if !service.jobs.isEmpty {
                        Text("In progress")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(service.jobs.reversed()) { job in
                            ThreeDChatBubbleView(
                                mode: .job(job),
                                onRetry: {
                                    ThreeDGenerationService.shared
                                        .generate(prompt: job.prompt, style: job.style)
                                },
                                onCancel: {
                                    ThreeDGenerationService.shared.cancelJob(job.id)
                                }
                            )
                        }
                    }

                    if !service.assets.isEmpty {
                        Text("Recent")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(Array(service.assets.enumerated()), id: \.element.taskId) { _, asset in
                            ThreeDChatBubbleView(
                                mode: .asset(asset),
                                onRetry: {
                                    ThreeDGenerationService.shared
                                        .generate(prompt: asset.prompt, style: asset.style)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cube.transparent.fill").foregroundStyle(.tint)
            Text("Generated 3D")
                .font(.headline)
            Spacer()
            Button {
                ThreeDViewerWindowManager.shared.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No 3D models yet")
                .font(.callout)
            Text("Ask in chat — e.g. \"make me a low-poly fox\" — or send `/3d a friendly mushroom`.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding()
    }
}
