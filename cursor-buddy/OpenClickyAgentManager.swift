import Combine
import Darwin
import Foundation
import OSLog

struct AgentConfig: Codable, Equatable {
    var provider: String?
    var providers: [String: ProviderEntry]?
    var agents: [String: AgentDefinition]?
    var telegram: ChannelConfig?
    var discord: ChannelConfig?

    struct ProviderEntry: Codable, Equatable {
        var apiKey: String?
        var baseUrl: String?
    }

    struct AgentDefinition: Codable, Equatable {
        var systemPrompt: String?
        var model: String?
        var tools: [String]?
    }

    struct ChannelConfig: Codable, Equatable {
        var token: String?
        var enabled: Bool?
    }
}

/// Manages the isolated openclicky-agent runtime (rebranded LightClaw).
/// - Runs as a separate binary / launchd service
/// - Communicates over Unix domain socket (ipc.sock)
/// - Completely separate config/data from any existing LightClaw install
@MainActor
final class OpenClickyAgentManager: ObservableObject {
    static let shared = OpenClickyAgentManager()

    private let logger = Logger(subsystem: "com.jkneen.openclicky", category: "AgentRuntime")
    nonisolated private static let streamReadIdleTimeout: TimeInterval = 90
    nonisolated private static let firstTokenTimeout: TimeInterval = 20

    // MARK: - Paths

    var agentBinaryName: String { "openclicky-agent" }

