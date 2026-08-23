#!/bin/bash
#
# Compiles a hand-authored patch against the running app's module and delivers
# it into the app's Documents/Patches inbox. The app loads it when you tap
# "Load pending patches".
#
#   ./patch.sh Patches/Patch1.swift
#   ./patch.sh Patches/Patch1.swift Patches/Patch2.swift
#
# In M1 the patch source is written by hand. Generating it from a source edit
# is M2's job; this script exists to prove the compile-deliver-load half works
# before a daemon is introduced.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MODULE=CounterApp
BUNDLE_ID=dev.swift-splice.CounterApp
OUT="$ROOT/.build/debug"

[ $# -gt 0 ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }

APP_BINARY="$OUT/$MODULE.app/$MODULE"

if [ ! -f "$OUT/$MODULE.swiftmodule" ] || [ ! -f "$APP_BINARY" ]; then
    echo "no debug build in $OUT -- run ./build.sh first" >&2
    exit 1
fi

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TRIPLE="arm64-apple-ios$(xcrun --sdk iphonesimulator --show-sdk-version)-simulator"

DATA="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data)"
INBOX="$DATA/Documents/Patches"
mkdir -p "$INBOX"

# Generation numbers order the inbox, and the runtime loads in filename order.
generation=$(( $(find "$INBOX" -name '*.dylib' | wc -l | tr -d ' ') ))

for source in "$@"; do
    generation=$((generation + 1))
    name="$(printf 'Patch_%03d' "$generation")"
    lib="$OUT/$name.dylib"

    # Linking against the application binary resolves the replacement keys at
    # LINK rather than deferring them to dlopen, so a declaration that is not
    # actually replaceable fails here with "Undefined symbols" instead of
    # failing later inside the running process. See DESIGN.md section 17.
    start=$(date +%s%N)
    xcrun swiftc -Onone \
        -target "$TRIPLE" -sdk "$SDK" \
        -Xclang-linker -isysroot -Xclang-linker "$SDK" \
        -emit-library -o "$lib" \
        -module-name "$name" \
        -I "$OUT" \
        "$ROOT/$source" \
        -Xlinker -bundle \
        -Xlinker -bundle_loader -Xlinker "$APP_BINARY"
    elapsed=$(( ($(date +%s%N) - start) / 1000000 ))

    cp "$lib" "$INBOX/$name.dylib"
    echo "$source -> $name.dylib  (${elapsed} ms)"
done

echo "delivered to $INBOX"
echo "the app polls this directory and loads new images within a second"
