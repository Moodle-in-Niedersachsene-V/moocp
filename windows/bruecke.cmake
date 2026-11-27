# Baut die Brücke für KI-Werkzeuge, die MCP nur über stdio sprechen
# (bin/moocp_bruecke.dart, lib/mcp/bruecke.dart), und legt sie als
# moocp-bruecke.exe neben moocp.exe. Läuft im Installationsschritt jedes
# Baus, also bei `flutter build windows` wie bei `flutter run`; die Variablen
# BRUECKE_* setzt CMakeLists.txt.
#
# Übersetzt über tool/bruecke_bauen.dart mit `dart compile exe` (eine einzige
# eigenständige Datei ohne separate libdartaot*.dll, E21; Build-Hook-Pakete aus
# Flutter-Plugins werden dafür vorab aus der package_config gefiltert).
#
# Ein KI-Werkzeug, das die Brücke gestartet hat, hält sie offen, solange es
# läuft. Überschreiben und Löschen gehen dann nicht, Umbenennen schon, und
# der laufende Prozess arbeitet mit der umbenannten Datei weiter. Also die
# alte beiseite, die neue an ihren Platz, und Beiseitegelegtes löschen,
# sobald es frei ist. Genauso macht es der Installer (installer/moocp.nsi).

set(zwischen "${BRUECKE_PROJEKT}/build/bruecke/moocp-bruecke.exe")
execute_process(
  COMMAND "${BRUECKE_DART}" tool/bruecke_bauen.dart "${zwischen}"
  WORKING_DIRECTORY "${BRUECKE_PROJEKT}"
  RESULT_VARIABLE fehler)
if(fehler)
  message(FATAL_ERROR "moocp-bruecke.exe nicht gebaut: tool/bruecke_bauen.dart endete mit ${fehler}")
endif()

set(ziel "${BRUECKE_ORDNER}/moocp-bruecke.exe")
if(EXISTS "${ziel}")
  string(TIMESTAMP jetzt "%Y%m%d%H%M%S")
  file(RENAME "${ziel}" "${BRUECKE_ORDNER}/moocp-bruecke.${jetzt}.alt" RESULT fehler)
  if(fehler)
    message(FATAL_ERROR "moocp-bruecke.exe nicht ersetzt: ${fehler}")
  endif()
endif()
file(COPY_FILE "${zwischen}" "${ziel}")
message(STATUS "Installing: ${ziel}")

file(GLOB reste "${BRUECKE_ORDNER}/moocp-bruecke.*.alt")
foreach(rest IN LISTS reste)
  # Noch in Gebrauch: Dann beim nächsten Bau.
  execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -f "${rest}" RESULT_VARIABLE egal ERROR_QUIET)
endforeach()
