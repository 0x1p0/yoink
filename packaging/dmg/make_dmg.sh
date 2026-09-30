#!/bin/bash
# Builds the styled Yoink installer DMG.
#
#   packaging/dmg/make_dmg.sh <path/to/Yoink.app> <output.dmg> [volume name]
#
# Installs dmgbuild into a throwaway virtualenv, so nothing touches the system Python.
set -euo pipefail

APP="${1:?path to Yoink.app}"
OUT="${2:?output .dmg path}"
VOLNAME="${3:-Yoink}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -d "$APP" ] || { echo "✗ $APP not found" >&2; exit 1; }

VENV="$(mktemp -d)/venv"
python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet --disable-pip-version-check "dmgbuild>=1.6"

rm -f "$OUT"
"$VENV/bin/dmgbuild" -s "$DIR/settings.py" \
  -D app="$APP" -D assets="$DIR" \
  "$VOLNAME" "$OUT"

echo "✓ $(du -h "$OUT" | cut -f1)  $OUT"
