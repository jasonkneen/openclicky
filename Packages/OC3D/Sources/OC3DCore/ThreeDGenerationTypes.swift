// ThreeDGenerationTypes.swift
// Shared protocol + value types for 3D-model generation providers.
//
// Providers (Tripo, Meshy, Fal/Hunyuan, …) conform to ThreeDGenerationProvider
// so the rest of the app can be provider-agnostic.

import Foundation

// MARK: - Inputs

/// User-facing style hint. Translated per-provider into either a `style`
/// API field or prompt-engineering prefix.
nonisolated public enum ThreeDStyle: String, Codable, CaseIterable, Sendable {
    case lowPolyStylized   // Default for OpenClicky chat
    case clay
    case voxel
    case gameAsset
    case realistic
    case none

    public var promptPrefix: String {
        switch self {
        case .lowPolyStylized:
            return "faithful low-poly stylized game asset, preserve the user's described design exactly, preserve original silhouette, proportions, color palette, roof/wall/window/door/fence details, flat shaded, clean faceted geometry, simple readable shapes, "
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

public struct ThreeDGenerationRequest: Sendable {
    public let prompt: String
    public let style: ThreeDStyle
    /// Negative prompt — provider may ignore.
    public let negativePrompt: String?
    /// Request quad mesh (lower poly count, retopologised).
    public let quad: Bool
    /// Request PBR textures. If false, providers return base-color only.
    public let pbr: Bool

    public init(
        prompt: String,
        style: ThreeDStyle = .lowPolyStylized,
        negativePrompt: String? = "redesign, different architecture, changed color palette, changed roof shape, missing original details, high poly, photorealistic, noisy detail, blurry",
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

nonisolated public enum ThreeDTaskStatus: String, Codable, Sendable {
    case queued
    case running
    case success
    case failed
    case cancelled
}

nonisolated public struct ThreeDGenerationProgress: Sendable {
    public let status: ThreeDTaskStatus
    /// 0.0 – 1.0 when the provider supplies it; nil otherwise.
    public let progress: Double?
    public let message: String?

    public init(status: ThreeDTaskStatus, progress: Double? = nil, message: String? = nil) {
        self.status = status
        self.progress = progress
        self.message = message
    }
}

nonisolated public struct ThreeDGenerationResult: Sendable {
    public let taskId: String
    /// Local file URL of the downloaded GLB.
    public let glbURL: URL
    /// Optional thumbnail PNG file URL.
    public let thumbnailURL: URL?
    /// Remote URL the GLB was downloaded from (useful for share/export).
    public let remoteGLBURL: URL?
    public let provider: String
    public let prompt: String
    public let style: ThreeDStyle
    public let createdAt: Date

    public init(
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

nonisolated public enum ThreeDGenerationError: LocalizedError, Sendable {
    case missingAPIKey(provider: String)
    case submissionFailed(provider: String, status: Int, body: String)
    case pollingFailed(provider: String, status: Int, body: String)
    case taskFailed(provider: String, reason: String)
    case noModelURL(provider: String)
    case downloadFailed(URL, underlying: String)
    case timedOut(taskId: String, afterSeconds: Int)
    case cancelled

    public var errorDescription: String? {
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

nonisolated public protocol ThreeDGenerationProvider: Sendable {
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
