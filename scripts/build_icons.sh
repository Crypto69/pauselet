#!/bin/bash
#
# Builds AppIcon.icns from the vector source in Resources/icon.svg.
#
# The SVG is the single source of truth; every raster size is generated, so the
# icon can be edited in one place and rebuilt.
#
set -euo pipefail

cd "$(dirname "$0")/.."

SVG="Resources/icon.svg"
ICONSET="build/AppIcon.iconset"
OUT="Sources/ReminderApp/Resources/AppIcon.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$(dirname "$OUT")"

# The sizes macOS expects in an iconset, each at 1x and 2x.
for size in 16 32 128 256 512; do
  double=$((size * 2))
  swift scripts/rasterize.swift "$SVG" "$ICONSET/icon_${size}x${size}.png" "$size"
  swift scripts/rasterize.swift "$SVG" "$ICONSET/icon_${size}x${size}@2x.png" "$double"
done

iconutil --convert icns "$ICONSET" --output "$OUT"
echo "built $OUT"

# A monochrome template image for the menu bar. macOS tints template images
# automatically, so it adapts to light and dark menu bars.
swift scripts/rasterize.swift Resources/menubar-icon.svg \
  "Sources/ReminderApp/Resources/MenuBarIconTemplate.png" 18
swift scripts/rasterize.swift Resources/menubar-icon.svg \
  "Sources/ReminderApp/Resources/MenuBarIconTemplate@2x.png" 36
echo "built menu bar template images"
