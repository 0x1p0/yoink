# Download Required Binaries

Before building Yoink, download these two files into this folder:

## yt-dlp (macOS universal binary)
```bash
curl -L -o yt-dlp \
  "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
chmod +x yt-dlp
```

## ffmpeg (static macOS build)
```bash
curl -L -o ffmpeg_zip \
  "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
unzip ffmpeg_zip
# Move the ffmpeg binary here and delete the zip
chmod +x ffmpeg
```

After downloading both files, build Yoink normally in Xcode.
The build will automatically copy them into the app bundle.
