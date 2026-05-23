// TripoThreeDProvider.swift
// Tripo AI text-to-3D provider. Uses the v2 OpenAPI:
//   POST https://api.tripo3d.ai/v2/openapi/task
//   GET  https://api.tripo3d.ai/v2/openapi/task/{task_id}
// Auth: Authorization: Bearer <tsk_...>

import Foundation

actor TripoThreeDProvider: ThreeDGenerationProvider {

    // MARK: - Config

    nonisolated let identifier = "tripo"
    nonisolated let displayName = "Tripo AI"

    private let apiKeyProvider: @Sendable () -> String?
    private let modelVersion: String?
    private let baseURL: URL
    private let session: URLSession
    private let pollInterval: TimeInterval
    private let timeoutSeconds: Int

    init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        modelVersion: String? = nil,
        baseURL: URL = URL(string: "https://api.tripo3d.ai/v2/openapi")!,
        session: URLSession = .shared,
        pollInterval: TimeInterval = 2.0,
        timeoutSeconds: Int = 300
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.modelVersion = modelVersion
        self.baseURL = baseURL
        self.session = session
        self.pollInterval = pollInterval
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Provider entry point

    func generate(
        request: ThreeDGenerationRequest,
        destinationDirectory: URL,
        onProgress: @Sendable @escaping (ThreeDGenerationProgress) -> Void
    ) async throws -> ThreeDGenerationResult {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw ThreeDGenerationError.missingAPIKey(provider: identifier)
        }

        onProgress(ThreeDGenerationProgress(status: .queued, progress: 0, message: "Submitting to Tripo…"))
        let taskId = try await submit(request: request, apiKey: apiKey)

        onProgress(ThreeDGenerationProgress(status: .running, progress: 0.05, message: "Queued (\(taskId))"))
        let outcome = try await poll(taskId: taskId, apiKey: apiKey, onProgress: onProgress)

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let glbDestination = destinationDirectory.appendingPathComponent("\(taskId).glb")
        try await download(from: outcome.modelURL, to: glbDestination, maxBytes: 200 * 1024 * 1024)

        var thumbLocal: URL? = nil
        if let thumb = outcome.thumbnailURL {
            let thumbDest = destinationDirectory.appendingPathComponent("\(taskId).png")
            do {
                try await download(from: thumb, to: thumbDest, maxBytes: 25 * 1024 * 1024)
                thumbLocal = thumbDest
            } catch {
                // Thumbnails are best-effort.
                thumbLocal = nil
            }
        }

        onProgress(ThreeDGenerationProgress(status: .success, progress: 1.0, message: "Ready"))

        return ThreeDGenerationResult(
            taskId: taskId,
            glbURL: glbDestination,
            thumbnailURL: thumbLocal,
            remoteGLBURL: outcome.modelURL,
            provider: identifier,
            prompt: request.prompt,
            style: request.style,
            createdAt: Date()
        )
    }

    // MARK: - Submit

    private struct SubmitResponse: Decodable {
        struct Data: Decodable { let task_id: String }
        let code: Int
        let data: Data?
        let message: String?
    }

    private func submit(request: ThreeDGenerationRequest, apiKey: String) async throws -> String {
        let url = baseURL.appendingPathComponent("task")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let styledPrompt = request.style.promptPrefix + request.prompt

        var body: [String: Any] = [
            "type": "text_to_model",
            "prompt": styledPrompt,
            "texture": true,
            "pbr": request.pbr,
            "quad": request.quad
        ]
        if let modelVersion, !modelVersion.isEmpty {
            // Only pin if the caller explicitly asked — otherwise let Tripo
            // pick its current default (forward-compat).
            body["model_version"] = modelVersion
        }
        if let neg = request.negativePrompt, !neg.isEmpty {
            body["negative_prompt"] = neg
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ThreeDGenerationError.submissionFailed(
                provider: identifier,
                status: status,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        let decoded = try JSONDecoder().decode(SubmitResponse.self, from: data)
        guard decoded.code == 0, let taskId = decoded.data?.task_id else {
            throw ThreeDGenerationError.submissionFailed(
                provider: identifier,
                status: status,
                body: decoded.message ?? "no task_id"
            )
        }
        return taskId
    }

    // MARK: - Poll

    private struct PollOutcome {
        let modelURL: URL
        let thumbnailURL: URL?
    }

    private struct PollResponse: Decodable {
        struct Output: Decodable {
            let model: String?
            let pbr_model: String?
            let base_model: String?
            let rendered_image: String?
        }
        struct Data: Decodable {
            let task_id: String
            let status: String
            let progress: Int?
            let output: Output?
        }
        let code: Int
        let data: Data?
        let message: String?
    }

    private func poll(
        taskId: String,
        apiKey: String,
        onProgress: @Sendable @escaping (ThreeDGenerationProgress) -> Void
    ) async throws -> PollOutcome {
        let url = baseURL.appendingPathComponent("task/\(taskId)")
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        while Date() < deadline {
            try Task.checkCancellation()

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw ThreeDGenerationError.pollingFailed(
                    provider: identifier,
                    status: status,
                    body: String(data: data, encoding: .utf8) ?? ""
                )
            }
            let decoded = try JSONDecoder().decode(PollResponse.self, from: data)
            guard let d = decoded.data else {
                throw ThreeDGenerationError.pollingFailed(
                    provider: identifier,
                    status: status,
                    body: decoded.message ?? "empty data"
                )
            }

            let normalized = d.status.lowercased()
            let progress = d.progress.map { Double($0) / 100.0 }
            onProgress(ThreeDGenerationProgress(
                status: ThreeDTaskStatus(rawValue: normalized) ?? .running,
                progress: progress,
                message: normalized
            ))

            switch normalized {
            case "success", "completed":
                let candidate = d.output?.pbr_model
                    ?? d.output?.model
                    ?? d.output?.base_model
                guard let modelStr = candidate,
                      let modelURL = URL(string: modelStr),
                      Self.isAllowedDownloadURL(modelURL) else {
                    throw ThreeDGenerationError.noModelURL(provider: identifier)
                }
                let thumb = d.output?.rendered_image.flatMap { raw -> URL? in
                    guard let url = URL(string: raw), Self.isAllowedDownloadURL(url) else { return nil }
                    return url
                }
                return PollOutcome(modelURL: modelURL, thumbnailURL: thumb)

            case "failed", "cancelled", "banned", "expired":
                throw ThreeDGenerationError.taskFailed(
                    provider: identifier,
                    reason: normalized
                )

            default:
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }

        throw ThreeDGenerationError.timedOut(taskId: taskId, afterSeconds: timeoutSeconds)
    }

    // MARK: - Download

    private func download(from remote: URL, to destination: URL, maxBytes: Int64) async throws {
        guard Self.isAllowedDownloadURL(remote) else {
            throw ThreeDGenerationError.downloadFailed(remote, underlying: "URL is not an allowed HTTPS download target")
        }
        do {
            let (tempURL, resp) = try await session.download(from: remote)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw ThreeDGenerationError.downloadFailed(remote, underlying: "HTTP \(status)")
            }
            let expectedLength = resp.expectedContentLength
            guard expectedLength <= 0 || expectedLength <= maxBytes else {
                throw ThreeDGenerationError.downloadFailed(remote, underlying: "download is too large")
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize > 0, fileSize <= maxBytes else {
                throw ThreeDGenerationError.downloadFailed(remote, underlying: "downloaded file size is invalid")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch let e as ThreeDGenerationError {
            throw e
        } catch {
            throw ThreeDGenerationError.downloadFailed(remote, underlying: error.localizedDescription)
        }
    }

    private static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              !isBlockedDownloadHost(host) else {
            return false
        }
        return true
    }

    private static func isBlockedDownloadHost(_ host: String) -> Bool {
        let stripped = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if stripped == "localhost" || stripped == "::1" || stripped.hasSuffix(".local") {
            return true
        }
        if stripped.contains(":") {
            return true
        }

        let octets = stripped.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch octets[0] {
        case 0, 10, 127:
            return true
        case 169 where octets[1] == 254:
            return true
        case 172 where (16...31).contains(octets[1]):
            return true
        case 192 where octets[1] == 168:
            return true
        default:
            return false
        }
    }
}
