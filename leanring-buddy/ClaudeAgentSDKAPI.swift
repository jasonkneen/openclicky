//
//  ClaudeAgentSDKAPI.swift
//  OpenClicky
//
//  Local Claude Agent SDK bridge. This keeps one Claude Agent SDK query session
//  warm and streams each voice turn through that session instead of spawning a
//  fresh Claude process for every response.
//

import Darwin
import Foundation

@MainActor
final class ClaudeAgentSDKAPI {
    private typealias ResponseContinuation = CheckedContinuation<(text: String, duration: TimeInterval), Error>

    private struct PendingRequest {
        let id: String
        let startedAt: Date
        let onTextChunk: @MainActor @Sendable (String) -> Void
        let continuation: ResponseContinuation
        var accumulatedText: String
        var didReceiveFirstDelta: Bool
    }

    private let executableURL: URL
    private let nodeExecutableURL: URL?
    private let bridgeScriptURL: URL?
    private let fileManager: FileManager
    private let workingDirectory: URL
    var model: String
    var maxOutputTokens: Int

    private static let persistentBridgeSystemPrompt = """
    You are OpenClicky's persistent local Claude Agent SDK voice response session.
    Keep the session warm and follow the current OpenClicky voice policy and context supplied with each user turn.
    """

    private var bridgeProcess: Process?
    private var bridgeInput: FileHandle?
    private var bridgeOutput: FileHandle?
    private var bridgeError: FileHandle?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var pendingRequests: [String: PendingRequest] = [:]
    private var warmupRequestID: String?
    private var activeBridgeModel: String?
    private var activeBridgeSystemPromptHash: Int?

