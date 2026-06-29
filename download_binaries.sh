#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/Yoink/Resources/bin"
mkdir -p "$BIN_DIR"

# ── Resolve latest Python version from python-build-standalone ────────────────

ARCH=$(uname -m)

echo "🔍 Fetching latest python-build-standalone release..."

# Get the latest release info from GitHub API
RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/indygreg/python-build-standalone/releases/latest")

# Extract the release tag (e.g. "20250101")
RELEASE_TAG=$(echo "$RELEASE_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data['tag_name'])
")

# Find the correct asset URL for this arch
if [ "$ARCH" = "arm64" ]; then
    ASSET_PATTERN="aarch64-apple-darwin-install_only.tar.gz"
else
    ASSET_PATTERN="x86_64-apple-darwin-install_only.tar.gz"
fi

PYTHON_URL=$(echo "$RELEASE_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
pattern = sys.argv[1]
assets = [a['browser_download_url'] for a in data['assets']
          if pattern in a['name'] and 'cpython-' in a['name']]
# Prefer the highest Python version in this release
assets.sort(reverse=True)
print(assets[0] if assets else '')
" "$ASSET_PATTERN")

if [ -z "$PYTHON_URL" ]; then
    echo "❌ Could not find a matching Python asset for $ARCH in release $RELEASE_TAG"
    exit 1
fi

# Extract Python version from the URL filename (e.g. cpython-3.13.2+...)
PYTHON_VERSION=$(basename "$PYTHON_URL" | sed -E 's/cpython-([0-9]+\.[0-9]+\.[0-9]+).*/\1/')

echo "✓ Latest release : $RELEASE_TAG"
echo "✓ Python version : $PYTHON_VERSION"
echo "✓ Asset URL      : $PYTHON_URL"

# ── Download and extract Python ───────────────────────────────────────────────

PYTHON_DIR="$BIN_DIR/python"

echo ""
echo "📦 Downloading standalone Python ${PYTHON_VERSION} for ${ARCH}..."
TMP_TAR="$(mktemp -d)/python.tar.gz"
curl -fL --progress-bar -o "$TMP_TAR" "$PYTHON_URL"

echo "📦 Extracting Python..."
rm -rf "$PYTHON_DIR"
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

echo ""
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

echo "✓ ffmpeg downloaded: $("$BIN_DIR/ffmpeg" -version 2>&1 | head -1 | awk '{print $3}')"

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

echo "✓ ffprobe downloaded: $("$BIN_DIR/ffprobe" -version 2>&1 | head -1 | awk '{print $3}')"

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
