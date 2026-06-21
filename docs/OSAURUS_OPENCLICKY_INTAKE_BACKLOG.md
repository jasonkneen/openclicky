# Osaurus to OpenClicky Intake Backlog

Status: living backlog, created from the local Osaurus checkout at
`/Users/jkneen/Documents/GitHub/osaurus`. Updated after the local OpenClicky
intake commits `e577021` (`chore: track OpenClicky intake updates`) and
`b6dac1b` (`docs: plan local voice and settings intake`).

Important source constraints:

- Refreshed after `git fetch --prune origin` in both repositories on 2026-06-21.
  OpenClicky is clean and two local commits ahead of `origin/main`; neither
  `e577021` nor `b6dac1b` is present on a remote branch.
- The Osaurus checkout is clean and no longer behind upstream. Its local `main`
  is two commits ahead of `origin/main`: local HEAD `73e38916` (`Merge branch
  'main' of https://github.com/osaurus-ai/osaurus`) on top of `3a87480d`
  (`Fixes`), with `origin/main` at `3a11a687` (`Repin vmlx-swift: L2 disk-cache
  orphan-row + solo seed-boundary fix (#1619)`).
- Keep new OpenClicky intake work local until the user explicitly asks to push.
- Keep the OpenClicky product shape: menu-bar companion, notch/panel UI, cursor
  overlay, Agent Mode dashboard, local keys, and OpenClicky visual language.
- Do not import Osaurus's management-app shell. Import behavior, data models, and
  rendering techniques only where they improve OpenClicky.

Refresh note: the current Osaurus tree still supports the same high-value intake:
FluidAudio/Parakeet local STT, local MLX/vMLX model catalog and downloads,
Runtime Lab-style inference controls, richer chat/tool rendering, and optional
hosted endpoint routing. The updated source state removes the old stale-checkout
caveat; it does not change the OpenClicky direction.

## Active Intake Principles

1. Preserve OpenClicky brand and surfaces.
2. Prefer OpenClicky's existing design tokens in `Packages/OpenClickyUI` and local
   panel/HUD patterns.
3. Keep provider routing aligned with the money rule: SDK/app-server first, direct
   API-key fallback only.
4. Favor small vertical slices that can be verified with `swiftc -parse` on touched
   Swift files.
5. Treat Osaurus speculative decoding as research-only until there is runtime proof.
6. Keep first-run settings simple: local voice/model defaults first, provider keys
   second, runtime/inference tuning behind an explicit power-user surface.

## Priority 0: Fix Before Expanding

- [x] Fix OpenAI/Codex voice-analysis routing in `CompanionManager.swift`.
  - Current review evidence says this path can use direct OpenAI before Codex.
  - Required shape: Codex/app-server first for Codex-capable text models, then
    OpenAI key fallback.
  - Keep the separate realtime speech exemption direct, because realtime voice is a
    different API path.
  - Implemented: `analyzeOpenAIOrCodexVoiceResponse` now tries Codex first for
    analysis models, falls back to direct OpenAI only with a configured key, and
    `voiceAnalysisModel(withID:)` no longer treats speech model IDs as analysis
    models.
- [ ] Harden `OpenClickyExternalControlBridge.swift` before adding more local
  integrations.
  - Keep `/health` useful but avoid leaking unnecessary pre-auth detail.
  - Keep token requirements for action endpoints.
  - Add clearer diagnostics for proxy, bridge, and MCP failures.
- [ ] Move any expensive Codex runtime/home preparation off the main actor before
  larger Agent HUD rendering work.

## Priority 1: Local Voice, Model Install, and Settings Simplification

### Osaurus Evidence To Adapt

- Local STT: `docs/VOICE_INPUT.md`, `SpeechModelManager.swift`,
  `SpeechService.swift`, and `VADService.swift` use FluidAudio with Parakeet TDT
  v3/v2 models, local VAD, off-main model probing, and a keep-alive audio engine
  path for fast handoff.
