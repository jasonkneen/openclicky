# Driving web-rendered apps

Covers apps whose UI is rendered in a web runtime inside a native
macOS shell:

- **Chromium-family browsers** — Chrome, Edge, Brave, Arc, Vivaldi,
  Opera
- **WebKit** — Safari
- **Electron apps** — Slack, Discord, VS Code, Notion, Figma (desktop),
  and most "native" chat / productivity apps
- **Tauri apps** — use macOS's built-in WKWebView; native menu bar +
  web content, similar to Electron in driving patterns

These apps share two traits that drive the rest of this file:

1. Their AX tree is **sparse** until explicitly enabled, and even
   then can be incomplete.
2. Their web content is routed through a renderer with its own input
   filters — synthetic events need specific delivery paths to land.

## Sparse AX trees — populate on first snapshot

Chromium and Electron apps ship with their web accessibility tree
disabled by default. CuaDriver flips it on automatically the first
time you snapshot such an app — the first `get_window_state` call for
that pid takes up to ~500 ms while Chromium builds the tree,
subsequent calls are fast. Because `launch_app` is the no-activation
browser entry point, the Chromium accessibility nudges (`AXManualAccessibility`,
`AXEnhancedUserInterface`, `AXObserver` registration) all happen
during the `get_window_state` snapshot itself — no explicit activation
is needed to populate the tree.

If the first snapshot still looks sparse (just the window frame and
menubar), **retry once** — Chromium occasionally needs a second call
to finish populating.

If it stays sparse after a retry, the target's AX tree genuinely
doesn't expose the UI you want. Prefer these before reporting a
pixel-mode blocker:

1. Look for native entry points Chromium apps usually keep AX-visible:
   menu bar items (`AXMenuBarItem`) — expand them via the two-snapshot
   flow in SKILL.md's menu section, cmd-k style command palettes
   (often AX-exposed), toolbar buttons in the window chrome.
2. Use keyboard shortcuts delivered straight to the pid —
   `hotkey({pid, keys: ["cmd", "enter"]})`, `hotkey({pid, keys:
   ["cmd", "k"]})`, etc. Posted via `CGEvent.postToPid`, reaches the
   target regardless of AX state, no activation required.
3. For typing into web inputs, use `type_text` — it automatically
   falls back to CGEvent synthesis when the input doesn't implement
   `AXSelectedText`, reaching any focused keyboard receiver including
   Unicode / emoji.
4. If none of the above reaches the target, tell the user this
   interaction isn't reachable from the driver today and ask for
   guidance.

## Navigate to a URL

**Primary path — resolve the user's default browser, then `launch_app`
with `urls`:**

Read-only LaunchServices lookup:

```bash
/usr/bin/python3 -c "import plistlib,subprocess; data=plistlib.loads(subprocess.check_output(['defaults','export','com.apple.LaunchServices/com.apple.launchservices.secure','-'])); print(next(h['LSHandlerRoleAll'] for h in data.get('LSHandlers',[]) if h.get('LSHandlerURLScheme')=='https'))"
```

```
launch_app({bundle_id: "<default_browser_bundle_id>", urls: ["https://cua.ai"]})
```

