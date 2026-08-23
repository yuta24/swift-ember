#!/bin/bash
#
# The M1 walkthrough, end to end:
#
#   build and launch -> capture -> compile and deliver patches -> capture
#
# Compare the two screenshots. The session token must be identical in both,
# which is what proves the process was never restarted, while the two rows
# under "Patched output" must have changed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID=dev.swift-splice.CounterApp
SHOTS="${SHOTS_DIR:-$ROOT/.build/demo}"

mkdir -p "$SHOTS"

echo "==> building and launching"
"$ROOT/build.sh" > /dev/null
sleep 3

# Start from an empty inbox so the run is repeatable.
DATA="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data)"
rm -f "$DATA/Documents/Patches"/*.dylib 2>/dev/null || true
xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch booted "$BUNDLE_ID" > /dev/null
sleep 3

xcrun simctl io booted screenshot "$SHOTS/before.png" > /dev/null 2>&1
echo "==> captured $SHOTS/before.png"

echo "==> patching"
"$ROOT/patch.sh" Patches/Patch1.swift Patches/Patch2.swift
sleep 2

xcrun simctl io booted screenshot "$SHOTS/after.png" > /dev/null 2>&1
echo "==> captured $SHOTS/after.png"

cat <<'EXPECTED'

Expected difference, with the session token unchanged:

  Subtotal   775 cents  ->  $7.75 across 2 item(s)
  Discount   none       ->  spend $10 to unlock
EXPECTED
