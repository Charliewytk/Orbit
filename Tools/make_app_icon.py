#!/usr/bin/env python3
"""Renders Orbit's app icon at every size the asset catalog needs.

A pastel gradient squircle (sage → lavender → blush) with a bold near-black
planet, its orbit ring passing behind and in front, and a small pink moon.
macOS sizes get the Big Sur grid (824 pt body, soft drop shadow); the iOS
1024 is full-bleed (the system applies its own mask).

    pip install pillow
    python3 Tools/make_app_icon.py
"""
import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "App", "Shared", "Resources", "Assets.xcassets", "AppIcon.appiconset")

SAGE = (220, 235, 216)
LAVENDER = (227, 221, 246)
BLUSH = (248, 220, 218)
BUTTER = (250, 239, 194)
INK = (21, 21, 21)
MOON = (232, 132, 154)
S = 2048  # working size (downscaled at the end for smooth edges)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def gradient(size):
    """Diagonal sage → lavender → blush, with a warm butter glow top-right."""
    small = 128
    img = Image.new("RGB", (small, small))
    px = img.load()
    for y in range(small):
        for x in range(small):
            t = (x + y) / (2 * (small - 1))
            c = lerp(SAGE, LAVENDER, t / 0.5) if t < 0.5 else lerp(LAVENDER, BLUSH, (t - 0.5) / 0.5)
            # Butter glow in the top-right corner.
            d = ((x - small) ** 2 + y ** 2) ** 0.5 / small
            g = max(0.0, 1 - d / 0.75) * 0.55
            px[x, y] = lerp(c, BUTTER, g)
    return img.resize((size, size), Image.BICUBIC)


def squircle_mask(size, inset, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((inset, inset, size - inset, size - inset), radius=radius, fill=255)
    return mask


def mark(size):
    """Planet + orbit ring + moon on a transparent layer, rotated as one."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cx = cy = size / 2
    ring_w, ring_h, stroke = size * 0.80, size * 0.30, size * 0.052
    planet_r = size * 0.205
    box = (cx - ring_w / 2, cy - ring_h / 2, cx + ring_w / 2, cy + ring_h / 2)

    ring = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse(box, outline=INK + (255,), width=int(stroke))

    # Back half of the ring, then the planet, then the front half over it.
    layer.alpha_composite(ring)
    d = ImageDraw.Draw(layer)
    # A thin gap around the planet so the front ring reads as "in front".
    gap = size * 0.03
    d.ellipse((cx - planet_r - gap, cy - planet_r - gap, cx + planet_r + gap, cy + planet_r + gap), fill=(0, 0, 0, 0))
    layer = Image.alpha_composite(Image.new("RGBA", (size, size), (0, 0, 0, 0)), layer)
    d = ImageDraw.Draw(layer)
    d.ellipse((cx - planet_r, cy - planet_r, cx + planet_r, cy + planet_r), fill=INK + (255,))
    # Soft highlight on the planet.
    hl = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(hl).ellipse((cx - planet_r * 0.62, cy - planet_r * 0.72, cx - planet_r * 0.05, cy - planet_r * 0.2),
                               fill=(255, 255, 255, 46))
    layer.alpha_composite(hl.filter(ImageFilter.GaussianBlur(size * 0.012)))

    front = ring.crop((0, int(cy), size, size))
    layer.alpha_composite(front, (0, int(cy)))

    # The moon sits on the ring, upper right.
    mr = size * 0.062
    mx, my = cx + ring_w * 0.40, cy - ring_h * 0.18
    d = ImageDraw.Draw(layer)
    d.ellipse((mx - mr - stroke * 0.55, my - mr - stroke * 0.55, mx + mr + stroke * 0.55, my + mr + stroke * 0.55),
              fill=(255, 255, 255, 255))
    d.ellipse((mx - mr, my - mr, mx + mr, my + mr), fill=MOON + (255,))
    return layer.rotate(24, resample=Image.BICUBIC, center=(cx, cy))


def render(full_bleed):
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    if full_bleed:
        inset, radius = 0, 0
    else:
        inset = int(S * 100 / 1024)          # 824 / 1024 body
        radius = int((S - 2 * inset) * 0.225)
    body = gradient(S).convert("RGBA")
    mask = squircle_mask(S, inset, radius) if radius else Image.new("L", (S, S), 255)

    if not full_bleed:
        shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        sm = squircle_mask(S, inset, radius).point(lambda v: int(v * 0.28))
        shadow.putalpha(sm)
        shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.018))
        canvas.alpha_composite(shadow, (0, int(S * 0.012)))

    tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    tile.paste(body, (0, 0), mask)
    size = S - 2 * inset
    m = mark(size)
    scale = 0.86
    m = m.resize((int(size * scale), int(size * scale)), Image.LANCZOS)
    off = inset + (size - m.width) // 2
    tile.alpha_composite(m, (off, off))
    # Keep the mark inside the squircle.
    clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    clipped.paste(tile, (0, 0), mask)
    canvas.alpha_composite(clipped)
    return canvas


def main():
    mac = render(full_bleed=False)
    ios = render(full_bleed=True).convert("RGB")  # iOS icons must be opaque
    ios.resize((1024, 1024), Image.LANCZOS).save(os.path.join(OUT, "icon-ios-1024.png"))
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            mac.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, f"icon-mac-{pt}@{scale}x.png"))
    print("Wrote icons to", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
