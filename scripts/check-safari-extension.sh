#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node --check SafariExtension/background.js
node --check scripts/prepare-safari-extension.js
node --test Tests/SafariExtensionTests/ResourcesTests.js
scripts/build-safari-extension.sh .build/safari-check/DownbenderSafari.zip
