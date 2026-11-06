#!/bin/bash
# Builds Lull.app into dist/<configuration>/.
#
#   scripts/build-app.sh                  release build, ad-hoc signed, for running on this Mac
#   scripts/build-app.sh debug            debug build with the automation bridge
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#                                         release build signed for distribution
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

# Assembled and signed in a temporary folder: folders like ~/Documents can tag files with extended
# attributes at any moment, and codesign refuses to sign a bundle that has them.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
BUNDLE="$STAGING/Lull.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_PATH/Lull" "$BUNDLE/Contents/MacOS/Lull"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
xattr -cr "$BUNDLE"

IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$BUNDLE"
else
    # Hardened runtime and a secure timestamp are what notarization requires.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BUNDLE"
fi
codesign --verify --strict "$BUNDLE"

APP="dist/$CONFIGURATION/Lull.app"
mkdir -p "dist/$CONFIGURATION"
rm -rf "$APP"
ditto "$BUNDLE" "$APP"

echo "$ROOT/$APP"
