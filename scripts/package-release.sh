#!/bin/bash
#
# Build the host CLI and package the two assets attached to a GitHub Release:
#
#   scripts/package-release.sh 0.3.0
#   scripts/package-release.sh 0.3.0 /path/to/output
#
# swift-ember.zip is for direct installation. The artifact bundle contains the
# same executable in the structured form consumed by SwiftPM binary targets.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL_PACKAGE="$ROOT/Tools/swift-ember"
VERSION="${1:-}"
OUTPUT_DIR="${2:-$ROOT/dist}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <major.minor.patch> [output-directory]" >&2
    exit 64
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

swift build -c release --package-path "$TOOL_PACKAGE"
BIN_DIR="$(swift build -c release --package-path "$TOOL_PACKAGE" --show-bin-path)"
SOURCE_BINARY="$BIN_DIR/swift-ember"
test -x "$SOURCE_BINARY" || { echo "release executable not found: $SOURCE_BINARY" >&2; exit 1; }

# The ordinary CI packaging probe uses 0.0.0 because it is not a release. A
# real tag must agree with the version compiled into the CLI; otherwise users
# can install one release and have the binary identify itself as another.
if [ "$VERSION" != "0.0.0" ]; then
    ACTUAL_VERSION="$("$SOURCE_BINARY" --version)"
    EXPECTED_VERSION="swift-ember $VERSION"
    test "$ACTUAL_VERSION" = "$EXPECTED_VERSION" || {
        echo "version mismatch: tag is $VERSION, binary says $ACTUAL_VERSION" >&2
        exit 1
    }
fi

# Sign one payload and copy that exact file into both archives. A Developer ID
# signature can replace this step later; current releases deliberately use
# ad-hoc signing and therefore need no repository secret.
PAYLOAD_BINARY="$WORK_DIR/swift-ember"
cp "$SOURCE_BINARY" "$PAYLOAD_BINARY"
chmod 755 "$PAYLOAD_BINARY"
codesign --force --sign - "$PAYLOAD_BINARY"

ARCHITECTURES="$(lipo -archs "$PAYLOAD_BINARY")"
case "$ARCHITECTURES" in
    arm64)
        SUPPORTED_TRIPLES='"arm64-apple-macosx"'
        ;;
    x86_64)
        echo "the release executable must include arm64" >&2
        exit 1
        ;;
    "arm64 x86_64"|"x86_64 arm64")
        SUPPORTED_TRIPLES='"arm64-apple-macosx", "x86_64-apple-macosx"'
        ;;
    *)
        echo "unsupported release architectures: $ARCHITECTURES" >&2
        exit 1
        ;;
esac

DIRECT_ROOT="$WORK_DIR/direct/swift-ember"
mkdir -p "$DIRECT_ROOT/bin"
cp "$PAYLOAD_BINARY" "$DIRECT_ROOT/bin/swift-ember"
cp "$ROOT/LICENSE" "$DIRECT_ROOT/LICENSE"
cp "$ROOT/scripts/release-install.sh" "$DIRECT_ROOT/install.sh"
chmod 755 "$DIRECT_ROOT/install.sh" "$DIRECT_ROOT/bin/swift-ember"

BUNDLE_ROOT="$WORK_DIR/artifact/swift-ember.artifactbundle"
VARIANT="swift-ember-$VERSION-macosx"
mkdir -p "$BUNDLE_ROOT/$VARIANT/bin"
cp "$PAYLOAD_BINARY" "$BUNDLE_ROOT/$VARIANT/bin/swift-ember"
cp "$ROOT/LICENSE" "$BUNDLE_ROOT/$VARIANT/bin/LICENSE"
chmod 755 "$BUNDLE_ROOT/$VARIANT/bin/swift-ember"
cat > "$BUNDLE_ROOT/info.json" <<EOF
{
  "schemaVersion": "1.0",
  "artifacts": {
    "swift-ember": {
      "type": "executable",
      "version": "$VERSION",
      "variants": [
        {
          "path": "$VARIANT/bin/swift-ember",
          "supportedTriples": [$SUPPORTED_TRIPLES]
        }
      ]
    }
  }
}
EOF

(cd "$WORK_DIR/direct" && /usr/bin/zip -qry -X "$WORK_DIR/swift-ember.zip" swift-ember)
(cd "$WORK_DIR/artifact" && /usr/bin/zip -qry -X \
    "$WORK_DIR/swift-ember.artifactbundle.zip" swift-ember.artifactbundle)

(cd "$WORK_DIR" && shasum -a 256 swift-ember.zip > swift-ember.zip.sha256)
(cd "$WORK_DIR" && shasum -a 256 swift-ember.artifactbundle.zip \
    > swift-ember.artifactbundle.zip.sha256)

# Treat the archives as a consumer would before publishing them.
mkdir -p "$WORK_DIR/verify/direct" "$WORK_DIR/verify/artifact"
unzip -q "$WORK_DIR/swift-ember.zip" -d "$WORK_DIR/verify/direct"
unzip -q "$WORK_DIR/swift-ember.artifactbundle.zip" -d "$WORK_DIR/verify/artifact"

DIRECT_BINARY="$WORK_DIR/verify/direct/swift-ember/bin/swift-ember"
BUNDLE_BINARY="$WORK_DIR/verify/artifact/swift-ember.artifactbundle/$VARIANT/bin/swift-ember"
test -x "$DIRECT_BINARY"
test -x "$BUNDLE_BINARY"
cmp "$DIRECT_BINARY" "$BUNDLE_BINARY"
codesign --verify --strict "$DIRECT_BINARY"
codesign --verify --strict "$BUNDLE_BINARY"
"$DIRECT_BINARY" --help >/dev/null
"$BUNDLE_BINARY" --help >/dev/null
INFO_JSON="$WORK_DIR/verify/artifact/swift-ember.artifactbundle/info.json"
jq -e --arg version "$VERSION" --arg path "$VARIANT/bin/swift-ember" '
    .schemaVersion == "1.0" and
    .artifacts["swift-ember"].type == "executable" and
    .artifacts["swift-ember"].version == $version and
    .artifacts["swift-ember"].variants[0].path == $path and
    (.artifacts["swift-ember"].variants[0].supportedTriples | length > 0)
' "$INFO_JSON" >/dev/null

EXPECTED_CHECKSUM="$(awk '{print $1}' "$WORK_DIR/swift-ember.artifactbundle.zip.sha256")"
SWIFTPM_CHECKSUM="$(swift package compute-checksum "$WORK_DIR/swift-ember.artifactbundle.zip")"
test "$EXPECTED_CHECKSUM" = "$SWIFTPM_CHECKSUM" || {
    echo "SwiftPM and shasum produced different artifact bundle checksums" >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR"
for asset in \
    swift-ember.zip \
    swift-ember.zip.sha256 \
    swift-ember.artifactbundle.zip \
    swift-ember.artifactbundle.zip.sha256
do
    install -m 644 "$WORK_DIR/$asset" "$OUTPUT_DIR/$asset"
done

echo "release assets for $VERSION ($ARCHITECTURES):"
ls -lh "$OUTPUT_DIR"/swift-ember.zip \
    "$OUTPUT_DIR"/swift-ember.zip.sha256 \
    "$OUTPUT_DIR"/swift-ember.artifactbundle.zip \
    "$OUTPUT_DIR"/swift-ember.artifactbundle.zip.sha256
