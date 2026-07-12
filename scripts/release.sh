#!/usr/bin/env bash
# Cuts a release end to end: checks the tree, runs the tests, builds the DMG
# and the self-updater zip, tags vX.Y.Z and publishes the GitHub release.
#
# The version comes from Sources/DownbenderCore/Version.swift — bump it there
# (and commit) before running this.
#
# Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' Sources/DownbenderCore/Version.swift)
TAG="v$VERSION"

if [ -z "$VERSION" ]; then
  echo "error: could not read the version from Version.swift" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "error: the working tree is not clean — commit or stash first" >&2
  exit 1
fi
if [ "$(git branch --show-current)" != "main" ]; then
  echo "error: releases are cut from main" >&2
  exit 1
fi
if gh release view "$TAG" > /dev/null 2>&1; then
  echo "error: release $TAG already exists — bump Version.swift first" >&2
  exit 1
fi

echo "Releasing Downbender $VERSION"
scripts/test.sh
scripts/make-dmg.sh

git tag "$TAG"
git push origin main "$TAG"

# Assets go up one at a time: batching them has hit upload timeouts before.
gh release create "$TAG" --title "Downbender $VERSION" --generate-notes --draft
gh release upload "$TAG" Downbender.dmg --clobber
gh release upload "$TAG" Downbender.zip --clobber
gh release edit "$TAG" --draft=false

# Point the Homebrew tap at the new version so `brew install` serves it.
SHA256=$(shasum -a 256 Downbender.dmg | cut -d' ' -f1)
TAP=$(mktemp -d)
git clone -q --depth 1 "https://github.com/NaztiRS/homebrew-tap.git" "$TAP"
sed -i '' \
  -e "s/version \".*\"/version \"$VERSION\"/" \
  -e "s/sha256 \".*\"/sha256 \"$SHA256\"/" \
  "$TAP/Casks/downbender.rb"
git -C "$TAP" -c user.name="Rey" -c user.email="reynaldosuarezprieto@gmail.com" \
  commit -aqm "downbender $VERSION"
git -C "$TAP" push -q origin main
echo "Homebrew tap bumped to $VERSION"

echo "Release $TAG published: $(gh release view "$TAG" --json url --jq .url)"
