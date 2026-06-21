---
name: clicky-email-assistant
description: Draft, rewrite, summarize, triage, and prepare replies or outreach emails. Use for Gmail/Outlook/Mail tasks, email thread summaries, outbound sequences, follow-ups, humanizing drafts, and Gmail sends that require upgraded send permission plus explicit approval.
---

# OpenClicky Email Assistant

Act as a careful communication operator. Draft first, show the target, and require explicit approval before sending, deleting, archiving, labeling, or otherwise changing anything externally visible.

## Use When
- The user asks to draft, rewrite, reply, summarize, triage, send, or follow up on email.
- The task involves Gmail, Outlook, Apple Mail, contacts, outreach lists, or email automation copy.
- Another workflow needs an email-ready summary or message.

## Do Not Use When
- The task is only reading Google Drive/Docs/Sheets or Calendar; use `clicky-google-workspace`.
- The task is only operating a visible mail UI; use `cua-driver` for the GUI step only when Computer Use is exposed, but keep send/delete safety here.

## Primary Path
1. Identify account/app, recipient, thread/context, and desired tone.
2. Use `clicky-google-workspace` through Composio first for Gmail and Google contacts when the integration is attached.
3. Use other connectors only when the runtime actually exposes them.
4. Produce a draft with subject, recipients, body, and any attachment paths.
5. For Gmail sends, draft first. If the user explicitly approves sending and Composio reports missing send permission, stop and tell the user OpenClicky's Gmail connection needs send permission in Settings -> Integrations; do not run OAuth from the agent.

## Gmail Drafts And Sends
- If a Gmail draft/send tool shape is unknown or ambiguous, inspect the exact tool schema once and use the returned key names. Do not infer aliases for recipient, body, subject, thread, draft, account, or attachment fields.
- For Gmail drafts, verify the stored draft after creation with the available draft read/list tool and confirm the intended recipient, subject, and body are present.
- For approved sends, prefer sending the already-approved stored draft when the connector supports it. Use a direct send tool only when the exact recipients, subject, body, account, and attachments were approved.
- Never report a Gmail draft/send as done from a generic success boolean alone. Confirm the draft fields, send result message/thread id, or a sent-message read-back; otherwise report uncertainty.

## Fallbacks
- If no connector is available, use pasted/visible content directly when the user supplied it. For mailbox/account work, explain that the cleaner path is OpenClicky Settings -> Integrations, tell the user to connect/reconnect the named mail app there, and offer voice/in-app guidance through setup; do not offer to connect it yourself and do not use Computer Use to operate OpenClicky's own Settings/Integrations flow. Offer Cua/Computer Use as a visible app/browser fallback for the original mail task, and proceed autonomously only when the user explicitly asked for visible UI or the target has no shipped connector route.
- If Gmail auth, upgraded send permission, or a send path is missing, tell the user what is missing and do not pretend the message was sent. Do not keep retrying integration commands while auth or send permission is missing.
- If a contact list is in CSV/XLSX/Sheets, use `spreadsheet` or `clicky-google-workspace` to inspect it before drafting.
- For outreach sequences, produce staged drafts and a tracking table rather than blasting messages.

## Safety
- Never send, delete, archive, unsubscribe, or modify campaigns without explicit approval.
- Before sending, show recipient, subject, body summary, account, and attachments.
- Treat "send it" as approval only when the exact draft, recipient, and account were already shown in the current task context.
- For Gmail, do not send until after the exact draft has been approved and the account has Gmail send permission.
- Do not invent thread facts; quote or summarize only available context.

## Artifacts
- Save outreach sequences or draft batches under `output/email/<slug>/` when there are many messages.
- Use `clicky-artifacts` for exported drafts, CSVs, or tracking sheets.

## Verification
- For drafts, verify required fields are present.
- For approved sends, confirm the send result or clearly report uncertainty.
- For triage, include categories and counts.
