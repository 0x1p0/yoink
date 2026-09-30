#!/bin/bash
# Regenerates every Yoink icon from packaging/icon/make_icon.swift:
#   - Yoink/Resources/Assets.xcassets/AppIcon.appiconset/*.png   (the app icon)
#   - packaging/dmg/VolumeIcon.icns                               (the mounted DMG's icon)
#   - packaging/icon/yoink-icon.png                               (512 px, used by the README)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ICON_DIR="$ROOT/packaging/icon"
APPICON="$ROOT/Yoink/Resources/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MASTER="$TMP/icon_1024.png"
swift "$ICON_DIR/make_icon.swift" "$MASTER" 1024

# App icon catalogue (file names match AppIcon.appiconset/Contents.json)
for px in 16 32 64 128 256 512 1024; do
  sips -z "$px" "$px" "$MASTER" --out "$APPICON/icon_${px}x${px}.png" >/dev/null
done

# README logo
sips -z 512 512 "$MASTER" --out "$ICON_DIR/yoink-icon.png" >/dev/null

# .icns for the DMG volume
ICONSET="$TMP/Yoink.iconset"
mkdir -p "$ICONSET"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" "512:icon_256x256@2x" \
            "512:icon_512x512" "1024:icon_512x512@2x"; do
  px="${spec%%:*}"; name="${spec#*:}"
  sips -z "$px" "$px" "$MASTER" --out "$ICONSET/$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/packaging/dmg/VolumeIcon.icns"

echo "✓ Icons regenerated"