Opens the URL in a new tab/window on the existing browser pid (or
starts the browser if it isn't running). Background-safe — Cua
v0.1.6's launch path asks LaunchServices not to activate the browser
and restores the previous frontmost app if the browser self-activates
while opening the URL. No omnibox dance, no focus-steal, no `⌘L`
flash. This is the default recommendation — use it even when the
browser is already running. Do not pass isolated profile flags; the
user's normal profile is what gives the agent the logged-in sessions
it needs.

Caveat: the browser window may be visible behind the user's current
foreground app, depending on browser and window state. That is fine;
the promise is "no foreground steal", not "no window ever exists".
If the user needs to watch the page, tell them to Cmd-Tab / click the
Dock icon themselves. Do not activate, unhide, or raise the browser
from the agent loop.

**Last-resort path — omnibox via `⌘L`:** forbidden under the
no-foreground contract (see SKILL.md) because `⌘L` activates
Chrome even when delivered to a backgrounded pid. Keep this
documented only as historical context:

```
# DON'T DO THIS — ⌘L steals focus. Use launch_app above.
hotkey({pid, keys: ["cmd", "l"]})
type_text({pid, text: "https://cua.ai", delay_ms: 30})
get_window_state({pid, window_id})
click({pid, window_id, element_index: <suggestion>})
```

**Why not AX `set_value` + `press_key return` on the omnibox?**
Empirically, browser omnibox commit logic requires a "user-typed"
signal that neither a raw AX value set nor `CGEvent.postToPid`
keystrokes reliably supply from a backgrounded pid. The URL
lands in the omnibox but Return fires as a no-op on the page
body instead of committing navigation. `launch_app({urls})` sidesteps
this entirely by handing the URL to the browser through the
canonical Apple Events / LaunchServices `open` path the app
itself honors.

Minor caveats for the rare case a `⌘L` flow is still needed
(last-resort only, with user buy-in on the focus flash):
- Don't drop `delay_ms` below ~25 for keystroked typing on
  Chromium — below that, autocomplete insertions interleave with
  your characters and you get garbage like `"exuample.comn"`
  instead of `"example.com"`.
- Chrome exposes omnibox suggestions as clickable AXMenuItems in
  a dropdown popup. Clicking the first match via AXPress is
  more reliable than pressing Return (which may not commit).

## Tabs vs windows — prefer windows for backgrounded drive

Browsers (Chrome, Dia, Arc, Brave, Edge, Safari) structure their
surface area as {windows → tabs → page content}. Picking the
right level for cua-driver is critical:

- **Tabs** share a window. Only the focused tab's `AXWebArea` is
  populated; switching tabs to drive a different one is visibly
  disruptive. `hotkey ⌘<N>` posts the real shortcut, the window
  re-renders, the user sees the flip. There is no AX path to
  read a background tab's DOM.

- **Windows** are independent AX trees. Each has its own `window_id`,
  its own `AXWebArea` with the page's content, and can be driven
  backgrounded via `get_window_state({pid, window_id})` + element-
  indexed clicks without activating or raising the window.
`launch_app({bundle_id: <default_browser_bundle_id>, urls: [url]})` opens each URL in a new
window (tested against Chrome; other browsers vary).

**Rule of thumb:** if the user needs to drive content across URLs
in the background, open each URL in its own **window** via
`launch_app({bundle_id: <default_browser_bundle_id>, urls: [...]})`
and address them by `window_id`. Only
reach for tab shortcuts when the user explicitly asked for "do it
in a specific tab" (rare).

**Read-only tab enumeration is fine.** Walk the window's toolbar /
tab-strip in the AX tree for `AXTab` / `AXRadioButton` elements
and read their `AXTitle`s. You can discover which tabs exist and
what URLs/titles they carry without switching to any of them.
Only *activating* a specific tab is visible.

## Keyboard commits on minimized windows

When the target window is **minimized** (genie'd into the Dock):

- **AX reads** (`get_window_state`), element-indexed AX **clicks**, and
  AX **value writes** (`set_value`) all still work — they land on
  the minimized AX tree and don't deminiaturize the window.
- **Keyboard commit events** — Return after typing into a text
  field, Space to toggle a checkbox, Tab to move focus — often
  **don't actually fire the element's handler**. The keystroke
  reaches the app via `SLEventPostToPid` but the app's renderer-side
  input focus isn't established on the intended field (setting
  `AXFocused=true` on a minimized window's descendants doesn't
  propagate to real keyboard focus). Symptom: macOS system-alert
  beep, or silent no-op. Example: `hotkey cmd+L` +
  `type_text URL` + `press_key return` on minimized Chrome —
  the URL lands in the omnibox AX value but Return doesn't commit
  the navigation.
- **Primary workaround — use `set_value` to commit directly**: For
  ordinary page/app text fields,
  `set_value({pid, window_id, element_index, value})` sets the entire
  field value at once, bypassing keyboard commits.
- **URL exception — never use `set_value` on the omnibox for
  navigation**: use
  `launch_app({bundle_id: <default_browser_bundle_id>, urls:
  ["https://..."]})` instead. URL-like `set_value`/`type_text`
  fallbacks are blocked in OpenClicky's runtime because logs showed they
  can foreground the browser or fail silently.
- **Secondary workaround — find a clickable equivalent**: If
  `set_value` doesn't auto-commit a normal form value, find a button
  and AX-click it instead. For a form, click Submit; for a toggle,
  AX-click the checkbox. Clicks route through AXPress, which doesn't
  need renderer focus.
- **Last resort — tell the user the window needs to be un-minimized**:
  Only if neither `set_value` nor clickable equivalents work. Don't
  silently deminiaturize the window — layout-disrupting side-effect
  on many apps.

## Scroll the main page

```
snap = get_window_state({pid, window_id})
# Find the AXWebArea — typically one per tab.
scroll({pid, window_id, direction: "down", amount: 3, by: "page", element_index: <web_area>})
```

Under the hood: `scroll` synthesizes PageUp / PageDown / arrow-key
keystrokes and posts them via the same auth-signed `SLEventPostToPid`
path `press_key` uses. That's why it reaches Chromium even when the
window is backgrounded. Wheel events posted via the same per-pid
SkyLight path are silently dropped by Chromium's renderer (no
Scroll-specific auth subclass exists — probe tests confirmed this),
so the working primitive is keyboard.

