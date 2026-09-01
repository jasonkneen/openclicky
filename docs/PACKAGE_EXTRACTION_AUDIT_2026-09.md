# OpenClicky Package Extraction Audit

Date: 2026-09-01

## Goal

Identify code that can leave the `cursor-buddy` app target and become independently testable Swift packages that are reusable by other macOS systems. The aim is not to package every large file; it is to create stable boundaries around capabilities while keeping OpenClicky-specific orchestration in the app.

## Current Position

OpenClicky already has five local Swift packages:

- `OpenClickyCore`: theme and wiki primitives
- `OpenClickyUI`: design system and liquid-glass components
- `OpenClickyBrowser`: browser workspace and browser-agent integration
- `OpenClickyMarkdown`: markdown viewer
- `OpenClickyMemory`: memory workspace UI

Those packages account for about 8,300 lines, while the app target still contains roughly 79,000 lines across 116 Swift files. The previous modularisation concentrated on UI workspaces. The strongest remaining seams are runtime capabilities and pure domain models.

The existing package graph is simple and should stay acyclic:

```text
OpenClickyCore
  └─ OpenClickyUI
       ├─ OpenClickyMarkdown
       ├─ OpenClickyMemory
       └─ OpenClickyBrowser
```

New capability packages should depend on Foundation or a small core target, not on `OpenClickyUI`, `CompanionManager`, or the app bundle.

## Recommended Extractions

### 1. OpenClickyAutomation

Priority: highest

Initial source set:

- `OpenClickyAutomation.swift`
- the persistence-neutral parts of `OpenClickyAutomationStore.swift`
- `OpenClickyJSONFileStore.swift`, either here initially or in a small persistence target

Why it is a good boundary:

- `OpenClickyAutomationSchedule`, `OpenClickyAutomation`, and `CronExpression` are Foundation-only.
- The cron evaluator is useful outside OpenClicky and already describes a coherent capability.
- Scheduling, persistence, and execution can be tested without UI or microphone permissions.

Required decoupling:

- Define an `AutomationExecutor` protocol instead of directly creating or inspecting `CodexAgentSession`.
- Inject clock, file location, application context, and prompt execution.
- Move skill-discovery UI state out of the automation store; it is a separate feature despite sharing the file today.

Suggested targets:

```text
OpenClickyAutomationCore   schedule models + cron evaluator
OpenClickyAutomationStore  persistence + timer coordinator
```

First tests should cover named cron fields, Vixie day-of-month/day-of-week semantics, missed intervals, disabled jobs, and deterministic next-fire calculation.

### 2. OpenClickySpeech

Priority: high

Initial source set:

- `BuddyTranscriptionProvider.swift`
- `BuddyAudioConversionSupport.swift`
- `StreamingWebSocketTranscriptionSession.swift`
- `AppleSpeechTranscriptionProvider.swift`
- `OpenAIAudioTranscriptionProvider.swift`
- `DeepgramStreamingTranscriptionProvider.swift`
- `AssemblyAIStreamingTranscriptionProvider.swift`
- `OpenClickyParakeetTranscriptionProvider.swift`
- `TTSStreamingPlaybackEngine.swift`
- `ElevenLabsTTSClient.swift`
- `CartesiaTTSClient.swift`
- `DeepgramTTSClient.swift`
- `MicrosoftEdgeTTSClient.swift`
- the provider-neutral portion of `OpenAIRealtimeSpeechClient.swift`

Why it is a good boundary:

- Transcription and TTS already communicate through protocols.
- The implementations are reusable in any macOS voice application.
- AVFoundation-heavy code can be isolated from the rest of the app and tested with audio fixtures.

Required decoupling:

- Rename `BuddyTranscriptionProvider` and `OpenClickyTTSClient` to package-neutral public protocols, retaining typealiases in the app during migration.
- Move provider selection out of `UserDefaults` and `AppBundleConfiguration`; accept an explicit configuration and credential resolver.
- Split `ElevenLabsTTSClient.swift`: it currently contains the ElevenLabs client, streaming session, filler phrase library, shared TTS protocol, and Deepgram voice-agent client in one 1,800-line file.
- Keep OpenClicky's money-rule/provider-order policy in the app orchestration layer, not in the transport package.

