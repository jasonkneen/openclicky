// ThreeDGenerationTypes.swift
// Shared protocol + value types for 3D-model generation providers.
//
// Providers (Tripo, Meshy, Fal/Hunyuan, …) conform to ThreeDGenerationProvider
// so the rest of the app can be provider-agnostic.

import Foundation

// MARK: - Inputs

/// User-facing style hint. Translated per-provider into either a `style`
/// API field or prompt-engineering prefix.
enum ThreeDStyle: String, Codable, CaseIterable, Sendable {
    case lowPolyStylized   // Default for OpenClicky chat
    case clay
    case voxel
    case gameAsset
    case realistic
    case none

    var promptPrefix: String {
        switch self {
        case .lowPolyStylized:
            return "low poly, stylized, flat shaded, faceted clean geometry, minimal triangle count, "
        case .clay:
            return "stylized clay, smooth matte surfaces, "
        case .voxel:
            return "voxel art, blocky, cubic geometry, "
        case .gameAsset:
            return "game-ready asset, clean topology, hand-painted style, "
        case .realistic:
            return ""
        case .none:
            return ""
        }
    }
}

struct ThreeDGenerationRequest: Sendable {
    let prompt: String
    let style: ThreeDStyle
    /// Negative prompt — provider may ignore.
    let negativePrompt: String?
    /// Request quad mesh (lower poly count, retopologised).
    let quad: Bool
    /// Request PBR textures. If false, providers return base-color only.
    let pbr: Bool

    init(
        prompt: String,
        style: ThreeDStyle = .lowPolyStylized,
        negativePrompt: String? = "high poly, photorealistic, noisy detail, blurry",
        quad: Bool = true,
        pbr: Bool = true
    ) {
        self.prompt = prompt
        self.style = style
        self.negativePrompt = negativePrompt
        self.quad = quad
        self.pbr = pbr
    }
}

// MARK: - Outputs

enum ThreeDTaskStatus: String, Codable, Sendable {
    case queued
    case running
    case success
    case failed
    case cancelled
}

struct ThreeDGenerationProgress: Sendable {
    let status: ThreeDTaskStatus
    /// 0.0 – 1.0 when the provider supplies it; nil otherwise.
    let progress: Double?
    let message: String?

    init(status: ThreeDTaskStatus, progress: Double? = nil, message: String? = nil) {
        self.status = status
        self.progress = progress
        self.message = message
    }
}

struct ThreeDGenerationResult: Sendable {
    let taskId: String
    /// Local file URL of the downloaded GLB.
    let glbURL: URL
    /// Optional thumbnail PNG file URL.
    let thumbnailURL: URL?
    /// Remote URL the GLB was downloaded from (useful for share/export).
    let remoteGLBURL: URL?
    let provider: String
    let prompt: String
    let style: ThreeDStyle
    let createdAt: Date

    init(
        taskId: String,
        glbURL: URL,
        thumbnailURL: URL?,
        remoteGLBURL: URL?,
        provider: String,
        prompt: String,
        style: ThreeDStyle,
        createdAt: Date
    ) {
        self.taskId = taskId
        self.glbURL = glbURL
        self.thumbnailURL = thumbnailURL
        self.remoteGLBURL = remoteGLBURL
        self.provider = provider
        self.prompt = prompt
        self.style = style
        self.createdAt = createdAt
    }
}

// MARK: - Errors

enum ThreeDGenerationError: LocalizedError, Sendable {
    case missingAPIKey(provider: String)
    case submissionFailed(provider: String, status: Int, body: String)
    case pollingFailed(provider: String, status: Int, body: String)
    case taskFailed(provider: String, reason: String)
    case noModelURL(provider: String)
    case downloadFailed(URL, underlying: String)
    case timedOut(taskId: String, afterSeconds: Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p):
            return "Missing API key for \(p). Set it in OpenClicky → Settings → 3D Generation."
        case .submissionFailed(let p, let s, let b):
            return "\(p) submission failed (\(s)): \(b)"
        case .pollingFailed(let p, let s, let b):
            return "\(p) polling failed (\(s)): \(b)"
        case .taskFailed(let p, let r):
            return "\(p) task failed: \(r)"
        case .noModelURL(let p):
            return "\(p) finished but returned no GLB URL."
        case .downloadFailed(let url, let underlying):
            return "Download failed from \(url): \(underlying)"
        case .timedOut(let id, let s):
            return "Task \(id) timed out after \(s)s."
        case .cancelled:
            return "3D generation cancelled."
        }
    }
}

// MARK: - Provider protocol

protocol ThreeDGenerationProvider: Sendable {
    /// Stable identifier for telemetry / settings UI ("tripo", "meshy", …).
    var identifier: String { get }
    /// Human label for menus.
    var displayName: String { get }

    /// Generate a single 3D asset. The provider must:
    ///   1. submit the task,
    ///   2. poll until terminal,
    ///   3. download the GLB into `destinationDirectory`,
    ///   4. return a `ThreeDGenerationResult`.
    /// `onProgress` is called on an arbitrary queue.
    func generate(
        request: ThreeDGenerationRequest,
        destinationDirectory: URL,
        onProgress: @Sendable @escaping (ThreeDGenerationProgress) -> Void
    ) async throws -> ThreeDGenerationResult
}
