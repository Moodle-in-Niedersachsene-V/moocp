// fragen_version_importieren (E38) gegen das Moodle-Doppel mit Fragensammlung:
// Was Moodle an Anfragen bekommt und was die Antwort sagt. Nur Moodle ist
// ersetzt; Prüfung, Freigabe, Sperre, Plugin-Aufruf, Rundlaufprobe und Löschen
// laufen echt.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/fragen_version.dart';
import 'package:moocp/moodle/fragen_xml.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'hilfen/fragenbank_doppel.dart';

void main() {
  late FragenbankDoppel moodle;
  late MoodleZugang zugang;
  late Directory ao;
  late Directory vorgaenge;
  late Freigaben freigaben;

  setUp(() async {
    moodle = FragenbankDoppel();
    await moodle.starten();
    ao = Directory.systemTemp.createTempSync('version-');
    vorgaenge = Directory.systemTemp.createTempSync('version-vorgaenge-');
    freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
    zugang = await MoodleZugang.fuerTest(Protokoll(), moodle.basis,
        benutzer: FragenbankDoppel.benutzer, passwort: FragenbankDoppel.passwort, schreibvorgaengeOrdner: vorgaenge.path);
  });

  tearDown(() async {
    await moodle.stoppen();
    ao.deleteSync(recursive: true);
    vorgaenge.deleteSync(recursive: true);
  });

  /// Die Datei, die die KI aus dem Export ableitet: Kommentar mit der Ausgangsnummer, geänderte Antwort.
  String datei(List<(DoppelVersion, String)> fragen, {String name = 'neu.xml'}) {
    final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<quiz>\n');
    for (final (v, antwort) in fragen) {
      b.writeln('<!-- question: ${v.id}  -->');
      b.writeln(v.xml.replaceAll(RegExp(r'<text>[^<]*</text></answer>'), '<text>$antwort</text></answer>'));
    }
    b.write('</quiz>');
    File(p.join(ao.path, name)).writeAsStringSync(b.toString());
    return name;
  }

  Future<String> los(String d, {int? uebergehen}) => fragenVersionImportieren(zugang, freigaben, ao.path,
      sammlung: FragenbankDoppel.sammlung, kategorie: 'ZZ Probe', datei: d, uebergehen: uebergehen);

  int schreibanfragen() {
    // Export ist ein POST, schreibt aber nichts; der Upload in den Entwurfsbereich auch nicht.
    return moodle.anfragen
        .where((a) => a.startsWith('POST') && !a.contains('repository_ajax') && !a.contains('exportquestions'))
        .length;
  }

  test('Eine Frage wird neue Version: Verlauf bleibt, verified, nur die Probeversion wurde gelöscht', () async {
    final e = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final alt = e.neueste;
    final bericht = await los(datei([(alt, 'B')]));
    expect(bericht, contains('verified: true'));
    expect(e.versionen.map((v) => v.nr), [1, 2], reason: 'alte Version bleibt im Verlauf, die Probeversion ist weg');
    expect(e.neueste.xml, contains('<text>B</text></answer>'));
    expect(moodle.geloescht, isNot(contains(e.neueste.id)));
    expect(moodle.geloescht, isNot(contains(alt.id)));
    expect(moodle.pluginAufrufe.where((a) => a.startsWith('POST')), hasLength(1));
  });

  test('Fehlt das Plugin, kommt der feste Satz, und nichts wird geschrieben', () async {
    final e = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    moodle.pluginDa = false;
    await expectLater(
      los(datei([(e.neueste, 'B')])),
      throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'meldung', pluginFehlt)),
    );
    expect(schreibanfragen(), 0);
    expect(e.versionen, hasLength(1));
  });

  test('Ohne Treffer, mehrdeutig oder mit anderem Typ: Abbruch vor dem ersten Schreiben', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final fremd = DoppelVersion(900, 1, FragenbankDoppel.frageXml('shortanswer', 'ZZ Fremd', 'zz-9', 'A'));
    // Ohne Treffer: andere Sachnummer.
    final ohne = DoppelVersion(a.neueste.id, 1, a.neueste.xml.replaceAll('zz-1', 'zz-404'));
    await expectLater(los(datei([(ohne, 'B')])), throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'm', contains('keine Frage'))));
    // Anderer Typ.
    final typ = DoppelVersion(a.neueste.id, 1, a.neueste.xml.replaceFirst('type="shortanswer"', 'type="truefalse"'));
    await expectLater(los(datei([(typ, 'B')])), throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'm', contains('Typ'))));
    // Mehrdeutig: zwei Einträge mit derselben Sachnummer.
    moodle.legeAn('shortanswer', 'ZZ Zwei', 'zz-1');
    await expectLater(los(datei([(a.neueste, 'B')])), throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'm', contains('mehrdeutig'))));
    expect(fremd.id, 900);
    expect(schreibanfragen(), 0);
  });

  test('Mehrere Fragen: Passt eine nicht, wird auch für die anderen nichts geschrieben', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final b = moodle.legeAn('shortanswer', 'ZZ Zwei', 'zz-2');
    final kaputt = DoppelVersion(b.neueste.id, 1, b.neueste.xml.replaceAll('zz-2', 'zz-500'));
    await expectLater(los(datei([(a.neueste, 'B'), (kaputt, 'C')])), throwsA(isA<MoodleFehler>()));
    expect(schreibanfragen(), 0);
    expect(a.versionen, hasLength(1));
  });

  test('Mehrere Fragen in einer Datei werden je einzeln eingespielt, mit einer Freigabe', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final b = moodle.legeAn('shortanswer', 'ZZ Zwei', 'zz-2');
    freigaben = Freigaben(Protokoll());
    final f = los(datei([(a.neueste, 'B'), (b.neueste, 'C')]));
    for (var i = 0; i < 200 && freigaben.aktuell == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final anfrage = freigaben.aktuell!;
    expect(anfrage.vergleich, isNotEmpty);
    expect(anfrage.punkte.join(' '), allOf(contains('zz-1'), contains('zz-2')));
    freigaben.entscheiden(true);
    final bericht = await f;
    expect(bericht, contains('verified: true'));
    expect(a.versionen.map((v) => v.nr), [1, 2]);
    expect(b.versionen.map((v) => v.nr), [1, 2]);
    expect(moodle.pluginAufrufe.where((x) => x.startsWith('POST')), hasLength(2));
  });

  test('Abgelehnte Freigabe: nichts geändert', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    freigaben = Freigaben(Protokoll());
    final f = los(datei([(a.neueste, 'B')]));
    for (var i = 0; i < 200 && freigaben.aktuell == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    freigaben.entscheiden(false);
    expect(await f, contains('Nicht eingespielt'));
    expect(schreibanfragen(), 0);
  });

  test('Eine inzwischen gespeicherte neuere Version stoppt den Aufruf und wird genannt', () async {
    final e = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final gelesen = e.neueste;
    final fremd = moodle.neueVersion(e, antwort: 'Von Hand');
    final d = datei([(gelesen, 'B')]);
    await expectLater(los(d), throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'm', allOf(contains('${fremd.id}'), contains('neuere Version')))));
    expect(schreibanfragen(), 0);
    // Ausdrücklich übergehen: die Version bleibt im Verlauf.
    final bericht = await los(d, uebergehen: fremd.id);
    expect(bericht, contains('verified: true'));
    expect(e.versionen.map((v) => v.nr), [1, 2, 3]);
  });

  test('Eine falsche Nummer zum Übergehen hilft nicht', () async {
    final e = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final gelesen = e.neueste;
    moodle.neueVersion(e, antwort: 'Von Hand');
    await expectLater(los(datei([(gelesen, 'B')]), uebergehen: 12345), throwsA(isA<MoodleFehler>()));
    expect(schreibanfragen(), 0);
  });

  test('Fehlgeschlagene Probe löscht keine nur aus dem Export ermittelte Version', () async {
    final e = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final alt = e.neueste;
    // Moodle „verliert" beim Speichern die Antwort.
    moodle.beimSpeichern = (x) => x.replaceAll(RegExp(r'<answer.*?</answer>', dotAll: true), '');
    final bericht = await los(datei([(alt, 'B')]));
    expect(bericht, contains('verified: false'));
    expect(bericht, contains('NICHT bestanden'));
    expect(e.versionen, hasLength(2));
    expect(moodle.geloescht, isEmpty);
    expect(bericht, contains('kann in Tests aktiv sein'));
    expect(bericht, contains('Nicht erneut schreiben'));
  });

  test('Paralleles Speichern nach dem Import berechtigt niemals zum Löschen der fremden Version', () async {
    final e = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final alt = e.neueste;
    late DoppelVersion fremd;
    moodle.nachPluginImport = (d) => fremd = d.neueVersion(e, antwort: 'Von Hand');
    final bericht = await los(datei([(alt, 'B')]));
    expect(bericht, contains('verified: false'));
    expect(e.versionen, hasLength(3));
    expect(e.neueste.id, fremd.id);
    expect(e.neueste.xml, contains('Von Hand'));
    expect(moodle.geloescht, isEmpty);
    expect(moodle.gespeichertMitStatus, isEmpty);
  });

  test('Nach einer Sperre (unklarer Ausgang) wird nicht wiederholt', () async {
    final e = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    // Das Plugin legt nichts an (Datei abgewiesen): Ausgang bleibt offen, die Sperre steht.
    moodle.pluginLegtNichtAn = true;
    final d = datei([(e.neueste, 'B')]);
    final bericht = await los(d);
    expect(bericht, contains('verified: false'));
    expect(bericht, contains('Nicht erneut schreiben'));
    final zweiter = await los(d);
    expect(zweiter, contains('Nicht erneut schreiben'));
    expect(moodle.pluginAufrufe.where((x) => x.startsWith('POST')), hasLength(1));
  });

  test('Eine neue STACK-Version ohne bestandene Fragetests erhält weder verified noch einen Notiznachweis', () async {
    final e = moodle.legeAn('stack', 'ZZ STACK', 'zz-stack');
    e.neueste.xml = stackXml({
      'name': 'ZZ STACK', 'idnummer': 'zz-stack',
      'fragetext': '<p>[[input:ans1]] [[validation:ans1]]</p>',
      'eingaben': [{'name': 'ans1', 'typ': 'algebraic', 'tans': '1'}],
      'prts': [{ 'name': 'prt1', 'knoten': [
        {'test': 'AlgEquiv', 'sans': 'ans1', 'tans': '1', 'wahr': {'punkte': 1}, 'falsch': {'punkte': 0}}
      ]}],
      'tests': [{'eingaben': {'ans1': '1'}, 'erwartet': {'prt1': {'punkte': 1, 'abzug': 0, 'hinweis': 'prt1-1-T'}}}],
    }, version: '2026010500');
    moodle.stackTestHtml = '<div id="region-main"><p>Keine Fragetests</p></div>';
    var nachweise = 0;
    final bericht = await fragenVersionImportieren(zugang, freigaben, ao.path,
        sammlung: FragenbankDoppel.sammlung, kategorie: 'ZZ Probe', datei: datei([(e.neueste, 'B')]),
        beiBestanden: (_, _, _) => nachweise++);
    expect(bericht, contains('verified: false'));
    expect(bericht, contains('STACK-Fragetests'));
    expect(nachweise, 0);
    expect(moodle.anfragen.any((a) => a.contains('/question/type/stack/questiontestrun.php')), isTrue);
    expect(e.versionen, hasLength(2));
    expect(moodle.geloescht, hasLength(1), reason: 'nur die direkt bestätigte Probeversion wird gelöscht');
  });
}
