# Generates Assets/AppIcon.svg and Assets/MenuBarIcon.svg.
# Usage: python3 scripts/generate-icon-svgs.py <out dir> [frame]
#
# The stone is a hand-traced, faceted lodestone (11 flat facets, lit from the top left). The frame is
# an Apple-style squircle (superellipse) body on the standard 1024 canvas, 824pt wide.
import math
import sys

out = sys.argv[1]
frame_name = sys.argv[2] if len(sys.argv) > 2 else "copper"

# Stone geometry, in the coordinates it was traced in (a 1024 canvas, stone centered near 510,511).
V = {
    "p1": (336, 286), "p2": (465, 285), "p3": (600, 350), "p4": (663, 367), "p5": (775, 387),
    "p6": (868, 483), "p7": (868, 575), "p8": (793, 670), "p9": (707, 708), "p10": (515, 718),
    "p11": (395, 738), "p12": (248, 720), "p13": (222, 675), "p14": (170, 612), "p15": (153, 570),
    "p16": (190, 450), "p17": (230, 420), "p18": (264, 338),
    "q1": (302, 380), "q2": (385, 380), "q3": (310, 516), "q4": (470, 462), "q5": (790, 507),
    "q6": (208, 522), "q7": (358, 625), "q8": (735, 590), "q9": (643, 625), "q10": (585, 690),
}
SILHOUETTE = ["p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9", "p10", "p11", "p12", "p13", "p14", "p15", "p16", "p17", "p18"]

# (name, vertices, base color, menu bar alpha). Order is back to front; facets share edges exactly.
FACETS = [
    ("top-left", ["p1", "p2", "q2", "q1", "p18"], "#8FA6BC", 1.0),
    ("top", ["p2", "p3", "p4", "q4", "q3", "q2"], "#67809A", 1.0),
    ("top-right", ["p4", "p5", "p6", "q5", "q4"], "#4E627B", 1.0),
    ("notch", ["p18", "q1", "p17"], "#3A3D44", 0.55),
    ("left", ["p17", "q1", "q2", "q3", "q6", "p16"], "#4B4F58", 0.55),
    ("rust-left", ["p16", "q6", "p14", "p15"], "#8A4334", 0.55),
    ("lower-left", ["q6", "q3", "q7", "p12", "p13", "p14"], "#393C43", 0.55),
    ("front", ["q3", "q4", "q5", "q8", "q9", "q10", "q7"], "#2A2C32", 0.8),
    ("rust-front", ["q9", "q8", "p9", "q10"], "#84412F", 0.8),
    ("right", ["q5", "p6", "p7", "p8", "p9", "q8"], "#30333A", 0.4),
    ("bottom", ["q7", "q10", "p9", "p10", "p11", "p12"], "#1E1F24", 0.4),
]

# Edges that catch the light: the top silhouette and the ridge between the top and the front.
RIM = ["p15", "p16", "p17", "p18", "p1", "p2", "p3", "p4", "p5", "p6"]
RIDGE = ["q6", "q3", "q4", "q5", "p6"]


def pts(names, f=lambda p: p):
    return " ".join("%.2f,%.2f" % f(V[n]) for n in names)


def shade(hex_color, amount):
    """Lighten (amount > 0) or darken (amount < 0) a color by mixing with white or black."""
    r, g, b = (int(hex_color[i:i + 2], 16) for i in (1, 3, 5))
    target = 255 if amount > 0 else 0
    a = abs(amount)
    return "#%02X%02X%02X" % tuple(round(c + (target - c) * a) for c in (r, g, b))


def squircle(cx, cy, a, n=5, steps=256):
    points = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        points.append("%.2f %.2f" % (cx + a * math.copysign(abs(c) ** (2 / n), c),
                                     cy + a * math.copysign(abs(s) ** (2 / n), s)))
    return "M" + " L".join(points) + " Z"


