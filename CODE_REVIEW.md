# OpenClicky — End-to-End Code Review

**Scope:** full codebase, 84,548 lines across 121 Swift files (95 in `cursor-buddy/`, 5 local SwiftPM packages, widget extension, tests).
**Method:** 6 parallel deep-review agents (lifecycle/state, inference/API, UI/windows, packages, computer-use/control, security/tests/build) + orchestrator synthesis. Every finding cites verified `file:line`.
**Mode:** read-only — no source files were edited.
**Status of prior review:** the prior `OPENCLICKY_ARCHITECTURE_REVIEW.md` focused on provider routing + computer-use wiring. Its #1 P0 (dishonest click selector) is **verified fixed**. This review covers the rest end-to-end and finds the dominant new liabilities are **security (browser agent + BCU HTTP) and the god-object structure**.

---

## Executive summary

OpenClicky is a large, ambitious, mostly-well-engineered macOS menu-bar AI companion. The plumbing is generally sound: window/panel lifecycle, accessibility-aware animation, money-rule routing on the main voice branch, secret redaction in logs, and a correct external-control auth model. The problems cluster in five areas:

1. **Two critical security surfaces** — an autonomous browser agent that exposes arbitrary-JS execution plus wholesale Chrome-cookie import into the same store, and a background computer-use HTTP server with **no authentication** that holds Accessibility trust. Either is a real trust-boundary breach; together they are the most important thing to fix.
2. **The money rule is bypassed in two places** (agent title generation; the browser agent's own runner) — direct Claude REST where the SDK should be primary. Costs real money on every invocation.
3. **`CompanionManager.swift` is 18,502 lines** — a single `@MainActor` class owning voice routing, CUA, agents, onboarding, external control, and persistence. The file already shows extraction seams; the work just hasn't been done.
4. **Latent concurrency hazards everywhere** because the project ships on `SWIFT_VERSION = 5.0` with no strict concurrency — every `@unchecked Sendable` + unsynchronised-`var` is a live data race the compiler doesn't catch.
5. **No CI and modest test coverage** (101 `@Test` functions for 84.5k LOC, concentrated in config/parsing) — the routing cascade, money-rule ordering, coordinate math, and persistence have no automated guard.

There are also genuine strengths worth preserving: secret redaction is thorough, no secret has ever been committed, notarization hygiene is correct, the markdown viewer avoids the WKWebView XSS trap, and the external-control bridge is fail-closed with constant-time token comparison.

---

## Critical (4 findings)

These are trust-boundary breaches or definite-cost bugs. Fix before shipping the affected features.

### C1. Browser agent `evaluate` = arbitrary JS on untrusted pages, no sandbox/allow-list/confirm
**Files:** `Packages/OCBrowser/.../OpenClickyBrowserAgent.swift:268-296` (tool), `:798-810` (`executeEvaluate`), `:847-869` (`evaluateJavaScript`); system prompt at `:295-300`.
The autonomous agent hands Claude an `evaluate` tool whose body is literally `webView.evaluateJavaScript(script)` on whatever page is loaded. Page content is injected verbatim into the same conversation as the trusted system prompt. A single malicious page → injected instruction → `evaluate` with attacker JS → exfiltrate `document.cookie`/`localStorage` or, after `navigate("file://…")`, read local files. `file://` navigation is explicitly accepted (`:744`). Combined with C2 this is a full session-hijack + local-file-read chain.
**Fix:** remove the unrestricted `evaluate`, or gate every call behind a user-confirmation dialog showing the script + origin; enforce a navigation allow-list in `WKNavigationDelegate.decidePolicyFor` (currently **no** navigation policy exists at all); never run the agent on a `WKWebsiteDataStore` that holds imported cookies.

### C2. Wholesale Chrome cookie import into the shared default `WKWebsiteDataStore`
**Files:** `Packages/OCBrowser/.../BrowserWorkspace.swift:1870-1889` (`importChromeCookies(.all)`), `:3008-3034` (decrypt → `WKWebsiteDataStore.default().httpCookieStore`), `:3134-3165` (Keychain `chromeSafeStoragePassword` → AES-CBC decrypt of v10/v11 cookies).
Reads the Chrome Safe Storage secret from Keychain, decrypts **every** Chrome cookie (banking, email, SaaS — `.all` scope, `matchingHost: nil`), and writes them into the *default* data store — the same store every workspace `WKWebView` uses (`:3380-3385`, no per-task store). Reachable by C1's `evaluate`. Cookie-domain matching is also inverted (`:3198-3202` matches a `mail.example.com` cookie when the page is `example.com`).
**Fix:** use a dedicated per-task `WKWebsiteDataStore` (never `.default()`); drop the `.all` scope; import only the active host with user confirmation; fix `matches()` to standard cookie-domain semantics; never combine with an unrestricted `evaluate`.

### C3. Background Computer Use HTTP server has no authentication and is an invisible AX-trusted input surface
**Files:** BCU binary `AppResources/OpenClicky/BackgroundComputerUseRuntime/…/BackgroundComputerUse` (no `authorization`/`token`/`bearer` symbols); client `OpenClickyComputerUseRuntime.swift:518-540` (`postJSON` sends `Content-Type` only); routes `/v1/click`, `/v1/scroll`, `/v1/drag`, `/v1/type_text`, `/v1/press_key` confirmed in-binary; port published to `$TMPDIR/background-computer-use/runtime-manifest.json` (`:578-606`).
BCU holds Accessibility trust (granted per code-signing identity, not per user) and exists specifically to synthesize **invisible** clicks/keys to any window. Any same-user process that can read the manifest can POST `/v1/type_text` into password/2FA fields and System Settings security panes. Notably OpenClicky's *own* external-control bridge requires a token (see Praise) — BCU does not, so the more dangerous surface is the less protected one.
**Fix:** generate a random token at spawn, pass via env/arg/0600 file, require `Authorization: Bearer <token>` constant-time on every route; or bind to a 0700 Unix-domain socket and verify peer euid. Drop `debug: true` from production requests (`OpenClickyComputerUseRuntime.swift:362, 404, 441`).

### C4. Codex voice + point detector run `danger-full-access` + `approval_policy="never"` on untrusted screenshots/speech
**Files:** `CodexVoiceSession.swift:214-222, 288-292`; `CodexProcessManager.swift:32-34`; `CodexPointDetector.swift:139-151` (`--sandbox danger-full-access` + `--dangerously-bypass-approvals-and-sandbox`); rendered into `config.toml` at `ClickyCodexConfigTemplate.swift:55-58`.
Every Codex path launches at maximum privilege with no human-in-the-loop. The voice session ingests transcribed speech + full-screen screenshots (arbitrary web pages, including adversarial "ignore previous instructions…" text). The point detector's only job is to return `[POINT:x,y]`, yet it can execute arbitrary shell against the full filesystem. `hide_full_access_warning = true` silences Codex's own safety notice. Classic indirect prompt-injection → arbitrary-command-execution.
**Fix:** match privilege to job — `read-only`/`workspace-write` sandbox pinned to the temp dir; drop `--dangerously-bypass-approvals-and-sandbox`; set `approval_policy="on-failure"` or `"on-request"` at minimum. Never combine `danger-full-access` with `approval_policy="never"` on a path consuming screen/speech content.

---

## High (15 findings)

### Money rule (2)

**H1. Agent-Mode task titles call direct Claude REST, skipping the SDK** — `CodexAgentSession.swift:1708-1730`: `fastFriendlyTitle` constructs a fresh `ClaudeAPI(apiKey:model:"claude-haiku-4-5")` and calls `analyzeImage` over HTTPS, never consulting `claudeAgentSDKAPI`. Direct REST bills per token; runs on every agent-task creation. **Fix:** route SDK-first (`analyzeImageStreaming`), fall back to HTTP only when SDK nil/throws. Keep `ClaudeAPI.swift`.

**H2. Browser agent runner prefers direct Anthropic HTTP over the SDK** — `OpenClickyBrowserAgent.swift:365-381`, with an explicit comment choosing direct REST "whenever an Anthropic API key is configured." Inverts the documented policy; up to 40 autonomous steps × screenshots billed per-token. **Fix:** invert — `runWithAgentSDK` first, `callClaudeAPI` only when `hasAgentSDK()` is false or it throws.

### Security / correctness (5)

**H3. External-control bridge `/click` bypasses the backend selector and force-enables native CUA** — `CompanionManager.swift:2989-3031`: `clickExternalControlPoint` calls `nativeComputerUseController.click(at:)` unconditionally (`:3004`) and force-enables it (`setEnabled(true)` at `:2993-2995`). A user who selected "Background Computer Use" gets a cursor-warping native click; a user who *disabled* CUA has it silently re-enabled on every bridge click. The prior review's P0 for this exact path — still unfixed. **Fix:** route through `clickUsingSelectedComputerUse`; return 409 if disabled.

**H4. Background-click path discards the BCU `stateToken` — likely rejected by BCU's stale-coordinate guard** — `OpenClickyComputerUseRuntime.swift:423-452` (`click` builds request with no token), `CompanionManager.swift:7065-7163` (`clickUsingBackgroundComputerUse` never forwards `capture.stateToken`). The BCU binary carries explicit reject strings ("Supplied stateToken did not match…"). The prior review's headline fix (wire BCU click transport) may be functionally non-functional in practice. **Fix:** add `stateToken` to `OpenClickyBackgroundComputerUseClickRequest`/`press_key`/`type_text`; thread it through; add a `/v1/get_window_state` recapture before each click if the route requires it.

**H5. `CodexProcessManager` is `@unchecked Sendable` but mutates `process`/pipes off its serial queue** — `CodexProcessManager.swift:1` (`@unchecked Sendable`), `start()` writes `self.process`/`self.inputPipe` directly on the caller thread while `writeLine` reads `inputPipe` on `stateQueue` (`:344-347`); `stop()` nils them on the main actor. Torn optional read / dropped write or crash mid-RPC. **Fix:** move all process/pipe mutation behind `stateQueue` (including `start()`/`stop()`), or make it `@MainActor`.

**H6. System-audio capture controller races: writer fields mutated from multiple contexts with no sync** — `OpenClickySystemAudioCaptureController.swift`: `state` written in `start()` (`:38, 75`), `didStopWithError` (`:107`), `stop()` (`:112`), and the stream callback on `queue` (`:142-143`); `assetWriter`/`audioInput` assigned in `start()` from the caller context while the callback on `queue` reads them (`:131-141`). TSan-flagged data race; nondeterministic `.mov` corruption. **Fix:** make the controller `@MainActor` for `start()`/`stop()`/state, or route all writer/input mutations through `queue`.

**H7. Local model downloads verified by size only — no checksum** — `OpenClickyLocalModelDownloadService.swift:281` (`.verifying`), `didFinishDownloadingTo` does only `actualSize == expectedSize`. No `sha256`/`CryptoKit` anywhere in the local-model files. Supply-chain integrity gap; truncated/corrupted/substituted file of the right length is accepted. **Fix:** bundle expected `sha256` (HF exposes `lfs.oid`), compute `SHA256` in the `.verifying` phase, reject on mismatch.

### UI correctness (6)

**H8. Welcome-typing `Timer` never cancelled; the `@State` "timer" field is dead code** — `OverlayWindow.swift:514` (declared), `:890` (no-op invalidate against nil), `:1539` (the real timer, stored only in the RunLoop). On overlay disappear / multi-monitor rebuild, stale 33 Hz timers keep firing against recycled `@State`. **Fix:** capture the timer into the `@State` (or a dedicated field), invalidate in `onDisappear`, use `[weak self]`.

**H9. Per-screen 60 Hz cursor timer + always-ticking pet `TimelineView` run while hidden** — `OverlayWindow.swift:1145-1176` (one `DispatchSourceTimer` per display at 16 ms); `ClickyPetSpriteView.swift:50-54` (`TimelineView(.periodic)` continues at ~24 Hz at opacity 0). 2 displays = 2× background 60 Hz queues + 2× 24 Hz redraws producing no pixels, for the app's whole lifetime. **Fix:** gate on visibility; suspend the timer when `buddyIsVisibleOnThisScreen` is false.

**H10. Cursor-tracking `Timer` allocates a `Task { @MainActor }` on every 60 Hz tick** — `CompanionResponseOverlay.swift:103-109`: the timer is already on `RunLoop.main` (`.common`), so the `Task` wrap is ~60 needless allocations/sec for the lifetime of the streaming overlay. **Fix:** call `repositionPanelNearCursor()` directly.

**H11. `Color(hex:)` is non-failable, silently returns black; all `?? fallback` paths are dead** — `Packages/OCCore/.../Theme.swift:172-184` (`scanHexInt64` return value unchecked); consumed by `OverlayWindow.swift:1111-1115` returning `Color?` so callers write `?? overlayCursorColor` that can never trigger. Malformed/empty hex → solid black instead of the intended accent. **Fix:** make `init?(hex:)` return nil on scan failure / bad length.

**H12. `NSScreen.screens.first!` force-unwrap on the notch screen path** — `OpenClickyDynamicNotchKitBridge.swift:433`. Hard crash if `NSScreen.screens` is momentarily empty (display reconfig, sleep/wake race, headless tests). **Fix:** return optional, callers early-return.

**H13. `ForEach(inlineSuggestedActions, id: \.self)` traps on duplicate model titles** — `CodexAgentModePanelSection.swift:236`. If the model emits the same suggested action twice, SwiftUI `fatalError`s ("id is not unique"). **Fix:** wrap in an `Identifiable` struct with a `UUID` id, or de-duplicate.

### Lifecycle (2)

**H14. `OpenClickyAgentManager.refreshStatus()` / `sendRequest()` do blocking subprocess + socket I/O on the main actor** — `OpenClickyAgentManager.swift:204-243` (`launchctl` + `process.waitUntilExit()` on `@MainActor`, called from `.onAppear`); `sendRequest` (`:267-285`) + helpers do blocking socket I/O with a **90 s** idle timeout (`:517`), no suspension point. UI beachball up to 90 s. **Fix:** wrap in `Task.detached { }.value` (the `streamChat`/`ensureRunning` paths already do this — mirror them).

**H15. Message logs persist full voice transcripts indefinitely, no retention/pruning** — `OpenClickyMessageLogStore.swift:155-220` (verbatim `fields["text"]`), `:237-243` (daily-rotated files), no prune anywhere. Voice transcripts = PII (health, finance, names, spoken 2FA), plaintext, `app-sandbox=false`, in backups, unbounded growth. Log viewer can read but not clear. **Fix:** default 14–30 day retention pruned on launch; "Clear logs" + "Auto-delete" settings; consider opt-in diagnostic logging for release.

---

## Medium (24 findings, grouped)

**Concurrency / Sendable (4)**
- M1. `OpenClickyRequestCompletionState` is `@unchecked Sendable` with an unsynchronised `var didComplete` (`CompanionManager.swift:242-244`). **Fix:** `@MainActor` it, or guard with `OSAllocatedUnfairLock`.
- M2. LiquidGlass `NSView` subclasses not `@MainActor`-isolated despite mutating AppKit state (`Packages/OCUI/.../LiquidGlass.swift:104, 114, 236`). **Fix:** annotate `@MainActor`.
- M3. `CodexVoiceSession` registers `pendingTurn` after the `turn/start` response — early notifications dropped, continuation can hang (`CodexVoiceSession.swift:210, 232-244`). **Fix:** pre-register/buffer by turnID.
- M4. Project on `SWIFT_VERSION = 5.0`, no `SWIFT_STRICT_CONCURRENCY` (`project.pbxproj:504+`) — all `@unchecked Sendable`/race findings latent. **Fix:** set `minimal` now.

**Browser/packages (4)**
- M5. No `WKNavigationDelegate.decidePolicyFor`, no `WKUIDelegate`, no `WKDownloadDelegate` (`BrowserWorkspace.swift:3370-3435`). Navigation hijack (`file://`, custom schemes), unhandled downloads, no capture gating. **Fix:** implement allow-list policy + UI/download delegates.
- M6. `WKScriptMessageHandler` registered via `add` never removed → retain cycle leaking model + all `WKWebView`s per tab (`BrowserWorkspace.swift:3383`, no `removeScriptMessageHandler`/`deinit` in package). **Fix:** weak-wrapper pattern or `removeScriptMessageHandler` in teardown.
- M7. Research runner fetches arbitrary schemes/hosts (`file://`, `127.0.0.1`, `169.254.169.254`) from parsed search results — SSRF + local-file read (`BrowserWorkspace.swift:2845-2856, 2876-2889`). **Fix:** reject non-http(s), block private/loopback ranges.
- M8. Chrome cookie decrypt falls back to `"peanuts"` and temp DB copy not securely wiped (`BrowserWorkspace.swift:3135, 3036-3046`). **Fix:** return nil if Keychain unavailable; secure-delete temp.

**Computer-use (6)**
- M9. Native click silently uses an unconverted (wrong-Y) AppKit point when off all screens (`OpenClickyComputerUseRuntime.swift:1165-1168`). Voice/native path doesn't clamp (only the bridge does). Misfired click. **Fix:** throw `eventCreationFailed("off-screen")` or clamp+convert.
- M10. `setEnabled(true)` auto-enables native CUA at **7 sites**, overwriting the user's persisted "disabled" choice (`CompanionManager.swift:2993, 6611, 6635, 7186, 7707, 7826, 7924`). **Fix:** treat disabled as authoritative; return error + prompt.
- M11. BCU process lifecycle unmanaged: spawned via `/usr/bin/open`, no PID stored, never torn down in `stop()`, "ready" decided by a file on disk with no liveness probe (`OpenClickyComputerUseRuntime.swift:199-308`, `CompanionManager.stop()` at `:3067-3111`). **Fix:** track PID/`NSRunningApplication`, terminate on `stop()`, add a bootstrap probe.
- M12. Cron evaluator uses AND for day-of-month + day-of-week (standard cron uses OR) — `0 0 1 * 1` fires only when the 1st is a Monday (`OpenClickyAutomation.swift:132`). **Fix:** implement OR semantics when both restricted.
- M13. Automation persistence has no schema version; decode failure silently returns `[]` then overwrites the file with only the re-seeded automation (`OpenClickyAutomationStore.swift:261-277`). **Fix:** version the envelope; on failure, quarantine the file and seed in-memory only.
- M14. No finite/NaN guard on external-control coordinate parsing — `NaN`/`Infinity` JSON tokens propagate through `pointClampedToDesktop` into `CGEvent(mouseCursorPosition:)` (`OpenClickyExternalControlBridge.swift:850-854, 928-933, 1027-1034`). **Fix:** reject non-finite, return 400.

**Inference / API (5)**
- M15. Agent inference base URL allows `http://` for remote hosts (`ClickyCodexConfigTemplate.swift:207-216`). ATS mitigates at runtime (only `NSAllowsLocalNetworking`), but the validator is misleading. **Fix:** require `https` for non-loopback in code.
- M16. SDK primary path silently drops `assistantPrefill` (`ClaudeAgentSDKAPI.swift:167-186` has no prefill param; `CompanionManager.swift:16412-16433` omits it; HTTP fallback passes it). Behavioral divergence free vs. paid paths. **Fix:** add prefill to the bridge, or document/log the gap.
- M17. API keys stored/read from UserDefaults, not Keychain (`AppBundleConfiguration.swift:75-99, 181-190`). Migration to Keychain exists but new writes still go to UserDefaults. **Fix:** route Settings through Keychain; env/Info.plist bootstrap only.
- M18. `OpenAIAPI` labels every image `image/jpeg` regardless of bytes (`OpenAIAPI.swift:92, 377`). PNG screenshots mislabeled → decode/reject risk. **Fix:** sniff the PNG signature like `ClaudeAPI.detectImageMediaType`.
- M19. `config.toml` `escape()` doesn't neutralise newlines/control chars (`ClickyCodexConfigTemplate.swift:151-155`). Malformed command value → unparseable TOML, confusing startup error. **Fix:** strip/reject control chars.

**UI / state (5)**
- M20. Escape-key local monitor swallows Escape app-wide while the main panel is open (`OpenClickyNotchCaptureWindowManager.swift:714-720`). Breaks Escape in sibling sheets/fields. **Fix:** only swallow when the panel is key.
- M21. Pervasive `NSApp.activate(ignoringOtherApps: true)` (deprecated macOS 14+) on programmatic window shows (`CodexHUDWindowManager.swift:75`; `MiniChatPanelManager.swift:129, 179`; `ThreeDViewerWindowManager.swift:48-51`; etc.). Recurring focus steal. **Fix:** no-arg `activate()` only on user-initiated paths; `orderFrontRegardless()` for floats.
- M22. `UserDefaults.didChangeNotification` observed app-wide just to re-check theme (`MenuBarPanelManager.swift:88-96`; `CodexHUDWindowManager.swift:21-30`). Constant Task churn for unrelated writes. **Fix:** KVO on the specific key, or a dedicated theme-changed notification.
- M23. Heavy filter/sort computed properties re-run on every body evaluation (`OpenClickyNotchPanelView.swift:273-339`, `ConversationSidebarView.swift:116-135`). **Fix:** move to the model layer / memoise.
- M24. Accessibility gaps on legacy surfaces — `CompanionPanelView`, `MenuBarPanelManager`, `CodexAgentModePanelSection`, `MemoryDrawerView` add essentially no labels (contrast with the well-labelled notch/HUD). **Fix:** label icon-only buttons; `statusItem.button?.accessibilityTitle`.

---

## Low (condensed — 25+ findings)

- **Structure (lifecycle):** incomplete `stop()` — 8 tracked Tasks + `agentDockFollowTimer` never cancelled, no `deinit` (`CompanionManager.swift:3067-3107`); login item force-registered every launch, overriding the user's System Settings choice (`cursor_buddyApp.swift:120-130`); hardcoded dev path `/Users/jkneen/.../openclicky` seeded as a built-in shortcut (`CompanionManager.swift:18038-18064`); `WikiRuntimeManager` synchronous file I/O on `@MainActor` + O(lines) recount per ingest (`WikiRuntimeManager.swift`); heavy sync work in `start()` at launch (`CompanionManager.swift:2171-2266`); `DateFormatter` allocated per call; dead onboarding-video observer state.
- **Inference:** no retry/backoff anywhere (no 429/5xx handling); model IDs hardcoded across catalogs (drift-prone, silent fallback to `catalogModels[0]`); realtime sends long-lived OpenAI key over WebSocket (allowed by the exemption, but OpenAI recommends ephemeral session tokens); child processes inherit full parent environment; `CodexPointDetector`/`ClaudeAgentSDKAPI` have no per-request timeout/watchdog.
- **UI:** dead `interactivityTimer` field (`OverlayWindow.swift:2927`); deprecated single-param `onChange(of:)` pervasive; `@ObservedObject` initialised inline from `.shared` (anti-pattern); log viewer re-centres every open (no `setFrameAutosaveName`); guarded force-unwraps that re-evaluate the optional; design-system tokens bypassed for raw `Color.white.opacity(...)` + `.font(.system(size:))` literals; `showPanelOnLaunch` strong-captures `self` in `asyncAfter`; `MenuBarPanelManager.deinit` doesn't `removeStatusItem`; redundant `makeKeyAndOrderFront` + `orderFrontRegardless`.
- **Packages:** dead `#available(macOS 10.14)` on a macOS-26 package; `WikiManager` unbounded recursion + full-body load; `@MainActor` on a pure `Index.viewerEntries` for no data reason; `extractAliases` matches any line containing "also:"; custom markdown parser misses setext headings, mishandles `1.2.3` lists, only supports ```` ``` ```` fences; `MemoryWorkspaceView` holds new articles only in ephemeral `@State` (lost on re-show); `WKWebView` private-API `drawsBackground` KVC; `DS.Colors` hard-codes several semantic tokens to the blue family (ignores accent theme); `@State` inside `ButtonStyle` (fragile hover).
- **Computer-use:** `/health` exposes bridge capability metadata unauthenticated (`OpenClickyExternalControlBridge.swift:163-176`); overly-broad CORS `http://127.0.0.1` origin (`:446, 479`); cron `nextFireDate` brute-forces minute-by-minute to 366 days, silently nil for impossible expressions; `debug: true` hardcoded in all BCU requests; hardcoded dev source path as default BCU root.
- **Build/misc:** `.mcp.json` tracked (should be ignored); `ENABLE_USER_SCRIPT_SANDBOXING = NO`; no CI (`.github/workflows` missing); two-sources-of-truth for profile apply (`applyProfile` silently drops `ttsVoiceID`).

---

## The structural liability: `CompanionManager.swift` (18,502 lines)

A single `@MainActor final class` doing voice capture, realtime streaming, computer use, agent orchestration, onboarding, external-control IPC, widget snapshots, permission polling, speculative pre-fire, TTS provider management, and wiki parsing. ~618 methods, 53 `@Published` properties, 25 nested types, 7 `Timer`s. The file already contains the extraction seams (extracted *types* at `// MARK: - Extracted voice-routing types`, `:18347`) but left the *logic* inside. Recommended peel order (each low-coupling, already implied by existing `MARK`s):

1. **Point-tag parsing** (`:17153-17320`, pure `static func`s) → `PointTagParser` enum — trivial, immediate testability win.
2. **Request timing** (`:3821-3990`) → `RequestTimingRecorder` (pure helper).
3. **Voice intent routing** (`:8274-9640`, mostly already `static func`) → `VoiceIntentRouter` (largely `nonisolated`, unit-testable).
4. **Local automation runner / system volume** (`:250-365`, already `nonisolated private enum`) → own files.
5. **Speculative pre-fire** (`:8640-9070`) → `SpeculativePreFireController` (self-contained state machine).
6. **Computer-use action coordination** (`:5382-8020`, ~2,600 lines) → `ComputerUseActionCoordinator`.
7. **Realtime bidirectional voice** (`:4346-5050`) → `RealtimeVoiceCoordinator`.
8. **External control / proxy cursors** (`:2366-3060`) → `ExternalControlCoordinator`.
9. **Agent-session lifecycle** (`:3418-3820`) → `AgentSessionStore: ObservableObject`.
10. **TTS/STT provider management** (`:659-960`) → `VoiceProviderManager`.
11. **Onboarding** (`:2268-2400`, `:17326+`) → `OnboardingCoordinator`.

Target: start with #1–#4 (low-risk, mostly-static), then #5, then #6 (the biggest block). Each extraction shrinks the `@MainActor` surface and makes the remaining concurrency reasoning tractable — and is a precondition for the Swift 6 migration.

---

## Test gaps (for the critical paths)

The 101 `@Test` functions are concentrated in Codex config rendering, CUA model parsing, and widget state. The load-bearing/security-sensitive behaviour with **no** automated coverage:

- **Money-rule ordering** (SDK-first vs. HTTP fallback) at every call site — would catch H1 + H2.
- **Coordinate math**: `quartzPoint(fromAppKitPoint:)` incl. the off-screen fallback (M9), `pointClampedToDesktop`, multi-display Y-flip — would catch M9 directly.
- **BCU HTTP lifecycle**: manifest parsing, `ensureRuntimeReady` stale-manifest behaviour (M11), `ClickRequest` shape incl. the missing `stateToken` (H4).
- **`CronExpression.nextFireDate`** + AND-vs-OR day semantics (M12) + impossible-expression handling.
- **`OpenClickyAutomationStore`** corrupt-file behaviour + migration (M13).
- **`OpenClickyExternalControlBridge`** command parsing, token auth, NaN handling (M14).
- **`CodexProcessManager`** / `OpenClickySystemAudioCaptureController` concurrency (H5/H6).
- **Browser agent navigation/evaluate policy** (C1) + cookie-import scoping (C2) + SSRF fetch (M7).

Adding these is cheap (the contracts are already `Sendable`/`Codable` value types) and would have caught roughly a third of the findings in this review.

---

## Genuine strengths (preserve these)

- **Secret handling is responsible.** `OpenClickyMessageLogStore.isSensitiveKey` (`:290-299`) redacts `api_key`/`apikey`/`authorization`/`password`/`secret`/`token`/`x-api-key` by field name, and `sensitiveValuePatterns` (`:301-307`) scrubs `sk-ant-`/`sk-proj-`/`sk-`/`gh[pousr]_`/`AIza`/JWT from values. No secret has ever been committed to git history. Notarization uses Keychain profiles. Keychain migration exists for UserDefaults keys.
- **Money rule is correct on the main voice branch.** `analyzeClaudeResponse` (`CompanionManager.swift:16392-16452`) goes SDK-first with a `voice.response_fallback` log on HTTP fallback; OpenAI branch mirrors it; the realtime exemption is honored.
- **External-control bridge is fail-closed.** `hasValidBridgeToken` (`OpenClickyExternalControlBridge.swift:411-420`) requires a token on every command route, 401 otherwise; `constantTimeEquals` is correct; binds to `127.0.0.1` only. The inference proxy is opt-in and SSRF-safe (three fixed paths, server-side key injection).
- **The prior review's #1 P0 is genuinely fixed.** `clickUsingSelectedComputerUse` (`CompanionManager.swift:7055-7063`) now branches on `selectedComputerUseBackend`, and `clickUsingBackgroundComputerUse` (`:7065-7163`) implements the full capture→point→`/v1/click` chain.
- **Markdown viewer deliberately avoids the WKWebView XSS trap** — renders as SwiftUI `Text` + `AttributedString(markdown:)`, no `loadHTMLString` (`OpenClickyMarkdownViewer.swift:334-339`). `<script>` in a note is literal text.
- **JS string interpolation is properly JSON-escaped** (`OpenClickyBrowserAgent.swift:962-969, 1830-1838`).
- **Accessibility-aware animation** — `accessibilityReduceMotion` is honored across the overlay (`OverlayWindow.swift:491, 801, 975, …`); broad labelling on the notch/HUD.
- **Off-main cursor sampling with coalescing** (`OverlayWindow.swift:1145-1176`); `streamChat` gets async-stream cancellation right (`OpenClickyAgentManager.swift:300-316`); `OpenClickyDirectActionMemoryStore` is a correct `@unchecked Sendable` (NSLock + serial write queue) — a template for the ones that aren't.

---

## Recommended fix order

1. **C1 + C2 + M5 + M6** — browser agent security hardening (remove/gate `evaluate`, per-task cookie store, navigation delegate, fix retain cycle). Highest blast radius.
2. **C3** — BCU authentication (token on every route). Invisible-input trust breach.
3. **C4** — drop `danger-full-access` + `approval_policy="never"` on Codex voice/point paths.
4. **H1 + H2** — route title generation and the browser runner SDK-first. Stops the per-token cost leak.
5. **H3 + H4** — finish the click-selector work (bridge path) and thread the BCU `stateToken`. Makes the headline feature actually work.
6. **H5/H6 + M1–M4** — flip `SWIFT_STRICT_CONCURRENCY = minimal`, fix the `@unchecked Sendable`/race findings it surfaces.
7. **H14 + H15** — move blocking I/O off the main actor; add message-log retention.
8. **H8–H13** — the UI correctness batch (timers, `Color(hex:)`, force-unwraps, `ForEach` ids).
9. **Add CI** + the test gaps above, then start the `CompanionManager` extraction in the recommended peel order.
