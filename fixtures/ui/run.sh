#!/bin/bash
#
# Runs the UI-level fixtures: cases whose outcome is only visible in a process
# that renders.
#
#   ./run.sh                     # every case
#   ./run.sh --case <id>         # one case
#   DEPLOY=16.0 ./run.sh         # the supported deployment floor
#
# Why these are not in fixtures/run.sh: that harness is a console process, and
# what these measure needs SwiftUI's own rendering. `swiftui-body-direct-call`
# over there reads `body` directly and passes; it stayed green while the design
# document said two different wrong things about what happens on screen,
# because a direct read never touches the storage that aborts.
#
# Each case builds an application, installs it on the booted simulator, lets it
# run, and delivers a patch into its Documents/Patches inbox. It then checks
# whether the process is still beating and, where expected, what rendered.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${BUILD_DIR:-$ROOT/.build}"
MODULE=Fixture
BUNDLE_ID=dev.swift-ember.UIFixture
STARTUP_TIMEOUT_SECONDS=15

# Deployment selects the eraser. Below iOS 26, `some View` erases to AnyView.
# For cases that need DebugReplaceableView, MIN_DEPLOY sets the build floor.
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
RUNTIME="$(xcrun simctl getenv booted SIMULATOR_RUNTIME_VERSION 2>/dev/null)"
[ -n "$RUNTIME" ] || RUNTIME=unknown

version_at_least() {
    local version="$1" minimum="$2"
    [ "$(printf '%s\n%s\n' "$version" "$minimum" | sort -V | head -1)" = "$minimum" ]
}

wait_for_heartbeat() {
    local deadline data heartbeat
    deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))

    while :; do
        data="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)"
        if [ -n "$data" ]; then
            heartbeat="$(cat "$data/Documents/heartbeat" 2>/dev/null)"
            if [ -n "$heartbeat" ]; then
                printf '%s\n' "$data"
                return 0
            fi
        fi

        [ "$SECONDS" -ge "$deadline" ] && return 1
        sleep 1
    done
}

rm -rf "$BUILD"
mkdir -p "$BUILD"

