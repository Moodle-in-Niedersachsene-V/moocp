// Der Kanal zwischen Brücke und App (lib/mcp/kanal.dart) mit echten
// Unix-Sockets in einem privaten Ordner (unter Windows mit der echten Named
// Pipe): Verbindung und Neuaufbau, ein Endpunkt je Profil, und die Fälle, in
// denen nichts fließen darf -- Ordner oder Socket eines anderen Kontos, zu
// weite Rechte, Verknüpfung, Gegenstelle mit fremder Kennung. Ein zweites
// Konto gibt es hier nicht; seine Kennung steht als Attrappe an der Stelle, an
// der das System sie liefert. Was nur für Unix-Sockets gilt, ist unter Windows
// übersprungen; die Fälle, die beide Kanäle tragen, laufen dort über die Pipe
// (mit je Aufruf eigenem Namen, damit sie keine laufende App stören).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/mcp/bruecke.dart' show werkzeuglisteFuerStart;
import 'package:moocp/mcp/kanal.dart';
import 'package:moocp/mcp/kanal_windows.dart';
import 'package:moocp/plattform/datei_rechte.dart';
import 'package:moocp/plattform/privater_ordner.dart';
import 'package:path/path.dart' as p;

/// Das echte Dateisystem, aber mit einer anderen Kennung für das laufende
/// Konto: Alles, was dem echten Konto gehört, ist dann das eines anderen.
class _AnderesKonto implements PrivatSystem {
  _AnderesKonto();
  final _echt = UnixPrivatSystem();
  @override
  int get uid => _echt.uid + 1;
  @override
  DateiAngabe? angabe(String pfad) => _echt.angabe(pfad);
  @override
  void anlegen(String pfad) => _echt.anlegen(pfad);
}

/// Die Rechte eines Sockets, wie sie ein anderes Konto hinterließe.
class _FremderSocket implements DateiRechte {
  static const _echt = UnixDateiRechte();
  @override
  DateiEintrag? eintrag(String pfad) {
    final e = _echt.eintrag(pfad);
    return e == null ? null : DateiEintrag(art: e.art, uid: e.uid + 1, modus: e.modus);
  }

  @override
  void chmod(String pfad, int modus) => _echt.chmod(pfad, modus);
}

Future<List<String>> _zeilen(KanalVerbindung v, int anzahl) async {
  final z = <String>[];
  final fertig = Completer<void>();
  final abo = v.eingang.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
    z.add(l);
    if (z.length >= anzahl && !fertig.isCompleted) fertig.complete();
  });
  await fertig.future.timeout(const Duration(seconds: 5));
  await abo.cancel();
  return z;
}

/// Zählt die Profilnamen unter Windows hoch: Der Name einer Pipe gehört dem
/// ganzen Rechner, ein Rest eines früheren Tests oder die laufende App dürfen
/// nicht stören.
int _zaehler = 0;

