#!/bin/bash
#
# Submit a signed CLI to Apple as a ZIP. Gatekeeper looks up the ticket online.
# Set NOTARY_KEY_PATH to the App Store Connect .p8, plus NOTARY_KEY_ID and
# NOTARY_ISSUER_ID for that key.

set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "usage: $0 <signed-executable>" >&2
    exit 64
fi
binary="$1"
: "${NOTARY_KEY_PATH:?set NOTARY_KEY_PATH}"
: "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"

work="$(mktemp -d "${TMPDIR:-/tmp}/swift-ember-notary.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
archive="$work/swift-ember-notary.zip"
/usr/bin/zip -q -j -X "$archive" "$binary"

# The raw response and errors can contain account information.
result="$work/result.json"
code=0
xcrun notarytool submit "$archive" \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --wait --timeout 30m --output-format json >"$result" 2>/dev/null || code=$?
status="$(jq -r '.status // empty' "$result" 2>/dev/null)" || status=
case "$status" in
    Accepted|Invalid|Rejected|"In Progress") ;;
    *) status=unknown ;;
esac
submission="$(jq -r '.id | strings | select(test("^[0-9a-fA-F-]{36}$"))' \
    "$result" 2>/dev/null)" || submission=
echo "notarytool: exit code $code, status $status, submission ${submission:-unavailable}"
if [ "$code" -ne 0 ] || [ "$status" != Accepted ]; then
    echo "Apple notarization failed; check the API credentials or retrieve the submission log" >&2
    exit 1
fi

# Check the online ticket for a standalone Mach-O. Allow time for propagation.
for attempt in 1 2 3; do
    if codesign --verify --strict -R='notarized' --check-notarization "$binary" >/dev/null 2>&1; then
        echo "Verified the online notarization ticket"
        exit 0
    fi
    if [ "$attempt" -lt 3 ]; then
        sleep 10
    fi
done
echo "Apple accepted the submission, but the online notarization ticket could not be verified" >&2
exit 1
