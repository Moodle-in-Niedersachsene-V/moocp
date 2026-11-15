// Ein Plugin liest Moodle über die Adresse der App (E36): nur GET, nur der
// lesende Teil der Positivliste, vorher die für jedes Plugin gesperrten
// Bereiche und die Sperrliste, für die Adresse und jedes Umleitungsziel. Was
// nicht erlaubt ist, erreicht Moodle nie und kommt ohne Dialog als Ablehnung
// zurück. Auf der einen Seite steht ein HTTP-Client im Test an Stelle eines
// Plugins, auf der anderen ein Moodle-Doppel auf 127.0.0.1; das echte
// Beispiel-Plugin prüft test/plugin_start_test.dart. Die Adressentscheidung
// steht hier gegen dieselben Tabellen wie die Sperrliste
// (test/sperrliste_test.dart). Alles in Temp-Ordnern.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/werkzeugquelle.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/moodle/sperrliste.dart';
import 'package:moocp/plugin/app_adresse.dart';
import 'package:moocp/plugin/moodle_lesen.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'hilfen/plugin_adresse.dart';
import 'sperrliste_test.dart' show mussDurchlassen, mussSperren, werkzeugGet;

const _schluessel = beispielSchluessel;

/// Der Wert des Sitzungscookies, den das Doppel setzt: Er darf nie in einer
/// Antwort an das Plugin oder im Protokoll stehen.
const sitzungsCookie = 'sitzungswert-geheim-4711';

/// Der erfundene Name der angemeldeten Lehrkraft im Doppel: Er steht im
/// Nutzermenü und in der Anmeldezeile jeder ganzen Seite.
const lehrkraftImDoppel = 'Paula Musterlehrerin';

/// Eine ganze Seite, wie Moodle sie mit Standardlayout liefert (Theme Boost,
/// vereinfacht): `M.cfg` mit sesskey, Kurs und Kontext im Kopf, Nutzermenü
/// mit dem Namen der Lehrkraft, ein Block mit einem Namen, der Hauptbereich
/// mit [inhalt], im Fuß die Anmeldezeile und ein Skript mit dem sesskey.
String moodleSeite(String inhalt, {int kurs = 12, int kontext = 900}) =>
    '<!DOCTYPE html><html><head><title>Seite</title><script>M.cfg = {"wwwroot":"http://x","sesskey":"abc123",'
    '"courseId":$kurs,"contextid":$kontext,"userId":3};</script></head><body>'
    '<nav class="navbar"><div class="usermenu"><span class="userinitials" title="$lehrkraftImDoppel">PM</span>'
    '<span class="usertext">$lehrkraftImDoppel</span></div></nav>'
    '<aside class="block_online_users"><a href="/user/view.php?id=7&amp;course=$kurs">Erika Mustermann</a></aside>'
    '<div id="page"><div id="region-main-box"><section id="region-main" aria-label="Inhalt">$inhalt</section></div></div>'
    '<footer id="page-footer"><div class="logininfo">Sie sind angemeldet als <a href="http://x/user/profile.php?id=3" '
    'title="Profil anzeigen">$lehrkraftImDoppel</a> (<a href="http://x/login/logout.php?sesskey=abc123">Logout</a>)'
    '</div></footer><script>M.util.js_complete("abc123");</script></body></html>';

/// Eine Person auf der Teilnehmendenseite des Doppels: Nummer, voller Name
/// und wie das Bild aussieht (Kürzel aus Initialen, Bild oder nichts).
typedef TeilnehmendeImDoppel = ({int id, String name, String bild});

/// Die Teilnehmendenseite eines Kurses (`/user/index.php`), nach Moodles
/// Standardseite (vereinfacht, nicht an einer Instanz gemessen). [gesamt]
/// ersetzt die Gesamtzahl, [zusatz] steht vor der Tabelle, [zeilen] nach den
/// Personen in `tbody`; ohne [tabelle] steht statt ihr ein Hinweis.
String teilnehmendenseiteImDoppel(
  int kurs,
  List<TeilnehmendeImDoppel> personen, {
  String? gesamt,
  String zusatz = '',
  String zeilen = '',
  bool tabelle = true,
  String initialen = '<li class="initialbarall page-item active"><a class="page-link">Alle</a></li>'
      '<li class="page-item"><a class="page-link">A</a></li>',
}) {
  String zeile(TeilnehmendeImDoppel t) {
    final bild = switch (t.bild) {
      'kuerzel' =>
        '<span class="userinitials size-35" title="${t.name}" aria-label="${t.name}" role="img">'
            '${t.name.split(' ').map((w) => w[0]).join()}</span>',
      'bild' => '<img src="/pluginfile.php/5/user/icon/boost/f2" class="userpicture" width="35" height="35" alt="">',
      _ => '',
    };
    return '<tr><td class="cell c0"><input type="checkbox" class="usercheckbox" name="user${t.id}">'
        '<label for="user${t.id}" class="accesshide">${t.name} auswählen</label></td>'
        '<th class="cell c1"><a href="http://x/user/view.php?id=${t.id}&amp;course=$kurs" class="d-inline-block aabtn">'
        '$bild${t.name}</a></th><td class="cell c2">Teilnehmer/in</td><td class="cell c3">Aktiv</td></tr>';
  }

  final liste = tabelle
      ? '<table id="participants" class="generaltable"><thead><tr><th>Vorname / Nachname</th></tr></thead>'
            '<tbody>${personen.map(zeile).join()}$zeilen<tr class="emptyrow"><td></td></tr></tbody></table>'
      : '<div class="alert">Nichts anzuzeigen</div>';
  return moodleSeite(
    '<div class="initialbar firstinitial"><nav><ul class="pagination">$initialen</ul></nav></div>$zusatz'
    '<p data-region="participant-count" class="mb-1">${gesamt ?? '${personen.length}'} Teilnehmer/innen gefunden</p>'
    '$liste',
    kurs: kurs,
    kontext: 800 + kurs,
  );
}

