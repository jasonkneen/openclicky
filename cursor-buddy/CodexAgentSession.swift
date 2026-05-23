import AppKit
import Combine
import Foundation
import OpenClickyBrowser
import OpenClickyCore
#if canImport(FoundationModels)
import FoundationModels
#endif

actor OpenClickyAgentFileLeaseCoordinator {
    static let shared = OpenClickyAgentFileLeaseCoordinator()

    struct LeaseConflict {
        let path: String
        let ownerSessionID: UUID
        let ownerTitle: String
    }

    struct LeaseSummary {
        let claimedPaths: [String]
        let conflicts: [LeaseConflict]
        let activeClaims: [String]
        let waitedForConflicts: Bool
        let waitTimedOut: Bool
    }

    private struct LeaseRecord {
        let sessionID: UUID
        let sessionTitle: String
        let acquiredAt: Date
    }

    private var leasesByPath: [String: LeaseRecord] = [:]
    private var pathsBySession: [UUID: Set<String>] = [:]

    func claimPaths(_ paths: [String], for sessionID: UUID, title: String) -> LeaseSummary {
        claimAvailablePaths(Array(Set(paths.map(Self.normalizedPath))).sorted(), for: sessionID, title: title, waitedForConflicts: false, waitTimedOut: false)
    }

    func claimPathsWaitingForRelease(_ paths: [String], for sessionID: UUID, title: String, timeout: TimeInterval = 900, pollInterval: TimeInterval = 2) async -> LeaseSummary {
        releaseLeases(for: sessionID)
        let uniquePaths = Array(Set(paths.map(Self.normalizedPath))).sorted()
        let deadline = Date().addingTimeInterval(timeout)
        var waitedForConflicts = false

        while !conflicts(for: uniquePaths, excluding: sessionID).isEmpty {
            waitedForConflicts = true
            guard Date() < deadline else {
                return claimAvailablePaths(uniquePaths, for: sessionID, title: title, waitedForConflicts: true, waitTimedOut: true)
            }
            let nanoseconds = UInt64(max(0.25, pollInterval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }

        return claimAvailablePaths(uniquePaths, for: sessionID, title: title, waitedForConflicts: waitedForConflicts, waitTimedOut: false)
    }

    private func claimAvailablePaths(_ uniquePaths: [String], for sessionID: UUID, title: String, waitedForConflicts: Bool, waitTimedOut: Bool) -> LeaseSummary {
        releaseLeases(for: sessionID)
        var claimedPaths: [String] = []
        var conflicts: [LeaseConflict] = []

        for path in uniquePaths {
            if let existing = leasesByPath[path], existing.sessionID != sessionID {
                conflicts.append(LeaseConflict(path: path, ownerSessionID: existing.sessionID, ownerTitle: existing.sessionTitle))
                continue
            }

            leasesByPath[path] = LeaseRecord(sessionID: sessionID, sessionTitle: title, acquiredAt: Date())
            pathsBySession[sessionID, default: []].insert(path)
            claimedPaths.append(path)
        }

        return LeaseSummary(
            claimedPaths: claimedPaths,
            conflicts: conflicts,
            activeClaims: activeClaimLines(excluding: sessionID),
            waitedForConflicts: waitedForConflicts,
            waitTimedOut: waitTimedOut
        )
    }

    private func conflicts(for paths: [String], excluding sessionID: UUID) -> [LeaseConflict] {
        paths.compactMap { path in
            guard let existing = leasesByPath[path], existing.sessionID != sessionID else { return nil }
            return LeaseConflict(path: path, ownerSessionID: existing.sessionID, ownerTitle: existing.sessionTitle)
        }
    }

    func coordinationSnapshot(excluding sessionID: UUID? = nil) -> [String] {
        activeClaimLines(excluding: sessionID)
    }

    func releaseLeases(for sessionID: UUID) {
        guard let paths = pathsBySession.removeValue(forKey: sessionID) else { return }
        for path in paths {
            if leasesByPath[path]?.sessionID == sessionID {
                leasesByPath.removeValue(forKey: path)
            }
        }
    }

    private func activeClaimLines(excluding sessionID: UUID? = nil) -> [String] {
        leasesByPath
            .filter { _, lease in lease.sessionID != sessionID }
            .map { path, lease in "- \(path) (owned by \(lease.sessionTitle))" }
            .sorted()
    }

    private static func normalizedPath(_ path: String) -> String {
        let expanded: String
        if path == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        } else {
            expanded = path
        }
        return (expanded as NSString).standardizingPath
    }
}

struct CodexTranscriptEntry: Identifiable, Equatable, Codable {
    enum Role: String, Equatable, Codable {
        case user
        case assistant
        case system
        case command
        case plan
    }

    let id: String
    var role: Role
    var text: String
    var createdAt: Date

    init(id: String = UUID().uuidString, role: Role, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

struct CodexAgentScreenContextAttachment: Equatable {
    let label: String
    let fileURL: URL
    let note: String?
}

struct CodexAgentScreenContext: Equatable {
    let source: String
    let capturedAt: Date
    let selectedText: String?
    let attachments: [CodexAgentScreenContextAttachment]

    var isEmpty: Bool {
        attachments.isEmpty && (selectedText == nil || selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
    }

    func promptPrefix() -> String {
        guard !isEmpty else { return "" }

        var lines: [String] = [
            "OpenClicky screen context:",
            "- Source: \(source)",
            "- Captured at: \(ISO8601DateFormatter().string(from: capturedAt))",
            "- Screenshot files are saved locally as task context. Inspect them if your runtime exposes image/file viewing; otherwise be explicit that screenshot inspection is unavailable.",
            "- Treat these screenshots as visual reference material for the task, not as files the user is asking you to find or show back to them."
        ]

        if let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("- Selected text:\n\(selectedText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        for (index, attachment) in attachments.enumerated() {
            lines.append("\(index + 1). \(attachment.label): \(attachment.fileURL.path)")
            if let note = attachment.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                lines.append("   Note: \(note)")
            }
        }

        return lines.joined(separator: "\n")
    }
}


enum CodexAgentSessionStatus: Equatable {
    case stopped
    case starting
    case ready
    case running
    case failed(String)

    var label: String {
        switch self {
        case .stopped: return "Ready"
        case .starting: return "Starting"
        case .ready: return "Ready"
        case .running: return "Running"
        case .failed: return "Stopped"
        }
    }
}

enum CodexAgentProgressStage: Equatable {
    case idle
    case starting
    case planning
    case executing
    case composing
    case completed
    case failed

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .planning: return "Planning"
        case .executing: return "Executing"
        case .composing: return "Composing reply"
        case .completed: return "Completed"
        case .failed: return "Stopped"
        }
    }
}

@MainActor
final class CodexAgentSession: ObservableObject, Identifiable, BrowserWorkspaceAgentSessionProtocol {
    let id: UUID
    let createdAt: Date
    let accentTheme: OpenClickyCore.ClickyAccentTheme
    @Published private(set) var status: CodexAgentSessionStatus = .stopped
    @Published private(set) var entries: [CodexTranscriptEntry] = []
    @Published private(set) var activeThreadID: String?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var latestResponseCard: ClickyResponseCard?
    @Published private(set) var stopReason: String?
    @Published private(set) var title: String
    @Published private(set) var progressStage: CodexAgentProgressStage = .idle
    @Published private(set) var activityStatusLines: [String] = []
    @Published private(set) var queuedFollowUpPrompts: [String] = []
    @Published private(set) var wasRestoredAfterRelaunch = false
    @Published var model: String = OpenClickyModelCatalog.codexActionsModel(
        withID: UserDefaults.standard.string(forKey: "clickyCodexModel") ?? OpenClickyModelCatalog.defaultCodexActionsModelID
    ).id
    /// Optional specialist-agent system context (soul/instructions/memory)
    /// prepended to the developer instructions when this session is launched
    /// under a specialist agent. Empty for default sessions.
    @Published var prependedSystemContext: String = ""
    /// Slug of the specialist agent powering this session, if any.
    @Published var specialistAgentSlug: String? = nil
    @Published var workingDirectoryPath: String = UserDefaults.standard.string(forKey: "clickyCodexWorkingDirectory")
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    var onOpenableFileFound: (@MainActor (URL) -> Void)?

    var spokenAgentName: String {
        "the agent"
    }

    var spokenAgentSentenceName: String {
        "The agent"
    }

    private var spokenTaskTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle != "Agent" else {
            return "the agent task"
        }
        return trimmedTitle
    }

    var statusSummaryLine: String {
        let taskTitle = spokenTaskTitle
        let latestActivity = latestActivitySummary

        if canResumeAfterRelaunch {
            return "\(taskTitle) needs resuming after relaunch."
        }

        switch status {
        case .stopped:
            guard hasVisibleActivity else {
                return "No agent task has been started yet."
            }
            return "\(taskTitle) is stopped."
        case .starting:
            return "\(taskTitle) is starting."
        case .running:
            if let latestActivity {
                return "\(taskTitle) is running. Latest: \(latestActivity)"
            }
            return "\(taskTitle) is running."
        case .ready:
            if let latestActivity {
                return "\(taskTitle) is done. Latest: \(latestActivity)"
            }
            return "\(taskTitle) is ready."
        case .failed:
            let errorText = lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let errorText, !errorText.isEmpty {
                return "\(taskTitle) stopped: \(Self.spokenSnippet(from: errorText, maxLength: 110))"
            }
            return "\(taskTitle) stopped."
        }
    }

    var latestActivitySummary: String? {
        if isTurnActiveForChatQueue, let statusActivity = latestActivityStatusLine {
            return Self.spokenSnippet(from: statusActivity, maxLength: 120)
        }
        if let transcriptActivity = Self.latestActivitySummary(from: entries) {
            return transcriptActivity
        }
        return latestActivityStatusLine.map { Self.spokenSnippet(from: $0, maxLength: 120) }
    }

    var latestActivityDisplaySummary: String? {
        if isTurnActiveForChatQueue, let statusActivity = latestActivityStatusLine {
            return Self.displaySnippet(from: statusActivity, maxLength: 1_200)
        }
        if let transcriptActivity = Self.latestActivityDisplaySummary(from: entries) {
            return transcriptActivity
        }
        return latestActivityStatusLine.map { Self.displaySnippet(from: $0, maxLength: 1_200) }
    }

    private var latestActivityStatusLine: String? {
        activityStatusLines.reversed().first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var latestActivityDate: Date {
        entries.last?.createdAt ?? createdAt
    }

    var hasVisibleActivity: Bool {
        !entries.isEmpty || activeThreadID != nil || status != .stopped
    }

    var hasFinishedAgentResponse: Bool {
        entries.contains { entry in
            entry.role == .assistant
                && !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var isFinishedForArchive: Bool {
        if canResumeAfterRelaunch {
            return false
        }

        if progressStage == .completed {
            return true
        }

        guard status == .ready, !isTurnActiveForChatQueue else {
            return false
        }

        return hasFinishedAgentResponse
    }

    var canResumeAfterRelaunch: Bool {
        wasRestoredAfterRelaunch && lastSubmittedPrompt != nil && !isTurnActiveForChatQueue
    }

    var isRelaunchResumeCandidate: Bool {
        switch status {
        case .starting, .running:
            return true
        case .failed:
            return lastSubmittedPrompt != nil
        case .ready:
            return progressStage != .completed && lastSubmittedPrompt != nil
        case .stopped:
            return false
        }
    }

    private let homeManager: CodexHomeManager
    private let processManager: CodexProcessManager
    private var currentAssistantEntryID: String?
    private var pendingAssistantDeltas: [String: String] = [:]
    private var pendingAssistantDeltaFlushTask: Task<Void, Never>?
    private var hasInitializedProcess = false
    private var lastSubmittedPrompt: String?
    var lastSubmittedPromptText: String? {
        lastSubmittedPrompt
    }
    private var currentLeasePaths: [String] = []
    private static let codexRuntimeCompatibilityFallbackModel = "gpt-5.4-mini"
    private static let assistantDeltaFlushDelayNanoseconds: UInt64 = 180_000_000

    init(
        id: UUID = UUID(),
        title: String = "Agent",
        accentTheme: OpenClickyCore.ClickyAccentTheme = .blue,
        homeManager: CodexHomeManager? = nil,
        processManager: CodexProcessManager? = nil
    ) {
        self.id = id
        self.createdAt = Date()
        self.title = title
        self.accentTheme = accentTheme
        self.homeManager = homeManager ?? CodexHomeManager()
        self.processManager = processManager ?? CodexProcessManager()

        self.processManager.onNotification = { [weak self] notification in
            Task { @MainActor in
                self?.handleNotification(notification)
            }
        }
        self.processManager.onStderrLine = { [weak self] line in
            Task { @MainActor in
                self?.handleStderrLine(line)
            }
        }
    }

    func warmUp() {
        Task {
            do {
                try await ensureThread()
            } catch {
                lastErrorMessage = error.localizedDescription
                status = .failed(error.localizedDescription)
            }
        }
    }

    func restoreArchivedState(entries archivedEntries: [CodexTranscriptEntry], activeThreadID archivedThreadID: String?, lastSubmittedPrompt archivedPrompt: String?) {
        stop(reason: "archived_session_recalled")
        entries = archivedEntries
        activeThreadID = archivedThreadID
        lastSubmittedPrompt = archivedPrompt
        latestResponseCard = nil
        queuedFollowUpPrompts.removeAll()
        activityStatusLines.removeAll()
        progressStage = hasFinishedAgentResponse ? .completed : .idle
        lastErrorMessage = nil
        stopReason = nil
        status = archivedEntries.isEmpty ? .stopped : .ready
    }

    func restoreInterruptedRelaunchState(entries restoredEntries: [CodexTranscriptEntry], activeThreadID restoredThreadID: String?, lastSubmittedPrompt restoredPrompt: String?, canResume: Bool = true) {
        stop(reason: "restored_after_relaunch")
        entries = restoredEntries
        activeThreadID = restoredThreadID
        lastSubmittedPrompt = restoredPrompt
        latestResponseCard = nil
        queuedFollowUpPrompts.removeAll()
        activityStatusLines = ["Restored after relaunch"]
        progressStage = (!canResume && hasFinishedAgentResponse) ? .completed : .idle
        lastErrorMessage = nil
        stopReason = "restored_after_relaunch"
        wasRestoredAfterRelaunch = canResume
        status = restoredEntries.isEmpty ? .stopped : .ready
    }

    func resumeInterruptedTaskAfterRelaunch() {
        guard let originalPrompt = lastSubmittedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !originalPrompt.isEmpty else { return }

        let recentContext = entries.suffix(8).map { entry in
            "\(entry.role.rawValue): \(Self.spokenSnippet(from: entry.text, maxLength: 900))"
        }.joined(separator: "\n\n")
        wasRestoredAfterRelaunch = false
        activeThreadID = nil
        submitPromptFromUI("""
        Resume this OpenClicky Agent Mode task after an app relaunch.

        Original user request:
        \(originalPrompt)

        Recent visible transcript before relaunch:
        \(recentContext.isEmpty ? "No transcript was captured before relaunch." : recentContext)

        Continue from the last unfinished step. Re-check files and current state before editing, preserve unrelated work, and finish the task if it is still needed.
        """)
    }

    func submitPromptFromUI(_ prompt: String, screenContext: CodexAgentScreenContext? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isTurnActiveForChatQueue {
            queueFollowUp(trimmed)
            return
        }

        startPromptTurn(trimmed, screenContext: screenContext)
    }

    var isTurnActiveForChatQueue: Bool {
        switch status {
        case .starting, .running:
            return true
        case .stopped, .ready, .failed:
            return false
        }
    }

    func removeQueuedFollowUp(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where queuedFollowUpPrompts.indices.contains(index) {
            queuedFollowUpPrompts.remove(at: index)
        }
    }

    func removeQueuedFollowUp(_ prompt: String) {
        guard let index = queuedFollowUpPrompts.firstIndex(of: prompt) else { return }
        queuedFollowUpPrompts.remove(at: index)
    }

    private func queueFollowUp(_ prompt: String) {
        queuedFollowUpPrompts.append(prompt)
        appendActivityStatusLine("Queued follow-up: \(Self.spokenSnippet(from: prompt, maxLength: 90))")
    }

    private func startPromptTurn(_ prompt: String, screenContext: CodexAgentScreenContext? = nil) {
        if entries.isEmpty {
            let fallbackTitle = Self.shortTitle(from: prompt)
            title = fallbackTitle
            if !Self.shouldKeepInitialTaskTitle(fallbackTitle) {
                Task { [weak self] in
                    guard let generatedTitle = await Self.fastFriendlyTitle(from: prompt, fallbackTitle: fallbackTitle) else { return }
                    guard let self else { return }
                    if self.entries.first?.text == prompt, self.title == fallbackTitle {
                        self.title = generatedTitle
                    }
                }
            }
        }

        lastSubmittedPrompt = prompt
        entries.append(CodexTranscriptEntry(role: .user, text: prompt))
        OpenClickyMessageLogStore.shared.appendConversationTurn(
            lane: "agent",
            direction: "incoming",
            role: "user",
            text: prompt,
            source: "codex_agent_session",
            sessionID: id.uuidString,
            title: title,
            extraFields: [
                "model": model,
                "workingDirectory": workingDirectoryPath,
                "screenContextAttached": screenContext != nil
            ]
        )
        appendActivityStatusLine("Queued request: \(Self.spokenSnippet(from: prompt, maxLength: 90))")
        Task {
            let coordinationNote = await buildAgentCoordinationNote(for: prompt)
            await runPrompt(promptForModel(prompt: prompt, screenContext: screenContext, coordinationNote: coordinationNote))
        }
    }

    func dismissLatestResponseCard() {
        latestResponseCard = nil
    }

    func setModel(_ model: String) {
        let resolvedModel = OpenClickyModelCatalog.codexActionsModel(withID: model).id
        guard self.model != resolvedModel else { return }
        self.model = resolvedModel
        homeManager.model = resolvedModel
        UserDefaults.standard.set(resolvedModel, forKey: "clickyCodexModel")

        if processManager.isRunning {
            stop(reason: "model_changed")
        }
    }

    func stop(reason: String? = nil) {
        queuedFollowUpPrompts.removeAll()
        pendingAssistantDeltaFlushTask?.cancel()
        pendingAssistantDeltaFlushTask = nil
        pendingAssistantDeltas.removeAll()
        stopReason = reason
        processManager.stop()
        hasInitializedProcess = false
        activeThreadID = nil
        currentAssistantEntryID = nil
        status = .stopped
        progressStage = .idle
        Task { await OpenClickyAgentFileLeaseCoordinator.shared.releaseLeases(for: id) }
    }

    private func runPrompt(_ prompt: String, didRetryCompatibilityFallback: Bool = false) async {
        do {
            try await ensureThread()
            guard let activeThreadID else {
                throw CodexRPCError(message: "Codex thread did not start.")
            }

            stopReason = nil
            status = .running
            progressStage = .starting
            lastErrorMessage = nil
            UserDefaults.standard.set(model, forKey: "clickyCodexModel")
            UserDefaults.standard.set(workingDirectoryPath, forKey: "clickyCodexWorkingDirectory")

            _ = try await processManager.sendRequest(method: "turn/start", params: [
                "threadId": activeThreadID,
                "input": [[
                    "type": "text",
                    "text": prompt,
                    "text_elements": []
                ]],
                "cwd": workingDirectoryPath,
                "approvalPolicy": "never",
                "sandbox": "danger-full-access",
                "model": model,
                "effort": homeManager.reasoningEffort,
                "config": [
                    "approval_policy": "never",
                    "sandbox_mode": "danger-full-access"
                ]
            ])
        } catch {
            let text = Self.userFacingErrorMessage(from: error.localizedDescription)
            if text == "Codex app-server stopped.",
               lastErrorMessage?.contains("terminal xcodebuild") == true {
                return
            }

            if !didRetryCompatibilityFallback,
               Self.shouldRetryWithCompatibilityFallback(text),
               model != Self.codexRuntimeCompatibilityFallbackModel {
                let requestedModel = model
                entries.append(CodexTranscriptEntry(
                    role: .system,
                    text: "Codex rejected \(requestedModel) with this runtime, so OpenClicky is retrying with \(Self.codexRuntimeCompatibilityFallbackModel)."
                ))
                setModel(Self.codexRuntimeCompatibilityFallbackModel)
                await runPrompt(prompt, didRetryCompatibilityFallback: true)
                return
            }

            lastErrorMessage = text
            status = .failed(text)
            progressStage = .failed
            entries.append(CodexTranscriptEntry(role: .system, text: text))
        }
    }

    private func promptForModel(prompt: String, screenContext: CodexAgentScreenContext?, coordinationNote: String?) -> String {
        let coordinationSection: String
        if let coordinationNote, !coordinationNote.isEmpty {
            coordinationSection = "\n\(coordinationNote)\n"
        } else {
            coordinationSection = ""
        }

        let taskBrief = """
        OpenClicky Agent Mode brief:
        - User request: \(prompt)
        - Work as an independent background agent. Each OpenClicky agent session has its own Codex runtime, thread, and process; do not assume another agent has your local state.
        \(coordinationSection)
        - Runtime map file: \(homeManager.runtimeMapFile.path)
        - Codex home directory: \(homeManager.codexHomeDirectory.path)
        - Codex config file: \(homeManager.codexHomeDirectory.appendingPathComponent("config.toml", isDirectory: false).path)
        - Soul/persona file: \(homeManager.soulFile.path)
        - Persistent memory file: \(homeManager.persistentMemoryFile.path)
        - Memory articles directory: \(homeManager.memoriesDirectory.path)
        - Bundled skills directory: \(homeManager.codexHomeDirectory.appendingPathComponent(homeManager.bundledSkillsDirectoryName, isDirectory: true).path)
        - Learned skills directory: \(homeManager.learnedSkillsDirectory.path)
        - Archives directory: \(homeManager.archivesDirectory.path)
        - Logs directory: \(OpenClickyMessageLogStore.shared.logDirectory.path)
        - Current message log file: \(OpenClickyMessageLogStore.shared.currentLogFile.path)
        - Log review JSONL file: \(OpenClickyMessageLogStore.shared.reviewCommentsFile.path)
        - Log review comments file: \(OpenClickyMessageLogStore.shared.agentReviewCommentsFile.path)
        - Widget snapshot file: \(OpenClickyWidgetStateStore.snapshotURL.path)
        - Before working, read the soul/persona file, runtime map, and persistent memory file if they exist.
        - Treat SOUL.md as OpenClicky's operating identity. Follow it for tone, autonomy, memory, learning, and agent-routing behavior.
        - If the user asks where OpenClicky stores logs, memory, skills, widgets, config, sessions, or review comments, answer from the runtime map and include exact paths.
        - If the user asks to view or edit OpenClicky's logs, memory, learned skills, runtime map, widget state, or review comments, use the local filesystem paths above directly instead of claiming you cannot access them.
        - If the user asks to look at skills and optimize them, inspect bundled and learned skills, archive previous versions under \(homeManager.archivesDirectory.path), then update or create the improved skill files needed.
        - If the user asks to look at logs and learn from them, inspect message logs and review comments, extract actionable learnings, create or update memory and learned skills, and archive superseded artifacts under \(homeManager.archivesDirectory.path). Do not delete old versions.
        - If the user asks you to fix OpenClicky behavior, tune prompts, or review flagged logs, read the log review comments file and address those comments as concrete issues.
        - If the user asks about widgets or desktop task/status display, read the widget snapshot file to understand the current widget state.
        - Do not say you cannot remember outside the current conversation. Use the persistent memory file.
        - Update persistent memory only for stable preferences, useful project facts, task outcomes, or workflow context that will clearly help future sessions.
        - Use or update learned skills only when the user asks to inspect, optimize, or learn from skills/logs, or when a repeated workflow would materially speed up future work. Do not mention skill creation in progress or final answers unless the user asked about skills.
        - When working on the OpenClicky app repo, do not run terminal `xcodebuild`. Use Xcode for app builds and permission testing, and use `swiftc -parse <relevant Swift source files>` for lightweight Swift syntax checks.
        - Proceed autonomously. Choose sensible defaults and keep working without asking the user unless critical information is truly missing or the action would be destructive, credential-related, or permission-sensitive.
        - Voice is the primary interaction path. Keep user-facing progress and final answers concise enough to be spoken aloud, and put detailed logs or code context in the transcript when needed.
        - Final user-facing answers should sound like a capable coworker over the user's shoulder: one or two plain sentences, no bullets, no markdown, no headings, and no code blocks unless the user explicitly asks for them.
        - When you discover a local document, image, or other user file as the object of the user's request, include its exact local path in your final answer so OpenClicky can show it.
        - Do not restate paths for OpenClicky-provided screen-context images or dropped task attachments in the final answer unless the user specifically asks for the file location; those images are evidence to assist the task, not search results.
        - If blocked, report the exact blocker and the smallest user action needed. If not blocked, finish the task and summarize what changed or what you found.
        - After the final user-facing answer, include a `<NEXT_ACTIONS>` block with one or two overlay button suggestions. Each suggestion must be a `- ` bullet, under about 40 characters, self-contained, and executable without more user input. Prefer concrete follow-ups like "Review the Swift diff" or "Test the cursor label". Omit weak suggestions instead of padding.
        - The `<NEXT_ACTIONS>` block is machine-readable metadata. Do not mention it in prose, and do not put anything after the closing `</NEXT_ACTIONS>` tag except the `TASK_TITLE:` metadata line below.
        - At the end of your final response, include one metadata line exactly like `TASK_TITLE: Short task title` using 2-5 words. Make it a compact noun-based action label with filler removed, such as `Voice Response Naturalization` or `Task Subject Cleanup`. OpenClicky strips this line and uses it to rename the agent task.
        """

        guard let context = screenContext, !context.isEmpty else {
            return taskBrief
        }

        return """
        \(context.promptPrefix())

        \(taskBrief)
        """
    }

    private func ensureThread() async throws {
        if processManager.isRunning, activeThreadID != nil {
            return
        }

        status = .starting
        let processManager = self.processManager
        let applicationSupportDirectory = homeManager.applicationSupportDirectory
        let workerBaseURL = homeManager.workerBaseURL
        let model = homeManager.model
        let reasoningEffort = homeManager.reasoningEffort
        let modelProviderID = homeManager.modelProviderID

        let preparedLayout = try await MainActor.run {
            let hm = CodexHomeManager(
                applicationSupportDirectory: applicationSupportDirectory,
                workerBaseURL: workerBaseURL,
                model: model,
                reasoningEffort: reasoningEffort
            )
            return try hm.prepare(bundle: .main)
        }

        let executable = try CodexRuntimeLocator.codexExecutableURL(bundle: .main)
        try await Task.detached(priority: .userInitiated) {
            try processManager.start(executableURL: executable, codexHome: preparedLayout.homeDirectory)
        }.value

        if !hasInitializedProcess {
            _ = try await processManager.initialize(clientName: "openclicky", title: "OpenClicky", version: "1.0.0")
            hasInitializedProcess = true
        }

        try await ensureCodexAuthentication()

        let baseInstructions = (try? String(contentsOf: preparedLayout.modelInstructionsFile, encoding: .utf8))
            ?? "You are OpenClicky, a friendly macOS cursor companion with Codex Agent Mode."
        let specialistContext = prependedSystemContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let specialistPrefix = specialistContext.isEmpty ? "" : "\(specialistContext)\n\n--- OpenClicky base instructions ---\n"
        let developerInstructions = """
        \(specialistPrefix)You are running inside OpenClicky Agent Mode on macOS. Be direct, helpful, and careful. Prefer concrete actions over vague advice.

        When working on the OpenClicky app repo, do not run terminal `xcodebuild`. Use Xcode for app builds and permission testing, and use `swiftc -parse <relevant Swift source files>` for lightweight Swift syntax checks.

        OpenClicky's runtime map is at \(preparedLayout.runtimeMapFile.path). Read it when the user asks about logs, storage locations, memory, skills, widgets, settings, sessions, or where OpenClicky keeps anything. You may view or edit those local files when asked, subject to normal safety rules for destructive changes, credentials, and permissions.

        OpenClicky's persona is at \(preparedLayout.soulFile.path). Read it before task work. Treat it as the operating identity for voice-first behavior, autonomy, memory, archive-first changes, and plain-English progress.

        Archive-first is mandatory. When replacing, optimizing, pruning, or superseding OpenClicky memory, skills, runtime notes, prompts, config, or log-derived artifacts, copy or move the old version into \(preparedLayout.archivesDirectory.path) first. Do not delete old artifacts unless the user explicitly asks for deletion and understands it is destructive.

        Persistent memory is available. Read \(preparedLayout.persistentMemoryFile.path) before task work, then update it only when useful durable context is learned. Never tell the user you cannot remember outside the current conversation; use this memory file instead.

        Learned skills live at \(preparedLayout.learnedSkillsDirectory.path). Use or update them when the user asks to inspect, optimize, or learn from skills/logs, or when a repeated workflow would materially speed up future work. Do not announce learned-skill checks or skill creation in progress or final answers unless the user asked about skills.

        Message logs are stored in \(OpenClickyMessageLogStore.shared.logDirectory.path). The current JSONL log is \(OpenClickyMessageLogStore.shared.currentLogFile.path). Log review comments are available at \(OpenClickyMessageLogStore.shared.agentReviewCommentsFile.path), with JSONL comments at \(OpenClickyMessageLogStore.shared.reviewCommentsFile.path). When the user asks you to fix issues discovered from logs, read those files and treat each comment as actionable review context.

        When the user asks you to optimize skills, audit learned skills, or learn from logs, treat that as an active task: inspect the relevant files, identify repeatable improvements, archive old versions first, then create or update memory entries and learned skill files that make future agents faster and better.

        Widget state is available at \(OpenClickyWidgetStateStore.snapshotURL.path). When the user asks about widgets or desktop task/status display, read that snapshot before changing widget behavior.

        You are allowed to help with computer-use tasks. OpenClicky may be configured to use native CUA Swift or Background Computer Use for direct control before Agent Mode. When you operate the Mac from Agent Mode, prefer OpenClicky's available direct computer-use path and the `cuaDriver` MCP server when available; describe it as OpenClicky's computer-use path rather than assuming CUA is always selected. Do not choose or advertise Clawd or clawdcursor mouse/keyboard tools as the default for typing or focused-window control; use them only as an explicit fallback when OpenClicky's direct computer-use path is unavailable and say that it is a fallback. Simple focused-window typing is normally intercepted by OpenClicky before Agent Mode and handled through the selected direct computer-use backend.

        You are allowed to perform web research when the user asks for current information, web search, browsing, or research. Use the available network, browser, or search capabilities in the runtime; cite the pages or URLs you relied on in your final response. Do not tell the user voice mode lacks live web access once a task is running in Agent Mode.

        If a task requires destructive filesystem, git, credentials, or system permission changes, explain the action before doing it.

        \(ThreeDGenerationDispatcher.systemPromptInstruction)
        """

        let threadStart: [String: Any]
        do {
            threadStart = try await processManager.sendRequest(method: "thread/start", params: [
                "model": model,
                "modelProvider": modelProviderID,
                "cwd": workingDirectoryPath,
                "approvalPolicy": "never",
                "sandbox": "danger-full-access",
                "config": [:],
                "serviceName": "OpenClicky",
                "baseInstructions": baseInstructions,
                "developerInstructions": developerInstructions,
                "personality": "friendly",
                "ephemeral": false,
                "sessionStartSource": "startup"
            ])
        } catch {
            let text = Self.userFacingErrorMessage(from: error.localizedDescription)
            if Self.shouldRetryWithCompatibilityFallback(text),
               model != Self.codexRuntimeCompatibilityFallbackModel {
                let requestedModel = model
                entries.append(CodexTranscriptEntry(
                    role: .system,
                    text: "Codex rejected \(requestedModel) during startup with this runtime, so OpenClicky is retrying with \(Self.codexRuntimeCompatibilityFallbackModel)."
                ))
                setModel(Self.codexRuntimeCompatibilityFallbackModel)
                try await ensureThread()
                return
            }
            throw error
        }

        if let thread = CodexJSON.dictionary(threadStart["thread"]),
           let threadID = CodexJSON.string(thread["id"]) {
            activeThreadID = threadID
            status = .ready
            progressStage = .idle
        } else {
            throw CodexRPCError(message: "Codex app-server did not return a thread id.")
        }
    }

    private func ensureCodexAuthentication() async throws {
        let modelProviderID = homeManager.modelProviderID
        guard modelProviderID == ClickyCodexConfigTemplate.defaultModelProviderID else { return }

        let accountRead = try await processManager.sendRequest(method: "account/read", params: [
            "refreshToken": false
        ])

        if CodexJSON.dictionary(accountRead["account"]) != nil {
            return
        }

        let loginStart = try await processManager.sendRequest(method: "account/login/start", params: [
            "type": "chatgpt"
        ])

        if let authURLString = CodexJSON.string(loginStart["authUrl"]),
           let authURL = URL(string: authURLString) {
            NSWorkspace.shared.open(authURL)
        }

        throw CodexRPCError(message: "OpenClicky found no Codex ChatGPT login. Finish the Codex sign-in that just opened, then start the Agent task again.")
    }

    private func handleNotification(_ notification: [String: Any]) {
        guard let method = CodexJSON.string(notification["method"]) else { return }
        let params = CodexJSON.dictionary(notification["params"]) ?? [:]

        switch method {
        case "thread/started":
            if let thread = CodexJSON.dictionary(params["thread"]),
               let threadID = CodexJSON.string(thread["id"]) {
                activeThreadID = threadID
                status = .ready
                progressStage = .idle
            }
        case "turn/started":
            status = .running
            progressStage = .starting
            appendActivityStatusLine("Starting the agent loop")
        case "item/agentMessage/delta":
            let itemID = CodexJSON.string(params["itemId"]) ?? UUID().uuidString
            let delta = CodexJSON.string(params["delta"]) ?? ""
            let wasComposing = progressStage == .composing
            progressStage = .composing
            if !wasComposing {
                appendActivityStatusLine("Writing the response")
            }
            appendAssistantDelta(itemID: itemID, delta: delta)
        case "item/started":
            if blockForbiddenCommandIfNeeded(params["item"]) {
                return
            }
            handleStartedItem(params["item"])
        case "item/completed":
            handleCompletedItem(params["item"])
        case "turn/plan/updated":
            if let text = CodexJSON.string(params["text"]), !text.isEmpty {
                progressStage = .planning
                appendActivityStatusLine("Planning: \(Self.spokenSnippet(from: text, maxLength: 100))")
                entries.append(CodexTranscriptEntry(role: .plan, text: text))
            }
        case "command/exec/outputDelta", "item/commandExecution/outputDelta":
            let itemID = CodexJSON.string(params["itemId"])
                ?? CodexJSON.string(params["callId"])
                ?? "active-command-progress"
            let commandText = CodexJSON.string(params["command"])
                ?? CodexJSON.string(CodexJSON.dictionary(params["item"])?["command"])
                ?? ""
            progressStage = .executing
            let summary = Self.liveCommandProgressSummary(command: commandText)
            appendActivityStatusLine(summary)
            upsertEntryIfChanged(
                id: itemID,
                role: .command,
                text: summary
            )
        case "turn/completed":
            flushPendingAssistantDeltas()
            currentAssistantEntryID = nil
            status = .ready
            progressStage = .completed
            appendActivityStatusLine("Finished the agent loop")
            Task { await OpenClickyAgentFileLeaseCoordinator.shared.releaseLeases(for: id) }
            currentLeasePaths = []
            if !queuedFollowUpPrompts.isEmpty {
                let nextPrompt = queuedFollowUpPrompts.removeFirst()
                startPromptTurn(nextPrompt, screenContext: nil)
            }
            // Chime intentionally NOT played here. CompanionManager owns
            // the audio choreography and plays the chime *after* any
            // in-flight TTS finishes, so the chime can't cut the
            // acknowledgement speech. See `playAgentDoneChimeAfterCurrentTTS`.
        case "error":
            let text = Self.userFacingErrorMessage(
                from: Self.notificationErrorMessage(from: params) ?? "Codex app-server emitted an error."
            )
            lastErrorMessage = text
            status = .failed(text)
            progressStage = .failed
            entries.append(CodexTranscriptEntry(role: .system, text: text))
            appendActivityStatusLine("Stopped: \(Self.spokenSnippet(from: text, maxLength: 100))")
        case "account/login/completed":
            if CodexJSON.bool(params["success"]) == true {
                entries.append(CodexTranscriptEntry(role: .system, text: "Codex ChatGPT sign-in completed. Start the Agent task again."))
            } else if let text = CodexJSON.string(params["error"]), !text.isEmpty {
                lastErrorMessage = text
                status = .failed(text)
                progressStage = .failed
                entries.append(CodexTranscriptEntry(role: .system, text: text))
            }
        default:
            break
        }
    }

    private static func notificationErrorMessage(from params: [String: Any]) -> String? {
        if let text = CodexRPCErrorMessage.readableMessage(from: params["message"]), !text.isEmpty {
            return text
        }

        guard let error = CodexJSON.dictionary(params["error"]) else { return nil }

        let message = CodexRPCErrorMessage.readableMessage(from: error["message"])
            ?? CodexRPCErrorMessage.readableMessage(from: error)
            ?? "Codex app-server emitted an error."
        let details = CodexRPCErrorMessage.readableMessage(from: error["additionalDetails"])
        if let details, !details.isEmpty, details != message {
            return "\(message)\n\(details)"
        }

        return message
    }

    private func blockForbiddenCommandIfNeeded(_ itemValue: Any?) -> Bool {
        guard let item = CodexJSON.dictionary(itemValue),
              let command = Self.forbiddenTerminalCommand(from: item) else {
            return false
        }

        let message = "OpenClicky stopped this Agent Mode run because it attempted to run terminal xcodebuild. Use Xcode for app builds and permission testing, and use `swiftc -parse <relevant Swift source files>` for lightweight Swift syntax checks."
        let id = CodexJSON.string(item["id"]) ?? UUID().uuidString
        upsertEntry(id: id, role: .system, text: message)
        latestResponseCard = ClickyResponseCard(
            source: .agent,
            rawText: message,
            contextTitle: lastSubmittedPrompt
        )
        lastErrorMessage = message
        currentAssistantEntryID = nil
        activeThreadID = nil
        hasInitializedProcess = false
        status = .failed(message)
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "blocked",
            event: "openclicky.agent_task.blocked_forbidden_command",
            fields: [
                "command": command,
                "reason": "terminal_xcodebuild_forbidden"
            ]
        )
        processManager.stop()
        return true
    }

    private static func forbiddenTerminalCommand(from item: [String: Any]) -> String? {
        var commands: [String] = []
        if let command = CodexJSON.string(item["command"]) {
            commands.append(command)
        }
        if let commandActions = CodexJSON.array(item["commandActions"]) {
            for actionValue in commandActions {
                guard let action = CodexJSON.dictionary(actionValue),
                      let command = CodexJSON.string(action["command"]) else {
                    continue
                }
                commands.append(command)
            }
        }

        return commands.first { commandInvokesTerminalXcodebuild($0) }
    }

    private static func commandInvokesTerminalXcodebuild(_ command: String) -> Bool {
        let normalized = command
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if normalized == "xcodebuild" || normalized.hasPrefix("xcodebuild ") {
            return true
        }

        let invocationPattern = #"(^|[;&|(`"'])\s*(?:sudo\s+|env\s+)?(?:/[^\s"';|&`]+/)?xcodebuild(\s|$)"#
        return normalized.range(of: invocationPattern, options: .regularExpression) != nil
    }

    nonisolated static func userFacingErrorMessage(from rawMessage: String) -> String {
        CodexRPCErrorMessage.readableMessage(from: rawMessage) ?? rawMessage
    }

    nonisolated static func shouldRetryWithCompatibilityFallback(_ message: String) -> Bool {
        let foldedMessage = message
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return foldedMessage.contains("requires a newer version of codex")
            || foldedMessage.contains("please upgrade to the latest app or cli")
    }

    private func handleStartedItem(_ itemValue: Any?) {
        guard let item = CodexJSON.dictionary(itemValue), let type = CodexJSON.string(item["type"]) else { return }

        switch type {
        case "reasoning":
            progressStage = .planning
            appendActivityStatusLine("Thinking through the task")
        case "plan":
            progressStage = .planning
            appendActivityStatusLine("Planning next steps")
        case "commandExecution":
            progressStage = .executing
            appendActivityStatusLine(Self.commandStartedSummary(from: item))
        case "webSearch":
            progressStage = .executing
            appendActivityStatusLine(Self.webSearchStartedSummary(from: item))
        case "fileChange":
            progressStage = .executing
            appendActivityStatusLine(Self.fileChangeStartedSummary(from: item))
        case "agentMessage":
            progressStage = .composing
            appendActivityStatusLine("Writing the response")
        case "userMessage":
            break
        default:
            appendActivityStatusLine("Using \(Self.humanReadableItemType(type))")
        }
    }

    private func handleCompletedItem(_ itemValue: Any?) {
        guard let item = CodexJSON.dictionary(itemValue), let type = CodexJSON.string(item["type"]) else { return }
        let id = CodexJSON.string(item["id"]) ?? UUID().uuidString

        switch type {
        case "agentMessage":
            flushPendingAssistantDeltas(for: id)
            appendActivityStatusLine("Finished writing the response")
            let text = CodexJSON.string(item["text"]) ?? ""
            if !text.isEmpty {
                let parsed = Self.extractTaskTitleMetadata(from: text)
                if let taskTitle = parsed.taskTitle {
                    title = taskTitle
                }
                let visibleText = parsed.visibleText
                if !visibleText.isEmpty {
                    upsertEntry(id: id, role: .assistant, text: visibleText)
                    OpenClickyMessageLogStore.shared.appendConversationTurn(
                        lane: "agent",
                        direction: "outgoing",
                        role: "assistant",
                        text: visibleText,
                        source: "codex_agent_session",
                        sessionID: self.id.uuidString,
                        title: title,
                        extraFields: [
                            "model": model,
                            "workingDirectory": workingDirectoryPath,
                            "itemID": id,
                            "taskTitleMetadata": parsed.taskTitle ?? ""
                        ]
                    )
                    latestResponseCard = ClickyResponseCard(
                        source: .agent,
                        rawText: Self.userFacingAgentMessage(from: visibleText),
                        contextTitle: lastSubmittedPrompt
                    )
                    if let fileURL = Self.firstOpenableFileURL(in: visibleText) {
                        onOpenableFileFound?(fileURL)
                    }
                    persistCompletedTurnMemory(agentResponse: visibleText)
                }
            }
            currentAssistantEntryID = nil
        case "plan":
            if let text = CodexJSON.string(item["text"]), !text.isEmpty {
                appendActivityStatusLine("Planned: \(Self.spokenSnippet(from: text, maxLength: 100))")
                upsertEntry(id: id, role: .plan, text: text)
            }
        case "commandExecution":
            let command = CodexJSON.string(item["command"]) ?? "Command"
            let output = CodexJSON.string(item["aggregatedOutput"]) ?? ""
            let exitCode = CodexJSON.int(item["exitCode"])
            let summary = Self.plainEnglishCommandSummary(command: command, output: output, exitCode: exitCode)
            appendActivityStatusLine(summary)
            upsertEntry(
                id: id,
                role: .command,
                text: summary
            )
        case "webSearch":
            appendActivityStatusLine("Finished web search")
        case "fileChange":
            appendActivityStatusLine(Self.fileChangeCompletedSummary(from: item))
        default:
            break
        }
    }

    private func buildAgentCoordinationNote(for prompt: String) async -> String? {
        let mentionedPaths = Self.extractLikelyFilePaths(from: prompt)
        let leaseSummary: OpenClickyAgentFileLeaseCoordinator.LeaseSummary?

        if mentionedPaths.isEmpty {
            currentLeasePaths = []
            await OpenClickyAgentFileLeaseCoordinator.shared.releaseLeases(for: id)
            leaseSummary = nil
        } else {
            let claimed = await OpenClickyAgentFileLeaseCoordinator.shared.claimPathsWaitingForRelease(mentionedPaths, for: id, title: title)
            currentLeasePaths = claimed.claimedPaths
            leaseSummary = claimed
        }

        let activeClaims: [String]
        if let leaseSummary {
            activeClaims = leaseSummary.activeClaims
        } else {
            activeClaims = await OpenClickyAgentFileLeaseCoordinator.shared.coordinationSnapshot(excluding: id)
        }
        let activeClaimsSection = activeClaims.isEmpty
            ? "  - No explicit file leases are currently registered by other OpenClicky agents."
            : "  - Files currently claimed by other OpenClicky agents:\n" + activeClaims.joined(separator: "\n")

        let claimedSection: String
        if let leaseSummary, !leaseSummary.claimedPaths.isEmpty {
            claimedSection = "  - Claimed file ownership for this run:\n"
                + leaseSummary.claimedPaths.map { "- \($0)" }.joined(separator: "\n")
        } else {
            claimedSection = "  - This prompt did not name exact files, so no file lease was claimed yet."
        }

        let conflictSection: String
        if let leaseSummary, !leaseSummary.conflicts.isEmpty {
            let conflicts = leaseSummary.conflicts.map { conflict in
                "- \(conflict.path) (currently held by \(conflict.ownerTitle))"
            }.joined(separator: "\n")
            let timeoutNote = leaseSummary.waitTimedOut
                ? " OpenClicky already waited for the lease to clear, but it is still active."
                : ""
            conflictSection = "  - Potential ownership conflicts detected:\n"
                + conflicts
                + "\n  -\(timeoutNote) Do not edit conflicting files; wait for the lease to be released, then re-check before patching."
        } else if let leaseSummary, leaseSummary.waitedForConflicts {
            conflictSection = "  - OpenClicky waited for the previous file lease to be released before claiming these files. Re-check the target file immediately before patching."
        } else {
            conflictSection = "  - If scope changes or exact files become clear, avoid editing files owned by another running agent; wait for the lease to be released before patching."
        }

        return """
        - OpenClicky agent coordination:
          - Multiple OpenClicky agents may share the same working directory even though each has its own Codex runtime, process, and thread.
          - Before editing, run `git status --short` and inspect target files so you preserve uncommitted work from other agents.
          - Re-read a file immediately before patching it, and never replace whole files or reset changes unless the user explicitly asked for that destructive action.
          - Prefer small patches that merge with existing edits; if another agent owns or is clearly editing the same file, wait until the lease is released before patching.
        \(activeClaimsSection)
        \(claimedSection)
        \(conflictSection)
        """
    }

    private static func extractLikelyFilePaths(from text: String) -> [String] {
        let pattern = #"(?:~|/)?(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+\.(?:swift|m|mm|h|cpp|c|js|ts|tsx|jsx|json|toml|yaml|yml|md|txt|plist|xcodeproj|pbxproj)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match in
            guard match.range.location != NSNotFound else { return nil }
            let candidate = nsText.substring(with: match.range)
            return isLikelyRealFilePath(candidate) ? candidate : nil
        }
    }

    private static func isLikelyRealFilePath(_ candidate: String) -> Bool {
        if candidate.contains("/") || candidate.hasPrefix("~/") {
            return true
        }

        // Console snippets often contain reverse-DNS domains that look like
        // header files, e.g. `com.apple.ViewBridge.error.h`. Those are log
        // identifiers, not editable files, so do not claim leases for them.
        let lowered = candidate.lowercased()
        let reverseDNSPrefixes = ["com.", "org.", "net.", "io.", "dev.", "app."]
        if reverseDNSPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return false
        }

        let dotCount = candidate.filter { $0 == "." }.count
        if dotCount >= 3 {
            return false
        }

        return true
    }

    private func appendAssistantDelta(itemID: String, delta: String) {
        guard !delta.isEmpty else { return }
        let id = currentAssistantEntryID ?? itemID
        currentAssistantEntryID = id
        pendingAssistantDeltas[id, default: ""] += delta
        scheduleAssistantDeltaFlush()
    }

    private func scheduleAssistantDeltaFlush() {
        guard pendingAssistantDeltaFlushTask == nil else { return }
        pendingAssistantDeltaFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.assistantDeltaFlushDelayNanoseconds)
            await MainActor.run {
                guard let self else { return }
                self.pendingAssistantDeltaFlushTask = nil
                self.flushPendingAssistantDeltas()
            }
        }
    }

    private func flushPendingAssistantDeltas(for entryID: String? = nil) {
        let targetIDs: [String]
        if let entryID {
            targetIDs = [entryID]
        } else {
            targetIDs = Array(pendingAssistantDeltas.keys)
        }

        for id in targetIDs {
            guard let delta = pendingAssistantDeltas.removeValue(forKey: id), !delta.isEmpty else { continue }
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].text += delta
            } else {
                entries.append(CodexTranscriptEntry(id: id, role: .assistant, text: delta))
            }
        }
    }

    private func upsertEntry(id: String, role: CodexTranscriptEntry.Role, text: String) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].role = role
            entries[index].text = text
        } else {
            entries.append(CodexTranscriptEntry(id: id, role: role, text: text))
        }
    }

    private func upsertEntryIfChanged(id: String, role: CodexTranscriptEntry.Role, text: String) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            guard entries[index].role != role || entries[index].text != text else { return }
            entries[index].role = role
            entries[index].text = text
        } else {
            entries.append(CodexTranscriptEntry(id: id, role: role, text: text))
        }
    }

    private func appendActivityStatusLine(_ text: String) {
        let flattened = Self.spokenSnippet(from: text, maxLength: 120)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return }
        if activityStatusLines.last == flattened { return }
        activityStatusLines.append(flattened)
        if activityStatusLines.count > 12 {
            activityStatusLines.removeFirst(activityStatusLines.count - 12)
        }
    }

    private func handleStderrLine(_ line: String) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return }
        if Self.isNonFatalCodexRuntimeStderrLine(trimmedLine) {
            return
        }

        if trimmedLine.localizedCaseInsensitiveContains("error") || trimmedLine.localizedCaseInsensitiveContains("unauthorized") {
            lastErrorMessage = trimmedLine
            if case .running = status {
                status = .failed(trimmedLine)
            }
        }
    }

    private static func isNonFatalCodexRuntimeStderrLine(_ line: String) -> Bool {
        let normalized = line
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if normalized.contains("responses_websocket")
            && normalized.contains("failed to connect to websocket")
            && normalized.contains("bad gateway") {
            return true
        }

        if normalized.contains("failed to load skill")
            && normalized.contains("invalid description")
            && normalized.contains("exceeds maximum length") {
            return true
        }

        if normalized.contains("apply_patch verification failed") {
            return true
        }

        return false
    }

    // Note: the agent-done chime is no longer played from this class.
    // `CompanionManager.playAgentDoneChimeAfterCurrentTTS()` owns it so
    // it can be sequenced behind any in-flight TTS playback.

    private func persistCompletedTurnMemory(agentResponse: String) {
        guard let lastSubmittedPrompt else { return }

        do {
            try homeManager.appendPersistentMemoryEvent(
                userRequest: lastSubmittedPrompt,
                agentResponse: agentResponse
            )
            try createLearnedSkillIfApplicable(userRequest: lastSubmittedPrompt, agentResponse: agentResponse)
        } catch {
            entries.append(CodexTranscriptEntry(role: .system, text: "OpenClicky could not update persistent memory or learned skills: \(error.localizedDescription)"))
        }
    }

    private func createLearnedSkillIfApplicable(userRequest: String, agentResponse: String) throws {
        let normalizedRequest = userRequest
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let normalizedResponse = agentResponse
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let normalizedCombined = "\(userRequest) \(agentResponse)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if isNoteWorkflow(requestText: normalizedRequest) {
            try homeManager.createLearnedSkillIfNeeded(
                name: "create_apple_note",
                title: "Create Apple Note",
                description: "Use when the user asks OpenClicky to create, save, or update an Apple Note from spoken or typed instructions.",
                body: """
                Use this workflow when the user asks to create a note in Apple Notes or save something as a note.

                ## Workflow

                1. Derive a concise note title from the request. If the user provides a title, use it exactly.
                2. Derive the note body from the request and any provided screen/file context. Keep formatting simple.
                3. Use AppleScript through `osascript` to create the note in Apple Notes. Prefer the default account and the standard Notes folder.
                4. Open or focus Notes only when useful for confirmation.
                5. Keep the final response short: say the note was created and include the title.
                6. Update `memory.md` with any durable preference or reusable detail learned during the note workflow.

                ## AppleScript Pattern

                ```applescript
                tell application "Notes"
                    activate
                    set noteTitle to "Title"
                    set noteBody to "Body"
                    make new note at folder "Notes" of default account with properties {name:noteTitle, body:noteBody}
                end tell
                ```

                If the default account or folder is unavailable, inspect the Notes accounts/folders and choose the most obvious personal Notes folder.
                """
            )
            return
        }

        guard let workflow = reusableWorkflowTemplateIfRequested(
            userRequest: userRequest,
            agentResponse: agentResponse,
            normalizedRequest: normalizedRequest,
            normalizedResponse: normalizedResponse,
            normalizedCombined: normalizedCombined
        ) else { return }
        try homeManager.createLearnedSkillIfNeeded(
            name: workflow.name,
            title: workflow.title,
            description: workflow.description,
            body: workflow.body
        )
    }

    private func isNoteWorkflow(requestText: String) -> Bool {
        let noteIntentPhrases = [
            "create a note",
            "create an apple note",
            "make a note",
            "save this to notes",
            "save that to notes",
            "save it to notes",
            "save this in notes",
            "add this to notes",
            "add that to notes",
            "add to apple notes",
            "put this in notes",
            "update my note",
            "update the note"
        ]
        return noteIntentPhrases.contains { requestText.contains($0) }
    }

    private func reusableWorkflowTemplateIfRequested(
        userRequest: String,
        agentResponse: String,
        normalizedRequest: String,
        normalizedResponse: String,
        normalizedCombined: String
    ) -> (name: String, title: String, description: String, body: String)? {
        let requestSummary = oneLineSnippet(from: userRequest, maxLength: 160)
        let responseSummary = oneLineSnippet(from: agentResponse, maxLength: 180)

        if isReusableWorkflowSignal(normalizedCombined) {
            return workflowTemplate(
                requestSummary: requestSummary,
                responseSummary: responseSummary,
                trigger: "explicit"
            )
        }

        guard isLikelyReusableWorkflow(
            requestText: normalizedRequest,
            responseText: normalizedResponse,
            combinedText: normalizedCombined
        ) else {
            return nil
        }

        return workflowTemplate(
            requestSummary: requestSummary,
            responseSummary: responseSummary,
            trigger: "implicit"
        )
    }

    private func workflowTemplate(
        requestSummary: String,
        responseSummary: String,
        trigger: String
    ) -> (name: String, title: String, description: String, body: String) {
        let triggerHint = trigger == "explicit" ? "for explicit reuse request" : "for an inferred repeated workflow pattern"
        let name = "workflow_\(skillSlug(from: requestSummary))"

        return (
            name: name,
            title: "Workflow: \(requestSummary)",
            description: "Captured workflow for a repeated task or process the user can reuse",
            body: """
            ## Goal

            Capture a repeatable version of this task so future OpenClicky sessions can reuse it.

            ## Source request

            - User request: \(requestSummary)
            - Observed response summary: \(responseSummary)

            ## Trigger condition

            The user workflow was recorded as reusable because OpenClicky detected \(triggerHint).

            ## Workflow

            1. Follow the exact intent from the source request above.
            2. Preserve user preferences, project context, and durable constraints from memory.
            3. If an environment step is risky or destructive, confirm with the user before proceeding.
            4. Keep the completion note concise and mention what changed.
            """
        )
    }

    private func isLikelyReusableWorkflow(requestText: String, responseText: String, combinedText: String) -> Bool {
        guard !isLikelyInformationalQuery(requestText) else { return false }

        let actionSignals = [
            "create",
            "make",
            "run",
            "set up",
            "setup",
            "configure",
            "update",
            "generate",
            "export",
            "import",
            "backup",
            "restore",
            "install",
            "archive",
            "cleanup",
            "clean",
            "build",
            "deploy",
            "send",
            "apply",
            "save",
            "switch",
            "open",
            "close",
            "launch",
            "start",
            "stop",
            "restart",
            "copy",
            "move",
            "rename"
        ]

        let targetSignals = [
            "project",
            "repo",
            "repository",
            "app",
            "application",
            "workflow",
            "script",
            "automation",
            "notes",
            "note",
            "profile",
            "setup",
            "setting",
            "settings",
            "preference",
            "config",
            "configuration",
            "environment",
            "workspace",
            "menu",
            "window",
            "file",
            "folder",
            "screen",
            "task",
            "pipeline",
            "release",
            "build",
            "test",
            "suite"
        ]

        let commandSignals = [
            " cd ",
            " npm ",
            " node ",
            " swift ",
            " python ",
            " pytest ",
            " xcodebuild ",
            " git ",
            " docker ",
            " make ",
            " rg ",
            " find ",
            " ls ",
            " grep ",
            " chmod ",
            " sudo "
        ]

        let workflowStructureSignals = [
            " step",
            " step:",
            " then ",
            " first,",
            " next,",
            " finally",
            " after",
            " before",
            " once done"
        ]

        var score = 0
        score += actionSignals.contains(where: { requestText.contains($0) }) ? 3 : 0
        score += targetSignals.contains(where: { requestText.contains($0) }) ? 2 : 0
        score += commandSignals.contains(where: { combinedText.contains($0) }) ? 2 : 0
        score += workflowStructureSignals.contains(where: { requestText.contains($0) }) ? 1 : 0

        if isLikelyProceduralPhrase(requestText) {
            score += 2
        }

        // avoid capturing tiny single-line commands that are likely one-off answers
        if requestText.count < 36 {
            score -= 2
        }

        if responseText.contains("error") || responseText.contains("cannot") || responseText.contains("unable") {
            score += 1
        }

        if responseText.contains("summary:") || responseText.contains("steps:") {
            score += 1
        }

        return score >= 5
    }

    private func isLikelyInformationalQuery(_ text: String) -> Bool {
        let informationalSignals = [
            "what is",
            "what are",
            "how does",
            "how do",
            "how can",
            "why did",
            "explain",
            "list ",
            "show me",
            "tell me",
            "difference between",
            "where is",
            "where are",
            "can you explain",
            "i want to know",
            "i need to know",
            "what would",
            "help me understand"
        ]

        return informationalSignals.contains(where: { text.contains($0) })
    }

    private func isLikelyProceduralPhrase(_ text: String) -> Bool {
        let proceduralSignals = [
            "if",
            "once",
            "after",
            "before",
            "when",
            "until",
            "while"
        ]

        var matches = 0
        for signal in proceduralSignals {
            if text.contains(signal) {
                matches += 1
            }
        }
        return matches >= 2
    }



    private func isReusableWorkflowSignal(_ text: String) -> Bool {
        let explicitSignals = [
            "save this as a skill",
            "save this as a workflow",
            "remember this",
            "for next time",
            "for the future",
            "next time",
            "repeat this",
            "repeat these",
            "repeatable",
            "create a skill",
            "make this a skill",
            "capture this",
            "capture this workflow",
            "reusable workflow",
            "workflow for the future",
            "create a workflow",
            "make it a skill",
            "keep this as a skill",
            "always do this",
            "every time",
            "standard procedure",
            "standard process"
        ]

        guard explicitSignals.contains(where: { text.contains($0) }) else {
            return false
        }

        let actionSignals = [
            "create",
            "make",
            "run",
            "set up",
            "setup",
            "configure",
            "update",
            "open",
            "generate",
            "export",
            "import",
            "backup",
            "restore",
            "install",
            "archive",
            "cleanup",
            "clean",
            "build",
            "deploy",
            "send",
            "remember",
            "reuse",
            "repeat",
            "use",
            "apply",
            "save"
        ]

        return actionSignals.contains(where: { text.contains($0) })
    }

    private func skillSlug(from title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let lowered = folded.lowercased()
        let pieces = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !pieces.isEmpty else { return "workflow" }
        return pieces.joined(separator: "_").trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private func oneLineSnippet(from text: String, maxLength: Int) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard maxLength > 0 else { return "" }
        guard flattened.count > maxLength else { return flattened }
        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxLength)
        let prefix = String(flattened[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return "\(prefix[..<lastSpace])..."
        }
        return "\(prefix)..."
    }


    private static func userFacingAgentMessage(from text: String) -> String {
        let visibleText = strippingAgentResponseMetadata(from: text)
        if let fileURL = firstOpenableFileURL(in: visibleText) {
            return "Found \(genericArtifactLabel(for: fileURL)). Showing it now."
        }

        return visibleText
    }

    private static func genericArtifactLabel(for fileURL: URL) -> String {
        let ext = fileURL.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"].contains(ext) {
            return "the image"
        }
        if ["log", "txt", "md", "json", "jsonl", "yaml", "yml", "toml", "csv"].contains(ext) {
            return "that file"
        }
        if ["keychain", "pem", "key", "crt", "cer", "p12", "pfx"].contains(ext) {
            return "that login file"
        }
        return "that file"
    }

    private static func plainEnglishCommandSummary(command: String, output: String, exitCode: Int?) -> String {
        let cleanedCommand = compactSingleLine(command)
        _ = output

        if let exitCode, exitCode != 0 {
            return "Command failed (\(exitCode)): \(snippet(cleanedCommand, maxLength: 180))"
        }

        if !cleanedCommand.isEmpty {
            return "Command finished: \(snippet(cleanedCommand, maxLength: 160))"
        }

        return "Command finished"
    }

    private static func compactSingleLine(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func snippet(_ text: String, maxLength: Int) -> String {
        guard maxLength > 0, text.count > maxLength else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: maxLength)
        let prefix = String(text[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return "\(prefix[..<lastSpace])..."
        }
        return "\(prefix)..."
    }

    private static func strippingANSI(_ text: String) -> String {
        let ansiPattern = #"\u{001B}\[[0-9;]*[A-Za-z]"#
        return text.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression)
    }

    private static func firstOpenableFileURL(in text: String, fileManager: FileManager = .default) -> URL? {
        for candidate in pathCandidates(in: text) {
            guard let fileURL = resolvedFileURL(from: candidate, fileManager: fileManager) else { continue }
            return fileURL
        }

        return nil
    }

    private static func pathCandidates(in text: String) -> [String] {
        var candidates: [String] = []

        for delimiter in ["`", "\"", "'"] {
            let parts = text.components(separatedBy: delimiter)
            guard parts.count > 2 else { continue }
            for index in stride(from: 1, to: parts.count, by: 2) {
                candidates.append(parts[index])
            }
        }

        for line in text.components(separatedBy: .newlines) {
            for marker in ["~/", "/Users/", "/Volumes/", "/tmp/", "/var/"] {
                guard let range = line.range(of: marker) else { continue }
                let suffix = String(line[range.lowerBound...])
                if let candidate = pathCandidateEndingAtKnownExtension(in: suffix) {
                    candidates.append(candidate)
                }
            }
        }

        return candidates
    }

    private static func pathCandidateEndingAtKnownExtension(in text: String) -> String? {
        let loweredText = text.lowercased()
        var bestEnd: String.Index?

        for fileExtension in openableFileExtensions {
            guard let range = loweredText.range(of: ".\(fileExtension)") else { continue }
            let end = text.index(text.startIndex, offsetBy: loweredText.distance(from: loweredText.startIndex, to: range.upperBound))
            if bestEnd == nil || end < bestEnd! {
                bestEnd = end
            }
        }

        guard let bestEnd else { return nil }
        return String(text[..<bestEnd])
    }

    private static func resolvedFileURL(from candidate: String, fileManager: FileManager) -> URL? {
        let trimmed = candidate.trimmingCharacters(in: pathTrimCharacters)
        guard !trimmed.isEmpty else { return nil }

        let fileURL: URL
        if trimmed.hasPrefix("~/") {
            let relativePath = String(trimmed.dropFirst(2))
            fileURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(relativePath)
        } else if trimmed.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: trimmed)
        } else {
            return nil
        }

        guard openableFileExtensions.contains(fileURL.pathExtension.lowercased()) else { return nil }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }

        return fileURL.standardizedFileURL
    }

    private static let openableFileExtensions: Set<String> = [
        "csv",
        "doc",
        "docx",
        "gif",
        "heic",
        "jpeg",
        "jpg",
        "key",
        "md",
        "numbers",
        "pages",
        "pdf",
        "png",
        "rtf",
        "txt",
        "webp",
        "xls",
        "xlsx"
    ]

    private static let pathTrimCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "`'\".,;:)]}>"))

    private static func shortTitle(from prompt: String) -> String {
        nounBasedTaskTitle(from: prompt, maximumCharacters: 44, maximumWords: 5)
    }

    private static func shouldKeepInitialTaskTitle(_ title: String) -> Bool {
        let stableTitles: Set<String> = [
            "Log Issue Review",
            "Task Title Cleanup",
            "Task Title Stability",
            "Task Title Ordering",
            "Task Status Wording",
            "Lozenge Sizing"
        ]
        return stableTitles.contains(title)
    }

    private static func fastFriendlyTitle(from prompt: String, fallbackTitle: String) async -> String? {
        let systemPrompt = """
        You create compact, friendly titles for OpenClicky background agent tasks.
        Return only the title, with no quotes or punctuation.
        Rules:
        - 2 to 5 words.
        - Noun-based action label.
        - Remove filler like can you, please, just, maybe, help me, deal with it.
        - Preserve the real requested work.
        - Examples: Voice Response Naturalization, Task Subject Cleanup, Inbox Triage, Settings Permissions Move.
        """
        let userPrompt = """
        Create a friendly task title for this OpenClicky agent request:
        \(prompt)
        """

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let title = await localFoundationFriendlyTitle(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                fallbackTitle: fallbackTitle
            ) {
                return title
            }
        }
        #endif

        if let anthropicAPIKey = AppBundleConfiguration.anthropicAPIKey() {
            do {
                let api = ClaudeAPI(
                    apiKey: anthropicAPIKey,
                    model: OpenClickyModelCatalog.defaultVoiceResponseModelID,
                    maxOutputTokens: 64
                )
                let (text, duration) = try await api.analyzeImage(
                    images: [],
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt
                )
                if let title = cleanedFastFriendlyTitle(text, fallbackTitle: fallbackTitle) {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "agent",
                        direction: "incoming",
                        event: "openclicky.agent_task.title_generated",
                        fields: [
                            "provider": "anthropic",
                            "model": OpenClickyModelCatalog.defaultVoiceResponseModelID,
                            "durationMs": Int((duration * 1000).rounded()),
                            "title": title
                        ]
                    )
                    return title
                }
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.title_generation_failed",
                    fields: [
                        "provider": "anthropic",
                        "model": OpenClickyModelCatalog.defaultVoiceResponseModelID,
                        "error": error.localizedDescription
                    ]
                )
            }
        }

        if let openAIAPIKey = AppBundleConfiguration.openAIAPIKey() {
            let fastOpenAIModel = "gpt-5.4-mini"
            do {
                let api = OpenAIAPI(
                    apiKey: openAIAPIKey,
                    model: fastOpenAIModel,
                    maxOutputTokens: 64
                )
                let (text, duration) = try await api.analyzeImage(
                    images: [],
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt
                )
                if let title = cleanedFastFriendlyTitle(text, fallbackTitle: fallbackTitle) {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "agent",
                        direction: "incoming",
                        event: "openclicky.agent_task.title_generated",
                        fields: [
                            "provider": "openai",
                            "model": fastOpenAIModel,
                            "durationMs": Int((duration * 1000).rounded()),
                            "title": title
                        ]
                    )
                    return title
                }
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.title_generation_failed",
                    fields: [
                        "provider": "openai",
                        "model": fastOpenAIModel,
                        "error": error.localizedDescription
                    ]
                )
            }
        }

        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func localFoundationFriendlyTitle(
        systemPrompt: String,
        userPrompt: String,
        fallbackTitle: String
    ) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.title_generation_skipped",
                fields: [
                    "provider": "apple_foundation_models",
                    "reason": "unavailable"
                ]
            )
            return nil
        }

        let startedAt = Date()
        do {
            let session = LanguageModelSession(instructions: systemPrompt)
            let response = try await session.respond(to: userPrompt)
            if let title = cleanedFastFriendlyTitle(response.content, fallbackTitle: fallbackTitle) {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "openclicky.agent_task.title_generated",
                    fields: [
                        "provider": "apple_foundation_models",
                        "model": "SystemLanguageModel.default",
                        "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000),
                        "title": title
                    ]
                )
                return title
            }
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "openclicky.agent_task.title_generation_failed",
                fields: [
                    "provider": "apple_foundation_models",
                    "model": "SystemLanguageModel.default",
                    "error": error.localizedDescription
                ]
            )
        }

        return nil
    }
    #endif

    private static func cleanedFastFriendlyTitle(_ rawTitle: String, fallbackTitle: String) -> String? {
        if isRawTransportDiagnosticText(rawTitle) {
            return "Runtime Event Filter"
        }

        var title = rawTitle
            .components(separatedBy: .newlines)
            .first ?? rawTitle
        title = title.replacingOccurrences(
            of: #"(?i)^\s*(?:TASK_TITLE|title)\s*:\s*"#,
            with: "",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:task\s+title|friendly\s+title)\b\s*:?"#,
            with: "",
            options: .regularExpression
        )
        title = title
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t`\"'“”‘’.,:;!?-–—[](){}<>"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let words = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { word in
                guard !word.isEmpty else { return false }
                return word.count > 1 || word.rangeOfCharacter(from: .decimalDigits) != nil
            }
            .prefix(5)

        let cleaned = words
            .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.split(separator: " ").count >= 2 else { return nil }
        guard cleaned.count <= 44 else {
            return nounBasedTaskTitle(from: cleaned, maximumCharacters: 44, maximumWords: 5)
        }
        guard cleaned.caseInsensitiveCompare(fallbackTitle) != .orderedSame else { return nil }
        return cleaned
    }

    private static func nounBasedTaskTitle(
        from prompt: String,
        maximumCharacters: Int,
        maximumWords: Int
    ) -> String {
        var title = prompt
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " `\"'.,:;!?-–—[](){}<>"))

        if isRawTransportDiagnosticText(title) {
            return "Runtime Event Filter"
        }

        let directTitleRules: [(pattern: String, title: String)] = [
            (#"(?i)\b(?:see\s+(?:the\s+)?issue\s+here|look\s+at\s+this|fix\s+this)\b.*\b(?:OpenClickyLog|NSXPCDecoder|ViewBridge|unifiedReasons|NSXPCConnection)\b"#, "Log Issue Review"),
            (#"(?i)\b(?:OpenClickyLog|NSXPCDecoder|NSXPCInterface|NSXPCConnection|ViewBridge|NSViewBridgeError|Unable to obtain a task name port right|nw_protocol_instance|nw_read_request_report|unifiedReasons)\b"#, "Log Issue Review"),
            (#"(?i)\b(?:lozenge|pill|caption|label)\b.*\b(?:too\s+long|wide|overflow|cut\s*off|trim|shorter|shorten|compact)\b"#, "Lozenge Sizing"),
            (#"(?i)\b(?:too\s+long|wide|overflow|cut\s*off|trim|shorter|shorten|compact)\b.*\b(?:lozenge|pill|caption|label)\b"#, "Lozenge Sizing"),
            (#"(?i)\b(?:whole|full)\s+(?:task\s+)?names?\b"#, "Task Status Wording"),
            (#"(?i)\bshort\s+(?:version|task\s+name|name)\b"#, "Task Status Wording"),
            (#"(?i)\b(?:read(?:ing)?\s+out|speak(?:ing)?|say(?:ing)?)\b.*\b(?:whole|full|long|raw)\b.*\b(?:task\s+)?(?:name|title|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:whole|full|long|raw)\b.*\b(?:task\s+)?(?:name|title|request)\b.*\b(?:read(?:ing)?\s+out|speak(?:ing)?|say(?:ing)?)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:short|compact)\s+(?:version|label|title|name)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:proper|better|concise|short|compact)\s+(?:task\s+)?titles?\b"#, "Task Title Cleanup"),
            (#"(?i)\btask\s+titles?\b.*\b(?:read(?:ing)?\s+out|raw|asked\s+for|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:read(?:ing)?\s+out|raw)\b.*\b(?:asked\s+for|request)\b"#, "Task Title Cleanup"),
            (#"(?i)\b(?:titles?|task\s+titles?)\b.*\b(?:out\s+of\s+order|wrong\s+order|scrambl(?:ed|ing)|jumbled)\b"#, "Task Title Ordering"),
            (#"(?i)\b(?:out\s+of\s+order|wrong\s+order|scrambl(?:ed|ing)|jumbled)\b.*\b(?:titles?|task\s+titles?)\b"#, "Task Title Ordering"),
            (#"(?i)\b(?:titles?|task\s+titles?)\b.*\b(?:mix(?:ed|ing)?|backwards?|forwards?|flip(?:ping)?|jump(?:ing)?|changing)\b"#, "Task Title Stability"),
            (#"(?i)\b(?:mix(?:ed|ing)?|backwards?|forwards?|flip(?:ping)?|jump(?:ing)?|changing)\b.*\b(?:titles?|task\s+titles?)\b"#, "Task Title Stability")
        ]
        for rule in directTitleRules where title.range(of: rule.pattern, options: .regularExpression) != nil {
            return rule.title
        }

        let attachmentPathPatterns = [
            #"(?i)^/.*?\.(?:png|jpe?g|jpeg|heic|webp|gif|pdf|mov|mp4|m4v)\b"#,
            #"(?i)(?:^|\s)/(?:Users|var|tmp|private|Applications|Volumes)/\S+"#
        ]
        for pattern in attachmentPathPatterns {
            title = title.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        let fillerPatterns = [
            #"(?i)^hey\s+(?:clicky\s+)?agent[,\s]+"#,
            #"(?i)^clicky\s+agent[,\s]+"#,
            #"(?i)^(?:can|could|would)\s+you\s+"#,
            #"(?i)^(?:please\s+)?(?:help\s+me\s+)?(?:do|make|handle|sort|take\s+care\s+of)\s+"#,
            #"(?i)^the\s+(?:updates?|changes?)\s+(?:we(?:'|’)ve|we\s+have|we\s+were)\s+(?:just\s+)?(?:been\s+)?talking\s+about[,\s]+"#,
            #"(?i)^(?:we(?:'|’)ve|we\s+have|we\s+were)\s+(?:just\s+)?(?:been\s+)?talking\s+about[,\s]+"#,
            #"(?i)^(?:to|for|about)\s+"#
        ]
        for pattern in fillerPatterns {
            title = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        title = title.replacingOccurrences(
            of: #"(?i)\b(?:please|just|maybe|basically|actually|kind\s+of|sort\s+of|you\s+know|everything\s+else)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:can\s+you|could\s+you|would\s+you|we(?:'|’)ve|we\s+have|we\s+were|talking\s+about)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:so\s+that|and\s+then|which\s+is\s+to|that\s+you)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:shorten|remove|make|making|sound|sounding|turn|change|update|fix|clean\s+up)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:the|a|an|this|that|it|them|you|your|then|also|with|from|into|and|or|but|for|of|to|in|on|as|is|are|be|have|has|had|asked)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:find|out|why|when|sure|use|uses?|using|start|starts|started|starting|speak|speaks|speaking|say|says|saying|read|reads|reading|whole|full|long|name|version|words?|thing|stuff|phrases?|responses?)\b"#,
            with: " ",
            options: .regularExpression
        )

        let words = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { word in
                guard !word.isEmpty else { return false }
                return word.count > 1 || word.rangeOfCharacter(from: .decimalDigits) != nil
            }
            .prefix(maximumWords)

        var cleaned = words
            .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty {
            cleaned = "Agent Task"
        }

        guard cleaned.count > maximumCharacters else { return cleaned }
        let endIndex = cleaned.index(cleaned.startIndex, offsetBy: maximumCharacters)
        let prefix = String(cleaned[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractTaskTitleMetadata(from text: String) -> (visibleText: String, taskTitle: String?) {
        let lines = text.components(separatedBy: .newlines)
        var extractedTitle: String?
        var visibleLines: [String] = []

        for line in lines {
            if let parsedTitle = taskTitleMetadataValue(from: line) {
                extractedTitle = sanitizedReturnedTaskTitle(parsedTitle)
                continue
            }
            visibleLines.append(line)
        }

        let visibleText = strippingAgentResponseMetadata(from: visibleLines.joined(separator: "\n"))
        let fallbackText = strippingAgentResponseMetadata(from: text)
        return (visibleText.isEmpty ? fallbackText : visibleText, extractedTitle)
    }

    private static func strippingAgentResponseMetadata(from text: String) -> String {
        var visibleText = text
        visibleText = visibleText.replacingOccurrences(
            of: #"(?is)<\s*NEXT_ACTIONS\s*>.*?<\s*/\s*NEXT_ACTIONS\s*>"#,
            with: " ",
            options: .regularExpression
        )
        visibleText = visibleText.replacingOccurrences(
            of: #"(?im)^\s*TASK[_\s-]*TITLE\s*:\s*.*$"#,
            with: " ",
            options: .regularExpression
        )
        return visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func taskTitleMetadataValue(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\[?\s*TASK[_\s-]*TITLE\s*:\s*(.+?)\s*\]?$"#,
            #"(?i)^\[?\s*TITLE\s*:\s*(.+?)\s*\]?$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  let valueRange = Range(match.range(at: 1), in: trimmed) else { continue }
            return String(trimmed[valueRange])
        }
        return nil
    }

    private static func sanitizedReturnedTaskTitle(_ value: String) -> String? {
        let cleaned = nounBasedTaskTitle(from: value, maximumCharacters: 44, maximumWords: 5)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func latestActivitySummary(from entries: [CodexTranscriptEntry]) -> String? {
        latestActivityText(from: entries).map { spokenSnippet(from: $0, maxLength: 120) }
    }

    private static func latestActivityDisplaySummary(from entries: [CodexTranscriptEntry]) -> String? {
        latestActivityText(from: entries).map { displaySnippet(from: $0, maxLength: 1_200) }
    }

    private static func latestActivityText(from entries: [CodexTranscriptEntry]) -> String? {
        guard let latestEntry = entries.reversed().first(where: { entry in
            switch entry.role {
            case .assistant, .plan, .command, .system:
                return !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .user:
                return false
            }
        }) else {
            return nil
        }

        let text = strippingAgentResponseMetadata(from: latestEntry.text)
        return text.isEmpty ? nil : text
    }

    private static func liveCommandProgressSummary(command: String) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCommand.isEmpty {
            return "Running: \(spokenSnippet(from: trimmedCommand, maxLength: 90))"
        }

        return "Executing command…"
    }

    private static func commandStartedSummary(from item: [String: Any]) -> String {
        if let command = CodexJSON.string(item["command"]),
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Running command: \(spokenSnippet(from: command, maxLength: 90))"
        }

        if let commandActions = CodexJSON.array(item["commandActions"]) {
            for actionValue in commandActions {
                guard let action = CodexJSON.dictionary(actionValue),
                      let command = CodexJSON.string(action["command"]),
                      !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                return "Running command: \(spokenSnippet(from: command, maxLength: 90))"
            }
        }

        return "Running a command"
    }

    private static func webSearchStartedSummary(from item: [String: Any]) -> String {
        let query = CodexJSON.string(item["query"])
            ?? CodexJSON.string(item["searchQuery"])
            ?? CodexJSON.string(item["text"])
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Searching web: \(spokenSnippet(from: query, maxLength: 90))"
        }
        return "Searching the web"
    }

    private static func fileChangeStartedSummary(from item: [String: Any]) -> String {
        let path = CodexJSON.string(item["path"])
            ?? CodexJSON.string(item["filePath"])
            ?? CodexJSON.string(item["filename"])
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Editing a file"
        }
        return "Editing files"
    }

    private static func fileChangeCompletedSummary(from item: [String: Any]) -> String {
        let path = CodexJSON.string(item["path"])
            ?? CodexJSON.string(item["filePath"])
            ?? CodexJSON.string(item["filename"])
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Updated a file"
        }
        return "Updated files"
    }

    private static func humanReadableItemType(_ type: String) -> String {
        let spaced = type
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return spaced.isEmpty ? "tool" : spaced.lowercased()
    }


    private static func isRawTransportDiagnosticText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let signals = [
            "/incoming]",
            "/outgoing]",
            "[incoming]",
            "[outgoing]",
            "codex.rpc.message",
            "codex.rpc.notification",
            "codex.rpc.request",
            #""method":"#,
            "paramsSummary",
            "turn/completed",
            "thread/tokenUsage/updated",
            "account/rateLimits/updated"
        ]
        let signalCount = signals.filter { trimmed.localizedCaseInsensitiveContains($0) }.count
        return signalCount >= 2 || (trimmed.localizedCaseInsensitiveContains("codex.rpc") && signalCount >= 1)
    }

    private static func spokenSnippet(from text: String, maxLength: Int) -> String {
        if isRawTransportDiagnosticText(text) {
            return "OpenClicky runtime event"
        }

        let flattened = strippingAgentResponseMetadata(from: text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard flattened.count > maxLength else {
            return flattened
        }

        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxLength)
        let prefix = String(flattened[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return "\(prefix[..<lastSpace])..."
        }
        return "\(prefix)..."
    }

    private static func displaySnippet(from text: String, maxLength: Int) -> String {
        if isRawTransportDiagnosticText(text) {
            return "OpenClicky runtime event"
        }

        let flattened = strippingAgentResponseMetadata(from: text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard flattened.count > maxLength else {
            return flattened
        }

        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxLength)
        return String(flattened[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if DEBUG
extension CodexAgentSession {
    func setTestStatus(_ status: CodexAgentSessionStatus) {
        self.status = status
    }
    func setTestLastErrorMessage(_ message: String?) {
        self.lastErrorMessage = message
    }
}
#endif