Suggested targets in one package:

```text
OpenClickyAudioCore          public audio/session protocols and PCM helpers
OpenClickyTranscription     Apple, OpenAI, Deepgram, AssemblyAI, Parakeet
OpenClickyTextToSpeech      ElevenLabs, Cartesia, Deepgram, Edge
OpenClickyRealtimeVoice     realtime bidirectional session transport
```

Separate targets prevent a consumer from inheriting CoreML, Speech, every network provider, and every playback implementation when it needs only one capability.

### 3. OpenClickyComputerUse

Priority: high

Initial source set:

- `OpenClickyComputerUseModels.swift`
- `OpenClickyComputerUseRuntime.swift`
- `OpenClickyVisualGuidanceOverlayModels.swift`
- `CompanionScreenCaptureUtility.swift`
- the Accessibility-based portion of `ElementLocationDetector.swift`
- `CircleSelectSnapResolver.swift`

Why it is a good boundary:

- The models are already `Sendable`, `Codable`, and largely independent.
- Window enumeration, capture, keyboard input, mouse input, and permission probing form a reusable macOS automation capability.
- This is directly useful to other agent hosts, testing tools, and accessibility utilities.

Required decoupling:

- Separate pure models from AppKit/Accessibility/ScreenCaptureKit implementations.
- Inject bundle identifier, permission copy, logger, and frontmost-application resolver rather than reading `AppBundleConfiguration`, `Bundle.main`, or `NSApp`.
- Keep `CodexPointDetector` in an agent-integration package; model inference is not part of computer-use mechanics.
- Keep actual visual overlay windows in the OpenClicky app or a later presentation package. Overlay data models can move now.
- Expose capabilities through narrow protocols such as `WindowEnumerating`, `WindowCapturing`, `KeyboardControlling`, and `PointerControlling` rather than one global controller.

Suggested targets:

```text
OpenClickyComputerUseCore   models, errors, commands, capability protocols
OpenClickyMacComputerUse    AX, CGEvent, ScreenCaptureKit implementations
```

This package needs explicit permission-contract documentation so host apps know which Info.plist keys and TCC grants they must supply.

### 4. OpenClickyAgentRuntime

Priority: medium-high, but extract in stages

Low-coupling first stage:

- `CodexRPCRequest.swift`
- `CodexRuntimeLocator.swift`
- `ClickyCodexConfigTemplate.swift`
- `CodexProcessManager.swift`
- `OpenClickyAgentDefinition.swift`
- `OpenClickyAgentStore.swift`

Later stage:

- `CodexHomeManager.swift`
- the transport and transcript portions of `CodexAgentSession.swift`
- provider-neutral parts of `OpenClickyAgentManager.swift`

Why it is valuable:

- Other macOS apps could embed the same local Codex/Claude agent lifecycle without pulling in the OpenClicky HUD, notch, speech, or overlay.
- Runtime discovery, config rendering, process supervision, transcript parsing, and specialist-agent definitions are coherent reusable services.

Required decoupling:

- Replace direct calls to `OpenClickyMessageLogStore.shared` with an injected logger protocol.
- Replace `AppBundleConfiguration`, `Bundle.main`, and `UserDefaults.standard` access with a runtime environment value.
- Split the 2,450-line `CodexAgentSession` into transport, transcript reducer, file-lease coordinator, screen-context attachment builder, and OpenClicky UI adapter.
- Move `BrowserWorkspaceAgentSessionProtocol` conformance to an adapter in the app or browser package so the runtime package does not depend on `OpenClickyBrowser`.
- Replace direct `CompanionManager.shared` access with closures or event sinks.
- Keep HUD state, spoken completion summaries, task cards, and OpenClicky-specific prompt assembly outside the package.

Suggested targets:

```text
OpenClickyAgentCore       definitions, transcript/status models, file leases
OpenClickyCodexRuntime    runtime lookup, config, process/RPC transport
OpenClickyAgentStorage    specialist definitions and on-disk overlays
```

