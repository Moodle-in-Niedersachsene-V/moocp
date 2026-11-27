#!/usr/bin/env bash
# Prüft tool/mac_dmg.sh ohne Mac: Bau, lipo und dmgbuild sind ersetzt.
#   bash tool/mac_dmg_test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/moocp-mac-dmg-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
FIXTURE="$TEST_ROOT/repo"
MOCKS="$TEST_ROOT/bin"
mkdir -p "$FIXTURE/tool" "$FIXTURE/installer/macos" "$MOCKS"
cp "$SCRIPT_DIR/mac_dmg.sh" "$FIXTURE/tool/"
printf 'name: moocp\nversion: 1.2.3+4\n' > "$FIXTURE/pubspec.yaml"
: > "$FIXTURE/installer/macos/dmg_einstellungen.py"

# Bau: legt die App an und merkt sich Modus und Testzugangs-Variablen.
cat > "$FIXTURE/tool/mac_bau.sh" <<'MOCK'
#!/usr/bin/env bash
printf '%s|%s\n' "$*" "${MOOCP_TESTZUGANG:-}" >> "$MOOCP_BAU_ARGS"
mkdir -p build/macos/Build/Products/Release/moocp.app/Contents/MacOS
printf '#!/bin/sh\n' > build/macos/Build/Products/Release/moocp.app/Contents/MacOS/moocp-bruecke
chmod +x build/macos/Build/Products/Release/moocp.app/Contents/MacOS/moocp-bruecke
MOCK
cat > "$MOCKS/lipo" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$MOCK_ARCHS"
MOCK
# python3 -m venv <ordner>: legt pip und dmgbuild als Attrappen an.
cat > "$MOCKS/python3" <<'MOCK'
#!/usr/bin/env bash
ziel="${@: -1}"
mkdir -p "$ziel/bin"
printf '#!/usr/bin/env bash\ncat > "%s"\n' "$MOOCP_PIP_INPUT" > "$ziel/bin/pip"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s"\n: > "${@: -1}"\n' "$MOOCP_DMG_ARGS" > "$ziel/bin/dmgbuild"
chmod +x "$ziel/bin/pip" "$ziel/bin/dmgbuild"
MOCK
chmod +x "$MOCKS/lipo" "$MOCKS/python3"

export PATH="$MOCKS:$PATH"
export MOOCP_BAU_ARGS="$TEST_ROOT/bau-args"
export MOOCP_DMG_ARGS="$TEST_ROOT/dmg-args"
export MOOCP_PIP_INPUT="$TEST_ROOT/pip-input"
DMG="$FIXTURE/installer/moocp_1.2.3_macos.dmg"

# Universeller Bau: DMG mit der Version aus pubspec.yaml, Release ohne Testzugang.
export MOCK_ARCHS='x86_64 arm64'
MOOCP_TESTZUGANG=geheim bash "$FIXTURE/tool/mac_dmg.sh" > "$TEST_ROOT/ok.log"
[[ -f "$DMG" ]] || { echo 'DMG fehlt' >&2; exit 1; }
grep -q '^DMG-OK installer/moocp_1.2.3_macos.dmg$' "$TEST_ROOT/ok.log"
[[ "$(cat "$MOOCP_BAU_ARGS")" == 'release|' ]] || { echo "Bau falsch: $(cat "$MOOCP_BAU_ARGS")" >&2; exit 1; }
grep -q -- '-D app=build/macos/Build/Products/Release/moocp.app' "$MOOCP_DMG_ARGS"
grep -q -- ' moocp installer/moocp_1.2.3_macos.dmg$' "$MOOCP_DMG_ARGS"
# Pakete nur mit fester Version und Prüfsumme.
[[ "$(grep -c -- '--hash=sha256:' "$MOOCP_PIP_INPUT")" == 3 ]] || { echo 'Prüfsummen fehlen' >&2; exit 1; }

# Nur eine Architektur: Abbruch, und die DMG des vorigen Laufs ist weg.
export MOCK_ARCHS='arm64'
if bash "$FIXTURE/tool/mac_dmg.sh" > "$TEST_ROOT/arm.log" 2>&1; then
  echo 'Bau nur für arm64 wurde angenommen' >&2; exit 1
fi
grep -q 'x86_64 nicht' "$TEST_ROOT/arm.log"
[[ ! -e "$DMG" ]] || { echo 'Alte DMG nach Abbruch noch da' >&2; exit 1; }
export MOCK_ARCHS='x86_64'
if bash "$FIXTURE/tool/mac_dmg.sh" > "$TEST_ROOT/intel.log" 2>&1; then
  echo 'Bau nur für x86_64 wurde angenommen' >&2; exit 1
fi
grep -q 'arm64 nicht' "$TEST_ROOT/intel.log"
[[ ! -e "$DMG" ]] || { echo 'DMG trotz Abbruch angelegt' >&2; exit 1; }

echo 'mac_dmg_test: OK'
