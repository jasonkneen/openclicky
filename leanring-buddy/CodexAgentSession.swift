import AppKit
import Combine
import Foundation

struct CodexTranscriptEntry: Identifiable, Equatable {
    enum Role: String, Equatable {
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
            "- Screenshot files are saved locally. Inspect them if your runtime exposes image/file viewing; otherwise be explicit that screenshot inspection is unavailable."
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
        case .stopped: return "Offline"
        case .starting: return "Starting"
        case .ready: return "Ready"
        case .running: return "Running"
        case .failed: return "Needs attention"
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
        case .failed: return "Needs attention"
        }
    }
}

@MainActor
final class CodexAgentSession: ObservableObject, Identifiable {
    let id: UUID
    let accentTheme: ClickyAccentTheme
    @Published private(set) var status: CodexAgentSessionStatus = .stopped
    @Published private(set) var entries: [CodexTranscriptEntry] = []
    @Published private(set) var activeThreadID: String?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var latestResponseCard: ClickyResponseCard?
    @Published private(set) var stopReason: String?
    @Published private(set) var title: String
    @Published private(set) var progressStage: CodexAgentProgressStage = .idle
    @Published var model: String = OpenClickyModelCatalog.codexActionsModel(
        withID: UserDefaults.standard.string(forKey: "clickyCodexModel") ?? OpenClickyModelCatalog.defaultCodexActionsModelID
    ).id
    @Published var workingDirectoryPath: String = UserDefaults.standard.string(forKey: "clickyCodexWorkingDirectory")
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    var onOpenableFileFound: (@MainActor (URL) -> Void)?

    var spokenAgentName: String {
        "the agent"
    }

    var spokenAgentSentenceName: String {
        "The agent"
    }

    var statusSummaryLine: String {
        let agentName = spokenAgentSentenceName
        let latestActivity = latestActivitySummary

        switch status {
        case .stopped:
            return "\(agentName) is offline."
        case .starting:
            return "An agent is starting."
        case .running:
            if let latestActivity {
                return "An agent is working. Latest: \(latestActivity)"
            }
            return "An agent is working."
        case .ready:
            if let latestActivity {
                return "The agent has completed the task. Latest: \(latestActivity)"
            }
            return "The agent is ready."
        case .failed:
            let errorText = lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let errorText, !errorText.isEmpty {
                return "\(agentName) needs attention: \(Self.spokenSnippet(from: errorText, maxLength: 110))"
            }
            return "\(agentName) needs attention."
        }
    }

    var latestActivitySummary: String? {
        Self.latestActivitySummary(from: entries)
    }

    var hasVisibleActivity: Bool {
        !entries.isEmpty || activeThreadID != nil || status != .stopped
    }

    private let homeManager: CodexHomeManager
    private let processManager: CodexProcessManager
    private var currentAssistantEntryID: String?
    private var pendingAssistantDeltas: [String: String] = [:]
    private var pendingAssistantDeltaFlushTask: Task<Void, Never>?
    private var hasInitializedProcess = false
    private var lastSubmittedPrompt: String?
    private static let codexRuntimeCompatibilityFallbackModel = "gpt-5.4-mini"
    private static let assistantDeltaFlushDelayNanoseconds: UInt64 = 180_000_000

