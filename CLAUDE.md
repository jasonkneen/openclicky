# OpenClicky Agent Instructions

## Non-Negotiable Rules

1. Check model validity before making assumptions about current model releases or identifiers.
2. Never use emoji unless the user explicitly asks for them.
3. Do not run `xcodebuild` from the terminal. Use Xcode for app builds and permission testing.
4. Do not rename the legacy `cursor-buddy` project folder or scheme unless the user explicitly asks.

## Overview

OpenClicky is a macOS menu-bar companion app by Jason Kneen. It uses SwiftUI with AppKit bridging for a custom floating panel, cursor overlay, Agent Mode dashboard, and macOS permission flows.

The product identity is OpenClicky:

- Bundle identifier: `com.jkneen.openclicky`
- Display name: `OpenClicky`
- Copyright: Jason Kneen

## Architecture

- App type: menu-bar app using `LSUIElement=true`
- Frameworks: SwiftUI, AppKit, AVFoundation, ScreenCaptureKit
- Pattern: `@MainActor` state orchestration with observable SwiftUI views
- Voice input: push-to-talk via a global CGEvent tap and pluggable transcription providers
- Voice response: Claude through Anthropic API-key configuration
- Text-to-speech: ElevenLabs through local key configuration
- Screen context: ScreenCaptureKit screenshots when the user invokes help
- Agent Mode: bundled Codex runtime and OpenClicky resource pack in `AppResources/OpenClicky`

## Key Files

- `cursor-buddy/cursor_buddyApp.swift`: app entry point and delegate hookup.
- `cursor-buddy/CompanionManager.swift`: central app state machine for voice, screen capture, Claude, TTS, overlay, settings, and Agent Mode.
- `cursor-buddy/MenuBarPanelManager.swift`: menu-bar item and floating panel lifecycle.
- `cursor-buddy/CompanionPanelView.swift`: main OpenClicky panel and settings subscreen.
- `cursor-buddy/OverlayWindow.swift`: cursor overlay, agent dock icons, captions, and response cards.
- `cursor-buddy/CodexHUDWindowManager.swift`: Agent Mode dashboard window.
- `cursor-buddy/CodexHomeManager.swift`: prepares the local Codex home using OpenClicky bundled resources.
- `cursor-buddy/ClickyCodexConfigTemplate.swift`: renders Codex configuration for OpenClicky Agent Mode.
- `cursor-buddy/ClickyNextStageParityModels.swift`: knowledge index, permission guide, response-card, and handoff support models.
- `AppResources/OpenClicky/`: bundled Agent Mode instructions, skills, wiki seed, runtime, and completion sound.

## Configuration

OpenClicky should use local keys and user configuration. Do not add Google login or hosted key sync:

- `ANTHROPIC_API_KEY` for Claude responses
- `ELEVENLABS_API_KEY` for ElevenLabs TTS
- `OPENAI_API_KEY` for Codex/Agent Mode where needed

Do not introduce a hard dependency on a Cloudflare Worker for the final app.

## Inference Routing

Two independent layers — keep them straight:

1. **Provider selection (driven by Settings).** Every model in `OpenClickyModelCatalog` carries a `provider` (`.anthropic` / `.openAI` / `.codex` / `.deepgram`). `CompanionManager.analyzeVoiceResponse` and the element-pointing path switch on the selected model's provider to choose the backend family:
   - `.anthropic` -> Claude (`ClaudeAgentSDKAPI` then `ClaudeAPI`)
   - `.openAI` -> `OpenAIAPI`
   - `.codex` -> `CodexVoiceSession` / `CodexPointDetector` (selecting e.g. `gpt-5.5` means Codex handles it)
   - `.deepgram` -> Deepgram Voice Agent
   - `.localOpenAICompatible` -> `LocalChatCompletionsAPI` (Ollama / LM Studio / MLX / llama.cpp via `/v1/chat/completions`); element pointing uses `LocalElementLocationDetector`. Local model ids are namespaced `local:<id>`; the catalog resolves them ahead of the cloud fallback. Config lives in `LocalModelSettingsStore`.
   - `.appleFoundation` -> `AppleFoundationModelClient` (Apple on-device `FoundationModels`, text-only, behind `#if canImport(FoundationModels)` + macOS 26 availability). Fixed id `apple-foundation`; no vision (the voice path drops images with a one-line note).
2. **Within-provider ordering (money rule).** For the Claude branch, the Claude Agent SDK is the PRIMARY path because it uses the local Claude Code sign-in already paid for. Direct `ClaudeAPI` HTTP is FALLBACK ONLY (SDK nil or throws). Never short-circuit to direct REST for latency or capability reasons — direct REST bills per token. The OpenAI/Codex branch follows the same shape: Codex app server first, OpenAI key fallback. EXEMPTION: the OpenAI realtime voice API (`gpt-realtime-2` / `gpt-realtime-1.5`, the bidirectional `OpenAIRealtimeSpeechClient` path) cannot run through the Codex app server and must use the direct API; everything after the realtime turn (gpt-5.x / codex models, including realtime IDs remapped by `voiceAnalysisModel(withID:)`) goes app-server-first.

Do not delete `ClaudeAPI.swift` or the HTTP path — it is the deliberate fallback. Before editing any Claude/OpenAI call site, confirm the order is SDK/app-server -> key fallback.

LOCAL EXEMPTION: `.localOpenAICompatible` and `.appleFoundation` are DIRECT by design. There is no paid cloud call to protect, so the SDK/app-server-first ordering does not apply to them. An explicitly-selected local model must never silently fall back to a billed cloud model — surface the error (e.g. "is Ollama running?") instead. This is the same shape of narrow exemption as the realtime-voice case above.


## Development Rules

- Prefer existing design-system tokens and local view patterns.
- Keep UI state updates on the main actor.
- Use async/await for asynchronous work.
- Use AppKit only where SwiftUI cannot provide the needed macOS behavior.
- Keep changes scoped to the requested behavior.
- Preserve user or generated changes in the worktree unless explicitly told to revert them.
- User-facing copy should use the OpenClicky product name.

## Verification

Use lightweight checks that do not disturb macOS permissions:

```sh
swiftc -parse <relevant Swift source files>
```

Do not launch unsigned or throwaway builds for TCC permission testing.
