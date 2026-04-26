import Foundation

nonisolated final class CodexProcessManager: @unchecked Sendable {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.codex-process")

    var onNotification: (([String: Any]) -> Void)?
    var onStderrLine: ((String) -> Void)?

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start(executableURL: URL, codexHome: URL) throws {
        if isRunning { return }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        environment["PATH"] = CodexRuntimeLocator.pathByPrependingBundledRuntimePaths(
            existingPath: environment["PATH"],
            runtimeExecutableURL: executableURL
        )

        let codexAuthFile = codexHome.appendingPathComponent("auth.json", isDirectory: false)
        let configFile = codexHome.appendingPathComponent("config.toml", isDirectory: false)
        let configText = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        let prefersChatGPTAuth = configText.contains("preferred_auth_method = \"chatgpt\"")
        if prefersChatGPTAuth, FileManager.default.fileExists(atPath: codexAuthFile.path) {
            environment.removeValue(forKey: "OPENAI_API_KEY")
        } else if environment["OPENAI_API_KEY"]?.isEmpty != false,
                  let configuredAPIKey = AppBundleConfiguration.openAIAPIKey(),
                  !configuredAPIKey.isEmpty {
            environment["OPENAI_API_KEY"] = configuredAPIKey
        }

        process.environment = environment
        process.terminationHandler = { [weak self] terminated in
            self?.failAllPendingRequests(message: "Codex app-server exited with status \(terminated.terminationStatus).")
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.stateQueue.async { [weak self] in
                self?.consumeStdout(data)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.stateQueue.async { [weak self] in
                self?.consumeStderr(data)
            }
        }

        try process.run()
    }

    @discardableResult
    func initialize(clientName: String = "open-clicky", title: String = "OpenClicky", version: String = "1.0.0") async throws -> [String: Any] {
        let response = try await sendRequest(request: Self.makeInitializeRequest(clientName: clientName, title: title, version: version))
        try sendNotification(method: "initialized")
        return response
    }

    static func makeInitializeRequest(clientName: String = "open-clicky", title: String = "OpenClicky", version: String = "1.0.0") -> CodexRPCRequest {
        CodexRPCRequest(id: 1, method: "initialize", params: [
            "clientInfo": [
                "name": clientName,
                "title": title,
                "version": version
            ],
            "capabilities": [
                "experimentalApi": true
            ]
        ])
    }

    func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await sendRequest(request: CodexRPCRequest(method: method, params: params))
    }

    func sendRequest(request: CodexRPCRequest) async throws -> [String: Any] {
        guard isRunning else {
            throw CodexRPCError(message: "Codex app-server is not running.")
        }

        let requestID = stateQueue.sync { () -> Int in
            let id = nextRequestID
            nextRequestID += 1
            return id
        }
        let requestWithID = CodexRPCRequest(id: requestID, method: request.method, params: request.params)
        let line = try requestWithID.encodedLine()
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "codex.rpc.request",
            fields: Self.summarizedRequestFieldsForLog(
                id: requestID,
                method: request.method,
                params: request.params as? [String: Any]
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [weak self] in
                guard let self else { return }
                self.pending[requestID] = continuation
                self.writeLine(line)
            }
        }
    }

    func sendNotification(method: String, params: [String: Any]? = nil) throws {
        guard isRunning else {
            throw CodexRPCError(message: "Codex app-server is not running.")
        }
        let request = CodexRPCRequest(id: nil, method: method, params: params)
        let line = try request.encodedLine()
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "codex.rpc.notification",
            fields: [
                "method": method,
                "params": params ?? [:]
            ]
        )
        stateQueue.async { [weak self] in
            self?.writeLine(line)
        }
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        inputPipe?.fileHandleForWriting.closeFile()
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        failAllPendingRequests(message: "Codex app-server stopped.")
    }

    deinit {
        stop()
    }

    private func writeLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        inputPipe?.fileHandleForWriting.write(data)
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        consumeLines(from: &stdoutBuffer) { [weak self] line in
            self?.handleStdoutLine(line)
        }
    }

    private func consumeStderr(_ data: Data) {
        stderrBuffer.append(data)
        consumeLines(from: &stderrBuffer) { [weak self] line in
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "codex.stderr",
                fields: [
                    "line": line
                ]
            )
            DispatchQueue.main.async {
                self?.onStderrLine?(line)
            }
        }
    }

    private func consumeLines(from buffer: inout Data, handler: (String) -> Void) {
        let newline = Data([0x0A])
        while let range = buffer.firstRange(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            handler(line)
        }
    }

    private func handleStdoutLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: "codex.rpc.message",
                fields: Self.summarizedMessageFieldsForLog(message)
            )
            if let id = CodexJSON.int(message["id"]) {
                let continuation = pending.removeValue(forKey: id)
                if let error = CodexJSON.dictionary(message["error"]) {
                    var text = CodexRPCErrorMessage.readableMessage(from: error["message"])
                        ?? "Codex app-server returned an error."
                    if let dataText = Self.readableErrorData(error["data"]),
                       !dataText.isEmpty,
                       dataText != text {
                        text += "\n\(dataText)"
                    }
                    continuation?.resume(throwing: CodexRPCError(message: text))
                } else {
                    let result = CodexJSON.dictionary(message["result"]) ?? [:]
                    continuation?.resume(returning: result)
                }
            } else {
                onNotification?(message)
            }
        } catch {
            onStderrLine?("Could not parse Codex RPC line: \(line)")
        }
    }

    private static func summarizedRequestFieldsForLog(id: Int, method: String, params: [String: Any]?) -> [String: Any] {
        var fields: [String: Any] = [
            "id": id,
            "method": method
        ]

        guard let params else { return fields }

        switch method {
        case "thread/start":
            fields["model"] = params["model"] ?? ""
            fields["cwd"] = params["cwd"] ?? ""
            fields["approvalPolicy"] = params["approvalPolicy"] ?? ""
            fields["sandbox"] = params["sandbox"] ?? ""
            fields["baseInstructionsLength"] = (params["baseInstructions"] as? String)?.count ?? 0
            fields["developerInstructionsLength"] = (params["developerInstructions"] as? String)?.count ?? 0
        case "turn/start":
            fields["threadId"] = params["threadId"] ?? ""
            fields["model"] = params["model"] ?? ""
            fields["cwd"] = params["cwd"] ?? ""
            fields["effort"] = params["effort"] ?? ""
            if let input = params["input"] as? [[String: Any]],
               let first = input.first,
               let text = first["text"] as? String {
                fields["inputTextLength"] = text.count
                fields["inputTextPreview"] = Self.shortLogSnippet(text, maxLength: 240)
            }
        default:
            fields["params"] = params
        }

        return fields
    }

    private static func summarizedMessageFieldsForLog(_ message: [String: Any]) -> [String: Any] {
        var fields: [String: Any] = [:]
        if let id = CodexJSON.int(message["id"]) {
            fields["id"] = id
        }
        if let method = CodexJSON.string(message["method"]) {
            fields["method"] = method
            let params = CodexJSON.dictionary(message["params"]) ?? [:]
            fields["paramsSummary"] = summarizedNotificationParamsForLog(method: method, params: params)
            return fields
        }
        if let error = CodexJSON.dictionary(message["error"]) {
            fields["error"] = CodexRPCErrorMessage.readableMessage(from: error["message"]) ?? "Codex RPC error"
        } else if let result = CodexJSON.dictionary(message["result"]) {
            fields["resultKeys"] = Array(result.keys).sorted()
        } else {
            fields["kind"] = "unknown"
        }
        return fields
    }

    private static func summarizedNotificationParamsForLog(method: String, params: [String: Any]) -> [String: Any] {
        var summary: [String: Any] = [:]
        if let itemID = CodexJSON.string(params["itemId"]) {
            summary["itemId"] = itemID
        }
        if let turnID = CodexJSON.string(params["turnId"]) {
            summary["turnId"] = turnID
        }
        if let delta = CodexJSON.string(params["delta"]) {
            summary["deltaLength"] = delta.count
        }
        if let text = CodexJSON.string(params["text"]) {
            summary["textLength"] = text.count
            summary["textPreview"] = Self.shortLogSnippet(text, maxLength: 180)
        }
        if let item = CodexJSON.dictionary(params["item"]) {
            summary["itemType"] = CodexJSON.string(item["type"]) ?? ""
            summary["itemId"] = CodexJSON.string(item["id"]) ?? summary["itemId"] ?? ""
            if let text = CodexJSON.string(item["text"]) {
                summary["itemTextLength"] = text.count
                summary["itemTextPreview"] = Self.shortLogSnippet(text, maxLength: 180)
            }
            if let command = CodexJSON.string(item["command"]) {
                summary["commandPreview"] = Self.shortLogSnippet(command, maxLength: 180)
            }
            if let output = CodexJSON.string(item["aggregatedOutput"]) {
                summary["aggregatedOutputLength"] = output.count
            }
        }
        if summary.isEmpty {
            summary["keys"] = Array(params.keys).sorted()
        }
        return summary
    }

    private static func shortLogSnippet(_ text: String, maxLength: Int) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > maxLength else { return flattened }
        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxLength)
        return "\(flattened[..<endIndex])..."
    }

    private static func readableErrorData(_ value: Any?) -> String? {
        guard let value else { return nil }

        if let message = CodexRPCErrorMessage.readableMessage(from: value) {
            return message
        }

        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return text
    }

    private func failAllPendingRequests(message: String) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let continuations = self.pending.values
            self.pending.removeAll()
            for continuation in continuations {
                continuation.resume(throwing: CodexRPCError(message: message))
            }
        }
    }
}