    var supportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenClicky/agent", isDirectory: true)
    }

    var ipcSocketPath: String {
        supportDirectory.appendingPathComponent("ipc.sock").path
    }

    var launchAgentPlistPath: URL {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return launchAgents.appendingPathComponent("com.jkneen.openclicky.agent.plist")
    }

    var configPath: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    // MARK: - Service Status

    enum ServiceStatus: Equatable {
        case notInstalled
        case stopped
        case running
        case error(String)
    }

    @Published var status: ServiceStatus = .notInstalled
    @Published private(set) var config: AgentConfig?

    /// True when the daemon socket exists AND the published status is running.
    /// Cheap to call — used by the agent session to decide whether to prefer
    /// the daemon over the bundled Codex path for a given turn.
    var isDaemonAvailable: Bool {
        Self.canConnectToDaemonSocket(path: ipcSocketPath)
    }

    // MARK: - Binary Location

    func locateBinary() -> URL? {
        // A persistent launch agent must never be installed from PATH or a
        // user-writable adjacent directory in a release build. The signed app
        // bundle is the only execution authority in production.
        if let bundled = Self.bundledBinaryURL(named: agentBinaryName) {
            return bundled
        }

        #if DEBUG
        guard Self.developmentBinaryOverridesEnabled else { return nil }

        // Local development is deliberately opt-in. Setting the environment
        // variable below is an explicit acknowledgement that the runtime will
        // execute an unbundled binary and persist it through launchd.
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let devBinary = appDir.appendingPathComponent("openclicky-agent")
        if FileManager.default.isExecutableFile(atPath: devBinary.path) {
            return devBinary
        }

        // PATH and ~/bin are available only to the explicit debug override.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("openclicky-agent")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        let homeBin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/openclicky-agent")
        if FileManager.default.isExecutableFile(atPath: homeBin.path) {
            return homeBin
        }
        #endif

        return nil
    }

    nonisolated private static func bundledBinaryURL(
        named name: String,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let binary = bundle.url(forResource: name, withExtension: nil),
              fileManager.isExecutableFile(atPath: binary.path),
              let resourceURL = bundle.resourceURL else {
            return nil
        }

        let resolvedBinary = binary.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedResources = resourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedBinary.path.hasPrefix(resolvedResources.path + "/") else {
            return nil
        }
        return resolvedBinary
    }

    #if DEBUG
    nonisolated private static var developmentBinaryOverridesEnabled: Bool {
        ProcessInfo.processInfo.environment["OPENCLICKY_ALLOW_UNTRUSTED_AGENT_RUNTIME"] == "1"
    }
    #endif

    nonisolated private static func isPermittedLaunchBinary(_ binaryURL: URL) -> Bool {
        let resolvedBinary = binaryURL.standardizedFileURL.resolvingSymlinksInPath()
        if let bundled = bundledBinaryURL(named: "openclicky-agent"), bundled == resolvedBinary {
            return true
        }

        #if DEBUG
        return developmentBinaryOverridesEnabled
            && FileManager.default.isExecutableFile(atPath: resolvedBinary.path)
        #else
        return false
        #endif
    }

    // MARK: - Service Management

    func installService() throws {
        guard let binary = locateBinary() else {
            throw NSError(domain: "OpenClickyAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "openclicky-agent binary not found"])
        }

        // Make sure provider keys from OpenClicky settings are in the daemon
        // config before the daemon process starts up.
        syncProvidersFromSettings()

        try Self.performInstall(
            binaryPath: binary.path,
            plistPath: launchAgentPlistPath.path,
            supportDir: supportDirectory
        )

        logger.info("Installed and loaded openclicky-agent service")
        status = .running
    }

    /// Synchronous worker used by both the @MainActor installService and the
    /// detached ensureRunning/restartService paths. Lives off the main actor so
    /// the launchctl `waitUntilExit()` and file writes never block the UI.
    nonisolated static func performInstall(binaryPath: String, plistPath: String, supportDir: URL) throws {
        let installLog = Logger(subsystem: "com.jkneen.openclicky", category: "AgentRuntime")
        let binaryURL = URL(fileURLWithPath: binaryPath, isDirectory: false)
        guard isPermittedLaunchBinary(binaryURL) else {
            throw NSError(
                domain: "OpenClickyAgent",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Refusing to install an untrusted openclicky-agent executable. Bundle the runtime with OpenClicky, or use the explicit debug-only development override."]
            )
        }
        installLog.info("performInstall: writing plist to \(plistPath, privacy: .public)")
        let plist: [String: Any] = [
            "Label": "com.jkneen.openclicky.agent",
            "ProgramArguments": [binaryURL.path, "run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": supportDir.appendingPathComponent("logs/agent.log").path,
            "StandardErrorPath": supportDir.appendingPathComponent("logs/agent.err").path,
            "EnvironmentVariables": [
                "OPENCLICKY_AGENT_DATA_DIR": supportDir.path
            ]
        ]

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        // A launchd job keeps the old ProgramArguments in memory after its
        // plist is overwritten. Unload it before writing so an explicit
        // install cannot accidentally preserve a stale executable.
        _ = try? runLaunchctlStatic(["bootout", "gui/\(getuid())/com.jkneen.openclicky.agent"])
        _ = try? runLaunchctlStatic(["unload", plistPath])
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportDir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try plistData.write(to: URL(fileURLWithPath: plistPath))
        installLog.info("performInstall: plist written, running launchctl load")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["load", plistPath]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        installLog.info("performInstall: launchctl load exit=\(process.terminationStatus, privacy: .public)")
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "OpenClickyAgent",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: errorText?.isEmpty == false
                        ? "launchctl load failed: \(errorText!)"
                        : "launchctl load failed with exit code \(process.terminationStatus)."
                ]
            )
        }
    }

    /// A pre-existing launchd plist is executable state. Verify it points to
    /// the binary selected for this run before kickstarting it; otherwise a
    /// previous PATH/dev selection can survive an app upgrade indefinitely.
    nonisolated private static func launchAgentPlistMatchesExpectedBinary(
        plistPath: String,
        binaryPath: String
    ) -> Bool {
        let plistURL = URL(fileURLWithPath: plistPath, isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = propertyList as? [String: Any],
              plist["Label"] as? String == "com.jkneen.openclicky.agent",
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.count == 2,
              arguments[1] == "run" else {
            return false
        }

        let expected = URL(fileURLWithPath: binaryPath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let configured = URL(fileURLWithPath: arguments[0], isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return configured == expected && isPermittedLaunchBinary(configured)
    }

    nonisolated private static func unloadAndRemoveLaunchAgent(plistPath: String) {
        _ = try? runLaunchctlStatic(["bootout", "gui/\(getuid())/com.jkneen.openclicky.agent"])
        _ = try? runLaunchctlStatic(["unload", plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    func uninstallService() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", launchAgentPlistPath.path]
        try? process.run()
        process.waitUntilExit()

        try? FileManager.default.removeItem(at: launchAgentPlistPath)
        status = .notInstalled
        logger.info("Uninstalled openclicky-agent service")
    }

    func refreshStatus() {
        // H14: previously this ran the launchctl subprocess + blocking socket
        // connect on the @MainActor (invoked from .onAppear), beachballing the
        // UI. The performInstall/ensureRunning paths already move launchctl
        // off-main; mirror that here.
        Task { @MainActor in
            let next = await Task.detached(priority: .userInitiated) { () -> ServiceStatus in
                if await Self.canConnectToDaemonSocket(path: self.ipcSocketPath) {
                    return .running
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["list", "com.jkneen.openclicky.agent"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if Self.launchctlOutputHasRunningPID(output) {
                        return .running
                    } else if output.localizedCaseInsensitiveContains("Could not find service")
                        || output.localizedCaseInsensitiveContains("Could not find domain")
                        || output.localizedCaseInsensitiveContains("service is not loaded") {
                        return .notInstalled
                    } else {
                        return .stopped
                    }
                } catch {
                    return .error(error.localizedDescription)
                }
            }.value
            self.status = next
        }
    }

    // MARK: - IPC Dispatch

    struct AgentRequest: Encodable {
        let type: String
        let payload: [String: String]

        private struct DynKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: DynKey.self)
            try c.encode(type, forKey: DynKey(stringValue: "type")!)
            for (k, v) in payload {
                try c.encode(v, forKey: DynKey(stringValue: k)!)
            }
        }
    }

    nonisolated struct AgentResponse: Codable, Sendable {
        let status: String
        let reply: String?
        let error: String?
    }

    func sendRequest(_ request: AgentRequest) async throws -> AgentResponse {
        let socketPath = ipcSocketPath
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw NSError(domain: "OpenClickyAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Agent IPC socket not found. Is the service running?"])
        }

        let input = try JSONEncoder().encode(request)
        var requestLine = String(data: input, encoding: .utf8)!
        requestLine.append("\n")

        // H14: the connect/write/read helpers below are synchronous with a
        // 90s idle timeout. Previously this ran inline on the @MainActor (no
        // suspension point), beachballing for up to 90s. Run them off-main in
        // a detached task, mirroring streamChatInternal.
        return try await Task.detached(priority: .userInitiated) { () -> AgentResponse in
            let handle = try Self.openConnectedSocketHandle(path: socketPath)
            defer { try? handle.close() }

            try handle.write(contentsOf: Data(requestLine.utf8))

            // Read one JSON line response.
            let responseData = try Self.readLineData(from: handle)
            return try JSONDecoder().decode(AgentResponse.self, from: responseData)
        }.value
    }

    // MARK: - Convenience

    func sendChat(_ message: String) async throws -> String {
        let req = AgentRequest(type: "chat", payload: ["content": message])
        let resp = try await sendRequest(req)
        return resp.reply ?? resp.error ?? "No response"
    }

    /// Streaming chat — yields tokens as they arrive from the daemon.
    /// Usage:
    /// for try await token in manager.streamChat("Hello") { ... }
    func streamChat(_ message: String) -> AsyncThrowingStream<String, Error> {
        let socketPath = ipcSocketPath
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try Self.streamChatInternal(message, socketPath: socketPath, continuation: continuation)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    nonisolated private static func streamChatInternal(
        _ message: String,
        socketPath: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw NSError(domain: "OpenClickyAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Agent IPC socket not found"])
        }

        let input = try JSONSerialization.data(withJSONObject: [
            "type": "chat",
            "content": message
        ])
        var requestLine = String(data: input, encoding: .utf8)!
        requestLine.append("\n")

        let handle = try Self.openConnectedSocketHandle(path: socketPath)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data(requestLine.utf8))

        // Read JSON lines until we see {"type":"done"}. This runs inside
        // a Task, so blocking socket reads do not block the main actor. Treat
        // silence or a closed socket before a terminal message as a daemon
        // failure so CodexAgentSession can fall back to bundled Codex instead
        // of leaving the request visually stuck in Running. Poll in short
        // intervals so user cancellation closes the socket promptly instead
        // of leaving a zombie daemon request behind.
        var buffer = Data()
        var receivedPayload = false
        var receivedAnyData = false
        var deadline = Date().addingTimeInterval(firstTokenTimeout)
        while true {
            try Task.checkCancellation()
            let chunk = try readChunk(from: handle, timeout: 1.0)
            guard let chunk else {
                if Date() < deadline { continue }
                let limit = receivedAnyData ? streamReadIdleTimeout : firstTokenTimeout
                throw NSError(
                    domain: "OpenClickyAgent",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "openclicky-agent did not produce a response within \(Int(limit)) seconds."]
                )
            }
            if chunk.isEmpty { break }
            receivedPayload = true
            if !receivedAnyData {
                receivedAnyData = true
            }
            // After we receive any data, switch to the longer idle deadline so
            // gaps between tokens during a long generation don't fail the turn.
            deadline = Date().addingTimeInterval(streamReadIdleTimeout)
            buffer.append(chunk)

            // Process complete lines
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if try handleStreamLine(lineData, continuation: continuation) {
                    return
                }
            }
        }

        if !buffer.isEmpty {
            if try handleStreamLine(buffer, continuation: continuation) {
                return
            }
        }

        if receivedPayload {
            throw NSError(domain: "OpenClickyAgent", code: 7, userInfo: [NSLocalizedDescriptionKey: "openclicky-agent closed the IPC stream before sending a completion marker."])
        }

        throw NSError(domain: "OpenClickyAgent", code: 8, userInfo: [NSLocalizedDescriptionKey: "openclicky-agent accepted the request but returned no response."])
    }

    nonisolated private static func handleStreamLine(
        _ lineData: Data,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws -> Bool {
        guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return false
        }

        if let type = json["type"] as? String {
            if type == "token", let content = json["content"] as? String {
                continuation.yield(content)
                return false
            }
            if type == "done" {
                continuation.finish()
                return true
            }
            if type == "error" {
                let message = json["error"] as? String ?? json["message"] as? String ?? "openclicky-agent stream failed"
                throw NSError(domain: "OpenClickyAgent", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        if let error = json["error"] as? String, !error.isEmpty {
            throw NSError(domain: "OpenClickyAgent", code: 4, userInfo: [NSLocalizedDescriptionKey: error])
        }

        if let reply = json["reply"] as? String {
            if !reply.isEmpty {
                continuation.yield(reply)
            }
            continuation.finish()
            return true
        }

        if let status = json["status"] as? String,
           status.lowercased() != "ok" && status.lowercased() != "success" {
            throw NSError(domain: "OpenClickyAgent", code: 4, userInfo: [NSLocalizedDescriptionKey: "openclicky-agent returned status: \(status)"])
        }

        return false
    }

    nonisolated private static func readChunk(from handle: FileHandle, timeout: TimeInterval) throws -> Data? {
        let fd = handle.fileDescriptor
        let timeoutMilliseconds = Int32(max(1, timeout * 1000))
        while true {
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
            if pollResult == 0 { return nil }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw posixSocketError("Could not read openclicky-agent IPC socket")
            }
            if pollDescriptor.revents & Int16(POLLIN) == 0,
               pollDescriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                return Data()
            }

            var bytes = [UInt8](repeating: 0, count: 4096)
            let readCount = Darwin.read(fd, &bytes, bytes.count)
            if readCount == 0 { return Data() }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw posixSocketError("Could not read openclicky-agent IPC socket")
            }
            return Data(bytes.prefix(readCount))
        }
    }

    nonisolated private static func openConnectedSocketHandle(path socketPath: String) throws -> FileHandle {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Self.posixSocketError("Could not create agent IPC socket")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(
                domain: "OpenClickyAgent",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Agent IPC socket path is too long: \(socketPath)"]
            )
        }

        _ = socketPath.withCString { pathPointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    strncpy(destination, pathPointer, maxPathLength)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            let error = Self.posixSocketError("Could not connect to openclicky-agent IPC socket")
            Darwin.close(fd)
            throw error
        }

        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    nonisolated private static func canConnectToDaemonSocket(path socketPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        do {
            let handle = try openConnectedSocketHandle(path: socketPath)
            try? handle.close()
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func launchctlOutputHasRunningPID(_ output: String) -> Bool {
        let pattern = #"\"PID\"\s*=\s*([0-9]+)\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range), match.numberOfRanges > 1 else {
            return false
        }
        guard let pidRange = Range(match.range(at: 1), in: output), let pid = Int(output[pidRange]) else {
            return false
        }
        return pid > 0
    }

    nonisolated private static func readLineData(from handle: FileHandle) throws -> Data {
        var buffer = Data()
        while true {
            let chunk = try readChunk(from: handle, timeout: streamReadIdleTimeout)
            guard let chunk else {
                throw NSError(
                    domain: "OpenClickyAgent",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "openclicky-agent did not produce a response within \(Int(streamReadIdleTimeout)) seconds."]
                )
            }
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return Data(buffer[..<newline])
            }
        }
        guard !buffer.isEmpty else {
            throw NSError(domain: "OpenClickyAgent", code: 8, userInfo: [NSLocalizedDescriptionKey: "openclicky-agent accepted the request but returned no response."])
        }
        return buffer
    }

    nonisolated private static func posixSocketError(_ prefix: String) -> NSError {
        let code = Int(errno)
        let message = String(cString: strerror(errno))
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: "\(prefix): \(message)"]
        )
    }

    func activateSkill(_ skillName: String) async throws -> String {
        let req = AgentRequest(type: "activate_skill", payload: ["name": skillName])
        let resp = try await sendRequest(req)
        return resp.reply ?? "Skill activated"
    }

    /// Starts the agent service if it is not already running.
    ///
    /// Performs all launchctl and socket-wait work on a detached task so the
    /// main actor stays responsive. `progress` is invoked on the main actor
    /// for each phase transition.
    func ensureRunning(progress: (@MainActor (String) -> Void)? = nil) async throws {
        logger.info("ensureRunning: begin (currentStatus=\(String(describing: self.status), privacy: .public))")
        syncProvidersFromSettings()
        refreshStatus()

        guard let binary = locateBinary() else {
            logger.error("ensureRunning: trusted bundled openclicky-agent binary not found")
            throw NSError(domain: "OpenClickyAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "OpenClicky needs a bundled openclicky-agent runtime. It will not install a runtime from PATH or a user-writable location."])
        }

        let binaryPath = binary.path
        let plistPath = launchAgentPlistPath.path
        let supportDir = supportDirectory
        let socketPath = ipcSocketPath
        let log = self.logger

        if case .running = status,
           FileManager.default.fileExists(atPath: socketPath),
           Self.launchAgentPlistMatchesExpectedBinary(plistPath: plistPath, binaryPath: binaryPath) {
            logger.info("ensureRunning: already running with the expected bundled runtime")
            return
        }

        logger.info("ensureRunning: binary=\(binaryPath, privacy: .public) plist=\(plistPath, privacy: .public) socket=\(socketPath, privacy: .public)")

        let report: @Sendable (String) -> Void = { message in
            Task { @MainActor in progress?(message) }
        }

        try await Task.detached(priority: .userInitiated) {
            log.info("ensureRunning.work: detached task started")
            report("Stopping conflicting interactive runtimes")
            Self.terminateAgentProcesses(modes: ["tui"])

            // Clean a stale unix-domain socket inode left behind by a previous
            // daemon. Tokio's UnixListener::bind() fails with EADDRINUSE if the
            // file already exists, which silently blocks the daemon from ever
            // listening even though launchctl reports it as loaded.
            Self.clearStaleSocket(at: socketPath)

            let plistMatchesExpectedBinary = Self.launchAgentPlistMatchesExpectedBinary(
                plistPath: plistPath,
                binaryPath: binaryPath
            )
            log.info("ensureRunning.work: plistMatchesExpectedBinary=\(plistMatchesExpectedBinary, privacy: .public)")

            if plistMatchesExpectedBinary {
                report("Kickstarting openclicky-agent via launchctl")
                let kickstart = (try? Self.runLaunchctlStatic(["kickstart", "-k", "gui/\(getuid())/com.jkneen.openclicky.agent"])) ?? -1
                let startCmd = (try? Self.runLaunchctlStatic(["start", "com.jkneen.openclicky.agent"])) ?? -1
                log.info("ensureRunning.work: launchctl kickstart=\(kickstart, privacy: .public) start=\(startCmd, privacy: .public)")
                if Self.waitForRunningSocketStatic(path: socketPath, timeout: 2.0) {
                    log.info("ensureRunning.work: socket live after kickstart")
                    return
                }
                log.warning("ensureRunning.work: socket not live after kickstart; falling through to install")
            }

            // Never let a stale plist retain an old/untrusted executable. Also
            // unload a matching but failed service before replacing its plist.
            Self.unloadAndRemoveLaunchAgent(plistPath: plistPath)

            report("Installing openclicky-agent launch service")
            do {
                try Self.performInstall(binaryPath: binaryPath, plistPath: plistPath, supportDir: supportDir)
                log.info("ensureRunning.work: performInstall succeeded")
            } catch {
                log.error("ensureRunning.work: performInstall failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }

            report("Waiting for openclicky-agent IPC socket")
            if Self.waitForRunningSocketStatic(path: socketPath, timeout: 5.0) {
                log.info("ensureRunning.work: socket live after install")
                return
            }

            log.error("ensureRunning.work: socket never came up after install")
            throw NSError(
                domain: "OpenClickyAgent",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "openclicky-agent service started but its IPC socket did not become available."]
            )
        }.value

        status = .running
        logger.info("ensureRunning: complete, status=running")
    }

    func restartService(reason: String) async {
        logger.warning("Restarting openclicky-agent service: \(reason, privacy: .public)")

        guard let binary = locateBinary() else {
            status = .error("openclicky-agent binary not found")
            return
        }

        let binaryPath = binary.path
        let plistPath = launchAgentPlistPath.path
        let supportDir = supportDirectory
        let socketPath = ipcSocketPath

        let result: ServiceStatus = await Task.detached(priority: .userInitiated) {
            // Rebuild the launchd definition from the freshly resolved,
            // permitted binary. Never bootstrap whatever a stale plist names.
            Self.unloadAndRemoveLaunchAgent(plistPath: plistPath)
            Self.terminateAgentProcesses(modes: ["run"])
            try? FileManager.default.removeItem(atPath: socketPath)

            do {
                try Self.performInstall(binaryPath: binaryPath, plistPath: plistPath, supportDir: supportDir)

                if Self.waitForRunningSocketStatic(path: socketPath, timeout: 5.0) {
                    return .running
                } else {
                    return .error("openclicky-agent restart did not expose its IPC socket.")
                }
            } catch {
                return .error(error.localizedDescription)
            }
        }.value

        status = result
    }

    /// Stops the agent service without removing its launchd plist. Used by the
    /// runtime view "Stop Service" button so the next prompt doesn't pay the
    /// full install cost.
    func stopService() async {
        let plistPath = launchAgentPlistPath.path
        let socketPath = ipcSocketPath

        await Task.detached(priority: .userInitiated) {
            _ = try? Self.runLaunchctlStatic(["bootout", "gui/\(getuid())/com.jkneen.openclicky.agent"])
            _ = try? Self.runLaunchctlStatic(["unload", plistPath])
            Self.terminateAgentProcesses(modes: ["run"])
            try? FileManager.default.removeItem(atPath: socketPath)
        }.value

        status = .stopped
        logger.info("Stopped openclicky-agent service (plist retained)")
    }

    private func terminateConflictingInteractiveRuntimes() {
        Self.terminateAgentProcesses(modes: ["tui"])
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) throws -> Int32 {
        try Self.runLaunchctlStatic(arguments)
    }

    /// Removes a stale unix-domain socket file at `path` if it exists and is
    /// not currently bound. Safe to call even when the file is absent.
    nonisolated static func clearStaleSocket(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if canConnectToDaemonSocket(path: path) { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    @discardableResult
    nonisolated static func runLaunchctlStatic(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    nonisolated private static func terminateAgentProcesses(modes: Set<String>) {
        for process in agentProcesses(modes: modes) {
            guard process.pid != getpid() else { continue }
            Darwin.kill(process.pid, SIGTERM)
        }
        Thread.sleep(forTimeInterval: 0.25)
        for process in agentProcesses(modes: modes) {
            guard process.pid != getpid() else { continue }
            if Darwin.kill(process.pid, 0) == 0 {
                Darwin.kill(process.pid, SIGKILL)
            }
        }
    }

    nonisolated private static func agentProcesses(modes: Set<String>) -> [(pid: pid_t, command: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.split(separator: "\n").compactMap { line -> (pid: pid_t, command: String)? in
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 2, let pid = pid_t(String(parts[0])) else { return nil }
                let command = String(parts[1])
                guard command.contains("openclicky-agent") else { return nil }
                guard modes.contains(where: { mode in
                    command.hasSuffix("openclicky-agent \(mode)")
                        || command.contains("/openclicky-agent \(mode)")
                        || command.contains(" openclicky-agent \(mode)")
                }) else { return nil }
                return (pid, command)
            }
        } catch {
            return []
        }
    }

    private func waitForRunningSocket(timeout: TimeInterval = 2.0) -> Bool {
        if Self.waitForRunningSocketStatic(path: ipcSocketPath, timeout: timeout) {
            status = .running
            return true
        }
        refreshStatus()
        return false
    }

    nonisolated static func waitForRunningSocketStatic(path socketPath: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if canConnectToDaemonSocket(path: socketPath) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    // MARK: - Config

    func loadConfig() {
        let url = configPath
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(AgentConfig.self, from: data)
            config = decoded
        } catch {
            logger.error("Failed to load agent config: \(error.localizedDescription)")
        }
    }

    // MARK: - Settings Sync

    /// Reads provider availability from OpenClicky's user settings and writes
    /// non-secret defaults into the daemon config. Secret provider keys are not
    /// copied into config.json unless the user has explicitly enabled the legacy
    /// plaintext sync escape hatch.
    @discardableResult
    func syncProvidersFromSettings() -> Bool {
        let anthropic = AppBundleConfiguration.anthropicAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let openai = AppBundleConfiguration.openAIAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Load existing config object so we preserve unrelated user fields.
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configPath.path),
           let data = try? Data(contentsOf: configPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        var changed = false

        func updateProviderSecret(_ provider: String, key: String?) {
            var entry = (root[provider] as? [String: Any]) ?? [:]
            if AppBundleConfiguration.agentPlaintextProviderSyncEnabled(), let key, !key.isEmpty {
                guard (entry["apiKey"] as? String) != key else { return }
                entry["apiKey"] = key
                root[provider] = entry
                changed = true
            } else if entry["apiKey"] != nil {
                entry.removeValue(forKey: "apiKey")
                root[provider] = entry
                changed = true
            }
        }

        updateProviderSecret("anthropic", key: anthropic)
        updateProviderSecret("openai", key: openai)

        // Pick a sensible default provider/model when none is configured yet.
        var agents = (root["agents"] as? [String: Any]) ?? [:]
        var defaults = (agents["defaults"] as? [String: Any]) ?? [:]
        let currentProvider = defaults["provider"] as? String
        let currentModel = defaults["model"] as? String

        let desiredProvider: String? = {
            if let a = anthropic, !a.isEmpty { return "anthropic" }
            if let o = openai, !o.isEmpty { return "openai" }
            return nil
        }()

        if currentProvider == nil, let desiredProvider {
            defaults["provider"] = desiredProvider
            changed = true
        }

        // Mirror OpenClicky's delegation model into the agent runtime so the
        // daemon uses the same model the rest of the app uses. Only set when
        // not already configured — never overwrite a user's manual choice.
        if currentModel == nil {
            let effectiveProvider = currentProvider ?? desiredProvider
            if effectiveProvider == "anthropic" {
                defaults["model"] = "anthropic/\(OpenClickyModelCatalog.defaultDelegationModelID)"
                changed = true
            }
        }

        if changed {
            agents["defaults"] = defaults
            root["agents"] = agents
        }

        guard changed else { return false }

        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configPath, options: [.atomic])
            logger.info("Synced provider keys into agent config at \(self.configPath.path)")
            loadConfig()
            return true
        } catch {
            logger.error("Failed to write agent config: \(error.localizedDescription)")
            return false
        }
    }
}
