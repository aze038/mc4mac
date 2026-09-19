#!/usr/bin/env python3
"""Renders the FalconMail app icon (macOS squircle, glass envelope) and the DMG background.
Requires Pillow: pip install pillow"""
import json, math, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "App/FalconMail/Assets.xcassets/AppIcon.appiconset")
S = 4096  # supersampled master


def squircle_mask(size, radius_ratio=0.2237):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * radius_ratio), fill=255)
    return m


def vertical_gradient(size, top, bottom):
    g = Image.linear_gradient("L").resize((size, size))
    a = Image.new("RGBA", (size, size), top)
    b = Image.new("RGBA", (size, size), bottom)
    return Image.composite(b, a, g)


def radial_glow(size, center, radius, color, alpha):
    glow = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(glow)
    cx, cy = center
    d.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=alpha)
    glow = glow.filter(ImageFilter.GaussianBlur(radius * 0.55))
    layer = Image.new("RGBA", (size, size), color + (0,))
    layer.putalpha(glow)
    return layer


def render_icon():
    s = S
    bg = vertical_gradient(s, (36, 118, 255, 255), (12, 44, 140, 255))
    bg = Image.alpha_composite(bg, radial_glow(s, (int(s * 0.28), int(s * 0.12)), int(s * 0.55), (150, 200, 255), 150))
    bg = Image.alpha_composite(bg, radial_glow(s, (int(s * 0.85), int(s * 0.95)), int(s * 0.45), (0, 10, 60), 120))

    # Envelope geometry
    w, h = s * 0.62, s * 0.44
    x0, y0 = (s - w) / 2, (s - h) / 2 + s * 0.02
    x1, y1 = x0 + w, y0 + h
    r = s * 0.06

    # Soft shadow under the glass slab
    shadow = Image.new("L", (s, s), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x0, y0 + s * 0.035, x1, y1 + s * 0.035), radius=r, fill=140)
    shadow = shadow.filter(ImageFilter.GaussianBlur(s * 0.035))
    sh = Image.new("RGBA", (s, s), (0, 20, 80, 0))
    sh.putalpha(shadow)
    bg = Image.alpha_composite(bg, sh)

    # Glass slab: translucent white with vertical fade
    slab_mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(slab_mask).rounded_rectangle((x0, y0, x1, y1), radius=r, fill=255)
    fade = Image.linear_gradient("L").resize((s, s)).point(lambda v: int(120 - v * 0.30))
    slab_alpha = ImageChops.multiply(slab_mask, fade.point(lambda v: min(255, v * 2)))
    slab = Image.new("RGBA", (s, s), (255, 255, 255, 0))
    slab.putalpha(slab_alpha)
    bg = Image.alpha_composite(bg, slab)

    # Specular highlight along the top of the slab
    spec = Image.new("L", (s, s), 0)
    ImageDraw.Draw(spec).rounded_rectangle((x0, y0, x1, y0 + h * 0.42), radius=r, fill=90)
    spec = ImageChops.multiply(spec, Image.linear_gradient("L").resize((s, s)).point(lambda v: max(0, 255 - v * 2)))
    spec = spec.filter(ImageFilter.GaussianBlur(s * 0.01))
    sp = Image.new("RGBA", (s, s), (255, 255, 255, 0))
    sp.putalpha(ImageChops.multiply(spec, slab_mask))
    bg = Image.alpha_composite(bg, sp)

    # Crisp glass rim
    rim = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle((x0, y0, x1, y1), radius=r, outline=(255, 255, 255, 190), width=int(s * 0.006))
    bg = Image.alpha_composite(bg, rim)

    # Flap: two strokes meeting slightly below centre, with a winged curve
    line = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(line)
    lw = int(s * 0.03)
    cx, cy = s / 2, y0 + h * 0.60
    inset = s * 0.004
    d.line([(x0 + inset, y0 + inset * 3), (cx, cy)], fill=(255, 255, 255, 235), width=lw, joint="curve")
    d.line([(x1 - inset, y0 + inset * 3), (cx, cy)], fill=(255, 255, 255, 235), width=lw, joint="curve")
    d.ellipse((cx - lw / 2, cy - lw / 2, cx + lw / 2, cy + lw / 2), fill=(255, 255, 255, 235))
    line = Image.alpha_composite(line, line)
    clip = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    clip.paste(line, mask=slab_mask)
    bg = Image.alpha_composite(bg, clip)

    # Corner light sweep for the glass feel of the whole tile
    sweep = radial_glow(s, (int(s * 0.15), int(-s * 0.05)), int(s * 0.5), (255, 255, 255), 70)
    bg = Image.alpha_composite(bg, sweep)

    icon = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    icon.paste(bg, mask=squircle_mask(s))
    return icon.resize((1024, 1024), Image.LANCZOS)


def write_iconset(master):
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    images = []
    entries = []
    for base in [16, 32, 128, 256, 512]:
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}@{scale}x.png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(ICONSET, name))
            entries.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{base}x{base}"})
    json.dump({"images": entries, "info": {"author": "xcode", "version": 1}}, open(os.path.join(ICONSET, "Contents.json"), "w"), indent=2)


def render_dmg_background(icon):
    w, h = 540, 380
    img = vertical_gradient(w, (246, 247, 250, 255), (226, 230, 238, 255)).resize((w, h))
    d = ImageDraw.Draw(img)
    # arrow between the two drop targets
    ax0, ax1, ay = 205, 335, 190
    d.line([(ax0, ay), (ax1 - 14, ay)], fill=(120, 130, 150, 255), width=6)
    d.polygon([(ax1, ay), (ax1 - 26, ay - 14), (ax1 - 26, ay + 14)], fill=(120, 130, 150, 255))
    d.text((w / 2, 300), "Drag FalconMail to Applications", fill=(90, 98, 115, 255), anchor="mm")
    img.save(os.path.join(ROOT, "scripts/dmg-background.png"))


if __name__ == "__main__":
    os.makedirs(ICONSET, exist_ok=True)
    master = render_icon()
    master.save(os.path.join(ROOT, "scripts/icon-1024.png"))
    write_iconset(master)
    render_dmg_background(master)
    print("icon and DMG background rendered")
