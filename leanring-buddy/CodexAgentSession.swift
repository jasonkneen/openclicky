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

    private let homeManager: CodexHomeManager
    private let processManager: CodexProcessManager
    private var currentAssistantEntryID: String?
    private var hasInitializedProcess = false
    private var lastSubmittedPrompt: String?

    init(
        id: UUID = UUID(),
        title: String = "Agent",
        accentTheme: ClickyAccentTheme = .blue,
        homeManager: CodexHomeManager = CodexHomeManager(),
        processManager: CodexProcessManager = CodexProcessManager()
    ) {
        self.id = id
        self.title = title
        self.accentTheme = accentTheme
        self.homeManager = homeManager
        self.processManager = processManager

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

    func submitPromptFromUI(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if entries.isEmpty {
            title = Self.shortTitle(from: trimmed)
        }

        lastSubmittedPrompt = trimmed
        entries.append(CodexTranscriptEntry(role: .user, text: trimmed))
        Task {
            await runPrompt(trimmed)
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
                "effort": homeManager.reasoningEffort,
                "responsesapiClientMetadata": [
                    "client": "openclicky",
                    "surface": "agent-mode"
                ]
            ])
        } catch {
            lastErrorMessage = error.localizedDescription
            status = .failed(error.localizedDescription)
            entries.append(CodexTranscriptEntry(role: .system, text: error.localizedDescription))
        }
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

        let baseInstructions = (try? String(contentsOf: layout.modelInstructionsFile, encoding: .utf8))
            ?? "You are OpenClicky, a friendly macOS cursor companion with Codex Agent Mode."
        let developerInstructions = """
        You are running inside OpenClicky Agent Mode on macOS. Be direct, helpful, and careful. Prefer concrete actions over vague advice. If a task requires destructive filesystem, git, credentials, or system permission changes, explain the action before doing it.
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
            "sessionStartSource": "startup",
            "dynamicTools": [],
            "experimentalRawEvents": false,
            "persistExtendedHistory": false
        ])

        if let thread = CodexJSON.dictionary(threadStart["thread"]),
           let threadID = CodexJSON.string(thread["id"]) {
            activeThreadID = threadID
            status = .ready
        } else {
            throw CodexRPCError(message: "Codex app-server did not return a thread id.")
        }
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
            let delta = CodexJSON.string(params["delta"]) ?? CodexJSON.string(params["chunk"]) ?? ""
            if !delta.isEmpty {
                entries.append(CodexTranscriptEntry(role: .command, text: delta))
            }
        case "turn/completed":
            currentAssistantEntryID = nil
            status = .ready
            playAgentDoneSoundIfAvailable()
        case "error":
            let text = CodexJSON.string(params["message"]) ?? "Codex app-server emitted an error."
            lastErrorMessage = text
            status = .failed(text)
            entries.append(CodexTranscriptEntry(role: .system, text: text))
        default:
            break
        }
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
                    rawText: text,
                    contextTitle: lastSubmittedPrompt
                )
            }
            currentAssistantEntryID = nil
        case "plan":
            if let text = CodexJSON.string(item["text"]), !text.isEmpty {
                upsertEntry(id: id, role: .plan, text: text)
            }
        case "commandExecution":
            let command = CodexJSON.string(item["command"]) ?? "Command"
            let output = CodexJSON.string(item["aggregatedOutput"]) ?? ""
            let exitCode = CodexJSON.int(item["exitCode"]).map { "exit \($0)" } ?? "running"
            upsertEntry(id: id, role: .command, text: "\(command) — \(exitCode)\n\(output)")
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
}
