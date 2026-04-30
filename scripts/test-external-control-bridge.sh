#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${OPENCLICKY_BRIDGE_URL:-http://127.0.0.1:32123}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${TMPDIR:-/tmp}/openclicky-bridge-tests"
mkdir -p "$TMP_DIR"

pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN %s\n' "$*" >&2; }

json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
obj=json.loads(sys.argv[1])
cur=obj
for part in sys.argv[2].split('.'):
    if part:
        cur=cur[part]
print(cur)
PY
}

contains_tool() {
  python3 - "$1" "$2" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
name=sys.argv[2]
tools=d.get('tools', [])
print('yes' if any(t.get('name') == name or t == name for t in tools) else 'no')
PY
}

printf '== Swift parse checks ==\n'
cd "$ROOT_DIR"
xcrun swiftc -parse \
  leanring-buddy/OpenClickyExternalControlBridge.swift \
  leanring-buddy/CompanionManager.swift \
  leanring-buddy/OverlayWindow.swift \
  leanring-buddy/CodexAgentSession.swift
pass 'swiftc -parse changed bridge/overlay/session files'

# Typecheck the app sources without launching/building the app. The project uses
# bare slash regex literals, so pass the same frontend capability here.
xcrun swiftc -enable-bare-slash-regex -typecheck \
  $(find leanring-buddy -maxdepth 1 -name '*.swift' ! -name 'leanring_buddyApp.swift' | sort)
pass 'swiftc -typecheck app Swift sources (no xcodebuild)'

printf '\n== Bridge health ==\n'
if ! health=$(curl -sS --max-time 2 "$BASE_URL/health"); then
  warn "bridge is not reachable at $BASE_URL; launch/restart OpenClicky to run live bridge tests"
  exit 0
fi
printf '%s\n' "$health"
[[ "$(json_get "$health" ok)" == "True" || "$(json_get "$health" ok)" == "true" ]] || fail 'health ok was not true'
pass 'health endpoint'

printf '\n== MCP/tool descriptors ==\n'
tools=$(curl -sS --max-time 2 "$BASE_URL/mcp/tools")
printf '%s\n' "$tools"
for tool in show_cursor show_cursors show_caption screenshot speak clear; do
  [[ "$(contains_tool "$tools" "$tool")" == "yes" ]] || fail "missing tool descriptor: $tool"
done
pass 'tool descriptors include expected tools'

printf '\n== Basic visual commands ==\n'
caption_resp=$(curl -sS --max-time 2 -X POST "$BASE_URL/caption" \
  -H 'Content-Type: application/json' \
  -d '{"text":"Bridge caption test","durationMs":900}')
printf 'caption: %s\n' "$caption_resp"
[[ "$(json_get "$caption_resp" ok)" == "True" || "$(json_get "$caption_resp" ok)" == "true" ]] || fail '/caption failed'

secondary_resp=$(curl -sS --max-time 2 -X POST "$BASE_URL/cursor" \
  -H 'Content-Type: application/json' \
  -d '{"x":500,"y":500,"caption":"Secondary cursor test","mode":"secondary","durationMs":900,"accentHex":"#34D399"}')
printf 'secondary cursor: %s\n' "$secondary_resp"
[[ "$(json_get "$secondary_resp" ok)" == "True" || "$(json_get "$secondary_resp" ok)" == "true" ]] || fail '/cursor secondary failed'

multi_resp=$(curl -sS --max-time 2 -X POST "$BASE_URL/cursors" \
  -H 'Content-Type: application/json' \
  -d '{"durationMs":900,"cursors":[{"x":520,"y":520,"caption":"A","accentHex":"#60A5FA"},{"x":620,"y":520,"caption":"B","accentHex":"#F59E0B"}]}')
printf 'multi cursor: %s\n' "$multi_resp"
[[ "$(json_get "$multi_resp" ok)" == "True" || "$(json_get "$multi_resp" ok)" == "true" ]] || fail '/cursors failed'
pass 'caption/secondary/multi commands'

