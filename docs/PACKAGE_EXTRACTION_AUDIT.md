# OpenClicky Package Extraction Audit

## Goal

Move reusable capabilities out of the `cursor-buddy` application target without
turning the package graph into a mirror of the app's UI. The extracted products
should be usable by another macOS app without constructing `CompanionManager`,
opening OpenClicky windows, or reading OpenClicky's global `UserDefaults` keys.

This audit is based on the current source tree. It does not move files yet.

## Current state

OpenClicky already has five local Swift packages:

| Package | Approximate source size | Current responsibility |
| --- | ---: | --- |
| `OpenClickyCore` | 505 lines | Theme values and wiki indexing |
| `OpenClickyUI` | 1,219 lines | Design system and liquid glass views |
| `OpenClickyBrowser` | 5,543 lines | Browser workspace, browser agent and host delegate |
| `OpenClickyMarkdown` | 517 lines | Markdown viewer/window |
| `OpenClickyMemory` | 421 lines | Memory workspace UI |

About 79,000 lines of Swift remain in the application target. The public
`OpenClickySDKSession` also remains in that target, so the documented SDK is
still a source-linking integration rather than a consumable Swift package.

The existing boundaries prove that local packages work in the Xcode project,
but they also expose issues to avoid in the next extractions:

- `OpenClickyCore` mixes UI/AppKit theme concerns with wiki storage/indexing.
- `OpenClickyBrowser` is a capability package, but nearly all of it lives in two
  files (`BrowserWorkspace.swift` and `OpenClickyBrowserAgent.swift`). It mixes
  WebKit UI, agent orchestration, provider HTTP, persistence and credentials.
- All package manifests require macOS 26. Reusable targets should declare the
  oldest platform their APIs actually need.
- None of the packages has a test target.
- `OpenClickyImports.swift` re-exports modules into the app target, which makes
  real dependency direction harder to see.

## Recommended target graph

Keep the graph one-way and host-driven:

```text
OpenClickyFoundation
    |-- OpenClickyModels
    |-- OpenClickySpeech
    |-- OpenClickyComputerUse
    |-- OpenClickyAgentRuntime
    |-- OpenClickyAutomation
    `-- OpenClicky3D

