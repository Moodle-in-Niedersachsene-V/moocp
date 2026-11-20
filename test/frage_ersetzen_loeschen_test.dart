// frage_ersetzen mit loeschen: true (E9, E20) gegen das Moodle-Doppel mit Fragensammlung und
// Test: Die Freigabe kommt auf jeder Stufe mit einem Haken, die alte Frage ist vor dem Löschen
// als XML gesichert, und ändert sie sich nach der Freigabe, bleibt sie stehen. Nur Moodle ist ersetzt.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/fragen_xml.dart';
import 'package:moocp/moodle/frage_ersetzen.dart';
import 'package:moocp/protokoll.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:path/path.dart' as p;

import 'hilfen/fragenbank_doppel.dart';

void main() {
  late FragenbankDoppel moodle;
  late MoodleZugang zugang;
  late Directory ao;
  late Directory sicherungen;
  late Directory vorgaenge;
  late Freigaben freigaben;
  late DoppelEintrag alt;
  late DoppelEintrag anderes;

  setUp(() async {
    moodle = FragenbankDoppel();
    await moodle.starten();
    ao = Directory.systemTemp.createTempSync('ersetzen-');
    sicherungen = Directory.systemTemp.createTempSync('ersetzen-sicherung-');
    vorgaenge = Directory.systemTemp.createTempSync('ersetzen-vorgaenge-');
    freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
    zugang = await MoodleZugang.fuerTest(Protokoll(), moodle.basis,
        benutzer: FragenbankDoppel.benutzer, passwort: FragenbankDoppel.passwort, schreibvorgaengeOrdner: vorgaenge.path);
    alt = moodle.legeAn('shortanswer', 'ZZ Alt', 'zz-alt');
    anderes = moodle.legeAn('shortanswer', 'ZZ Anderes', 'zz-anderes');
    moodle.legeTestAn(40, 'ZZ Test', [(alt, 1, 2.0), (anderes, 1, 1.0)]);
    File(p.join(ao.path, 'neu.xml')).writeAsStringSync(
        '<?xml version="1.0" encoding="UTF-8"?><quiz>${FragenbankDoppel.frageXml('shortanswer', 'ZZ Neu', 'zz-neu', 'B')}</quiz>');
  });

  tearDown(() async {
    await moodle.stoppen();
    for (final d in [ao, sicherungen, vorgaenge]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  Future<String> los({required bool loeschen}) => frageErsetzen(
        zugang,
        freigaben,
        ao.path,
        sammlung: FragenbankDoppel.sammlung,
        kategorie: 'ZZ Probe',
        frage: alt.neueste.id,
        name: 'ZZ Alt',
        datei: 'neu.xml',
        tests: [(40, 'ZZ Test')],
        loeschen: loeschen,
        stackTesten: (_) async => '',
        sicherungsOrdner: sicherungen.path,
      );

  Future<FreigabeAnfrage> aufFreigabe() async {
    for (var i = 0; i < 400 && freigaben.aktuell == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return freigaben.aktuell!;
  }

  List<File> dateien() =>
      sicherungen.existsSync() ? sicherungen.listSync(recursive: true).whereType<File>().toList() : <File>[];

  int? neueId() => moodle.eintraege.where((e) => e.versionen.isNotEmpty && e.neueste.name == 'ZZ Neu').firstOrNull?.neueste.id;

  test('Auf jeder Stufe: Freigabe mit Haken, Sicherung der alten Frage vor dem Löschen, Platz getauscht, alte Frage gelöscht',
      () async {
    final altId = alt.neueste.id;
    var beimLoeschen = <String>[];
    moodle.beiLoeschen = () => beimLoeschen = [for (final f in dateien()) f.readAsStringSync()];

    final f = los(loeschen: true);
    final anfrage = await aufFreigabe();
    expect(freigaben.stufe, Bestaetigungen.keine);
    expect(anfrage.ab, Bestaetigungen.keine);
    expect(anfrage.abhaken.single, allOf(contains('ZZ Alt'), contains('$altId')));
    expect(anfrage.punkte.join('\n'), allOf(contains(sicherungen.path), contains('aktuelle Version')));
    expect(dateien(), hasLength(1), reason: 'die Sicherung liegt vor der Freigabe da');
    expect(neueId(), isNull, reason: 'bis zur Freigabe wird nichts importiert');
    expect(moodle.geloescht, isEmpty);

    freigaben.entscheiden(true);
    final bericht = await f;

    expect(bericht, contains('verified: true'), reason: bericht);
    expect(moodle.geloescht, contains(altId));
    expect(alt.versionen, isEmpty);
    expect(beimLoeschen, hasLength(1), reason: 'die Sicherung lag beim Löschen schon da');
    expect([for (final x in fragenAusXml(beimLoeschen.single)) x.name], ['ZZ Alt']);
    expect(dateien(), hasLength(1), reason: 'nach dem Löschen bleibt die Sicherung');
    // Der Platz zeigt auf die neue Frage, an derselben Stelle mit denselben Punkten.
    final plaetze = moodle.testPlaetze[40]!;
    expect(plaetze, hasLength(2));
    expect(plaetze.first.frage, neueId());
    expect(plaetze.first.punkte, 2.0);
    expect(plaetze.last.frage, anderes.neueste.id);
  });

  test('Abgelehnt: nichts importiert, getauscht oder gelöscht, keine Sicherungsdatei bleibt liegen', () async {
    final vorher = [for (final x in moodle.testPlaetze[40]!) x.frage];
    final f = los(loeschen: true);
    await aufFreigabe();
    freigaben.entscheiden(false);
    expect(await f, contains('Nicht ersetzt'));
    expect(dateien(), isEmpty);
    expect(neueId(), isNull);
    expect(moodle.geloescht, isEmpty);
    expect([for (final x in moodle.testPlaetze[40]!) x.frage], vorher);
    expect(alt.versionen, isNotEmpty);
  });

  test('Ändert sich die alte Frage nach der Freigabe, bleibt sie stehen: verified false, keine Sicherung bleibt liegen', () async {
    // Erst beim Einfügen der neuen Frage in den Test, also nach der Freigabe und vor dem Löschen.
    moodle.beiPlatzEinfuegen = () => alt.neueste.xml = alt.neueste.xml.replaceAll('<text>A</text></answer>', '<text>C</text></answer>');
    final altId = alt.neueste.id;
    final f = los(loeschen: true);
    await aufFreigabe();
    freigaben.entscheiden(true);
    final bericht = await f;

    expect(bericht, contains('verified: false'), reason: bericht);
    expect(bericht, contains('NICHT gelöscht'));
    expect(moodle.geloescht, isNot(contains(altId)));
    expect(alt.versionen, isNotEmpty);
    expect(dateien(), isEmpty, reason: 'eine Frage, die nicht gelöscht wurde, hat keine Sicherung gebraucht');
    // Der Tausch im Test ist trotzdem geschehen: Das meldet die Antwort als abweichend.
    expect(moodle.testPlaetze[40]!.first.frage, neueId());
  });

  test('Ohne Löschen fragt es nur ab „mittel", ohne Haken und ohne Sicherung; die alte Frage bleibt', () async {
    final bericht = await los(loeschen: false);
    expect(bericht, contains('verified: true'), reason: bericht);
    expect(dateien(), isEmpty);
    expect(moodle.geloescht, isNot(contains(alt.neueste.id)));
    expect(alt.versionen, isNotEmpty);
    expect(moodle.testPlaetze[40]!.first.frage, neueId());
  });
}
