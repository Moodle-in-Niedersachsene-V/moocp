// Downloads eines Plugins über eine Zusatzadresse (E36): nur in einem Lauf,
// in einen eigenen Ordner je Plugin und Instanzprofil außerhalb des
// Arbeitsordners, mit einem Dateinamen, den moocp vergibt. Der Ordner wird
// beim Start und beim Beenden der App geleert, und am Ende eines Laufs löscht
// moocp, was der Lauf geladen hat. Sein Pfad steht in keinem Protokoll, und
// die letzte Sperre hält jeden Text eines Plugins an, der ihn nennt. Auf der
// einen Seite steht ein HTTP-Client im Test an Stelle eines Plugins, auf der
// anderen das Moodle-Doppel aus test/plugin_moodle_test.dart; das echte
// Beispiel-Plugin prüft test/plugin_start_test.dart. Alles in Temp-Ordnern,
// nie im Ordner der App.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/werkzeugquelle.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/plugin/adressmuster.dart';
import 'package:moocp/plugin/app_adresse.dart';
import 'package:moocp/plugin/beschreibung.dart';
import 'package:moocp/plugin/downloads.dart';
import 'package:moocp/plugin/laufende_plugins.dart';
import 'package:moocp/plugin/namenssperre.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'hilfen/plugin_adresse.dart';
import 'plugin_moodle_test.dart';

const _schluessel = beispielSchluessel;
const _zweiterSchluessel = 'schluessel-des-zweiten-plugins-0123456789abcd';

final _zusatzadressen = [
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/bericht.php'), ZugriffsArt.lesen, 'Liest den Bericht.'),
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/export.php'), ZugriffsArt.lesen, 'Lädt den Export.'),
  Zusatzadresse(
    Adressmuster.parsen('/pluginfile.php/*/mod_beispiel/export/*'),
    ZugriffsArt.lesen,
    'Lädt Dateien des Exports.',
  ),
  Zusatzadresse(Adressmuster.parsen('/mod/beispiel/speichern.php'), ZugriffsArt.schreiben, 'Speichert.'),
];

class _Kontext implements AufrufKontext {
  _Kontext(this.moodle, this.arbeitsordner, {this.eingebaut});

  @override
  final MoodleZugang moodle;
  @override
  final String arbeitsordner;
  @override
  Protokoll get protokoll => moodle.protokoll;

  final Future<EingebautErgebnis> Function(String name, Map<String, dynamic> args)? eingebaut;

  @override
  Future<EingebautErgebnis> eingebautAufrufen(
    String name,
    Map<String, dynamic> args, {
    required Future<void> abbruch,
    required String aufrufer,
  }) => eingebaut!(name, args);

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

  @override
  String? get testDialogantworten => null;
}


