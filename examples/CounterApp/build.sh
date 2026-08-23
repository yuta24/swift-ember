#!/bin/bash
#
# Builds the M1 sample app, installs it on the booted simulator, and launches it.
#
#   ./build.sh              instrumented for hot reload (the default)
#   ./build.sh --release    without instrumentation, to check Release isolation
#
# The bundle is assembled by hand rather than by an Xcode project so that every
# flag the design documents care about is visible in one place. Real projects
# get these through xcconfig; see DESIGN.md section 5.2.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MODULE=CounterApp
BUNDLE_ID=dev.swift-splice.CounterApp

CONFIG=debug
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=release ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 64 ;;
    esac
done

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TRIPLE="arm64-apple-ios$(xcrun --sdk iphonesimulator --show-sdk-version)-simulator"
OUT="$ROOT/.build/$CONFIG"
APP="$OUT/$MODULE.app"

rm -rf "$OUT"
mkdir -p "$APP"

sources=("$ROOT"/Sources/*.swift "$ROOT"/Runtime/*.swift)

if [ "$CONFIG" = debug ]; then
    # The three settings that make hot reload possible. -enable-testing is not
    # optional: without it the dynamic replacement keys stay hidden and a patch
    # cannot bind to them. See DESIGN.md section 5.4.
    flags=(-Onone
           -enable-testing
           -Xfrontend -enable-implicit-dynamic
           -D SPLICE_ENABLED)
else
    flags=(-O)
fi

xcrun swiftc -parse-as-library \
    -target "$TRIPLE" -sdk "$SDK" \
    -Xclang-linker -isysroot -Xclang-linker "$SDK" \
    "${flags[@]}" \
    -module-name "$MODULE" \
    -emit-module -emit-module-path "$OUT/$MODULE.swiftmodule" \
    -emit-executable -o "$APP/$MODULE" \
    "${sources[@]}"

cp "$ROOT/Info.plist" "$APP/Info.plist"

keys=$(xcrun nm -gU "$APP/$MODULE" | grep -c 'Tx$' || true)
echo "configuration      $CONFIG"
echo "replacement keys   $keys exported"

if [ "$CONFIG" = release ]; then
    # DESIGN.md section 5.3: a Release build must not be reloadable at all.
    if [ "$keys" -ne 0 ]; then
        echo "FAIL: release build exported $keys replacement keys" >&2
        exit 1
    fi
    if xcrun nm "$APP/$MODULE" | grep -q 'Splice'; then
        echo "FAIL: release build contains the reload runtime" >&2
        exit 1
    fi
    echo "release isolation  OK (no keys, no runtime)"
fi

xcrun simctl install booted "$APP"
xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch booted "$BUNDLE_ID"
