# Einstellungen für dmgbuild: das Fenster, das die DMG beim Öffnen zeigt
# (tool/mac_dmg.sh, E24). dmgbuild führt diese Datei aus und gibt ihr die
# Werte aus -D als `defines`.
#
# Das Fenster ist so groß wie der Hintergrund (560 × 360), ohne Symbolleiste,
# Pfadleiste und Statusleiste: links die App, rechts die Verknüpfung auf
# /Applications, dazwischen der Pfeil aus dem Hintergrund. Die Verknüpfung
# heißt „Programme“, weil der Finder den Namen einer Verknüpfung nicht
# übersetzt und Lehrkräfte den Ordner unter diesem Namen kennen. Die Lagen in
# icon_locations sind die Mitten der Symbole und müssen zu
# installer/macos/hintergrund.svg passen.
#
# dmgbuild schreibt Fensterlage und Hintergrund selbst in die .DS_Store der
# DMG und braucht dafür keinen Finder; der übliche Weg über AppleScript
# fernsteuert den Finder und hängt auf Build-Rechnern ohne Anmeldung.
# hintergrund@2x.png neben hintergrund.png findet dmgbuild selbst und legt
# beide als ein Bild für Retina-Bildschirme ab.
import os.path

app = defines["app"]  # noqa: F821 – von dmgbuild gesetzt
name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Programme": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
background = defines["hintergrund"]  # noqa: F821 – von dmgbuild gesetzt

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 120), (560, 360))
default_view = "icon-view"
show_icon_preview = False
icon_size = 128
text_size = 13
icon_locations = {name: (140, 150), "Programme": (420, 150)}
