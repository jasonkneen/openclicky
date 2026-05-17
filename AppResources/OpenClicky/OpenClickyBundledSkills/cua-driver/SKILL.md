---
name: cua-driver
description: Drive native macOS apps and browser UI through OpenClicky's local computer-use MCP server, backed by Cua. Snapshot AX state, act by element_index, keep work backgrounded, prefer the user's default browser, and verify via re-snapshot. Use when the user asks you to operate, drive, automate, or perform a GUI task in a real macOS application on the host.
---

# cua-driver

Orchestrates macOS app automation through Cua. In OpenClicky's managed
runtime, this skill is the instruction surface, but the callable tool
server is named `computer-use`. Call the local MCP tools by name
(`launch_app`, `get_window_state`, `click`, `set_value`, etc.) instead
of shelling out to `cua-driver`.

Whenever a user asks to drive a native macOS app or browser UI, follow
the loop in this skill rather than calling tools ad-hoc. The
snapshot-before-action invariant is not optional and silently breaks if
you skip it.

## OpenClicky managed runtime rules

OpenClicky ships Cua as a local `computer-use` MCP server backed by
`OpenClickyComputerUseRuntime`. That helper is spawned by Codex inside
OpenClicky.app, so macOS attributes Accessibility and Screen Recording use
to OpenClicky itself. In this product runtime:

- Use the `computer-use` MCP tools directly. Do not run the
  `cua-driver` CLI, `open`, AppleScript, `cliclick`, browser CLIs, or
  other GUI automation shims to operate apps.
- For external account-backed apps, prefer a connected structured MCP or
  Composio integration when one is exposed and suitable. Do not silently
  use Computer Use as a substitute for a missing/expired connector on
  private account data, and do not offer to connect that integration
  yourself. Tell the user to open OpenClicky Settings -> Integrations and
  connect/reconnect the named app, offer voice/in-app guidance through
  setup, and do not use Computer Use to operate OpenClicky's own
  Settings/Integrations setup flow. Use visible UI only for the original
  third-party app task when the user asked for it, approved it, or the app
  has no shipped connector route.
- Screenshots and focused-window context do not choose the Computer Use
  route by themselves. If an integration-capable app such as LinkedIn,
  Gmail, Slack, Notion, Linear, GitHub, Calendar, Drive, Docs, or Sheets is
  visible, still prefer the structured MCP/Composio route first unless the
  user explicitly asks to click, type, or use that visible page/window.
- Keep work backgrounded by default. The user should be able to keep
  typing in their current app while you operate another app or browser
  window.
- For a new browser task, resolve the user's default HTTPS browser and
  open the target URL in a new background window with
  `launch_app({bundle_id: <default_browser_bundle_id>, urls: [...]})`.
  This preserves the user's current tab/window and their normal logged-in
  browser profile.
- If the user explicitly asks you to work in "this tab", "this window",
  "the page I have open", or the screenshot clearly shows the target
  browser context they want operated, use that existing window/tab after
  a fresh snapshot instead of opening a new one.
- Do not pass `--user-data-dir` or other isolated-profile flags; they
  log the agent out of the accounts the user expects to use.
- Prefer AX and app-scoped actions: `click({pid, window_id,
  element_index})`, `right_click({pid, window_id, element_index})`,
  `set_value`, `type_text`, `press_key`, `hotkey`, `scroll`, `page`,
  and `get_window_state`.
- OpenClicky's default runtime does not expose `move_cursor`, `drag`, or
  `double_click` (not exposed in this build); it also blocks coordinate-only `click` / `right_click`, recording,
  replay, or zoom. If a target has no AX or page path, stop and say that
  completing it would require moving the user's real pointer or using
  pixel mode, then ask for explicit permission instead of pretending.
- Stop before purchases, sends, deletes, payments, account changes,
  submitting forms, or other irreversible actions unless the user
  explicitly approved that exact step.

## The no-foreground contract — read this first

**The user's frontmost app MUST NOT change.** This is the whole
reason OpenClicky ships Computer Use. Users pay for the right to keep typing in
their editor while an agent drives another app in the background.
Violate this rule and every other nice property the driver gives
you (no cursor warp, no Space switch, no window raise) stops
mattering — you just shipped the Accessibility Inspector with extra
steps.

Before running any shell command, ask: **"does this raise,
activate, foreground, or make-key any app?"** If yes, don't run it.
Every one of the commands below activates the target on macOS and
is therefore forbidden unless the user **explicitly** asked for
frontmost state:

- **Every form of the `open` CLI — `open -a <App>`, `open -b
  <bundle-id>`, `open <file>`, `open <path-to-App.app>`, `open
  <url>` — always activates.** macOS routes all forms through
  LaunchServices, which unhides and foregrounds the target
  regardless of whether you passed an app name, a bundle id, a
  document, a URL, or the bundle path itself. The activation
  happens even when the only intent was "start the process."
  **Never use `open` for any app launch.** This includes launching
  a just-built .app from a local build dir (e.g. `open
  build/Build/Products/Debug/MyApp.app`) — resolve the
  `CFBundleIdentifier` from `Info.plist` and use `launch_app`
  with that id. See "The narrow carve-out" below for why
  `launch_app` is safe even when the app internally calls
  `NSApp.activate`.
