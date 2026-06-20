import Foundation

/// Errors surfaced by the local-model paths. User-facing strings are
/// actionable and name the likely cause (server not running, etc.).
enum LocalModelError: LocalizedError {
    case serverUnreachable(URL)
    case badResponse(Int, String)
    case emptyList

    var errorDescription: String? {
        switch self {
        case .serverUnreachable(let url):
            return "No local model server reachable at \(url.absoluteString). Is Ollama or LM Studio running?"
        case .badResponse(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Local model server returned \(code)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        case .emptyList:
            return "The local model server is reachable but reported no installed models."
        }
    }
}

/// Discovers installed models from an OpenAI-compatible local server via
/// `GET {baseURL}/models`. Both Ollama and LM Studio serve this route.
enum LocalModelDiscovery {
    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    /// Pure parser, unit-tested without the network.
    static func parseModelList(_ data: Data) throws -> [String] {
        let decoded = try JSONDecoder().decode(ModelList.self, from: data)
        let ids = decoded.data.map(\.id)
        if ids.isEmpty { throw LocalModelError.emptyList }
        return ids
    }

    static func listModels(baseURL: URL, apiKey: String?) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 5
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LocalModelError.serverUnreachable(baseURL)
            }
            guard http.statusCode == 200 else {
                throw LocalModelError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            return try parseModelList(data)
        } catch let error as URLError where
            error.code == .cannotConnectToHost ||
            error.code == .cannotFindHost ||
            error.code == .timedOut {
            throw LocalModelError.serverUnreachable(baseURL)
        }
    }
}
