# OpenClicky Full System Code Review

Date: 2026-06-09
Scope: agentic system, voice pipeline, computer use, speed, architecture/understandability.
Method: five parallel deep-review passes (agentic/Codex subsystem, voice pipeline, computer-use subsystem, CompanionManager core + inference-routing audit, performance/infrastructure), followed by manual spot-verification of every Critical/High headline claim against source. One subagent finding was disproved during verification and is documented below so it does not get "fixed" incorrectly later.

Severity scale: Critical (likely production breakage, money, or memory safety), High (real bug or policy violation, reachable), Medium (correctness/perf hazard), Low (debt, hygiene).

---

## 0. Executive summary

The architecture is fundamentally sound: process-isolated Codex subprocess over stdio JSON-RPC, pluggable transcription providers, sentence-pipelined TTS, per-display calibration keyed by screen frame, and a file-lease coordinator for concurrent agent sessions are all good designs. The main problems cluster in five areas:

1. **Money-rule violations.** Two inference call sites do not honor the CLAUDE.md routing order (SDK/app-server first, billed REST fallback). Proactive element pointing goes straight to direct Anthropic REST; the OpenAI/Codex voice branch is inverted.
2. **Races and hangs in the Codex RPC layer.** A continuation-leak race in `CodexProcessManager.sendRequest`, no per-request timeouts anywhere (Codex RPC and Claude SDK bridge), and a double-startup race in `ensureThread()`.
3. **Main-actor blocking.** Synchronous `Process.waitUntilExit()`, heavy file I/O, `usleep`, and a 300 ms `Thread.sleep` at launch all run on the main thread.
4. **Coordinate-space fragility.** The pixel/point vocabulary is mixed inside `CompanionScreenCapture`, the BCU click path reuses pixel fields as point fields ("works by accident"), and the proactive pointing path skips the calibration offset that the voice path applies.
5. **Reliability gaps in voice.** No `AVAudioEngineConfigurationChange` handling on any of the three audio engines; device switches silently kill dictation/wake-word/TTS.

Top 10 fixes by value, in order: routing inversions (1), Codex continuation leak + timeouts (2), audio route-change handling (3), main-actor `waitUntilExit` sites (4), proactive-pointing calibration skip (5), SkyLight raw-memory probing (6), startup `Thread.sleep` (7), UserDefaults-as-blob-store for session snapshots (8), push-to-talk tap-timeout stuck-pressed state (9), 12.5 Hz hover probe + broad `UserDefaults.didChangeNotification` observers (10).

---

## 1. Inference routing compliance audit (CLAUDE.md "money rule")

| Call site | Provider switch | Order compliant? | Notes |
|---|---|---|---|
| `analyzeVoiceResponse` (CompanionManager.swift:15923) | Yes, four-way on `.provider` | n/a (dispatcher) | Correct |
| `analyzeClaudeResponse` (CompanionManager.swift:15964) | Yes | **Yes** | SDK first; HTTP only when SDK nil/throws and key present |
| `analyzeOpenAIOrCodexVoiceResponse` (CompanionManager.swift:16033) | Yes | **NO — inverted** | Tries billed `openAIAPI` first when a key exists, Codex session only as fallback. CLAUDE.md says Codex app server first. Verified in source. |
| `analyzeCodexVoiceResponse` (CompanionManager.swift:16080) | n/a | n/a | Clean leaf |
| `analyzeComputerUsePointingResponse` (CompanionManager.swift:16349) | Yes | Yes | Anthropic branch delegates to `analyzeClaudeResponse` (SDK-first) |
| `attemptProactiveElementPointingIfUseful` (CompanionManager.swift:16456) | Yes | **NO — SDK bypassed** | `.anthropic` branch hard-requires `AppBundleConfiguration.anthropicAPIKey()` and calls `ElementLocationDetector(apiKey:)` directly: every proactive pointing request bills per-token, and users with SDK-only sign-in get no proactive pointing at all. Verified in source. |
| Speculative pre-fire (CompanionManager.swift:8587), tutor observation (:15683), continuation text (:15256) | delegate | Yes | Inherit correct routing |

