# dmgbuild settings for the Blend disk image: tools/release.sh passes the app path as
# -Dapp=... Finder shows the window at this size with the toolbar, sidebar and status bar
# hidden. The icon centres match the arrow ends in background.svg; if either changes,
# regenerate the PNGs with tools/dmg/render.sh and re-run tools/dmg/preview.py.
import os

app = defines["app"]  # noqa: F821 (dmgbuild injects defines)
here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else "."

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Blend.app"]

background = os.path.join(here, "background.png")  # background@2x.png is found beside it
# Finder's window height includes the 28 point title bar; the artwork is 640 x 400.
window_rect = ((200, 120), (640, 428))
icon_size = 128
text_size = 13
icon_locations = {"Blend.app": (190, 170), "Applications": (450, 170)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
arrange_by = None
