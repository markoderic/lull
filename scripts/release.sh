#!/bin/bash
# Builds a signed DMG for GitHub Releases, notarizes it, and checks it the way a download gets checked.
#
#   NOTARY_PROFILE=lull-notary SIGN_IDENTITY="Developer ID Application: …" scripts/release.sh
#
# Store the notarization credentials once first (see docs/RELEASING.md). Without NOTARY_PROFILE the
# DMG is only signed, and macOS warns anyone who downloads it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application certificate name}"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# Sends a file to Apple and stops with Apple's explanation if it's rejected.
notarize() {
    local output
    output="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
    echo "$output"
    if ! grep -q "status: Accepted" <<<"$output"; then
        local id
        id="$(awk '/^ *id:/ { print $2; exit }' <<<"$output")"
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
        echo "Apple didn't accept $1." >&2
        exit 1
    fi
}

scripts/build-app.sh release >/dev/null
APP="$STAGING/Lull.app"
ditto dist/release/Lull.app "$APP"

# The app gets its own ticket as well as the DMG, so it still opens offline after it's been copied out.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Notarizing the app. This usually takes a few minutes."
    ditto -c -k --keepParent "$APP" "$STAGING/Lull.zip"
    notarize "$STAGING/Lull.zip"
    xcrun stapler staple "$APP"
    ditto "$APP" dist/release/Lull.app
fi

# The filename stays the same across versions, so the download link never has to change.
DMG="dist/Lull.dmg"

# Lays out the window people see when they open the DMG: the app, an arrow, and Applications.
# This needs permission to control Finder. Without it the DMG still works, just without the layout.
layout_window() {
    osascript <<'APPLESCRIPT' &
tell application "Finder"
    tell disk "Lull"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Lull.app" of container window to {160, 195}
        set position of item "Applications" of container window to {480, 195}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT
    local script=$!
    # Gives someone time to answer the permission prompt, without waiting forever.
    for _ in $(seq 1 180); do
        kill -0 "$script" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$script" 2>/dev/null; then
        kill "$script" 2>/dev/null || true
        return 1
    fi
    wait "$script"
}

# A leftover mount would make this one appear as "Lull 1", which the layout can't find.
hdiutil detach /Volumes/Lull -quiet -force 2>/dev/null || true
WRITABLE="$STAGING/writable.dmg"
hdiutil create -size 60m -fs HFS+ -volname "Lull" -ov "$WRITABLE" >/dev/null 2>&1
hdiutil attach "$WRITABLE" -noverify -noautoopen -quiet
ditto "$APP" /Volumes/Lull/Lull.app
ln -s /Applications /Volumes/Lull/Applications
mkdir /Volumes/Lull/.background
cp Resources/dmg-background.tiff /Volumes/Lull/.background/background.tiff
layout_window || echo "The installer window wasn't laid out: Finder permission was refused or not answered." >&2
sync
hdiutil detach /Volumes/Lull -quiet
rm -f "$DMG"
hdiutil convert "$WRITABLE" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
xattr -c "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "Signed but NOT notarized. Downloads will show a macOS warning until NOTARY_PROFILE is set." >&2
    shasum -a 256 "$DMG"
    echo "$ROOT/$DMG"
    exit 0
fi

echo "Notarizing the DMG."
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "Checking it the way macOS checks a download."
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

(cd dist && shasum -a 256 Lull.dmg | tee Lull.dmg.sha256)
echo "$ROOT/$DMG"
