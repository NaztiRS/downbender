#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bundle.sh release
STAGE="$(mktemp -d)"
cp -R Downbender.app "$STAGE/"
cp LICENSE NOTICE "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f Downbender.dmg
hdiutil create -volname "Downbender" -srcfolder "$STAGE" -ov -format UDZO Downbender.dmg
echo "Created Downbender.dmg"

# Zip of the bare .app: the asset the in-app self-updater downloads and swaps in.
rm -f Downbender.zip
ditto -c -k --keepParent Downbender.app Downbender.zip
echo "Created Downbender.zip"
