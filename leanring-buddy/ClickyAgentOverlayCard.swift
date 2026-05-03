import SwiftUI
import AppKit

/// Three softly-pulsing dots used as a "thinking" affordance while the
/// agent has not produced its first streamed token yet. Replaces the
/// previous static "An agent is working on this." string.
struct ClickyThinkingDots: View {
    let tint: Color
    @State private var phase: Int = 0
    /// Stored handle for the phase-cycling task so we can cancel it in
    /// `onDisappear`. Without this, every remount of the view (dock
    /// hide/show, hover-card toggle) leaks another infinite task.
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint.opacity(opacity(for: index)))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            // Cancel any prior task before starting a fresh one — guards
            // against duplicate `onAppear` events during transitions.
            animationTask?.cancel()
            animationTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 360_000_000)
                    if Task.isCancelled { return }
                    phase = (phase + 1) % 3
                }
            }
        }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
        }
    }

    private func opacity(for index: Int) -> Double {
        index == phase ? 0.95 : 0.32
    }
}

struct ClickyAgentDockHoverCard: View {
    let item: ClickyAgentDockItem
    let canOpenDashboard: Bool
    let chat: () -> Void
    let text: () -> Void
    let voice: () -> Void
    let close: () -> Void
    let stop: () -> Void
    /// Called when the user taps "Dismiss" on a terminal (`.done`/`.failed`)
    /// agent. Distinct from `stop` (which sends a cancel signal) — this
    /// just removes the dock item visually.
    let dismiss: () -> Void
    let runSuggestedAction: (String) -> Void
    @State private var isConfirmingStop = false
    @State private var hoveredQuickAction: QuickAction? = nil
    @State private var statusLineCycleIndex = 0
    @State private var statusLineCycleTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(displayTitle)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundColor(titleAccentColor)
                    .kerning(1.4)
                    .fixedSize(horizontal: false, vertical: true)

                Text(statusText)
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundColor(titleAccentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(statusBackgroundColor))
                    .overlay(
                        Capsule()
                            .stroke(titleAccentColor.opacity(0.34), lineWidth: 0.8)
                    )

