#!/bin/bash

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELECTOR="$ROOT/scripts/select-simulator-device.sh"
failures=0

expect() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        printf '  PASS  %s\n' "$name"
    else
        printf '  FAIL  %s -- expected %s, got %s\n' "$name" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

# Xcode betas can expose several runtime images with the same display version.
# Empty duplicate headings preceded the populated one on the machine that
# found this regression.
actual="$(bash "$SELECTOR" 27.0 <<'DEVICES'
== Devices ==
-- iOS 26.5 --
    iPhone 17 Pro (AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA) (Shutdown)
-- iOS 27.0 --
-- iOS 27.0 --
-- iOS 27.0 --
    iPhone 17 Pro (2A3A5E1C-D455-42F9-9DC1-B1FDD94BA59A) (Shutdown)
DEVICES
)"
expect "duplicate runtime headings" \
    "2A3A5E1C-D455-42F9-9DC1-B1FDD94BA59A" "$actual"

actual="$(bash "$SELECTOR" 27.0 <<'DEVICES'
== Devices ==
-- iOS 26.5 --
    iPhone 17 Pro (AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA) (Shutdown)
-- iOS 27.0 --
    iPad Pro (BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB) (Shutdown)
    iPhone 17 Pro (CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC) (Shutdown)
DEVICES
)"
expect "requested version and iPhone kind" \
    "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC" "$actual"

actual="$(bash "$SELECTOR" 27.0 <<'DEVICES'
== Devices ==
-- iOS 26.5 --
    iPhone 17 Pro (AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA) (Shutdown)
DEVICES
)"
expect "missing requested runtime" "" "$actual"

if [ "$failures" -ne 0 ]; then
    echo "$failures script test(s) failed" >&2
    exit 1
fi
echo "3 script tests passed"
