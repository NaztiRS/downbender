# Downbender

![Downbender](docs/assets/hero.png)

*The last download master.* A native macOS app that downloads videos from
YouTube and many other sites, or extracts their audio as MP3 — powered by
[yt-dlp](https://github.com/yt-dlp/yt-dlp) with an embedded FFmpeg.

## Features

- Video downloads up to 1080p (H.264/MP4) or MP3 audio extraction.
- Works with YouTube — the most battle-tested path — and [many other sites](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md) supported by yt-dlp (support for non-YouTube sites is still maturing).
- Download queue with per-item progress, pause/resume and cancel.
- Clipboard detection: copy a video link anywhere, confirm, download.
- Dock bounce and completion sound when a download finishes in the background.
- Self-contained: yt-dlp, FFmpeg and Deno ship inside the app. Nothing to install.
- One-click updater for the download engine (yt-dlp) in Settings.

## Requirements

- macOS 26 or later, Apple Silicon.

## Install

1. Download **[Downbender.dmg](https://github.com/NaztiRS/downbender/releases/latest/download/Downbender.dmg)** (or grab it from the [website](https://naztirs.github.io/downbender/)).
2. Open the DMG and drag **Downbender** into **Applications**.
3. First launch: Downbender is not notarized by Apple (no paid developer
   account), so macOS will block it once. Go to
   **System Settings → Privacy & Security**, scroll down and click
   **Open Anyway**. This is only needed the first time.
   Terminal alternative: `xattr -dr com.apple.quarantine /Applications/Downbender.app`

## Usage

![Downbender main window](docs/assets/screenshot.png)

Paste a video URL (or copy one anywhere and confirm the prompt), pick a
quality or **Extract MP3**, choose a folder, download. Click a finished
row to reveal the file in Finder.

- **Age-restricted / members-only videos:** set **Settings → Privacy →
  Browser cookies** to the browser where you're signed in. macOS may ask
  for permission once.
- **Downloads suddenly failing?** YouTube changes constantly. Use
  **Settings → Downloader (yt-dlp) → Check for updates** to update the
  engine without reinstalling the app.

## Build from source

Requires macOS 26+ with Command Line Tools (full Xcode not needed).

```bash
./scripts/fetch-binaries.sh   # once: downloads yt-dlp, FFmpeg (GPL build) and Deno
./scripts/make-dmg.sh         # builds Downbender.dmg
# or, for a quick run:
./scripts/bundle.sh && open Downbender.app
```

Tests: `./scripts/test.sh` (plain `swift test` silently runs 0 tests with
Command Line Tools only).

## Responsible use

Downbender is a frontend for yt-dlp intended for downloading content you
have the right to download (your own uploads, public-domain or
appropriately licensed material). Downloading videos may violate the
terms of service of some platforms; you are responsible for how you use
this tool. Downbender does not circumvent DRM.

## License

GPLv3 — see [LICENSE](LICENSE). Bundled third-party components are listed
in [NOTICE](NOTICE).
