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
# Regression guard for the whole point of building this way: launches must run in parallel.
# Absolute timings drift a lot with how warm the machine is (the same binary measured anywhere
# between 5 s and 19 s), so the check compares the RATIO, which stayed put across every run:
# a self-extracting build costs ~N times one launch, an extracted one costs about the same.
warm_up() { "$DEST/yt-dlp" --version >/dev/null 2>&1; }
# The command's own output is swallowed in here: redirecting at the call site would swallow the
# measurement itself, since the caller reads this function through a command substitution.
elapsed() {
  local start
  start=$(date +%s.%N)
  "$@" >/dev/null 2>&1
  awk -v s="$start" -v e="$(date +%s.%N)" 'BEGIN { printf "%.3f", e - s }'
}
launch_many() {
  local n=$1 i
  for ((i = 0; i < n; i++)); do "$DEST/yt-dlp" --version >/dev/null 2>&1 & done
  wait
}

warm_up   # the very first launch pays the one-off scan of the freshly written files
ONE=$(elapsed "$DEST/yt-dlp" --version)
EIGHT=$(elapsed launch_many 8)
RATIO=$(awk -v a="$EIGHT" -v b="$ONE" 'BEGIN { printf "%.2f", (b > 0 ? a / b : 99) }')
echo "Startup: 1 launch ${ONE}s, 8 in parallel ${EIGHT}s (ratio ${RATIO}x)"
if awk -v r="$RATIO" 'BEGIN { exit !(r > 3) }'; then
  echo "ERROR: eight launches cost ${RATIO}x one — they are serialising, as the onefile build did." >&2
  echo "       The tree is meant to keep stable inodes so macOS scans it once." >&2
  exit 1
fi

echo "yt-dlp $BUILT ready at $DEST ($(du -sh "$DEST" | cut -f1))"
