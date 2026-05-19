import SwiftUI
import WidgetKit

struct OpenClickyWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: OpenClickyWidgetSnapshot
}

struct OpenClickyWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> OpenClickyWidgetEntry {
        OpenClickyWidgetEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (OpenClickyWidgetEntry) -> Void) {
        completion(OpenClickyWidgetEntry(date: Date(), snapshot: OpenClickyWidgetSnapshotReader.readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OpenClickyWidgetEntry>) -> Void) {
        let entry = OpenClickyWidgetEntry(date: Date(), snapshot: OpenClickyWidgetSnapshotReader.readSnapshot())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

@main
struct OpenClickyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        OpenClickyActiveAgentsWidget()
        OpenClickyTodayStatsWidget()
        OpenClickyNeedsAttentionWidget()
    }
}

struct OpenClickyActiveAgentsWidget: Widget {
    let kind = "OpenClickyActiveAgentsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OpenClickyWidgetProvider()) { entry in
            OpenClickyWidgetContainer(title: "Active Agents", deepLink: OpenClickyWidgetDeepLink.agents) {
                OpenClickyActiveAgentsWidgetView(snapshot: entry.snapshot)
            }
        }
        .configurationDisplayName("OpenClicky Agents")
        .description("Shows active OpenClicky agent tasks and statuses.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct OpenClickyTodayStatsWidget: Widget {
    let kind = "OpenClickyTodayStatsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OpenClickyWidgetProvider()) { entry in
            OpenClickyWidgetContainer(title: "Today", deepLink: OpenClickyWidgetDeepLink.agents) {
                OpenClickyTodayStatsWidgetView(stats: entry.snapshot.todayStats)
            }
        }
        .configurationDisplayName("OpenClicky Today")
        .description("Shows today's OpenClicky voice and agent stats.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct OpenClickyNeedsAttentionWidget: Widget {
    let kind = "OpenClickyNeedsAttentionWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OpenClickyWidgetProvider()) { entry in
            OpenClickyWidgetContainer(title: "Review Items", deepLink: OpenClickyWidgetDeepLink.logs) {
                OpenClickyNeedsAttentionWidgetView(snapshot: entry.snapshot)
            }
        }
        .configurationDisplayName("OpenClicky Attention")
        .description("Shows failed agents, permissions, and flagged logs.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

private struct OpenClickyWidgetContainer<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    let title: String
    let deepLink: URL
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(OpenClickyWidgetTheme.accent.opacity(0.28))
                .frame(width: family == .systemSmall ? 112 : 172, height: family == .systemSmall ? 112 : 172)
                .blur(radius: 24)
                .offset(x: family == .systemSmall ? 46 : 58, y: -52)

            Circle()
                .fill(Color.purple.opacity(0.16))
                .frame(width: family == .systemSmall ? 90 : 136, height: family == .systemSmall ? 90 : 136)
                .blur(radius: 26)
                .offset(x: family == .systemSmall ? -44 : -70, y: family == .systemSmall ? 98 : 122)

            VStack(alignment: .leading, spacing: contentSpacing) {
                HStack(spacing: 8) {
                    OpenClickyWidgetMark()
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("LIVE")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(OpenClickyWidgetTheme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(OpenClickyWidgetTheme.accent.opacity(0.17))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(OpenClickyWidgetTheme.accent.opacity(0.34), lineWidth: 1)
                                )
                        )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(OpenClickyWidgetTheme.headerBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                content

                Spacer()
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        }
        .containerBackground(for: .widget) {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.022, green: 0.026, blue: 0.04),
                        Color(red: 0.06, green: 0.075, blue: 0.11),
                        Color(red: 0.018, green: 0.044, blue: 0.062)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [OpenClickyWidgetTheme.accent.opacity(0.24), .clear],
                    center: .topTrailing,
                    startRadius: 8,
                    endRadius: 170
                )
                LinearGradient(
                    colors: [.white.opacity(0.12), .clear, .black.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .widgetURL(deepLink)
    }

    private var horizontalPadding: CGFloat {
        switch family {
        case .systemSmall:
            return 12
        case .systemMedium:
            return 16
        default:
            return 18
        }
    }

    private var verticalPadding: CGFloat {
        family == .systemMedium ? 10 : 13
    }

    private var contentSpacing: CGFloat {
        family == .systemMedium ? 8 : 10
    }
}

private struct OpenClickyActiveAgentsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: OpenClickyWidgetSnapshot

    var body: some View {
        if snapshot.activeAgents.isEmpty {
            EmptyWidgetMessage(text: "No active agents")
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(snapshot.activeAgents.prefix(maxRows))) { agent in
                    Link(destination: URL(string: "openclicky://agent/\(agent.id.uuidString)") ?? OpenClickyWidgetDeepLink.agents) {
                        HStack(alignment: .top, spacing: 8) {
                            statusDot(for: agent.status)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(agent.title)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if family != .systemSmall {
                                        Text(agent.status)
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                            .foregroundStyle(statusColor(for: agent.status))
                                            .lineLimit(1)
                                    }
                                }
                                if family != .systemSmall, let caption = agent.caption {
                                    Text(caption)
                                        .font(.system(size: 10, weight: .regular, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.58))
                                        .lineLimit(family == .systemMedium ? 1 : 2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, family == .systemMedium ? 6 : 9)
                        .modifier(OpenClickyWidgetCardStyle())
                    }
                    .foregroundStyle(.white.opacity(0.94))
                }
            }
        }
    }

    private var maxRows: Int {
        switch family {
        case .systemSmall:
            return 2
        case .systemMedium:
            return 2
        default:
            return 5
        }
    }

    private func statusDot(for status: String) -> some View {
        Circle()
            .fill(statusColor(for: status))
            .frame(width: 8, height: 8)
            .shadow(color: statusColor(for: status).opacity(0.45), radius: 5)
    }

    private func statusColor(for status: String) -> Color {
        switch status {
        case "Done":
            return .green
        case "Needs review":
            return .red
        case "Running":
            return .cyan
        default:
            return .yellow
        }
    }
}

