import AppKit
import Foundation
import Network

/// Keep the loopback bridge bounded before authentication and JSON decoding.
/// The bridge may proxy multimodal inference payloads, so this retains the
/// previous ten-megabyte total-request ceiling while rejecting oversized or
/// malformed requests before any integer/range arithmetic occurs.
private let openClickyExternalControlMaximumHeaderBytes = 32 * 1024
private let openClickyExternalControlMaximumBodyBytes = 10 * 1024 * 1024

/// Local-only bridge used by other apps/agents to display OpenClicky UI affordances
/// without entering the normal voice/conversation/agent state machine.
struct OpenClickyExternalCursorSpec {
    var point: CGPoint
    var caption: String?
    var duration: TimeInterval
    var accentHex: String?
}

enum OpenClickyExternalCursorMode: String {
    case primary
    case secondary
}

enum OpenClickyExternalControlCommand {
    case showCursor(point: CGPoint, caption: String?, duration: TimeInterval, accentHex: String?, mode: OpenClickyExternalCursorMode, travelDuration: TimeInterval)
    case showCursors([OpenClickyExternalCursorSpec])
    case showVisualGuidanceOverlay(OpenClickyVisualGuidanceOverlay)
    case showCaption(text: String, point: CGPoint?, duration: TimeInterval, accentHex: String?)
    case captureScreenshot(focused: Bool)
    case click(point: CGPoint, caption: String?)
    case clear
    case speak(text: String, interrupt: Bool)
    case notify(title: String, body: String, threadID: String?, sound: Bool)
    /// Structured non-success result for gated/stub tools (e.g. Gmail OAuth).
    /// Prefer this over returning `nil` so agents get an explicit capability error.
    case unavailable(statusCode: Int, body: [String: Any])
}

struct OpenClickyExternalControlResponse {
    var statusCode: Int
    var body: [String: Any]

    static func ok(_ body: [String: Any] = [:]) -> OpenClickyExternalControlResponse {
        OpenClickyExternalControlResponse(statusCode: 200, body: ["ok": true].merging(body) { _, new in new })
    }

    static func accepted(_ body: [String: Any] = [:]) -> OpenClickyExternalControlResponse {
        OpenClickyExternalControlResponse(statusCode: 202, body: ["ok": true, "accepted": true].merging(body) { _, new in new })
    }

    static func error(_ statusCode: Int, _ message: String) -> OpenClickyExternalControlResponse {
        OpenClickyExternalControlResponse(statusCode: statusCode, body: ["ok": false, "error": message])
    }

    static func unavailable(
        statusCode: Int = 501,
        tool: String,
        capability: String,
        message: String,
        extra: [String: Any] = [:]
    ) -> OpenClickyExternalControlResponse {
        var body: [String: Any] = [
            "ok": false,
            "error": message,
            "tool": tool,
            "capability": capability,
            "status": "gated",
            "implementation": "stub"
        ]
        for (key, value) in extra {
            body[key] = value
        }
        return OpenClickyExternalControlResponse(statusCode: statusCode, body: body)
    }

}

typealias OpenClickyExternalControlHandler = @MainActor (OpenClickyExternalControlCommand) async -> OpenClickyExternalControlResponse

final class OpenClickyExternalControlBridgeServer: @unchecked Sendable {
    private let port: UInt16
    private let handler: OpenClickyExternalControlHandler
    private let queue = DispatchQueue(label: "com.jkneen.openclicky.external-control-bridge")
    private var listener: NWListener?
    private var sseConnections: [UUID: NWConnection] = [:]
    private let proxySession: URLSession

    init(port: UInt16 = 32123, handler: @escaping OpenClickyExternalControlHandler) {
        self.port = port
        self.handler = handler

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.proxySession = URLSession(configuration: config)
    }

