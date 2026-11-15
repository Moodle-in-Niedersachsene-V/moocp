// Jede Anfrage an Moodle wird geprüft (Sperrliste vor Positivliste) und mit
// einer Zeile ins Protokoll geschrieben (A4): erlaubt mit Methode, Pfad, Query
// (ohne sesskey) und Status; gesperrt mit den Namen der Parameter, nie ihren
// Werten. Das gilt für jede Anfrage gleich, auch für den Download einer
// Sicherungsdatei, der einen eigenen Weg über die Leitung nimmt.
//
// Die Tests halten die Zeilen Wort für Wort fest, gegen ein Moodle-Doppel auf
// 127.0.0.1: Wer die Prüfung oder die Form der Zeilen umbaut, darf an keiner
// ändern. Dazu die Entscheidungen selbst: Was nicht angefragt werden darf,
// erreicht den Server nie.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

/// Ein Moodle, das Anmeldung, ein paar erlaubte Seiten und einen Download kann
/// und alles Angefragte mitschreibt.
class _Moodle {
  late final HttpServer server;
  late final Uri basis;

  /// Jede Anfrage, die den Server erreicht hat: `GET /pfad?query`.
  final angefragt = <String>[];
  var eingeloggt = false;

  // Die Antwort auf den Download.
  var downloadStatus = 200;
  var downloadTyp = 'application/octet-stream';
  var downloadBytes = List<int>.filled(2048, 7);

  Future<void> starten() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    basis = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen(_bedienen);
  }

  Future<void> _bedienen(HttpRequest req) async {
    await req.drain<void>();
    angefragt.add('${req.method} ${req.uri}');
    final r = req.response;
    final q = req.uri.queryParameters;

    Future<void> html(String text, {int status = 200}) {
      r
        ..statusCode = status
        ..headers.contentType = ContentType.html
        ..write(text);
      return r.close();
    }

    Future<void> json(String text) {
      r
        ..headers.contentType = ContentType.json
        ..write(text);
      return r.close();
    }

    switch (req.uri.path) {
      case '/login/index.php':
        if (req.method == 'POST') return r.redirect(Uri.parse('/login/index.php?testsession=1'), status: 303);
        if (q.containsKey('testsession')) {
          eingeloggt = true;
          return r.redirect(Uri.parse('/my/'), status: 303);
        }
        return html(
          eingeloggt
              ? '<html>Sie sind bereits angemeldet. {"sesskey":"abc123","userId":3}</html>'
              : '<html><input name="logintoken" value="t"></html>',
        );
      case '/course/modedit.php':
        if (q['update'] == '35') {
          // Ein Schutzdienst verlangt seine Prüfung.
          r.headers
            ..set('cf-mitigated', 'challenge')
            ..set('cf-ray', 'r1-FRA');
          return html('<html>Just a moment...</html>', status: 403);
        }
        if (q['update'] == '36') {
          // Ein Schutzdienst weist ab, ohne Ray-ID.
          r.headers.set('server', 'cloudflare');
          return html('<html>Blocked</html>', status: 403);
        }
        return html('<html>Kurs 12 {"sesskey":"abc123"}</html>');
      case '/course/view.php':
        if (q['id'] == '13') return r.redirect(Uri.parse('/user/profile.php?id=5'), status: 302);
        return html('<html>Kurs</html>');
      case '/mod/book/move.php':
        return html('<html>Buch</html>');
      case '/lib/ajax/service.php':
        return json('[{"error":false,"data":{"ok":1}}]');
      case '/repository/repository_ajax.php':
        return json('{"id":1}');
      case '/pluginfile.php/55/user/backup/1/download.mbz':
        r
          ..statusCode = downloadStatus
          ..headers.contentType = ContentType.parse(downloadTyp)
          ..contentLength = downloadBytes.length
          ..add(downloadBytes);
        return r.close();
    }
    return html('<html>nichts</html>', status: 404);
  }
}

