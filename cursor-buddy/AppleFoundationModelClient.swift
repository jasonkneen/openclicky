import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleFoundationError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let why):
            return "Apple on-device model unavailable: \(why)"
        }
    }
}

/// Availability gate for Apple's on-device model. Safe to call on any host;
/// returns false where `FoundationModels` or Apple Intelligence is absent.
enum AppleFoundationModelAvailability {
    static func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
            return false
        }
        return false
        #else
        return false
        #endif
    }

    static func unavailableReason() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                return String(describing: reason)
            @unknown default:
                return "unknown"
            }
        }
        return "Requires macOS 26 or later."
        #else
        return "FoundationModels framework not available in this build."
        #endif
    }
}

/// Text-only on-device responder using Apple's `FoundationModels`.
/// No vision: the routing layer drops images and appends a one-line note.
struct AppleFoundationModelClient {
    func streamResponse(systemPrompt: String,
                        history: [(userPlaceholder: String, assistantResponse: String)],
                        userPrompt: String,
                        onTextChunk: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard AppleFoundationModelAvailability.isAvailable() else {
                throw AppleFoundationError.unavailable(AppleFoundationModelAvailability.unavailableReason() ?? "unknown")
            }
            let session = LanguageModelSession(instructions: systemPrompt)
            var prompt = ""
            for turn in history {
                prompt += "User: \(turn.userPlaceholder)\nAssistant: \(turn.assistantResponse)\n"
            }
            prompt += userPrompt

            var full = ""
            let stream = session.streamResponse(to: prompt)
            for try await partial in stream {
                // Partials are cumulative snapshots; emit only the new suffix.
                let snapshot = String(describing: partial)
                if snapshot.count > full.count, snapshot.hasPrefix(full) {
                    let delta = String(snapshot.dropFirst(full.count))
                    full = snapshot
                    let piece = delta
                    await MainActor.run { onTextChunk(piece) }
                } else if snapshot != full {
                    // Fallback if the snapshot is not a clean prefix extension.
                    full = snapshot
                    let piece = snapshot
                    await MainActor.run { onTextChunk(piece) }
                }
            }
            return full
        }
        throw AppleFoundationError.unavailable("Requires macOS 26 or later.")
        #else
        throw AppleFoundationError.unavailable("FoundationModels framework not available in this build.")
        #endif
    }
}
