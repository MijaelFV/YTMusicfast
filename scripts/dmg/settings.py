# dmgbuild layout for the release DMG (scripts/release.sh passes -D app=… -D background=…).
# Icon centres match the arrow in scripts/make-dmg-background.swift.
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

background = defines["background"]
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
icon_locations = {
    app_name: (165, 185),
    "Applications": (495, 185),
}
