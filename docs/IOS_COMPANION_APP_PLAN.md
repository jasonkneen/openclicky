# OpenClicky iOS Companion App Plan

## Goal

Build an iPhone and iPad companion app that lets the user talk to Clicky away from the Mac keyboard, see current OpenClicky tasks, start or steer Agent Mode work, review results, and receive task-status notifications.

The iOS app should feel like a remote control and second surface for the existing macOS OpenClicky runtime. The Mac remains the source of truth for local files, screen context, computer-use permissions, agent processes, secrets, and Codex runtime state.

## Product Shape

### Core jobs

1. Talk to Clicky from iPhone or iPad.
   - Press-to-talk and hold-to-talk.
   - Text fallback composer.
   - Live transcript while speaking.
   - Spoken reply from the device when appropriate.
   - Clear indication when the Mac is listening, thinking, speaking, or running an agent.

2. See current work.
   - Active agent tasks with title, status, short caption, and last update.
   - Needs-attention items such as failed agents, permissions, credentials, or log review comments.
   - Recent completions and artifacts.
   - Same high-level stats currently published to `widget-snapshot.json`.

3. Interact with tasks.
   - Start a new agent task.
   - Send a follow-up to a running or completed agent session.
   - Stop a running task with confirmation.
   - Archive completed tasks.
   - Open a result on the Mac when it points to a local file, repo, or app surface.

4. Carry useful context from iOS to Mac.
   - Voice/text prompt from the device.
   - Optional photo attachment from camera or library.
   - Optional file attachment through the iOS document picker.
   - Optional clipboard text from iOS.
   - No direct iOS filesystem assumptions inside the Mac agent prompt; uploads are copied into an OpenClicky attachment inbox on the Mac first.

## Guiding Constraints

- Keep OpenClicky macOS as the authority. Do not run Codex, local file automation, or computer-use from iOS directly in the first version.
- Use local network pairing first. Avoid hosted OpenClicky accounts or cloud key sync.
- Keep secrets on the Mac. The iOS app should authenticate to the Mac bridge with a device token, not store OpenAI, Anthropic, Google, or Codex keys.
- Treat iOS as privacy-sensitive. The device should not display full prompts, screenshots, memory bodies, or raw logs unless the Mac privacy settings allow it.
- Preserve voice-first speed. The primary iOS screen should be one tap to speak plus a visible task strip.
- Make iPad useful, not just stretched iPhone. iPad should show a sidebar of tasks and a selected conversation/detail pane.

## Recommended Architecture

### High-level flow

```text
iPhone/iPad app
  |
  | local network over TLS/WebSocket after pairing
  v
OpenClicky Mac Companion Bridge
  |
  | MainActor-safe commands and async event stream
  v
CompanionManager, CodexAgentSession, widget/task state, voice pipeline
```

### Why a Mac-hosted bridge

OpenClicky already owns:

- Agent sessions and lifecycle in `CodexAgentSession`.
- Voice/realtime settings and speech playback in `CompanionManager`.
- Widgets and task summary snapshots in `OpenClickyWidgetStateStore`.
- Local-only bridge precedent in `OpenClickyExternalControlBridge`.
- SDK-style public wrapper in `OpenClickySDK`.

The companion app should extend that architecture with a trusted-device bridge rather than duplicating runtime logic on iOS.

## Mac-side Components

### 1. `OpenClickyCompanionBridgeServer`

Add a second bridge alongside the current local-only external control bridge.

Purpose:

- Serves paired iOS devices on the local network.
- Exposes task state, voice commands, task commands, attachments, and event streaming.
- Uses a stricter authenticated API than the current `127.0.0.1` bridge.

Suggested transport:

- Bonjour service discovery: `_openclicky._tcp`.
- HTTPS or WebSocket over Network.framework.
- WebSocket for live state and transcript events.
- REST-style POST endpoints for commands and attachment upload.

First version can bind only to local network interfaces and require same-network pairing.

### 2. Pairing store

Add a small Mac-side store:

- Paired device ID.
- Device display name.
- Public key or shared token hash.
- Last seen date.
- Permission flags: voice, task control, attachments, notifications.

Suggested file:

- `~/Library/Application Support/OpenClicky/PairedDevices/paired-devices.json`

Do not put API keys in this store.

### 3. Companion snapshot model

Reuse the widget snapshot as the base, but create a richer companion-specific state model:

