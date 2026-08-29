#!/bin/bash
# Selects the first iPhone UDID under the requested iOS version from
# `xcrun simctl list devices available`. Input is read from stdin so the
# parser can be regression-tested without changing Simulator state.

set -uo pipefail

if [ $# -ne 1 ]; then
    echo "usage: select-simulator-device.sh <iOS-version>" >&2
    exit 64
fi

awk -v wanted="-- iOS $1 --" '
    $0 == wanted {
        inside = 1
        next
    }
    /^-- / {
        inside = 0
        next
    }
    inside && /^[[:space:]]*iPhone/ {
        # Device lines are `name (UDID) (state)`. `split` is POSIX awk;
        # unlike match(..., ..., captures), it works in the awk macOS ships.
        count = split($0, parts, /[()]/)
        for (part = 2; part <= count; part += 2) {
            candidate = parts[part]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", candidate)
            if (candidate ~ /^[[:xdigit:]-]+$/) {
                print candidate
                exit
            }
        }
    }
'
