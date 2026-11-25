// Läufe (E36): Ein Plugin liest über seine Zusatzadressen mit der Art „lesen“
// nur in einem Lauf. Beim Beginn ermittelt moocp den Kurs der Aktivität selbst
// und lädt die Namen seiner Teilnehmenden in die Datenschutzprüfung; jede Anfrage
// des Laufs ist an Kurs und Aktivität gebunden. Dazu der Nachtrag zum rohen
// Lesen: von einer Seite nur der Hauptbereich, nie der sesskey, und der Name
// der Lehrkraft sperrt. Auf der einen Seite steht ein HTTP-Client im Test an
// Stelle eines Plugins, auf der anderen das Moodle-Doppel aus
// test/plugin_moodle_test.dart mit erfundenen Namen; das echte Beispiel-Plugin
// prüft test/plugin_start_test.dart. Alles in Temp-Ordnern.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/werkzeugquelle.dart';
import 'package:moocp/plugin/datenschutz.dart' show DatenschutzAusgang, Datenschutzwarnung;
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/plugin/adressmuster.dart';
import 'package:moocp/plugin/app_adresse.dart';
import 'package:moocp/plugin/beschreibung.dart';
import 'package:moocp/plugin/lauf.dart';
import 'package:moocp/plugin/moodle_lesen.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'hilfen/plugin_adresse.dart';
import 'plugin_moodle_test.dart';

const _schluessel = beispielSchluessel;
const _zweiterSchluessel = 'schluessel-des-zweiten-plugins-0123456789abcd';

/// Jeder Teil jedes erfundenen Namens im Doppel, klein geschrieben: Keiner
/// davon darf in einem Protokoll, einer Antwort oder einer Fehlermeldung
/// stehen, die nicht ausdrücklich den Seiteninhalt liefert.
const _namensteile = ['erika', 'max', 'mustermann', 'lieschen', 'müller', 'paula', 'musterlehrerin'];

final _zusatzadressen = [
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/bericht.php'), ZugriffsArt.lesen, 'Liest den Bericht.'),
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/fragment.php'), ZugriffsArt.lesen, 'Liest ein Stück.'),
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/ohnehaupt.php'), ZugriffsArt.lesen, 'Liest eine Seite.'),
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/daten.php'), ZugriffsArt.lesen, 'Liest Daten.'),
  // Läge sonst auf der Sperrliste (/mod/…/report.php).
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/report.php'), ZugriffsArt.lesen, 'Liest den Bericht.'),
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/speichern.php'), ZugriffsArt.schreiben, 'Speichert.'),
];

class _Kontext implements AufrufKontext {
  _Kontext(this.moodle, this.arbeitsordner);

  @override
  final MoodleZugang moodle;
  @override
  final String arbeitsordner;
  @override
  Protokoll get protokoll => moodle.protokoll;

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
  }) async => PluginFreigabeAusgang.freigegeben;

  /// Die Adresse der App fragt nie die Lehrkraft; nur die laufenden Plugins
  /// tun es (test/plugin_start_test.dart, test/plugin_datenschutz_test.dart).
  @override
  Future<DatenschutzAusgang> datenschutzwarnung({
    required Datenschutzwarnung warnung,
    required Future<void> abbruch,
    required String aufrufer,
  }) async => DatenschutzAusgang.sperren;

  @override
  String? get testDialogantworten => null;
}

/// Eine Antwort von Moodle für die Auswertung, ohne Netz.
Antwort _seite(String pfad, String html, {int status = 200, String typ = 'text/html'}) =>
    Antwort(status, Uri.parse('https://moodle.schule.example$pfad'), Uint8List.fromList(utf8.encode(html)), typ);

const _teilnehmendenpfad = '/user/index.php?id=12&perpage=5000&tifirst=&tilast=';

