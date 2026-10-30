#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="EMLQuickLook.app"
BUILD_APP="$ROOT/build/$APP_NAME"
DEST="$HOME/Applications/$APP_NAME"
EXTENSION_ID="com.youi.EMLQuickLook.Extension"
MAIL_EXTENSION_ID="com.apple.mail.MailQuickLookExtension"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ "${1:-}" == "--no-build" ]]; then
    if [[ ! -d "$BUILD_APP" ]]; then
        echo "error: $BUILD_APP not found; run ./build.sh first" >&2
        exit 1
    fi
else
    "$ROOT/build.sh"
fi

echo "==> Installing to $DEST"
mkdir -p "$HOME/Applications"

# Remove any previous registration before replacing the bundle so the old
# prototype's UTI declarations do not linger in Launch Services.
if [[ -d "$DEST" ]]; then
    pluginkit -r "$DEST/Contents/PlugIns/EMLQuickLookExtension.appex" >/dev/null 2>&1 || true
    "$LSREGISTER" -u "$DEST" >/dev/null 2>&1 || true
    rm -rf "$DEST"
fi

ditto "$BUILD_APP" "$DEST"

# The build copy can otherwise stay registered as a second bundle with the
# same identifier and extension.
"$LSREGISTER" -u "$BUILD_APP" >/dev/null 2>&1 || true

echo "==> Registering"
"$LSREGISTER" -f "$DEST"
EXTENSION_PATH="$DEST/Contents/PlugIns/EMLQuickLookExtension.appex"
pluginkit -a "$EXTENSION_PATH" >/dev/null 2>&1 || true

# Registration is asynchronous; retry briefly before electing the extension.
for _ in 1 2 3 4 5; do
    if pluginkit -m -A -D -v -p com.apple.quicklook.preview 2>/dev/null \
        | grep -q "$EXTENSION_ID"; then
        break
    fi
    sleep 1
    pluginkit -a "$EXTENSION_PATH" >/dev/null 2>&1 || true
done
pluginkit -e use -i "$EXTENSION_ID" >/dev/null 2>&1 || true

# Quick Look has no per-UTI extension precedence.  When both extensions are
# enabled, Mail's extension wins for com.apple.mail.email, so it has to be
# disabled for this extension to be selected.
echo "==> Disabling Apple Mail's Quick Look extension"
pluginkit -e ignore -i "$MAIL_EXTENSION_ID" >/dev/null 2>&1 || true

echo "==> Resetting Quick Look"
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
killall quicklookd >/dev/null 2>&1 || true

echo
pluginkit -m -A -D -v -p com.apple.quicklook.preview 2>/dev/null \
    | grep -iE 'mail.MailQuickLookExtension|EMLQuickLook' || true
echo
echo "Installed $DEST"
echo "Enable Mail's Quick Look again with:"
echo "  pluginkit -e use -i $MAIL_EXTENSION_ID"
