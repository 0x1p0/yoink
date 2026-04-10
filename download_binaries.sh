#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/Yoink/Resources/bin"
mkdir -p "$BIN_DIR"

# ── yt-dlp via standalone Python ──────────────────────────────────────────────

PYTHON_VERSION="3.12.8"
ARCH=$(uname -m)

if [ "$ARCH" = "arm64" ]; then
    PYTHON_URL="https://github.com/indygreg/python-build-standalone/releases/download/20241219/cpython-${PYTHON_VERSION}+20241219-aarch64-apple-darwin-install_only.tar.gz"
else
    PYTHON_URL="https://github.com/indygreg/python-build-standalone/releases/download/20241219/cpython-${PYTHON_VERSION}+20241219-x86_64-apple-darwin-install_only.tar.gz"
fi

PYTHON_DIR="$BIN_DIR/python"

echo "📦 Downloading standalone Python ${PYTHON_VERSION} for ${ARCH}..."
TMP_TAR="$(mktemp -d)/python.tar.gz"
curl -fL --progress-bar -o "$TMP_TAR" "$PYTHON_URL"

echo "📦 Extracting Python..."
mkdir -p "$PYTHON_DIR"
tar -xzf "$TMP_TAR" -C "$PYTHON_DIR" --strip-components=1
rm -f "$TMP_TAR"

echo "✓ Python extracted: $("$PYTHON_DIR/bin/python3" --version)"

echo "📦 Installing yt-dlp into standalone Python..."
"$PYTHON_DIR/bin/pip3" install --quiet yt-dlp

echo "✓ yt-dlp installed: $("$PYTHON_DIR/bin/python3" -m yt_dlp --version)"

# Launcher script
cat > "$BIN_DIR/yt-dlp" << 'LAUNCHER'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/python/bin/python3" -m yt_dlp "$@"
LAUNCHER

chmod +x "$BIN_DIR/yt-dlp"
echo "✓ yt-dlp launcher written"

# ── ffmpeg ───────────────────────────────────────────────────────────────────

echo "📦 Downloading ffmpeg..."

FFMPEG_URL="https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
FFPROBE_URL="https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"

# ---- ffmpeg ----
TMP_ZIP="$(mktemp -d)/ffmpeg.zip"
curl -fJL --progress-bar -o "$TMP_ZIP" "$FFMPEG_URL"

if ! file "$TMP_ZIP" | grep -q "Zip archive"; then
    echo "❌ ffmpeg download failed (not a zip)"
    exit 1
fi

unzip -o "$TMP_ZIP" -d "$BIN_DIR" ffmpeg
chmod +x "$BIN_DIR/ffmpeg"
rm -f "$TMP_ZIP"

echo "✓ ffmpeg downloaded"

# ---- ffprobe ----
echo "📦 Downloading ffprobe..."
TMP_ZIP2="$(mktemp -d)/ffprobe.zip"
curl -fJL --progress-bar -o "$TMP_ZIP2" "$FFPROBE_URL"

if ! file "$TMP_ZIP2" | grep -q "Zip archive"; then
    echo "❌ ffprobe download failed (not a zip)"
    exit 1
fi

unzip -o "$TMP_ZIP2" -d "$BIN_DIR" ffprobe
chmod +x "$BIN_DIR/ffprobe"
rm -f "$TMP_ZIP2"

echo "✓ ffprobe downloaded"

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "✅ Done! Bundle sizes:"
du -sh "$BIN_DIR/python" "$BIN_DIR/ffmpeg" "$BIN_DIR/ffprobe" "$BIN_DIR/yt-dlp"

echo ""
echo "⚠️  IMPORTANT — Xcode setup:"
echo "   1. In Xcode, select the 'python' folder under Resources/bin/"
echo "   2. Delete reference (don't move to trash) and re-add it"
echo "   3. Choose 'Create folder references' (blue folder)"
echo "   4. Ensure target membership is enabled"
echo ""
echo "   The python/ folder MUST be a blue folder (folder reference)"
echo "   or Xcode will try to compile Python files and fail."