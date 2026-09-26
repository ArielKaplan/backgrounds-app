#!/bin/bash
# CI end-to-end update test on a real Mac. Builds "old" 0.9.0 and "new" 99.0.0 with a throwaway key, serves the
# update from localhost, and checks that the app refuses a badly signed update, then installs a good one by itself,
# refreshing unedited built-in wallpapers while keeping edited ones.
set -u
cd "$(dirname "$0")/../.."
REPO="$PWD"
W="${RUNNER_TEMP:-/tmp}/upd"; rm -rf "$W"; mkdir -p "$W/srv"
SHOTS="$REPO/smoke"; mkdir -p "$SHOTS"
fail=0
check() { if eval "$1"; then echo "  ok   $2"; else echo "  FAIL $2"; fail=$((fail+1)); fi; }
APP="$HOME/Applications/Backgrounds.app"
SUPPORT="$HOME/Library/Application Support/Backgrounds"
PICS="$HOME/Pictures/Backgrounds"
FEED=http://127.0.0.1:8765/update.json
ver() { /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null; }

openssl ecparam -name prime256v1 -genkey -noout -out "$W/key.pem"
openssl ecparam -name prime256v1 -genkey -noout -out "$W/wrong.pem"
PUB=$(openssl ec -in "$W/key.pem" -pubout -outform DER 2>/dev/null | tail -c 64 | base64 | tr -d '\n')

echo "== building old (0.9.0)"
VERSION=0.9.0 UPDATE_PUBLIC_KEY="$PUB" UPDATE_FEED="$FEED" OUT="$W/old" app/mac/build.sh > "$W/build-old.log" 2>&1 || { tail -30 "$W/build-old.log"; exit 1; }
# The "new" version changes two wallpapers and adds one.
echo "<!-- v99 -->" >> "Wallpaper - Sheep/index.html"
echo "<!-- v99 -->" >> "Wallpaper - Aquarium/index.html"
mkdir -p "Wallpaper - Zz New"; printf '<!doctype html><title>New</title><body style="margin:0;background:#2a6">' > "Wallpaper - Zz New/index.html"
echo "== building new (99.0.0)"
VERSION=99.0.0 UPDATE_PUBLIC_KEY="$PUB" UPDATE_FEED="$FEED" OUT="$W/new" app/mac/build.sh > "$W/build-new.log" 2>&1 || { tail -30 "$W/build-new.log"; exit 1; }
git checkout -- "Wallpaper - Sheep/index.html" "Wallpaper - Aquarium/index.html"; rm -rf "Wallpaper - Zz New"
cp "$W/new/Backgrounds-mac.zip" "$W/srv/"

python3 -m venv "$W/venv" && "$W/venv/bin/pip" install -q cryptography
feed() { "$W/venv/bin/python" app/release/make_feed.py --version 99.0.0 --key "$1" --base-url http://127.0.0.1:8765 \
           --mac "$W/srv/Backgrounds-mac.zip" --notes "- Test update" --out "$W/srv/update.json"; }
(cd "$W/srv" && python3 -m http.server 8765 --bind 127.0.0.1 > "$W/http.log" 2>&1 &)
sleep 1

# Fresh install of the old version, told to install updates without asking (test hook).
pkill -x Backgrounds; sleep 1
rm -rf "$APP" "$SUPPORT" "$PICS"; mkdir -p "$HOME/Applications" "$SUPPORT"
cp -R "$W/old/Backgrounds.app" "$APP"
echo '{"updateAutoInstall": true}' > "$SUPPORT/config.json"

echo "== 1. update signed with the wrong key"
feed "$W/wrong.pem"
open "$APP"; sleep 30
check '[ "$(ver)" = 0.9.0 ]' "badly signed update refused (still $(ver))"
check 'pgrep -x Backgrounds >/dev/null' 'app still running'
check 'grep -q lastUpdateCheck "$SUPPORT/config.json"' 'it did check the feed'
check 'grep -q "GET /Backgrounds-mac.zip" "$W/http.log"' 'it downloaded the update before refusing it'

# The user edits one built-in wallpaper and deletes another.
echo "<!-- my edit -->" >> "$PICS/Aquarium/index.html"
rm -rf "$PICS/Meadow"
pkill -x Backgrounds; sleep 2
python3 - "$SUPPORT/config.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
for k in ("lastUpdateCheck", "notifiedVersion"): c.pop(k, None)
json.dump(c, open(p, "w"))
PY

echo "== 2. correctly signed update"
feed "$W/key.pem"
open "$APP"
for i in $(seq 1 60); do [ "$(ver)" = 99.0.0 ] && pgrep -x Backgrounds >/dev/null && break; sleep 2; done
sleep 8
check '[ "$(ver)" = 99.0.0 ]' "app replaced itself with 99.0.0 (now $(ver))"
check 'pgrep -x Backgrounds >/dev/null' 'new version relaunched'
check 'ps -o command= -p "$(pgrep -x Backgrounds | head -1)" | grep -q "$APP"' 'running from the same place'
check '[ ! -e "$APP.old" ] && ! ls -d "$HOME/Applications/".Backgrounds-*-update.app >/dev/null 2>&1' 'no leftovers'
check 'codesign --verify "$APP"' 'updated app signature intact'
check 'grep -q "v99" "$PICS/Sheep/index.html"' 'unedited built-in wallpaper updated'
check 'grep -q "my edit" "$PICS/Aquarium/index.html" && ! grep -q "v99" "$PICS/Aquarium/index.html"' 'edited wallpaper kept as the user left it'
check '[ -f "$PICS/Zz New/index.html" ]' 'new built-in wallpaper added'
check '[ ! -e "$PICS/Meadow" ]' 'deleted wallpaper not brought back'
check 'grep -q "\"syncedVersion\" *: *\"99.0.0\"" "$SUPPORT/config.json"' 'sync recorded'
screencapture -x "$SHOTS/mac-update-done.png" || true
log show --last 3m --predicate 'process == "Backgrounds"' --style compact 2>/dev/null | grep -iE "update|synced|keeping" | tail -20
pkill -x Backgrounds
if [ $fail -gt 0 ]; then echo "$fail FAILED"; exit 1; fi
echo "all passed"