- `osascript -e 'tell application "X" to activate'` —
  activates by design. Same for `... to open <file>`,
  `... to launch`, and anything with `activate` in the tell block.
- `osascript -e 'tell application "System Events" to ... frontmost'`
  in a mutating form (setting `frontmost` rather than reading it).
- AppleScript files that invoke `activate`, `launch`, or `open`
  against the target app.
- `cliclick` (moves the user's real cursor to the target coords
  before clicking — a focus-steal-equivalent even if the app's
  window state is unchanged).
- `CGEventPost` with `cghidEventTap` targeting a coordinate over
  a different app's window (warps the cursor, possibly activates
  on hit).
- `AppleScriptTask`, `NSAppleScript`, `Process` wrapping `osascript`
  that contains any of the above.
- `NSRunningApplication.activate(options:)` called from your own
  helper binary — same class.
- Dock clicks and any `open` invocation (see the first bullet —
  every form of `open` goes through LaunchServices which
  activates, full stop).
- **Keyboard shortcuts that semantically mean "focus here" —
  most notably Chrome / Safari / Arc's `⌘L` (focus omnibox) and
  Finder's `⌘⇧G` (Go to Folder).** These aren't pure key events —
  the receiving app interprets "user wants to type here" as
  activation intent and raises its window to be key. Even when
  delivered to a backgrounded pid via `hotkey`, the downstream app
  pulls focus. **For omnibox navigation specifically**, the correct
  path is to resolve the user's default browser bundle id and call
  `launch_app({bundle_id: <default_browser_bundle_id>, urls:
  ["https://..."]})` — no omnibox dance, no `⌘L`, no focus-steal. Do
  NOT try `set_value` on the omnibox for navigation: browser commit
  logic often requires a "user-typed" signal that neither an AX value
  write nor `CGEvent.postToPid` keystrokes supply from a backgrounded
  pid. The URL may land in the field but Return can fire as a no-op.
  See `WEB_APPS.md` → "Navigate to a URL" for the full
  default-browser pattern. The general principle: a shortcut that says
  "put my cursor inside this app" is a focus-steal; a shortcut that
  says "do this thing" (copy, save, quit) is fine.
- **Tab-switching shortcuts in browsers (`⌘1..⌘9`, `⌘]`, `⌘[`,
  `⌘⇧[`, `⌘⇧]`) are visibly disruptive even when delivered to a
  backgrounded pid.** The app's key handler processes the shortcut,
  the window re-renders the new tab's content, the user sees their
  tabs flipping. There is no AX-only workaround: page content (HTML,
  form state, `AXWebArea`) populates only for the focused tab;
  inspecting a background tab requires activating it, which is the
  visible flip. Observed with Dia; the same mechanic applies to every
  Chromium-family browser (Chrome, Arc, Brave, Edge).

  **Prefer the windows-over-tabs pattern**: for each URL you need to
  drive backgrounded, resolve the user's default browser and use
  `launch_app({bundle_id: <default_browser_bundle_id>, urls: [url]})`
  so browsers open each URL in a new **window** where supported. Each
  window has its own `window_id`, its own AX tree, and can be
  inspected / interacted with via `element_index` without activating or
  switching anything. Tabs are a UX grouping for humans; cua-driver
  workflows should default to windows. See `WEB_APPS.md` → "Tabs vs
  windows" for the full pattern.

  Tab-title enumeration (read-only) IS safe — walk a window's toolbar
  AX tree for `AXTab` / `AXRadioButton` children and read their
  `AXTitle`s. Tab switching (activating one) is not.

If exact frontmost-app identity matters and the local `computer-use`
tools cannot answer it, stop and explain the limitation. Do not shell
out to `osascript` as a side channel.

**Corollary — the AXMenuBar rule.** `AXMenuBarItem` + AXPick
dispatches at the AX layer regardless of which app is frontmost,
but macOS's on-screen menu bar always belongs to the frontmost
app. If you drive a *backgrounded* app's menu bar, the AX call
succeeds but the viewer sees the dispatch rendered over the
*frontmost* app's menu bar — confusing in any observed session and
routinely a silent no-op too, because action menu items go
`DISABLED` when their owning app isn't the key window. **So: only
use menu-bar navigation when the target is already frontmost.** For
backgrounded targets, read state via in-window AX (window title,
toolbar `AXStaticText`) and dispatch via in-window `element_index`
actions. Pixel clicks are blocked in OpenClicky's default runtime. Full
rationale in "Navigating native menu bars" below.

**"Open \<app\>" in user speech means launch, not activate.**
`launch_app` is the one correct path for process
startup — it's idempotent (no-op on a running app), returns the
pid, and has an internal `FocusRestoreGuard` that catches
`NSApp.activate(ignoringOtherApps:)` calls the target makes during
`application(_:open:)` and clobbers the frontmost back to what it
was before the launch. That guard is why `launch_app` with `urls`
(e.g. `{"bundle_id": "com.colliderli.iina", "urls": ["~/video.mp4"]}`)
is safe even for apps that normally foreground on media-load
(Chrome, Electron, media players).

