//
//  AgentChatUI.swift
//  Shared agent transcript + status visuals for panel and HUD.
//

import AppKit
import SwiftUI

// MARK: - Voice follow-up capture (dock + HUD)

struct AgentVoiceFollowUpCaptureBanner: View {
    let phase: OpenClickyAgentVoiceFollowUpCapturePhase
    var audioLevel: CGFloat
    let onCancel: () -> Void
    @AppStorage(OpenClickyAgentPreferences.followUpAttachScreenKey) private var agentFollowUpAttachScreen = true

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusLeading
                .frame(width: 28, height: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(titleText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            listeningMeter

            Toggle(isOn: $agentFollowUpAttachScreen) {
                Text("Screen")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .toggleStyle(.checkbox)
            .help("Attach desktop screenshot with this follow-up. Turn off for text-only.")

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(DS.Colors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 6)
    }

    @ViewBuilder
    private var statusLeading: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .preparing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.9)
        case .listening:
            ZStack {
                Circle()
                    .fill(DS.Colors.destructive.opacity(0.22))
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.destructiveText)
            }
        case .processing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.9)
        }
    }

    @ViewBuilder
    private var listeningMeter: some View {
        if phase == .listening {
            GeometryReader { geo in
                let level = min(1, max(0, audioLevel))
                let w = max(6, min(geo.size.width, level * geo.size.width * 2.2 + 8))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(DS.Colors.surface3)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(DS.Colors.accent.opacity(0.92))
                        .frame(width: w, height: 6)
                }
            }
            .frame(width: 72, height: 10)
        }
    }

    private var titleText: String {
        switch phase {
        case .idle: return ""
        case .preparing: return "Preparing microphone"
        case .listening: return "Listening"
        case .processing: return "Finishing up"
        }
    }

    private var subtitleText: String {
        switch phase {
        case .idle: return ""
        case .preparing:
            return "Hang on — OpenClicky is waking the mic. The blue waveform on your cursor also means we’re live."
        case .listening:
            return "Speak your follow-up. We send it after you pause (about 8s max per take)."
        case .processing:
            return "Turning speech into text…"
        }
    }
}

// MARK: - Density

enum AgentChatDensity {
    case panel
    case hud

    fileprivate var bodySize: CGFloat {
        switch self {
        case .panel: return 10
        case .hud: return 11
        }
    }

    fileprivate var verticalPadding: CGFloat {
        switch self {
        case .panel: return 6
        case .hud: return 8
        }
    }

    fileprivate var horizontalPadding: CGFloat {
        switch self {
        case .panel: return 9
        case .hud: return 10
        }
    }
}

// MARK: - Status pill

struct AgentStatusPill: View {
    let title: String
    let subtitle: String?
    let indicatorColor: Color

    init(title: String, subtitle: String? = nil, indicatorColor: Color) {
        self.title = title
        self.subtitle = subtitle
        self.indicatorColor = indicatorColor
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Session output links (panel + HUD)

struct AgentSessionOutputsStrip: View {
    var workspaceDirectoryPath: String
    var fileURLs: [URL]
    var showWorkspaceLink: Bool

    var body: some View {
        let trimmed = workspaceDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let showFolder = showWorkspaceLink && !trimmed.isEmpty
        if fileURLs.isEmpty, !showFolder {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if showFolder {
                        sessionOutputChip(title: "Output folder", systemImage: "folder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: trimmed))
                        }
                    }
                    ForEach(Array(fileURLs.prefix(12)), id: \.path) { url in
                        sessionOutputChip(title: url.lastPathComponent, systemImage: "doc.text") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
    }

    private func sessionOutputChip(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .medium))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(DS.Colors.surface3)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - Transcript bubble

struct AgentChatBubble: View {
    let entry: CodexTranscriptEntry
    var density: AgentChatDensity

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if stripeWidth > 0 {
                Rectangle()
                    .fill(stripeFill)
                    .frame(width: stripeWidth)
            }

            VStack(alignment: .leading, spacing: density == .panel ? 3 : 4) {
                Text(Self.roleLabel(for: entry.role))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text(entry.text)
                    .font(.system(size: density.bodySize, design: entry.role == .command ? .monospaced : .default))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, stripeWidth > 0 ? 9 : density.horizontalPadding)
            .padding(.trailing, density.horizontalPadding)
            .padding(.vertical, density.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(fillColor)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private var stripeWidth: CGFloat {
        switch entry.role {
        case .user, .system: return 3
        case .command, .plan: return 2
        case .assistant: return 0
        }
    }

    private var stripeFill: Color {
        switch entry.role {
        case .user: return DS.Colors.accent
        case .assistant: return .clear
        case .system: return DS.Colors.destructive.opacity(0.85)
        case .command: return DS.Colors.textTertiary.opacity(0.7)
        case .plan: return DS.Colors.info.opacity(0.55)
        }
    }

    private var fillColor: Color {
        switch entry.role {
        case .user: return DS.Colors.surface3
        case .assistant: return DS.Colors.surface2
        case .system: return DS.Colors.destructive.opacity(0.09)
        case .command, .plan: return DS.Colors.surface2
        }
    }

    private static func roleLabel(for role: CodexTranscriptEntry.Role) -> String {
        switch role {
        case .user: return "You"
        case .assistant: return "OpenClicky"
        case .system: return "System"
        case .command: return "Command"
        case .plan: return "Plan"
        }
    }
}
