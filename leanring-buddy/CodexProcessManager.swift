import Foundation

final class CodexProcessManager {
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

        if environment["OPENAI_API_KEY"]?.isEmpty != false,
           let userDefaultAPIKey = UserDefaults.standard.string(forKey: AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey),
           !userDefaultAPIKey.isEmpty {
            environment["OPENAI_API_KEY"] = userDefaultAPIKey
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
            if let id = CodexJSON.int(message["id"]) {
                let continuation = pending.removeValue(forKey: id)
                if let error = CodexJSON.dictionary(message["error"]) {
                    let text = CodexJSON.string(error["message"]) ?? "Codex app-server returned an error."
                    continuation?.resume(throwing: CodexRPCError(message: text))
                } else {
                    let result = CodexJSON.dictionary(message["result"]) ?? [:]
                    continuation?.resume(returning: result)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.onNotification?(message)
                }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onStderrLine?("Could not parse Codex RPC line: \(line)")
            }
        }
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
