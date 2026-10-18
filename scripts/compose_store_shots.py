#!/usr/bin/env python3
"""Compose Mac App Store screenshots from the snapshot harness output.

The harness renders each surface at its natural size. The store wants
2880x1800 frames, so each surface is placed on a backdrop with a caption.

Usage:
    ./scripts/build_app.sh
    dist/Pauselet.app/Contents/MacOS/Pauselet --snapshot build/ui2x --snapshot-scale 2
    python3 scripts/compose_store_shots.py build/ui2x dist/mac-app-store-screenshots
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

W, H = 2880, 1800
MARGIN = 150
CAPTION_TOP = 110
GAP_BELOW_CAPTION = 80

# Dark slate that suits both the light popover and the dark overlays, with the
# app's teal as the accent.
BG_TOP = (18, 22, 28)
BG_BOTTOM = (10, 13, 17)
TEXT = (245, 247, 250)
SUBTEXT = (150, 160, 175)

FRAMES = [
    ("overlay-exercise-coach.png", "It counts you through your physio programme",
     "Every exercise coached, set by set, with the cues spoken aloud"),
    ("popover.png", "Everything in the menu bar",
     "What is next, how long you have, and a pause button"),
    ("overlay-critical.png", "When it matters, it takes the screen",
     "A Critical reminder dims every display until you answer it"),
    ("editor-exercise-section.png", "Paste the handout, not the numbers",
     "Pauselet reads sets, reps and hold times on your own Mac"),
    ("editor-new.png", "Four levels of interruption",
     "Each reminder decides how much attention it is allowed to take"),
    ("preferences.png", "Quiet hours, snooze, and a voice coach",
     "Every setting explained, with a button rather than a tooltip"),
    ("settings.png", "See whether you are actually doing them",
     "Adherence per reminder over a day, a week or a month"),
    ("about.png", "Built for one hourly reminder that could not be missed",
     "Free, no account, and everything stays on your Mac"),
]

# Surfaces whose view is shorter than the frame the harness renders it in.
# Trimming the dead space stops them being scaled down to fit empty pixels.
TRIM_BOTTOM = {
    "about.png": 0.27,
}


def font(size, bold=False):
    name = "SFNS.ttf" if not bold else "SFNS.ttf"
    for path in (
        f"/System/Library/Fonts/{name}",
        "/System/Library/Fonts/Helvetica.ttc",
    ):
        try:
            f = ImageFont.truetype(path, size)
            if bold and path.endswith("SFNS.ttf"):
                try:
                    return ImageFont.truetype(path, size, index=0)
                except Exception:
                    return f
            return f
        except Exception:
            continue
    return ImageFont.load_default()


def backdrop():
    img = Image.new("RGB", (W, H), BG_TOP)
    draw = ImageDraw.Draw(img)
    for y in range(H):
        t = y / H
        draw.line(
            [(0, y), (W, y)],
            fill=tuple(
                int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3)
            ),
        )
    return img


def rounded(img, radius=28):
    """Round the corners of a surface so it reads as a window, not a crop."""
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [(0, 0), (img.size[0] - 1, img.size[1] - 1)], radius=radius, fill=255
    )
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def compose(surface_path, title, subtitle, out_path):
    canvas = backdrop()
    draw = ImageDraw.Draw(canvas)

    title_font = font(86, bold=True)
    sub_font = font(46)

    draw.text((W // 2, CAPTION_TOP), title, font=title_font, fill=TEXT, anchor="mt")
    draw.text(
        (W // 2, CAPTION_TOP + 120), subtitle, font=sub_font, fill=SUBTEXT, anchor="mt"
    )

    surface = Image.open(surface_path).convert("RGBA")

    trim = TRIM_BOTTOM.get(Path(surface_path).name)
    if trim:
        keep = int(surface.height * (1 - trim))
        surface = surface.crop((0, 0, surface.width, keep))

    top = CAPTION_TOP + 120 + GAP_BELOW_CAPTION + 60
    avail_h = H - top - MARGIN
    avail_w = W - MARGIN * 2

    # Fill the available height, so a narrow surface like the popover is as
    # tall as a wide one rather than floating in the middle of the frame.
    # Capped so a surface is never blown up past 2.2x its rendered pixels,
    # which would soften the text.
    ratio = min(
        avail_h / surface.height,
        avail_w / surface.width,
        2.2,
    )

    new_size = (int(surface.width * ratio), int(surface.height * ratio))
    surface = surface.resize(new_size, Image.LANCZOS)
    surface = rounded(surface)

    x = (W - surface.width) // 2
    y = top + (avail_h - surface.height) // 2

    # A soft shadow so the surface sits on the backdrop rather than floating.
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [(x, y + 14), (x + surface.width, y + surface.height + 14)],
        radius=28, fill=(0, 0, 0, 110),
    )
    from PIL import ImageFilter
    shadow = shadow.filter(ImageFilter.GaussianBlur(26))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow)

    canvas.paste(surface, (x, y), surface)
    canvas.convert("RGB").save(out_path, "PNG")
    return out_path


def main():
    src = Path(sys.argv[1] if len(sys.argv) > 1 else "build/ui2x")
    dst = Path(sys.argv[2] if len(sys.argv) > 2 else "dist/mac-app-store-screenshots")
    dst.mkdir(parents=True, exist_ok=True)

    made = 0
    for i, (name, title, subtitle) in enumerate(FRAMES, 1):
        surface = src / name
        if not surface.exists():
            print(f"  skip {name}: not rendered")
            continue
        out = dst / f"{i:02d}-{name}"
        compose(surface, title, subtitle, out)
        print(f"  {out}")
        made += 1
    print(f"{made} frames at {W}x{H}")


if __name__ == "__main__":
    main()
