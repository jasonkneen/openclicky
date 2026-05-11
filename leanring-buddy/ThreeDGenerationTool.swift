// ThreeDGenerationTool.swift
// Tool surface exposed to the chat agents (Codex / Claude).
//
// Both ClaudeAgentSDKAPI.swift and CodexAgentSession.swift register tools
// the agent can call. This file provides:
//   - A static JSON Schema usable by either backend.
//   - A unified `invoke(...)` entry point that parses args, kicks off
//     ThreeDGenerationService.shared, and returns a tool-call result string.

import Foundation

enum ThreeDGenerationTool {

    static let name = "generate_3d"
    static let description = """
    Generate a 3D low-poly stylized model (GLB) from a text prompt. \
    The model appears inline in the chat as a rotatable preview. \
    Use this whenever the user asks for a 3D object, prop, character, \
    artifact, or asset that should be visualised in three dimensions.
    """

    /// JSON Schema (subset OpenAI/Anthropic-compatible).
    static let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "prompt": [
                "type": "string",
                "description": "Short description of the 3D object to generate. Example: 'a friendly fox holding a lantern'."
            ],
            "style": [
                "type": "string",
                "enum": ["low_poly_stylized", "clay", "voxel", "game_asset", "realistic"],
                "description": "Visual style. Default 'low_poly_stylized' suits the app aesthetic.",
                "default": "low_poly_stylized"
            ],
            "quad": [
                "type": "boolean",
                "description": "Request quad-mesh retopology (cleaner, lower poly count). Default true.",
                "default": true
            ],
            "pbr": [
                "type": "boolean",
                "description": "Request PBR textures. Default true.",
                "default": true
            ]
        ],
        "required": ["prompt"]
    ]

    /// Public result returned to the agent.
    struct InvocationResult: Codable {
        let job_id: String
        let prompt: String
        let style: String
        let status: String       // "queued"
        let provider: String
        let user_message: String // What to show in the chat alongside the bubble.
    }

    /// Invoke the tool. Returns immediately with a job id — UI binds to
    /// `ThreeDGenerationService.shared.jobs` to render progress / completion.
    @MainActor
    static func invoke(arguments: [String: Any]) throws -> InvocationResult {
        guard let prompt = arguments["prompt"] as? String, !prompt.isEmpty else {
            throw NSError(
                domain: "ThreeDGenerationTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing required argument: prompt"]
            )
        }
        let styleRaw = (arguments["style"] as? String) ?? "low_poly_stylized"
        let style = parseStyle(styleRaw)
        let quad = arguments["quad"] as? Bool ?? true
        let pbr = arguments["pbr"] as? Bool ?? true

        let service = ThreeDGenerationService.shared
        let jobId = service.generate(prompt: prompt, style: style, quad: quad, pbr: pbr)

        return InvocationResult(
            job_id: jobId.uuidString,
            prompt: prompt,
            style: style.rawValue,
            status: "queued",
            provider: "tripo",
            user_message: "Generating a \(style.rawValue) 3D model of: \(prompt). I'll show the preview inline when it's ready."
        )
    }

    private static func parseStyle(_ raw: String) -> ThreeDStyle {
        switch raw.lowercased() {
        case "low_poly_stylized", "low_poly", "lowpoly", "stylized":
            return .lowPolyStylized
        case "clay":       return .clay
        case "voxel":      return .voxel
        case "game_asset", "gameasset", "game-ready":
            return .gameAsset
        case "realistic":  return .realistic
        default:           return .lowPolyStylized
        }
    }
}
