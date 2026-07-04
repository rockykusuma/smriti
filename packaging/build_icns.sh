#!/bin/bash
# Build AppIcon.icns from the 1024px master.
set -e
cd "$(dirname "$0")"
SRC="${1:-icon_1024.png}"
ISET=AppIcon.iconset
rm -rf "$ISET"; mkdir "$ISET"
sips -z 16 16   "$SRC" --out "$ISET/icon_16x16.png"      >/dev/null
sips -z 32 32   "$SRC" --out "$ISET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32   "$SRC" --out "$ISET/icon_32x32.png"      >/dev/null
sips -z 64 64   "$SRC" --out "$ISET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 "$SRC" --out "$ISET/icon_128x128.png"    >/dev/null
sips -z 256 256 "$SRC" --out "$ISET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SRC" --out "$ISET/icon_256x256.png"    >/dev/null
sips -z 512 512 "$SRC" --out "$ISET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SRC" --out "$ISET/icon_512x512.png"    >/dev/null
cp "$SRC" "$ISET/icon_512x512@2x.png"
iconutil -c icns "$ISET" -o AppIcon.icns
echo "built AppIcon.icns"
