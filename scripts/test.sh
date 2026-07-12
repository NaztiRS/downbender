#!/bin/bash
# Runs the test suite in an environment with only Command Line Tools (no Xcode).
#
# A plain `swift test` compiles but silently RUNS 0 TESTS: SPM passes -I instead
# of -F for Testing.framework and `canImport(Testing)` is false without warning.
# These flags force the CLT framework into the test runner.
#
# Usage: scripts/test.sh [extra swift test args, e.g. --filter TestName]
set -euo pipefail
cd "$(dirname "$0")/.."

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

exec swift test \
  -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" \
  -Xlinker -framework -Xlinker Testing \
  "$@"
