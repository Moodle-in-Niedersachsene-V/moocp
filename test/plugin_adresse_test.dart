// Die Adresse der App für Plugins (E35): Anmeldung mit dem Schlüssel des
// Plugins, das Token eines laufenden Aufrufs, Host und Origin, und die
// Funktionen Protokollzeile, Arbeitsordner, eingebautes Werkzeug, Dialoge und
// Freigabe. Auf der
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
import 'package:moocp/plugin/dialoge.dart';
import 'package:moocp/plugin/klartext.dart';
import 'package:moocp/plugin/namenssperre.dart';
import 'package:moocp/testschalter.dart';
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

  /// Nicht angemeldet: Moodle erreicht ein Plugin hier nicht
  /// (test/plugin_moodle_test.dart prüft den Weg dorthin).
  @override
  late final MoodleZugang moodle = MoodleZugang(protokoll);
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

  final freigaben = <({String titel, String zusammenfassung, Bestaetigungen ab, String aufrufer})>[];

  @override
  Future<PluginFreigabeAusgang> pluginFreigabe({
    required String titel,
    required String zusammenfassung,
    required Bestaetigungen ab,
    required Future<void> abbruch,
    required String aufrufer,
  }) async {
    freigaben.add((titel: titel, zusammenfassung: zusammenfassung, ab: ab, aufrufer: aufrufer));
    return PluginFreigabeAusgang.freigegeben;
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
  late PluginDialoge dialoge;
  late List<SperrTreffer> gemeldet;

  setUp(() async {
    wurzel = Directory.systemTemp.createTempSync('moocp_adresse_');
    protokoll = Protokoll();
    dialoge = PluginDialoge();
    gemeldet = [];
    adresse = await AppAdresse.starten(protokoll, dialoge: dialoge, sperre: LetzteSperre(melden: gemeldet.add));
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

  /// Wartet, bis [bedingung] gilt, höchstens fünf Sekunden.
  Future<void> warten(bool Function() bedingung) async {
    final ende = DateTime.now().add(const Duration(seconds: 5));
    while (!bedingung()) {
      if (DateTime.now().isAfter(ende)) fail('Die Bedingung trat nicht binnen fünf Sekunden ein.');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Beantwortet jeden Dialog, sobald er offen ist, mit [antwort] (null heißt
  /// abgebrochen), wie die Lehrkraft in der Oberfläche; liefert die gezeigten.
  List<PluginDialog> antworten(Map<String, Object?>? Function(PluginDialog d) antwort) {
    final gezeigt = <PluginDialog>[];
    dialoge.addListener(() {
      final d = dialoge.aktuell;
      if (d != null && d.offen && !gezeigt.contains(d)) {
        gezeigt.add(d);
        scheduleMicrotask(() => dialoge.beantworten(d, antwort(d)));
      }
    });
    return gezeigt;
  }

  group('Dialoge über die Adresse', () {
    test('jede Art liefert ihre Antwort; ins Protokoll gehen Plugin, Art und Ausgang, nie die Werte', () async {
      final a = _aufruf(kontext('A'));
      adresse.aufrufAnmelden('beispiel', a);
      final gezeigt = antworten(
        (d) => switch (d) {
          AuswahlDialog() => AuswahlDialog.antwort([2, 0]),
          EingabeDialog() => EingabeDialog.antwort('geheime Eingabe'),
          PfadDialog() => PfadDialog.antwort(p.join(wurzel.path, 'Erika Mustermann')),
          HinweisDialog() => const {},
        },
      );

      final auswahl = await _post(
        adresse.adresse,
        pfadAuswahl,
        daten: {
          'titel': 'Kurs wählen',
          'eintraege': ['Kurs 12', 'Kurs 13', 'Kurs 14'],
          'mehrfach': true,
        },
        token: a.token,
      );
      final eingabe = await _post(adresse.adresse, pfadEingabe, daten: {'titel': 'Text', 'vorgabe': 'x'}, token: a.token);
      final pfad = await _post(adresse.adresse, pfadPfadwahl, daten: {'titel': 'Ordner', 'art': 'ordner'}, token: a.token);
      final hinweis = await _post(
        adresse.adresse,
        pfadHinweis,
        daten: {'titel': 'Fertig', 'text': 'Alles erledigt.'},
        token: a.token,
      );

      expect(auswahl.status, 200);
      expect(auswahl.json, {
        'abgebrochen': false,
        'gewaehlt': [0, 2],
      });
      expect(eingabe.json, {'abgebrochen': false, 'text': 'geheime Eingabe'});
      expect(pfad.json, {'abgebrochen': false, 'pfad': p.join(wurzel.path, 'Erika Mustermann')});
      expect(hinweis.json, {'abgebrochen': false});
      expect([for (final d in gezeigt) d.art], PluginDialogArt.values);
      expect([for (final d in gezeigt) d.absender], everyElement('Plugin „Beispiel“'));
      expect((gezeigt[0] as AuswahlDialog).mehrfach, isTrue);
      expect((gezeigt[1] as EingabeDialog).vorgabe, 'x');
      expect((gezeigt[2] as PfadDialog).ordner, isTrue);
      expect(gezeigt[3].text, 'Alles erledigt.');
      expect(
        zeilen(),
        containsAllInOrder([
          '[A] Plugin „Beispiel“: Dialog „Auswahl“ geöffnet',
          '[A] Plugin „Beispiel“: Dialog „Auswahl“ beantwortet',
          '[A] Plugin „Beispiel“: Dialog „Eingabe“ geöffnet',
          '[A] Plugin „Beispiel“: Dialog „Eingabe“ beantwortet',
          '[A] Plugin „Beispiel“: Dialog „Ordner- oder Dateiwahl“ geöffnet',
          '[A] Plugin „Beispiel“: Dialog „Ordner- oder Dateiwahl“ beantwortet',
          '[A] Plugin „Beispiel“: Dialog „Hinweis“ geöffnet',
          '[A] Plugin „Beispiel“: Dialog „Hinweis“ beantwortet',
        ]),
      );
      final alles = zeilen().join('\n');
      expect(alles, isNot(contains('geheime Eingabe')));
      expect(alles, isNot(contains('Mustermann')));
      expect(alles, isNot(contains('Kurs 12')));
    });

    test('abgebrochen ist ein Ausgang, kein Fehler', () async {
      final a = _aufruf(kontext('A'));
      adresse.aufrufAnmelden('beispiel', a);
      antworten((_) => null);

      for (final (pfad, daten) in [
        (pfadAuswahl, {'titel': 'T', 'eintraege': ['a']}),
        (pfadEingabe, {'titel': 'T', 'art': 'link'}),
        (pfadPfadwahl, {'titel': 'T', 'art': 'datei'}),
        (pfadHinweis, {'titel': 'T'}),
      ]) {
        final r = await _post(adresse.adresse, pfad, daten: daten, token: a.token);
        expect(r.status, 200, reason: pfad);
        expect(r.json, {'abgebrochen': true}, reason: pfad);
      }
      expect(zeilen(), contains('[A] Plugin „Beispiel“: Dialog „Eingabe“ abgebrochen'));
    });

    test('ohne gültiges Token kein Dialog und keine Freigabe: 403', () async {
      final a = _aufruf(kontext('A'));
      final ende = adresse.aufrufAnmelden('beispiel', a);
      ende();
      for (final pfad in [pfadAuswahl, pfadEingabe, pfadPfadwahl, pfadHinweis, pfadFreigabe]) {
        expect((await _post(adresse.adresse, pfad, daten: {'titel': 'T'})).status, 403, reason: pfad);
        expect((await _post(adresse.adresse, pfad, daten: {'titel': 'T'}, token: a.token)).status, 403, reason: pfad);
      }
      expect(dialoge.aktuell, isNull);
    });

    test('je Aufruf nur ein Dialog zugleich: ein zweiter 409, auch eine Freigabe; ein anderer Aufruf wartet', () async {
      final k = kontext('A');
      final a = _aufruf(k);
      final b = _aufruf(kontext('B'));
      adresse.aufrufAnmelden('beispiel', a);
      adresse.aufrufAnmelden('beispiel', b);

      final erster = _post(adresse.adresse, pfadHinweis, daten: {'titel': 'Eins'}, token: a.token);
      await warten(() => dialoge.aktuell != null);
      final zweiter = await _post(adresse.adresse, pfadEingabe, daten: {'titel': 'Zwei'}, token: a.token);
      final freigabe = await _post(
        adresse.adresse,
        pfadFreigabe,
        daten: {'titel': 'F', 'zusammenfassung': 'Z', 'ab': 'mittel'},
        token: a.token,
      );
      final andererAufruf = _post(adresse.adresse, pfadHinweis, daten: {'titel': 'Drei'}, token: b.token);
      await warten(() => dialoge.wartend == 1);

      expect(zweiter.status, 409);
      expect(zweiter.json['fehler'], contains('nur einer zugleich'));
      expect(freigabe.status, 409);
      expect(k.freigaben, isEmpty);
      expect(zeilen(), contains('[A] Plugin „Beispiel“: zweiter Dialog im selben Aufruf abgewiesen'));
      expect(dialoge.aktuell!.titel, 'Eins');

      dialoge.beantworten(dialoge.aktuell!, const {});
      expect((await erster).json, {'abgebrochen': false});
      expect(dialoge.aktuell!.titel, 'Drei');
      dialoge.beantworten(dialoge.aktuell!, const {});
      expect((await andererAufruf).json, {'abgebrochen': false});

      // Nach der Antwort geht der nächste Dialog desselben Aufrufs.
      antworten((_) => const {});
      expect((await _post(adresse.adresse, pfadHinweis, daten: {'titel': 'Vier'}, token: a.token)).status, 200);
    });

    for (final wie in ['bricht der Client den äußeren Aufruf ab', 'endet der äußere Aufruf']) {
      test('$wie, schließt sich der offene Dialog: abgebrochen', () async {
        final abbruch = Completer<void>();
        final a = _aufruf(kontext('A'), abbruch: abbruch.future);
        final ende = adresse.aufrufAnmelden('beispiel', a);

        final antwort = _post(
          adresse.adresse,
          pfadAuswahl,
          daten: {'titel': 'T', 'eintraege': ['a', 'b']},
          token: a.token,
        );
        await warten(() => dialoge.aktuell != null);
        final d = dialoge.aktuell!;
        wie.startsWith('bricht') ? abbruch.complete() : ende();

        final r = await antwort.timeout(const Duration(seconds: 5));
        expect(r.status, 200);
        expect(r.json, {'abgebrochen': true});
        expect(d.offen, isFalse);
        expect(dialoge.aktuell, isNull);
        expect(zeilen(), contains('[A] Plugin „Beispiel“: Dialog „Auswahl“ abgebrochen'));
      });
    }

    test('nach der Frist gilt der Dialog als abgebrochen und schließt sich', () async {
      final kurz = PluginDialoge(frist: const Duration(milliseconds: 100));
      final ad = await AppAdresse.starten(protokoll, dialoge: kurz);
      addTearDown(ad.beenden);
      ad.pluginAnmelden('beispiel', 'Beispiel', _schluessel);
      final a = _aufruf(kontext('A'));
      ad.aufrufAnmelden('beispiel', a);

      final r = await _post(ad.adresse, pfadHinweis, daten: {'titel': 'T'}, token: a.token).timeout(const Duration(seconds: 5));

      expect(r.json, {'abgebrochen': true});
      expect(kurz.aktuell, isNull);
      expect(PluginDialoge().frist, Freigaben.fristVorgabe);
    });

    test('ohne Oberfläche für Dialoge: 503', () async {
      final ohne = await AppAdresse.starten(protokoll);
      addTearDown(ohne.beenden);
      ohne.pluginAnmelden('beispiel', 'Beispiel', _schluessel);
      final a = _aufruf(kontext('A'));
      ohne.aufrufAnmelden('beispiel', a);

      final r = await _post(ohne.adresse, pfadHinweis, daten: {'titel': 'T'}, token: a.token);

      expect(r.status, 503);
    });
  });

  group('Grenzen der Dialoge', () {
    test('Titel und Einträge einzeilig und gekürzt, der Text mehrzeilig ohne Steuer- und Richtungszeichen', () async {
      final a = _aufruf(kontext('A'));
      adresse.aufrufAnmelden('beispiel', a);
      final gezeigt = antworten((_) => null);
      final rlo = String.fromCharCode(0x202e);
      final bel = String.fromCharCode(0x07);
      final lrm = String.fromCharCode(0x200e);

      await _post(
        adresse.adresse,
        pfadAuswahl,
        daten: {
          'titel': 'Zeile eins\nZeile zwei ${'x' * 300}',
          'text': 'erste\r\nzweite$bel$rlo dritte\t!\n\n\n\nvierte <b>fett</b> https://moodle.schule.example',
          'eintraege': ['a${rlo}b', 'y' * 300, '  Kurs$lrm 12  '],
        },
        token: a.token,
      );

      final d = gezeigt.single as AuswahlDialog;
      expect(d.titel, startsWith('Zeile eins Zeile zwei xxx'));
      expect(d.titel.length, dialogTitelHoechstens);
      expect(d.titel, endsWith('…'));
      expect(d.text, 'erste\nzweite dritte !\n\nvierte <b>fett</b> https://moodle.schule.example');
      expect(d.eintraege, ['a b', '${'y' * (auswahlEintragHoechstens - 1)}…', 'Kurs 12']);
    });

    test('mehrzeilig begrenzt die Länge', () {
      expect(mehrzeilig('z' * 3000, dialogTextHoechstens).length, dialogTextHoechstens);
      expect(mehrzeilig('z' * 3000, dialogTextHoechstens), endsWith('…'));
    });

    test('zu viele, leere oder falsche Einträge, fehlender Titel, falsche Art: 400 mit deutschem Satz; nichts gezeigt', () async {
      final a = _aufruf(kontext('A'));
      adresse.aufrufAnmelden('beispiel', a);
      final gezeigt = antworten((_) => null);
      Future<({int status, Map json})> post(String pfad, Map<String, Object?> daten) =>
          _post(adresse.adresse, pfad, daten: daten, token: a.token);

      final zuViele = await post(pfadAuswahl, {
        'titel': 'T',
        'eintraege': [for (var i = 0; i <= auswahlEintraegeHoechstens; i++) 'E $i'],
      });
      expect(zuViele.status, 400);
      expect(zuViele.json['fehler'], contains('höchstens $auswahlEintraegeHoechstens'));
      for (final (pfad, daten) in [
        (pfadAuswahl, {'titel': 'T', 'eintraege': <String>[]}),
        (pfadAuswahl, {'titel': 'T', 'eintraege': ['', 'x']}),
        (pfadAuswahl, {'titel': 'T', 'eintraege': [1]}),
        (pfadAuswahl, {'titel': 'T', 'eintraege': ['x'], 'mehrfach': 'ja'}),
        (pfadAuswahl, {'eintraege': ['x']}),
        (pfadHinweis, {'titel': ' \n '}),
        (pfadHinweis, {'titel': 'T', 'text': 3}),
        (pfadEingabe, {'titel': 'T', 'art': 'zahl'}),
        (pfadEingabe, {'titel': 'T', 'vorgabe': 3}),
        (pfadPfadwahl, {'titel': 'T'}),
        (pfadPfadwahl, {'titel': 'T', 'art': 'ordner', 'start': 'C:\\a\nb'}),
        (pfadPfadwahl, {'titel': 'T', 'art': 'ordner', 'start': 'x' * (pfadHoechstens + 1)}),
      ]) {
        final r = await post(pfad, daten);
        expect(r.status, 400, reason: '$pfad $daten');
        expect(r.json['fehler'], isA<String>());
      }
      expect(gezeigt, isEmpty);

      final genug = await post(pfadAuswahl, {
        'titel': 'T',
        'eintraege': [for (var i = 0; i < auswahlEintraegeHoechstens; i++) 'E $i'],
      });
      expect(genug.status, 200);
      expect((gezeigt.single as AuswahlDialog).eintraege, hasLength(auswahlEintraegeHoechstens));
    });
  });

  group('Freigabe eines Plugins über die Adresse', () {
    test('Titel, Zusammenfassung und Stufe gehen bereinigt an das Profil des Aufrufs, mit dem Plugin als Aufrufer', () async {
      final k = kontext('A');
      final a = _aufruf(k);
      adresse.aufrufAnmelden('beispiel', a);

      final r = await _post(
        adresse.adresse,
        pfadFreigabe,
        daten: {
          'titel': 'Zwei\nZeilen',
          'zusammenfassung': 'Eins\r\nZwei${String.fromCharCode(0x202e)}',
          'ab': 'alle',
        },
        token: a.token,
      );

      expect(r.status, 200);
      expect(r.json, {'ausgang': 'freigegeben', 'ohneFrage': false});
      expect(k.freigaben.single, (titel: 'Zwei Zeilen', zusammenfassung: 'Eins\nZwei', ab: Bestaetigungen.alle, aufrufer: 'Plugin „Beispiel“'));
      expect(zeilen(), contains('[A] Plugin „Beispiel“: Freigabe ab Stufe „alle“ -- erteilt'));
    });

    test('ohne Titel, Zusammenfassung oder gültige Stufe: 400', () async {
      final k = kontext('A');
      final a = _aufruf(k);
      adresse.aufrufAnmelden('beispiel', a);
      for (final daten in [
        {'zusammenfassung': 'Z', 'ab': 'mittel'},
        {'titel': 'T', 'ab': 'mittel'},
        {'titel': 'T', 'zusammenfassung': 'Z'},
        {'titel': 'T', 'zusammenfassung': 'Z', 'ab': 'hoch'},
      ]) {
        expect((await _post(adresse.adresse, pfadFreigabe, daten: daten, token: a.token)).status, 400, reason: '$daten');
      }
      expect(k.freigaben, isEmpty);
    });
  });

  group('Freigabe eines Plugins über den MCP-Dienst eines Profils', () {
    late Protokoll ansicht;
    late Freigaben freigaben;
    late McpDienst dienst;

    McpDienst dienstMit(Freigaben f) => McpDienst(
      Einstellungen(schluessel: 'test'),
      MoodleZugang(ansicht),
      ansicht,
      f,
      (Directory(p.join(wurzel.path, 'A'))..createSync(recursive: true)).path,
      profil: _profil('a', 'A'),
    );

    setUp(() {
      ansicht = protokoll.fuer('A');
      freigaben = Freigaben(ansicht);
      dienst = dienstMit(freigaben);
    });

    Future<({int status, Map json})> bitten(WerkzeugAufruf a, String ab) => _post(
      adresse.adresse,
      pfadFreigabe,
      daten: {'titel': 'Beispiel freigeben?', 'zusammenfassung': 'Das Beispiel ändert nichts.', 'ab': ab},
      token: a.token,
    );

    /// Entscheidet jede offene Freigabe mit [ja]; liefert die gezeigten.
    List<FreigabeAnfrage> entscheiden(bool ja) {
      final gezeigt = <FreigabeAnfrage>[];
      freigaben.addListener(() {
        final f = freigaben.aktuell;
        if (f != null && f.offen && !gezeigt.contains(f)) {
          gezeigt.add(f);
          scheduleMicrotask(() => freigaben.entscheiden(ja));
        }
      });
      return gezeigt;
    }

    test('Stufe mittel, ab mittel: die Lehrkraft gibt frei; Plugin als Aufrufer, Zusammenfassung als vom Plugin', () async {
      final gezeigt = entscheiden(true);
      final a = _aufruf(dienst);
      adresse.aufrufAnmelden('beispiel', a);

      final r = await bitten(a, 'mittel');

      expect(r.json, {'ausgang': 'freigegeben', 'ohneFrage': false});
      final f = gezeigt.single;
      expect(f.titel, 'Beispiel freigeben?');
      expect(f.vomPlugin, 'Das Beispiel ändert nichts.');
      expect(f.aufrufer, 'Plugin „Beispiel“');
      expect(f.knopf, 'Freigeben');
      expect(f.ab, Bestaetigungen.mittel);
      expect(
        zeilen(),
        containsAllInOrder([
          '[A] Freigabe angefragt: Freigabe eines Plugins (Aufrufer: Plugin „Beispiel“, Frist 30 min)',
          '[A] Freigabe erteilt',
          '[A] Plugin „Beispiel“: Freigabe ab Stufe „mittel“ -- erteilt',
        ]),
      );
      expect(zeilen().join('\n'), isNot(contains('Beispiel freigeben?')));
      expect(zeilen().join('\n'), isNot(contains('ändert nichts')));
    });

    test('abgelehnt', () async {
      entscheiden(false);
      final a = _aufruf(dienst);
      adresse.aufrufAnmelden('beispiel', a);

      expect((await bitten(a, 'mittel')).json, {'ausgang': 'abgelehnt', 'ohneFrage': false});
      expect(zeilen(), contains('[A] Plugin „Beispiel“: Freigabe ab Stufe „mittel“ -- abgelehnt'));
    });

    for (final (stufe, ab) in [(Bestaetigungen.keine, 'mittel'), (Bestaetigungen.mittel, 'alle')]) {
      test('Stufe „${stufe.text}“, ab „$ab“: ohne Frage freigegeben, im Protokoll und als ohneFrage', () async {
        final gezeigt = entscheiden(false);
        freigaben.stufe = stufe;
        final a = _aufruf(dienst);
        adresse.aufrufAnmelden('beispiel', a);

        final r = await bitten(a, ab);

        expect(r.json, {'ausgang': 'freigegeben', 'ohneFrage': true});
        expect(gezeigt, isEmpty);
        expect(freigaben.ausgelassen, 1);
        expect(
          zeilen(),
          contains('[A] Ohne Freigabe (Bestätigungen: ${stufe.text}): Freigabe eines Plugins (Aufrufer: Plugin „Beispiel“)'),
        );
        expect(zeilen(), contains('[A] Plugin „Beispiel“: Freigabe ab Stufe „$ab“ -- ohne Frage erteilt'));
      });
    }

    test('ab „keine“ fragt auf jeder Stufe, auch bei „keine“', () async {
      final gezeigt = entscheiden(true);
      freigaben.stufe = Bestaetigungen.keine;
      final a = _aufruf(dienst);
      adresse.aufrufAnmelden('beispiel', a);

      expect((await bitten(a, 'keine')).json, {'ausgang': 'freigegeben', 'ohneFrage': false});
      expect(gezeigt.single.ab, Bestaetigungen.keine);
      expect(freigaben.ausgelassen, 0);
    });

    test('bricht der Client den äußeren Aufruf ab, schließt sich die offene Freigabe: abgebrochen', () async {
      final abbruch = Completer<void>();
      freigaben.addListener(() {
        if (freigaben.aktuell?.offen == true && !abbruch.isCompleted) abbruch.complete();
      });
      final a = _aufruf(dienst, abbruch: abbruch.future);
      adresse.aufrufAnmelden('beispiel', a);

      final r = await bitten(a, 'mittel');

      expect(r.json, {'ausgang': 'abgebrochen', 'ohneFrage': false});
      expect(freigaben.aktuell, isNull);
      expect(zeilen(), contains('[A] Plugin „Beispiel“: Freigabe ab Stufe „mittel“ -- abgebrochen'));
    });

    test('endet der äußere Aufruf, schließt sich die offene Freigabe: abgebrochen', () async {
      final a = _aufruf(dienst);
      final ende = adresse.aufrufAnmelden('beispiel', a);
      freigaben.addListener(() {
        if (freigaben.aktuell?.offen == true) scheduleMicrotask(ende);
      });

      expect((await bitten(a, 'mittel')).json, {'ausgang': 'abgebrochen', 'ohneFrage': false});
      expect(freigaben.aktuell, isNull);
    });

    test('nach der Frist: abgebrochen', () async {
      final kurz = Freigaben(ansicht, frist: const Duration(milliseconds: 100));
      final a = _aufruf(dienstMit(kurz));
      adresse.aufrufAnmelden('beispiel', a);

      expect((await bitten(a, 'mittel')).json, {'ausgang': 'abgebrochen', 'ohneFrage': false});
      expect(kurz.aktuell, isNull);
      expect(zeilen(), contains('[A] Frist abgelaufen -- nicht gespeichert'));
    });

    test('der Testbetrieb gibt eine Freigabe eines Plugins nicht automatisch frei', () async {
      expect(testbetriebAktiv, isTrue);
      freigaben.stufe = Bestaetigungen.alle;
      // Zum Vergleich: In dieser Zone gäbe der Testbetrieb eine Freigabe der
      // App automatisch frei.
      final eigene = await freigaben.imTest(
        () => freigaben.anfragen(FreigabeAnfrage(titel: 'ZZ Probe', punkte: const [], vergleich: const [])),
        pruefen: () async => true,
      );
      expect(eigene, isTrue);
      expect(freigaben.testfreigaben, 1);
      final gezeigt = entscheiden(false);

      final ausgang = await freigaben.imTest(
        () => dienst.pluginFreigabe(
          titel: 'T',
          zusammenfassung: 'Z',
          ab: Bestaetigungen.mittel,
          abbruch: Completer<void>().future,
          aufrufer: 'Plugin „Beispiel“',
        ),
        pruefen: () async => true,
      );

      expect(ausgang, PluginFreigabeAusgang.abgelehnt);
      expect(gezeigt, hasLength(1));
      expect(freigaben.testfreigaben, 1);
    });
  });

  group('Letzte Sperre: Namen nennen und Protokollzeilen', () {
    // Erfundene Namen (A8, A11).
    const name = 'Erika Mustermann';

    Future<({int status, Map json})> nennen(String token, Object? namen) =>
        _post(adresse.adresse, pfadNamen, daten: {'namen': namen}, token: token);

    test('Namen nennen braucht das Token eines laufenden Aufrufs; Antwort und Protokoll nennen nur die Zahl', () async {
      expect((await _post(adresse.adresse, pfadNamen, daten: {'namen': [name]})).status, 403);
      final a = _aufruf(kontext('A'));
      adresse.aufrufAnmelden('beispiel', a);

      final r = await nennen(a.token, [name, 'Max Muster']);

      expect(r.status, 200);
      expect(r.json, isEmpty);
      expect(zeilen(), contains('[A] Plugin „Beispiel“: 2 Namen zum Sperren genannt'));
      expect(adresse.sperre.anzahl('beispiel'), 2);
      expect(zeilen().join('\n'), isNot(contains('Erika')));
      expect(zeilen().join('\n'), isNot(contains('Muster')));
    });

    test('eine Protokollzeile mit einem Namensteil erscheint nicht; im Protokoll steht nur, dass gesperrt wurde', () async {
      expect(testbetriebAktiv, isTrue, reason: 'auch im Testbetrieb sperrt die letzte Sperre');
      final a = _aufruf(kontext('A'));
      adresse.aufrufAnmelden('beispiel', a);
      await nennen(a.token, [name]);

      final gesperrt = await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'Bearbeitet: ERIKA'}, token: a.token);
      final frei = await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'Bearbeitet: Aufgabe 3'}, token: a.token);

      expect(gesperrt.status, 422);
      expect(gesperrt.json['fehler'], startsWith('Gesperrt: Die Zeile enthält ein Wort'));
      expect(jsonEncode(gesperrt.json), isNot(contains('ERIKA')));
      expect(frei.status, 200);
      expect(
        zeilen(),
        contains('[A] Plugin „Beispiel“, Werkzeug beispiel_echo: Protokollzeile gesperrt (letzte Sperre: könnte einen Namen enthalten)'),
      );
      expect(zeilen(), contains('[A] Plugin „Beispiel“: Bearbeitet: Aufgabe 3'));
      expect(zeilen().join('\n').toLowerCase(), isNot(contains('erika')));
      expect(protokoll.eintraege.where((e) => e.art == Art.gesperrt), hasLength(1));
      expect(gemeldet.single.plugin, 'Beispiel');
      expect(gemeldet.single.werkzeug, 'beispiel_echo');
      expect(gemeldet.single.stelle, SperrStelle.protokollzeile);
      expect(gemeldet.single.wort, 'ERIKA');
    });

    test('die Sperre gilt nach dem Ende des Aufrufs weiter, auch ohne Token und nach einem neuen Schlüssel', () async {
      final a = _aufruf(kontext('A'));
      final ende = adresse.aufrufAnmelden('beispiel', a);
      await nennen(a.token, [name]);
      ende();

      final ohneToken = await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'später: Mustermann'});
      adresse.pluginAnmelden('beispiel', 'Beispiel', 'neuer-schluessel-0123456789abcdefghijklmnop');
      final nachNeustart = await _post(
        adresse.adresse,
        pfadProtokoll,
        daten: {'text': 'nach dem Neustart: Erika'},
        schluessel: 'neuer-schluessel-0123456789abcdefghijklmnop',
      );

      expect(ohneToken.status, 422);
      expect(nachNeustart.status, 422);
      expect(zeilen(), contains('Plugin „Beispiel“: Protokollzeile gesperrt (letzte Sperre: könnte einen Namen enthalten)'));
      expect(zeilen().join('\n'), isNot(contains('Mustermann')));
      expect(gemeldet.map((t) => t.werkzeug), [null, null]);
    });

    test('die Namen eines Plugins sperren kein anderes, und sie gelten in jedem Profil', () async {
      protokoll.profilnamenZeigen = true;
      adresse.pluginAnmelden('anderes', 'Anderes', _fremderSchluessel);
      final a = _aufruf(kontext('A'));
      adresse.aufrufAnmelden('beispiel', a);
      await nennen(a.token, [name]);
      final b = _aufruf(kontext('B'));
      adresse.aufrufAnmelden('beispiel', b);
      final fremd = _aufruf(kontext('C'));
      adresse.aufrufAnmelden('anderes', fremd);

      final imAnderenProfil = await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'Erika'}, token: b.token);
      final anderesPlugin = await _post(
        adresse.adresse,
        pfadProtokoll,
        daten: {'text': 'Erika'},
        schluessel: _fremderSchluessel,
        token: fremd.token,
      );

      expect(imAnderenProfil.status, 422);
      expect(anderesPlugin.status, 200);
      expect(zeilen(), contains('[C] Plugin „Anderes“: Erika'));
      expect(
        zeilen(),
        contains('[B] Plugin „Beispiel“, Werkzeug beispiel_echo: Protokollzeile gesperrt (letzte Sperre: könnte einen Namen enthalten)'),
      );
    });

    test('Name und Argumente eines eingebauten Werkzeugs gehen nur ohne Namen ins Protokoll; sonst läuft es nicht', () async {
      final k = kontext('A');
      final a = _aufruf(k);
      adresse.aufrufAnmelden('beispiel', a);
      await nennen(a.token, [name]);

      final r = await _post(
        adresse.adresse,
        pfadWerkzeug,
        daten: {
          'name': 'textseite_anlegen',
          'argumente': {
            'abschnitt': 1,
            'inhalt': '<p>Abgabe\nvon Mustermann</p>',
          },
        },
        token: a.token,
      );

      expect(r.status, 422);
      expect(r.json['fehler'], startsWith('Gesperrt: Der Aufruf enthält ein Wort'));
      expect(k.aufgerufen, isEmpty);
      expect(
        zeilen(),
        contains(
          '[A] Plugin „Beispiel“, Werkzeug beispiel_echo: Aufruf eines Werkzeugs von moocp gesperrt '
          '(letzte Sperre: könnte einen Namen enthalten)',
        ),
      );
      expect(zeilen().join('\n'), isNot(contains('Mustermann')));
      expect(gemeldet.single.stelle, SperrStelle.werkzeugaufruf);
      expect(gemeldet.single.wort, 'Mustermann');
      expect((await _post(adresse.adresse, pfadWerkzeug, daten: {'name': 'status'}, token: a.token)).status, 200);
    });

    test('Grenzen: zu viele, zu lang, leer, kein Text: abgelehnt, nichts aufgenommen, kein Name in der Meldung', () async {
      final a = _aufruf(kontext('A'));
      adresse.aufrufAnmelden('beispiel', a);

      final antworten = {
        'fehlt': await _post(adresse.adresse, pfadNamen, daten: <String, Object?>{}, token: a.token),
        'leer': await nennen(a.token, <String>[]),
        'keine Liste': await nennen(a.token, name),
        'zu viele': await nennen(a.token, [for (var i = 0; i <= namenJeAnfrageHoechstens; i++) 'Erika$i']),
        'zu lang': await nennen(a.token, ['Erika', 'E' * (nameHoechstens + 1)]),
        'nur Satzzeichen': await nennen(a.token, ['Erika', ' - ']),
        'kein Text': await nennen(a.token, ['Erika', 3]),
      };

      expect({for (final e in antworten.entries) e.key: e.value.status}, {
        'fehlt': 400,
        'leer': 400,
        'keine Liste': 400,
        'zu viele': 413,
        'zu lang': 400,
        'nur Satzzeichen': 400,
        'kein Text': 400,
      });
      expect(antworten['zu lang']!.json['fehler'], 'Name Nr. 2 ist länger als $nameHoechstens Zeichen; nichts aufgenommen.');
      expect(antworten['nur Satzzeichen']!.json['fehler'], contains('Nr. 2'));
      expect(antworten.values.map((r) => jsonEncode(r.json)).join(), isNot(contains('Erika')));
      expect(adresse.sperre.anzahl('beispiel'), 0, reason: 'über der Grenze nichts, auch nicht teilweise');
      expect((await _post(adresse.adresse, pfadProtokoll, daten: {'text': 'Erika'}, token: a.token)).status, 200);
      expect(
        (await nennen(a.token, [for (var i = 0; i < namenJeAnfrageHoechstens; i++) 'Erika$i'])).status,
        200,
        reason: 'genau an der Grenze geht es',
      );
    });

    test('je Plugin höchstens $namenJePluginHoechstens verschiedene Namen; gleiche zählen einmal', () async {
      final a = _aufruf(kontext('A'));
      adresse.aufrufAnmelden('beispiel', a);
      adresse.sperre.namenHinzufuegen('beispiel', [for (var i = 0; i < namenJePluginHoechstens - 1; i++) 'Probe$i']);

      final nochEiner = await nennen(a.token, ['Erika', 'erika', 'ERIKA']);
      final zuViel = await nennen(a.token, ['Max']);

      expect(nochEiner.status, 200);
      expect(zuViel.status, 413);
      expect(zuViel.json['fehler'], contains('höchstens $namenJePluginHoechstens'));
      expect(adresse.sperre.anzahl('beispiel'), namenJePluginHoechstens);
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
