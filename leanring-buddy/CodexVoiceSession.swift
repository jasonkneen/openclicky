import AppKit
import Foundation

@MainActor
final class CodexVoiceSession {
    private typealias ResponseContinuation = CheckedContinuation<(text: String, duration: TimeInterval), Error>

    private struct PendingTurn {
        let id: String
        let kind: String
        let turnID: String
        let startedAt: Date
        let temporaryDirectory: URL
        let onTextChunk: @MainActor @Sendable (String) -> Void
        let continuation: ResponseContinuation
        var accumulatedText: String
        var didReceiveFirstDelta: Bool
    }

    private let homeManager: CodexHomeManager
    private let processManager: CodexProcessManager
    private let fileManager: FileManager
    private let workingDirectory: URL
    var model: String {
        didSet {
            guard oldValue != model else { return }
            homeManager.model = model
            stop()
        }
    }

    private var activeThreadID: String?
    private var hasInitializedProcess = false
    private var pendingTurn: PendingTurn?
    private var isWarmUpInFlight = false
    private var didWarmUpCurrentThread = false

    init(
        model: String,
        homeManager: CodexHomeManager,
        processManager: CodexProcessManager? = nil,
        fileManager: FileManager = .default,
        workingDirectory: URL? = nil
    ) {
        self.model = model
        self.homeManager = homeManager
        self.processManager = processManager ?? CodexProcessManager()
        self.fileManager = fileManager
        self.workingDirectory = workingDirectory ?? fileManager.homeDirectoryForCurrentUser

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

    func warmUp(systemPrompt: String) {
        guard !isWarmUpInFlight, !didWarmUpCurrentThread, pendingTurn == nil else { return }
        isWarmUpInFlight = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWarmUpInFlight = false }

            do {
                _ = try await self.sendTurn(
                    kind: "warmup",
                    images: [],
                    systemPrompt: systemPrompt,
                    conversationHistory: [],
                    userPrompt: "get ready. prime the OpenClicky Codex voice response session and reply with ready only.",
                    onTextChunk: { _ in }
                )
                self.didWarmUpCurrentThread = true
            } catch where Self.isExpectedWarmUpCancellation(error) {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "internal",
                    event: "codex_voice.warmup.cancelled",
                    fields: self.logFields(extra: [
                        "reason": Self.expectedWarmUpCancellationReason(for: error)
                    ])
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "error",
                    event: "codex_voice.warmup.failed",
                    fields: self.logFields(extra: [
                        "error": error.localizedDescription
                    ])
                )
            }
        }
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        try await sendTurn(
            kind: "request",
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
    }

    func cancelActiveTurn(reason: String = "cancelled") {
        guard let pending = pendingTurn else { return }
        pendingTurn = nil
        cleanupTemporaryDirectory(pending.temporaryDirectory)
        pending.continuation.resume(throwing: CancellationError())

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "outgoing",
            event: "codex_voice.turn.interrupt",
            fields: logFields(extra: [
                "requestID": pending.id,
                "turnID": pending.turnID,
                "reason": reason
            ])
        )

        guard let activeThreadID, processManager.isRunning else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.processManager.sendRequest(method: "turn/interrupt", params: [
                "threadId": activeThreadID,
                "turnId": pending.turnID
            ])
        }
    }

    func stop() {
        if pendingTurn != nil {
            cancelActiveTurn(reason: "session_stopped")
        }
        processManager.stop()
        activeThreadID = nil
        hasInitializedProcess = false
        isWarmUpInFlight = false
        didWarmUpCurrentThread = false
    }

    private func sendTurn(
        kind: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        if pendingTurn != nil {
            cancelActiveTurn(reason: "superseded_by_new_voice_turn")
        }

        try Task.checkCancellation()
        try await ensureThread()
        guard let activeThreadID else {
            throw CodexRPCError(message: "Codex app-server did not start a voice thread.")
        }

        let requestID = UUID().uuidString
        let temporaryDirectory = try makeTemporaryDirectory()

        do {
            let attachments = try writeImageAttachments(images, to: temporaryDirectory)
            let prompt = Self.composePrompt(
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                attachments: attachments,
                userPrompt: userPrompt
            )
            var input: [[String: Any]] = [[
                "type": "text",
                "text": prompt,
                "text_elements": []
            ]]
            input.append(contentsOf: attachments.map { attachment in
                [
                    "type": "localImage",
                    "path": attachment.fileURL.path
                ]
            })

            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "outgoing",
                event: kind == "warmup" ? "codex_voice.warmup.request" : "codex_voice.query.request",
                fields: logFields(extra: [
                    "requestID": requestID,
                    "promptLength": prompt.count,
                    "imageCount": attachments.count
                ])
            )

            let turnStart = try await processManager.sendRequest(method: "turn/start", params: [
                "threadId": activeThreadID,
                "input": input,
                "cwd": workingDirectory.path,
                "approvalPolicy": "never",
                "model": model,
                // Voice responses should prioritize first-token latency;
                // Agent Mode keeps the user-selected reasoning effort.
                "effort": "low"
            ])

            guard let turn = CodexJSON.dictionary(turnStart["turn"]),
                  let turnID = CodexJSON.string(turn["id"]) else {
                throw CodexRPCError(message: "Codex app-server did not return a voice turn id.")
            }

            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pendingTurn = PendingTurn(
                    id: requestID,
                    kind: kind,
                    turnID: turnID,
                    startedAt: Date(),
                    temporaryDirectory: temporaryDirectory,
                    onTextChunk: onTextChunk,
                    continuation: continuation,
                    accumulatedText: "",
                    didReceiveFirstDelta: false
                )
            }
        } catch {
            cleanupTemporaryDirectory(temporaryDirectory)
            throw error
        }
    }

    private func ensureThread() async throws {
        if processManager.isRunning, activeThreadID != nil {
            return
        }

        homeManager.model = model
        let layout = try homeManager.prepare(bundle: .main)
        let executable = try CodexRuntimeLocator.codexExecutableURL(bundle: .main)
        try processManager.start(executableURL: executable, codexHome: layout.homeDirectory)

        if !hasInitializedProcess {
            _ = try await processManager.initialize(clientName: "openclicky-voice", title: "OpenClicky Voice", version: "1.0.0")
            hasInitializedProcess = true
        }

        try await ensureCodexAuthentication()

        let baseInstructions = (try? String(contentsOf: layout.modelInstructionsFile, encoding: .utf8))
            ?? "You are OpenClicky, a voice-first macOS cursor companion."
        let developerInstructions = """
        You are OpenClicky's persistent local Codex voice response session.

        Stay fast, concise, and voice-first. Each turn includes the current OpenClicky voice policy, recent conversation, memory context, and any screenshots as localImage input items. Inspect attached localImage inputs directly when screen context matters.

        This voice-response session is not Agent Mode. Do not spawn agents, assign background tasks, or ask for agent confirmation. Simple computer-control requests are handled by OpenClicky's native CUA router before they reach you; when you do receive a voice-response turn, answer briefly and include OpenClicky's [POINT:x,y:label] tag only when pointing would help.

        Do not run shell commands, Python, find, ls, or other terminal tools from this voice-response session to inspect local files or folders. If the user asks to view, find, inspect, clean up, or open a local file or folder and the request was not handled by direct computer use, explain that file inspection belongs in explicit Agent Mode and give the exact phrase to say.

        Keep the Codex app-server process warm. Treat API keys as fallback; prefer this local Codex session when it is available.
        """

        let threadStart = try await processManager.sendRequest(method: "thread/start", params: [
            "model": model,
            "modelProvider": homeManager.modelProviderID,
            "cwd": workingDirectory.path,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "config": [:],
            "serviceName": "OpenClicky Voice",
            "baseInstructions": baseInstructions,
            "developerInstructions": developerInstructions,
            "personality": "friendly",
            "ephemeral": true,
            "sessionStartSource": "startup"
        ])

        if let thread = CodexJSON.dictionary(threadStart["thread"]),
           let threadID = CodexJSON.string(thread["id"]) {
            activeThreadID = threadID
            didWarmUpCurrentThread = false
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "incoming",
                event: "codex_voice.thread.ready",
                fields: logFields(extra: [
                    "threadID": threadID
                ])
            )
        } else {
            throw CodexRPCError(message: "Codex app-server did not return a voice thread id.")
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

        if AppBundleConfiguration.openAIAPIKey() != nil {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "error",
                event: "codex_voice.auth.login_missing_api_fallback",
                fields: logFields()
            )
            throw CodexRPCError(message: "Codex ChatGPT login is not available. OpenClicky is falling back to the OpenAI API key.")
        }

        let loginStart = try await processManager.sendRequest(method: "account/login/start", params: [
            "type": "chatgpt"
        ])

        if let authURLString = CodexJSON.string(loginStart["authUrl"]),
           let authURL = URL(string: authURLString) {
            NSWorkspace.shared.open(authURL)
        }

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "error",
            event: "codex_voice.auth.login_required",
            fields: logFields()
        )
        throw CodexRPCError(message: "OpenClicky found no Codex ChatGPT login. Finish the Codex sign-in that just opened, then try again.")
    }

    private func handleNotification(_ notification: [String: Any]) {
        guard let method = CodexJSON.string(notification["method"]) else { return }
        let params = CodexJSON.dictionary(notification["params"]) ?? [:]

        switch method {
        case "thread/started":
            if let thread = CodexJSON.dictionary(params["thread"]),
               let threadID = CodexJSON.string(thread["id"]) {
                activeThreadID = threadID
            }
        case "item/agentMessage/delta":
            handleAssistantDelta(params)
        case "item/completed":
            handleCompletedItem(params["item"], turnID: CodexJSON.string(params["turnId"]))
        case "turn/completed":
            handleTurnCompleted(params)
        case "error":
            let text = Self.notificationErrorMessage(from: params) ?? "Codex app-server emitted an error."
            failPendingTurn(CodexRPCError(message: text), event: "codex_voice.query.error")
        default:
            break
        }
    }

    private func handleAssistantDelta(_ params: [String: Any]) {
        guard var pending = pendingTurn,
              CodexJSON.string(params["turnId"]) == pending.turnID,
              let delta = CodexJSON.string(params["delta"]),
              !delta.isEmpty else { return }

        pending.accumulatedText += delta
        if !pending.didReceiveFirstDelta {
            pending.didReceiveFirstDelta = true
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "incoming",
                event: "codex_voice.query.first_text_delta",
                fields: logFields(extra: [
                    "requestID": pending.id,
                    "turnID": pending.turnID,
                    "firstTokenLatencyMs": Self.elapsedMilliseconds(from: pending.startedAt, to: Date())
                ])
            )
        }

        pendingTurn = pending
        pending.onTextChunk(pending.accumulatedText)
    }

    private func handleCompletedItem(_ itemValue: Any?, turnID: String?) {
        guard var pending = pendingTurn,
              turnID == pending.turnID,
              let item = CodexJSON.dictionary(itemValue),
              CodexJSON.string(item["type"]) == "agentMessage",
              let text = CodexJSON.string(item["text"]),
              !text.isEmpty,
              text != pending.accumulatedText else {
            return
        }

        pending.accumulatedText = text
        pendingTurn = pending
        pending.onTextChunk(text)
    }

    private func handleTurnCompleted(_ params: [String: Any]) {
        guard let turn = CodexJSON.dictionary(params["turn"]),
              let turnID = CodexJSON.string(turn["id"]),
              let pending = pendingTurn,
              pending.turnID == turnID else {
            return
        }

        let status = CodexJSON.string(turn["status"]) ?? "completed"
        if status == "failed" {
            let message = Self.turnErrorMessage(from: turn) ?? "Codex voice turn failed."
            failPendingTurn(CodexRPCError(message: message), event: "codex_voice.query.failed")
            return
        }

        if status == "interrupted" {
            failPendingTurn(CancellationError(), event: "codex_voice.query.interrupted")
            return
        }

        let text = pending.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Date().timeIntervalSince(pending.startedAt)
        pendingTurn = nil
        cleanupTemporaryDirectory(pending.temporaryDirectory)

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: pending.kind == "warmup" ? "codex_voice.warmup.ready" : "codex_voice.query.response",
            fields: logFields(extra: [
                "requestID": pending.id,
                "turnID": pending.turnID,
                "responseLength": text.count,
                "durationMs": Int((duration * 1000).rounded())
            ])
        )
        pending.continuation.resume(returning: (text: text, duration: duration))
    }

    private func failPendingTurn(_ error: Error, event: String) {
        guard let pending = pendingTurn else { return }
        pendingTurn = nil
        cleanupTemporaryDirectory(pending.temporaryDirectory)

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "error",
            event: event,
            fields: logFields(extra: [
                "requestID": pending.id,
                "turnID": pending.turnID,
                "error": error.localizedDescription
            ])
        )
        pending.continuation.resume(throwing: error)
    }

    private func handleStderrLine(_ line: String) {
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: "codex_voice.stderr",
            fields: logFields(extra: [
                "line": Self.truncated(line, maxLength: 1_000)
            ])
        )
    }

    private func writeImageAttachments(
        _ images: [(data: Data, label: String)],
        to directory: URL
    ) throws -> [(label: String, fileURL: URL)] {
        try images.enumerated().map { index, image in
            let fileExtension = image.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
            let fileURL = directory.appendingPathComponent("screen-\(index + 1).\(fileExtension)", isDirectory: false)
            try image.data.write(to: fileURL, options: [.atomic])
            return (label: image.label, fileURL: fileURL)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenClickyCodexVoice", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanupTemporaryDirectory(_ directory: URL) {
        try? fileManager.removeItem(at: directory)
    }

    private func logFields(extra: [String: Any] = [:]) -> [String: Any] {
        var fields: [String: Any] = [
            "executor": "voice_response",
            "executionMethod": "CodexVoiceSession.turnStart",
            "authMode": "local_codex_chatgpt_primary",
            "transport": "codex_app_server_stdio",
            "streamingMethod": "codex_app_server_agentMessage_delta",
            "model": model,
            "apiKeyFallback": AppBundleConfiguration.openAIAPIKey() != nil
        ]
        extra.forEach { fields[$0.key] = $0.value }
        return fields
    }

    private static func isExpectedWarmUpCancellation(_ error: Error) -> Bool {
        isExpectedCancellation(error) || isCodexAppServerStopped(error)
    }

    private static func expectedWarmUpCancellationReason(for error: Error) -> String {
        if isCodexAppServerStopped(error) {
            return "app_server_stopped"
        }
        return "expected_cancellation"
    }

    private static func isExpectedCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return true
        }

        let description = String(describing: error).lowercased()
        return description == "cancellationerror()" || description.contains("cancelled") || description.contains("canceled")
    }

    private static func isCodexAppServerStopped(_ error: Error) -> Bool {
        let localized = (error as NSError).localizedDescription.lowercased()
        let description = String(describing: error).lowercased()
        return localized.contains("codex app-server stopped") || description.contains("codex app-server stopped")
    }

    private static func composePrompt(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        attachments: [(label: String, fileURL: URL)],
        userPrompt: String
    ) -> String {
        var sections = [
            "OpenClicky voice policy and memory:\n\(systemPrompt)"
        ]

        if conversationHistory.isEmpty {
            sections.append("Recent conversation:\nnone")
        } else {
            var lines = ["Recent conversation:"]
            for entry in conversationHistory {
                lines.append("User: \(entry.userPlaceholder)")
                lines.append("OpenClicky: \(entry.assistantResponse)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if attachments.isEmpty {
            sections.append("Screen context:\nNo screenshots are attached.")
        } else {
            var lines = [
                "Screen context:",
                "The following screenshots are attached to this Codex turn as localImage inputs. Use their labels and dimensions for [POINT:x,y:label] coordinates."
            ]
            for (index, attachment) in attachments.enumerated() {
                lines.append("\(index + 1). \(attachment.label): \(attachment.fileURL.path)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        sections.append("User request:\n\(userPrompt)")
        return sections.joined(separator: "\n\n")
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

    private static func turnErrorMessage(from turn: [String: Any]) -> String? {
        guard let error = CodexJSON.dictionary(turn["error"]) else { return nil }
        let message = CodexRPCErrorMessage.readableMessage(from: error["message"])
            ?? CodexRPCErrorMessage.readableMessage(from: error)
            ?? "Codex voice turn failed."
        let details = CodexRPCErrorMessage.readableMessage(from: error["additionalDetails"])
        if let details, !details.isEmpty, details != message {
            return "\(message)\n\(details)"
        }
        return message
    }

    private static func elapsedMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private static func truncated(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength))
    }
}