/// Alle Dateien unter [ordner], als Pfade relativ zu ihm, mit `/`.
List<String> _dateien(Directory ordner) => [
  for (final e in ordner.listSync(recursive: true))
    if (e is File) p.relative(e.path, from: ordner.path).replaceAll(r'\', '/'),
]..sort();

void main() {
  late PluginTestMoodle moodle;
  late Directory wurzel;
  late PluginDownloads downloads;
  late AppAdresse adresse;
  late Protokoll protokoll;
  late MoodleZugang zugang;

  setUp(() async {
    moodle = PluginTestMoodle();
    await moodle.starten();
    wurzel = Directory.systemTemp.createTempSync('moocp_plugin_download_');
    protokoll = Protokoll();
    zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
    await zugang.sesskey();
    protokoll.leeren();
    moodle.angefragt.clear();
    (downloads, _) = PluginDownloads.einrichten(basis: p.join(wurzel.path, 'temp'));
    adresse = await AppAdresse.starten(Protokoll(), downloads: downloads);
    adresse.pluginAnmelden('beispiel', 'Beispiel', _schluessel, zusatzadressen: _zusatzadressen);
    adresse.pluginAnmelden('zweites', 'Zweites', _zweiterSchluessel, zusatzadressen: _zusatzadressen);
  });

  tearDown(() async {
    moodle.haltenBericht?.complete();
    await adresse.beenden();
    await moodle.server.close(force: true);
    wurzel.deleteSync(recursive: true);
  });

  List<String> zeilen() => [for (final e in protokoll.eintraege) '${e.art.name}: ${e.text}'];

  Directory ordnerDerDownloads() => Directory(downloads.wurzel);

  /// Kein Teil des Pfads des Ordners in [text], in keiner Schreibweise.
  void ohnePfad(String text) {
    final t = text.toLowerCase().replaceAll(r'\', '/');
    expect(t, isNot(contains(PluginDownloads.ordnername)));
    expect(t, isNot(contains(wurzel.path.toLowerCase().replaceAll(r'\', '/'))));
  }

  ({String token, void Function() ende}) aufruf({
    String kurzname = 'beispiel',
    String profil = 'A',
    Future<EingebautErgebnis> Function(String, Map<String, dynamic>)? eingebaut,
  }) {
    final a = WerkzeugAufruf(
      name: '${kurzname}_download',
      args: const {},
      profil: Profil(kennung: profil, name: profil, adresse: 'https://moodle.schule.example', port: 1, mcpName: profil, schluessel: 't'),
      token: aufrufToken(),
      abbruch: Completer<void>().future,
      kontext: _Kontext(
        zugang,
        (Directory(p.join(wurzel.path, 'arbeitsordner', profil))..createSync(recursive: true)).path,
        eingebaut: eingebaut,
      ),
    );
    return (token: a.token, ende: adresse.aufrufAnmelden(kurzname, a).ende);
  }

  String schluesselVon(String kurzname) => kurzname == 'zweites' ? _zweiterSchluessel : _schluessel;

  Future<AdresseAntwort> beginnen(String token, int cmid, {String kurzname = 'beispiel'}) =>
      anAdresse(adresse.adresse, pfadLaufBeginnen, {'cmid': cmid}, token: token, schluessel: schluesselVon(kurzname));

  Future<AdresseAntwort> beenden(String token) => anAdresse(adresse.adresse, pfadLaufBeenden, {}, token: token);

  Future<AdresseAntwort> laden(String token, String pfad, {String kurzname = 'beispiel'}) =>
      anAdresse(adresse.adresse, pfadZusatzDatei, {'pfad': pfad}, token: token, schluessel: schluesselVon(kurzname));

  Future<({String token, void Function() ende})> imLauf({String kurzname = 'beispiel', String profil = 'A'}) async {
    final a = aufruf(kurzname: kurzname, profil: profil);
    final r = await beginnen(a.token, 501, kurzname: kurzname);
    expect(r.status, 200, reason: r.roh);
    return a;
  }

  group('Der Ordner', () {
    test('liegt außerhalb des Arbeitsordners und wird beim Einrichten (Start) geleert', () {
      final basis = p.join(wurzel.path, 'start');
      final alt = File(p.join(basis, PluginDownloads.ordnername, 'beispiel', 'A', '1.csv'))
        ..createSync(recursive: true)
        ..writeAsStringSync('vom letzten Lauf');
      final (d, geblieben) = PluginDownloads.einrichten(basis: basis);
      expect(geblieben, 0);
      expect(alt.existsSync(), isFalse);
      expect(Directory(d.wurzel).existsSync(), isTrue);
      expect(Directory(d.wurzel).listSync(), isEmpty);
      expect(p.basename(d.wurzel), PluginDownloads.ordnername);
    });

    test('leeren (Beenden) löscht alles darin und lässt den Ordner stehen', () {
      File(p.join(downloads.wurzel, 'beispiel', 'A', '7.pdf')).createSync(recursive: true);
      File(p.join(downloads.wurzel, 'zweites', 'B', '8.bin')).createSync(recursive: true);
      expect(downloads.leeren(), 0);
      expect(ordnerDerDownloads().listSync(), isEmpty);
    });

    test('je Plugin und Instanzprofil ein eigener Ordner; Dateinamen vergibt moocp', () {
      final a = downloads.neueDatei('beispiel', 'A', Uri.parse('https://m.example/pluginfile.php/950/x/0/Erika_Mustermann.PDF'));
      final b = downloads.neueDatei('beispiel', 'B', Uri.parse('https://m.example/mod/beispiel/export.php?id=501'));
      final c = downloads.neueDatei('zweites', 'A', Uri.parse('https://m.example/pluginfile.php/950/x/0/bericht.erika'));
      expect(p.dirname(a.path), p.join(downloads.wurzel, 'beispiel', 'A'));
      expect(p.dirname(b.path), p.join(downloads.wurzel, 'beispiel', 'B'));
      expect(p.dirname(c.path), p.join(downloads.wurzel, 'zweites', 'A'));
      // Laufende Nummer und eine Endung aus einer festen Liste; sonst „bin“.
      expect(p.basename(a.path), matches(RegExp(r'^\d+\.pdf$')));
      expect(p.basename(b.path), matches(RegExp(r'^\d+\.bin$')));
      expect(p.basename(c.path), matches(RegExp(r'^\d+\.bin$')));
      expect({a.path, b.path, c.path}, hasLength(3));
      for (final f in [a, b, c]) {
        expect(f.path.toLowerCase(), isNot(contains('erika')));
        expect(f.path.toLowerCase(), isNot(contains('mustermann')));
      }
    });

    test('ein Profil mit einer Kennung, die kein Ordnername ist, bekommt einen eigenen, festen', () {
      final x = downloads.ordner('beispiel', '../A');
      final y = downloads.ordner('beispiel', '../B');
      expect(p.isWithin(p.join(downloads.wurzel, 'beispiel'), x), isTrue);
      expect(x, isNot(y));
      expect(downloads.ordner('beispiel', '../A'), x);
    });
  });

  group('Herunterladen', () {
    test('außerhalb eines Laufs abgelehnt; Moodle sieht nichts', () async {
      final a = aufruf();
      final r = await laden(a.token, '/mod/beispiel/export.php?id=501');
      expect(r.status, 403);
      expect(r.json['fehler'], contains('nur in einem Lauf'));
      expect(moodle.angefragt, isEmpty);
      expect(zeilen(), [
        'gesperrt: Plugin „Beispiel“: Herunterladen über eine Zusatzadresse außerhalb eines Laufs abgewiesen: '
            'GET /mod/beispiel/export.php?id=…',
      ]);
      expect(_dateien(ordnerDerDownloads()), isEmpty);
    });

    test('im Lauf: in den Ordner des Plugins und Profils, mit Nummer als Namen, nicht in den Arbeitsordner', () async {
      final a = await imLauf();
      moodle.angefragt.clear();
      protokoll.leeren();
      final r = await laden(a.token, '/mod/beispiel/export.php?id=501');

      expect(r.status, 200, reason: r.roh);
      expect(r.json.keys.toSet(), {'datei', 'bytes'});
      expect(r.json['bytes'], exportGroesse);
      final datei = File(r.json['datei'] as String);
      expect(datei.lengthSync(), exportGroesse);
      expect(p.isWithin(p.join(downloads.wurzel, 'beispiel', 'A'), datei.path), isTrue);
      expect(p.basename(datei.path), matches(RegExp(r'^\d+\.bin$')));
      // Der Dateiname aus Moodle kommt nirgends hin.
      expect(r.roh, isNot(contains('Erika')));
      expect(_dateien(Directory(p.join(wurzel.path, 'arbeitsordner'))), isEmpty);
      expect(moodle.angefragt, ['GET /mod/beispiel/export.php?id=501']);
      expect(zeilen(), ['moodle: Plugin „Beispiel“, Zusatzadresse: GET /mod/beispiel/export.php?id=… → 200']);
      ohnePfad(zeilen().join('\n'));
    });

    test('das Protokoll endet am Skriptnamen: kein Dateiname, keine Nummern dahinter', () async {
      final a = await imLauf();
      protokoll.leeren();
      final r = await laden(a.token, '/pluginfile.php/950/mod_beispiel/export/0/Liste_Klasse_7b.csv?forcedownload=1');
      expect(r.status, 200, reason: r.roh);
      expect(p.basename(r.json['datei'] as String), matches(RegExp(r'^\d+\.csv$')));
      expect(r.roh, isNot(contains('Liste_Klasse')));
      expect(zeilen(), ['moodle: Plugin „Beispiel“, Zusatzadresse: GET /pluginfile.php?forcedownload=… → 200']);
      expect(zeilen().join('\n'), isNot(contains('950')));
      expect(zeilen().join('\n'), isNot(contains('Liste_Klasse')));
    });

    test('ein Pfad mit einem Namen des Laufs geht gar nicht erst an Moodle', () async {
      final a = await imLauf();
      moodle.angefragt.clear();
      final r = await laden(a.token, '/pluginfile.php/950/mod_beispiel/export/0/Erika_Mustermann.csv');
      expect(r.status, 422);
      expect(moodle.angefragt, isEmpty);
      expect(_dateien(ordnerDerDownloads()), isEmpty);
    });

    test('ohne angekündigte Größe geht es auch, in den Grenzen', () async {
      final a = await imLauf();
      final r = await laden(a.token, '/mod/beispiel/export.php?id=501&ohnegroesse=1');
      expect(r.status, 200, reason: r.roh);
      expect(r.json['bytes'], exportGroesse);
    });

    test('nur Zusatzadressen „lesen“ dieses Plugins, und nur, was zum Lauf passt', () async {
      final a = await imLauf();
      moodle.angefragt.clear();
      for (final (pfad, grund) in [
        ('/mod/beispiel/speichern.php?id=501', 'keine Zusatzadresse dieses Plugins'),
        ('/pluginfile.php/55/mod_folder/content/0/blatt.pdf', 'keine Zusatzadresse dieses Plugins'),
        ('/mod/beispiel/export.php?id=502', 'andere Aktivität'),
        ('/pluginfile.php/951/mod_beispiel/export/0/a.csv', 'anderen Kontext'),
        ('/admin/index.php', 'keine Zusatzadresse dieses Plugins'),
      ]) {
        final r = await laden(a.token, pfad);
        expect(r.status, 403, reason: pfad);
        expect(r.json['fehler'], contains(grund), reason: pfad);
      }
      expect(moodle.angefragt, isEmpty);
      expect(_dateien(ordnerDerDownloads()), isEmpty);
    });

    test('einer Umleitung auf eine erlaubte Adresse folgt der Download; jede Anfrage im Protokoll ohne Werte', () async {
      final a = await imLauf();
      moodle.angefragt.clear();
      protokoll.leeren();
      final r = await laden(a.token, '/mod/beispiel/export.php?id=501&umleitung=1');

      expect(r.status, 200, reason: r.roh);
      expect(r.json['bytes'], exportGroesse);
      final datei = File(r.json['datei'] as String);
      expect(p.isWithin(p.join(downloads.wurzel, 'beispiel', 'A'), datei.path), isTrue);
      expect(datei.lengthSync(), exportGroesse);
      expect(moodle.angefragt, ['GET /mod/beispiel/export.php?id=501&umleitung=1', 'GET /mod/beispiel/export.php?id=501']);
      expect(zeilen(), [
        'moodle: Plugin „Beispiel“, Zusatzadresse: GET /mod/beispiel/export.php?id=…&umleitung=… → 303',
        'moodle: Plugin „Beispiel“, Zusatzadresse: GET /mod/beispiel/export.php?id=… → 200',
      ]);
      ohnePfad(zeilen().join('\n'));
      expect(_dateien(Directory(p.join(wurzel.path, 'arbeitsordner'))), isEmpty);
    });

    test('auch auf eine andere Zusatzadresse „lesen“; das Protokoll endet am Skriptnamen', () async {
      final a = await imLauf();
      protokoll.leeren();
      final r = await laden(a.token, '/mod/beispiel/export.php?id=501&umleitung=8');
      expect(r.status, 200, reason: r.roh);
      expect(zeilen().last, 'moodle: Plugin „Beispiel“, Zusatzadresse: GET /pluginfile.php?forcedownload=… → 200');
      expect(zeilen().join('\n'), isNot(contains('950')));
      expect(zeilen().join('\n'), isNot(contains('Liste_Klasse')));
    });

    test('ein Umleitungsziel, das nicht passt, beendet den Download als Fehler; keine Datei, Moodle sieht das Ziel nie', () async {
      final a = await imLauf();
      for (final (umleitung, status, grund) in [
        ('2', 403, 'nicht angemeldet'),
        ('3', 403, 'gesperrter Bereich'),
        ('4', 403, 'andere Aktivität'),
        ('5', 403, 'anderer Kontext'),
        ('6', 403, 'fremder Rechner'),
        ('7', 502, 'zu viele Umleitungen'),
        ('9', 502, 'Anmeldeseite'),
      ]) {
        moodle.angefragt.clear();
        protokoll.leeren();
        final r = await laden(a.token, '/mod/beispiel/export.php?id=501&umleitung=$umleitung');
        expect(r.status, status, reason: '$grund: ${r.roh}');
        expect(r.json.keys, ['fehler'], reason: grund);
        expect(_dateien(ordnerDerDownloads()), isEmpty, reason: grund);
        if (umleitung != '7') {
          expect(moodle.angefragt, ['GET /mod/beispiel/export.php?id=501&umleitung=$umleitung'], reason: grund);
        }
        final text = zeilen().join('\n');
        ohnePfad(text);
        expect(text, isNot(contains('501')), reason: 'keine Werte: $grund');
        expect(text, isNot(contains('502')), reason: 'keine Werte: $grund');
        expect(text, isNot(contains('951')), reason: 'keine Werte: $grund');
      }
    });

    test('ohne Ordner für Downloads (keine Oberfläche, Tests) gibt es keinen Download', () async {
      final ohne = await AppAdresse.starten(Protokoll());
      addTearDown(ohne.beenden);
      ohne.pluginAnmelden('beispiel', 'Beispiel', _schluessel, zusatzadressen: _zusatzadressen);
      final a = WerkzeugAufruf(
        name: 'beispiel_download',
        args: const {},
        profil: Profil(kennung: 'A', name: 'A', adresse: 'https://moodle.schule.example', port: 1, mcpName: 'A', schluessel: 't'),
        token: aufrufToken(),
        abbruch: Completer<void>().future,
        kontext: _Kontext(zugang, wurzel.path),
      );
      ohne.aufrufAnmelden('beispiel', a);
      expect((await anAdresse(ohne.adresse, pfadLaufBeginnen, {'cmid': 501}, token: a.token)).status, 200);
      moodle.angefragt.clear();
      final r = await anAdresse(ohne.adresse, pfadZusatzDatei, {'pfad': '/mod/beispiel/export.php?id=501'}, token: a.token);
      expect(r.status, 503);
      expect(moodle.angefragt, isEmpty);
    });
  });

  group('Am Ende des Laufs ist die Datei weg', () {
    test('wenn das Plugin den Lauf beendet', () async {
      final a = await imLauf();
      final r = await laden(a.token, '/mod/beispiel/export.php?id=501');
      final datei = File(r.json['datei'] as String);
      expect(datei.existsSync(), isTrue);
      expect((await beenden(a.token)).status, 200);
      expect(datei.existsSync(), isFalse);
      expect(_dateien(ordnerDerDownloads()), isEmpty);
    });

    test('wenn der Aufruf endet oder abgebrochen wird (auch bei einem Absturz des Plugins)', () async {
      final a = await imLauf();
      final r = await laden(a.token, '/mod/beispiel/export.php?id=501');
      final datei = File(r.json['datei'] as String);
      a.ende();
      expect(datei.existsSync(), isFalse);
    });

    test('wenn moocp endet', () async {
      final a = await imLauf();
      final r = await laden(a.token, '/mod/beispiel/export.php?id=501');
      await adresse.beenden();
      expect(File(r.json['datei'] as String).existsSync(), isFalse);
    });

    test('endet der Lauf, während Moodle noch liefert: 409, keine Datei bleibt', () async {
      final a = await imLauf();
      moodle.haltenBericht = Completer<void>();
      moodle.angefragt.clear();
      final offen = laden(a.token, '/mod/beispiel/export.php?id=501&warten=1');
      while (moodle.angefragt.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect((await beenden(a.token)).status, 200);
      final r = await offen;
      expect(r.status, 409);
      expect(r.json.containsKey('datei'), isFalse);
      moodle.haltenBericht!.complete();
      moodle.haltenBericht = null;
      // Was Moodle danach noch liefert, landet nicht im Ordner.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(_dateien(ordnerDerDownloads()), isEmpty);
    });

    test('der Lauf eines Profils löscht nur seine Dateien; zwei Profile teilen nie Dateien', () async {
      final a = await imLauf(profil: 'A');
      final b = await imLauf(profil: 'B');
      final da = File((await laden(a.token, '/mod/beispiel/export.php?id=501')).json['datei'] as String);
      final db = File((await laden(b.token, '/mod/beispiel/export.php?id=501')).json['datei'] as String);
      expect(p.dirname(da.path), isNot(p.dirname(db.path)));
      expect((await beenden(a.token)).status, 200);
      expect(da.existsSync(), isFalse);
      expect(db.existsSync(), isTrue);
      // Ebenso zwei Plugins.
      final c = await imLauf(kurzname: 'zweites', profil: 'B');
      final dc = File((await laden(c.token, '/mod/beispiel/export.php?id=501', kurzname: 'zweites')).json['datei'] as String);
      expect(p.dirname(dc.path), isNot(p.dirname(db.path)));
      b.ende();
      expect(db.existsSync(), isFalse);
      expect(dc.existsSync(), isTrue);
    });
  });

  group('Der Pfad geht nie an die KI', () {
    /// Der Ordner in den Schreibweisen, in denen ein Plugin ihn nennen
    /// könnte.
    List<String> schreibweisen(String pfad) => [
      pfad,
      pfad.toUpperCase(),
      pfad.replaceAll(r'\', '/'),
      pfad.replaceAll('/', r'\'),
      pfad.replaceAll(r'\', r'\\').replaceAll('/', r'\\'),
      jsonEncode({'datei': p.join(pfad, 'beispiel', 'A', '3.bin')}),
      'file:///${pfad.replaceAll(r'\', '/')}/beispiel/A/3.bin',
      'Gelesen: ${p.join(pfad, 'beispiel', 'A', '3.bin')} (1234 Bytes)',
      // Einfach kodiert (namenssperre.dart, kodierungenAufgeloest).
      Uri.encodeComponent(pfad),
      Uri.encodeComponent(Uri.encodeComponent(pfad)),
      // Unicode-Escapes wie in JSON, zusammengesetzt, damit kein Werkzeug sie
      // im Quelltext auflöst.
      pfad.replaceAll(r'\', '${r'\'}u005c').replaceAll('/', '${r'\'}u002f'),
      pfad.replaceAll(r'\', '&#92;').replaceAll('/', '&#x2F;'),
    ];

    test('die letzte Sperre hält jeden Text mit dem Pfad an, für jedes Plugin, auch ohne Namen', () {
      final sperre = LetzteSperre();
      sperre.pfadSperren(downloads.wurzel);
      for (final t in schreibweisen(downloads.wurzel)) {
        expect(sperre.treffer('beispiel', [t]), isNotNull, reason: t);
        expect(sperre.treffer('irgendeins', ['davor', t]), isNotNull, reason: t);
      }
      // Was den Ordner nicht nennt, geht durch: auch das Temp-Verzeichnis
      // selbst und der Arbeitsordner.
      for (final t in [p.dirname(downloads.wurzel), p.join(wurzel.path, 'arbeitsordner', 'A', 'plugin-beispiel'), '3.bin', '']) {
        expect(sperre.treffer('beispiel', [t]), isNull, reason: t);
      }
    });

    test('ein Treffer auf den Pfad geht an die Lehrkraft als Pfad, nicht als Wort', () {
      final gemeldet = <SperrTreffer>[];
      final sperre = LetzteSperre(melden: gemeldet.add)..pfadSperren(downloads.wurzel);
      expect(
        sperre.gesperrt('beispiel', ['Datei: ${downloads.wurzel}'], plugin: 'Beispiel', werkzeug: 'beispiel_x', stelle: SperrStelle.ergebnis),
        isTrue,
      );
      expect(gemeldet.single.pfad, isTrue);
      expect(gemeldet.single.stelle, SperrStelle.ergebnis);
      expect('${gemeldet.single}', isNot(contains(PluginDownloads.ordnername)));
    });

    test('Protokollzeile, Aufruf eines eingebauten Werkzeugs und Pfad an Moodle mit dem Pfad: 422, nichts im Protokoll', () async {
      var aufgerufen = false;
      final a = aufruf(
        eingebaut: (_, _) async {
          aufgerufen = true;
          return (text: 'ok', fehlgeschlagen: false);
        },
      );
      for (final t in schreibweisen(downloads.wurzel)) {
        final r = await anAdresse(adresse.adresse, pfadProtokoll, {'text': 'Datei liegt in $t'}, token: a.token);
        expect(r.status, 422, reason: t);
      }
      final w = await anAdresse(adresse.adresse, pfadWerkzeug, {
        'name': 'status',
        'argumente': {'datei': p.join(downloads.wurzel, 'beispiel', 'A', '1.bin')},
      }, token: a.token);
      expect(w.status, 422);
      expect(aufgerufen, isFalse);
      // Ohne Token ebenso, und für ein anderes Plugin.
      expect((await anAdresse(adresse.adresse, pfadProtokoll, {'text': downloads.wurzel})).status, 422);
      expect(
        (await anAdresse(adresse.adresse, pfadProtokoll, {'text': downloads.wurzel}, schluessel: _zweiterSchluessel)).status,
        422,
      );
      expect((await anAdresse(adresse.adresse, pfadProtokoll, {'text': 'Aufgabe 3 fertig'}, token: a.token)).status, 200);
      ohnePfad(zeilen().join('\n'));
      expect(zeilen(), contains('info: Plugin „Beispiel“: Aufgabe 3 fertig'));
    });

    test('eine Antwort des Plugins an die KI mit dem Pfad wird gesperrt', () async {
      final l = LaufendePlugins(protokoll, downloads: downloads);
      addTearDown(l.beenden);
      final sperre = l.sperre;
      expect(sperre.treffer('beispiel', ['Gespeichert unter ${downloads.wurzel}']), isNotNull);
    });
  });

  test('LaufendePlugins.beenden leert den Ordner (Beenden der App)', () async {
    File(p.join(downloads.wurzel, 'beispiel', 'A', '1.bin')).createSync(recursive: true);
    final l = LaufendePlugins(protokoll, downloads: downloads);
    await l.beenden();
    expect(ordnerDerDownloads().listSync(), isEmpty);
    ohnePfad(zeilen().join('\n'));
  });
}
