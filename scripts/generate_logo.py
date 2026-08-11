#!/usr/bin/env python3
"""Generate the Reminder app icon via OpenAI image generation.

Kept in the repo so the icon can be regenerated or tweaked later rather than
being an unreproducible binary blob.
"""
import base64
import os
import sys
import urllib.request
import json

PROMPT = (
    "A macOS application icon. The rounded-square icon shape must fill the "
    "entire image edge to edge, bleeding off all four sides, with absolutely no "
    "surrounding background, no drop shadow, no glow, and no border around it. "
    "The artwork is the icon face itself. "
    "Design: a smooth teal-to-aqua gradient face. Centred on it, a single "
    "elegant mark in warm cream: an open circular arc, like a cycle or orbit "
    "with a gap, enclosing a simple geometric seated human figure shown in "
    "profile tilting gently backward, suggesting posture change and rest. "
    "Minimalist geometric vector style, clean even stroke weights, generous "
    "negative space, no text, no letters, no numbers. Calm and restorative, "
    "in the visual language of Apple system icons. Flat with only very subtle "
    "depth."
)

def main():
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        sys.exit("OPENAI_API_KEY is not set")

    body = json.dumps({
        "model": "gpt-image-1",
        "prompt": PROMPT,
        "size": "1024x1024",
        "quality": "high",
        "n": 1,
    }).encode()

    req = urllib.request.Request(
        "https://api.openai.com/v1/images/generations",
        data=body,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        payload = json.load(resp)

    out = sys.argv[1] if len(sys.argv) > 1 else "Resources/icon-source.png"
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as handle:
        handle.write(base64.b64decode(payload["data"][0]["b64_json"]))
    print(f"wrote {out}")

if __name__ == "__main__":
    main()
