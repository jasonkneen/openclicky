---
name: openclicky-guided-tutorials
description: Use OpenClicky's proper pointing tool calls, screenshots, captions, speech, and multi-call bridge to walk the user through visible macOS or app workflows step by step. Use when the user asks "how do I", "walk me through", "show me where", "tutorial", "teach me", or asks for guided help such as sending something with AirDrop.
version: 1.0.0
argument-hint: "[workflow to teach]"
---

## OpenClicky compatibility guardrails

- Follow `../_shared/OpenClickySkillCompatibilityPolicy.md` before acting.
- Verify required local commands, tools, keys, or bridge endpoints before promising execution.
- Treat sends, publishes, deploys, deletes, moves, merges, playlist/library changes, cloud writes, and app-control clicks as external writes unless this skill narrows them further.
- Stop and report the exact missing setup step for unavailable tools, auth, or macOS permissions; do not loop or silently switch to browser automation.

Use OpenClicky's local external-control bridge as a real tool surface for guided tutorials. Do not fake pointing with hidden text tags when tool calls are available.

## Tool surface

Bridge base URL:

```text
http://127.0.0.1:32123
```

Health and tool discovery:

```bash
curl -s http://127.0.0.1:32123/health
curl -s http://127.0.0.1:32123/mcp/tools
```

Primary tools:

- `openclicky_point`: point OpenClicky's native cursor at one screen coordinate with a short caption.
- `openclicky_point_many`: show several temporary secondary cursors at once.
- `screenshot`: capture screen/window context and display-frame metadata.
- `show_caption`: place a caption near a point.
- `show_scribble`: draw a temporary freehand path over visible current-screen content when `visual_guidance.scribble` is supported.
- `show_highlight` / `show_rectangle`: draw a temporary rectangle highlight over visible current-screen content when `visual_guidance.rectangle` is supported.
- `speak`: speak a short instruction through OpenClicky.
- `clear`: remove stale overlay markers.

Compatibility aliases still work: `show_cursor`, `show_cursors`, `openclicky_show_cursor`, and `openclicky_show_cursors`.

## Coordinate rule

Tool calls use macOS/AppKit global screen coordinates, origin at the bottom-left of the global desktop. Screenshot responses include frame metadata in that coordinate space.

If you only have screenshot pixel coordinates, convert them into the screenshot's display frame before calling `openclicky_point`.

## Single-step pointing

When the next visible target is known and directly relevant to the current tutorial step, call the tool first, then answer briefly. If the target is not visible or you are unsure it is the right target, do not point; ask for the missing context or describe the next step in text.

```bash
curl -s -X POST http://127.0.0.1:32123/mcp/call \
  -H 'Content-Type: application/json' \
  -d '{"tool":"openclicky_point","arguments":{"x":820,"y":760,"caption":"Click Share","durationMs":4500}}'
```

## Multi-tool tutorial sequence

For multi-step tutorials, use multiple tool calls in order. Either call the tools one by one as each step becomes relevant, or batch a short scene through `/mcp/calls` when the steps are known.

```bash
curl -s -X POST http://127.0.0.1:32123/mcp/calls \
  -H 'Content-Type: application/json' \
  -d '{
    "calls": [
      {"tool":"clear","arguments":{}},
      {"tool":"speak","arguments":{"text":"First, open the Share menu for the item you want to send.","interrupt":true}},
      {"tool":"openclicky_point","arguments":{"x":820,"y":760,"caption":"Share menu","durationMs":3500}},
      {"tool":"show_caption","arguments":{"x":820,"y":720,"text":"Choose AirDrop from this menu.","durationMs":4500},"delayMs":800}
    ]
  }'
```

Use short delays only for visual pacing. Do not batch a long tutorial that depends on what the user does next; wait, recapture, then point at the next actual target.

## Screenshot-driven workflow

When the target is not known:

1. Call `screenshot` with `focused: true` for the active app, or `focused: false` for all screens.
2. Inspect the returned screenshot path and display frame.
3. Pick the visible target only if it directly matches the next step the user asked about.
4. Call `openclicky_point` with a short caption, or do not point if the relevant target is missing or ambiguous.
5. Speak or write one concise instruction.
6. After the user completes the step, repeat from screenshot if the UI changed.

```bash
curl -s -X POST http://127.0.0.1:32123/mcp/call \
  -H 'Content-Type: application/json' \
  -d '{"tool":"screenshot","arguments":{"focused":true}}'
```

## Example: AirDrop on a Mac

If the user asks, "how can I send something via AirDrop on my Mac":

- Ask them to select or open the file/photo/webpage only if there is no visible item to send.
- If a share button or context menu is visible, point there immediately.
- Otherwise explain the standard path: select the item, use Share, choose AirDrop, pick the recipient.
- Use OpenClicky's pointer for each visible next target rather than dumping all steps at once.

Suggested flow:

1. Capture the focused window.
2. Point at the selected item or Share button: caption `Share this`.
3. Speak: `Open the Share menu, then choose AirDrop.`
4. After the menu appears, capture again.
5. Point at `AirDrop` in the menu.
6. After the AirDrop sheet appears, point at the recipient.
7. Remind the user that both devices need AirDrop enabled and nearby if no recipient appears.

## Tutorial behavior rules

- Prefer one visible next step over a long abstract checklist.
- Point only at UI that is directly relevant to the current step; never mark unrelated controls just because they are visible.
- Use `openclicky_point` as the normal pointing tool call.
- Use `openclicky_point_many` only when comparing or marking several choices.
- Use `speak` for short spoken prompts, not long lectures.
- Use `clear` before changing scenes.
- Do not click or type unless the user asked OpenClicky to perform the action; this skill is for teaching and pointing.
- Keep captions to one to four words when possible.
- For safety or permission prompts, point and explain; let the user confirm.

## Current visual tool boundary

Guided tutorials should use the existing point, multi-point, caption, screenshot, speak, clear, scribble, and rectangle highlight bridge commands. When the user asks to highlight or draw, verify `/health` reports the matching visual guidance capability as `supported` and `show_scribble`, `show_highlight`, or `show_rectangle` appears in `/mcp/tools`, then use temporary overlays on visible current-screen targets.

Do not use coordinate clicks as tutorial steps unless the user asked OpenClicky to perform the action rather than show it.
