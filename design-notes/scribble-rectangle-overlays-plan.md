# Scribble and Rectangle Highlight Overlays Plan

Date: 2026-06-01
Scope: design-only plan for adding freehand scribble and rectangle highlight overlays to the OpenClicky agent. No repository source files are changed by this note.

## Goals

Add a focused visual guidance layer that lets OpenClicky draw transient attention cues on top of the desktop:

- Freehand scribbles for circling, underlining, arrows, or quick path-like emphasis.
- Rectangle highlights for bounding UI elements, windows, cards, controls, or screen regions.
- Programmatic create, update, and clear operations available to the app and external Agent Mode bridge.
- Click-through by default so overlays never block the user or automation.
- Multi-display safe, permission-aware, and compatible with existing cursor/caption guidance.

## User-Facing Behavior

- The agent can say or imply visual guidance while drawing on screen, e.g. “I’ve highlighted the button you need.”
- Rectangles appear as polished OpenClicky highlight frames with configurable color, opacity, corner radius, line width, optional glow, and optional short label.
- Scribbles render as smooth freehand strokes with rounded caps and joins, optionally animated as if drawn over 200–700 ms.
- Overlays are temporary by default, fading after a supplied duration, but can be persistent until explicitly cleared for longer walkthroughs.
- Multiple marks can coexist, grouped by a guidance session id so an agent can clear only its own marks.
- The overlay remains click-through unless a future interactive editing mode is explicitly enabled.
- If a target is on another display, the mark appears only on the overlay window for that display.
- If the screen layout changes, marks are either remapped by global coordinates when still valid or cleared if their display no longer exists.

## Proposed API Shape

Introduce a small visual guidance module rather than adding more ad hoc state to `CompanionManager`.

### Swift Surface

```swift
@MainActor
protocol VisualGuidanceOverlayControlling: AnyObject {
    @discardableResult
    func show(_ request: VisualGuidanceRequest) -> VisualGuidanceResult
    func update(id: VisualGuidanceMark.ID, with patch: VisualGuidancePatch) -> VisualGuidanceResult
    func clear(_ scope: VisualGuidanceClearScope)
    func clearExpired(now: Date)
}
```

Primary concrete type:

```swift
@MainActor
final class VisualGuidanceOverlayController: ObservableObject, VisualGuidanceOverlayControlling {
    @Published private(set) var marksByScreen: [NSScreenNumber: [VisualGuidanceMark]]
}
```

`OverlayWindowManager` owns or receives one controller and injects it into each per-screen SwiftUI overlay view. `CompanionManager` exposes convenience methods and bridge handlers but does not become the rendering model.

### Request Types

```swift
struct VisualGuidanceRequest: Equatable, Sendable {
    var groupID: String?
    var marks: [VisualGuidanceMarkDraft]
    var defaultDuration: TimeInterval?
    var animation: VisualGuidanceAnimation
    var zIndex: VisualGuidanceZIndex
}

enum VisualGuidanceMarkDraft: Equatable, Sendable {
    case rectangle(VisualRectangleHighlightDraft)
    case scribble(VisualScribbleDraft)
}
```

### External Bridge Shape

Extend `OpenClickyExternalControlCommand` with backward-compatible commands:

```json
{
  "type": "show_visual_guidance",
  "groupId": "agent-session-id",
  "durationMs": 2500,
  "marks": [
    {
      "kind": "rectangle",
      "rect": { "x": 240, "y": 180, "width": 320, "height": 88, "coordinateSpace": "globalScreenPoints" },
      "style": { "accentHex": "#5B8CFF", "lineWidth": 3, "cornerRadius": 14 },
      "label": "Target button"
    },
    {
      "kind": "scribble",
      "points": [{ "x": 250, "y": 250 }, { "x": 300, "y": 230 }],
      "coordinateSpace": "globalScreenPoints",
      "style": { "accentHex": "#FFB020", "lineWidth": 5 }
    }
  ]
}
```

Also add:

- `update_visual_guidance` for replacing points/rect/style by id.
- `clear_visual_guidance` for clearing all, by id, by group id, expired marks, or marks on a display.
- Keep existing `show_cursor`, `show_cursors`, `show_caption`, and `clear` intact.

## Data Model

### Core Mark

```swift
struct VisualGuidanceMark: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case rectangle(VisualRectangleHighlight)
        case scribble(VisualScribble)
    }

    var id: UUID
    var groupID: String?
    var kind: Kind
    var style: VisualGuidanceStyle
    var label: String?
    var createdAt: Date
    var expiresAt: Date?
    var animation: VisualGuidanceAnimation
    var displayID: NSScreenNumber?
    var zIndex: VisualGuidanceZIndex
}
```

### Rectangles

```swift
struct VisualRectangleHighlight: Equatable, Sendable {
    var rect: CGRect
    var coordinateSpace: VisualCoordinateSpace
    var cornerRadius: CGFloat
    var inset: CGFloat
}
```

Rectangle conventions:

- Store geometry in global AppKit screen points by default.
- Normalize negative width/height on ingest.
- Clamp drawing rect to the owning screen’s frame plus a small overscan allowance for glow.
- Convert to per-window SwiftUI coordinates at render time.

### Freehand Paths

```swift
struct VisualScribble: Equatable, Sendable {
    var points: [CGPoint]
    var coordinateSpace: VisualCoordinateSpace
    var smoothing: VisualPathSmoothing
    var closePath: Bool
}

enum VisualPathSmoothing: String, Equatable, Sendable {
    case none
    case quadraticMidpoint
    case catmullRom
}
```

Scribble conventions:

- Minimum valid path: 2 points; single-point inputs render as a dot only if explicitly requested later.
- Densely sampled paths are simplified before rendering using a small screen-point tolerance.
- Preserve original points for updates/debugging, but render from simplified points.
- Use rounded caps and joins.

### Style

```swift
struct VisualGuidanceStyle: Equatable, Sendable {
    var accentHex: String
    var fillOpacity: Double
    var strokeOpacity: Double
    var lineWidth: CGFloat
    var glowRadius: CGFloat
    var glowOpacity: Double
    var dashPattern: [CGFloat]
}
```

Defaults should reuse OpenClicky’s current cursor accent direction: saturated blue/purple for primary guidance, amber for secondary warning guidance, and high-contrast white label cards.

## Rendering Approach

### Window and Layering

Use the existing per-screen `OverlayWindow` infrastructure:

- `OverlayWindow` already covers each screen, uses `.screenSaver` level, joins all spaces, is transparent, and ignores mouse events.
- Add a `VisualGuidanceLayerView` inside the existing `BlueCursorView` hierarchy or as a sibling in the `NSHostingView` root.
- Render marks before cursor avatars/captions when marks are contextual background cues, but above dimmed screenshots or response cards if those are present. A practical default is: background media, visual marks, cursor/dock/captions, response cards.
- Keep `ignoresMouseEvents = true` on the window for the initial feature.

### Coordinate Conversion

Each per-screen view receives `screenFrame` and renders marks whose global geometry intersects that frame.

Conversion from global AppKit coordinates to SwiftUI local coordinates:

- Local x: `globalPoint.x - screenFrame.minX`
- Local y: `screenFrame.maxY - globalPoint.y`

This mirrors the current cursor overlay conversion pattern and avoids storing display-specific local points in the model.

### SwiftUI Rendering

Rectangles:

- Use `RoundedRectangle(cornerRadius:)` with stroke and translucent fill.
- Add optional glow via `shadow(color:radius:)` or a duplicate blurred stroke.
- Label attaches to top-left or outside-top edge, clamped inside the screen.

Scribbles:

- Convert simplified points to a `Path`.
- For smoothing, use midpoint quadratic curves first; defer Catmull-Rom unless the path quality needs it.
- Animate reveal with `trim(from: 0, to: progress)` for draw-on behavior.

### Hit Testing

No hit-testing is needed for v1 because marks are non-interactive and should not intercept user input or automation.

Reserve an internal `isInteractive` flag for a future annotation editing mode, but do not expose it externally yet. If interactive editing is added later, use a separate lower-risk overlay window or temporarily disable click-through only for explicit edit sessions.