```swift
struct OpenClickyCompanionSnapshot: Codable, Equatable {
    var generatedAt: Date
    var connection: CompanionConnectionState
    var voice: CompanionVoiceState
    var activeAgents: [CompanionAgentSummary]
    var selectedAgent: CompanionAgentDetail?
    var needsAttention: [OpenClickyWidgetAttentionItem]
    var todayStats: OpenClickyWidgetTodayStats
    var privacy: OpenClickyWidgetPrivacySettings
}

struct CompanionAgentSummary: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var status: String
    var progressStage: String
    var caption: String?
    var updatedAt: Date
    var canStop: Bool
    var canArchive: Bool
}

struct CompanionAgentDetail: Codable, Equatable {
    var id: UUID
    var title: String
    var entries: [CompanionTranscriptEntry]
    var activityLines: [String]
    var latestResultSummary: String?
}
```

Keep the iOS-facing model deliberately smaller than the full in-process `CodexAgentSession`.

### 4. Event stream

The Mac should push:

- `snapshot.updated`
- `voice.state_changed`
- `voice.partial_transcript`
- `voice.final_transcript`
- `agent.created`
- `agent.updated`
- `agent.completed`
- `agent.failed`
- `attachment.received`
- `permission.changed`

The iOS app should not poll aggressively. It can request a fresh snapshot on resume, then stay on the event stream.

### 5. Command API

Minimum commands:

```text
GET  /health
GET  /pairing/status
POST /pairing/start
POST /pairing/confirm
GET  /snapshot
GET  /events
POST /voice/start
POST /voice/stop
POST /voice/cancel
POST /prompt/text
POST /agent/start
POST /agent/{id}/follow-up
POST /agent/{id}/stop
POST /agent/{id}/archive
POST /attachments
POST /open-on-mac
```

Command notes:

- `/voice/start` can either stream microphone audio from iOS to the Mac voice pipeline or trigger Mac microphone capture. For the companion app, prefer streaming iOS microphone audio so the phone is the actual input device.
- `/prompt/text` should route through the same path as main panel text prompts.
- `/agent/start` should route through `submitNewAgentTaskFromUI(...)` or its equivalent new-task path, not through a fake completion state.
- `/agent/{id}/follow-up` should select the session and queue/send the follow-up just like the Agents panel composer.
- `/open-on-mac` should only open whitelisted local paths/deep links returned by OpenClicky, not arbitrary device-provided paths.

## iOS App UX

### iPhone layout

Primary tab: Talk

- Large Clicky orb / press-to-talk button.
- Current state text: Listening, Thinking, Speaking, Running task.
- Live transcript card.
- Latest reply/result card.
- Active task strip under the voice area.

Second tab: Tasks

- Segmented filter: Active, Needs review, Done.
- Task rows with status dot, title, caption, updated time.
- Swipe actions: Stop, Archive, Open on Mac.
- Tap row opens transcript/detail.

Third tab: Settings

- Pairing status.
- Device permissions: microphone, local network, notifications.
- Privacy level: compact titles only vs detailed content from Mac.
- Mac host selector if multiple OpenClicky Macs are discovered.

### iPad layout

Use a split view:

- Sidebar: Talk, Active Tasks, Review, Settings.
- Main pane: selected conversation/task detail.
- Bottom or floating voice bar always available.
- When an agent is running, show activity timeline and transcript side-by-side if space allows.

### Interaction rules

- Starting a new task while Clicky is speaking should interrupt the old spoken response and start the new capture, matching the Mac behavior.
- Stopping an active agent needs confirmation.
- Archiving a running task should be blocked.
- If the Mac is offline, the app should show cached last-known tasks as stale and disable mutating actions.

## Voice Design

### MVP route

For the first working version:

1. iOS captures microphone audio with `AVAudioEngine`.
2. iOS streams Opus/AAC/PCM chunks to the Mac companion bridge.
3. Mac feeds the audio into the existing OpenClicky voice/realtime pipeline.
4. Mac sends state and transcript events back to iOS.
5. Spoken response can play on:
   - iOS device by default for remote use.
   - Mac by toggle when the user is at the desk.

### Alternative route

If streaming raw audio into the Mac pipeline is too invasive for v1:

- iOS uses Speech framework or OpenAI Realtime directly for transcription/audio.
- iOS sends final text to Mac as a prompt.
- Mac still owns agents, tools, and files.

This is easier to prototype but less faithful to “talk to Clicky” because it bypasses OpenClicky’s existing voice state machine.

## Notifications

Use local notifications first:

- Mac bridge sends event to connected iOS app while in foreground/background if the socket is alive.
- iOS schedules local notifications for task completed, task failed, needs attention.

Later remote option:

- Add APNs only if the user needs notifications when away from the Mac’s local network.
- Avoid hosted accounts by using an optional relay only for notification wakeups, not content.

## Security And Privacy

Pairing flow:

