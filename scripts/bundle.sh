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

for b in yt-dlp_macos ffmpeg ffprobe deno; do
  if [ -f "Resources/binaries/$b" ]; then
    cp "Resources/binaries/$b" "$APP/Contents/Resources/$b"
    chmod +x "$APP/Contents/Resources/$b"
  else
    echo "WARNING: missing Resources/binaries/$b"
  fi
done

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
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 64 128 256 512; do
    sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil --convert icns "$ICONSET" --output "$APP/Contents/Resources/AppIcon.icns"
fi

for b in yt-dlp_macos ffmpeg ffprobe deno; do
  [ -f "$APP/Contents/Resources/$b" ] && codesign --force --sign - "$APP/Contents/Resources/$b"
done
codesign --force --sign - "$APP/Contents/MacOS/downbender-native-host"
codesign --force --sign - "$APP"
echo "Built $APP"