## Event and Input Integration

### Agent/Internal Calls

Add `CompanionManager` convenience methods:

```swift
func showVisualGuidance(_ request: VisualGuidanceRequest) -> VisualGuidanceResult
func updateVisualGuidance(id: UUID, patch: VisualGuidancePatch) -> VisualGuidanceResult
func clearVisualGuidance(_ scope: VisualGuidanceClearScope)
```

Use these from:

- Agent Mode progress events when a tool knows target bounds.
- Permission walkthroughs where rectangle highlights are clearer than cursor pointing.
- Screen-tour and visual-explainer skills that need temporary on-screen emphasis.

### External Control Bridge

Add JSON commands to the external bridge so background agents can draw marks without reaching into Swift internals.

Validation should happen at the bridge boundary:

- Reject malformed color strings or fall back to defaults.
- Reject non-finite numbers.
- Clamp duration to a safe range, e.g. 0.25–30 seconds unless persistent is explicitly requested.
- Cap per-request marks and points.

### Existing Cursor Guidance

Existing `showCursor`, `showCursors`, and `showCaption` remain for pointer/avatar behavior. New rectangle/scribble guidance should be complementary, not a replacement.

Common use pattern:

1. Rectangle highlight target region.
2. Optional cursor flight to the same region.
3. Caption explains the next action.
4. Clear the rectangle when the action completes or times out.

## Lifecycle

### Create

- Normalize request data.
- Assign ids.
- Resolve display ownership from geometry intersection or point majority.
- Insert marks into the controller on the main actor.
- Ensure overlay windows are showing if visual guidance is requested while the overlay is hidden.
- Start expiry timer if any mark has `expiresAt`.

### Update

- Patch known mark by id.
- Re-resolve display if geometry changes.
- Preserve `createdAt` unless explicitly replacing the mark.
- Restart draw-on animation only when geometry changes substantially or caller asks for replay.

### Clear

Scopes:

```swift
enum VisualGuidanceClearScope: Equatable, Sendable {
    case all
    case id(UUID)
    case groupID(String)
    case display(NSScreenNumber)
    case expired
}
```

Clearing should fade marks out over a short duration unless called during app shutdown or overlay teardown.

### Display Changes

On `NSApplication.didChangeScreenParametersNotification`:

- Existing `OverlayWindowManager` refreshes overlay windows.
- Controller re-buckets marks by current screens.
- Marks with no intersecting display are cleared unless persistent and still within any global screen union.

## Performance Considerations

- Cap one request to roughly 32 marks and 2,000 total scribble points by default.
- Simplify scribble points before publishing to SwiftUI to reduce path work.
- Coalesce rapid updates to one main-thread publish per frame when streaming a scribble.
- Avoid recreating overlay windows for mark changes; update only controller state.
- Keep animations lightweight: opacity, trim, and stroke/fill changes only.
- Prefer value-type marks and stable ids so SwiftUI diffs predictably.
- Skip rendering marks outside the screen’s frame.
- Clear expired marks on a lightweight timer only while marks exist.

## Failure and Permission Handling

- Drawing overlays does not require Screen Recording; it relies on standard app windows. The existing overlay should still appear if the app can create its menu-bar/helper windows.
- Accessibility permission is not required for drawing, but may be needed to discover target element bounds or automate clicks. If unavailable, callers can still draw from supplied coordinates.
- Screen Recording permission is only needed when the agent needs screenshots or screen-content analysis to calculate target geometry.
- If overlay windows cannot be created, return a structured error and continue the agent task without visual guidance.
- If a request references off-screen or invalid geometry, return partial success with rejected mark ids/reasons.
- If the app is hidden, inactive, or the user changes Spaces, the overlay should retain `.canJoinAllSpaces` behavior and remain non-focus-stealing.
- If reduced motion is enabled, disable draw-on flight effects and use short fades.

## Minimal Test Strategy

Use lightweight checks only; do not run `xcodebuild` from terminal.

### Unit-Level Tests or Parse Checks

