# Local AI Models Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let OpenClicky run inference on the user's local models — any OpenAI-compatible server (Ollama/LM Studio/MLX/llama.cpp/vLLM) and Apple's on-device Foundation Models — across voice/chat, element pointing, and Agent Mode.

**Architecture:** Two new `OpenClickyModelProvider` cases (`.localOpenAICompatible`, `.appleFoundation`). Local model ids are namespaced (`local:<id>`, `apple-foundation`) and resolved by the catalog into synthesized options before the existing cloud fallback. New dedicated per-provider clients mirror the existing `ClaudeAPI`/`OpenAIAPI` pattern; the billed cloud clients are not modified. Settings gain a "Local AI" group with discovery.

**Tech Stack:** Swift, SwiftUI + AppKit, `URLSession.bytes(for:)` SSE streaming, `FoundationModels` (macOS 26), XCTest.

## Global Constraints

- Do NOT run `xcodebuild` from the terminal. Builds/permission tests happen in Xcode (drive via AppleScript). Verbatim from CLAUDE.md.
- Per-file syntax verification: `swiftc -parse <files>`. Verbatim from CLAUDE.md.
- Do not rename the legacy `cursor-buddy` project folder or scheme.
- No emoji in code or copy unless explicitly requested.
- User-facing copy uses the product name "OpenClicky".
- Money rule: never reorder existing cloud paths to bill per token. New local paths are direct (nothing billed to protect) and must be documented as an exemption.
- Do NOT modify `OpenAIAPI.swift` or `ClaudeAPI.swift`.
- Keep UI state updates on the main actor; async/await for async work.
- New Swift files must be added to the `cursor-buddy` target in `cursor-buddy.xcodeproj`.
- Do not stage the unrelated working-tree edits (`project.pbxproj` team/bundle, `Info.plist`, `*.entitlements`) into feature commits except the specific `project.pbxproj` lines that add new files to the target.

---

### Task 1: Provider enum + namespaced local-id resolution in the catalog

**Files:**
- Modify: `cursor-buddy/OpenClickyModelCatalog.swift` (enum at 3-21; resolvers at 105-147)
- Test: `cursor-buddyTests/LocalModelCatalogTests.swift` (create)

**Interfaces:**
- Produces: `OpenClickyModelProvider.localOpenAICompatible`, `.appleFoundation`; `var isLocal: Bool`; `OpenClickyModelCatalog.appleFoundationModelID = "apple-foundation"`; `OpenClickyModelCatalog.localModelIDPrefix = "local:"`; `static func isLocalModelID(_ id: String) -> Bool`; `static func localModelOption(forID id: String) -> OpenClickyModelOption?`.
- Consumes: `LocalModelSettingsStore.maxOutputTokens` (Task 5) — until Task 5 lands, default to a literal `8192` and replace the read in Task 5.

- [ ] **Step 1: Write the failing test**

```swift
// cursor-buddyTests/LocalModelCatalogTests.swift
import XCTest
@testable import OpenClicky

final class LocalModelCatalogTests: XCTestCase {
    func testFoundationIDResolvesToFoundationProvider() {
        let opt = OpenClickyModelCatalog.localModelOption(forID: "apple-foundation")
        XCTAssertEqual(opt?.provider, .appleFoundation)
        XCTAssertEqual(opt?.id, "apple-foundation")
    }

    func testLocalPrefixResolvesToLocalProviderAndStripsPrefix() {
        let opt = OpenClickyModelCatalog.localModelOption(forID: "local:qwen2.5:7b")
        XCTAssertEqual(opt?.provider, .localOpenAICompatible)
        XCTAssertEqual(opt?.label, "qwen2.5:7b")
        XCTAssertEqual(opt?.id, "local:qwen2.5:7b")
    }

    func testCloudIDIsNotLocal() {
        XCTAssertNil(OpenClickyModelCatalog.localModelOption(forID: "claude-haiku-4-5"))
        XCTAssertFalse(OpenClickyModelCatalog.isLocalModelID("gpt-5.5"))
    }

    func testVoiceResolverReturnsLocalOptionInsteadOfCloudFallback() {
        let opt = OpenClickyModelCatalog.voiceResponseModel(withID: "local:llama3.1")
        XCTAssertEqual(opt.provider, .localOpenAICompatible)
    }
}
```

- [ ] **Step 2: Verify it fails (Xcode test run at checkpoint, or note the symbols are undefined)**

