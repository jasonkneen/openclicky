---
name: "learn_from_openclicky_logs"
description: "Use when the user asks OpenClicky to review logs, find learnings, tune behavior from logs, or create improvements from logged messages."
---

## OpenClicky compatibility guardrails

- Follow `../_shared/OpenClickySkillCompatibilityPolicy.md` before acting.
- Verify required local commands, tools, keys, or bridge endpoints before promising execution.
- Treat sends, publishes, deploys, deletes, moves, merges, playlist/library changes, cloud writes, and app-control clicks as external writes unless this skill narrows them further.
- Stop and report the exact missing setup step for unavailable tools, auth, or macOS permissions; do not loop or silently switch to browser automation.

# Learn From OpenClicky Logs

Use this workflow when the user asks to review logs, learn from logs, tune OpenClicky, inspect message JSONL, or turn flagged log comments into improvements.

## Required Inputs

1. Read `OpenClickyRuntimeMap.md` from Codex home.
2. Read `memory.md`.
3. Inspect `agent-review-comments.md` and `log-review-comments.jsonl` when present.
4. Inspect recent `messages-YYYY-MM-DD.jsonl` files from the logs directory. Start with the newest log unless the user names a date.

## What To Look For

Look for patterns that can become durable improvements:

- Repeated refusals where OpenClicky should have started an agent task.
- Raw command output shown to the user instead of plain English progress.
- Voice responses that are too long, too heavy, or not action-oriented.
- Missed opportunities to create a learned skill.
- Missing file paths, missing summaries, or unclear agent status responses.
- Tool failures that need a better fallback or a clearer permission/key message.

## Archive First

Before changing memory, learned skills, prompt notes, review notes, or generated summaries:

1. Create a timestamped backup under the archives path from `OpenClickyRuntimeMap.md`.
2. Preserve the source filename and enough context to restore it.
3. Do not delete old logs or old notes unless the user explicitly asks for destructive deletion.

Recommended archive command shape:

```sh
mkdir -p "$ARCHIVES_DIR/log-learning/YYYYMMDD-HHMMSS"
cp "$FILE_TO_CHANGE" "$ARCHIVES_DIR/log-learning/YYYYMMDD-HHMMSS/"
```

## Outputs

After reviewing logs, create the useful artifacts directly:

1. Update `memory.md` with stable user preferences, recurring failures, and product behavior decisions.
2. Create or update learned skills for repeat workflows found in logs.
3. Add concise review notes for issues that need code changes.
4. If no durable change is justified, write a short findings note instead of inventing a skill.

Final response should name:

- Logs reviewed.
- Learnings found.
- Files created or updated.
- Archive path used.
