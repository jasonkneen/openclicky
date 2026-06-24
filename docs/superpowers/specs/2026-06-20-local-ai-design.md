# Local AI Models — Design Spec

Date: 2026-06-20
Branch: `claude/local-ai-models`
Status: Approved (design); ready for implementation plan

## Goal

Let OpenClicky use the user's own locally-run models — anything exposing the
OpenAI-compatible HTTP API (Ollama, LM Studio, MLX-server, llama.cpp, vLLM), and
Apple's on-device model via the `FoundationModels` framework — across the voice/chat,
element-pointing, and Agent Mode surfaces.

## Decisions (locked)

- **Backends:** both
  1. Generic OpenAI-compatible local endpoint (default Ollama `http://localhost:11434/v1`).
  2. Apple Foundation Models (on-device, text-only, macOS 26 + Apple Intelligence).
- **Surfaces:** voice/chat responses, element pointing (vision), Agent Mode (Codex).
- **Model discovery:** auto-discover via `GET {baseURL}/models` + manual id override.
- **Approach:** dedicated per-provider clients (matches the existing `ClaudeAPI` /
  `OpenAIAPI` / Deepgram pattern). `OpenAIAPI.swift` and `ClaudeAPI.swift` are NOT modified.
- Foundation Models with an attached screenshot: answer text-only and append a one-line
  "on-device model can't see your screen" note (do not error).
- An explicitly-selected local model never silently falls back to a billed cloud model.

## Non-goals (YAGNI)

- No Ollama/LM Studio auto-install or model download/management UI.
- No MLX-embedded (in-process) inference — use the local server.
- No cloud fallback for a local selection.
- No vision shim for Foundation Models (it stays text-only).
- No new persistent config / standing rules beyond the settings below.

## Architecture

```
Settings → "Local AI" group
   ├─ baseURL (UserDefaults: localModelBaseURL)         default http://localhost:11434/v1
   ├─ token   (Keychain via AppBundleConfiguration)     optional bearer
   ├─ maxOutputTokens (UserDefaults: localModelMaxOutputTokens, default 8192)
   ├─ [Detect models] → LocalModelDiscovery → picker + manual override
   ├─ [Test] → one tiny completion → reachability check
   ├─ Apple On-Device toggle (UserDefaults: appleFoundationEnabled; gated on availability)
   └─ "Use local endpoint for Agent Mode" → writes existing clickyAgentBaseURL

OpenClickyModelProvider += .localOpenAICompatible, .appleFoundation
OpenClickyModelCatalog   → resolves namespaced ids to synthesized options

Routing:
  analyzeVoiceResponse switch (CompanionManager.swift ~16279)
     .localOpenAICompatible → analyzeLocalChatResponse → LocalChatCompletionsAPI
     .appleFoundation       → analyzeAppleFoundationResponse → AppleFoundationModelClient
  element-pointing switch (CompanionManager.swift ~16797)
     .localOpenAICompatible → LocalElementLocationDetector
     .appleFoundation       → .unsupported
  Agent Mode → ClickyCodexConfigTemplate custom-provider block (wire_api="chat" for local)
```

## Component design

### 1. Provider enum & catalog (`OpenClickyModelCatalog.swift`)

Add two cases:

```swift
enum OpenClickyModelProvider: String {
    case anthropic, openAI, codex, deepgram
    case localOpenAICompatible   // Ollama / LM Studio / MLX / llama.cpp / vLLM
    case appleFoundation         // Apple on-device FoundationModels
    var isLocal: Bool { self == .localOpenAICompatible || self == .appleFoundation }
    // displayName: "Local (OpenAI-compatible)", "Apple On-Device"
}
```

Local model ids are dynamic, so they are namespaced when persisted:
- Foundation Models → fixed id `"apple-foundation"`.
- OpenAI-compatible local → `"local:<modelid>"` (e.g. `local:qwen2.5:7b`).

New catalog members:

```swift
static let appleFoundationModelID = "apple-foundation"
static let localModelIDPrefix = "local:"
static func isLocalModelID(_ id: String) -> Bool
static func localModelOption(forID id: String) -> OpenClickyModelOption?  // nil if not namespaced-local
```

`localModelOption(forID:)` synthesizes the option (reading `maxOutputTokens` from the
settings store; Foundation defaults to 4096). The resolvers
`voiceResponseModel(withID:)`, `voiceAnalysisModel(withID:)`, and
`computerUseModel(withID:)` check `localModelOption(forID:)` FIRST, before the existing
`?? voiceResponseModels[0]` cloud fallback — so a local id resolves to a local option
instead of a default cloud model.

### 2. `LocalChatCompletionsAPI.swift` (new)

```swift
struct LocalChatCompletionsAPI {
    let baseURL: URL            // .../v1
    let apiKey: String?         // optional Bearer
    let model: String           // raw id, e.g. "qwen2.5:7b"
    let maxOutputTokens: Int
    func streamResponse(
        systemPrompt: String,
        history: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        images: [(data: Data, label: String)],
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String
}
```

- `POST {baseURL}/chat/completions`, body `{ model, messages, max_tokens, stream: true }`.
- Messages use OpenAI content-parts: text + `{ "type":"image_url", "image_url":{ "url":"data:image/png;base64,…" } }`.
- SSE parse on `choices[0].delta.content` until `data: [DONE]` (URLSession `bytes(for:)`,
  same streaming style as `OpenAIAPI.swift`).
- Auth header only when `apiKey` non-empty.
- Timeouts: request 120s, resource 300s (cold-start model loads). Connection-refused
  (`URLError.cannotConnectToHost` / `.cannotFindHost`) mapped to a dedicated
  "server not running" error.