Run: `swiftc -parse cursor-buddy/OpenClickyModelCatalog.swift cursor-buddyTests/LocalModelCatalogTests.swift`
Expected: FAIL — `localModelOption`, `.appleFoundation`, `.localOpenAICompatible`, `isLocalModelID` undefined.

- [ ] **Step 3: Add enum cases + isLocal**

In the enum (after `case deepgram`):
```swift
    case localOpenAICompatible
    case appleFoundation
```
Add to `displayName`'s switch:
```swift
        case .localOpenAICompatible:
            return "Local (OpenAI-compatible)"
        case .appleFoundation:
            return "Apple On-Device"
```
Add below the cases:
```swift
    var isLocal: Bool { self == .localOpenAICompatible || self == .appleFoundation }
```

- [ ] **Step 4: Add catalog resolution**

Inside `enum OpenClickyModelCatalog`, near the top:
```swift
    static let appleFoundationModelID = "apple-foundation"
    static let localModelIDPrefix = "local:"
    static let appleFoundationLabel = "Apple On-Device"

    static func isLocalModelID(_ id: String) -> Bool {
        id == appleFoundationModelID || id.hasPrefix(localModelIDPrefix)
    }

    /// Synthesizes an option for a namespaced local id; nil for cloud ids.
    static func localModelOption(forID id: String) -> OpenClickyModelOption? {
        if id == appleFoundationModelID {
            return OpenClickyModelOption(id: id, label: appleFoundationLabel, provider: .appleFoundation, maxOutputTokens: 4_096)
        }
        if id.hasPrefix(localModelIDPrefix) {
            let raw = String(id.dropFirst(localModelIDPrefix.count))
            return OpenClickyModelOption(id: id, label: raw, provider: .localOpenAICompatible, maxOutputTokens: 8_192)
        }
        return nil
    }
```
Add a local short-circuit to the THREE routing resolvers (first line of each body), `voiceResponseModel(withID:)`, `voiceAnalysisModel(withID:)`, `computerUseModel(withID:)`:
```swift
        if let local = localModelOption(forID: modelID) { return local }
```
(For `voiceAnalysisModel(withID modelID: String?)`, guard the optional: `if let modelID, let local = localModelOption(forID: modelID) { return local }`.)

- [ ] **Step 5: Verify parse + commit**

Run: `swiftc -parse cursor-buddy/OpenClickyModelCatalog.swift`
Expected: no errors.
```bash
git add cursor-buddy/OpenClickyModelCatalog.swift cursor-buddyTests/LocalModelCatalogTests.swift
git commit -m "feat(local-ai): add local provider cases + namespaced id resolution"
```

---

### Task 2: `LocalModelDiscovery` — GET /models probe

**Files:**
- Create: `cursor-buddy/LocalModelDiscovery.swift`
- Test: `cursor-buddyTests/LocalModelDiscoveryTests.swift`

**Interfaces:**
- Produces: `enum LocalModelDiscovery { static func parseModelList(_ data: Data) throws -> [String]; static func listModels(baseURL: URL, apiKey: String?) async throws -> [String] }`; `enum LocalModelError: Error { case serverUnreachable(URL); case badResponse(Int, String); case emptyList }`.

- [ ] **Step 1: Failing test for the pure parser**

```swift
// cursor-buddyTests/LocalModelDiscoveryTests.swift
import XCTest
@testable import OpenClicky

final class LocalModelDiscoveryTests: XCTestCase {
    func testParsesOpenAIModelList() throws {
        let json = Data("""
        {"object":"list","data":[{"id":"qwen2.5:7b","object":"model"},{"id":"llava","object":"model"}]}
        """.utf8)
        XCTAssertEqual(try LocalModelDiscovery.parseModelList(json), ["qwen2.5:7b", "llava"])
    }

    func testEmptyListThrows() {
        let json = Data(#"{"object":"list","data":[]}"#.utf8)
        XCTAssertThrowsError(try LocalModelDiscovery.parseModelList(json))
    }
}
```

- [ ] **Step 2: Verify fail**

Run: `swiftc -parse cursor-buddy/LocalModelDiscovery.swift cursor-buddyTests/LocalModelDiscoveryTests.swift`
Expected: FAIL — file/symbols missing.

- [ ] **Step 3: Implement**