private struct OpenClickyTodayStatsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let stats: OpenClickyWidgetTodayStats

    var body: some View {
        if family == .systemSmall {
            VStack(alignment: .leading, spacing: 8) {
                statLine(value: stats.agentTasksCreated, label: "Agents", color: OpenClickyWidgetTheme.accent)
                statLine(value: stats.voiceInteractions, label: "Voice", color: .purple)
                statLine(value: stats.agentFailures + stats.logReviewComments, label: "Review", color: .orange)
            }
        } else if family == .systemMedium {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4),
                alignment: .leading,
                spacing: 0
            ) {
                statTile(value: stats.agentTasksCreated, label: "Agents", color: OpenClickyWidgetTheme.accent, compact: true)
                statTile(value: stats.agentCompletions, label: "Done", color: .green, compact: true)
                statTile(value: stats.voiceInteractions, label: "Voice", color: .purple, compact: true)
                statTile(value: stats.agentFailures + stats.logReviewComments, label: "Review", color: .orange, compact: true)
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                statTile(value: stats.agentTasksCreated, label: "Agent tasks", color: OpenClickyWidgetTheme.accent)
                statTile(value: stats.agentCompletions, label: "Completed", color: .green)
                statTile(value: stats.voiceInteractions, label: "Voice", color: .purple)
                statTile(value: stats.agentFailures + stats.logReviewComments, label: "Needs review", color: .orange)
            }
        }
    }

    private func statLine(value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 4, height: 24)
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.64))
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func statTile(value: Int, label: String, color: Color, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            Circle()
                .fill(color)
                .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
                .shadow(color: color.opacity(0.35), radius: 5)
            Text("\(value)")
                .font(.system(size: compact ? 20 : 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.system(size: compact ? 9 : 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 7 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(OpenClickyWidgetCardStyle())
    }
}

private struct OpenClickyNeedsAttentionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: OpenClickyWidgetSnapshot

    var body: some View {
        if snapshot.needsAttention.isEmpty {
            EmptyWidgetMessage(text: "Nothing to review")
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(snapshot.needsAttention.prefix(maxRows))) { item in
                    Link(destination: item.deepLink ?? OpenClickyWidgetDeepLink.logs) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: iconName(for: item.kind))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(color(for: item.kind))
                                .frame(width: 18, height: 18)
                                .background(
                                    Circle()
                                        .fill(color(for: item.kind).opacity(0.16))
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                if family != .systemSmall, let detail = item.detail {
                                    Text(detail)
                                        .font(.system(size: 10, weight: .regular, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.58))
                                        .lineLimit(family == .systemMedium ? 1 : 2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, family == .systemMedium ? 6 : 9)
                        .modifier(OpenClickyWidgetCardStyle())
                    }
                    .foregroundStyle(.white.opacity(0.94))
                }
            }
        }
    }

    private var maxRows: Int {
        switch family {
        case .systemSmall:
            return 3
        case .systemMedium:
            return 2
        default:
            return 5
        }
    }

    private func iconName(for kind: OpenClickyWidgetAttentionItem.Kind) -> String {
        switch kind {
        case .failedAgent:
            return "exclamationmark.triangle.fill"
        case .missingPermission:
            return "lock.fill"
        case .missingCredential:
            return "key.fill"
        case .flaggedLog:
            return "doc.text.magnifyingglass"
        case .staleSnapshot:
            return "clock.arrow.circlepath"
        }
    }

    private func color(for kind: OpenClickyWidgetAttentionItem.Kind) -> Color {
        switch kind {
        case .failedAgent:
            return .red
        case .missingPermission, .missingCredential:
            return .orange
        case .flaggedLog:
            return OpenClickyWidgetTheme.accent
        case .staleSnapshot:
            return .yellow
        }
    }
}

private struct EmptyWidgetMessage: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Text("Open OpenClicky to update this widget.")
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(OpenClickyWidgetCardStyle())
    }
}

private enum OpenClickyWidgetTheme {
    static let accent = Color(red: 0.33, green: 0.88, blue: 0.98)

    static var headerBackground: some ShapeStyle {
        LinearGradient(
            colors: [.white.opacity(0.13), .white.opacity(0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct OpenClickyWidgetCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.045),
                                .white.opacity(0.018),
                                OpenClickyWidgetTheme.accent.opacity(0.018)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(OpenClickyWidgetTheme.accent.opacity(0.05), lineWidth: 1)
                            .blur(radius: 0.5)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 7, x: 0, y: 4)
            )
    }
}

private struct OpenClickyWidgetMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(OpenClickyWidgetTheme.accent.opacity(0.18))
            Circle()
                .strokeBorder(OpenClickyWidgetTheme.accent.opacity(0.55), lineWidth: 1)
            Circle()
                .fill(OpenClickyWidgetTheme.accent)
                .frame(width: 5, height: 5)
        }
        .frame(width: 18, height: 18)
    }
}