Granularity: `by: "page"` → PageDown/PageUp (one viewport height
per unit). `by: "line"` → arrow keys (fine-grained; a few pixels
per unit in web views, one line in text views). Horizontal `page`
falls back to Left/Right arrows since there's no standard
horizontal-page shortcut.

`element_index` is focused (`AXFocused=true`) before the
keystrokes fire — useful for directing the scroll into a specific
element. Without it, keys land wherever the pid's current focus is.

## Jump to page bottom / top

```
press_key({pid, window_id, element_index: <web_area>, key: "end"})
# or "home" / "pagedown" / "pageup"
```

Targets the `AXWebArea` directly (not the omnibox). Routes keys
through SkyLight's `SLEventPostToPid` where available, falling back
to `CGEventPostToPid`. Works for most in-page shortcuts against a
backgrounded window.

## Click something inside a page

```
click({pid, window_id, element_index: <some_AXLink_or_AXButton>})
```

Standard element-indexed click. Chromium exposes `AXLink` /
`AXButton` / `AXTextField` / etc. under the `AXWebArea` — walk the
tree to find your target, snapshot, click.

For a **context menu** on a browser-chrome element (links, buttons,
toolbar items — anything that advertises `AXShowMenu`), use
`right_click({pid, window_id, element_index})`. Pure AX RPC,
identical to `click({pid, window_id, element_index, action: "show_menu"})`.

For a context menu on **web content itself** (right-clicking an image,
a selection, the page background), OpenClicky's default runtime has no
coordinate right-click path. Prefer `element_index` whenever the target
is AX-addressable; otherwise stop and report that the interaction needs
pixel/pointer mode.

## Enable "Allow JavaScript from Apple Events" — browser support matrix

| Browser | `execute javascript` supported | Setting needed | Programmatic path |
|---|---|---|---|
| Chrome | ✅ Full | ✅ Yes | Edit Preferences JSON (see below) |
| Brave | ✅ Full | ✅ Yes | Edit Preferences JSON (same key, different path) |
| Edge | ✅ Full | ✅ Yes | Edit Preferences JSON (same key, different path) |
| Safari | ✅ Full (`do JavaScript`) | ✅ Yes | UI automation only — `defaults write` broken |
| Arc | ⚠️ No return values | No toggle | No reliable path |
| Firefox | ❌ Not supported | N/A | N/A |

### Chrome / Brave / Edge — permissioned `page` action

Required for `page({action: "execute_javascript" | "get_text" |
"query_dom"})` calls that use browser JavaScript. All three are
Chromium-based and share the same preference key and mechanism. Each
browser stores preferences per-profile.

### Why menu clicks don't work

The menu item (`View → Developer → Allow JavaScript from Apple Events`)
is a security-sensitive toggle. Verified experimentally:

- `AXPress` — advertised actions are `[AXCancel, AXPick]`, not
  `AXPress`; Chrome's command dispatch silently discards it.
