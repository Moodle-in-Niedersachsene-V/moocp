// Brücke und MCP-Dienst über einen echten Kanal (Unix-Socket in einem privaten
// Ordner): Das Profil wählt die Brücke mit ihrem Argument, jedes Profil hat
// seinen eigenen Endpunkt, die Brücke findet die App nach einem Neustart
// wieder, es gibt keinen Port auf 127.0.0.1 und keinen Schlüssel mehr, eine
// Gegenseite mit fremder Kennung wird abgewiesen, bevor sie etwas anfragen
// kann, und das Ende einer Verbindung bricht einen laufenden Aufruf ab (der
// Dialog einer Freigabe schließt sich, E4).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/bruecke.dart';
import 'package:moocp/mcp/kanal.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/mcp/werkzeugquelle.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

class _WartendeQuelle implements WerkzeugQuelle {
  final angefangen = Completer<void>();
  final abgebrochen = Completer<void>();

  @override
  List<WerkzeugBeschreibung> werkzeuge(Profil profil) => [
    const WerkzeugBeschreibung(
      name: 'probe_warten',
      beschreibung: 'Wartet, bis der Aufruf abgebrochen wird.',
      eingabeSchema: {'type': 'object', 'properties': <String, Object?>{}},
    ),
  ];

  @override
  Future<String> aufrufen(WerkzeugAufruf aufruf) async {
    angefangen.complete();
    await aufruf.abbruch;
    abgebrochen.complete();
    return 'abgebrochen';
  }
}

Profil _profil(String kennung, String name, String mcpName, int port) =>
    Profil(kennung: kennung, name: name, adresse: 'https://moodle.schule.example', port: port, mcpName: mcpName);

String zeile(Object n) => '${jsonEncode(n)}\n';

