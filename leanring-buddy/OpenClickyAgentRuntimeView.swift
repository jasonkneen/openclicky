import SwiftUI

/// Full management UI for the isolated openclicky-agent runtime.
/// Replaces the old "Agents" concept with proper Claw-style sections:
/// Providers, Agents, Cron Jobs, Sessions, Skills, Memory, Channels.
struct OpenClickyAgentRuntimeView: View {
    @StateObject private var manager = OpenClickyAgentManager.shared
    @State private var selectedTab: Tab = .overview
    let sessions: [CodexAgentSession]
    let activeSessionID: UUID?
    let selectSession: ((UUID) -> Void)?

    init(
        sessions: [CodexAgentSession] = [],
        activeSessionID: UUID? = nil,
        selectSession: ((UUID) -> Void)? = nil
    ) {
        self.sessions = sessions
        self.activeSessionID = activeSessionID
        self.selectSession = selectSession
    }

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case providers = "Providers"
        case agents = "Agents"
        case cron = "Cron Jobs"
        case sessions = "Sessions"
        case skills = "Skills"
        case memory = "Memory"
        case channels = "Channels"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Agent Runtime")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                statusBadge
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.03))

            Divider()

            // Tab bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Tab.allCases) { tab in
                        Button(action: { selectedTab = tab }) {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            // Content
            ScrollView {
                Group {
                    switch selectedTab {
                    case .overview:
                        overviewSection
                    case .providers:
                        providersSection
                    case .agents:
                        agentsSection
                    case .cron:
                        cronSection
                    case .sessions:
                        sessionsSection
                    case .skills:
                        skillsSection
                    case .memory:
                        memorySection
                    case .channels:
                        channelsSection
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 420, minHeight: 520)
        .onAppear {
            manager.refreshStatus()
        }
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        Group {
            switch manager.status {
            case .running:
                Label("Running", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .stopped:
                Label("Stopped", systemImage: "pause.circle.fill")
                    .foregroundColor(.orange)
            case .notInstalled:
                Label("Not Installed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            case .error(let msg):
                Label("Error", systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red)
                    .help(msg)
            }
        }
        .font(.system(size: 11, weight: .medium))
    }

    // MARK: - Sections

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenClicky Agent Runtime")
                .font(.headline)

            Text("Isolated agent engine (openclicky-agent). Separate from any existing LightClaw installation.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button("Start Service") {
                    Task { try? await manager.ensureRunning() }
                }
                .disabled({
                    if case .running = manager.status { return true }
                    return false
                }())

                Button("Stop Service") {
                    Task { await manager.stopService() }
                }
                .disabled(manager.status != .running)

                Button("Refresh") {
                    manager.refreshStatus()
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Providers")
                .font(.headline)

            if let cfg = manager.config, let providers = cfg.providers {
                ForEach(Array(providers.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key.capitalized)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if let entry = providers[key], let _ = entry.apiKey {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Text("No key")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                Text("No providers configured yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Button("Sync from OpenClicky settings") {
                    manager.syncProvidersFromSettings()
                }
                Button("Reload Config") {
                    manager.loadConfig()
                }
            }
            .font(.caption)

            Text("Provider keys are synced automatically from Settings → API Keys. Use Sync if the runtime config seems out of date.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onAppear { manager.loadConfig() }
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Named Agents")
                .font(.headline)
            Text("Define specialized agents (Scout, Coder, Researcher, etc.) with their own system prompts and tool access.")
                .font(.caption)
                .foregroundColor(.secondary)

            // Future: list + create agents from config
            Text("Agent definitions live in the agent runtime config.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var cronSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cron Jobs")
                .font(.headline)
            Text("Scheduled tasks managed by the agent runtime.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Use the cron tool inside the agent or the TUI (`openclicky-agent cron list`).")
                .font(.system(size: 11))
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions")
                .font(.headline)
            Text("OpenClicky Agent Mode sessions currently held by the Swift app. openclicky-agent is the execution backend when available; these rows are the UI session wrappers receiving its stream.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if sessions.isEmpty {
                Text("No agent sessions have been created in this app run yet.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sessions) { session in
                        OpenClickyRuntimeSessionRow(
                            session: session,
                            isActive: session.id == activeSessionID,
                            select: selectSession
                        )
                    }
                }
            }
        }
    }

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skills")
                .font(.headline)
            Text("SKILL.md discovery and activation. Skills are loaded from ~/Library/Application Support/OpenClicky/agent/workspace/skills/")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Memory")
                .font(.headline)
            Text("SQLite + vector memory store for this agent runtime.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Channels")
                .font(.headline)
            Text("Telegram, Discord, and other connected channels.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Configure tokens in the agent config or via `openclicky-agent configure`.")
                .font(.system(size: 11))
        }
    }
}
private struct OpenClickyRuntimeSessionRow: View {
    @ObservedObject var session: CodexAgentSession
    let isActive: Bool
    let select: ((UUID) -> Void)?

    var body: some View {
        Button(action: { select?(session.id) }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if isActive {
                        Text("Active")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    Spacer()
                    Text(session.status.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(statusColor)
                }

                Text(session.statusSummaryLine)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Label(session.progressStage.label, systemImage: "waveform.path.ecg")
                    Label(session.model, systemImage: "cpu")
                    Label(shortID, systemImage: "number")
                    if let prompt = session.lastSubmittedPromptText, !prompt.isEmpty {
                        Label(Self.short(prompt), systemImage: "text.bubble")
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isActive ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(select == nil)
    }

    private var shortID: String {
        String(session.id.uuidString.prefix(8))
    }

    private var statusColor: Color {
        switch session.status {
        case .stopped:
            return .secondary
        case .starting:
            return .orange
        case .ready:
            return .green
        case .running:
            return .blue
        case .failed:
            return .red
        }
    }

    private static func short(_ value: String, maxLength: Int = 60) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)) + "…"
    }
}
