#!/usr/bin/env bash
# Baut das Beispiel-Plugin zu einem fertigen Plugin-Ordner: übersetzt das
# Programm mit `dart compile exe` unter dem Namen, den `programm` in
# plugin.json nennt, und legt es mit plugin.json und skills/ in den
# Zielordner. Auf dem Mac; unter Windows tut bauen.ps1 dasselbe.
#
#   bash example/example-plugin/bauen.sh [Zielordner]
#
# Vorgabe für den Zielordner ist build/beispiel in diesem Projekt. Installiert
# ist das Plugin, wenn der Ordner als plugins/beispiel im Einstellungsordner
# von moocp liegt; dorthin schreibt das Skript nur, wenn er als Zielordner
# genannt ist, und es liest dort nichts. moocp vorher beenden: Ein geändertes
# Plugin braucht beim nächsten Start eine neue Zustimmung.
#
# Ein Zielordner, der nicht leer ist und keine plugin.json enthält, ist kein
# Plugin-Ordner; dann bricht das Skript ab, ohne etwas zu ändern. Sonst
# ersetzt es dort Programm, plugin.json und skills/ und lässt alles andere
# stehen.
#
# Das dart kommt aus dem Suchpfad oder aus der Umgebungsvariablen DART.
set -euo pipefail

ORDNER="$(cd "$(dirname "$0")" && pwd)"
ZIEL="${1:-$ORDNER/build/beispiel}"
DART="${DART:-dart}"

# Ohne jq: der Text hinter "programm" in plugin.json.
PROGRAMM="$(sed -n 's/.*"programm"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ORDNER/plugin.json" | head -n 1)"
if [[ -z "$PROGRAMM" ]]; then
  echo 'plugin.json nennt kein programm.' >&2
  exit 2
fi
if [[ -e "$ZIEL" && ! -d "$ZIEL" ]]; then
  echo "Der Zielordner ist eine Datei: $ZIEL" >&2
  exit 2
fi
if [[ -d "$ZIEL" && -n "$(ls -A "$ZIEL")" && ! -f "$ZIEL/plugin.json" ]]; then
  echo "Der Zielordner ist nicht leer und kein Plugin-Ordner: $ZIEL" >&2
  exit 2
fi
mkdir -p "$ZIEL"
ZIEL="$(cd "$ZIEL" && pwd)"

# Im Projektordner: dart findet dort pubspec.yaml und holt beim ersten Mal
# die Pakete. Erst übersetzen, dann ersetzen: Schlägt das Übersetzen fehl,
# bleibt der Zielordner, wie er war.
cd "$ORDNER"
"$DART" compile exe bin/beispiel.dart -o "$ZIEL/$PROGRAMM.neu"
rm -rf "$ZIEL/skills" "$ZIEL/plugin.json" "$ZIEL/$PROGRAMM"
mv "$ZIEL/$PROGRAMM.neu" "$ZIEL/$PROGRAMM"
cp plugin.json "$ZIEL/plugin.json"
cp -R skills "$ZIEL/skills"
echo "Das Beispiel-Plugin liegt fertig in $ZIEL"
