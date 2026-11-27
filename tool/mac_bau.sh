#!/usr/bin/env bash
# Baut die App für den Mac in einer Kopie im Temp-Ordner und legt sie nach
# build/macos/Build/Products/<Debug|Release>/. Grund: docs/agents/testing.md.
#
#   bash tool/mac_bau.sh            Entwicklungsbau (Debug)
#   bash tool/mac_bau.sh release    Bau ohne Debugmodus
#
# Ist eine der Variablen MOOCP_TESTZUGANG_PROFILE, MOOCP_TESTZUGANG oder
# MOOCP_TESTZUGANG_ADRESSE gesetzt, entsteht ein Debug-Bau mit Testbetrieb
# (--dart-define=MOOCP_TESTBETRIEB=true, lib/testschalter.dart); neben dem Bau
# liegt dann die Marke „testbetrieb". Ohne die Variablen entsteht ein Bau ohne
# Testbetrieb, und die Marke fehlt. Ein Release-Bau hat den Testbetrieb nie.
#
# Die Brücke für KI-Werkzeuge (bin/moocp_bruecke.dart, E21) kommt als
# Contents/MacOS/moocp-bruecke in die App, wie moocp-bruecke.exe unter Windows
# neben moocp.exe liegt. Gebaut wird sie mit `dart build cli` (nicht `dart
# compile exe`: Das lehnt Pakete mit Build-Hooks ab) für die Architektur dieses
# Macs. Dart übersetzt nicht für die andere Architektur; eine universelle App
# (Release, DMG) braucht darum zusätzlich die auf der anderen Architektur
# gebaute Brücke in MOOCP_BRUECKE_ANDERE_ARCH, die hier mit der eigenen
# zusammengefügt wird (lipo). Danach wird die App neu ad hoc signiert: Eine
# Datei, die der Bau nicht kannte, bräche sonst das Siegel.
set -euo pipefail
MODUS="${1:-debug}"
case "$MODUS" in
  debug) ZIEL=Debug ;;
  release) ZIEL=Release ;;
  *) echo "Unbekannter Modus: $MODUS (debug oder release)" >&2; exit 2 ;;
esac
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TESTBETRIEB=nein
DEFINES=()
if [[ "$MODUS" == debug && -n "${MOOCP_TESTZUGANG_PROFILE:-}${MOOCP_TESTZUGANG:-}${MOOCP_TESTZUGANG_ADRESSE:-}" ]]; then
  TESTBETRIEB=ja
  DEFINES=(--dart-define=MOOCP_TESTBETRIEB=true)
fi
TMP=$(mktemp -d /tmp/moocp-bau.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
rsync -a --delete --exclude build --exclude .git --exclude .dart_tool "$REPO"/ "$TMP"/
# ${DEFINES[@]+...}: Das Mac-bash 3.2 meldet ein leeres Feld unter `set -u` als nicht gesetzt.
(cd "$TMP" && flutter build macos --"$MODUS" ${DEFINES[@]+"${DEFINES[@]}"})
APP_TMP="$TMP/build/macos/Build/Products/$ZIEL/moocp.app"
(cd "$TMP" && dart build cli -t bin/moocp_bruecke.dart -o build/bruecke --verbosity=error)
BRUECKE="$TMP/build/bruecke/bundle/bin/moocp_bruecke"
if [[ -n "${MOOCP_BRUECKE_ANDERE_ARCH:-}" ]]; then
  lipo -create -output "$APP_TMP/Contents/MacOS/moocp-bruecke" "$BRUECKE" "$MOOCP_BRUECKE_ANDERE_ARCH"
else
  cp "$BRUECKE" "$APP_TMP/Contents/MacOS/moocp-bruecke"
fi
chmod 755 "$APP_TMP/Contents/MacOS/moocp-bruecke"
ENTITLEMENTS="$TMP/macos/Runner/DebugProfile.entitlements"
[[ "$MODUS" == release ]] && ENTITLEMENTS="$TMP/macos/Runner/Release.entitlements"
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_TMP"
mkdir -p "$REPO/build/macos/Build/Products/$ZIEL"
rm -rf "$REPO/build/macos/Build/Products/$ZIEL/moocp.app"
cp -R "$TMP/build/macos/Build/Products/$ZIEL/moocp.app" "$REPO/build/macos/Build/Products/$ZIEL/"
if [[ "$TESTBETRIEB" == ja ]]; then
  : > "$REPO/build/macos/Build/Products/$ZIEL/testbetrieb"
  echo 'Bau mit Testbetrieb (MOOCP_TESTBETRIEB)'
else
  rm -f "$REPO/build/macos/Build/Products/$ZIEL/testbetrieb"
fi
echo BAU-OK
