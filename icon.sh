#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RESOURCES="$ROOT/Resources"
MASTER="$RESOURCES/AppIcon-1024.png"
ICONSET="$RESOURCES/AppIcon.iconset"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$RESOURCES"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

echo "==> Drawing icon"
xcrun swiftc -O -framework AppKit -o "$TMP/makeicon" "$ROOT/Tools/makeicon.swift"
"$TMP/makeicon" "$MASTER"

echo "==> Building iconset"
while read -r name pixels; do
    sips -z "$pixels" "$pixels" "$MASTER" --out "$ICONSET/$name" >/dev/null
done <<'EOF'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
EOF

iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET"
echo "==> Built $RESOURCES/AppIcon.icns"
