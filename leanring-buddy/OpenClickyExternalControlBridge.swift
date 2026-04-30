import Foundation
import Network

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
    case showCaption(text: String, point: CGPoint?, duration: TimeInterval, accentHex: String?)
    case captureScreenshot(focused: Bool)
    case clear
    case speak(text: String, interrupt: Bool)
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

}

typealias OpenClickyExternalControlHandler = @MainActor (OpenClickyExternalControlCommand) async -> OpenClickyExternalControlResponse

final class OpenClickyExternalControlBridgeServer: @unchecked Sendable {
    private let port: UInt16
    private let handler: OpenClickyExternalControlHandler
    private let queue = DispatchQueue(label: "com.jkneen.openclicky.external-control-bridge")
    private var listener: NWListener?
    private var sseConnections: [UUID: NWConnection] = [:]

    init(port: UInt16 = 32123, handler: @escaping OpenClickyExternalControlHandler) {
        self.port = port
        self.handler = handler
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

            if let request = HTTPRequest(data: nextBuffer) {
                self.handle(request, on: connection)
                return
            }

            if isComplete || nextBuffer.count > 512 * 1024 {
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
            sendJSON([
                "ok": true,
                "name": "OpenClicky External Control Bridge",
                "port": port,
                "transport": "local-http+sse",
                "tools": ["show_cursor", "show_cursors", "show_caption", "screenshot", "clear", "speak"]
            ], statusCode: 200, on: connection)
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
        case "/caption":
            command = Self.captionCommand(from: request.jsonBody)
        case "/screenshot", "/screenshots":
            command = .captureScreenshot(focused: Self.bool(request.jsonBody["focused"]) ?? false)
        case "/clear":
            command = .clear
        case "/speak":
            command = Self.speakCommand(from: request.jsonBody)
        case "/mcp/call", "/tools/call":
            command = Self.mcpToolCommand(from: request.jsonBody)
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
        let reason = Self.reasonPhrase(for: statusCode)
        let headers = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(responseData.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: http://127.0.0.1\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n\r\n"
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

    private static func speakCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let text = string(json["text"]), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .speak(text: text, interrupt: bool(json["interrupt"]) ?? false)
    }

    private static var mcpToolDescriptors: [[String: Any]] {
        [
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
            [
                "name": "screenshot",
                "description": "Capture current screens to local JPEG files with frame metadata so the agent can locate UI and then show it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "focused": ["type": "boolean"]
                    ]
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
                "name": "clear",
                "description": "Clear the OpenClicky proxy cursor/caption overlay.",
                "inputSchema": ["type": "object", "properties": [:]]
            ]
        ]
    }

    private static func mcpToolCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        let tool = string(json["tool"]) ?? string(json["name"])
        let arguments = dictionary(json["arguments"]) ?? dictionary(json["args"]) ?? json
        switch tool {
        case "show_cursor", "openclicky_show_cursor":
            return cursorCommand(from: arguments)
        case "show_cursors", "openclicky_show_cursors":
            return cursorsCommand(from: arguments)
        case "show_caption", "openclicky_show_caption":
            return captionCommand(from: arguments)
        case "screenshot", "screenshots", "capture_screenshot", "openclicky_screenshot":
            return .captureScreenshot(focused: bool(arguments["focused"]) ?? false)
        case "clear", "openclicky_clear":
            return .clear
        case "speak", "openclicky_speak":
            return speakCommand(from: arguments)
        default:
            return nil
        }
    }

    private static func mcpJSONRPCResponse(from json: [String: Any]) -> MCPJSONRPCBridgeResponse? {
        guard string(json["jsonrpc"]) != nil || string(json["method"]) != nil else { return nil }
        let id = json["id"]
        let method = string(json["method"])
        switch method {
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
        if let point = dictionary(json["point"]), let x = double(point["x"]), let y = double(point["y"]) {
            return CGPoint(x: x, y: y)
        }
        guard let x = double(json["x"]), let y = double(json["y"]) else { return nil }
        return CGPoint(x: x, y: y)
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
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
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
        default: return "OK"
        }
    }
}

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

    init?(data: Data) {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + contentLength else { return nil }
        self.method = parts[0].uppercased()
        self.path = URLComponents(string: parts[1])?.path ?? parts[1]
        self.headers = headers
        self.body = data[bodyStart..<bodyStart + contentLength]
    }
}
