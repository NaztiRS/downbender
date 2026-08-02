#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
# Single source of truth for the app version: Version.swift.
VERSION=$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' Sources/DownbenderCore/Version.swift)
# Public identity and internals both say "downbender" (renamed for the
# public release; the old Application Support folder is intentionally abandoned).
APP="Downbender.app"
BIN_NAME="downbender"
BUNDLE_ID="com.naztirs.downbender"

swift build -c "$CONFIG"
BIN_PATH=".build/$CONFIG/$BIN_NAME"
HOST_PATH=".build/$CONFIG/downbender-native-host"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp "$HOST_PATH" "$APP/Contents/MacOS/downbender-native-host"
chmod +x "$APP/Contents/MacOS/downbender-native-host"

# GPL compliance travels inside the bundle, keeping the DMG window clean.
cp LICENSE NOTICE "$APP/Contents/Resources/"
cp -R ChromeExtension "$APP/Contents/Resources/ChromeExtension"

for b in ffmpeg ffprobe deno; do
  if [ -f "Resources/binaries/$b" ]; then
    cp "Resources/binaries/$b" "$APP/Contents/Resources/$b"
    chmod +x "$APP/Contents/Resources/$b"
  else
    echo "WARNING: missing Resources/binaries/$b"
  fi
done

# yt-dlp travels as its extracted directory (scripts/build-ytdlp.sh). The self-extracting single
# file unpacked 104 Mach-O files to a new temporary directory on every launch, and macOS rescans
# each unseen one through a single serial service, so launches could not run in parallel.
if [ -d "Resources/binaries/yt-dlp" ]; then
  cp -R "Resources/binaries/yt-dlp" "$APP/Contents/Resources/yt-dlp"
  chmod +x "$APP/Contents/Resources/yt-dlp/yt-dlp"
else
  echo "WARNING: missing Resources/binaries/yt-dlp (run scripts/build-ytdlp.sh)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$BIN_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Downbender</string>
  <key>CFBundleDisplayName</key><string>Downbender</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.naztirs.downbender.add</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array><string>downbender</string></array>
    </dict>
  </array>
  <key>NSAppTransportSecurity</key>
  <dict>
    <!-- Downbender is a general download tool: users paste http mirrors (SourceForge, uni
         mirrors). We allow http but confirm each insecure download in-app first. -->
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
</dict></plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

# All repo images live in docs/assets (single home; Resources/ holds only fetched binaries).
ICON_SRC="docs/assets/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
  # Raw copy of the PNG (circle with transparent corners) to show it in the UI
  # (empty state) without the "tile" macOS adds to applicationIconImage.
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.png"
  ICON_TMP="$(mktemp -d)"
  ICONSET="$ICON_TMP/AppIcon.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil --convert icns "$ICONSET" --output "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICON_TMP"
fi

MENU_BAR_ICON_SRC="docs/assets/AppIcon.svg"
if [ -f "$MENU_BAR_ICON_SRC" ]; then
  cp "$MENU_BAR_ICON_SRC" "$APP/Contents/Resources/DownbenderMenuBar.svg"
fi

for b in ffmpeg ffprobe deno; do
  [ -f "$APP/Contents/Resources/$b" ] && codesign --force --sign - "$APP/Contents/Resources/$b"
done
# Nested code has to carry its own signature before the app seals its resources: the framework
# as a bundle first, then every remaining loose Mach-O in the tree.
if [ -d "$APP/Contents/Resources/yt-dlp" ]; then
  find "$APP/Contents/Resources/yt-dlp" -type d -name "*.framework" -print0 |
    while IFS= read -r -d '' framework; do
      codesign --force --sign - "$framework"
    done
  find "$APP/Contents/Resources/yt-dlp" -type f -path "*.framework/*" -prune -o -type f -print0 |
    while IFS= read -r -d '' file; do
      case "$(file -b "$file")" in
      *Mach-O*) codesign --force --sign - "$file" ;;
      esac
    done
fi
codesign --force --sign - "$APP/Contents/MacOS/downbender-native-host"
codesign --force --sign - "$APP"
echo "Built $APP"
