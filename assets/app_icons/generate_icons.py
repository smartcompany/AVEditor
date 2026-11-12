#!/usr/bin/env python3
"""Generate 10 luxury metallic/glass 1024x1024 AVEditor app icons."""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageEnhance

OUT = Path(__file__).resolve().parent
SIZE = 1024
SCALE = 2
RS = SIZE * SCALE

# Luxury palette
OBSIDIAN = (6, 6, 8)
NAVY = (12, 16, 28)
INK = (248, 244, 236)
ACCENT = (255, 72, 72)
CYAN = (90, 210, 245)
GOLD_HI = (245, 230, 190)
GOLD_MID = (212, 175, 110)
GOLD_LO = (120, 85, 40)
ROSE = (220, 140, 120)
PEARL = (255, 252, 245)


def s(v: float) -> float:
    return v * SCALE


def box(*xy: float):
    return [s(v) for v in xy]


def clamp_u8(a: np.ndarray) -> np.ndarray:
    return np.clip(a, 0, 255).astype(np.uint8)


def mix_rgb(a, b, t):
    t = float(np.clip(t, 0, 1))
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def save(img: Image.Image, name: str) -> Path:
    path = OUT / name
    out = img.convert("RGBA").resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    out = out.filter(ImageFilter.UnsharpMask(radius=1.4, percent=90, threshold=2))
    # slight contrast lift for premium punch
    out = ImageEnhance.Contrast(out).enhance(1.06)
    out = ImageEnhance.Color(out).enhance(1.08)
    out.convert("RGB").save(path, "PNG", optimize=True)
    return path


def radial(size, inner, outer, power=1.1, cx=None, cy=None) -> Image.Image:
    cx = size / 2 if cx is None else cx
    cy = size / 2 if cy is None else cy
    ys, xs = np.ogrid[:size, :size]
    max_r = math.hypot(max(cx, size - cx), max(cy, size - cy))
    t = np.clip((np.hypot(xs - cx, ys - cy) / max_r) ** power, 0, 1)[..., None]
    rgb = np.array(inner, np.float32) + (np.array(outer, np.float32) - np.array(inner, np.float32)) * t
    alpha = np.full((size, size, 1), 255, np.uint8)
    return Image.fromarray(np.concatenate([clamp_u8(rgb), alpha], 2), "RGBA")


def linear_metal(size, top, mid, bottom, angle_deg=115) -> Image.Image:
    """Brushed-metal style linear gradient with soft bands."""
    ang = math.radians(angle_deg)
    ys, xs = np.ogrid[:size, :size]
    u = (xs * math.cos(ang) + ys * math.sin(ang))
    u = (u - u.min()) / (u.max() - u.min() + 1e-6)
    # add subtle brush noise bands
    bands = 0.5 + 0.5 * np.sin(u * math.pi * 18)
    t = np.clip(u * 0.85 + bands * 0.08, 0, 1)
    top_a, mid_a, bot_a = map(lambda c: np.array(c, np.float32), (top, mid, bottom))
    rgb = np.where(
        t[..., None] < 0.5,
        top_a + (mid_a - top_a) * (t * 2)[..., None],
        mid_a + (bot_a - mid_a) * ((t - 0.5) * 2)[..., None],
    )
    # specular streak
    streak = np.exp(-((t - 0.28) ** 2) / 0.01)[..., None]
    rgb = rgb + (np.array(PEARL, np.float32) - rgb) * streak * 0.55
    alpha = np.full((size, size, 1), 255, np.uint8)
    return Image.fromarray(np.concatenate([clamp_u8(rgb), alpha], 2), "RGBA")


