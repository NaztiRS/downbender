#!/bin/bash
# Runs SwiftFormat (lint mode) and SwiftLint over the whole package.
#
# Usage: scripts/lint.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swiftformat > /dev/null || ! command -v swiftlint > /dev/null; then
  echo "error: missing linters — install with: brew install swiftformat swiftlint" >&2
  exit 1
fi

swiftformat --lint .

# Without Xcode, SwiftLint must be pointed at the CLT copy of SourceKit or it
# aborts with "Loading sourcekitdInProc.framework ... failed".
if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
  export XCODE_DEFAULT_TOOLCHAIN_OVERRIDE="/Library/Developer/CommandLineTools"
fi
swiftlint --strict --quiet
