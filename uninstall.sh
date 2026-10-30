#!/bin/bash
set -euo pipefail

DEST="$HOME/Applications/EMLQuickLook.app"
EXTENSION_ID="com.youi.EMLQuickLook.Extension"
MAIL_EXTENSION_ID="com.apple.mail.MailQuickLookExtension"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "==> Removing EML Quick Look"
pluginkit -e ignore -i "$EXTENSION_ID" >/dev/null 2>&1 || true
if [[ -d "$DEST" ]]; then
    pluginkit -r "$DEST/Contents/PlugIns/EMLQuickLookExtension.appex" >/dev/null 2>&1 || true
    "$LSREGISTER" -u "$DEST" >/dev/null 2>&1 || true
    rm -rf "$DEST"
fi

echo "==> Re-enabling Apple Mail's Quick Look extension"
pluginkit -e use -i "$MAIL_EXTENSION_ID" >/dev/null 2>&1 || true

echo "==> Resetting Quick Look"
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
killall quicklookd >/dev/null 2>&1 || true

echo "Done."
