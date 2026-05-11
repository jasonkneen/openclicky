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

struct OpenClickyOpenableLink: Identifiable, Hashable {
    let url: URL

    var id: String { url.absoluteString }

    var buttonTitle: String {
        guard url.isFileURL else { return "Open link" }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "Open folder"
        }
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Open file" : "Open \(name)"
    }

    var systemImageName: String {
        guard url.isFileURL else { return "arrow.up.right.square" }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "folder"
        }
        return "doc"
    }
}

enum OpenClickyOpenableLinkExtractor {
    static func links(in text: String, limit: Int = 3) -> [OpenClickyOpenableLink] {
        guard !text.isEmpty, limit > 0 else { return [] }
        var urls: [URL] = []
        appendWebLinks(from: text, to: &urls)
        appendFileLinks(from: text, to: &urls)

        var seen = Set<String>()
        return urls.compactMap { url -> OpenClickyOpenableLink? in
            let key = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
            guard seen.insert(key).inserted else { return nil }
            return OpenClickyOpenableLink(url: url)
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func appendWebLinks(from text: String, to urls: inout [URL]) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let url = match?.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            urls.append(url)
        }
    }

    private static func appendFileLinks(from text: String, to urls: inout [URL]) {
        for line in text.components(separatedBy: .newlines) {
            urls.append(contentsOf: fileURLs(inLine: line))
        }
    }

    private static func fileURLs(inLine line: String) -> [URL] {
        var results: [URL] = []
        var searchStart = line.startIndex
        while searchStart < line.endIndex,
              let range = line.range(of: #"(?:file://)?/Users/"#, options: .regularExpression, range: searchStart..<line.endIndex) {
            let rawCandidate = String(line[range.lowerBound..<line.endIndex])
            if let url = resolvedFileURL(from: rawCandidate) {
                results.append(url)
            }
            searchStart = range.upperBound
        }
        return results
    }

    private static func resolvedFileURL(from rawCandidate: String) -> URL? {
        var candidate = rawCandidate
            .replacingOccurrences(of: "file://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "`'\" <>[]{}"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        candidate = trimTrailingSentencePunctuation(candidate)

        let fileManager = FileManager.default
        while !candidate.isEmpty {
            let expanded = (candidate as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
            guard let lastSpace = candidate.lastIndex(where: { $0 == " " || $0 == "\t" }) else { break }
            candidate = String(candidate[..<lastSpace])
            candidate = trimTrailingSentencePunctuation(candidate)
        }
        return nil
    }

    private static func trimTrailingSentencePunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)\n\t "))
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
    private static let agentProgressBottomID = "agent-progress-bottom"

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
                if hasTaskActionButtons {
                    HStack(spacing: 8) {
                        ForEach(item.suggestedNextActions, id: \.self) { actionTitle in
                            Button(action: {
                                runSuggestedAction(actionTitle)
                            }) {
                                Text(actionTitle)
                            }
                            .buttonStyle(ClickyAgentDockPillButtonStyle())
                        }

                        ForEach(linkTargets) { link in
                            Button {
                                NSWorkspace.shared.open(link.url)
                            } label: {
                                Label(link.buttonTitle, systemImage: link.systemImageName)
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
            .offset(x: 13, y: -3)
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
        .onChange(of: item.status) { _, _ in
            restartStatusLineCycle()
        }
    }

    @ViewBuilder
    private var agentProgressContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    if let trimmedCaption,
                       !trimmedCaption.isEmpty {
                        Text(trimmedCaption)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                            Text("Stopped.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.agentProgressBottomID)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.vertical, 8)
            }
            .mask(ClickyAgentProgressScrollFadeMask())
            .onAppear { scrollAgentProgressToBottom(proxy, animated: false) }
            .onChange(of: agentProgressScrollKey) { _, _ in
                scrollAgentProgressToBottom(proxy, animated: true)
            }
        }
    }


    private var agentProgressScrollKey: String {
        [
            trimmedCaption ?? "",
            currentStatusLine ?? "",
            statusText
        ].joined(separator: "\u{1F}")
    }

    private func scrollAgentProgressToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            let action = {
                proxy.scrollTo(Self.agentProgressBottomID, anchor: .bottom)
            }
            if animated {
                withAnimation(.easeOut(duration: 0.18), action)
            } else {
                action()
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
        if isTerminalStatus { return "Final" }
        return activityStatusLines.count > 1 ? "Update" : "Step"
    }

    private var currentStatusLine: String? {
        let lines = activityStatusLines
        guard !lines.isEmpty else { return nil }
        if isTerminalStatus {
            return lines.last
        }
        let safeIndex = min(statusLineCycleIndex, lines.count - 1)
        return lines[safeIndex]
    }

    private var isTerminalStatus: Bool {
        item.status == .done || item.status == .failed
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
        statusLineCycleIndex = isTerminalStatus ? max(lines.count - 1, 0) : 0
        guard !isTerminalStatus else { return }
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
                Image(systemName: "stop.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .accessibilityLabel("Stop")
            .help("Stop")
            .buttonStyle(ClickyAgentDockStopButtonStyle(isConfirming: false))
            .confirmationDialog("Stop this agent?", isPresented: $isConfirmingStop, titleVisibility: .visible) {
                Button("Stop", role: .destructive, action: stop)
                Button("Keep running", role: .cancel) {}
            }
        } else if item.status == .done || item.status == .failed {
            Button(action: dismiss) {
                Image(systemName: "archivebox")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .accessibilityLabel("Archive")
            .help("Archive")
                .buttonStyle(ClickyAgentDockPillButtonStyle())
        }
    }

    private enum QuickAction { case voice, text, dashboard }

    private var hasTaskActionButtons: Bool {
        !item.suggestedNextActions.isEmpty || !linkTargets.isEmpty
    }

    private var linkTargets: [OpenClickyOpenableLink] {
        let text = ([item.caption ?? ""] + item.activityStatusLines + [item.progressStepText ?? ""])
            .joined(separator: "\n")
        return OpenClickyOpenableLinkExtractor.links(in: text, limit: 2)
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

private struct ClickyAgentProgressScrollFadeMask: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.055),
                .init(color: .black, location: 0.945),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
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
