#!/usr/bin/env bash
# Builds yt-dlp as an ALREADY-EXTRACTED directory instead of the official single file.
#
# yt-dlp_macos is a PyInstaller "onefile": every launch unpacks ~137 files (104 of them Mach-O)
# into a brand-new temporary directory, and macOS scans every Mach-O it has not seen before
# through one serial system service. Measured on macOS 26.6 / arm64: a single `--version` took
# 5-18 s while burning 0.5 s of CPU, and ten in parallel took 78 s — the launches do not
# parallelise at all, which is what made ten simultaneous analyses finish in one late burst.
#
# The directory layout ships the same files with stable inodes, so the scan happens once, at
# install time: 0.19 s per launch and 0.39 s for ten in parallel.
#
# Usage: scripts/build-ytdlp.sh          (pinned version)
#        YTDLP_VERSION=2026.08.01 scripts/build-ytdlp.sh
set -euo pipefail
cd "$(dirname "$0")/.."

YTDLP_VERSION="${YTDLP_VERSION:-2026.07.04}"
DEST="Resources/binaries/yt-dlp"

PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
  for candidate in python3.14 python3.13 python3.12; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PYTHON="$(command -v "$candidate")"
      break
    fi
  done
fi
if [ -z "$PYTHON" ]; then
  echo "ERROR: no python3.12+ found. Install one (brew install python@3.14) or set PYTHON=." >&2
  exit 1
fi

echo "Building yt-dlp ${YTDLP_VERSION} with ${PYTHON}…"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$PYTHON" -m venv "$WORK/venv"
"$WORK/venv/bin/pip" -q install --upgrade pip
# The same optional libraries the official macOS build ships, so extraction behaviour matches:
# curl_cffi (impersonation), websockets, pycryptodomex, brotli, certifi, mutagen.
"$WORK/venv/bin/pip" -q install "yt-dlp[default,curl-cffi]==$YTDLP_VERSION" pyinstaller

cat > "$WORK/entry.py" <<'PY'
import yt_dlp

if __name__ == '__main__':
    yt_dlp.main()
PY

# yt-dlp imports its extractors lazily, so they have to be collected explicitly.
"$WORK/venv/bin/pyinstaller" --onedir --noconfirm --clean --log-level WARN \
  --name yt-dlp --distpath "$WORK/dist" --workpath "$WORK/build" --specpath "$WORK" \
  --collect-all yt_dlp --collect-all yt_dlp_ejs --collect-all curl_cffi \
  --collect-all websockets --collect-all Cryptodome --collect-all certifi \
  --collect-all brotli --collect-all mutagen \
  --console "$WORK/entry.py"

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$WORK/dist/yt-dlp" "$DEST"
chmod +x "$DEST/yt-dlp"

BUILT="$("$DEST/yt-dlp" --version)"
if [ "$BUILT" != "$YTDLP_VERSION" ]; then
  echo "ERROR: built $BUILT but expected $YTDLP_VERSION" >&2
  exit 1
fi
echo "yt-dlp $BUILT ready at $DEST ($(du -sh "$DEST" | cut -f1))"
