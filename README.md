<div align="center">

# Yoink
**Native macOS video downloader. No Terminal. No Homebrew. No nonsense.**

[![macOS](https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](#license)
[![Release](https://img.shields.io/github/v/release/0x1p0/yoink?style=flat-square)](https://github.com/0x1p0/yoink/releases/latest)

[**Download DMG**](https://github.com/0x1p0/yoink/releases/latest) · [Report a Bug](https://github.com/0x1p0/yoink/issues) · [Request a Feature](https://github.com/0x1p0/yoink/issues)

</div>

---

## Demo

https://github.com/user-attachments/assets/d543bf3e-5aa3-4ba5-b808-5bb7b1bcb1f1

---

## What is Yoink?

Yoink is a clean, native macOS app for downloading videos and audio from YouTube, Twitch, Instagram, TikTok, Twitter/X, Reddit, Vimeo, SoundCloud, and 1000+ other sites. It wraps `yt-dlp` and `ffmpeg` in a proper SwiftUI interface so you never have to touch the Terminal.

`ffmpeg` and `ffprobe` ship inside the app bundle (placed in `Yoink/Resources/bin/` in the repo). `yt-dlp` is driven via a bundled standalone Python environment - the `download_binaries.sh` script handles building everything. On first launch the app copies all binaries to `~/Library/Application Support/Yoink/bin/` and keeps `yt-dlp` up to date silently in the background.

---

## Features

### Core Downloading
- **1000+ supported sites** - YouTube, Twitch, Instagram, TikTok, Twitter/X, Reddit, Vimeo, SoundCloud, and everything else yt-dlp supports
- **Quality picker** - Best available, 1080p H.264, 720p, 480p, 360p, audio-only (Best / MP3 / M4A / Opus)
- **Live progress** - real-time speed, ETA, and per-download progress bars
- **Pause & resume** - pause any active download and pick it back up later
- **Concurrent downloads** - configurable queue with parallel downloads (1 / 2 / 3 / 5 / unlimited)
- **Batch download** - queue multiple URLs and start them all at once

### Playlist & Channel Support
- **Full playlist mode** - paste a playlist or channel URL, Yoink fetches every entry
- **Video picker** - checklist to select exactly which videos you want before downloading
- **Per-video settings** - individual quality, clip range, and chapter selection per item
- **Chapter-aware clipping** - trim by timestamp or by chapter markers

### Watch Later
- **Save for later** - bookmark any video or playlist URL to download when you're ready
- **Scheduled downloads** - pick a date and time; Yoink downloads it automatically in the background
- **Global SponsorBlock toggle** - one click removes sponsor segments, self-promo, and interaction reminders from every Watch Later download
- **Global Subtitles toggle** - automatically grab subtitles when available, skip gracefully when not
- **Instant playlist picker** - video list is pre-fetched in the background so the picker opens immediately with no loading spinner
- **Playlist names** - saved playlists show their real name, not the raw URL

### Clipboard Monitor
- **Auto-detection** - copy a supported link anywhere on your Mac and Yoink's banner appears automatically
- **Zero friction** - tap Download Now, Save for Later, or dismiss - no app switching needed
- **System notification** - fires even when Yoink is running in the background
- **Snooze** - pause the monitor for 5 min, 30 min, 1 hour, until tomorrow, while using a specific app, or for the session for a specific domain
- **Smart re-detection** - copy anything else between two copies of the same link and Yoink will offer it again
- **Domain filter** - choose exactly which sites trigger the clipboard monitor

### Menu Bar
- **Always accessible** - Yoink lives in the menu bar so you can start downloads without switching apps
- **Live icon** - animated progress indicator while downloads are running; customisable icon (SF Symbols, emoji, % counter)
- **Paste & go** - paste a URL directly from the menu bar popover

### History
- **Full download log** - every completed download with title, thumbnail, site, and timestamp
- **Reveal in Finder** - jump straight to the file on disk
- **Re-download** - re-queue any past download in one click
- **Duplicate detection** - Yoink warns you before downloading something you already have

### Post-processing
- **SponsorBlock** - remove sponsor segments, intros, outros, and interaction reminders automatically
- **Subtitles** - download manual or auto-generated subtitles alongside the video
- **Metadata embedding** - thumbnail, title, and chapter markers embedded in the output file
- **Post-download conversion** - optionally re-encode to H.265 (HEVC), extract to MP3/M4A, or compress audio to 128 kbps AAC

### Customisation
- **Themes** - system, light, or dark
- **Custom output folder** - global default with per-session override; output categories (e.g. Educational 🎓, Music 🎵) with per-category save paths
- **Speed limiting** - cap download speed so you don't saturate your connection
- **Process priority** - Low (efficiency cores), Balanced, Normal, or High
- **Concurrency control** - set how many downloads run in parallel
- **Proxy support** - route downloads through a custom proxy URL
- **Extra yt-dlp arguments** - power-user escape hatch for anything not in the UI
- **Cookie support** - pass a Netscape cookie file for authenticated downloads (age-gated content, private videos, etc.)
- **Show in Dock toggle** - hide Yoink from the Dock and keep it menu-bar-only

### Automatic Updates
- **yt-dlp auto-update** - silently checks for a newer yt-dlp release once every 24 hours and updates in the background without restarting the app
- **App update check** - notifies you when a new version of Yoink itself is available on GitHub Releases

### First-launch Experience
- **Built-in tutorial** - 8-step interactive walkthrough shown automatically on first launch
- **Re-playable** - open it again anytime from Settings → About

---

## Installation

### Option 1 - Download the DMG *(recommended)*

1. Go to the [**Releases page**](https://github.com/0x1p0/yoink/releases/latest)
2. Download `Yoink.dmg`
3. Open the DMG and drag **Yoink.app** to your Applications folder
4. Launch Yoink - that's it. All binaries are already bundled inside the app.

> **"Yoink can't be opened" / Gatekeeper prompt?** Right-click Yoink.app → Open → Open. This only happens once on unsigned builds.

### Option 2 - Build from source

See [Building Locally](#building-locally) below.

---

## Requirements

- macOS 13 Ventura or later
- Apple Silicon or Intel
- No Homebrew, no Python, no system dependencies required at runtime

---

## Building Locally

### Prerequisites
- Xcode 15 or later
- macOS 13 Ventura or later

### Steps

**1. Clone the repo**
```bash
git clone https://github.com/0x1p0/yoink.git
cd yoink
```

**2. Get the binaries**

`ffmpeg` and `ffprobe` are provided as releases assets in this repo - download them from the [Releases page](https://github.com/0x1p0/yoink/releases/latest) and place them in `Yoink/Resources/bin/`.

To also build the `yt-dlp` + standalone Python bundle (required for a fully working build), run:

```bash
./download_binaries.sh
```

This script downloads a standalone Python 3.12, installs `yt-dlp` into it, downloads `ffmpeg` and `ffprobe` from evermeet.cx, and places everything in `Yoink/Resources/bin/`. It will also print instructions for adding the `python/` folder to Xcode correctly.

> **Note:** You do not need Python installed on your Mac. The script uses a self-contained Python build that lives entirely inside the app.

**3. Open in Xcode**
```bash
open Yoink.xcodeproj
```

**4. Disable sandboxing**

Xcode → `Yoink` target → Signing & Capabilities → remove **App Sandbox**

> Sandboxed apps cannot spawn child processes like yt-dlp and ffmpeg.

**5. Set your signing team**

Signing & Capabilities → select your Apple ID team

**6. Build & Run**

Press `⌘R`

---

## Creating a Release DMG

**1. Archive**
```
Xcode → Product → Archive
```

**2. Export**
```
Organizer → Distribute App → Copy App → save Yoink.app
```

**3. Package as DMG**
```bash
brew install create-dmg

create-dmg \
  --volname "Yoink" \
  --window-size 600 400 \
  --icon-size 128 \
  --icon "Yoink.app" 175 190 \
  --app-drop-link 425 190 \
  "Yoink.dmg" \
  "/path/to/folder/containing/Yoink.app/"
```

**4. Notarize** *(optional - removes Gatekeeper warning for all users)*

Requires a paid Apple Developer account ($99/yr).

```bash
xcrun notarytool submit Yoink.dmg \
  --apple-id you@example.com \
  --team-id YOUR_TEAM_ID \
  --password APP_SPECIFIC_PASSWORD \
  --wait

xcrun stapler staple Yoink.dmg
```

Upload the resulting `Yoink.dmg` to the GitHub Release. Upload `ffmpeg` and `ffprobe` as additional release assets so contributors can grab them without running the full script.

---

## Project Structure

```
Yoink/
├── download_binaries.sh              ← build & refresh all binaries
├── Yoink/
│   ├── Sources/
│   │   ├── YoinkApp.swift            # app entry point, AppDelegate, notification handling
│   │   ├── Models/
│   │   │   ├── DownloadJob.swift     # job model, format definitions, yt-dlp arg builder
│   │   │   ├── SettingsManager.swift # all user preferences, output categories
│   │   │   ├── ThemeManager.swift    # light/dark/system theme
│   │   │   └── Haptics.swift         # haptic feedback helpers
│   │   ├── Services/
│   │   │   ├── Services.swift        # DependencyService, DownloadService, DownloadQueue,
│   │   │   │                         # HistoryStore, AppUpdateService
│   │   │   ├── ClipboardMonitor.swift # clipboard watcher, snooze, banner
│   │   │   ├── TwitchService.swift   # Twitch VOD/clip metadata & quality fetching
│   │   │   ├── WatchLaterStore.swift # watch later bookmarks persistence
│   │   │   └── ScheduledDownloadStore.swift # scheduled download persistence
│   │   └── Views/
│   │       ├── ContentView.swift     # main window, tab bar, mode switcher
│   │       ├── JobCard.swift         # individual download card UI
│   │       ├── AdvancedView.swift    # playlist / channel mode
│   │       ├── WatchLaterView.swift  # watch later, scheduler, playlist picker
│   │       ├── HistoryView.swift     # download history log
│   │       ├── MenuBarView.swift     # menu bar popover UI
│   │       ├── SettingsView.swift    # full settings panel
│   │       ├── TutorialView.swift    # first-launch onboarding walkthrough
│   │       └── Sheets.swift          # shared sheet components
│   └── Resources/
│       ├── Assets.xcassets/          # app icon, accent colour
│       └── bin/
│           ├── yt-dlp                ← launcher script (runs via bundled Python)
│           ├── python/               ← standalone Python 3.12 (blue folder reference in Xcode)
│           ├── ffmpeg                ← download from Releases or run download_binaries.sh
│           └── ffprobe               ← download from Releases or run download_binaries.sh
```

---

## How the Binaries Work

On first launch, Yoink copies all binaries from the app bundle to `~/Library/Application Support/Yoink/bin/` (a writable location outside the `.app` bundle). Once there, `yt-dlp` can be updated without touching the app itself.

```
App launches
  └─ ensureBinariesCopied()
       Copies Resources/bin/ → ~/Library/Application Support/Yoink/bin/
       (skipped on subsequent launches if files already exist)
  └─ checkAll()
       Reads installed versions → shows in Settings → Dependencies
       If >24h since last check:
         └─ Fetches github.com/yt-dlp/yt-dlp/releases/latest
              If newer version found:
                └─ pip installs newer yt-dlp into the bundled Python env
                     Logs "✓ yt-dlp updated to vX.YY.ZZ"
         └─ Checks evermeet.cx for newer ffmpeg / ffprobe builds
              If newer found: downloads and atomically replaces the binary
```

`yt-dlp` is run via the bundled standalone Python (`python/bin/python3 -m yt_dlp`), so it updates through `pip` rather than replacing a binary. `ffmpeg` and `ffprobe` are static builds and update by binary replacement. You can also force-update any of them from **Settings → Dependencies**.

---

## Acknowledgements

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) - the engine that powers all downloads
- [ffmpeg](https://ffmpeg.org) - post-processing, stream merging, and format conversion
- [SponsorBlock](https://sponsor.ajay.app) - community-sourced sponsor segment database
- [python-build-standalone](https://github.com/indygreg/python-build-standalone) - self-contained Python used to run yt-dlp

---

## License

MIT - see [LICENSE](LICENSE) for details.