/// Die Teilnehmenden in Kurs 12 im Doppel: drei Personen und die Lehrkraft,
/// mit Kürzel, mit Bild und ohne beides.
const teilnehmendeKurs12 = <TeilnehmendeImDoppel>[
  (id: 7, name: 'Erika Mustermann', bild: 'kuerzel'),
  (id: 8, name: 'Max Mustermann', bild: 'bild'),
  (id: 9, name: 'Lieschen Müller', bild: ''),
  (id: 3, name: lehrkraftImDoppel, bild: 'kuerzel'),
];

/// So groß ist die erfundene Datei `/mod/beispiel/export.php` im Doppel.
const exportGroesse = 1234;

/// Ein Moodle, das die Anmeldung kann, ein paar Seiten und Dateien liefert,
/// Umleitungen auf Erlaubtes und Unerlaubtes macht und alles Angefragte
/// mitschreibt. Auch für den Ende-zu-Ende-Test mit dem Beispiel-Plugin.
class PluginTestMoodle {
  late final HttpServer server;
  late final Uri basis;

  /// Jede Anfrage, die den Server erreicht hat: `GET /pfad?query`.
  final angefragt = <String>[];
  var eingeloggt = false;

  /// Die nächste Anfrage außerhalb der Anmeldung landet auf der Anmeldeseite.
  var sitzungAbgelaufen = false;

  /// Hält die Antwort auf `/mod/board/view.php?id=99` an, bis sie sich erfüllt.
  Completer<void>? halten;

  /// Der Inhalt jeder Anfrage, in derselben Reihenfolge wie [angefragt].
  final rumpfe = <String>[];

  /// Was zuletzt an die erfundene Seite `/mod/beispiel/speichern.php`
  /// gesendet wurde (Feld `notiz`); ihre Ansicht zeigt es.
  String? notiz;

  /// Die Aktivitäten, deren Bearbeitungsformular das Doppel kennt, mit Kurs
  /// und Kontext; [formular] ersetzt das Formular einer Aktivität.
  final aktivitaeten = <int, ({int kurs, int kontext})>{
    501: (kurs: 12, kontext: 950),
    502: (kurs: 12, kontext: 951),
    601: (kurs: 13, kontext: 960),
    701: (kurs: 14, kontext: 970),
  };
  final formular = <int, String>{};

  /// Die Teilnehmendenseite je Kurs, wenn sie von der aus [teilnehmende]
  /// abweichen soll; `umleitung` und `fehler` stehen für eine Umleitung und
  /// einen Serverfehler.
  final teilnehmendenseite = <int, String>{};
  final teilnehmende = <int, List<TeilnehmendeImDoppel>>{
    12: teilnehmendeKurs12,
    13: const [],
    14: const [(id: 3, name: lehrkraftImDoppel, bild: 'kuerzel')],
  };

  /// Hält die Antwort auf `/mod/beispiel/bericht.php?…&warten=1` an, bis sie
  /// sich erfüllt.
  Completer<void>? haltenBericht;

