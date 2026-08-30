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

# The oldest Swift the matrix in DESIGN.md section 20 has actually been run
# against. Not 6.2: Xcode 26.0 and 26.1 ship 6.2.x and have never been measured,
# and a floor that admits them would let CI report a pass for something the
# documentation does not claim.
MINIMUM=${EMBER_MINIMUM_SWIFT:-6.2.3}

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

# Before any expansion of the array: bash 3.2 treats "${empty[@]}" under set -u
# as an unbound variable, and inside a pipeline the error does not reach the
# exit status -- so --list reported success while printing a bash error.
if [ ${#candidates[@]} -eq 0 ]; then
    echo "no usable Xcode found under /Applications" >&2
    exit 1
fi

# Sorted on the version field alone. Sorting the whole "version|path" string
# put 6.0 after 6.0.2, which made "oldest" right only by accident.
sorted() { printf '%s\n' "${candidates[@]}" | sort -V -t'|' -k1,1; }

if [ "${1:-}" = "--list" ]; then
    sorted | while IFS='|' read -r version dir; do
        # --supported narrows to what DESIGN.md section 20 claims. CI images
        # carry a decade of Xcodes, and compiling under one this project has
        # never measured produces a red that means nothing.
        if [ "${2:-}" = "--supported" ] && ! at_least "$MINIMUM" "$version"; then
            continue
        fi
        printf 'swift %-8s %s\n' "$version" "$dir"
    done
    exit 0
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
done < <(sorted)

if [ -z "$best" ]; then
    {
        echo "no installed Xcode ships Swift $MINIMUM or newer. Found:"
        printf '%s\n' "${candidates[@]}" | sort -V | sed 's/|/  /' | sed 's/^/  swift /'
    } >&2
    exit 1
fi

echo "$best"
