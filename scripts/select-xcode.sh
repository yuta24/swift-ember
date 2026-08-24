#!/bin/bash
#
# Prints the DEVELOPER_DIR of the newest installed Xcode whose Swift meets the
# floor in DESIGN.md section 20, or fails saying what it found instead.
#
#   export DEVELOPER_DIR="$(scripts/select-xcode.sh)"
#   scripts/select-xcode.sh --oldest      the floor rather than the newest
#   scripts/select-xcode.sh --list
#
# CI images change what they ship without warning. Pinning a version in a
# workflow file means the build breaks the day an image rotates, and hardcoding
# "latest" means it silently starts testing something nobody chose. Asking the
# machine what it has, against a floor recorded next to the measurements that
# justify it, does neither.

set -uo pipefail

MINIMUM=${SPLICE_MINIMUM_SWIFT:-6.2}

swift_version_of() {
    local developer_dir="$1"
    DEVELOPER_DIR="$developer_dir" xcrun swiftc --version 2>/dev/null \
        | sed -n 's/.*Apple Swift version \([0-9][0-9.]*\).*/\1/p' | head -1
}

at_least() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

candidates=()
for app in /Applications/Xcode*.app; do
    [ -d "$app/Contents/Developer" ] || continue
    version="$(swift_version_of "$app/Contents/Developer")"
    [ -n "$version" ] || continue
    candidates+=("$version|$app/Contents/Developer")
done

if [ "${1:-}" = "--list" ]; then
    printf '%s\n' "${candidates[@]}" | sort -V | while IFS='|' read -r version dir; do
        printf 'swift %-8s %s\n' "$version" "$dir"
    done
    exit 0
fi

if [ ${#candidates[@]} -eq 0 ]; then
    echo "no usable Xcode found under /Applications" >&2
    exit 1
fi

# Version-sorted, so "oldest" and "newest" mean what they say. A string
# comparison would put 6.10 before 6.2, which is the kind of thing that stays
# wrong until the day it matters.
best=""
best_version=""
while IFS='|' read -r version dir; do
    at_least "$MINIMUM" "$version" || continue
    if [ "${1:-}" = "--oldest" ] && [ -n "$best" ]; then continue; fi
    best="$dir"
    best_version="$version"
done < <(printf '%s\n' "${candidates[@]}" | sort -V)

if [ -z "$best" ]; then
    {
        echo "no installed Xcode ships Swift $MINIMUM or newer. Found:"
        printf '%s\n' "${candidates[@]}" | sort -V | sed 's/|/  /' | sed 's/^/  swift /'
    } >&2
    exit 1
fi

echo "$best"
