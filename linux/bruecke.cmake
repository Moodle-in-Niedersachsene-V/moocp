# Baut die Brücke für KI-Werkzeuge (bin/moocp_bruecke.dart, lib/mcp/bruecke.dart)
# und legt sie als moocp-bruecke neben moocp. Läuft im Installationsschritt
# jedes Baus, also bei `flutter build linux` wie bei `flutter run`; die
# Variablen BRUECKE_* setzt CMakeLists.txt. Dasselbe tut windows/bruecke.cmake
# für moocp-bruecke.exe.
#
# `dart build cli`, nicht `dart compile exe`: compile lehnt ein Projekt ab,
# sobald eine seiner Abhängigkeiten Build-Hooks hat (über die Flutter-Plugins).
# Die Brücke braucht davon nichts; das Bündel enthält nur die ausführbare Datei.
#
# Ein laufender Prozess hält seine Datei offen: Überschreiben scheitert mit
# „Text file busy", Löschen nicht. Also die alte entfernen und die neue an ihren
# Platz legen; ein KI-Werkzeug, das die Brücke schon gestartet hat, arbeitet mit
# seiner Fassung weiter.

set(zwischen "${BRUECKE_PROJEKT}/build/bruecke")
execute_process(
  COMMAND "${BRUECKE_DART}" build cli -t bin/moocp_bruecke.dart -o "${zwischen}" --verbosity=error
  WORKING_DIRECTORY "${BRUECKE_PROJEKT}"
  RESULT_VARIABLE fehler)
if(fehler)
  message(FATAL_ERROR "moocp-bruecke nicht gebaut: dart build cli endete mit ${fehler}")
endif()

set(ziel "${BRUECKE_ORDNER}/moocp-bruecke")
file(REMOVE "${ziel}")
file(COPY_FILE "${zwischen}/bundle/bin/moocp_bruecke" "${ziel}")
file(CHMOD "${ziel}" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
message(STATUS "Installing: ${ziel}")
