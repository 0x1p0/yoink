# dmgbuild settings for the Yoink installer.
#
#   dmgbuild -s packaging/dmg/settings.py -D app=path/to/Yoink.app "Yoink" Yoink.dmg
#
# dmgbuild writes Finder's window layout (.DS_Store) directly, so the styled window
# works on headless CI machines without scripting Finder.
import os.path

application = defines.get("app", "Yoink.app")  # noqa: F821 (provided by dmgbuild)
appname = os.path.basename(application)
here = defines.get("assets", "packaging/dmg")  # noqa: F821

# ── Volume ────────────────────────────────────────────────────────────────────
# LZMA compression: the smallest download. Opens on macOS 10.15+, below our minimum.
format = "ULMO"
filesystem = "HFS+"
size = None
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(here, "VolumeIcon.icns")

# ── Window ────────────────────────────────────────────────────────────────────
# Keep icon positions in sync with make_background.swift.
background = os.path.join(here, "background.tiff")
window_rect = ((200, 140), (660, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 180
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

# ── Icon view ────────────────────────────────────────────────────────────────
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 120
icon_locations = {
    appname: (170, 210),
    "Applications": (490, 210),
}
# Don't use hide_extensions: it writes a Finder flag onto the .app bundle, which breaks its
# code signature ("Finder information … not allowed") and makes macOS call the app damaged.
# Finder already hides the .app extension on its own.
