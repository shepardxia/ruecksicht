# /// script
# requires-python = ">=3.9"
# dependencies = ["pillow>=9.2"]
# ///
"""Generates every Ruecksicht icon from the vector definition of the mark.

Run: uv run Uebersicht/branding/make-icons.py
Outputs status-icon.png, status-icon@2x.png, Ruecksicht.iconset/ and Ruecksicht.icns
next to this script. Status icons are macOS template images: pure black, alpha only.
"""

import math
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent
SS = 8  # supersample factor; every shape is drawn at SS x and box-filtered down

# The mark, in em coordinates on the unit square. Stroke weight and cap height are
# calibrated so the 18pt status icon carries the same optical mass as upstream's 16pt Ü.
STEM_X = 0.135
STEM_W = 0.175
CAP_TOP = 0.090
BASELINE = 0.910
COUNTER = 0.160
LEG_END = 0.870
LEG_W = 0.920  # leg thickness as a fraction of STEM_W; diagonals read heavy

BOWL_D = COUNTER + 2 * STEM_W
BOWL_R = BOWL_D / 2
BOWL_CX = STEM_X + BOWL_R
BOWL_CY = CAP_TOP + BOWL_R
JUNCTION = CAP_TOP + BOWL_D

INK = (STEM_X, CAP_TOP, LEG_END, BASELINE)

# Dusk palette: the plate recedes, the mark carries the only warmth.
PLATE_TOP = (0x46, 0x52, 0x78)
PLATE_BOT = (0x11, 0x15, 0x21)
MARK_TOP = (0xFF, 0xE0, 0xA2)
MARK_BOT = (0xEC, 0x9E, 0x2C)
BACKLIGHT = (0x8C, 0x93, 0xC4)


def _perp_quad(p0, p1, half):
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    n = math.hypot(dx, dy)
    ox, oy = -dy / n * half, dx / n * half
    return [(p0[0] + ox, p0[1] + oy), (p1[0] + ox, p1[1] + oy),
            (p1[0] - ox, p1[1] - oy), (p0[0] - ox, p0[1] - oy)]


def draw_mark(draw, to_px, fill, hole):
    """Stamp the R. `to_px` maps em coordinates to device pixels."""
    def box(cx, cy, r):
        return [to_px(cx - r, cy - r), to_px(cx + r, cy + r)]

    draw.ellipse(_flat(box(BOWL_CX, BOWL_CY, BOWL_R)), fill=fill)
    draw.ellipse(_flat(box(BOWL_CX, BOWL_CY, BOWL_R - STEM_W)), fill=hole)

    leg = _perp_quad((STEM_X + STEM_W * 0.5, JUNCTION - STEM_W * 0.5),
                     (LEG_END - STEM_W * 0.5, BASELINE + 0.06),
                     STEM_W * LEG_W / 2)
    draw.polygon([to_px(*p) for p in leg], fill=fill)

    draw.rectangle(_flat([to_px(STEM_X, CAP_TOP), to_px(STEM_X + STEM_W, BASELINE)]), fill=fill)
    # The leg overshoots so its foot can be cut square on the baseline.
    draw.rectangle(_flat([to_px(-0.2, BASELINE), to_px(1.2, 1.4)]), fill=hole)


def _flat(pairs):
    return [pairs[0][0], pairs[0][1], pairs[1][0], pairs[1][1]]


def mark_mask(px, height, center):
    """Antialiased alpha mask of the mark, its ink box scaled to `height` px."""
    S = px * SS
    scale = height * SS / (BASELINE - CAP_TOP)
    icx, icy = (INK[0] + INK[2]) / 2, (INK[1] + INK[3]) / 2
    ox, oy = center[0] * SS, center[1] * SS

    def to_px(x, y):
        return (ox + (x - icx) * scale, oy + (y - icy) * scale)

    img = Image.new("L", (S, S), 0)
    draw_mark(ImageDraw.Draw(img), to_px, 255, 0)
    return img.resize((px, px), Image.LANCZOS)


def status_icon(px):
    """Template image: black where the mark is, transparent everywhere else."""
    mask = mark_mask(px, px * (BASELINE - CAP_TOP), (px / 2, px / 2))
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    img.putalpha(mask)
    return img


