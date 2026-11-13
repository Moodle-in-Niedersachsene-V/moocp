// Gemeinsames für die Tests, die das Beispiel-Plugin (beispiele/plugin/) als
// echten Prozess starten oder anhängen: test/plugin_start_test.dart und
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
];

/// Einstellungen, die nie in eine Datei geschrieben werden; sie zählen, wie
/// oft die App sie geschrieben hätte.
class EinstellungenOhneDatei extends Einstellungen {
  EinstellungenOhneDatei({super.profile}) : super(schluessel: 'test');

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
  schluessel: 'test',
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
    Einstellungen(schluessel: ''),
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