### R1. Critical — Proactive pointing bypasses the SDK and hard-requires a paid key
`CompanionManager.swift:16456-16465`. Route the `.anthropic` branch through the same SDK-first chain as `analyzeClaudeResponse` (a pointing-specific prompt through `ClaudeAgentSDKAPI`, falling back to `ElementLocationDetector`/REST only when SDK is unavailable).

### R2. Critical — OpenAI/Codex ordering inverted
`CompanionManager.swift:16042-16078`. Attempt `codexVoiceSession` first; fall back to `openAIAPI.analyzeImageStreaming` only when the Codex session fails or is unavailable. The fallback log event (`voice.response_fallback`) should then read `from: codex_voice_session, to: openai_api_key`.

Policy clarification (Jason, 2026-06-09): the OpenAI realtime voice API (`gpt-realtime-2` / `gpt-realtime-1.5`) cannot go through the Codex app server and must use the direct API — that exemption applies to the bidirectional realtime path (`OpenAIRealtimeSpeechClient`), which is a separate code path and is correctly direct today. It does NOT soften this finding: `OpenClickyModelCatalog.voiceAnalysisModel(withID:)` (OpenClickyModelCatalog.swift:109-117) remaps realtime IDs to `gpt-5.4` before this function runs, so every model that reaches `analyzeOpenAIOrCodexVoiceResponse` is a gpt-5.x/codex-capable text model and should be app-server-first. When fixing, add a defensive `!OpenClickyModelCatalog.isSpeechModelID(modelOption.id)` guard before the Codex attempt so a future un-remapped realtime ID can never be sent to the Codex session.

---

## 2. Agentic system (Codex sessions, RPC, process lifecycle)

### A1. Critical — Continuation leak: request registered after `stop()` already failed pending requests
`CodexProcessManager.swift:148-177`. `sendRequest` checks `isRunning` outside `stateQueue`, then enqueues registration + stdin write. If `stop()` interleaves, `failAllPendingRequests` runs before the continuation is registered; the write is then silently dropped (nil pipe) and the continuation never resumes. The session hangs forever in `.starting`/`.running`. Fix: move the `isRunning` guard inside the `stateQueue` block; resume immediately with an error if stopped.

### A2. Critical — Double-startup race in `ensureThread()`
`CodexAgentSession.swift:424-432, 557-560, 713-821`. `warmUp()` and `startPromptTurn` both spawn unstructured Tasks calling `ensureThread()`; the `isRunning && activeThreadID != nil` guard spans multiple suspension points without a lock. Two concurrent calls can issue two `thread/start` RPCs; the second overwrites `activeThreadID` while notifications from the first thread keep arriving — permanent session confusion. Fix: an `isStartingUp` in-flight flag (or a shared startup Task that re-entrant callers await).

### A3. High — No request timeout anywhere in the RPC layer
`CodexProcessManager.swift:171-177`. A frozen (not exited) Codex process leaves `pending` continuations waiting forever; `handleBridgeTermination`-style recovery only fires on exit. Fix: deadline Task per request (e.g. 30 s for `initialize`/`thread/start`, 90 s for `turn/start`); on expiry remove + resume with a timeout error and restart the process.

### A4. Critical — Main-thread subprocess execution
- `CodexRuntimeLocator.swift:198-220`: `codexVersion` runs `Process` + `waitUntilExit()` synchronously; called via `codexExecutableURL` on the main actor in `ensureThread` (CodexAgentSession.swift:735), once per candidate binary, on every session start.
- `OpenClickyAgentManager.swift:204-237, 192-202`: `refreshStatus()`/`uninstallService()` block the main actor on `launchctl`; called from `.onAppear` (OpenClickyAgentRuntimeView.swift:99).
- `CodexAgentSession.swift:726-734`: `CodexHomeManager.prepare(bundle:)` (recursive copy/diff of the resource pack, TOML write) runs inside `MainActor.run`.
Fix: move all three into the existing `Task.detached` startup block; cache `codexExecutableURL` after first resolution; cache the prepared `CodexHomeLayout` and invalidate only on settings change (it is re-prepared per session today, A8).

