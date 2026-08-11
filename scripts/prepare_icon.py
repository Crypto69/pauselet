#!/usr/bin/env python3
"""Prepares Resources/icon-source.png for use as a macOS app icon.

The source artwork is a full-bleed square. macOS expects an app icon to be a
rounded "squircle" with transparent corners, and to sit inside a small margin
so it does not look oversized next to system icons. This script does both, and
writes Resources/icon-master.png at 1024x1024 for the .icns build.

Run via scripts/build_icons.sh; kept separate so the shaping can be tweaked
without touching the build.
"""
import sys
from PIL import Image, ImageDraw

# Apple's icon grid: the artwork occupies roughly 80% of the canvas, leaving a
# transparent margin so icons line up optically in the Dock.
CANVAS = 1024
CONTENT = 824
# Corner radius as a fraction of the content square, matching the macOS squircle.
RADIUS_RATIO = 0.2237


def rounded_mask(size: int, radius: int) -> Image.Image:
    """A high-quality antialiased rounded-rectangle mask."""
    # Draw at 4x and downsample, which gives smoother corners than drawing
    # directly at the target size.
    scale = 4
    mask = Image.new("L", (size * scale, size * scale), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (0, 0, size * scale - 1, size * scale - 1),
        radius=radius * scale,
        fill=255,
    )
    return mask.resize((size, size), Image.LANCZOS)


def content_bounds(image: Image.Image, tolerance: int = 26):
    """The bounding box of everything that is not the flat background colour.

    The source artwork carries a wide band of empty background. Simply scaling
    the whole square down would leave the mark looking small next to other
    icons, so we find the artwork and crop to it instead.
    """
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    background = pixels[8, 8]

    def differs(colour):
        return sum(abs(a - b) for a, b in zip(colour, background)) > tolerance

    left, right, top, bottom = width, 0, height, 0
    for y in range(0, height, 2):
        for x in range(0, width, 2):
            if differs(pixels[x, y]):
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
    if right <= left or bottom <= top:
        return None, background
    return (left, top, right, bottom), background


def main() -> int:
    source_path = sys.argv[1] if len(sys.argv) > 1 else "Resources/icon-source.png"
    output_path = sys.argv[2] if len(sys.argv) > 2 else "Resources/icon-master.png"

    source = Image.open(source_path).convert("RGBA")

    bounds, background = content_bounds(source)
    if bounds is None:
        # No detectable artwork; fall back to a plain centre crop.
        edge = min(source.size)
        left = (source.width - edge) // 2
        top = (source.height - edge) // 2
        source = source.crop((left, top, left + edge, top + edge))
    else:
        left, top, right, bottom = bounds
        # Square crop centred on the artwork, with a small breathing margin so
        # the mark is not jammed against the rounded corners.
        centre_x = (left + right) // 2
        centre_y = (top + bottom) // 2
        art_edge = max(right - left, bottom - top)
        edge = int(art_edge * 1.16)
        edge = min(edge, source.width, source.height)

        crop_left = centre_x - edge // 2
        crop_top = centre_y - edge // 2
        # Keep the crop inside the image.
        crop_left = max(0, min(crop_left, source.width - edge))
        crop_top = max(0, min(crop_top, source.height - edge))

        # Paste onto a background-coloured square first, so if the crop runs
        # past an edge the gap is filled with the artwork's own navy rather
        # than transparency.
        squared = Image.new("RGBA", (edge, edge), background + (255,))
        region = source.crop(
            (crop_left, crop_top, crop_left + edge, crop_top + edge)
        )
        squared.paste(region, (0, 0))
        source = squared

    art = source.resize((CONTENT, CONTENT), Image.LANCZOS)

    # Round the corners.
    radius = int(CONTENT * RADIUS_RATIO)
    art.putalpha(rounded_mask(CONTENT, radius))

    # Centre it on a transparent 1024 canvas.
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - CONTENT) // 2
    canvas.paste(art, (offset, offset), art)
    canvas.save(output_path)

    print(f"wrote {output_path} ({CANVAS}x{CANVAS}, content {CONTENT}px)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
