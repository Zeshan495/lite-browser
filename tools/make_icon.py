"""Draws LiteBrowser's app icon (globe + lightning bolt) and writes AppIcon.png and AppIcon.icns."""
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4096                      # supersampled canvas; final icon is 1024
OUT = sys.argv[1] if len(sys.argv) > 1 else "Resources"


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def diagonal_gradient(size, c1, c2):
    small = Image.new("RGB", (256, 256))
    px = small.load()
    for y in range(256):
        for x in range(256):
            px[x, y] = lerp(c1, c2, (x + y) / 510)
    return small.resize((size, size), Image.BICUBIC)


def rounded_mask(size, box, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


u = S / 1024                  # 1 unit = 1px of the final 1024 icon
icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Squircle-ish tile following the macOS icon grid (824px tile, 100px margin)
tile_box = (100 * u, 92 * u, 924 * u, 916 * u)
tile_mask = rounded_mask(S, tile_box, 186 * u)

# Soft drop shadow
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow_mask = rounded_mask(S, (100 * u, 112 * u, 924 * u, 936 * u), 186 * u)
shadow.putalpha(shadow_mask.point(lambda v: v * 0.35))
shadow = shadow.filter(ImageFilter.GaussianBlur(22 * u))
icon = Image.alpha_composite(icon, shadow)

# Background gradient: indigo -> sky blue -> cyan
bg = diagonal_gradient(S, (67, 56, 202), (14, 165, 233)).convert("RGBA")
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse((150 * u, 40 * u, 760 * u, 560 * u), fill=(255, 255, 255, 70))
glow = glow.filter(ImageFilter.GaussianBlur(110 * u))
bg = Image.alpha_composite(bg, glow)
tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
tile.paste(bg, (0, 0), tile_mask)
icon = Image.alpha_composite(icon, tile)

# Globe
cx, cy, r = 512 * u, 500 * u, 270 * u
w = 30 * u
globe = Image.new("RGBA", (S, S), (0, 0, 0, 0))
g = ImageDraw.Draw(globe)
white = (255, 255, 255, 255)
g.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 38))
g.ellipse((cx - r * 0.42, cy - r, cx + r * 0.42, cy + r), outline=white, width=int(w * 0.8))
g.line((cx, cy - r, cx, cy + r), fill=white, width=int(w * 0.8))
for frac in (-0.5, 0, 0.5):
    y = cy + r * frac
    half = (r * r - (r * frac) ** 2) ** 0.5
    g.line((cx - half, y, cx + half, y), fill=white, width=int(w * 0.8))
circle = Image.new("L", (S, S), 0)
ImageDraw.Draw(circle).ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)
globe.putalpha(ImageChops.multiply(globe.getchannel("A"), circle))
ImageDraw.Draw(globe).ellipse((cx - r, cy - r, cx + r, cy + r), outline=white, width=int(w))
icon = Image.alpha_composite(icon, globe)

# Lightning-bolt badge (bottom right) = "lite & fast"
bx, by, br = 700 * u, 700 * u, 150 * u
badge_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(badge_shadow).ellipse((bx - br, by - br + 14 * u, bx + br, by + br + 14 * u), fill=(20, 20, 80, 110))
badge_shadow = badge_shadow.filter(ImageFilter.GaussianBlur(18 * u))
icon = Image.alpha_composite(icon, badge_shadow)

badge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(badge)
d.ellipse((bx - br, by - br, bx + br, by + br), fill=(255, 255, 255, 255))
d.ellipse((bx - br + 20 * u, by - br + 20 * u, bx + br - 20 * u, by + br - 20 * u), fill=(255, 196, 0, 255))
bolt = [(-18, -100), (-70, 15), (-8, 15), (-30, 105), (62, -20), (2, -20), (32, -100)]
d.polygon([(bx + x * u * 1.05, by + y * u * 1.05) for x, y in bolt], fill=(255, 255, 255, 255))
icon = Image.alpha_composite(icon, badge)

final = icon.resize((1024, 1024), Image.LANCZOS)
final.save(f"{OUT}/AppIcon.png")
final.save(f"{OUT}/AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
print("wrote", OUT)
