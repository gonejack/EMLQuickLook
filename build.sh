#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/EMLQuickLook.app"
APEX="$APP/Contents/PlugIns/EMLQuickLookExtension.appex"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macosx14.0"
ICON="$ROOT/Resources/AppIcon.icns"
ZSTD="$ROOT/Vendor/zstd"

if [[ ! -f "$ICON" || "$ROOT/Tools/makeicon.swift" -nt "$ICON" ]]; then
    "$ROOT/icon.sh"
fi

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APEX/Contents/MacOS"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp "$ZSTD/LICENSE" "$APP/Contents/Resources/Zstandard-LICENSE.txt"

echo "==> Building zstd decoder"
xcrun clang \
    -O2 \
    -fPIC \
    -target "$TARGET" \
    -isysroot "$SDK" \
    -c "$ZSTD/zstddeclib.c" \
    -o "$BUILD/zstddeclib.o"

echo "==> Building Quick Look extension"
xcrun swiftc \
    -module-name EMLQuickLookExtension \
    -target "$TARGET" \
    -sdk "$SDK" \
    -application-extension \
    -parse-as-library \
    -O \
    -I "$ZSTD/include" \
    -framework Foundation \
    -framework QuickLookUI \
    -framework UniformTypeIdentifiers \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APEX/Contents/MacOS/EMLQuickLookExtension" \
    "$ROOT/Extension/PreviewProvider.swift" \
    "$ROOT/Extension/MIMERenderer.swift" \
    "$ROOT/Extension/HTMLRenderer.swift" \
    "$BUILD/zstddeclib.o"

cp "$ROOT/Extension/Info.plist" "$APEX/Contents/Info.plist"

echo "==> Building host app"
xcrun swiftc \
    -module-name EMLQuickLook \
    -target "$TARGET" \
    -sdk "$SDK" \
    -O \
    -framework AppKit \
    -framework QuickLookUI \
    -o "$APP/Contents/MacOS/EMLQuickLook" \
    "$ROOT/Host/main.swift"

cp "$ROOT/Host/Info.plist" "$APP/Contents/Info.plist"

echo "==> Building render tool"
xcrun swiftc \
    -module-name EMLRender \
    -target "$TARGET" \
    -sdk "$SDK" \
    -O \
    -I "$ZSTD/include" \
    -framework Foundation \
    -o "$BUILD/emlrender" \
    "$ROOT/Tools/main.swift" \
    "$ROOT/Extension/MIMERenderer.swift" \
    "$ROOT/Extension/HTMLRenderer.swift" \
    "$BUILD/zstddeclib.o"

echo "==> Signing (ad-hoc)"
codesign --force --sign - \
    --entitlements "$ROOT/Extension/Extension.entitlements" \
    --timestamp=none \
    "$APEX"
codesign --force --sign - \
    --timestamp=none \
    "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> Built $APP"
echo "==> Built $BUILD/emlrender"