- `swiftc -parse` for new model/controller files once implemented.
- Model normalization tests for rectangles: negative dimensions, off-screen clamping, invalid numbers.
- Coordinate conversion tests for multiple screen origins and top-left/bottom-left transforms.
- Scribble simplification tests for point caps, duplicate points, and smoothing path generation.
- Clear-scope tests for all/id/group/display/expired behavior.

### Manual Verification in Xcode/App

- Show a rectangle around a known button and verify alignment on primary display.
- Show a scribble across a window and verify it is smooth and click-through.
- Test two displays with marks on each display.
- Test `showCursor` plus rectangle together to confirm layering.
- Test clear by group id after an agent session completes.
- Test without Accessibility and without Screen Recording to confirm graceful degradation.

## Migration Path for Existing Visual Guidance Calls

1. Keep all current calls unchanged: `showCursor`, `showCursors`, `showCaption`, `click`, and `clear`.
2. Add `show_visual_guidance` and `clear_visual_guidance` as new bridge commands.
3. Add a compatibility helper that can translate simple cursor/caption targets into rectangle guidance when a target bounding rect is available:
   - Existing point-only calls remain cursor flights.
   - New rect-aware calls use rectangle plus optional cursor.
4. Update internal permission walkthroughs first because they have stable target rectangles and clear acceptance criteria.
5. Update bundled Agent Mode instructions to prefer rectangle highlights for bounded UI regions and scribbles for freeform visual explanation.
6. After adoption, consider a single higher-level `guide` command that can combine cursor, caption, rectangle, and scribble in one request while preserving the lower-level commands.

## Implementation Tasks and Acceptance Criteria

### 1. Add Visual Guidance Models

Task:

- Add model types for marks, requests, styles, coordinate spaces, animations, patches, clear scopes, and results.

Acceptance criteria:

- Types are `Equatable` where practical and safe to use from main-actor UI code.
- Invalid geometry is representable as validation failure, not a crash.
- `swiftc -parse` passes for the new model file and direct dependencies.

### 2. Add Overlay Controller

Task:

- Add `VisualGuidanceOverlayController` with create, update, clear, expiry, and display bucketing.

Acceptance criteria:

- Marks can be created, updated, and cleared by id and group id.
- Expired marks are removed without timers running when no marks exist.
- Display changes do not leave stale marks attached to removed screens.

### 3. Render Marks in OverlayWindow

Task:

- Inject the controller into the existing per-screen overlay root and add `VisualGuidanceLayerView`.

Acceptance criteria:

- Rectangles and scribbles render in the correct screen position.
- Overlay remains click-through and does not become key/main.
- Existing cursor avatar, captions, dock, and response cards continue to render above or alongside marks as designed.

### 4. Add External Bridge Commands

Task:

- Extend bridge command decoding and handling for show/update/clear visual guidance.

Acceptance criteria:

- A JSON request can draw a rectangle and scribble with a returned mark id list.
- Invalid requests return structured errors or partial-success details.
- Existing bridge commands remain backward-compatible.

### 5. Integrate First Internal Call Sites

Task:

- Use rectangle highlights in one permission walkthrough or visual guidance path where target bounds are already known.

Acceptance criteria:

- The walkthrough visibly highlights the correct region.
- Clearing happens when the walkthrough ends, times out, or the overlay hides.
- No new permissions are required to display the overlay.

### 6. Document Agent Usage

Task:

- Update bundled Agent Mode instructions after implementation to explain when to use cursor, rectangle, scribble, and clear operations.

Acceptance criteria:

- Agents prefer rectangles for bounded targets and scribbles for freehand explanation.
- Instructions include duration and clearing guidance.
- Existing cursor guidance examples still work.

## Recommended First Slice

Implement the feature in this order:

1. Models and controller.
2. Rectangle rendering only.
3. Bridge show/clear commands.
4. Internal permission walkthrough call site.
5. Scribble rendering and smoothing.
6. Update/replay support and documentation.

This keeps the first user-visible milestone small: reliable click-through rectangle highlights with bridge control, before tackling freehand path quality and streaming updates.
