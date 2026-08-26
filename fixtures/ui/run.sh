#!/bin/bash
#
# Runs the UI-level fixtures: cases whose outcome is only visible in a process
# that renders.
#
#   ./run.sh                     # every case
#   ./run.sh --case <id>         # one case
#   DEPLOY=18.0 ./run.sh         # a different deployment target
#
# Why these are not in fixtures/run.sh: that harness is a console process, and
# what these measure needs SwiftUI's own rendering. `swiftui-body-direct-call`
# over there reads `body` directly and passes; it stayed green while the design
# document said two different wrong things about what happens on screen,
# because a direct read never touches the storage that aborts.
#
# Each case builds an application, installs it on the booted simulator, lets it
# run, delivers a patch into its Documents/Patches inbox, and then asks one
# question: is the process still beating.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${BUILD_DIR:-$ROOT/.build}"
MODULE=Fixture
BUNDLE_ID=dev.swift-splice.UIFixture

# The crash these pin needs the iOS 26 eraser. Below that `some View` erases to
# AnyView, which tolerates a type change, so a run at an older target is a
# different measurement and says so rather than failing.
DEPLOY="${DEPLOY:-$(xcrun --sdk iphonesimulator --show-sdk-version)}"
FILTER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --case) FILTER="$2"; shift 2 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)" || exit 1
TRIPLE="$(uname -m)-apple-ios$DEPLOY-simulator"

if ! xcrun simctl list devices booted | grep -q Booted; then
    echo "no booted simulator" >&2
    exit 1
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"

pass=0; fail=0; skip=0

for dir in "$ROOT"/Cases/*/; do
    id="$(basename "$dir")"
    [ -n "$FILTER" ] && [ "$id" != "$FILTER" ] && continue

    EXPECT=alive
    # The lowest deployment target the case says anything at. The abort needs
    # the iOS 26 eraser, so running it at 18 measures a different thing rather
    # than a regression -- it is skipped and named instead of failing.
    MIN_DEPLOY=""
    NOTE=""
    # shellcheck disable=SC1090
    [ -f "$dir/case.conf" ] && . "$dir/case.conf"

    if [ -n "$MIN_DEPLOY" ] && [ "$(printf '%s\n%s\n' "$MIN_DEPLOY" "$DEPLOY" | sort -V | head -1)" != "$MIN_DEPLOY" ]; then
        skip=$((skip + 1))
        printf '  \033[33mSKIP\033[0m  %-34s needs iOS %s or later\n' "$id" "$MIN_DEPLOY"
        continue
    fi

    out="$BUILD/$id"
    app="$out/$MODULE.app"
    mkdir -p "$app"
    verdict=""; detail=""

    if ! xcrun swiftc -parse-as-library \
            -target "$TRIPLE" -sdk "$SDK" \
            -Xclang-linker -isysroot -Xclang-linker "$SDK" \
            -Onone -enable-testing \
            -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports \
            -module-name "$MODULE" \
            -emit-module -emit-module-path "$out/$MODULE.swiftmodule" \
            -emit-executable -o "$app/$MODULE" \
            "$ROOT/Harness/Loader.swift" "$dir/App.swift" > "$out/app-build.log" 2>&1; then
        verdict=FAIL; detail="application build failed; see $out/app-build.log"
    fi

    if [ -z "$verdict" ]; then
        sed -e "s/@BUNDLE_ID@/$BUNDLE_ID/" "$ROOT/Info.plist" > "$app/Info.plist"
        if ! xcrun swiftc -Onone -target "$TRIPLE" -sdk "$SDK" \
                -emit-library -o "$out/Patch.dylib" -module-name Patch1 -I "$out" \
                "$dir/Patch.swift" \
                -Xlinker -undefined -Xlinker dynamic_lookup > "$out/patch-build.log" 2>&1; then
            verdict=FAIL; detail="patch build failed; see $out/patch-build.log"
        fi
    fi

    if [ -z "$verdict" ]; then
        xcrun simctl uninstall booted "$BUNDLE_ID" > /dev/null 2>&1
        xcrun simctl install booted "$app" > /dev/null 2>&1
        xcrun simctl launch booted "$BUNDLE_ID" > /dev/null 2>&1
        sleep 3

        data="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)"
        before="$(cat "$data/Documents/heartbeat" 2>/dev/null || echo "")"
        if [ -z "$before" ]; then
            verdict=FAIL; detail="the application never started beating"
        else
            mkdir -p "$data/Documents/Patches"
            cp "$out/Patch.dylib" "$data/Documents/Patches/Patch.dylib"

            # Sampled twice *after* the patch, not once against a reading from
            # before it. A crashing case still beats a few times between the
            # patch landing and the abort, so a single comparison against the
            # earlier value called a dead process alive.
            sleep 4
            first="$(cat "$data/Documents/heartbeat" 2>/dev/null || echo "")"
            sleep 3
            after="$(cat "$data/Documents/heartbeat" 2>/dev/null || echo "")"

            # The heartbeat, not the process list: a process that had already
            # aborted was still listed by launchctl, which would have let a
            # crashing case pass.
            if [ -n "$after" ] && [ "$after" != "$first" ]; then
                observed=alive
            else
                observed=crash
            fi
            detail="heartbeat $before -> $first -> ${after:-none}"

            if [ "$observed" = "$EXPECT" ]; then
                verdict=PASS
            else
                verdict=FAIL; detail="expected $EXPECT, observed $observed ($detail)"
            fi
        fi
        xcrun simctl terminate booted "$BUNDLE_ID" > /dev/null 2>&1
    fi

    if [ "$verdict" = PASS ]; then
        pass=$((pass + 1)); printf '  \033[32mPASS\033[0m  %-34s %s\n' "$id" "$detail"
    else
        fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %-34s %s\n' "$id" "$detail"
    fi
done

echo
summary="$pass passed, $fail failed"
[ "$skip" -gt 0 ] && summary="$summary, $skip skipped"
echo "$summary  (iOS $DEPLOY, $TRIPLE)"

if [ $((pass + fail + skip)) -eq 0 ]; then
    echo "no cases ran${FILTER:+ (--case $FILTER matched nothing)}" >&2
    exit 1
fi

[ "$fail" -eq 0 ]