### A5. High — `GOG_KEYRING_PASSWORD` placed in child process environment
`CodexProcessManager.swift:107-111`. Plaintext secret visible to the subprocess environment and one refactor away from being logged via `summarizedRequestFieldsForLog`. Fix: keychain-helper read inside the runtime, or an explicit never-log allowlist for environment keys.

### A6. High — TOML escape misses newlines: config injection from UserDefaults values
`ClickyCodexConfigTemplate.swift:58-59, 151-155`. `escape()` handles `\` and `"` but not `\n`/`\r`/`\t`. A tampered `clickyCodexModel` default containing a newline injects arbitrary TOML keys (including overriding `sandbox_mode`). Fix: escape control characters and validate `model`/`reasoningEffort` against `[A-Za-z0-9./-]+` before persisting.

### A7. High — `danger-full-access` + `approvalPolicy = never` hard-coded in three layers with no user override
`CodexProcessManager.swift:33-34`, `CodexAgentSession.swift:618-622, 789`, `ClickyCodexConfigTemplate.swift:62-63`. Intentional per product design, but there is no per-session way to dial it down for sensitive work and the risk is not surfaced in UI. Fix (design): single source of truth for sandbox/approval, exposed as a session-level setting; document the default.

### A8. Medium — Redundant home preparation and config rewrite per session start
`CodexHomeManager.swift:89-167` via `CodexAgentSession.swift:726-734`. An ephemeral `CodexHomeManager` re-prepares (full file reads + directory enumeration for equality checks) on every `ensureThread`/`warmUp`. Cache the layout.

### A9. Medium — stderr "error" substring marks healthy sessions `.failed`
`CodexAgentSession.swift:1322-1327`. `localizedCaseInsensitiveContains("error")` on stderr is too broad (the allowlist has already needed patching once). Fix: rely on the structured `error` notification on stdout; restrict stderr-driven failure to unambiguous fatal signals.

### A10. Medium — Untracked fire-and-forget Tasks fight `stop()`
`CodexAgentSession.swift:424-432, 557-560, 591, 913`. Prompt and warm-up Tasks are not stored/cancelled; a post-`stop()` `runPrompt` can restart the process, and a failed warm-up overwrites `status` on an intentionally stopped session. Fix: store handles, cancel in `stop()`.

### A11. Medium — `DroppedAttachments/` grows forever
`CodexHUDWindowManager.swift:1210-1223`. Drag-and-drop PNGs are never deleted. Fix: delete after send, plus a startup sweep for files older than 24 h.

### A12. Medium — Agent markdown files injected into system context unbounded
`OpenClickyAgentDefinition.swift:70-107`. `soul.md`/`instructions.md`/`memory.md`/`HEARTBEAT.md` are concatenated into developer instructions with no byte cap (skills have a 64 KB cap). Third-party agent templates are a prompt-injection vector. Fix: per-file byte caps; treat agent packs as trusted-as-config and say so in UI.

### A13. Medium — `CLICKY_AGENT_BASE_URL` accepted with any scheme
`ClickyCodexBackend.swift:188-192`. Accepts `file://` etc. into `base_url`. Fix: require `https` (allow `http` only for localhost).

### A14. Low — Two overlapping "agent" subsystems, one unwired
`OpenClickyAgentManager.swift` (launchd daemon + UDS) vs `CodexAgentSession`/`CodexProcessManager` (bundled Codex over stdio). `isDaemonAvailable` is computed but never used for routing. Fix: wire it or remove the daemon path; rename one subsystem.

---

## 3. Voice pipeline

### V1. Critical — No `AVAudioEngineConfigurationChange` handling on any engine
`BuddyDictationManager.swift:267, 762-779`; `OpenClickyWakeWordManager.swift:63, 150-157`; TTS engine init sites in `ElevenLabsTTSClient.swift`. Device switch / headphone unplug stops the engine silently; the stale tap then makes the next `installTap` crash-prone. Fix: subscribe in each engine owner; tear down tap, restart with backoff.

### V2. High — AssemblyAI ready-continuation race
`AssemblyAIStreamingTranscriptionProvider.swift:202-213`. `resume()` + receive loop start before the continuation is stored; a fast `begin` frame leaves `open()` suspended forever. Fix: register the continuation before `resume()`.