OpenClickyUI --> OpenClickyModels
OpenClickyBrowser --> Models + AgentRuntime + UI
OpenClickyApp --> every capability package
```

`OpenClickyFoundation` should be small: file-store utilities, injectable clock,
process execution contracts, credential contracts and logging contracts. It
must not import SwiftUI, AppKit, WebKit, ScreenCaptureKit or the app target.

This can be implemented either as sibling local packages, matching the current
layout, or as multiple targets/products in one `OpenClickyKit` package. A single
manifest with multiple products will be easier to version externally and will
still let consumers link only the products they need.

## Extraction candidates

### 1. `OpenClicky3D` — first extraction

**Why:** The provider abstraction already exists and the core has very little
app coupling. This is the cleanest proof that an extracted capability can be
used independently.

**Move into the package:**

- `ThreeDGenerationTypes.swift`
- `TripoThreeDProvider.swift`
- the provider-independent part of `ThreeDGenerationService.swift`
- sentinel parsing from `ThreeDGenerationDispatcher.swift`

**Optional UI product:**

- `ThreeDViewerView.swift`
- `ThreeDViewerWindowManager.swift`
- `ThreeDChatBubbleView.swift`

**Leave in the host adapter:**

- code that opens `ThreeDViewerWindowManager.shared`
- registration in `ClaudeAgentSDKAPI` and `CodexAgentSession`
- OpenClicky-specific default prompts and Settings labels

**Required decoupling:** Inject an assets directory and credential provider.
Do not read `UserDefaults.standard` or hard-code
`Application Support/OpenClicky` in the reusable service. Make the existing
types and initializers public. Put the SceneKit/GLTF viewer in a separate UI
target so generation clients do not acquire UI dependencies.

### 2. `OpenClickyComputerUse` — highest reuse value

**Why:** The approximately 4,000-line cluster already has strongly named models
and controllers and is referenced through a small number of host call sites.
It is useful to any macOS agent, accessibility tool or voice-control app.

**Move:**

- `OpenClickyComputerUseModels.swift`
- `OpenClickyComputerUseRuntime.swift`
- `CompanionScreenCaptureUtility.swift`
- `OpenClickyVisualGuidanceOverlayModels.swift`
- `CircleSelectSession.swift`
- `CircleSelectSnapResolver.swift`

`ElementLocationDetector.swift` and `CodexPointDetector.swift` belong in a
separate `OpenClickyComputerVision` or agent adapter target because they add
model-provider and Codex runtime dependencies to otherwise local computer use.

**Required decoupling:**

- Replace calls into `OpenClickyApplicationUsageLogStore` with an injected
  `ApplicationUsageRecording` protocol.
- Replace `WindowPositionManager` and app permission-state references with
  value types/protocols owned by this package.
- Pass capture and input policy through configuration rather than
  `AppBundleConfiguration`.
- Keep the private SkyLight event path behind a package-internal strategy and
  expose only supported mouse/keyboard operations.
- Use explicit coordinate-space types at the public boundary instead of raw
  `CGPoint` values whose pixel/point meaning is implicit.

### 3. `OpenClickySpeech` — large, coherent provider ecosystem

**Why:** Roughly 8,500 lines already form a provider-based subsystem. Most
provider implementations only need Foundation/AVFoundation and shared audio
helpers.

**Move first:**

- `BuddyTranscriptionProvider.swift`
- `BuddyAudioConversionSupport.swift`
- `StreamingWebSocketTranscriptionSession.swift`
- `TTSStreamingPlaybackEngine.swift`
- Apple, AssemblyAI, Deepgram, OpenAI and Parakeet transcription providers
- Cartesia, Deepgram, ElevenLabs and Microsoft Edge TTS clients
- `OpenAIRealtimeSpeechClient.swift`

**Move later or keep as host integration:**

- `BuddyDictationManager.swift`
- `OpenClickyWakeWordManager.swift`
- `OpenClickyLocalSpeechModelManager.swift`
- `OpenClickyVoiceBackendSelector.swift`

**Required decoupling:** Define `CredentialProviding`, `SpeechEventLogging` and
`AudioSessionConfig` contracts. Providers currently reach into
`AppBundleConfiguration`, and realtime/dictation/wake-word code logs directly
through `OpenClickyMessageLogStore`. Remove the `CompanionManager` references
from TTS callbacks. Split provider implementations into optional targets if
FluidAudio/CoreML should not be required by every consumer.

Suggested products:

- `OpenClickySpeechCore`
- `OpenClickySpeechApple`
- `OpenClickySpeechRemoteProviders`
- `OpenClickySpeechLocalModels`

### 4. `OpenClickyModels` — small extraction with immediate payoff

**Why:** Model/provider/profile configuration is reused by settings, voice,
agents and SDK surfaces. It should not be owned by `CompanionManager`.

**Move:**

- `OpenClickyModelCatalog.swift`
- `OpenClickyLocalModelCatalog.swift`
- `OpenClickyProfile.swift`
- `OpenClickyRuntimeMode.swift`
- provider descriptor value types from `OpenClickyProviderDiscovery.swift`

Keep active probing in a macOS-specific target. Replace profile references to
`CompanionManager` and concrete speech providers with stable identifiers and
host-supplied resolution. Move `Theme.swift` out of `OpenClickyCore` and into
`OpenClickyUI`; then `OpenClickyCore` can become the seed of this models target
or be renamed to reflect its actual wiki responsibility.

### 5. `OpenClickyAgentRuntime` — important but extract in layers

**Why:** This is the capability needed to make `OpenClickySDKSession` a real
package product. It is also one of the most coupled areas, so moving the whole
cluster at once would merely relocate the monolith.

**Layer A, process/RPC:**

- `CodexRPCRequest.swift`
- `CodexRuntimeLocator.swift`
- `CodexProcessManager.swift`
- generic process helpers from `ClaudeAgentSDKAPI.swift`

**Layer B, home and durable state:**

- reusable portions of `CodexHomeManager.swift`
- agent definition/store models
- config template generation

**Layer C, sessions:**

- `CodexAgentSession.swift`
- `ClaudeAgentSDKAPI.swift`
- `ClaudeAPI.swift`

The session layer must depend on injected interfaces for transcript logging,
widget updates, title generation, 3D tool registration and host actions. It
must not import `OpenClickyBrowser` or know about `CompanionManager` or
`ClickyResponseCard`. Browser conformance belongs in the app/browser adapter.

### 6. `OpenClickyAutomation`

**Why:** Schedule parsing, persisted automation definitions, skill suggestions
and application-usage context can operate independently of the OpenClicky UI.

**Move:**

- `OpenClickyAutomation.swift`
- schedule/store persistence from `OpenClickyAutomationStore.swift`
- `OpenClickyApplicationUsageLogStore.swift`
- `OpenClickyAppSkillContext.swift`
- `OpenClickyGogCLIStatus.swift`

Replace `bind(companion: CompanionManager)` with an injected executor such as:

```swift
public protocol AutomationExecuting: AnyObject {
    func execute(_ request: AutomationExecutionRequest) async throws -> UUID?
}
```

Keep automation Settings views in the app or an `OpenClickyAutomationUI`
target. Treat `OpenClickyExternalControlBridge.swift` as a separate
`OpenClickyControlBridge` package because its local HTTP/MCP server has a
different security and lifecycle boundary.

### 7. `OpenClickySharedState` — remove duplicated contracts

**Why:** `OpenClickyWidgetModels.swift` is duplicated between the app and widget
targets and has already drifted: the app copy has `nonisolated` annotations, an
attention-item initializer and an agent deep-link helper that the widget copy
lacks.

**Move:**

- widget snapshot, summary, privacy and deep-link value types
- `OpenClickyJSONFileStore.swift`
- host-neutral message-log record types

Both the app and widget extension should import one shared target. Keep
`WidgetKit` writers/readers, notifications and app-group path selection in
platform adapters so the shared model target remains Foundation-only.

### 8. `OpenClickyWindowing` — useful after capability extraction

**Move:**

- `OpenClickyManagedWindowController.swift`
- generic glass/container pieces from `OpenClickyWindowInfrastructure.swift`
- `ResponseOverlayAutoHidePolicy.swift`

Do not move `WindowPositionManager` unchanged: it combines positioning,
permissions, screen capture and a permission-assistant UI. Split those concerns
first. Also remove references from generic window infrastructure to
`OpenClickyNotchCaptureWindowManager` and global app settings.

## What should remain application-owned

These are OpenClicky composition and product experience rather than reusable
libraries:

- `CompanionManager` and its extensions, until its routing responsibilities are
  replaced by explicit capability coordinators
- menu-bar, notch, HUD, settings, onboarding and app entry-point code
- pet/hatching experience
- OpenClicky-specific prompt wording and default automation installation
- concrete wiring between voice, agents, widgets, browser and overlays

`CompanionManager.swift` is over 16,000 lines. Package extraction will only help
if the app keeps adapters and orchestration while algorithms, protocols and
state machines move behind narrow public APIs. Moving the manager itself into a
package would make the coupling reusable rather than remove it.

## Recommended extraction order

1. Create the shared Foundation contracts and shared widget models.
2. Extract `OpenClicky3D` and add package tests for sentinel parsing, provider
   response decoding and index persistence.
3. Extract `OpenClickyComputerUse`, starting with models and local runtime; keep
   AI point detection as an adapter.
4. Extract speech core and remote providers; then decide whether dictation and
   wake-word orchestration belong in the same product.
5. Extract model/profile values and correct the current `OpenClickyCore` naming
   and dependency direction.
6. Extract Codex process/RPC, then agent sessions once host callbacks have been
   introduced.
7. Extract automation scheduling/storage, followed by the control bridge.
8. Publish `OpenClickySDKSession` from a real SPM product that composes these
   capabilities; keep the full OpenClicky panel as an optional UI product.

## Package acceptance criteria

Each extraction should meet all of these before the next one starts:

- The package builds and tests with `swift build`/`swift test` independently.
- A small example host can use it without the OpenClicky app target.
- No package references `CompanionManager`, an OpenClicky window manager or
  `Bundle.main` for required resources.
- Credentials, storage roots, logging and clocks are injected.
- Public API uses package-owned value types and documents actor isolation.
- The app has a thin adapter that preserves existing behaviour.
- The oldest supported macOS version is intentional rather than inherited.
- At least contract, persistence and parsing tests are present.

## Immediate next slice

The safest implementation slice is `OpenClicky3D` plus shared infrastructure:

1. Add an `OpenClicky3D` product with Foundation-only generation types,
   provider protocol, Tripo provider and service.
2. Add `ThreeDStorageConfiguration` and `ThreeDCredentialProviding` inputs.
3. Leave viewer/window and agent-tool registration in the app initially.
4. Add package tests using a fake provider and temporary directory.
5. Replace app files with imports and host adapters only after tests pass.

That slice is small enough to validate package conventions without touching the
currently edited agent, computer-use and settings files in the working tree.
