# Osaurus to OpenClicky Intake Backlog

Status: living backlog, created from the local Osaurus checkout at
`/Users/jkneen/Documents/GitHub/osaurus`.

Important source constraints:

- The local Osaurus checkout is currently behind `origin/main` by 52 commits, so every
  observation here is from the local tree, not a refreshed remote.
- OpenClicky has a dirty worktree from prior Clicky skill migration work. Do not bulk
  overwrite existing OpenClicky resources.
- Keep the OpenClicky product shape: menu-bar companion, notch/panel UI, cursor
  overlay, Agent Mode dashboard, local keys, and OpenClicky visual language.
- Do not import Osaurus's management-app shell. Import behavior, data models, and
  rendering techniques only where they improve OpenClicky.

## Active Intake Principles

1. Preserve OpenClicky brand and surfaces.
2. Prefer OpenClicky's existing design tokens in `Packages/OpenClickyUI` and local
   panel/HUD patterns.
3. Keep provider routing aligned with the money rule: SDK/app-server first, direct
   API-key fallback only.
4. Favor small vertical slices that can be verified with `swiftc -parse` on touched
   Swift files.
5. Treat Osaurus speculative decoding as research-only until there is runtime proof.

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

## Priority 1: Connectivity Intake

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

## Priority 2: Automation, Memory, and Agents

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

## Priority 3: Chat Rendering and Interaction Intake

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
  - OpenClicky currently has no dedicated syntax/diff-rendering dependency found
    in the local project search.
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

## Priority 4: Hosted Endpoints and Privacy

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

1. Add an OpenClicky runtime discovery file writer.
2. Add a small OpenClicky message-block model for the Agent HUD.
3. Add markdown/code block rendering behind the current OpenClicky HUD style.
4. Add richer tool-call rows and artifact cards.
5. Add App Intents over the existing OpenClicky bridge.
6. Add remote MCP provider connection settings.
7. Upgrade automations and memory.
