import Foundation

#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class OpenClickyWidgetStateStore {
    nonisolated static let snapshotFileName = "widget-snapshot.json"
    nonisolated static let fallbackContainerName = "WidgetState"

    private let fileManager: FileManager
    private var pendingWriteTask: Task<Void, Never>?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    nonisolated static var snapshotURL: URL {
        containerDirectory()
            .appendingPathComponent(snapshotFileName, isDirectory: false)
    }

    nonisolated static func containerDirectory(fileManager: FileManager = .default) -> URL {
        if let appGroupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppBundleConfiguration.appGroupIdentifier) {
            return appGroupURL
        }

        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent(fallbackContainerName, isDirectory: true)
    }

    func scheduleSnapshotPublish(from companionManager: CompanionManager) {
        guard UserDefaults.standard.bool(forKey: AppBundleConfiguration.userWidgetsEnabledDefaultsKey) else { return }

        pendingWriteTask?.cancel()
        pendingWriteTask = Task { [weak self, weak companionManager] in
            // Agent transcript/activity updates can arrive many times per
            // second. Keep WidgetKit publishing out of that hot path so the
            // main actor remains free for cursor tracking, panel dragging, and
            // SwiftUI input.
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let companionManager else { return }
                self.publishSnapshot(from: companionManager)
            }
        }
    }

    func publishSnapshot(from companionManager: CompanionManager) {
        let snapshot = makeSnapshot(from: companionManager)
        write(snapshot)
    }

    func write(_ snapshot: OpenClickyWidgetSnapshot) {
        do {
            let container = Self.containerDirectory(fileManager: fileManager)
            try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: container.appendingPathComponent(Self.snapshotFileName, isDirectory: false), options: [.atomic])
            Self.reloadTimelines()
        } catch {
            print("OpenClicky widget snapshot write failed: \(error.localizedDescription)")
        }
    }

    func refreshLogReviewAttentionSnapshot() {
        var snapshot = Self.readSnapshot(fileManager: fileManager)
        guard snapshot.privacy.widgetsEnabled else { return }

        let reviewText = (try? String(contentsOf: OpenClickyMessageLogStore.shared.reviewCommentsFile, encoding: .utf8)) ?? ""
        let commentCount = reviewText.split(separator: "\n", omittingEmptySubsequences: true).count
        snapshot.generatedAt = Date()
        snapshot.todayStats.logReviewComments = commentCount
        snapshot.needsAttention.removeAll { $0.kind == .flaggedLog }
        if commentCount > 0 {
            snapshot.needsAttention.append(OpenClickyWidgetAttentionItem(
                kind: .flaggedLog,
                title: "\(commentCount) flagged log comments",
                detail: "Review tuning notes in the log viewer.",
                deepLink: OpenClickyWidgetDeepLink.logs
            ))
        }
        write(snapshot)
    }

    func makeSnapshot(from companionManager: CompanionManager, now: Date = Date()) -> OpenClickyWidgetSnapshot {
        let privacy = currentPrivacySettings()
        let activeAgents: [OpenClickyWidgetAgentSummary] = Array(companionManager.agentDockItems.suffix(6))
            .compactMap { (item: ClickyAgentDockItem) -> OpenClickyWidgetAgentSummary? in
                guard let sessionID = item.sessionID else { return nil }
                return OpenClickyWidgetAgentSummary(
                    id: sessionID,
                    title: privacy.includesAgentTaskNames ? item.title : redactedAgentTitle(for: item.status),
                    status: widgetStatusLabel(for: item.status),
                    caption: privacy.includesAgentTaskNames ? sanitizedSnippet(item.caption, maxLength: 120) : nil,
                    updatedAt: item.createdAt
                )
            }

        let stats = todayStats(from: now)
        let attention = attentionItems(from: companionManager, stats: stats, privacy: privacy)
        let memorySummary = privacy.includesMemorySnippets
            ? latestMemorySummary(from: companionManager.codexHomeManager.persistentMemoryFile)
            : nil

        return OpenClickyWidgetSnapshot(
            schemaVersion: OpenClickyWidgetSnapshot.schemaVersion,
            generatedAt: now,
            activeAgents: activeAgents,
            todayStats: stats,
            needsAttention: attention,
            latestMemorySummary: memorySummary,
            privacy: privacy
        )
    }

    nonisolated static func readSnapshot(fileManager: FileManager = .default) -> OpenClickyWidgetSnapshot {
        let fileURL = containerDirectory(fileManager: fileManager)
            .appendingPathComponent(snapshotFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL) else {
            return .empty
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(OpenClickyWidgetSnapshot.self, from: data)) ?? .empty
    }

    static func reloadTimelines() {
        #if canImport(WidgetKit)
        if #available(macOS 11.0, *) {
            WidgetCenter.shared.reloadTimelines(ofKind: "OpenClickyActiveAgentsWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "OpenClickyTodayStatsWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "OpenClickyNeedsAttentionWidget")
        }
        #endif
    }

    private func currentPrivacySettings() -> OpenClickyWidgetPrivacySettings {
        OpenClickyWidgetPrivacySettings(
            widgetsEnabled: UserDefaults.standard.bool(forKey: AppBundleConfiguration.userWidgetsEnabledDefaultsKey),
            includesAgentTaskNames: UserDefaults.standard.bool(forKey: AppBundleConfiguration.userWidgetsIncludeAgentTaskNamesDefaultsKey),
            includesMemorySnippets: UserDefaults.standard.bool(forKey: AppBundleConfiguration.userWidgetsIncludeMemorySnippetsDefaultsKey),
            includesFocusedAppContext: UserDefaults.standard.bool(forKey: AppBundleConfiguration.userWidgetsIncludeFocusedAppContextDefaultsKey)
        )
    }

    private func attentionItems(
        from companionManager: CompanionManager,
        stats: OpenClickyWidgetTodayStats,
        privacy: OpenClickyWidgetPrivacySettings
    ) -> [OpenClickyWidgetAttentionItem] {
        var items: [OpenClickyWidgetAttentionItem] = []

        for session in companionManager.codexAgentSessions {
            if case .failed = session.status {
                items.append(OpenClickyWidgetAttentionItem(
                    kind: .failedAgent,
                    title: privacy.includesAgentTaskNames ? "\(session.title) stopped" : "Agent stopped",
                    detail: privacy.includesAgentTaskNames ? sanitizedSnippet(session.lastErrorMessage, maxLength: 140) : nil,
                    deepLink: OpenClickyWidgetDeepLink.agent(session.id)
                ))
            }
        }

        if !companionManager.hasMicrophonePermission {
            items.append(OpenClickyWidgetAttentionItem(
                kind: .missingPermission,
                title: "Microphone permission needed",
                detail: "Voice input is not available.",
                deepLink: OpenClickyWidgetDeepLink.settings
            ))
        }

        if !companionManager.hasScreenContentPermission {
            items.append(OpenClickyWidgetAttentionItem(
                kind: .missingPermission,
                title: "Screen recording permission needed",
                detail: "Screen-aware help is not available.",
                deepLink: OpenClickyWidgetDeepLink.settings
            ))
        }

        if stats.logReviewComments > 0 {
            items.append(OpenClickyWidgetAttentionItem(
                kind: .flaggedLog,
                title: "\(stats.logReviewComments) flagged log comments",
                detail: "Review tuning notes in the log viewer.",
                deepLink: OpenClickyWidgetDeepLink.logs
            ))
        }

        return Array(items.prefix(6))
    }

    private func todayStats(from now: Date) -> OpenClickyWidgetTodayStats {
        let logURL = OpenClickyMessageLogStore.shared.currentLogFile
        let logText = Self.readTailText(from: logURL, byteLimit: 128 * 1024)
        let reviewText = (try? String(contentsOf: OpenClickyMessageLogStore.shared.reviewCommentsFile, encoding: .utf8)) ?? ""

        return OpenClickyWidgetTodayStats(
            voiceInteractions: countOccurrences(of: "\"event\":\"voice.transcript\"", in: logText),
            agentTasksCreated: countOccurrences(of: "\"event\":\"openclicky.agent_task.created\"", in: logText),
            agentCompletions: countOccurrences(of: "\"method\":\"turn/completed\"", in: logText),
            agentFailures: countOccurrences(of: "\"event\":\"codex.stderr\"", in: logText) + countOccurrences(of: "\"method\":\"error\"", in: logText),
            logReviewComments: reviewText.split(separator: "\n", omittingEmptySubsequences: true).count
        )
    }

    private nonisolated static func readTailText(from url: URL, byteLimit: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > byteLimit ? fileSize - byteLimit : 0
        do {
            try handle.seek(toOffset: offset)
            return String(data: handle.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func latestMemorySummary(from fileURL: URL) -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return sanitizedSnippet(paragraphs.last, maxLength: 160)
    }

    private func widgetStatusLabel(for status: ClickyAgentDockStatus) -> String {
        switch status {
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .done:
            return "Done"
        case .failed:
            return "Needs review"
        }
    }

    private func redactedAgentTitle(for status: ClickyAgentDockStatus) -> String {
        switch status {
        case .starting:
            return "Agent starting"
        case .running:
            return "Agent running"
        case .done:
            return "Agent done"
        case .failed:
            return "Agent stopped"
        }
    }

    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private func sanitizedSnippet(_ text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return nil }
        guard flattened.count > maxLength else { return flattened }
        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxLength)
        let prefix = String(flattened[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return "\(prefix[..<lastSpace])..."
        }
        return "\(prefix)..."
    }
}
