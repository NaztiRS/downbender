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

DMG_WORK="$(mktemp -d)"
STAGE="$DMG_WORK/stage"
RW_DMG="$DMG_WORK/Downbender-rw.dmg"
MOUNT_DEVICE=""

cleanup() {
  if [ -n "$MOUNT_DEVICE" ]; then
    hdiutil detach "$MOUNT_DEVICE" >/dev/null 2>&1 || true
  fi
  rm -rf "$DMG_WORK"
}
trap cleanup EXIT

mkdir -p "$STAGE"
cp -R Downbender.app "$STAGE/"
cp docs/assets/dmg-background.tiff \
  "$STAGE/Downbender.app/Contents/Resources/DMGBackground.tiff"
codesign --force --sign - "$STAGE/Downbender.app"
codesign --verify --deep --strict "$STAGE/Downbender.app"

create-dmg \
  --volname "Downbender" \
  --window-pos 200 120 \
  --window-size 680 480 \
  --icon-size 128 \
  --text-size 13 \
  --icon "Downbender.app" 175 200 \
  --app-drop-link 505 200 \
  --hide-extension "Downbender.app" \
  --skip-finalize \
  "$RW_DMG" "$STAGE"

# Keep the Finder background inside the app bundle. This avoids the hidden
# top-level files that create-dmg normally pushes beyond the right edge, which
# expands Finder's icon canvas and leaves a scrollbar in the shipped DMG.
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen -nobrowse "$RW_DMG")"
MOUNT_DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/Apple_HFS/ {print $1; exit}')"
if [ -z "$MOUNT_DEVICE" ]; then
  echo "error: could not find the mounted DMG device" >&2
  exit 1
fi

osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "Downbender"
    open
    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set bounds to {200, 120, 880, 600}
    end tell
    set opts to icon view options of container window
    tell opts
      set arrangement to not arranged
      set icon size to 128
      set text size to 13
    end tell
    set background picture of opts to file "Downbender.app:Contents:Resources:DMGBackground.tiff"
    set position of item "Downbender.app" to {175, 200}
    set position of item "Applications" to {505, 200}
    set extension hidden of item "Downbender.app" to true
    close
  end tell
  delay 2
end tell
APPLESCRIPT

hdiutil detach "$MOUNT_DEVICE" >/dev/null
MOUNT_DEVICE=""

rm -f Downbender.dmg
hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o Downbender.dmg
echo "Created Downbender.dmg"

# Zip of the bare .app: the asset the in-app self-updater downloads and swaps in.
rm -f Downbender.zip
ditto -c -k --keepParent Downbender.app Downbender.zip
echo "Created Downbender.zip"