    init?(
        model: String = OpenClickyModelCatalog.defaultVoiceResponseModelID,
        maxOutputTokens: Int = 64_000,
        fileManager: FileManager = .default,
        workingDirectory: URL? = nil
    ) {
        guard let executableURL = Self.findExecutable(fileManager: fileManager) else {
            return nil
        }

        self.executableURL = executableURL
        self.nodeExecutableURL = Self.findNodeExecutable(fileManager: fileManager)
        self.bridgeScriptURL = Self.findBridgeScript(fileManager: fileManager)
        self.fileManager = fileManager
        self.workingDirectory = workingDirectory ?? fileManager.homeDirectoryForCurrentUser
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    deinit {
        bridgeProcess?.terminationHandler = nil
        bridgeOutput?.readabilityHandler = nil
        bridgeError?.readabilityHandler = nil
        try? bridgeInput?.close()
        terminateBridgeProcess(bridgeProcess)
    }

    static func findExecutable(fileManager: FileManager = .default) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let explicitPath = environment["OPENCLICKY_CLAUDE_EXECUTABLE"],
           let executable = executableURL(atPath: explicitPath, fileManager: fileManager) {
            return executable
        }

        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude", isDirectory: false) }

        let fixedCandidates = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude", isDirectory: false),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude", isDirectory: false),
            URL(fileURLWithPath: "/usr/local/bin/claude", isDirectory: false)
        ]

        return (pathCandidates + fixedCandidates).first { candidate in
            fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    static func findNodeExecutable(fileManager: FileManager = .default) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let explicitPath = environment["OPENCLICKY_NODE_EXECUTABLE"],
           let executable = executableURL(atPath: explicitPath, fileManager: fileManager) {
            return executable
        }

        var candidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node", isDirectory: false) }

        let home = fileManager.homeDirectoryForCurrentUser
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/node", isDirectory: false),
            URL(fileURLWithPath: "/usr/local/bin/node", isDirectory: false),
            URL(fileURLWithPath: "/usr/bin/node", isDirectory: false)
        ])

        let nvmRoot = home
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
                .map { $0.appendingPathComponent("bin/node", isDirectory: false) })
        }

        return candidates.first { candidate in
            fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    func warmUp(systemPrompt: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sendRequest(
                    kind: "warmup",
                    images: [],
                    systemPrompt: systemPrompt,
                    conversationHistory: [],
                    userPrompt: "get ready. prime the OpenClicky voice response session and reply with ready only.",
                    onTextChunk: { _ in }
                )
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "error",
                    event: "claude_agent_sdk.warmup.failed",
                    fields: [
                        "executor": "voice_response",
                        "executionMethod": "ClaudeAgentSDKAPI.query",
                        "transport": "agent_sdk_query",
                        "streamingMethod": "claude_agent_sdk_query",
                        "error": error.localizedDescription
                    ]
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
        try await sendRequest(
            kind: "request",
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
    }

    func stop() {
        let process = bridgeProcess
        bridgeProcess = nil
        process?.terminationHandler = nil
        bridgeOutput?.readabilityHandler = nil
        bridgeError?.readabilityHandler = nil
        try? bridgeInput?.close()
        bridgeInput = nil
        bridgeOutput = nil
        bridgeError = nil
        activeBridgeModel = nil
        activeBridgeSystemPromptHash = nil
        terminateBridgeProcess(process)
        failPendingRequests(
            NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Claude Agent SDK bridge stopped."]
            )
        )
    }

    private func sendRequest(
        kind: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        try ensureBridge()

        let requestID = UUID().uuidString
        let attachments = images.map { image -> [String: Any] in
            [
                "label": image.label,
                "mediaType": image.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg",
                "data": image.data.base64EncodedString()
            ]
        }
        let history = conversationHistory.map { entry -> [String: Any] in
            [
                "user": entry.userPlaceholder,
                "assistant": entry.assistantResponse
            ]
        }
        let payload: [String: Any] = [
            "type": kind,
            "id": requestID,
            "systemPrompt": systemPrompt,
            "prompt": userPrompt,
            "conversationHistory": history,
            "images": attachments
        ]

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "outgoing",
            event: kind == "warmup" ? "claude_agent_sdk.warmup.request" : "claude_agent_sdk.query.request",
            fields: [
                "executor": "voice_response",
                "executionMethod": "ClaudeAgentSDKAPI.query",
                "transport": "agent_sdk_query",
                "streamingMethod": "claude_agent_sdk_query",
                "model": model,
                "maxTokens": maxOutputTokens,
                "requestID": requestID,
                "imageCount": images.count,
                "promptLength": userPrompt.count
            ]
        )

        // No per-request timeout. The Agent SDK needs as long as it
        // needs — cold-start (Node + claude CLI spin-up + model warm)
        // can run 10-30s on a fresh bridge, and we don't want HTTP
        // hijacking the response just because the SDK is slow. If the
        // bridge process dies, `handleBridgeTermination` fails pending
        // requests; if the user truly wants to abandon, they can press
        // push-to-talk again to interrupt.
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = PendingRequest(
                id: requestID,
                startedAt: Date(),
                onTextChunk: onTextChunk,
                continuation: continuation,
                accumulatedText: "",
                didReceiveFirstDelta: false
            )
            if kind == "warmup" {
                warmupRequestID = requestID
            }
            do {
                try writeBridgeCommand(payload)
            } catch {
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
                return
            }
        }
    }

    private func ensureBridge() throws {
        let promptHash = Self.persistentBridgeSystemPrompt.hashValue
        if let bridgeProcess,
           bridgeProcess.isRunning,
           activeBridgeModel == model,
           activeBridgeSystemPromptHash == promptHash,
           bridgeInput != nil {
            return
        }

        stop()

        guard let nodeExecutableURL else {
            throw NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "Node.js is required for the Claude Agent SDK bridge but was not found."]
            )
        }

        guard let bridgeScriptURL else {
            throw NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "OpenClicky could not find ClaudeAgentSDKBridge/bridge.mjs."]
            )
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = nodeExecutableURL
        process.arguments = [bridgeScriptURL.path]
        process.currentDirectoryURL = workingDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = bridgeEnvironment(
            nodeExecutableURL: nodeExecutableURL,
            bridgeScriptURL: bridgeScriptURL,
            systemPrompt: Self.persistentBridgeSystemPrompt
        )

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.consumeStdout(text)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.consumeStderr(text)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.handleBridgeTermination(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        bridgeProcess = process
        bridgeInput = inputPipe.fileHandleForWriting
        bridgeOutput = outputPipe.fileHandleForReading
        bridgeError = errorPipe.fileHandleForReading
        activeBridgeModel = model
        activeBridgeSystemPromptHash = promptHash

        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "outgoing",
            event: "claude_agent_sdk.bridge.started",
            fields: [
                "executor": "voice_response",
                "executionMethod": "ClaudeAgentSDKAPI.query",
                "transport": "agent_sdk_query",
                "streamingMethod": "claude_agent_sdk_query",
                "model": model,
                "maxTokens": maxOutputTokens,
                "node": nodeExecutableURL.path,
                "bridge": bridgeScriptURL.path,
                "claudeExecutable": executableURL.path
            ]
        )
    }

    private func bridgeEnvironment(
        nodeExecutableURL: URL,
        bridgeScriptURL: URL,
        systemPrompt: String
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let nodeDirectory = nodeExecutableURL.deletingLastPathComponent().path
        let existingPath = environment["PATH"] ?? ""
        let baselinePath = "/Users/jkneen/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [nodeDirectory, existingPath, baselinePath]
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        environment["OPENCLICKY_CLAUDE_EXECUTABLE"] = executableURL.path
        environment["OPENCLICKY_CLAUDE_MODEL"] = model
        environment["OPENCLICKY_CLAUDE_MAX_OUTPUT_TOKENS"] = String(maxOutputTokens)
        environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(maxOutputTokens)
        environment["OPENCLICKY_CLAUDE_CWD"] = workingDirectory.path
        environment["OPENCLICKY_CLAUDE_SYSTEM_PROMPT"] = systemPrompt
        environment["OPENCLICKY_CLAUDE_AGENT_SDK_PATHS"] = Self.nodeModuleSearchPaths(
            bridgeScriptURL: bridgeScriptURL,
            fileManager: fileManager
        ).joined(separator: ":")
        environment["CLAUDE_AGENT_SDK_CLIENT_APP"] = "openclicky/1.0"
        return environment
    }

    private static func nodeModuleSearchPaths(bridgeScriptURL: URL, fileManager: FileManager) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser
        var paths = [
            bridgeScriptURL.deletingLastPathComponent().path,
            home.appendingPathComponent(".nvm/versions/node", isDirectory: true).path,
            "/opt/homebrew/lib/node_modules",
            "/usr/local/lib/node_modules"
        ]

        let nvmRoot = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            paths.append(contentsOf: versions.map {
                $0.appendingPathComponent("lib/node_modules", isDirectory: true).path
            })
        }

        return Array(Set(paths)).sorted()
    }

    private func writeBridgeCommand(_ command: [String: Any]) throws {
        guard let bridgeInput else {
            throw NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -22,
                userInfo: [NSLocalizedDescriptionKey: "Claude Agent SDK bridge input is not available."]
            )
        }

        let data = try JSONSerialization.data(withJSONObject: command)
        bridgeInput.write(data)
        bridgeInput.write(Data("\n".utf8))
    }

    private func consumeStdout(_ text: String) {
        stdoutBuffer += text
        let lines = stdoutBuffer.components(separatedBy: "\n")
        stdoutBuffer = lines.last ?? ""
        for line in lines.dropLast() {
            handleBridgeLine(line)
        }
    }

    private func consumeStderr(_ text: String) {
        stderrBuffer += text
        let lines = stderrBuffer.components(separatedBy: "\n")
        stderrBuffer = lines.last ?? ""
        for line in lines.dropLast() where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "incoming",
                event: "claude_agent_sdk.bridge.stderr",
                fields: [
                    "executor": "voice_response",
                    "executionMethod": "ClaudeAgentSDKAPI.query",
                    "message": Self.truncated(line, maxLength: 1_000)
                ]
            )
        }
    }

    private func handleBridgeLine(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            return
        }

        let requestID = event["id"] as? String
        switch type {
        case "ready":
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "incoming",
                event: "claude_agent_sdk.bridge.ready",
                fields: [
                    "executor": "voice_response",
                    "executionMethod": "ClaudeAgentSDKAPI.query",
                    "transport": "agent_sdk_query",
                    "streamingMethod": "claude_agent_sdk_query",
                    "sdkPath": event["sdkPath"] as? String ?? "unknown"
                ]
            )

        case "started":
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "incoming",
                event: "claude_agent_sdk.query.started",
                fields: [
                    "executor": "voice_response",
                    "executionMethod": "ClaudeAgentSDKAPI.query",
                    "transport": "agent_sdk_query",
                    "streamingMethod": "claude_agent_sdk_query",
                    "requestID": requestID ?? "none"
                ]
            )

        case "delta":
            guard let requestID,
                  var pending = pendingRequests[requestID],
                  let text = event["text"] as? String else { return }
            pending.accumulatedText = text
            if !pending.didReceiveFirstDelta {
                pending.didReceiveFirstDelta = true
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "incoming",
                    event: "claude_agent_sdk.query.first_text_delta",
                    fields: [
                        "executor": "voice_response",
                        "executionMethod": "ClaudeAgentSDKAPI.query",
                        "transport": "agent_sdk_query",
                        "streamingMethod": "claude_agent_sdk_query",
                        "requestID": requestID,
                        "firstTokenLatencyMs": Self.elapsedMilliseconds(from: pending.startedAt, to: Date())
                    ]
                )
            }
            pendingRequests[requestID] = pending
            pending.onTextChunk(text)

        case "result":
            guard let requestID,
                  let pending = pendingRequests.removeValue(forKey: requestID) else { return }
            let text = (event["text"] as? String) ?? pending.accumulatedText
            let duration = Date().timeIntervalSince(pending.startedAt)
            let logEvent = requestID == warmupRequestID ? "claude_agent_sdk.warmup.ready" : "claude_agent_sdk.query.response"
            if requestID == warmupRequestID {
                warmupRequestID = nil
            }
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "incoming",
                event: logEvent,
                fields: [
                    "executor": "voice_response",
                    "executionMethod": "ClaudeAgentSDKAPI.query",
                    "transport": "agent_sdk_query",
                    "streamingMethod": "claude_agent_sdk_query",
                    "requestID": requestID,
                    "responseLength": text.count,
                    "durationMs": Int((duration * 1000).rounded())
                ]
            )
            pending.continuation.resume(returning: (text: text, duration: duration))

        case "error":
            let message = (event["message"] as? String) ?? "Claude Agent SDK bridge error."
            let error = NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            if let requestID,
               let pending = pendingRequests.removeValue(forKey: requestID) {
                pending.continuation.resume(throwing: error)
            } else {
                failPendingRequests(error)
            }
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "error",
                event: "claude_agent_sdk.query.error",
                fields: [
                    "executor": "voice_response",
                    "executionMethod": "ClaudeAgentSDKAPI.query",
                    "transport": "agent_sdk_query",
                    "streamingMethod": "claude_agent_sdk_query",
                    "requestID": requestID ?? "none",
                    "error": message
                ]
            )

        default:
            break
        }
    }

    private func handleBridgeTermination(status: Int32) {
        bridgeOutput?.readabilityHandler = nil
        bridgeError?.readabilityHandler = nil
        bridgeProcess = nil
        bridgeInput = nil
        bridgeOutput = nil
        bridgeError = nil
        activeBridgeModel = nil
        activeBridgeSystemPromptHash = nil

        let error = NSError(
            domain: "ClaudeAgentSDKAPI",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Claude Agent SDK bridge exited with status \(status)."]
        )
        failPendingRequests(error)
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: status == 0 ? "incoming" : "error",
            event: "claude_agent_sdk.bridge.exited",
            fields: [
                "executor": "voice_response",
                "executionMethod": "ClaudeAgentSDKAPI.query",
                "status": status
            ]
        )
    }

    private func failRequestIfPending(requestID: String, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        if requestID == warmupRequestID { warmupRequestID = nil }
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "error",
            event: "claude_agent_sdk.query.timeout",
            fields: [
                "executor": "voice_response",
                "executionMethod": "ClaudeAgentSDKAPI.query",
                "transport": "agent_sdk_query",
                "streamingMethod": "claude_agent_sdk_query",
                "requestID": requestID,
                "error": error.localizedDescription
            ]
        )
        print("⚠️ ClaudeAgentSDKAPI: request \(requestID) timed out — \(error.localizedDescription)")
        pending.continuation.resume(throwing: error)
        // Bridge is hung — tear it down so the next call rebuilds it fresh.
        stop()
    }

    private func failPendingRequests(_ error: Error) {
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        warmupRequestID = nil
        for request in requests {
            request.continuation.resume(throwing: error)
        }
    }

    nonisolated private func terminateBridgeProcess(_ process: Process?) {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            guard process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    private static func executableURL(atPath path: String, fileManager: FileManager) -> URL? {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard fileManager.isExecutableFile(atPath: expandedPath) else { return nil }
        return URL(fileURLWithPath: expandedPath, isDirectory: false)
    }

    private static func findBridgeScript(fileManager: FileManager = .default) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []

        func appendBridgeCandidate(_ url: URL) {
            if url.lastPathComponent == "bridge.mjs" {
                candidates.append(url)
            } else {
                candidates.append(url.appendingPathComponent("bridge.mjs", isDirectory: false))
            }
        }

        for key in ["OPENCLICKY_CLAUDE_AGENT_BRIDGE", "OPENCLICKY_CLAUDE_AGENT_SDK_BRIDGE"] {
            guard let rawPath = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawPath.isEmpty else {
                continue
            }
            appendBridgeCandidate(URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath, isDirectory: false))
        }

        if let bundled = Bundle.main.url(forResource: "ClaudeAgentSDKBridge", withExtension: nil) {
            appendBridgeCandidate(bundled)
        }

        if let resourcesDirectory = Bundle.main.resourceURL {
            appendBridgeCandidate(resourcesDirectory.appendingPathComponent("ClaudeAgentSDKBridge", isDirectory: true))
        }

        if let sourceResources = CodexRuntimeLocator.sourceAppResourcesDirectory(fileManager: fileManager) {
            appendBridgeCandidate(sourceResources.appendingPathComponent("ClaudeAgentSDKBridge", isDirectory: true))
        }

        appendBridgeCandidate(URL(
            fileURLWithPath: "\(fileManager.homeDirectoryForCurrentUser.path)/Documents/GitHub/openclicky/AppResources/OpenClicky/ClaudeAgentSDKBridge",
            isDirectory: true
        ))

        var currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            appendBridgeCandidate(
                currentDirectory
                    .appendingPathComponent("AppResources", isDirectory: true)
                    .appendingPathComponent("OpenClicky", isDirectory: true)
                    .appendingPathComponent("ClaudeAgentSDKBridge", isDirectory: true)
            )
            let parent = currentDirectory.deletingLastPathComponent()
            guard parent.path != currentDirectory.path else { break }
            currentDirectory = parent
        }

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private static func elapsedMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private static func truncated(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength))
    }
}