void main() {
  late _Moodle moodle;
  late Protokoll protokoll;
  late MoodleZugang zugang;
  late Directory ordner;

  /// Das Protokoll, wie es dasteht: Art und Text jeder Zeile.
  List<String> zeilen() => [for (final e in protokoll.eintraege) '${e.art.name}: ${e.text}'];

  setUp(() async {
    moodle = _Moodle();
    await moodle.starten();
    protokoll = Protokoll();
    zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
    await zugang.sesskey();
    protokoll.leeren();
    moodle.angefragt.clear();
    ordner = await Directory.systemTemp.createTemp('moocp_zugang_protokoll');
  });

  tearDown(() async {
    await moodle.server.close(force: true);
    await ordner.delete(recursive: true);
  });

  test('Anmeldung: Methode, Pfad und Status; Art schreiben für das Formular, die Query der Anmeldeseite bleibt unlesbar', () async {
    moodle.eingeloggt = false;
    final eigenes = Protokoll();
    await MoodleZugang.fuerTest(eigenes, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
    expect(
      [
        for (final e in eigenes.eintraege)
          if (e.art == Art.moodle || e.art == Art.schreiben) '${e.art.name}: ${e.text}',
      ],
      [
        'moodle: GET /login/index.php → 200',
        'schreiben: POST /login/index.php → 303',
        'moodle: GET /login/index.php?… → 303',
      ],
    );
    expect(eigenes.eintraege.map((e) => e.text).join('\n'), isNot(contains('geheim')));
  });

  group('erlaubte Anfragen', () {
    test('Lesen: Methode, Pfad, Query und Status', () async {
      await zugang.lesen('/course/modedit.php?update=34');
      expect(zeilen(), ['moodle: GET /course/modedit.php?update=34 → 200']);
    });

    test('ein GET mit sesskey ist eine Aktion; der sesskey steht nie im Protokoll', () async {
      await zugang.aufrufen('/mod/book/move.php?id=5&chapterid=7&up=1&sesskey=abc123');
      expect(zeilen(), ['schreiben: GET /mod/book/move.php?id=5&chapterid=7&up=1&sesskey=… → 200']);
    });

    test('ein lesender Dienst ist Art moodle, ein schreibender Art schreiben', () async {
      await zugang.dienst('core_courseformat_get_state', {'courseid': 12});
      await zugang.dienst('mod_board_delete_note', {'id': 5});
      expect(zeilen(), [
        'moodle: POST /lib/ajax/service.php?sesskey=…&info=core_courseformat_get_state → 200',
        'schreiben: POST /lib/ajax/service.php?sesskey=…&info=mod_board_delete_note → 200',
      ]);
    });

    test('ein Upload nennt den Dateinamen in Klammern', () async {
      await zugang.hochladen(
        '/repository/repository_ajax.php?action=upload',
        [const MapEntry('itemid', '1')],
        Anhang('repo_upload_file', 'bild.png', [1, 2, 3], 'image/png'),
      );
      expect(zeilen(), ['schreiben: POST /repository/repository_ajax.php?action=upload (bild.png) → 200']);
    });

    test('ein Schutzdienst: die Zeile nennt Prüfung oder Abweisung und, wenn da, die Ray-ID', () async {
      await expectLater(zugang.lesen('/course/modedit.php?update=35'), throwsA(isA<SchutzPruefung>()));
      await expectLater(zugang.lesen('/course/modedit.php?update=36'), throwsA(isA<SchutzPruefung>()));
      expect(zeilen(), [
        'moodle: GET /course/modedit.php?update=35 → 403 (Schutzdienst: Prüfung verlangt, Ray-ID r1-FRA)',
        'moodle: GET /course/modedit.php?update=36 → 403 (Schutzdienst: abgewiesen)',
      ]);
    });

    test('Moodle nicht erreichbar: nur der Pfad, ohne Query, als Fehler', () async {
      await moodle.server.close(force: true);
      await expectLater(zugang.lesen('/course/modedit.php?update=34'), throwsA(isA<MoodleNichtErreichbar>()));
      expect(zeilen(), ['fehler: GET /course/modedit.php: nicht erreichbar']);
    });
  });

  group('gesperrte Anfragen erreichen den Server nie', () {
    test('Sperrliste: Name der Parameter statt Werte, Regel in der Zeile, Meldung an die KI', () async {
      Object? fehler;
      try {
        await zugang.lesen('/user/index.php?id=2&studentid=45');
      } catch (e) {
        fehler = e;
      }
      expect(zeilen(), [
        r'gesperrt: Datenschutz-Sperre: GET /user/index.php?id=…&studentid=… (Regel [?&]studentid=)',
      ]);
      expect(
        (fehler! as MoodleFehler).meldung,
        'Gesperrt (Datenschutz): /user/index.php zeigt personenbezogene Daten -- Bewertungen, '
        'Abgaben, Versuche, Profile oder Protokolle. Die App liest sie grundsätzlich nicht. '
        'Dem Nutzer sagen, dass dieser Teil der Aufgabe offen bleibt, oder -- falls die '
        r'Adresse harmlos ist -- dass die Sperre zu weit ist (Regel [?&]studentid=).',
      );
      expect(moodle.angefragt, isEmpty);
    });

    test('nicht auf der Positivliste: GET nennt die Namen der Parameter', () async {
      Object? fehler;
      try {
        await zugang.lesen('/gibt/es/nicht.php?x=1&y=2');
      } catch (e) {
        fehler = e;
      }
      expect(zeilen(), ['gesperrt: Gesperrt: GET /gibt/es/nicht.php?x=…&y=…']);
      expect(
        (fehler! as MoodleFehler).meldung,
        'Gesperrt: GET /gibt/es/nicht.php steht nicht auf der Positivliste dieses Servers '
        '(oder die Werte passen nicht zu dem, was dort erlaubt ist).',
      );
      expect(moodle.angefragt, isEmpty);
    });

    test('nicht auf der Positivliste: ein Formular nennt die Namen der Felder, nie die Werte', () async {
      await expectLater(
        zugang.senden('/gibt/es/nicht.php', [const MapEntry('a', 'geheim'), const MapEntry('b', '2')]),
        throwsA(isA<MoodleFehler>()),
      );
      expect(zeilen(), ['gesperrt: Gesperrt: POST /gibt/es/nicht.php (Felder: a, b)']);
      expect(moodle.angefragt, isEmpty);
    });

    test('Wiederherstellen und Gruppen: zusätzlich die Form der Werte, nie die Werte', () async {
      final felder = [
        const MapEntry('zzz', 'abc'),
        const MapEntry('n', '12'),
        const MapEntry('m', 'a1!'),
        const MapEntry('leer', ''),
        MapEntry('h', 'a' * 32),
      ];
      await expectLater(zugang.senden('/backup/restore.php', felder), throwsA(isA<MoodleFehler>()));
      await expectLater(zugang.senden('/group/assign.php', felder), throwsA(isA<MoodleFehler>()));
      const form = ' (Felder: zzz, n, m, leer, h)'
          ' (Wertformen: zzz=Text(3), n=Zahl(2), m=gemischt(3), leer=leer(0), h=Hex32(32))';
      expect(zeilen(), [
        'gesperrt: Gesperrt: POST /backup/restore.php$form',
        'gesperrt: Gesperrt: POST /group/assign.php$form',
      ]);
      expect(moodle.angefragt, isEmpty);
    });

    test('ein Umleitungsziel wird wie jede Anfrage geprüft', () async {
      await expectLater(zugang.lesen('/course/view.php?id=13'), throwsA(isA<MoodleFehler>()));
      expect(zeilen(), [
        'moodle: GET /course/view.php?id=13 → 302',
        r'gesperrt: Datenschutz-Sperre: GET /user/profile.php?id=… (Regel /user/(view|profile|index|files|editadvanced)\.php)',
      ]);
      expect(moodle.angefragt, ['GET /course/view.php?id=13']);
    });

    test('ein fremder Rechner: Meldung, kein Eintrag, keine Anfrage', () async {
      Object? fehler;
      try {
        await zugang.lesen('https://fremd.example/course/view.php?id=12');
      } catch (e) {
        fehler = e;
      }
      expect((fehler! as MoodleFehler).meldung, 'Gesperrt: fremder Rechner oder kein https (fremd.example).');
      expect(zeilen(), isEmpty);
      expect(moodle.angefragt, isEmpty);
    });
  });

  group('Download einer Sicherungsdatei', () {
    const pfad = '/pluginfile.php/55/user/backup/1/download.mbz?forcedownload=1';
    File ziel() => File(p.join(ordner.path, 'sicherung.mbz'));
    File teil() => File('${ziel().path}.teil');

    test('geladen: dieselbe Zeile wie bei jeder Anfrage, Art moodle, die Datei liegt da', () async {
      final bytes = await zugang.herunterladen(pfad, ziel());
      expect(bytes, 2048);
      expect(zeilen(), ['moodle: GET /pluginfile.php/55/user/backup/1/download.mbz?forcedownload=1 → 200']);
      expect(await ziel().readAsBytes(), moodle.downloadBytes);
      expect(teil().existsSync(), isFalse);
      expect(moodle.angefragt, ['GET $pfad']);
    });

    test('eine andere Antwort als 200: Zeile mit Status, Meldung, nichts bleibt liegen', () async {
      moodle.downloadStatus = 404;
      Object? fehler;
      try {
        await zugang.herunterladen(pfad, ziel());
      } catch (e) {
        fehler = e;
      }
      expect((fehler! as MoodleFehler).meldung, 'Download abgelehnt (HTTP 404).');
      expect(zeilen(), ['moodle: GET /pluginfile.php/55/user/backup/1/download.mbz?forcedownload=1 → 404']);
      expect(ziel().existsSync(), isFalse);
      expect(teil().existsSync(), isFalse);
    });

    test('eine Seite statt einer Datei: Meldung, nichts bleibt liegen', () async {
      moodle.downloadTyp = 'text/html';
      Object? fehler;
      try {
        await zugang.herunterladen(pfad, ziel());
      } catch (e) {
        fehler = e;
      }
      expect(
        (fehler! as MoodleFehler).meldung,
        'Download liefert eine Seite statt einer Datei (Anmeldung abgelaufen?).',
      );
      expect(zeilen(), ['moodle: GET /pluginfile.php/55/user/backup/1/download.mbz?forcedownload=1 → 200']);
      expect(ziel().existsSync(), isFalse);
      expect(teil().existsSync(), isFalse);
    });

    test('über der Grenze: Zeile mit Status, DownloadZuGross, nichts bleibt liegen', () async {
      await expectLater(zugang.herunterladen(pfad, ziel(), maxBytes: 100), throwsA(isA<DownloadZuGross>()));
      expect(zeilen(), ['moodle: GET /pluginfile.php/55/user/backup/1/download.mbz?forcedownload=1 → 200']);
      expect(ziel().existsSync(), isFalse);
      expect(teil().existsSync(), isFalse);
    });

    test('eine vorhandene Zieldatei wird nie überschrieben, und es geht keine Anfrage hinaus', () async {
      await ziel().writeAsString('alt');
      Object? fehler;
      try {
        await zugang.herunterladen(pfad, ziel());
      } catch (e) {
        fehler = e;
      }
      expect((fehler! as MoodleFehler).meldung, 'Zieldatei existiert schon; nichts überschrieben.');
      expect(await ziel().readAsString(), 'alt');
      expect(zeilen(), isEmpty);
      expect(moodle.angefragt, isEmpty);
    });

    test('Moodle nicht erreichbar: nur der Pfad, als Fehler, nichts bleibt liegen', () async {
      await moodle.server.close(force: true);
      await expectLater(zugang.herunterladen(pfad, ziel()), throwsA(isA<MoodleNichtErreichbar>()));
      expect(zeilen(), ['fehler: GET /pluginfile.php/55/user/backup/1/download.mbz: nicht erreichbar']);
      expect(ziel().existsSync(), isFalse);
      expect(teil().existsSync(), isFalse);
    });

    test('die Sperrliste gilt auch hier: Zeile wie bei jeder Anfrage, kein Eintrag im Ziel, keine Anfrage', () async {
      Object? fehler;
      try {
        await zugang.herunterladen('/pluginfile.php/55/user/private/x.mbz?forcedownload=1', ziel());
      } catch (e) {
        fehler = e;
      }
      expect(
        (fehler! as MoodleFehler).meldung,
        startsWith('Gesperrt (Datenschutz): /pluginfile.php/55/user/private/x.mbz zeigt personenbezogene Daten'),
      );
      expect(zeilen(), [
        r'gesperrt: Datenschutz-Sperre: GET /pluginfile.php/55/user/private/x.mbz?forcedownload=… (Regel ^/pluginfile\.php/\d+/user/)',
      ]);
      expect(ziel().existsSync(), isFalse);
      expect(moodle.angefragt, isEmpty);
    });

    test('die Positivliste gilt auch hier: Zeile wie bei jeder Anfrage, keine Anfrage', () async {
      Object? fehler;
      try {
        await zugang.herunterladen('/gibt/es/nicht.php?forcedownload=1', ziel());
      } catch (e) {
        fehler = e;
      }
      expect(
        (fehler! as MoodleFehler).meldung,
        'Gesperrt: GET /gibt/es/nicht.php steht nicht auf der Positivliste dieses Servers '
        '(oder die Werte passen nicht zu dem, was dort erlaubt ist).',
      );
      expect(zeilen(), ['gesperrt: Gesperrt: GET /gibt/es/nicht.php?forcedownload=…']);
      expect(ziel().existsSync(), isFalse);
      expect(moodle.angefragt, isEmpty);
    });

    test('ein fremder Rechner: Meldung, kein Eintrag, keine Anfrage', () async {
      Object? fehler;
      try {
        await zugang.herunterladen('https://fremd.example$pfad', ziel());
      } catch (e) {
        fehler = e;
      }
      expect((fehler! as MoodleFehler).meldung, 'Gesperrt: fremder Rechner oder kein https (fremd.example).');
      expect(zeilen(), isEmpty);
      expect(moodle.angefragt, isEmpty);
    });
  });
}