- Local model install: `ModelManager.swift`, `ModelDownloadService.swift`,
  `MLXModel.swift`, and `ModelDownloadView.swift` provide a real catalog/download
  system: curated top picks, Hugging Face-compatible repo import, disk-space
  preflight, pause/resume, file-size completion checks, external HF/LM Studio
  discovery, and nonblocking grid refresh.
- Current local Osaurus catalog evidence includes a newer top-pick spine around
  LFM2.5, Gemma 4 QAT/MXFP variants, DiffusionGemma, and Qwen 3.6 MTP entries.
  Treat those IDs as Osaurus-local catalog evidence only until OpenClicky validates
  availability from its own catalog or official sources.
- Onboarding: `OnboardingConfigureAIView.swift` has the useful pattern of an
  opinionated default local pick plus a hidden "more options" disclosure. Its
  local checkout defaults the lead card to hosted Osaurus, but OpenClicky should
  invert that hierarchy.
- Advanced runtime settings: `ServerSettingsTabContent.swift` groups connection,
  sampling, batching, cache, memory safety, decode performance, speculative/MTP,
  multimodal, tools, residency, power, and request-limit controls behind a
  sidebar with validation and an anchored save/reset bar.

### OpenClicky Anchors

- `BuddyTranscriptionProvider.swift` is the correct insertion point for local
  Parakeet/FluidAudio STT. The existing Apple Speech provider already uses
  on-device recognition when supported, and cloud STT providers remain optional.
- `BuddyDictationManager.swift` already captures audio before provider readiness,
  uses a 256-frame input tap, buffers early audio, and logs provider-open timing.
  Keep that latency shape.
- `OpenAIRealtimeSpeechClient` and `DeepgramVoiceAgentClient` are separate
  speech-to-speech paths. Do not collapse them into normal STT + TTS settings.
- `OpenClickySettingsWindowManager.swift` currently mixes everyday voice choices,
  provider keys, captions, pre-fire, and playback controls in one Voice section.
  That needs layering, not more rows.
- `CodexHomeManager.swift` already links default Codex auth and writes Codex config
  with ChatGPT auth preferred unless an OpenAI key is configured. `ClaudeAgentSDKAPI`
  already detects the local `claude` executable. Onboarding should surface these
  as detected local accelerators.

### Target First-Run Experience

- Default install:
  - Request only the permissions needed for the chosen flow.
  - Show "Detected Claude Code" when `claude` is available and "Detected Codex"
    when Codex auth/config can be prepared.
  - Default to local voice: download the recommended Parakeet model, select it,
    and test the mic in-place.
  - Default to a recommended local model only after validating current model IDs
    from the local catalog or official source. Do not ship hardcoded 2026 model
    identifiers without verification.
  - Keep a "Use GPT Realtime instead" upgrade path visible for users who configure
    OpenAI and want the lowest end-to-end spoken latency.
- Basic settings:
  - Voice on/off, input mode, current local STT model, local model status,
    permission status, response voice, and captions.
  - No API-key text fields in the basic view.
- Advanced settings:
  - OpenAI/Codex, Anthropic, Deepgram, ElevenLabs, Cartesia, AssemblyAI, custom
    OpenAI-compatible endpoints, remote MCP/provider connections, and Agent Mode
    working directory/model.
- Runtime Lab:
  - Sampling defaults, context/cache policy, model residency, memory safety,
    batching/concurrency, decode performance, MTP/speculative decoding, power, and
    diagnostics.
  - Hide until an explicit "Show Runtime Lab" toggle or similar power-user entry.

### Implementation Queue

- [ ] Add `OpenClickyLocalSpeechModelManager`.
  - Model states: not downloaded, downloading(progress/metrics), ready, failed.
  - Start with Parakeet TDT v3 as recommended and v2 as English-focused alternate,
    matching Osaurus's FluidAudio model split.
  - Probe model cache off the main actor and avoid launch-time filesystem walks.