void main() {
  // Unter Windows gilt kein Unix-Socket, keine Kennung und kein POSIX-Recht.
  final String? posix = Platform.isWindows ? 'POSIX: Unix-Socket, Kennung, Dateirechte' : null;
  late Directory wurzel;
  late String ordner;
  late KanalOrt kanal;
  late String sfx;

  /// Der Profilname dieses Tests: unter Windows mit Zusatz.
  String n(String basis) => Platform.isWindows ? '$basis-zz$pid-$sfx' : basis;

  setUp(() {
    wurzel = Directory.systemTemp.createTempSync('moocp_kanal_');
    ordner = p.join(wurzel.path, 'k');
    sfx = '${_zaehler++}';
    kanal = Platform.isWindows ? WindowsKanal() : UnixKanal(ketten: () => [[ordner]]);
  });
  tearDown(() => wurzel.deleteSync(recursive: true));

  /// Wartet, bis die Pipe weg ist (die letzte Instanz schließt asynchron).
  Future<void> bisNichtDa(String name) async {
    for (var i = 0; i < 100; i++) {
      try {
        await (await kanal.verbinden(name)).schliessen();
      } on KanalNichtDa {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('der Kanal $name ist nach 5 s noch da');
  }

  test('eine Verbindung trägt Zeilen in beide Richtungen', () async {
    final l = await kanal.lauschen(n('moodle'));
    addTearDown(l.schliessen);
    final angenommen = l.verbindungen.first;
    final c = await kanal.verbinden(n('moodle'));
    final s = await angenommen;
    c.senden(utf8.encode('{"hin":1}\n'));
    expect(await _zeilen(s, 1), ['{"hin":1}']);
    s.senden(utf8.encode('{"zurueck":2}\n'));
    expect(await _zeilen(c, 1), ['{"zurueck":2}']);
    await c.schliessen();
  });

  test('der Ordner ist 0700, der Socket 0600', () async {
    final l = await kanal.lauschen('moodle');
    addTearDown(l.schliessen);
    expect(FileStat.statSync(ordner).mode & 0x1ff, 0x1c0);
    expect(FileStat.statSync(p.join(ordner, 'moodle.sock')).mode & 0x1ff, 0x180);
  }, skip: posix);

  test('zwei Profile, zwei Endpunkte: eine Verbindung erreicht nie das andere', () async {
    final a = await kanal.lauschen(n('moodle'));
    final b = await kanal.lauschen(n('moodle-test'));
    addTearDown(a.schliessen);
    addTearDown(b.schliessen);
    final beiA = <KanalVerbindung>[];
    final beiB = <KanalVerbindung>[];
    a.verbindungen.listen(beiA.add);
    b.verbindungen.listen(beiB.add);
    final c = await kanal.verbinden(n('moodle-test'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(beiA, isEmpty);
    expect(beiB, hasLength(1));
    await c.schliessen();
  });

  test('ohne Lauscher: KanalNichtDa; nach dem Neustart der App geht es wieder', () async {
    await expectLater(kanal.verbinden(n('moodle')), throwsA(isA<KanalNichtDa>()));
    final l1 = await kanal.lauschen(n('moodle'));
    await (await kanal.verbinden(n('moodle'))).schliessen();
    await l1.schliessen();
    await bisNichtDa(n('moodle'));
    final l2 = await kanal.lauschen(n('moodle'));
    addTearDown(l2.schliessen);
    await (await kanal.verbinden(n('moodle'))).schliessen();
  });

  test('ein Socket aus einem abgestürzten Lauf wird ersetzt', () async {
    // Dart löscht die Datei beim Schließen; einen Rest legt ein Prozess an,
    // der den Socket bindet und ohne Aufräumen endet.
    privaterOrdnerAnlegen(ordner);
    final rest = p.join(ordner, 'moodle.sock');
    final r = Process.runSync('python3', ['-c', 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])', rest]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(FileSystemEntity.typeSync(rest, followLinks: false), FileSystemEntityType.unixDomainSock);
    final l = await kanal.lauschen('moodle');
    addTearDown(l.schliessen);
    await (await kanal.verbinden('moodle')).schliessen();
  }, skip: Platform.isWindows ? 'POSIX' : null);

  test('läuft die App im Konto schon, bricht der zweite Start ab', () async {
    final l = await kanal.lauschen(n('moodle'));
    addTearDown(l.schliessen);
    await expectLater(kanal.lauschen(n('moodle')), throwsA(isA<KanalFehler>()));
    // und der erste lauscht weiter
    await (await kanal.verbinden(n('moodle'))).schliessen();
  });

  test('ein Pfad, der für einen Unix-Socket zu lang ist, weicht auf die nächste Kette aus; die Brücke findet sie', () async {
    final lang = p.join(wurzel.path, 'x' * 60, 'kanal');
    Directory(p.dirname(lang)).createSync(recursive: true);
    Process.runSync('chmod', ['700', p.dirname(lang)]);
    final zwei = UnixKanal(ketten: () => [[p.dirname(lang), lang], [ordner]]);
    final l = await zwei.lauschen('moodle-mit-langem-namen');
    addTearDown(l.schliessen);
    expect(File(p.join(ordner, 'moodle-mit-langem-namen.sock')).existsSync(), isTrue);
    await (await zwei.verbinden('moodle-mit-langem-namen')).schliessen();
    // Nur lange Ketten: Der Start meldet es, statt ohne Kanal zu laufen.
    final nurLang = UnixKanal(ketten: () => [[p.dirname(lang), lang]]);
    await expectLater(nurLang.lauschen('moodle-mit-langem-namen'), throwsA(isA<KanalUnsicher>()));
  }, skip: Platform.isWindows ? 'POSIX' : null);

  test('ein Profilname mit Pfadanteilen bildet keinen Endpunkt', () async {
    await expectLater(kanal.lauschen('../x'), throwsA(isA<KanalFehler>()));
    await expectLater(kanal.verbinden('a/b'), throwsA(isA<KanalFehler>()));
  });

  group('die App weist eine Gegenstelle ab, ohne zu lesen', skip: posix, () {
    test('mit fremder Kennung: nichts kommt an, der Grund wird gemeldet', () async {
      final gruende = <String>[];
      final streng = UnixKanal(ketten: () => [[ordner]], gegenstelle: (s, uid) => 'Die Gegenseite gehört einem anderen Konto.');
      final l = await streng.lauschen('moodle', abgewiesen: gruende.add);
      addTearDown(l.schliessen);
      final angenommen = <KanalVerbindung>[];
      l.verbindungen.listen(angenommen.add);
      // Der Client des Tests prüft die Gegenstelle nicht; er sendet trotzdem.
      final s = await Socket.connect(
        InternetAddress(p.join(ordner, 'moodle.sock'), type: InternetAddressType.unix),
        0,
      );
      unawaited(s.done.then<void>((_) {}, onError: (_) {}));
      try {
        s.write('{"jsonrpc":"2.0","id":1,"method":"tools/call"}\n');
        await s.flush();
      } on SocketException {
        // Die App hat schon geschlossen -- umso besser.
      }
      final ende = await s.toList().timeout(const Duration(seconds: 5)).catchError((_) => <Uint8List>[]); // die App schließt
      expect(ende, isEmpty, reason: 'keine Antwort');
      expect(angenommen, isEmpty);
      expect(gruende, hasLength(1));
      expect(gruende.single, isNot(contains(ordner)));
    });

    test('die echte Prüfung: die Kennung der Gegenseite kommt vom System', () async {
      final gruende = <String>[];
      // Erwartet wird ein anderes Konto als das, dem der Client gehört.
      final streng = UnixKanal(ketten: () => [[ordner]], gegenstelle: (s, uid) => gegenstelleDesKontos(s, uid + 1));
      final l = await streng.lauschen('moodle', abgewiesen: gruende.add);
      addTearDown(l.schliessen);
      final angenommen = <KanalVerbindung>[];
      l.verbindungen.listen(angenommen.add);
      final s = await Socket.connect(
        InternetAddress(p.join(ordner, 'moodle.sock'), type: InternetAddressType.unix),
        0,
      );
      await s.toList().timeout(const Duration(seconds: 5));
      expect(gruende, hasLength(1));
      expect(angenommen, isEmpty);
    });
  });

  group('die Brücke sendet nichts an einen Endpunkt, der nicht dem Konto gehört', skip: posix, () {
    /// Ein Lauscher, der mitzählt, ob je jemand kam.
    Future<(ServerSocket, List<Socket>)> hinter(String pfad) async {
      final s = await ServerSocket.bind(InternetAddress(pfad, type: InternetAddressType.unix), 0);
      final k = <Socket>[];
      s.listen(k.add);
      addTearDown(s.close);
      return (s, k);
    }

    test('Ordner eines anderen Kontos', () async {
      final l = await kanal.lauschen('moodle');
      addTearDown(l.schliessen);
      var gekommen = 0;
      l.verbindungen.listen((_) => gekommen++);
      final bruecke = UnixKanal(ketten: () => [[ordner]], system: _AnderesKonto());
      await expectLater(bruecke.verbinden('moodle'), throwsA(isA<KanalUnsicher>()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(gekommen, 0, reason: 'nicht einmal verbunden');
    });

    test('Ordner mit Rechten für andere', () async {
      Directory(ordner).createSync();
      Process.runSync('chmod', ['755', ordner]);
      final (_, k) = await hinter(p.join(ordner, 'moodle.sock'));
      await expectLater(kanal.verbinden('moodle'), throwsA(isA<KanalUnsicher>()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(k, isEmpty);
    });

    test('Ordner ist eine Verknüpfung auf einen privaten Ordner', () async {
      final echt = p.join(wurzel.path, 'echt');
      privaterOrdnerAnlegen(echt);
      final (_, k) = await hinter(p.join(echt, 'moodle.sock'));
      Link(ordner).createSync(echt);
      await expectLater(kanal.verbinden('moodle'), throwsA(isA<KanalUnsicher>()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(k, isEmpty);
    });

    test('Socket mit Rechten für andere', () async {
      privaterOrdnerAnlegen(ordner);
      final (_, k) = await hinter(p.join(ordner, 'moodle.sock'));
      Process.runSync('chmod', ['666', p.join(ordner, 'moodle.sock')]);
      await expectLater(kanal.verbinden('moodle'), throwsA(isA<KanalUnsicher>()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(k, isEmpty);
    });

    test('der Eintrag ist kein Socket', () async {
      privaterOrdnerAnlegen(ordner);
      File(p.join(ordner, 'moodle.sock')).writeAsStringSync('x');
      await expectLater(kanal.verbinden('moodle'), throwsA(isA<KanalUnsicher>()));
    });

    test('der Server auf der anderen Seite hat eine fremde Kennung: die Verbindung wird verworfen, nichts gesendet', () async {
      privaterOrdnerAnlegen(ordner);
      final (_, k) = await hinter(p.join(ordner, 'moodle.sock'));
      Process.runSync('chmod', ['600', p.join(ordner, 'moodle.sock')]);
      final streng = UnixKanal(ketten: () => [[ordner]], gegenstelle: (s, uid) => 'Die Gegenseite gehört einem anderen Konto.');
      await expectLater(streng.verbinden('moodle'), throwsA(isA<KanalUnsicher>()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // verbunden war es kurz (die Kennung lässt sich nur an einer Verbindung
      // lesen), gelesen hat die Brücke nichts und gesendet nichts.
      for (final s in k) {
        expect(await s.toList().timeout(const Duration(seconds: 5)), isEmpty);
      }
    });

    test('ein unsicherer Ordner vor einem sicheren hindert die Verbindung zum sicheren nicht', () async {
      final fremd = p.join(wurzel.path, 'fremd');
      Directory(fremd).createSync();
      Process.runSync('chmod', ['777', fremd]);
      final (_, kf) = await hinter(p.join(fremd, 'moodle.sock'));
      final l = await kanal.lauschen('moodle');
      addTearDown(l.schliessen);
      final zwei = UnixKanal(ketten: () => [[fremd], [ordner]]);
      final c = await zwei.verbinden('moodle');
      await c.schliessen();
      expect(kf, isEmpty);
    });
  });

  test('Socket eines anderen Kontos in einem eigenen Ordner: nichts wird gesendet', skip: posix, () async {
    final l = await kanal.lauschen('moodle');
    addTearDown(l.schliessen);
    var gekommen = 0;
    l.verbindungen.listen((_) => gekommen++);
    final bruecke = UnixKanal(ketten: () => [[ordner]], rechte: _FremderSocket());
    await expectLater(bruecke.verbinden('moodle'), throwsA(isA<KanalUnsicher>()));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(gekommen, 0);
  });

  group('Werkzeugliste für die Brücke (Linux, Mac)', skip: posix, () {
    final liste = jsonEncode({
      'versionen': ['2025-06-18'],
      'initialize': {'protocolVersion': '2025-06-18'},
      'tools': {'tools': <Object?>[]},
    });

    test('abgelegt im Ordner des Kontos mit 0600, von dort gelesen', () async {
      expect(await kanal.listeLesen('moodle'), isNull, reason: 'noch nichts abgelegt');
      await kanal.listeAblegen('moodle', liste);
      expect(FileStat.statSync(p.join(ordner, 'werkzeugliste-moodle.json')).mode & 0x1ff, 0x180);
      expect(File(p.join(ordner, 'werkzeugliste-moodle.json.neu')).existsSync(), isFalse, reason: 'keine Zwischendatei übrig');
      expect(await kanal.listeLesen('moodle'), liste);
      final bruecke = await werkzeuglisteFuerStart(File('moocp'), 'moodle', ort: kanal);
      expect(bruecke?.versionen, ['2025-06-18']);
    }, skip: Platform.isWindows ? 'Windows fragt die exe' : null);

    test('eine Datei eines anderen Kontos oder mit offenen Rechten wird nicht gelesen', () async {
      await kanal.listeAblegen('moodle', liste);
      final fremd = UnixKanal(ketten: () => [[ordner]], rechte: _FremderSocket());
      expect(await fremd.listeLesen('moodle'), isNull);
      Process.runSync('chmod', ['644', p.join(ordner, 'werkzeugliste-moodle.json')]);
      expect(await kanal.listeLesen('moodle'), isNull);
    });

    test('ein Ordner, der nicht dem Konto allein gehört, liefert keine Liste', () async {
      await kanal.listeAblegen('moodle', liste);
      Process.runSync('chmod', ['755', ordner]);
      expect(await kanal.listeLesen('moodle'), isNull);
    });

    test('Entfernen löscht genau die Liste des Profils; eine fremde Datei bleibt', () async {
      await kanal.listeAblegen('moodle', liste);
      await kanal.listeAblegen('moodle-test', liste);
      await kanal.listeEntfernen('moodle-test');
      expect(await kanal.listeLesen('moodle-test'), isNull);
      expect(await kanal.listeLesen('moodle'), liste);
      await kanal.listeEntfernen('moodle-test'); // gibt es nicht mehr: kein Fehler
      await kanal.listeEntfernen('../x'); // ungültiger Name: nichts geschieht
      final fremd = UnixKanal(ketten: () => [[ordner]], rechte: _FremderSocket());
      await fremd.listeEntfernen('moodle');
      expect(File(p.join(ordner, 'werkzeugliste-moodle.json')).existsSync(), isTrue, reason: 'Datei eines anderen Kontos');
    }, skip: Platform.isWindows ? 'Windows fragt die exe' : null);

    test('je Profil eine eigene Liste: die Brücke liest nur die ihres Profils', () async {
      await kanal.listeAblegen('moodle', liste);
      await kanal.listeAblegen('moodle-test', liste.replaceAll('2025-06-18', '2025-03-26'));
      expect((await werkzeuglisteFuerStart(File('moocp'), 'moodle', ort: kanal))?.versionen, ['2025-06-18']);
      expect((await werkzeuglisteFuerStart(File('moocp'), 'moodle-test', ort: kanal))?.versionen, ['2025-03-26']);
      expect(await werkzeuglisteFuerStart(File('moocp'), 'anderes', ort: kanal), isNull);
      expect(await kanal.listeLesen('../x'), isNull);
    }, skip: Platform.isWindows ? 'Windows fragt die exe' : null);

    test('ohne Datei keine Liste: die Brücke sagt es', () async {
      expect(await werkzeuglisteFuerStart(File('moocp'), 'moodle', ort: kanal), isNull);
    });
  });

  group('kanalOrdnerKetten', skip: posix, () {
    test('Laufzeitordner der Sitzung zuerst, nur wenn er dem Konto allein gehört; dann der Ort im Temp-Bereich', () {
      final system = UnixPrivatSystem();
      final laufzeit = p.join(wurzel.path, 'lauf');
      privaterOrdnerAnlegen(laufzeit);
      final ketten = kanalOrdnerKetten({'XDG_RUNTIME_DIR': laufzeit}, macos: false, temp: '/t', system: system);
      expect(ketten.first, [laufzeit, p.join(laufzeit, 'moocp'), p.join(laufzeit, 'moocp', 'kanal')]);
      expect(ketten.last, ['/t/moocp-${system.uid}', '/t/moocp-${system.uid}/kanal']);

      Process.runSync('chmod', ['755', laufzeit]);
      final ohne = kanalOrdnerKetten({'XDG_RUNTIME_DIR': laufzeit}, macos: false, temp: '/t', system: system);
      expect(ohne.expand((k) => k), isNot(contains(laufzeit)), reason: 'ein offener Laufzeitordner zählt nicht');
    });

    test('ohne die Variable gilt der Ort, an dem systemd den Laufzeitordner anlegt', () {
      final system = _AnderesKonto(); // erfundene Kennung: den Ordner gibt es nicht
      final ketten = kanalOrdnerKetten(const {}, macos: false, temp: '/t', system: system);
      expect(ketten, [['/t/moocp-${system.uid}', '/t/moocp-${system.uid}/kanal']]);
    });

    test('der Ort ohne Laufzeitordner ist fest /tmp, nie das TMPDIR eines Clients', () {
      final system = _AnderesKonto();
      final ketten = kanalOrdnerKetten(const {'TMPDIR': '/anderes/tmp'}, macos: false, system: system);
      expect(ketten, [['/tmp/moocp-${system.uid}', '/tmp/moocp-${system.uid}/kanal']],
          reason: 'App und Brücke finden sich, auch wenn ein Client die Brücke mit anderem TMPDIR startet');
    });

    test('auf dem Mac ein Ordner im Einstellungsordner, nie im Temp-Bereich', () {
      final uid = UnixPrivatSystem().uid;
      expect(kanalOrdnerKetten(const {}, macos: true, einstellungen: '/e/moocp'), [
        ['/e/moocp/kanal'],
        ['/tmp/moocp-$uid', '/tmp/moocp-$uid/kanal'],
      ], reason: 'dahinter der kurze Ort, für lange Benutzer- und Profilnamen');
    });
  });

  // Unter Windows läuft der Kanal über eine Named Pipe (kanal_windows.dart). Sie
  // lässt sich hier nicht öffnen; geprüft wird, was an Namen, Zugriffsliste und
  // Fehlernummern plattformunabhängig ist.
  group('Named Pipe: die reine Logik', () {
    const sid = 'S-1-5-21-1004336348-1177238915-682003330-1000';

    test('der Name trägt SID und Profil, so ist die Pipe je Konto und je Profil eine andere', () {
      expect(pipeName(sid, 'moodle'), r'\\.\pipe\moocp-S-1-5-21-1004336348-1177238915-682003330-1000-moodle');
      expect(pipeName(sid, 'moodle-test'), isNot(pipeName(sid, 'moodle')));
      expect(pipeName('S-1-5-21-1-2-3-1001', 'moodle'), isNot(pipeName(sid, 'moodle')));
    });

    test('die Zugriffsliste erlaubt nur der SID des Kontos etwas, geschützt und ohne Vererbung', () {
      expect(sddlNurKonto(sid), 'D:P(A;;GA;;;$sid)');
      expect(sddlNurKonto(sid), isNot(contains('WD')), reason: 'nicht „Jeder"');
      expect(sddlNurKonto(sid), isNot(contains('BU')));
      expect(sddlNurKonto(sid), isNot(contains('AU')));
    });

    test('nur eine echte SID kommt in Namen und Zugriffsliste', () {
      expect(sidGueltig(sid), isTrue);
      for (final x in ['', 'S-1', 'S-1-5-21-x', 'WD', '(A;;GA;;;WD)', 'S-1-5-21-1-2;D']) {
        expect(sidGueltig(x), isFalse, reason: x);
        expect(() => sddlNurKonto(x), throwsArgumentError, reason: x);
      }
    });

    test('ein Vorgang läuft nur bei STATUS_PENDING (0x103) in OVERLAPPED.Internal; alles andere ist fertig', () {
      expect(overlappedAusstehend(0x103), isTrue);
      expect(overlappedAusstehend(0x00000103 | 0x100000000), isTrue, reason: 'nur die unteren 32 Bit zählen (ULONG_PTR)');
      expect(overlappedAusstehend(0), isFalse, reason: 'STATUS_SUCCESS: fertig');
      expect(overlappedAusstehend(0xC000014B), isFalse, reason: 'STATUS_PIPE_BROKEN: gescheitert, nichts läuft');
      expect(overlappedAusstehend(0xC00000B2), isFalse, reason: 'STATUS_PIPE_CONNECTED: schon verbunden');
      expect(overlappedAusstehend(0xC0000120), isFalse, reason: 'STATUS_CANCELLED: abgebrochen, nichts läuft mehr');
      expect(overlappedAusstehend(0x102), isFalse, reason: 'STATUS_TIMEOUT ist kein „läuft“');
    });

    test('Fehlernummern beim Öffnen: nicht da heißt „App läuft nicht", Zugriff verwehrt heißt „unsicher"', () {
      expect(verbindungsFehlerFuer(2), isA<KanalNichtDa>());
      expect(verbindungsFehlerFuer(3), isA<KanalNichtDa>());
      expect(verbindungsFehlerFuer(5), isA<KanalUnsicher>());
      expect(verbindungsFehlerFuer(231), isNull);
    });
  });
}
