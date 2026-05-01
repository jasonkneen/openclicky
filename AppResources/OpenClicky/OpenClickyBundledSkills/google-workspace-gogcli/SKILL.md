---
name: google-workspace-gogcli
description: Connect to Google Workspace through the local gogcli (`gog`) command for Gmail, Calendar, Drive, Docs, Sheets, Slides, Chat, Contacts, Tasks, Groups, Admin, Classroom, Forms, Apps Script, People, and Keep. Use when the user asks OpenClicky to use Google Workspace, Gmail, Calendar, Drive, Docs, Sheets, Slides, Chat, Contacts, Tasks, Workspace Admin, or to set up/check gogcli auth.
version: 1.0.0
argument-hint: "[workspace task or auth setup]"
---

Use `gog` from https://github.com/steipete/gogcli as OpenClicky's local Google Workspace connector.

This is a local CLI integration, not an OpenClicky-hosted Google login. Do not add hosted key sync, server-side OAuth, or repository-stored credentials. `gog` stores credentials in its own OS keyring or encrypted/file keyring under the user's local account.

## First checks

```bash
command -v gog
gog --version
gog --json auth status
gog auth credentials list --json
gog --json auth list --check
```

If `gog auth list` reports that the file keyring needs a passphrase, stop and tell the user gogcli needs its local keyring passphrase or `GOG_KEYRING_PASSWORD`. Do not keep retrying.

If `gog` is not installed on macOS:

```bash
brew install gogcli
```

## Setup flow

For normal Gmail/Calendar/Drive tasks, do not run OAuth setup from the agent. Google setup belongs in OpenClicky Settings → Google unless the user explicitly asks for setup help.

The user must provide or create a Google Cloud Desktop OAuth client JSON. Do not create or store secrets in the repository.

1. Enable only the APIs needed for the task in the user's Google Cloud project.
2. Create OAuth client credentials with application type `Desktop app`.
3. Store the downloaded client JSON locally in gogcli:

```bash
gog auth credentials ~/Downloads/client_secret_....json
```

For a named Workspace client:

```bash
gog --client work auth credentials ~/Downloads/work-client.json --domain example.com
```

4. Authorize the account with least-privilege services:

```bash
# Read-only Gmail + Drive example
gog auth add you@example.com --services gmail,drive --gmail-scope readonly --drive-scope readonly

# Calendar + Tasks example
gog auth add you@example.com --services calendar,tasks --readonly

# Full user services only when explicitly needed
gog auth add you@example.com --services user
```

5. Set an alias if useful:

```bash
gog auth alias set work you@example.com
gog auth alias list
```

Use `--account work` or `GOG_ACCOUNT=work` in later commands.

## Safety defaults

- Prefer read-only commands unless the user explicitly asks for a write.
- For write actions, summarize the target account and intended mutation first unless the user gave a precise command.
- Never send email, delete files, modify calendar events, alter contacts, change admin state, or post chat messages without explicit user intent.
- Use `--json` for agent parsing.
- Use `--account <email|alias|auto>` when there may be multiple accounts.
- Respect `GOG_ENABLE_COMMANDS`, `GOG_DISABLE_COMMANDS`, and `GOG_GMAIL_NO_SEND` if set.
- If auth is missing, point the user to OpenClicky Settings → Google. Only provide `gog auth credentials` / `gog auth add` commands when the user explicitly asks for manual setup.

Useful safety env examples:

```bash
export GOG_ACCOUNT=work
export GOG_JSON=1
export GOG_GMAIL_NO_SEND=1
# Optional per-task command allowlist:
export GOG_ENABLE_COMMANDS=gmail,calendar,drive,docs,sheets,tasks,contacts
```

## Live command rule

Use the installed `gog` help as the source of truth. If a command fails with "expected one of", run the parent help, e.g. `gog gmail messages -h`, and retry with one of the listed subcommands. Do not keep using stale examples.

Current gog 0.12 command shapes to remember:

- Thread search: `gog gmail search <query> ...`
- Message search: `gog gmail messages search <query> ...`
- Message get: `gog gmail get <messageId>`
- Thread get: `gog gmail thread get <threadId>`
- Labels: `gog gmail labels list`
- Calendar events list: `gog calendar events` (not `calendar events list`)
- Calendar event get: `gog calendar event <calendarId> <eventId>`
- Drive search/list: `gog drive search <query> ...`, `gog drive ls`
- Contacts search/list: `gog contacts search <query> ...`, `gog contacts list`

## Common commands

### Auth/account

```bash
gog auth status --json
gog auth list --check
gog auth credentials list
gog auth doctor
gog auth alias list
```

### Gmail

```bash
gog gmail search 'newer_than:7d' --account work --json
gog gmail messages search 'from:person@example.com newer_than:30d' --max 10 --json
gog gmail labels list --account work --json
```

Send only when asked explicitly, after showing the exact draft and receiving approval. If `GOG_GMAIL_NO_SEND=1` is set, bypass it only for the one approved send:

```bash
env -u GOG_GMAIL_NO_SEND gog --json gmail send --to recipient@example.com --subject 'Subject' --body-file /path/to/approved-body.txt --account work
```

### Calendar

```bash
gog calendar calendars --account work --json
gog calendar events --account work --json
gog calendar search 'project sync' --account work --json
gog calendar freebusy primary --account work --json
```

Create/update/delete only when asked explicitly:

```bash
gog calendar create primary --summary 'Meeting' --from '2026-05-01T10:00:00' --to '2026-05-01T10:30:00' --account work
```

### Drive / Docs / Sheets / Slides

```bash
gog drive search "name contains 'proposal'" --account work --json
gog drive ls --account work --json
gog docs --help
gog sheets --help
gog slides --help
```

Prefer exporting/downloading to a temporary path for inspection. Do not overwrite user files unless explicitly requested.

### Contacts / People / Tasks / Chat

```bash
gog contacts search 'Jane Doe' --account work --json
gog people --help
gog tasks --help
gog chat spaces list --account work --json
```

Posting to Chat or changing contacts/tasks requires explicit permission.

### Workspace Admin / Groups / Keep

Workspace-only/admin commands may require service account and domain-wide delegation:

```bash
gog admin users list --json
gog admin groups list --json
gog groups --help
gog keep --help
```

Use these only for Workspace domains where the user has admin authorization.

## Troubleshooting

- `credentials_exists: false`: check `gog auth credentials list --json`; if still empty, use OpenClicky Settings → Google or run `gog auth credentials <client-json>` only for explicit setup tasks.
- No accounts in `gog auth list`: use OpenClicky Settings → Google or run `gog auth add <email> --services ...` only for explicit setup tasks.
- Re-auth needed or missing scopes: use OpenClicky Settings → Google, or run `gog auth add <email> --services ... --force-consent` only for explicit setup tasks.
- Keyring issues: run `gog auth doctor`; on headless systems use the file keyring intentionally.
- Multiple clients/accounts: use `--client`, `GOG_CLIENT`, `--account`, or account aliases.
- Command not available: inspect with `GOG_HELP=full gog --help` or `gog <group> --help`.

## Agent response style

When you use this skill:

1. Check install/auth state.
2. If missing auth, provide the shortest safe setup commands.
3. If authenticated, run the smallest read command that answers the user's request.
4. For writes, confirm or restate the exact mutation unless the user's command was already explicit.
5. Return concise results with account/context, not raw huge JSON unless asked.