- `AXPick` on a leaf item — opens submenus correctly but does NOT
  commit a leaf toggle; the item is "selected" but not activated.
- System Events `click theItem` / `click at {x, y}` — returns the
  menu item reference (found it) but Chrome requires a genuine
  trusted user event to flip this flag; synthetic AppleEvent-routed
  clicks are rejected.
- `CGEvent.post(tap: .cghidEventTap)` while the menu is open —
  Chrome's event loop is occupied processing the menu; the event
  either races or Chrome treats it as untrusted for this toggle.

Additionally, when Chrome is **backgrounded**, the Developer submenu
items appear with `AXEnabled = false` (Chrome's `commandDispatch`
marks them DISABLED) — any action dispatched returns `.success` at
the AX layer but is silently discarded. This is the root cause of the
"ghost click" pattern: the driver reports ✅ but nothing changes.

### Correct path — ask, then use the `page` tool

This action quits the browser, patches profile Preferences, and
relaunches. Because that changes browser settings and can briefly
close/reopen windows, ask the user first. Then call:

```
page({
  pid: <browser_pid>,
  window_id: <browser_window_id>,
  action: "enable_javascript_apple_events",
  bundle_id: "<default_browser_bundle_id>",
  user_has_confirmed_enabling: true
})
```

After it completes, re-snapshot the browser window and verify with a
read-only call such as `page({pid, window_id, action: "get_text"})` or
`page({pid, window_id, action: "execute_javascript", javascript:
"(() => document.title)()"})`.

**Which profile?** Chrome writes to whichever profile is active.
If you're unsure, write to all non-system profiles:

```bash
python3 -c "
import json, glob, os
for p in glob.glob(os.path.expanduser(
        '~/Library/Application Support/Google/Chrome/*/Preferences')):
    profile = p.split('/')[-2]
    if 'System' in profile or 'Guest' in profile:
        continue
    try:
        data = json.load(open(p))
        data.setdefault('browser', {})['allow_javascript_apple_events'] = True
        data.setdefault('account_values', {}).setdefault('browser', {})['allow_javascript_apple_events'] = True
        json.dump(data, open(p, 'w'))
        print(f'wrote to {profile}')
    except Exception as e:
        print(f'skipped {profile}: {e}')
"
```

Chrome overwrites its Preferences file on every clean exit, so the
write must happen while Chrome is **not running** — otherwise Chrome
will stomp the change when it quits.

**Sync note (Chrome only):** Chrome syncs `browser.allow_javascript_apple_events`
via Google account (confirmed in `chrome_syncable_prefs_database.cc`).
Writing both `browser` and `account_values.browser` to the local file
causes Chrome to push `true` to the sync server on next launch,
making the change durable. Brave and Edge use their own sync systems
and likely do NOT sync this Mac-only pref — treat as local-only for
those browsers.

For Brave and Edge, pass `com.brave.Browser` or
`com.microsoft.edgemac` as the `bundle_id`. Do not run the standalone
shell/AppleScript preference-editing recipes from upstream Cua docs in
OpenClicky's managed runtime.

### Safari and Arc

Do not use Safari or Arc AppleScript JavaScript bridges in OpenClicky's
managed runtime. They require browser-specific Apple Events state,
foreground assumptions, clipboard side channels, or security prompts
that bypass `computer-use`. If a task genuinely needs in-page script
execution and the shipped MCP tools cannot provide it, stop and report
that this build does not ship a dedicated browser automation runtime.

### Firefox

Firefox has no `execute javascript` capability. Bugzilla #287447
(filed 2004) tracks this and remains unresolved. OpenClicky's current
curated runtime does not ship a Firefox-specific automation bridge; if
AX interaction cannot complete the task, report the missing browser
capability rather than inventing another route.

## Typing into a web input

```
type_text({pid, window_id, element_index: <input_field>, text: "…"})
```

If it silently drops (some web inputs don't implement
`AXSelectedText`), `type_text` automatically falls back to CGEvent
synthesis — pure CGEvent keystrokes delivered to the pid, reaching
any focused keyboard receiver. You can also click the field first
to ensure focus before typing.
