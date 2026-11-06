#!/bin/bash
# Builds a signed DMG for GitHub Releases, and notarizes it when credentials are available.
#
#   SIGN_IDENTITY="Developer ID Application: …" scripts/release.sh
#
# To notarize as well, store credentials once, then set NOTARY_PROFILE:
#   xcrun notarytool store-credentials lull-notary --apple-id you@example.com --team-id TEAMID
#   NOTARY_PROFILE=lull-notary SIGN_IDENTITY="…" scripts/release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application certificate name}"

scripts/build-app.sh release >/dev/null

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/Lull-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R dist/release/Lull.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Lull" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
else
    echo "Not notarized: set NOTARY_PROFILE to notarize. Downloads will show a macOS warning until then." >&2
fi

shasum -a 256 "$DMG"
echo "$ROOT/$DMG"