### V3. High — Whisper provider: unbounded in-memory buffer + `stateQueue.sync` from a Task
`OpenAIAudioTranscriptionProvider.swift:116-119, 147-148`. No byte cap (cf. the 360-buffer cap in `BuddyDictationManager`) and a synchronous queue hop that can deadlock the main thread. Fix: cap (~25 MB) + replace `sync` with an atomic flag.

### V4. High — Deepgram `open()` returns before server confirmation
`DeepgramStreamingTranscriptionProvider.swift:136-146`. No readiness handshake (AssemblyAI has one); auth failures surface late. Fix: await first `metadata` frame, mirroring the AssemblyAI pattern.

### V5. Medium — Push-to-talk stuck "pressed" after tap timeout
`GlobalPushToTalkShortcutMonitor.swift:129-134`. On `tapDisabledByTimeout` the tap is re-enabled but a missed release leaves `isShortcutCurrentlyPressed = true`; the overlay hangs in listening state. Fix: synthesize a `.released` transition before re-enabling.

### V6. Medium — Wake-word and dictation engines can both tap input bus 0
`OpenClickyWakeWordManager.swift:152` vs `BuddyDictationManager.swift:768`. TOCTOU window in wake-word -> dictation handoff can double-install a tap on the shared hardware input. Fix: a single microphone coordinator that serializes engine ownership.

### V7. Medium — TTS drain polls at 80 ms
`ElevenLabsTTSClient.swift:510-523`. Adds up to 80 ms tail latency per utterance; `voiceState` stays `.responding` meanwhile. Fix: `scheduleBuffer(..., completionCallbackType: .dataPlayedBack)` + continuation.

### V8. Medium — Converter recreated based on `settings.description` string comparison
`BuddyAudioConversionSupport.swift:28-30`. Dictionary-ordering-dependent; can recreate `AVAudioConverter` every buffer. Fix: compare `AVAudioFormat` with `isEqual(_:)`.

### V9. Medium — Per-buffer main-queue hops from the tap callback
`BuddyDictationManager.swift:1044-1062`. ~172 hops/s at 256-frame buffers; the throttle only gates history, not the dispatch. Fix: throttle on the audio thread before dispatching.

### V10. Low — `@unchecked Sendable` with partially guarded state (AssemblyAI), Deepgram URL logging (key currently in header, safe, but fragile), double `invalidateAndCancel()` in the Whisper session.

### V11. Structural — `ElevenLabsTTSClient.swift` is six clients in one file (~4,300 lines)
ElevenLabs, `StreamingTTSSession`, `FillerPhraseLibrary`, Cartesia, Microsoft Edge TTS, and `OpenAIRealtimeSpeechClient` (~1,500 lines of bidirectional realtime audio I/O — a different architectural tier, not a TTS client). Split into at least three files.

Latency assessment: the pipeline is well designed for latency — 256-sample taps, buffer-before-provider-ready hides WebSocket handshake, sentence-pipelined TTS, pre-baked filler phrases. Realistic key-release-to-first-audio floor is ~1.0-2.5 s. The 80 ms drain poll (V7) and the speculative pre-fire 50 ms busy-poll (C7 below) are the avoidable contributors.

---

## 4. Computer use / screen interaction

### U1. High — Proactive pointing skips the calibration offset
`CompanionManager.swift:16483-16487` (verified). The voice-triggered path applies `visualGuidanceCalibrationOffset` (`:15411`); the proactive path adds only `displayFrame.origin`. On any calibrated display, proactive pointers land consistently off by the calibration delta. Fix: apply `Self.visualGuidanceCalibrationOffset(for: displayFrame)` here too.

### U2. High — SkyLight private-API path probes raw CGEvent memory at hardcoded offsets
`OpenClickyComputerUseRuntime.swift:1251-1258` (verified). `extractEventRecord` walks offsets `[24, 32, 16]` from the opaque CGEvent pointer and treats the first non-nil slot as the event record — undocumented, OS-version-specific ABI; a wrong hit hands garbage to `SLEventSetAuthenticationMessage` (heap corruption risk). Fix: prefer `event.postToPid(_:)`; if the SkyLight path stays, gate it on exact validated macOS versions and fall back otherwise.

