import Foundation

public protocol BrowserWorkspaceAgentSessionProtocol {
    var id: UUID { get }
    var title: String { get }
}

@MainActor
public protocol BrowserWorkspaceAgentDelegate: AnyObject {
    func hasLinkedAgentSession(id: UUID) -> Bool
    func selectCodexAgentSession(_ id: UUID)
    func submitAgentPromptFromUI(_ prompt: String)
    func submitAgentPromptFromUI(_ prompt: String, source: String)
    func submitNewAgentTaskFromUI(_ prompt: String, source: String) -> BrowserWorkspaceAgentSessionProtocol?
    func hasAgentSDK() -> Bool
    func analyzeImageWithAgentSDK(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String

    // Config and Models providers
    func getAnthropicAPIKey() -> String
    func getSelectedComputerUseModelID() -> String
    func selectedComputerUseModelUsesAnthropic() -> Bool

    // MARK: - Voice dictation hooks
    //
    // The Browser Workspace embeds a mic button in its composer so the user
    // can talk to the browser agent the same way they talk to any other
    // OpenClicky agent. Dictation is owned by the host app (CompanionManager
    // wraps BuddyDictationManager); the workspace just calls these hooks.

    /// True when any dictation session is in flight. The workspace uses this
    /// to flip the mic button affordance (record vs stop).
    func isBrowserWorkspaceDictationActive() -> Bool

    /// Starts a push-to-talk dictation session that auto-submits its final
    /// transcript when the user stops recording. Partial transcripts update
    /// the composer draft in real time via `updateDraft`.
    func startBrowserWorkspaceDictation(
        currentDraft: String,
        updateDraft: @escaping @MainActor (String) -> Void,
        submitDraft: @escaping @MainActor (String) -> Void
    )

    /// Stops the active dictation session (if any). The final transcript is
    /// delivered via the callbacks that were passed to `startBrowserWorkspaceDictation`.
    func stopBrowserWorkspaceDictation()
}

public extension BrowserWorkspaceAgentDelegate {
    func submitAgentPromptFromUI(_ prompt: String, source: String) {
        submitAgentPromptFromUI(prompt)
    }
}
