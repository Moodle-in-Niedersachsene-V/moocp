// Die Adresse der App für Plugins (E35): Anmeldung mit dem Schlüssel des
// Plugins, das Token eines laufenden Aufrufs, Host und Origin, und die drei
// Funktionen Protokollzeile, Arbeitsordner und eingebautes Werkzeug. Auf der
// anderen Seite steht hier ein HTTP-Client im Test an Stelle eines Plugins;
// das echte Beispiel-Plugin als Prozess prüft test/plugin_start_test.dart.
// Alles in Temp-Ordnern, nie im Einstellungsordner der App.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/mcp/werkzeug_aufrufe.dart';
import 'package:moocp/mcp/werkzeugquelle.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/plugin/app_adresse.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'testbetrieb_mcp_test.dart' show TestMoodle;

const _schluessel = 'schluessel-des-beispiels-0123456789abcdefghijkl';
const _fremderSchluessel = 'schluessel-eines-anderen-plugins-0123456789abc';

Profil _profil(String kennung, String name) => Profil(
  kennung: kennung,
  name: name,
  adresse: 'https://$kennung.moodle.schule.example',
  port: 1,
  mcpName: name.toLowerCase(),
  schluessel: 'test',
);

/// Ein Profil, wie es die Adresse sieht: Protokoll, Arbeitsordner und
/// eingebaute Werkzeuge. [werkzeug] bestimmt, was ein eingebautes Werkzeug
/// tut; ohne gibt es seinen Namen zurück.
class _Kontext implements AufrufKontext {
  _Kontext(this.protokoll, this.arbeitsordner, {this.werkzeug});

  @override
  final Protokoll protokoll;
  @override
  final String arbeitsordner;
  final Future<EingebautErgebnis> Function(String name, Future<void> abbruch)? werkzeug;

  final aufgerufen = <({String name, Map<String, dynamic> args, String aufrufer})>[];

  @override
  Future<EingebautErgebnis> eingebautAufrufen(
    String name,
    Map<String, dynamic> args, {
    required Future<void> abbruch,
    required String aufrufer,
  }) {
    aufgerufen.add((name: name, args: args, aufrufer: aufrufer));
    final w = werkzeug;
    return w != null ? w(name, abbruch) : Future.value((text: 'Antwort von $name', fehlgeschlagen: false));
  }
}

/// Eine Anfrage wie von einem Plugin; liefert Status und JSON der Antwort.
Future<({int status, Map json})> _post(
  Uri adresse,
  String pfad, {
  Object? daten = const <String, Object?>{},
  String? schluessel = _schluessel,
  String? token,
  String? host,
  String? origin,
  String methode = 'POST',
  List<int>? roh,
}) async {
  final http = HttpClient();
  try {
    final r = await http.openUrl(methode, adresse.resolve(pfad));
    if (schluessel != null) r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $schluessel');
    if (token != null) r.headers.set(aufrufKopf, token);
    if (host != null) r.headers.host = host;
    if (origin != null) r.headers.set('Origin', origin);
    r.headers.contentType = ContentType.json;
    if (methode == 'POST') r.add(roh ?? utf8.encode(jsonEncode(daten)));
    final antwort = await r.close();
    final text = await utf8.decoder.bind(antwort).join();
    return (status: antwort.statusCode, json: text.isEmpty ? const {} : jsonDecode(text) as Map);
  } finally {
    http.close(force: true);
  }
}

/// Ein Aufruf eines Werkzeugs des Plugins, wie ihn die laufenden Plugins
/// anmelden.
WerkzeugAufruf _aufruf(AufrufKontext kontext, {Future<void>? abbruch}) => WerkzeugAufruf(
  name: 'beispiel_echo',
  args: const {},
  profil: _profil('standard', 'Moodle'),
  token: aufrufToken(),
  abbruch: abbruch ?? Completer<void>().future,
  kontext: kontext,
);