### U3. High — BCU click path stuffs pixel dimensions into point fields
`CompanionManager.swift:6871-6876`. `displayWidthInPoints = screenshotWidthInPixels`, `displayFrame = .zero` makes the downstream scale ratio 1.0 and the offset a no-op — correct today only by coincidence, and semantically wrong on any non-1x capture if the path evolves. Fix: an explicit `isWindowScreenshotSpaceCapture` sentinel (or a separate type) instead of field reuse; this is the active manifestation of the mixed pixel/point vocabulary in `CompanionScreenCapture` (see also `CompanionScreenCaptureUtility.swift:229-265`).

### U4. High — `appKitFrame(for:displays:)` fallback flips Y with the primary display height
`CompanionScreenCaptureUtility.swift:329-338`. When the containing display is not found, the window Y is flipped using `NSScreen.screens.first` height — wrong for windows on secondaries with different resolutions. Fix: resolve the containing screen via `CGDisplayBounds` cross-reference before falling back.

### U5. High — Click synthesis: cursor move + 35 ms `usleep` on the calling (main) actor
`OpenClickyComputerUseRuntime.swift:1157-1162` (verified). The `mouseMoved` pre-event moves the real cursor system-wide (hover/focus side effects); `usleep(35_000)` blocks the main actor mid-click. Fix: drop the moved event or use `CGWarpMouseCursorPosition`; run click sequences off the main actor with `Task.sleep`.

### U6. High — Shared 3-second `SCShareableContent` cache can leak OpenClicky's own windows into screenshots
`CompanionScreenCaptureUtility.swift:35-48`. The cache is not keyed by capture type or invalidated when app windows change, so a panel opened within the window can appear in the next model-bound screenshot. Fix: keep the cache, but invalidate on workspace/window changes and key by request type.

### U7. High — External control bridge: unauthenticated discovery + 10 MiB pre-auth body buffering
`OpenClickyExternalControlBridge.swift:158-176, 143, 325-329`. `/health` enumerates all tools and reveals `bridgeTokenConfigured: false` without a token; bodies up to 10 MiB are buffered before auth (local DoS); no-token mode silently 401s every action (correct default, but undocumented — one refactor away from fail-open). Fix: minimal unauthenticated health payload, tighter pre-parse limit (~512 KB), startup warning when no token configured.

### U8. Medium — Calibration accumulation can drift past the plausibility gate
`CompanionManager.swift:14773-14797, 15411-15419`. Individually plausible samples can accumulate to an implausible offset; no post-accumulation bound and no reset on resolution change. Fix: clamp/reset the accumulated offset against `maximumVisualGuidanceCalibrationDelta`.

### U9. Medium — Overlay hygiene
`OverlayWindow.swift:1539-1555`: welcome-animation `Timer` is unstored, cannot be invalidated in `onDisappear`, and keeps mutating `@State` after teardown. `OverlayWindow.swift:1156-1175`: the `updateQueuedOnMain` coalescing flag is correct but undocumented and breaks if the re-dispatch queue ever changes — document or use a lock.

### U10. Low — `typeCharacters` blocks the calling thread per character
`OpenClickyComputerUseRuntime.swift:1057-1065`. 30 ms x N characters of `usleep` on whatever thread calls it. Fix: `async` + `Task.sleep`.

### Disproved during verification
The review pass flagged `quartzPoint(fromAppKitPoint:)` (`OpenClickyComputerUseRuntime.swift:1165-1179`) as a Critical multi-monitor Y-inversion bug. Manual verification shows the formula is algebraically identical to the canonical `cgY = primaryScreenHeight - appKitY` global conversion (because `CGDisplayBounds.origin.y = primaryHeight - appKitFrame.maxY` holds for every display), so it is correct on all monitor arrangements. Do not "fix" it. The only real weakness is the `return point` fallback when no screen's frame contains the point (e.g. exact max-edge coordinates); consider nearest-screen resolution there.

Coordinate design assessment: structurally sound (screenshot pixels -> scale to points -> Y-flip -> display offset -> calibration) but fragile because three coordinate vocabularies share one struct with misleading field names. U3/U4 are where the confusion has already produced wrong or accidental code.

