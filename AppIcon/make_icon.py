#!/usr/bin/env python3
"""Generate Polyhelm icon art: dark pill with five glowing dots.
Draws at 4x supersample then downsamples for clean anti-aliased edges."""
from PIL import Image, ImageDraw, ImageFilter
import math, os, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
S = 4               # supersample factor
N = 1024            # final master size
W = N * S

def lerp(a, b, t): return tuple(int(round(a[i] + (b[i]-a[i])*t)) for i in range(len(a)))

def radial_glow(size, inner, outer, r_inner_frac, r_outer_frac):
    """RGBA image, radial gradient from inner color (center) to transparent."""
    img = Image.new("RGBA", (size, size), (0,0,0,0))
    px = img.load()
    c = size/2.0
    ri = size*r_inner_frac
    ro = size*r_outer_frac
    for y in range(size):
        for x in range(size):
            d = math.hypot(x-c, y-c)
            if d >= ro:
                continue
            if d <= ri:
                t = 0.0
            else:
                t = (d-ri)/(ro-ri)
            col = lerp(inner, outer, t)
            a = int(round((1-t) * inner[3] + t*outer[3]))
            px[x,y] = (col[0], col[1], col[2], a)
    return img

def rounded_rect_mask(w, h, r):
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0,0,w-1,h-1], radius=r, fill=255)
    return m

def glow_disc(canvas, cx, cy, radius, color, alpha, blur):
    """Composite a soft blurred circular glow onto canvas (artifact-free)."""
    layer = Image.new("RGBA", canvas.size, (0,0,0,0))
    d = ImageDraw.Draw(layer)
    d.ellipse([cx-radius, cy-radius, cx+radius, cy+radius],
              fill=(color[0], color[1], color[2], alpha))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    return Image.alpha_composite(canvas, layer)

# ---- background square tile (squircle-ish rounded rect) ----
tile = Image.new("RGBA", (W, W), (0,0,0,0))
# vertical dark gradient
grad = Image.new("RGBA", (W, W))
gp = grad.load()
top = (14, 19, 27)      # #0e131b
bot = (5, 7, 11)        # #05070b
for y in range(W):
    t = y / (W-1)
    c = lerp(top, bot, t)
    for x in range(W):
        gp[x, y] = (c[0], c[1], c[2], 255)
mask = rounded_rect_mask(W, W, int(W*0.225))
tile.paste(grad, (0,0), mask)

# central ambient blue glow behind the pill
tile = glow_disc(tile, W//2, W//2, int(W*0.28), (40,150,255), 70, 60*S)

# ---- the pill ----
pill_w = int(W*0.72)
pill_h = int(W*0.30)
pill_x = (W - pill_w)//2
pill_y = (W - pill_h)//2
pr = pill_h//2

# outer soft rim glow of the pill
rim = Image.new("RGBA", (W, W), (0,0,0,0))
rd = ImageDraw.Draw(rim)
rd.rounded_rectangle([pill_x-6*S, pill_y-6*S, pill_x+pill_w+6*S, pill_y+pill_h+6*S],
                     radius=pr+6*S, outline=(70,170,255,180), width=5*S)
rim = rim.filter(ImageFilter.GaussianBlur(9*S))
tile = Image.alpha_composite(tile, rim)

# pill body
body = Image.new("RGBA", (W, W), (0,0,0,0))
bd = ImageDraw.Draw(body)
bd.rounded_rectangle([pill_x, pill_y, pill_x+pill_w, pill_y+pill_h],
                     radius=pr, fill=(9,13,20,255))
# subtle inner top highlight
bd.rounded_rectangle([pill_x, pill_y, pill_x+pill_w, pill_y+pill_h],
                     radius=pr, outline=(90,150,210,60), width=2*S)
tile = Image.alpha_composite(tile, body)

# ---- five dots ----
cx = W//2
cy = W//2
gap = int(pill_w*0.185)
# (offset index, diameter, core color, glow strength)
BRIGHT = (90, 200, 255)   # cyan center
MID    = (55, 120, 150)   # teal
DIM    = (45, 95, 120)    # dim teal
dots = [
    (-2, int(pill_h*0.42), DIM,    0.5),
    (-1, int(pill_h*0.34), MID,    0.55),
    ( 0, int(pill_h*0.54), BRIGHT, 1.0),
    ( 1, int(pill_h*0.34), MID,    0.55),
    ( 2, int(pill_h*0.42), DIM,    0.5),
]
def draw_dots(canvas):
    for off, dia, col, gs in dots:
        dcx = cx + off*gap
        r = dia//2
        # soft glow halo (blurred disc)
        canvas = glow_disc(canvas, dcx, cy, int(r*1.5), col, int(160*gs), int(r*0.9))
        # solid core with a brighter center highlight
        core = radial_glow(dia*2,
                           (min(col[0]+70,255),min(col[1]+50,255),min(col[2]+30,255),255),
                           col+(255,), 0.0, 0.5)
        disc = Image.new("L", (dia*2, dia*2), 0)
        ImageDraw.Draw(disc).ellipse([dia-r, dia-r, dia+r, dia+r], fill=255)
        canvas.paste(Image.composite(core, Image.new("RGBA",(dia*2,dia*2),(0,0,0,0)), disc),
                     (dcx-dia, cy-dia), disc)
    return canvas

tile = draw_dots(tile)

# downsample
master = tile.resize((N, N), Image.LANCZOS)
master.save(os.path.join(OUT, "polyhelm-icon-1024.png"))

# transparent standalone pill mark (crop to pill bbox with padding), for in-app/Logos
pad = int(W*0.04)
markbox = (pill_x-pad, pill_y-pad, pill_x+pill_w+pad, pill_y+pill_h+pad)
# rebuild mark on transparent bg: reuse body+dots by compositing over transparent
markfull = Image.new("RGBA", (W, W), (0,0,0,0))
markfull = Image.alpha_composite(markfull, rim)
markfull = Image.alpha_composite(markfull, body)
markfull = draw_dots(markfull)
mark = markfull.crop(markbox).resize(
    (int((markbox[2]-markbox[0])/S), int((markbox[3]-markbox[1])/S)), Image.LANCZOS)
mark.save(os.path.join(OUT, "polyhelm-mark.png"))
print("wrote polyhelm-icon-1024.png", master.size, "and polyhelm-mark.png", mark.size)