This should not be attempted as a single file move. The app-specific calls in `CodexAgentSession` make a big-bang package likely to reproduce the current coupling behind `public` declarations.

### 5. OpenClickyPersistence

Priority: medium

Initial source set:

- `OpenClickyJSONFileStore.swift`
- pure record/envelope types from `OpenClickyMessageLogStore.swift`
- pure models from `OpenClickyWidgetModels.swift`
- persistence-neutral parts of `OpenClickyApplicationUsageLogStore.swift`

Why it is useful:

- Atomic Codable file storage, JSONL append/read, retention, and app-group snapshot writing recur across OpenClicky.
- A shared persistence package prevents each future package from inventing its own file and locking behavior.

Required decoupling:

- Use caller-supplied URLs and retention policies.
- Do not put OpenClicky directory names or app-group identifiers in the generic layer.
- Split data models from `WidgetKit` publishing. `OpenClickyWidgetStateStore` currently mixes state construction, app configuration, logging, user defaults, and widget reloads.

Suggested targets:

```text
OpenClickyPersistenceCore  atomic Codable files + JSONL utilities
OpenClickyWidgetBridge     OpenClicky snapshot schema + WidgetKit publisher
```

The generic persistence target should be depended on by other capability packages, never the reverse.

### 6. OpenClickyWindowKit

Priority: medium-low

Initial source set:

- `OpenClickyManagedWindowController.swift`
- generic parts of `OpenClickyWindowInfrastructure.swift`
- generic positioning logic from `WindowPositionManager.swift`

Why it is useful:

- The app repeats non-activating panels, hosting-view wiring, liquid-glass surfaces, window levels, and managed lifecycle behavior.
- These primitives could support other macOS companion apps.

Required decoupling:

- Inject glass appearance values instead of reading OpenClicky defaults keys.
- Separate reusable NSWindow/NSPanel lifecycle from OpenClicky window-level policy.
- Avoid a dependency on `OpenClickyCore` merely to obtain theme values; accept appearance inputs or define a tiny presentation protocol.

This should follow the runtime packages. Window abstractions are easier to over-generalise and should be extracted only after two or more OpenClicky windows use the same stable API.

### 7. OpenClicky3D

Priority: medium-low, easy standalone win

Initial source set:

- `ThreeDGenerationTypes.swift`
- `TripoThreeDProvider.swift`
- provider-neutral job handling from `ThreeDGenerationService.swift`

Why it is a good boundary:

- `ThreeDGenerationProvider` already provides the seam.
- Request, progress, result, error, and provider types are independent of the OpenClicky UI.

Required decoupling:

- Inject credentials; do not read `UserDefaults` or environment variables inside the service.
- Keep `ThreeDChatBubbleView`, `ThreeDViewerView`, and window management in the app or a separate optional UI target.
- Make polling policy and URLSession injectable for deterministic tests.

Suggested targets:

```text
OpenClicky3DCore       request/result/provider protocols
OpenClickyTripo        Tripo transport implementation
```

## Expand Existing Packages Instead of Creating New Ones

Some code should move, but not into another new package:

- `OpenClickyModelProvider`, `OpenClickyModelOption`, and model-normalisation primitives can move to `OpenClickyCore`. The concrete current product catalog should stay in the app because it is OpenClicky policy and changes with available models.
- Pure response-card, permission-guide, and handoff models in `ClickyNextStageParityModels.swift` belong in `OpenClickyCore` if they remain shared by browser, memory, and app surfaces.
- Generic visual tokens should continue moving into `OpenClickyUI`; complete feature views should stay with their feature package or the app.
- `WikiRuntimeManager` should be reviewed against `OpenClickyCore/WikiManager.swift`; duplicated file-location and seed-install behavior should be consolidated rather than creating a third wiki module.

## Code That Should Stay in the App Shell

Do not package these yet:

- `CompanionManager.swift` and its extensions: this is the composition root and product state machine.
- Settings views and `OpenClickySettingsWindowManager`: they encode product policy and user-facing choices.
- notch, HUD, response bubble, overlay, and menu-bar presentation.
- `cursor_buddyApp.swift` and app lifecycle/delegate wiring.
- the concrete `OpenClickyModelCatalog` lists and provider-order/money-rule policy.
- onboarding, notifications, product copy, and bundled-resource installation policy.