## Defaults — always prefer the local MCP tools over shell shims

Every reference to `click(...)`, `get_window_state(...)`, etc. in this
skill means call the same-named tool on OpenClicky's local `computer-use`
MCP server. The standalone `cua-driver` CLI examples in upstream docs
are for local development only; they are not the product runtime path.

Intent → tool mapping. If you find yourself reaching for the right
column, something has gone wrong — re-read "The no-foreground
contract" above:

| Intent | Use | Don't use |
|---|---|---|
| Open / launch an app | `launch_app({bundle_id})` or `launch_app({bundle_id, urls:[...]})` | `open -a`, `osascript 'tell app … to launch/activate/open'` |
| Find a pid | `list_apps` or `launch_app`'s return | `pgrep`, `ps`, `osascript frontmost` |
| Enumerate an app's windows | `list_windows({pid})` — or read the `windows` array `launch_app` already returns | `osascript 'every window of app …'` |
| Click / type / scroll / keys | `click`, `type_text`, `scroll`, `press_key`, `hotkey` | `osascript`, `cliclick`, raw `CGEvent`, `open <url>` |
| Drag / drag-and-drop / marquee select | Not exposed in OpenClicky's default runtime; stop and explain that this build lacks a safe drag/pixel mode | `cliclick dd:`, `osascript drag` |
| Screenshot | `screenshot` or the PNG in `get_window_state` | `screencapture` |
| Quit an app | ask the user first, then `hotkey({pid, keys:["cmd","q"]})` | `kill`, `killall`, `pkill` |
| Hand a file/URL to an app | `launch_app({bundle_id, urls:[<path>]})` | `open -a <App> <path>`, `open <url>` |

### The narrow frontmost carve-out

OpenClicky's default runtime has no activation tool and does not allow
`osascript` activation. If the user explicitly asks for frontmost state
("bring Chrome to the front", "make it frontmost", "I want to see X"),
say that this build can keep working in the background but cannot
foreground the app through Computer Use. Reaching for activation because
a tool call returned something confusing is wrong — that's the classic
foot-in-the-door failure mode and it steals focus every time.

When a Computer Use call surprises you, diagnose the local MCP state first:

- **Tiny screenshot / empty `tree_markdown`?** Check
  `get_config` → `capture_mode`. Default `"som"` returns
  both the AX tree and screenshot. `"vision"` omits the AX tree
  (PNG only), `"ax"` omits the PNG. If a snapshot lacks a tree,
  `capture_mode` is almost certainly `"vision"` — either reason
  purely from the PNG or flip to `"som"` / `"ax"` via `set_config`.
- **`has_screenshot: false`?** The window capture failed (transient
  race against a close, or the window has no backing store yet).
  Re-snapshot; if persistent, pick a different `window_id` via
  `list_windows`.
- **`Invalid element_index` / `No cached AX state`?** You either
  skipped `get_window_state` this turn or passed a different
  `window_id` than the one the snapshot cached against. The cache
  is keyed on `(pid, window_id)` — indices don't carry across
  windows of the same app. Re-snapshot with the same window_id
  you're about to click in.
- **Sparse Chromium AX tree?** Retry `get_window_state` once — the
  tree populates on second call.

Only after those are ruled out, and only if the user's action
genuinely needs frontmost state, stop and explain the foreground
requirement. OpenClicky's default runtime does not expose an activation
tool.

### Self-check pattern

Before every Computer Use tool call that touches any macOS app
(launching, opening, clicking, typing, scripting, screenshotting), run
the self-check:

1. **Does this command foreground the target?** If yes — stop and
   translate to the Computer Use equivalent from the mapping table.
2. **Does this command move the user's real cursor?** (`cliclick`,
   any `CGEventPost` at `cghidEventTap` over another app's window).
   If yes — stop; use an AX element action, keyboard shortcut, or
   `page` action. OpenClicky's default runtime blocks coordinate clicks.
3. **Does this command bypass Computer Use entirely?** (`osascript`
   mutating GUI state, AppleScript files, external helpers.) If
   yes — stop; find the local MCP tool that does the intent.

If all three are "no," the command is safe. If you can't answer,
default to stop and ask rather than proceed. A single `open -a`
run by accident kills the demo, the trust, and the user's in-flight
editor state.

## Prerequisites — check before starting

1. Confirm the `computer-use` MCP server is available in the current
   Codex session. OpenClicky starts it automatically from the bundled
   `OpenClickyComputerUseRuntime` helper.
2. Call `check_permissions({"prompt": false})`. If Accessibility or
   Screen Recording is missing, stop and ask the user to grant those
   permissions to OpenClicky.app in System Settings.
3. Do not start daemons, install CuaDriver.app, or invoke standalone
   shell commands. In OpenClicky, the MCP server is already the daemon.

## Using the local MCP tools

Tool names are `snake_case` and are called directly through the
`computer-use` MCP server.

Canonical multi-step workflow:

```
launch_app({"bundle_id":"com.apple.calculator"})
# -> {pid: 844, windows: [{window_id: 10725, ...}]}
get_window_state({"pid":844,"window_id":10725})
click({"pid":844,"window_id":10725,"element_index":14})
get_window_state({"pid":844,"window_id":10725})
```

