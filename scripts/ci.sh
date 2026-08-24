#!/bin/bash
#
# Everything CI runs, in one script that also runs locally.
#
#   scripts/ci.sh                     everything
#   scripts/ci.sh --skip-simulator    host only, no simulator boot
#   scripts/ci.sh --only tests        one stage: toolchain|build|tests|fixtures|
#                                     simulator|examples|xcode
#
# Keeping this out of the workflow file is deliberate. PRD.md section 13 asks
# for reproducible build and test instructions, and a set of steps that only
# exist inside a CI provider's YAML is not that -- nobody can run them before
# pushing, and nobody can tell what a red build actually ran.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SKIP_SIMULATOR=0
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-simulator) SKIP_SIMULATOR=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done

failures=()

step() {
    local name="$1"; shift
    if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then return 0; fi
    printf '\n\033[1m==> %s\033[0m\n' "$name"
    if "$@"; then
        printf '\033[32m    %s ok\033[0m\n' "$name"
    else
        printf '\033[31m    %s FAILED\033[0m\n' "$name"
        failures+=("$name")
    fi
}

# --- toolchain -------------------------------------------------------------

MINIMUM_SWIFT=6.2

check_toolchain() {
    echo "developer dir  $(xcode-select -p)"
    echo "xcodebuild     $(xcodebuild -version | head -1)"
    local version
    version="$(xcrun swiftc --version 2>/dev/null | head -1)"
    echo "swiftc         $version"

    local numeric
    numeric="$(sed -n 's/.*Apple Swift version \([0-9][0-9.]*\).*/\1/p' <<< "$version")"
    if [ -z "$numeric" ]; then
        echo "could not read the Swift version" >&2
        return 1
    fi
    # DESIGN.md section 20 records what has actually been run. Anything older
    # than the floor is not a failure of this script, but it must not be
    # reported as a pass either.
    if [ "$(printf '%s\n%s\n' "$MINIMUM_SWIFT" "$numeric" | sort -V | head -1)" != "$MINIMUM_SWIFT" ]; then
        echo "Swift $numeric is below the tested floor of $MINIMUM_SWIFT" >&2
        return 1
    fi
}

# --- host ------------------------------------------------------------------

# Release, not debug. Classification is SwiftSyntax parsing and costs about
# fourteen times as much unoptimised, and a debug build has also hidden a
# type-checker crash that only appears with optimisation off in some versions.
build_package() { swift build -c release; }

run_tests() { swift test; }

run_fixtures() { ./fixtures/run.sh; }

# --- simulator -------------------------------------------------------------

boot_simulator() {
    if xcrun simctl list devices | grep -q Booted; then
        echo "already booted: $(xcrun simctl list devices | grep Booted | head -1 | sed 's/^ *//')"
        return 0
    fi
    local device
    device="$(xcrun simctl list devices available \
        | grep -E '^\s+iPhone' | head -1 | sed 's/.*(\([A-F0-9-]*\)).*/\1/')"
    if [ -z "$device" ]; then
        echo "no iPhone simulator available" >&2
        return 1
    fi
    echo "booting $device"
    xcrun simctl boot "$device" || return 1
    xcrun simctl bootstatus "$device" -b > /dev/null 2>&1
    xcrun simctl list devices | grep Booted | sed 's/^ *//'
}

run_simulator_fixtures() { ./fixtures/run.sh --platform simulator; }

# --- examples --------------------------------------------------------------

build_examples() {
    ./examples/CounterApp/build.sh > /dev/null || return 1
    echo "CounterApp debug ok"
    # The check DESIGN.md section 5.3 asks for: the build fails if a Release
    # binary exports any replacement key or carries the reload client.
    ./examples/CounterApp/build.sh --release | grep -E 'release isolation|replacement keys' || return 1
}

build_xcode_example() {
    local project=examples/XcodeApp/XcodeApp.xcodeproj
    xcodebuild -project "$project" -scheme XcodeApp -configuration Debug \
        -destination 'generic/platform=iOS Simulator' \
        build 2>&1 | tail -3 | grep -q 'BUILD SUCCEEDED' || return 1
    echo "XcodeApp builds"
    # doctor reads the built binary back, so this also proves the settings in
    # integrations/xcode actually produce a patchable binary.
    "$(swift build -c release --show-bin-path)/swift-splice" doctor \
        --project "$project" --scheme XcodeApp --sources examples/XcodeApp/Sources
}

# --- run -------------------------------------------------------------------

step toolchain check_toolchain
step build build_package
step tests run_tests
step fixtures run_fixtures
if [ "$SKIP_SIMULATOR" -eq 0 ]; then
    step simulator boot_simulator
    step fixtures-simulator run_simulator_fixtures
    step examples build_examples
    step xcode build_xcode_example
fi

printf '\n'
if [ ${#failures[@]} -eq 0 ]; then
    printf '\033[32mall stages passed\033[0m\n'
    exit 0
fi
printf '\033[31mfailed: %s\033[0m\n' "${failures[*]}"
exit 1