- [ ] Add a `ParakeetTranscriptionProvider` behind `BuddyTranscriptionProvider`.
  - Use the existing dictation manager's early audio buffering.
  - Preserve `requiresSpeechRecognitionPermission = false` if FluidAudio only needs
    microphone permission.
  - Reuse Osaurus's VAD sensitivity ideas, but keep OpenClicky's settings copy and
    visual style.
- [ ] Add local voice setup to onboarding.
  - Single requirement row for microphone permission.
  - Single requirement row for local STT model download.
  - Test microphone button with live transcript before completion.
- [ ] Add a local model installer/catalog for OpenClicky.
  - Start with a small curated catalog, hardware-fit badge, storage preflight,
    pause/resume, delete, and "show in Finder".
  - Use Application Support/OpenClicky-managed storage by default.
  - Optionally discover HF/LM Studio caches read-only later; never mutate external
    cache folders without explicit user action.
- [ ] Add first-run local brain selection.
  - Pick the smallest comfortable recommended local model, not the biggest model
    that merely fits.
  - Pin the selected local model to default voice/agent routing after download.
  - If Claude Code or Codex is detected, show them as ready local accelerators and
    auto-configure existing OpenClicky runtime files.
- [ ] Split Settings into Basic, Advanced, and Runtime Lab.
  - Basic should be viable for nontechnical users.
  - Advanced owns keys/services.
  - Runtime Lab owns model/inference internals and should include validation,
    save/reset, and restart-required cues.

### Latency Guardrails

- Keep GPT Realtime as a direct speech-to-speech fast path when selected. It is
  intentionally not the same route as local STT + text model + TTS.
- Keep OpenClicky's audio capture-before-provider-ready behavior. Local STT must
  plug into that, not add a cold provider-start gap after the user starts talking.
- Preload the selected local STT model after onboarding and keep the audio engine
  warm during VAD-to-chat handoff where safe.
- Warm Claude Agent SDK and Codex app-server sessions opportunistically, but never
  block the UI waiting for them.
- Track at least: mic press to recording start, provider-open duration, first
  partial transcript, final transcript, first model token, first audio playback.
- Do not claim local model voice is as fast as GPT Realtime until we have measured
  first-audio latency on the same OpenClicky path.

### Speculative Scope

- OpenClicky's current "speculative pre-fire" is a voice UX optimization: start a
  likely response while speech is still stable. Keep it named and surfaced
  separately from model-level speculative decoding.
- Osaurus's `MTPSection.swift` is useful UI reference for native MTP controls, but
  `docs/MODEL_COMPATIBILITY_RESEARCH.md` still treats DFlash speculative decoding
  as design/proof work with no draft-model contract. OpenClicky should not expose
  DFlash-style controls until the runtime proves target/draft acceptance,
  cancellation, cache rollback, and token/sec benefit.

## Priority 2: Connectivity Intake

- [ ] Add an OpenClicky Connect layer for remote MCP providers.
  - Osaurus references: `docs/REMOTE_MCP_PROVIDERS.md`,
    `Packages/OsaurusCore/Managers/MCPProviderManager.swift`,
    `Packages/OsaurusCore/Models/MCP/MCPProviderTemplate.swift`.
  - OpenClicky anchors: `ClickyCodexConfigTemplate.swift`,
    `AppBundleConfiguration.swift`, `OpenClickyExternalControlBridge.swift`.
  - Take: provider catalog, OAuth/DCR flow shape, bearer/API-key modes, Keychain
    storage, provider-namespaced tool registration, safe diagnostics.
  - Avoid: hosted key sync, Google login, or forcing every user through a cloud
    account.