1. User opens OpenClicky Settings → Companion Devices.
2. Mac shows QR code containing host identity, Bonjour name, port, and one-time pairing nonce.
3. iOS scans QR code.
4. iOS and Mac exchange keys and confirm a short code on both screens.
5. Mac stores device authorization.

Rules:

- Require explicit pairing before any remote command.
- Bind tokens to a device keypair.
- Allow revocation from Mac settings.
- Lock sensitive actions behind Mac-side privacy settings.
- Do not expose raw log files, full memory, screenshots, or local paths unless they are selected output artifacts.
- Redact secrets before any transcript/detail leaves the Mac.

## Build Plan

### Phase 1: Mac bridge foundation

- Add `OpenClickyCompanionBridgeServer`.
- Add pairing store and Settings UI for paired devices.
- Add companion snapshot builder from `CompanionManager`, `CodexAgentSession`, and `OpenClickyWidgetStateStore`.
- Add local event stream.
- Add smoke tests for snapshot privacy filtering and command routing.

Exit criteria:

- A local script can pair in development mode, fetch `/snapshot`, and receive agent update events.

### Phase 2: iOS shell

- Add a new iOS target or sibling Swift package app: `OpenClickyCompanion`.
- Build SwiftUI iPhone and iPad layouts.
- Add Bonjour discovery and manual host entry fallback.
- Add QR pairing scanner.
- Render snapshots and live event updates.

Exit criteria:

- iPhone/iPad app can pair with the Mac and display live active tasks.

### Phase 3: Text and task control

- Implement text prompt submission.
- Implement new agent task creation.
- Implement agent follow-up.
- Implement stop/archive with correct safety rules.
- Implement Open on Mac for returned artifacts/deep links.

Exit criteria:

- User can start, steer, stop, and archive OpenClicky agent tasks from iOS.

### Phase 4: Voice

- Add iOS microphone capture.
- Stream audio to the Mac bridge.
- Feed streamed audio into OpenClicky’s voice/realtime path.
- Send partial/final transcript and speaking state back to iOS.
- Add playback destination toggle: iPhone/iPad or Mac.

Exit criteria:

- User can press-to-talk on iPhone/iPad and get a real Clicky response routed through the Mac runtime.

### Phase 5: Attachments and notifications

- Add camera/photo/document attachments.
- Store uploads in an OpenClicky Mac attachment inbox and pass them into agent task context.
- Add foreground/local notifications for task completion/failure.
- Add stale/offline state handling.

Exit criteria:

- User can attach a photo/file to a new iOS-originated task and receive completion notifications.

### Phase 6: Polish

- iPad split-view refinement.
- Widgets or Live Activity exploration for running task status.
- Shortcuts integration for “Ask Clicky” and “Start OpenClicky Agent.”
- Optional remote relay/APNs design if local-network-only is too limiting.

## Repo Touchpoints

Likely new files:

- `leanring-buddy/OpenClickyCompanionBridgeServer.swift`
- `leanring-buddy/OpenClickyCompanionPairingStore.swift`
- `leanring-buddy/OpenClickyCompanionModels.swift`
- `leanring-buddy/OpenClickyCompanionSnapshotStore.swift`
- `leanring-buddy/OpenClickyCompanionSettingsView.swift`
- `OpenClickyCompanion/` or a new Xcode iOS target folder.

Likely existing files to extend:

- `CompanionManager.swift` for command routing and voice session entry points.
- `CodexAgentSession.swift` for sanitized companion transcript summaries if needed.
- `OpenClickyWidgetStateStore.swift` for shared stats/attention conversion.
- `OpenClickySettingsWindowManager.swift` for paired-device settings.
- `leanring_buddyApp.swift` for deep links and bridge lifecycle.
- `README.md` with companion setup once the feature exists.

## MVP Cut

The smallest useful version:

1. Pair iPhone/iPad to Mac on local network.
2. Show active tasks and needs-attention items.
3. Start a new text agent task.
4. Send follow-up to a selected task.
5. Stop/archive safely.
6. Press-to-talk streams iOS microphone audio to the Mac and returns a spoken/text reply.

Do not include remote cloud access, account login, iCloud sync, or direct Codex-on-iOS execution in the MVP.

## Open Questions

- Should the iOS app be inside this Xcode project as a second target, or a sibling project that shares a Swift package for models/networking?
- Should spoken replies default to the iOS device, the Mac, or “where the request came from”?
- How much transcript history should be cached on iOS?
- Should the companion app be local-network-only permanently, or should it later support away-from-home access through a relay?
- Should iOS-originated tasks show a distinct source badge in the Mac Agents panel?
