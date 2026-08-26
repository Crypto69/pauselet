#!/usr/bin/env python3
"""Generates the Windows app's binary assets into Windows/Pauselet.App/Assets.

Run from anywhere; paths are resolved relative to this file. Requires Pillow
and fonttools (the font step downloads its ~10 MB source into scripts/cache/
on first run).

Produces:
- Pauselet.ico        — app icon, from Resources/icon-master.png
- TrayLight.ico       — tray glyph for a LIGHT taskbar (dark strokes)
- TrayDark.ico        — tray glyph for a DARK taskbar (white strokes)
- Sounds/*.wav        — synthesized placeholder chimes
- Fonts/MaterialSymbolsSubset.ttf — the reminder-icon glyphs, subset from
  Google's Material Symbols (Apache 2.0; licence copied alongside). The
  built-in Segoe fonts have no human-figure glyphs, and SF Symbols cannot
  ship on Windows — this is what lets "figure.seated.side" actually look
  like someone reclining. The SF-name → codepoint table lives in
  SymbolMap.cs and must stay in step with SUBSET_GLYPHS below.

The tray glyphs are recolored from the Mac menu bar template image
(Sources/ReminderApp/Resources/MenuBarIconTemplate@2x.png), which is a black
silhouette with alpha — the same source the Mac app tints automatically.
Windows has no template-image tinting, so both variants are baked here.

The sounds are deliberately simple synthesized chimes (sine partials with an
exponential decay), standing in for macOS system sounds that cannot ship with
the app. Replace with properly designed CC0 recordings before release; the
name mapping lives in Sounds.cs.
"""

import math
import struct
import wave
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "Windows" / "Pauselet.App" / "Assets"
SOUNDS = ASSETS / "Sounds"

ICO_SIZES = [(16, 16), (20, 20), (24, 24), (32, 32), (48, 48), (64, 64), (256, 256)]
TRAY_SIZES = [(16, 16), (20, 20), (24, 24), (32, 32)]


def build_app_icon() -> None:
    master = Image.open(ROOT / "Resources" / "icon-master.png").convert("RGBA")
    ASSETS.mkdir(parents=True, exist_ok=True)
    master.save(ASSETS / "Pauselet.ico", sizes=ICO_SIZES)
    print("wrote", ASSETS / "Pauselet.ico")


def recolor(template: Image.Image, rgb: tuple[int, int, int]) -> Image.Image:
    """Keeps the template's alpha, replaces its color entirely."""
    alpha = template.getchannel("A")
    solid = Image.new("RGBA", template.size, rgb + (255,))
    solid.putalpha(alpha)
    return solid


def build_tray_icons() -> None:
    template = Image.open(
        ROOT / "Sources" / "ReminderApp" / "Resources" / "MenuBarIconTemplate@2x.png"
    ).convert("RGBA")
    # Dark strokes for a light taskbar; white for the (default) dark one.
    recolor(template, (32, 32, 32)).save(ASSETS / "TrayLight.ico", sizes=TRAY_SIZES)
    recolor(template, (255, 255, 255)).save(ASSETS / "TrayDark.ico", sizes=TRAY_SIZES)
    print("wrote", ASSETS / "TrayLight.ico", "and TrayDark.ico")


RATE = 44100


def synth(partials, duration, decay, attack=0.008, gain=0.22):
    """A struck-bell tone: sine partials under an exponential decay."""
    samples = []
    count = int(RATE * duration)
    for i in range(count):
        t = i / RATE
        envelope = math.exp(-t / decay)
        if t < attack:
            envelope *= t / attack
        value = sum(
            amplitude * math.sin(2 * math.pi * freq * t)
            for freq, amplitude in partials
        )
        samples.append(gain * envelope * value)
    return samples


def mix(*clips_with_offsets):
    length = max(int(offset * RATE) + len(clip) for clip, offset in clips_with_offsets)
    out = [0.0] * length
    for clip, offset in clips_with_offsets:
        start = int(offset * RATE)
        for i, sample in enumerate(clip):
            out[start + i] += sample
    return out


def write_wav(name: str, samples) -> None:
    SOUNDS.mkdir(parents=True, exist_ok=True)
    path = SOUNDS / f"{name}.wav"
    peak = max(1.0, max(abs(s) for s in samples) / 0.85)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        frames = b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s / peak)) * 32767))
            for s in samples
        )
        handle.writeframes(frames)
    print("wrote", path)