    func start() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if let address = IPv4Address("127.0.0.1"),
               let endpointPort = NWEndpoint.Port(rawValue: port) {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: endpointPort)
            }

            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("OpenClicky external control bridge listening on http://127.0.0.1:\(self.port)")
                case .failed(let error):
                    print("OpenClicky external control bridge failed: \(error)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("OpenClicky external control bridge could not start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, connection) in sseConnections {
            connection.cancel()
        }
        sseConnections.removeAll()
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .cancelled = state {
                self.removeSSEConnection(connection)
            }
            if case .failed = state {
                self.removeSSEConnection(connection)
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.sendJSON(["ok": false, "error": error.localizedDescription], statusCode: 400, on: connection)
                return
            }

            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }

            switch HTTPRequest.parse(nextBuffer) {
            case .request(let request):
                self.handle(request, on: connection)
                return
            case .malformed(let reason):
                self.sendJSON(["ok": false, "error": reason], statusCode: 400, on: connection)
                return
            case .incomplete:
                break
            }

            if isComplete || nextBuffer.count > openClickyExternalControlMaximumHeaderBytes + openClickyExternalControlMaximumBodyBytes {
                self.sendJSON(["ok": false, "error": "Malformed HTTP request"], statusCode: 400, on: connection)
                return
            }

            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        if request.method == "OPTIONS" {
            sendJSON(["ok": true], statusCode: 200, on: connection)
            return
        }

        if request.method == "GET", request.path == "/health" || request.path == "/" {
            var body: [String: Any] = [
                "ok": true,
                "name": "OpenClicky External Control Bridge",
                "port": port,
                "transport": "local-http+sse",
                "bridgeTokenRequired": true,
                "bridgeTokenConfigured": AppBundleConfiguration.externalControlBridgeToken() != nil,
                "tools": Self.mcpToolDescriptors.compactMap { $0["name"] as? String },
                "capabilities": Self.capabilityCompatibilityMetadata,
                "multiToolEndpoints": ["/mcp/calls", "/tools/calls"],
                "inferenceProxyEnabled": AppBundleConfiguration.externalInferenceProxyEnabled()
            ]
            if AppBundleConfiguration.externalInferenceProxyEnabled() {
                body["proxyEndpoints"] = ["/v1/messages", "/v1/responses", "/v1/chat/completions"]
            }
            sendJSON(body, statusCode: 200, on: connection)
            return
        }

        guard hasValidBridgeToken(request) else {
            sendJSON([
                "ok": false,
                "error": "OpenClicky bridge token required. Configure OPENCLICKY_BRIDGE_TOKEN or the bridge token setting."
            ], statusCode: 401, on: connection)
            return
        }

        if request.method == "GET", request.path == "/mcp/tools" {
            sendJSON(["ok": true, "tools": Self.mcpToolDescriptors], statusCode: 200, on: connection)
            return
        }

        if request.method == "GET", request.path == "/events" {
            attachSSE(connection)
            return
        }

        if isInferenceProxyEndpoint(request.path) {
            guard AppBundleConfiguration.externalInferenceProxyEnabled() else {
                sendJSON(["ok": false, "error": "Inference proxy is disabled."], statusCode: 404, on: connection)
                return
            }
            guard hasValidBridgeToken(request) else {
                sendJSON(["ok": false, "error": "Inference proxy requires a valid OpenClicky bridge token."], statusCode: 401, on: connection)
                return
            }
            proxyInferenceRequest(request, on: connection)
            return
        }

        guard request.method == "POST" else {
            sendJSON(["ok": false, "error": "Use POST for control commands"], statusCode: 405, on: connection)
            return
        }

        let command: OpenClickyExternalControlCommand?
        switch request.path {
        case "/cursor":
            command = Self.cursorCommand(from: request.jsonBody)
        case "/cursors":
            command = Self.cursorsCommand(from: request.jsonBody)
        case "/scribble":
            command = Self.scribbleCommand(from: request.jsonBody)
        case "/highlight", "/rectangle":
            command = Self.rectangleCommand(from: request.jsonBody)
        case "/caption":
            command = Self.captionCommand(from: request.jsonBody)
        case "/screenshot", "/screenshots":
            command = .captureScreenshot(focused: Self.bool(request.jsonBody["focused"]) ?? false)
        case "/click":
            command = Self.clickCommand(from: request.jsonBody)
        case "/clear":
            command = .clear
        case "/speak":
            command = Self.speakCommand(from: request.jsonBody)
        case "/notify", "/notification":
            command = Self.notifyCommand(from: request.jsonBody)
        case "/mcp/call", "/tools/call":
            command = Self.mcpToolCommand(from: request.jsonBody)
        case "/mcp/calls", "/tools/calls":
            handleBatchToolCall(request, on: connection)
            return
        case "/mcp":
            if let response = Self.mcpJSONRPCResponse(from: request.jsonBody) {
                if let command = response.command {
                    Task { @MainActor in
                        let result = await self.handler(command)
                        self.queue.async {
                            self.broadcast(event: "command", object: ["ok": result.statusCode < 400, "path": request.path])
                            self.sendJSON(response.responseBody(result: result), statusCode: result.statusCode, on: connection)
                        }
                    }
                    return
                }
                sendJSON(response.responseBody(result: nil), statusCode: 200, on: connection)
                return
            }
            command = nil
        default:
            sendJSON(["ok": false, "error": "Unknown endpoint"], statusCode: 404, on: connection)
            return
        }

        guard let command else {
            sendJSON(["ok": false, "error": "Invalid command payload"], statusCode: 400, on: connection)
            return
        }

        Task { @MainActor in
            let response = await self.handler(command)
            self.queue.async {
                self.broadcast(event: "command", object: ["ok": response.statusCode < 400, "path": request.path])
                self.sendJSON(response.body, statusCode: response.statusCode, on: connection)
            }
        }
    }

    private func handleBatchToolCall(_ request: HTTPRequest, on connection: NWConnection) {
        guard let calls = Self.array(request.jsonBody["calls"] ?? request.jsonBody["tool_calls"] ?? request.jsonBody["tools"]) else {
            sendJSON(["ok": false, "error": "Expected calls array"], statusCode: 400, on: connection)
            return
        }

        let parsedCalls = calls.enumerated().compactMap { index, value -> (index: Int, name: String, command: OpenClickyExternalControlCommand, delay: TimeInterval)? in
            guard let call = Self.dictionary(value) else { return nil }
            let name = Self.string(call["tool"]) ?? Self.string(call["name"]) ?? "unknown"
            guard let command = Self.mcpToolCommand(from: call) else { return nil }
            let delayMilliseconds = Self.double(call["delayMs"]) ?? Self.double(call["waitMs"]) ?? 0
            let delay = max(0, min(delayMilliseconds / 1000.0, 10.0))
            return (index, name, command, delay)
        }

        guard parsedCalls.count == calls.count else {
            sendJSON(["ok": false, "error": "Every batch call must include a valid tool/name and arguments"], statusCode: 400, on: connection)
            return
        }

        Task { @MainActor in
            var results: [[String: Any]] = []
            var allSucceeded = true
            for parsed in parsedCalls {
                if parsed.delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(parsed.delay * 1_000_000_000))
                }
                let result = await self.handler(parsed.command)
                allSucceeded = allSucceeded && result.statusCode < 400
                results.append([
                    "index": parsed.index,
                    "tool": parsed.name,
                    "ok": result.statusCode < 400,
                    "statusCode": result.statusCode,
                    "body": result.body
                ])
            }
            self.queue.async {
                self.broadcast(event: "command", object: ["ok": allSucceeded, "path": request.path, "count": parsedCalls.count])
                self.sendJSON(["ok": allSucceeded, "results": results], statusCode: allSucceeded ? 200 : 207, on: connection)
            }
        }
    }


    private func isInferenceProxyEndpoint(_ path: String) -> Bool {
        path == "/v1/responses" || path == "/v1/chat/completions" || path == "/v1/messages"
    }

    private func hasValidBridgeToken(_ request: HTTPRequest) -> Bool {
        guard let configuredToken = AppBundleConfiguration.externalControlBridgeToken(),
              !configuredToken.isEmpty else { return false }
        if Self.constantTimeEquals(request.headers["x-openclicky-token"], configuredToken) {
            return true
        }
        if Self.constantTimeEquals(request.headers["authorization"], "Bearer \(configuredToken)") {
            return true
        }
        return false
    }

    private static func constantTimeEquals(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs,
              let lhsData = lhs.data(using: .utf8),
              let rhsData = rhs.data(using: .utf8),
              lhsData.count == rhsData.count else { return false }

        var difference: UInt8 = 0
        for (left, right) in zip(lhsData, rhsData) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private func proxyInferenceRequest(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.method == "POST" else {
            sendJSON(["ok": false, "error": "Use POST for inference proxy endpoints"], statusCode: 405, on: connection)
            return
        }

        guard let proxyRequest = makeInferenceProxyURLRequest(from: request) else {
            let provider = request.path == "/v1/messages" ? "Anthropic" : "OpenAI"
            sendJSON(["ok": false, "error": "OpenClicky \(provider) API key is not configured"], statusCode: 401, on: connection)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await self.proxySession.data(for: proxyRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.queue.async {
                        self.sendJSON(["ok": false, "error": "Invalid upstream response"], statusCode: 502, on: connection)
                    }
                    return
                }
                self.queue.async {
                    self.sendRawResponse(
                        data,
                        statusCode: httpResponse.statusCode,
                        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/json",
                        extraHeaders: Self.proxyResponseHeaders(from: httpResponse),
                        on: connection
                    )
                }
            } catch {
                self.queue.async {
                    self.sendJSON(["ok": false, "error": "Inference proxy failed: \(error.localizedDescription)"], statusCode: 502, on: connection)
                }
            }
        }
    }

    private func makeInferenceProxyURLRequest(from request: HTTPRequest) -> URLRequest? {
        let targetBase: String
        let apiKey: String?
        if request.path == "/v1/messages" {
            targetBase = AppBundleConfiguration.anthropicBaseURL()
            apiKey = AppBundleConfiguration.anthropicAPIKey()
        } else {
            targetBase = "https://api.openai.com"
            apiKey = AppBundleConfiguration.openAIAPIKey()
        }

        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: targetBase + request.path) else { return nil }

        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        upstream.timeoutInterval = 120
        upstream.httpBody = request.body
        upstream.setValue(request.headers["content-type"] ?? "application/json", forHTTPHeaderField: "Content-Type")
        if let accept = request.headers["accept"] {
            upstream.setValue(accept, forHTTPHeaderField: "Accept")
        }

        if request.path == "/v1/messages" {
            upstream.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            upstream.setValue(request.headers["anthropic-version"] ?? "2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let beta = request.headers["anthropic-beta"] {
                upstream.setValue(beta, forHTTPHeaderField: "anthropic-beta")
            }
        } else {
            upstream.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if let organization = request.headers["openai-organization"] {
                upstream.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
            }
            if let project = request.headers["openai-project"] {
                upstream.setValue(project, forHTTPHeaderField: "OpenAI-Project")
            }
            if let beta = request.headers["openai-beta"] {
                upstream.setValue(beta, forHTTPHeaderField: "OpenAI-Beta")
            }
        }
        return upstream
    }

    private static func proxyResponseHeaders(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for key in ["request-id", "x-request-id", "openai-processing-ms", "anthropic-ratelimit-requests-remaining", "anthropic-ratelimit-tokens-remaining"] {
            if let value = response.value(forHTTPHeaderField: key) {
                headers[key] = value
            }
        }
        return headers
    }

    private func attachSSE(_ connection: NWConnection) {
        let id = UUID()
        sseConnections[id] = connection
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: http://127.0.0.1\r\n\r\n"
        connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] _ in
            self?.sendSSE(event: "ready", object: ["ok": true, "port": self?.port ?? 0], on: connection)
        })
    }

    private func broadcast(event: String, object: [String: Any]) {
        for (_, connection) in sseConnections {
            sendSSE(event: event, object: object, on: connection)
        }
    }

    private func sendSSE(event: String, object: [String: Any], on connection: NWConnection) {
        let dataObject = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let json = String(data: dataObject, encoding: .utf8) ?? "{}"
        let frame = "event: \(event)\ndata: \(json)\n\n"
        connection.send(content: Data(frame.utf8), completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, error != nil else { return }
            self.removeSSEConnection(connection)
        })
    }

    private func removeSSEConnection(_ connection: NWConnection) {
        sseConnections = sseConnections.filter { $0.value !== connection }
    }

    private func sendJSON(_ body: [String: Any], statusCode: Int, on connection: NWConnection) {
        let responseData = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        sendRawResponse(responseData, statusCode: statusCode, contentType: "application/json", on: connection)
    }

    private func sendRawResponse(_ responseData: Data, statusCode: Int, contentType: String, extraHeaders: [String: String] = [:], on connection: NWConnection) {
        let reason = Self.reasonPhrase(for: statusCode)
        var headers = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(responseData.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: http://127.0.0.1\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization, x-api-key, x-openclicky-token, anthropic-version, anthropic-beta, OpenAI-Organization, OpenAI-Project, OpenAI-Beta\r\n"
        for (key, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            headers += "\(key): \(value)\r\n"
        }
        headers += "\r\n"
        var data = Data(headers.utf8)
        data.append(responseData)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func cursorCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let point = point(from: json) else { return nil }
        return .showCursor(
            point: point,
            caption: string(json["caption"]),
            duration: duration(from: json),
            accentHex: string(json["accentHex"]),
            mode: cursorMode(from: json),
            travelDuration: travelDuration(from: json)
        )
    }

    private static func cursorsCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let rawCursors = array(json["cursors"]) else { return nil }
        let fallbackDuration = duration(from: json)
        let specs = rawCursors.compactMap { value -> OpenClickyExternalCursorSpec? in
            guard let cursor = dictionary(value), let point = point(from: cursor) else { return nil }
            let cursorDuration = cursor["durationMs"] == nil && cursor["ttlMs"] == nil && cursor["duration"] == nil
                ? fallbackDuration
                : duration(from: cursor)
            return OpenClickyExternalCursorSpec(
                point: point,
                caption: string(cursor["caption"]),
                duration: cursorDuration,
                accentHex: string(cursor["accentHex"])
            )
        }
        return specs.isEmpty ? nil : .showCursors(specs)
    }

    private static func captionCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let text = string(json["text"]), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .showCaption(
            text: text,
            point: point(from: json),
            duration: duration(from: json),
            accentHex: string(json["accentHex"])
        )
    }

    private static func clickCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let point = point(from: json) else { return nil }
        return .click(point: point, caption: string(json["caption"]) ?? string(json["label"]))
    }

    private static func speakCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let text = string(json["text"]), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .speak(text: text, interrupt: bool(json["interrupt"]) ?? false)
    }

    private static func notifyCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        let title = string(json["title"]) ?? "OpenClicky"
        guard let body = string(json["body"]) ?? string(json["text"]),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .notify(
            title: title,
            body: body,
            threadID: string(json["threadID"]) ?? string(json["threadId"]),
            sound: bool(json["sound"]) ?? true
        )
    }

    private static var mcpToolDescriptors: [[String: Any]] {
        var descriptors: [[String: Any]] = [
            [
                "name": "openclicky_point",
                "description": "Point OpenClicky's native cursor at a macOS screen coordinate with a short caption. Use this as the normal pointing tool call for guided help and tutorials.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "caption": ["type": "string"],
                        "durationMs": ["type": "number"],
                        "travelMs": ["type": "number"],
                        "accentHex": ["type": "string"],
                        "mode": ["type": "string", "enum": ["primary", "secondary"]]
                    ],
                    "required": ["x", "y"]
                ]
            ],
            [
                "name": "openclicky_point_many",
                "description": "Point at several visible UI targets at once with temporary secondary OpenClicky cursors.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cursors": ["type": "array"],
                        "durationMs": ["type": "number"]
                    ],
                    "required": ["cursors"]
                ]
            ],
            [
                "name": "show_cursor",
                "description": "Use OpenClicky's native smooth primary-cursor pointing choreography by default, or show a secondary colored cursor when mode=secondary.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "caption": ["type": "string"],
                        "durationMs": ["type": "number"],
                        "travelMs": ["type": "number"],
                        "accentHex": ["type": "string"],
                        "mode": ["type": "string", "enum": ["primary", "secondary"]]
                    ],
                    "required": ["x", "y"]
                ]
            ],
            [
                "name": "show_cursors",
                "description": "Show one or more temporary secondary colored cursors with captions. They collapse away automatically.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cursors": ["type": "array"]
                    ],
                    "required": ["cursors"]
                ]
            ],
            [
                "name": "show_caption",
                "description": "Show an OpenClicky proxy caption, optionally at macOS screen coordinates.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "durationMs": ["type": "number"],
                        "accentHex": ["type": "string"]
                    ],
                    "required": ["text"]
                ]
            ],
        ]

        if AppBundleConfiguration.visualDrawingOverlayToolsEnabled() {
            descriptors.append(contentsOf: visualDrawingMCPToolDescriptors)
        }

        // Gmail tools stay off the advertised surface until the local flag is
        // enabled. Even then they are stubs that return structured gated errors.
        if AppBundleConfiguration.gmailOAuthToolsEnabled() {
            descriptors.append(contentsOf: gmailMCPToolDescriptors)
        }

        descriptors.append(contentsOf: [
            [
                "name": "screenshot",
                "description": "Capture current screens to local JPEG files with frame metadata so the agent can locate UI and then show or click it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "focused": ["type": "boolean"]
                    ]
                ]
            ],
            [
                "name": "openclicky_click",
                "description": "Actually left-click a macOS screen coordinate using OpenClicky's native computer-use path. Coordinates are global AppKit screen points, the same coordinate space returned in screenshot displayFrame metadata.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "caption": ["type": "string"]
                    ],
                    "required": ["x", "y"]
                ]
            ],
            [
                "name": "click",
                "description": "Alias for openclicky_click: actually left-click a macOS screen coordinate through OpenClicky.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "caption": ["type": "string"]
                    ],
                    "required": ["x", "y"]
                ]
            ],
            [
                "name": "speak",
                "description": "Speak a short instruction through OpenClicky's TTS without entering dictation or voice-response mode.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "interrupt": ["type": "boolean"]
                    ],
                    "required": ["text"]
                ]
            ],
            [
                "name": "notify",
                "description": "Send a native macOS desktop notification from OpenClicky without stealing focus.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "body": ["type": "string"],
                        "threadID": ["type": "string"],
                        "sound": ["type": "boolean"]
                    ],
                    "required": ["body"]
                ]
            ],
            [
                "name": "clear",
                "description": "Clear the OpenClicky proxy cursor/caption overlay.",
                "inputSchema": ["type": "object", "properties": [:]]
            ]
        ])

        return descriptors
    }

    private static var visualDrawingMCPToolDescriptors: [[String: Any]] {
        [
            [
                "name": "show_scribble",
                "description": "Draw a temporary freehand visual guidance path over visible screen content. Coordinates are global AppKit screen points.",
                "compatibility": ["status": "supported", "capability": "visual_guidance.scribble"],
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "points": ["type": "array"],
                        "durationMs": ["type": "number"],
                        "accentHex": ["type": "string"],
                        "lineWidth": ["type": "number"],
                        "caption": ["type": "string"]
                    ],
                    "required": ["points"]
                ]
            ],
            [
                "name": "show_highlight",
                "description": "Draw a temporary rectangle highlight over visible screen content. Coordinates are global AppKit screen points.",
                "compatibility": ["status": "supported", "capability": "visual_guidance.rectangle"],
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "width": ["type": "number"],
                        "height": ["type": "number"],
                        "durationMs": ["type": "number"],
                        "accentHex": ["type": "string"],
                        "lineWidth": ["type": "number"],
                        "fillOpacity": ["type": "number"],
                        "caption": ["type": "string"]
                    ],
                    "required": ["x", "y", "width", "height"]
                ]
            ],
            [
                "name": "show_rectangle",
                "description": "Alias for show_highlight.",
                "compatibility": ["status": "supported", "capability": "visual_guidance.rectangle"],
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "width": ["type": "number"],
                        "height": ["type": "number"],
                        "durationMs": ["type": "number"],
                        "accentHex": ["type": "string"],
                        "lineWidth": ["type": "number"],
                        "fillOpacity": ["type": "number"],
                        "caption": ["type": "string"]
                    ],
                    "required": ["x", "y", "width", "height"]
                ]
            ],
        ]
    }

    private static var gmailMCPToolDescriptors: [[String: Any]] {
        let compatibility: [String: Any] = [
            "status": "gated",
            "capability": "gmail.oauth",
            "requiresOAuth": true,
            "policy": "read-only-until-confirmed-send",
            "implementation": "stub"
        ]

        return [
            [
                "name": "gmail_list_messages",
                "description": "Gated Gmail OAuth stub. Advertised only when the local Gmail OAuth tools flag is enabled. Calls return a structured not-implemented error until the gog-backed backend is wired.",
                "compatibility": compatibility,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "maxResults": ["type": "number"],
                        "account": ["type": "string"]
                    ]
                ]
            ],
            [
                "name": "gmail_read_message",
                "description": "Gated Gmail OAuth stub. Advertised only when the local Gmail OAuth tools flag is enabled. Calls return a structured not-implemented error until the gog-backed backend is wired.",
                "compatibility": compatibility,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "messageId": ["type": "string"],
                        "account": ["type": "string"]
                    ],
                    "required": ["messageId"]
                ]
            ],
            [
                "name": "gmail_draft_reply",
                "description": "Gated Gmail OAuth stub. Prepare a reply draft for user review once the backend exists. Sending remains blocked and is not implemented on this path.",
                "compatibility": compatibility,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "messageId": ["type": "string"],
                        "body": ["type": "string"],
                        "account": ["type": "string"]
                    ],
                    "required": ["messageId", "body"]
                ]
            ]
        ]
    }

    private static var capabilityCompatibilityMetadata: [[String: Any]] {
        let drawingStatus = AppBundleConfiguration.visualDrawingOverlayToolsEnabled() ? "supported" : "gated"
        let gmailToolsEnabled = AppBundleConfiguration.gmailOAuthToolsEnabled()
        return [
            [
                "id": "visual_guidance.scribble",
                "title": "Scribble drawing overlay",
                "status": drawingStatus,
                "tools": ["show_scribble"],
                "featureFlag": AppBundleConfiguration.userVisualDrawingOverlayToolsEnabledDefaultsKey,
                "policy": "visible-current-screen-content-only"
            ],
            [
                "id": "visual_guidance.rectangle",
                "title": "Rectangle highlight overlay",
                "status": drawingStatus,
                "tools": ["show_highlight", "show_rectangle"],
                "featureFlag": AppBundleConfiguration.userVisualDrawingOverlayToolsEnabledDefaultsKey,
                "policy": "visible-current-screen-content-only"
            ],
            [
                "id": "gmail.oauth",
                "title": "Gmail OAuth",
                // Always gated until a real OAuth/gog backend exists. The flag only
                // controls whether the stub tools are advertised for early integration.
                "status": "gated",
                "tools": gmailToolsEnabled
                    ? ["gmail_list_messages", "gmail_read_message", "gmail_draft_reply"]
                    : [],
                "featureFlag": AppBundleConfiguration.userGmailOAuthToolsEnabledDefaultsKey,
                "featureFlagEnabled": gmailToolsEnabled,
                "requiresOAuth": true,
                "risk": "external-account-data",
                "policy": "read-only-until-confirmed-send",
                "implementation": "stub"
            ]
        ]
    }

    private static func mcpToolCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        let tool = string(json["tool"]) ?? string(json["name"])
        let arguments = dictionary(json["arguments"]) ?? dictionary(json["args"]) ?? json
        switch tool {
        case "openclicky_point", "point", "show_cursor", "openclicky_show_cursor":
            return cursorCommand(from: arguments)
        case "openclicky_point_many", "point_many", "show_cursors", "openclicky_show_cursors":
            return cursorsCommand(from: arguments)
        case "show_caption", "openclicky_show_caption":
            return captionCommand(from: arguments)
        case "show_scribble", "openclicky_show_scribble", "scribble":
            return scribbleCommand(from: arguments)
        case "show_highlight", "show_rectangle", "openclicky_show_highlight", "highlight", "rectangle":
            return rectangleCommand(from: arguments)
        case "screenshot", "screenshots", "capture_screenshot", "openclicky_screenshot":
            return .captureScreenshot(focused: bool(arguments["focused"]) ?? false)
        case "openclicky_click", "click", "left_click", "mouse_click":
            return clickCommand(from: arguments)
        case "clear", "openclicky_clear":
            return .clear
        case "speak", "openclicky_speak":
            return speakCommand(from: arguments)
        case "notify", "notification", "openclicky_notify":
            return notifyCommand(from: arguments)
        case "gmail_list_messages", "gmail_read_message", "gmail_draft_reply":
            return gmailUnavailableCommand(tool: tool ?? "gmail", arguments: arguments)
        default:
            return nil
        }
    }

    private static func gmailUnavailableCommand(tool: String, arguments: [String: Any]) -> OpenClickyExternalControlCommand {
        let featureEnabled = AppBundleConfiguration.gmailOAuthToolsEnabled()
        let message: String
        if featureEnabled {
            message = "Gmail OAuth bridge tools are advertised as stubs only. No local OAuth/gog mailbox backend is wired yet. Prefer the bundled gog / google-workspace-gogcli skill path for reads, and do not treat this call as a send."
        } else {
            message = "Gmail OAuth tools are disabled. Enable openClickyGmailOAuthToolsEnabled or OPENCLICKY_GMAIL_OAUTH_TOOLS_ENABLED to advertise the stub surface. Prefer the bundled gog / google-workspace-gogcli skill path."
        }

        var body: [String: Any] = [
            "ok": false,
            "error": message,
            "tool": tool,
            "capability": "gmail.oauth",
            "status": "gated",
            "implementation": "stub",
            "featureFlag": AppBundleConfiguration.userGmailOAuthToolsEnabledDefaultsKey,
            "featureFlagEnabled": featureEnabled,
            "policy": "read-only-until-confirmed-send"
        ]
        if let messageId = string(arguments["messageId"]) {
            body["messageId"] = messageId
        }
        if let query = string(arguments["query"]) {
            body["query"] = query
        }
        return .unavailable(statusCode: 501, body: body)
    }

    private static func mcpJSONRPCResponse(from json: [String: Any]) -> MCPJSONRPCBridgeResponse? {
        guard string(json["jsonrpc"]) != nil || string(json["method"]) != nil else { return nil }
        let id = json["id"]
        let method = string(json["method"])
        switch method {
        case "initialize":
            return MCPJSONRPCBridgeResponse(id: id, command: nil, staticResult: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "OpenClicky External Control Bridge", "version": "1.0.0"]
            ])
        case "notifications/initialized":
            return MCPJSONRPCBridgeResponse(id: id, command: nil, staticResult: [:])
        case "tools/list":
            return MCPJSONRPCBridgeResponse(id: id, command: nil, staticResult: ["tools": mcpToolDescriptors])
        case "tools/call":
            let params = dictionary(json["params"]) ?? [:]
            let name = string(params["name"]) ?? string(params["tool"])
            let arguments = dictionary(params["arguments"]) ?? [:]
            guard let name else {
                return MCPJSONRPCBridgeResponse(id: id, command: nil, staticResult: nil, errorMessage: "Missing tool name")
            }
            let command = mcpToolCommand(from: ["tool": name, "arguments": arguments])
            return MCPJSONRPCBridgeResponse(id: id, command: command, staticResult: nil, errorMessage: command == nil ? "Unknown or invalid tool" : nil)
        default:
            return MCPJSONRPCBridgeResponse(id: id, command: nil, staticResult: nil, errorMessage: "Unsupported MCP method")
        }
    }

    private static func point(from json: [String: Any]) -> CGPoint? {
        // M14: guard against NaN/Infinity so a malformed {"x":"NaN","y":"NaN"}
        // cannot propagate through pointClampedToDesktop into a CGEvent.
        if let point = dictionary(json["point"]), let x = double(point["x"]), let y = double(point["y"]) {
            guard x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y)
        }
        guard let x = double(json["x"]), let y = double(json["y"]) else { return nil }
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func scribbleCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let rawPoints = array(json["points"]) else { return nil }
        let points = rawPoints.compactMap { value -> CGPoint? in
            if let dict = dictionary(value) { return point(from: dict) }
            if let pair = array(value), pair.count >= 2, let x = double(pair[0]), let y = double(pair[1]) {
                return CGPoint(x: x, y: y)
            }
            return nil
        }
        guard points.count >= 2 else { return nil }
        let overlay = OpenClickyVisualGuidanceOverlay.scribble(
            points: points,
            accentHex: string(json["accentHex"]),
            lineWidth: double(json["lineWidth"]) ?? double(json["strokeWidth"]) ?? 5,
            caption: string(json["caption"]),
            duration: duration(from: json)
        )
        return overlay.isRenderable ? .showVisualGuidanceOverlay(overlay) : nil
    }

    private static func rectangleCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        let rect: CGRect?
        if let rectDict = dictionary(json["rect"]) ?? dictionary(json["rectangle"]) {
            rect = rectFrom(rectDict)
        } else {
            rect = rectFrom(json)
        }
        guard let rect else { return nil }
        let overlay = OpenClickyVisualGuidanceOverlay.rectangle(
            rect: rect,
            accentHex: string(json["accentHex"]),
            lineWidth: double(json["lineWidth"]) ?? double(json["strokeWidth"]) ?? 4,
            fillOpacity: double(json["fillOpacity"]) ?? 0.14,
            caption: string(json["caption"]),
            duration: duration(from: json)
        )
        return overlay.isRenderable ? .showVisualGuidanceOverlay(overlay) : nil
    }

    private static func rectFrom(_ json: [String: Any]) -> CGRect? {
        if let x = double(json["x"]), let y = double(json["y"]), let width = double(json["width"]), let height = double(json["height"]) {
            return CGRect(x: x, y: y, width: width, height: height)
        }
        if let x1 = double(json["x1"]), let y1 = double(json["y1"]), let x2 = double(json["x2"]), let y2 = double(json["y2"]) {
            return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
        }
        return nil
    }

    private static func cursorMode(from json: [String: Any]) -> OpenClickyExternalCursorMode {
        guard let rawMode = string(json["mode"])?.lowercased() else { return .primary }
        if rawMode == "secondary" || rawMode == "new" || rawMode == "ghost" {
            return .secondary
        }
        return .primary
    }

    private static func duration(from json: [String: Any]) -> TimeInterval {
        let milliseconds = double(json["durationMs"]) ?? double(json["ttlMs"])
        if let milliseconds { return max(0.2, min(milliseconds / 1000.0, 60.0)) }
        return max(0.2, min(double(json["duration"]) ?? 4.0, 60.0))
    }

    private static func travelDuration(from json: [String: Any]) -> TimeInterval {
        let milliseconds = double(json["travelMs"]) ?? double(json["moveMs"])
        if let milliseconds { return max(0.0, min(milliseconds / 1000.0, 3.0)) }
        return max(0.0, min(double(json["travelDuration"]) ?? 0.65, 3.0))
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value.isFinite ? value : nil }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String, let parsed = Double(value) { return parsed.isFinite ? parsed : nil }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? String { return ["true", "yes", "1"].contains(value.lowercased()) }
        if let value = value as? Int { return value != 0 }
        return nil
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 408: return "Request Timeout"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "OK"
        }
    }
}