```swift
// cursor-buddy/LocalModelDiscovery.swift
import Foundation

enum LocalModelError: LocalizedError {
    case serverUnreachable(URL)
    case badResponse(Int, String)
    case emptyList

    var errorDescription: String? {
        switch self {
        case .serverUnreachable(let url):
            return "No local model server reachable at \(url.absoluteString). Is Ollama or LM Studio running?"
        case .badResponse(let code, let body):
            return "Local model server returned \(code): \(body)"
        case .emptyList:
            return "The local model server is reachable but reported no installed models."
        }
    }
}

enum LocalModelDiscovery {
    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

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
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost || error.code == .timedOut {
            throw LocalModelError.serverUnreachable(baseURL)
        }
    }
}
```

- [ ] **Step 4: Verify parse + commit**

Run: `swiftc -parse cursor-buddy/LocalModelDiscovery.swift`
Expected: no errors.
```bash
git add cursor-buddy/LocalModelDiscovery.swift cursor-buddyTests/LocalModelDiscoveryTests.swift
git commit -m "feat(local-ai): add LocalModelDiscovery /models probe"
```

---

### Task 3: `LocalChatCompletionsAPI` — streaming chat/completions client

**Files:**
- Create: `cursor-buddy/LocalChatCompletionsAPI.swift`
- Test: `cursor-buddyTests/LocalChatCompletionsAPITests.swift`

**Interfaces:**
- Consumes: `LocalModelError` (Task 2).
- Produces: `struct LocalChatCompletionsAPI { init(baseURL: URL, apiKey: String?, model: String, maxOutputTokens: Int); func streamResponse(systemPrompt: String, history: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String, images: [(data: Data, label: String)], onTextChunk: @MainActor @Sendable @escaping (String) -> Void) async throws -> String }`; `static func deltaContent(fromSSELine line: String) -> String?` (pure, testable); `static func requestBody(model:, maxOutputTokens:, messages:) -> [String: Any]`.

- [ ] **Step 1: Failing test for SSE delta extraction (pure)**

```swift
// cursor-buddyTests/LocalChatCompletionsAPITests.swift
import XCTest
@testable import OpenClicky

final class LocalChatCompletionsAPITests: XCTestCase {
    func testExtractsDeltaContent() {
        let line = #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#
        XCTAssertEqual(LocalChatCompletionsAPI.deltaContent(fromSSELine: line), "Hel")
    }
    func testDoneLineReturnsNil() {
        XCTAssertNil(LocalChatCompletionsAPI.deltaContent(fromSSELine: "data: [DONE]"))
    }
    func testNonDataLineReturnsNil() {
        XCTAssertNil(LocalChatCompletionsAPI.deltaContent(fromSSELine: ": keep-alive"))
    }
}
```

- [ ] **Step 2: Verify fail**

Run: `swiftc -parse cursor-buddy/LocalChatCompletionsAPI.swift cursor-buddyTests/LocalChatCompletionsAPITests.swift`
Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
// cursor-buddy/LocalChatCompletionsAPI.swift
import Foundation

struct LocalChatCompletionsAPI {
    let baseURL: URL
    let apiKey: String?
    let model: String
    let maxOutputTokens: Int