The target outcome is a thin OpenClicky shell that composes packages. Moving the shell itself into a package would merely hide the monolith.

## Cross-Cutting Problems to Fix During Extraction

### Configuration globals

`AppBundleConfiguration`, `UserDefaults.standard`, `Bundle.main`, and environment-variable reads currently appear inside candidate runtime code. Each package should accept a configuration value and explicit resource/credential providers.

### Logging singleton

Runtime code calls `OpenClickyMessageLogStore.shared` directly. Define a small `OpenClickyLogSink` protocol with a no-op default; the app can adapt its existing log store.

### Main-actor leakage

Only UI state and AVFoundation objects that require the main actor should be main-actor isolated. Network transport, parsing, file I/O, cron evaluation, and process supervision should remain testable off the main actor.

### Access control

Most app-target declarations are internal. Make APIs public deliberately after a package boundary is stable, rather than mechanically marking every moved type public.

### Package platform floor

Every current package declares macOS 26.0. For genuine reuse, lower each package's deployment target to the oldest OS required by its own APIs. A pure Foundation automation or persistence package should not inherit the app's macOS 26 floor.

### Package tests

The five existing packages have no checked-in `Tests` targets. New extraction should not continue that pattern. Put tests beside each package, especially for cron parsing, config rendering, transcript reduction, JSONL retention, model normalisation, and computer-use geometry.

### Generated build artefacts

Local package `.build` and `.swiftpm` state exists under package folders. These are not source boundaries and should remain ignored. Package audits and scripts should prune them to avoid treating compiler caches as package content.

## Recommended Dependency Graph

```text
OpenClickyCore
├─ OpenClickyPersistenceCore
├─ OpenClickyAutomationCore
├─ OpenClickyAudioCore
├─ OpenClickyComputerUseCore
├─ OpenClickyAgentCore
└─ OpenClicky3DCore

OpenClickyPersistenceCore
├─ OpenClickyAutomationStore
├─ OpenClickyAgentStorage
└─ OpenClickyWidgetBridge

OpenClickyAudioCore
├─ OpenClickyTranscription
├─ OpenClickyTextToSpeech
└─ OpenClickyRealtimeVoice

OpenClickyComputerUseCore
└─ OpenClickyMacComputerUse

OpenClickyAgentCore
└─ OpenClickyCodexRuntime

OpenClicky3DCore
└─ OpenClickyTripo
```

`OpenClickyUI` may depend on core model packages for rendering, but runtime packages must not depend on `OpenClickyUI`.

## Migration Order

1. Add tests around the pure cron, model, config, JSON, and geometry behavior before moving files.
2. Extract `OpenClickyAutomationCore` and `OpenClickyPersistenceCore` as low-risk boundaries.
3. Extract `OpenClickyAudioCore` plus one provider at a time.
4. Extract `OpenClickyComputerUseCore`, then the macOS implementation behind protocols.
5. Extract runtime locator/config/process primitives into `OpenClickyCodexRuntime`.
6. Split `CodexAgentSession`; move transport and models only after the singleton callbacks are removed.
7. Extract 3D provider types and transport.
8. Extract window infrastructure only after the capability boundaries have reduced app-level coupling.
9. Update `OpenClickySDK` to expose composed package capabilities instead of requiring host apps to link the entire `cursor-buddy/*.swift` directory.

Each migration should keep temporary app-target typealiases/adapters, move one dependency direction at a time, and compile the package independently before removing the original app-target declaration.

## Best First Slice

The safest useful first implementation is:

1. Create `OpenClickyAutomation` with `OpenClickyAutomationSchedule`, `OpenClickyAutomation`, and `CronExpression`.
2. Add package tests for cron parsing and next-run calculation.
3. Create `OpenClickyPersistenceCore` with the atomic Codable helper.
4. Make the app's automation store consume those products without changing its execution behavior.

That produces two reusable libraries with almost no UI or permission risk, establishes the package test pattern missing from the current five packages, and creates infrastructure needed by the later agent-runtime extraction.
