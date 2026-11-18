#!/bin/bash
# Builds the app and wraps it in a double-clickable bundle at build/Lamplight.app
#
#   ./scripts/build.sh           build, and replace build/Lamplight.app
#   ./scripts/build.sh --wait    the same, but if that copy is running, wait until it quits
#
# build/Lamplight.app is the copy the owner uses. It is never replaced while it is running:
# without --wait the new build is left in build/next/ and the script stops.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Lamplight.app"
NEXT="build/next/Lamplight.app"

running() { pgrep -f "$PWD/$APP/Contents/MacOS/Lamplight" >/dev/null 2>&1; }

swift build -c release

rm -rf build/next
mkdir -p "$NEXT/Contents/MacOS" "$NEXT/Contents/Resources"
cp .build/release/Lamplight "$NEXT/Contents/MacOS/Lamplight"
cp Resources/Info.plist "$NEXT/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$NEXT/Contents/Resources/AppIcon.icns"
fi
# The recorded sound packs.
if [ -d Resources/Sounds ]; then
    cp -R Resources/Sounds "$NEXT/Contents/Resources/Sounds"
fi
# An ad-hoc signature is enough to run on this Mac.
codesign --force --sign - "$NEXT" >/dev/null 2>&1 || echo "note: could not sign the app; it will still run"

if running; then
    if [ "${1:-}" != "--wait" ]; then
        echo "Lamplight is running from $APP, so it was not replaced. The new build is in $NEXT."
        echo "Quit Lamplight and run this again, or use: ./scripts/build.sh --wait"
        exit 1
    fi
    echo "Lamplight is running; the new build goes in as soon as it quits."
    while running; do sleep 0.3; done
fi

# Swap the finished bundle in by renaming, so there is never a half-copied app at that path.
rm -rf build/previous.app
if [ -d "$APP" ]; then mv "$APP" build/previous.app; fi
mv "$NEXT" "$APP"
rm -rf build/previous.app build/next

echo "Built $APP"
