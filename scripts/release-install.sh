#!/bin/bash
#
# This file is packaged as install.sh in swift-ember.zip. The first argument,
# or PREFIX when no argument is given, chooses the installation prefix.

set -eu

PREFIX="${1:-${PREFIX:-/usr/local}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

install -d "$PREFIX/bin"
install -m 755 "$SCRIPT_DIR/bin/swift-ember" "$PREFIX/bin/swift-ember"

echo "installed swift-ember in $PREFIX/bin"
