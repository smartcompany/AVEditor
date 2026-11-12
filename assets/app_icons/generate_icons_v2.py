#!/usr/bin/env python3
"""5 creative AVEditor icons — non-black, bright, inventive backgrounds."""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageEnhance

OUT = Path(__file__).resolve().parent
SIZE = 1024
SCALE = 2
RS = SIZE * SCALE

ACCENT = (255, 72, 72)
CYAN = (64, 196, 230)
GOLD = (212, 170, 100)
INK = (40, 36, 42)
PEARL = (255, 252, 248)
CREAM = (255, 245, 232)


def s(v: float) -> float:
    return v * SCALE


def box(*xy):
    return [s(v) for v in xy]


def clamp_u8(a):
    return np.clip(a, 0, 255).astype(np.uint8)


def mix(a, b, t):
    t = float(np.clip(t, 0, 1))
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def save(img: Image.Image, name: str) -> Path:
    path = OUT / name
    out = img.convert("RGBA").resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    out = out.filter(ImageFilter.UnsharpMask(radius=1.3, percent=85, threshold=2))
    out = ImageEnhance.Color(out).enhance(1.1)
    out = ImageEnhance.Contrast(out).enhance(1.04)
    out.convert("RGB").save(path, "PNG", optimize=True)
    return path


def radial(size, inner, outer, power=1.05, cx=None, cy=None):
    cx = size / 2 if cx is None else cx
    cy = size / 2 if cy is None else cy
    ys, xs = np.ogrid[:size, :size]
    max_r = math.hypot(max(cx, size - cx), max(cy, size - cy))
    t = np.clip((np.hypot(xs - cx, ys - cy) / max_r) ** power, 0, 1)[..., None]
    rgb = np.array(inner, np.float32) + (np.array(outer, np.float32) - np.array(inner, np.float32)) * t
    alpha = np.full((size, size, 1), 255, np.uint8)
    return Image.fromarray(np.concatenate([clamp_u8(rgb), alpha], 2), "RGBA")


def linear(size, c1, c2, angle=135):
    ang = math.radians(angle)
    ys, xs = np.ogrid[:size, :size]
    u = xs * math.cos(ang) + ys * math.sin(ang)
    u = (u - u.min()) / (u.max() - u.min() + 1e-6)
    rgb = np.array(c1, np.float32) + (np.array(c2, np.float32) - np.array(c1, np.float32)) * u[..., None]
    # soft highlight band
    streak = np.exp(-((u - 0.32) ** 2) / 0.02)[..., None]
    rgb = rgb + (np.array(PEARL, np.float32) - rgb) * streak * 0.25
    alpha = np.full((size, size, 1), 255, np.uint8)
    return Image.fromarray(np.concatenate([clamp_u8(rgb), alpha], 2), "RGBA")


def mesh_bg(c_tl, c_tr, c_bl, c_br):
    """Soft 4-corner mesh gradient — lively, not black."""
    ys = np.linspace(0, 1, RS)[:, None]
    xs = np.linspace(0, 1, RS)[None, :]
    top = np.array(c_tl, np.float32) + (np.array(c_tr, np.float32) - np.array(c_tl, np.float32)) * xs[..., None]
    bot = np.array(c_bl, np.float32) + (np.array(c_br, np.float32) - np.array(c_bl, np.float32)) * xs[..., None]
    rgb = top + (bot - top) * ys[..., None]
    alpha = np.full((RS, RS, 1), 255, np.uint8)
    return Image.fromarray(np.concatenate([clamp_u8(rgb), alpha], 2), "RGBA")


def soft_blobs(base: Image.Image, blobs):
    overlay = Image.new("RGBA", (RS, RS), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    for x, y, r, color, a in blobs:
        d.ellipse([s(x - r), s(y - r), s(x + r), s(y + r)], fill=color + (a,))
    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=s(70)))
    return Image.alpha_composite(base, overlay)


def mask_draw(fn) -> Image.Image:
    m = Image.new("L", (RS, RS), 0)
    fn(ImageDraw.Draw(m))
    return m


