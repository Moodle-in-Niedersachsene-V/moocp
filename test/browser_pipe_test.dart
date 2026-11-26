// Die Pipe zum Browser der Bildschirmfotos (GHSA-x3m7): Rahmen und Zuordnung
// ohne Betriebssystem, der Ablauf der Aufnahme gegen einen nachgebauten
// Browser, die private Pipe unter Linux und Mac gegen echte FIFO. Mit
// Synthetikdaten; nie gegen eine echte Moodle-Instanz.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/bildschirmfoto.dart';
import 'package:moocp/moodle/cdp_pipe.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/plattform/browser_start.dart';
import 'package:moocp/plattform/browser_unix.dart';
import 'package:moocp/plattform/browser_windows.dart';
import 'package:moocp/plattform/datei_rechte.dart';
import 'package:moocp/plattform/privater_ordner.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

List<int> rahmen(Map<String, Object?> m) => [...utf8.encode(jsonEncode(m)), 0];

void main() {
  group('Rahmen und Zuordnung (CdpPipe)', () {
    late StreamController<List<int>> ein;
    late List<List<int>> aus;
    late CdpPipe pipe;
    setUp(() {
      ein = StreamController<List<int>>();
      aus = [];
      pipe = CdpPipe(
        ein.stream,
        aus.add,
        zeitgrenze: const Duration(milliseconds: 300),
      );
    });
    tearDown(() => pipe.schliessen());

    Map<String, dynamic> gesendet(int i) {
      final b = aus[i];
      expect(b.last, 0, reason: 'Jede Nachricht endet mit NUL');
      expect(b.sublist(0, b.length - 1), isNot(contains(0)));
      return jsonDecode(utf8.decode(b.sublist(0, b.length - 1)))
          as Map<String, dynamic>;
    }

    test(
      'sendet NUL-begrenztes JSON und ordnet die Antwort dem Befehl zu',
      () async {
        final f = pipe.senden('Page.navigate', {'url': 'about:blank'});
        final m = gesendet(0);
        expect(m['method'], 'Page.navigate');
        expect(m.containsKey('sessionId'), isFalse);
        ein.add(
          rahmen({
            'id': m['id'],
            'result': {'ok': 1},
          }),
        );
        expect(await f, {'ok': 1});
      },
    );

    test(
      'Antworten in anderer Reihenfolge gehen an den richtigen Befehl',
      () async {
        final a = pipe.senden('A'), b = pipe.senden('B');
        final ia = gesendet(0)['id'], ib = gesendet(1)['id'];
        ein.add([
          ...rahmen({
            'id': ib,
            'result': {'wer': 'b'},
          }),
          ...rahmen({
            'id': ia,
            'result': {'wer': 'a'},
          }),
        ]);
        expect((await a)['wer'], 'a');
        expect((await b)['wer'], 'b');
      },
    );

    test(
      'Nachricht in beliebig kleinen Stücken (auch mitten im UTF-8-Zeichen)',
      () async {
        final f = pipe.senden('X');
        final id = gesendet(0)['id'];
        final bytes = rahmen({
          'id': id,
          'result': {'text': 'Grüße ✓'},
        });
        for (final b in bytes) {
          ein.add([b]);
          await Future<void>.delayed(Duration.zero);
        }
        expect((await f)['text'], 'Grüße ✓');
      },
    );

    test(
      'mehrere Nachrichten in einem Stück, die letzte angebrochen',
      () async {
        final ereignisse = <String>[];
        pipe.ereignisse.listen((e) => ereignisse.add('${e['method']}'));
        final r = [
          ...rahmen({'method': 'E1'}),
          ...rahmen({'method': 'E2'}),
          ...rahmen({'method': 'E3'}),
        ];
        ein.add(r.sublist(0, r.length - 5));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(ereignisse, ['E1', 'E2']);
        ein.add(r.sublist(r.length - 5));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(ereignisse, ['E1', 'E2', 'E3']);
      },
    );

    test('ein NUL im Text steht nie roh im Rahmen', () {
      pipe.senden('X', {'t': 'a\u0000b'}).ignore();
      final b = aus[0];
      expect(b.where((x) => x == 0).length, 1);
    });

    test('Fehlerantwort des Browsers wird ein MoodleFehler', () async {
      final f = pipe.senden('X');
      ein.add(
        rahmen({
          'id': gesendet(0)['id'],
          'error': {'message': 'nein'},
        }),
      );
      await expectLater(
        f,
        throwsA(
          isA<MoodleFehler>().having((e) => '$e', 'Text', contains('nein')),
        ),
      );
    });

    test('Müll zwischen den Nachrichten stört nicht', () async {
      final f = pipe.senden('X');
      ein.add([
        ...utf8.encode('kein json'),
        0,
        0,
        ...rahmen({'id': gesendet(0)['id'], 'result': {}}),
      ]);
      expect(await f, isEmpty);
    });

    test('Sitzungen: Befehle tragen sessionId, Ereignisse gehen an die richtige Sicht', () async {
      final s1 = pipe.sitzung('S1'), s2 = pipe.sitzung('S2');
      final bei1 = <String>[], bei2 = <String>[], wurzel = <String>[];
      s1.ereignisse.listen((e) => bei1.add('${e['method']}'));
      s2.ereignisse.listen((e) => bei2.add('${e['method']}'));
      pipe.ereignisse.listen((e) => wurzel.add('${e['method']}'));
      final f = s1.senden('Runtime.evaluate');
      expect(gesendet(0)['sessionId'], 'S1');
      ein.add([
        ...rahmen({'method': 'A', 'sessionId': 'S1'}),
        ...rahmen({'method': 'B', 'sessionId': 'S2'}),
        ...rahmen({'method': 'C'}),
        ...rahmen({
          'id': gesendet(0)['id'],
          'sessionId': 'S1',
          'result': {'v': 1},
        }),
      ]);
      expect((await f)['v'], 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bei1, ['A']);
      expect(bei2, ['B']);
      expect(wurzel, ['C']);
    });

    test('keine Antwort: MoodleFehler nach der Zeitgrenze', () async {
      await expectLater(
        pipe.senden('Browser.getVersion'),
        throwsA(
          isA<MoodleFehler>().having(
            (e) => '$e',
            'Text',
            contains('antwortet nicht'),
          ),
        ),
      );
    });

    test('Ende des Kanals beendet offene Befehle und spätere scheitern als MoodleFehler', () async {
      final f = pipe.senden('X');
      await ein.close();
      await expectLater(f, throwsA(isA<MoodleFehler>()));
      await pipe.ende;
      await expectLater(pipe.senden('Y'), throwsA(isA<MoodleFehler>()));
    });
  });

  test('keine Schalterliste kennt einen Port, alle die Pipe', () {
    final a = browserArgumente(profil: Directory('/x/profil'), breite: 1280);
    expect(a.where((x) => x.contains('remote-debugging-port')), isEmpty);
    expect(a, contains('--remote-debugging-pipe'));
    expect(a.last, 'about:blank');
  });

  test('der Quelltext der Aufnahme kennt keinen Port und keine Port-Datei', () {
    for (final d in [
      'lib/moodle/bildschirmfoto.dart',
      'lib/plattform/browser_start.dart',
      'lib/plattform/browser_unix.dart',
      'lib/plattform/browser_windows.dart',
    ]) {
      final t = File(d).readAsStringSync();
      // Der Schalter darf in Kommentaren genannt werden, nie als Zeichenkette.
      expect(
        RegExp(r"'[^'\n]*remote-debugging-port").hasMatch(t),
        isFalse,
        reason: d,
      );
      expect(t.contains('DevToolsActivePort'), isFalse, reason: d);
      expect(t.contains('WebSocket.connect'), isFalse, reason: d);
    }
  });

  group('Ablauf der Aufnahme gegen einen nachgebauten Browser', () {
    late Directory ordner;
    setUp(() => ordner = Directory.systemTemp.createTempSync('moocp_pipe_'));
    tearDown(() => ordner.deleteSync(recursive: true));

    final adresse = Uri.parse(
      'https://moodle.schule.example/mod/page/view.php?id=7',
    );
    final basis = Uri.parse('https://moodle.schule.example/');

    Future<Aufnahme> lauf(
      FakeStarter st, {
      List<String>? geholt,
      Future<void>? abbruch,
      Duration? anlauf,
    }) => aufnehmen(
      basis: basis,
      holen: (methode, uri, {required seiten, rumpf, dokument = false}) async {
        geholt?.add('$methode $uri');
        return Antwort(
          200,
          uri,
          Uint8List.fromList(utf8.encode('<html></html>')),
          'text/html',
        );
      },
      protokoll: Protokoll(),
      adresse: adresse,
      inhalt: ('#region-main .generalbox.center', null),
      arbeitsordner: ordner.path,
      starter: st,
      browserWahl: ('Fake', '/fake/browser'),
      abbruch: abbruch,
      anlaufgrenze: anlauf ?? const Duration(seconds: 5),
      hartBeenden: (_, _) async => 0,
    );

    void aufgeraeumt(FakeStarter st) {
      expect(ordner.listSync(), isEmpty, reason: 'Profil gelöscht');
      expect(st.prozess!.beendet_, isTrue, reason: 'Browser beendet');
    }

    test('Erfolg: Pipe vor jeder Seite, Anfragen über die App, Fremdes gesperrt, danach aufgeräumt', () async {
      final st = FakeStarter(ordner);
      final geholt = <String>[];
      final a = await lauf(st, geholt: geholt);
      expect(a.bilder, hasLength(1));
      expect(
        st.argumente.where((x) => x.contains('remote-debugging-port')),
        isEmpty,
      );
      expect(st.argumente, contains('--remote-debugging-pipe'));
      // Reihenfolge: Anhalten der Anfragen steht, bevor navigiert wird.
      final l = st.prozess!.log;
      expect(l.indexOf('Fetch.enable'), greaterThanOrEqualTo(0));
      expect(l.indexOf('Fetch.enable'), lessThan(l.indexOf('Page.navigate')));
      expect(
        l.indexOf('Browser.getVersion'),
        lessThan(l.indexOf('Fetch.enable')),
      );
      // Befehle an die Seite tragen die Sitzung, Fetch geht an den Browser.
      expect(st.prozess!.sitzungVon['Page.navigate'], 'S1');
      expect(st.prozess!.sitzungVon['Fetch.enable'], isNull);
      // Das Dokument kommt über die App, die fremde Adresse nie.
      expect(geholt, ['GET $adresse']);
      expect(st.prozess!.log, contains('Fetch.failRequest'));
      expect(a.gesperrt.single, contains('fremder Rechner'));
      aufgeraeumt(st);
    });

    test('Browser antwortet nicht auf die Pipe: Fehler vor jeder Seite, nichts von Moodle geladen', () async {
      final st = FakeStarter(ordner, stumm: true);
      final geholt = <String>[];
      await expectLater(
        lauf(st, geholt: geholt, anlauf: const Duration(milliseconds: 300)),
        throwsA(
          isA<MoodleFehler>().having(
            (e) => '$e',
            'Text',
            allOf(
              contains('antwortet nicht auf die Pipe'),
              contains('nichts von Moodle geladen'),
            ),
          ),
        ),
      );
      expect(geholt, isEmpty);
      expect(st.prozess!.log, isNot(contains('Page.navigate')));
      expect(st.prozess!.log, isNot(contains('Fetch.enable')));
      aufgeraeumt(st);
    });

    test(
      'Browser startet nicht: Fehler mit Meldung, Profil gelöscht',
      () async {
        final st = FakeStarter(ordner, startFehler: 'kaputt');
        await expectLater(
          lauf(st),
          throwsA(
            isA<MoodleFehler>().having(
              (e) => '$e',
              'Text',
              contains('startet nicht'),
            ),
          ),
        );
        expect(ordner.listSync(), isEmpty);
      },
    );

    test('Fehler auf der Seite: Browser beendet, Profil gelöscht', () async {
      final st = FakeStarter(ordner, auswertenFehler: true);
      await expectLater(lauf(st), throwsA(isA<MoodleFehler>()));
      aufgeraeumt(st);
    });

    test('Abbruch des Clients mitten in der Aufnahme: Browser beendet, Profil gelöscht', () async {
      final st = FakeStarter(ordner, haengtBeimLaden: true);
      final abbruch = Completer<void>();
      final f = lauf(st, abbruch: abbruch.future);
      f.ignore();
      while (st.prozess == null || !st.prozess!.log.contains('Page.navigate')) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      abbruch.complete();
      await expectLater(f, throwsA(isA<MoodleAbgebrochen>()));
      aufgeraeumt(st);
    });

    test(
      'Browser reagiert auf Browser.close nicht: er wird hart beendet',
      () async {
        final st = FakeStarter(ordner, schliesstNicht: true);
        await lauf(st);
        aufgeraeumt(st);
      },
    );
  });

  group('Freigabe und Abbruch über bildschirmfoto', () {
    late Directory ordner;
    setUp(() => ordner = Directory.systemTemp.createTempSync('moocp_frei_'));
    tearDown(() => ordner.deleteSync(recursive: true));

    final basis = Uri.parse('https://moodle.schule.example/');
    final adresse = Uri.parse(
      'https://moodle.schule.example/mod/page/view.php?id=7',
    );

    Future<Aufnahme> aufnahme(FakeStarter st, {Future<void>? abbruch}) =>
        aufnehmen(
          basis: basis,
          holen: (m, uri, {required seiten, rumpf, dokument = false}) async =>
              Antwort(
                200,
                uri,
                Uint8List.fromList(utf8.encode('<html></html>')),
                'text/html',
              ),
          protokoll: Protokoll(),
          adresse: adresse,
          inhalt: ('#region-main .generalbox.center', null),
          arbeitsordner: ordner.path,
          starter: st,
          browserWahl: ('Fake', '/fake/browser'),
          abbruch: abbruch,
          anlaufgrenze: const Duration(seconds: 5),
          hartBeenden: (_, _) async => 0,
        );

    Future<String> anbieten(
      FakeStarter st,
      Freigaben fg, {
      Future<void>? abbruch,
    }) => aufnahmeAnbieten(
      aufnahme: () => aufnahme(st, abbruch: abbruch),
      kursZeile: () async => null,
      freigaben: fg,
      wozu: 'Prüfen, ob die Formeln gesetzt werden',
      seite: 'Textseite „Muster“ (cmid 7)',
      adresse: adresse,
      druck: false,
      name: 'cm-7',
      arbeitsordner: ordner.path,
    );

    List<String> pngs() => [
      for (final f in ordner.listSync().whereType<File>())
        if (f.path.endsWith('.png')) f.path,
    ];

    Future<void> aufDialog(Freigaben fg) async {
      while (fg.aktuell == null) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('Ablehnung: Browser und Profil sind schon vor der Entscheidung weg, kein PNG', () async {
      final st = FakeStarter(ordner);
      final fg = Freigaben(Protokoll());
      final f = anbieten(st, fg);
      await aufDialog(fg);
      expect(st.prozess!.beendet_, isTrue);
      expect(
        ordner.listSync().whereType<Directory>(),
        isEmpty,
        reason: 'Profil gelöscht',
      );
      expect(
        pngs(),
        isEmpty,
        reason: 'vor der Freigabe nichts im Arbeitsordner',
      );
      fg.entscheiden(false);
      expect(await f, contains('Nicht freigegeben'));
      expect(pngs(), isEmpty);
    });

    test('Freigabe: erst danach liegt das PNG im Arbeitsordner', () async {
      final st = FakeStarter(ordner);
      final fg = Freigaben(Protokoll());
      final f = anbieten(st, fg);
      await aufDialog(fg);
      expect(pngs(), isEmpty);
      fg.entscheiden(true);
      expect(await f, contains('bildschirmfoto-cm-7.png'));
      expect(pngs(), hasLength(1));
    });

    test('Abbruch des Clients über Freigaben.mitAbbruch beendet den Browser und löscht das Profil', () async {
      final st = FakeStarter(ordner, haengtBeimLaden: true);
      final fg = Freigaben(Protokoll());
      final abbruch = Completer<void>();
      final f = Freigaben.mitAbbruch(
        abbruch.future,
        () => aufnahmeAnbieten(
          aufnahme: () => aufnahme(st, abbruch: Freigaben.abbruchImAufruf),
          kursZeile: () async => null,
          freigaben: fg,
          wozu: 'Prüfen, ob die Formeln gesetzt werden',
          seite: 'Seite',
          adresse: adresse,
          druck: false,
          name: 'cm-7',
          arbeitsordner: ordner.path,
        ),
      );
      f.ignore();
      while (st.prozess == null || !st.prozess!.log.contains('Page.navigate')) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      abbruch.complete();
      await expectLater(f, throwsA(isA<MoodleAbgebrochen>()));
      expect(st.prozess!.beendet_, isTrue);
      expect(ordner.listSync(), isEmpty);
      expect(fg.aktuell, isNull, reason: 'keine Freigabe angefragt');
    });
  });

  group('Windows-Hilfen (plattformunabhängig prüfbar)', () {
    test('windowsArgument: Anführungszeichen nur wo nötig, Schrägstriche vor " verdoppelt', () {
      expect(windowsArgument('--a=b'), '--a=b');
      expect(windowsArgument(''), '""');
      expect(
        windowsArgument(r'C:\Program Files\x.exe'),
        r'"C:\Program Files\x.exe"',
      );
      expect(windowsArgument(r'a\"b'), r'"a\\\"b"');
      expect(
        windowsArgument(r'--user-data-dir=C:\mit leer\'),
        r'"--user-data-dir=C:\mit leer\\"',
      );
    });

    test('windowsUmgebungsblock: name=wert, NUL-beendet, sortiert, doppeltes NUL am Ende', () {
      final b = windowsUmgebungsblock({'b': '2', 'A': '1'});
      expect(String.fromCharCodes(b), 'A=1\u0000b=2\u0000\u0000\u0000');
    });

    test('windowsReserved2: Zahl, Flags, Handles (CRT-Layout)', () {
      final b = windowsReserved2(nul: 10, lesen: 20, schreiben: 30);
      final d = ByteData.sublistView(b);
      expect(b.length, 4 + 5 + 5 * 8);
      expect(d.getInt32(0, Endian.little), 5);
      expect(b.sublist(4, 9), [0x41, 0x41, 0x41, 0x09, 0x09]);
      expect(
        [for (var i = 0; i < 5; i++) d.getInt64(9 + i * 8, Endian.little)],
        [10, 10, 10, 20, 30],
      );
    });
  });

  test(
    'beiFehlerAufraeumen räumt bei einem Fehler auf und reicht ihn weiter',
    () async {
      var aufgeraeumt = 0;
      await expectLater(
        beiFehlerAufraeumen<int>(
          () async => throw StateError('x'),
          () => aufgeraeumt++,
        ),
        throwsA(isA<StateError>()),
      );
      expect(aufgeraeumt, 1);
      expect(await beiFehlerAufraeumen(() async => 5, () => aufgeraeumt++), 5);
      expect(aufgeraeumt, 1, reason: 'bei Erfolg nicht');
      // Scheitert das Aufräumen selbst, zählt der ursprüngliche Fehler.
      await expectLater(
        beiFehlerAufraeumen<int>(
          () async => throw StateError('x'),
          () => throw ArgumentError('y'),
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  group('private Pipe unter Linux und Mac', () {
    late Directory ordner;
    setUp(() => ordner = Directory.systemTemp.createTempSync('moocp_unix_'));
    tearDown(() async {
      await Process.run('chmod', ['-R', 'u+rwx', ordner.path]);
      ordner.deleteSync(recursive: true);
    });
    final unix = Platform.isLinux || Platform.isMacOS;

    test('Profil: Ordner mit Rechten 700, dem aktuellen Benutzer', () async {
      final d = await UnixBrowserStarter().profilAnlegen(ordner.path);
      expect(FileStat.statSync(d.path).mode & 511, 448);
      expect(
        FileSystemEntity.typeSync(d.path, followLinks: false),
        FileSystemEntityType.directory,
      );
      privatPruefen(d.path);
    }, skip: !unix);

    test(
      'Prüfung lehnt Verknüpfung, falsche Rechte, Sonderbits und fremden Besitzer ab',
      () async {
        final echt = Directory(p.join(ordner.path, 'echt'))..createSync();
        await Process.run('chmod', ['700', echt.path]);
        Link(p.join(ordner.path, 'link')).createSync(echt.path);
        expect(() => privatPruefen(p.join(ordner.path, 'link')), throwsA(isA<BrowserStartFehler>()));
        await Process.run('chmod', ['755', echt.path]);
        expect(() => privatPruefen(echt.path), throwsA(isA<BrowserStartFehler>()));
        // Sonderbits: mit der alten Maske auf die unteren neun Bit wäre 2700 durchgegangen.
        await Process.run('chmod', ['2700', echt.path]);
        expect(() => privatPruefen(echt.path), throwsA(isA<BrowserStartFehler>()), reason: 'setgid');
        // Bei einem Ordner lässt `chmod 700` das setgid-Bit stehen.
        await Process.run('chmod', ['g-s,u=rwx,go=', echt.path]);
        privatPruefen(echt.path);
        expect(() => privatPruefen(echt.path, system: _AnderesKonto()), throwsA(isA<BrowserStartFehler>()), reason: 'fremder Besitzer');
        // Eine Datei statt einer FIFO oder eines Ordners
        final datei = File(p.join(ordner.path, 'f'))..writeAsStringSync('x');
        expect(() => privatPruefen(datei.path, fifo: true), throwsA(isA<BrowserStartFehler>()));
        expect(() => privatPruefen(datei.path), throwsA(isA<BrowserStartFehler>()));
        expect(() => privatPruefen(p.join(ordner.path, 'gibt-es-nicht')), throwsA(isA<BrowserStartFehler>()));
      },
      skip: !unix,
    );

    test('FIFO: genau 600, dem Benutzer, sonst Fehler', () async {
      final fifo = p.join(ordner.path, 'fifo');
      Process.runSync('mkfifo', ['-m', '600', fifo]);
      privatPruefen(fifo, fifo: true);
      Process.runSync('chmod', ['660', fifo]);
      expect(() => privatPruefen(fifo, fifo: true), throwsA(isA<BrowserStartFehler>()), reason: 'Gruppe darf mit');
      Process.runSync('chmod', ['600', fifo]);
      expect(() => privatPruefen(fifo, system: _AnderesKonto(), fifo: true), throwsA(isA<BrowserStartFehler>()));
    }, skip: !unix);

    test('`stat` kommt von einem festen Ort, nie aus dem PATH', () {
      final stat = statProgramm();
      expect(stat, anyOf(isNull, '/usr/bin/stat', '/bin/stat'));
      expect(stat != null, isTrue, reason: 'auf diesem Rechner gibt es eines');
    }, skip: !unix);

    test('ein Profil, das sich nicht anlegen lässt (mkdir scheitert): deutscher Fehler, bevor etwas von Moodle kommt', () async {
      final geholt = <String>[];
      final st = UnixBrowserStarter(system: _MkdirKaputt());
      await expectLater(
        aufnehmen(
          basis: Uri.parse('https://moodle.schule.example/'),
          holen: (methode, uri, {required seiten, rumpf, dokument = false}) async {
            geholt.add('$methode $uri');
            return Antwort(200, uri, Uint8List.fromList(utf8.encode('<html></html>')), 'text/html');
          },
          protokoll: Protokoll(),
          adresse: Uri.parse('https://moodle.schule.example/mod/page/view.php?id=7'),
          inhalt: ('#region-main .generalbox.center', null),
          arbeitsordner: ordner.path,
          starter: st,
          browserWahl: ('Fake', '/fake/browser'),
          hartBeenden: (_, _) async => 0,
        ),
        throwsA(
          isA<MoodleFehler>().having(
            (e) => '$e',
            'Text',
            allOf(contains('Profil des Browsers ließ sich nicht anlegen'), contains('ließ sich nicht anlegen. moocp schreibt dort nichts')),
          ),
        ),
      );
      expect(geholt, isEmpty);
      expect(ordner.listSync(), isEmpty, reason: 'nichts bleibt liegen');
    }, skip: !unix);

    test('ein Profil mit fremdem Besitzer nach dem Anlegen wird nicht benutzt', () async {
      final st = UnixBrowserStarter(system: _AnderesKonto());
      await expectLater(st.profilAnlegen(ordner.path), throwsA(isA<BrowserStartFehler>()));
      expect(ordner.listSync(), isEmpty, reason: 'der unbrauchbare Ordner wird entfernt');
    }, skip: !unix);

    // Ein „Browser“, der an fd 3 liest und an fd 4 zurückschreibt: Er prüft
    // den Weg über die Shell und die FIFO.
    File echo() {
      final f = File(p.join(ordner.path, 'echo.sh'))
        ..writeAsStringSync('#!/bin/sh\nexec cat <&3 >&4\n');
      Process.runSync('chmod', ['700', f.path]);
      return f;
    }

    test('Bytes laufen über fd 3 und fd 4; FIFO mit Rechten 600 im privaten Ordner', () async {
      final st = UnixBrowserStarter();
      final profil = await st.profilAnlegen(ordner.path);
      final proz = await st.starten(echo().path, const [], profil);
      final empfangen = <int>[];
      final fertig = Completer<void>();
      proz.eingang.listen(empfangen.addAll);
      for (final n in ['cdp-ein', 'cdp-aus']) {
        final f = p.join(profil.path, n);
        expect(
          FileSystemEntity.typeSync(f, followLinks: false),
          FileSystemEntityType.pipe,
        );
        expect(FileStat.statSync(f).mode & 511, 384);
      }
      proz.senden([...utf8.encode('{"id":1}'), 0]);
      for (var i = 0; i < 100 && empfangen.length < 9; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(utf8.decode(empfangen.sublist(0, 8)), '{"id":1}');
      expect(empfangen[8], 0);
      await proz.beenden();
      fertig.complete();
    }, skip: !unix);

    test(
      'Browser, der nicht startet: der Kanal endet sofort, nichts hängt',
      () async {
        final st = UnixBrowserStarter(
          oeffnenGrenze: const Duration(seconds: 5),
        );
        final profil = await st.profilAnlegen(ordner.path);
        final proz = await st
            .starten(p.join(ordner.path, 'gibt-es-nicht'), const [], profil)
            .timeout(const Duration(seconds: 10));
        await proz.eingang.drain<void>().timeout(const Duration(seconds: 5));
        expect(
          await proz.beendet.timeout(const Duration(seconds: 5)),
          isNonZero,
        );
        await proz.beenden();
      },
      skip: !unix,
    );

    test('fehlende Shell oder fehlendes mkfifo: klarer Fehler', () async {
      final st = UnixBrowserStarter(shell: p.join(ordner.path, 'keine-shell'));
      final profil = await st.profilAnlegen(ordner.path);
      await expectLater(
        st.starten('/bin/true', const [], profil),
        throwsA(
          isA<BrowserStartFehler>().having(
            (e) => e.meldung,
            'Text',
            contains('Shell'),
          ),
        ),
      );
      final st2 = UnixBrowserStarter(mkfifo: 'gibt-es-nicht-mkfifo');
      final profil2 = await st2.profilAnlegen(ordner.path);
      await expectLater(
        st2.starten('/bin/true', const [], profil2),
        throwsA(
          isA<BrowserStartFehler>().having(
            (e) => e.meldung,
            'Text',
            contains('mkfifo'),
          ),
        ),
      );
    }, skip: !unix);

    test('Pfade mit Sonderzeichen gelangen unverändert zum Browser (nie in Shell-Text)', () async {
      final f = File(p.join(ordner.path, r'a b$(touch pwn)`x`.sh'))
        ..writeAsStringSync('#!/bin/sh\nexec cat <&3 >&4\n');
      Process.runSync('chmod', ['700', f.path]);
      final st = UnixBrowserStarter();
      final profil = await st.profilAnlegen(ordner.path);
      final proz = await st.starten(f.path, const [
        r'--x=$(touch pwn2)',
      ], profil);
      await proz.beenden();
      expect(File(p.join(ordner.path, 'pwn')).existsSync(), isFalse);
      expect(File('pwn2').existsSync(), isFalse);
    }, skip: !unix);
  });
}

/// Das echte Dateisystem, aber ein anderes Konto als Benutzer: Was dem
/// Prozess gehört, gehört dann einem Fremden.
class _AnderesKonto implements PrivatSystem {
  final _echt = UnixPrivatSystem();

  @override
  int get uid => _echt.uid + 1;

  @override
  DateiAngabe? angabe(String pfad) => _echt.angabe(pfad);

  @override
  void anlegen(String pfad) => _echt.anlegen(pfad);
}

/// `mkdir` scheitert (etwa ein Arbeitsordner, der nicht beschreibbar ist).
class _MkdirKaputt extends _AnderesKonto {
  @override
  int get uid => _echt.uid;

  @override
  void anlegen(String pfad) => throw FileSystemException('Ordner ließ sich nicht anlegen', pfad);
}

/// Ein nachgebauter Browser: spricht CDP über die Schnittstelle der Pipe.
class FakeStarter implements BrowserStarter {
  FakeStarter(
    this.ordner, {
    this.stumm = false,
    this.startFehler,
    this.auswertenFehler = false,
    this.haengtBeimLaden = false,
    this.schliesstNicht = false,
  });

  final Directory ordner;
  final bool stumm, auswertenFehler, haengtBeimLaden, schliesstNicht;
  final String? startFehler;
  FakeProzess? prozess;
  List<String> argumente = const [];

  @override
  Future<Directory> profilAnlegen(String arbeitsordner) async =>
      Directory(p.join(arbeitsordner, '.browser-test')).create();

  @override
  Future<BrowserProzess> starten(
    String programm,
    List<String> argumente,
    Directory profil,
  ) async {
    this.argumente = argumente;
    if (startFehler != null) throw BrowserStartFehler(startFehler!);
    return prozess = FakeProzess(this);
  }
}

class FakeProzess implements BrowserProzess {
  FakeProzess(this.v);
  final FakeStarter v;
  final _ein = StreamController<List<int>>();
  final _exit = Completer<int>();
  final log = <String>[];
  final sitzungVon = <String, String?>{};
  var beendet_ = false;
  var _puffer = <int>[];

  @override
  int get pid => 4242;
  @override
  Stream<List<int>> get eingang => _ein.stream;
  @override
  Future<int> get beendet => _exit.future;

  void _an(Map<String, Object?> m) {
    if (!_ein.isClosed) _ein.add(rahmen(m));
  }

  @override
  void senden(List<int> bytes) {
    _puffer = [..._puffer, ...bytes];
    while (_puffer.contains(0)) {
      final i = _puffer.indexOf(0);
      final m = jsonDecode(
        utf8.decode(_puffer.sublist(0, i)),
      ) as Map<String, dynamic>;
      _puffer = _puffer.sublist(i + 1);
      scheduleMicrotask(() => _behandeln(m));
    }
  }

  void _behandeln(Map<String, dynamic> m) {
    final id = m['id'], methode = '${m['method']}';
    final s = m['sessionId'] as String?;
    log.add(methode);
    sitzungVon[methode] = s;
    if (v.stumm) return;
    void ok([Map<String, Object?> r = const {}]) =>
        _an({'id': id, 'result': r, 'sessionId': ?s});
    final p = (m['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    switch (methode) {
      case 'Target.getTargets':
        ok({
          'targetInfos': [
            {'type': 'page', 'targetId': 'T1'},
          ],
        });
      case 'Target.attachToTarget':
        ok({'sessionId': 'S1'});
      case 'Page.navigate':
        ok();
        if (v.haengtBeimLaden) return;
        _an({
          'method': 'Fetch.requestPaused',
          'params': {
            'requestId': 'R1',
            'request': {
              'method': 'GET',
              'url': 'https://moodle.schule.example/mod/page/view.php?id=7',
            },
            'resourceType': 'Document',
          },
        });
        _an({
          'method': 'Fetch.requestPaused',
          'params': {
            'requestId': 'R2',
            'request': {'method': 'GET', 'url': 'https://fremd.example/x.js'},
            'resourceType': 'Script',
          },
        });
      case 'Fetch.fulfillRequest':
        ok();
        _an({'method': 'Page.loadEventFired', 'sessionId': 'S1', 'params': {}});
      case 'Runtime.evaluate':
        if (v.auswertenFehler) {
          ok({
            'exceptionDetails': {'text': 'x'},
          });
          return;
        }
        final e = '${p['expression']}';
        final wert = e.contains('__moocpFehler || []')
            ? '[]'
            : e.contains('filter_mathjaxloader_equation')
            ? '{"huellen":0,"gesetzt":0,"text":0}'
            : '{"x":0,"y":0,"w":100,"h":50,"sperren":[]}';
        ok({
          'result': {'value': wert},
        });
      case 'Page.captureScreenshot':
        ok({
          'data': base64Encode([137, 80, 78, 71]),
        });
      case 'Browser.close':
        ok();
        if (!v.schliesstNicht) _beenden();
      default:
        ok();
    }
  }

  void _beenden() {
    beendet_ = true;
    if (!_ein.isClosed) unawaited(_ein.close());
    if (!_exit.isCompleted) _exit.complete(0);
  }

  @override
  Future<void> beenden() async => _beenden();
}