#if DEBUG
extension OpenClickyExternalControlBridgeServer {
    static var testMCPToolDescriptors: [[String: Any]] {
        mcpToolDescriptors
    }

    static var testCapabilityCompatibilityMetadata: [[String: Any]] {
        capabilityCompatibilityMetadata
    }

    static func testCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        mcpToolCommand(from: json)
    }
}
#endif

private struct MCPJSONRPCBridgeResponse {
    let id: Any?
    let command: OpenClickyExternalControlCommand?
    let staticResult: [String: Any]?
    var errorMessage: String? = nil

    func responseBody(result: OpenClickyExternalControlResponse?) -> [String: Any] {
        var body: [String: Any] = ["jsonrpc": "2.0"]
        if let id { body["id"] = id }
        if let errorMessage {
            body["error"] = ["code": -32602, "message": errorMessage]
            return body
        }
        if let staticResult {
            body["result"] = staticResult
            return body
        }
        if let result {
            body["result"] = [
                "content": [[
                    "type": "text",
                    "text": (result.body["ok"] as? Bool) == true ? "ok" : (result.body["error"] as? String ?? "error")
                ]],
                "isError": result.statusCode >= 400
            ]
            return body
        }
        body["result"] = [:]
        return body
    }
}

private struct HTTPRequest {
    enum ParseResult {
        case incomplete
        case malformed(String)
        case request(HTTPRequest)
    }

    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var jsonBody: [String: Any] {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    private init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > openClickyExternalControlMaximumHeaderBytes
                ? .malformed("HTTP request headers exceed the maximum size.")
                : .incomplete
        }
        guard headerRange.lowerBound <= openClickyExternalControlMaximumHeaderBytes else {
            return .malformed("HTTP request headers exceed the maximum size.")
        }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .malformed("HTTP request headers must be UTF-8.")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .malformed("HTTP request line is missing.")
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[2].hasPrefix("HTTP/") else {
            return .malformed("HTTP request line is invalid.")
        }

