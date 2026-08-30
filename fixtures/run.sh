#!/bin/bash
#
# Runs the dynamic replacement fixture matrix and reports pass/fail per case.
#
#   ./run.sh                            # macOS host
#   ./run.sh --platform simulator       # booted arm64 iOS Simulator
#   ./run.sh --case actor-method        # one case
#   ./run.sh --results results-macos.yaml   # also write the machine-readable matrix
#
# Each case directory holds App.swift, one or more patch sources, an
# expected.txt of exact stdout, and an optional case.conf of overrides.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${BUILD_DIR:-$ROOT/.build}"
MODULE=Fixture

PLATFORM=macos
TRIPLE=""
SDK=""
FILTER=""
RESULTS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORM="$2"; shift 2 ;;
        --triple)   TRIPLE="$2";   shift 2 ;;
        --sdk)      SDK="$2";      shift 2 ;;
        --case)     FILTER="$2";   shift 2 ;;
        --results)  RESULTS="$2";  shift 2 ;;
        -h|--help)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done

case "$PLATFORM" in
    macos)
        SDK="${SDK:-macosx}"
        TRIPLE="${TRIPLE:-$(uname -m)-apple-macosx$(sw_vers -productVersion | cut -d. -f1).0}"
        spawn() { "$@"; }
        ;;
    simulator)
        SDK="${SDK:-iphonesimulator}"
        TRIPLE="${TRIPLE:-$(uname -m)-apple-ios$(xcrun --sdk "$SDK" --show-sdk-version)-simulator}"
        spawn() { xcrun simctl spawn booted "$@"; }
        ;;
    *) echo "unknown platform: $PLATFORM" >&2; exit 64 ;;
esac

SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)" || exit 1
SWIFT_VERSION="$(xcrun swiftc --version 2>/dev/null | head -1)"
XCODE_PATH="$(xcode-select -p)"

# Every case's configuration is checked before any case is built.
#
# Two reasons it is a pass of its own. A bad value used to be found only when
# the loop reached that case, so a typo in the last one threw away the whole
# matrix and left a stale results file behind. And validating a value that is
# present is not the same as requiring one: `PLATFORMS=""` passed the old
# check, matched no platform, was skipped everywhere, and the run still exited
# 0 -- the exact hole this validation exists to close.
for dir in "$ROOT"/Cases/*/; do
    [ -f "$dir/case.conf" ] || continue
    (
        id="$(basename "$dir")"
        PLATFORMS="macos simulator"
        EXTRA_SOURCES=""
        HARNESS_SOURCE="Harness/Harness.swift"
        # shellcheck disable=SC1090
        . "$dir/case.conf"
        [ -n "$PLATFORMS" ] || { echo "$id: PLATFORMS is empty" >&2; exit 64; }
        for name in $PLATFORMS; do
            case "$name" in
                macos|simulator) ;;
                *) echo "$id: unknown platform in PLATFORMS: $name" >&2; exit 64 ;;
            esac
        done
        for source in $EXTRA_SOURCES; do
            [ -f "$ROOT/../$source" ] || {
                echo "$id: EXTRA_SOURCES names a file that does not exist: $source" >&2
                exit 64
            }
        done
        [ -f "$ROOT/$HARNESS_SOURCE" ] || {
            echo "$id: HARNESS_SOURCE names a file that does not exist: $HARNESS_SOURCE" >&2
            exit 64
        }
    ) || exit 64
done

rm -rf "$BUILD"
mkdir -p "$BUILD"

pass=0; fail=0; skip=0; report=""

for dir in "$ROOT"/Cases/*/; do
    id="$(basename "$dir")"
    [ -n "$FILTER" ] && [ "$id" != "$FILTER" ] && continue

    SUPPORTED=yes
    KIND=replace
    PATCHES="Patch.swift"
    # Which platforms the case can build on. A UIKit case has nothing to say on
    # the host, and skipping is not the same as passing: a skipped case is
    # counted and named so a run cannot quietly cover less than it appears to.
    PLATFORMS="macos simulator"
    # Sources compiled into the application alongside App.swift, relative to
    # the repository root. One case uses it to run the runtime's own reader
    # against a real loaded image rather than against a description of one.
    EXTRA_SOURCES=""
    # Most cases use the generation-at-a-time driver. A concurrency fixture
    # can replace it when the event under test has to straddle patch loading.
    HARNESS_SOURCE="Harness/Harness.swift"
    APP_TESTABILITY=yes
    APP_PRIVATE_IMPORTS=yes
    STATE_PRESERVED=no
    EXPECT_COMPILE_ERROR=""
    EXPECT_SIGNAL=""
    NOTE=""
    observed=""
    # shellcheck disable=SC1090
    [ -f "$dir/case.conf" ] && . "$dir/case.conf"

    case " $PLATFORMS " in
        *" $PLATFORM "*) ;;
        *)
            skip=$((skip + 1))
            printf '  \033[33mSKIP\033[0m  %s -- %s only\n' "$id" "$PLATFORMS"
            report="$report  - id: $id
    supported: $([ "$SUPPORTED" = yes ] && echo true || echo false)
    kind: $KIND
    result: skipped
    platforms: \"$PLATFORMS\"
