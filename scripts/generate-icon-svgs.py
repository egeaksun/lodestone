# Generates Assets/AppIcon.svg and Assets/MenuBarIcon.svg. Usage: python3 scripts/generate-icon-svgs.py Assets
import math, sys
out = sys.argv[1]
# Apple-style squircle (superellipse, n=5) for the 824pt icon body on a 1024 canvas.
def squircle(cx, cy, a, n=5, steps=240):
    pts=[]
    for i in range(steps):
        t = 2*math.pi*i/steps
        c, s = math.cos(t), math.sin(t)
        x = cx + a*math.copysign(abs(c)**(2/n), c)
        y = cy + a*math.copysign(abs(s)**(2/n), s)
        pts.append("%.1f %.1f"%(x,y))
    return "M"+" L".join(pts)+" Z"
body = squircle(512, 512, 412)
P = [(252,548),(282,410),(392,300),(556,262),(706,298),(790,412),(798,566),(726,704),(566,778),(392,764),(282,676)]
def spline(P):
    n=len(P); d="M %g %g"%P[0]
    for i in range(n):
        p0,p1,p2,p3=P[i-1],P[i],P[(i+1)%n],P[(i+2)%n]
        c1=(p1[0]+(p2[0]-p0[0])/6, p1[1]+(p2[1]-p0[1])/6)
        c2=(p2[0]-(p3[0]-p1[0])/6, p2[1]-(p3[1]-p1[1])/6)
        d+=" C %.1f %.1f %.1f %.1f %g %g"%(c1+c2+p2)
    return d+" Z"
pebble = spline(P)
gap = 28; cx, cy = 522, 522
def quads(g, x0, y0, x1, y1):
    h = g/2
    return [(x0, y0, cx-h-x0, cy-h-y0), (cx+h, y0, x1-cx-h, cy-h-y0),
            (x0, cy+h, cx-h-x0, y1-cy-h), (cx+h, cy+h, x1-cx-h, y1-cy-h)]
q = quads(gap, 200, 220, 830, 820)
rect = lambda r, fill: '<rect x="%g" y="%g" width="%g" height="%g" fill="%s"/>' % (r + (fill,))
app = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#4A5C86"/>
      <stop offset="1" stop-color="#1C2438"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.16"/>
      <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="stone" gradientUnits="userSpaceOnUse" x1="300" y1="270" x2="760" y2="780">
      <stop offset="0" stop-color="#D6DBE4"/>
      <stop offset="1" stop-color="#5D6678"/>
    </linearGradient>
    <linearGradient id="glow" gradientUnits="userSpaceOnUse" x1="270" y1="280" x2="510" y2="510">
      <stop offset="0" stop-color="#FFD27A"/>
      <stop offset="1" stop-color="#F0862A"/>
    </linearGradient>
    <radialGradient id="shadow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#000000" stop-opacity="0.45"/>
      <stop offset="1" stop-color="#000000" stop-opacity="0"/>
    </radialGradient>
    <clipPath id="pebble"><path d="{pebble}"/></clipPath>
  </defs>
  <path d="{body}" fill="url(#bg)"/>
  <path d="{body}" fill="url(#sheen)"/>
  <ellipse cx="520" cy="800" rx="290" ry="46" fill="url(#shadow)"/>
  <g clip-path="url(#pebble)">
    {rect(q[0], "url(#glow)")}
    {rect(q[1], "url(#stone)")}
    {rect(q[2], "url(#stone)")}
    {rect(q[3], "url(#stone)")}
  </g>
</svg>
'''
open(out+"/AppIcon.svg","w").write(app)
# Menu bar template: same pebble and split, black on transparent, 18pt.
s = 16/546; tx = 9 - (252+798)/2*s; ty = 9 - (262+778)/2*s
mq = quads(gap*1.45, 200, 220, 830, 820)
mb = f'''<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
  <defs><clipPath id="pebble"><path d="{pebble}"/></clipPath></defs>
  <g transform="translate({tx:.3f} {ty:.3f}) scale({s:.5f})">
    <g clip-path="url(#pebble)">
      {"".join(rect(r, "#000") for r in mq)}
    </g>
  </g>
</svg>
'''
open(out+"/MenuBarIcon.svg","w").write(mb)
