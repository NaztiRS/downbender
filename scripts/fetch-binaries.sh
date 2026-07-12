#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="Resources/binaries"
mkdir -p "$DEST"

# yt-dlp (self-contained universal binary, Unlicense)
echo "Downloading yt-dlp_macos…"
curl -L --fail -o "$DEST/yt-dlp_macos" \
  "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
chmod +x "$DEST/yt-dlp_macos"

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
echo "Verify: $DEST/yt-dlp_macos --version && $DEST/ffmpeg -version && $DEST/deno --version"