FRAMES = {
    # Warm copper plate: high contrast against the iron stone, and it echoes the rust facets.
    "copper": dict(top="#F6BC74", bottom="#A9441C", glow="#FFE6B8", glow_opacity=0.6, field="#6B2408", field_opacity=0.32),
    # Brushed silver plate.
    "silver": dict(top="#F4F6F9", bottom="#B9C2CF", glow="#FFFFFF", glow_opacity=0.7, field="#5D6B80", field_opacity=0.16),
    # Deep blue-black, the closest to Obsidian's mood.
    "midnight": dict(top="#3A4A6E", bottom="#121725", glow="#8FB3E8", glow_opacity=0.35, field="#9FB8E0", field_opacity=0.12),
}

body = squircle(512, 512, 412)
fr = FRAMES[frame_name]

# Place the stone: about 600pt wide, centered slightly above the body's middle.
SCALE = 0.9
CX, CY = 510, 511
TX, TY = 512, 508
place = lambda p: (TX + (p[0] - CX) * SCALE, TY + (p[1] - CY) * SCALE)

defs = []
shapes = []
for i, (name, verts, color, _) in enumerate(FACETS):
    gid = "f%d" % i
    defs.append(
        '<linearGradient id="%s" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>'
        % (gid, shade(color, 0.10), shade(color, -0.12)))
    # A hairline stroke in the fill color closes anti-aliasing seams between facets.
    shapes.append('<polygon points="%s" fill="url(#%s)" stroke="%s" stroke-width="0.8" stroke-linejoin="round"/>'
                  % (pts(verts, place), gid, color))

# Magnetic field lines: faint arcs around the stone, like iron filings on paper.
field = []
for k, (rx, ry) in enumerate([(352, 250), (396, 290), (440, 330)]):
    field.append('<ellipse cx="%d" cy="%d" rx="%d" ry="%d" fill="none" stroke="%s" stroke-opacity="%.3f" stroke-width="%.1f" stroke-linecap="round" stroke-dasharray="0.1 %d"/>'
                 % (TX, TY + 14, rx, ry, fr["field"], fr["field_opacity"] * (1 - 0.28 * k), 7 - 1.5 * k, 16 + 4 * k))

app = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{fr["top"]}"/>
      <stop offset="1" stop-color="{fr["bottom"]}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.45" cy="0.38" r="0.55">
      <stop offset="0" stop-color="{fr["glow"]}" stop-opacity="{fr["glow_opacity"]}"/>
      <stop offset="1" stop-color="{fr["glow"]}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/>
      <stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="shadow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#000000" stop-opacity="0.5"/>
      <stop offset="0.6" stop-color="#000000" stop-opacity="0.18"/>
      <stop offset="1" stop-color="#000000" stop-opacity="0"/>
    </radialGradient>
    <clipPath id="body"><path d="{body}"/></clipPath>
    {"".join(defs)}
  </defs>
  <path d="{body}" fill="url(#bg)"/>
  <g clip-path="url(#body)">
    <rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>
    {"".join(field)}
    <ellipse cx="{TX + 10}" cy="{TY + 205}" rx="300" ry="44" fill="url(#shadow)"/>
  </g>
  <path d="{body}" fill="url(#sheen)"/>
  <g stroke-linejoin="round">
    {"".join(shapes)}
    <polyline points="{pts(RIM, place)}" fill="none" stroke="#FFFFFF" stroke-opacity="0.45" stroke-width="3"/>
    <polyline points="{pts(RIDGE, place)}" fill="none" stroke="#C9D8E8" stroke-opacity="0.35" stroke-width="2.5"/>
  </g>
</svg>
'''
open(out + "/AppIcon.svg", "w").write(app)

# Menu bar template: the same facets as alpha levels (the system tints it for light and dark menu bars),
# fitted to an 18pt square with a little margin.
xs = [V[n][0] for n in SILHOUETTE]
ys = [V[n][1] for n in SILHOUETTE]
w, h = max(xs) - min(xs), max(ys) - min(ys)
s = 16.5 / w
mx = 9 - (min(xs) + w / 2) * s
my = 9 - (min(ys) + h / 2) * s
small = lambda p: (mx + p[0] * s, my + p[1] * s)
polys = "".join('<polygon points="%s" fill="#000" fill-opacity="%.2f"/>' % (pts(v, small), a) for _, v, _, a in FACETS)
mb = f'''<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
  {polys}
</svg>
'''
open(out + "/MenuBarIcon.svg", "w").write(mb)
