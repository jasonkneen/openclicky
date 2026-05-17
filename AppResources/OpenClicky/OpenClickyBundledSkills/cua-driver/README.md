# cua-driver — OpenClicky Computer Use skill

OpenClicky's bundled Computer Use skill teaches Codex agents to drive
native macOS apps through the local `computer-use` MCP server, backed
by [`cua-driver`](https://github.com/trycua/cua/tree/main/libs/cua-driver).
Agents snapshot an app's accessibility tree, act by `element_index`
where possible, and verify via re-snapshot. Backgrounded-first: no
focus steal, no cursor warp, no Space follow.

This copy is product-managed inside OpenClicky. Do not ask users to
install `CuaDriver.app`, run the standalone `cua-driver` CLI, or
change their browser profile. OpenClicky ships its own helper binary
inside `OpenClicky.app`, inherits OpenClicky's Accessibility and Screen
Recording grants, and exposes a curated MCP tool subset.

## What the skill covers

- The snapshot-before-AND-after invariant that keeps the agent honest
  about whether an action actually landed.
- The backgrounded-click recipe (yabai focus-without-raise + stamped
  SLEventPostToPid) that lets synthetic clicks land on Chrome web
  content without raising the window or pulling the user across Spaces.
- Web-app quirks (`WEB_APPS.md`) — Chromium/WebKit/Electron/Tauri,
  including the minimized-Chrome keyboard-commit caveat and the
  non-omnibox `set_value` workaround for ordinary fields.
- Trajectory recording (`RECORDING.md`) — upstream reference only in
  this build. OpenClicky's default runtime does not expose recording or
  replay tools.
- Canvas/viewport apps (Blender, Unity, GHOST, Qt, wxWidgets) —
  diagnostic guidance only in this build. OpenClicky's default runtime blocks
  coordinate clicks and does not expose pixel/recording/replay tools; stop and
  explain the missing capability instead of guessing.

See `SKILL.md` for the main body.

## Runtime prerequisites

1. **macOS 14 or newer**.
2. **OpenClicky permissions**: Accessibility and Screen Recording granted
   to OpenClicky.app during onboarding.
3. **Bundled helper present**:
   `OpenClicky.app/Contents/Helpers/OpenClickyComputerUseRuntime`.

## Invoking the skill

Codex auto-invokes the skill when the user asks for macOS GUI
automation, browser use, or background app control — e.g. "open the
Downloads folder in Finder", "click the Save button in Numbers", or
"navigate to trycua.com in my browser".

## Files

- `SKILL.md` — the main skill body (~500 lines). Loaded on first
  invocation; stays in context for the session.
- `WEB_APPS.md` — browsers, Electron, Tauri (Chromium + WebKit). Loaded
  on demand when SKILL.md's pointer is followed.
- `RECORDING.md` — upstream trajectory recording / replay reference.
  OpenClicky's default runtime does not expose these tools.
- `TESTS.md` — manual test scripts for end-to-end skill verification.

## Troubleshooting

- Missing Computer Use tools → verify the bundled helper exists and
  the runtime config registers `[mcp_servers.computer-use]`.
- `No cached AX state for pid X window_id W` → element_index was
  reused across turns, or across different windows of the same app.
  Call `get_window_state({pid, window_id})` first in the same turn,
  with the same window_id you're about to act against.
- Empty `tree_markdown` → `capture_mode` may be set to `vision`, which
  skips the AX walk by design. Prefer the default `som` mode for app
  control.
  Tiny screenshot → likely a stale window capture. See "Behavior
  matrix" in SKILL.md for the full mode table.
- System-alert beep when pressing Return in a minimized browser →
  the keyboard-commit-on-minimized limitation. For URL navigation,
  use `launch_app({bundle_id, urls:[...]})`; for normal page forms,
  use `set_value` on the field or AX-click a Go/Submit button. See
  `WEB_APPS.md`.

## Updates

The skill evolves alongside the driver. In OpenClicky, update it through
the bundled runtime upgrade path: bump
`OpenClickyComputerUseRuntime/Package.swift`, sync the upstream skill docs,
then re-apply OpenClicky's managed-runtime guardrails.

## License

MIT. Same license as the parent `trycua/cua` repo.
