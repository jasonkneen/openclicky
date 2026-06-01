---
name: "optimize_openclicky_skills"
description: "Use when the user asks OpenClicky to inspect, audit, improve, consolidate, or optimize bundled or learned skills."
---

## OpenClicky compatibility guardrails

- Follow `../_shared/OpenClickySkillCompatibilityPolicy.md` before acting.
- Verify required local commands, tools, keys, or bridge endpoints before promising execution.
- Treat sends, publishes, deploys, deletes, moves, merges, playlist/library changes, cloud writes, and app-control clicks as external writes unless this skill narrows them further.
- Stop and report the exact missing setup step for unavailable tools, auth, or macOS permissions; do not loop or silently switch to browser automation.

# Optimize OpenClicky Skills

Use this workflow when the user asks to look at skills, improve skills, optimize skills, clean up skills, make agents faster, or reduce repeated mistakes through better workflow skills.

## Required Inputs

1. Read `OpenClickyRuntimeMap.md` from Codex home.
2. Read `memory.md`.
3. Inspect the learned skills directory from the runtime map.
4. Inspect bundled skills only when the user asks about built-in behavior or when learned skills depend on them.

## Archive First

Before replacing or superseding any skill file:

1. Create a timestamped backup under the archives path from `OpenClickyRuntimeMap.md`.
2. Preserve the original relative path in the archive folder name or a short `README.md`.
3. Do not delete the old skill unless the user explicitly asked for destructive deletion.

Recommended archive command shape:

```sh
mkdir -p "$ARCHIVES_DIR/skills/YYYYMMDD-HHMMSS"
cp -R "$SKILL_DIR" "$ARCHIVES_DIR/skills/YYYYMMDD-HHMMSS/"
```

## Optimization Pass

For each relevant skill:

1. Check whether the trigger description is specific enough for agents to choose it.
2. Remove vague motivational text and keep direct workflow steps.
3. Add exact file paths, commands, app names, permission gotchas, and verification steps from successful prior runs.
4. Split unrelated workflows into separate learned skills.
5. Merge duplicate skills only after archiving all originals.
6. Keep skill names snake_case and action-oriented, for example `create_apple_note` or `review_openclicky_logs`.

## Outputs

Create or update the needed `SKILL.md` files. Then update `memory.md` with a short note summarizing:

- Which skills were optimized.
- Which skills were created.
- Where backups were archived.
- Any remaining gap that future agents should know.

Final response should be short and include the changed skill paths and archive path.