void main() {
  late Directory wurzel;
  late Protokoll protokoll;
  late AppAdresse adresse;

  setUp(() async {
    wurzel = Directory.systemTemp.createTempSync('moocp_adresse_');
    protokoll = Protokoll();
    adresse = await AppAdresse.starten(protokoll);
    adresse.pluginAnmelden('beispiel', 'Beispiel', _schluessel);
  });

  tearDown(() async {
    await adresse.beenden();
    wurzel.deleteSync(recursive: true);
  });

  List<String> zeilen() => [for (final e in protokoll.eintraege) e.text];

  _Kontext kontext(String name, {Future<EingebautErgebnis> Function(String, Future<void>)? werkzeug}) =>
      _Kontext(protokoll.fuer(name), (Directory(p.join(wurzel.path, name))..createSync()).path, werkzeug: werkzeug);

  group('Anmeldung', () {
    test('ohne Schlüssel und mit falschem Schlüssel: 401, ohne Auskunft, was es gibt', () async {
      for (final s in [null, 'falsch', '']) {
        for (final pfad in [pfadProtokoll, pfadWerkzeug, '/gibt-es-nicht']) {
          final r = await _post(adresse.adresse, pfad, daten: {'text': 'x'}, schluessel: s);
          expect(r.status, 401, reason: '$s $pfad');
          expect(r.json, {'fehler': 'Nicht angemeldet.'});
        }
      }
      expect(zeilen(), contains('Anfrage an die Adresse der App für Plugins ohne gültigen Schlüssel abgewiesen'));
      expect(zeilen(), isNot(contains(contains('Plugin „Beispiel“: x'))));
    });

    test('mit Schlüssel: unbekannte Pfade 404, andere Methoden als POST 405', () async {
      expect((await _post(adresse.adresse, '/v1/gibt-es-nicht')).status, 404);
      expect((await _post(adresse.adresse, '/protokoll')).status, 404);
      expect((await _post(adresse.adresse, pfadProtokoll, methode: 'GET')).status, 405);
    });

    test('der Schlüssel eines anderen Plugins kommt nicht an das Token dieses Plugins', () async {
      adresse.pluginAnmelden('anderes', 'Anderes', _fremderSchluessel);
      final k = kontext('A');
      final a = _aufruf(k);
      adresse.aufrufAnmelden('beispiel', a);

      final fremd = await _post(adresse.adresse, pfadArbeitsordner, schluessel: _fremderSchluessel, token: a.token);
      final protokollFremd = await _post(
        adresse.adresse,
        pfadProtokoll,
        daten: {'text': 'untergeschoben'},
        schluessel: _fremderSchluessel,
        token: a.token,
      );
      final eigen = await _post(adresse.adresse, pfadArbeitsordner, token: a.token);

      expect(fremd.status, 403);
      expect(protokollFremd.status, 403, reason: 'auch die Protokollzeile nicht mit einem fremden Token');
      expect(eigen.status, 200);
      expect(zeilen(), isNot(contains(contains('untergeschoben'))));
      expect(k.aufgerufen, isEmpty);
    });

    test('nach einem neuen Start gilt nur der neue Schlüssel; abgemeldet gilt keiner', () async {
      adresse.pluginAnmelden('beispiel', 'Beispiel', 'neuer-schluessel-0123456789abcdefghijklmnop');

      expect((await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'alt'})).status, 401);
      expect(
        (await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'neu'}, schluessel: 'neuer-schluessel-0123456789abcdefghijklmnop')).status,
        200,
      );
      // Das Abmelden mit dem alten Schlüssel nimmt den neuen nicht mit.
      adresse.pluginAbmelden('beispiel', _schluessel);
      expect(
        (await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'neu'}, schluessel: 'neuer-schluessel-0123456789abcdefghijklmnop')).status,
        200,
      );
      adresse.pluginAbmelden('beispiel', 'neuer-schluessel-0123456789abcdefghijklmnop');
      expect(
        (await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'weg'}, schluessel: 'neuer-schluessel-0123456789abcdefghijklmnop')).status,
        401,
      );
    });

    test('Host und Origin wie beim MCP-Server', () async {
      final port = adresse.adresse.port;
      expect((await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'x'}, host: 'moodle.schule.example')).status, 403);
      expect((await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'x'}, origin: 'https://moodle.schule.example')).status, 403);
      expect((await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'x'}, origin: 'null')).status, 403);
      expect((await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'x'}, host: 'localhost')).status, 200);
      expect((await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'x'}, origin: 'http://127.0.0.1:$port')).status, 200);
      expect(zeilen(), contains('Anfrage an die Adresse der App für Plugins abgewiesen (Host oder Origin)'));
    });

    test('der Server lauscht nur auf 127.0.0.1', () {
      expect(adresse.adresse.host, '127.0.0.1');
    });

    test('Schlüssel und Token stehen in keinem Protokoll und keiner Antwort', () async {
      final a = _aufruf(kontext('A'));
      final ende = adresse.aufrufAnmelden('beispiel', a);
      final antworten = [
        await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'eins'}, token: a.token),
        await _post(adresse.adresse, pfadArbeitsordner, token: a.token),
        await _post(adresse.adresse, pfadWerkzeug, daten: {'name': 'status'}, token: a.token),
        await _post(adresse.adresse, pfadWerkzeug, daten: {'name': 'status'}, token: 'erfunden'),
        await _post(adresse.adresse, pfadWerkzeug, daten: {'name': 'status'}, schluessel: 'falsch'),
      ];
      ende();
      final alles = '${zeilen().join('\n')}\n${antworten.map((r) => jsonEncode(r.json)).join('\n')}';
      expect(alles, isNot(contains(_schluessel)));
      expect(alles, isNot(contains(a.token)));
      expect(alles, isNot(contains('erfunden')));
    });
  });

  group('Das Token des Aufrufs', () {
    test('ohne Token: nur die Protokollzeile, ins Protokoll der App; alles andere 403', () async {
      final r = await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'ohne Aufruf'});
      final ordner = await _post(adresse.adresse, pfadArbeitsordner);
      final werkzeug = await _post(adresse.adresse, pfadWerkzeug, daten: {'name': 'status'});

      expect(r.status, 200);
      expect(zeilen(), contains('Plugin „Beispiel“: ohne Aufruf'));
      expect(ordner.status, 403);
      expect(werkzeug.status, 403);
      expect(ordner.json['fehler'], contains('Moocp-Aufruf'));
      expect(zeilen(), contains('Plugin „Beispiel“: Anfrage an /v1/arbeitsordner ohne gültiges Aufruf-Token abgewiesen'));
    });

    test('nach dem Ende des Aufrufs gilt das Token nicht mehr', () async {
      final a = _aufruf(kontext('A'));
      final ende = adresse.aufrufAnmelden('beispiel', a);
      expect((await _post(adresse.adresse, pfadArbeitsordner, token: a.token)).status, 200);

      ende();

      final danach = await _post(adresse.adresse, pfadArbeitsordner, token: a.token);
      expect(danach.status, 403);
      expect(danach.json['fehler'], contains('keinem laufenden Aufruf'));
      expect((await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'spät'}, token: a.token)).status, 403);
    });

    test('nach dem Abbruch durch den Client gilt das Token nicht mehr', () async {
      final abbruch = Completer<void>();
      final a = _aufruf(kontext('A'), abbruch: abbruch.future);
      adresse.aufrufAnmelden('beispiel', a);

      abbruch.complete();
      await Future<void>.delayed(Duration.zero);

      expect((await _post(adresse.adresse, pfadArbeitsordner, token: a.token)).status, 403);
    });

    test('das Token wählt das Profil: Protokoll und Arbeitsordner je Profil und Plugin', () async {
      protokoll.profilnamenZeigen = true;
      final a = kontext('A');
      final b = kontext('B');
      final aufrufA = _aufruf(a);
      final aufrufB = _aufruf(b);
      adresse.aufrufAnmelden('beispiel', aufrufA);
      adresse.aufrufAnmelden('beispiel', aufrufB);

      await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'für A'}, token: aufrufA.token);
      await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'für B'}, token: aufrufB.token);
      final ordnerA = await _post(adresse.adresse, pfadArbeitsordner, token: aufrufA.token);
      final ordnerB = await _post(adresse.adresse, pfadArbeitsordner, token: aufrufB.token);
      await _post(adresse.adresse, pfadWerkzeug, daten: {'name': 'status'}, token: aufrufB.token);

      expect(zeilen(), containsAllInOrder(['[A] Plugin „Beispiel“: für A', '[B] Plugin „Beispiel“: für B']));
      expect(ordnerA.json['pfad'], p.join(wurzel.path, 'A', 'plugin-beispiel'));
      expect(ordnerB.json['pfad'], p.join(wurzel.path, 'B', 'plugin-beispiel'));
      expect(Directory(ordnerA.json['pfad'] as String).existsSync(), isTrue);
      expect(Directory(ordnerB.json['pfad'] as String).existsSync(), isTrue);
      expect(a.aufgerufen, isEmpty);
      expect(b.aufgerufen.single.name, 'status');
    });
  });

  group('Die Protokollzeile', () {
    test('einzeilig, ohne Steuerzeichen, mit dem Namen des Plugins davor', () async {
      final r = await _post(
        adresse.adresse,
        pfadProtokoll,
        daten: {'text': 'erste\nzweite\r\n\tdritte\u001b[31m${String.fromCharCode(0x2028)}vierte${String.fromCharCode(0x202e)}umgedreht  '},
      );

      expect(r.status, 200);
      expect(protokoll.eintraege.last.text, 'Plugin „Beispiel“: erste zweite dritte [31m vierte umgedreht');
      expect(protokoll.eintraege.last.art, Art.info);
    });

    test('in der Länge begrenzt', () async {
      await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'x' * 2000});

      final zeile = protokoll.eintraege.last.text;
      expect(zeile, startsWith('Plugin „Beispiel“: xxx'));
      expect(zeile.length, 'Plugin „Beispiel“: '.length + protokollzeileHoechstens);
      expect(zeile, endsWith('…'));
    });

    test('ohne Text, kein JSON, kein Objekt, zu groß: abgelehnt mit deutschem Satz', () async {
      expect((await _post(adresse.adresse, pfadProtokoll, daten: {'text': ' \n '})).status, 400);
      expect((await _post(adresse.adresse, pfadProtokoll, daten: {'text': 3})).status, 400);
      expect((await _post(adresse.adresse, pfadProtokoll, roh: utf8.encode('{kein json'))).status, 400);
      expect((await _post(adresse.adresse, pfadProtokoll, daten: ['text'])).status, 400);
      final gross = await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'x' * (1024 * 1024 + 10)});
      expect(gross.status, 413);
      expect(gross.json['fehler'], contains('größer als'));
      expect(zeilen(), isNot(contains(startsWith('Plugin „Beispiel“: '))));
    });
  });

  group('Ein eingebautes Werkzeug über die Adresse', () {
    test('Name und Argumente gehen an das Profil des Aufrufs, mit dem Plugin als Aufrufer', () async {
      final k = kontext('A');
      final a = _aufruf(k);
      adresse.aufrufAnmelden('beispiel', a);

      final r = await _post(
        adresse.adresse,
        pfadWerkzeug,
        daten: {
          'name': 'meine_kurse',
          'argumente': {'zuletzt': true},
        },
        token: a.token,
      );

      expect(r.status, 200);
      expect(r.json, {'text': 'Antwort von meine_kurse', 'fehlgeschlagen': false});
      expect(k.aufgerufen.single.args, {'zuletzt': true});
      expect(k.aufgerufen.single.aufrufer, 'Plugin „Beispiel“');
    });

    test('ohne Namen oder mit Argumenten, die kein Objekt sind: 400', () async {
      final a = _aufruf(kontext('A'));
      adresse.aufrufAnmelden('beispiel', a);
      expect((await _post(adresse.adresse, pfadWerkzeug, daten: <String, Object?>{}, token: a.token)).status, 400);
      expect(
        (await _post(adresse.adresse, pfadWerkzeug, daten: {'name': 'status', 'argumente': [1]}, token: a.token)).status,
        400,
      );
    });

    test('endet der äußere Aufruf durch Abbruch, endet auch der innere: 409, und der Abbruch kommt an', () async {
      final angekommen = Completer<void>();
      final innererAbbruch = Completer<void>();
      final k = kontext('A', werkzeug: (name, abbruch) async {
        angekommen.complete();
        await abbruch;
        innererAbbruch.complete();
        return (text: 'zu spät', fehlgeschlagen: false);
      });
      final abbruch = Completer<void>();
      final a = _aufruf(k, abbruch: abbruch.future);
      adresse.aufrufAnmelden('beispiel', a);

      final antwort = _post(adresse.adresse, pfadWerkzeug, daten: {'name': 'status'}, token: a.token);
      await angekommen.future.timeout(const Duration(seconds: 5));
      abbruch.complete();

      final r = await antwort.timeout(const Duration(seconds: 5));
      expect(r.status, 409);
      expect(r.json['fehler'], startsWith('Abgebrochen'));
      await innererAbbruch.future.timeout(const Duration(seconds: 5));
    });
  });

  group('Über den MCP-Dienst eines Profils', () {
    late MoodleZugang moodle;
    late Freigaben freigaben;
    late McpDienst dienst;
    late Protokoll ansicht;

    setUp(() {
      ansicht = protokoll.fuer('A');
      moodle = MoodleZugang(ansicht);
      freigaben = Freigaben(ansicht);
      dienst = McpDienst(
        Einstellungen(schluessel: 'test'),
        moodle,
        ansicht,
        freigaben,
        (Directory(p.join(wurzel.path, 'A'))..createSync()).path,
        profil: _profil('a', 'A'),
        werkzeugquellen: [_EineQuelle()],
      );
    });

    test('status läuft wie für ein KI-Werkzeug, im Protokoll mit dem Plugin als Aufrufer', () async {
      final a = _aufruf(dienst);
      adresse.aufrufAnmelden('beispiel', a);

      final r = await _post(adresse.adresse, pfadWerkzeug, daten: {'name': 'status'}, token: a.token);

      expect(r.status, 200);
      expect(r.json['fehlgeschlagen'], false);
      expect(r.json['text'], contains('Angemeldet: nein -- bitte in der App anmelden'));
      expect(r.json['text'], contains('Profil: A (a)'));
      expect(zeilen(), contains('[A] status({}) -- Aufrufer: Plugin „Beispiel“'));
    });

    test('Werkzeuge eines Plugins, auch die eigenen, lassen sich über die Adresse nicht aufrufen', () async {
      final a = _aufruf(dienst);
      adresse.aufrufAnmelden('beispiel', a);

      final eigen = await _post(adresse.adresse, pfadWerkzeug, daten: {'name': 'beispiel_echo'}, token: a.token);
      final unbekannt = await _post(adresse.adresse, pfadWerkzeug, daten: {'name': 'gibt_es_nicht'}, token: a.token);

      expect(eigen.status, 400);
      expect(eigen.json['fehler'], contains('„beispiel_echo“ ist kein eingebautes Werkzeug von moocp'));
      expect(eigen.json['fehler'], contains('auch nicht die eigenen'));
      expect(unbekannt.status, 400);
      expect(zeilen(), isNot(contains(startsWith('beispiel_echo('))));
    });

    test('ungültige Argumente prüft dasselbe Schema wie bei einem KI-Werkzeug', () async {
      final a = _aufruf(dienst);
      adresse.aufrufAnmelden('beispiel', a);

      final r = await _post(
        adresse.adresse,
        pfadWerkzeug,
        daten: {
          'name': 'meine_kurse',
          'argumente': {'zuletzt': 'ja'},
        },
        token: a.token,
      );

      expect(r.status, 200);
      expect(r.json['fehlgeschlagen'], true);
      expect(r.json['text'], contains('Ungültige Argumente für „meine_kurse“'));
    });

    test('nicht angemeldet: der Fehler, den ein KI-Werkzeug bekäme', () async {
      final a = _aufruf(dienst);
      adresse.aufrufAnmelden('beispiel', a);

      final r = await _post(adresse.adresse, pfadWerkzeug, daten: {'name': 'meine_kurse'}, token: a.token);

      expect(r.status, 200);
      expect(r.json['fehlgeschlagen'], true);
      expect(r.json['text'], contains('Nicht angemeldet'));
    });
  });

  group('Freigaben eines eingebauten Werkzeugs, das ein Plugin aufruft', () {
    late TestMoodle extern;
    late Directory ordner;
    late Protokoll ansicht;
    late Freigaben freigaben;
    late McpDienst dienst;

    setUp(() async {
      extern = TestMoodle();
      await extern.starten();
      ordner = Directory(p.join(wurzel.path, 'profil'))..createSync();
      Directory(p.join(ordner.path, 'entwurf')).createSync();
      File(p.join(ordner.path, 'entwurf', 'page.html')).writeAsStringSync(extern.inhalt);
      ansicht = protokoll.fuer('Test');
      freigaben = Freigaben(ansicht, stufe: Bestaetigungen.alle);
      final moodle = await MoodleZugang.fuerTest(
        ansicht,
        extern.basis,
        benutzer: 'e.mustermann',
        passwort: 'erfunden',
      );
      addTearDown(moodle.abmelden);
      dienst = McpDienst(
        Einstellungen(schluessel: 'test'),
        moodle,
        ansicht,
        freigaben,
        ordner.path,
        profil: Profil(
          kennung: 'test',
          name: 'Test',
          adresse: extern.basis.toString(),
          port: 1,
          mcpName: 'test',
          schluessel: 'test',
        ),
      );
    });

    tearDown(() => extern.server.close(force: true));

    Future<({int status, Map json})> anlegen(WerkzeugAufruf a) => _post(
      adresse.adresse,
      pfadWerkzeug,
      daten: {
        'name': 'aktivitaet_anlegen',
        'argumente': {'kurs': 12, 'abschnitt_id': 1, 'typ': 'page', 'name': 'ZZ Probe', 'ordner': 'entwurf'},
      },
      token: a.token,
    );

    test('Stufe „alle“: die Freigabe nennt das Plugin als Aufrufer, das Protokoll auch', () async {
      String? aufruferImDialog;
      freigaben.addListener(() {
        final f = freigaben.aktuell;
        if (f != null && f.offen) {
          aufruferImDialog = f.aufrufer;
          scheduleMicrotask(() => freigaben.entscheiden(true));
        }
      });
      final a = _aufruf(dienst);
      adresse.aufrufAnmelden('beispiel', a);

      final r = await anlegen(a);

      expect(r.status, 200);
      expect(r.json['text'], contains('verified: true'));
      expect(aufruferImDialog, 'Plugin „Beispiel“');
      expect(zeilen(), contains(startsWith('[Test] aktivitaet_anlegen({')));
      expect(zeilen(), contains(endsWith(' -- Aufrufer: Plugin „Beispiel“')));
      expect(zeilen(), contains(allOf(startsWith('[Test] Freigabe angefragt: '), contains('(Aufrufer: Plugin „Beispiel“, Frist'))));
    });

    test('Stufe „keine“: der Hinweis „ohne Freigabe ausgeführt“ nennt das Plugin', () async {
      freigaben.stufe = Bestaetigungen.keine;
      final a = _aufruf(dienst);
      adresse.aufrufAnmelden('beispiel', a);

      final r = await anlegen(a);

      expect(r.status, 200);
      expect(r.json['text'], contains('verified: true'));
      expect(r.json['text'], contains('Ohne Freigabe ausgeführt (1 Vorgang, Aufrufer: Plugin „Beispiel“)'));
      expect(zeilen(), contains(allOf(startsWith('[Test] Ohne Freigabe (Bestätigungen: keine): '), endsWith('(Aufrufer: Plugin „Beispiel“)'))));
    });

    test('bricht der Client den äußeren Aufruf ab, verfällt die offene Freigabe, und nichts wird angelegt', () async {
      final abbruch = Completer<void>();
      freigaben.addListener(() {
        if (freigaben.aktuell?.offen == true && !abbruch.isCompleted) abbruch.complete();
      });
      final a = _aufruf(dienst, abbruch: abbruch.future);
      adresse.aufrufAnmelden('beispiel', a);

      final r = await anlegen(a);

      expect(r.status, 409);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(freigaben.aktuell, isNull);
      expect(extern.vorhanden, isFalse);
      expect(zeilen(), contains('[Test] Die KI wartet nicht mehr -- nicht gespeichert'));
    });
  });

  group('Die Hülle direkt', () {
    test('direkt aufgerufen: dieselbe Hülle, der Aufrufer im Hinweis und im Protokoll; ein unbekannter Name gibt null', () async {
      final f = Freigaben(protokoll, stufe: Bestaetigungen.keine);
      final aufrufe = WerkzeugAufrufe(protokoll, f, ausfuehren: (_, _, aufruf) => aufruf());
      final server = McpServer(const Implementation(name: 'probe', version: '1'));
      aufrufe.registrieren(
        server,
        'probe',
        titel: 'Probe',
        beschreibung: 'Probe',
        ausfuehren: (a) async {
          await f.anfragen(FreigabeAnfrage(titel: 'Probe speichern?', punkte: const [], vergleich: const []));
          return 'ok';
        },
      );

      final mit = await aufrufe.direktAufrufen(
        server,
        'probe',
        const {},
        abbruch: Completer<void>().future,
        aufrufer: 'Plugin „Beispiel“',
      )!;

      expect((mit.content.single as TextContent).text, contains('(1 Vorgang, Aufrufer: Plugin „Beispiel“)'));
      expect(aufrufe.direktAufrufen(server, 'fehlt', const {}, abbruch: Completer<void>().future, aufrufer: 'x'), isNull);
      expect(zeilen(), containsAllInOrder(['probe({}) -- Aufrufer: Plugin „Beispiel“', 'Ohne Freigabe (Bestätigungen: keine): Probe speichern? (Aufrufer: Plugin „Beispiel“)']));
    });
  });
}

/// Eine Werkzeugquelle mit einem Werkzeug, das wie eines des Plugins heißt.
class _EineQuelle implements WerkzeugQuelle {
  @override
  List<WerkzeugBeschreibung> werkzeuge(Profil profil) => const [
    WerkzeugBeschreibung(name: 'beispiel_echo', beschreibung: 'Probe', eingabeSchema: {'type': 'object'}),
  ];

  @override
  Future<String> aufrufen(WerkzeugAufruf aufruf) async => 'Echo';
}
