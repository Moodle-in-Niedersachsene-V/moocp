// Gemeinsames für die Tests, die das Beispiel-Plugin (example/example-plugin/)
// als echten Prozess starten oder anhängen: test/plugin_start_test.dart und
// test/plugin_entwicklung_test.dart. Alles mit erfundenen Angaben.
import 'dart:io';

import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

/// Die Werkzeuge des Beispiel-Plugins in der Reihenfolge seiner Liste.
const beispielWerkzeuge = [
  'beispiel_echo',
  'beispiel_absturz',
  'beispiel_protokoll',
  'beispiel_datei',
  'beispiel_status',
  'beispiel_auswahl',
  'beispiel_eingabe',
  'beispiel_pfad',
  'beispiel_hinweis',
  'beispiel_freigabe',
  'beispiel_moodle_lesen',
  'beispiel_moodle_gesperrt',
  'beispiel_moodle_datei',
  'beispiel_moodle_schreiben',
  'beispiel_lauf',
  'beispiel_download',
  'beispiel_namen',
  'beispiel_pfade',
];

/// Der Projektordner des Beispiel-Plugins, relativ zur Wurzel des
/// Repositorys (dort laufen die Tests).
final beispielOrdner = p.join('example', 'example-plugin');

/// Übersetzt das Beispiel-Plugin nach [exe], wie ein Plugin-Autor es tut
/// (`dart compile exe`), mit dem `dart` des Flutter-SDK und ohne Netz.
///
/// Das Beispiel ist ein eigenes Dart-Projekt mit eigener pubspec.yaml. Ohne
/// aufgelöste Pakete holte `dart compile exe` sie selbst, und zwar aus dem
/// Netz. Deshalb löst der Test sie vorher mit `dart pub get --offline` aus
/// dem Pub-Cache auf, den `flutter pub get` für die App schon gefüllt hat
/// (mcp_dart ist auch ein Paket der App). Das geschieht in einer Kopie in
/// einem Temp-Ordner, ohne die pubspec.lock des Beispiels: Im Arbeitsbaum
/// entsteht nichts, zwei Testdateien kommen sich nicht in die Quere, und es
/// genügen die Versionen, die die App gerade benutzt.
Future<void> beispielUebersetzen(String exe) async {
  final projekt = Directory.systemTemp.createTempSync('moocp_beispiel_projekt_');
  try {
    File(p.join(beispielOrdner, 'pubspec.yaml')).copySync(p.join(projekt.path, 'pubspec.yaml'));
    for (final unter in ['bin', 'lib']) {
      final quelle = Directory(p.join(beispielOrdner, unter));
      if (!quelle.existsSync()) continue;
      for (final f in quelle.listSync(recursive: true).whereType<File>()) {
        final ziel = File(p.join(projekt.path, p.relative(f.path, from: beispielOrdner)));
        ziel.parent.createSync(recursive: true);
        f.copySync(ziel.path);
      }
    }
    final holen = await Process.run(dartDesSdk(), ['pub', 'get', '--offline'], workingDirectory: projekt.path);
    if (holen.exitCode != 0) {
      throw StateError('dart pub get --offline ist gescheitert: ${holen.stdout}${holen.stderr}');
    }
    final r = await Process.run(dartDesSdk(), [
      'compile',
      'exe',
      p.join('bin', 'beispiel.dart'),
      '-o',
      p.absolute(exe),
    ], workingDirectory: projekt.path);
    if (r.exitCode != 0) {
      throw StateError('dart compile exe ist gescheitert: ${r.stdout}${r.stderr}');
    }
  } finally {
    projekt.deleteSync(recursive: true);
  }
}

/// Löscht einen Temp-Ordner der Tests, auch wenn Windows ihn einen Augenblick
/// länger festhält. Unter Windows verweigert das Löschen mit "Zugriff
/// verweigert" (errno 5), solange das Programm eines eben beendeten Plugins
/// noch in der Prozessverwaltung steht oder ein Virenscanner die Datei prüft;
/// ein Wiederholen löst das, ein Fehler in der App ist es nicht. Nach
/// höchstens etwa zehn Sekunden gilt der Fehler. Auf anderen Systemen ist es
/// ein einfaches Löschen.
Future<void> ordnerLoeschen(Directory ordner) async {
  for (var versuch = 0;; versuch++) {
    try {
      if (ordner.existsSync()) ordner.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      if (!Platform.isWindows || versuch >= 50) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}

/// Einstellungen, die nie in eine Datei geschrieben werden; sie zählen, wie
/// oft die App sie geschrieben hätte.
class EinstellungenOhneDatei extends Einstellungen {
  EinstellungenOhneDatei({super.profile}) : super();

  /// Wie oft die App ihre Einstellungen geschrieben hätte.
  int gespeichert = 0;

  @override
  Future<void> speichern() async => gespeichert++;
}

/// Das `dart` des Flutter-SDK, mit dem die Tests laufen: `flutter test`
/// führt die Tests im flutter_tester aus, nicht in dart; das SDK liegt
/// darüber in `bin/cache/dart-sdk`.
String dartDesSdk() {
  final exe = Platform.isWindows ? 'dart.exe' : 'dart';
  final wurzel = Platform.environment['FLUTTER_ROOT'];
  if (wurzel != null) {
    final f = File(p.join(wurzel, 'bin', 'cache', 'dart-sdk', 'bin', exe));
    if (f.existsSync()) return f.path;
  }
  var d = File(Platform.resolvedExecutable).parent;
  while (d.parent.path != d.path) {
    final f = File(p.join(d.path, 'dart-sdk', 'bin', exe));
    if (f.existsSync()) return f.path;
    d = d.parent;
  }
  throw StateError('Das dart des Flutter-SDK ist nicht zu finden.');
}

/// Ein Instanzprofil mit erfundener Adresse.
Profil beispielProfil(String kennung, String mcpName, int port) => Profil(
  kennung: kennung,
  name: mcpName,
  adresse: 'https://$kennung.moodle.schule.example',
  port: port,
  mcpName: mcpName,
);

/// Ein Port, der gerade frei ist.
Future<int> freierPort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// Die Namen der eingebauten Werkzeuge, wie die App sie beim Start ermittelt.
Future<Set<String>> eingebauteWerkzeuge() {
  final protokoll = Protokoll();
  return McpDienst(
    Einstellungen(),
    MoodleZugang(protokoll),
    protokoll,
    Freigaben(protokoll),
    '',
    profil: Profil.migriert(''),
  ).eingebauteWerkzeugnamen();
}

/// Ob ein Prozess mit dieser Nummer noch läuft.
Future<bool> prozessLaeuft(int pid) async {
  if (Platform.isWindows) {
    final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return '${r.stdout}'.contains(' $pid ');
  }
  return (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;
}
