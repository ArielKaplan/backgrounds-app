#!/bin/bash
# Builds Backgrounds.app (universal: Apple silicon + Intel) and Backgrounds-mac.zip into app/mac/build/.
# Needs only the Xcode command line tools (xcode-select --install); no Xcode project.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
OUT=build
APP="$OUT/Backgrounds.app"
VERSION="$(tr -d '[:space:]' < ../VERSION)"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Wallpapers"

for arch in arm64 x86_64; do
  echo "== compiling $arch"
  swiftc -O -target "$arch-apple-macos13.0" -o "$OUT/Backgrounds-$arch" Sources/*.swift \
    -framework AppKit -framework WebKit -framework IOKit -framework ServiceManagement
done
lipo -create -output "$APP/Contents/MacOS/Backgrounds" "$OUT"/Backgrounds-arm64 "$OUT"/Backgrounds-x86_64
rm "$OUT"/Backgrounds-arm64 "$OUT"/Backgrounds-x86_64

sed "s/VERSION/$VERSION/g" Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
cp ../shared/settings.html "$APP/Contents/Resources/"

# Built-in wallpapers: every "Wallpaper - X" folder of the repo becomes Wallpapers/X (zips left out).
for d in "$ROOT"/Wallpaper\ -\ */; do
  name="$(basename "$d")"; name="${name#Wallpaper - }"
  [ -f "$d/index.html" ] || continue
  rsync -a --exclude '*.zip' --exclude '.DS_Store' "$d" "$APP/Contents/Resources/Wallpapers/$name/"
done

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
