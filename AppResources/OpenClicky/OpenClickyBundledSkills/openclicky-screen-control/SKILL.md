---
name: openclicky-screen-control
description: Instantly control OpenClicky's local overlay bridge to point on screen, show captions, or speak through OpenClicky's voice. Use when the user says "show me where you mean", "show me how to", "how do I do this", "point to it", "highlight that", "say this", or asks for visual on-screen guidance.
version: 1.1.0
argument-hint: "[what to show or say]"
---

Use OpenClicky's local external-control bridge for immediate visual guidance. Do this instead of describing where to look when the user asks you to show them.

## Transport

Local-only HTTP/SSE bridge:

```text
http://127.0.0.1:32123
```

Health check:

```bash
curl -s http://127.0.0.1:32123/health
```

The bridge is designed to be fast and non-invasive: commands only drive OpenClicky's proxy overlay/voice layer and do not start dictation, submit prompts, create agent sessions, or mutate the main app conversation.

Important cursor model:
- OpenClicky's cursor is the little triangle that normally follows the user's real system pointer.
- Default `/cursor` uses OpenClicky's native smooth pointing choreography: the triangle zips to the target, captions it, then flies back. It does not warp the real macOS pointer and does not draw a duplicate primary cursor icon.
- Use `mode: "secondary"` only when you intentionally want an extra temporary colored pointer. Secondary pointers disappear automatically.

## Coordinates

Use macOS/AppKit screen coordinates: origin at the bottom-left of the global desktop. Use screenshot context, window geometry, or visible UI positions to estimate points. It is better to point approximately immediately than to spend a long time calculating.

## Fast commands

### Point at a location with the primary cursor

```bash
curl -s -X POST http://127.0.0.1:32123/cursor \
  -H 'Content-Type: application/json' \
  -d '{"x": 640, "y": 520, "caption": "Click here", "durationMs": 4500}'
```

Optional fields:
- `caption`: short text shown beside OpenClicky's primary cursor
- `durationMs`: how long to keep the caption visible; default is about 4s
- `travelMs`: accepted for compatibility, but primary cursor motion uses OpenClicky's native smooth pointing choreography.
- `accentHex`: caption color, e.g. `#60A5FA`
- `mode`: default `primary`; use `secondary` only for an extra temporary pointer

### Show extra temporary cursors

Use this when showing multiple possible locations or comparing alternatives. These are additional colored OpenClicky-style cursors, not the user's primary pointer.

```bash
curl -s -X POST http://127.0.0.1:32123/cursors \
  -H 'Content-Type: application/json' \
  -d '{"cursors":[{"x":640,"y":520,"caption":"Option A","accentHex":"#60A5FA"},{"x":900,"y":520,"caption":"Option B","accentHex":"#34D399"}],"durationMs":4500}'
```

Or a single secondary cursor:

```bash
curl -s -X POST http://127.0.0.1:32123/cursor \
  -H 'Content-Type: application/json' \
  -d '{"x": 640, "y": 520, "caption": "Look here", "mode": "secondary"}'
```

### Show a caption near a point

```bash
curl -s -X POST http://127.0.0.1:32123/caption \
  -H 'Content-Type: application/json' \
  -d '{"x": 900, "y": 700, "text": "This is the setting you want", "durationMs": 5000}'
```

If `x`/`y` are omitted, OpenClicky shows the caption near the current mouse location.

### Capture screenshots to locate something

When you need to find something before showing it, request screenshots first. The response includes local JPEG paths and display frame metadata in the same AppKit coordinate space used by `/cursor`.

```bash
curl -s -X POST http://127.0.0.1:32123/screenshot \
  -H 'Content-Type: application/json' \
  -d '{"focused": false}'
```

Use `focused: true` to capture only the focused window when possible.

Workflow: capture screenshot → inspect/recognize target → call `/cursor` with a short caption.

### Speak without entering voice mode

```bash
curl -s -X POST http://127.0.0.1:32123/speak \
  -H 'Content-Type: application/json' \
  -d '{"text": "Click the button in the top right."}'
```

If OpenClicky is already speaking, this returns HTTP 409 unless `interrupt: true` is passed. Prefer not to interrupt unless the user explicitly wants the new instruction spoken now.

### Clear the proxy overlay

```bash
curl -s -X POST http://127.0.0.1:32123/clear
```

## MCP-style tool endpoints

List descriptors:

```bash
curl -s http://127.0.0.1:32123/mcp/tools
```

If your runtime wants one generic tool-call shape, use:

```bash
curl -s -X POST http://127.0.0.1:32123/mcp/call \
  -H 'Content-Type: application/json' \
  -d '{"tool":"show_cursor","arguments":{"x":640,"y":520,"caption":"This one"}}'
```

Supported tool names:
- `show_cursor`
- `show_cursors`
- `show_caption`
- `screenshot`
- `speak`
- `clear`

JSON-RPC style MCP calls are also accepted:

```bash
curl -s -X POST http://127.0.0.1:32123/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show_cursor","arguments":{"x":640,"y":520,"caption":"This one"}}}'
```

## SSE status stream

For another app that wants acknowledgements:

```bash
curl -N http://127.0.0.1:32123/events
```

## Behavior rules

When the user says "show me where you mean", "show me how to", "how do I do this", "point to it", or similar:

1. If you already know the coordinate, immediately call `/cursor` with the best available coordinate.
2. If you do not know the coordinate, immediately call `/screenshot`, inspect it, then call `/cursor`.
3. Keep captions short: 3-8 words is ideal.
4. Do not start a new agent just to point.
5. Do not narrate a long explanation first; show the on-screen cue first, then add text only if needed.
6. If exact coordinates are unknown, point to the approximate region and say what to look for.

Example response flow:

```bash
curl -s -X POST http://127.0.0.1:32123/cursor \
  -H 'Content-Type: application/json' \
  -d '{"x":1180,"y":760,"caption":"Use this menu", "durationMs":5000}'
```

Then reply briefly: "Shown on screen."
