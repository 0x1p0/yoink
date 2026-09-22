#!/bin/bash
# Fetch native/universal macOS binaries for Yoink.
#   - yt-dlp : official universal2 binary (yt-dlp_macos) — no Python runtime needed
#   - ffmpeg/ffprobe : fat (universal) binaries lipo'd from martin-riedl.de arm64 + amd64
# Evermeet.cx is intentionally NOT used: it only ships x86_64 and forces Rosetta on Apple Silicon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/Yoink/Resources/bin"
mkdir -p "$BIN_DIR"

ARCH="$(uname -m)"
FFMPEG_MIRROR="https://ffmpeg.martin-riedl.de"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

log()  { printf '\033[1m✓\033[0m %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

fetch_zip_tool() {
  # $1 = arch (arm64|amd64)  $2 = tool name (ffmpeg|ffprobe)  $3 = dest dir
  local arch="$1" tool="$2" dest="$3"
  local url="$FFMPEG_MIRROR/redirect/latest/macos/${arch}/release/${tool}.zip"
  local zip="$TMP_ROOT/${tool}-${arch}.zip"
  mkdir -p "$dest"

  info "Downloading ${tool} (${arch})…"
  if ! curl -fsSL --retry 3 --retry-delay 1 -o "$zip" "$url"; then
    # Fall back to snapshot builds if a release slot is missing for this arch
    url="$FFMPEG_MIRROR/redirect/latest/macos/${arch}/snapshot/${tool}.zip"
    info "Release missing — trying snapshot: $url"
    curl -fsSL --retry 3 --retry-delay 1 -o "$zip" "$url" \
      || die "Could not download ${tool} for ${arch}"
  fi

  # Zips from this mirror contain a bare binary at the root
  unzip -oq "$zip" -d "$dest" "$tool" 2>/dev/null \
    || unzip -oq "$zip" -d "$dest"
  # Some zips nest the binary — search one level if needed
  if [ ! -f "$dest/$tool" ]; then
    local found
    found="$(find "$dest" -maxdepth 3 -type f -name "$tool" | head -1)"
    [ -n "$found" ] || die "Extracted zip for ${tool} (${arch}) has no ${tool} binary"
    mv "$found" "$dest/$tool"
  fi
  chmod +x "$dest/$tool"
}

install_universal_tool() {
  # $1 = tool name. Builds a fat binary when both arch slices are available.
  local tool="$1"
  local arm_dir="$TMP_ROOT/arm64-$tool"
  local intel_dir="$TMP_ROOT/amd64-$tool"
  local out="$BIN_DIR/$tool"

  fetch_zip_tool arm64  "$tool" "$arm_dir"
  fetch_zip_tool amd64  "$tool" "$intel_dir"

  if command -v lipo >/dev/null 2>&1; then
    info "Creating universal ${tool} (arm64 + x86_64)…"
    rm -f "$out"
    lipo -create "$arm_dir/$tool" "$intel_dir/$tool" -output "$out"
    chmod +x "$out"
    local archs
    archs="$(lipo -archs "$out" 2>/dev/null || true)"
    log "${tool} → universal (${archs:-unknown})"
  else
    # No lipo (rare) — prefer the host architecture
    if [ "$ARCH" = "arm64" ]; then
      cp "$arm_dir/$tool" "$out"
    else
      cp "$intel_dir/$tool" "$out"
    fi
    chmod +x "$out"
    log "${tool} → $ARCH only (lipo not found)"
  fi

  # Sanity: must be a Mach-O that can at least print a version
  if ! "$out" -version >/dev/null 2>&1 && ! "$out" -h >/dev/null 2>&1; then
    die "${tool} downloaded but failed to execute — wrong architecture?"
  fi
}

# ── yt-dlp (official universal2 standalone — replaces the old Python + pip setup) ──

echo ""
echo "📦 Fetching yt-dlp (universal macOS binary)…"
curl -fsSL --retry 3 --retry-delay 1 \
  -o "$BIN_DIR/yt-dlp" \
  "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
chmod +x "$BIN_DIR/yt-dlp"
# Gatekeeper quarantine breaks freshly downloaded Mach-O binaries inside DMG installs
xattr -d com.apple.quarantine "$BIN_DIR/yt-dlp" 2>/dev/null || true

YT_VER="$("$BIN_DIR/yt-dlp" --version 2>/dev/null | head -1 || true)"
[ -n "$YT_VER" ] || die "yt-dlp downloaded but failed to run"
log "yt-dlp ${YT_VER} (universal)"

# ── ffmpeg / ffprobe (universal) ──

echo ""
echo "📦 Fetching ffmpeg + ffprobe…"
install_universal_tool ffmpeg
install_universal_tool ffprobe

# ── Stale artifacts from the old Python-based pipeline ──

if [ -d "$BIN_DIR/python" ]; then
  info "Removing legacy bundled Python runtime…"
  rm -rf "$BIN_DIR/python"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
log "Bundle ready:"
du -sh "$BIN_DIR/yt-dlp" "$BIN_DIR/ffmpeg" "$BIN_DIR/ffprobe" | sed 's/^/   /'

echo ""
echo "   Host arch : $ARCH"
echo "   ffmpeg    : $("$BIN_DIR/ffmpeg" -version 2>/dev/null | head -1)"
echo "   ffprobe   : $("$BIN_DIR/ffprobe" -version 2>/dev/null | head -1)"
echo ""
echo "⚠️  Xcode: ensure Resources/bin stays a blue folder reference"
echo "   (folder references copy binary contents as-is; yellow groups do not)."