def fill_mask(mask, material: Image.Image) -> Image.Image:
    out = material.copy().convert("RGBA")
    out.putalpha(mask)
    return out


def solid_mask(mask, color, alpha=255) -> Image.Image:
    layer = Image.new("RGBA", (RS, RS), color + (255,))
    layer.putalpha(mask.point(lambda p: int(p * alpha / 255)))
    return layer


def shadow(mask, ox=8, oy=14, blur=20, alpha=70):
    sh = Image.new("RGBA", (RS, RS), (0, 0, 0, 255))
    a = mask.point(lambda p: min(255, int(p * alpha / 255)))
    sh.putalpha(a)
    sh = ImageChops.offset(sh, int(s(ox)), int(s(oy)))
    return sh.filter(ImageFilter.GaussianBlur(radius=s(blur)))


def glow(mask, color, blur=22, alpha=110):
    layer = Image.new("RGBA", (RS, RS), color + (255,))
    layer.putalpha(mask.point(lambda p: min(255, int(p * alpha / 255))))
    return layer.filter(ImageFilter.GaussianBlur(radius=s(blur)))


def play_pts(cx, cy, size):
    h, w = size, size * 0.86
    return [
        (cx - w * 0.35, cy - h * 0.5),
        (cx - w * 0.35, cy + h * 0.5),
        (cx + w * 0.55, cy),
    ]


def poly_m(pts):
    return mask_draw(lambda d: d.polygon([(s(x), s(y)) for x, y in pts], fill=255))


def round_m(xy, r):
    return mask_draw(lambda d: d.rounded_rectangle(box(*xy), radius=s(r), fill=255))


def ellipse_m(xy):
    return mask_draw(lambda d: d.ellipse(box(*xy), fill=255))


def rim(mask, color, width=3, alpha=180):
    edge = mask.filter(ImageFilter.MaxFilter(size=max(3, int(s(width) * 2 + 1) | 1)))
    edge = ImageChops.subtract(edge, mask)
    return solid_mask(edge, color, alpha)


def metal(c1, c2, c3, angle=120):
    ang = math.radians(angle)
    ys, xs = np.ogrid[:RS, :RS]
    u = xs * math.cos(ang) + ys * math.sin(ang)
    u = (u - u.min()) / (u.max() - u.min() + 1e-6)
    bands = 0.5 + 0.5 * np.sin(u * math.pi * 14)
    t = np.clip(u * 0.9 + bands * 0.06, 0, 1)
    a1, a2, a3 = map(lambda c: np.array(c, np.float32), (c1, c2, c3))
    rgb = np.where(
        t[..., None] < 0.5,
        a1 + (a2 - a1) * (t * 2)[..., None],
        a2 + (a3 - a2) * ((t - 0.5) * 2)[..., None],
    )
    streak = np.exp(-((t - 0.3) ** 2) / 0.012)[..., None]
    rgb = rgb + (np.array(PEARL, np.float32) - rgb) * streak * 0.45
    alpha = np.full((RS, RS, 1), 255, np.uint8)
    return Image.fromarray(np.concatenate([clamp_u8(rgb), alpha], 2), "RGBA")


def compose(base, *layers):
    img = base.convert("RGBA")
    for layer in layers:
        if layer is not None:
            img = Image.alpha_composite(img, layer)
    return img


