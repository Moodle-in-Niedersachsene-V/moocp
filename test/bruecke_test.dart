// Offline prüfbar: die Brücke für stdio-Clients (lib/mcp/bruecke.dart)
// gegen eine nachgebaute App im Speicher -- Anmeldung auf der Verbindung,
// Nachrichten nebeneinander, Neustart der App (der laufende Aufruf wird nie
// wiederholt), ein Kanal, dem die Brücke nicht traut; initialize und
// tools/list aus der Werkzeugliste, ob die App läuft oder nicht; Start der
// App erst beim Werkzeugaufruf, und kein Aufruf, den der Client abgebrochen
// hat, während die Brücke auf die App wartete. Die Verbindung selbst, ihre
// Prüfungen und den Weg über ein echtes Socket prüft test/kanal_test.dart und
// test/bruecke_kanal_test.dart.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/mcp/bruecke.dart';
import 'package:moocp/mcp/kanal.dart';

/// Die eine Seite einer Verbindung im Speicher.
class _Seite implements KanalVerbindung {
  _Seite(this.eingangQuelle);
  final StreamController<List<int>> eingangQuelle;
  late _Seite gegenueber;
  bool zu = false;

  @override
  Stream<List<int>> get eingang => eingangQuelle.stream;

  @override
  void senden(List<int> daten) {
    if (!gegenueber.zu && !gegenueber.eingangQuelle.isClosed) gegenueber.eingangQuelle.add(daten);
  }

  @override
  Future<void> schliessen() async {
    if (zu) return;
    zu = true;
    unawaited(eingangQuelle.close());
    if (!gegenueber.eingangQuelle.isClosed) unawaited(gegenueber.eingangQuelle.close());
  }
}

/// Eine App, wie die Brücke sie über den Kanal erlebt, so weit sie sie
/// braucht. Merkt sich jede Nachricht, die ankommt.
class Attrappe {
  /// Was bei der App ankommt, je Verbindung eine Liste.
  final verbindungen = <List<Map>>[];
  final _seiten = <_Seite>[];

  /// Die Werkzeuge, die ein `tools/call` aufrief.
  final aufgerufen = <String?>[];

  /// Ob jemand lauscht.
  bool laeuft = true;

  /// Gibt [verbinden] stattdessen [KanalUnsicher] zurück (Ordner, Socket oder
  /// Gegenstelle gehören einem anderen Konto).
  String? unsicher;

  /// Die Anfragen, die nie beantwortet werden (die App wird mitten im Aufruf
  /// beendet).
  final unbeantwortet = <String>{};

  Future<KanalVerbindung> verbinden() async {
    final u = unsicher;
    if (u != null) throw KanalUnsicher(u);
    if (!laeuft) throw KanalNichtDa();
    final brueckenSeite = _Seite(StreamController<List<int>>());
    final appSeite = _Seite(StreamController<List<int>>());
    brueckenSeite.gegenueber = appSeite;
    appSeite.gegenueber = brueckenSeite;
    final empfangen = <Map>[];
    verbindungen.add(empfangen);
    _seiten.add(appSeite);
    appSeite.eingang.transform(utf8.decoder).transform(const LineSplitter()).listen((z) => _antworten(appSeite, empfangen, z));
    return brueckenSeite;
  }

  /// Beendet die App: Alle Verbindungen enden.
  void beenden() {
    laeuft = false;
    for (final s in _seiten) {
      unawaited(s.schliessen());
    }
    _seiten.clear();
  }

  Future<void> _antworten(_Seite s, List<Map> empfangen, String zeile) async {
    final n = jsonDecode(zeile) as Map;
    empfangen.add(n);
    if (n['method'] == 'tools/call') aufgerufen.add((n['params'] as Map?)?['name'] as String?);
    final id = n['id'];
    if (id == null) return;
    if (n['method'] == 'initialize') {
      _senden(s, {'jsonrpc': '2.0', 'id': id, 'result': {'protocolVersion': '2025-06-18'}});
      return;
    }
    if (unbeantwortet.contains(n['method'])) {
      Timer(const Duration(milliseconds: 100), beenden);
      return;
    }
    if (n['method'] == 'langsam') await Future<void>.delayed(const Duration(milliseconds: 300));
    _senden(s, {'jsonrpc': '2.0', 'id': id, 'result': n['method']});
  }

  void _senden(_Seite s, Object daten) => s.senden(utf8.encode('${jsonEncode(daten)}\n'));
}

String zeile(Object n) => '${jsonEncode(n)}\n';
Map anfrage(Object id, String methode, [Map<String, Object?>? params]) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': methode,
  'params': ?params,
};
Map anmelden(Object id, {String version = '2025-06-18'}) => anfrage(id, 'initialize', {
  'protocolVersion': version,
  'capabilities': <String, Object?>{},
  'clientInfo': {'name': 'test', 'version': '1'},
});
const initialisiert = {'jsonrpc': '2.0', 'method': 'notifications/initialized'};

