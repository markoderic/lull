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

APP="dist/$CONFIGURATION/Lull.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Lull" "$APP/Contents/MacOS/Lull"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
else
    # Hardened runtime and a secure timestamp are what notarization requires.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

echo "$ROOT/$APP"
