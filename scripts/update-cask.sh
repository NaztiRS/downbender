#!/usr/bin/env bash
# Syncs the Homebrew cask with the published GitHub release: downloads the
# DMG actually being served, recomputes its sha256 and pushes the bump to
# NaztiRS/homebrew-tap.
#
# scripts/release.sh runs this at the end; run it standalone if that step
# ever fails or the cask drifts from the release.
#
# Usage: scripts/update-cask.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' Sources/DownbenderCore/Version.swift)
URL="https://github.com/NaztiRS/downbender/releases/download/v$VERSION/Downbender.dmg"

WORK=$(mktemp -d)
echo "Hashing the published asset for v$VERSION..."
curl -fsSL -o "$WORK/Downbender.dmg" "$URL"
SHA256=$(shasum -a 256 "$WORK/Downbender.dmg" | cut -d' ' -f1)

git clone -q --depth 1 "https://github.com/NaztiRS/homebrew-tap.git" "$WORK/tap"
sed -i '' \
  -e "s/version \".*\"/version \"$VERSION\"/" \
  -e "s/sha256 \".*\"/sha256 \"$SHA256\"/" \
  "$WORK/tap/Casks/downbender.rb"

if git -C "$WORK/tap" diff --quiet; then
  echo "Cask already up to date ($VERSION)."
  exit 0
fi
git -C "$WORK/tap" -c user.name="Rey" -c user.email="reynaldosuarezprieto@gmail.com" \
  commit -aqm "downbender $VERSION"
git -C "$WORK/tap" push -q origin main
echo "Homebrew cask bumped to $VERSION ($SHA256)"
