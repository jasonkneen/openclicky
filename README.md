# OpenClicky

OpenClicky is a native macOS menu-bar companion by Jason Kneen. It provides push-to-talk voice help, screen-aware responses, a cursor overlay for pointing at UI elements, and an Agent Mode dashboard for coding, research, writing, and automation tasks.

OpenClicky uses local configuration only. There is no Google login requirement and no hosted key-sync flow.

## Requirements

- macOS 14.2 or newer
- Xcode with the macOS SDK
- A signing team configured in Xcode for local runs
- Local API keys supplied outside the repository

## Repository Layout

- `leanring-buddy.xcodeproj` and `leanring-buddy/` contain the macOS app target.
- `leanring-buddyTests/` contains focused app tests.
- `leanring-buddyUITests/` contains UI test scaffolding.
- `AppResources/OpenClicky/` contains bundled model instructions, skills, wiki seed, Codex runtime, and completion audio.
- `appcast.xml`, `clicky-demo.gif`, and `dmg-background.png` support distribution and release packaging.
- `docs/APP_UPDATES.md` documents the Sparkle update feed and direct-distribution release flow.

The legacy `leanring-buddy` folder and scheme names are kept for project continuity. The product, bundle display name, and app identity are OpenClicky.

## Secrets

Do not commit API keys to this repository.

OpenClicky can read local secrets from:

- the in-app Settings fields
- launch environment variables
- a secrets file at `~/.config/openclicky/secrets.env`
- a custom file path set with `OPENCLICKY_SECRETS_FILE`

Supported values:

```sh
ANTHROPIC_API_KEY=your_anthropic_key
ELEVENLABS_API_KEY=your_elevenlabs_key
ELEVENLABS_VOICE_ID=your_elevenlabs_voice_id
OPENAI_API_KEY=your_openai_or_codex_key
```

Recommended local setup:

```sh
mkdir -p ~/.config/openclicky
chmod 700 ~/.config/openclicky
$EDITOR ~/.config/openclicky/secrets.env
chmod 600 ~/.config/openclicky/secrets.env
```

The repo `.gitignore` excludes `.env` and `.env.local`, but the app no longer reads repo-local `.env` files. Keep secrets outside the project directory.

## Build And Run

Open the project in Xcode:

```sh
open leanring-buddy.xcodeproj
```

In Xcode:

1. Select the `leanring-buddy` scheme.
2. Select the OpenClicky app target.
3. Set your signing team.
4. Run the app with `Cmd+R`.
5. Grant Accessibility, Microphone, and Screen Recording permissions when macOS asks.

Do not use terminal `xcodebuild` for permission testing. macOS TCC permissions are tied to the signed app identity and install path, and throwaway command-line builds can cause permission loops.

## Development Verification

For a lightweight syntax check that does not disturb macOS permissions, run `swiftc -parse` over the changed source files. Avoid launching unsigned or temporary build products for permission testing.

The external-control bridge can be checked with:

```sh
scripts/test-external-control-bridge.sh
```

The script performs Swift parse/typecheck checks, verifies the local bridge, exercises MCP descriptors, screenshot capture, captions, secondary cursors, SSE events, and confirms that primary cursor guidance uses OpenClicky's native choreography without warping the real system pointer.

## External Control Bridge

OpenClicky exposes a local-only control bridge for agents and other trusted local apps:

```text
http://127.0.0.1:32123
```

The bridge is intentionally non-invasive. It drives OpenClicky's overlay, screenshots, and TTS, but does not start dictation, submit prompts, create new agent sessions, or mutate the normal OpenClicky conversation state.

Useful endpoints:

- `GET /health` checks bridge status.
- `GET /mcp/tools` lists MCP-style tool descriptors.
- `POST /cursor` points with the primary OpenClicky cursor, or creates one secondary marker with `mode: "secondary"`.
- `POST /cursors` shows multiple temporary secondary markers at once.
- `POST /caption` shows a short caption near a coordinate or the current cursor.
- `POST /screenshot` captures local screenshots with display-frame metadata for locating UI.
- `POST /speak` speaks through OpenClicky's TTS without entering voice mode.
- `POST /clear` clears bridge-created overlay elements.
- `GET /events` streams server-sent bridge events.

