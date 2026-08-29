#!/bin/bash
#
# The automated loop, end to end:
#
#   build and launch -> start the daemon -> edit a method body -> observe
#
# No patch is written by hand. The only action is a save, exactly as it would
# be in an editor; the daemon does the rest.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"
TOOL_PACKAGE="$REPO/Tools/swift-splice"
BUNDLE_ID=dev.swift-splice.CounterApp
SHOTS="${SHOTS_DIR:-$ROOT/.build/demo}"
SUBJECT="$ROOT/Sources/Cart.swift"
LOG="$ROOT/.build/watch.log"

mkdir -p "$SHOTS" "$ROOT/.build"

cleanup() {
    if [ -n "${DAEMON:-}" ]; then
        # Reaping the job keeps the shell from printing its own "Terminated"
        # notice over the demo's output.
        { kill "$DAEMON"; wait "$DAEMON"; } 2>/dev/null || true
    fi
    [ -f "$SUBJECT.orig" ] && mv "$SUBJECT.orig" "$SUBJECT"
    return 0
}
trap cleanup EXIT

# Optimised, and not as a matter of taste. Classification is SwiftSyntax
# parsing, which at -Onone costs about fourteen times what it does optimised:
# on a 2,000-line file that is 244 ms against 18 ms, turning a 366 ms reload
# into a 591 ms one. The first build of this takes a couple of minutes.
echo "==> building the daemon (release)"
swift build -c release --package-path "$TOOL_PACKAGE" > /dev/null
SPLICE="$(swift build -c release --package-path "$TOOL_PACKAGE" --show-bin-path)/swift-splice"

echo "==> building and launching the app"
"$ROOT/build.sh" > /dev/null
sleep 3

echo "==> starting the daemon"
"$SPLICE" watch --context "$ROOT/splice-context.json" > "$LOG" 2>&1 &
DAEMON=$!

# The app dials the daemon, so give it a moment to notice the session file.
for _ in $(seq 20); do
    grep -q "^connected" "$LOG" && break
    sleep 0.5
done
grep -q "^connected" "$LOG" || { echo "the app never connected; see $LOG" >&2; exit 1; }

xcrun simctl io booted screenshot "$SHOTS/before.png" > /dev/null 2>&1
echo "==> captured $SHOTS/before.png"

echo "==> editing subtotalLabel()"
cp "$SUBJECT" "$SUBJECT.orig"
python3 - "$SUBJECT" <<'PY'
import sys
path = sys.argv[1]
source = open(path).read()
old = '''    func subtotalLabel() -> String {
        "\\(subtotalCents) cents"
    }'''
new = '''    func subtotalLabel() -> String {
        let dollars = Double(subtotalCents) / 100
        return String(format: "$%.2f  (edited live)", dollars)
    }'''
assert source.count(old) == 1, "demo edit no longer matches Cart.swift"
open(path, "w").write(source.replace(old, new, 1))
PY

for _ in $(seq 30); do
    grep -q "hot reloaded" "$LOG" && break
    sleep 0.5
done

sleep 1
xcrun simctl io booted screenshot "$SHOTS/after.png" > /dev/null 2>&1
echo "==> captured $SHOTS/after.png"
echo

sed -n '/hot reloaded/,$p' "$LOG"

cat <<'EXPECTED'

Expected difference, with the session token unchanged:

  Subtotal   775 cents  ->  $7.75  (edited live)
EXPECTED
