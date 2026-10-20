# dmgbuild settings for Flatline.dmg, used by app/make-dmg.sh (https://dmgbuild.readthedocs.io)
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/Flatline.icns")
background = "app/dmg/background.tiff"  # 640x400 with a @2x layer for Retina
format = "ULFO"
window_rect = ((200, 160), (640, 400))
icon_size = 112
text_size = 13
icon_locations = {"Flatline.app": (160, 200), "Applications": (480, 200)}
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
