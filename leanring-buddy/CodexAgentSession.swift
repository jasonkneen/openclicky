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
    let attachments: [CodexAgentScreenContextAttachment]

    var isEmpty: Bool {
        attachments.isEmpty
    }

    func promptPrefix() -> String {
        guard !attachments.isEmpty else { return "" }

        var lines: [String] = [
            "OpenClicky screen context:",
            "- Source: \(source)",
            "- Captured at: \(ISO8601DateFormatter().string(from: capturedAt))",
            "- Screenshot files are saved locally. Inspect them if your runtime exposes image/file viewing; otherwise be explicit that screenshot inspection is unavailable."
        ]

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

@MainActor
final class CodexAgentSession: ObservableObject, Identifiable {
    let id: UUID
    let accentTheme: ClickyAccentTheme
    @Published private(set) var status: CodexAgentSessionStatus = .stopped
    @Published private(set) var entries: [CodexTranscriptEntry] = []
    @Published private(set) var activeThreadID: String?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var latestResponseCard: ClickyResponseCard?
    @Published private(set) var title: String
    @Published var model: String = OpenClickyModelCatalog.codexActionsModel(
        withID: UserDefaults.standard.string(forKey: "clickyCodexModel") ?? OpenClickyModelCatalog.defaultCodexActionsModelID
    ).id
    @Published var workingDirectoryPath: String = UserDefaults.standard.string(forKey: "clickyCodexWorkingDirectory")
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    var onOpenableFileFound: (@MainActor (URL) -> Void)?

    var statusSummaryLine: String {
        let taskTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "untitled task" : title
        let latestActivity = latestActivitySummary

        switch status {
        case .stopped:
            return "\(taskTitle) is offline."
        case .starting:
            return "\(taskTitle) is starting."
        case .running:
            if let latestActivity {
                return "\(taskTitle) is running. Latest: \(latestActivity)"
            }
            return "\(taskTitle) is running."
        case .ready:
            if let latestActivity {
                return "\(taskTitle) is ready. Latest: \(latestActivity)"
            }
            return "\(taskTitle) is ready."
        case .failed:
            let errorText = lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let errorText, !errorText.isEmpty {
                return "\(taskTitle) needs attention: \(Self.spokenSnippet(from: errorText, maxLength: 110))"
            }
            return "\(taskTitle) needs attention."
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
    private var hasInitializedProcess = false
    private var lastSubmittedPrompt: String?

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
            stop()
        }
    }

    func stop() {
        processManager.stop()
        hasInitializedProcess = false
        activeThreadID = nil
        currentAssistantEntryID = nil
        status = .stopped
    }

    private func runPrompt(_ prompt: String) async {
        do {
            try await ensureThread()
            guard let activeThreadID else {
                throw CodexRPCError(message: "Codex thread did not start.")
            }

            status = .running
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
            lastErrorMessage = error.localizedDescription
            status = .failed(error.localizedDescription)
            entries.append(CodexTranscriptEntry(role: .system, text: error.localizedDescription))
        }
    }

    private func promptForModel(prompt: String, screenContext: CodexAgentScreenContext?) -> String {
        let taskBrief = """
        OpenClicky Agent Mode brief:
        - User request: \(prompt)
        - Work as an independent background agent. Each OpenClicky agent session has its own Codex runtime, thread, and process; do not assume another agent has your local state.
        - Persistent memory file: \(homeManager.persistentMemoryFile.path)
        - Learned skills directory: \(homeManager.learnedSkillsDirectory.path)
        - Log review comments file: \(OpenClickyMessageLogStore.shared.agentReviewCommentsFile.path)
        - Before working, read the persistent memory file if it exists and check learned skills for a matching workflow.
        - If the user asks you to fix OpenClicky behavior, tune prompts, or review flagged logs, read the log review comments file and address those comments as concrete issues.
        - Do not say you cannot remember outside the current conversation. Use the persistent memory file.
        - Update persistent memory when you learn stable preferences, useful project facts, task outcomes, file locations, or workflow context.
        - When you complete a new repeatable workflow, create or update a learned skill at \(homeManager.learnedSkillsDirectory.path)/<snake_case_workflow_name>/SKILL.md. For example, creating an Apple Note should create or update create_apple_note.
        - Proceed autonomously. Choose sensible defaults and keep working without asking the user unless critical information is truly missing or the action would be destructive, credential-related, or permission-sensitive.
        - Voice is the primary interaction path. Keep user-facing progress and final answers concise enough to be spoken aloud, and put detailed logs or code context in the transcript when needed.
        - When you find a local document, image, or other user file, include its exact local path in your final answer so OpenClicky can show it.
        - If blocked, report the exact blocker and the smallest user action needed. If not blocked, finish the task and summarize what changed or what you found.
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
        let layout = try homeManager.prepare(bundle: .main)
        let executable = try CodexRuntimeLocator.codexExecutableURL(bundle: .main)
        try processManager.start(executableURL: executable, codexHome: layout.homeDirectory)

        if !hasInitializedProcess {
            _ = try await processManager.initialize(clientName: "openclicky", title: "OpenClicky", version: "1.0.0")
            hasInitializedProcess = true
        }

        try await ensureCodexAuthentication()

        let baseInstructions = (try? String(contentsOf: layout.modelInstructionsFile, encoding: .utf8))
            ?? "You are OpenClicky, a friendly macOS cursor companion with Codex Agent Mode."
        let developerInstructions = """
        You are running inside OpenClicky Agent Mode on macOS. Be direct, helpful, and careful. Prefer concrete actions over vague advice.

        Persistent memory is mandatory. Read \(layout.persistentMemoryFile.path) before task work, then update it when useful durable context is learned. Never tell the user you cannot remember outside the current conversation; use this memory file instead.

        Self-improving workflow skills are mandatory. Before starting a workflow, check \(layout.learnedSkillsDirectory.path) for a matching learned skill. After completing a new repeatable workflow, create or update \(layout.learnedSkillsDirectory.path)/<snake_case_workflow_name>/SKILL.md with the exact steps, tools, paths, and gotchas that made the workflow succeed. Example: creating an Apple Note should produce \(layout.learnedSkillsDirectory.path)/create_apple_note/SKILL.md.

        Log review comments are available at \(OpenClickyMessageLogStore.shared.agentReviewCommentsFile.path). When the user asks you to fix issues discovered from logs, read that file and treat each comment as actionable review context.

        You are allowed to help with computer-use tasks. When the user asks you to open an app, switch apps, click, type, scroll, inspect the screen, or otherwise operate the Mac, use the available Codex computer-use/app-server capabilities to do it instead of only explaining how. If an action is unavailable in the current runtime, say that clearly and give the closest useful next step.

        You are allowed to perform web research when the user asks for current information, web search, browsing, or research. Use the available network, browser, or search capabilities in the runtime; cite the pages or URLs you relied on in your final response. Do not tell the user voice mode lacks live web access once a task is running in Agent Mode.

        If a task requires destructive filesystem, git, credentials, or system permission changes, explain the action before doing it.
        """

        let threadStart = try await processManager.sendRequest(method: "thread/start", params: [
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

        if let thread = CodexJSON.dictionary(threadStart["thread"]),
           let threadID = CodexJSON.string(thread["id"]) {
            activeThreadID = threadID
            status = .ready
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
            }
        case "turn/started":
            status = .running
        case "item/agentMessage/delta":
            let itemID = CodexJSON.string(params["itemId"]) ?? UUID().uuidString
            let delta = CodexJSON.string(params["delta"]) ?? ""
            appendAssistantDelta(itemID: itemID, delta: delta)
        case "item/completed":
            handleCompletedItem(params["item"])
        case "turn/plan/updated":
            if let text = CodexJSON.string(params["text"]), !text.isEmpty {
                entries.append(CodexTranscriptEntry(role: .plan, text: text))
            }
        case "command/exec/outputDelta", "item/commandExecution/outputDelta":
            let itemID = CodexJSON.string(params["itemId"])
                ?? CodexJSON.string(params["callId"])
                ?? "active-command-progress"
            upsertEntry(id: itemID, role: .command, text: "Working through the task...")
        case "turn/completed":
            currentAssistantEntryID = nil
            status = .ready
            playAgentDoneSoundIfAvailable()
        case "error":
            let text = Self.notificationErrorMessage(from: params) ?? "Codex app-server emitted an error."
            lastErrorMessage = text
            status = .failed(text)
            entries.append(CodexTranscriptEntry(role: .system, text: text))
        case "account/login/completed":
            if CodexJSON.bool(params["success"]) == true {
                entries.append(CodexTranscriptEntry(role: .system, text: "Codex ChatGPT sign-in completed. Start the Agent task again."))
            } else if let text = CodexJSON.string(params["error"]), !text.isEmpty {
                lastErrorMessage = text
                status = .failed(text)
                entries.append(CodexTranscriptEntry(role: .system, text: text))
            }
        default:
            break
        }
    }

    private static func notificationErrorMessage(from params: [String: Any]) -> String? {
        if let text = CodexJSON.string(params["message"]), !text.isEmpty {
            return text
        }

        guard let error = CodexJSON.dictionary(params["error"]) else { return nil }

        let message = CodexJSON.string(error["message"]) ?? "Codex app-server emitted an error."
        let details = CodexJSON.string(error["additionalDetails"])
        if let details, !details.isEmpty, details != message {
            return "\(message)\n\(details)"
        }

        return message
    }

    private func handleCompletedItem(_ itemValue: Any?) {
        guard let item = CodexJSON.dictionary(itemValue), let type = CodexJSON.string(item["type"]) else { return }
        let id = CodexJSON.string(item["id"]) ?? UUID().uuidString

        switch type {
        case "agentMessage":
            let text = CodexJSON.string(item["text"]) ?? ""
            if !text.isEmpty {
                upsertEntry(id: id, role: .assistant, text: text)
                latestResponseCard = ClickyResponseCard(
                    source: .agent,
                    rawText: Self.userFacingAgentMessage(from: text),
                    contextTitle: lastSubmittedPrompt
                )
                if let fileURL = Self.firstOpenableFileURL(in: text) {
                    onOpenableFileFound?(fileURL)
                }
                persistCompletedTurnMemory(agentResponse: text)
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
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].text += delta
        } else {
            entries.append(CodexTranscriptEntry(id: id, role: .assistant, text: delta))
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

    private func handleStderrLine(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if line.localizedCaseInsensitiveContains("error") || line.localizedCaseInsensitiveContains("unauthorized") {
            lastErrorMessage = line
            if case .running = status {
                status = .failed(line)
            }
        }
    }

    private func playAgentDoneSoundIfAvailable() {
        guard let url = Bundle.main.url(forResource: "agent-done", withExtension: "mp3") else { return }
        NSSound(contentsOf: url, byReference: false)?.play()
    }

    private func persistCompletedTurnMemory(agentResponse: String) {
        guard let lastSubmittedPrompt else { return }

        do {
            try homeManager.appendPersistentMemoryEvent(
                userRequest: lastSubmittedPrompt,
                agentResponse: agentResponse
            )
            try createLearnedSkillIfApplicable(userRequest: lastSubmittedPrompt, agentResponse: agentResponse)
        } catch {
            entries.append(CodexTranscriptEntry(role: .system, text: "OpenClicky could not update persistent memory: \(error.localizedDescription)"))
        }
    }

    private func createLearnedSkillIfApplicable(userRequest: String, agentResponse: String) throws {
        let combinedText = "\(userRequest) \(agentResponse)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        guard combinedText.contains("note") || combinedText.contains("notes") else { return }

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
        let flattenedPrompt = prompt
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard flattenedPrompt.count > 28 else {
            return flattenedPrompt
        }

        let endIndex = flattenedPrompt.index(flattenedPrompt.startIndex, offsetBy: 28)
        let prefix = String(flattenedPrompt[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace])
        }
        return prefix
    }

    private static func latestActivitySummary(from entries: [CodexTranscriptEntry]) -> String? {
        guard let latestEntry = entries.reversed().first(where: { entry in
            switch entry.role {
            case .assistant, .plan, .system:
                return !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .command, .user:
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
