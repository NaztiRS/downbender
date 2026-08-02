#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="Resources/binaries"
mkdir -p "$DEST"

# yt-dlp (Unlicense). Built locally as an extracted directory rather than downloading the
# official self-extracting binary: that one re-unpacks 104 Mach-O files on every launch and
# macOS rescans them one at a time, so concurrent launches serialise. See scripts/build-ytdlp.sh.
"$(dirname "$0")/build-ytdlp.sh"

# ffmpeg + ffprobe (arm64, signed+notarized, martin-riedl.de). GPL build — the
# reason Downbender itself is GPLv3 (see NOTICE).
for tool in ffmpeg ffprobe; do
  echo "Downloading $tool (arm64)…"
  curl -L --fail -o "$DEST/$tool.zip" \
    "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/snapshot/$tool.zip"
  unzip -oq "$DEST/$tool.zip" -d "$DEST"
  chmod +x "$DEST/$tool"
  rm -f "$DEST/$tool.zip"
done

# deno (JS runtime required by yt-dlp for the current YouTube extraction).
echo "Downloading deno (arm64)…"
curl -L --fail -o "$DEST/deno.zip" \
  "https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip"
unzip -oq "$DEST/deno.zip" -d "$DEST"
chmod +x "$DEST/deno"
rm -f "$DEST/deno.zip"

ls -la "$DEST"
echo "Verify: $DEST/yt-dlp/yt-dlp --version && $DEST/ffmpeg -version && $DEST/deno --version"
