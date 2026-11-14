#!/usr/bin/env bash
# Startet das Beispiel-Plugin zum Entwickeln und hängt es an moocp an
# (README, Teil 4, „Ein Plugin entwickeln“). Auf dem Mac; unter Windows tut
# entwickeln.ps1 dasselbe.
#
#   bash example/example-plugin/entwickeln.sh [Pfad zum Programm von moocp]
#
# Auf dem Mac gibt es moocp nur aus dem Entwicklungsbau (tool/mac_bau.sh);
# Vorgabe ist deshalb das Programm in dessen Bau im Repository von moocp,
# zwei Ordner über diesem.
#
# Was das Skript tut, tut jeder Plugin-Entwickler auf seine Weise:
#
# 1. einen zufälligen Schlüssel erzeugen und in die Umgebungsvariable
#    MOOCP_PLUGIN_SCHLUESSEL legen -- nie auf die Kommandozeile, dort stünde
#    er in jeder Prozessliste. Plugin und moocp erben ihn von hier;
# 2. das Plugin auf dem Port aus `entwicklungsPort` in plugin.json starten
#    (`--port <Zahl>`), hier aus dem Quelltext mit `dart run`, sonst im
#    Debugger; `--entwicklung` hält das Beispiel am Leben, auch wenn seine
#    Standardeingabe endet;
# 3. moocp mit `--plugin-entwicklung <dieser Ordner>` starten. moocp fragt im
#    Dialog „Entwicklungs-Plugin anhängen“, ob es sich verbinden soll.
#
# Läuft moocp schon, holt der Start nur das Fenster nach vorn und hängt
# nichts an: moocp vorher beenden. Ein neu gebautes und neu gestartetes
# Plugin braucht keinen neuen Start von moocp, solange es denselben Schlüssel
# bekommt. Deshalb behält das Skript den Schlüssel, bis es selbst endet: Endet
# das Plugin, startet Enter es mit demselben Schlüssel neu (etwa nach einer
# Änderung am Quelltext), und moocp verbindet sich wieder, sobald es zurück
# ist. Strg+C beendet das Plugin und das Skript; moocp läuft weiter.
set -euo pipefail

ORDNER="$(cd "$(dirname "$0")" && pwd)"
MOOCP="${1:-$ORDNER/../../build/macos/Build/Products/Debug/moocp.app/Contents/MacOS/moocp}"

if [[ ! -x "$MOOCP" ]]; then
  echo "moocp ist nicht zu finden: $MOOCP (erster Parameter)" >&2
  exit 2
fi
# Ohne jq: Die Zahl hinter "entwicklungsPort" in plugin.json.
PORT="$(sed -n 's/.*"entwicklungsPort"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$ORDNER/plugin.json" | head -n 1)"
if [[ -z "$PORT" ]]; then
  echo 'plugin.json nennt keinen entwicklungsPort.' >&2
  exit 2
fi

# 32 Bytes aus dem sicheren Zufall, Base64url ohne Auffüllung -- wie moocp es
# für ein gestartetes Plugin tut.
MOOCP_PLUGIN_SCHLUESSEL="$(head -c 32 /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_')"
export MOOCP_PLUGIN_SCHLUESSEL

# Im Projektordner: dart run findet dort pubspec.yaml und holt beim ersten
# Mal die Pakete.
cd "$ORDNER"
PLUGIN=""
trap '[[ -n "$PLUGIN" ]] && kill "$PLUGIN" 2>/dev/null; exit 130' INT TERM
trap '[[ -n "$PLUGIN" ]] && kill "$PLUGIN" 2>/dev/null || true' EXIT
MOOCP_GESTARTET=""
while true; do
  dart run bin/beispiel.dart --port "$PORT" --entwicklung &
  PLUGIN=$!
  if [[ -z "$MOOCP_GESTARTET" ]]; then
    echo "Beispiel-Plugin läuft auf 127.0.0.1:$PORT. moocp startet und fragt, ob es das Plugin anhängen soll."
    "$MOOCP" --plugin-entwicklung "$ORDNER" >/dev/null 2>&1 &
    MOOCP_GESTARTET=1
  else
    echo "Beispiel-Plugin läuft wieder auf 127.0.0.1:$PORT, mit demselben Schlüssel; moocp verbindet sich von selbst."
  fi
  wait "$PLUGIN" || true
  PLUGIN=""
  # Nur Enter startet neu; Strg+C hier beendet das Skript.
  read -r -p 'Das Plugin ist beendet. Enter startet es mit demselben Schlüssel neu, Strg+C beendet: ' || exit 0
done