void main() {
  late PluginTestMoodle moodle;
  late Directory wurzel;
  late AppAdresse adresse;
  late Protokoll protokoll;
  late MoodleZugang zugang;

  setUp(() async {
    moodle = PluginTestMoodle();
    await moodle.starten();
    wurzel = Directory.systemTemp.createTempSync('moocp_plugin_lauf_');
    protokoll = Protokoll();
    zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
    await zugang.sesskey();
    protokoll.leeren();
    moodle.angefragt.clear();
    adresse = await AppAdresse.starten(Protokoll());
    adresse.pluginAnmelden('beispiel', 'Beispiel', _schluessel, zusatzadressen: _zusatzadressen);
    adresse.pluginAnmelden('zweites', 'Zweites', _zweiterSchluessel);
  });

  tearDown(() async {
    moodle.haltenBericht?.complete();
    await adresse.beenden();
    await moodle.server.close(force: true);
    wurzel.deleteSync(recursive: true);
  });

  List<String> zeilen() => [for (final e in protokoll.eintraege) '${e.art.name}: ${e.text}'];

  /// Kein Teil eines erfundenen Namens in [text].
  void ohneNamen(String text, {String? grund}) {
    for (final n in _namensteile) {
      expect(text.toLowerCase(), isNot(contains(n)), reason: grund ?? n);
    }
  }

  ({String token, void Function() ende}) aufruf({String kurzname = 'beispiel', MoodleZugang? z}) {
    final a = WerkzeugAufruf(
      name: '${kurzname}_lauf',
      args: const {},
      profil: Profil(kennung: 'A', name: 'A', adresse: 'https://moodle.schule.example', port: 1, mcpName: 'A', schluessel: 't'),
      token: aufrufToken(),
      abbruch: Completer<void>().future,
      kontext: _Kontext(z ?? zugang, (Directory(p.join(wurzel.path, 'A'))..createSync(recursive: true)).path),
    );
    return (token: a.token, ende: adresse.aufrufAnmelden(kurzname, a).ende);
  }

  String schluesselVon(String kurzname) => kurzname == 'zweites' ? _zweiterSchluessel : _schluessel;

  Future<AdresseAntwort> beginnen(String token, Object? cmid, {String kurzname = 'beispiel'}) =>
      anAdresse(adresse.adresse, pfadLaufBeginnen, {'cmid': cmid}, token: token, schluessel: schluesselVon(kurzname));

  Future<AdresseAntwort> beenden(String token) => anAdresse(adresse.adresse, pfadLaufBeenden, {}, token: token);

  Future<AdresseAntwort> lesen(String token, String pfad, {String kurzname = 'beispiel'}) =>
      anAdresse(adresse.adresse, pfadZusatzLesen, {'pfad': pfad}, token: token, schluessel: schluesselVon(kurzname));

  Future<AdresseAntwort> protokollzeile(String token, String text) =>
      anAdresse(adresse.adresse, pfadProtokoll, {'text': text}, token: token);

  /// Beginnt einen Lauf für Aktivität 501 in Kurs 12 und erwartet, dass er
  /// beginnt.
  Future<({String token, void Function() ende})> imLauf() async {
    final a = aufruf();
    final r = await beginnen(a.token, 501);
    expect(r.status, 200, reason: r.roh);
    return a;
  }

  group('Außerhalb eines Laufs', () {
    test('eine lesende Zusatzadresse ist abgelehnt; Moodle sieht nichts', () async {
      final a = aufruf();
      final r = await lesen(a.token, '/mod/beispiel/bericht.php?id=501');
      expect(r.status, 403);
      expect(r.json['fehler'], contains('nur in einem Lauf'));
      expect(r.json['fehler'], contains(pfadLaufBeginnen));
      expect(moodle.angefragt, isEmpty);
      expect(zeilen(), [
        'gesperrt: Plugin „Beispiel“: Lesen über eine Zusatzadresse außerhalb eines Laufs abgewiesen: '
            'GET /mod/beispiel/bericht.php?id=…',
      ]);
    });

    test('nach dem Ende des Laufs und nach dem Ende des Aufrufs ebenso', () async {
      final a = await imLauf();
      expect((await lesen(a.token, '/mod/beispiel/bericht.php?id=501')).status, 200);
      expect((await beenden(a.token)).status, 200);
      moodle.angefragt.clear();
      expect((await lesen(a.token, '/mod/beispiel/bericht.php?id=501')).status, 403);
      expect((await beenden(a.token)).status, 409);

      final b = await imLauf();
      b.ende();
      moodle.angefragt.clear();
      expect((await lesen(b.token, '/mod/beispiel/bericht.php?id=501')).status, 403);
      expect(moodle.angefragt, isEmpty);
    });

    test('über /v1/moodle/lesen liest ein Plugin eine Zusatzadresse auch im Lauf nicht', () async {
      final a = await imLauf();
      moodle.angefragt.clear();
      final r = await anAdresse(adresse.adresse, pfadMoodleLesen, {'pfad': '/mod/beispiel/report.php?id=501'}, token: a.token);
      expect(r.status, 403);
      expect(moodle.angefragt, isEmpty);
    });
  });

  group('Der Beginn', () {
    test('ermittelt den Kurs selbst, lädt die Namen, nennt nur den Kurs; im Protokoll nur die Zahl', () async {
      final a = aufruf();
      final r = await beginnen(a.token, 501);

      expect(r.status, 200);
      expect(r.json, {'kurs': 12});
      ohneNamen(r.roh);
      expect(moodle.angefragt, ['GET /course/modedit.php?update=501', 'GET $_teilnehmendenpfad']);
      expect(
        zeilen(),
        containsAllInOrder([
          'moodle: GET /course/modedit.php?update=501 → 200',
          'moodle: Datenschutzprüfung, Namen der Teilnehmenden: GET /user/index.php?id=…&perpage=…&tifirst=…&tilast=… → 200',
          'info: Plugin „Beispiel“: Lauf begonnen, 4 Namen zum Sperren geladen',
        ]),
      );
      ohneNamen(zeilen().join('\n'));
      for (final n in ['Erika', 'Mustermann', 'Max', 'Lieschen', 'Mueller', 'Paula', 'Musterlehrerin']) {
        expect(adresse.pruefung.treffer('beispiel', [n]), isNotNull, reason: n);
      }
      // Kürzel und Bild gehören nicht zum Namen.
      expect(adresse.pruefung.treffer('beispiel', ['EM PM']), isNull);
      // Nur für dieses Plugin.
      expect(adresse.pruefung.treffer('zweites', ['Erika']), isNull);
    });

    test('ein Kurs ohne Teilnehmende oder nur mit der Lehrkraft ist kein Fehler', () async {
      final leer = aufruf();
      final r = await beginnen(leer.token, 601);
      expect(r.json, {'kurs': 13});
      expect(zeilen(), contains('info: Plugin „Beispiel“: Lauf begonnen, 0 Namen zum Sperren geladen'));
      final allein = aufruf();
      expect((await beginnen(allein.token, 701)).json, {'kurs': 14});
      expect(zeilen(), contains('info: Plugin „Beispiel“: Lauf begonnen, 1 Name zum Sperren geladen'));
    });

    test('je Aufruf höchstens ein Lauf zugleich; nach dem Ende ein neuer', () async {
      final a = await imLauf();
      final zweiter = await beginnen(a.token, 701);
      expect(zweiter.status, 409);
      expect((await beenden(a.token)).status, 200);
      expect((await beginnen(a.token, 701)).json, {'kurs': 14});
      expect((await lesen(a.token, '/mod/beispiel/bericht.php?id=501')).status, 403, reason: 'Lauf gilt für 701');
    });

    test('cmid fehlt oder ist keine Zahl: 400; nicht angemeldet: 503; ohne Token: 403', () async {
      final a = aufruf();
      for (final cmid in [null, '501', -1, 0, 1.5, 99999999999]) {
        expect((await beginnen(a.token, cmid)).status, 400, reason: '$cmid');
      }
      final ohne = aufruf(z: MoodleZugang(protokoll));
      expect((await beginnen(ohne.token, 501)).status, 503);
      expect((await anAdresse(adresse.adresse, pfadLaufBeginnen, {'cmid': 501})).status, 403);
      expect(moodle.angefragt, isEmpty);
    });

    group('Im Zweifel kein Lauf', () {
      /// Erwartet, dass für Aktivität [cmid] kein Lauf beginnt: ein Fehler mit
      /// Grund, keine Namen geladen, lesende Zusatzadressen weiter gesperrt,
      /// kein Name in Antwort, Fehlermeldung oder Protokoll.
      Future<void> keinLauf(String fall, {int cmid = 501, String? grund}) async {
        final a = aufruf();
        final r = await beginnen(a.token, cmid);
        expect(r.status, anyOf(502, 403, 404), reason: fall);
        expect(r.json.keys, ['fehler'], reason: fall);
        expect(r.json['fehler'], contains('Kein Lauf begonnen'), reason: fall);
        if (grund != null) expect(r.json['fehler'], contains(grund), reason: fall);
        ohneNamen(r.roh, grund: fall);
        for (final n in ['Erika', 'Max', 'Lieschen']) {
          expect(adresse.pruefung.treffer('beispiel', [n]), isNull, reason: '$fall: $n');
        }
        moodle.angefragt.clear();
        expect((await lesen(a.token, '/mod/beispiel/bericht.php?id=$cmid')).status, 403, reason: fall);
        expect(moodle.angefragt, isEmpty, reason: fall);
        ohneNamen(zeilen().where((z) => !z.contains('Lehrkraft')).join('\n'), grund: fall);
        a.ende();
      }

      String tabelle(List<TeilnehmendeImDoppel> personen, {String? gesamt, String zusatz = '', String zeilen = ''}) =>
          teilnehmendenseiteImDoppel(12, personen, gesamt: gesamt, zusatz: zusatz, zeilen: zeilen);

      test('der Kurs lässt sich nicht ermitteln', () async {
        await keinLauf('unbekannte Aktivität', cmid: 555, grund: 'Kurs der Aktivität');
        moodle.formular[501] =
            '<form><input type="hidden" name="course" value="13"><input type="hidden" name="coursemodule" value="501"></form>';
        await keinLauf('Formular nennt einen anderen Kurs', grund: 'nicht eindeutig');
        moodle.formular[501] = '<form><input type="hidden" name="course" value="12"></form>';
        await keinLauf('Formular ohne Aktivität', grund: 'nicht eindeutig');
        moodle.formular[501] =
            '<form><input type="hidden" name="course" value="12"><input type="hidden" name="coursemodule" value="502"></form>';
        await keinLauf('Formular einer anderen Aktivität', grund: 'nicht eindeutig');
      });

      test('die Teilnehmendenseite lässt sich nicht lesen', () async {
        moodle.teilnehmendenseite[12] = 'fehler';
        await keinLauf('Serverfehler', grund: 'nicht abrufbar');
        moodle.teilnehmendenseite[12] = 'umleitung';
        await keinLauf('Umleitung auf eine andere Form der Seite');
        expect(zeilen(), contains(startsWith('gesperrt: Datenschutzprüfung, Namen der Teilnehmenden: Datenschutz-Sperre: GET /user/index.php?id=…')));
      });

      test('die Teilnehmendenseite lässt sich nicht sicher auswerten', () async {
        final faelle = <String, String>{
          'ohne Gesamtzahl': moodleSeite('<table id="participants"><tbody></tbody></table>'),
          'Zahl passt nicht': tabelle(teilnehmendeKurs12, gesamt: '5'),
          'Zahl zu klein': tabelle(teilnehmendeKurs12, gesamt: '3'),
          'zwei Zahlen': tabelle(teilnehmendeKurs12, gesamt: '4 von 9'),
          'leer, obwohl die Seite Teilnehmende nennt': tabelle(const [], gesamt: '3'),
          'mehr als 5000': tabelle(teilnehmendeKurs12, gesamt: '5001'),
          'eine zweite Seite': tabelle(
            teilnehmendeKurs12,
            zusatz: '<nav><a href="/user/index.php?id=12&amp;page=1">2</a></nav>',
          ),
          'eine zweite Seite der Tabelle': tabelle(teilnehmendeKurs12, zusatz: '<a href="#" data-page-number="2">2</a>'),
          'ein Filter nach Anfangsbuchstaben': teilnehmendenseiteImDoppel(
            12,
            teilnehmendeKurs12,
            initialen: '<li class="initialbarall page-item"><a>Alle</a></li><li class="page-item active"><a>E</a></li>',
          ),
          'eine Zeile ohne Link': tabelle(teilnehmendeKurs12, gesamt: '5', zeilen: '<tr><th>Ohne Link</th></tr>'),
          'eine Zeile mit zwei Personen': tabelle(
            teilnehmendeKurs12,
            gesamt: '5',
            zeilen:
                '<tr><th><a href="/user/view.php?id=20&amp;course=12">A</a><a href="/user/view.php?id=21&amp;course=12">B</a></th></tr>',
          ),
          'ein Link in einen anderen Kurs': tabelle(
            teilnehmendeKurs12,
            gesamt: '5',
            zeilen: '<tr><th><a href="/user/view.php?id=20&amp;course=13">Otto Normalverbraucher</a></th></tr>',
          ),
          'ein Kürzel, das nicht zum Namen passt': tabelle(
            teilnehmendeKurs12,
            gesamt: '5',
            zeilen:
                '<tr><th><a href="/user/view.php?id=20&amp;course=12"><span class="userinitials" title="Otto Normalverbraucher">ON</span>'
                'Anna Andere</a></th></tr>',
          ),
          'ein Name ohne Buchstaben': tabelle(
            teilnehmendeKurs12,
            gesamt: '5',
            zeilen: '<tr><th><a href="/user/view.php?id=20&amp;course=12"> – </a></th></tr>',
          ),
          'ohne Tabelle': teilnehmendenseiteImDoppel(12, teilnehmendeKurs12, tabelle: false),
          'die Seite eines anderen Kurses': teilnehmendenseiteImDoppel(13, const []),
        };
        for (final MapEntry(key: fall, value: seite) in faelle.entries) {
          moodle.teilnehmendenseite[12] = seite;
          await keinLauf(fall);
        }
      });
    });
  });

  group('Im Lauf lesen', () {
    test('eine Zusatzadresse „lesen“: nur der Hauptbereich, ohne sesskey, Lehrkraft und Blöcke', () async {
      final a = await imLauf();
      moodle.angefragt.clear();
      protokoll.leeren();
      final r = await lesen(a.token, '/mod/beispiel/bericht.php?id=501');

      expect(r.status, 200);
      expect(r.json.keys.toSet(), {'status', 'inhaltstyp', 'pfad', 'text'});
      expect(r.json['status'], 200);
      expect(r.json['pfad'], '/mod/beispiel/bericht.php?id=501');
      final text = r.json['text'] as String;
      expect(text, startsWith('<section id="region-main"'));
      expect(text, contains('<h3>Bericht</h3>'));
      // Was im Hauptbereich steht, bekommt das Plugin; dafür steht es ein.
      expect(text, contains('Erika Mustermann: 3 Punkte'));
      for (final weg in ['abc123', lehrkraftImDoppel, 'M.cfg', 'usermenu', 'logininfo', 'block_online_users']) {
        expect(r.roh, isNot(contains(weg)), reason: weg);
      }
      expect(text, contains('sesskey=…'));
      expect(moodle.angefragt, ['GET /mod/beispiel/bericht.php?id=501']);
      expect(zeilen(), ['moodle: Plugin „Beispiel“, Zusatzadresse: GET /mod/beispiel/bericht.php?id=… → 200']);
    });

    test('für eine Zusatzadresse dieses Plugins gilt die Sperrliste nicht', () async {
      final a = await imLauf();
      moodle.angefragt.clear();
      final r = await lesen(a.token, '/mod/beispiel/report.php?id=501');
      expect(r.status, 200);
      expect(moodle.angefragt, ['GET /mod/beispiel/report.php?id=501']);
    });

    test('ein Stück HTML ohne Seite bleibt, eine Seite ohne Hauptbereich nicht, JSON ohne sesskey', () async {
      final a = await imLauf();
      expect((await lesen(a.token, '/mod/beispiel/fragment.php?id=501')).json['text'], '<div class="teil">Teil</div>');
      final ohne = await lesen(a.token, '/mod/beispiel/ohnehaupt.php?id=501');
      expect(ohne.status, 502);
      expect(ohne.json['fehler'], KeinHauptbereich.meldung);
      expect(ohne.roh, isNot(contains('Kein Hauptbereich</div>')));
      final daten = await lesen(a.token, '/mod/beispiel/daten.php?id=501');
      expect(daten.json['inhaltstyp'], 'application/json');
      expect(daten.json['text'], '{"sesskey":"…","werte":[1,2]}');
    });

    test('nur Zusatzadressen „lesen“ dieses Plugins; die eines anderen Plugins nicht', () async {
      final a = await imLauf();
      moodle.angefragt.clear();
      for (final pfad in ['/mod/beispiel/speichern.php?id=501', '/mod/page/view.php?id=501', '/question/banks.php?courseid=12']) {
        final r = await lesen(a.token, pfad);
        expect(r.status, 403, reason: pfad);
        expect(r.json['fehler'], contains('keine Zusatzadresse dieses Plugins'), reason: pfad);
      }
      final b = aufruf(kurzname: 'zweites');
      expect((await beginnen(b.token, 501, kurzname: 'zweites')).status, 200);
      moodle.angefragt.clear();
      final r = await lesen(b.token, '/mod/beispiel/bericht.php?id=501', kurzname: 'zweites');
      expect(r.status, 403);
      expect(moodle.angefragt, isEmpty);
    });

    test('eine andere Kurs- oder Aktivitätsnummer, in jeder Schreibweise: 403, Moodle sieht nichts', () async {
      final a = await imLauf();
      moodle.angefragt.clear();
      protokoll.leeren();
      for (final pfad in [
        '/mod/beispiel/bericht.php?id=502',
        '/mod/beispiel/bericht.php?id=501&id=502',
        '/mod/beispiel/bericht.php?id=12',
        '/mod/beispiel/bericht.php?id=501&course=13',
        '/mod/beispiel/bericht.php?id=501&courseid=13',
        '/mod/beispiel/bericht.php?id=501&Course=13',
        '/mod/beispiel/bericht.php?id=501&%63ourse=13',
        '/mod/beispiel/bericht.php?id=501&course%5B%5D=13',
        '/mod/beispiel/bericht.php?id=501&course.=13',
        '/mod/beispiel/bericht.php?id=501&course=12abc',
        '/mod/beispiel/bericht.php?id=501&course=12%20',
        '/mod/beispiel/bericht.php?id=501&course=',
        '/mod/beispiel/bericht.php?id=0501',
        '/mod/beispiel/bericht.php?id=501&cmid=502',
        '/mod/beispiel/bericht.php?id=501&cm=502',
        '/mod/beispiel/bericht.php?id=501&coursemodule=502',
        '/mod/beispiel/bericht.php?id=501&contextid=960',
        '/mod/beispiel/bericht.php?id=501&contextid=1',
        '/mod/beispiel/bericht.php',
        '/mod/beispiel/bericht.php?d=5&seite=2',
      ]) {
        final r = await lesen(a.token, pfad);
        expect(r.status, 403, reason: pfad);
        expect(r.json['fehler'], startsWith('Abgelehnt: Die Adresse nennt'), reason: pfad);
      }
      expect(moodle.angefragt, isEmpty);
      expect(zeilen().first, 'gesperrt: Plugin „Beispiel“: Im Lauf abgewiesen: GET /mod/beispiel/bericht.php?id=… (passt nicht zum Lauf)');
      expect(zeilen().join('\n'), isNot(contains('502')));
    });

    test('was zum Lauf passt, geht durch: Aktivität, Kurs, Kontext von Kurs und Aktivität', () async {
      final a = await imLauf();
      for (final pfad in [
        '/mod/beispiel/bericht.php?id=501',
        '/mod/beispiel/bericht.php?id=501&course=12',
        '/mod/beispiel/bericht.php?cmid=501',
        '/mod/beispiel/bericht.php?courseid=12&seite=2',
        '/mod/beispiel/bericht.php?contextid=950',
        '/mod/beispiel/bericht.php?contextid=812',
      ]) {
        expect((await lesen(a.token, pfad)).status, 200, reason: pfad);
      }
    });

    test('jedes Umleitungsziel wird geprüft wie die Adresse, auch auf Kurs und Aktivität', () async {
      final a = await imLauf();
      for (final (umleitung, grund) in [
        ('1', 'andere Aktivität'),
        // Die Bindung an den Lauf greift vor der Sperrliste.
        ('2', 'keine Kurs-, Aktivitäts- oder Kontextnummer'),
        ('4', 'Gesperrt für jedes Plugin'),
      ]) {
        moodle.angefragt.clear();
        final r = await lesen(a.token, '/mod/beispiel/bericht.php?id=501&umleitung=$umleitung');
        expect(r.status, 403, reason: umleitung);
        expect(r.json['fehler'], contains(grund), reason: umleitung);
        expect(moodle.angefragt, ['GET /mod/beispiel/bericht.php?id=501&umleitung=$umleitung'], reason: umleitung);
      }
      final r = await lesen(a.token, '/mod/beispiel/bericht.php?id=501&umleitung=3');
      expect(r.status, 200);
      expect(r.json['pfad'], '/mod/beispiel/bericht.php?id=501&seite=2');
    });

    test('endet der Lauf oder der Aufruf, während Moodle noch antwortet: 409, nichts geht hinaus', () async {
      final a = await imLauf();
      moodle.haltenBericht = Completer<void>();
      final offen = lesen(a.token, '/mod/beispiel/bericht.php?id=501&warten=1');
      while (!moodle.angefragt.any((x) => x.contains('warten=1'))) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect((await beenden(a.token)).status, 200);
      final r = await offen;
      expect(r.status, 409);
      expect(r.roh, isNot(contains('Bericht')));
      moodle.haltenBericht!.complete();

      final b = await imLauf();
      moodle.haltenBericht = Completer<void>();
      moodle.angefragt.clear();
      final offenB = lesen(b.token, '/mod/beispiel/bericht.php?id=501&warten=1');
      while (moodle.angefragt.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      b.ende();
      expect((await offenB).status, 409);
    });

    test('nach einem Schreibvorgang folgt moocp im Lauf einer Umleitung auf eine Zusatzadresse „lesen“, die passt', () async {
      Future<AdresseAntwort> schreiben(String token, String pfad) async {
        final daten = {
          'methode': 'POST',
          'pfad': pfad,
          'felder': [
            {'name': 'notiz', 'wert': 'Hallo'},
          ],
        };
        final f = await anAdresse(adresse.adresse, pfadZusatzFreigabe, {...daten, 'titel': 'T', 'zusammenfassung': 'Z'}, token: token);
        return anAdresse(adresse.adresse, pfadZusatzSchreiben, {...daten, 'kennung': f.json['kennung']}, token: token);
      }

      final ohne = aufruf();
      final r0 = await schreiben(ohne.token, '/mod/beispiel/speichern.php?id=40');
      expect(r0.json['umleitungNichtGelesen'], contains('Geschrieben ist schon'));

      final a = await imLauf();
      final r = await schreiben(a.token, '/mod/beispiel/speichern.php?id=40');
      expect(r.status, 200);
      expect(r.json['pfad'], '/mod/beispiel/bericht.php?id=501');
      expect(r.json.containsKey('umleitungNichtGelesen'), isFalse);
      expect(r.json['text'], startsWith('<section id="region-main"'));
      for (final weg in ['abc123', lehrkraftImDoppel, 'M.cfg']) {
        expect(r.roh, isNot(contains(weg)), reason: weg);
      }

      final anders = await schreiben(a.token, '/mod/beispiel/speichern.php?id=41');
      expect(anders.json['umleitungNichtGelesen'], contains('andere Aktivität'));
    });
  });

  group('Datenschutzprüfung', () {
    test('die Namen des Kurses treffen für dieses Plugin, auch nach dem Ende von Lauf und Aufruf: Platzhalter statt Zeile', () async {
      final a = await imLauf();
      Future<bool> platzhalter(String token, String text) async {
        final vorher = zeilen().where((z) => z.endsWith(protokollPlatzhalterName)).length;
        final r = await protokollzeile(token, text);
        expect(r.status, 200, reason: text);
        return zeilen().where((z) => z.endsWith(protokollPlatzhalterName)).length == vorher + 1;
      }

      expect(await platzhalter(a.token, 'Lieschen hat abgegeben'), isTrue);
      await beenden(a.token);
      expect(await platzhalter(a.token, 'Müller fehlt'), isTrue);
      a.ende();
      final b = aufruf();
      expect(await platzhalter(b.token, 'mustermann'), isTrue);
      expect(await platzhalter(b.token, 'Aufgabe 3 fertig'), isFalse);
      // Ohne Token gilt die Prüfung ebenso.
      final ohne = await anAdresse(adresse.adresse, pfadProtokoll, {'text': 'Erika'});
      expect(ohne.status, 200);
      expect(zeilen().where((z) => z.endsWith(protokollPlatzhalterName)), hasLength(3), reason: 'ohne Token geht die Zeile ins Protokoll der App');
      ohneNamen(zeilen().join('\n'));
    });

    test('der Name der Lehrkraft sperrt, sobald moocp eine Seite mit der Anmeldezeile gelesen hat', () async {
      final a = aufruf();
      expect((await protokollzeile(a.token, 'Paula')).status, 200, reason: 'noch nicht bekannt');
      final r = await anAdresse(adresse.adresse, pfadMoodleLesen, {'pfad': '/question/banks.php?courseid=12'}, token: a.token);
      expect(r.status, 200);
      expect(zugang.lehrkraftNamen, [lehrkraftImDoppel]);
      expect((await protokollzeile(a.token, 'Frau Musterlehrerin')).status, 200);
      expect(zeilen(), contains('info: Plugin „Beispiel“: $protokollPlatzhalterName'));
      // Für jedes Plugin, das in diesem Profil arbeitet.
      final b = aufruf(kurzname: 'zweites');
      expect(
        (await anAdresse(adresse.adresse, pfadProtokoll, {'text': 'Paula'}, token: b.token, schluessel: _zweiterSchluessel)).status,
        200,
      );
      expect(zeilen().where((z) => z == 'info: Plugin „Beispiel“: $protokollPlatzhalterName'), hasLength(1));
      ohneNamen(zeilen().where((z) => !z.contains('Paula')).join('\n'));
      expect(zeilen().join('\n'), isNot(contains('Musterlehrerin')));
    });
  });

  group('Rohes Lesen: nur der Hauptbereich', () {
    test('ohne Kopf, Nutzermenü, Blöcke, Fuß und sesskey', () async {
      final a = aufruf();
      final r = await anAdresse(adresse.adresse, pfadMoodleLesen, {'pfad': '/question/banks.php?courseid=12'}, token: a.token);
      expect(r.status, 200);
      expect(r.json['text'], '<section id="region-main" aria-label="Inhalt">Fragensammlungen</section>');
      for (final weg in ['abc123', lehrkraftImDoppel, 'Erika', 'M.cfg', 'logininfo', 'usermenu']) {
        expect(r.roh, isNot(contains(weg)), reason: weg);
      }
    });

    test('ohne Hauptbereich keine Seite, auch kein Stück HTML; das Protokoll sagt es ohne Werte', () async {
      final a = aufruf();
      for (final id in ['21', '22']) {
        final r = await anAdresse(adresse.adresse, pfadMoodleLesen, {'pfad': '/mod/learningmap/view.php?id=$id'}, token: a.token);
        expect(r.status, 502, reason: id);
        expect(r.json, {'fehler': KeinHauptbereich.meldung}, reason: id);
      }
      expect(zeilen(), contains('gesperrt: Plugin „Beispiel“: Seite nicht geliefert (kein Hauptbereich): GET /mod/learningmap/view.php'));
    });

    test('eine Datei bleibt, wie sie ist', () async {
      final a = aufruf();
      final r = await anAdresse(adresse.adresse, pfadMoodleLesen, {'pfad': '/pluginfile.php/55/mod_folder/content/0/blatt.pdf'}, token: a.token);
      expect(r.status, 200);
      expect((r.json['text'] as String).length, 2048);
    });
  });

  group('Die Regeln für sich', () {
    test('textFuerPlugin: Hauptbereich, Stück, JSON und der sesskey in jeder Form', () {
      const seite =
          '<html><head><script>M.cfg={"sesskey":"k3Y9zz8aQ1"};</script></head><body><div id="region-main">'
          '<form><input type="hidden" name="sesskey" value="k3Y9zz8aQ1"><input value="x" name="sesskey"></form>'
          '<a href="/x.php?a=1&amp;sesskey=k3Y9zz8aQ1">x</a><script>var s = "k3Y9zz8aQ1";</script></div>'
          '<div class="usermenu">Paula</div></body></html>';
      final t = textFuerPlugin(_seite('/x.php', seite), zusatzadresse: false);
      expect(t, isNot(contains('k3Y9zz8aQ1')));
      expect(t, isNot(contains('Paula')));
      expect(t, startsWith('<div id="region-main">'));
      expect(t, contains('name="sesskey" value="…"'));
      expect(t, contains('sesskey=…'));
      // Bekannt aus der Sitzung, auch wo die Seite ihn nicht in M.cfg nennt.
      expect(
        textFuerPlugin(_seite('/x.json', '{"a":"k3Y9zz8aQ1"}', typ: 'application/json'), zusatzadresse: true, sesskeys: ['k3Y9zz8aQ1']),
        '{"a":"…"}',
      );
      expect(textFuerPlugin(_seite('/x.txt', 'Hallo Welt', typ: 'text/plain'), zusatzadresse: false), 'Hallo Welt');
      expect(textFuerPlugin(_seite('/x.php', '<div>Teil</div>'), zusatzadresse: true), '<div>Teil</div>');
      expect(() => textFuerPlugin(_seite('/x.php', '<div>Teil</div>'), zusatzadresse: false), throwsA(isA<KeinHauptbereich>()));
      expect(
        () => textFuerPlugin(_seite('/x.php', '<HTML><BODY>ohne</BODY></HTML>'), zusatzadresse: true),
        throwsA(isA<KeinHauptbereich>()),
      );
    });

    test('lehrkraftNamenIn: nur Links auf das Profil in der Anmeldezeile', () {
      expect(lehrkraftNamenIn(moodleSeite('x')), [lehrkraftImDoppel]);
      expect(
        lehrkraftNamenIn(
          '<div class="logininfo"><div class="logininfo">Angemeldet als <a href="/user/profile.php?id=2">Admin Muster</a>, '
          '<a href="https://m.example/user/profile.php?id=5">Erika  Mustermann</a> (<a href="/login/logout.php">Logout</a>)</div></div>',
        ),
        ['Admin Muster', 'Erika Mustermann'],
      );
      expect(lehrkraftNamenIn('<div class="usermenu"><a href="/user/profile.php?id=3">Profil</a></div>'), isEmpty);
      expect(lehrkraftNamenIn('<div class="logininfo">Sie sind nicht angemeldet. (<a href="/login/index.php">Login</a>)</div>'), isEmpty);
    });

    test('laufBindungVerletzt: id je nach Skript, Dateien nach Kontext', () {
      final lauf = Lauf(kurs: 12, cmid: 501, kurskontext: 812, modulkontext: 950);
      String? b(String pfad) => laufBindungVerletzt(lauf, Uri.parse('https://m.example$pfad'));
      for (final passt in [
        '/mod/x/view.php?id=501',
        '/mod/x/index.php?id=12',
        '/course/x.php?id=12',
        '/report/x/index.php?id=12',
        '/local/x/seite.php?id=12',
        '/user/view.php?id=7&course=12',
        '/pluginfile.php/950/mod_x/inhalt/0/a.txt',
        '/pluginfile.php/812/course/overviewfiles/a.png',
        '/pluginfile.php?file=/950/mod_x/inhalt/0/a.txt',
        '/mod/x/view.php?cmid=501&id=501&seite=3',
      ]) {
        expect(b(passt), isNull, reason: passt);
      }
      for (final nicht in [
        '/mod/x/view.php?id=12',
        '/mod/x/index.php?id=501',
        '/course/x.php?id=501',
        '/local/x/seite.php?id=13',
        '/user/view.php?id=7',
        '/user/view.php?id=7&course=13',
        '/pluginfile.php/999/mod_x/inhalt/0/a.txt',
        '/pluginfile.php?file=/999/mod_x/a.txt',
        '/pluginfile.php?file=950/mod_x/a.txt',
        '/draftfile.php/5/user/draft/1/a.txt',
        '/mod/x/view.php?a=5',
        '/mod/x/view.php',
        '/mod/x/view.php?id=501&contextid=950&contextid=1',
      ]) {
        expect(b(nicht), isNotNull, reason: nicht);
      }
      // Ohne bekannte Kontexte passt kein Kontext.
      final ohne = Lauf(kurs: 12, cmid: 501);
      expect(laufBindungVerletzt(ohne, Uri.parse('https://m.example/pluginfile.php/950/mod_x/a.txt')), isNotNull);
    });

    test('kursAusFormular und teilnehmendeAuswerten ohne Netz, mit und ohne Kürzel und Bild', () {
      final formular = _seite(
        '/course/modedit.php',
        moodleSeite(
          '<form><input type="hidden" name="course" value="12"><input type="hidden" name="coursemodule" value="501"></form>',
          kontext: 950,
        ),
      );
      expect(kursAusFormular(formular, 501), (kurs: 12, modulkontext: 950));
      expect(() => kursAusFormular(formular, 502), throwsA(isA<LaufFehler>()));

      final t = teilnehmendeAuswerten(_seite(_teilnehmendenpfad, teilnehmendenseiteImDoppel(12, teilnehmendeKurs12)), 12);
      expect(t.namen, ['Erika Mustermann', 'Max Mustermann', 'Lieschen Müller', lehrkraftImDoppel]);
      expect(t.kurskontext, 812);
      final leer = teilnehmendeAuswerten(_seite(_teilnehmendenpfad, teilnehmendenseiteImDoppel(12, const [], tabelle: false)), 12);
      expect(leer.namen, isEmpty);
      expect(
        () => teilnehmendeAuswerten(_seite(_teilnehmendenpfad, teilnehmendenseiteImDoppel(12, teilnehmendeKurs12), status: 404), 12),
        throwsA(isA<LaufFehler>()),
      );
      // Eine Fehlermeldung trägt keinen Namen, auch nicht in toString.
      try {
        teilnehmendeAuswerten(_seite(_teilnehmendenpfad, teilnehmendenseiteImDoppel(12, teilnehmendeKurs12, gesamt: '9')), 12);
        fail('kein Fehler');
      } on LaufFehler catch (x) {
        ohneNamen(x.grund);
        expect('$x', 'LaufFehler');
      }
    });
  });
}