    init(baseURL: URL, apiKey: String?, model: String, maxOutputTokens: Int) {
        self.baseURL = baseURL
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    /// Extracts the streamed token from one SSE line, or nil for [DONE]/keep-alive/non-data.
    static func deltaContent(fromSSELine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        return content
    }

    static func requestBody(model: String, maxOutputTokens: Int, messages: [[String: Any]]) -> [String: Any] {
        ["model": model, "max_tokens": maxOutputTokens, "stream": true, "messages": messages]
    }

    private func buildMessages(systemPrompt: String,
                               history: [(userPlaceholder: String, assistantResponse: String)],
                               userPrompt: String,
                               images: [(data: Data, label: String)]) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for turn in history {
            messages.append(["role": "user", "content": turn.userPlaceholder])
            messages.append(["role": "assistant", "content": turn.assistantResponse])
        }
        var parts: [[String: Any]] = [["type": "text", "text": userPrompt]]
        for image in images {
            let b64 = image.data.base64EncodedString()
            parts.append(["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b64)"]])
        }
        // If no images, send plain string content for maximum server compatibility.
        if images.isEmpty {
            messages.append(["role": "user", "content": userPrompt])
        } else {
            messages.append(["role": "user", "content": parts])
        }
        return messages
    }

    func streamResponse(systemPrompt: String,
                        history: [(userPlaceholder: String, assistantResponse: String)],
                        userPrompt: String,
                        images: [(data: Data, label: String)],
                        onTextChunk: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let messages = buildMessages(systemPrompt: systemPrompt, history: history, userPrompt: userPrompt, images: images)
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(model: model, maxOutputTokens: maxOutputTokens, messages: messages))

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw LocalModelError.serverUnreachable(baseURL) }
            guard http.statusCode == 200 else {
                var body = ""
                for try await line in bytes.lines { body += line }
                throw LocalModelError.badResponse(http.statusCode, body)
            }
            var full = ""
            for try await line in bytes.lines {
                if let chunk = Self.deltaContent(fromSSELine: line) {
                    full += chunk
                    let piece = chunk
                    await MainActor.run { onTextChunk(piece) }
                }
            }
            return full
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
            throw LocalModelError.serverUnreachable(baseURL)
        }
    }
}
```

- [ ] **Step 4: Verify parse + commit**

Run: `swiftc -parse cursor-buddy/LocalChatCompletionsAPI.swift`
Expected: no errors.
```bash
git add cursor-buddy/LocalChatCompletionsAPI.swift cursor-buddyTests/LocalChatCompletionsAPITests.swift
git commit -m "feat(local-ai): add streaming LocalChatCompletionsAPI client"
```

---

### Task 4: `AppleFoundationModelClient` — on-device text

**Files:**
- Create: `cursor-buddy/AppleFoundationModelClient.swift`
- Test: `cursor-buddyTests/AppleFoundationModelClientTests.swift`

**Interfaces:**
- Produces: `enum AppleFoundationModelAvailability { static func isAvailable() -> Bool; static func unavailableReason() -> String? }`; `struct AppleFoundationModelClient { func streamResponse(systemPrompt:, history:, userPrompt:, onTextChunk:) async throws -> String }`; `enum AppleFoundationError: Error { case unavailable(String) }`.

- [ ] **Step 1: Failing test (availability gate only — generation needs the device)**

```swift
// cursor-buddyTests/AppleFoundationModelClientTests.swift
import XCTest
@testable import OpenClicky