# ---------------------------------------------------------------------------
# 11 — Sunrise studio: peach dawn + floating glass clip card
# ---------------------------------------------------------------------------
def icon_11():
    bg = mesh_bg((255, 214, 186), (255, 236, 210), (255, 180, 170), (255, 210, 195))
    bg = soft_blobs(
        bg,
        [
            (220, 180, 260, (255, 255, 255), 90),
            (780, 760, 300, (255, 120, 100), 55),
            (700, 200, 180, (255, 230, 140), 50),
        ],
    )
    card = round_m((210, 250, 814, 760), 56)
    screen = round_m((260, 300, 764, 640), 36)
    play = poly_m(play_pts(500, 470, 180))
    # soft timeline chips under screen
    chip1 = round_m((280, 670, 520, 720), 16)
    chip2 = round_m((540, 670, 740, 720), 16)

    white_glass = metal((255, 255, 255), (245, 248, 252), (220, 228, 236), 100)
    layers = [
        shadow(card, 0, 22, 28, 45),
        fill_mask(card, white_glass),
        rim(card, (255, 255, 255), 3, 200),
        solid_mask(screen, (255, 245, 240), 255),
        glow(play, ACCENT, 24, 90),
        fill_mask(play, metal((255, 140, 130), ACCENT, (180, 40, 50), 130)),
        rim(play, (255, 220, 200), 2, 160),
        fill_mask(chip1, metal((255, 200, 120), GOLD, (160, 110, 50), 100)),
        fill_mask(chip2, metal((140, 230, 245), CYAN, (40, 120, 150), 100)),
    ]
    # floating spark dots
    spark = Image.new("RGBA", (RS, RS), (0, 0, 0, 0))
    sd = ImageDraw.Draw(spark)
    for x, y, r, c in [(170, 320, 10, PEARL), (860, 280, 8, (255, 220, 160)), (150, 700, 7, ACCENT)]:
        sd.ellipse(box(x - r, y - r, x + r, y + r), fill=c + (210,))
    spark = spark.filter(ImageFilter.GaussianBlur(radius=s(1)))
    layers.append(spark)
    return save(compose(bg, *layers), "11_sunrise_card.png")


# ---------------------------------------------------------------------------
# 12 — Mint magic: soft seafoam + wand slicing a ribbon clip
# ---------------------------------------------------------------------------
def icon_12():
    bg = mesh_bg((210, 245, 235), (230, 250, 245), (190, 235, 250), (245, 255, 250))
    bg = soft_blobs(
        bg,
        [
            (180, 200, 240, (255, 255, 255), 100),
            (820, 700, 280, (120, 210, 200), 70),
            (600, 180, 200, (180, 230, 255), 60),
        ],
    )
    # ribbon / clip bar
    ribbon = round_m((160, 430, 860, 560), 40)
    cut_gap = round_m((470, 410, 554, 580), 8)  # negative cut feel via overlay later
    left = round_m((160, 430, 480, 560), 40)
    right = round_m((540, 430, 860, 560), 40)

    # wand
    wand_shaft = mask_draw(
        lambda d: d.rounded_rectangle(box(620, 180, 660, 780), radius=s(16), fill=255)
    )
    # rotate wand by compositing angled polygon instead
    wand = poly_m([(640, 160), (690, 180), (430, 820), (380, 800)])
    tip = ellipse_m((620, 140, 720, 240))
    star = poly_m(
        [
            (670, 120),
            (682, 155),
            (720, 155),
            (690, 178),
            (702, 215),
            (670, 192),
            (638, 215),
            (650, 178),
            (620, 155),
            (658, 155),
        ]
    )

    coral = metal((255, 150, 140), ACCENT, (170, 40, 50), 110)
    mint = metal((200, 255, 240), (120, 210, 195), (50, 140, 130), 100)
    gold = metal((255, 235, 180), GOLD, (150, 100, 40), 115)

    layers = [
        shadow(left, 0, 16, 22, 40),
        shadow(right, 0, 16, 22, 40),
        fill_mask(left, coral),
        fill_mask(right, mint),
        rim(left, PEARL, 2, 140),
        rim(right, PEARL, 2, 140),
        # bright cut seam
        solid_mask(round_m((492, 400, 532, 590), 10), PEARL, 230),
        glow(wand, GOLD, 20, 80),
        fill_mask(wand, gold),
        rim(wand, (255, 245, 210), 2, 160),
        fill_mask(tip, coral),
        glow(star, (255, 230, 120), 14, 140),
        fill_mask(star, metal((255, 250, 200), (255, 220, 100), GOLD, 90)),
    ]
    return save(compose(bg, *layers), "12_mint_magic_cut.png")


