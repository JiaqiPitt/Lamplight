#!/bin/bash
# Redraws the app icon from the scene and packs it into Resources/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
WORK="$(mktemp -d)"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
.build/release/Lamplight --make-icon "$WORK/icon.png" >/dev/null

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$WORK/icon.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$WORK/icon.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$WORK"
echo "Wrote Resources/AppIcon.icns"
