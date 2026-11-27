#!/usr/bin/env bash
# Ruft ein Werkzeug der laufenden App auf, ohne Claude-Sitzung -- zum
# Durchspielen im Testkurs. Der Aufruf geht wie bei einem KI-Werkzeug über die
# Brücke moocp-bruecke und den Kanal, den nur das eigene Konto erreicht (E6,
# E21); ein Schlüssel oder ein Port ist dafür nicht nötig.
#
#   bash tool/mcp_aufruf.sh <werkzeug> '<json-argumente>' [mcp-name]
#   bash tool/mcp_aufruf.sh kurs_uebersicht '{"kurs":43}'
#   bash tool/mcp_aufruf.sh kurs_uebersicht '{}' moodle-test
#
# Schreibende Werkzeuge warten auf die Freigabe in der App (bis 30 Minuten);
# deshalb ohne Zeitgrenze.
#
# Unter Windows in Git Bash aufrufen, unter macOS und Linux in der Shell. Nicht
# aus Python heraus: Das Python auf dem Entwicklungsrechner ist ein gepacktes
# Programm, dem Windows %APPDATA% umleitet -- es und jede Bash, die es startet,
# sehen die Einstellungen der App nicht.
#
# Die Brücke ist die neben dem letzten Bau (build/...) oder die installierte;
# MOOCP_BRUECKE nennt eine andere. Den MCP-Namen liest das Skript aus den
# Einstellungen der App (Profil: mcpName, Name oder Kennung); ohne Angabe gilt
# das erste Profil. Jeder Aufruf bekommt eigene Dateien; parallele Aufrufe
# überschreiben sich nicht.
WURZEL="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname)" in
  Darwin)
    D="$HOME/Library/Application Support/moocp"
    BRUECKEN=("$WURZEL/build/macos/Build/Products/Debug/moocp.app/Contents/MacOS/moocp-bruecke"
      "$WURZEL/build/macos/Build/Products/Release/moocp.app/Contents/MacOS/moocp-bruecke"
      "/Applications/moocp.app/Contents/MacOS/moocp-bruecke") ;;
  Linux)
    D="${XDG_CONFIG_HOME:-$HOME/.config}/moocp"
    BRUECKEN=("$WURZEL/build/linux/x64/debug/bundle/moocp-bruecke"
      "$WURZEL/build/linux/x64/release/bundle/moocp-bruecke"
      "$HOME/.local/opt/moocp/moocp-bruecke") ;;
  *)
    D="$(cygpath -u "$APPDATA")/moocp"
    BRUECKEN=("$WURZEL/build/windows/x64/runner/Debug/moocp-bruecke.exe"
      "$WURZEL/build/windows/x64/runner/Release/moocp-bruecke.exe"
      "$(cygpath -u "$LOCALAPPDATA")/Programs/moocp/moocp-bruecke.exe") ;;
esac
F="$D/einstellungen.json"
if command -v cygpath >/dev/null; then PY=python; else PY=python3; fi
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
NF="$TMPD/name.txt"
if ! "$PY" -c '
import json,re,sys
j=json.load(open(sys.argv[1],encoding="utf-8"))
p=j.get("profile") or []
wahl=sys.argv[3]
if wahl:
 p=[x for x in p if wahl in (x.get("mcpName"),x.get("name"),x.get("kennung"))]
 if len(p)!=1: raise ValueError()
name=p[0].get("mcpName") if p else "moodle"
if not isinstance(name,str) or not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*",name): raise ValueError()
open(sys.argv[2],"w",encoding="ascii").write(name)
' "$F" "$NF" "${3:-}" 2>/dev/null; then
  echo "Einstellungen fehlen oder das Profil ist ungültig -- läuft die App schon einmal gestartet?" >&2
  exit 2
fi
NAME=$(cat "$NF")
# Eingaben validieren, bevor irgendein Werkzeug aufgerufen wird.
ARG="$TMPD"/argumente.json
printf '%s' "${2:-{\}}" > "$ARG"
if ! "$PY" -c 'import json,sys; json.loads(open(sys.argv[1],"rb").read().decode("utf-8"))' "$ARG" 2>/dev/null; then
  echo "Argumente sind kein gültiges JSON." >&2
  exit 2
fi
BRUECKE="${MOOCP_BRUECKE:-}"
if [ -z "$BRUECKE" ]; then
  for b in "${BRUECKEN[@]}"; do [ -x "$b" ] && { BRUECKE="$b"; break; }; done
fi
if [ -z "$BRUECKE" ] || [ ! -x "$BRUECKE" ]; then
  echo "Transportfehler: Die Brücke moocp-bruecke fehlt -- erst bauen (tool/neustart.sh) oder MOOCP_BRUECKE setzen." >&2
  exit 3
fi
ANF="$TMPD"/anfrage.json
ANT="$TMPD"/antwort.txt
ENDE="$TMPD"/ende
: > "$ANT"
# Die Anfrage baut Python (json.dumps): Bash halbierte Backslashes in Pfaden.
# Die Argumente gehen als UTF-8-Datei hinüber, nicht über die Kommandozeile:
# Dort kommen sie über die Codepage an, und was nicht in Latin-1 liegt, ging
# verloren (… wurde zum Steuerzeichen U+0085, € verschwand).
"$PY" -c "import json,sys;print(json.dumps({'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':sys.argv[1],'arguments':json.loads(open(sys.argv[2],'rb').read().decode('utf-8'))}}))" "$1" "$ARG" > "$ANF"
# Die Brücke liest von stdin, bis es endet; das Skript hält es offen, bis die
# Antwort da ist (oder die Brücke endet) -- ein schreibendes Werkzeug wartet
# auf die Freigabe in der App.
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp_aufruf","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  cat "$ANF"
  while ! grep -Eq '"id": ?2[,}]' "$ANT" 2>/dev/null && [ ! -e "$ENDE" ]; do sleep 0.5; done
} | { "$BRUECKE" --profil "$NAME" > "$ANT" 2>/dev/null; : > "$ENDE"; }
ANT2="$TMPD"/antwort.json
grep -E '"id": ?2[,}]' "$ANT" | head -n 1 > "$ANT2"
if [ ! -s "$ANT2" ]; then
  echo "Transportfehler beim MCP-Werkzeugaufruf." >&2; exit 3
fi
$PY -c "
import sys, json
sys.stdout.reconfigure(encoding='utf-8')
try:
    d = json.loads(open(sys.argv[1], 'rb').read().decode('utf-8'))
    if not isinstance(d, dict): raise ValueError('response shape')
    if 'error' in d:
        print('JSON-RPC-Fehler:', d['error'])
        sys.exit(4)
    else:
        r = d['result']
        if not isinstance(r, dict): raise ValueError('result shape')
        is_error = r.get('isError', False) is True
        print('isError:', is_error)
        for c in r.get('content', []):
            print(c.get('text', ''))
        if is_error:
            sys.exit(4)
except (UnicodeDecodeError, json.JSONDecodeError):
    print('MCP-Antwort enthält ungültiges JSON.', file=sys.stderr)
    sys.exit(5)
except (KeyError, TypeError, ValueError):
    print('MCP-Antwort hat eine ungültige Struktur.', file=sys.stderr)
    sys.exit(5)
" "$ANT2"
