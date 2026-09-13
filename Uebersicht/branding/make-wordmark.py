# /// script
# requires-python = ">=3.9"
# dependencies = ["pillow>=9.2"]
# ///
"""Generates the Ruecksicht wordmark seeded into every new widget folder.

Run: uv run Uebersicht/branding/make-wordmark.py
Outputs ruecksicht-logo.png next to this script, at the 352x168 the Getting
Started widget's background-size expects.
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent
W, H = 352, 168
MARGIN = 24
SS = 4  # supersample factor; drawn at SS x and box-filtered down

INK = (20, 25, 45, 255)
RULE = (20, 25, 45, 60)
IPA_INK = (20, 25, 45, 150)

WORD = "Rücksicht"
IPA = "[ˈʁʏkˌzɪçt]"

# A face has to carry both the wordmark and the IPA glyphs; the IPA line falls
# back separately because far fewer faces cover it.
WORD_FACES = [
    "/System/Library/Fonts/Supplemental/Futura.ttc",
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial.ttf",
]
IPA_FACES = [
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial.ttf",
]


def load(faces, size, index=0):
    for path in faces:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size, index=index)
            except OSError:
                continue
    return None


def covers(font, text):
    """A face silently renders missing glyphs as blank, so check before trusting it."""
    if font is None:
        return False
    size = font.size
    probe = Image.new("L", (size * len(text) + size, size * 3), 0)
    ImageDraw.Draw(probe).text((size // 2, size // 2), text, font=font, fill=255)
    return probe.getbbox() is not None


def fit(faces, text, max_width, max_size):
    """Largest size at which the word still clears the margins."""
    for size in range(max_size, 8, -1):
        font = load(faces, size * SS)
        if font is None:
            return None
        left, _, right, _ = ImageDraw.Draw(
            Image.new("RGBA", (1, 1))).textbbox((0, 0), text, font=font)
        if right - left <= max_width * SS:
            return font
    return None


def main():
    word_font = fit(WORD_FACES, WORD, W - 2 * MARGIN, 104)
    if not covers(word_font, WORD):
        print("no available face renders the wordmark", file=sys.stderr)
        return 1

    ipa_font = None
    for face in IPA_FACES:
        candidate = load([face], 25 * SS)
        if covers(candidate, IPA):
            ipa_font = candidate
            break
    if ipa_font is None:
        print("no available face covers the IPA glyphs", file=sys.stderr)
        return 1

    image = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    rule_y = 122 * SS

    left, top, right, bottom = draw.textbbox((0, 0), WORD, font=word_font)
    draw.text(((W * SS - (right - left)) / 2 - left,
               (rule_y - (bottom - top)) / 2 - top),
              WORD, font=word_font, fill=INK)

    draw.rectangle([MARGIN * SS, rule_y, (W - MARGIN) * SS, rule_y + SS], fill=RULE)

    left, top, right, bottom = draw.textbbox((0, 0), IPA, font=ipa_font)
    draw.text(((W * SS - (right - left)) / 2 - left, 132 * SS - top),
              IPA, font=ipa_font, fill=IPA_INK)

    image.resize((W, H), Image.LANCZOS).save(OUT / "ruecksicht-logo.png")
    print(f"wrote {OUT / 'ruecksicht-logo.png'} ({W}x{H})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
