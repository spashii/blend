#!/bin/sh
# Renders background.svg to background.png (1x) and background@2x.png. Needs cairosvg:
# python3 -m venv v && v/bin/pip install cairosvg
set -e
cd "$(dirname "$0")"
python3 - <<'PY'
import cairosvg
cairosvg.svg2png(url="background.svg", write_to="background.png", output_width=640, output_height=400)
cairosvg.svg2png(url="background.svg", write_to="background@2x.png", output_width=1280, output_height=800)
PY
