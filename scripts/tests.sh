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

# select-xcode.sh reads the installed Xcodes and the Swift version in each.
# Real ones cannot be arranged into the shapes that broke CI, so these tests
# build fake ones: an app with Contents/Developer, the Swift version recorded
# beside it, and a Contents/version.plist when the build number matters. A fake
# xcrun first on PATH reports that recorded version for whatever DEVELOPER_DIR
# it is handed, so nothing here touches a real toolchain.
SELECT_XCODE="$ROOT/scripts/select-xcode.sh"
fake_root="$(mktemp -d)" || exit 1
trap 'rm -rf "$fake_root"' EXIT
mkdir -p "$fake_root/bin"
cat > "$fake_root/bin/xcrun" <<'XCRUN'
#!/bin/bash
version="$(cat "$DEVELOPER_DIR/swift-version" 2>/dev/null)"
[ -n "$version" ] || exit 1
echo "Apple Swift version $version (swiftlang-6.4.2.1.1 clang-2100.0.24.11)"
XCRUN
chmod +x "$fake_root/bin/xcrun"

# make_app <applications-dir> <app-name> <swift-version> [build-version]
# Without a build version no version.plist is written, which is the shape of
# an Xcode this script cannot classify.
make_app() {
    local app="$1/$2.app" build="${4:-}"
    mkdir -p "$app/Contents/Developer"
    printf '%s\n' "$3" > "$app/Contents/Developer/swift-version"
    if [ -n "$build" ]; then
        cat > "$app/Contents/version.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleShortVersionString</key>
	<string>$2</string>
	<key>ProductBuildVersion</key>
	<string>$build</string>
</dict>
</plist>
PLIST
    fi
}

# run_selector <arg>... -- runs the real script against the fixtures above
run_selector() {
    EMBER_APPLICATIONS_DIR="$apps" PATH="$fake_root/bin:$PATH" \
        bash "$SELECT_XCODE" "$@" 2>/dev/null
}

# The composition of the xcode-27 image that failed CI: 27.2 and the 27.3 beta
# ship the same Swift, the beta is newer, its build number ends in a letter,
# and the image also links the two names the beta goes by.
apps="$fake_root/xcode-27"
make_app "$apps" Xcode_27.0 6.4.0 27A9275
make_app "$apps" Xcode_27.2 6.4.2 27B52
make_app "$apps" Xcode_27.3_beta 6.4.2 27C5020n
ln -s Xcode_27.3_beta.app "$apps/Xcode_27.3.app"
ln -s Xcode_27.3_beta.app "$apps/Xcode_27.3.0.app"

expect "newest release beside a beta with the same Swift" \
    "$apps/Xcode_27.2.app/Contents/Developer" "$(run_selector)"
expect "oldest is the release, not the beta" \
    "$apps/Xcode_27.0.app/Contents/Developer" "$(run_selector --oldest)"
expect "--list keeps the beta" \
    "1" "$(run_selector --list | grep -c 'Xcode_27.3_beta.app/Contents/Developer')"

# A beta that is merely newer than every release must not win either.
apps="$fake_root/newer-beta"
make_app "$apps" Xcode_27.2 6.4.2 27B52
make_app "$apps" Xcode_27.3_beta 6.5.0 27C5020n
expect "release wins when the beta's Swift is newer" \
    "$apps/Xcode_27.2.app/Contents/Developer" "$(run_selector)"

apps="$fake_root/older-beta"
make_app "$apps" Xcode_27.0_beta 6.2.3 27A5020n
make_app "$apps" Xcode_27.1 6.4.0 27A9275
expect "--oldest skips a beta that is older than every release" \
    "$apps/Xcode_27.1.app/Contents/Developer" "$(run_selector --oldest)"

# Releases that end in a letter or carry four digits. Reading the build number
# as "a letter means beta" would drop both of these.
apps="$fake_root/letter-release"
make_app "$apps" Xcode_27.0 6.2.3 27A266a
make_app "$apps" Xcode_27.1_beta 6.4.2 27C5020n
expect "release build ending in a letter" \
    "$apps/Xcode_27.0.app/Contents/Developer" "$(run_selector)"

apps="$fake_root/four-digit-release"
make_app "$apps" Xcode_27.0 6.2.3 27A9275
make_app "$apps" Xcode_27.1_beta 6.4.2 27C5020n
expect "release build with four digits" \
    "$apps/Xcode_27.0.app/Contents/Developer" "$(run_selector)"

# A machine with only a beta still gets an answer.
apps="$fake_root/only-beta"
make_app "$apps" Xcode_27.3_beta 6.4.2 27C5020n
expect "a beta alone is still selected" \
    "$apps/Xcode_27.3_beta.app/Contents/Developer" "$(run_selector)"
expect "a beta alone is still the oldest" \
    "$apps/Xcode_27.3_beta.app/Contents/Developer" "$(run_selector --oldest)"

# 26.0 is below the floor, so the beta is the only way to meet it.
apps="$fake_root/floor-beta-only"
make_app "$apps" Xcode_26.0 6.2.0 26A300
make_app "$apps" Xcode_27.3_beta 6.4.2 27C5020n
expect "a beta is used when it alone meets the floor" \
    "$apps/Xcode_27.3_beta.app/Contents/Developer" "$(run_selector)"

# Unknown is not beta: an Xcode whose build number cannot be read stays usable.
apps="$fake_root/no-plist"
make_app "$apps" Xcode_27.2 6.4.2
make_app "$apps" Xcode_27.3_beta 6.4.2 27C5020n
expect "an Xcode without version.plist is not a beta" \
    "$apps/Xcode_27.2.app/Contents/Developer" "$(run_selector)"

if [ "$failures" -ne 0 ]; then
    echo "$failures script test(s) failed" >&2
    exit 1
fi
echo "14 script tests passed"
