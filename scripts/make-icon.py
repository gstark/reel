#!/usr/bin/env python3
"""Writes the layer SVGs of Sources/Reel.icon and the flat preview in assets/icon.svg.

Sources/Reel.icon/icon.json holds the background color and the Liquid Glass settings.
Open Sources/Reel.icon in Icon Composer to see the rendered icon."""
import math, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, "Sources/Reel.icon")
os.makedirs(out + "/Assets", exist_ok=True)

def circle(cx, cy, r):
    return f"M{cx-r:.1f} {cy:.1f}a{r} {r} 0 1 0 {2*r} 0a{r} {r} 0 1 0 {-2*r} 0Z"

def rrect(x, y, w, h, r):
    return (f"M{x+r:.1f} {y:.1f}h{w-2*r:.1f}a{r} {r} 0 0 1 {r} {r}v{h-2*r:.1f}a{r} {r} 0 0 1 {-r} {r}"
            f"h{-(w-2*r):.1f}a{r} {r} 0 0 1 {-r} {-r}v{-(h-2*r):.1f}a{r} {r} 0 0 1 {r} {-r}Z")

# Reel: a disc with a rim groove, three rounded windows, and a spindle hole.
CX, CY, R = 470, 440, 320
def polar(a, r):
    a = math.radians(a)
    return f"{CX + r * math.cos(a):.1f} {CY + r * math.sin(a):.1f}"
def window(a0, a1, r1, r2, rc):
    l2, l1 = math.sqrt((r2 - rc) ** 2 - rc ** 2), math.sqrt((r1 + rc) ** 2 - rc ** 2)
    d2, d1 = math.degrees(math.asin(rc / (r2 - rc))), math.degrees(math.asin(rc / (r1 + rc)))
    big = 1 if a1 - a0 - 2 * d2 > 180 else 0
    return (f"M{polar(a0, l2)}A{rc} {rc} 0 0 1 {polar(a0 + d2, r2)}"
            f"A{r2} {r2} 0 {big} 1 {polar(a1 - d2, r2)}A{rc} {rc} 0 0 1 {polar(a1, l2)}"
            f"L{polar(a1, l1)}A{rc} {rc} 0 0 1 {polar(a1 - d1, r1)}"
            f"A{r1} {r1} 0 0 0 {polar(a0 + d1, r1)}A{rc} {rc} 0 0 1 {polar(a0, l1)}Z")
d = [circle(CX, CY, R), circle(CX, CY, 298), circle(CX, CY, 284)]
for c in (-90, 30, 150):
    d.append(window(c - 37, c + 37, 100, 232, 34))
d.append(circle(CX, CY, 30))
reel = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="metal" x1="0" y1="0" x2="0.35" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#C7CDD6"/>
    </linearGradient>
  </defs>
  <path fill-rule="evenodd" fill="url(#metal)" d="{''.join(d)}"/>
</svg>
'''

# Film: a strip at -18 degrees with sprocket holes cut out and frame cells.
W, H = 1900, 236
body = [rrect(-W/2, -H/2, W, H, 0)]
for i in range(-22, 23):
    x = i * 46 - 16
    body.append(rrect(x, -H/2 + 16, 32, 24, 8))
    body.append(rrect(x, H/2 - 40, 32, 24, 8))
frames = [rrect(k * 196 - 80, -66, 160, 132, 16) for k in range(-5, 4) if k != 1]
film = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <g transform="translate(540 838) rotate(-18)">
    <path fill-rule="evenodd" fill="#191B22" d="{''.join(body)}"/>
    <path fill="#3B414D" d="{''.join(frames)}"/>
  </g>
</svg>
'''
# The paused frame, in its own layer so it sits above the strip.
frame = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <g transform="translate(540 838) rotate(-18)">
    <path fill="#FFC43D" d="{rrect(196 - 80, -66, 160, 132, 16)}"/>
  </g>
</svg>
'''
for name, svg in [("reel", reel), ("film", film), ("frame", frame)]:
    open(f"{out}/Assets/{name}.svg", "w").write(svg)

# Flat preview for the README: background, film, frame, reel. It approximates the glass render.
inner = lambda s: s.split(">", 1)[1].rsplit("</svg>", 1)[0]
open(os.path.join(root, "assets/icon.svg"), "w").write(f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#D0313F"/>
      <stop offset="1" stop-color="#8A1426"/>
    </linearGradient>
    <clipPath id="squircle"><rect width="1024" height="1024" rx="230"/></clipPath>
  </defs>
  <g clip-path="url(#squircle)">
    <rect width="1024" height="1024" fill="url(#bg)"/>
    {inner(film)}
    {inner(frame)}
    {inner(reel)}
  </g>
</svg>
''')
