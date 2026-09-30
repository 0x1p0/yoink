#!/bin/bash
# Regenerates the installer artwork from the Swift sources in this folder:
#   - packaging/dmg/background.tiff        (1x + 2x, used by dmgbuild)
#   - packaging/dmg/installer-preview.png  (README picture of the installer window)
# Run packaging/icon/build_icons.sh first if the icon changed.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift "$DIR/make_background.swift" "$TMP/background.png"    1
swift "$DIR/make_background.swift" "$TMP/background@2x.png" 2
tiffutil -cathidpicheck "$TMP/background.png" "$TMP/background@2x.png" -out "$DIR/background.tiff" >/dev/null

swift "$DIR/make_preview.swift" "$TMP/background@2x.png" "$ROOT/packaging/icon/yoink-icon.png" \
      "$DIR/installer-preview.png"

echo "✓ Installer artwork regenerated"
