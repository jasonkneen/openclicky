# OpenClicky Agent Instructions

## Non-Negotiable Rules

1. Check model validity before making assumptions about current model releases or identifiers.
2. Never use emoji unless the user explicitly asks for them.
3. Do not run `xcodebuild` from the terminal. Use Xcode for app builds and permission testing.
4. Do not rename the legacy `leanring-buddy` project folder or scheme unless the user explicitly asks.

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

- `leanring-buddy/leanring_buddyApp.swift`: app entry point and delegate hookup.
- `leanring-buddy/CompanionManager.swift`: central app state machine for voice, screen capture, Claude, TTS, overlay, settings, and Agent Mode.
- `leanring-buddy/MenuBarPanelManager.swift`: menu-bar item and floating panel lifecycle.
- `leanring-buddy/CompanionPanelView.swift`: main OpenClicky panel and settings subscreen.
- `leanring-buddy/OverlayWindow.swift`: cursor overlay, agent dock icons, captions, and response cards.
- `leanring-buddy/CodexHUDWindowManager.swift`: Agent Mode dashboard window.
- `leanring-buddy/CodexHomeManager.swift`: prepares the local Codex home using OpenClicky bundled resources.
- `leanring-buddy/ClickyCodexConfigTemplate.swift`: renders Codex configuration for OpenClicky Agent Mode.
- `leanring-buddy/ClickyNextStageParityModels.swift`: knowledge index, permission guide, response-card, and handoff support models.
- `AppResources/OpenClicky/`: bundled Agent Mode instructions, skills, wiki seed, runtime, and completion sound.

## Configuration

OpenClicky should use local keys and user configuration. Do not add Google login or hosted key sync:

- `ANTHROPIC_API_KEY` for Claude responses
- `ELEVENLABS_API_KEY` for ElevenLabs TTS
- `OPENAI_API_KEY` for Codex/Agent Mode where needed

Do not introduce a hard dependency on a Cloudflare Worker for the final app.

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
