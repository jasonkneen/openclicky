// ThreeDChatBubbleView.swift
// Chat-message-shaped wrapper around ThreeDViewerView with progress, prompt,
// and action buttons (Show in Finder / Copy path / Re-generate).

import SwiftUI
import AppKit

struct ThreeDChatBubbleView: View {

    enum Mode {
        /// A job currently being generated.
        case job(ThreeDJob)
        /// A finished asset.
        case asset(ThreeDGenerationResult)
    }

    let mode: Mode
    var onRetry: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @ObservedObject private var service = ThreeDGenerationService.shared

    init(
        mode: Mode,
        onRetry: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.onRetry = onRetry
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            actions
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
        .frame(maxWidth: 360)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "cube.transparent.fill")
                .foregroundStyle(.tint)
            Text(titleText)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(subtitleText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var titleText: String {
        switch mode {
        case .job(let j):    return j.prompt
        case .asset(let a):  return a.prompt
        }
    }

    private var subtitleText: String {
        switch mode {
        case .job(let j):    return "\(j.providerName) · \(j.style.rawValue)"
        case .asset(let a):  return "\(a.provider) · \(a.style.rawValue)"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .job(let job):
            switch job.status {
            case .success:
                if let url = job.resultGLBURL {
                    ThreeDViewerView(glbURL: url)
                } else {
                    placeholder("Finished but no file. Try re-generating.")
                }
            case .failed:
                placeholder(job.message, systemImage: "exclamationmark.triangle")
            case .cancelled:
                placeholder("Cancelled", systemImage: "stop.circle")
            case .queued, .running:
                progressView(job: job)
            }

        case .asset(let asset):
            ThreeDViewerView(glbURL: asset.glbURL)
        }
    }

    @ViewBuilder
    private func progressView(job: ThreeDJob) -> some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView(value: job.progress, total: 1.0) {
                Text(job.message).font(.caption)
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 220)
            Text("Generating 3D model…")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func placeholder(_ message: String, systemImage: String = "cube.transparent") -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 24))
            Text(message).font(.caption).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.secondary)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if case .job(let j) = mode {
                switch j.status {
                case .running, .queued:
                    Button("Cancel", systemImage: "stop.circle") {
                        onCancel?()
                        service.cancelJob(j.id)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                case .failed, .cancelled:
                    Button("Retry", systemImage: "arrow.clockwise") { onRetry?() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                case .success:
                    if let url = j.resultGLBURL {
                        finderButtons(for: url)
                    }
                }
            }
            if case .asset(let asset) = mode {
                finderButtons(for: asset.glbURL)
                Button("Re-generate", systemImage: "arrow.clockwise") { onRetry?() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            Spacer()
        }
        .font(.caption)
    }

    @ViewBuilder
    private func finderButtons(for url: URL) -> some View {
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .buttonStyle(.borderless)
        .controlSize(.small)

        Button("Copy Path", systemImage: "doc.on.doc") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url.path, forType: .string)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
