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
#
# A released Xcode is preferred while one meets the floor. An image can ship a
# 27.3 beta whose Swift matches the released 27.2's, and then the version sort
# alone picked the beta, whose simulator runtime CI does not expect. The path
# cannot say which is which -- that image names the beta Xcode_27.3.app, with
# no "beta" in it -- so this reads Contents/version.plist and looks at
# ProductBuildVersion: after the capital, a beta has four digits starting with
# 5 and then one lowercase letter (27C5020n), a release does not (17C52, 27B52,
# 27A266a, 27A9275).

set -uo pipefail

# Where the Xcodes live. Overridable so the tests can point at fake ones.
APPLICATIONS=${EMBER_APPLICATIONS_DIR:-/Applications}

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

# The build number of the Xcode at this .app path, or empty when the plist is
# missing or unreadable. An unreadable build number is not evidence of a beta.
product_build_version_of() {
    local plist="$1/Contents/version.plist"
    [ -f "$plist" ] || return 0
    /usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$plist" \
        </dev/null 2>/dev/null
}

# True when this Developer directory belongs to a beta. The build number, not
# the name: a release ends in a letter (27A266a) or carries four digits
# (27A9275) too, so neither the path nor the tail of the number separates them.
is_beta() {
    local build
    build="$(product_build_version_of "${1%/Contents/Developer}")"
    [ -n "$build" ] || return 1
    printf '%s\n' "$build" | grep -Eq '^[0-9]+[A-Z]5[0-9]{3}[a-z]$'
}

candidates=()
for app in "$APPLICATIONS"/Xcode*.app; do
    [ -d "$app/Contents/Developer" ] || continue
    version="$(swift_version_of "$app/Contents/Developer")"
    [ -n "$version" ] || continue
    candidates+=("$version|$app/Contents/Developer")
done

# Before any expansion of the array: bash 3.2 treats "${empty[@]}" under set -u
# as an unbound variable, and inside a pipeline the error does not reach the
# exit status -- so --list reported success while printing a bash error.
if [ ${#candidates[@]} -eq 0 ]; then
    echo "no usable Xcode found under $APPLICATIONS" >&2
    exit 1
fi

# Sorted on the version field alone. Sorting the whole "version|path" string
# put 6.0 after 6.0.2, which made "oldest" right only by accident.
sorted() { printf '%s\n' "${candidates[@]}" | sort -V -t'|' -k1,1; }

if [ "${1:-}" = "--list" ]; then
    sorted | while IFS='|' read -r version dir; do
        # --supported narrows to what DESIGN.md section 20 claims. CI images
        # carry a decade of Xcodes, and compiling under one this project has
        # never measured produces a red that means nothing. Betas stay in the
        # list: ci.sh's runtime-toolchains compiles with every Xcode listed, so
        # dropping one would leave that toolchain unchecked.
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
#
# Prints the chosen DEVELOPER_DIR, or nothing when no candidate qualifies.
pick() {
    local releases_only="$1" oldest="$2" best="" version dir
    while IFS='|' read -r version dir; do
        at_least "$MINIMUM" "$version" || continue
        if [ "$releases_only" = "1" ] && is_beta "$dir"; then continue; fi
        if [ "$oldest" = "1" ] && [ -n "$best" ]; then continue; fi
        best="$dir"
    done < <(sorted)
    printf '%s' "$best"
}

oldest=0
if [ "${1:-}" = "--oldest" ]; then oldest=1; fi

best="$(pick 1 "$oldest")"
# Someone whose machine only has a beta gets an answer anyway: a beta is
# better than no toolchain at all, and it is what this script did before it
# learned to tell betas apart.
[ -n "$best" ] || best="$(pick 0 "$oldest")"

if [ -z "$best" ]; then
    {
        echo "no installed Xcode ships Swift $MINIMUM or newer. Found:"
        printf '%s\n' "${candidates[@]}" | sort -V | sed 's/|/  /' | sed 's/^/  swift /'
    } >&2
    exit 1
fi

echo "$best"