## Agent cursor overlay

Visual cursor overlay for demos and visible progress. Default:
enabled. Toggle with `set_agent_cursor_enabled({"enabled":true|false})`.
A triangle pointer Bezier-glides to each
click target, ring-ripples on landing, idle-hides after ~1.5s.
Motion knobs: `set_agent_cursor_motion` takes any subset of
`start_handle`, `end_handle`, `arc_size`, `arc_flow`, `spring` —
tuneable at runtime, persisted to config.

OpenClicky's MCP helper bootstraps the AppKit runloop required by the
overlay.

## The core invariant — snapshot before AND after every action

**Every action MUST be bracketed by `get_window_state(pid, window_id)`**:

- **Before** — the pre-action snapshot resolves the `element_index`
  you're about to use. Indices from previous turns are stale; the
  server replaces the element index map on every snapshot, keyed
  on `(pid, window_id)`. Indices from turn N don't resolve in turn
  N+1, and indices from window A don't resolve against window B of
  the same app. Skip this and element-indexed actions fail with
  `No cached AX state`.
- **After** — the post-action snapshot verifies the action actually
  landed. Without it you can't tell a silent no-op from a real
  effect. The AX tree change (new value, new window, disappeared
  menu, disabled button, etc.) is your evidence that the action
  fired. If nothing changed, the action probably failed silently —
  say so, don't assume success.

This applies to pixel clicks too — re-snapshot after to confirm the
click landed on the intended target.

### Why window selection is the caller's job now

`get_app_state` used to pick a window for you via a max-area heuristic
that returned the wrong surface on apps with large off-screen utility
panels. Concrete reproducer: IINA's OpenSubtitles helper (600×432
off-screen) out-area'd the visible 320×240 player window, so
`get_app_state(pid)` screenshot'd the invisible panel and clicks landed
there silently. The new `get_window_state(pid, window_id)` makes the
caller name the window explicitly — the driver validates that the
window belongs to the pid and is on the current Space, then snapshots
exactly what was asked for. Enumerate candidates via `list_windows` or
read the `windows` array `launch_app` already returns.

## Behavior matrix

Two orthogonal axes shape what the agent can do.

**capture_mode → addressing mode**

| `capture_mode` | `get_window_state` returns | Use for actions |
|---|---|---|
| **`som`** (default) | tree + screenshot | `element_index` preferred; pixels are diagnostic only in OpenClicky |
| **`ax`** | tree only (no PNG) | `element_index` only |
| **`vision`** | PNG only (no tree) | read-only visual inspection in OpenClicky — see [SCREENSHOT.md](./SCREENSHOT.md) |

`vision` was renamed from `screenshot` — the old name still decodes
as a deprecated alias, so an on-disk `"capture_mode": "screenshot"`
keeps working. Default is `som` so element_index clicks work the
first time a user calls `get_window_state`; the other modes are
opt-in when the caller specifically doesn't want one half of the
work. Note the tool named `screenshot` is separate (raw PNG, no AX
walk) and unrelated to the capture mode.

When a snapshot looks wrong (tiny screenshot / empty tree), call
`get_config` and inspect `capture_mode` before anything else.

Pure-vision mode has its own caveats — the model's vision
pipeline downsamples dense text aggressively, so pixel grounding
takes multiple correction cycles on text-heavy UIs. Read
[SCREENSHOT.md](./SCREENSHOT.md) before driving anything in that
mode; it documents the iterate/annotate/verify recipe plus the
JPEG-over-PNG finding.

**Window state → what works**

| state | `get_window_state` | `click`/`set_value` (AX) | `press_key` commit (Return/Space/Tab) | pixel click in OpenClicky |
|---|---|---|---|---|
| frontmost | ✅ | ✅ | ✅ | blocked |
| backgrounded / visible | ✅ | ✅ | ✅ | blocked |
| **minimized** (Dock genie) | ✅ | ✅ (no deminiaturize — AX actions fire on the minimized window in place) | ❌ silent no-op / system beep — use `set_value` or click equivalent | ❌ no on-screen bounds |
| hidden (`hides=true` / `NSApp.hide`) | ✅ | ✅ | depends | ❌ |
| on another Space | ⚠️ AX tree often stripped to menu-bar-only on SwiftUI apps (System Settings) — AppKit apps usually fine. Response carries `off_space: true` + `window_space_ids` so you can detect it | ✅ | ✅ | ❌ window not in current-Space list |

**Critical cell — minimized + keyboard commit.** The keystroke
reaches the app but AX focus doesn't propagate to renderer focus on
a minimized window. Workarounds in order of preference:
`set_value` to write the field's entire value directly, or AX-click
a commit-equivalent button (Go, Submit, checkbox). Tell the user
the window needs to un-minimize only as a last resort.

## The canonical loop

```
launch_app(target)
  → pick window_id from the returned `windows` array
    (or call list_windows(pid) separately)
  → get_window_state(pid, window_id)
    → [act]  # every action also takes (pid, window_id)
  → get_window_state(pid, window_id) → verify
```

