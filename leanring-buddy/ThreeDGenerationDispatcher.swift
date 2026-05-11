// ThreeDGenerationDispatcher.swift
// Parses user input AND LLM output for 3D-generation triggers and dispatches
// them to ThreeDGenerationService.
//
// Supported triggers, in priority order:
//   1. `/3d <prompt>`                           — slash command (user or LLM)
//   2. `[OPENCLICKY_3D] prompt: <prompt>`       — explicit sentinel for LLMs
//   3. `[OPENCLICKY_3D] prompt: "<p>" style: "<s>"`  — with optional style
//
// Style values: low_poly_stylized | clay | voxel | game_asset | realistic
//
// Returns a `Match` describing what was matched (so the caller can strip the
// line from displayed text and substitute a user-facing message).

import Foundation

@MainActor
enum ThreeDGenerationDispatcher {

    struct Match {
        /// The exact substring that triggered (so caller can strip / replace).
        let originalText: String
        let prompt: String
        let style: ThreeDStyle
        /// The job id created by the service.
        let jobId: UUID
        /// A short message to surface in chat ("Generating a low-poly fox…").
        let userMessage: String
    }

    // MARK: - Entry points

    /// Scan a block of text. Returns matches in order found. Each match has
    /// already started a generation job — caller only needs to substitute the
    /// `originalText` with `userMessage` in the displayed transcript.
    @discardableResult
    static func scanAndDispatch(_ text: String) -> [Match] {
        var matches: [Match] = []

        // 1. /3d <prompt>  (one per line)
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = parseSlashCommand(trimmed) {
                matches.append(match)
            }
        }

        // 2. [OPENCLICKY_3D] sentinel — anywhere in text, possibly multi-line.
        matches.append(contentsOf: parseSentinels(text))

        return matches
    }

    /// Try to parse a single line as `/3d <prompt>`. Returns nil if not a match.
    static func parseSlashCommand(_ line: String) -> Match? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #"^/3d\b\s*"#, options: .regularExpression) else {
            return nil
        }
        let prompt = String(trimmed[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return nil }
        return dispatch(originalText: line, prompt: prompt, style: .lowPolyStylized)
    }

    /// Find every `[OPENCLICKY_3D] prompt: ...` occurrence in arbitrary text.
    private static func parseSentinels(_ text: String) -> [Match] {
        let pattern = #"\[OPENCLICKY_3D\][^\n]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let results = regex.matches(in: text, options: [], range: range)

        var out: [Match] = []
        for r in results {
            let line = nsText.substring(with: r.range)
            guard let (prompt, style) = extractSentinelFields(from: line) else { continue }
            if let m = dispatch(originalText: line, prompt: prompt, style: style) {
                out.append(m)
            }
        }
        return out
    }

    private static func extractSentinelFields(from line: String) -> (String, ThreeDStyle)? {
        // prompt: "<...>"  or  prompt: <unquoted text to end of line>
        let promptQuoted = match(line, pattern: #"prompt:\s*"([^"]+)""#)
        let promptUnquoted = match(line, pattern: #"prompt:\s*([^\s"]+(?:[^"\n]*[^"\s])?)"#)
        guard let promptRaw = (promptQuoted ?? promptUnquoted)?.trimmingCharacters(in: .whitespaces),
              !promptRaw.isEmpty
        else { return nil }

        let styleRaw = match(line, pattern: #"style:\s*"?([a-zA-Z_]+)"?"#)?.lowercased()
        let style = parseStyle(styleRaw)
        return (promptRaw, style)
    }

    private static func match(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let ns = text as NSString
        let r = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: text, range: r), m.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }

    private static func parseStyle(_ raw: String?) -> ThreeDStyle {
        switch raw ?? "" {
        case "low_poly_stylized", "low_poly", "lowpoly", "stylized":
            return .lowPolyStylized
        case "clay":      return .clay
        case "voxel":     return .voxel
        case "game_asset", "gameasset", "game-ready":
            return .gameAsset
        case "realistic": return .realistic
        default:          return .lowPolyStylized
        }
    }

    // MARK: - Dispatch

    private static func dispatch(originalText: String, prompt: String, style: ThreeDStyle) -> Match? {
        let service = ThreeDGenerationService.shared
        let id = service.generate(prompt: prompt, style: style)
        // Ensure the floating viewer is alive AND visible so the user sees the
        // progress bubble immediately. Safe to call repeatedly — toggles to
        // visible / brings to front.
        ThreeDViewerWindowManager.shared.showWindow()
        let msg = "Generating a \(style.rawValue) 3D model of: \(prompt). The preview opens automatically when ready."
        return Match(
            originalText: originalText,
            prompt: prompt,
            style: style,
            jobId: id,
            userMessage: msg
        )
    }

    // MARK: - System-prompt instruction (inject into LLM agents)

    /// Append this to the Claude / Codex system prompt so the model knows to
    /// emit the sentinel when the user asks for a 3D model. Both agents
    /// already have system-prompt machinery in OpenClicky.
    static let systemPromptInstruction = """
    3D model generation is available. When the user asks you to make, create, generate, sculpt, or visualise a 3D object, prop, asset, character, or artifact, emit a single line in your reply with EXACTLY this format and nothing else on that line:
        [OPENCLICKY_3D] prompt: "<short description of the object>" style: "low_poly_stylized"
    OpenClicky will detect that line, start a 3D generation job, and show the rotating preview in a floating window. The default style is low_poly_stylized; alternatives are clay, voxel, game_asset, realistic.
    You may include normal conversational text before or after the line. Do NOT call any tool, do NOT use Bash, do NOT try to write any files yourself — just emit the [OPENCLICKY_3D] line and OpenClicky handles the rest.
    """
}
