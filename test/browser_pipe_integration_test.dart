// Prüft die Pipe gegen einen echten Browser (Chrome, Chromium oder Edge). Nur
// auf Anforderung: MOOCP_BROWSER_PIPE=/pfad/zum/browser flutter test …
// Lädt nie eine Seite von Moodle, nur about:blank und Skript in der Seite.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/moodle/bildschirmfoto.dart';
import 'package:moocp/moodle/cdp_pipe.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/protokoll.dart';
import 'package:moocp/plattform/browser_start.dart';
import 'package:moocp/plattform/browser_unix.dart';
import 'package:path/path.dart' as p;

void main() {
  final browser = Platform.environment['MOOCP_BROWSER_PIPE'];
  test('echter Browser spricht CDP über die Pipe, ohne Port', () async {
    final ordner = Directory.systemTemp.createTempSync('moocp_echt_');
    final st = UnixBrowserStarter();
    final profil = await st.profilAnlegen(ordner.path);
    final proz = await st.starten(browser!, [
      ...browserArgumente(profil: profil, breite: 800),
      '--no-sandbox', // Der Test läuft eventuell als Container-Benutzer.
    ], profil);
    try {
      final pipe = CdpPipe(proz.eingang, proz.senden);
      final v = await pipe.senden('Browser.getVersion').timeout(const Duration(seconds: 30));
      expect('${v['product']}', isNotEmpty);
      Map<String, dynamic> r;
      do {
        r = await pipe.senden('Target.getTargets');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } while (((r['targetInfos'] as List).where((t) => (t as Map)['type'] == 'page')).isEmpty);
      final seite = (r['targetInfos'] as List).cast<Map>().firstWhere((t) => t['type'] == 'page');
      final a = await pipe.senden('Target.attachToTarget', {'targetId': seite['targetId'], 'flatten': true});
      final s = pipe.sitzung('${a['sessionId']}');
      final e = await s.senden('Runtime.evaluate', {'expression': '6*7', 'returnByValue': true});
      expect((e['result'] as Map)['value'], 42);
      // Kein DevTools-Port: weder Datei noch hörender Socket des Browsers.
      expect(File(p.join(profil.path, 'DevToolsActivePort')).existsSync(), isFalse);
      // Kommandozeile des Browsers: unter Linux aus /proc (NUL-getrennt), auf
      // dem Mac gibt es kein /proc, dort liefert `ps` sie. Unter Windows
      // läuft dieser Test nicht (UnixBrowserStarter).
      final cmd = Platform.isMacOS
          ? '${Process.runSync('ps', ['-o', 'command=', '-p', '${proz.pid}']).stdout}'
          : File('/proc/${proz.pid}/cmdline').readAsStringSync();
      expect(cmd, contains('--remote-debugging-pipe'));
      expect(cmd, isNot(contains('remote-debugging-port')));
      await pipe.senden('Browser.close').timeout(const Duration(seconds: 10)).catchError((_) => <String, dynamic>{});
    } finally {
      await proz.beenden();
      await Process.run('chmod', ['-R', 'u+rwx', ordner.path]);
      for (var i = 0; i < 20 && ordner.existsSync(); i++) {
        try {
          ordner.deleteSync(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    }
  }, skip: browser == null
      ? 'MOOCP_BROWSER_PIPE nicht gesetzt'
      : (Platform.isWindows ? 'POSIX: UnixBrowserStarter (unter Windows prüft der zweite Test den WindowsBrowserStarter)' : false),
      timeout: const Timeout(Duration(minutes: 2)));
  test('ganze Aufnahme mit echtem Browser: Seite kommt über die App, Fremdes bleibt draußen', () async {
    final ordner = Directory.systemTemp.createTempSync('moocp_echt2_');
    addTearDown(() => ordner.deleteSync(recursive: true));
    final geholt = <String>[];
    final a = await aufnehmen(
      basis: Uri.parse('https://moodle.schule.example/'),
      holen: (methode, uri, {required seiten, rumpf, dokument = false}) async {
        geholt.add('$methode $uri');
        const html = '<html><body><div id="region-main"><div class="generalbox center">'
            '<p>Muster GmbH</p><img src="https://fremd.example/x.png"></div></div></body></html>';
        return Antwort(200, uri, Uint8List.fromList(utf8.encode(html)), 'text/html');
      },
      protokoll: Protokoll(),
      adresse: Uri.parse('https://moodle.schule.example/mod/page/view.php?id=7'),
      inhalt: ('#region-main .generalbox.center', null),
      arbeitsordner: ordner.path,
      browserWahl: ('Chrome', browser!),
    );
    expect(a.bilder, hasLength(1));
    expect(a.bilder.single.sublist(1, 4), 'PNG'.codeUnits);
    expect(geholt, ['GET https://moodle.schule.example/mod/page/view.php?id=7']);
    expect(a.gesperrt.single, contains('fremd.example'));
    expect(ordner.listSync(), isEmpty, reason: 'Profil gelöscht');
  }, skip: browser == null ? 'MOOCP_BROWSER_PIPE nicht gesetzt' : false, timeout: const Timeout(Duration(minutes: 2)));
}
