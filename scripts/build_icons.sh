#!/bin/bash
#
# Builds AppIcon.icns from the vector source in Resources/icon.svg.
#
# The SVG is the single source of truth; every raster size is generated, so the
# icon can be edited in one place and rebuilt.
#
set -euo pipefail

cd "$(dirname "$0")/.."

ICONSET="build/AppIcon.iconset"
OUT="Sources/ReminderApp/Resources/AppIcon.icns"
MASTER="Resources/icon-master.png"

# Shape the artwork into a rounded, correctly-inset 1024px master.
python3 scripts/prepare_icon.py Resources/icon-source.png "$MASTER"

rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$(dirname "$OUT")"

# The sizes macOS expects in an iconset, each at 1x and 2x, downsampled from
# the master with Lanczos so small sizes stay sharp.
for size in 16 32 128 256 512; do
  double=$((size * 2))
  python3 -c "
from PIL import Image
m = Image.open('$MASTER')
m.resize(($size, $size), Image.LANCZOS).save('$ICONSET/icon_${size}x${size}.png')
m.resize(($double, $double), Image.LANCZOS).save('$ICONSET/icon_${size}x${size}@2x.png')
"
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
