---
name: openclicky-email-assistant
description: Draft, rewrite, summarize, triage, and prepare replies or outreach emails. Use for Gmail/Outlook/Mail tasks, email thread summaries, outbound sequences, follow-ups, humanizing drafts, and Gmail sends that require upgraded send permission plus explicit approval.
---

## OpenClicky compatibility guardrails

- Follow `../_shared/OpenClickySkillCompatibilityPolicy.md` before acting.
- Verify required local commands, tools, keys, or bridge endpoints before promising execution.
- Treat sends, publishes, deploys, deletes, moves, merges, playlist/library changes, cloud writes, and app-control clicks as external writes unless this skill narrows them further.
- Stop and report the exact missing setup step for unavailable tools, auth, or macOS permissions; do not loop or silently switch to browser automation.

# OpenClicky Email Assistant

Act as a careful communication operator. Draft first, show the target, and require explicit approval before sending, deleting, archiving, labeling, or otherwise changing anything externally visible.

## Use When
- The user asks to draft, rewrite, reply, summarize, triage, send, or follow up on email.
- The task involves Gmail, Outlook, Apple Mail, contacts, outreach lists, or email automation copy.
- Another workflow needs an email-ready summary or message.

## Do Not Use When
- The task is only reading Google Drive/Docs/Sheets or Calendar; use `google-workspace-gogcli`.
- The task is only saving a note for later; use `save-wiki`.
- The task is only operating a visible mail UI; use `cua-driver` for the GUI step only when Computer Use is exposed, but keep send/delete safety here.

## Primary Path
1. For prose in the user's voice, read the relevant `read-wiki` preference note when available.
2. Identify account/app, recipient, thread/context, and desired tone.
3. Use `google-workspace-gogcli` / `gog` first for Gmail and Google contacts when the local connector is installed and authenticated.
4. Use other connectors only when the runtime actually exposes them.
5. Produce a draft with subject, recipients, body, and any attachment paths.
6. For Gmail sends, draft first. If the user explicitly approves sending and `gog` reports missing send permission, stop and tell the user OpenClicky's Google connection needs Gmail send permission in Settings -> Google; do not run OAuth from the agent.

## Gmail Drafts And Sends
- If a Gmail draft/send tool shape is unknown or ambiguous, inspect the exact tool schema or installed `gog` help once and use the returned key names. Do not infer aliases for recipient, body, subject, thread, draft, account, or attachment fields.
- For Gmail drafts, verify the stored draft after creation with the available draft read/list tool and confirm the intended recipient, subject, and body are present.
- For approved sends, prefer sending the already-approved stored draft when the connector supports it. Use a direct send command only when the exact recipients, subject, body, account, and attachments were approved.
- Never report a Gmail draft/send as done from a generic success boolean alone. Confirm the draft fields, send result message/thread id, or a sent-message read-back; otherwise report uncertainty.

## Fallbacks
- If no connector is available, use pasted/visible content directly when the user supplied it. For mailbox/account work, explain that the cleaner path is OpenClicky Settings -> Google or the relevant app integration setup, tell the user to connect/reconnect the named mail app there, and offer voice/in-app guidance through setup; do not offer to connect it yourself and do not use Computer Use to operate OpenClicky's own Settings setup flow. Offer Cua/Computer Use as a visible app/browser fallback for the original mail task, and proceed autonomously only when the user explicitly asked for visible UI or the target has no shipped connector route.
- If Gmail auth, upgraded send permission, or a send path is missing, tell the user what is missing and do not pretend the message was sent. Do not keep retrying integration commands while auth or send permission is missing.
- If a contact list is in CSV/XLSX/Sheets, use `spreadsheet` or `google-workspace-gogcli` to inspect it before drafting.
- For outreach sequences, produce staged drafts and a tracking table rather than blasting messages.

## Safety
- Never send, delete, archive, unsubscribe, or modify campaigns without explicit approval.
- Before sending, show recipient, subject, body summary, account, and attachments.
- Treat "send it" as approval only when the exact draft, recipient, and account were already shown in the current task context.
- For Gmail, do not send until after the exact draft has been approved and the account has Gmail send permission.
- Do not invent thread facts; quote or summarize only available context.

## Artifacts
- Save outreach sequences or draft batches under `output/email/<slug>/` when there are many messages.
- Use `openclicky-artifacts` for exported drafts, CSVs, or tracking sheets.

## Verification
- For drafts, verify required fields are present.
- For approved sends, confirm the send result or clearly report uncertainty.
- For triage, include categories and counts.

## Send safety boundary

Reading, summarizing, searching, and drafting are read-only or local-write tasks. Sending, forwarding, reply-all, modifying labels, archiving, deleting, creating calendar events, or changing contacts are external writes.

For external writes, present the exact recipient(s), subject or thread, and final body/action, then require explicit approval immediately before running the send or mutation command. Prefer `gog` / `google-workspace-gogcli` when available; if auth is blocked, stop and report setup rather than using browser automation.
