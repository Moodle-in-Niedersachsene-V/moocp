// Lesen und Ändern einer Aktivität mit mehreren eingebetteten PNG-Bildern,
// über den öffentlichen MCP-Aufruf. Ausschließlich Moodle ist ein lokaler
// HTTP-Server, der je Bild ein Verhalten bekommt: antwortet, antwortet nie,
// bricht die Verbindung mitten in der Antwort ab, kennt das Bild nicht.
//
// Die Tests halten fest, was bei einem hängenden oder abgebrochenen Bild
// geschieht (Zeitüberschreitung, ECONNRESET) und dass die Größe der Bilder
// (26 bis 196 KB) für sich nichts ändert.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'mcp_client.dart';

enum _Bild { antwortet, traege, haengt, bricht, unbekannt }

class _Moodle {
  late HttpServer server;
  final anfragen = <String>[];
  final angemeldet = <String>{};
  int sitzungen = 0;

  /// Größen der sechs Bilder in Byte (26 bis 196 KB).
  static const groessen = [26 * 1024, 61 * 1024, 98 * 1024, 133 * 1024, 170 * 1024, 196 * 1024];

  /// Verhalten je Bild; ohne Eintrag antwortet es.
  final verhalten = <int, _Bild>{};

  /// Ab diesem Bild (einschließlich) gilt [_Bild.haengt] für alle weiteren.
  int? ab;

  /// Verbindungen, die die App von sich aus geschlossen hat, solange ein Bild hing.
  int abgebrochenVonApp = 0;
  int haengend = 0;
  bool postAbbrechen = false;
  String text = '';
  final _nie = Completer<void>();

  Uri get basis => Uri.parse('http://127.0.0.1:${server.port}');

  List<String> get bildanfragen => [
    for (final a in anfragen)
      if (a.startsWith('GET /draftfile.php/')) a,
  ];

  Future<void> starten() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    text =
        '<p>ZZ Seite</p>${[for (var i = 0; i < groessen.length; i++) '<img class="img-fluid" alt="Bild $i" src="http://127.0.0.1:${server.port}/draftfile.php/5/user/draft/777/bild$i.png">'].join()}';
    server.listen(_antworte);
  }

  _Bild _verhalten(int i) => ab != null && i >= ab! ? _Bild.haengt : verhalten[i] ?? _Bild.antwortet;

  Future<void> _antworte(HttpRequest r) async {
    final body = await utf8.decoder.bind(r).join();
    anfragen.add('${r.method} ${r.uri.path}');
    final id = r.cookies.where((c) => c.name == 'MoodleSession').map((c) => c.value).firstOrNull;
    final ein = id != null && angemeldet.contains(id);
    Future<void> seite(String s) async {
      r.response
        ..headers.contentType = ContentType.html
        ..write(s);
      await r.response.close();
    }

    Future<void> umleiten(String ziel) async {
      r.response.redirect(Uri.parse(ziel), status: HttpStatus.seeOther);
      await r.response.close();
    }

    if (r.uri.path == '/login/index.php') {
      if (r.method == 'POST') {
        angemeldet.add(id!);
        return umleiten('/login/index.php?testsession=1');
      }
      if (r.uri.queryParameters.containsKey('testsession')) return umleiten(ein ? '/my/' : '/login/index.php');
      r.response.cookies.add(Cookie('MoodleSession', 's${sitzungen++}'));
      return seite('<form><input name="logintoken" value="tok"></form>');
    }
    if (!ein) return umleiten('/login/index.php');
    if (r.uri.path.startsWith('/draftfile.php/')) {
      final i = int.parse(RegExp(r'bild(\d+)\.png').firstMatch(r.uri.path)!.group(1)!);
      final bytes = Uint8List(groessen[i])..setRange(0, 4, const [0x89, 0x50, 0x4E, 0x47]);
      switch (_verhalten(i)) {
        case _Bild.traege:
          await Future<void>.delayed(const Duration(milliseconds: 400));
          r.response.headers.contentType = ContentType('image', 'png');
          r.response.add(bytes);
          return r.response.close();
        case _Bild.antwortet:
          r.response.headers.contentType = ContentType('image', 'png');
          r.response.add(bytes);
          return r.response.close();
        case _Bild.unbekannt:
          r.response.statusCode = HttpStatus.notFound;
          return r.response.close();
        case _Bild.bricht:
          r.response
            ..headers.contentType = ContentType('image', 'png')
            ..contentLength = bytes.length;
          final s = await r.response.detachSocket();
          s.add(bytes.sublist(0, bytes.length ~/ 2));
          await s.flush();
          s.destroy();
          return;
        case _Bild.haengt:
          haengend++;
          // HttpResponse.done meldet das Schließen durch den Client erst, wenn
          // die Antwort begonnen hat; am abgelösten Socket sieht man es sofort.
          final s = await r.response.detachSocket(writeHeaders: false);
          s.listen((_) {}, onDone: () => abgebrochenVonApp++, onError: (_) => abgebrochenVonApp++);
          await _nie.future;
          s.destroy();
          return;
      }
    }
    if (r.uri.path == '/lib/ajax/service.php') {
      return seite(
        jsonEncode([
          {
            'error': false,
            'data': {
              'section': [
                {'id': 1, 'number': 1, 'title': 'ZZ Abschnitt', 'visible': 1, 'cmlist': [101]},
              ],
              'cm': [
                {'id': 101, 'module': 'page', 'name': 'ZZ Seite', 'visible': 0, 'sectionid': 1},
              ],
            },
          },
        ]),
      );
    }
    if (r.uri.path == '/course/modedit.php' && r.method == 'POST') {
      final f = Uri.splitQueryString(body);
      text = f['page[text]']!;
      if (postAbbrechen) {
        final s = await r.response.detachSocket(writeHeaders: false);
        s.destroy();
        return;
      }
      return umleiten('/course/view.php?id=12');
    }
    if (r.uri.path == '/course/modedit.php') {
      return seite(
        '<script>M.cfg = {"sesskey":"sk","courseId":12,"contextid":"55"};</script>'
        '<form class="mform" method="post" action="/course/modedit.php">'
        '<input type="hidden" name="sesskey" value="sk"><input type="hidden" name="modulename" value="page">'
        '<input type="hidden" name="_qf__mod_page_mod_form" value="1"><input type="hidden" name="course" value="12">'
        '<input type="hidden" name="update" value="101"><input type="text" name="name" value="ZZ Seite">'
        '<textarea name="page[text]">${const HtmlEscape().convert(text)}</textarea>'
        '<input type="hidden" name="page[itemid]" value="777"></form>',
      );
    }
    return seite('<script>M.cfg = {"sesskey":"sk","courseId":12,"contextid":"55"};</script>ZZ Kurs');
  }

  Future<void> stoppen() async {
    if (!_nie.isCompleted) _nie.complete();
    await server.close(force: true);
  }
}

