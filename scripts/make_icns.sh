#!/usr/bin/env bash
set -euo pipefail

INPUT_PNG="${1:-}"
if [[ -z "$INPUT_PNG" || ! -f "$INPUT_PNG" ]]; then
  echo "Usage: scripts/make_icns.sh <input_1024x1024.png>" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
RESOURCES_DIR="$REPO_ROOT/Resources"
mkdir -p "$RESOURCES_DIR"

ICONSET_DIR="/tmp/Minuteer.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sips -z 16 16     "$INPUT_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32     "$INPUT_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$INPUT_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64     "$INPUT_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$INPUT_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256   "$INPUT_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$INPUT_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512   "$INPUT_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$INPUT_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$INPUT_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ICONSET_DIR"

echo "Generated $RESOURCES_DIR/AppIcon.icns"