def luxury_bg(warm=False) -> Image.Image:
    if warm:
        img = radial(RS, (28, 20, 18), OBSIDIAN, power=1.0)
    else:
        img = radial(RS, (20, 24, 38), OBSIDIAN, power=1.05)
    # ambient gold wash
    wash = Image.new("RGBA", (RS, RS), (0, 0, 0, 0))
    wd = ImageDraw.Draw(wash)
    wd.ellipse(box(180, 120, 844, 700), fill=GOLD_MID + (28,))
    wash = wash.filter(ImageFilter.GaussianBlur(radius=s(90)))
    img = Image.alpha_composite(img, wash)
    # fine gold ring
    ring = Image.new("RGBA", (RS, RS), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    rd.ellipse(box(70, 70, 954, 954), outline=GOLD_MID + (45,), width=int(s(2)))
    rd.ellipse(box(110, 110, 914, 914), outline=GOLD_HI + (25,), width=int(s(1)))
    ring = ring.filter(ImageFilter.GaussianBlur(radius=s(1.5)))
    img = Image.alpha_composite(img, ring)
    # vignette
    vig = Image.new("RGBA", (RS, RS), (0, 0, 0, 0))
    vd = ImageDraw.Draw(vig)
    for i in range(30):
        inset = i * (RS // 90)
        vd.rectangle([inset, inset, RS - inset, RS - inset], outline=(0, 0, 0, 10 + i), width=3)
    vig = vig.filter(ImageFilter.GaussianBlur(radius=RS // 25))
    return Image.alpha_composite(img, vig)


def mask_from_draw(draw_fn) -> Image.Image:
    m = Image.new("L", (RS, RS), 0)
    d = ImageDraw.Draw(m)
    draw_fn(d)
    return m


def fill_mask(mask: Image.Image, material: Image.Image, soft=True) -> Image.Image:
    if soft:
        mask = mask.filter(ImageFilter.GaussianBlur(radius=0.8))
    out = material.copy()
    out.putalpha(mask)
    return out


def soft_shadow(mask: Image.Image, offset=(10, 16), blur=22, alpha=160) -> Image.Image:
    sh = Image.new("RGBA", (RS, RS), (0, 0, 0, 0))
    m = mask.point(lambda p: min(255, int(p * alpha / 255)))
    black = Image.new("RGBA", (RS, RS), (0, 0, 0, 255))
    black.putalpha(m)
    sh = ImageChops.offset(black, int(s(offset[0])), int(s(offset[1])))
    return sh.filter(ImageFilter.GaussianBlur(radius=s(blur)))


def glow_mask(mask: Image.Image, color, blur=24, alpha=140) -> Image.Image:
    col = Image.new("RGBA", (RS, RS), color + (255,))
    a = mask.point(lambda p: min(255, int(p * alpha / 255)))
    col.putalpha(a)
    return col.filter(ImageFilter.GaussianBlur(radius=s(blur)))


def play_pts(cx, cy, size):
    h = size
    w = size * 0.86
    return [
        (cx - w * 0.35, cy - h * 0.5),
        (cx - w * 0.35, cy + h * 0.5),
        (cx + w * 0.55, cy),
    ]


def poly_mask(points, fill=255):
    def fn(d):
        d.polygon([(s(x), s(y)) for x, y in points], fill=fill)

    return mask_from_draw(fn)


def round_mask(xy, radius):
    def fn(d):
        d.rounded_rectangle(box(*xy), radius=s(radius), fill=255)

    return mask_from_draw(fn)


def ellipse_mask(xy):
    def fn(d):
        d.ellipse(box(*xy), fill=255)

    return mask_from_draw(fn)


def gold_mat():
    return linear_metal(RS, GOLD_HI, GOLD_MID, GOLD_LO, 118)


def pearl_mat():
    return linear_metal(RS, PEARL, INK, mix_rgb(INK, GOLD_MID, 0.25), 100)


def coral_mat():
    return linear_metal(RS, (255, 140, 130), ACCENT, (160, 30, 40), 125)


def glass_mat():
    return linear_metal(RS, (70, 80, 100), (22, 28, 42), (8, 10, 16), 100)


def cyan_mat():
    return linear_metal(RS, (180, 240, 255), CYAN, (20, 80, 110), 110)


def composite(base, *layers):
    img = base.convert("RGBA")
    for layer in layers:
        if layer is not None:
            img = Image.alpha_composite(img, layer)
    return img


def rim_stroke(mask: Image.Image, color, width=3, alpha=200) -> Image.Image:
    """Approximate rim by dilating mask edge."""
    edge = mask.filter(ImageFilter.MaxFilter(size=max(3, int(s(width) * 2 + 1))))
    edge = ImageChops.subtract(edge, mask)
    col = Image.new("RGBA", (RS, RS), color + (255,))
    a = edge.point(lambda p: min(255, int(p * alpha / 255)))
    col.putalpha(a)
    return col


# ---------------------------------------------------------------------------
# Icons
# ---------------------------------------------------------------------------
def icon_01():
    bg = luxury_bg(warm=True)
    # gold outer play plate + pearl inner for jewelry depth
    play_outer = poly_mask(play_pts(455, 512, 360))
    play_m = poly_mask(play_pts(455, 512, 300))
    blade_m = round_mask((610, 240, 678, 780), 22)
    knob_m = ellipse_mask((588, 198, 700, 310))

    layers = [
        soft_shadow(play_outer, (8, 18), 28, 180),
        glow_mask(blade_m, ACCENT, 30, 120),
        glow_mask(play_outer, GOLD_MID, 26, 55),
        fill_mask(play_outer, gold_mat()),
        rim_stroke(play_outer, GOLD_HI, 3, 200),
        fill_mask(play_m, pearl_mat()),
        rim_stroke(play_m, GOLD_LO, 2, 100),
        fill_mask(blade_m, coral_mat()),
        rim_stroke(blade_m, GOLD_HI, 3, 200),
        fill_mask(knob_m, gold_mat()),
        rim_stroke(knob_m, GOLD_HI, 3, 230),
    ]
    inner = ellipse_mask((620, 230, 668, 278))
    layers.append(fill_mask(inner, pearl_mat()))
    gem = ellipse_mask((632, 242, 656, 266))
    layers += [fill_mask(gem, coral_mat()), glow_mask(gem, ACCENT, 10, 100)]
    spec_m = poly_mask(play_pts(440, 470, 140))
    spec = Image.new("RGBA", (RS, RS), PEARL + (255,))
    spec.putalpha(spec_m.point(lambda p: int(p * 0.28)))
    layers.append(spec)
    return save(composite(bg, *layers), "01_play_cut.png")


def icon_02():
    bg = luxury_bg()
    panel_m = round_mask((120, 230, 904, 794), 54)
    layers = [
        soft_shadow(panel_m, (0, 22), 30, 180),
        fill_mask(panel_m, glass_mat()),
        rim_stroke(panel_m, GOLD_MID, 3, 170),
    ]
    # glass sheen
    sheen_m = round_mask((150, 250, 874, 360), 28)
    sheen = Image.new("RGBA", (RS, RS), PEARL + (255,))
    sheen.putalpha(sheen_m.point(lambda p: int(p * 0.14)))
    layers.append(sheen)

    clips = [
        ((185, 305, 625, 390), gold_mat(), 16),
        ((185, 425, 770, 510), pearl_mat(), 16),
        ((185, 545, 530, 630), cyan_mat(), 16),
    ]
    for xy, mat, rad in clips:
        m = round_mask(xy, rad)
        layers += [soft_shadow(m, (0, 8), 12, 110), fill_mask(m, mat), rim_stroke(m, GOLD_HI, 1, 90)]

    head_m = round_mask((552, 270, 596, 710), 10)
    tip_m = poly_mask([(536, 255), (612, 255), (574, 320)])
    layers += [
        glow_mask(head_m, ACCENT, 18, 130),
        fill_mask(head_m, coral_mat()),
        fill_mask(tip_m, gold_mat()),
    ]
    # ticks
    tick_layer = Image.new("RGBA", (RS, RS), (0, 0, 0, 0))
    td = ImageDraw.Draw(tick_layer)
    for x in range(210, 820, 46):
        td.rounded_rectangle(box(x, 694, x + 16, 708), radius=s(4), fill=GOLD_MID + (150,))
    layers.append(tick_layer)
    return save(composite(bg, *layers), "02_timeline.png")


def icon_03():
    bg = luxury_bg(warm=True)
    a_left = poly_mask([(165, 805), (275, 805), (415, 245), (305, 245)])
    a_right = poly_mask([(305, 245), (415, 245), (555, 805), (445, 805)])
    a_bar = round_mask((260, 515, 460, 585), 14)
    v_left = poly_mask([(480, 245), (595, 245), (725, 805), (610, 805)])
    v_right = poly_mask([(700, 245), (815, 245), (725, 805), (610, 805)])
    play_m = poly_mask(play_pts(675, 640, 78))

    a_m = ImageChops.lighter(ImageChops.lighter(a_left, a_right), a_bar)
    layers = [
        glow_mask(a_m, ACCENT, 36, 70),
        soft_shadow(a_m, (8, 16), 20, 160),
        soft_shadow(v_left, (10, 16), 18, 140),
        fill_mask(a_left, coral_mat()),
        fill_mask(a_right, coral_mat()),
        fill_mask(a_bar, gold_mat()),
        rim_stroke(a_m, GOLD_HI, 2, 120),
        fill_mask(v_left, pearl_mat()),
        fill_mask(v_right, gold_mat()),
        rim_stroke(ImageChops.lighter(v_left, v_right), GOLD_HI, 2, 130),
        glow_mask(play_m, ACCENT, 12, 120),
        fill_mask(play_m, coral_mat()),
    ]
    # sparkles
    spark = Image.new("RGBA", (RS, RS), (0, 0, 0, 0))
    sd = ImageDraw.Draw(spark)
    for cx, cy, r in [(240, 200, 7), (790, 220, 6), (520, 160, 5), (860, 520, 4)]:
        sd.ellipse(box(cx - r, cy - r, cx + r, cy + r), fill=GOLD_HI + (220,))
    spark = spark.filter(ImageFilter.GaussianBlur(radius=s(1.2)))
    layers.append(spark)
    return save(composite(bg, *layers), "03_av_monogram.png")


def icon_04():
    bg = luxury_bg()
    frame_m = round_mask((170, 190, 854, 710), 44)
    screen_m = round_mask((225, 245, 800, 655), 30)
    play_m = poly_mask(play_pts(500, 450, 200))
    blade_l = poly_mask([(275, 725), (470, 640), (495, 675), (315, 768)])
    blade_r = poly_mask([(745, 725), (550, 640), (525, 675), (705, 768)])
    pivot = ellipse_mask((476, 636, 548, 708))
    h1 = ellipse_mask((215, 735, 325, 845))
    h2 = ellipse_mask((699, 735, 809, 845))

    def ring(xy, thickness=16):
        outer = ellipse_mask(xy)
        # erode by repeated min of small odd size
        inner = outer
        steps = max(1, int(s(thickness) / 3))
        for _ in range(steps):
            inner = inner.filter(ImageFilter.MinFilter(size=5))
        ring_m = ImageChops.subtract(outer, inner)
        return fill_mask(ring_m, gold_mat())

    r1 = ring((215, 735, 325, 845))
    r2 = ring((699, 735, 809, 845))

    layers = [
        soft_shadow(frame_m, (0, 24), 28, 180),
        fill_mask(frame_m, glass_mat()),
        rim_stroke(frame_m, GOLD_MID, 4, 200),
        fill_mask(screen_m, Image.new("RGBA", (RS, RS), (4, 5, 8, 255))),
        soft_shadow(play_m, (4, 10), 14, 120),
        fill_mask(play_m, pearl_mat()),
        rim_stroke(play_m, GOLD_HI, 2, 120),
        glow_mask(blade_l, ACCENT, 16, 100),
        fill_mask(blade_l, coral_mat()),
        fill_mask(blade_r, gold_mat()),
        fill_mask(pivot, pearl_mat()),
        fill_mask(ellipse_mask((496, 656, 528, 688)), coral_mat()),
        r1,
        r2,
    ]
    _ = (h1, h2)  # masks kept for clarity / future tweaks
    # glass sheen on frame
    sheen_m = round_mask((240, 220, 560, 320), 24)
    sheen = Image.new("RGBA", (RS, RS), PEARL + (255,))
    sheen.putalpha(sheen_m.point(lambda p: int(p * 0.16)))
    layers.insert(3, sheen)
    return save(composite(bg, *layers), "04_frame_scissors.png")


def icon_05():
    bg = luxury_bg(warm=True)
    body_m = round_mask((165, 340, 859, 825), 40)
    top_m = poly_mask([(165, 340), (859, 340), (825, 205), (195, 275)])
    play_m = poly_mask(play_pts(512, 580, 185))
    bar_m = round_mask((220, 752, 510, 776), 8)

    layers = [
        soft_shadow(body_m, (0, 22), 26, 180),
        fill_mask(body_m, glass_mat()),
        rim_stroke(body_m, GOLD_MID, 3, 180),
        fill_mask(top_m, linear_metal(RS, (40, 44, 56), (22, 26, 36), (10, 12, 18), 80)),
    ]
    # stripes with materials
    stripes = [
        ([(220, 295), (300, 276), (320, 325), (240, 344)], pearl_mat()),
        ([(340, 272), (420, 253), (440, 302), (360, 321)], coral_mat()),
        ([(460, 250), (540, 231), (560, 280), (480, 299)], gold_mat()),
        ([(580, 228), (660, 209), (680, 258), (600, 277)], pearl_mat()),
        ([(700, 206), (780, 190), (800, 238), (720, 254)], coral_mat()),
    ]
    for pts, mat in stripes:
        layers.append(fill_mask(poly_mask(pts), mat))

    layers += [
        soft_shadow(play_m, (4, 10), 14, 120),
        fill_mask(play_m, pearl_mat()),
        rim_stroke(play_m, GOLD_HI, 2, 140),
        fill_mask(bar_m, gold_mat()),
        fill_mask(round_mask((220, 752, 360, 776), 8), coral_mat()),
    ]
    return save(composite(bg, *layers), "05_clapper.png")


def icon_06():
    bg = luxury_bg()
    layers_def = [
        ((275, 265, 850, 620), glass_mat(), 0.55),
        ((225, 315, 800, 670), glass_mat(), 0.75),
        ((175, 365, 750, 720), glass_mat(), 1.0),
    ]
    layers = []
    for xy, mat, op in layers_def:
        m = round_mask(xy, 40)
        card = fill_mask(m, mat)
        # reduce opacity for back cards
        r, g, b, a = card.split()
        a = a.point(lambda p, o=op: int(p * o))
        card = Image.merge("RGBA", (r, g, b, a))
        layers += [soft_shadow(m, (8, 16), 18, int(140 * op)), card, rim_stroke(m, GOLD_MID, 2, int(160 * op))]
        sheen_m = round_mask((xy[0] + 24, xy[1] + 18, xy[2] - 24, xy[1] + 80), 22)
        sheen = Image.new("RGBA", (RS, RS), PEARL + (255,))
        sheen.putalpha(sheen_m.point(lambda p, o=op: int(p * 0.14 * o)))
        layers.append(sheen)

    screen = round_mask((215, 415, 715, 680), 28)
    play_m = poly_mask(play_pts(455, 545, 145))
    badge = ellipse_mask((640, 335, 775, 470))
    badge_play = poly_mask(play_pts(710, 402, 50))
    layers += [
        fill_mask(screen, Image.new("RGBA", (RS, RS), (4, 5, 8, 255))),
        fill_mask(play_m, pearl_mat()),
        glow_mask(badge, ACCENT, 20, 130),
        fill_mask(badge, coral_mat()),
        rim_stroke(badge, GOLD_HI, 4, 220),
        fill_mask(badge_play, Image.new("RGBA", (RS, RS), OBSIDIAN + (255,))),
    ]
    return save(composite(bg, *layers), "06_layered_clips.png")


def icon_07():
    bg = luxury_bg()
    disc_m = ellipse_mask((145, 145, 879, 879))
    inner_m = ellipse_mask((210, 210, 814, 814))
    layers = [
        soft_shadow(disc_m, (0, 18), 28, 170),
        glow_mask(disc_m, GOLD_MID, 30, 50),
        fill_mask(disc_m, gold_mat()),
        rim_stroke(disc_m, GOLD_HI, 4, 220),
        fill_mask(inner_m, glass_mat()),
        rim_stroke(inner_m, GOLD_LO, 2, 100),
    ]

    bars = [0.28, 0.48, 0.72, 0.98, 0.62, 0.88, 0.42, 0.78, 0.58, 0.92, 0.52, 0.34]
    total_w, start_x, gap = 400, 365, 10
    bw = (total_w - gap * (len(bars) - 1)) / len(bars)
    for i, h in enumerate(bars):
        x0 = start_x + i * (bw + gap)
        hh = 270 * h
        y0 = 512 - hh / 2
        if i in (3, 9):
            mat = coral_mat()
        elif i % 3 == 0:
            mat = cyan_mat()
        elif i % 2 == 0:
            mat = gold_mat()
        else:
            mat = pearl_mat()
        m = round_mask((x0, y0, x0 + bw, y0 + hh), 11)
        layers += [fill_mask(m, mat), rim_stroke(m, GOLD_HI, 1, 80)]

    play_c = ellipse_mask((205, 425, 345, 565))
    play_t = poly_mask(play_pts(278, 495, 56))
    layers += [
        glow_mask(play_c, ACCENT, 18, 140),
        fill_mask(play_c, coral_mat()),
        rim_stroke(play_c, GOLD_HI, 4, 230),
        fill_mask(play_t, Image.new("RGBA", (RS, RS), OBSIDIAN + (255,))),
    ]
    return save(composite(bg, *layers), "07_waveform_play.png")


def icon_08():
    bg = luxury_bg(warm=True)
    left_m = round_mask((115, 195, 505, 830), 46)
    right_m = round_mask((520, 195, 910, 830), 46)
    div_m = round_mask((496, 155, 528, 870), 8)
    tip_m = poly_mask([(472, 145), (552, 145), (512, 220)])

    layers = [
        soft_shadow(left_m, (-6, 18), 22, 140),
        soft_shadow(right_m, (8, 18), 22, 160),
        fill_mask(left_m, glass_mat()),
        rim_stroke(left_m, mix_rgb(GOLD_MID, (80, 80, 90), 0.4), 2, 100),
        fill_mask(right_m, linear_metal(RS, (70, 35, 38), (40, 18, 22), (18, 8, 10), 100)),
        rim_stroke(right_m, GOLD_MID, 3, 190),
    ]
    # left muted clips
    for xy, mat in [
        ((165, 275, 455, 420), linear_metal(RS, (60, 68, 82), (40, 48, 60), (24, 28, 36), 90)),
        ((165, 455, 385, 520), gold_mat()),
        ((165, 555, 425, 600), linear_metal(RS, (70, 78, 90), (50, 58, 70), (30, 34, 42), 90)),
    ]:
        m = round_mask(xy, 18)
        layers.append(fill_mask(m, mat))

    # right vivid
    for xy, mat in [
        ((570, 275, 860, 420), coral_mat()),
        ((570, 455, 810, 520), gold_mat()),
        ((570, 555, 850, 600), pearl_mat()),
    ]:
        m = round_mask(xy, 18)
        layers += [fill_mask(m, mat), rim_stroke(m, GOLD_HI, 1, 90)]
    play_m = poly_mask(play_pts(715, 348, 72))
    layers.append(fill_mask(play_m, pearl_mat()))

    sheen = Image.new("RGBA", (RS, RS), PEARL + (255,))
    sheen_m = round_mask((545, 215, 885, 285), 22)
    sheen.putalpha(sheen_m.point(lambda p: int(p * 0.16)))
    layers.append(sheen)

    layers += [
        glow_mask(div_m, PEARL, 14, 100),
        fill_mask(div_m, pearl_mat()),
        fill_mask(tip_m, gold_mat()),
        fill_mask(poly_mask([(486, 155), (538, 155), (512, 210)]), coral_mat()),
    ]
    return save(composite(bg, *layers), "08_split_cut.png")


def icon_09():
    bg = luxury_bg()
    strip_m = round_mask((155, 275, 870, 750), 32)
    layers = [
        soft_shadow(strip_m, (0, 20), 26, 170),
        fill_mask(strip_m, glass_mat()),
        rim_stroke(strip_m, GOLD_MID, 3, 190),
    ]
    for y in (308, 390, 472, 554, 636):
        for x in (198, 782):
            hole = round_mask((x, y, x + 44, y + 56), 10)
            layers.append(fill_mask(hole, Image.new("RGBA", (RS, RS), OBSIDIAN + (255,))))
            glint = round_mask((x + 6, y + 6, x + 38, y + 18), 4)
            g = Image.new("RGBA", (RS, RS), GOLD_HI + (255,))
            g.putalpha(glint.point(lambda p: int(p * 0.35)))
            layers.append(g)

    frames = [
        ((278, 328, 432, 692), glass_mat()),
        ((448, 328, 602, 692), Image.new("RGBA", (RS, RS), (4, 5, 8, 255))),
        ((618, 328, 772, 692), glass_mat()),
    ]
    for xy, mat in frames:
        m = round_mask(xy, 16)
        layers += [fill_mask(m, mat), rim_stroke(m, GOLD_HI, 1, 70)]

    play_m = poly_mask(play_pts(525, 510, 125))
    crescent = mask_from_draw(lambda d: d.pieslice(box(700, 190, 915, 405), 200, 340, fill=255))
    layers += [
        fill_mask(play_m, pearl_mat()),
        rim_stroke(play_m, GOLD_HI, 2, 140),
        glow_mask(crescent, ACCENT, 18, 120),
        fill_mask(crescent, coral_mat()),
        rim_stroke(crescent, GOLD_HI, 2, 180),
    ]
    return save(composite(bg, *layers), "09_film_strip.png")


def icon_10():
    bg = radial(RS, (22, 24, 36), OBSIDIAN, 1.0)
    # ambient
    wash = Image.new("RGBA", (RS, RS), (0, 0, 0, 0))
    ImageDraw.Draw(wash).ellipse(box(220, 180, 820, 780), fill=GOLD_MID + (35,))
    wash = wash.filter(ImageFilter.GaussianBlur(radius=s(100)))
    bg = Image.alpha_composite(bg, wash)

    rings = Image.new("RGBA", (RS, RS), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rings)
    for rad, col, w, a in [
        (445, GOLD_HI, 2, 80),
        (415, GOLD_MID, 2, 110),
        (385, GOLD_LO, 1, 70),
    ]:
        rd.ellipse(
            [s(512) - s(rad), s(512) - s(rad), s(512) + s(rad), s(512) + s(rad)],
            outline=col + (a,),
            width=max(1, int(s(w))),
        )
    rings = rings.filter(ImageFilter.GaussianBlur(radius=s(1.2)))

    disc_m = ellipse_mask((175, 175, 849, 849))
    play_m = poly_mask(play_pts(530, 512, 270))
    # arc mask
    arc_m = Image.new("L", (RS, RS), 0)
    ad = ImageDraw.Draw(arc_m)
    ad.arc(box(215, 215, 809, 809), start=-48, end=108, fill=255, width=int(s(46)))
    knob_m = ellipse_mask((692, 268, 772, 348))
    knob_in = ellipse_mask((712, 288, 752, 328))

    layers = [
        rings,
        soft_shadow(disc_m, (0, 16), 26, 170),
        fill_mask(disc_m, gold_mat()),
        rim_stroke(disc_m, GOLD_HI, 4, 230),
        fill_mask(ellipse_mask((210, 210, 814, 814)), glass_mat()),
        glow_mask(arc_m, ACCENT, 20, 130),
        fill_mask(arc_m, coral_mat()),
        rim_stroke(arc_m, GOLD_HI, 2, 180),
        soft_shadow(play_m, (4, 10), 14, 120),
        fill_mask(play_m, pearl_mat()),
        rim_stroke(play_m, GOLD_HI, 2, 140),
        glow_mask(knob_m, CYAN, 14, 120),
        fill_mask(knob_m, cyan_mat()),
        rim_stroke(knob_m, GOLD_HI, 3, 220),
        fill_mask(knob_in, pearl_mat()),
    ]
    return save(composite(bg, *layers), "10_orbit_play.png")


def main():
    gens = [
        icon_01,
        icon_02,
        icon_03,
        icon_04,
        icon_05,
        icon_06,
        icon_07,
        icon_08,
        icon_09,
        icon_10,
    ]
    for gen in gens:
        path = gen()
        im = Image.open(path)
        print(f"wrote {path.name} {im.size} {path.stat().st_size // 1024}KB")
    print(f"done: {len(gens)} luxury icons -> {OUT}")


if __name__ == "__main__":
    main()