void main() {
  late _Moodle extern;
  late Directory ordner;
  late Directory vorgaenge;
  late McpDienst dienst;
  late McpTestClient client;
  late Freigaben freigaben;
  late MoodleZugang moodle;
  late Protokoll protokoll;

  Future<void> starten({
    Duration antwortfrist = const Duration(seconds: 30),
    Duration langsamAb = const Duration(seconds: 5),
  }) async {
    final port = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final profil = Profil(
      kennung: 'test',
      name: 'Test',
      adresse: extern.basis.toString(),
      port: port.port,
      mcpName: 'test',
      schluessel: 'test',
    );
    await port.close();
    protokoll = Protokoll();
    moodle = await MoodleZugang.fuerTest(
      protokoll,
      extern.basis,
      benutzer: 'e.mustermann',
      passwort: 'erfunden',
      schreibvorgaengeOrdner: vorgaenge.path,
      antwortfrist: antwortfrist,
      langsamAb: langsamAb,
    );
    freigaben = Freigaben(protokoll, frist: const Duration(seconds: 20));
    // Der Test spielt die Lehrkraft: jede Freigabe wird erteilt.
    freigaben.addListener(() {
      if (freigaben.aktuell != null) scheduleMicrotask(() => freigaben.entscheiden(true));
    });
    dienst = McpDienst(Einstellungen(schluessel: 'test'), moodle, protokoll, freigaben, ordner.path, profil: profil);
    await dienst.starten();
    client = McpTestClient(profil.port);
    await client.initialize();
  }

  setUp(() async {
    extern = _Moodle();
    await extern.starten();
    ordner = await Directory.systemTemp.createTemp('moocp-bilder-');
    vorgaenge = await Directory.systemTemp.createTemp('moocp-bilder-vorgaenge-');
  });

  tearDown(() async {
    client.http.close(force: true);
    await dienst.stoppen();
    moodle.abmelden();
    await extern.stoppen();
    await ordner.delete(recursive: true);
    await vorgaenge.delete(recursive: true);
  });

  Future<String> lesen() => client.tool('aktivitaet_lesen', {'cmid': 101});

  bool bildOrdnerVorhanden() => Directory(p.join(ordner.path, 'cm-101')).existsSync();

  group('Bilder von 26 bis 196 KB', () {
    test('aktivitaet_lesen liest sechs Bilder vollständig, in einer Anfrage je Bild', () async {
      await starten();
      extern.anfragen.clear();
      final antwort = await lesen();
      expect(antwort, isNot(contains('NICHT gelesen')));
      for (var i = 0; i < _Moodle.groessen.length; i++) {
        expect(
          File(p.join(ordner.path, 'cm-101', 'dateien', 'bild$i.png')).lengthSync(),
          _Moodle.groessen[i],
          reason: 'bild$i.png vollständig übernommen',
        );
      }
      expect(extern.anfragen.where((a) => a.startsWith('POST')), isEmpty);
      expect(extern.bildanfragen, hasLength(6));
      expect(extern.anfragen, hasLength(7));
    });

    test('aendern speichert mit genau einem POST, lädt kein Bild neu hoch und meldet verified', () async {
      await starten();
      await lesen();
      final seite = File(p.join(ordner.path, 'cm-101', 'page.html'));
      seite.writeAsStringSync('${seite.readAsStringSync()}<p>ZZ Zusatz</p>');
      extern.anfragen.clear();
      final antwort = await client.tool('aendern', {'ordner': 'cm-101'});
      expect(antwort, contains('Gespeichert'));
      expect(antwort, contains('verified: true'));
      expect(extern.anfragen.where((a) => a.startsWith('POST /course/modedit.php')), hasLength(1));
      expect(extern.anfragen.where((a) => a.contains('/repository/')), isEmpty);
      expect(extern.text, contains('ZZ Zusatz'));
    });

    test('Verbindungsabbruch beim Speichern sendet den POST nicht noch einmal', () async {
      await starten();
      await lesen();
      final seite = File(p.join(ordner.path, 'cm-101', 'page.html'));
      seite.writeAsStringSync('${seite.readAsStringSync()}<p>ZZ Zusatz</p>');
      extern.postAbbrechen = true;
      extern.anfragen.clear();
      final antwort = await client.tool('aendern', {'ordner': 'cm-101'});
      expect(antwort, contains('Ausgang unklar'));
      expect(antwort, contains('verified: false'));
      expect(extern.anfragen.where((a) => a.startsWith('POST /course/modedit.php')), hasLength(1));
    });
  });

  group('Ein Bild, auf das Moodle nicht antwortet', () {
    test('ein hängendes Bild beendet das Lesen nach einer Zeitgrenze, nicht nach einer je Bild', () async {
      await starten(antwortfrist: const Duration(seconds: 1));
      extern.ab = 1;
      extern.anfragen.clear();
      final antwort = await lesen();
      expect(antwort, contains('Keine Antwort innerhalb der Zeitgrenze'));
      expect(antwort, contains('Moodle nicht erreichbar'));
      expect(antwort, isNot(contains('NICHT gelesen')));
      // Bild 0 antwortet, Bild 1 hängt; danach wird kein weiteres Bild versucht.
      expect(extern.bildanfragen, hasLength(2));
      expect(bildOrdnerVorhanden(), isFalse, reason: 'kein halb gelesener Ordner');
    });

    test('eine mitten in der Antwort abgebrochene Verbindung beendet das Lesen mit der Phase im Fehler', () async {
      await starten();
      extern.verhalten[2] = _Bild.bricht;
      extern.anfragen.clear();
      final antwort = await lesen();
      expect(antwort, contains('Verbindung abgebrochen'));
      expect(antwort, contains('Phase Antwortinhalt'));
      expect(extern.bildanfragen, hasLength(3));
      expect(bildOrdnerVorhanden(), isFalse);
    });

    test('ein unbekanntes Bild (404) bleibt ein Befund, die übrigen Bilder werden gelesen', () async {
      await starten();
      extern.verhalten[3] = _Bild.unbekannt;
      final antwort = await lesen();
      expect(antwort, contains('NICHT gelesen (1): bild3.png (HTTP 404)'));
      expect(extern.bildanfragen, hasLength(6));
      expect(File(p.join(ordner.path, 'cm-101', 'dateien', 'bild5.png')).existsSync(), isTrue);
    });

    test('bricht der Client das Lesen ab, schließt die App die Anfrage an Moodle und gibt den Ordner frei', () async {
      await starten();
      extern.ab = 1;
      final nummer = client.id + 1;
      final laufend = client.call('tools/call', {
        'name': 'aktivitaet_lesen',
        'arguments': {'cmid': 101},
      });
      unawaited(laufend.then((_) {}, onError: (_) {}));
      for (var i = 0; i < 200 && extern.haengend == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(extern.haengend, 1, reason: 'Das Lesen wartet auf das hängende Bild');

      await client.notification('notifications/cancelled', {'requestId': nummer, 'reason': 'Zeitlimit'});
      for (var i = 0; i < 200 && extern.abgebrochenVonApp == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(extern.abgebrochenVonApp, 1, reason: 'Die App schließt die Anfrage an Moodle, statt auf die Frist zu warten');

      // Ein erneutes Lesen desselben Ordners wartet nicht hinter dem abgebrochenen.
      extern.ab = null;
      final antwort = await lesen().timeout(const Duration(seconds: 5));
      expect(antwort, isNot(contains('NICHT gelesen')));
      expect(File(p.join(ordner.path, 'cm-101', 'dateien', 'bild5.png')).existsSync(), isTrue);
    });
  });

  group('Protokoll', () {
    test('die langsame Bildanfrage steht mit Dauer und Größe im Protokoll', () async {
      await starten(langsamAb: const Duration(milliseconds: 200));
      extern.verhalten[1] = _Bild.traege;
      await lesen();
      final langsam = [
        for (final e in protokoll.eintraege)
          if (e.text.contains('langsam') && e.text.contains('GET /draftfile.php/5/user/draft/777/bild1.png')) e.text,
      ];
      expect(langsam, hasLength(1));
      expect(langsam.single, contains('GET /draftfile.php/'));
      expect(langsam.single, matches(RegExp('\\(langsam: \\d+ ms, ${_Moodle.groessen[1]} Byte\\)')));
    });
  });
}
