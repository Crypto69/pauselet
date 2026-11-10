#!/usr/bin/env python3
"""Generates the MSIX package's icons in Windows/Packaging/Images/.

Run after changing Resources/icon-master.png:

    python3 Windows/Packaging/build_images.py

Needs Pillow. The PNGs are committed, so CI does not need Python.

The master is the Mac icon: the artwork sits inside a 100 px transparent
margin, the macOS grid. Windows icons are drawn edge to edge, so the
artwork is cropped to its bounds first. Start tiles keep some breathing
room around it, the way Windows' own tiles do.

Names follow the MSIX resource convention (Square44x44Logo.scale-200.png,
.targetsize-24_altform-unplated.png, ...); makepri indexes them and Windows
picks the right size for each place.
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent / "Images"

SCALES = {100: 1.0, 125: 1.25, 150: 1.5, 200: 2.0, 400: 4.0}


def artwork() -> Image.Image:
    master = Image.open(ROOT / "Resources" / "icon-master.png").convert("RGBA")
    return master.crop(master.getchannel("A").getbbox())


def fitted(art: Image.Image, width: int, height: int, fill: float) -> Image.Image:
    """The artwork centred on a transparent canvas, its side `fill` of the shorter edge."""
    side = max(1, round(min(width, height) * fill))
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    icon = art.resize((side, side), Image.LANCZOS)
    canvas.paste(icon, ((width - side) // 2, (height - side) // 2), icon)
    return canvas


def save(image: Image.Image, name: str) -> None:
    image.save(OUT / name)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.png"):
        old.unlink()
    art = artwork()

    # Start list, taskbar, notifications, Settings.
    for scale, factor in SCALES.items():
        side = round(44 * factor)
        save(fitted(art, side, side, 1.0), f"Square44x44Logo.scale-{scale}.png")
    for size in (16, 24, 32, 48, 256):
        icon = fitted(art, size, size, 1.0)
        save(icon, f"Square44x44Logo.targetsize-{size}.png")
        save(icon, f"Square44x44Logo.targetsize-{size}_altform-unplated.png")
        save(icon, f"Square44x44Logo.targetsize-{size}_altform-lightunplated.png")

    # Start tiles.
    for scale in (100, 125, 150, 200, 400):
        factor = SCALES[scale]
        side = round(150 * factor)
        save(fitted(art, side, side, 0.66), f"Square150x150Logo.scale-{scale}.png")
        save(
            fitted(art, round(310 * factor), round(150 * factor), 0.66),
            f"Wide310x150Logo.scale-{scale}.png",
        )

    # The package logo.
    for scale, factor in SCALES.items():
        side = round(50 * factor)
        save(fitted(art, side, side, 1.0), f"StoreLogo.scale-{scale}.png")

    print(f"wrote {len(list(OUT.glob('*.png')))} images to {OUT}")


if __name__ == "__main__":
    main()
