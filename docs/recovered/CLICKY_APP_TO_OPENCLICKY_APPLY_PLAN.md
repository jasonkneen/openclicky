# Clicky.app → OpenClicky Apply Plan

Scope: map recovered Clicky.app Swift/UI contracts into the live OpenClicky repo at `/Users/jkneen/clawd/github/openclicky` without copying proprietary implementation.

Repo identity verified from `AGENTS.md` and `README.md`: OpenClicky native macOS app, bundle id `com.jkneen.openclicky`, legacy `leanring-buddy` folder/scheme preserved.

Current git state at inspection: `main...origin/main [ahead 6]` with existing modified/untracked skill-resource files. This plan is a sidecar only; no source files are intentionally changed by it.

## Existing overlap

OpenClicky already has these recovered Clicky-lineage files or equivalents:

- `leanring-buddy/CompanionManager.swift`
- `leanring-buddy/CompanionPanelView.swift`
- `leanring-buddy/MenuBarPanelManager.swift`
- `leanring-buddy/OverlayWindow.swift`
- `leanring-buddy/CodexHUDWindowManager.swift`
- `leanring-buddy/CodexAgentSession.swift`
- `leanring-buddy/DesignSystem.swift`
- `leanring-buddy/ClickyNextStageParityModels.swift`
- `leanring-buddy/ClickyNextStageParityViews.swift`
- `leanring-buddy/OpenClickySettingsWindowManager.swift`
- `leanring-buddy/OpenClickyComputerUseRuntime.swift`
- `leanring-buddy/OpenClickyExternalControlBridge.swift`
- `AppResources/OpenClicky/OpenClickyBundledSkills/`

Recovered source markers found existing exactly: 16 / 65. OpenClicky has 74 Swift files total.

## Highest-value code we can apply

### 1. Notch surfaces as OpenClicky compact HUD views

Recovered Clicky components:

- `NotchRootView`
- `NotchPanel`
- `NotchHomeTab`
- `NotchAgentsTab`
- `NotchSettingsTab`
- `NotchTextInputSurface`
- `NotchTextResponseSurface`
- `NotchActivitySurface`
- `NotchAgentSurface`

OpenClicky target:

- Possible new clean-room file: `leanring-buddy/OpenClickyCompactHUDView.swift`
- Existing host/wiring candidates: `leanring-buddy/CodexHUDWindowManager.swift` and `leanring-buddy/MenuBarPanelManager.swift`
- Existing state: `CompanionManager`, `CodexAgentSession`, `DesignSystem`

Apply as OpenClicky-native compact HUD, not a Clicky-branded notch clone. Start with three tabs/views:

- Home: permission state, voice shortcut hint, active integrations, update pill, dock/cursor controls.
- Agents: running agent rows, activity timeline, notifications, thread history, artifact preview tiles.
- Settings: pill-card rows, provider/API settings entrypoints, permissions, crons, model/folder shortcuts.

Recovered helper contracts to preserve structurally:

- `NotchHomeTab`: `primaryHomeContent`, `meetClickyBlock`, `permissionIntroBlock`, `permissionActiveCardBlock`, `voiceShortcutHintRow`, `activeIntegrationsSection`, `updateReadyPill`.
- `NotchAgentsTab`: `loadingState`, `runningRow`, `activityTimelineView`, `notificationRow`, `threadRow`, `artifactsBlock`, `artifactPreviewTile`, `statusChip`.
- `NotchSettingsTab`: `mainSettingsList`, `pillCard`, `planUsageMeter`, `agentPermissionsPage`, `integrationsPage`, `cronsPage`, `settingsRowBody`, `actionRow`, `toggleRow`.
- `NotchTextInputSurface`: `attachButton`, `attachmentChipsRow`, `inputColumn`, `sendButton`.
- `NotchTextResponseSurface`: `textStreamActorSlot`, `chromeControl`, `closeButton`, `dismissPill`, `actionPill`.

### 2. Improve existing ChatWorkspace composer using recovered NotchTextInputSurface

OpenClicky target:

- `leanring-buddy/ChatWorkspaceView.swift`

Current state:

- Composer is real but thin: `plus` button is empty, no attachment chips, no text compose actor slot, no draft attachments.

Apply:

- Add real attachment model + file importer/drop support.
- Show attachment chips row.
- Wire plus button to import attachments.
- Pass attachment paths into `CompanionManager.submitAgentPromptFromUI` or add a sibling method if needed.
- Keep existing ChatGPT-style shape; do not introduce Clicky branding.

### 3. Agent dashboard parity from NotchAgentsTab

OpenClicky target:

- `leanring-buddy/CodexHUDWindowManager.swift`
- `leanring-buddy/ChatWorkspaceView.swift`
- `leanring-buddy/CodexAgentSession.swift`

Apply:

- Add a reusable `OpenClickyAgentActivityList`/`OpenClickyAgentThreadRow` component.
- Add structured sections for running tasks, notifications, and completed threads.
- Render artifact previews from existing `CodexAgentFileDiffItem`/openable file extraction.
- Add status chips and remove-from-history action.

This is one of the strongest direct ports because recovered helpers map cleanly to existing `CodexAgentSession` types.

### 4. Settings parity from NotchSettingsTab / CompanionPanelView

OpenClicky target:

