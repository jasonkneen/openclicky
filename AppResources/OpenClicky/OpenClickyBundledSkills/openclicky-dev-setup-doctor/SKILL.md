---
name: openclicky-dev-setup-doctor
description: Diagnose and fix developer environment, agent runtime, MCP, API key, package manager, localhost, Node/npm/Python, Supabase, Cloudflare/Wrangler, Codex, Claude Code, and terminal setup problems.
---

## OpenClicky compatibility guardrails

- Follow `../_shared/OpenClickySkillCompatibilityPolicy.md` before acting.
- Verify required local commands, tools, keys, or bridge endpoints before promising execution.
- Treat sends, publishes, deploys, deletes, moves, merges, playlist/library changes, cloud writes, and app-control clicks as external writes unless this skill narrows them further.
- Stop and report the exact missing setup step for unavailable tools, auth, or macOS permissions; do not loop or silently switch to browser automation.

# OpenClicky Dev Setup Doctor

Help non-expert builders understand and repair their local development environment. Prefer diagnosis before changes, and explain the failure in plain language.

## Use When
- The user asks why Codex, Claude Code, MCP, terminal commands, localhost, packages, API keys, or dev servers are broken.
- The task mentions npm, node, pnpm, Python, Supabase, Cloudflare, Wrangler, `.env`, MCP servers, or auth setup.
- The user asks what to run next.

## Do Not Use When
- The user asks for normal repo feature work, PRs, commits, or CI review; use `openclicky-repo-operator`.
- The user asks to build and visually preview a site/app; use `openclicky-build-preview`, then return here only for setup blockers.
- The user asks to connect an external app account; only diagnose local auth/config if a real connection runtime is exposed, otherwise report that the connection surface is not shipped in this build.

## Primary Path
1. Identify the project folder and active toolchain.
2. Check status before changing anything: versions, env files, running processes, ports, auth status, and logs.
3. Explain the failure in plain language.
4. Apply the smallest safe fix or provide the exact next command.

## Fallbacks
- If permissions/auth are missing, state the exact missing permission or login and the next setup action.
- If a local server is not running, start it only when the user asked for a working preview or task execution.
- Use app-specific setup skills, such as OpenClicky's local-dev skill, when they apply.

## Safety
- Do not overwrite `.env` files or secrets.
- Do not touch production services unless the user explicitly asks.
- Do not run destructive package or database resets without confirmation.

## Artifacts
- When setup creates logs, config files, or reports, provide exact paths.
- When fixing localhost, provide the final URL and process command.

## Verification
- Re-run the failing command, health check, or version check.
- For web servers, verify the port responds.
- For MCP/agent setup, verify tool discovery or connection status.