### 3. `AppleFoundationModelClient.swift` (new)

```swift
#if canImport(FoundationModels)
import FoundationModels
@available(macOS 26.0, *)
struct AppleFoundationModelClient {
    static func isAvailable() -> Bool      // SystemLanguageModel.default.availability == .available
    static func unavailableReason() -> String?
    func streamResponse(
        systemPrompt: String,
        history: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String
}
#endif
```

- `LanguageModelSession(instructions: systemPrompt)`, history folded into the transcript,
  `streamResponse(to: userPrompt)` streamed to `onTextChunk`.
- Text-only; the routing layer drops any images and appends the one-line caveat.
- All call sites guard `#if canImport(FoundationModels)` + `@available`; when the framework
  or model is absent, routing throws an actionable error rather than crashing.

### 4. `LocalModelDiscovery.swift` (new)

```swift
enum LocalModelDiscovery {
    static func listModels(baseURL: URL, apiKey: String?) async throws -> [String]  // GET /models → data[].id
}
```

- 5s timeout. Distinguishes connection-refused from "200 but empty list".

### 5. `LocalElementLocationDetector.swift` (new)

Mirrors `ElementLocationDetector`'s contract:

```swift
struct LocalElementLocationDetector {
    init(baseURL: URL, apiKey: String?, model: String)
    func detectElementLocation(
        screenshotData: Data, userQuestion: String,
        displayWidthInPoints: Double, displayHeightInPoints: Double
    ) async -> DisplayLocalPoint?   // nil on failure, like the Anthropic detector
}
```

- Reuses `LocalChatCompletionsAPI` vision + the same coordinate-extraction prompt/contract
  the Anthropic detector uses. Wired into the element-pointing switch (~16797).

### 6. Settings store + UI

`LocalModelSettingsStore` (small): reads/writes `localModelBaseURL`,
`localModelMaxOutputTokens`, `appleFoundationEnabled` (UserDefaults) and the optional token
(Keychain via `AppBundleConfiguration`). Base URL is not a secret → UserDefaults.

"Local AI" disclosure group in the `CompanionPanelView` settings subscreen:
base URL field (+ reset), optional token secure field, **[Detect models]**, model picker +
manual id field, max-output-tokens field, **[Test]**, Apple On-Device availability/toggle,
"Use local endpoint for Agent Mode" toggle. The existing voice/computer-use pickers gain the
discovered-local and (when available) Foundation entries, persisted as namespaced ids.

### 7. Agent Mode (`ClickyCodexConfigTemplate.swift`)

Reuse the existing `CLICKY_AGENT_BASE_URL` / `clickyAgentBaseURL` mechanism. Add a
wire-format branch: when the configured base URL is local, emit `wire_api = "chat"` in the
`[model_providers.openclicky]` block (the template currently hardcodes `"responses"`, which
Ollama/LM Studio do not serve). Scoped strictly to the local case.

## Routing & money rule

Local providers are inherently **direct** — there is no paid cloud call to protect, so the
"SDK / app-server first, key fallback" ordering does not apply. Document this as a narrow,
explicit exemption in `CLAUDE.md`'s Inference Routing section, alongside the existing
realtime-voice exemption, naming `.localOpenAICompatible` and `.appleFoundation`.

## Error handling

| Condition | Behavior |
|---|---|
| Local server unreachable | Actionable error ("No local model server at `<url>` — is Ollama/LM Studio running?"). No silent cloud fallback. |
| Model not found / vision sent to text-only model | Surface the server's error body with a hint. |
| Foundation unavailable at call time | Error carrying the availability reason; suggest the OpenAI-compatible path. |
| Discovery timeout | Inline message; manual id entry still works. |
| Cold-start slowness | Generous timeouts + one-time "first response may be slow while the model loads" note. |

## Testing

- `swiftc -parse` on every changed/new Swift file (per CLAUDE.md; no terminal `xcodebuild`,
  no TCC disturbance).
- Unit tests (`cursor-buddyTests`):
  - Namespaced-id resolution: `local:foo` → `.localOpenAICompatible`; `apple-foundation`
    → `.appleFoundation`; unknown cloud id still falls back to a cloud default.
  - `LocalModelDiscovery` JSON parse (`{data:[{id}]}`).
  - `LocalChatCompletionsAPI` request-body shape + canned-SSE delta parsing (no network).
  - `AppleFoundationModelClient` test skipped when `!isAvailable()`.
- Manual (Xcode, user-side — a real local server can't run in CI here): voice response,
  pointing, and Agent Mode against a live Ollama/LM Studio. Checklist supplied with the PR.

## Known pre-existing issues (out of scope, flagged not fixed)

- `cursor-buddyTests/ClickyNextStageParityTests.swift:10` asserts the bundle id is
  `com.jkneen.openclicky`, but the working tree renamed the app to `com.openclicky` (an
  unrelated concurrent edit). That test already fails independent of this feature.
- The app-group identifier is inconsistent across entitlements/code (`group.aloes` vs
  `group.com.jkneen.openclicky` vs missing). Unrelated to local AI.

## Files

New: `LocalChatCompletionsAPI.swift`, `AppleFoundationModelClient.swift`,
`LocalModelDiscovery.swift`, `LocalElementLocationDetector.swift`, `LocalModelSettingsStore.swift`,
plus unit tests.
Modified: `OpenClickyModelCatalog.swift`, `CompanionManager.swift` (two switches + two new
analyze functions), `CompanionPanelView.swift` (settings UI), `ClickyCodexConfigTemplate.swift`
(wire-format branch), `CLAUDE.md` (routing doc), and the Xcode project to include new files.