---

## 5. Speed / performance

### P1. High — 300 ms `Thread.sleep` on the main thread at launch
`cursor_buddyApp.swift:107-110` (verified). Duplicate-instance handling sleeps the main thread before the status item exists. Fix: continue startup via `asyncAfter`.

### P2. High — Full agent transcripts stored as blobs in `UserDefaults`
`MiniChatPanelManager.swift:44-114`. `openClickyArchivedSessionSnapshots` / `openClickyRelaunchableAgentSessionSnapshots` hold full transcript JSON; every save does a full decode/append/encode on the main actor and bloats the app's plist (slowing every defaults access app-wide). Fix: JSON files in Application Support written on a background queue; IDs only in defaults.

### P3. High — Five process-wide `UserDefaults.didChangeNotification` observers
`MenuBarPanelManager.swift:87-96`; `OpenClickyNotchCaptureWindowManager.swift:168-176, 2168-2174, 2514-2520`; `CodexHUDWindowManager.swift:29-35`. Every defaults write anywhere (agent machinery writes constantly) triggers main-actor work and repaints in five places. Fix: KVO/`publisher(for:)` on the specific keys.

### P4. High — 12.5 Hz hover-probe timer in `.common` mode, plus a 1.4 Hz accessibility probe, running whenever the pill is visible (the app's idle state)
`OpenClickyNotchCaptureWindowManager.swift:1148-1157, 1166`. Fix: `NSTrackingArea` / global mouse-moved monitor, uninstalled when not needed.

### P5. High — Main panel SwiftUI tree rebuilt from scratch on every open
`OpenClickyNotchCaptureWindowManager.swift:539-614` (and `hideMainPanel` :498 nils the hosting view). A 3,600-line view with all its subscriptions is reconstructed per show. Fix: retain the hosting view across show/hide.

### P6. High — Per-app-switch synchronous read-modify-write of the usage log on the main thread
`OpenClickyApplicationUsageLogStore.swift:65-110`, unbounded `applications` list. Fix: serial background queue + entry cap.

### P7. Medium — Speculative pre-fire 50 ms busy-poll for the whole generation
`CompanionManager.swift:8613-8623`. ~20 main-actor hops/s for 3-10 s per speculative request. Fix: push updates from `onTextChunk` via continuation/`AsyncStream`.

### P8. Medium — Synchronous main-actor I/O hotspots
Screenshot `.atomic` writes (`CompanionManager.swift:14173, 14210, 14235, 14258`); widget snapshot 128 KB tail-read + scans on main actor (`OpenClickyWidgetStateStore.swift:206-218`); `OpenClickyAgentStore.reload()` directory enumeration on main actor (`OpenClickyAgentStore.swift:44-53`); `FileHandle` open/close per log line (`OpenClickyMessageLogStore.swift:221-230`); `MemoryDrawerView.conversationRefs` O(sessions x entries) substring scan inside `body` (`MemoryDrawerView.swift:176-186`).

### P9. Medium — Small hot-path waste
Uncached `NSRegularExpression` per response/log line (`ClickyNextStageParityModels.swift:233-246`, `OpenClickyMessageLogStore.swift:319-327`); per-write `ISO8601DateFormatter` (`OpenClickyMessageLogStore.swift:163-170`); `OpenPetsCatalogService.runProcess` semaphore-blocks a cooperative thread (`OpenPetsCatalogService.swift:327-343`); `UUID()`-identified `OpenClickyNotchConnectionRow` defeats `ForEach` identity (`OpenClickyNotchPanelView.swift:3245`); `.onChange` cascades firing per streaming chunk (`OpenClickyNotchPanelView.swift:428-485`).

---

## 6. CompanionManager core and API clients

### C1. Critical — `runOpenApplication` blocks the main actor with `waitUntilExit()`
`CompanionManager.swift:7836-7848`. A slow `open` (first-launch verification, iCloud app) freezes UI, audio, and the state machine. Fix: `Task.detached`, like `addReminderUsingNativeAutomation` already does.

