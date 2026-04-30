---
name: openclicky-screen-tour
description: Create recordable OpenClicky visual tours with multiple simultaneous markers, area-focused overlays, primary cursor choreography, screenshots, captions, and TTS. Use when the user asks to show several things at once, focus markers into one screen region, make a demo easier to record, explain what is on screen visually, or animate a guided screen tour.
version: 1.0.0
argument-hint: "[area or topic to tour visually]"
---

Use OpenClicky's local external-control bridge to create a visual tour directly on the user's screen.

Bridge base URL:

```text
http://127.0.0.1:32123
```

Health check before a tour if unsure:

```bash
curl -s http://127.0.0.1:32123/health
```

## Core behavior

- Use `POST /cursors` for multiple simultaneous temporary markers.
- Use default `POST /cursor` for the primary OpenClicky pointer choreography. This uses OpenClicky's existing smooth point-and-return animation and must not warp the real macOS pointer.
- Use `POST /speak` for a short spoken explanation.
- Use `POST /screenshot` first when you need to see or locate the UI.
- Use `POST /clear` between scenes so old markers do not clutter the recording.

Keep tours short, visual, and recordable. Prefer 3-6 markers, short captions, and one clear area of the screen.

## Coordinate model

Coordinates are macOS/AppKit global screen coordinates with origin at the bottom-left of the global desktop.

For recordable area-focused tours, calculate points from the current screen's `visibleFrame` rather than hardcoding coordinates. This avoids marker clusters on different displays.

## Area-focused multi-marker tour

Use this pattern when the user says something like:

- "focus them all in the top left quarter"
- "I want to record this more easily"
- "show multiple things at the same time"
- "move them around and describe parts of this area"

```bash
python3 - <<'PY'
import json, subprocess, time
base = 'http://127.0.0.1:32123'

def current_screen():
    swift = r'''
import AppKit
let p = NSEvent.mouseLocation
let s = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main!
let f = s.visibleFrame
print("{\"minX\":\(f.minX),\"minY\":\(f.minY),\"width\":\(f.width),\"height\":\(f.height)}")
'''
    path = '/tmp/openclicky-tour-screen.swift'
    open(path, 'w').write(swift)
    return json.loads(subprocess.check_output(['swift', path], text=True))

def post(path, payload):
    subprocess.run([
        'curl', '-sS', '--max-time', '2', '-X', 'POST', base + path,
        '-H', 'Content-Type: application/json',
        '-d', json.dumps(payload)
    ], check=False)

f = current_screen()
minX, minY, w, h = f['minX'], f['minY'], f['width'], f['height']

def pt(rx, ry):
    # rx 0.0...0.25 and ry 0.5...1.0 keeps points in top-left quarter.
    return {'x': round(minX + w * rx), 'y': round(minY + h * ry)}

items = [
    ('Menu bar', '#60A5FA', 0.035, 0.965),
    ('Editor', '#34D399', 0.145, 0.835),
    ('Sidebar', '#F59E0B', 0.045, 0.755),
    ('Logs', '#FF7A9A', 0.195, 0.675),
]

post('/clear', {})
post('/speak', {
    'text': 'Here is a focused visual tour of the top left part of the screen.',
    'interrupt': True,
})
time.sleep(0.4)

# Animate the simultaneous secondary markers by refreshing nearby positions.
for step in range(5):
    wobble = [(-0.004, 0.000), (0.004, 0.006), (0.006, -0.004), (-0.006, 0.005), (0.000, -0.003)][step]
    cursors = []
    for i, (label, color, rx, ry) in enumerate(items):
        cursors.append({
            **pt(rx + wobble[0] * (i + 1), ry + wobble[1] * (i + 1)),
            'caption': label,
            'accentHex': color,
        })
    post('/clear', {})
    post('/cursors', {'durationMs': 900, 'cursors': cursors})
    time.sleep(0.48)

# Leave final markers visible.
final_cursors = [
    {**pt(rx, ry), 'caption': label, 'accentHex': color}
    for label, color, rx, ry in items
]
post('/clear', {})
post('/cursors', {'durationMs': 6500, 'cursors': final_cursors})
time.sleep(0.4)

# Visit each item with the native primary cursor choreography.
for label, color, rx, ry in items:
    post('/cursor', {**pt(rx, ry), 'caption': label, 'durationMs': 1800, 'accentHex': color})
    time.sleep(1.35)

post('/speak', {
    'text': 'Those markers identify the menu bar, editor, sidebar, and logs in this area.',
    'interrupt': False,
})
PY
```

## Screenshot-driven tour

When the user asks you to describe what is on the screen:

1. Capture screenshots.
2. Inspect the screenshot content.
3. Pick a compact region if the user wants to record.
4. Place simultaneous secondary markers for visible items.
5. Use primary `/cursor` to visit the most important items.
6. Speak one short summary.

```bash
curl -s -X POST http://127.0.0.1:32123/screenshot \
  -H 'Content-Type: application/json' \
  -d '{"focused":false}'
```

The screenshot response includes image paths and display frames. Use the display frame to convert visual positions to AppKit coordinates.

## Tour guidelines

- Keep labels to 1-3 words when possible.
- Keep all points inside the requested region.
- Avoid hardcoded low coordinates like `500,500`; they can cluster at the bottom-left on large displays.
- Clear stale overlays before changing scenes.
- Use secondary markers for simultaneous context and the primary cursor for the current focus.
- Prefer a short spoken setup before the markers and a short spoken recap after.
- If the user is recording, use a compact region and avoid covering important text with large captions.

## Minimal commands

Multiple markers:

```bash
curl -s -X POST http://127.0.0.1:32123/cursors \
  -H 'Content-Type: application/json' \
  -d '{"durationMs":4500,"cursors":[{"x":640,"y":980,"caption":"Menu","accentHex":"#60A5FA"},{"x":820,"y":820,"caption":"Editor","accentHex":"#34D399"}]}'
```

Primary choreography:

```bash
curl -s -X POST http://127.0.0.1:32123/cursor \
  -H 'Content-Type: application/json' \
  -d '{"x":820,"y":820,"caption":"Editor","durationMs":2500}'
```

Speak:

```bash
curl -s -X POST http://127.0.0.1:32123/speak \
  -H 'Content-Type: application/json' \
  -d '{"text":"I am marking the important parts of this area.","interrupt":true}'
```

Clear:

```bash
curl -s -X POST http://127.0.0.1:32123/clear
```
