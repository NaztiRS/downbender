#!/usr/bin/env bash
# Builds the distributable DMG (branded window: app + Applications only) and
# the bare-app zip the in-app self-updater downloads.
#
# Needs create-dmg: brew install create-dmg
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v create-dmg > /dev/null; then
  echo "error: create-dmg missing — install with: brew install create-dmg" >&2
  exit 1
fi

./scripts/bundle.sh release

STAGE="$(mktemp -d)"
cp -R Downbender.app "$STAGE/"

rm -f Downbender.dmg
create-dmg \
  --volname "Downbender" \
  --volicon "Downbender.app/Contents/Resources/AppIcon.icns" \
  --background "docs/assets/dmg-background.tiff" \
  --window-pos 200 120 \
  --window-size 660 420 \
  --icon-size 128 \
  --icon "Downbender.app" 165 200 \
  --app-drop-link 495 200 \
  --hide-extension "Downbender.app" \
  Downbender.dmg "$STAGE"
echo "Created Downbender.dmg"

# Zip of the bare .app: the asset the in-app self-updater downloads and swaps in.
rm -f Downbender.zip
ditto -c -k --keepParent Downbender.app Downbender.zip
echo "Created Downbender.zip"
