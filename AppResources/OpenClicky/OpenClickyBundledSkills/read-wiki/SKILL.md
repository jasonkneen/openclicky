---
name: read-wiki
description: Use when a task references a specific project, person, or note the user has saved (e.g. "about my project X", "what did I say about Y", "who is Z to me"). The user's overall voice/tone/personality is already loaded into the system prompt automatically and does NOT require this skill — only reach for read-wiki when the task names a specific entity that lives in the wiki. Read-only counterpart to the `save-wiki` skill (which writes to the wiki).
---

# read-wiki

OpenClicky maintains a local personal wiki of plain markdown notes the user (and OpenClicky) has written about their projects, the people they care about, references, and anything else worth remembering across agent runs.

The user's overall personality / voice / tone (`Personality.md`) is already inlined into your system prompt at startup, so you do NOT need this skill for tone matching. Use it only when a task references a specific named project, person, or note.

## Where it lives

- Wiki content (curated notes): `~/Library/Application Support/OpenClicky/wiki/wiki/`
- Raw saves (auto-captured snippets): `~/Library/Application Support/OpenClicky/wiki/raw/`
- Index: `~/Library/Application Support/OpenClicky/wiki/wiki/_index.md`
- Backlinks graph: `~/Library/Application Support/OpenClicky/wiki/wiki/_backlinks.json`

## How to use it

This is a **read-only** skill. Don't create, edit, or delete anything in the wiki — the user has separate flows for that.

Start with the index:

```bash
cat "$HOME/Library/Application Support/OpenClicky/wiki/wiki/_index.md"
```

The index is structured as `[[Title]] (relative/path.md) — short description` plus an `also:` line listing aliases. Use the aliases to match user phrasings ("my tone", "how I write", "my project", a person's nickname, etc.) — they're there exactly so you don't have to guess at filenames.

Then read only the targeted note(s). Examples:

```bash
# Writing in the user's voice / matching tone / personality-sensitive task
cat "$HOME/Library/Application Support/OpenClicky/wiki/wiki/Personality.md"

# Drafting about a project
cat "$HOME/Library/Application Support/OpenClicky/wiki/wiki/projects/openclicky.md"

# Mentioning a person they know
cat "$HOME/Library/Application Support/OpenClicky/wiki/wiki/people/farza-majeed.md"
```

If you don't know which note applies, grep:

```bash
grep -rli "<keyword>" "$HOME/Library/Application Support/OpenClicky/wiki/wiki/"
```

## When to consult it

Reach for the wiki when the task asks for *user-specific* color rather than general knowledge:

- "Write/draft/reply to an email/message/post" → read `Personality.md` so the voice matches.
- "About my project X / my company / my work on Y" → read the matching `projects/*.md`.
- "Write something for/about [person]" or "What did I say about [person]" → read the matching `people/*.md`.
- "What's my take on X" / "How do I usually phrase Y" → grep the wiki for X/Y.
- Tasks where a generic answer would feel impersonal or off-brand for the user.

Skip the wiki for purely factual, mechanical, or generic tasks (math, public knowledge, code refactors, file ops with no tone implications).

## How to apply what you find

- Don't paste wiki text verbatim into the user-facing output. Internalize it, then write naturally in their voice.
- Don't surface the existence of the wiki to the user ("according to your wiki...") unless they ask. The wiki is a backstage memory layer, not a citation source.
- If the wiki contradicts something in the user's current request, follow the current request — the wiki is context, not a constraint.
- If a relevant note is missing or empty, proceed without it instead of stalling.

## Efficiency

Read targeted files only. Don't `cat` every note "just in case" — that wastes tokens and adds latency. The pattern is: index → 1-2 specific reads → done.
