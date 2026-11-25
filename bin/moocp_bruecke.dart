// moocp-bruecke, die Brücke für KI-Werkzeuge, die MCP nur über stdio
// sprechen (lib/mcp/bruecke.dart). Bei jedem Bau der App mit `dart compile
// exe` übersetzt und neben moocp gelegt (windows/bruecke.cmake,
// tool/linux_bau.sh, tool/mac_bau.sh). Aufruf: `moocp-bruecke --profil <name>`.
import 'dart:io';

import 'package:moocp/mcp/bruecke.dart';

Future<void> main(List<String> argumente) async => exit(await brueckeStarten(argumente));
