"""Mock-up of the Finder window at 2x: the background with the app icon and a stand-in
Applications folder at the positions in settings.py. Finder draws the real icons and
labels, so this only checks alignment and balance. Needs cairosvg and pillow.
Usage: preview.py OUT.png"""
import io, sys
import cairosvg
from PIL import Image, ImageDraw, ImageFont

S = 2
ICON = 128
POSITIONS = {"Blend": (190, 170), "Applications": (450, 170)}
LABEL_Y = 170 + ICON // 2 + 8

app_svg = """<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4d9bff"/><stop offset="1" stop-color="#2361f4"/></linearGradient></defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#g)"/>
<path d="M512.0,311.2 A236,236 0 0 1 512.0,712.8 A236,236 0 0 1 512.0,311.2 Z" fill="#fff"/>
<g opacity=".55"><circle cx="388" cy="512" r="236" fill="#fff"/><circle cx="636" cy="512" r="236" fill="#fff"/></g>
</svg>"""
folder_svg = """<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs><linearGradient id="b" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6ec6fb"/><stop offset="1" stop-color="#2a8fe0"/></linearGradient></defs>
<path d="M110 230 q0-50 50-50 h210 q30 0 50 25 l30 35 h414 q50 0 50 50 v60 H110z" fill="#4aa8ee"/>
<rect x="110" y="320" width="804" height="520" rx="50" fill="url(#b)"/>
<path d="M512 430 l70 200 h-30 l-40-120 -40 120 h-30z" fill="#fff" opacity=".85"/>
</svg>"""

def png(svg):
    return Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg.encode(), output_width=ICON * S, output_height=ICON * S))).convert("RGBA")

bg = Image.open("background@2x.png").convert("RGBA")
for name, svg in (("Blend", app_svg), ("Applications", folder_svg)):
    cx, cy = POSITIONS[name]
    ic = png(svg)
    bg.alpha_composite(ic, ((cx - ICON // 2) * S, (cy - ICON // 2) * S))
d = ImageDraw.Draw(bg)
font = ImageFont.truetype("/home/sam2k/.local/share/fonts/inter/InterVariable.ttf", 13 * S)
for name, (cx, _) in POSITIONS.items():
    d.text((cx * S, LABEL_Y * S), name, fill="#1d1d1f", font=font, anchor="ma")
bg.convert("RGB").save(sys.argv[1])
