#!/bin/bash
# CI smoke test: launches the built app and checks its desktop-level wallpaper windows and settings window.
set -u
cd "$(dirname "$0")/../.."
SHOTS=smoke; mkdir -p "$SHOTS"
APP=app/mac/build/Backgrounds.app
fail=0
check() { if eval "$1"; then echo "  ok   $2"; else echo "  FAIL $2"; fail=$((fail+1)); fi; }

sw_vers
open "$APP"
sleep 20
check 'pgrep -x Backgrounds >/dev/null' 'app is running'
check '[ -f ~/Pictures/Backgrounds/Aquarium/index.html ]' 'built-in wallpapers copied to ~/Pictures/Backgrounds'
check '[ -f ~/Library/Application\ Support/Backgrounds/config.json ]' 'config.json written'
echo "  wallpapers: $(ls ~/Pictures/Backgrounds | tr '\n' ',')"

cat > /tmp/windows.swift <<'EOF'
import CoreGraphics
import AppKit
let desktop = Int(CGWindowLevelForKey(.desktopWindow))
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var wall = 0, settings = 0
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Backgrounds" {
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    print("  window layer=\(layer) onscreen=\(onscreen) bounds=\(b)")
    if layer == desktop && onscreen { wall += 1 }
    if layer == 0 && onscreen { settings += 1 }
}
for s in NSScreen.screens { print("  screen \(s.localizedName) \(s.frame)") }
print("RESULT \(wall) \(settings)")
EOF
out="$(swift /tmp/windows.swift 2>&1)"; echo "$out"
res=($(echo "$out" | grep RESULT))
check '[ "${res[1]:-0}" -ge 1 ]' "wallpaper window(s) at desktop level (${res[1]:-0})"
check '[ "${res[2]:-0}" -ge 1 ]' "settings window open on first launch (${res[2]:-0})"
screencapture -x "$SHOTS/mac-1-first-launch.png" || echo "  (screencapture failed)"

# Second launch must not start another copy (LaunchServices reuses the running app).
open "$APP"; sleep 3
check '[ "$(pgrep -x Backgrounds | wc -l | tr -d " ")" = 1 ]' 'single instance'

osascript -e 'tell application "System Events" to set visible of every process whose name is "Backgrounds" to false' 2>/dev/null
sleep 3
screencapture -x "$SHOTS/mac-2-desktop.png" || true
log show --last 2m --predicate 'process == "Backgrounds"' --style compact 2>/dev/null | tail -40 > "$SHOTS/mac-log.txt"
cat "$SHOTS/mac-log.txt" | grep -i backgrounds | tail -20
pkill -x Backgrounds; sleep 2

# Settings written the way the settings page writes them reach the wallpaper: City at night.
python3 - <<'PY'
import json, os
p = os.path.expanduser('~/Library/Application Support/Backgrounds/config.json')
c = json.load(open(p))
c['settings']['wallpaper'] = 'City'
c['settings'].setdefault('params', {})['City'] = {'values': {'time': 'night'}, 'hash': 'time=night'}
json.dump(c, open(p, 'w'))
PY
open "$APP"; sleep 15
check 'pgrep -x Backgrounds >/dev/null' 'app restarts with edited settings'
check 'grep -q "time=night" ~/Library/Application\ Support/Backgrounds/config.json' 'settings kept after restart'
osascript -e 'tell application "System Events" to set visible of every process whose name is "Backgrounds" to false' 2>/dev/null
sleep 2
screencapture -x "$SHOTS/mac-3-city-night.png" || true
pkill -x Backgrounds
if [ $fail -gt 0 ]; then echo "$fail FAILED"; exit 1; fi
echo "all passed"