    init(
        id: UUID = UUID(),
        title: String = "Agent",
        accentTheme: ClickyAccentTheme = .blue,
        homeManager: CodexHomeManager? = nil,
        processManager: CodexProcessManager? = nil
    ) {
        self.id = id
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

    func submitPromptFromUI(_ prompt: String, screenContext: CodexAgentScreenContext? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if entries.isEmpty {
            title = Self.shortTitle(from: trimmed)
        }

        lastSubmittedPrompt = trimmed
        entries.append(CodexTranscriptEntry(role: .user, text: trimmed))
        Task {
            await runPrompt(promptForModel(prompt: trimmed, screenContext: screenContext))
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
                "model": model,
                "effort": homeManager.reasoningEffort
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

    private func promptForModel(prompt: String, screenContext: CodexAgentScreenContext?) -> String {
        let taskBrief = """
        OpenClicky Agent Mode brief:
        - User request: \(prompt)
        - Work as an independent background agent. Each OpenClicky agent session has its own Codex runtime, thread, and process; do not assume another agent has your local state.
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
        - When you find a local document, image, or other user file, include its exact local path in your final answer so OpenClicky can show it.
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
        let homeManager = self.homeManager
        let processManager = self.processManager
        let preparedLayout = try homeManager.prepare(bundle: .main)
        let executable = try CodexRuntimeLocator.codexExecutableURL(bundle: .main)
        let layout = try await Task.detached(priority: .userInitiated) {
            try processManager.start(executableURL: executable, codexHome: preparedLayout.homeDirectory)
            return preparedLayout
        }.value

        if !hasInitializedProcess {
            _ = try await processManager.initialize(clientName: "openclicky", title: "OpenClicky", version: "1.0.0")
            hasInitializedProcess = true
        }

        try await ensureCodexAuthentication()

        let baseInstructions = (try? String(contentsOf: layout.modelInstructionsFile, encoding: .utf8))
            ?? "You are OpenClicky, a friendly macOS cursor companion with Codex Agent Mode."
        let developerInstructions = """
        You are running inside OpenClicky Agent Mode on macOS. Be direct, helpful, and careful. Prefer concrete actions over vague advice.

        When working on the OpenClicky app repo, do not run terminal `xcodebuild`. Use Xcode for app builds and permission testing, and use `swiftc -parse <relevant Swift source files>` for lightweight Swift syntax checks.

        OpenClicky's runtime map is at \(layout.runtimeMapFile.path). Read it when the user asks about logs, storage locations, memory, skills, widgets, settings, sessions, or where OpenClicky keeps anything. You may view or edit those local files when asked, subject to normal safety rules for destructive changes, credentials, and permissions.

        OpenClicky's persona is at \(layout.soulFile.path). Read it before task work. Treat it as the operating identity for voice-first behavior, autonomy, memory, archive-first changes, and plain-English progress.

        Archive-first is mandatory. When replacing, optimizing, pruning, or superseding OpenClicky memory, skills, runtime notes, prompts, config, or log-derived artifacts, copy or move the old version into \(layout.archivesDirectory.path) first. Do not delete old artifacts unless the user explicitly asks for deletion and understands it is destructive.

        Persistent memory is available. Read \(layout.persistentMemoryFile.path) before task work, then update it only when useful durable context is learned. Never tell the user you cannot remember outside the current conversation; use this memory file instead.

        Learned skills live at \(layout.learnedSkillsDirectory.path). Use or update them when the user asks to inspect, optimize, or learn from skills/logs, or when a repeated workflow would materially speed up future work. Do not announce learned-skill checks or skill creation in progress or final answers unless the user asked about skills.

        Message logs are stored in \(OpenClickyMessageLogStore.shared.logDirectory.path). The current JSONL log is \(OpenClickyMessageLogStore.shared.currentLogFile.path). Log review comments are available at \(OpenClickyMessageLogStore.shared.agentReviewCommentsFile.path), with JSONL comments at \(OpenClickyMessageLogStore.shared.reviewCommentsFile.path). When the user asks you to fix issues discovered from logs, read those files and treat each comment as actionable review context.

        When the user asks you to optimize skills, audit learned skills, or learn from logs, treat that as an active task: inspect the relevant files, identify repeatable improvements, archive old versions first, then create or update memory entries and learned skill files that make future agents faster and better.

        Widget state is available at \(OpenClickyWidgetStateStore.snapshotURL.path). When the user asks about widgets or desktop task/status display, read that snapshot before changing widget behavior.

        You are allowed to help with computer-use tasks. OpenClicky may be configured to use native CUA Swift or Background Computer Use for direct control before Agent Mode. When you operate the Mac from Agent Mode, prefer OpenClicky's available direct computer-use path and the `cuaDriver` MCP server when available; describe it as OpenClicky's computer-use path rather than assuming CUA is always selected. Do not choose or advertise Clawd or clawdcursor mouse/keyboard tools as the default for typing or focused-window control; use them only as an explicit fallback when OpenClicky's direct computer-use path is unavailable and say that it is a fallback. Simple focused-window typing is normally intercepted by OpenClicky before Agent Mode and handled through the selected direct computer-use backend.

        You are allowed to perform web research when the user asks for current information, web search, browsing, or research. Use the available network, browser, or search capabilities in the runtime; cite the pages or URLs you relied on in your final response. Do not tell the user voice mode lacks live web access once a task is running in Agent Mode.

        If a task requires destructive filesystem, git, credentials, or system permission changes, explain the action before doing it.
        """

        let threadStart: [String: Any]
        do {
            threadStart = try await processManager.sendRequest(method: "thread/start", params: [
                "model": model,
                "modelProvider": homeManager.modelProviderID,
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
        guard homeManager.modelProviderID == ClickyCodexConfigTemplate.defaultModelProviderID else { return }

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
        case "item/agentMessage/delta":
            let itemID = CodexJSON.string(params["itemId"]) ?? UUID().uuidString
            let delta = CodexJSON.string(params["delta"]) ?? ""
            progressStage = .composing
            appendAssistantDelta(itemID: itemID, delta: delta)
        case "item/started":
            if blockForbiddenCommandIfNeeded(params["item"]) {
                return
            }
        case "item/completed":
            handleCompletedItem(params["item"])
        case "turn/plan/updated":
            if let text = CodexJSON.string(params["text"]), !text.isEmpty {
                progressStage = .planning
                entries.append(CodexTranscriptEntry(role: .plan, text: text))
            }
        case "command/exec/outputDelta", "item/commandExecution/outputDelta":
            let itemID = CodexJSON.string(params["itemId"])
                ?? CodexJSON.string(params["callId"])
                ?? "active-command-progress"
            progressStage = .executing
            upsertEntryIfChanged(id: itemID, role: .command, text: "Working through the task...")
        case "turn/completed":
            flushPendingAssistantDeltas()
            currentAssistantEntryID = nil
            status = .ready
            progressStage = .completed
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

    private func handleCompletedItem(_ itemValue: Any?) {
        guard let item = CodexJSON.dictionary(itemValue), let type = CodexJSON.string(item["type"]) else { return }
        let id = CodexJSON.string(item["id"]) ?? UUID().uuidString

        switch type {
        case "agentMessage":
            flushPendingAssistantDeltas(for: id)
            let text = CodexJSON.string(item["text"]) ?? ""
            if !text.isEmpty {
                let parsed = Self.extractTaskTitleMetadata(from: text)
                if let taskTitle = parsed.taskTitle {
                    title = taskTitle
                }
                let visibleText = parsed.visibleText
                upsertEntry(id: id, role: .assistant, text: visibleText)
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
            currentAssistantEntryID = nil
        case "plan":
            if let text = CodexJSON.string(item["text"]), !text.isEmpty {
                upsertEntry(id: id, role: .plan, text: text)
            }
        case "commandExecution":
            let command = CodexJSON.string(item["command"]) ?? "Command"
            let output = CodexJSON.string(item["aggregatedOutput"]) ?? ""
            let exitCode = CodexJSON.int(item["exitCode"])
            upsertEntry(
                id: id,
                role: .command,
                text: Self.plainEnglishCommandSummary(command: command, output: output, exitCode: exitCode)
            )
        default:
            break
        }
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

        return normalized.contains("responses_websocket")
            && normalized.contains("failed to connect to websocket")
            && normalized.contains("bad gateway")
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

        if isNoteWorkflow(combinedText: normalizedCombined) {
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

    private func isNoteWorkflow(combinedText: String) -> Bool {
        let noteTerms = ["note", "notes", "apple note", "apple notes"]
        return noteTerms.contains { combinedText.contains($0) }
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
        if let fileURL = firstOpenableFileURL(in: text) {
            return "Found \(fileURL.lastPathComponent). Showing it now."
        }

        return text
    }

    private static func plainEnglishCommandSummary(command: String, output: String, exitCode: Int?) -> String {
        let loweredCommand = command.lowercased()
        let loweredOutput = output.lowercased()

        if let exitCode, exitCode != 0 {
            return "A tool step needs attention."
        }

        if loweredCommand.contains("mdfind")
            || loweredCommand.contains(" find ")
            || loweredCommand.hasPrefix("find ")
            || loweredCommand.contains(" rg ")
            || loweredCommand.hasPrefix("rg ")
            || loweredCommand.contains(" grep ")
            || loweredCommand.hasPrefix("grep ")
            || loweredCommand.contains(" ls ")
            || loweredCommand.hasPrefix("ls ") {
            return "Looking for matching files..."
        }

        if loweredCommand.contains("open ")
            || loweredCommand.contains("qlmanage")
            || loweredCommand.contains("quick look")
            || loweredOutput.contains("opened")
            || loweredOutput.contains("showing") {
            return "Showing the result..."
        }

        if loweredCommand.contains("osascript")
            || loweredCommand.contains("tell application")
            || loweredCommand.contains("activate") {
            return "Focusing the right app..."
        }

        if loweredCommand.contains("swift")
            || loweredCommand.contains("npm")
            || loweredCommand.contains("node")
            || loweredCommand.contains("python")
            || loweredCommand.contains("pytest")
            || loweredCommand.contains("test") {
            return "Checking the work..."
        }

        return "Working through the task..."
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
            of: #"(?i)\b(?:the|a|an|this|that|it|them|you|your|then|also|with|from|into|and|or|but|for|of|to|in|on|as|is|are|be)\b"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\b(?:words?|thing|stuff|phrases?|responses?)\b"#,
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

        let visibleText = visibleLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (visibleText.isEmpty ? text : visibleText, extractedTitle)
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

        return spokenSnippet(from: latestEntry.text, maxLength: 120)
    }

    private static func spokenSnippet(from text: String, maxLength: Int) -> String {
        let flattened = text
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
}