def build_sounds() -> None:
    bell = [(880, 1.0), (1320, 0.5), (1760, 0.25), (2640, 0.12)]
    low = [(220, 1.0), (330, 0.55), (440, 0.3), (660, 0.12)]
    glass = [(1568, 1.0), (2352, 0.4), (3136, 0.2)]
    pluck = [(660, 1.0), (1320, 0.35), (1980, 0.1)]

    write_wav("chime-soft", synth(bell, 1.4, 0.45))
    write_wav("chime-low", synth(low, 2.0, 0.7))
    write_wav("chime-glass", synth(glass, 0.9, 0.25))
    write_wav("chime-pluck", synth(pluck, 0.6, 0.12))
    write_wav(
        "chime-double",
        mix((synth(bell, 0.8, 0.22), 0.0), (synth(bell, 1.0, 0.35), 0.28)),
    )
    write_wav(
        "chime-triad",
        mix(
            (synth([(523, 1.0), (1046, 0.3)], 0.7, 0.3), 0.0),
            (synth([(659, 1.0), (1318, 0.3)], 0.7, 0.3), 0.18),
            (synth([(784, 1.0), (1568, 0.3)], 1.1, 0.45), 0.36),
        ),
    )


FONT_URL = (
    "https://github.com/google/material-design-icons/raw/master/variablefont/"
    "MaterialSymbolsOutlined%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf"
)
LICENSE_URL = (
    "https://raw.githubusercontent.com/google/material-design-icons/master/LICENSE"
)

# Material Symbols names and codepoints kept by the subset — everything
# SymbolMap.cs maps to, plus a couple of spares for future mappings.
SUBSET_GLYPHS = {
    "accessibility_new": 0xE92C,
    "account_box": 0xE851,
    "airline_seat_recline_extra": 0xE636,
    "alarm": 0xE855,
    "auto_awesome": 0xE65F,
    "bedtime": 0xF159,
    "calendar_month": 0xEBCC,
    "call": 0xF0D4,
    "check_circle": 0xF0BE,
    "clean_hands": 0xF21F,
    "desktop_windows": 0xE30C,
    "directions_walk": 0xE536,
    "eco": 0xEA35,
    "favorite": 0xE87E,
    "home": 0xE9B2,
    "keyboard": 0xE312,
    "light_mode": 0xE518,
    "local_cafe": 0xEB44,
    "mail": 0xE159,
    "medication": 0xF033,
    "menu_book": 0xEA19,
    "motion_photos_on": 0xE9C1,
    "music_note": 0xE405,
    "notification_important": 0xE004,
    "notifications": 0xE7F5,
    "notifications_off": 0xE7F6,
    "notifications_unread": 0xF4FE,
    "pause_circle": 0xE1A2,
    "pets": 0xE91D,
    "photo_camera": 0xE412,
    "play_circle": 0xE1C4,
    "psychology": 0xEA4A,
    "public": 0xE80B,
    "pulmonology": 0xE124,
    "radio_button_unchecked": 0xE836,
    "restaurant": 0xE56C,
    "schedule": 0xEFD6,
    "self_improvement": 0xEA78,
    "settings": 0xE8B8,
    "smart_display": 0xF06A,
    "sports_esports": 0xEA28,
    "sports_gymnastics": 0xEBC4,
    "swap_vertical_circle": 0xE8D6,
    "timer": 0xE425,
    "visibility": 0xE8F4,
    "warning": 0xF083,
    "water_drop": 0xE798,
}


def build_icon_font() -> None:
    import urllib.request

    from fontTools import subset
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont

    cache = Path(__file__).parent / "cache"
    cache.mkdir(exist_ok=True)
    source = cache / "MaterialSymbolsOutlined-variable.ttf"
    if not source.exists():
        print("downloading", FONT_URL)
        urllib.request.urlretrieve(FONT_URL, source)

    fonts_dir = ASSETS / "Fonts"
    fonts_dir.mkdir(parents=True, exist_ok=True)
    licence = fonts_dir / "LICENSE-MaterialSymbols.txt"
    if not licence.exists():
        urllib.request.urlretrieve(LICENSE_URL, licence)

    font = TTFont(source)
    # Pin the variable axes to the regular outlined style: a static font
    # sidesteps any variable-font quirks in WPF's text stack.
    instantiateVariableFont(
        font, {"wght": 400, "FILL": 0, "GRAD": 0, "opsz": 24}, inplace=True
    )

    subsetter = subset.Subsetter()
    subsetter.populate(unicodes=sorted(SUBSET_GLYPHS.values()))
    subsetter.subset(font)

    out = fonts_dir / "MaterialSymbolsSubset.ttf"
    font.save(out)
    print(f"wrote {out} ({out.stat().st_size} bytes, {len(SUBSET_GLYPHS)} glyphs)")


if __name__ == "__main__":
    build_app_icon()
    build_tray_icons()
    build_sounds()
    build_icon_font()
