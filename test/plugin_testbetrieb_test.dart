// Der Testbetrieb für Plugins (E35, Testbetrieb): in engen Grenzen, damit ein
// Ende-zu-Ende-Lauf mit einem Plugin ohne Klicks geht und die Datensperre
// nie schwächer wird. Eingebaute Werkzeuge über ein Plugin folgen den Regeln
// des Testbetriebs; Schreiben über eine Zusatzadresse gibt er nur in einem
// Lauf im gebundenen Testkurs frei; Dialoge eines Plugins beantwortet er aus
// einer Datei neben der Zugangsdatei des Testprofils. Nie automatisch: die
// Zustimmung, der Dialog eines Entwicklungs-Plugins, Schnittstelle und Update,
// alles, was auf jeder Stufe fragt, und die letzte Sperre.
//
// Auf der einen Seite steht ein HTTP-Client im Test an Stelle eines Plugins,
// auf der anderen ein Moodle-Doppel; die Testzugänge sind von Hand gebunden,
// mit erfundenen Angaben, und die Zugangsdatei des Testbetriebs liest hier
// niemand. Alles in Temp-Ordnern.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/mcp/testbetrieb.dart' show pluginDialogantwortenDatei;
import 'package:moocp/mcp/werkzeugquelle.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/plugin/adressmuster.dart';
import 'package:moocp/plugin/app_adresse.dart';
import 'package:moocp/plugin/beschreibung.dart';
import 'package:moocp/plugin/dialoge.dart';
import 'package:moocp/plugin/moodle_schreiben.dart';
import 'package:moocp/plugin/namenssperre.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:moocp/testschalter.dart';
import 'package:moocp/testzugang.dart';
import 'package:path/path.dart' as p;

import 'mcp_client.dart';
import 'plugin_moodle_test.dart' show PluginTestMoodle;
import 'testbetrieb_mcp_test.dart' show TestMoodle;

const _schluessel = 'schluessel-des-beispiels-0123456789abcdefghijkl';

final _zusatzadressen = [
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/speichern.php'), ZugriffsArt.schreiben, 'Speichert die Notiz.'),
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/bericht.php'), ZugriffsArt.lesen, 'Liest den Bericht.'),
];

Future<({int status, Map json})> _post(Uri adresse, String pfad, Map<String, Object?> daten, {String? token}) async {
  final http = HttpClient();
  try {
    final r = await http.postUrl(adresse.resolve(pfad));
    r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_schluessel');
    if (token != null) r.headers.set(aufrufKopf, token);
    r.headers.contentType = ContentType.json;
    r.add(utf8.encode(jsonEncode(daten)));
    final antwort = await r.close();
    final text = await utf8.decoder.bind(antwort).join();
    return (status: antwort.statusCode, json: text.isEmpty ? const {} : jsonDecode(text) as Map);
  } finally {
    http.close(force: true);
  }
}

/// Ein Werkzeug eines Plugins, das während des Aufrufs tut, was [ablauf]
/// sagt, über die Adresse der App wie ein echtes Plugin.
class _Quelle implements WerkzeugQuelle {
  _Quelle(this.adresse, this.ablauf);
  final AppAdresse adresse;
  final Future<String> Function(String token, WerkzeugAufruf aufruf) ablauf;

  @override
  List<WerkzeugBeschreibung> werkzeuge(Profil profil) => const [
    WerkzeugBeschreibung(
      name: 'beispiel_test',
      beschreibung: 'Ein Werkzeug des Beispiel-Plugins im Test.',
      eingabeSchema: {'type': 'object', 'properties': <String, Object?>{}},
    ),
  ];

  @override
  Future<String> aufrufen(WerkzeugAufruf aufruf) async {
    final angemeldet = adresse.aufrufAnmelden('beispiel', aufruf);
    try {
      return await ablauf(aufruf.token, aufruf);
    } finally {
      angemeldet.ende();
    }
  }
}

