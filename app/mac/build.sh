#!/bin/bash
# Builds Backgrounds.app (universal: Apple silicon + Intel) and Backgrounds-mac.zip into app/mac/build/.
# Needs only the Xcode command line tools (xcode-select --install); no Xcode project.
# Optional overrides (used by the CI update test): VERSION=9.9.9 UPDATE_PUBLIC_KEY=<base64> UPDATE_FEED=<url> OUT=<dir>
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
OUT="${OUT:-build}"
APP="$OUT/Backgrounds.app"
VERSION="${VERSION:-$(tr -d '[:space:]' < ../VERSION)}"
UPDATE_PUBLIC_KEY="${UPDATE_PUBLIC_KEY:-$(tr -d '[:space:]' < ../update-public-key.txt)}"
UPDATE_FEED="${UPDATE_FEED:-https://github.com/ArielKaplan/backgrounds-app/releases/latest/download/update.json}"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Wallpapers"

for arch in arm64 x86_64; do
  echo "== compiling $arch"
  swiftc -O -target "$arch-apple-macos13.0" -o "$OUT/Backgrounds-$arch" Sources/*.swift \
    -framework AppKit -framework WebKit -framework IOKit -framework ServiceManagement
done
lipo -create -output "$APP/Contents/MacOS/Backgrounds" "$OUT"/Backgrounds-arm64 "$OUT"/Backgrounds-x86_64
rm "$OUT"/Backgrounds-arm64 "$OUT"/Backgrounds-x86_64

sed -e "s|<string>VERSION</string>|<string>$VERSION</string>|g" \
    -e "s|UPDATE_PUBLIC_KEY|$UPDATE_PUBLIC_KEY|" -e "s|UPDATE_FEED|$UPDATE_FEED|" Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
cp ../shared/settings.html "$APP/Contents/Resources/"

# Built-in wallpapers: every "Wallpaper - X" folder of the repo becomes Wallpapers/X (zips left out).
for d in "$ROOT"/Wallpaper\ -\ */; do
  name="$(basename "$d")"; name="${name#Wallpaper - }"
  [ -f "$d/index.html" ] || continue
  rsync -a --exclude '*.zip' --exclude '.DS_Store' "$d" "$APP/Contents/Resources/Wallpapers/$name/"
done

# Fingerprints of every shipped version of the built-in wallpapers (lets updates refresh unedited copies).
python3 ../release/wallpaper_history.py "$ROOT" "$APP/Contents/Resources/wallpaper-history.json" || echo "(no wallpaper history)"

# Icon
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s ../icons/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) ../icons/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Ad-hoc signature (no Apple Developer account): required to run on Apple silicon.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Backgrounds-mac.zip"
echo "== built $APP ($VERSION) and $OUT/Backgrounds-mac.zip"
