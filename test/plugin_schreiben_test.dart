// Ein Plugin schreibt über eine Zusatzadresse (E36): erst eine Freigabe der
// Lehrkraft auf jeder Stufe, dann genau ein POST mit der Kennung daraus. Was
// nicht erlaubt ist, erreicht Moodle nie und kommt ohne Dialog als Ablehnung
// zurück. Auf der einen Seite steht ein HTTP-Client im Test an Stelle eines
// Plugins, auf der anderen das Moodle-Doppel aus test/plugin_moodle_test.dart;
// das echte Beispiel-Plugin prüft test/plugin_start_test.dart, den Dialog
// test/freigabe_dialoge_test.dart. Alles in Temp-Ordnern.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/mcp/werkzeugquelle.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/moodle/sperrliste.dart';
import 'package:moocp/plugin/adressmuster.dart';
import 'package:moocp/plugin/app_adresse.dart';
import 'package:moocp/plugin/beschreibung.dart';
import 'package:moocp/plugin/moodle_schreiben.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:moocp/testschalter.dart';
import 'package:path/path.dart' as p;

import 'plugin_moodle_test.dart' show PluginTestMoodle, sitzungsCookie;

const _schluessel = 'schluessel-des-beispiels-0123456789abcdefghijkl';
const _zweiterSchluessel = 'schluessel-des-zweiten-plugins-0123456789abcd';
const _freierSchluessel = 'schluessel-des-freien-plugins-0123456789abcdef';