Primary cursor behavior matters: default `/cursor` uses OpenClicky's existing smooth pointing choreography, the same behavior used by voice prompts like "show me the Apple menu". The OpenClicky triangle zips to the target, shows the caption, and returns to the real pointer. It should not warp the macOS pointer and should not draw a duplicate primary cursor.

Secondary cursors are explicit temporary markers. Use them for multi-point explanations, alternatives, or screen-tour overlays. They automatically disappear after `durationMs` or can be cleared with `/clear`.

Example primary pointer cue:

```sh
curl -s -X POST http://127.0.0.1:32123/cursor \
  -H 'Content-Type: application/json' \
  -d '{"x":640,"y":520,"caption":"Click this menu","durationMs":4500}'
```

Example simultaneous multi-marker cue:

```sh
curl -s -X POST http://127.0.0.1:32123/cursors \
  -H 'Content-Type: application/json' \
  -d '{"durationMs":4500,"cursors":[{"x":640,"y":520,"caption":"Editor","accentHex":"#60A5FA"},{"x":900,"y":520,"caption":"Logs","accentHex":"#F59E0B"}]}'
```

Example screenshot-to-pointer workflow:

```sh
curl -s -X POST http://127.0.0.1:32123/screenshot \
  -H 'Content-Type: application/json' \
  -d '{"focused":false}'

curl -s -X POST http://127.0.0.1:32123/cursor \
  -H 'Content-Type: application/json' \
  -d '{"x":1180,"y":760,"caption":"Use this button"}'
```

Bundled agent skills for this bridge live in `AppResources/OpenClicky/OpenClickyBundledSkills/`:

- `openclicky-screen-control`: quick point, caption, screenshot, speak, and clear commands.
- `openclicky-screen-tour`: recordable visual tours with multiple simultaneous markers, area-focused overlays, speech, and primary cursor choreography.

## Swift SDK Embedding (Windowed)

For Swift hosts that want an in-window OpenClicky instance that is separate from the OS-level menu-bar companion, use `OpenClickySDKSession` from `leanring-buddy/OpenClickySDK.swift`.

Example:

```swift
import SwiftUI

let sdk = OpenClickySDKSession(mode: .embeddedWindow)

// In app startup
sdk.start()

// In SwiftUI
var body: some View {
    sdk.makePanelView(actions: .init(
        onPanelDismiss: { /* dismiss host panel */ },
        onQuit: { /* close host window if needed */ }
    ))
}

// Send input
sdk.submitTextPrompt("Summarize this page")
```

The host can either use SDK actions for Settings/HUD/Memory, or keep them no-op and route that experience separately.

See [OpenClicky SDK Integration Guide](docs/OpenClickySDKIntegration.md) for step-by-step host app integration instructions.

## Direct Updates

OpenClicky uses Sparkle for direct-distribution OTA updates. Installed builds check the signed `appcast.xml` feed from this repository's `main` branch, then download and install signed release DMGs from GitHub Releases. See [docs/APP_UPDATES.md](docs/APP_UPDATES.md) for the release checklist and appcast item template.

## Credits And Upstream Work

OpenClicky is maintained by [Jason Kneen](https://github.com/jasonkneen).

This project builds on the original open-source Clicky work:

- Original project: [farzaa/clicky](https://github.com/farzaa/clicky)
- Original creator: Farza, GitHub [@farzaa](https://github.com/farzaa), X [@FarzaTV](https://x.com/farzatv)

OpenClicky has also incorporated ideas and implementation patterns from these forks:

- [@danpeg](https://github.com/danpeg)'s [danpeg/clicky](https://github.com/danpeg/clicky), reviewed locally as `clicky-teach`, for tutor-mode direction and idle observation behavior.
- [@milind-soni](https://github.com/milind-soni)'s [milind-soni/tiptour-macos](https://github.com/milind-soni/tiptour-macos), for developer-menu/debug tooling patterns and related teaching-assistant UX ideas.

## License

MIT. Copyright 2026 Jason Kneen. Portions are derived from or informed by the upstream MIT-licensed projects credited above.
