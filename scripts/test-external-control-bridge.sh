#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${OPENCLICKY_BRIDGE_URL:-http://127.0.0.1:32123}"
BRIDGE_TOKEN="${OPENCLICKY_BRIDGE_TOKEN:-}"
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

curl_bridge() {
  if [[ -n "$BRIDGE_TOKEN" ]]; then
    curl -sS --max-time "${CURL_MAX_TIME:-2}" -H "Authorization: Bearer $BRIDGE_TOKEN" "$@"
  else
    curl -sS --max-time "${CURL_MAX_TIME:-2}" "$@"
  fi
}

printf '== Swift parse checks ==\n'
cd "$ROOT_DIR"
xcrun swiftc -parse \
  cursor-buddy/OpenClickyExternalControlBridge.swift \
  cursor-buddy/CompanionManager.swift \
  cursor-buddy/OverlayWindow.swift \
  cursor-buddy/CodexAgentSession.swift
pass 'swiftc -parse changed bridge/overlay/session files'

# Keep this script lightweight: raw swiftc cannot resolve the SwiftPM package
# products imported by several app files unless Xcode has built module artifacts.
# The full module graph remains an Xcode verification step; this script should
# still reach the live bridge tests on a clean checkout.
pass 'skipped raw swiftc typecheck of full app module graph'

printf '\n== Bridge health ==\n'
if ! health=$(curl -sS --max-time 2 "$BASE_URL/health"); then
  warn "bridge is not reachable at $BASE_URL; launch/restart OpenClicky to run live bridge tests"
  exit 0
fi
printf '%s\n' "$health"
[[ "$(json_get "$health" ok)" == "True" || "$(json_get "$health" ok)" == "true" ]] || fail 'health ok was not true'
pass 'health endpoint'

if [[ -z "$BRIDGE_TOKEN" ]]; then
  warn "OPENCLICKY_BRIDGE_TOKEN is not set; protected live bridge tests are skipped"
  exit 0
fi

printf '\n== MCP/tool descriptors ==\n'
tools=$(curl_bridge "$BASE_URL/mcp/tools")
printf '%s\n' "$tools"
for tool in show_cursor show_cursors show_caption screenshot openclicky_native_status openclicky_native_type_text openclicky_native_press_key openclicky_workflow speak clear; do
  [[ "$(contains_tool "$tools" "$tool")" == "yes" ]] || fail "missing tool descriptor: $tool"
done
pass 'tool descriptors include expected tools'

printf '\n== UTCP manual and workflow descriptors ==\n'
utcp=$(curl_bridge "$BASE_URL/utcp")
printf '%s\n' "$utcp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print({"manual_version":d.get("manual_version"),"utcp_version":d.get("utcp_version"),"tools":len(d.get("tools", []))})'
for tool in openclicky_native_status openclicky_native_type_text openclicky_native_press_key openclicky_workflow; do
  [[ "$(contains_tool "$utcp" "$tool")" == "yes" ]] || fail "missing UTCP tool descriptor: $tool"
done
workflow_resp=$(curl_bridge -X POST "$BASE_URL/utcp/workflow" \
  -H 'Content-Type: application/json' \
  -d '{"steps":[{"tool":"openclicky_native_status","arguments":{}}],"stopOnError":true}')
printf '%s\n' "$workflow_resp"
[[ "$(json_get "$workflow_resp" ok)" == "True" || "$(json_get "$workflow_resp" ok)" == "true" ]] || fail '/utcp/workflow failed'
pass 'UTCP manual and workflow endpoint'

printf '\n== Basic visual commands ==\n'
cat > "$TMP_DIR/visual-points.swift" <<'SWIFT'
import AppKit
let p = NSEvent.mouseLocation
let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main!
let f = screen.visibleFrame
func emit(_ name: String, _ x: CGFloat, _ y: CGFloat) {
    print("\(name)_x=\(Int(x)); \(name)_y=\(Int(y))")
}
emit("caption", f.minX + f.width * 0.52, f.minY + f.height * 0.62)
emit("secondary", f.minX + f.width * 0.38, f.minY + f.height * 0.50)
emit("multi_a", f.minX + f.width * 0.48, f.minY + f.height * 0.42)
emit("multi_b", f.minX + f.width * 0.62, f.minY + f.height * 0.42)
SWIFT
eval "$(swift "$TMP_DIR/visual-points.swift")"

caption_resp=$(curl_bridge -X POST "$BASE_URL/caption" \
  -H 'Content-Type: application/json' \
  -d "{\"x\":$caption_x,\"y\":$caption_y,\"text\":\"Bridge caption test\",\"durationMs\":650}")
