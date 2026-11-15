// Der eine Weg, auf dem moocp andere Programme startet: Browser für
// Bildschirmfotos, Kommandozeilen der KI-Werkzeuge, Installer von moocp und
// von Plugins, Dateimanager und Standardbrowser, Hilfsprogramme des Systems,
// Plugins -- und die Brücke, wenn sie moocp startet.
//
// Wozu: Die Umgebung der App kann den Schlüssel eines Entwicklungs-Plugins
// tragen ([schluesselVariable], plugin/entwicklung.dart). Ein Programm, das
// die App startet, erbte ihn sonst und könnte sich damit an der Adresse der
// App für Plugins als dieses Plugin anmelden. Deshalb bekommt jedes Kind eine
// Kopie der Umgebung ohne diese Variable; ein gestartetes Plugin bekommt
// seinen eigenen, frisch erzeugten Schlüssel über [dazu]
// (plugin/laufende_plugins.dart).
//
// Kein `Process.start` oder `Process.run` in lib/ geht hieran vorbei
// (test/kindprozess_test.dart hält den Quelltext darauf fest). Ohne Flutter:
// Die Brücke (mcp/bruecke.dart) bindet diese Datei ein.

import 'dart:convert';
import 'dart:io';

/// Die Umgebungsvariable, in der ein Plugin seinen Schlüssel bekommt und in
/// der ein Entwicklungs-Plugin ihn der App gibt. Nicht auf der Kommandozeile:
/// Die steht in jeder Prozessliste, die Umgebung eines Prozesses nicht
/// (plugin/laufende_plugins.dart, gemessen in test/plugin_start_test.dart).
const schluesselVariable = 'MOOCP_PLUGIN_SCHLUESSEL';

/// Die Umgebung eines Kindprozesses: [von] (Vorgabe: die der App) ohne
/// [schluesselVariable], dazu [dazu]. Unter Windows ([windows]) sind Namen
/// von Umgebungsvariablen ohne Rücksicht auf Groß- und Kleinschreibung
/// gleich; dann fällt die Variable in jeder Schreibweise weg.
Map<String, String> kindUmgebung({
  Map<String, String> dazu = const {},
  Map<String, String>? von,
  bool? windows,
}) {
  final gross = windows ?? Platform.isWindows;
  bool geheim(String name) =>
      gross ? name.toUpperCase() == schluesselVariable.toUpperCase() : name == schluesselVariable;
  return {
    for (final MapEntry(:key, :value) in (von ?? Platform.environment).entries)
      if (!geheim(key)) key: value,
    ...dazu,
  };
}

/// [Process.start] mit der Umgebung aus [kindUmgebung].
Future<Process> prozessStarten(
  String programm,
  List<String> argumente, {
  String? arbeitsordner,
  ProcessStartMode modus = ProcessStartMode.normal,
  Map<String, String> dazu = const {},
}) =>
    Process.start(
      programm,
      argumente,
      workingDirectory: arbeitsordner,
      mode: modus,
      environment: kindUmgebung(dazu: dazu),
      includeParentEnvironment: false,
    );

/// [Process.run] mit der Umgebung aus [kindUmgebung].
Future<ProcessResult> prozessAusfuehren(
  String programm,
  List<String> argumente, {
  Encoding? stdoutEncoding = systemEncoding,
  Map<String, String> dazu = const {},
}) =>
    Process.run(
      programm,
      argumente,
      environment: kindUmgebung(dazu: dazu),
      includeParentEnvironment: false,
      stdoutEncoding: stdoutEncoding,
    );

/// [Process.runSync] mit der Umgebung aus [kindUmgebung].
ProcessResult prozessAusfuehrenSync(String programm, List<String> argumente) =>
    Process.runSync(programm, argumente, environment: kindUmgebung(), includeParentEnvironment: false);
