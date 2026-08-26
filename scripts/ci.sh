#!/bin/bash
#
# Everything CI runs, in one script that also runs locally.
#
#   scripts/ci.sh                     everything
#   scripts/ci.sh --skip-simulator    only the stages that need no simulator
#   scripts/ci.sh --only <stage>      one stage; --list-stages to see them
#
# Keeping this out of the workflow file is deliberate. PRD.md section 13 asks
# for reproducible build and test instructions, and a set of steps that only
# exist inside a CI provider's YAML is not that -- nobody can run them before
# pushing, and nobody can tell what a red build actually ran.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Stages that need a booted simulator are listed separately rather than
# inferred, so that skipping "the simulator" does not quietly skip a build that
# never needed one.
ALWAYS_STAGES="toolchain build tests fixtures runtime-toolchains xcode-build"
SIMULATOR_STAGES="simulator fixtures-simulator examples doctor"
ALL_STAGES="$ALWAYS_STAGES $SIMULATOR_STAGES"

SKIP_SIMULATOR=0
ONLY=""

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-simulator) SKIP_SIMULATOR=1; shift ;;
        --list-stages) printf '%s\n' $ALL_STAGES; exit 0 ;;
        --only)
            # Explicit, because `set -u` would otherwise kill the script with
            # "$2: unbound variable" and exit 127 instead of saying anything.
            if [ $# -lt 2 ]; then echo "--only needs a stage name" >&2; exit 64; fi
            ONLY="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done

# A name that matches no stage used to skip everything and report success,
# which is the failure this whole script exists to make impossible elsewhere.
if [ -n "$ONLY" ]; then
    case " $ALL_STAGES " in
        *" $ONLY "*) ;;
        *) echo "unknown stage: $ONLY" >&2
           echo "stages: $ALL_STAGES" >&2
           exit 64 ;;
    esac
fi

# Pick the toolchain here rather than in the workflow, so that a local run and
# a CI run are the same run. An explicit DEVELOPER_DIR still wins.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR="$("$ROOT/scripts/select-xcode.sh")" || exit 1
    export DEVELOPER_DIR
fi

ran=0
failures=""

step() {
    local name="$1"; shift
    if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then return 0; fi
    printf '\n\033[1m==> %s\033[0m\n' "$name"
    ran=$((ran + 1))
    if "$@"; then
        printf '\033[32m    %s ok\033[0m\n' "$name"
    else
        printf '\033[31m    %s FAILED\033[0m\n' "$name"
        failures="$failures $name"
    fi
}

# --- toolchain -------------------------------------------------------------

check_toolchain() {
    echo "developer dir  $DEVELOPER_DIR"
    echo "xcodebuild     $(xcodebuild -version | head -1)"
    local version
    version="$(xcrun swiftc --version 2>/dev/null | head -1)"
    echo "swiftc         $version"
    [ -n "$version" ] || { echo "could not read the Swift version" >&2; return 1; }
}

# --- host ------------------------------------------------------------------

# Both configurations, and the debug one is not redundant. SPLICE_ENABLED is
# defined only for debug, so a release build compiles the runtime's dialling
# and loading code to nothing -- which is how a type-checker crash in that file
# went unnoticed on three shipping toolchains.
build_package() {
    swift build || return 1
    swift build -c release
}

run_tests() { swift test; }

run_fixtures() { ./fixtures/run.sh; }

