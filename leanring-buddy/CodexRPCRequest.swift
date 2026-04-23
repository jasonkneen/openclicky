import Foundation

struct CodexRPCRequest {
    let id: Int?
    let method: String
    let params: Any?

    init(id: Int? = nil, method: String, params: Any? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    func dictionary() -> [String: Any] {
        var value: [String: Any] = ["method": method]
        if let id {
            value["id"] = id
        }
        if let params {
            value["params"] = params
        }
        return value
    }

    func encodedLine() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dictionary(), options: [.sortedKeys, .withoutEscapingSlashes])
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodexRPCError(message: "Could not encode Codex RPC request as UTF-8.")
        }
        return string + "\n"
    }
}

struct CodexRPCError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum CodexJSON {
    static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }
}