final class AppleFoundationModelClientTests: XCTestCase {
    func testAvailabilityQueryDoesNotCrash() {
        // Returns a Bool on any host; on CI without Apple Intelligence it is false.
        _ = AppleFoundationModelAvailability.isAvailable()
    }
    func testUnavailableReasonNilWhenAvailable() {
        if AppleFoundationModelAvailability.isAvailable() {
            XCTAssertNil(AppleFoundationModelAvailability.unavailableReason())
        }
    }
}
```

- [ ] **Step 2: Verify fail**

Run: `swiftc -parse cursor-buddy/AppleFoundationModelClient.swift cursor-buddyTests/AppleFoundationModelClientTests.swift`
Expected: FAIL.

- [ ] **Step 3: Implement (all framework use behind canImport + @available)**

```swift
// cursor-buddy/AppleFoundationModelClient.swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleFoundationError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let why): return "Apple on-device model unavailable: \(why)" }
    }
}

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
            case .available: return nil
            case .unavailable(let reason): return String(describing: reason)
            @unknown default: return "unknown"
            }
        }
        return "Requires macOS 26 or later."
        #else
        return "FoundationModels framework not available in this build."
        #endif
    }
}

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
            for turn in history { prompt += "User: \(turn.userPlaceholder)\nAssistant: \(turn.assistantResponse)\n" }
            prompt += userPrompt
            var full = ""
            let stream = session.streamResponse(to: prompt)
            for try await partial in stream {
                let snapshot = String(describing: partial)
                let delta = String(snapshot.dropFirst(full.count))
                if !delta.isEmpty {
                    full = snapshot
                    let piece = delta
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
```

> NOTE during execution: `LanguageModelSession.streamResponse(to:)`'s element type is an API detail to confirm against the installed SDK in Xcode. If partials are cumulative snapshots, the `dropFirst(full.count)` delta logic above holds; if they are already deltas, append directly. Adjust at the Xcode build checkpoint and keep the `onTextChunk` contract (emit deltas).

- [ ] **Step 4: Verify parse + commit**

Run: `swiftc -parse cursor-buddy/AppleFoundationModelClient.swift`
Expected: no errors (FoundationModels may be absent to `swiftc`; the `#else` keeps it compiling).
```bash
git add cursor-buddy/AppleFoundationModelClient.swift cursor-buddyTests/AppleFoundationModelClientTests.swift
git commit -m "feat(local-ai): add AppleFoundationModelClient (on-device, text-only)"
```

---

### Task 5: `LocalModelSettingsStore` — config persistence

**Files:**
- Create: `cursor-buddy/LocalModelSettingsStore.swift`
- Modify: `cursor-buddy/OpenClickyModelCatalog.swift` (replace the literal `8_192` in `localModelOption` with `LocalModelSettingsStore.maxOutputTokens`)
- Test: `cursor-buddyTests/LocalModelSettingsStoreTests.swift`

**Interfaces:**
- Produces: `enum LocalModelSettingsStore { static var baseURL: URL; static var baseURLString: String (get/set); static var maxOutputTokens: Int (get/set); static var appleFoundationEnabled: Bool (get/set); static var token: String? (get/set, Keychain); static let defaultBaseURLString = "http://localhost:11434/v1" }`.

- [ ] **Step 1: Failing test**

```swift
// cursor-buddyTests/LocalModelSettingsStoreTests.swift
import XCTest
@testable import OpenClicky

final class LocalModelSettingsStoreTests: XCTestCase {
    func testDefaultBaseURL() {
        UserDefaults.standard.removeObject(forKey: "localModelBaseURL")
        XCTAssertEqual(LocalModelSettingsStore.baseURLString, "http://localhost:11434/v1")
    }
    func testRoundTripsMaxTokens() {
        LocalModelSettingsStore.maxOutputTokens = 4096
        XCTAssertEqual(LocalModelSettingsStore.maxOutputTokens, 4096)
    }
}
```

- [ ] **Step 2: Verify fail**

Run: `swiftc -parse cursor-buddy/LocalModelSettingsStore.swift cursor-buddyTests/LocalModelSettingsStoreTests.swift`
Expected: FAIL.

- [ ] **Step 3: Implement (token reuses AppBundleConfiguration keychain helpers)**

```swift
// cursor-buddy/LocalModelSettingsStore.swift
import Foundation

enum LocalModelSettingsStore {
    static let defaultBaseURLString = "http://localhost:11434/v1"
    private static let baseURLKey = "localModelBaseURL"
    private static let maxTokensKey = "localModelMaxOutputTokens"
    private static let foundationEnabledKey = "appleFoundationEnabled"
    private static let tokenKey = "localModelToken"

    static var baseURLString: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURLString }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    static var baseURL: URL {
        URL(string: baseURLString) ?? URL(string: defaultBaseURLString)!
    }

    static var maxOutputTokens: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: maxTokensKey)
            return v > 0 ? v : 8_192
        }
        set { UserDefaults.standard.set(newValue, forKey: maxTokensKey) }
    }

    static var appleFoundationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: foundationEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: foundationEnabledKey) }
    }

    static var token: String? {
        get { AppBundleConfiguration.secret(forKey: tokenKey) }
        set { AppBundleConfiguration.setSecret(newValue, forKey: tokenKey) }
    }
}
```

> During execution: confirm the exact keychain accessor names in `AppBundleConfiguration.swift` (the explorer noted a keychain-backed store with service `com.jkneen.openclicky.secrets`). If a generic `secret(forKey:)`/`setSecret(_:forKey:)` does not exist, add a minimal pair there or register `localModelToken` in the existing `keychainBackedDefaultsKeys` set and use the existing read/write path. Pick whichever matches the established pattern; do not invent a second keychain mechanism.

- [ ] **Step 4: Wire catalog to the store**

In `OpenClickyModelCatalog.localModelOption`, replace `maxOutputTokens: 8_192` with `maxOutputTokens: LocalModelSettingsStore.maxOutputTokens`.

- [ ] **Step 5: Verify parse + commit**

Run: `swiftc -parse cursor-buddy/LocalModelSettingsStore.swift cursor-buddy/OpenClickyModelCatalog.swift`
Expected: no errors.
```bash
git add cursor-buddy/LocalModelSettingsStore.swift cursor-buddy/OpenClickyModelCatalog.swift cursor-buddyTests/LocalModelSettingsStoreTests.swift
git commit -m "feat(local-ai): add LocalModelSettingsStore + wire catalog max tokens"
```

---

### Task 6: Route voice/chat responses to the local clients

**Files:**
- Modify: `cursor-buddy/CompanionManager.swift` (the `analyzeVoiceResponse` provider switch ~16279-16333; add two private analyze functions near `analyzeClaudeResponse` ~16335)

**Interfaces:**
- Consumes: `LocalChatCompletionsAPI` (Task 3), `AppleFoundationModelClient` + `AppleFoundationModelAvailability` (Task 4), `LocalModelSettingsStore` (Task 5), `selectedVoiceResponseModel` (existing).
- Produces: `analyzeLocalChatResponse(...)`, `analyzeAppleFoundationResponse(...)` returning `String`.

- [ ] **Step 1: Add the two switch cases**

In the `switch selectedVoiceResponseModel.provider` block, before the closing brace, add:
```swift
    case .localOpenAICompatible:
        return try await analyzeLocalChatResponse(
            images: images, model: selectedVoiceResponseModel,
            systemPrompt: systemPrompt, conversationHistory: conversationHistory,
            userPrompt: userPrompt, onTextChunk: onTextChunk)
    case .appleFoundation:
        return try await analyzeAppleFoundationResponse(
            images: images, systemPrompt: systemPrompt,
            conversationHistory: conversationHistory, userPrompt: userPrompt,
            onTextChunk: onTextChunk)
```

- [ ] **Step 2: Add the analyze functions**

```swift
private func analyzeLocalChatResponse(
    images: [(data: Data, label: String)],
    model: OpenClickyModelOption,
    systemPrompt: String,
    conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
    userPrompt: String,
    onTextChunk: @MainActor @Sendable @escaping (String) -> Void
) async throws -> String {
    let rawModel = String(model.id.dropFirst(OpenClickyModelCatalog.localModelIDPrefix.count))
    let api = LocalChatCompletionsAPI(
        baseURL: LocalModelSettingsStore.baseURL,
        apiKey: LocalModelSettingsStore.token,
        model: rawModel,
        maxOutputTokens: model.maxOutputTokens)
    return try await api.streamResponse(
        systemPrompt: systemPrompt, history: conversationHistory,
        userPrompt: userPrompt, images: images, onTextChunk: onTextChunk)
}

private func analyzeAppleFoundationResponse(
    images: [(data: Data, label: String)],
    systemPrompt: String,
    conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
    userPrompt: String,
    onTextChunk: @MainActor @Sendable @escaping (String) -> Void
) async throws -> String {
    let client = AppleFoundationModelClient()
    var result = try await client.streamResponse(
        systemPrompt: systemPrompt, history: conversationHistory,
        userPrompt: userPrompt, onTextChunk: onTextChunk)
    if !images.isEmpty {
        let note = "\n\n(Note: the on-device model can't see your screen.)"
        await MainActor.run { onTextChunk(note) }
        result += note
    }
    return result
}
```

- [ ] **Step 3: Verify parse + commit**

Run: `swiftc -parse cursor-buddy/CompanionManager.swift cursor-buddy/OpenClickyModelCatalog.swift cursor-buddy/LocalChatCompletionsAPI.swift cursor-buddy/AppleFoundationModelClient.swift cursor-buddy/LocalModelSettingsStore.swift cursor-buddy/LocalModelDiscovery.swift`
Expected: no errors.
```bash
git add cursor-buddy/CompanionManager.swift
git commit -m "feat(local-ai): route voice/chat responses to local + on-device clients"
```

---

### Task 7: `LocalElementLocationDetector` + element-pointing route

**Files:**
- Create: `cursor-buddy/LocalElementLocationDetector.swift`
- Modify: `cursor-buddy/CompanionManager.swift` (element-pointing provider switch ~16797 and the detector-dispatch block ~16829-16849)

**Interfaces:**
- Consumes: `LocalChatCompletionsAPI` (Task 3); the existing `DisplayLocalPoint` type and the prompt/parse used by `ElementLocationDetector`.
- Produces: `struct LocalElementLocationDetector { init(baseURL: URL, apiKey: String?, model: String); func detectElementLocation(screenshotData: Data, userQuestion: String, displayWidthInPoints: Double, displayHeightInPoints: Double) async -> <same return type as ElementLocationDetector.detectElementLocation> }`.

- [ ] **Step 1: Read `ElementLocationDetector.swift` for the exact prompt, response JSON, coordinate scaling, and return type. Mirror them.** (No new test for coordinate math beyond reuse; add a parse test if the JSON parser is extracted.)

- [ ] **Step 2: Implement** the detector calling `LocalChatCompletionsAPI.streamResponse` with `images: [(screenshotData, "screen")]`, the identical system/user prompt `ElementLocationDetector` uses, accumulate the streamed text, then run the SAME coordinate-extraction/parse + scaling code. Return the same type; return nil on any failure.

```swift
// cursor-buddy/LocalElementLocationDetector.swift — skeleton; fill prompt/parse from ElementLocationDetector
import Foundation

struct LocalElementLocationDetector {
    let baseURL: URL
    let apiKey: String?
    let model: String

    func detectElementLocation(screenshotData: Data,
                               userQuestion: String,
                               displayWidthInPoints: Double,
                               displayHeightInPoints: Double) async -> /* DisplayLocalPoint? per ElementLocationDetector */ Any? {
        let api = LocalChatCompletionsAPI(baseURL: baseURL, apiKey: apiKey, model: model, maxOutputTokens: 1024)
        do {
            let text = try await api.streamResponse(
                systemPrompt: /* copy from ElementLocationDetector */ "",
                history: [],
                userPrompt: /* copy from ElementLocationDetector, incl. width/height + userQuestion */ userQuestion,
                images: [(data: screenshotData, label: "screen")],
                onTextChunk: { _ in })
            // parse `text` into coordinates exactly as ElementLocationDetector does, then scale.
            return nil // replace with parsed DisplayLocalPoint
        } catch {
            return nil
        }
    }
}
```

- [ ] **Step 3: Add the route.** In the element-pointing provider switch add `case .localOpenAICompatible: return .localOpenAICompatible` (extend the backend enum used there) and `case .appleFoundation: return .unsupported`. In the dispatch block, add a branch that constructs `LocalElementLocationDetector(baseURL: LocalModelSettingsStore.baseURL, apiKey: LocalModelSettingsStore.token, model: rawModelID)` and assigns `displayLocalLocation`.

- [ ] **Step 4: Verify parse + commit**

Run: `swiftc -parse cursor-buddy/LocalElementLocationDetector.swift cursor-buddy/CompanionManager.swift`
Expected: no errors.
```bash
git add cursor-buddy/LocalElementLocationDetector.swift cursor-buddy/CompanionManager.swift
git commit -m "feat(local-ai): local vision element-pointing"
```

---

### Task 8: Settings UI — "Local AI" group

**Files:**
- Modify: `cursor-buddy/CompanionPanelView.swift` (settings subscreen)

**Interfaces:**
- Consumes: `LocalModelSettingsStore`, `LocalModelDiscovery`, `AppleFoundationModelAvailability`, `OpenClickyModelCatalog.localModelIDPrefix`/`appleFoundationModelID`, the existing model-picker binding (`selectedModel` / `selectedVoiceResponseModel`).

- [ ] **Step 1: Add a "Local AI" `DisclosureGroup`/`Section`** with: base URL `TextField` (default + reset button), optional token `SecureField`, "Detect models" button (calls `LocalModelDiscovery.listModels` in a `Task`, stores results in a `@State [String]`, surfaces errors to a `@State String?`), a `Picker` over discovered ids + a manual-id `TextField`, a max-output-tokens `TextField`, a "Test" button (one short `LocalChatCompletionsAPI` call), an Apple On-Device row (shows `AppleFoundationModelAvailability` status; `Toggle` bound to `LocalModelSettingsStore.appleFoundationEnabled`, disabled when unavailable), and a "Use local endpoint for Agent Mode" `Toggle` that writes `clickyAgentBaseURL`.
- [ ] **Step 2: Compose model selections.** Where the voice/computer-use pickers list cloud models, append discovered local ids as `"local:<id>"` options (label = raw id) and, when `appleFoundationEnabled && isAvailable`, the `"apple-foundation"` option. Persist selection through the existing binding. Keep all updates on the main actor.
- [ ] **Step 3: Verify parse + commit**

Run: `swiftc -parse cursor-buddy/CompanionPanelView.swift`
Expected: no errors.
```bash
git add cursor-buddy/CompanionPanelView.swift
git commit -m "feat(local-ai): settings UI for local endpoint, discovery, on-device toggle"
```

---

### Task 9: Agent Mode wire-format branch

**Files:**
- Modify: `cursor-buddy/ClickyCodexConfigTemplate.swift` (custom-provider block ~72-84)

**Interfaces:**
- Consumes: existing `configuredWorkerBaseURL()` / `clickyAgentBaseURL` / `CLICKY_AGENT_BASE_URL`.

- [ ] **Step 1:** Add a helper `isLocalBaseURL(_ url: URL) -> Bool` (host is `localhost`/`127.0.0.1`/`::1`, or port 11434/1234). In the `[model_providers.openclicky]` block emit `wire_api = "chat"` when `isLocalBaseURL` is true, else keep `"responses"`.
- [ ] **Step 2: Verify parse + commit**

Run: `swiftc -parse cursor-buddy/ClickyCodexConfigTemplate.swift`
Expected: no errors.
```bash
git add cursor-buddy/ClickyCodexConfigTemplate.swift
git commit -m "feat(local-ai): Agent Mode uses chat wire format for local endpoints"
```

---

### Task 10: Register new files in the Xcode target + CLAUDE.md routing doc

**Files:**
- Modify: `cursor-buddy.xcodeproj/project.pbxproj` (add the 6 new `cursor-buddy/*.swift` to the `cursor-buddy` target; add the 5 new test files to the test target)
- Modify: `CLAUDE.md` (Inference Routing section)

- [ ] **Step 1:** Add new sources to the project. Prefer doing this **in Xcode** (File > Add Files, ensure `cursor-buddy` target membership for app files and the test target for test files) to get correct `PBXBuildFile`/`PBXFileReference`/`PBXGroup`/`PBXSourcesBuildPhase` entries. (Hand-editing pbxproj is error-prone and another agent is editing this file; coordinate / re-verify hashes before staging only these added lines.)
- [ ] **Step 2:** Append to `CLAUDE.md` Inference Routing, after the realtime exemption:

```
   - `.localOpenAICompatible` -> LocalChatCompletionsAPI (Ollama/LM Studio/MLX/llama.cpp); `.appleFoundation` -> AppleFoundationModelClient (on-device, text-only). Local providers are DIRECT by design: there is no paid cloud call to protect, so the SDK/app-server-first ordering does not apply. An explicitly-selected local model must never silently fall back to a billed cloud model.
```

- [ ] **Step 3: Build in Xcode** (AppleScript, not terminal `xcodebuild`) on the `cursor-buddy` scheme; resolve any compile errors. Then run the unit tests in Xcode (Product > Test).
- [ ] **Step 4: Commit**

```bash
git add cursor-buddy.xcodeproj/project.pbxproj CLAUDE.md
git commit -m "build(local-ai): add new sources to target; document local routing"
```

---

### Task 11: Integration verification

- [ ] **Step 1:** Build + run in Xcode (AppleScript). Confirm the app launches (menu-bar item) with no regression.
- [ ] **Step 2 (user-side, documented in PR):** With Ollama running (`ollama serve`, a model pulled), open Settings > Local AI, Detect models, pick one, ask Clicky a question (voice/chat), try element pointing with a vision model, and try Agent Mode pointed at the local endpoint. With Apple Intelligence available, toggle Apple On-Device and confirm a text reply. (A live local server cannot run in this environment; this step is the human acceptance checklist.)
- [ ] **Step 3:** Open a PR with the checklist and the known-pre-existing-issues note (bundle-id test, app-group inconsistency).

## Self-Review

- **Spec coverage:** providers (T1), discovery (T2), OpenAI-compatible client (T3), Foundation client (T4), settings/storage (T5, T8), voice routing (T6), pointing (T7), Agent Mode (T9), CLAUDE.md + target wiring (T10), error handling (woven through T2/T3/T4/T6), testing (T1-T5 unit + T11 manual). All spec sections map to a task.
- **Placeholder note:** T7's detector body intentionally defers the exact prompt/parse to `ElementLocationDetector` (read-and-mirror) because duplicating an unread prompt verbatim would be guesswork; the step says exactly what to copy and from where. T4 flags the one SDK detail to confirm in Xcode. These are execution-time reads, not vague TODOs.
- **Type consistency:** `localModelIDPrefix`, `appleFoundationModelID`, `LocalModelError`, `LocalModelSettingsStore.{baseURL,token,maxOutputTokens}`, `AppleFoundationModelAvailability.isAvailable()`, `LocalChatCompletionsAPI.streamResponse` signatures match across T1-T8.