- [ ] Publish a runtime discovery file for OpenClicky.
  - Osaurus pattern: `~/.osaurus/runtime/<instanceId>/configuration.json`.
  - OpenClicky target: Application Support or `~/.openclicky/runtime/...`.
  - Include local bridge URL, port, health URL, app version, bridge token status
    without exposing the token.
- [ ] Add App Intents backed by OpenClicky's loopback bridge.
  - Osaurus reference: `docs/APP_INTENTS.md`.
  - Candidate intents: Ask OpenClicky, Run OpenClicky Agent, Capture Screen Context,
    Speak With OpenClicky.

## Priority 3: Automation, Memory, and Agents

- [ ] Upgrade OpenClicky automations with Osaurus schedule semantics.
  - OpenClicky anchor: `OpenClickyAutomationStore.swift`.
  - Take: explicit target agent, missed-run handling, pause/resume, source labels,
    external session key, and next-run display.
- [ ] Add folder watchers as OpenClicky agent triggers.
  - Osaurus reference: `docs/WATCHERS.md`.
  - Take: FSEvents monitoring, debounce modes, directory fingerprinting,
    convergence loop, and watcher-source session tagging.
- [ ] Design Memory v2 behind OpenClicky's existing Memory UI.
  - Osaurus reference: `docs/MEMORY.md`.
  - Take: identity overrides, pinned facts, episodes, transcript fallback,
    relevance gate, background consolidation, and a `search_memory` tool.
  - Keep: OpenClicky's wiki/skill/archive feel and product copy.
- [ ] Add lightweight per-agent scratch DB only after Memory v2 lands.
  - Osaurus reference: `docs/AGENT_DB.md`.
  - Start with one next-run slot and a small notes/table store before exposing full
    database tooling.

## Priority 4: Chat Rendering and Interaction Intake

OpenClicky should keep its visual style, but Osaurus has useful rendering mechanics.

- [ ] Define an OpenClicky message-block model for the Agent HUD.
  - Osaurus reference: `ContentBlock.swift`.
  - Take: flattened block identity, separate header/paragraph/tool/thinking/artifact
    rows, stable IDs, and cheap equality during streaming.
  - OpenClicky anchors: `CodexHUDWindowManager.swift`,
    `OpenClickyNotchPanelView.swift`, `CodexTranscriptEntry`.
- [ ] Replace raw transcript text rendering with native markdown/code rendering.
  - Osaurus references: `NativeMarkdownView.swift`, `NativeBlockViews.swift`,
    `MarkdownMessageView.swift`.
  - Take: selectable text, fenced code blocks, tables, images, math-ready segment
    boundaries, streaming cursor/fader behavior, width-aware height measurement.
  - Keep: OpenClicky's `DS.Colors`, response-caption font controls, bubble shape,
    and compact notch presentation.
- [ ] Evaluate adding `Highlightr` for syntax highlighting.
  - Osaurus uses `https://github.com/raspu/Highlightr` from `2.3.0`.
  - OpenClicky already has a first-party `Packages/OpenClickyMarkdown` package. It
    renders OpenClicky-owned Markdown documents and fenced code blocks, but it is
    not yet a streaming chat renderer or syntax highlighter.
  - First task is to extend/reuse `OpenClickyMarkdown` for chat blocks before
    adding another dependency.
  - Start with code blocks only. Do not add a broad editor dependency unless the HUD
    needs editing.
- [ ] Add first-class tool interaction rows.
  - Osaurus references: `NativeToolCallGroupView.swift`, `ToolDisplayName.swift`.
  - Take: grouped tool calls, category icons, JSON argument previews, result
    previews, duration chips, expand/collapse state, and terminal output handling.
  - Keep: OpenClicky's existing rounded command chips and quieter companion-app
    density.
- [ ] Add artifact cards for generated outputs.
  - Osaurus references: `SharedArtifact.swift`, `NativeArtifactCardView.swift`,
    `ShareArtifactTool.swift`.
  - OpenClicky fit: show files, images, reports, websites, and exported artifacts
    in the Agent HUD without forcing users to find hidden files on disk.