  Future<void> starten() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    basis = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen(_bedienen);
  }

  Future<void> _bedienen(HttpRequest req) async {
    rumpfe.add(await utf8.decoder.bind(req).join());
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

    Future<void> datei(List<int> bytes, ContentType typ) {
      r
        ..headers.contentType = typ
        ..contentLength = bytes.length
        ..add(bytes);
      return r.close();
    }

    Future<void> weiter(String ziel) => r.redirect(Uri.parse(ziel), status: 303);

    if (req.uri.path == '/login/index.php') {
      if (req.method == 'POST') return weiter('/login/index.php?testsession=1');
      if (q.containsKey('testsession')) {
        eingeloggt = true;
        r.cookies.add(Cookie('MoodleSession', sitzungsCookie));
        return weiter('/my/');
      }
      return html(
        eingeloggt
            ? '<html>Sie sind bereits angemeldet. {"sesskey":"abc123","userId":3}</html>'
            : '<html><input name="logintoken" value="t"></html>',
      );
    }
    if (sitzungAbgelaufen) {
      sitzungAbgelaufen = false;
      eingeloggt = false;
      return weiter('/login/index.php');
    }
    // Eine erfundene Seite eines Plugins, das über eine Zusatzadresse
    // schreibt (test/plugin_schreiben_test.dart): Nach dem POST leitet sie um,
    // je nach id auf sich selbst oder auf Erlaubtes und Unerlaubtes.
    if (req.uri.path == '/mod/beispiel/speichern.php') {
      if (req.method != 'POST') return html('<html>Notiz: ${notiz ?? ''}</html>');
      notiz = Uri.splitQueryString(rumpfe.last)['notiz'];
      switch (q['id']) {
        case '12':
          return weiter('/question/banks.php?courseid=12');
        case '13':
          return weiter('/admin/index.php');
        case '15':
          return weiter('/course/view.php?id=2');
        case '19':
          return weiter('/mod/beispiel/lesen.php?id=1');
        case '40':
          return weiter('/mod/beispiel/bericht.php?id=501');
        case '41':
          return weiter('/mod/beispiel/bericht.php?id=777');
        case '20':
          return weiter('/mod/beispiel/speichern.php?id=20&sesskey=abc123');
        case '21':
          return weiter('/user/profile.php?id=5');
        case '35':
          r.headers
            ..set('cf-mitigated', 'challenge')
            ..set('cf-ray', 'r2-FRA');
          return html('<html>Just a moment...</html>', status: 403);
      }
      return weiter('/mod/beispiel/speichern.php?id=${q['id']}&gespeichert=1');
    }
    if (req.uri.path == '/mod/beispiel/report.php' && req.method == 'POST') return html('<html>Bericht</html>');
    if (req.uri.path == '/course/modedit.php' && q.containsKey('update')) {
      final cmid = int.parse(q['update']!);
      final a = aktivitaeten[cmid];
      if (a == null) return html(moodleSeite('<div class="errorbox">Ungültige Kursmodul-ID</div>', kurs: 1), status: 404);
      return html(
        moodleSeite(
          formular[cmid] ??
              '<form action="modedit.php" method="post"><input type="hidden" name="course" value="${a.kurs}">'
                  '<input type="hidden" name="coursemodule" value="$cmid"><input name="name" value="Bericht"></form>',
          kurs: a.kurs,
          kontext: a.kontext,
        ),
      );
    }
    if (req.uri.path == '/user/index.php') {
      final kurs = int.parse(q['id']!);
      final seite = teilnehmendenseite[kurs];
      if (seite == 'umleitung') return weiter('/user/index.php?id=$kurs');
      if (seite == 'fehler') return html(moodleSeite('Fehler'), status: 500);
      return html(seite ?? teilnehmendenseiteImDoppel(kurs, teilnehmende[kurs] ?? const []));
    }
    // Erfundene Seiten eines Plugins, das in einem Lauf über Zusatzadressen
    // liest (test/plugin_lauf_test.dart, Beispiel-Plugin).
    if (req.uri.path == '/mod/beispiel/bericht.php') {
      if (q['warten'] == '1') await haltenBericht?.future;
      switch (q['umleitung']) {
        case '1':
          return weiter('/mod/beispiel/bericht.php?id=999');
        case '2':
          return weiter('/user/profile.php?id=5');
        case '3':
          return weiter('/mod/beispiel/bericht.php?id=501&seite=2');
        case '4':
          return weiter('/admin/index.php');
      }
      return html(
        moodleSeite('<h3>Bericht</h3><p>Erika Mustermann: 3 Punkte</p><a href="?id=501&amp;sesskey=abc123">x</a>'),
      );
    }
    // Eine erfundene Datei eines Plugins, die es in einem Lauf über eine
    // Zusatzadresse herunterlädt (test/plugin_download_test.dart,
    // Beispiel-Plugin): mit einem Dateinamen, der einen Namen trägt, ohne
    // angekündigte Größe, mit Umleitung oder angehalten.
    if (req.uri.path == '/mod/beispiel/export.php' ||
        req.uri.path.startsWith('/pluginfile.php/950/mod_beispiel/export/')) {
      if (q['warten'] == '1') await haltenBericht?.future;
      switch (q['umleitung']) {
        case '1':
          return weiter('/mod/beispiel/export.php?id=501');
        case '2':
          return weiter('/mod/beispiel/anders.php?id=501');
        case '3':
          return weiter('/admin/index.php');
        case '4':
          return weiter('/mod/beispiel/export.php?id=502');
        case '5':
          return weiter('/pluginfile.php/951/mod_beispiel/export/0/a.csv');
        case '6':
          return weiter('https://fremd.example/mod/beispiel/export.php?id=501');
        case '7':
          return weiter('/mod/beispiel/export.php?id=501&umleitung=7');
        case '8':
          return weiter('/pluginfile.php/950/mod_beispiel/export/0/Liste_Klasse_7b.csv?forcedownload=1');
        case '9':
          return weiter('/login/index.php');
      }
      r.headers.set('content-disposition', 'attachment; filename="Erika_Mustermann.csv"');
      if (q['ohnegroesse'] == '1') {
        r.headers.contentType = ContentType('text', 'csv');
        r.add(List<int>.filled(exportGroesse, 0x61));
        return r.close();
      }
      return datei(List<int>.filled(exportGroesse, 0x61), ContentType('text', 'csv'));
    }
    if (req.uri.path == '/mod/beispiel/fragment.php') return html('<div class="teil">Teil</div>');
    if (req.uri.path == '/mod/beispiel/ohnehaupt.php') return html('<html><body><div>Kein Hauptbereich</div></body></html>');
    if (req.uri.path == '/mod/beispiel/daten.php') {
      r.headers.contentType = ContentType.json;
      r.write('{"sesskey":"abc123","werte":[1,2]}');
      return r.close();
    }
    // Eine Seite ohne Hauptbereich und ein Stück HTML ohne Seite, beide auf
    // einer Adresse, die ein Plugin roh lesen darf.
    if (req.uri.path == '/mod/learningmap/view.php' && q['id'] == '21') {
      return html('<html><body><div>ohne Hauptbereich</div></body></html>');
    }
    if (req.uri.path == '/mod/learningmap/view.php' && q['id'] == '22') return html('<div>Teil</div>');
    switch ((req.uri.path, q['id'] ?? q['pageid'] ?? q['courseid'])) {
      case ('/question/banks.php', _):
        r.cookies.add(Cookie('weiterer', 'keks-aus-moodle'));
        r.headers.set('X-Moodle-Intern', 'kopf-aus-moodle');
        return html(moodleSeite('Fragensammlungen'));
      case ('/mod/wiki/view.php', '5'):
        return weiter('/mod/wiki/view.php?pageid=9');
      case ('/mod/wiki/view.php', '9'):
        return html(moodleSeite('Wikiseite'));
      case ('/mod/learningmap/view.php', _):
        return html(moodleSeite('Lernlandkarte'));
      case ('/mod/board/view.php', '13'):
        return weiter('/admin/index.php');
      case ('/mod/board/view.php', '14'):
        return weiter('/user/profile.php?id=5');
      case ('/mod/board/view.php', '15'):
        return weiter('/course/view.php?id=2');
      case ('/mod/board/view.php', '16'):
        return weiter('https://fremd.example/mod/board/view.php?id=1');
      case ('/mod/board/view.php', '17'):
        return weiter('/mod/book/delete.php?id=1&chapterid=2&confirm=1&sesskey=abc123');
      case ('/mod/board/view.php', '18'):
        return weiter('/mod/%2e%2e/admin/index.php');
      case ('/mod/board/view.php', '35'):
        r.headers
          ..set('cf-mitigated', 'challenge')
          ..set('cf-ray', 'r1-FRA');
        return html('<html>Just a moment...</html>', status: 403);
      case ('/mod/board/view.php', '99'):
        await halten?.future;
        return html('<html>spät</html>');
      case ('/pluginfile.php/55/mod_folder/content/0/blatt.pdf', _):
        return datei(List<int>.filled(2048, 7), ContentType('application', 'pdf'));
      case ('/pluginfile.php/55/mod_folder/content/0/seite.html', _):
        return html('<html>keine Datei</html>');
      case ('/pluginfile.php/55/mod_page/content/0/gross.txt', _):
        return datei(List<int>.filled(textHoechstens + 1, 0x61), ContentType.text);
    }
    return html('<html>nichts</html>', status: 404);
  }
}