printf 'caption: %s\n' "$caption_resp"
[[ "$(json_get "$caption_resp" ok)" == "True" || "$(json_get "$caption_resp" ok)" == "true" ]] || fail '/caption failed'

secondary_resp=$(curl_bridge -X POST "$BASE_URL/cursor" \
  -H 'Content-Type: application/json' \
  -d "{\"x\":$secondary_x,\"y\":$secondary_y,\"caption\":\"Secondary\",\"mode\":\"secondary\",\"durationMs\":650,\"accentHex\":\"#34D399\"}")
printf 'secondary cursor: %s\n' "$secondary_resp"
[[ "$(json_get "$secondary_resp" ok)" == "True" || "$(json_get "$secondary_resp" ok)" == "true" ]] || fail '/cursor secondary failed'

multi_resp=$(curl_bridge -X POST "$BASE_URL/cursors" \
  -H 'Content-Type: application/json' \
  -d "{\"durationMs\":650,\"cursors\":[{\"x\":$multi_a_x,\"y\":$multi_a_y,\"caption\":\"A\",\"accentHex\":\"#60A5FA\"},{\"x\":$multi_b_x,\"y\":$multi_b_y,\"caption\":\"B\",\"accentHex\":\"#F59E0B\"}]}")
printf 'multi cursor: %s\n' "$multi_resp"
[[ "$(json_get "$multi_resp" ok)" == "True" || "$(json_get "$multi_resp" ok)" == "true" ]] || fail '/cursors failed'
sleep 0.75
curl_bridge -X POST "$BASE_URL/clear" -H 'Content-Type: application/json' -d '{}' >/dev/null
pass 'caption/secondary/multi commands'

printf '\n== Screenshot command ==\n'
CURL_MAX_TIME=8
screenshot_resp=$(curl_bridge -X POST "$BASE_URL/screenshot" \
  -H 'Content-Type: application/json' \
  -d '{"focused":false}')
unset CURL_MAX_TIME
printf '%s\n' "$screenshot_resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print({"ok":d.get("ok"),"count":d.get("count"),"first":(d.get("screens") or [{}])[0].get("path")})'
[[ "$(json_get "$screenshot_resp" ok)" == "True" || "$(json_get "$screenshot_resp" ok)" == "true" ]] || fail '/screenshot failed'
count=$(json_get "$screenshot_resp" count)
[[ "$count" -ge 1 ]] || fail '/screenshot returned no screens'
pass 'screenshot endpoint'

printf '\n== SSE stream ==\n'
rm -f "$TMP_DIR/sse.out" "$TMP_DIR/sse.err"
(curl -sS -N --max-time 2 -H "Authorization: Bearer $BRIDGE_TOKEN" "$BASE_URL/events" > "$TMP_DIR/sse.out" 2>"$TMP_DIR/sse.err" & echo $! > "$TMP_DIR/sse.pid")
sleep 0.2
curl_bridge -X POST "$BASE_URL/caption" -H 'Content-Type: application/json' -d '{"text":"SSE command test","durationMs":800}' >/dev/null
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
primary_resp=$(curl_bridge -X POST "$BASE_URL/cursor" \
  -H 'Content-Type: application/json' \
  -d "{\"x\":$tx,\"y\":$ty,\"caption\":\"Primary choreography test\",\"durationMs\":1000}")
sleep 0.35
after=$(swift "$TMP_DIR/mouse.swift")
printf 'before=%s target=%s after=%s response=%s\n' "$before" "$target" "$after" "$primary_resp"
[[ "$(json_get "$primary_resp" ok)" == "True" || "$(json_get "$primary_resp" ok)" == "true" ]] || fail '/cursor primary failed'
python3 - "$before" "$after" "$target" <<'PY'
import sys, math
bx,by=map(int, sys.argv[1].split(','))
ax,ay=map(int, sys.argv[2].split(','))
tx,ty=map(int, sys.argv[3].split(','))
if math.hypot(tx-ax, ty-ay) <= 12:
    raise SystemExit(f'primary /cursor warped the real pointer to the target: target={tx},{ty} after={ax},{ay}')
if math.hypot(bx-ax, by-ay) > 24:
    print(f'WARN pointer moved during test but did not warp to target: before={bx},{by} after={ax},{ay}', file=sys.stderr)
PY
pass 'primary /cursor triggers OpenClicky choreography without warping system pointer'

printf '\n== Clear ==\n'
clear_resp=$(curl_bridge -X POST "$BASE_URL/clear" -H 'Content-Type: application/json' -d '{}')
printf '%s\n' "$clear_resp"
[[ "$(json_get "$clear_resp" ok)" == "True" || "$(json_get "$clear_resp" ok)" == "true" ]] || fail '/clear failed'
pass 'clear endpoint'

printf '\nAll OpenClicky external-control bridge tests passed.\n'