### C2. High — Claude SDK bridge has no per-request timeout
`ClaudeAgentSDKAPI.swift:256-282`. A hung (not exited) bridge leaves the continuation pending and the voice state in `.processing` forever; the only auto-recovery guard (`:4570` in CompanionManager) covers the realtime path only. Fix: deadline Task per request (60 s cold / 30 s warm) -> `failRequestIfPending` -> bridge restart.

### C3. High — Hardcoded developer paths ship in the binary
`ClaudeAgentSDKAPI.swift:393` (`/Users/jkneen/.local/bin` in `baselinePath`, verified); `CompanionManager.swift:11272, 17606` (`/Users/jkneen/Documents/GitHub/openclicky` dev-seed candidates); `ConversationSidebarView.swift:244` (literal "Jason Kneen" footer); `scripts/release.sh:16-24` (Apple ID in comments). Fix: derive from `homeDirectoryForCurrentUser` / configuration; remove the rest.

### C4. High — Full prompts and responses logged
`ClaudeAPI.swift:213, 220, 348, 417, 424`. System prompt (with injected screen context), user utterances, and responses go to `OpenClickyMessageLogStore` untruncated. The store redacts known secret patterns but not conversation content. Fix: metadata-only (lengths, model, latency) in release builds, or apply the existing `truncatedLogText` pattern.

### C5. Medium — API-client hygiene
`OpenAIAPI.swift:377`: MIME type hardcoded `image/jpeg` regardless of content (ClaudeAPI sniffs magic bytes — mirror it). `OpenAIAPI.swift:37-42`: TLS warm-up has no once-only gate (ClaudeAPI's `TLSWarmupGate` exists — reuse). `OpenAIAPI.swift:278-284`: `response.output_text.done` ignored once any delta arrived. `CompanionManager.swift:568-570`: stale `static let` API-key snapshots that future code will misuse — delete. `CompanionManager.swift:3243, 2231, 2250`: timers reassigned without invalidating the previous instance. `CompanionManager.swift:12737`: uncancellable bare `asyncAfter` mutating `agentDockItems`. `CompanionManager.swift:840`: needless `DispatchQueue.main.async` inside an `@MainActor` method.

### C6. Structural — Splitting the 18,000-line god object
The dependency edges are already unidirectional; the natural split is:
1. `VoiceSessionCoordinator` (~3,000 lines): `voiceState`, PTT lifecycle, `handleFinalVoiceTranscript`, speculative pre-fire, realtime task management.
2. `InferenceRouter` (~500 lines): the five `analyze*` functions and the API client references. Fixes the money rule once, in one place — do this split first.
3. `ComputerUseDispatcher` (~4,000 lines): AppleScript/Spotify/Reminders/Messages/type/click/open handlers — fire-and-forget, no shared voice state.
4. `AgentSessionManager` (~2,500 lines): session create/archive/select/cancel, dock items, resume loop.
5. `PermissionsAndStartupCoordinator` (~600 lines): start/stop, permission polling, onboarding, settings writes.
Residual `CompanionManager` (~1,000 lines) becomes the observable state bag bridging SwiftUI.

Also recommended: centralize `voiceState` resets behind a single `completeRequest` call site (the per-branch repetition is currently correct but fragile), and extract the four duplicated `appResolvedWeight` helpers in `CodexHUDWindowManager.swift:333, 1408, 1458, 1681`.

---

## 7. What is good (worth preserving)

- Process isolation of the agent over stdio JSON-RPC; the agent cannot take down the host app. The serial `stateQueue` cleanly separates pipe I/O from the main actor.
- The file-lease coordinator for concurrent agent sessions in one working directory.
- SDK-first routing in `analyzeClaudeResponse` is implemented correctly — the violations are in the two satellite paths, not the core.
- Voice latency engineering: 256-sample taps, buffering audio while the provider socket opens, sentence-pipelined TTS with parallel fetch + serialized scheduling, pre-baked filler phrases.
- Per-display calibration keyed by screen frame with plausibility gating; the global coordinate conversion (`quartzPoint`) is correct, including multi-monitor.
- The message log store's write queue and secret-pattern redaction; analytics is a no-op (no PII egress).
- Release scripts (sign/notarize/Sparkle) are well structured.
