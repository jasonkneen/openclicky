---
name: openclicky-specialist-agents
description: Create, equip, or repair OpenClicky specialist agents with explicit soul, instructions, memory, heartbeat, and skills.json wiring.
---

## OpenClicky compatibility guardrails

- Follow `../_shared/OpenClickySkillCompatibilityPolicy.md` before acting.
- Verify required local commands, tools, keys, or bridge endpoints before promising execution.
- Treat sends, publishes, deploys, deletes, moves, merges, playlist/library changes, cloud writes, and app-control clicks as external writes unless this skill narrows them further.
- Stop and report the exact missing setup step for unavailable tools, auth, or macOS permissions; do not loop or silently switch to browser automation.

# OpenClicky Specialist Agents

Use this skill when the user asks OpenClicky to create a new specialist, expert agent, recurring maintenance agent, or agent with domain expertise.

## Workflow

1. Inspect existing agents before writing:
   - Built-ins: `~/Library/Application Support/OpenClicky/agents/`
   - User agents: `~/.openclicky/agents/`
   - Runtime map: `~/Library/Application Support/OpenClicky/AgentMode/CodexHome/OpenClickyRuntimeMap.md`
2. Choose a compact slug and create or update one agent folder with:
   - `agent.json`
   - `soul.md`
   - `instructions.md`
   - `memory.md`
   - `HEARTBEAT.md`
   - `skills.json`
   - optional `skills/<skill-id>/SKILL.md` for specialist-only custom workflows
3. Associate skills deliberately:
   - Prefer existing bundled or learned skills when they match.
   - Add every required skill ID to `skills.json`.
   - If no existing skill covers a repeated workflow, create a small custom `SKILL.md` under that agent's `skills/` folder.
4. Keep the specialist bounded:
   - State what it does, what it should not do, and when it should stop or ask.
   - Include archive-first rules for OpenClicky memory, logs, skills, prompts, config, and other durable artifacts.
   - Include concise spoken progress/final-answer expectations.
5. Verify:
   - List the final files.
   - Confirm enabled skills resolve locally, or explicitly note which skill still needs installation.

## File shapes

`skills.json`:

```json
{
  "enabledSkillIDs": ["openclicky-specialist-agents"]
}
```

`agent.json`:

```json
{
  "displayName": "Short Name",
  "description": "One-line scope.",
  "accentColorHex": "22C55E",
  "schemaVersion": 1
}
```

## Guardrails

- Do not overwrite a user-authored agent or skill without archiving the prior version first.
- Do not create broad, vague agents. A good specialist has a narrow job and named skills.
- Do not claim a specialist can use a skill unless `skills.json` enables it or the skill is written into its custom `skills/` folder.
