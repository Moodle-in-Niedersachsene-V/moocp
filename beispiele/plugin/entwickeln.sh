#!/usr/bin/env bash
# Startet das Beispiel-Plugin zum Entwickeln und hängt es an moocp an
# (README, Teil 4, „Ein Plugin entwickeln“). Auf dem Mac; unter Windows tut
# entwickeln.ps1 dasselbe.
#
#   bash beispiele/plugin/entwickeln.sh [Pfad zum Programm von moocp]
#
# Auf dem Mac gibt es moocp nur aus dem Entwicklungsbau (tool/mac_bau.sh);
# Vorgabe ist deshalb das Programm in dessen Bau im Repository.
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
# bekommt. Strg+C beendet das Plugin; moocp läuft weiter und verbindet sich
# wieder, sobald es zurück ist.
set -euo pipefail

ORDNER="$(cd "$(dirname "$0")" && pwd)"
# Das Beispiel benutzt die Pakete von moocp; dart findet sie von der Wurzel
# des Repositorys aus.
WURZEL="$(cd "$ORDNER/../.." && pwd)"
MOOCP="${1:-$WURZEL/build/macos/Build/Products/Debug/moocp.app/Contents/MacOS/moocp}"

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

cd "$WURZEL"
dart run "$ORDNER/beispiel.dart" --port "$PORT" --entwicklung &
PLUGIN=$!
trap 'kill "$PLUGIN" 2>/dev/null || true' EXIT INT TERM
echo "Beispiel-Plugin läuft auf 127.0.0.1:$PORT. moocp startet und fragt, ob es das Plugin anhängen soll."
"$MOOCP" --plugin-entwicklung "$ORDNER" >/dev/null 2>&1 &
wait "$PLUGIN"
