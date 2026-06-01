# OpenClicky Skill Compatibility Policy

This policy applies to bundled skills when they run inside OpenClicky Agent Mode.

## Current Runtime Boundaries

- Agent Mode runs Codex with local filesystem and shell access, but skills must still respect explicit user intent, app-level policy, and macOS permission prompts.
- OpenClicky's native capabilities include local files, shell commands, web/current research when available, screenshots supplied by OpenClicky, local computer-use backends, the external visual bridge, local keys, and artifact handoff metadata.
- Do not assume provider-backed image generation, video generation, slide rendering, Spotify tools, Google Workspace tools, GitHub tools, or third-party CLIs exist unless the current runtime exposes them or the local command/auth check passes.
- Prefer structured local integrations over browser automation. If a structured tool or CLI is unavailable, stop with the exact missing setup step instead of silently falling back to risky UI automation.

## Permission Classes

- Read-only: search, summarize, inspect, list, preview, and draft. These are safe after normal task intent is clear.
- Local write: create or edit files inside the selected project/output location. Use archive-first rules when replacing OpenClicky memory, prompts, skills, config, runtime notes, or learned artifacts.
- External write: send email/messages, create calendar events, modify cloud docs, deploy, publish, trade, open PRs, merge, delete, rename, move, or complete tasks. These require explicit user approval immediately before execution unless the user request already names the exact action and target.
- Credential/auth setup: do not start OAuth, keychain, token, or passphrase flows unless the user explicitly asked for setup. Report the missing credential or account clearly.
- macOS TCC: do not run commands that intentionally trigger new Accessibility, Screen Recording, Contacts, Calendar, Photos, Reminders, Messages, Mail, Full Disk Access, Camera, Microphone, or Speech Recognition prompts unless the user asked for that permission flow.

## Visual Guidance Tools

OpenClicky's external bridge currently supports local token-gated endpoints for cursor pointing, multi-cursors, captions, screenshots, click, clear, speak, notify, multi-call batches, and MCP-style tool descriptors.

- Use coordinates only for visible, current screen content.
- Keep captions short and avoid covering critical UI.
- Use `/clear` before changing scenes or ending stale tours.
- Scribble/freehand path and rectangle highlight overlays are supported when `GET /health` reports `visual_guidance.scribble` and `visual_guidance.rectangle` as `supported` and `GET /mcp/tools` exposes `show_scribble`, `show_highlight`, and `show_rectangle`. If the capability status is `gated`, do not call those tools until the runtime flag is enabled. Do not claim spotlight masks, arrows, or persistent annotations exist until those descriptors are added.
- For clicks, prefer element-aware/native computer-use tools when available; use raw coordinate clicks only when the target is visible and unambiguous.

## Output and Artifacts

- User-facing deliverables belong in the configured project/output location, not loose at the projects root.
- Final artifact metadata should list only files or URLs the user should open or share.
- Exclude logs, temp files, helper scripts, package caches, lockfiles, and build outputs from artifact lists unless the user explicitly asked for them.

## Validation

For skill and prompt changes, run lightweight text validation such as frontmatter/header checks and targeted `rg` scans. For Swift source changes, use `swiftc -parse <relevant Swift source files>` only; do not run terminal `xcodebuild` for OpenClicky.
