# Draws NotchBlack's app icon: a screen whose black menu bar swallows the notch.
# Requires Pillow: pip install pillow. Run from the repo root: python3 docs/make_icon.py
from PIL import Image, ImageDraw, ImageFilter
import math

S = 1024
def lerp(a, b, t): return tuple(int(a[i] + (b[i]-a[i])*t) for i in range(len(a)))

def vgrad(w, h, top, bottom):
    g = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(g)
    for y in range(h):
        d.line([(0, y), (w, y)], fill=lerp(top, bottom, y / max(1, h-1)))
    return g

def rounded_mask(w, h, r, scale=4):
    m = Image.new("L", (w*scale, h*scale), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w*scale-1, h*scale-1], r*scale, fill=255)
    return m.resize((w, h), Image.LANCZOS)

icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Apple's icon grid: an 824px rounded square centred on the canvas, with a soft shadow.
body, rad = 824, 185
off = (S - body) // 2
sm = Image.new("L", (S, S), 0)
ImageDraw.Draw(sm).rounded_rectangle([off, off + 14, off + body, off + body + 14], rad, fill=110)
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 255))
shadow.putalpha(sm.filter(ImageFilter.GaussianBlur(18)))
icon = Image.alpha_composite(icon, shadow)

# The whole tile is the black bezel.
tile = Image.new("RGBA", (body, body), (0, 0, 0, 255))

# Screen inset inside the bezel, below a tall black menu bar.
bez, bar_h = 40, 150
sw, sh = body - 2 * bez, body - bar_h - bez
screen = vgrad(sw, sh, (150, 145, 230, 255), (52, 48, 118, 255))
wave = Image.new("L", (sw, sh), 0)
pts = [(x, sh * 0.55 + math.sin(x / sw * math.pi * 1.6 + 0.6) * sh * 0.15) for x in range(0, sw + 1, 4)]
ImageDraw.Draw(wave).polygon(pts + [(sw, sh), (0, sh)], fill=90)
dark = Image.new("RGBA", (sw, sh), (20, 18, 50, 255))
dark.putalpha(wave.filter(ImageFilter.GaussianBlur(4)))
screen = Image.alpha_composite(screen, dark)

# Round the screen's corners: small ones under the menu bar (like NotchBlack's
# Round Corners option), larger ones at the bottom to follow the icon's shape.
top_r = 64
smask = rounded_mask(sw, sh, rad - bez)
smask.paste(rounded_mask(sw, sh, top_r).crop((0, 0, sw, sh // 2)), (0, 0))
tile.paste(screen, (bez, bar_h), smask)

icon.paste(tile, (off, off), rounded_mask(body, body, rad))

# build.sh turns this PNG into the macOS icon.
icon.save("docs/icon.png")