- `leanring-buddy/OpenClickySettingsWindowManager.swift`
- `leanring-buddy/OpenClickyAgentsSettingsSection.swift`
- `leanring-buddy/OpenClickyAutomationsSettingsSection.swift`
- `leanring-buddy/CodexAgentModePanelSection.swift`

Apply:

- Convert repeated settings UI into reusable `settingsRowBody`, `actionRow`, `toggleRow`, `pillCard`, `planUsageMeter`-style helpers using `DS` tokens.
- Add missing compact subsections: Agent folder, Crons, Integration search/filter, Permissions status card, Build info footer.
- Preserve OpenClicky local-key privacy model. Do not add Supabase login, hosted Google auth, Cloudflare worker dependency, telemetry, or paywall.

### 5. Permission inspector / permission coach

Recovered Clicky files:

- `AgentPermissionsInspector.swift`
- `AgentPermissionsPage.swift`
- `PermissionFlowCoordinator.swift`
- `PermissionGuideAssistant.swift`

OpenClicky existing:

- `ClickyNextStageParityModels.swift` has `PermissionGuideAssistant`, `PermissionSnapshot`, `PermissionStatus`.
- `ClickyNextStageParityViews.swift` has `ClickyPermissionGuideSection`.
- `OpenClickySettingsWindowManager.swift` has Permissions section.

Apply:

- Create `OpenClickyAgentPermissionsPage.swift` or fold into settings.
- Add stale-cache and timeout states.
- Add per-permission rows for Accessibility, Screen Recording, Microphone, Speech Recognition.
- Add status badges and direct System Settings buttons.

### 6. Detached cursor / handoff overlays

Recovered Clicky components:

- `CursorTextInputOverlay.swift`
- `HandoffIndicatorWindow.swift`
- `HandoffRegionSelectOverlay.swift`
- `HandoffVoiceStopWindow.swift`
- `TextInjectionDelivery.swift`

OpenClicky existing:

- `OverlayWindow.swift`
- `OpenClickyExternalControlBridge.swift`
- `ClickyNextStageParityModels.swift`
- `ClickyNextStageParityViews.swift`

Apply:

- Add text-follow-up mini surface near cursor.
- Add region selection overlay for handoff screenshots.
- Add voice stop pill / handoff indicator chip.
- Use existing overlay manager and external bridge; keep no cursor warping.

### 7. Companion actor / activity micro-animations

Recovered Clicky components:

- `CompanionActorRenderer`
- `CompanionActorState`
- `CompanionActorSurface`
- `NotchActivitySurface`
- `VoiceWaveformBars`
- `InlineVoiceRecordingWaveformView`

OpenClicky existing:

- `ClickyBuddyPet.swift`
- `ClickyPetSpriteView.swift`
- `OverlayWindow.swift`
- `DesignSystem.swift`

Apply:

- Map listening/thinking/speaking/working states to existing pet/cursor overlay.
- Add compact waveform/equalizer bars to panel/HUD.
- Avoid copying assets; use original OpenClicky pet/artwork or SF-symbol/vector animation.

## Skip / do not apply

- Supabase auth/key sync (`SupabaseAuthManager`) — conflicts with OpenClicky local-key model.
- Billing/paywall (`BillingClient`, paywall HUD/cards) — not appropriate for privacy-first OpenClicky unless explicitly requested later.
- PostHog/Sentry telemetry defaults — privacy posture says omit by default.
- Hosted Cloudflare worker dependency — README/AGENTS explicitly says do not hard-depend on it.
- Clicky branding/copy/assets — re-express as OpenClicky.
- Exact proprietary SwiftUI bodies — clean-room only.

## Recommended implementation bursts

### Burst 1: Composer + attachment chips

Files:

- `leanring-buddy/ChatWorkspaceView.swift`
- maybe `leanring-buddy/CodexAgentSession.swift`

Why first: smallest visible improvement; directly maps recovered `NotchTextInputSurface` helpers into existing real UI.

Verification:

```sh
swiftc -parse leanring-buddy/ChatWorkspaceView.swift
```

### Burst 2: Agent activity/thread row components

Files:

- `leanring-buddy/CodexHUDWindowManager.swift`
- optional new `leanring-buddy/OpenClickyAgentActivityViews.swift`

Why second: high parity value from `NotchAgentsTab` and existing session model.

Verification:

```sh
swiftc -parse leanring-buddy/OpenClickyAgentActivityViews.swift leanring-buddy/CodexHUDWindowManager.swift
```

### Burst 3: Permissions page polish

Files:

- `leanring-buddy/ClickyNextStageParityViews.swift`
- `leanring-buddy/OpenClickySettingsWindowManager.swift`
- optional new `leanring-buddy/OpenClickyAgentPermissionsPage.swift`

Why third: high user trust value and low product-risk.

### Burst 4: Compact HUD / notch-inspired mini-window

Files:

- new `leanring-buddy/OpenClickyCompactHUDView.swift`
- `leanring-buddy/CodexHUDWindowManager.swift`
- `leanring-buddy/MenuBarPanelManager.swift`

Why fourth: bigger UX change; should come after reusable pieces exist.

## Verification constraints

Do not run terminal `xcodebuild`. Use lightweight source checks only, per repo instructions.

```sh
swiftc -parse <changed Swift files>
```

Do not launch unsigned builds for TCC/permission approval.
