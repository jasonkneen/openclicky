# OpenClicky Package Structure

Current as of 2026-09-01. Supersedes the package inventory in
`PACKAGE_EXTRACTION_AUDIT.md` and `PACKAGE_EXTRACTION_AUDIT_2026-09.md`,
which remain as the point-in-time analyses that produced this layout.

## Naming

Every local package uses the `OC` module prefix. **Module names carry the
prefix; type names do not.** `OCBrowser` still vends
`OpenClickyBrowserWorkspace`, `OCAutomation` still vends
`OpenClickyAutomation`. The app module itself is `OpenClicky` and is
unchanged — the test target's `@testable import OpenClicky` still refers to
the app, not to a package.

## Graph

```text
OCCore ──> OCUI ──┬─> OCMarkdown
                  ├─> OCMemory
                  └─> OCBrowser

OC3DCore ──> OCTripo          (both in Packages/OC3D)

OCFoundation      (standalone)
OCAutomation      (standalone)
OCAudioCore       (standalone)
OCComputerUseCore (standalone)
```

No runtime package depends on `OCUI`, on `CompanionManager`, or on the app
bundle. The graph is acyclic.

## Packages

| Package | Floor | Tests | Contents |
| --- | --- | ---: | --- |
| `OCCore` | macOS 26 | — | Theme values, wiki indexing |
| `OCUI` | macOS 26 | — | Design system, liquid-glass components |
| `OCBrowser` | macOS 26 | — | Browser workspace and browser agent |
| `OCMarkdown` | macOS 26 | — | Markdown viewer |
| `OCMemory` | macOS 26 | — | Memory workspace UI |
| `OCFoundation` | macOS 10.13 | 11 | Atomic Codable JSON file store |
| `OCAutomation` | macOS 10.15 | 27 | Schedule models + 5-field cron evaluator |
| `OCAudioCore` | macOS 10.15 | 18 | PCM16 conversion, WAV builder, WebSocket session base |
| `OCComputerUseCore` | macOS 10.15 | 9 | Computer-use + visual-guidance models, snap geometry |
| `OC3D` | macOS 10.15 | 25 | `OC3DCore` value types + provider protocol; `OCTripo` transport |

Deployment floors are the lowest each package's own APIs require, measured
rather than assumed — `OCFoundation` is pinned at 10.13 only by
`JSONEncoder.OutputFormatting.sortedKeys`, and the four 10.15 floors come
from `Identifiable`, `URLSessionWebSocketTask` and async `URLSession`. The
five macOS 26 floors are real: `OCUI` uses `NSGlassEffectContainerView`
unconditionally.

The five original packages still have no test targets. That is the main
remaining gap in this layout.

## What deliberately stayed in the app

- `CompanionManager` and its extensions — the composition root.
- Provider selection and the money-rule ordering (SDK/app-server first,
  key fallback). Transport packages must never encode that policy.
- Credential reads. `ThreeDGenerationService.readTripoAPIKey`,
  `AppBundleConfiguration`, and the transcription provider factory all
  read `UserDefaults` / environment and stay app-side; packages take
  credentials as parameters.
- Product paths and identity: `OpenClickyJSONFileStore.openClickyDirectory`
  is an app-side extension on the package type, so the string "OpenClicky"
  never enters `OCFoundation`.
- AppKit / Accessibility / ScreenCaptureKit / CGEvent implementations.
  `OCComputerUseCore` holds models and geometry; the AX and CGWindowList
  probes stay in `CircleSelectSnapResolver`, and the two
  `NSRunningApplication` conveniences live in
  `OpenClickyComputerUseModels+AppKit.swift`.
- All UI: notch, HUD, overlay, settings, menu bar.

## Deferred, with reasons

**`OCCodexRuntime` / `OCAgentCore`.** Audited and found not safe to move
as-is. `CodexRuntimeLocator.sourceCodexExecutableURL` calls
`CuaDriverMCPConfiguration.bundledRuntimeExecutableURL`, which lives in
`AppBundleConfiguration` — so moving the locator inverts the dependency
direction and the package would call back into the app. Three tests in
`CodexAgentModeTests` also depend on a `#filePath`-derived source-checkout
chain that changes meaning once the file moves, and the proposed
`extraEnvironment` merge would invert GOG environment precedence. This
needs the injection seams designed first, not a file move.

**`OCTranscription` / `OCTextToSpeech`.** The concrete providers and the
TTS clients. Two obstacles: the provider factory in
`BuddyTranscriptionProvider.swift` reads `UserDefaults` and
`AppBundleConfiguration` to choose a provider, so the protocols cannot
move without dragging product policy across the boundary; and
`ElevenLabsTTSClient.swift` is 1,837 lines containing five distinct things
(the ElevenLabs client, a streaming session, a filler-phrase library, the
shared `OpenClickyTTSClient` protocol, and a Deepgram voice-agent client)
that must be separated first. `OCAudioCore` was extracted as the
foundation this work will sit on.

**`OCWindowKit`.** Per the original audit, extract only after two or more
OpenClicky windows share a stable API.

## Adding a package

Local packages are **not** in the pbxproj `packageReferences` array — that
holds only the four remote dependencies. Each local package is wired in
four places, all of which must be edited together:

1. a `PBXFileReference` folder wrapper, added to the `Packages` `PBXGroup`;
2. an `XCSwiftPackageProductDependency` per product, with `productName`
   only and no `package` key;
3. a `PBXBuildFile` per product in the app target's Frameworks phase;
4. a `packageProductDependencies` entry per product on the app target.

`cursor-buddy/` is a `PBXFileSystemSynchronizedRootGroup`, so a file
removed from that directory silently leaves the app target with no project
edit and no warning. Always `git mv` a file out and add `import <OCModule>`
to every consumer in the same commit.

`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` is set on every
Swift target. A file must import the defining module to see a type's
*members*, even when it never names the type — so files that only touch
`someValue.property` still need the import.

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is also set on every app
target, while SwiftPM targets default to *nonisolated*. Moving a type
across the boundary therefore changes its isolation. The case that fails
hard rather than warning is an app subclass of a package class: the
subclass is MainActor-isolated by default and its overrides no longer
match the nonisolated base, giving

```text
error: main actor-isolated instance method 'x' has different actor
isolation from nonisolated overridden declaration
```

Mark such a subclass `nonisolated` when it genuinely runs off the main
actor. The same applies to an app type conforming to a package protocol.

## Verifying app-side compilation without Xcode

`swiftc -parse` checks syntax only; it resolves no imports and sees no
cross-module access levels or isolation, so it cannot catch a missing
`public`, a `public` class that needed to be `open`, or the isolation
mismatch above. Since app builds happen in Xcode, the way to check those
before handing over is a throwaway SwiftPM package that depends on the
extracted modules, reproduces the app's access patterns, and **compiles
with the app target's flags**:

```swift
swiftSettings: [
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .unsafeFlags(["-default-isolation", "MainActor"]),
]
```

Without those flags the check passes and proves nothing — the isolation
error above only appeared once they were applied. Verify the flags reached
the compiler (`swift build -v`) rather than assuming the manifest edit
took.

## Verification

Per `CLAUDE.md`, do not run `xcodebuild`; build the app in Xcode. Packages
verify standalone:

```sh
for p in Packages/*/; do (cd "$p" && swift build && swift test); done
```

Per-file syntax checks: `xcrun swiftc -parse <files>`.