`launch_app` now returns a `windows` array alongside the pid, so the
common case collapses to two calls (`launch_app` → `get_window_state`)
without a separate `list_windows` hop.

### 1. Resolve target pid — always via `launch_app`

**Always start with `launch_app`**, whether or not the target is already
running. It's idempotent (relaunching returns the existing pid with no
side effects) and gives you the pid in one call — no `list_apps` hop.

- `launch_app({bundle_id: "com.apple.finder"})` — preferred, unambiguous.
- `launch_app({name: "Calculator"})` — when bundle_id isn't known.

`launch_app` is the **background-safe launch primitive** — that's the
entire point of OpenClicky Computer Use: agents drive apps in the background while
the user keeps typing in their real foreground app. In Cua v0.1.6,
LaunchServices is called without activating the target, menu hotkey
delivery restores the previous frontmost app immediately after posting
the key, and the previous frontmost app is restored if the target
self-activates while opening URLs. The target window may become visible
behind the user's current app, but it must not become frontmost.

If the user explicitly wants the window foregrounded (usually for a
demo or recording), they bring it forward themselves — Dock click,
Cmd-Tab, or Spotlight. Do not reach for `open` / `osascript activate`
as a shortcut to make the window visible; those paths break the
backgrounded invariant on every call, not just the call that "needed"
the foreground. Say out loud what the user needs to do ("click the
Todo app in your Dock to bring it forward") and let them do it.

Never shell out to **any** form of `open` (including `open
<path-to-App.app>` for a just-built binary — resolve the bundle id
from `Info.plist` and use `launch_app` with that), `osascript 'tell
app … to launch/open'`, or similar. Those paths activate the target,
bypass the driver's focus-restore guard, and require a Bash
permission prompt the agent loop shouldn't be burning on app launch.
See "Prefer the local MCP tools over shell shims" above for the full
intent → tool mapping.

`list_apps` is for app-level discovery (answering "what's installed /
running / frontmost?") — not part of the core action loop. Skip it in
the loop. For **window-level** questions — "does this app have a
visible window?", "which Space is this window on?", "which of this
pid's windows is the main one?" — call `list_windows` instead; the
app record doesn't carry window state on purpose. In the common
single-window case you can skip `list_windows` entirely and read the
`windows` array that `launch_app` already returned.

### 2. Snapshot and act by element_index

Call `get_window_state({pid, window_id})` with the `window_id` from
`launch_app`'s `windows` array (or a fresh `list_windows({pid})` if
you're interacting with a long-lived process). The default `som`
capture_mode returns **both the AX tree and screenshot**, so the
canonical loop works immediately without any config change. The rest
of this section walks through `som` mode. If you're in `vision` mode
(PNG only, no AX tree), flip back with `set_config({"key":
"capture_mode", "value": "som"})`.

In `som` mode (the default) the response carries:

- `tree_markdown` — every actionable element tagged `[N]`. That `N`
  is the `element_index`. The tree can be very large (Finder is
  ~1600 elements, ~190 KB); when it exceeds token limits, inspect the
  returned file/path or re-snapshot a narrower target window.
- `screenshot_file_path` — absolute path to the saved screenshot when
  `screenshot_out_file` was passed. Absent otherwise.
- `screenshot_width` / `_height` / `_scale_factor` — dimensions of the
  captured image. Present whenever a screenshot was taken.
**Getting the screenshot as a file:**

Pass `screenshot_out_file` when using `get_window_state` and you need a
file path instead of inline image content:

```json
{"pid": N, "window_id": W, "screenshot_out_file": "/tmp/shot.jpg"}
```

The MCP image content block is omitted from the response when this param
is set, so the model receives the AX tree and `screenshot_file_path`.

**Reason over both the tree AND the screenshot — they're
complementary, not redundant.** In `som` mode every
turn's `get_window_state` gives you both halves and you should pull
signal from each:

- The **AX tree** tells you *what's clickable* — roles, labels,
  `element_index` handles, advertised actions, parent-child
  structure. This is the ground truth for dispatching.
- The **screenshot** tells you *which one* — the tree often has
  many buttons with similar or empty labels ("Delete", "OK",
  anonymous UUID-labeled buttons, five `AXStaticText = " "`), and
  visual context disambiguates. Captions, colors, layout relationships
  visible in pixels often don't show up in the AX tree at all
  (especially in Chromium / Electron / web content).

Canonical pattern: look at the screenshot to decide "the blue
Subscribe button on the top-right of the video card", then walk the
tree to find the matching `AXButton` and dispatch by its
`element_index`. Don't try to do it from just the tree — you'll
pick the wrong element when labels repeat. Don't try to do it from
just the screenshot — you lose the reliable AX-action path and the
safe backgrounded-dispatch.

Standalone Cua can support coordinate-based input for canvas, video,
WebGL, or custom-drawn surfaces that are not reachable through AX.
OpenClicky's default runtime blocks coordinate clicks to protect the user's
pointer model. If AX, keyboard, and `page` cannot reach the target,
stop and explain that this build lacks a safe pixel mode instead of
guessing.

The `actions=[...]` list on each element is **advisory**, not
authoritative. cua-driver does not pre-flight check against it —
`click({pid, element_index})` always attempts `AXPress` (or the
action you pass) and surfaces whatever the target returns. Many
apps accept `AXPress` on elements that don't advertise it — Chrome's
omnibox suggestion `AXMenuItem` is a live example. **Try the click
first** — pivot only on the returned AX error code.

Dispatch table (every row assumes a `(pid, window_id)` pair from the
last `get_window_state`; `window_id` is required alongside
`element_index`):

| Intent | Tool | Notes |
|---|---|---|
| List an app's windows | `list_windows({pid})` | returns `window_id`, `title`, `bounds`, `z_index`, `is_on_screen`, `on_current_space`. Already included in `launch_app`'s response — only call this for long-lived pids |
| Snapshot a window | `get_window_state({pid, window_id})` | returns `tree_markdown` + `screenshot_*`; populates the `(pid, window_id)` element_index cache |
| Left click | `click({pid, window_id, element_index})` | default `action: "press"`. Coordinate `x/y` clicks are blocked by OpenClicky's tool policy. |
| Double-click / open | Use `click({pid, window_id, element_index, action: "open"})` when the element advertises an open action | `double_click` is not exposed in OpenClicky's default runtime because it can fall back to pixel stamping. |
| Right click / context menu | `right_click({pid, window_id, element_index})` or `click({pid, window_id, element_index, action: "show_menu"})` | Chromium web-content coerces pixel right-click to left — see `WEB_APPS.md` |
| Type at cursor | `type_text({pid, text, window_id, element_index})` | `AXSelectedText` write; focuses first |
| Set whole field value | `set_value({pid, window_id, element_index, value})` | sliders, steppers, text fields; **use for keyboard-commit workarounds on minimized windows** |
| Scroll | `scroll({pid, direction, amount, by, window_id, element_index})` | synthesizes PageUp/PageDown/arrows via SLEventPostToPid |
| Focus + send key | `press_key({pid, key, window_id, element_index, modifiers})` | element_index sets AXFocused, then posts key |
| Send key to pid | `press_key({pid, key, modifiers})` | no focus change; key goes to pid's current focus |
| Modifier combo | `hotkey({pid, keys})` | e.g. `["cmd","c"]`; posted per-pid, not HID tap |
| Unicode keystrokes | `type_text({pid, text, delay_ms})` | AX write with automatic CGEvent fallback; reaches Chromium/Electron inputs |

**All keyboard/text primitives require `pid`.** There is no
frontmost-routed variant — every key goes to the named target via
`CGEvent.postToPid`, so the driver cannot leak keystrokes into the
user's foreground app.

**Why `element_index` is the primary path:** works on hidden /
occluded / off-Space windows, no focus steal, stable across
rebuilds, labels tell you what you're clicking. If AX cannot reach the
target, use keyboard shortcuts or `page` where possible; otherwise stop
and explain that this build lacks a safe pixel mode.

### Pixel-coordinate clicks

OpenClicky's default `computer-use` MCP server rejects coordinate clicks.
Screenshots are for visual disambiguation only: use them to choose the
right AX element, then dispatch by `element_index`. Do not translate
screenshot pixels into a click in this runtime.

If the target is a canvas, video player, WebGL surface, game viewport,
or custom-drawn control with no useful AX tree, try reachable
alternatives first: keyboard shortcuts, command palettes, toolbar
controls, or the `page` tool. If those cannot perform the task, stop
and tell the user the action needs a future foreground/pixel-mode
capability.

For browser video playback, prefer page or keyboard controls where
available, such as `press_key({pid, key: "k"})` for YouTube-style
players or `press_key({pid, key: "space"})` for a focused generic
player. Verify with a fresh snapshot.

### Canvases, viewports, games (Blender, Unity, GHOST, Qt, wxWidgets)

Apps whose main surface is an OpenGL / Metal / Qt / wxWidgets
viewport expose **no useful AX tree** — the whole surface is one
opaque `AXGroup` or `AXWindow` from AX's perspective. Per-pid event
paths (`SLEventPostToPid`, `CGEvent.postToPid`) are filtered by the
viewport's own event-source check and silently dropped — the event
loop wants "real HID origin".

There is no safe backgrounded path that reaches these apps today in
OpenClicky's default runtime. Stop and say the task requires a future
foreground/pixel mode instead of silently escalating.

## Navigating native menu bars (AXMenuBar)

**Only drive the menu bar when the target app is frontmost.** This
is the single most-misused cua-driver capability. If the target is
backgrounded, don't reach for `AXMenuBarItem` + AXPick — use
in-window `element_index`, toolbar controls, command palettes, or
keyboard shortcuts instead. Two reasons, one
functional and one perceptual:

- **Functional:** menu items that touch document/playback/editor
  state go `DISABLED` when their owning app isn't the key window
  (Preview rotate, IINA speed change, most editor commands). AXPick
  + AXPress will dispatch successfully from the driver's side but
  no-op at the target — you get a silent false-pass.
- **Perceptual (matters for demos, screen recordings, and anything
  the user watches live):** macOS's screen-rendered menu bar
  always belongs to the *frontmost* app. AXPick on a backgrounded
  app's `AXMenuBarItem` dispatches to that app's per-process menu at
  the AX layer, but any visible menu render happens over the
  frontmost app's menu bar — the viewer sees an IINA submenu
  flashing on top of Chrome's menus, which reads as "the agent
  clicked the wrong app." The AX call was correct; the frame the
  user sees is not. For recorded or observed sessions, this is an
  integrity bug even though it's not a correctness bug.

**Good decision rule:** if the target is not already frontmost, do
not use `AXMenuBarItem` at all. For *reading* in-window state,
snapshot the window AX tree — most apps expose the same state via
an in-window `AXStaticText`, title bar, or toolbar. For *dispatching*
actions, use in-window `element_index` targets, toolbar controls,
command palettes, keyboard shortcuts, or `page` where available. If
the only workable path is a coordinate/pixel click, stop and say that
this OpenClicky runtime does not expose pixel mode.

When the target IS frontmost, the menu-bar flow below is fine and
the canonical path for menus.

### The two-snapshot pattern (target frontmost only)

Menu contents are a two-snapshot flow. Closed AXMenu subtrees are
deliberately skipped during snapshot — otherwise every app's File /
Edit / View hierarchy plus every Recent Items macOS has ever seen
would inflate the tree 10-100x. But once a menu is *open*, its
AXMenuItem children do receive `element_index` values so you can
click them normally.

1. Find the `[N] AXMenuBarItem "<Menu Name>"` in the tree.
2. `click({pid, element_index: N, action: "pick"})` — menu bar items
   implement `AXPick` ("open my submenu"), not `AXPress`. Using the
   default action on an AXMenuBarItem is a no-op.
3. Re-snapshot. The expanded menu's items now appear under the bar
   item as `[M] AXMenuItem "<Item Name>"`.
4. Click the target item — most items respond to `AXPress` (default
   action). Submenus nest under the item and are walked the same way.
5. Re-snapshot and verify.

If you ever need to back out without selecting, `press_key({pid, key:
"escape"})` closes the open menu. Leaving a menu expanded between
turns poisons subsequent snapshots for that pid.

### Commands gated on the target being frontmost

Some menu items and global shortcuts (Preview's Tools → Rotate
Right, ⌘R; anything in the View menu that manipulates the current
document; most editor commands) are **disabled unless the target
app is the key / frontmost window**. You'll see it in the AX tree
as `DISABLED` on the menu item even though the user's intent is
obviously valid.

Before activating, confirm you're in this narrow case — the menu
item still reads `DISABLED` after a fresh snapshot AND the action
the user requested genuinely requires frontmost (Preview rotate,
View menu document manipulation, editor commands). If either
check fails, don't activate.

When both checks pass, OpenClicky's default runtime still does not expose
an activation tool and does not allow `osascript` activation. Stop and
tell the user the action requires the target app to be frontmost. If
they bring it frontmost or explicitly approve a future foreground-mode
capability, re-snapshot and continue.

## Web-rendered apps (browsers, Electron, Tauri)

For Chrome / Edge / Brave / Arc / Safari, Electron apps (Slack,
VSCode, Notion, Discord), and Tauri apps — see **`WEB_APPS.md`**.

Covers: sparse AX tree population (retry-once pattern for Chromium),
URL navigation via `launch_app({bundle_id, urls:[...]})`, forbidden
omnibox fallbacks (`⌘L`, URL-like `type_text`, URL-like `set_value`),
the `set_value` workaround for ordinary keyboard commits on
**minimized** windows (Return silently no-ops — symptom is a macOS
system beep), scrolling via synthetic PageUp/Down keystrokes, in-page
clicks, and typing into web inputs.

Chromium web content specifically also coerces `right_click` back to
left — use `element_index` for AX-addressable targets and accept the
limit otherwise.

### Browser JS primitives — `page` tool and `get_window_state(javascript=)`

When the AX tree doesn't expose the data you need (common in
Chromium/Electron — the tree is sparse for web content), use the
`page` tool or the `javascript` param on `get_window_state` to query
the DOM directly via Apple Events. Requires "Allow JavaScript from
Apple Events" to be enabled — see `WEB_APPS.md` for the setup path.

**Three actions on the `page` tool:**

- `page({pid, window_id, action: "get_text"})` — returns
  `document.body.innerText`. Fastest way to read page content, prices,
  article text, or any raw text the AX tree truncates or omits.

- `page({pid, window_id, action: "query_dom", css_selector: "a[href]",
  attributes: ["href"]})` — runs `querySelectorAll` and returns each
  match's tag, text, and requested attributes as a JSON array. Use for
  table rows, link hrefs, data attributes, structured page data.

- `page({pid, window_id, action: "execute_javascript", javascript:
  "..."})` — raw JS. Wrap in an IIFE with try-catch. Don't use this for
  elements already indexed by `get_window_state` — `click` and
  `set_value` are more reliable there.

**Co-located read — `get_window_state` with `javascript`:**

```
get_window_state({pid, window_id, javascript: "document.title"})
```

Runs the JS and appends the result as a `## JavaScript result` section
alongside the AX snapshot — one round-trip instead of two. Use this
when you need both the element tree (for subsequent clicks) and some
page data in the same turn.

**Decision rule — AX vs JS:**

| Need | Use |
|---|---|
| Click / type into an element | `get_window_state` → `click` / `set_value` (AX, works backgrounded) |
| Read text the AX tree drops | `page(get_text)` or `get_window_state(javascript=)` |
| Scrape structured data (tables, hrefs) | `page(query_dom)` |
| Trigger JS events / mutations | `page(execute_javascript)` |

Supported backends:

| App type | How | Context |
|---|---|---|
| Chrome / Brave / Edge | Apple Events `execute javascript` | Full DOM ✅ |
| Safari | Apple Events `do JavaScript` | Full DOM ✅ |
| Electron (VS Code, Cursor…) | SIGUSR1 → V8 inspector → CDP | Main process only: `process`, `Buffer` — no `document`, no `require` in sandboxed apps |
| Electron debug-port page target | Future/runtime-explicit only | Full DOM when exposed |

**Electron sandbox note:** SIGUSR1 connects to the Node.js *main* process.
Sandboxed Electron apps (VS Code, Cursor) strip `require` and Electron
APIs there. Useful for: `process.env`, `process.versions`, `process.cwd()`,
`process.pid`. Do not relaunch user apps with debugging flags in
OpenClicky's default runtime; only use a debug-port page target if the
runtime already exposes it.

Arc returns no values; Firefox has no JS-via-AppleEvents support — see
`WEB_APPS.md` for the full matrix.

### 3. Re-snapshot and verify — mandatory

**Always** call `get_window_state({pid, window_id})` after the action.
This isn't optional verification — it's the second half of the
snapshot invariant.

Check the AX tree diff: a changed value, a new element, a new
window, or the disappearance of the thing you just clicked (menus
collapse after selection, buttons may become disabled, etc.). If
nothing changed, the action likely failed silently — **tell the
user what you attempted and what you observed**, don't paper over
with "done" language. Agents that skip this step report success on
silently-dropped actions — the single most common failure mode.

## Recording trajectories

OpenClicky's default runtime does not expose `set_recording`, `get_recording_state`, or `replay_trajectory`.
If the user asks to record, replay, or export a browser/app trajectory,
stop and explain that this build cannot do it through Computer Use.

See **`RECORDING.md`** only as upstream reference material for a future
runtime that explicitly exposes those tools.

## Common error patterns

| Error text | Meaning | Fix |
|---|---|---|
| `No cached AX state for pid X window_id W` | You either skipped `get_window_state` this turn, or passed a different `window_id` to the click than the one the snapshot cached against | Call `get_window_state({pid: X, window_id: W})` first — the same window_id you intend to click in |
| `Invalid element_index N for pid X window_id W` | Index is stale or out of range | Re-run `get_window_state` with the same window_id, pick a fresh index from the new tree |
| `window_id W belongs to pid P, not …` | Passed a window_id that's owned by a different process | Use `list_windows({pid: X})` to enumerate this pid's own windows |
| `AX action AXPress failed with code …` | Element doesn't support AXPress | Try `show_menu`, `confirm`, `cancel`, or `pick` |
| macOS system-alert beep on `press_key` with no visible change | Target window is minimized; Return / Space / Tab commits don't establish real renderer focus on minimized windows | AX-click a clickable equivalent (Go button, Submit button, checkbox) instead of pressing the key; see "Keyboard commits on minimized windows" under the Browser section |
| `Accessibility permission not granted` | TCC not granted | Stop; tell user to grant in System Settings |
| `Screen Recording permission not granted` | TCC not granted for capture | Affects `screenshot` and `get_window_state` (which always captures). Grant in System Settings — the driver can't operate without it |

## Things to avoid

- **Never** reuse an `element_index` across a re-snapshot of the same pid.
- **Never** translate screenshot pixels into a click in OpenClicky's
  default runtime — the screenshot is for visual disambiguation, not
  coordinates. Use the `element_index`.
- **Prefer AX over pixels.** OpenClicky's default runtime blocks coordinate
  clicks; exhaust AX paths, command palettes, toolbar items, keyboard
  shortcuts, and `page` before reporting a pixel-mode blocker.
- **Never** drive destructive actions (delete files, close unsaved
  documents, send messages, submit forms) without explicit user
  intent for that specific destructive step.
- **Never** launch apps autonomously; confirm with the user first
  unless their original request clearly implies the launch.

## Example end-to-end task

**User:** "Open the Downloads folder in Finder."

1. `launch_app({bundle_id: "com.apple.finder", urls: ["~/Downloads"]})`
   → `{pid: 844, windows: [{window_id: 6123, title: "Downloads", ...}]}`.
   Idempotent launch; plus Finder opens a background-safe window rooted at
   `~/Downloads` via `application(_:open:)` — zero activation, no
   focus steal. The `windows` array lets you skip a `list_windows` hop.
2. `get_window_state({pid: 844, window_id: 6123})` → verify an
   `AXWindow` whose title contains "Downloads" is present with a
   populated AX subtree (sidebar, list view, files).
3. Done.

If the user instead asks to navigate *within* an already-open Finder
window, use the menu-bar flow from the "Navigating native menu bars"
section above (click Go → pick a menu item → re-snapshot → click it).