/// Eine Werkzeugliste, wie `moocp.exe --werkzeugliste` sie liefert.
Werkzeugliste werkzeugliste([List<Map<String, Object?>>? tools]) => Werkzeugliste(
  versionen: ['2025-11-25', '2025-06-18', '2025-03-26'],
  initialize: {
    'protocolVersion': '2025-11-25',
    'capabilities': {'tools': <String, Object?>{}},
    'serverInfo': {'name': 'moocp', 'version': '0.3.0'},
  },
  tools: {
    'tools':
        tools ??
        [
          {'name': 'status'},
        ],
  },
);

void main() {
  late Attrappe app;
  setUp(() => app = Attrappe());

  /// Lässt die Brücke über [eingaben] laufen; wartet zwischen zwei Eingaben
  /// kurz, damit ihre Reihenfolge feststeht. Eine Funktion unter den Eingaben
  /// wird an ihrer Stelle ausgeführt. Liefert, was der Client bekommt.
  Future<List<Map>> laufen(
    List<Object> eingaben, {
    Future<Werkzeugliste?> Function()? listeHolen,
    Future<bool> Function()? appStarten,
    Duration aufAppWarten = const Duration(seconds: 5),
  }) async {
    final aus = <Map>[];
    final ein = StreamController<List<int>>();
    final b = Bruecke(
      verbinden: app.verbinden,
      listeHolen: listeHolen ?? () async => werkzeugliste(),
      appStarten: appStarten ?? () async => fail('die App darf hier nicht starten'),
      aufAppWarten: aufAppWarten,
      ausgabe: (z) {
        expect(z, isNot(contains('\n')), reason: 'über stdio eine Nachricht je Zeile');
        aus.add(jsonDecode(z) as Map);
      },
    );
    final fertig = b.laufen(ein.stream);
    for (final e in eingaben) {
      if (e is void Function()) {
        e();
      } else {
        ein.add(utf8.encode(e is String ? e : zeile(e)));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }
    await ein.close();
    await fertig;
    return aus;
  }

  /// Die Methoden, die bei der App ankamen, je Verbindung.
  List<List<Object?>> methoden() => [
    for (final v in app.verbindungen) [for (final n in v) n['method']],
  ];

  group('Profil als Argument', () {
    test('ohne Angabe das Standardprofil', () => expect(profilAusArgumenten(const []), 'moodle'));
    test('--profil nennt das Profil', () {
      expect(profilAusArgumenten(const ['--profil', 'moodle-test']), 'moodle-test');
    });
    test('fehlender oder ungeeigneter Name: null, nichts wird verbunden', () {
      expect(profilAusArgumenten(const ['--profil']), isNull);
      expect(profilAusArgumenten(const ['--profil', '../x']), isNull);
      expect(profilAusArgumenten(const ['--profil', 'A b']), isNull);
      expect(profilAusArgumenten(const ['--profil', '']), isNull);
    });
  });

  group('App läuft', () {
    test('initialize und tools/list aus der Liste, die App nur für den Werkzeugaufruf, angemeldet von der Brücke', () async {
      final aus = await laufen([anmelden(1), initialisiert, anfrage(2, 'tools/list'), anfrage(3, 'tools/call')]);
      expect(aus.map((n) => n['id']), [1, 2, 3]);
      expect(aus[1]['result'], werkzeugliste().tools);
      expect(aus[2]['result'], 'tools/call');
      expect(methoden(), [
        ['initialize', 'notifications/initialized', 'tools/call'],
      ]);
      expect(app.verbindungen.single.first['id'], 'moocp-bruecke-anmeldung');
      expect(app.verbindungen.single.first['params']['clientInfo']['name'], 'test', reason: 'das initialize des Clients');
    });

    test('Nachrichten laufen nebeneinander: eine lange hält keine kurze auf', () async {
      final aus = await laufen([anmelden(1), anfrage(2, 'langsam'), anfrage(3, 'schnell')]);
      expect(aus.map((n) => n['id']), [1, 3, 2]);
    });

    test('ping beantwortet die Brücke selbst', () async {
      final aus = await laufen([anmelden(1), anfrage(2, 'ping')]);
      expect(aus.last, {'jsonrpc': '2.0', 'id': 2, 'result': {}});
      expect(app.verbindungen, isEmpty, reason: 'die App wurde nicht einmal angesprochen');
    });

    test('die Verbindung endet mit dem Client', () async {
      final aus = await laufen([anmelden(1), anfrage(2, 'tools/call')]);
      expect(aus.last['id'], 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Die Seite der App sieht das Ende ihres Eingangs.
      expect(app.verbindungen, hasLength(1));
    });

    test('App neu gestartet: neu anmelden, der Client merkt davon bei der nächsten Anfrage nichts', () async {
      final aus = await laufen([
        anmelden(1),
        initialisiert,
        anfrage(2, 'tools/call'),
        // Neustart: Die Verbindung endet, die neue App lauscht gleich wieder.
        () {
          app.beenden();
          app.laeuft = true;
        },
        anfrage(3, 'tools/call'),
      ]);
      expect(aus.map((n) => n['id']), [1, 2, 3]);
      expect(aus.last['result'], 'tools/call');
      expect(methoden().map((m) => m.first), ['initialize', 'initialize'], reason: 'neu angemeldet');
      expect(methoden().last, ['initialize', 'notifications/initialized', 'tools/call']);
    });

    test('App endet mitten im Aufruf: Fehlerantwort, der Aufruf wird nie wiederholt', () async {
      app.unbeantwortet.add('tools/call');
      final aus = await laufen([
        anmelden(1),
        anfrage(2, 'tools/call', {'name': 'aendern'}),
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      ]);
      expect(aus.last['id'], 2);
      expect(aus.last['error']['message'], contains('abgerissen'));
      expect(app.aufgerufen, ['aendern'], reason: 'genau einmal bei der App, nie ein zweites Mal');
      expect(methoden(), hasLength(1), reason: 'auch keine neue Verbindung dafür');
    });

    test('kaputte Zeile: Parse-Fehler ohne id', () async {
      final aus = await laufen(['{kein json\n']);
      expect(aus.single['id'], isNull);
      expect(aus.single['error']['code'], -32700);
    });
  });

  group('Ein Kanal, dem die Brücke nicht traut', () {
    test('Werkzeugaufruf: der Grund als Ergebnis, es wurde nichts gesendet, die App nicht gestartet', () async {
      app.unsicher = 'Der Ordner für den Kanal gehört einem anderen Konto.';
      final aus = await laufen([anmelden(1), anfrage(2, 'tools/call', {'name': 'aendern', 'arguments': {'x': 1}})]);
      expect(aus.last['id'], 2);
      expect(aus.last['result']['isError'], isTrue);
      final text = aus.last['result']['content'].single['text'] as String;
      expect(text, contains('nicht sicher'));
      expect(text, contains('nichts gesendet'));
      expect(app.verbindungen, isEmpty);
      expect(app.aufgerufen, isEmpty);
    });

    test('auch die Anmeldung geht nicht hinaus: kein initialize bei der App', () async {
      app.unsicher = 'Die Gegenseite gehört einem anderen Konto.';
      await laufen([anmelden(1), initialisiert, anfrage(2, 'tools/call')]);
      expect(app.verbindungen, isEmpty);
    });

    test('ein ungültiges Profil: jede Anfrage bekommt den Grund, nichts wird verbunden', () async {
      final aus = <Map>[];
      final ein = StreamController<List<int>>();
      final b = Bruecke(
        verbinden: () async => throw KanalFehler('Der Profilname der Brücke (--profil) ist ungültig.'),
        listeHolen: () async => werkzeugliste(),
        appStarten: () async => fail('nicht starten'),
        ausgabe: (z) => aus.add(jsonDecode(z) as Map),
      );
      final fertig = b.laufen(ein.stream);
      ein.add(utf8.encode(zeile(anmelden(1))));
      ein.add(utf8.encode(zeile(anfrage(2, 'tools/call'))));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await ein.close();
      await fertig;
      expect(aus.last['result']['content'].single['text'], contains('ungültig'));
    });
  });

  group('App läuft nicht', () {
    setUp(() => app.laeuft = false);

    test('initialize, tools/list und ping kommen von der Brücke, ohne die App zu starten', () async {
      var geholt = 0;
      final r = await laufen(
        [anmelden(1), initialisiert, anfrage(2, 'ping'), anfrage(3, 'tools/list')],
        listeHolen: () async {
          geholt++;
          return werkzeugliste();
        },
      );
      // ping wartet auf nichts, auch nicht auf initialize.
      expect(r.map((n) => n['id']).where((id) => id != 2), [1, 3]);
      expect(r.firstWhere((n) => n['id'] == 2)['result'], {});
      expect(r.firstWhere((n) => n['id'] == 1)['result'], {
        'protocolVersion': '2025-06-18',
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'moocp', 'version': '0.3.0'},
      }, reason: 'die Version, die der Client verlangt, wenn die App sie kann');
      expect(r.firstWhere((n) => n['id'] == 3)['result'], werkzeugliste().tools);
      expect(geholt, 2, reason: 'je Anfrage frisch von der exe, durchgereicht');
    });

    test('eine Version, die die App nicht kann: ihre erste', () async {
      final r = await laufen([anmelden(1, version: '2099-01-01')]);
      expect(r.single['result']['protocolVersion'], '2025-11-25');
    });

    test('ohne Werkzeugliste (moocp fehlt): Fehler statt Schweigen', () async {
      final r = await laufen([anmelden(1)], listeHolen: () async => null);
      expect(r.single['error']['message'], contains('gibt seine Werkzeuge nicht heraus'));
    });

    test('Werkzeugaufruf: startet die App, wartet auf sie und reicht weiter', () async {
      var gestartet = 0;
      final r = await laufen(
        [anmelden(1), initialisiert, anfrage(2, 'tools/list'), anfrage(3, 'tools/call')],
        appStarten: () async {
          gestartet++;
          Timer(const Duration(milliseconds: 300), () => app.laeuft = true);
          return true;
        },
      );
      expect(gestartet, 1);
      expect(r.last, {'jsonrpc': '2.0', 'id': 3, 'result': 'tools/call'});
      expect(methoden().single, containsAllInOrder(['initialize', 'notifications/initialized']));
    });

    test('ein Werkzeug eines Plugins steht in der Liste, auch wenn die App zu ist; der Aufruf geht an die App, sobald sie läuft', () async {
      final echo = {
        'name': 'beispiel_echo',
        'description': 'Gibt den Text zurück.',
        'inputSchema': {'type': 'object'},
      };
      var gestartet = 0;
      final r = await laufen(
        [
          anmelden(1),
          initialisiert,
          anfrage(2, 'tools/list'),
          anfrage(3, 'tools/call', {
            'name': 'beispiel_echo',
            'arguments': {'text': 'Hallo'},
          }),
        ],
        listeHolen: () async => werkzeugliste([
          {'name': 'status'},
          echo,
        ]),
        appStarten: () async {
          gestartet++;
          Timer(const Duration(milliseconds: 300), () => app.laeuft = true);
          return true;
        },
      );

      expect(r.map((n) => n['id']), [1, 2, 3], reason: 'die Liste kommt, bevor die App läuft');
      expect(r.firstWhere((n) => n['id'] == 2)['result']['tools'], [
        {'name': 'status'},
        echo,
      ]);
      expect(gestartet, 1, reason: 'gestartet wird die App erst für den Aufruf');
      expect(app.aufgerufen, ['beispiel_echo'], reason: 'der Aufruf geht unverändert an die App');
      expect(r.last, {'jsonrpc': '2.0', 'id': 3, 'result': 'tools/call'});
    });

    test('Werkzeugaufruf, den der Client abbricht, während die Brücke auf die App wartet: geht nicht hinaus',
        () async {
      final r = await laufen(
        [
          anmelden(1),
          anfrage(2, 'tools/call'),
          {
            'jsonrpc': '2.0',
            'method': 'notifications/cancelled',
            'params': {'requestId': 2, 'reason': 'Zeitlimit'},
          },
        ],
        appStarten: () async {
          Timer(const Duration(milliseconds: 300), () => app.laeuft = true);
          return true;
        },
      );
      expect(r.map((n) => n['id']), [1], reason: 'keine Antwort auf den abgebrochenen Aufruf');
      expect(methoden().expand((m) => m), contains('initialize'), reason: 'die App ist gestartet und verbunden');
      expect(methoden().expand((m) => m), isNot(contains('tools/call')), reason: 'der Aufruf ging nicht hinaus');
    });

    test('Werkzeugaufruf, die App wird nicht bereit: der Grund als Ergebnis des Werkzeugs', () async {
      final r = await laufen(
        [anmelden(1), anfrage(2, 'tools/call')],
        appStarten: () async => true,
        aufAppWarten: const Duration(milliseconds: 400),
      );
      expect(r.last['id'], 2);
      expect(r.last['result']['isError'], isTrue);
      expect(r.last['result']['content'].single['text'], contains('noch nicht bereit'));
    });

    test('Werkzeugaufruf, moocp lässt sich nicht starten: das sagt das Ergebnis', () async {
      final r = await laufen([anmelden(1), anfrage(2, 'tools/call')], appStarten: () async => false);
      expect(r.last['result']['isError'], isTrue);
      expect(r.last['result']['content'].single['text'], contains('ließ sich nicht starten'));
    });

    test('andere Anfragen starten die App nicht', () async {
      final r = await laufen([anmelden(1), anfrage(2, 'resources/list')]);
      expect(r.last['error']['message'], contains('läuft nicht'));
    });

    test('die Werkzeugliste aus JSON, wie main.dart sie schreibt', () {
      final l = werkzeugliste();
      expect(Werkzeugliste.ausJson(jsonDecode(jsonEncode(l.toJson())))!.toJson(), l.toJson());
      expect(Werkzeugliste.ausJson({'versionen': []}), isNull);
      expect(Werkzeugliste.ausJson('kaputt'), isNull);
    });
  });
}