void main() {
  late Directory wurzel;
  late UnixKanal kanal;
  final dienste = <McpDienst>[];
  late Protokoll protokoll;

  setUp(() {
    wurzel = Directory.systemTemp.createTempSync('moocp_bruecke_kanal_');
    kanal = UnixKanal(ketten: () => [[p.join(wurzel.path, 'k')]]);
    protokoll = Protokoll();
  });
  tearDown(() async {
    for (final d in dienste) {
      await d.stoppen();
    }
    dienste.clear();
    wurzel.deleteSync(recursive: true);
  });

  Future<McpDienst> starten(Profil profil, {KanalOrt? ort, List<WerkzeugQuelle> quellen = const []}) async {
    final d = McpDienst(
      Einstellungen(profile: [profil]),
      MoodleZugang(protokoll),
      protokoll,
      Freigaben(protokoll),
      wurzel.path,
      profil: profil,
      kanal: ort ?? kanal,
      werkzeugquellen: quellen,
    );
    dienste.add(d);
    await d.starten();
    return d;
  }

  /// Eine Brücke zum Profil [name], wie ein KI-Werkzeug sie startet.
  ({Bruecke bruecke, StreamController<List<int>> ein, List<Map> aus, Future<void> fertig}) bruecke(
    String name, {
    KanalOrt? ort,
  }) {
    final aus = <Map>[];
    final ein = StreamController<List<int>>();
    final b = Bruecke(
      verbinden: () => (ort ?? kanal).verbinden(name),
      listeHolen: () async => null,
      appStarten: () async => false,
      ausgabe: (z) => aus.add(jsonDecode(z) as Map),
    );
    return (bruecke: b, ein: ein, aus: aus, fertig: b.laufen(ein.stream));
  }

  Future<Map> aufruf(
    ({Bruecke bruecke, StreamController<List<int>> ein, List<Map> aus, Future<void> fertig}) b,
    int id,
    String methode, [
    Map<String, Object?>? params,
  ]) async {
    b.ein.add(utf8.encode(zeile({'jsonrpc': '2.0', 'id': id, 'method': methode, 'params': ?params})));
    for (var i = 0; i < 400; i++) {
      final r = b.aus.where((n) => n['id'] == id);
      if (r.isNotEmpty) return r.first;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('keine Antwort auf $methode');
  }

  Map<String, Object?> anmelden() => {
    'protocolVersion': '2025-06-18',
    'capabilities': <String, Object?>{},
    'clientInfo': {'name': 'test-client', 'version': '1'},
  };

  String text(Map antwort) => ((antwort['result'] as Map)['content'] as List).map((e) => (e as Map)['text']).join('\n');

  test('das Profil wählt die Brücke: --profil moodle-test erreicht nur den Server dieses Profils', () async {
    await starten(_profil('standard', 'Moodle', 'moodle', 47811));
    await starten(_profil('k2', 'Moodle Test', 'moodle-test', 47812));

    final a = bruecke('moodle');
    await aufruf(a, 1, 'initialize', anmelden());
    expect(text(await aufruf(a, 2, 'tools/call', {'name': 'status', 'arguments': <String, Object?>{}})),
        contains('Profil: Moodle (moodle)'));
    final b = bruecke('moodle-test');
    await aufruf(b, 1, 'initialize', anmelden());
    final status = text(await aufruf(b, 2, 'tools/call', {'name': 'status', 'arguments': <String, Object?>{}}));
    expect(status, contains('Profil: Moodle Test (moodle-test)'));
    expect(status, contains('Verbunden über: test-client 1'), reason: 'der Name des KI-Werkzeugs steht weiter im Status');
    await a.ein.close();
    await b.ein.close();
    await Future.wait([a.fertig, b.fertig]);
  });

  test('der Name des KI-Werkzeugs steht im Protokoll', () async {
    await starten(_profil('standard', 'Moodle', 'moodle', 47811));
    final b = bruecke('moodle');
    await aufruf(b, 1, 'initialize', anmelden());
    await aufruf(b, 2, 'tools/call', {'name': 'status', 'arguments': <String, Object?>{}});
    expect(protokoll.eintraege.map((e) => e.text), contains('KI-Werkzeug verbunden: test-client 1'));
    await b.ein.close();
    await b.fertig;
  });

  test('nach einem Neustart der App findet die Brücke sie wieder; der Client merkt nur den Aufruf dazwischen', () async {
    final profil = _profil('standard', 'Moodle', 'moodle', 47811);
    final erste = await starten(profil);
    final b = bruecke('moodle');
    await aufruf(b, 1, 'initialize', anmelden());
    expect(text(await aufruf(b, 2, 'tools/call', {'name': 'status', 'arguments': <String, Object?>{}})), contains('Profil'));

    await erste.stoppen();
    dienste.remove(erste);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await starten(profil);

    final nach = await aufruf(b, 3, 'tools/call', {'name': 'status', 'arguments': <String, Object?>{}});
    expect(text(nach), contains('Profil: Moodle (moodle)'));
    await b.ein.close();
    await b.fertig;
  });

  test('läuft die App nicht, sagt die Brücke es, und ohne Starten bleibt es dabei', () async {
    final b = bruecke('moodle');
    await aufruf(b, 1, 'initialize', anmelden());
    final r = await aufruf(b, 2, 'tools/call', {'name': 'status', 'arguments': <String, Object?>{}});
    expect((r['result'] as Map)['isError'], isTrue);
    await b.ein.close();
    await b.fertig;
  });

  test('es gibt keinen Port auf 127.0.0.1: weder der des Profils noch ein Schlüssel öffnet etwas', () async {
    final frei = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = frei.port;
    await frei.close();
    await starten(_profil('standard', 'Moodle', 'moodle', port));
    // Der Port des Profils ist frei: Er wäre sonst vom MCP-Server belegt.
    final nochmal = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await nochmal.close();
    // Und niemand antwortet dort, auch nicht mit einem Schlüssel von früher.
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    await expectLater(
      () async {
        final r = await http.postUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
        r.headers.set('Authorization', 'Bearer alter-schluessel');
        await r.close();
      }(),
      throwsA(isA<SocketException>()),
    );
  });

  test('eine Gegenseite mit fremder Kennung wird abgewiesen, bevor sie etwas fragen kann', () async {
    final streng = UnixKanal(
      ketten: () => [[p.join(wurzel.path, 'k')]],
      gegenstelle: (s, uid) => gegenstelleDesKontos(s, uid + 1),
    );
    await starten(_profil('standard', 'Moodle', 'moodle', 47811), ort: streng);
    final s = await Socket.connect(
      InternetAddress(p.join(wurzel.path, 'k', 'moodle.sock'), type: InternetAddressType.unix),
      0,
    );
    unawaited(s.done.then<void>((_) {}, onError: (_) {}));
    try {
      s.write(zeile({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': anmelden()}));
      s.write(zeile({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'status', 'arguments': {}}}));
      await s.flush();
    } on SocketException {
      // schon geschlossen
    }
    final bekommen = await s.toList().timeout(const Duration(seconds: 5)).catchError((_) => <Uint8List>[]);
    expect(bekommen, isEmpty, reason: 'weder eine Antwort noch ein Wort über Werkzeuge');
    expect(protokoll.eintraege.where((e) => e.text.contains('MCP-Verbindung abgewiesen')), isNotEmpty);
    expect(protokoll.eintraege.map((e) => e.text), isNot(contains(startsWith('KI-Werkzeug verbunden'))));
  });

  test('endet die Verbindung, bricht der laufende Aufruf ab (ein offener Freigabedialog schließt sich)', () async {
    final quelle = _WartendeQuelle();
    await starten(_profil('standard', 'Moodle', 'moodle', 47811), quellen: [quelle]);
    final b = bruecke('moodle');
    await aufruf(b, 1, 'initialize', anmelden());
    b.ein.add(utf8.encode(zeile({
      'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'probe_warten', 'arguments': <String, Object?>{}},
    })));
    await quelle.angefangen.future.timeout(const Duration(seconds: 5));
    // Der Client beendet die Brücke (sein Zeitlimit, ein Abbruch durch die Lehrkraft).
    await b.ein.close();
    await b.fertig;
    await quelle.abgebrochen.future.timeout(const Duration(seconds: 5));
  });

  test('ein Abbruch des Clients wird an die App weitergegeben', () async {
    final quelle = _WartendeQuelle();
    await starten(_profil('standard', 'Moodle', 'moodle', 47811), quellen: [quelle]);
    final b = bruecke('moodle');
    await aufruf(b, 1, 'initialize', anmelden());
    b.ein.add(utf8.encode(zeile({
      'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'probe_warten', 'arguments': <String, Object?>{}},
    })));
    await quelle.angefangen.future.timeout(const Duration(seconds: 5));
    b.ein.add(utf8.encode(zeile({
      'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': 2, 'reason': 'Zeitlimit'},
    })));
    await quelle.abgebrochen.future.timeout(const Duration(seconds: 5));
    await b.ein.close();
    await b.fertig;
  });
}