# Build the optional adapter as its real two-module product, then link its
# objects into each tiny fixture application. Keeping the module boundary here
# catches an SPI or exported-import mistake that compiling the files beside a
# case in one module would hide.
adapter="$BUILD/EmberSwiftUI"
mkdir -p "$adapter"
runtime_sources=("$ROOT"/../../runtime/Sources/*.swift)
swiftui_sources=("$ROOT"/../../runtime/SwiftUI/*.swift)

if ! xcrun swiftc -parse-as-library -whole-module-optimization \
        -target "$TRIPLE" -sdk "$SDK" -Onone -D EMBER_ENABLED \
        -module-name EmberRuntime \
        -emit-module -emit-module-path "$adapter/EmberRuntime.swiftmodule" \
        -emit-object -o "$adapter/EmberRuntime.o" \
        "${runtime_sources[@]}" > "$adapter/runtime-build.log" 2>&1; then
    echo "EmberRuntime build failed; see $adapter/runtime-build.log" >&2
    exit 1
fi

if ! xcrun swiftc -parse-as-library -whole-module-optimization \
        -target "$TRIPLE" -sdk "$SDK" -Onone -D EMBER_ENABLED \
        -module-name EmberSwiftUI -I "$adapter" \
        -emit-module -emit-module-path "$adapter/EmberSwiftUI.swiftmodule" \
        -emit-object -o "$adapter/EmberSwiftUI.o" \
        "${swiftui_sources[@]}" > "$adapter/swiftui-build.log" 2>&1; then
    echo "EmberSwiftUI build failed; see $adapter/swiftui-build.log" >&2
    exit 1
fi

pass=0; fail=0; skip=0

for dir in "$ROOT"/Cases/*/; do
    id="$(basename "$dir")"
    [ -n "$FILTER" ] && [ "$id" != "$FILTER" ] && continue

    EXPECT=alive
    EXPECT_REGISTERED=""
    EXPECT_RENDERED_PREFIX=""
    PRESERVE_RENDERED_SUFFIX=no
    MIN_DEPLOY=""
    ALIVE_FROM_RUNTIME=""
    # shellcheck source=/dev/null
    [ -f "$dir/case.conf" ] && . "$dir/case.conf"

    if [ -n "$MIN_DEPLOY" ] && ! version_at_least "$DEPLOY" "$MIN_DEPLOY"; then
        skip=$((skip + 1))
        printf '  \033[33mSKIP\033[0m  %-34s needs deployment target iOS %s or later\n' "$id" "$MIN_DEPLOY"
        continue
    fi

    if [ -n "$ALIVE_FROM_RUNTIME" ]; then
        if [ "$RUNTIME" = unknown ]; then
            fail=$((fail + 1))
            printf '  \033[31mFAIL\033[0m  %-34s cannot select expectation without the iOS runtime version\n' "$id"
            continue
        fi
        if version_at_least "$RUNTIME" "$ALIVE_FROM_RUNTIME"; then
            EXPECT=alive
        fi
    fi

    out="$BUILD/$id"
    app="$out/$MODULE.app"
    mkdir -p "$app"
    verdict=""; detail=""

    if ! xcrun swiftc -parse-as-library \
            -target "$TRIPLE" -sdk "$SDK" \
            -Xclang-linker -isysroot -Xclang-linker "$SDK" \
            -Onone -enable-testing \
            -D EMBER_ENABLED \
            -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports \
            -module-name "$MODULE" \
            -I "$adapter" \
            -emit-module -emit-module-path "$out/$MODULE.swiftmodule" \
            -emit-executable -o "$app/$MODULE" \
            "$adapter/EmberRuntime.o" "$adapter/EmberSwiftUI.o" \
            "$ROOT/Harness/Loader.swift" \
            "$ROOT/../../runtime/Sources/RegisteredReplacements.swift" \
            "$dir/App.swift" > "$out/app-build.log" 2>&1; then
        verdict=FAIL; detail="application build failed; see $out/app-build.log"
    fi

    if [ -z "$verdict" ]; then
        sed -e "s/@BUNDLE_ID@/$BUNDLE_ID/" "$ROOT/Info.plist" > "$app/Info.plist"
        if ! xcrun swiftc -Onone -target "$TRIPLE" -sdk "$SDK" \
                -emit-library -o "$out/Patch.dylib" -module-name Patch1 \
                -I "$out" -I "$adapter" \
                "$dir/Patch.swift" \
                -Xlinker -undefined -Xlinker dynamic_lookup > "$out/patch-build.log" 2>&1; then
            verdict=FAIL; detail="patch build failed; see $out/patch-build.log"
        fi
    fi

    if [ -z "$verdict" ]; then
        xcrun simctl uninstall booted "$BUNDLE_ID" > /dev/null 2>&1
        install_output=""
        launch_output=""
        if ! install_output="$(xcrun simctl install booted "$app" 2>&1)"; then
            verdict=FAIL; detail="application install failed: ${install_output:-no diagnostic}"
        elif ! launch_output="$(xcrun simctl launch booted "$BUNDLE_ID" 2>&1)"; then
            verdict=FAIL; detail="application launch failed: ${launch_output:-no diagnostic}"
        elif ! data="$(wait_for_heartbeat)"; then
            verdict=FAIL
            detail="application did not start beating within ${STARTUP_TIMEOUT_SECONDS}s (${launch_output:-launch returned no output})"
        fi

        before=""
        rendered_before=""
        if [ -z "$verdict" ]; then
            before="$(cat "$data/Documents/heartbeat" 2>/dev/null || echo "")"
            rendered_before="$(cat "$data/Documents/rendered" 2>/dev/null || echo "")"
        fi
        if [ -z "$verdict" ]; then
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
            rendered_after="$(cat "$data/Documents/rendered" 2>/dev/null || echo "")"
            registered="$(cat "$data/Documents/registered" 2>/dev/null || echo "")"

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
                verdict=FAIL; detail="observed $observed ($detail)"
            fi

            if [ "$verdict" = PASS ] && [ -n "$EXPECT_REGISTERED" ] && [ "$registered" != "$EXPECT_REGISTERED" ]; then
                verdict=FAIL
                detail="expected $EXPECT_REGISTERED registered replacements, observed ${registered:-none}"
            fi

            if [ "$verdict" = PASS ] && [ "$EXPECT" = alive ] && [ -n "$EXPECT_RENDERED_PREFIX" ]; then
                case "$rendered_after" in
                    "$EXPECT_RENDERED_PREFIX"*) ;;
                    *) verdict=FAIL; detail="expected rendered prefix '$EXPECT_RENDERED_PREFIX', observed '${rendered_after:-none}'" ;;
                esac
            fi

            if [ "$verdict" = PASS ] && [ "$PRESERVE_RENDERED_SUFFIX" = yes ]; then
                before_suffix="${rendered_before#*|}"
                after_suffix="${rendered_after#*|}"
                if [ -z "$rendered_before" ] || [ "$before_suffix" != "$after_suffix" ]; then
                    verdict=FAIL
                    detail="rendered state changed: '${rendered_before:-none}' -> '${rendered_after:-none}'"
                fi
            fi

            [ "$verdict" = PASS ] && detail="$detail, rendered '${rendered_before:-none}' -> '${rendered_after:-none}', registered ${registered:-none}"
        fi
        xcrun simctl terminate booted "$BUNDLE_ID" > /dev/null 2>&1
    fi

    if [ "$verdict" = PASS ]; then
        pass=$((pass + 1)); printf '  \033[32mPASS\033[0m  %-34s expected %s, %s\n' "$id" "$EXPECT" "$detail"
    else
        fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %-34s expected %s, %s\n' "$id" "$EXPECT" "$detail"
    fi
done

echo
summary="$pass passed, $fail failed"
[ "$skip" -gt 0 ] && summary="$summary, $skip skipped"
echo "$summary  (deployment target iOS $DEPLOY, runtime iOS $RUNTIME, $TRIPLE)"

if [ $((pass + fail + skip)) -eq 0 ]; then
    echo "no cases ran${FILTER:+ (--case $FILTER matched nothing)}" >&2
    exit 1
fi

[ "$fail" -eq 0 ]
