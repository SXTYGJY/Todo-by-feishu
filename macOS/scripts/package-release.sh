#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$MACOS_DIR/build/Todo.app"
OUTPUT_DIR="$MACOS_DIR/build/release"

case "$(uname -m)" in
  arm64) ARCH_LABEL="arm64" ;;
  x86_64) ARCH_LABEL="x64" ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

ZIP_NAME="Todo-macos-$ARCH_LABEL.zip"
ZIP_PATH="$OUTPUT_DIR/$ZIP_NAME"
CHECKSUM_PATH="$OUTPUT_DIR/SHA256SUMS.txt"

# Public learning-project releases use an optimized build and ad-hoc signing only.
TODO_CONFIGURATION=release TODO_CODESIGN_IDENTITY=- "$SCRIPT_DIR/package-app.sh"

mkdir -p "$OUTPUT_DIR"
rm -f "$ZIP_PATH" "$CHECKSUM_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
(cd "$OUTPUT_DIR" && shasum -a 256 "$ZIP_NAME" > "$(basename "$CHECKSUM_PATH")")

echo "Release archive: $ZIP_PATH"
echo "SHA-256 file: $CHECKSUM_PATH"
echo "This artifact has an ad-hoc signature only; it has no Apple Developer ID signature and is not notarized."