# ---------------------------------------------------------------------------
# 13 — Paper craft: soft sand background + origami play fold
# ---------------------------------------------------------------------------
def icon_13():
    bg = mesh_bg((245, 236, 220), (255, 248, 235), (235, 220, 200), (250, 240, 225))
    bg = soft_blobs(
        bg,
        [
            (300, 250, 260, (255, 255, 255), 80),
            (750, 700, 240, (230, 200, 160), 55),
            (200, 780, 180, (255, 180, 160), 40),
        ],
    )
    # origami play: three facet triangles
    face_main = poly_m([(280, 250), (280, 780), (780, 515)])
    face_fold = poly_m([(280, 250), (280, 515), (530, 515)])
    face_shadow = poly_m([(280, 515), (280, 780), (530, 515)])
    # small accent square "tape"
    tape = round_m((620, 300, 760, 360), 10)

    paper = metal((255, 252, 245), (245, 240, 230), (220, 210, 195), 95)
    fold_hi = metal((255, 255, 255), (250, 248, 242), (235, 230, 220), 80)
    fold_lo = metal((230, 220, 205), (200, 190, 175), (170, 160, 145), 100)
    coral = metal((255, 160, 145), ACCENT, (180, 50, 55), 120)

    layers = [
        shadow(face_main, 12, 22, 30, 50),
        fill_mask(face_main, paper),
        fill_mask(face_fold, fold_hi),
        fill_mask(face_shadow, fold_lo),
        rim(face_main, (255, 255, 255), 2, 120),
        # stitch / cut marks suggesting edit
        solid_mask(round_m((500, 500, 740, 518), 4), ACCENT, 200),
        solid_mask(round_m((560, 545, 720, 558), 3), mix(ACCENT, GOLD, 0.4), 160),
        fill_mask(tape, coral),
        rim(tape, (255, 210, 200), 2, 140),
    ]
    # soft perforated dots along fold
    dots = Image.new("RGBA", (RS, RS), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dots)
    for i in range(8):
        y = 300 + i * 55
        dd.ellipse(box(268, y, 292, y + 24), fill=(180, 170, 155, 160))
    layers.append(dots)
    return save(compose(bg, *layers), "13_origami_play.png")


# ---------------------------------------------------------------------------
# 14 — Sky aperture: soft sky blue + camera iris opening to play
# ---------------------------------------------------------------------------
def icon_14():
    bg = mesh_bg((186, 220, 255), (220, 240, 255), (170, 210, 250), (240, 248, 255))
    bg = soft_blobs(
        bg,
        [
            (250, 220, 280, (255, 255, 255), 110),
            (800, 300, 220, (255, 200, 180), 50),
            (700, 780, 260, (140, 190, 255), 70),
        ],
    )
    # iris blades — 6 wedges around center
    cx, cy, r_out, r_in = 512, 512, 340, 150
    blades = []
    for i in range(6):
        a0 = math.radians(i * 60 - 10)
        a1 = math.radians(i * 60 + 45)
        # approximate blade as quad
        pts = [
            (cx + r_in * math.cos(a0), cy + r_in * math.sin(a0)),
            (cx + r_out * math.cos(a0 + 0.15), cy + r_out * math.sin(a0 + 0.15)),
            (cx + r_out * math.cos(a1), cy + r_out * math.sin(a1)),
            (cx + r_in * math.cos(a1 - 0.1), cy + r_in * math.sin(a1 - 0.1)),
        ]
        blades.append(poly_m(pts))

    ring = ellipse_m((160, 160, 864, 864))
    hole = ellipse_m((360, 360, 664, 664))
    ring_donut = ImageChops.subtract(ring, hole)
    play = poly_m(play_pts(512, 512, 150))

    silver = metal((245, 250, 255), (200, 210, 225), (140, 155, 175), 110)
    sky_metal = metal((200, 230, 255), (120, 170, 230), (70, 120, 190), 100)
    coral = metal((255, 150, 140), ACCENT, (170, 40, 50), 125)

    layers = [shadow(ring, 0, 18, 26, 40), fill_mask(ring_donut, silver), rim(ring, PEARL, 3, 180)]
    for i, bm in enumerate(blades):
        mat = coral if i % 2 == 0 else sky_metal
        layers += [fill_mask(bm, mat), rim(bm, PEARL, 1, 100)]
    # center glass
    center = ellipse_m((390, 390, 634, 634))
    layers += [
        fill_mask(center, metal((255, 255, 255), (235, 245, 255), (210, 225, 245), 90)),
        glow(play, ACCENT, 18, 100),
        fill_mask(play, coral),
        rim(play, (255, 220, 210), 2, 160),
    ]
    return save(compose(bg, *layers), "14_sky_aperture.png")


