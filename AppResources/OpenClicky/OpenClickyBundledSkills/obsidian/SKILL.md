---
name: obsidian
description: Read, search, create, and edit notes in the configured Obsidian vault.
---

# Obsidian Vault

Use this skill for filesystem-first Obsidian vault work: reading notes, listing notes, searching note files, creating notes, appending content, adding wikilinks, backlinks, tags, and daily notes.

OpenClicky exposes Obsidian as a local vault path, not as a Composio connector. Use this skill only when the runtime instructions include an Obsidian vault path.

## Vault Path

- The configured vault path appears in the runtime prompt as `Obsidian vault path: ...`.
- The same path is also available as `OBSIDIAN_VAULT_PATH` for shell commands.
- Treat that concrete absolute path as the only vault root.
- Do not search for other Obsidian vaults.
- Do not use Composio, OAuth, browser sign-in, or a local Obsidian API for this integration.
- Vault paths may contain spaces; quote paths in shell commands.

## List And Search

```bash
rg --files "<vault-path>" -g '*.md'
rg -n "<query>" "<vault-path>"
```

Prefer `rg` for filenames and content searches. Read only the notes needed for the user's task. Preserve wiki links, tags, frontmatter, embeds, and callouts when summarizing or editing.

## Read A Note

Use normal file reads against the resolved absolute path. Do not pass paths containing shell variables.

## Create Or Edit Notes

- Create or edit Markdown files only when the user clearly asks for a note, cleanup, organization, or content change.
- Preserve existing YAML frontmatter and Obsidian syntax.
- Keep filenames readable and stable. Do not rename or move notes unless the user asked for organization/renaming.
- For deletes, large rewrites, plugin/config changes, or bulk moves, describe the exact plan and get explicit approval first.
- Prefer focused patches for targeted edits when stable context exists.
- For an anchored append, replace the anchor with the anchor plus the new content.

## Wikilinks And Daily Notes

- Obsidian links notes with `[[Note Name]]` syntax. Use wikilinks when connecting related notes inside the same vault.
- Keep tags as plain `#tag` or frontmatter tags, following the note's existing style.
- Daily notes should use the vault's existing daily-note pattern if one is obvious from nearby files; otherwise ask the root/user before inventing a convention.

## Final Response

Report the note paths you read or changed, relative to the vault when possible. Keep the user-facing summary short.
