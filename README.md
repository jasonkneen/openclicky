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

## License

MIT. Copyright 2026 Jason Kneen.