# The regression guard for that crash. It only reproduces on Swift 6.3.2 and
# earlier, so building on whichever toolchain happens to be newest proves
# nothing; this compiles the runtime under every one installed.
check_runtime_across_toolchains() {
    local any=0 failed=0 work arch
    work="$(mktemp -d)"
    # The host's architecture, like fixtures/run.sh. Hardcoding arm64 meant an
    # x86_64 machine checked a target it could not run.
    arch="$(uname -m)"
    while read -r _ version dir; do
        any=$((any + 1))
        printf '  swift %-8s ' "$version"

        # Both targets, because half the runtime only exists on one of them:
        # the UIKit adapter is behind `canImport(UIKit)`, so a host-only sweep
        # compiled every file except the one that changes most and reported
        # the toolchain as covered.
        # Numbered, not named by version: `select-xcode.sh` can report the
        # same Swift version for two Xcodes -- a beta and its release -- and
        # two toolchains then wrote the same module path.
        local sdk sdkversion ok=1 slot="$any"
        sdk="$(DEVELOPER_DIR="$dir" xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)"
        sdkversion="$(DEVELOPER_DIR="$dir" xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null)"
        : > "$work/log"

        DEVELOPER_DIR="$dir" xcrun swiftc -swift-version 6 -parse-as-library \
             -D SPLICE_ENABLED -emit-module \
             -emit-module-path "$work/SpliceRuntime-$slot-host.swiftmodule" \
             -module-name SpliceRuntime runtime/Sources/*.swift >> "$work/log" 2>&1 || ok=0

        if [ -n "$sdk" ] && [ -n "$sdkversion" ]; then
            DEVELOPER_DIR="$dir" xcrun swiftc -swift-version 6 -parse-as-library \
                 -D SPLICE_ENABLED -emit-module \
                 -target "$arch-apple-ios$sdkversion-simulator" -sdk "$sdk" \
                 -emit-module-path "$work/SpliceRuntime-$slot-ios.swiftmodule" \
                 -module-name SpliceRuntime runtime/Sources/*.swift >> "$work/log" 2>&1 || ok=0
        else
            echo "no iphonesimulator SDK" >> "$work/log"
            ok=0
        fi

        if [ "$ok" -eq 1 ]; then
            echo "ok  (host and simulator)"
        else
            echo "FAILED"
            # The error lines, not the first lines. Both legs share one log, so
            # `sed -n '1,6p'` printed the host's warnings and hid the simulator
            # failure underneath them -- which is exactly the leg this sweep
            # was extended to cover.
            grep -m6 -E 'error:|no iphonesimulator SDK' "$work/log" || sed -n '1,6p' "$work/log"
            failed=1
        fi
    done < <("$ROOT/scripts/select-xcode.sh" --list --supported)
    rm -rf "$work"
    [ "$any" -gt 0 ] || { echo "no toolchains to check" >&2; return 1; }
    return "$failed"
}

build_xcode_example() {
    xcodebuild -project examples/XcodeApp/XcodeApp.xcodeproj -scheme XcodeApp \
        -configuration Debug -destination 'generic/platform=iOS Simulator' \
        build 2>&1 | tail -3 | grep -q 'BUILD SUCCEEDED'
}

# --- simulator -------------------------------------------------------------

# Chosen to match the SDK of the selected toolchain. Taking whichever device
# came first booted an iOS 26.2 runtime for an iOS 27.0 SDK, which fails in
# dyld for a reason that has nothing to do with this project.
boot_simulator() {
    local wanted booted count
    wanted="$(xcrun --sdk iphonesimulator --show-sdk-version)"
    booted="$(xcrun simctl list devices | grep Booted)"
    count="$(printf '%s' "$booted" | grep -c . )"

    if [ "$count" -gt 1 ]; then
        # `simctl spawn booted` and `simctl install booted` are ambiguous with
        # more than one, and pick for themselves.
        echo "more than one simulator is booted; shut all but one down" >&2
        printf '%s\n' "$booted" >&2
        return 1
    fi
    if [ "$count" -eq 1 ]; then
        echo "already booted:$(printf '%s' "$booted" | sed 's/^ *//')"
        return 0
    fi

    local device
    device="$(xcrun simctl list devices available \
        | awk -v want="-- iOS $wanted --" '
            $0 == want { inside = 1; next }
            /^-- / { inside = 0 }
            inside && /iPhone/ { match($0, /\(([A-F0-9-]+)\)/, m); print m[1]; exit }' 2>/dev/null)"
    if [ -z "$device" ]; then
        device="$(xcrun simctl list devices available | sed -n "/-- iOS $wanted --/,/^-- /p" \
            | grep iPhone | head -1 | sed 's/.*(\([A-F0-9-]*\)).*/\1/')"
    fi
    if [ -z "$device" ]; then
        echo "no iPhone simulator on an iOS $wanted runtime, which is what this Xcode's SDK targets" >&2
        xcrun simctl list devices available >&2
        return 1
    fi
    echo "booting $device on iOS $wanted"
    xcrun simctl boot "$device" || return 1
    xcrun simctl bootstatus "$device" -b > /dev/null 2>&1 || return 1
    xcrun simctl list devices | grep Booted | sed 's/^ *//'
}

# Results are written where CI can collect them. Without --results the script
# writes nothing, and the workflow was uploading the files checked into git as
# though a runner had produced them.
run_simulator_fixtures() { ./fixtures/run.sh --platform simulator --results "$RESULTS_DIR/simulator.yaml"; }

build_examples() {
    ./examples/CounterApp/build.sh > /dev/null || return 1
    echo "CounterApp debug ok"
    # The check DESIGN.md section 5.3 asks for: the build fails if a Release
    # binary exports a replacement key or carries the reload client.
    ./examples/CounterApp/build.sh --release | grep -E 'release isolation'
}

# doctor reads the built binary back, so this proves the settings in
# integrations/xcode produce something actually patchable.
run_doctor() {
    "$(swift build --show-bin-path)/swift-splice" doctor \
        --project examples/XcodeApp/XcodeApp.xcodeproj --scheme XcodeApp \
        --sources examples/XcodeApp/Sources
}

# --- run -------------------------------------------------------------------

RESULTS_DIR="${SPLICE_RESULTS_DIR:-$ROOT/.ci-results}"
mkdir -p "$RESULTS_DIR"

step toolchain check_toolchain
step build build_package
step tests run_tests
step fixtures ./fixtures/run.sh --results "$RESULTS_DIR/macos.yaml"
step runtime-toolchains check_runtime_across_toolchains
step xcode-build build_xcode_example
if [ "$SKIP_SIMULATOR" -eq 0 ]; then
    step simulator boot_simulator
    step fixtures-simulator run_simulator_fixtures
    step examples build_examples
    step doctor run_doctor
fi

printf '\n'
if [ "$ran" -eq 0 ]; then
    echo "no stages ran" >&2
    exit 1
fi
if [ -z "$failures" ]; then
    printf '\033[32m%d stage(s) passed\033[0m\n' "$ran"
    exit 0
fi
printf '\033[31mfailed:%s\033[0m\n' "$failures"
exit 1
