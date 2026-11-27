# Baut die Brücke für KI-Werkzeuge (bin/moocp_bruecke.dart, lib/mcp/bruecke.dart)
# und legt sie als moocp-bruecke neben moocp. Läuft im Installationsschritt
# jedes Baus, also bei `flutter build linux` wie bei `flutter run`; die
# Variablen BRUECKE_* setzt CMakeLists.txt. Dasselbe tut windows/bruecke.cmake
# für moocp-bruecke.exe.
#
# Übersetzt über tool/bruecke_bauen.dart mit `dart compile exe` (eine einzige
# eigenständige Datei ohne separate libdartaot*.so, E21; Build-Hook-Pakete aus
# Flutter-Plugins werden dafür vorab aus der package_config gefiltert).
#
# Ein laufender Prozess hält seine Datei offen: Überschreiben scheitert mit
# „Text file busy", Löschen nicht. Also die alte entfernen und die neue an ihren
# Platz legen; ein KI-Werkzeug, das die Brücke schon gestartet hat, arbeitet mit
# seiner Fassung weiter.

set(zwischen "${BRUECKE_PROJEKT}/build/bruecke/moocp-bruecke")
execute_process(
  COMMAND "${BRUECKE_DART}" tool/bruecke_bauen.dart "${zwischen}"
  WORKING_DIRECTORY "${BRUECKE_PROJEKT}"
  RESULT_VARIABLE fehler)
if(fehler)
  message(FATAL_ERROR "moocp-bruecke nicht gebaut: tool/bruecke_bauen.dart endete mit ${fehler}")
endif()

set(ziel "${BRUECKE_ORDNER}/moocp-bruecke")
file(REMOVE "${ziel}")
file(COPY_FILE "${zwischen}" "${ziel}")
file(CHMOD "${ziel}" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
message(STATUS "Installing: ${ziel}")
