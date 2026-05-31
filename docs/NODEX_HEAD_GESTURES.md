# Nodex Head-Gesture Confirmations

OpenClicky Agent Mode can optionally use [Nodex](https://github.com/skysmith/nodex) for hands-free yes/no confirmations through AirPods head gestures.

This integration is intentionally lightweight: OpenClicky does not vendor Nodex or take on its hardware-permission surface. Instead, Agent Mode receives a bundled `nodex-head-gestures` skill that can call a locally installed `nodex-motion` or `nodex` command when the user asks to answer by nodding or shaking their head.

## Setup

Install Nodex separately and make sure the commands are on `PATH`:

```bash
nodex doctor
nodex-motion ask "Should OpenClicky continue?" --motion-only
```

The first `nodex-motion` run may trigger macOS Motion & Fitness permission. AirPods must be connected to the Mac, and gesture support depends on the headphone model and macOS version.

## Agent Mode Usage

Start an OpenClicky Agent Mode task with a prompt like:

```text
Use Nodex head gestures for yes/no questions. I want to answer by nodding or shaking my head.
```

The bundled skill tells the agent to ask one binary question at a time:

```bash
nodex-motion ask "Should I run the focused tests?" --motion-only --timeout 25 --default no
```

Exit-code mapping:

- `0` means yes
- `1` means no
- `2` means timeout
- `64` means setup or usage error

## Safety Boundary

Head gestures are suitable for low-risk workflow choices: run tests, keep a design direction, skip optional cleanup, or continue a non-destructive task.

Do not use head gestures as the only approval for destructive, live production, customer-facing, financial, email, remote-server, secret-bearing, or irreversible actions. Those still need explicit typed confirmation.

## Why This Is A Skill Instead Of Native App Code

Keeping Nodex as an optional local tool has three benefits:

1. OpenClicky does not need to bundle headphone-motion permissions or a second hardware stack.
2. Users who already have Nodex get the feature immediately in Agent Mode.
3. The app can later add a native settings toggle or direct CoreMotion support without locking into this first integration shape.
