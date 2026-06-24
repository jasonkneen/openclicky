import AppKit
import Foundation

/// Locates a UI element in a screenshot using a local vision model
/// (OpenAI-compatible). Unlike `ElementLocationDetector` (which drives
/// Anthropic's Computer Use tool for structured coordinates), local models
/// have no such tool, so we ask for a normalized `[POINT:x,y]` tag in
/// 0.0...1.0 image space and map it to display-local AppKit coordinates.
struct LocalElementLocationDetector {
    let baseURL: URL
    let apiKey: String?
    let model: String

    private static let systemPrompt = """
    You locate UI elements in screenshots. Respond with ONLY a normalized coordinate \
    as [POINT:x,y] where x and y are decimals from 0.0 (left/top) to 1.0 (right/bottom) \
    marking the center of the single element the user should interact with. Choose an \
    element only when it is visibly present and directly relevant. If no specific \
    relevant element is visible, respond [POINT:none].
    """

    /// Parses a normalized `[POINT:x,y]` tag. Returns nil for `[POINT:none]`,
    /// missing tags, or out-of-range values. Pure and unit-tested.
    static func parseNormalizedPoint(_ text: String) -> (x: Double, y: Double)? {
        guard let openRange = text.range(of: "[POINT:") else { return nil }
        let afterOpen = text[openRange.upperBound...]
        guard let closeRange = afterOpen.range(of: "]") else { return nil }
        let inner = afterOpen[..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        if inner.lowercased() == "none" { return nil }
        let parts = inner.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              (0.0...1.0).contains(x), (0.0...1.0).contains(y) else {
            return nil
        }
        return (x, y)
    }

    /// Returns a display-local AppKit (bottom-left origin) point, or nil.
    func detectElementLocation(
        screenshotData: Data,
        userQuestion: String,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) async -> CGPoint? {
        let api = LocalChatCompletionsAPI(baseURL: baseURL, apiKey: apiKey, model: model, maxOutputTokens: 256)
        let prompt = "The user asked this while looking at their screen: \"\(userQuestion)\". Mark the single element they should interact with."
        do {
            let text = try await api.streamResponse(
                systemPrompt: Self.systemPrompt,
                history: [],
                userPrompt: prompt,
                images: [(data: screenshotData, label: "screen")],
                onTextChunk: { _ in }
            )
            guard let point = Self.parseNormalizedPoint(text) else { return nil }
            let clampedX = max(0.0, min(point.x, 1.0))
            let clampedY = max(0.0, min(point.y, 1.0))
            let x = CGFloat(clampedX) * CGFloat(displayWidthInPoints)
            let yTopLeft = CGFloat(clampedY) * CGFloat(displayHeightInPoints)
            // Convert top-left origin (image) to bottom-left origin (AppKit).
            let yBottomLeft = CGFloat(displayHeightInPoints) - yTopLeft
            return CGPoint(x: x, y: yBottomLeft)
        } catch {
            return nil
        }
    }
}