void main() {
  late Directory wurzel;
  late Protokoll protokoll;
  late Freigaben freigaben;
  late PluginDialoge dialoge;
  late SperrHinweise hinweise;
  late AppAdresse adresse;

  /// Die Freigaben und Dialoge, die die Lehrkraft zu sehen bekam; beantwortet
  /// werden sie mit „Ablehnen“ und „Abbrechen“.
  late List<FreigabeAnfrage> gezeigt;
  late List<PluginDialog> dialogeGezeigt;

  setUp(() async {
    expect(testbetriebAktiv, isTrue, reason: 'flutter_test_config schaltet den Testbetrieb ein');
    wurzel = Directory.systemTemp.createTempSync('moocp_plugin_testbetrieb_');
    protokoll = Protokoll();
    freigaben = Freigaben(protokoll, stufe: Bestaetigungen.alle);
    gezeigt = [];
    freigaben.addListener(() {
      final f = freigaben.aktuell;
      if (f != null && f.offen && !gezeigt.contains(f)) {
        gezeigt.add(f);
        scheduleMicrotask(() => freigaben.entscheiden(false));
      }
    });
    dialoge = PluginDialoge();
    dialogeGezeigt = [];
    dialoge.addListener(() {
      final d = dialoge.aktuell;
      if (d != null && d.offen && !dialogeGezeigt.contains(d)) {
        dialogeGezeigt.add(d);
        scheduleMicrotask(() => dialoge.beantworten(d, null));
      }
    });
    hinweise = SperrHinweise();
    adresse = await AppAdresse.starten(protokoll, dialoge: dialoge, sperre: LetzteSperre(melden: hinweise.melden));
    adresse.pluginAnmelden('beispiel', 'Beispiel', _schluessel, zusatzadressen: _zusatzadressen);
  });

  tearDown(() async {
    testbetriebFuerTestsSetzen(true);
    await adresse.beenden();
    wurzel.deleteSync(recursive: true);
  });

  List<String> zeilen() => [for (final e in protokoll.eintraege) e.text];

  /// Die Zugangsdatei des Testprofils: nur ein Pfad, den hier niemand liest.
  String zugangsdatei() => p.join(wurzel.path, 'testzugang.env');

  /// Ein MCP-Dienst des Profils „test“ mit [moodle]; gebunden an die Kurse
  /// [kurse], wenn [kennung] und [adresse] passen.
  McpDienst dienst(
    MoodleZugang moodle, {
    Set<int> kurse = const {12},
    String kennung = 'test',
    String? adresse,
    String? datei,
    int port = 1,
    List<WerkzeugQuelle> quellen = const [],
  }) {
    final profil = Profil(
      kennung: 'test',
      name: 'Test',
      adresse: moodle.basis.toString(),
      port: port,
      mcpName: 'test',
      schluessel: 'test',
    );
    return McpDienst(
      Einstellungen(schluessel: 'test'),
      moodle,
      protokoll,
      freigaben,
      (Directory(p.join(wurzel.path, 'arbeit'))..createSync(recursive: true)).path,
      profil: profil,
      testzugang: Testzugang(kennung: kennung, datei: datei ?? zugangsdatei(), adresse: adresse ?? profil.adresse, kurse: kurse),
      werkzeugquellen: quellen,
    );
  }

  /// Meldet einen Aufruf des Beispiel-Plugins im Profil von [kontext] an.
  ({String token, AngemeldeterAufruf angemeldet}) aufruf(AufrufKontext kontext) {
    final a = WerkzeugAufruf(
      name: 'beispiel_test',
      args: const {},
      profil: Profil(kennung: 'test', name: 'Test', adresse: 'https://moodle.schule.example', port: 1, mcpName: 'test', schluessel: 't'),
      token: aufrufToken(),
      abbruch: Completer<void>().future,
      kontext: kontext,
    );
    return (token: a.token, angemeldet: adresse.aufrufAnmelden('beispiel', a));
  }

  group('Schreiben über eine Zusatzadresse', () {
    late PluginTestMoodle moodle;
    late MoodleZugang zugang;

    setUp(() async {
      moodle = PluginTestMoodle();
      await moodle.starten();
      zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
      await zugang.sesskey();
      moodle.angefragt.clear();
    });

    tearDown(() => moodle.server.close(force: true));

    List<String> posts() => [for (final a in moodle.angefragt) if (a.startsWith('POST ')) a];

    Map<String, Object?> anfrage(int id, {String notiz = 'Hallo', Map<String, String> mehr = const {}}) => {
      'methode': 'POST',
      'pfad': '/mod/beispiel/speichern.php?id=$id',
      'felder': [
        {'name': 'notiz', 'wert': notiz},
        for (final MapEntry(:key, :value) in mehr.entries) {'name': key, 'wert': value},
      ],
      'titel': 'Notiz speichern?',
      'zusammenfassung': 'Speichert die Notiz.',
    };

    Future<({int status, Map json})> laufBeginnen(String token, int cmid) =>
        _post(adresse.adresse, pfadLaufBeginnen, {'cmid': cmid}, token: token);

    Future<({int status, Map json})> freigabe(String token, Map<String, Object?> daten) =>
        _post(adresse.adresse, pfadZusatzFreigabe, daten, token: token);

    Future<({int status, Map json})> schreiben(String token, Map<String, Object?> daten, Object? kennung) =>
        _post(adresse.adresse, pfadZusatzSchreiben, {...daten, 'kennung': kennung}, token: token);

    test('in einem Lauf im gebundenen Testkurs: automatisch freigegeben, im Protokoll und in der Antwort', () async {
      final a = aufruf(dienst(zugang));
      expect((await laufBeginnen(a.token, 501)).json, {'kurs': 12});

      final f = await freigabe(a.token, anfrage(501));

      expect(f.status, 200);
      expect(f.json['ausgang'], 'freigegeben');
      expect(f.json['testbetrieb'], isTrue);
      expect(f.json['hinweis'], testfreigabeHinweis);
      expect(gezeigt, isEmpty);
      expect(freigaben.testfreigaben, 1);

      final r = await schreiben(a.token, anfrage(501), f.json['kennung']);
      expect(r.status, 200);
      expect(posts(), ['POST /mod/beispiel/speichern.php?id=501']);
      expect(a.angemeldet.zusatzSchreibvorgaenge, 1);
      expect(a.angemeldet.zusatzTestSchreibvorgaenge, 1);
      expect(
        zeilen(),
        containsAllInOrder([
          'Testmodus, automatisch freigegeben: Schreiben über eine Zusatzadresse eines Plugins (Aufrufer: Plugin „Beispiel“)',
          'Plugin „Beispiel“: Freigabe zum Schreiben über eine Zusatzadresse (POST /mod/beispiel/speichern.php?id=…) '
              '-- im Testbetrieb automatisch erteilt',
        ]),
      );
      // A4: keine Werte, keine Kennung.
      expect(zeilen().join('\n'), isNot(contains('Hallo')));
      expect(zeilen().join('\n'), isNot(contains(f.json['kennung'] as String)));
    });

    test('in einem Lauf in einem anderen Kurs: der Dialog wie sonst', () async {
      final a = aufruf(dienst(zugang));
      expect((await laufBeginnen(a.token, 601)).json, {'kurs': 13});

      final f = await freigabe(a.token, anfrage(601));

      expect(f.json, {'ausgang': 'abgelehnt'});
      expect(gezeigt, hasLength(1));
      expect(gezeigt.single.ab, Bestaetigungen.keine);
      expect(freigaben.testfreigaben, 0);
      expect(posts(), isEmpty);
    });

    test('außerhalb eines Laufs: der Dialog, auch für eine Aktivität des Testkurses', () async {
      final a = aufruf(dienst(zugang));

      final f = await freigabe(a.token, anfrage(501));

      expect(f.json, {'ausgang': 'abgelehnt'});
      expect(gezeigt, hasLength(1));
      expect(freigaben.testfreigaben, 0);
    });

    test('in einem Lauf im Testkurs, aber die Adresse nennt eine andere Aktivität: der Dialog', () async {
      final a = aufruf(dienst(zugang));
      await laufBeginnen(a.token, 501);

      final f = await freigabe(a.token, anfrage(502));

      expect(f.json, {'ausgang': 'abgelehnt'});
      expect(gezeigt, hasLength(1));
      expect(freigaben.testfreigaben, 0);
    });

    // Moodle liest Formularfelder vor den Parametern der Adresse: Ein Feld mit
    // einer anderen Nummer hebt die Bindung an den Lauf auf.
    for (final felder in <Map<String, String>>[
      {'course': '13'},
      {'courseid': '13'},
      {'data[course]': '13'},
      {'Course': '13'},
      {'cmid': '502'},
      {'coursemodule': '502'},
      {'id': '502'},
      {'contextid': '960'},
      {'course': ''},
    ]) {
      test('in einem Lauf im Testkurs, aber ein Formularfeld nennt eine andere Nummer ($felder): der Dialog', () async {
        final a = aufruf(dienst(zugang));
        await laufBeginnen(a.token, 501);

        final f = await freigabe(a.token, anfrage(501, mehr: felder));

        expect(f.json, {'ausgang': 'abgelehnt'});
        expect(gezeigt, hasLength(1));
        expect(freigaben.testfreigaben, 0);
      });
    }

    test('Formularfelder mit den Nummern des Laufs: weiter automatisch freigegeben', () async {
      final a = aufruf(dienst(zugang));
      await laufBeginnen(a.token, 501);

      final f = await freigabe(
        a.token,
        anfrage(501, mehr: {'course': '12', 'coursemodule': '501', 'contextid': '950', 'data[id]': '501', 'seite': '3'}),
      );

      expect(f.json['ausgang'], 'freigegeben');
      expect(f.json['testbetrieb'], isTrue);
      expect(gezeigt, isEmpty);
    });

    for (final fall in ['Profil', 'Adresse', 'Kurs']) {
      test('falsche Bindung ($fall): der Dialog', () async {
        final a = aufruf(
          dienst(
            zugang,
            kennung: fall == 'Profil' ? 'fremd' : 'test',
            adresse: fall == 'Adresse' ? 'https://fremd.schule.example' : null,
            kurse: fall == 'Kurs' ? {34} : {12},
          ),
        );
        await laufBeginnen(a.token, 501);

        expect((await freigabe(a.token, anfrage(501))).json, {'ausgang': 'abgelehnt'});
        expect(gezeigt, hasLength(1));
        expect(freigaben.testfreigaben, 0);
      });
    }

    test('ohne den Bauschalter des Testbetriebs: der Dialog', () async {
      final d = dienst(zugang);
      final a = aufruf(d);
      await laufBeginnen(a.token, 501);
      testbetriebFuerTestsSetzen(false);

      expect((await freigabe(a.token, anfrage(501))).json, {'ausgang': 'abgelehnt'});
      expect(gezeigt, hasLength(1));
      expect(freigaben.testfreigaben, 0);
    });

    test('die automatische Freigabe gilt nur im Lauf, in dem sie kam', () async {
      final a = aufruf(dienst(zugang));
      await laufBeginnen(a.token, 501);
      final kennung = (await freigabe(a.token, anfrage(501))).json['kennung'];
      await _post(adresse.adresse, pfadLaufBeenden, const {}, token: a.token);
      // Ein neuer Lauf in derselben Aktivität ist ein anderer Lauf.
      await laufBeginnen(a.token, 501);

      final r = await schreiben(a.token, anfrage(501), kennung);

      expect(r.status, 403);
      expect(r.json['fehler'], contains('nur in dem Lauf'));
      expect(posts(), isEmpty);
      // Verbraucht: Auch ein zweiter Versuch geht nicht.
      expect((await schreiben(a.token, anfrage(501), kennung)).status, 403);
    });

    test('die Bindung bleibt: andere Felder brauchen eine neue Freigabe', () async {
      final a = aufruf(dienst(zugang));
      await laufBeginnen(a.token, 501);
      final kennung = (await freigabe(a.token, anfrage(501))).json['kennung'];

      final r = await schreiben(a.token, anfrage(501, notiz: 'Anders'), kennung);

      expect(r.status, 403);
      expect(posts(), isEmpty);
    });

    for (final ab in ['mittel', 'keine']) {
      test('eine Freigabe des Plugins (ab „$ab“) bleibt im Lauf im Testkurs ein Dialog', () async {
        final a = aufruf(dienst(zugang));
        await laufBeginnen(a.token, 501);

        final f = await _post(
          adresse.adresse,
          pfadFreigabe,
          {'titel': 'Weiter?', 'zusammenfassung': 'Das Plugin fragt.', 'ab': ab},
          token: a.token,
        );

        expect(f.json, {'ausgang': 'abgelehnt', 'ohneFrage': false});
        expect(gezeigt, hasLength(1));
        expect(freigaben.testfreigaben, 0);
      });
    }

    test('über MCP: die Antwort des Werkzeugs an die KI nennt die automatische Freigabe', () async {
      final frei = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = frei.port;
      await frei.close();
      final d = dienst(
        zugang,
        port: port,
        quellen: [
          _Quelle(adresse, (token, _) async {
            await laufBeginnen(token, 501);
            final f = await freigabe(token, anfrage(501));
            await schreiben(token, anfrage(501), f.json['kennung']);
            return 'Notiz gespeichert.';
          }),
        ],
      );
      await d.starten();
      final client = McpTestClient(port);
      addTearDown(() async {
        client.http.close(force: true);
        await d.stoppen();
      });
      await client.initialize();

      final text = await client.tool('beispiel_test', const {});

      expect(text, contains('Notiz gespeichert.'));
      expect(text, contains(testfreigabeHinweis));
      expect(gezeigt, isEmpty);
      expect(posts(), ['POST /mod/beispiel/speichern.php?id=501']);
    });
  });

  group('Die Kennzeichnung für die KI', () {
    test('Schreibvorgänge mit automatischer Freigabe heißen nicht „mit Freigabe der Lehrkraft“', () {
      expect(zusatzKennzeichnung('Beispiel', 1), contains('mit Freigabe der Lehrkraft'));
      final alle = zusatzKennzeichnung('Beispiel', 1, automatisch: 1);
      expect(alle, contains('im Debug-Testbetrieb automatisch freigegeben, ohne persönliche Freigabe der Lehrkraft'));
      expect(alle, isNot(contains('mit Freigabe der Lehrkraft')));
      expect(zusatzKennzeichnung('Beispiel', 3, automatisch: 2), contains('davon 2 im Debug-Testbetrieb'));
    });

    test('beantwortete Dialoge', () {
      expect(testantwortenKennzeichnung('Beispiel', 1), contains('Einen Dialog des Plugins „Beispiel“'));
      expect(testantwortenKennzeichnung('Beispiel', 2), contains('2 Dialoge'));
      expect(testantwortenKennzeichnung('Beispiel', 2), contains('ohne die Lehrkraft'));
    });
  });

  group('Eingebaute Werkzeuge über ein Plugin', () {
    late TestMoodle extern;
    late MoodleZugang zugang;

    setUp(() async {
      extern = TestMoodle();
      await extern.starten();
      final ordner = Directory(p.join(wurzel.path, 'arbeit', 'entwurf'))..createSync(recursive: true);
      File(p.join(ordner.path, 'page.html')).writeAsStringSync(extern.inhalt);
      zugang = await MoodleZugang.fuerTest(protokoll, extern.basis, benutzer: 'e.mustermann', passwort: 'erfunden');
    });

    tearDown(() async {
      zugang.abmelden();
      await extern.server.close(force: true);
    });

    Future<({int status, Map json})> anlegen(String token, {int kurs = 12}) => _post(
      adresse.adresse,
      pfadWerkzeug,
      {
        'name': 'aktivitaet_anlegen',
        'argumente': {'kurs': kurs, 'abschnitt_id': 1, 'typ': 'page', 'name': 'ZZ Probe', 'ordner': 'entwurf'},
      },
      token: token,
    );

    test('eigene ZZ-Probe im gebundenen Testkurs: wie für ein KI-Werkzeug automatisch freigegeben', () async {
      final a = aufruf(dienst(zugang));

      final r = await anlegen(a.token);

      expect(r.status, 200);
      expect(r.json['text'], contains('verified: true'));
      expect(r.json['text'], contains(testfreigabeHinweis));
      expect(gezeigt, isEmpty);
      expect(freigaben.testfreigaben, 1);
      expect(
        zeilen(),
        contains(allOf(startsWith('Testmodus, automatisch freigegeben: '), endsWith('(Aufrufer: Plugin „Beispiel“)'))),
      );
    });

    test('in einem Kurs, der kein gebundener Testkurs ist: die Freigabe wie sonst', () async {
      final a = aufruf(dienst(zugang, kurse: {34}));

      final r = await anlegen(a.token);

      expect(r.json['text'], contains('Nicht angelegt'));
      expect(gezeigt, hasLength(1));
      expect(gezeigt.single.aufrufer, 'Plugin „Beispiel“');
      expect(freigaben.testfreigaben, 0);
      expect(extern.vorhanden, isFalse);
    });

    test('über MCP: die automatische Freigabe im eingebauten Werkzeug erreicht auch die KI', () async {
      final frei = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = frei.port;
      await frei.close();
      final d = dienst(
        zugang,
        port: port,
        quellen: [
          _Quelle(adresse, (token, _) async {
            final r = await anlegen(token);
            return (r.json['text'] as String).contains('verified: true') ? 'Angelegt.' : 'Fehlgeschlagen.';
          }),
        ],
      );
      await d.starten();
      final client = McpTestClient(port);
      addTearDown(() async {
        client.http.close(force: true);
        await d.stoppen();
      });
      await client.initialize();

      final text = await client.tool('beispiel_test', const {});

      expect(text, startsWith('Angelegt.'));
      expect(text, contains(testfreigabeHinweis));
    });

    test('über MCP: lässt die Stufe die Freigabe im eingebauten Werkzeug aus, erfährt es die KI mit dem Plugin als Aufrufer', () async {
      freigaben.stufe = Bestaetigungen.keine;
      final frei = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = frei.port;
      await frei.close();
      final d = dienst(
        zugang,
        kurse: {34},
        port: port,
        quellen: [
          _Quelle(adresse, (token, _) async {
            final r = await anlegen(token);
            return (r.json['text'] as String).contains('verified: true') ? 'Angelegt.' : 'Fehlgeschlagen.';
          }),
        ],
      );
      await d.starten();
      final client = McpTestClient(port);
      addTearDown(() async {
        client.http.close(force: true);
        await d.stoppen();
      });
      await client.initialize();

      final text = await client.tool('beispiel_test', const {});

      expect(text, startsWith('Angelegt.'));
      expect(text, contains('Ohne Freigabe ausgeführt (1 Vorgang, Aufrufer: Plugin „Beispiel“)'));
      expect(text, isNot(contains(testfreigabeHinweis)));
      expect(gezeigt, isEmpty);
    });
  });

  group('Vorbereitete Dialogantworten', () {
    late PluginTestMoodle moodle;
    late MoodleZugang zugang;

    setUp(() async {
      moodle = PluginTestMoodle();
      await moodle.starten();
      zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
      await zugang.sesskey();
    });

    tearDown(() => moodle.server.close(force: true));

    String antwortdatei() => p.join(wurzel.path, pluginDialogantwortenDatei);

    void antwortenSchreiben(List<Map<String, Object?>> antworten) =>
        File(antwortdatei()).writeAsStringSync(jsonEncode({'antworten': antworten}));

    Future<({int status, Map json})> zeigen(String token, String pfad, Map<String, Object?> daten) =>
        _post(adresse.adresse, pfad, daten, token: token);

    test('die Datei liegt neben der Zugangsdatei des gebundenen Testprofils', () {
      expect(dienst(zugang).testDialogantworten, antwortdatei());
      expect(dienst(zugang, kennung: 'fremd').testDialogantworten, isNull);
      expect(dienst(zugang, adresse: 'https://fremd.schule.example').testDialogantworten, isNull);
      expect(dienst(zugang, datei: 'testzugang.env').testDialogantworten, isNull, reason: 'kein absoluter Pfad');
      testbetriebFuerTestsSetzen(false);
      expect(dienst(zugang).testDialogantworten, isNull);
    });

    test('jede Art aus der Datei beantwortet, ohne Dialog; im Protokoll ohne Werte, für die KI gezählt', () async {
      final ordner = Directory(p.join(wurzel.path, 'Erika Mustermann'))..createSync();
      antwortenSchreiben([
        {'plugin': 'zweites', 'art': 'auswahl', 'titel': 'Kurs wählen', 'antwort': {'gewaehlt': [1]}},
        {'plugin': 'beispiel', 'art': 'auswahl', 'titel': 'Kurs wählen', 'antwort': {'gewaehlt': [2, 0]}},
        {'plugin': 'beispiel', 'art': 'eingabe', 'titel': 'Link', 'antwort': {'text': ' https://moodle.schule.example/x '}},
        {'plugin': 'beispiel', 'art': 'pfad', 'titel': 'Ordner', 'antwort': {'pfad': ordner.path}},
        {'plugin': 'beispiel', 'art': 'hinweis', 'titel': 'Fertig', 'antwort': <String, Object?>{}},
      ]);
      final a = aufruf(dienst(zugang));

      final auswahl = await zeigen(a.token, pfadAuswahl, {
        'titel': 'Kurs wählen',
        'eintraege': ['Kurs 12', 'Kurs 13', 'Kurs 14'],
        'mehrfach': true,
      });
      final eingabe = await zeigen(a.token, pfadEingabe, {'titel': 'Link', 'art': 'link'});
      final pfad = await zeigen(a.token, pfadPfadwahl, {'titel': 'Ordner', 'art': 'ordner'});
      final hinweis = await zeigen(a.token, pfadHinweis, {'titel': 'Fertig'});

      expect(auswahl.json, {'abgebrochen': false, 'gewaehlt': [0, 2], 'testbetrieb': true});
      expect(eingabe.json, {'abgebrochen': false, 'text': 'https://moodle.schule.example/x', 'testbetrieb': true});
      expect(pfad.json, {'abgebrochen': false, 'pfad': p.normalize(ordner.path), 'testbetrieb': true});
      expect(hinweis.json, {'abgebrochen': false, 'testbetrieb': true});
      expect(dialogeGezeigt, isEmpty);
      expect(a.angemeldet.testDialogantworten, 4);
      expect(
        zeilen(),
        containsAllInOrder([
          'Plugin „Beispiel“: Dialog „Auswahl“ im Testbetrieb aus einer vorbereiteten Antwort beantwortet, ohne Lehrkraft',
          'Plugin „Beispiel“: Dialog „Eingabe“ im Testbetrieb aus einer vorbereiteten Antwort beantwortet, ohne Lehrkraft',
          'Plugin „Beispiel“: Dialog „Ordner- oder Dateiwahl“ im Testbetrieb aus einer vorbereiteten Antwort beantwortet, '
              'ohne Lehrkraft',
          'Plugin „Beispiel“: Dialog „Hinweis“ im Testbetrieb aus einer vorbereiteten Antwort beantwortet, ohne Lehrkraft',
        ]),
      );
      final alles = zeilen().join('\n');
      expect(alles, isNot(contains('Mustermann')));
      expect(alles, isNot(contains('moodle.schule.example/x')));
    });

    test('„antwort“: null heißt abgebrochen', () async {
      antwortenSchreiben([
        {'plugin': 'beispiel', 'art': 'eingabe', 'titel': 'Text', 'antwort': null},
      ]);
      final a = aufruf(dienst(zugang));

      final r = await zeigen(a.token, pfadEingabe, {'titel': 'Text'});

      expect(r.json, {'abgebrochen': true, 'testbetrieb': true});
      expect(dialogeGezeigt, isEmpty);
      expect(zeilen(), contains(endsWith('aus einer vorbereiteten Antwort abgebrochen, ohne Lehrkraft')));
    });

    test('ohne passende Antwort erscheint der Dialog wie sonst', () async {
      antwortenSchreiben([
        {'plugin': 'zweites', 'art': 'eingabe', 'titel': 'Text', 'antwort': {'text': 'x'}},
        {'plugin': 'beispiel', 'art': 'auswahl', 'titel': 'Text', 'antwort': {'gewaehlt': [0]}},
        {'plugin': 'beispiel', 'art': 'eingabe', 'titel': 'Anderer Titel', 'antwort': {'text': 'x'}},
      ]);
      final a = aufruf(dienst(zugang));

      final r = await zeigen(a.token, pfadEingabe, {'titel': 'Text'});

      expect(r.json, {'abgebrochen': true});
      expect(dialogeGezeigt, hasLength(1));
      expect(a.angemeldet.testDialogantworten, 0);
    });

    test('ohne Datei, ohne gebundenes Testprofil oder ohne Bauschalter erscheint der Dialog', () async {
      final eintrag = {'plugin': 'beispiel', 'art': 'hinweis', 'titel': 'Fertig', 'antwort': <String, Object?>{}};
      final ohneDatei = aufruf(dienst(zugang));
      expect((await zeigen(ohneDatei.token, pfadHinweis, {'titel': 'Fertig'})).json, {'abgebrochen': true});

      antwortenSchreiben([eintrag]);
      final fremd = aufruf(dienst(zugang, kennung: 'fremd'));
      expect((await zeigen(fremd.token, pfadHinweis, {'titel': 'Fertig'})).json, {'abgebrochen': true});

      testbetriebFuerTestsSetzen(false);
      final ohneSchalter = aufruf(dienst(zugang));
      expect((await zeigen(ohneSchalter.token, pfadHinweis, {'titel': 'Fertig'})).json, {'abgebrochen': true});

      expect(dialogeGezeigt, hasLength(3));
    });

    test('eine Antwort, die die Lehrkraft so nicht geben könnte, gilt nicht: der Dialog erscheint', () async {
      final fehlt = p.join(wurzel.path, 'gibt es nicht');
      final datei = File(p.join(wurzel.path, 'datei.txt'))..writeAsStringSync('x');
      final faelle = <(String, Map<String, Object?>, Map<String, Object?>)>[
        (pfadAuswahl, {'titel': 'A', 'eintraege': ['x', 'y']}, {'gewaehlt': [2]}),
        (pfadAuswahl, {'titel': 'A', 'eintraege': ['x', 'y']}, {'gewaehlt': [0, 1]}),
        (pfadAuswahl, {'titel': 'A', 'eintraege': ['x', 'y'], 'mehrfach': true}, {'gewaehlt': [1, 1]}),
        (pfadAuswahl, {'titel': 'A', 'eintraege': ['x', 'y'], 'mehrfach': true}, {'gewaehlt': <int>[]}),
        (pfadAuswahl, {'titel': 'A', 'eintraege': ['x']}, {'gewaehlt': ['0']}),
        (pfadEingabe, {'titel': 'A', 'art': 'link'}, {'text': 'kein Link'}),
        (pfadEingabe, {'titel': 'A', 'art': 'link'}, {'text': 'javascript:alert(1)'}),
        (pfadEingabe, {'titel': 'A'}, {'text': '   '}),
        (pfadEingabe, {'titel': 'A'}, {'text': 'zwei\nZeilen'}),
        (pfadEingabe, {'titel': 'A'}, {'text': 'x' * (eingabeHoechstens + 1)}),
        (pfadPfadwahl, {'titel': 'A', 'art': 'ordner'}, {'pfad': fehlt}),
        (pfadPfadwahl, {'titel': 'A', 'art': 'ordner'}, {'pfad': datei.path}),
        (pfadPfadwahl, {'titel': 'A', 'art': 'datei'}, {'pfad': wurzel.path}),
        (pfadPfadwahl, {'titel': 'A', 'art': 'datei'}, {'pfad': 'datei.txt'}),
        (pfadHinweis, {'titel': 'A'}, {'gewaehlt': [0]}),
      ];
      for (final (pfad, daten, antwort) in faelle) {
        final art = pfad.split('/').last;
        antwortenSchreiben([
          {'plugin': 'beispiel', 'art': art, 'titel': 'A', 'antwort': antwort},
        ]);
        final a = aufruf(dienst(zugang));
        final r = await zeigen(a.token, pfad, daten);
        expect(r.json, {'abgebrochen': true}, reason: '$daten $antwort');
        expect(a.angemeldet.testDialogantworten, 0, reason: '$daten $antwort');
        a.angemeldet.ende();
      }
      expect(dialogeGezeigt, hasLength(faelle.length));
      expect(zeilen(), contains(startsWith('Plugin „Beispiel“: Testbetrieb: Die vorbereitete Antwort hält der Prüfung')));
      expect(zeilen().join('\n'), isNot(contains('kein Link')));
    });

    test('eine ungültige Datei: der Dialog erscheint, das Protokoll nennt den Grund ohne Inhalt', () async {
      for (final inhalt in ['{"antworten": [', '[]', '{"antworten": [{"plugin": "beispiel"}]}', '{"antworten": [{"plugin": "beispiel", "art": "hinweis", "titel": "Fertig", "antwort": [1]}]}']) {
        File(antwortdatei()).writeAsStringSync(inhalt);
        final a = aufruf(dienst(zugang));
        expect((await zeigen(a.token, pfadHinweis, {'titel': 'Fertig'})).json, {'abgebrochen': true}, reason: inhalt);
        a.angemeldet.ende();
      }
      expect(dialogeGezeigt, hasLength(4));
      expect(zeilen(), contains(contains('kein gültiges JSON der erwarteten Form')));
      expect(zeilen(), contains(contains('Ein Eintrag der Datei mit vorbereiteten Dialogantworten ist ungültig')));
    });

    test('die letzte Sperre bleibt: Gesperrtes geht nicht hinaus, die Warnung beantwortet niemand', () async {
      antwortenSchreiben([
        for (final art in ['auswahl', 'eingabe', 'pfad', 'hinweis'])
          {'plugin': 'beispiel', 'art': art, 'titel': 'Gesperrt: möglicher Name', 'antwort': <String, Object?>{}},
      ]);
      final a = aufruf(dienst(zugang));
      await _post(adresse.adresse, pfadNamen, {
        'namen': ['Erika Mustermann'],
      }, token: a.token);

      final r = await _post(adresse.adresse, pfadProtokoll, {'text': 'Bearbeitet: Erika'}, token: a.token);

      expect(r.status, 422);
      expect(zeilen().join('\n'), isNot(contains('Erika')));
      expect(hinweise.offen, hasLength(1));
    });
  });

  group('Nie automatisch', () {
    /// Was im Quelltext auf den Testbetrieb oder vorbereitete Antworten zeigt.
    final testbetrieb = RegExp(
      r'testbetriebAktiv|Testzugang|imTest\(|testDialogantworten|testantwort|plugin-dialoge\.json|Testbetrieb\(',
    );

    test('Zustimmung, Entwicklungs-Plugin, Schnittstelle und Update kennen den Testbetrieb nicht', () {
      for (final datei in [
        'lib/plugin/entscheidung.dart',
        'lib/plugin/plugins.dart',
        'lib/plugin/entwicklung.dart',
        'lib/plugin/schnittstelle.dart',
        'lib/plugin/plugin_update.dart',
        'lib/plugin/pruefsumme.dart',
        'lib/einstellungen_dialog.dart',
      ]) {
        expect(File(datei).readAsStringSync(), isNot(contains(testbetrieb)), reason: datei);
      }
    });

    test('die letzte Sperre kennt den Testbetrieb nicht', () {
      for (final datei in ['lib/plugin/namenssperre.dart', 'lib/plugin/laufende_plugins.dart']) {
        final text = File(datei).readAsStringSync();
        expect(text, isNot(contains(RegExp(r'testbetriebAktiv|Testzugang|imTest\('))), reason: datei);
      }
    });

    test('vorbereitete Antworten liest nur der Dialog eines Plugins an der Adresse der App', () {
      final leser = [
        for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
          if (f.path.endsWith('.dart') && f.readAsStringSync().contains('testantwortSuchen(')) p.basename(f.path),
      ]..sort();
      expect(leser, ['app_adresse.dart', 'testantworten.dart']);
    });

    test('eine Freigabe ab „keine“ gibt der Testbetrieb nur als Bildschirmfoto oder Schreiben über eine Zusatzadresse frei', () async {
      final auto = await freigaben.imTest(
        () => freigaben.anfragen(FreigabeAnfrage(titel: 'Übergabe', punkte: const [], vergleich: const [], ab: Bestaetigungen.keine)),
        pruefen: () async => true,
      );
      expect(auto, isFalse);
      expect(gezeigt, hasLength(1));
      expect(freigaben.testfreigaben, 0);
    });
  });
}