/// Die Zusatzadressen des Plugins „Beispiel“ in diesen Tests.
final _zusatzadressen = [
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/speichern.php'), ZugriffsArt.schreiben, 'Speichert die Notiz.'),
  // Läge sonst auf der Sperrliste (/mod/…/report.php).
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/report.php'), ZugriffsArt.schreiben, 'Schreibt den Bericht.'),
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/datei.php/*'), ZugriffsArt.schreiben, 'Legt eine Datei ab.'),
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/lesen.php'), ZugriffsArt.lesen, 'Liest die Seite.'),
];

/// Ein Instanzprofil, wie es die Adresse sieht; die Freigabe beantwortet
/// [ausgang] und merkt sich, was gefragt wurde.
class _Kontext implements AufrufKontext {
  _Kontext(this.moodle, this.arbeitsordner);

  @override
  final MoodleZugang moodle;
  @override
  final String arbeitsordner;
  @override
  Protokoll get protokoll => moodle.protokoll;

  PluginFreigabeAusgang ausgang = PluginFreigabeAusgang.freigegeben;

  /// Hält die Freigabe an, bis es sich erfüllt.
  Completer<void>? halten;

  final gefragt =
      <({String titel, String zusammenfassung, Bestaetigungen ab, String aufrufer, List<String> punkte, String? protokolltitel})>[];

  @override
  Future<EingebautErgebnis> eingebautAufrufen(
    String name,
    Map<String, dynamic> args, {
    required Future<void> abbruch,
    required String aufrufer,
  }) => throw UnimplementedError();

  @override
  Future<PluginFreigabeAusgang> pluginFreigabe({
    required String titel,
    required String zusammenfassung,
    required Bestaetigungen ab,
    required Future<void> abbruch,
    required String aufrufer,
    List<String> punkte = const [],
    String? protokolltitel,
    int? laufKurs,
  }) async {
    gefragt.add((
      titel: titel,
      zusammenfassung: zusammenfassung,
      ab: ab,
      aufrufer: aufrufer,
      punkte: punkte,
      protokolltitel: protokolltitel,
    ));
    final h = halten;
    if (h != null) {
      await Future.any([h.future, abbruch]);
      return PluginFreigabeAusgang.abgebrochen;
    }
    return ausgang;
  }

  @override
  String? get testDialogantworten => null;
}

typedef _Antwort = ({int status, Map json, HttpHeaders kopf, String roh});

Future<_Antwort> _post(Uri adresse, String pfad, Map<String, Object?> daten, {String? token, String schluessel = _schluessel}) async {
  final http = HttpClient();
  try {
    final r = await http.postUrl(adresse.resolve(pfad));
    r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $schluessel');
    if (token != null) r.headers.set(aufrufKopf, token);
    r.headers.contentType = ContentType.json;
    r.add(utf8.encode(jsonEncode(daten)));
    final antwort = await r.close();
    final text = await utf8.decoder.bind(antwort).join();
    return (status: antwort.statusCode, json: jsonDecode(text) as Map, kopf: antwort.headers, roh: text);
  } finally {
    http.close(force: true);
  }
}

List<Map<String, String>> _felder(Map<String, String> f) => [
  for (final MapEntry(:key, :value) in f.entries) {'name': key, 'wert': value},
];

void main() {
  late PluginTestMoodle moodle;
  late Directory wurzel;
  late AppAdresse adresse;
  late Protokoll protokoll;
  late MoodleZugang zugang;

  setUp(() async {
    moodle = PluginTestMoodle();
    await moodle.starten();
    wurzel = Directory.systemTemp.createTempSync('moocp_plugin_schreiben_');
    protokoll = Protokoll();
    zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
    await zugang.sesskey();
    protokoll.leeren();
    moodle.angefragt.clear();
    moodle.rumpfe.clear();
    adresse = await AppAdresse.starten(Protokoll());
    adresse.pluginAnmelden('beispiel', 'Beispiel', _schluessel, zusatzadressen: _zusatzadressen);
    // Ein zweites Plugin ohne Zusatzadressen, und eines, dessen Muster alles
    // trifft: An der Beschreibungsdatei käme es nicht vorbei
    // (sperrbereichBeruehrt), hier zeigt es, dass die Bereiche auch zur
    // Laufzeit vor jeder Zusatzadresse gelten.
    adresse.pluginAnmelden('zweites', 'Zweites', _zweiterSchluessel);
    adresse.pluginAnmelden(
      'frei',
      'Frei',
      _freierSchluessel,
      zusatzadressen: [Zusatzadresse(Adressmuster.parsen('/*'), ZugriffsArt.schreiben, 'Alles.')],
    );
  });

  tearDown(() async {
    await adresse.beenden();
    await moodle.server.close(force: true);
    wurzel.deleteSync(recursive: true);
  });

  List<String> zeilen() => [for (final e in protokoll.eintraege) '${e.art.name}: ${e.text}'];

  List<String> posts() => [for (final a in moodle.angefragt) if (a.startsWith('POST ')) a];

  /// Meldet einen Aufruf des Plugins [kurzname] an.
  ({String token, AngemeldeterAufruf angemeldet, _Kontext kontext}) aufruf({
    String kurzname = 'beispiel',
    AufrufKontext? kontext,
    MoodleZugang? z,
  }) {
    final k = _Kontext(z ?? zugang, (Directory(p.join(wurzel.path, 'A'))..createSync(recursive: true)).path);
    final a = WerkzeugAufruf(
      name: '${kurzname}_schreiben',
      args: const {},
      profil: Profil(kennung: 'A', name: 'A', adresse: 'https://moodle.schule.example', port: 1, mcpName: 'A', schluessel: 't'),
      token: aufrufToken(),
      abbruch: Completer<void>().future,
      kontext: kontext ?? k,
    );
    return (token: a.token, angemeldet: adresse.aufrufAnmelden(kurzname, a), kontext: k);
  }

  String schluesselVon(String kurzname) => switch (kurzname) {
    'zweites' => _zweiterSchluessel,
    'frei' => _freierSchluessel,
    _ => _schluessel,
  };

  Map<String, Object?> anfrage(String pfad, {Map<String, String> felder = const {'notiz': 'Hallo'}, String methode = 'POST'}) => {
    'methode': methode,
    'pfad': pfad,
    'felder': _felder(felder),
  };

  Future<_Antwort> freigabe(String token, Map<String, Object?> daten, {String kurzname = 'beispiel'}) => _post(
    adresse.adresse,
    pfadZusatzFreigabe,
    {'titel': 'Notiz speichern?', 'zusammenfassung': 'Speichert die Notiz „Hallo“.', ...daten},
    token: token,
    schluessel: schluesselVon(kurzname),
  );

  Future<_Antwort> schreiben(String token, Map<String, Object?> daten, {String kurzname = 'beispiel'}) =>
      _post(adresse.adresse, pfadZusatzSchreiben, daten, token: token, schluessel: schluesselVon(kurzname));

  /// Freigabe und Schreiben mit denselben Angaben.
  Future<_Antwort> freigebenUndSchreiben(String token, Map<String, Object?> daten) async {
    final f = await freigabe(token, daten);
    expect(f.status, 200);
    expect(f.json['ausgang'], 'freigegeben');
    return schreiben(token, {...daten, 'kennung': f.json['kennung']});
  }

  group('Ohne Freigabe kein Schreiben', () {
    test('ohne Kennung oder mit einer ausgedachten: 403 auf jeder Stufe, auch „keine“; Moodle sieht nichts', () async {
      for (final stufe in Bestaetigungen.values) {
        final freigaben = Freigaben(protokoll)..stufe = stufe;
        final dienst = McpDienst(Einstellungen(schluessel: 'test'), zugang, protokoll, freigaben, wurzel.path, profil: Profil.migriert(''));
        final a = aufruf(kontext: dienst);
        for (final kennung in [null, '', 'ausgedacht', 12]) {
          final r = await schreiben(a.token, {...anfrage('/mod/beispiel/speichern.php?id=7'), 'kennung': ?kennung});
          expect(r.status, 403, reason: '${stufe.text} $kennung');
          expect(r.json['fehler'], contains('Ohne Freigabe der Lehrkraft'));
        }
        expect(freigaben.ausgelassen, 0);
        a.angemeldet.ende();
      }
      expect(posts(), isEmpty);
      expect(zeilen(), contains('gesperrt: Plugin „Beispiel“: Schreiben über eine Zusatzadresse ohne gültige Freigabe abgewiesen'));
    });

    test('mit Kennung genau einmal; die zweite Verwendung ist abgelehnt', () async {
      final a = aufruf();
      final daten = anfrage('/mod/beispiel/speichern.php?id=7');
      final f = await freigabe(a.token, daten);
      final kennung = f.json['kennung'] as String;
      expect(kennung.length, greaterThanOrEqualTo(40));

      expect((await schreiben(a.token, {...daten, 'kennung': kennung})).status, 200);
      final nochmal = await schreiben(a.token, {...daten, 'kennung': kennung});
      expect(nochmal.status, 403);
      expect(posts(), ['POST /mod/beispiel/speichern.php?id=7']);
      expect(a.angemeldet.zusatzSchreibvorgaenge, 1);
      expect(zeilen().join('\n'), isNot(contains(kennung)));
    });

    test('die Kennung gilt nur für Pfad, Parameter und Felder der Freigabe; jeder Versuch verbraucht sie', () async {
      final daten = anfrage('/mod/beispiel/speichern.php?id=7', felder: {'notiz': 'Hallo', 'farbe': 'rot'});
      for (final anders in [
        anfrage('/mod/beispiel/speichern.php?id=8', felder: {'notiz': 'Hallo', 'farbe': 'rot'}),
        anfrage('/mod/beispiel/speichern.php?id=7&x=1', felder: {'notiz': 'Hallo', 'farbe': 'rot'}),
        anfrage('/mod/beispiel/speichern.php?id=07', felder: {'notiz': 'Hallo', 'farbe': 'rot'}),
        anfrage('/mod/beispiel/report.php?id=7', felder: {'notiz': 'Hallo', 'farbe': 'rot'}),
        anfrage('/mod/beispiel/speichern.php?id=7', felder: {'notiz': 'Hallo!', 'farbe': 'rot'}),
        anfrage('/mod/beispiel/speichern.php?id=7', felder: {'farbe': 'rot', 'notiz': 'Hallo'}),
        anfrage('/mod/beispiel/speichern.php?id=7', felder: {'notiz': 'Hallo'}),
        anfrage('/mod/beispiel/speichern.php?id=7', felder: {'notiz': 'Hallo', 'farbe': 'rot', 'mehr': ''}),
      ]) {
        final a = aufruf();
        final f = await freigabe(a.token, daten);
        final kennung = f.json['kennung'];
        final r = await schreiben(a.token, {...anders, 'kennung': kennung});
        expect(r.status, 403, reason: '$anders');
        // Verbraucht: Auch mit den richtigen Angaben geht sie nicht mehr.
        expect((await schreiben(a.token, {...daten, 'kennung': kennung})).status, 403, reason: '$anders');
        a.angemeldet.ende();
      }
      expect(posts(), isEmpty);
    });

    test('die Kennung eines anderen Aufrufs oder eines anderen Plugins gilt nicht', () async {
      final a = aufruf();
      final b = aufruf();
      final fremd = aufruf(kurzname: 'zweites');
      final daten = anfrage('/mod/beispiel/speichern.php?id=7');
      final kennung = (await freigabe(a.token, daten)).json['kennung'];

      expect((await schreiben(b.token, {...daten, 'kennung': kennung})).status, 403);
      expect((await schreiben(fremd.token, {...daten, 'kennung': kennung}, kurzname: 'zweites')).status, 403);
      // Das Token von a mit dem Schlüssel des anderen Plugins: kein Aufruf.
      expect((await schreiben(a.token, {...daten, 'kennung': kennung}, kurzname: 'zweites')).status, 403);
      expect(posts(), isEmpty);
      // Nichts davon hat sie verbraucht: Sie lag nie bei diesen Aufrufen.
      expect((await schreiben(a.token, {...daten, 'kennung': kennung})).status, 200);
    });

    test('abgelehnt oder abgebrochen: keine Kennung, nichts gesendet', () async {
      for (final ausgang in [PluginFreigabeAusgang.abgelehnt, PluginFreigabeAusgang.abgebrochen, PluginFreigabeAusgang.ohneFrage]) {
        final a = aufruf();
        a.kontext.ausgang = ausgang;
        final f = await freigabe(a.token, anfrage('/mod/beispiel/speichern.php?id=7'));
        expect(f.status, 200);
        expect(f.json.keys, ['ausgang'], reason: '$ausgang');
        expect(f.json['ausgang'], ausgang == PluginFreigabeAusgang.abgelehnt ? 'abgelehnt' : 'abgebrochen');
      }
      expect(posts(), isEmpty);
      expect(zeilen(), contains('info: Plugin „Beispiel“: Freigabe zum Schreiben über eine Zusatzadresse (POST /mod/beispiel/speichern.php?id=…) -- abgelehnt'));
    });

    test('endet der Aufruf während der Freigabe oder vor dem Schreiben: nichts gesendet, die Kennung ist fort', () async {
      final a = aufruf();
      a.kontext.halten = Completer<void>();
      final offen = freigabe(a.token, anfrage('/mod/beispiel/speichern.php?id=7'));
      while (a.kontext.gefragt.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      a.angemeldet.ende();
      expect((await offen).json, {'ausgang': 'abgebrochen'});

      final b = aufruf();
      final daten = anfrage('/mod/beispiel/speichern.php?id=7');
      final kennung = (await freigabe(b.token, daten)).json['kennung'];
      b.angemeldet.ende();
      expect((await schreiben(b.token, {...daten, 'kennung': kennung})).status, 403);
      expect(posts(), isEmpty);
    });
  });

  group('Die Freigabe', () {
    test('fragt ab „keine“, mit dem Plugin als Aufrufer, der Adresse ohne Werte, den Feldnamen und dem Grund', () async {
      final a = aufruf();
      final f = await freigabe(
        a.token,
        anfrage('/mod/beispiel/speichern.php?id=7&seite=2', felder: {'notiz': 'Erika', 'farbe': 'rot'}),
      );
      expect(f.json['ausgang'], 'freigegeben');
      final g = a.kontext.gefragt.single;
      expect(g.ab, Bestaetigungen.keine);
      expect(g.aufrufer, 'Plugin „Beispiel“');
      expect(g.titel, 'Notiz speichern?');
      expect(g.zusammenfassung, 'Speichert die Notiz „Hallo“.');
      expect(g.protokolltitel, 'Schreiben über eine Zusatzadresse eines Plugins');
      expect(g.punkte, [
        'Schreibt in Moodle über eine Zusatzadresse des Plugins: POST /mod/beispiel/speichern.php?id=…&seite=…',
        'Formularfelder (nur die Namen): notiz, farbe',
        'Grund dieser Zusatzadresse aus der Beschreibungsdatei, dem Sie bei der Zustimmung zum Plugin zugestimmt '
            'haben: Speichert die Notiz.',
        'moocp prüft nicht, was das Plugin sendet, und liest nicht zurück; das tut das Plugin.',
      ]);
      expect(g.punkte.join('\n'), isNot(contains('Erika')));
      expect(g.punkte.join('\n'), isNot(contains('rot')));
    });

    group('über den MCP-Dienst des Profils', () {
      late Freigaben freigaben;
      late McpDienst dienst;
      setUp(() {
        freigaben = Freigaben(protokoll);
        dienst = McpDienst(Einstellungen(schluessel: 'test'), zugang, protokoll, freigaben, wurzel.path, profil: Profil.migriert(''));
      });

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

      for (final stufe in Bestaetigungen.values) {
        test('Stufe „${stufe.text}“: die Lehrkraft wird gefragt; erst danach geht der POST hinaus', () async {
          final gezeigt = entscheiden(true);
          freigaben.stufe = stufe;
          final a = aufruf(kontext: dienst);
          final r = await freigebenUndSchreiben(a.token, anfrage('/mod/beispiel/speichern.php?id=7'));
          expect(r.status, 200);
          final f = gezeigt.single;
          expect(f.ab, Bestaetigungen.keine);
          expect(f.aufrufer, 'Plugin „Beispiel“');
          expect(f.vomPlugin, 'Speichert die Notiz „Hallo“.');
          expect(f.punkte.first, 'Schreibt in Moodle über eine Zusatzadresse des Plugins: POST /mod/beispiel/speichern.php?id=…');
          expect(freigaben.ausgelassen, 0);
          expect(
            zeilen(),
            containsAllInOrder([
              'info: Freigabe angefragt: Schreiben über eine Zusatzadresse eines Plugins (Aufrufer: Plugin „Beispiel“, Frist 30 min)',
              'schreiben: Freigabe erteilt',
              'info: Plugin „Beispiel“: Freigabe zum Schreiben über eine Zusatzadresse (POST /mod/beispiel/speichern.php?id=…) -- erteilt',
              'schreiben: Plugin „Beispiel“, Zusatzadresse: POST /mod/beispiel/speichern.php?id=… → 303',
            ]),
          );
        });
      }

      test('abgelehnt: nichts gesendet', () async {
        entscheiden(false);
        final a = aufruf(kontext: dienst);
        final f = await freigabe(a.token, anfrage('/mod/beispiel/speichern.php?id=7'));
        expect(f.json, {'ausgang': 'abgelehnt'});
        expect(posts(), isEmpty);
      });

      test('der Testbetrieb gibt nichts frei', () async {
        expect(testbetriebAktiv, isTrue);
        final gezeigt = entscheiden(false);
        final a = aufruf(kontext: dienst);
        final f = await freigaben.imTest(
          () => freigabe(a.token, anfrage('/mod/beispiel/speichern.php?id=7')),
          pruefen: () async => true,
        );
        expect(f.json, {'ausgang': 'abgelehnt'});
        expect(gezeigt, hasLength(1));
        expect(freigaben.testfreigaben, 0);
        expect(posts(), isEmpty);
      });
    });
  });

  group('Ablehnung ohne Dialog, bevor gefragt wird', () {
    /// Bittet um eine Freigabe für [daten] und erwartet die Ablehnung ohne
    /// Dialog, für Freigabe wie Schreiben.
    Future<Map> abgelehnt(Map<String, Object?> daten, int status, {String kurzname = 'beispiel', String? grund}) async {
      final a = aufruf(kurzname: kurzname);
      final f = await freigabe(a.token, daten, kurzname: kurzname);
      expect(f.status, status, reason: '$daten');
      expect(f.json.keys, ['fehler'], reason: '$daten');
      if (grund != null) expect(f.json['fehler'], contains(grund), reason: '$daten');
      expect(a.kontext.gefragt, isEmpty, reason: '$daten');
      a.angemeldet.ende();
      return f.json;
    }

    tearDown(() => expect(moodle.angefragt, isEmpty));

    test('gesperrte Bereiche gelten vor jeder Zusatzadresse, auch verschleiert', () async {
      for (final pfad in ['/admin/tool/x.php', '/admin', '/ADMIN/x.php', '/%61dmin/x.php', '/login/index.php', '/auth/x.php', '/webservice/x.php', '/user/managetoken.php']) {
        await abgelehnt(anfrage(pfad), 403, kurzname: 'frei', grund: 'Gesperrt für jedes Plugin');
      }
      for (final pfad in ['/mod/beispiel/../../admin/x.php', '/mod/%2e%2e/admin/x.php', '/mod/%252e%252e/admin/x.php', '/mod//x.php', r'/mod\x.php']) {
        await abgelehnt(anfrage(pfad), 400, kurzname: 'frei', grund: 'Normalform');
      }
      expect(zeilen(), contains('gesperrt: Plugin „Frei“: Gesperrt für Plugins: POST /admin/tool/x.php (Bereich Adminbereich)'));
    });

    test('keine Zusatzadresse dieses Plugins zum Schreiben: 403, auch für Schreibpfade der Positivliste', () async {
      await abgelehnt(anfrage('/mod/page/view.php?id=1'), 403, grund: 'keine Zusatzadresse dieses Plugins');
      await abgelehnt(anfrage('/course/modedit.php'), 403, grund: 'keine Zusatzadresse dieses Plugins');
      await abgelehnt(anfrage('/mod/beispiel/lesen.php?id=1'), 403, grund: 'Art „lesen“');
      expect(zeilen(), contains('gesperrt: Plugin „Beispiel“: Gesperrt: POST /mod/page/view.php?id=…'));
    });

    test('eine Zusatzadresse von Plugin „Beispiel“ gilt nicht für ein anderes Plugin', () async {
      await abgelehnt(anfrage('/mod/beispiel/speichern.php?id=7'), 403, kurzname: 'zweites');
      // Hier wirkt für das andere Plugin die Sperrliste.
      await abgelehnt(anfrage('/mod/beispiel/report.php'), 403, kurzname: 'zweites', grund: 'Gesperrt (Datenschutz)');
    });

    test('der sesskey kommt nie vom Plugin: weder als Feld noch als Parameter', () async {
      for (final felder in [
        {'sesskey': 'abc123'},
        {'SessKey': 'abc123'},
        {'sesskey[]': 'abc123'},
        {'sesskey ': 'x'},
      ]) {
        await abgelehnt(anfrage('/mod/beispiel/speichern.php?id=7', felder: felder), 400);
      }
      for (final pfad in ['/mod/beispiel/speichern.php?sesskey=abc123', '/mod/beispiel/speichern.php?sess%6Bey=abc123', '/mod/beispiel/speichern.php?sesskey%5B%5D=1']) {
        await abgelehnt(anfrage(pfad), 403, grund: 'sesskey');
      }
      expect(zeilen().join('\n'), isNot(contains('abc123')));
    });

    test('nur POST, gültige Felder, angemeldet', () async {
      for (final m in ['GET', 'PUT', 'post']) {
        await abgelehnt(anfrage('/mod/beispiel/speichern.php?id=7', methode: m), 405);
      }
      await abgelehnt({'pfad': '/mod/beispiel/speichern.php?id=7'}, 405);
      for (final felder in [
        'notiz=Hallo',
        {'notiz': 'Hallo'},
        [
          {'name': 'notiz'},
        ],
        [
          {'name': 'notiz', 'wert': 5},
        ],
        [
          {'name': '', 'wert': ''},
        ],
        [
          {'name': 'mit leer', 'wert': ''},
        ],
      ]) {
        await abgelehnt({'methode': 'POST', 'pfad': '/mod/beispiel/speichern.php?id=7', 'felder': felder}, 400);
      }
      final ohne = aufruf(z: MoodleZugang(protokoll));
      final r = await freigabe(ohne.token, anfrage('/mod/beispiel/speichern.php?id=7'));
      expect(r.status, 503);
      expect(r.json, {'fehler': 'Bitte melden Sie sich zuerst in moocp an (Fenster der App); danach geht dieser Aufruf.'});
    });

    test('ein gesperrter Name in Pfad, Parameter- oder Feldname: 422, kein Name im Protokoll', () async {
      adresse.sperre.namenHinzufuegen('beispiel', ['Erika Mustermann']);
      for (final daten in [
        anfrage('/mod/beispiel/datei.php/7/Erika.txt'),
        anfrage('/mod/beispiel/datei.php/7/M%75stermann.txt'),
        anfrage('/mod/beispiel/speichern.php?id=7&erika=1'),
        anfrage('/mod/beispiel/speichern.php?id=7', felder: {'mustermann': '1'}),
      ]) {
        await abgelehnt(daten, 422);
      }
      expect(zeilen().join('\n').toLowerCase(), isNot(contains('erika')));
      expect(zeilen().join('\n').toLowerCase(), isNot(contains('mustermann')));
    });
  });

  group('Senden', () {
    test('POST mit den Feldern des Plugins und dem sesskey von moocp; Antwort ohne Cookies und Kopfzeilen', () async {
      final a = aufruf();
      final r = await freigebenUndSchreiben(
        a.token,
        anfrage('/mod/beispiel/speichern.php?id=7', felder: {'notiz': 'Hallo Welt', 'tags[]': 'a'}),
      );

      expect(r.status, 200);
      expect(r.json.keys.toSet(), {'geschrieben', 'status', 'inhaltstyp', 'pfad', 'text'});
      expect(r.json['geschrieben'], true);
      expect(r.json['status'], 200);
      expect(r.json['pfad'], '/mod/beispiel/speichern.php?id=7&gespeichert=1');
      expect(r.json['text'], '<html>Notiz: Hallo Welt</html>');
      expect(moodle.angefragt, ['POST /mod/beispiel/speichern.php?id=7', 'GET /mod/beispiel/speichern.php?id=7&gespeichert=1']);
      expect(moodle.rumpfe.first, 'notiz=Hallo+Welt&tags%5B%5D=a&sesskey=abc123');
      for (final geheim in [sitzungsCookie, 'MoodleSession', 'abc123']) {
        expect(r.roh, isNot(contains(geheim)));
        expect(r.kopf.toString(), isNot(contains(geheim)));
      }
      expect(r.kopf[HttpHeaders.setCookieHeader], isNull);
      expect(a.angemeldet.zusatzSchreibvorgaenge, 1);
    });

    test('das Protokoll nennt Methode, Pfad bis zum Skriptnamen, Parameternamen und Status, nie Werte', () async {
      final a = aufruf();
      await freigebenUndSchreiben(a.token, anfrage('/mod/beispiel/speichern.php?id=7', felder: {'notiz': 'Geheimnis'}));
      await freigebenUndSchreiben(a.token, anfrage('/mod/beispiel/datei.php/7/blatt.txt?x=1&y=2', felder: {'inhalt': 'Text'}));

      final schreiben = [for (final z in zeilen()) if (z.contains('Zusatzadresse:')) z];
      expect(schreiben, [
        'schreiben: Plugin „Beispiel“, Zusatzadresse: POST /mod/beispiel/speichern.php?id=… → 303',
        'moodle: Plugin „Beispiel“, Zusatzadresse: GET /mod/beispiel/speichern.php?id=…&gespeichert=… → 200',
        'schreiben: Plugin „Beispiel“, Zusatzadresse: POST /mod/beispiel/datei.php?x=…&y=… → 404',
      ]);
      final alle = zeilen().join('\n');
      for (final wert in ['Geheimnis', 'Text', 'blatt.txt', 'abc123', '=7', '=1', '=2']) {
        expect(alle, isNot(contains(wert)), reason: wert);
      }
    });

    test('die Sperrliste gilt für eine Zusatzadresse dieses Plugins nicht, für die eingebauten Werkzeuge weiter', () async {
      final a = aufruf();
      final r = await freigebenUndSchreiben(a.token, anfrage('/mod/beispiel/report.php'));
      expect(r.status, 200);
      expect(r.json['text'], '<html>Bericht</html>');

      // Positivliste und Sperrliste der App sind dieselben wie vorher.
      final bericht = moodle.basis.resolve('/mod/beispiel/report.php');
      final speichern = moodle.basis.resolve('/mod/beispiel/speichern.php?id=7');
      expect(sperrregel(bericht), isNotNull);
      expect(zugang.erlaubt('POST', speichern, [const MapEntry('notiz', 'x')]), isFalse);
      moodle.angefragt.clear();
      await expectLater(zugang.senden('/mod/beispiel/speichern.php?id=7', [const MapEntry('notiz', 'x')]), throwsA(isA<AnfrageGesperrt>()));
      await expectLater(zugang.senden('/mod/beispiel/report.php', [const MapEntry('notiz', 'x')]), throwsA(isA<AnfrageGesperrt>()));
      expect(moodle.angefragt, isEmpty);
    });

    group('Umleitungen nach dem POST', () {
      test('gefolgt wird zu einer Zusatzadresse „schreiben“ dieses Plugins und zu Lesbarem', () async {
        final a = aufruf();
        final r = await freigebenUndSchreiben(a.token, anfrage('/mod/beispiel/speichern.php?id=12'));
        expect(r.json['pfad'], '/question/banks.php?courseid=12');
        expect(r.json.containsKey('umleitungNichtGelesen'), isFalse);
      });

      test('sonst nicht; die Antwort sagt unmissverständlich, dass schon geschrieben ist', () async {
        for (final (id, grund) in [
          ('13', 'Gesperrt für jedes Plugin'),
          ('15', 'lesenden Teil'),
          ('19', 'nicht auf der Positivliste'),
          ('20', 'sesskey'),
          ('21', 'Gesperrt (Datenschutz)'),
        ]) {
          moodle.angefragt.clear();
          final a = aufruf();
          final r = await freigebenUndSchreiben(a.token, anfrage('/mod/beispiel/speichern.php?id=$id'));
          expect(r.status, 200, reason: id);
          expect(r.json['geschrieben'], true, reason: id);
          expect(r.json['status'], 303, reason: id);
          expect(r.json['pfad'], '/mod/beispiel/speichern.php?id=$id', reason: id);
          expect(r.json['umleitungNichtGelesen'], startsWith('Geschrieben ist schon: Der Schreibvorgang ist gesendet'), reason: id);
          expect(r.json['umleitungNichtGelesen'], contains(grund), reason: id);
          expect(moodle.angefragt, ['POST /mod/beispiel/speichern.php?id=$id'], reason: id);
          expect(a.angemeldet.zusatzSchreibvorgaenge, 1, reason: id);
        }
        expect(zeilen().join('\n'), isNot(contains('abc123')));
      });
    });

    test('abgelaufene Sitzung: Neuanmeldung durch moocp, nichts wiederholt, nicht als geschrieben gezählt', () async {
      final a = aufruf();
      final daten = anfrage('/mod/beispiel/speichern.php?id=7');
      final kennung = (await freigabe(a.token, daten)).json['kennung'];
      moodle.sitzungAbgelaufen = true;
      final r = await schreiben(a.token, {...daten, 'kennung': kennung});
      expect(r.status, 503);
      expect(r.json['fehler'], startsWith('Nicht geschrieben: Die Sitzung war abgelaufen'));
      expect(posts().where((x) => x.contains('/mod/beispiel/')), ['POST /mod/beispiel/speichern.php?id=7']);
      expect(zeilen().where((z) => z.contains('Sitzung abgelaufen -- melde neu an')), hasLength(1));
      expect(a.angemeldet.zusatzSchreibvorgaenge, 0);
      expect((await schreiben(a.token, {...daten, 'kennung': kennung})).status, 403);
    });

    test('ein Schutzdienst: als Fehler gemeldet, nicht umgangen, nicht übergeben', () async {
      final a = aufruf();
      final r = await freigebenUndSchreiben(a.token, anfrage('/mod/beispiel/speichern.php?id=35'));
      expect(r.status, 502);
      expect(r.json['fehler'], startsWith(SchutzPruefung().meldung));
      expect(posts(), ['POST /mod/beispiel/speichern.php?id=35']);
      expect(
        zeilen(),
        contains('schreiben: Plugin „Beispiel“, Zusatzadresse: POST /mod/beispiel/speichern.php?id=… → 403 (Schutzdienst: Prüfung verlangt, Ray-ID r2-FRA)'),
      );
      expect(a.angemeldet.zusatzSchreibvorgaenge, 0);
    });
  });

  group('Lesen bleibt, wie es war', () {
    test('eine Zusatzadresse, ob „lesen“ oder „schreiben“, liest ein Plugin über /v1/moodle/lesen nicht', () async {
      final a = aufruf();
      for (final pfad in ['/mod/beispiel/lesen.php?id=1', '/mod/beispiel/speichern.php?id=7', '/mod/beispiel/report.php']) {
        final r = await _post(adresse.adresse, pfadMoodleLesen, {'pfad': pfad}, token: a.token);
        expect(r.status, 403, reason: pfad);
      }
      expect(moodle.angefragt, isEmpty);
    });
  });

  group('Hilfen', () {
    test('Pfad bis zum Skriptnamen', () {
      Uri u(String s) => Uri.parse('https://m.example$s');
      expect(skriptAdresse(u('/mod/x/speichern.php')), '/mod/x/speichern.php');
      expect(skriptAdresse(u('/mod/x/speichern.php?id=5&a=b')), '/mod/x/speichern.php?id=…&a=…');
      expect(skriptAdresse(u('/pluginfile.php/5/mod_x/Erika.pdf?forcedownload=1')), '/pluginfile.php?forcedownload=…');
      expect(skriptAdresse(u('/mod/x/A.PHP/Erika')), '/mod/x/A.PHP');
      expect(skriptAdresse(u('/mod/x/ohne')), '/mod/x/ohne');
    });

    test('die Summe der Felder hängt an Namen, Werten und Reihenfolge', () {
      const a = [MapEntry('a', '1'), MapEntry('b', '2')];
      expect(felderSumme(a), felderSumme([const MapEntry('a', '1'), const MapEntry('b', '2')]));
      expect(felderSumme(a), isNot(felderSumme([const MapEntry('b', '2'), const MapEntry('a', '1')])));
      expect(felderSumme(a), isNot(felderSumme([const MapEntry('a', '12'), const MapEntry('b', '')])));
      expect(felderSumme([const MapEntry('a=1&b', '2')]), isNot(felderSumme(a)));
    });

    test('die Kennzeichnung für die KI sagt, dass moocp nichts geprüft hat, und nie „verified“', () {
      final t = zusatzKennzeichnung('Beispiel', 1);
      expect(t, contains('des Plugins „Beispiel“'));
      expect(t, contains('Geprüft vom Plugin, nicht von moocp'));
      expect(t.toLowerCase(), isNot(contains('verified')));
      expect(zusatzKennzeichnung('Beispiel', 2), contains('2 Schreibvorgänge'));
    });
  });
}
