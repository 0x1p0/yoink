# Download Required Binaries

Before building Yoink, fetch the bundled tools into this folder:

```bash
./download_binaries.sh
```

That script installs:

| Tool      | Source                              | Architecture        |
|-----------|-------------------------------------|---------------------|
| `yt-dlp`  | Official `yt-dlp_macos` release     | Universal (arm64+x86_64) |
| `ffmpeg`  | ffmpeg.martin-riedl.de static builds | Universal (lipo)    |
| `ffprobe` | ffmpeg.martin-riedl.de static builds | Universal (lipo)    |

No Python runtime is bundled anymore — `yt-dlp_macos` is a self-contained universal binary.
No Homebrew or Rosetta required on any Mac.

Manual one-off fetch (only if you cannot run the script):

```bash
# yt-dlp (universal)
curl -L -o yt-dlp \
  "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
chmod +x yt-dlp

# ffmpeg + ffprobe (pick your arch; arm64 = Apple Silicon)
curl -L -o ffmpeg.zip  "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
curl -l -o ffprobe.zip "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffprobe.zip"
unzip -o ffmpeg.zip && unzip -o ffprobe.zip && rm -f *.zip
chmod +x ffmpeg ffprobe
```

After downloading, build Yoink normally in Xcode.
The build will copy `Resources/bin/` into the app bundle (blue folder reference).