# ---------------------------------------------------------------------------
# 15 — Coral ribbon studio: blush gradient + looping edit ribbon / infinity cut
# ---------------------------------------------------------------------------
def icon_15():
    bg = mesh_bg((255, 210, 220), (255, 230, 235), (255, 190, 175), (255, 225, 210))
    bg = soft_blobs(
        bg,
        [
            (200, 180, 260, (255, 255, 255), 100),
            (820, 220, 220, (255, 240, 180), 60),
            (700, 800, 280, (255, 120, 130), 55),
        ],
    )
    # infinity / loop ribbon as two overlapping ellipses arcs approximated by thick ellipses subtracted
    loop_outer = ellipse_m((180, 340, 620, 700))
    loop_inner = ellipse_m((250, 400, 550, 640))
    left_loop = ImageChops.subtract(loop_outer, loop_inner)
    loop_outer2 = ellipse_m((404, 340, 844, 700))
    loop_inner2 = ellipse_m((474, 400, 774, 640))
    right_loop = ImageChops.subtract(loop_outer2, loop_inner2)

    # center play gem
    gem = ellipse_m((410, 410, 614, 614))
    play = poly_m(play_pts(512, 512, 120))
    # small scissors accent
    blade_l = poly_m([(300, 250), (430, 320), (415, 350), (285, 280)])
    blade_r = poly_m([(724, 250), (594, 320), (609, 350), (739, 280)])

    coral = metal((255, 160, 150), ACCENT, (170, 40, 55), 115)
    cream = metal((255, 250, 245), (255, 235, 220), (240, 200, 180), 100)
    gold = metal((255, 235, 180), GOLD, (150, 100, 45), 110)

    layers = [
        shadow(left_loop, 0, 14, 20, 40),
        shadow(right_loop, 0, 14, 20, 40),
        fill_mask(left_loop, coral),
        fill_mask(right_loop, cream),
        rim(left_loop, (255, 210, 200), 2, 140),
        rim(right_loop, PEARL, 2, 150),
        glow(gem, (255, 200, 100), 22, 90),
        fill_mask(gem, gold),
        rim(gem, (255, 245, 210), 3, 200),
        fill_mask(play, metal((255, 255, 255), PEARL, (230, 220, 210), 90)),
        fill_mask(blade_l, metal((80, 70, 75), (40, 35, 40), (20, 18, 22), 100)),
        fill_mask(blade_r, metal((80, 70, 75), (40, 35, 40), (20, 18, 22), 100)),
    ]
    # soft highlight dashes on ribbon
    dashes = Image.new("RGBA", (RS, RS), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dashes)
    for xy in [(260, 420, 340, 445), (680, 560, 760, 585), (500, 360, 560, 380)]:
        dd.rounded_rectangle(box(*xy), radius=s(10), fill=PEARL + (120,))
    layers.append(dashes)
    return save(compose(bg, *layers), "15_coral_ribbon_loop.png")


def main():
    for gen in (icon_11, icon_12, icon_13, icon_14, icon_15):
        path = gen()
        im = Image.open(path)
        print(f"wrote {path.name} {im.size} {path.stat().st_size // 1024}KB")
    print("done: 5 creative bright icons")


if __name__ == "__main__":
    main()