def _linear_gradient(px, top, bottom):
    strip = Image.new("RGB", (1, px))
    for y in range(px):
        t = y / max(px - 1, 1)
        strip.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return strip.resize((px, px), Image.BICUBIC)


def _radial(px, center, radius, strength):
    """Soft round falloff mask; cheap to compute small and smooth when scaled up."""
    g = 96
    img = Image.new("L", (g, g), 0)
    cx, cy, r = center[0] * g, center[1] * g, radius * g
    pix = img.load()
    for y in range(g):
        for x in range(g):
            d = math.hypot(x + 0.5 - cx, y + 0.5 - cy) / r
            if d < 1.0:
                pix[x, y] = int((1.0 - d) ** 2 * 255 * strength)
    return img.resize((px, px), Image.BICUBIC)


def _squircle(px, side, n=5.0, steps=1024):
    """Apple-style continuous-curvature plate as a superellipse mask."""
    S = px * SS
    a = side * SS / 2
    c = S / 2
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        pts.append((c + math.copysign(abs(ct) ** (2 / n), ct) * a,
                    c + math.copysign(abs(st) ** (2 / n), st) * a))
    img = Image.new("L", (S, S), 0)
    ImageDraw.Draw(img).polygon(pts, fill=255)
    return img.resize((px, px), Image.LANCZOS)


def app_icon(px):
    """Lit plate with the mark standing on it. Detail below 64px is dropped, not shrunk."""
    # Small sizes carry no shadow, so they reclaim the margin the shadow needs.
    detailed = px >= 64
    plate_side = px * (0.804 if detailed else 0.900)
    mark_h = px * (0.415 if detailed else 0.520)

    canvas = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    plate_mask = _squircle(px, plate_side)

    if detailed:
        shadow = plate_mask.filter(ImageFilter.GaussianBlur(px * 0.016)).point(
            lambda v: int(v * 0.38))
        drop = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        drop.putalpha(shadow)
        canvas.alpha_composite(drop, (0, max(1, round(px * 0.011))))

    plate = _linear_gradient(px, PLATE_TOP, PLATE_BOT).convert("RGBA")
    plate.putalpha(plate_mask)
    canvas.alpha_composite(plate)

    if detailed:
        # Light behind the mark: the plate is a surface the letter stands away from,
        # not a coloured square the letter is printed on.
        back = Image.new("RGBA", (px, px), BACKLIGHT + (0,))
        back.putalpha(ImageChops.multiply(_radial(px, (0.50, 0.44), 0.46, 0.55), plate_mask))
        canvas.alpha_composite(back)

        # A hairline of sky along the top edge gives the plate a lit rim.
        band = ImageChops.subtract(plate_mask, _squircle(px, plate_side - max(2.0, px * 0.007)))
        fade = _linear_gradient(px, (185, 185, 185), (0, 0, 0)).convert("L")
        rim = Image.new("RGBA", (px, px), (255, 255, 255, 0))
        rim.putalpha(ImageChops.multiply(band, fade))
        canvas.alpha_composite(rim)

    mask = mark_mask(px, mark_h, (px / 2, px / 2))
    if detailed:
        glow = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        glow.putalpha(mask.filter(ImageFilter.GaussianBlur(px * 0.012)).point(
            lambda v: int(v * 0.38)))
        canvas.alpha_composite(glow, (0, max(1, round(px * 0.008))))

    mark = _linear_gradient(px, MARK_TOP, MARK_BOT).convert("RGBA")
    mark.putalpha(mask)
    canvas.alpha_composite(mark)
    return canvas


ICONSET = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
           (256, 1), (256, 2), (512, 1), (512, 2)]


def main():
    for px, name in ((18, "status-icon.png"), (36, "status-icon@2x.png")):
        status_icon(px).save(OUT / name)

    iconset = OUT / "Ruecksicht.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir()
    for pt, scale in ICONSET:
        suffix = "@2x" if scale == 2 else ""
        app_icon(pt * scale).save(iconset / f"icon_{pt}x{pt}{suffix}.png")

    icns = OUT / "Ruecksicht.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)
    print(f"wrote {icns}")


if __name__ == "__main__":
    sys.exit(main())
