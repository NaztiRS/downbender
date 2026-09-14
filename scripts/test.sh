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
TESTING_MACROS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

SWIFT_TEST_ARGS=(
  -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS"
  -Xlinker -framework -Xlinker Testing
)

# CLT 27 exposes Testing's macro declarations but no longer discovers the matching
# compiler plugin automatically. Loading it explicitly keeps @Test available while
# remaining compatible with earlier CLT releases where the library exists.
if [ -f "$TESTING_MACROS" ]; then
  SWIFT_TEST_ARGS+=(
    -Xswiftc -load-plugin-library
    -Xswiftc "$TESTING_MACROS"
  )
fi

exec swift test \
  "${SWIFT_TEST_ARGS[@]}" \
  "$@"
