---
name: nodex-head-gestures
description: Ask low-risk yes/no questions through the optional local Nodex AirPods head-gesture helper. Use when the user wants to answer by nodding or shaking their head, says they are hands-free, or asks for AirPods gesture confirmation while an OpenClicky Agent Mode task is running.
version: 1.0.0
argument-hint: "[yes/no question]"
metadata:
  openclicky:
    tags: [Accessibility, Hands-Free, AirPods, Agent-Mode, Confirmation]
    related_skills: [codex]
---

# Nodex Head Gestures

Use the optional local Nodex CLI to ask one binary question at a time when the user wants hands-free yes/no control.

Nodex maps:

- nod = yes
- shake = no
- keyboard `y`/`n` = fallback when using `nodex ask`

## Preconditions

Check for Nodex before using it:

```bash
command -v nodex-motion || command -v nodex
```

If neither command exists, tell the user Nodex is not installed and use normal OpenClicky input instead. Do not try to install software unless the user explicitly asks.

AirPods/head-motion input requires a compatible Apple headphone model, macOS Motion & Fitness permission, and the `nodex-motion` app wrapper.

## Ask With Head Gestures

For AirPods head gestures, prefer:

```bash
nodex-motion ask "Should I continue with this patch?" --motion-only --timeout 25 --default no
```

Interpret exit codes:

- `0`: yes
- `1`: no
- `2`: timeout
- `64`: setup or usage error

Treat timeout as no for risky actions and as the conservative default for ordinary choices.

## Ask With Keyboard Fallback

If head gestures are unavailable but Nodex is installed:

```bash
nodex ask "Should I run the focused tests?" --log --default no
```

Use `--voice kokoro` only if the user asked for Kokoro or the local Nodex setup is known to support it.

## Rules

1. Ask exactly one yes/no question at a time.
2. Phrase questions so both yes and no have obvious meanings.
3. Prefer conservative defaults over low-value interruptions.
4. Do not use head gestures as the only approval for destructive, live production, customer-facing, financial, email, remote-server, secret-bearing, or irreversible actions. Require typed confirmation for those.
5. Avoid `--log` when the question contains secrets or sensitive personal data.

## Good Questions

- "Should I run the focused tests now?"
- "Should I keep the current UI layout?"
- "Should I skip the optional refactor?"

## Bad Questions

- "What should I do next?"
- "Which option do you prefer?"
- "Should I do the risky thing?" without naming the concrete risk.