/// Ein Instanzprofil, wie es die Adresse sieht.
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
  }) => throw StateError('Ein Plugin, das Moodle liest, bekommt nie einen Dialog.');

  @override
  String? get testDialogantworten => null;
}


void main() {
  late PluginTestMoodle moodle;
  late Directory wurzel;
  late AppAdresse adresse;
  late Protokoll protokoll;
  late MoodleZugang zugang;

  setUp(() async {
    moodle = PluginTestMoodle();
    await moodle.starten();
    wurzel = Directory.systemTemp.createTempSync('moocp_plugin_moodle_');
    protokoll = Protokoll();
    zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
    await zugang.sesskey();
    protokoll.leeren();
    moodle.angefragt.clear();
    adresse = await AppAdresse.starten(Protokoll());
    adresse.pluginAnmelden('beispiel', 'Beispiel', _schluessel);
  });

  tearDown(() async {
    moodle.halten?.complete();
    await adresse.beenden();
    await moodle.server.close(force: true);
    wurzel.deleteSync(recursive: true);
  });

  List<String> zeilen() => [for (final e in protokoll.eintraege) '${e.art.name}: ${e.text}'];

  String ordner(String name) => (Directory(p.join(wurzel.path, name))..createSync()).path;

  /// Meldet einen Aufruf des Beispiel-Plugins im Profil mit [z] an; liefert
  /// das Token und die Funktion, die den Aufruf beendet.
  ({String token, void Function() ende}) aufruf({MoodleZugang? z, String profil = 'A'}) {
    final a = WerkzeugAufruf(
      name: 'beispiel_echo',
      args: const {},
      profil: Profil(kennung: profil, name: profil, adresse: 'https://moodle.schule.example', port: 1, mcpName: profil, schluessel: 't'),
      token: aufrufToken(),
      abbruch: Completer<void>().future,
      kontext: _Kontext(z ?? zugang, ordner(profil)),
    );
    return (token: a.token, ende: adresse.aufrufAnmelden('beispiel', a).ende);
  }

  Future<AdresseAntwort> lesen(String token, Object? pfad, {String? methode}) => anAdresse(adresse.adresse, pfadMoodleLesen, {
    'pfad': pfad,
    'methode': ?methode,
  }, token: token);

  group('Token und Anmeldung', () {
    test('ohne Token oder nach dem Ende des Aufrufs: 403, Moodle wird nicht gefragt', () async {
      final a = aufruf();
      a.ende();
      for (final f in [pfadMoodleLesen, pfadMoodleDatei]) {
        expect((await anAdresse(adresse.adresse, f, {'pfad': '/question/banks.php?courseid=12'})).status, 403);
        expect((await anAdresse(adresse.adresse, f, {'pfad': '/question/banks.php?courseid=12'}, token: a.token)).status, 403);
      }
      expect(moodle.angefragt, isEmpty);
    });

    test('nicht angemeldet: 503 mit dem Satz der eingebauten Werkzeuge, nichts gesendet', () async {
      final a = aufruf(z: MoodleZugang(protokoll));
      // Ein Wortlaut, eine Quelle: der Satz von NichtAngemeldet.
      final satz = NichtAngemeldet().meldung;
      expect(satz, 'Nicht angemeldet. Bitte in der App anmelden.');
      for (final f in [pfadMoodleLesen, pfadMoodleDatei, pfadZusatzLesen, pfadZusatzDatei]) {
        final r = await anAdresse(adresse.adresse, f, {'pfad': '/question/banks.php?courseid=12'}, token: a.token);
        expect(r.status, 503);
        expect(r.json, {'fehler': satz});
      }
      final lauf = await anAdresse(adresse.adresse, pfadLaufBeginnen, {'cmid': 501}, token: a.token);
      expect(lauf.status, 503);
      expect(lauf.json, {'fehler': satz});
      expect(moodle.angefragt, isEmpty);
    });
  });

  group('erlaubtes Lesen', () {
    test('Status, Inhaltstyp, Pfad und Text; keine Cookies und keine Kopfzeilen von Moodle', () async {
      final a = aufruf();
      final r = await lesen(a.token, '/question/banks.php?courseid=12');

      expect(r.status, 200);
      expect(r.json.keys.toSet(), {'status', 'inhaltstyp', 'pfad', 'text'});
      expect(r.json['status'], 200);
      expect(r.json['inhaltstyp'], 'text/html');
      expect(r.json['pfad'], '/question/banks.php?courseid=12');
      // Was im Seiteninhalt steht, bleibt; moocp setzt nichts dazu.
      expect(r.json['text'], contains('Fragensammlungen'));
      expect(r.kopf[HttpHeaders.setCookieHeader], isNull);
      expect(r.kopf['x-moodle-intern'], isNull);
      for (final geheim in [sitzungsCookie, 'keks-aus-moodle', 'kopf-aus-moodle', 'MoodleSession']) {
        expect(r.roh, isNot(contains(geheim)));
        expect(r.kopf.toString(), isNot(contains(geheim)));
      }
      expect(moodle.angefragt, ['GET /question/banks.php?courseid=12']);
      // Im Protokoll des Profils, mit dem Plugin, ohne Werte.
      expect(zeilen(), ['moodle: Plugin „Beispiel“: GET /question/banks.php?courseid=… → 200']);
    });

    test('eine erlaubte Umleitung: jedes Ziel geprüft, der Pfad am Ende ohne Rechner', () async {
      final a = aufruf();
      final r = await lesen(a.token, '/mod/wiki/view.php?id=5');
      expect(r.status, 200);
      expect(r.json['pfad'], '/mod/wiki/view.php?pageid=9');
      expect(r.json['text'], '<section id="region-main" aria-label="Inhalt">Wikiseite</section>');
      expect(zeilen(), [
        'moodle: Plugin „Beispiel“: GET /mod/wiki/view.php?id=… → 303',
        'moodle: Plugin „Beispiel“: GET /mod/wiki/view.php?pageid=… → 200',
      ]);
    });

    test('Parameterwerte stehen nie im Protokoll, auch bei Dateien mit freien Parametern', () async {
      final a = aufruf();
      final r = await lesen(a.token, '/pluginfile.php/55/mod_folder/content/0/blatt.pdf?x=Erika');
      expect(r.status, 200);
      expect(zeilen().join('\n'), isNot(contains('Erika')));
      expect(zeilen(), ['moodle: Plugin „Beispiel“: GET /pluginfile.php/55/mod_folder/content/0/blatt.pdf?x=… → 200']);
    });

    test('abgelaufene Sitzung: genau eine Neuanmeldung durch die App, dann die Seite', () async {
      final a = aufruf();
      moodle.sitzungAbgelaufen = true;
      final r = await lesen(a.token, '/mod/learningmap/view.php?id=20');
      expect(r.status, 200);
      expect(r.json['text'], '<section id="region-main" aria-label="Inhalt">Lernlandkarte</section>');
      final z = zeilen();
      expect(z.where((l) => l.contains('Sitzung abgelaufen -- melde neu an')), hasLength(1));
      // Die Anmeldung stellt die App, nicht das Plugin.
      expect(z, contains('schreiben: POST /login/index.php → 303'));
      expect(z.where((l) => l.contains('Plugin') && l.contains('/login/')), isEmpty);
      expect(z.join('\n'), isNot(contains('geheim')));
    });

    test('größer als die Grenze für Text: 413 mit dem Hinweis auf den Download', () async {
      final a = aufruf();
      final r = await lesen(a.token, '/pluginfile.php/55/mod_page/content/0/gross.txt');
      expect(r.status, 413);
      expect(r.json['fehler'], contains(pfadMoodleDatei));
      expect(zeilen(), [
        'moodle: Plugin „Beispiel“: GET /pluginfile.php/55/mod_page/content/0/gross.txt → 200 (zu groß, abgebrochen)',
      ]);
    });

    test('ein Schutzdienst: wie bei den eingebauten Werkzeugen gemeldet, nicht umgangen', () async {
      final a = aufruf();
      final r = await lesen(a.token, '/mod/board/view.php?id=35');
      expect(r.status, 502);
      expect(r.json['fehler'], SchutzPruefung().meldung);
      expect(zeilen(), [
        'moodle: Plugin „Beispiel“: GET /mod/board/view.php?id=… → 403 (Schutzdienst: Prüfung verlangt, Ray-ID r1-FRA)',
      ]);
    });

    test('endet der Aufruf, während Moodle noch antwortet: 409, das Ergebnis geht nicht hinaus', () async {
      final a = aufruf();
      moodle.halten = Completer<void>();
      final antwort = lesen(a.token, '/mod/board/view.php?id=99');
      while (moodle.angefragt.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      a.ende();
      final r = await antwort;
      expect(r.status, 409);
      expect(r.roh, isNot(contains('spät')));
    });
  });

  group('Ablehnung ohne Dialog', () {
    Future<void> abgelehnt(Object? pfad, {int status = 403, String? grund}) async {
      final a = aufruf();
      final r = await lesen(a.token, pfad);
      expect(r.status, status, reason: '$pfad');
      expect(r.json.keys, ['fehler'], reason: '$pfad');
      if (grund != null) expect(r.json['fehler'], contains(grund), reason: '$pfad');
      a.ende();
    }

    tearDown(() => expect(moodle.angefragt, isEmpty));

    test('Adminbereich, Anmeldung und Zugangsdaten, auch verschleiert', () async {
      for (final pfad in [
        '/admin/index.php',
        '/admin',
        '/ADMIN/index.php',
        '/Admin/settings.php?section=x',
        '/%61dmin/index.php',
        '/%2561dmin/index.php',
        '/login/index.php',
        '/login/logout.php?sesskey=x',
        '/LOGIN/change_password.php',
        '/auth/oauth2/login.php',
        '/webservice/rest/server.php?wstoken=x',
        '/user/managetoken.php',
        '/User/ManageToken.php',
      ]) {
        await abgelehnt(pfad, grund: 'Gesperrt für jedes Plugin');
      }
      expect(zeilen(), contains('gesperrt: Plugin „Beispiel“: Gesperrt für Plugins: GET /admin/index.php (Bereich Adminbereich)'));
      expect(zeilen().join('\n'), isNot(contains('wstoken=x')));
    });

    test('„..“, „.“, „//“ und „\\“, auch prozentkodiert: 400', () async {
      for (final pfad in [
        '/mod/../admin/index.php',
        '/mod/%2e%2e/admin/index.php',
        '/mod/%252e%252e/admin/index.php',
        '/mod/./wiki/view.php?id=5',
        '/mod//wiki/view.php?id=5',
        '/mod/%2f/wiki/view.php?id=5',
        r'/mod\wiki/view.php?id=5',
        '/mod%5cwiki/view.php?id=5',
      ]) {
        await abgelehnt(pfad, status: 400, grund: 'Normalform');
      }
    });

    test('absolute, fremde und unvollständige Adressen: 400', () async {
      for (final pfad in [
        'https://fremd.example/question/banks.php?courseid=12',
        '${moodle.basis}/question/banks.php?courseid=12',
        '//fremd.example/question/banks.php?courseid=12',
        'question/banks.php?courseid=12',
        '/question/banks.php?courseid=12#anker',
        '/question/banks.php?courseid=12 ',
        '',
        null,
        12,
      ]) {
        await abgelehnt(pfad, status: 400);
      }
    });

    test('jede Methode außer GET: 405, mit dem Weg über die eingebauten Werkzeuge', () async {
      for (final m in ['POST', 'PUT', 'DELETE', 'get']) {
        final a = aufruf();
        final r = await lesen(a.token, '/question/banks.php?courseid=12', methode: m);
        expect(r.status, 405, reason: m);
        expect(r.json['fehler'], contains(pfadWerkzeug));
      }
      expect(zeilen(), contains('gesperrt: Plugin „Beispiel“: Gesperrt: POST /question/banks.php?courseid=… (nur Lesen)'));
    });

    test('eine Methode, die keine ist, steht nicht im Protokoll', () async {
      final a = aufruf();
      expect((await lesen(a.token, '/question/banks.php?courseid=12', methode: 'Erika')).status, 405);
      expect(zeilen(), contains('gesperrt: Plugin „Beispiel“: Gesperrt: ? /question/banks.php?courseid=… (nur Lesen)'));
      expect(zeilen().join('\n'), isNot(contains('Erika')));
    });

    test('ein Pfad oder Parametername mit einem gesperrten Namen: 422, Moodle wird nicht gefragt, kein Name im Protokoll', () async {
      final a = aufruf();
      adresse.sperre.namenHinzufuegen('beispiel', ['Erika Mustermann']);
      for (final (f, pfad) in [
        (pfadMoodleLesen, '/pluginfile.php/55/mod_folder/content/0/Erika.pdf'),
        (pfadMoodleLesen, '/pluginfile.php/55/mod_folder/content/0/M%75stermann.pdf'),
        (pfadMoodleLesen, '/question/banks.php?courseid=12&mustermann=1'),
        (pfadMoodleDatei, '/pluginfile.php/55/mod_folder/content/0/erika_mustermann.pdf'),
      ]) {
        final r = await anAdresse(adresse.adresse, f, {'pfad': pfad}, token: a.token);
        expect(r.status, 422, reason: pfad);
        expect(r.json['fehler'], startsWith('Gesperrt: Der Pfad enthält ein Wort'));
      }
      expect(moodle.angefragt, isEmpty);
      final alle = zeilen();
      expect(alle, hasLength(4));
      expect(alle.toSet(), {
        'gesperrt: Plugin „Beispiel“, Werkzeug beispiel_echo: Anfrage an Moodle gesperrt (letzte Sperre: könnte einen Namen enthalten)',
      });
    });

    test('mit sesskey, auch kodiert: 403', () async {
      for (final pfad in [
        '/mod/quiz/edit.php?cmid=5&sesskey=abc123',
        '/course/modedit.php?update=5&sesskey=abc123',
        '/mod/quiz/edit.php?cmid=5&sess%6Bey=abc123',
        '/question/bank/exporttoxml/exportone.php?id=1&cmid=2&sesskey=abc123',
      ]) {
        await abgelehnt(pfad, grund: 'sesskey');
      }
      expect(zeilen().join('\n'), isNot(contains('abc123')));
    });

    test('GET-Schritte von Schreibvorgängen und GET mit Nebenwirkung: 403', () async {
      for (final pfad in [
        '/course/modedit.php?add=page&course=12&section=1',
        '/mod/wiki/edit.php?pageid=9',
        '/mod/wiki/create.php?swid=1&title=Neu&action=new',
        '/question/bank/deletequestion/delete.php?cmid=5002&deleteselected=1&deleteall=1&returnurl=%2Fquestion%2Fedit.php%3Fcmid%3D5002&q5006=1',
        '/backup/backup.php?id=12',
        '/backup/restorefile.php?contextid=55',
        '/course/view.php?id=12',
        '/group/group.php?courseid=12',
      ]) {
        await abgelehnt(pfad, grund: 'lesenden Teil');
      }
    });

    test('Sicherungen und andere Dateien unter user/: 403, auch über den Download', () async {
      const pfad = '/pluginfile.php/55/user/backup/1/kurs.mbz?forcedownload=1';
      await abgelehnt(pfad, grund: 'user/');
      final a = aufruf();
      final r = await anAdresse(adresse.adresse, pfadMoodleDatei, {'pfad': pfad}, token: a.token);
      expect(r.status, 403);
      final plugin = Directory(p.join(wurzel.path, 'A', 'plugin-beispiel'));
      expect(plugin.existsSync() ? plugin.listSync() : const [], isEmpty);
    });

    test('nicht auf der Positivliste: 403', () async {
      await abgelehnt('/gibt/es/nicht.php?x=1', grund: 'nicht auf der Positivliste');
      expect(zeilen(), ['gesperrt: Plugin „Beispiel“: Gesperrt: GET /gibt/es/nicht.php?x=…']);
    });
  });

  group('Umleitungen auf Unerlaubtes', () {
    test('jedes Ziel wird geprüft; Moodle sieht nur die erste Anfrage', () async {
      for (final (id, grund) in [
        ('13', 'Gesperrt für jedes Plugin'),
        ('14', 'Gesperrt (Datenschutz)'),
        ('15', 'lesenden Teil'),
        ('16', 'fremder Rechner'),
        ('17', 'sesskey'),
        ('18', 'Gesperrt für jedes Plugin'),
      ]) {
        moodle.angefragt.clear();
        final a = aufruf();
        final r = await lesen(a.token, '/mod/board/view.php?id=$id');
        expect(r.status, 403, reason: id);
        expect(r.json['fehler'], contains(grund), reason: id);
        expect(moodle.angefragt, ['GET /mod/board/view.php?id=$id'], reason: id);
      }
      expect(zeilen().join('\n'), isNot(contains('abc123')));
    });
  });

  group('Die Adressentscheidung gegen die Tabellen der Sperrliste', () {
    final basis = Uri.parse('https://m.example');

    /// Entscheidet wie der Moodle-Zugang vor dem Senden: Sperre, dann
    /// Positivliste; null heißt erlaubt.
    String? entscheiden(Uri u) {
      final pl = PluginAufrufer(MoodleZugang(Protokoll()), 'Plugin „Beispiel“');
      return pl.gesperrtDurch(u) ?? (pl.erlaubt('GET', u, null, null, null) ? null : 'Positivliste');
    }

    /// Dieselbe Adresse, wie ein Plugin sie verschleiern könnte: jeder
    /// Buchstabe nach einem „/“ prozentkodiert, einmal und doppelt.
    List<Uri> verschleiert(String a) {
      String kodiert(String prozent) => a.replaceAllMapped(
        RegExp(r'/([a-z])'),
        (m) => '/$prozent${m[1]!.codeUnitAt(0).toRadixString(16)}',
      );
      return [Uri.parse('$basis$a'), Uri.parse('$basis${kodiert('%')}'), Uri.parse('$basis${kodiert('%25')}')];
    }

    test('was die Sperrliste sperren muss, liest kein Plugin, auch verschleiert nicht', () {
      final durch = [
        for (final a in mussSperren)
          for (final u in verschleiert(a))
            if (entscheiden(u) == null) '$u',
      ];
      expect(durch, isEmpty);
    });

    test('was ein Plugin lesen darf, dürfen auch die eingebauten Werkzeuge, und die Sperrliste lässt es durch', () {
      final z = MoodleZugang(Protokoll());
      for (final a in [...mussSperren, ...mussDurchlassen, ...werkzeugGet]) {
        final u = Uri.parse('$basis$a');
        if (entscheiden(u) != null) continue;
        expect(z.erlaubt('GET', u), isTrue, reason: a);
        expect(gesperrt(u), isFalse, reason: a);
      }
    });

    test('von dem, was die Werkzeuge anfragen, liest ein Plugin genau den lesenden Teil', () {
      expect(
        [
          for (final a in werkzeugGet)
            if (entscheiden(Uri.parse('$basis$a')) == null) a,
        ],
        [
          '/course/modedit.php?update=15271',
          '/mod/learningmap/view.php?id=15731',
          '/course/editsection.php?id=812',
          '/filter/manage.php?contextid=11591',
          '/draftfile.php/2393/user/draft/905327642/bild.svg',
          '/pluginfile.php/6520/mod_folder/content/0/a.odt',
          '/pluginfile.php/7000/mod_page/content/3/zeichnung.svg',
          '/pluginfile.php/7001/mod_assign/introattachment/0/vorlage.pdf',
          '/pluginfile.php/7001/mod_assign/intro/bild.png',
          '/pluginfile.php/7449/question/questiontext/1/2/3/bild.png',
          '/question/type/stack/adminui/caschat.php?questionid=5005&cmid=5002',
        ],
      );
    });

    test('jede lesende Regel der Positivliste ist ein GET ohne Formular, Rumpf und Datei', () {
      for (final e in MoodleZugang(Protokoll()).positivliste.where((e) => e.lesend)) {
        expect(e.methode, 'GET', reason: e.zweck);
        expect(e.formular == null && e.inhalt == null && e.anhang == null, isTrue, reason: e.zweck);
      }
    });
  });

  group('Download in den Ordner des Plugins', () {
    test('landet im Unterordner des Plugins im Arbeitsordner des Profils des Aufrufs, nie überschrieben', () async {
      final b = aufruf(profil: 'B');
      final a = aufruf();
      const pfad = '/pluginfile.php/55/mod_folder/content/0/blatt.pdf';
      final r = await anAdresse(adresse.adresse, pfadMoodleDatei, {'pfad': pfad}, token: a.token);

      final ziel = p.join(wurzel.path, 'A', 'plugin-beispiel', 'blatt.pdf');
      expect(r.status, 200);
      expect(r.json, {'datei': ziel, 'bytes': 2048});
      expect(File(ziel).lengthSync(), 2048);
      expect(Directory(p.join(wurzel.path, 'B', 'plugin-beispiel')).existsSync(), isFalse);
      expect(zeilen(), ['moodle: Plugin „Beispiel“: GET /pluginfile.php/55/mod_folder/content/0/blatt.pdf → 200']);

      final nochmal = await anAdresse(adresse.adresse, pfadMoodleDatei, {'pfad': pfad}, token: a.token);
      expect(nochmal.status, 409);
      final mitName = await anAdresse(adresse.adresse, pfadMoodleDatei, {'pfad': pfad, 'dateiname': 'zwei.pdf'}, token: a.token);
      expect(mitName.json['datei'], p.join(wurzel.path, 'A', 'plugin-beispiel', 'zwei.pdf'));
      b.ende();
    });

    test('ein ungültiger Dateiname, eine Seite statt einer Datei, eine abgelehnte Adresse: nichts bleibt liegen', () async {
      final a = aufruf();
      for (final name in ['../x.pdf', r'a\b.pdf', '.versteckt', 'a/b.pdf', '', 7]) {
        final r = await anAdresse(adresse.adresse, pfadMoodleDatei, {
          'pfad': '/pluginfile.php/55/mod_folder/content/0/blatt.pdf',
          'dateiname': name,
        }, token: a.token);
        expect(r.status, 400, reason: '$name');
      }
      final seite = await anAdresse(adresse.adresse, pfadMoodleDatei, {
        'pfad': '/pluginfile.php/55/mod_folder/content/0/seite.html',
      }, token: a.token);
      expect(seite.status, 502);
      expect(seite.json['fehler'], contains('Seite statt einer Datei'));
      final admin = await anAdresse(adresse.adresse, pfadMoodleDatei, {'pfad': '/admin/tool/x/datei.pdf'}, token: a.token);
      expect(admin.status, 403);
      final post = await anAdresse(adresse.adresse, pfadMoodleDatei, {
        'pfad': '/pluginfile.php/55/mod_folder/content/0/blatt.pdf',
        'methode': 'POST',
      }, token: a.token);
      expect(post.status, 405);
      final plugin = Directory(p.join(wurzel.path, 'A', 'plugin-beispiel'));
      expect(plugin.existsSync() ? plugin.listSync() : const [], isEmpty);
    });
  });
}
