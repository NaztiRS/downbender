#!/usr/bin/env bash
# Builds the Safari extension template that ships zipped inside Downbender.app. Downbender
# extracts, signs and registers it at install time, so the zip itself is never discoverable.
# Usage: scripts/build-safari-extension.sh OUTPUT_ZIP
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT="${1:?usage: scripts/build-safari-extension.sh OUTPUT_ZIP}"
VERSION=$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' Sources/DownbenderCore/Version.swift)
SDK="$(xcrun --sdk macosx --show-sdk-path)"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Downbender for Safari.app"
EXTENSION="$APP/Contents/PlugIns/DownbenderSafariExtension.appex"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXTENSION/Contents/MacOS" "$EXTENSION/Contents/Resources"

SWIFT_FLAGS=(-swift-version 6 -O -sdk "$SDK" -target arm64-apple-macos26.0)
xcrun swiftc "${SWIFT_FLAGS[@]}" SafariExtension/Container/main.swift -o "$APP/Contents/MacOS/DownbenderSafari"
# The router is shared with DownbenderCore and only depends on BrowserBridge.
xcrun swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -application-extension \
  -module-name DownbenderSafariExtension -Xlinker -e -Xlinker _NSExtensionMain \
  Sources/DownbenderCore/Services/BrowserBridge.swift \
  Sources/DownbenderCore/Safari/SafariRequestRouter.swift \
  SafariExtension/Extension/SafariWebExtensionHandler.swift \
  -o "$EXTENSION/Contents/MacOS/DownbenderSafariExtension"

cp SafariExtension/Container/Info.plist "$APP/Contents/Info.plist"
cp SafariExtension/Extension/Info.plist "$EXTENSION/Contents/Info.plist"
for BUNDLE in "$APP" "$EXTENSION"; do
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$BUNDLE/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$BUNDLE/Contents/Info.plist"
  plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null
done
node scripts/prepare-safari-extension.js "$EXTENSION/Contents/Resources"

ICONSET="$STAGING/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" docs/assets/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  sips -z "$((SIZE * 2))" "$((SIZE * 2))" docs/assets/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET" --output "$APP/Contents/Resources/AppIcon.icns"
cp "$APP/Contents/Resources/AppIcon.icns" "$EXTENSION/Contents/Resources/AppIcon.icns"

# Ad hoc here; Downbender re-signs the extracted copy in the mode the user chooses.
for BUNDLE in "$EXTENSION" "$APP"; do
  codesign --force --sign - --entitlements SafariExtension/Sandbox.entitlements "$BUNDLE"
done
codesign --verify --deep --strict "$APP"

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
ditto -c -k --keepParent "$APP" "$OUTPUT"
echo "Built $OUTPUT"