                Spacer()
            }
            .padding(.trailing, 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("Stage: \(item.progressStageLabel)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)

                if let statusLine = currentStatusLine {
                    Text("\(statusLineLabel): \(statusLine)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                } else {
                    Text(" ")
                        .font(.system(size: 11, weight: .regular))
                        .lineLimit(2)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 36, alignment: .topLeading)
            .padding(.top, 2)

            agentProgressContent
                .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .topLeading)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                if !item.suggestedNextActions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(item.suggestedNextActions, id: \.self) { actionTitle in
                            Button(action: {
                                runSuggestedAction(actionTitle)
                            }) {
                                Text(actionTitle)
                            }
                            .buttonStyle(ClickyAgentDockPillButtonStyle())
                        }
                    }
                    .frame(height: 28, alignment: .leading)
                } else {
                    Color.clear
                        .frame(height: 28)
                }

                bottomActionRow
            }
            .padding(.top, 12)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .heavy))
            }
            .buttonStyle(ClickyAgentGlassCloseButtonStyle())
            .help("Close")
            .offset(x: 8, y: -8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 500, height: 236, alignment: .leading)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            item.accentTheme.cursorColor.opacity(0.18),
                            Color(hex: "#111827").opacity(0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(item.accentTheme.cursorColor.opacity(0.20), lineWidth: 1.2)
        )
        .onAppear { restartStatusLineCycle() }
        .onDisappear {
            statusLineCycleTask?.cancel()
            statusLineCycleTask = nil
        }
        .onChange(of: item.activityStatusLines) { _, _ in
            restartStatusLineCycle()
        }
        .onChange(of: item.progressStepText ?? "") { _, _ in
            restartStatusLineCycle()
        }
    }

    @ViewBuilder
    private var agentProgressContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let trimmedCaption,
               !trimmedCaption.isEmpty {
                Text(trimmedCaption)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.82)
            } else {
                // No real activity yet — surface a thinking indicator
                // instead of the canned "An agent is working on this." line.
                switch item.status {
                case .starting, .running:
                    ClickyThinkingDots(tint: item.accentTheme.cursorColor)
                case .done:
                    Text("Done.")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(item.accentTheme.cursorColor)
                case .failed:
                    Text("Needs attention.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                }
            }

            if let linkTarget {
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(linkTarget)
                    } label: {
                        Label(linkButtonTitle(for: linkTarget), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(ClickyAgentDockPillButtonStyle())

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var trimmedCaption: String? {
        guard let trimmed = item.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered == "checking the work" || lowered == "check the work" {
            return nil
        }
        return trimmed
    }

    private var statusLineLabel: String {
        activityStatusLines.count > 1 ? "Update" : "Step"
    }

    private var currentStatusLine: String? {
        let lines = activityStatusLines
        guard !lines.isEmpty else { return nil }
        let safeIndex = min(statusLineCycleIndex, lines.count - 1)
        return lines[safeIndex]
    }

    private var activityStatusLines: [String] {
        var lines: [String] = []
        for candidate in item.activityStatusLines + [item.progressStepText ?? ""] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if lines.last != trimmed {
                lines.append(trimmed)
            }
        }
        return lines
    }

    private func restartStatusLineCycle() {
        statusLineCycleTask?.cancel()
        statusLineCycleTask = nil
        let lines = activityStatusLines
        statusLineCycleIndex = 0
        guard lines.count > 1 else { return }

        statusLineCycleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_900_000_000)
                if Task.isCancelled { return }
                let count = activityStatusLines.count
                guard count > 1 else { continue }
                withAnimation(.easeInOut(duration: 0.18)) {
                    statusLineCycleIndex = (statusLineCycleIndex + 1) % count
                }
            }
        }
    }

    private var bottomActionRow: some View {
        HStack(spacing: 8) {
            quickActionButtons
            Spacer(minLength: 12)
            terminalActionButton
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
    }

    private var quickActionButtons: some View {
        HStack(spacing: 8) {
            HoverExpandIconActionButton(icon: "mic", label: "Voice", isExpanded: hoveredQuickAction == .voice, action: voice)
                .onHover { hoveredQuickAction = $0 ? .voice : nil }
            HoverExpandIconActionButton(icon: "text.cursor", label: "Text", isExpanded: hoveredQuickAction == .text, action: text)
                .onHover { hoveredQuickAction = $0 ? .text : nil }
            if canOpenDashboard {
                HoverExpandIconActionButton(icon: "message", label: "Chat", isExpanded: hoveredQuickAction == .dashboard, action: chat)
                    .onHover { hoveredQuickAction = $0 ? .dashboard : nil }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var terminalActionButton: some View {
        if item.status == .starting || item.status == .running {
            Button {
                isConfirmingStop = true
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .buttonStyle(ClickyAgentDockStopButtonStyle(isConfirming: false))
            .confirmationDialog("Stop this agent?", isPresented: $isConfirmingStop, titleVisibility: .visible) {
                Button("Stop", role: .destructive, action: stop)
                Button("Keep running", role: .cancel) {}
            }
        } else if item.status == .done || item.status == .failed {
            Button(action: dismiss) { Label("Dismiss", systemImage: "trash") }
                .buttonStyle(ClickyAgentDockPillButtonStyle())
        }
    }

    private enum QuickAction { case voice, text, dashboard }

    private var linkTarget: URL? {
        // Only scan the live caption — the previous version scanned the
        // canned "An agent is working on this." fallback, which never
        // contained a link anyway.
        Self.firstOpenableURL(in: item.caption ?? "")
    }

    private func linkButtonTitle(for url: URL) -> String {
        url.isFileURL ? "Open \(url.lastPathComponent)" : "Open link"
    }

    private static func firstOpenableURL(in text: String) -> URL? {
        let patterns = [
            #"`((?:file://)?/[^`]+)`"#,
            #"((?:file://)?/Users/[^\s`]+)"#,
            #"(https?://[^\s`]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "`'\".,)\n\t "))
            if raw.hasPrefix("file://"), let url = URL(string: raw) {
                return url
            }
            if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                return URL(string: raw)
            }
            if raw.hasPrefix("/") {
                return URL(fileURLWithPath: raw)
            }
        }
        return nil
    }

    private var displayTitle: String {
        let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "HEY THERE" : trimmedTitle.uppercased()
    }

    private var statusText: String {
        switch item.status {
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        }
    }

    private var titleAccentColor: Color {
        item.accentTheme.cursorColor.opacity(0.95)
    }

    private var statusBackgroundColor: Color {
        switch item.status {
        case .failed:
            return DS.Colors.destructive.opacity(0.20)
        case .starting, .running, .done:
            return item.accentTheme.cursorColor.opacity(0.18)
        }
    }

}


struct ClickyAgentGlassCloseButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(DS.Colors.textPrimary.opacity(isHovered ? 1.0 : 0.82))
            .frame(width: 30, height: 30)
            .background(.ultraThinMaterial, in: Circle())
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : (isHovered ? 0.14 : 0.08)))
            )
            .overlay(
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(isHovered ? 0.42 : 0.28), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.94 : (isHovered ? 1.04 : 1.0))
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .pointerCursor()
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

struct HoverExpandIconActionButton: View {
    let icon: String
    let label: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                if isExpanded { Text(label) }
            }
        }
        .buttonStyle(ClickyAgentDockPillButtonStyle())
    }
}

struct ClickyAgentDockStopButtonStyle: ButtonStyle {
    let isConfirming: Bool
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(isConfirming ? Color.white : Color(hex: "#FFB4BA"))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isConfirming ? Color(hex: "#B91C1C").opacity(configuration.isPressed ? 0.95 : 0.82) : Color(hex: "#7F1D1D").opacity(isHovered ? 0.38 : 0.22))
            )
            .overlay(
                Capsule()
                    .stroke(Color(hex: "#FF6369").opacity(isHovered || isConfirming ? 0.50 : 0.28), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .pointerCursor()
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

struct ClickyAgentDockPillButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : (isHovered ? 0.14 : 0.10)))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isHovered ? 0.24 : 0.14), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .pointerCursor()
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
