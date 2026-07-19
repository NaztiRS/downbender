<h1 align="center">
  <img src="docs/assets/wordmark.png" alt="Downbender" width="440">
</h1>

![Downbender](docs/assets/hero.png)

<p align="center">
  <a href="https://github.com/NaztiRS/downbender/actions/workflows/ci.yml"><img src="https://github.com/NaztiRS/downbender/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/NaztiRS/downbender/actions/workflows/ci.yml"><img src="https://img.shields.io/badge/coverage-86%25-brightgreen" alt="Test coverage"></a>
  <a href="https://github.com/NaztiRS/downbender/releases/latest"><img src="https://img.shields.io/github/v/release/NaztiRS/downbender?color=3aa0f7&label=release" alt="Latest release"></a>
  <a href="https://github.com/NaztiRS/downbender#requirements"><img src="https://img.shields.io/badge/macOS-26%2B%20Apple%20Silicon-0b1e38" alt="Supported platform: macOS 26+ on Apple Silicon"></a>
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/NaztiRS/downbender?color=blue" alt="License: GPLv3"></a>
</p>

*The last download master.* A native macOS app that downloads videos from
YouTube and many other sites, or extracts their audio as MP3 — powered by
[yt-dlp](https://github.com/yt-dlp/yt-dlp) with an embedded FFmpeg.

## Features

- Video downloads up to 1080p (H.264/MP4) or MP3 audio extraction.
- Works with YouTube — the most battle-tested path — and [many other sites](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md) supported by yt-dlp (support for non-YouTube sites is still maturing).
- Download queue with per-item progress, pause/resume and cancel.
- Clipboard detection: copy a video link anywhere, confirm, download.
- Optional Chrome companion: an IDM-style button follows only the video currently playing or previewing, with toolbar and right-click fallbacks.
- Dock bounce and completion sound when a download finishes in the background.
- Self-contained: yt-dlp, FFmpeg and Deno ship inside the app. Nothing to install.
- One-click updater for the download engine (yt-dlp) in Settings.

## Requirements

- macOS 26 or later, Apple Silicon.

## Install

With [Homebrew](https://brew.sh):

```bash
brew install --cask naztirs/tap/downbender
```

Or manually:

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

### Chrome companion (manual install)

No Chrome Web Store account is required. Open **Settings → Chrome extension** and click
**Install Chrome Extension**. Downbender creates a temporary shortcut in Downloads and takes you
to Chrome's extension screen. Then:

1. Open `chrome://extensions` in Chrome.
2. Enable **Developer mode**.
3. Click **Load unpacked**, choose **Downloads** in the sidebar and select
   `Downbender Extension Installer`.
4. Once Chrome loads the extension, its native host verifies and removes the temporary shortcut
   automatically. **Clean up manually** remains available in Downbender as a fallback.

Chrome resolves the shortcut to the extension bundled inside `Downbender.app`; no permanent
installation folder remains in Downloads.

The app registers its native-messaging helper automatically. The page overlay is deliberately
singular: it appears only when a sufficiently large video is playing or its hover preview is
advancing. Click Downbender's toolbar icon or use **Download with Downbender** in the context menu
when a site uses a player the overlay cannot see.

## Build from source

Requires macOS 26+ with Command Line Tools (full Xcode not needed).

```bash
./scripts/fetch-binaries.sh   # once: downloads yt-dlp, FFmpeg (GPL build) and Deno
./scripts/make-dmg.sh         # builds Downbender.dmg
# or, for a quick run:
./scripts/bundle.sh && open Downbender.app
```

With [pnpm](https://pnpm.io) installed, every task is one short command:

| Command | What it does |
| --- | --- |
| `pnpm check` | Lint, build and run the tests — the same gate CI enforces |
| `pnpm build` | Compile the package (`swift build`) |
| `pnpm test` | Run the test suite (CLT-safe wrapper around `swift test`) |
| `pnpm lint` | SwiftFormat in lint mode + SwiftLint, no changes applied |
| `pnpm format` | Apply SwiftFormat fixes in place |
| `pnpm bundle` | Build `Downbender.app` |
| `pnpm dmg` | Build the distributable DMG and the self-updater zip |
| `pnpm release` | Cut a full release: tests → DMG/zip → tag → GitHub release → cask bump |
| `pnpm cask` | Sync the Homebrew cask with the published release |
| `pnpm binaries` | Download yt-dlp, FFmpeg and Deno (first-time setup) |

Tests: `./scripts/test.sh` (plain `swift test` silently runs 0 tests with
Command Line Tools only).

Contributing? Run `pnpm install` once — [husky](https://typicode.github.io/husky/)
wires the git hooks: lint + build on every commit, the test suite on every
push (linters via `brew install swiftformat swiftlint`).

## Responsible use

Downbender is a frontend for yt-dlp intended for downloading content you
have the right to download (your own uploads, public-domain or
appropriately licensed material). Downloading videos may violate the
terms of service of some platforms; you are responsible for how you use
this tool. Downbender does not circumvent DRM.

## License

GPLv3 — see [LICENSE](LICENSE). Bundled third-party components are listed
in [NOTICE](NOTICE).