printf '\n== Screenshot command ==\n'
screenshot_resp=$(curl -sS --max-time 8 -X POST "$BASE_URL/screenshot" \
  -H 'Content-Type: application/json' \
  -d '{"focused":false}')
printf '%s\n' "$screenshot_resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print({"ok":d.get("ok"),"count":d.get("count"),"first":(d.get("screens") or [{}])[0].get("path")})'
[[ "$(json_get "$screenshot_resp" ok)" == "True" || "$(json_get "$screenshot_resp" ok)" == "true" ]] || fail '/screenshot failed'
count=$(json_get "$screenshot_resp" count)
[[ "$count" -ge 1 ]] || fail '/screenshot returned no screens'
pass 'screenshot endpoint'

printf '\n== SSE stream ==\n'
rm -f "$TMP_DIR/sse.out" "$TMP_DIR/sse.err"
(curl -sS -N --max-time 2 "$BASE_URL/events" > "$TMP_DIR/sse.out" 2>"$TMP_DIR/sse.err" & echo $! > "$TMP_DIR/sse.pid")
sleep 0.2
curl -sS --max-time 2 -X POST "$BASE_URL/caption" -H 'Content-Type: application/json' -d '{"text":"SSE command test","durationMs":800}' >/dev/null
sleep 0.4
kill "$(cat "$TMP_DIR/sse.pid")" 2>/dev/null || true
sse_text=$(cat "$TMP_DIR/sse.out")
printf '%s\n' "$sse_text"
grep -q 'event: ready' <<< "$sse_text" || fail 'SSE ready event missing'
grep -q 'event: command' <<< "$sse_text" || fail 'SSE command event missing'
pass 'SSE ready/command events'

printf '\n== Primary pointer choreography ==\n'
cat > "$TMP_DIR/mouse.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
if args.count > 1, args[1] == "target" {
    let p = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main!
    let f = screen.frame
    let targetX = min(max(f.minX + 260, f.minX + 1), f.maxX - 2)
    let targetY = min(max(f.minY + 260, f.minY + 1), f.maxY - 2)
    print("\(Int(targetX)),\(Int(targetY))")
} else {
    let p = NSEvent.mouseLocation
    print("\(Int(p.x)),\(Int(p.y))")
}
SWIFT
before=$(swift "$TMP_DIR/mouse.swift")
target=$(swift "$TMP_DIR/mouse.swift" target)
tx=${target%,*}; ty=${target#*,}
primary_resp=$(curl -sS --max-time 2 -X POST "$BASE_URL/cursor" \
  -H 'Content-Type: application/json' \
  -d "{\"x\":$tx,\"y\":$ty,\"caption\":\"Primary choreography test\",\"durationMs\":1000}")
sleep 0.35
after=$(swift "$TMP_DIR/mouse.swift")
printf 'before=%s target=%s after=%s response=%s\n' "$before" "$target" "$after" "$primary_resp"
[[ "$(json_get "$primary_resp" ok)" == "True" || "$(json_get "$primary_resp" ok)" == "true" ]] || fail '/cursor primary failed'
python3 - "$before" "$after" <<'PY'
import sys, math
bx,by=map(int, sys.argv[1].split(','))
ax,ay=map(int, sys.argv[2].split(','))
if math.hypot(bx-ax, by-ay) > 6:
    raise SystemExit(f'primary /cursor should not warp the real pointer: before={bx},{by} after={ax},{ay}')
PY
pass 'primary /cursor triggers OpenClicky choreography without warping system pointer'

printf '\n== Clear ==\n'
clear_resp=$(curl -sS --max-time 2 -X POST "$BASE_URL/clear" -H 'Content-Type: application/json' -d '{}')
printf '%s\n' "$clear_resp"
[[ "$(json_get "$clear_resp" ok)" == "True" || "$(json_get "$clear_resp" ok)" == "true" ]] || fail '/clear failed'
pass 'clear endpoint'

printf '\nAll OpenClicky external-control bridge tests passed.\n'
