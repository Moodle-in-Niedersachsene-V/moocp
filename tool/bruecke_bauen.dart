// Baut die Brücke `moocp-bruecke` (bin/moocp_bruecke.dart) als einzelne,
// eigenständige Programmdatei per `dart compile exe` (E21).
//
// Warum nicht direkt `dart compile exe` im Projektordner und nicht `dart build cli`:
// - `dart compile exe` lehnt ein Projekt ab, sobald irgendeine Abhängigkeit in
//   `.dart_tool/package_config.json` einen Build-Hook (`hook/build.dart`) hat
//   (über Flutter-Plugins wie `cnativeapi` oder `objective_c`). Die Brücke
//   importiert davon nichts.
// - `dart build cli` (ab Dart 3.14) trennt den AOT-Snapshot in eine eigene
//   Bibliothek `../lib/libdartaot<Name>.{so,dylib,dll}` ab; eine allein
//   kopierte Programmdatei startet dann nur als nackte `dartaotruntime`.
//
// Dieses Skript schreibt eine gefilterte `package_config.json` ohne Pakete mit
// Build-Hook in einen temporären Ordner, kopiert `bin/moocp_bruecke.dart`
// daneben und übersetzt sie dort mit `dart compile exe` in genau die gewünschte
// Zieldatei. Aufruf:
//   dart tool/bruecke_bauen.dart <ziel>

import 'dart:convert';
import 'dart:io';

/// Filtert alle Pakete mit `hook/build.dart` aus einer `package_config.json`
/// heraus und löst relative `rootUri`-Pfade auf absolute `file://`-URIs auf,
/// damit die Konfiguration aus einem beliebigen temporären Ordner heraus gilt.
Map<String, Object?> paketKonfigurationOhneHooks(
  Map<String, Object?> konfiguration,
  Directory dartToolOrdner,
) {
  final basisUri = Uri.directory(dartToolOrdner.absolute.path);
  final pakete = konfiguration['packages'];
  if (pakete is! List) {
    throw const FormatException('package_config.json enthält keine Liste „packages“.');
  }
  final behalten = <Map<String, Object?>>[];
  for (final eintrag in pakete) {
    if (eintrag is! Map) continue;
    final kopie = Map<String, Object?>.from(eintrag);
    final rootUriText = kopie['rootUri'];
    if (rootUriText is! String) continue;
    final rootUri = _ordnerUri(basisUri.resolve(rootUriText));
    final hookDatei = File.fromUri(rootUri.resolve('hook/build.dart'));
    if (hookDatei.existsSync()) continue;
    kopie['rootUri'] = _ohneEndSchraegstrich(rootUri.toString());
    behalten.add(kopie);
  }
  return <String, Object?>{
    ...konfiguration,
    'packages': behalten,
  };
}

Uri _ordnerUri(Uri uri) => uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');

String _ohneEndSchraegstrich(String uri) =>
    uri.endsWith('/') && uri.length > 'file:///'.length ? uri.substring(0, uri.length - 1) : uri;

int main(List<String> argumente) {
  if (argumente.length != 1 || argumente.first.trim().isEmpty) {
    stderr.writeln('Aufruf: dart tool/bruecke_bauen.dart <ziel>');
    exitCode = 2;
    return 2;
  }

  final projekt = Directory.current.absolute;
  final dartTool = Directory.fromUri(Uri.directory(projekt.path).resolve('.dart_tool/'));
  final paketDatei = File.fromUri(Uri.directory(dartTool.path).resolve('package_config.json'));
  final quelle = File.fromUri(Uri.directory(projekt.path).resolve('bin/moocp_bruecke.dart'));
  final ziel = File(argumente.first).absolute;

  if (!paketDatei.existsSync()) {
    stderr.writeln('Fehlt: ${paketDatei.path} (erst `flutter pub get` ausführen).');
    exitCode = 1;
    return 1;
  }
  if (!quelle.existsSync()) {
    stderr.writeln('Fehlt: ${quelle.path}');
    exitCode = 1;
    return 1;
  }

  final decoded = jsonDecode(paketDatei.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    stderr.writeln('Ungültige package_config.json: ${paketDatei.path}');
    exitCode = 1;
    return 1;
  }
  final gefiltert = paketKonfigurationOhneHooks(decoded, dartTool);

  ziel.parent.createSync(recursive: true);
  final tmp = Directory.systemTemp.createTempSync('moocp-bruecke-');
  try {
    final tmpDartTool = Directory.fromUri(Uri.directory(tmp.path).resolve('.dart_tool/'))
      ..createSync(recursive: true);
    File.fromUri(Uri.directory(tmpDartTool.path).resolve('package_config.json'))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(gefiltert));
    quelle.copySync(File.fromUri(Uri.directory(tmp.path).resolve('moocp_bruecke.dart')).path);

    final lauf = Process.runSync(
      Platform.resolvedExecutable,
      ['compile', 'exe', 'moocp_bruecke.dart', '-o', ziel.path, '--verbosity=error'],
      workingDirectory: tmp.path,
    );
    if (lauf.stdout is String && (lauf.stdout as String).isNotEmpty) {
      stdout.write(lauf.stdout);
    }
    if (lauf.stderr is String && (lauf.stderr as String).isNotEmpty) {
      stderr.write(lauf.stderr);
    }
    if (lauf.exitCode != 0) {
      exitCode = lauf.exitCode;
      return lauf.exitCode;
    }
    if (!ziel.existsSync()) {
      stderr.writeln('dart compile exe meldete Erfolg, aber ${ziel.path} fehlt.');
      exitCode = 1;
      return 1;
    }
    return 0;
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Temp-Reste beim Aufräumen ignorieren.
    }
  }
}