        var headers: [String: String] = [:]
        var sawContentLength = false
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                return .malformed("HTTP request header is invalid.")
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                return .malformed("HTTP request header name is missing.")
            }
            if key == "content-length" {
                guard !sawContentLength else {
                    return .malformed("Multiple Content-Length headers are not allowed.")
                }
                sawContentLength = true
            }
            headers[key] = value
        }

        if let transferEncoding = headers["transfer-encoding"],
           !transferEncoding.isEmpty,
           transferEncoding.lowercased() != "identity" {
            return .malformed("Transfer-Encoding is not supported.")
        }

        let bodyStart = headerRange.upperBound
        let contentLength: Int
        if let declaredLength = headers["content-length"] {
            guard !declaredLength.isEmpty,
                  declaredLength.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let parsedLength = Int(declaredLength),
                  parsedLength <= openClickyExternalControlMaximumBodyBytes else {
                return .malformed("Content-Length is invalid or exceeds the maximum request size.")
            }
            contentLength = parsedLength
        } else {
            contentLength = 0
        }

        // `contentLength <= data.count - bodyStart` avoids both a negative
        // range and integer overflow for attacker-controlled header values.
        guard bodyStart <= data.count else {
            return .malformed("HTTP request body offset is invalid.")
        }
        guard contentLength <= data.count - bodyStart else {
            return .incomplete
        }
        let bodyEnd = bodyStart + contentLength
        return .request(
            HTTPRequest(
                method: parts[0].uppercased(),
                path: URLComponents(string: parts[1])?.path ?? parts[1],
                headers: headers,
                body: Data(data[bodyStart..<bodyEnd])
            )
        )
    }
}
