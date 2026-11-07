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

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/Lull-$VERSION.dmg"
CONTENTS="$STAGING/contents"
mkdir -p "$CONTENTS"
ditto "$APP" "$CONTENTS/Lull.app"
ln -s /Applications "$CONTENTS/Applications"
rm -f "$DMG"
hdiutil create -volname "Lull" -srcfolder "$CONTENTS" -ov -format UDZO "$DMG" >/dev/null
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

(cd dist && shasum -a 256 "Lull-$VERSION.dmg" | tee "Lull-$VERSION.dmg.sha256")
echo "$ROOT/$DMG"
