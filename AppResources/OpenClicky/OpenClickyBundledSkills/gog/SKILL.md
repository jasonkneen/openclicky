---
name: gog
description: Use OpenClicky's local gog CLI as the primary Google Workspace route for Gmail read/search, optional Gmail send only when already connected and explicitly approved, Calendar, Drive, Docs, Sheets, Chat, Contacts, auth status, and account inspection. Prefer gog over browser automation for normal Google Workspace work.
version: 1.0.0
---

# gog

Use `gog` as OpenClicky's primary local Google Workspace CLI for Gmail, Calendar, Drive, Docs, Sheets/spreadsheets, Google Workspace automations, Chat, Contacts, Tasks, People, Forms, Slides, Apps Script, Groups, Admin, and auth/account inspection.

Prefer `gog` over browser automation for normal Google Workspace requests. Do not open or automate Gmail, Calendar, Drive, Docs, or Sheets in the browser unless `gog` cannot cover the requested action, the user explicitly asks for visible browser UI, or the user is already signed into a visible Google web app and the local connector is unavailable.

Do not use `gog` for Google Cloud/GCP, Google Ads, generic Google Search, or public web research. Those are not Google Workspace surfaces.

## Local sources

- CLI: `gog`
- Homebrew path: `/opt/homebrew/bin/gog`
- Config: `~/Library/Application Support/gogcli/config.json`
- Credentials: `~/Library/Application Support/gogcli/credentials.json`
- File keyring tokens: `~/Library/Application Support/gogcli/keyring/`

Treat gog credentials and keyring data as user-local secrets. Do not print tokens, export tokens, commit credentials, or ask the user to paste OAuth secrets.

## Auth

Inspect auth before assuming Google Workspace is blocked:

```bash
gog --json auth status
gog --json auth list --check
```

If the file-keyring backend asks for a passphrase, stop and report that gogcli needs its local keyring passphrase or `GOG_KEYRING_PASSWORD` in the environment. Do not spin or keep retrying.

If no usable account is authenticated, stop the `gog` route. Do not run `gog auth add`, `gog auth credentials`, or OAuth setup from an agent task unless the user explicitly asks for setup help. Google sign-in/setup belongs in OpenClicky Settings -> Google.

Do not claim OAuth client credentials are missing until you have checked both:

```bash
gog auth status --json
gog auth credentials list --json
```

`gog auth status` may not report credentials correctly in every local state; `credentials list` is the more direct check.

Use `--json` for scriptable output and `--dry-run` for write planning where supported.

## Live command rule

Use the installed `gog` help as the source of truth. Do not rely on stale command examples from older gogcli builds. If a command fails with "expected one of", immediately run the parent help, e.g. `gog gmail messages -h`, then retry with one of the listed subcommands.

Important gog 0.12 command shapes:

- Thread search: `gog gmail search <query> ...`
- Message search: `gog gmail messages search <query> ...`
- Message get: `gog gmail get <messageId>`
- Thread get: `gog gmail thread get <threadId>`
- Labels: `gog gmail labels list`
- Calendar events list: `gog calendar events` (not `calendar events list`)
- Calendar event get: `gog calendar event <calendarId> <eventId>`
- Drive search/list: `gog drive search <query> ...`, `gog drive ls`
- Contacts search/list: `gog contacts search <query> ...`, `gog contacts list`

## Common reads

```bash
gog --json gmail search "newer_than:7d" --max 10 --account auto
gog --json gmail messages search "from:example@example.com newer_than:30d" --max 10 --account auto
gog --json gmail get MESSAGE_ID --account auto
gog --json gmail thread get THREAD_ID --account auto
gog --json gmail labels list --account auto
gog --json calendar events --today --account auto
gog --json calendar events --days 7 --account auto
gog --json calendar search "project sync" --account auto
gog --json drive search "name contains 'deck'" --account auto
gog --json drive ls --account auto
gog --json contacts search "Name" --account auto
```

For large results, use max/filters first. Summarize results instead of dumping huge JSON.

## Gmail send safety

Default to read-only behavior. If the user asks to send email:

1. Draft first.
2. Show account, recipient, subject, body summary, and attachments.
3. Require explicit approval of that exact draft.
4. Only then send if the account already has Gmail send permission.
5. If send permission is missing, stop and say OpenClicky's Google connection needs Gmail send permission in Settings. Do not run OAuth from the agent.

Keep `GOG_GMAIL_NO_SEND=1` as the default guard where it is set. Bypass it only for one exact approved send command:

```bash
env -u GOG_GMAIL_NO_SEND gog --json gmail send --account "$GOG_ACCOUNT" --to "recipient@example.com" --subject "Subject" --body-file /path/to/approved-body.txt
```

## Write safety

Do not send email, create/update/delete Drive files, change calendar events, share Drive files, post Chat messages, modify contacts, or change Workspace admin state unless the user explicitly asks. For writes, summarize the target account and intended mutation first unless the user already gave a concrete command.

After writes, verify by re-reading or listing the changed item when possible.

## Fallbacks

- If `gog` is not installed or not authenticated, say exactly what is missing and stop the Google API route.
- Use browser/Computer Use only for a visible UI task, a gog coverage gap, or an already-open signed-in Google web app when the local connector is unavailable.
- Do not loop on the same blocked Google command.

## Smoke commands

```bash
gog --version
gog --json auth status
gog auth credentials list --json
```