- [ ] Add clarify/choice chips for agent questions.
  - Osaurus references: `ClarifyPromptOverlay.swift`, `PromptCard.swift`.
  - Take: single-select chips, multi-select chips, free-form fallback, prompt queue
    so cards do not stack.
  - Keep: OpenClicky's overlay/panel language and avoid Osaurus modal chrome.
- [ ] Improve composer chips.
  - Osaurus references: `FloatingInputCard.swift`, `DocumentChip.swift`.
  - Take: queued-send chip, pending-skill chip, document/pasted-content chips,
    model/context/status chip family, and wrapping chip layout.
  - OpenClicky anchors: HUD attachment chips and notch quick-prompt chips.
- [ ] Add code-diff rendering as an OpenClicky-specific layer.
  - Osaurus exposes `git_diff` and renders code/terminal output well, but no
    dedicated chat diff-rendering library was found in its package graph.
  - Recommended OpenClicky path: parse unified diffs locally, render added/removed
    lines with OpenClicky colors, and use `Highlightr` only for fenced code syntax.
  - Avoid: importing a full code editor just to display diffs.
- [ ] Consider NSTableView-backed transcript rendering only if HUD performance needs it.
  - Osaurus references: `MessageThreadView.swift`, `MessageTableRepresentable.swift`,
    `NativeMessageCellView.swift`.
  - Take: diffable data source, cell reuse, scroll anchoring, debounced row height
    measurement, cached chart/tool subviews.
  - Start smaller in SwiftUI unless long sessions prove the current HUD needs
    AppKit table reuse.

## Priority 5: Hosted Endpoints and Privacy

- [ ] Optional hosted endpoint/router intake.
  - Osaurus reference: `docs/OSAURUS_ROUTER.md`.
  - Take only if OpenClicky needs hosted inference: OpenAI-compatible shape,
    idempotency keys, safe streaming repair, sanitized diagnostics, and
    metadata-only billing.
  - Keep local-key mode as the default.
- [ ] Add optional privacy filtering for cloud-bound text prompts.
  - Osaurus reference: `docs/PRIVACY_FILTER.md`.
  - Treat screenshots/images as a separate privacy problem; Osaurus's text filter is
    not enough for image payloads.
- [ ] Do not ship speculative decoding yet.
  - Osaurus references: `docs/INFERENCE_RUNTIME.md`,
    `docs/MODEL_COMPATIBILITY_RESEARCH.md`.
  - Required before adoption: draft/target contract, acceptance metrics, benchmark
    proof, cancellation/unload proof, and feature flag.

## Deferred or Avoid

- Do not copy Osaurus's full local model server into OpenClicky without a separate
  provider/runtime plan.
- Do not copy Osaurus's full plugin C ABI before remote MCP/provider connectivity
  proves the need.
- Do not copy Osaurus identity/secure-channel/relay unless OpenClicky exposes
  remote agent access beyond loopback.
- Do not bulk-copy Clicky or Osaurus skill trees over OpenClicky's current bundled
  skills.

## Immediate Next Implementation Queue

1. Add local voice/model onboarding scaffolding and detection cards for Claude Code
   and Codex.
2. Add `OpenClickyLocalSpeechModelManager` and a Parakeet transcription provider.
3. Add a small local model catalog/download manager with storage preflight.
4. Split Settings into Basic, Advanced, and Runtime Lab.
5. Add an OpenClicky runtime discovery file writer.
6. Add a small OpenClicky message-block model for the Agent HUD.
7. Extend `Packages/OpenClickyMarkdown` for HUD chat/code rendering behind the
   current OpenClicky style.
8. Add richer tool-call rows and artifact cards.
9. Add App Intents over the existing OpenClicky bridge.
10. Add remote MCP provider connection settings.
11. Upgrade automations and memory.
