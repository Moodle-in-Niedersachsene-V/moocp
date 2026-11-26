#!/usr/bin/env bash
# Baut das Disk-Image für den Mac: installer/moocp_<Version>_macos.dmg (E24).
# Wer es öffnet, sieht moocp neben „Programme“ und zieht die App hinüber.
#
#   bash tool/mac_dmg.sh
#
# Die App ist ein Release-Bau (tool/mac_bau.sh release, nie der Testbetrieb)
# für Apple Silicon und Intel zugleich; fehlt eine der beiden Architekturen,
# bricht das Skript ab. Sie ist nicht signiert und nicht von Apple beglaubigt:
# Beim ersten Öffnen fragt macOS deshalb nach (README, „Installation auf dem
# Mac“).
#
# Das Fenster der DMG beschreibt installer/macos/dmg_einstellungen.py. Gebaut
# wird mit dmgbuild 1.6.5 (BSD) und seinen Paketen ds_store und mac_alias (MIT),
# beim ersten Lauf nach build/tools geladen und gegen die festen Prüfsummen
# unten geprüft. Diese Versionen laufen noch mit dem Python 3.9 von Apple;
# neuere brauchen Python 3.11.
set -euo pipefail
cd "$(dirname "$0")/.."
unset MOOCP_TESTZUGANG_PROFILE MOOCP_TESTZUGANG MOOCP_TESTZUGANG_ADRESSE
VERSION="$(sed -nE 's/^version: *([0-9][0-9.]*(-[0-9A-Za-z.]+)?).*/\1/p' pubspec.yaml | head -1)"
[[ -n "$VERSION" ]] || { echo 'Version in pubspec.yaml nicht gefunden' >&2; exit 1; }

WERKZEUG="build/tools/dmgbuild-1.6.5"
if [[ ! -x "$WERKZEUG/bin/dmgbuild" ]]; then
  rm -rf "$WERKZEUG"
  python3 -m venv "$WERKZEUG"
  "$WERKZEUG/bin/pip" install --quiet --disable-pip-version-check --no-deps --only-binary :all: --require-hashes -r /dev/stdin <<'PAKETE'
dmgbuild==1.6.5 --hash=sha256:e19ab8c5e8238e6455d9ccb9175817be7fd62b9cdd1eef20f63dd88e0ec469ab
ds_store==1.3.1 --hash=sha256:fbacbb0bd5193ab3e66e5a47fff63619f15e374ffbec8ae29744251a6c8f05b5
mac_alias==2.2.2 --hash=sha256:504ab8ac546f35bbd75ad014d6ad977c426660aa721f2cd3acf3dc2f664141bd
PAKETE
fi

# Eine DMG von früher darf nach einem Abbruch nicht für die neue gehalten werden.
AUS="installer/moocp_${VERSION}_macos.dmg"
rm -f "$AUS"
bash tool/mac_bau.sh release
APP="build/macos/Build/Products/Release/moocp.app"
ARCHS=" $(lipo -archs "$APP/Contents/MacOS/moocp") "
for arch in arm64 x86_64; do
  [[ "$ARCHS" == *" $arch "* ]] || { echo "Der Bau enthält $arch nicht (gefunden:$ARCHS)" >&2; exit 1; }
done

# Die Brücke für KI-Werkzeuge liegt in der App (tool/mac_bau.sh) und muss auf
# jedem Mac laufen, auf dem die App läuft.
BRUECKE_ARCHS=" $(lipo -archs "$APP/Contents/MacOS/moocp-bruecke") "
for arch in arm64 x86_64; do
  [[ "$BRUECKE_ARCHS" == *" $arch "* ]] || { echo "Die Brücke enthält $arch nicht (gefunden:$BRUECKE_ARCHS); MOOCP_BRUECKE_ANDERE_ARCH nennt die Brücke der anderen Architektur (tool/mac_bau.sh)" >&2; exit 1; }
done

mkdir -p installer
"$WERKZEUG/bin/dmgbuild" -s installer/macos/dmg_einstellungen.py \
  -D app="$APP" -D hintergrund=installer/macos/hintergrund.png moocp "$AUS"
echo "DMG-OK $AUS"