"
            continue
            ;;
    esac

    out="$BUILD/$id"
    mkdir -p "$out"
    verdict=""; detail=""

    testflag=()
    [ "$APP_TESTABILITY" = yes ] && testflag=(-enable-testing)

    # A patch reaches a `private` declaration only if the module it imports was
    # built for private imports. On by default so the ordinary cases have it;
    # `no-private-imports-rejected` turns it off to pin how that fails.
    privflag=()
    [ "$APP_PRIVATE_IMPORTS" = yes ] && privflag=(-Xfrontend -enable-private-imports)

    # The runtime's sources are compiled out without this, so a case that
    # borrows one gets it. Cases that do not borrow anything are unaffected:
    # nothing else in Cases/ mentions the flag.
    extra=()
    if [ -n "$EXTRA_SOURCES" ]; then
        extra=(-D EMBER_ENABLED)
        for source in $EXTRA_SOURCES; do extra+=("$ROOT/../$source"); done
    fi

    if ! xcrun swiftc -parse-as-library -Onone \
            -target "$TRIPLE" -sdk "$SDKROOT" \
            ${testflag[@]+"${testflag[@]}"} \
            ${privflag[@]+"${privflag[@]}"} \
            ${extra[@]+"${extra[@]}"} \
            -Xfrontend -enable-implicit-dynamic \
            -module-name "$MODULE" \
            -emit-module -emit-module-path "$out/$MODULE.swiftmodule" \
            -emit-executable -o "$out/app" \
            "$ROOT/$HARNESS_SOURCE" "$dir/App.swift" > "$out/app-build.log" 2>&1; then
        verdict=FAIL; detail="application build failed; see $out/app-build.log"
    fi

    dylibs=()
    if [ -z "$verdict" ]; then
        n=0
        for patch in $PATCHES; do
            n=$((n + 1))
            lib="$out/patch$n.dylib"
            if xcrun swiftc -Onone \
                    -target "$TRIPLE" -sdk "$SDKROOT" \
                    -emit-library -o "$lib" \
                    -module-name "Patch$n" -I "$out" "$dir/$patch" \
                    -Xlinker -undefined -Xlinker dynamic_lookup \
                    > "$out/patch$n-build.log" 2>&1; then
                dylibs+=("$lib")
                if [ "$KIND" = reject-compile ]; then
                    verdict=FAIL; detail="patch compiled but the case expects rejection"
                    break
                fi
            else
                if [ "$KIND" = reject-compile ]; then
                    if grep -qF "$EXPECT_COMPILE_ERROR" "$out/patch$n-build.log"; then
                        verdict=PASS
                        detail="rejected at COMPILE: $(grep -m1 -o "error:.*" "$out/patch$n-build.log")"
                    else
                        verdict=FAIL
                        detail="rejected, but not with the expected diagnostic '$EXPECT_COMPILE_ERROR'"
                    fi
                else
                    verdict=FAIL; detail="patch build failed; see $out/patch$n-build.log"
                fi
                break
            fi
        done
    fi

    if [ -z "$verdict" ]; then
        spawn "$out/app" ${dylibs[@]+"${dylibs[@]}"} > "$out/actual.txt" 2> "$out/stderr.txt"
        status=$?
        sed -i '' "s|$out|@BUILD@|g" "$out/actual.txt"

        signal=""
        [ $status -gt 128 ] && signal=$((status - 128))

        if [ "$KIND" = unsafe ]; then
            # The outcome is undefined, so record it rather than assert it.
            if [ -n "$signal" ]; then
                observed="signal $signal"
            else
                observed="exit $status; $(tr '\n' ' ' < "$out/actual.txt" | sed 's/ *$//')"
            fi
            verdict=PASS; detail="undefined behavior, observed: $observed"
        elif [ "$KIND" = crash ]; then
            if [ "$signal" = "$EXPECT_SIGNAL" ]; then
                verdict=PASS; detail="crashed with signal $signal as expected"
            else
                verdict=FAIL; detail="expected signal $EXPECT_SIGNAL, got exit status $status"
            fi
        elif [ $status -ne 0 ]; then
            verdict=FAIL; detail="exited with status $status"
            if [ $status -eq 70 ]; then
                timeout_detail="$(grep -m1 '^fixture-timeout:' "$out/actual.txt")"
                [ -n "$timeout_detail" ] && detail="$detail; $timeout_detail"
            fi
        elif diff -q "$dir/expected.txt" "$out/actual.txt" > /dev/null; then
            verdict=PASS
        else
            verdict=FAIL
            detail="output mismatch"
            diff -u "$dir/expected.txt" "$out/actual.txt" > "$out/diff.txt"
        fi
    fi

    if [ "$verdict" = PASS ]; then
        pass=$((pass + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$id"
    else
        fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s -- %s\n' "$id" "$detail"
        [ -f "$out/diff.txt" ] && sed 's/^/        /' "$out/diff.txt"
    fi

    report="$report  - id: $id
    supported: $([ "$SUPPORTED" = yes ] && echo true || echo false)
    kind: $KIND
    state_preserved: $([ "$STATE_PRESERVED" = yes ] && echo true || echo false)
    result: $(echo "$verdict" | tr 'A-Z' 'a-z')
"
    [ -n "$observed" ] && report="$report    observed: \"$observed\"
"
    [ -n "$NOTE" ] && report="$report    note: \"$NOTE\"
"
done

echo
summary="$pass passed, $fail failed"
[ "$skip" -gt 0 ] && summary="$summary, $skip skipped"
echo "$summary  ($PLATFORM, $TRIPLE)"

# A run that matched no cases used to exit 0, so a renamed directory or a
# filter with a typo was indistinguishable from a clean pass.
if [ $((pass + fail + skip)) -eq 0 ]; then
    echo "no cases ran${FILTER:+ (--case $FILTER matched nothing)}" >&2
    exit 1
fi

# Asking for one case by name and having it skipped is not a pass. The whole
# run reporting success when the one thing requested never executed is the
# shape of failure this script refuses everywhere else.
if [ -n "$FILTER" ] && [ $((pass + fail)) -eq 0 ]; then
    echo "--case $FILTER was skipped on $PLATFORM and nothing ran" >&2
    exit 1
fi

if [ -n "$RESULTS" ]; then
    {
        echo "# Generated by fixtures/run.sh. Do not edit by hand."
        echo "toolchain:"
        echo "  xcode_path: \"$XCODE_PATH\""
        echo "  swift: \"$SWIFT_VERSION\""
        echo "  target: \"$TRIPLE\""
        echo "  sdk: \"$SDK\""
        echo "platform: $PLATFORM"
        echo "cases:"
        printf '%s' "$report"
    } > "$RESULTS"
    echo "wrote $RESULTS"
fi

[ "$fail" -eq 0 ]
