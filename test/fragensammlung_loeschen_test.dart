// Eine Fragensammlung löschen (loeschen, E9, E20) gegen das Moodle-Doppel: Sie
// fragt auf jeder Stufe, mit einem Haken je Kategorie, und sichert vorher alle
// Fragen als XML in den dauerhaften Ordner. Nur Moodle ist ersetzt.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/fragen_xml.dart';
import 'package:moocp/moodle/kurs_aendern.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'hilfen/fragenbank_doppel.dart';

void main() {
  late FragenbankDoppel moodle;
  late MoodleZugang zugang;
  late Directory sicherungen;
  late Directory vorgaenge;
  late Freigaben freigaben;

  Future<void> stufeSetzen(Bestaetigungen stufe) async {
    freigaben = Freigaben(Protokoll(), stufe: stufe);
  }

  setUp(() async {
    moodle = FragenbankDoppel();
    await moodle.starten();
    sicherungen = Directory.systemTemp.createTempSync('sammlung-loeschen-sicherung-');
    vorgaenge = Directory.systemTemp.createTempSync('sammlung-loeschen-vorgaenge-');
    freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
    zugang = await MoodleZugang.fuerTest(Protokoll(), moodle.basis,
        benutzer: FragenbankDoppel.benutzer, passwort: FragenbankDoppel.passwort, schreibvorgaengeOrdner: vorgaenge.path);
    // Bank 12 „ZZ Bank": Kategorie „ZZ Probe" mit Unterkategorie „ZZ Unter" und einer leeren.
    moodle.legeKategorieAn(2, 'ZZ Unter', eltern: 1);
    moodle.legeKategorieAn(3, 'ZZ Leer');
    moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    moodle.legeAn('shortanswer', 'ZZ Zwei', 'zz-2');
    moodle.legeAn('shortanswer', 'ZZ Drei', 'zz-3', kategorie: 2);
  });

  tearDown(() async {
    await moodle.stoppen();
    for (final d in [sicherungen, vorgaenge]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  Future<String> los({int cmid = FragenbankDoppel.sammlung, String name = 'ZZ Bank', String? ordner}) =>
      loeschen(zugang, freigaben, kurs: 12, cmid: cmid, name: name, sicherungsOrdner: ordner ?? sicherungen.path);

  Future<FreigabeAnfrage> aufFreigabe() async {
    for (var i = 0; i < 400 && freigaben.aktuell == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return freigaben.aktuell!;
  }

  List<File> dateien() =>
      sicherungen.existsSync() ? sicherungen.listSync(recursive: true).whereType<File>().toList() : <File>[];

  bool kursAktion(String aktion) => moodle.kursAktionen.any((a) => a.aktion == aktion);

  test('Auf jeder Stufe: Freigabe mit einem Haken je Kategorie, Sicherung vor dem Löschen, dann gelöscht', () async {
    List<String>? beimLoeschen;
    moodle.beiKursAktion = () => beimLoeschen = [for (final f in dateien()) f.readAsStringSync()];

    final f = los();
    final anfrage = await aufFreigabe();
    expect(freigaben.stufe, Bestaetigungen.keine);
    expect(anfrage.ab, Bestaetigungen.keine);
    expect(anfrage.abhaken, hasLength(3));
    expect(anfrage.abhaken[0], allOf(contains('ZZ Probe'), contains('2 Fragen')));
    expect(anfrage.abhaken[1], allOf(contains('ZZ Probe / ZZ Unter'), contains('1 Frage')));
    expect(anfrage.abhaken[2], allOf(contains('ZZ Leer'), contains('0 Fragen')));
    final text = anfrage.punkte.join('\n');
    expect(text, contains(sicherungen.path));
    expect(text, contains('Verborgene Fragen'));
    expect(kursAktion('cm_delete'), isFalse, reason: 'bis zur Freigabe wird nichts gelöscht');
    expect(dateien(), hasLength(1));

    freigaben.entscheiden(true);
    final bericht = await f;
    expect(bericht, contains('verified: true'));
    expect(bericht, contains(dateien().single.path));
    expect(bericht, contains('Verborgene Fragen'));
    expect(moodle.kursBanken, isEmpty);

    expect(beimLoeschen, hasLength(1), reason: 'die Sicherung lag vor dem Löschen da');
    final datei = dateien().single;
    expect(p.basename(datei.path), matches(RegExp(r'^sammlung-12-geloescht-\d{8}-\d{6}\.xml$')));
    expect(p.dirname(datei.path), sicherungen.path);
    final xml = datei.readAsStringSync();
    expect([for (final q in fragenAusXml(xml)) q.name], unorderedEquals(['ZZ Eins', 'ZZ Zwei', 'ZZ Drei']));
    // Die Kategorien stehen mit in der Datei, damit sie im Ganzen wieder einzuspielen ist.
    expect(xml, allOf(contains('type="category"'), contains('ZZ Probe/ZZ Unter'), contains('ZZ Leer')));
  });

  test('Abgelehnt: nichts gelöscht, keine Sicherungsdatei bleibt liegen', () async {
    final f = los();
    await aufFreigabe();
    freigaben.entscheiden(false);
    expect(await f, contains('Nicht gelöscht'));
    expect(kursAktion('cm_delete'), isFalse);
    expect(moodle.kursBanken, isNotEmpty);
    expect(dateien(), isEmpty);
  });

  test('Eine Sicherung, die sich nicht schreiben lässt, verhindert Freigabe und Löschen', () async {
    final blockiert = File(p.join(vorgaenge.path, 'datei'))..writeAsStringSync('x');
    await expectLater(
      los(ordner: p.join(blockiert.path, 'unter')),
      throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'meldung', allOf(contains('nichts gelöscht'), contains('Sicherung')))),
    );
    expect(freigaben.aktuell, isNull);
    expect(kursAktion('cm_delete'), isFalse);
  });

  test('Passt der Name nicht, bricht es ab, bevor gesichert oder gefragt wird', () async {
    await expectLater(los(name: 'ZZ Falsch'), throwsA(isA<MoodleFehler>()));
    expect(freigaben.aktuell, isNull);
    expect(dateien(), isEmpty);
    expect(kursAktion('cm_delete'), isFalse);
  });

  test('Ändert sich die Sammlung, während die Freigabe offen ist, wird nichts gelöscht', () async {
    final f = los();
    final erwartet =
        expectLater(f, throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'meldung', contains('nichts gelöscht'))));
    await aufFreigabe();
    moodle.legeAn('shortanswer', 'ZZ Neu dazu', 'zz-9');
    freigaben.entscheiden(true);
    await erwartet;
    expect(kursAktion('cm_delete'), isFalse);
    expect(dateien(), isEmpty);
  });

  test('Wirkt das Löschen nicht, steht verified: false in der Antwort; die Sicherung bleibt', () async {
    moodle.kursLoeschenWirktNicht = true;
    final f = los();
    await aufFreigabe();
    freigaben.entscheiden(true);
    final bericht = await f;
    expect(bericht, contains('verified: false'));
    expect(dateien(), hasLength(1));
  });

  test('Ohne Test, der die Sammlung benutzt: kein Hinweis auf Tests, nur der kurze Satz zu verborgenen Fragen', () async {
    moodle.legeTestAn(40, 'ZZ Anderer Test', [(moodle.eintraege.first, 1, 1.0)]); // Bank des Tests selbst, keine Herkunft
    final f = los();
    final anfrage = await aufFreigabe();
    final text = anfrage.punkte.join('\n');
    expect(text, contains('Verborgene Fragen stehen in keiner Sicherung.'));
    expect(text, isNot(contains('Test „')));
    expect(text, isNot(contains('anderen Kursen')));
    freigaben.entscheiden(true);
    final bericht = await f;
    expect(bericht, isNot(contains('Test „')));
  });

  test('Benutzt ein Test Fragen der Sammlung (fest oder zufällig), nennt der Dialog ihn mit der Zahl der Plätze', () async {
    // Die Frage „ZZ Zwei" steckt in einem Test und ist durch ein Löschen verborgen: Moodle zählt sie nicht
    // mehr mit, und der Export liefert sie nicht.
    final zwei = moodle.eintraege.firstWhere((e) => e.neueste.name == 'ZZ Zwei');
    moodle.legeTestAn(40, 'ZZ Test', [(zwei, 1, 1.0), (zwei, 1, 1.0), (moodle.eintraege.first, 1, 1.0)]);
    moodle.testPlaetze[40]![0].bank = FragenbankDoppel.sammlung;
    moodle.testPlaetze[40]![1]
      ..bank = FragenbankDoppel.sammlung
      ..zufall = true;
    moodle.testPlaetze[40]![2].bank = 99; // eine andere Sammlung
    moodle.legeTestAn(41, 'ZZ Anderer Test', [(zwei, 1, 1.0)]); // ohne Herkunft
    moodle.versteckt.add(zwei.neueste.id);

    final f = los();
    final anfrage = await aufFreigabe();
    final text = anfrage.punkte.join('\n');
    expect(text, contains('Test „ZZ Test" (cmid 40): 2 Plätze aus der Sammlung „ZZ Bank"'));
    expect(text, isNot(contains('ZZ Anderer Test')));
    expect(text, allOf(contains('können verborgen sein'), contains('nicht geprüft'), contains('anderen Kursen')));
    // Die verborgene Frage ist in Moodles Zahl nicht enthalten: „ZZ Probe" zählt nur „ZZ Eins".
    expect(anfrage.abhaken[0], allOf(contains('ZZ Probe'), contains('1 Frage')));
    expect(kursAktion('cm_delete'), isFalse);
    freigaben.entscheiden(true);
    final bericht = await f;
    expect(bericht, allOf(contains('verified: true'), contains('Test „ZZ Test" (cmid 40): 2 Plätze'), contains('können verborgen sein')));
    expect([for (final q in fragenAusXml(dateien().single.readAsStringSync())) q.name], isNot(contains('ZZ Zwei')));
  });

  test('Ein Test, der sich nicht lesen lässt, bricht ab, bevor gesichert oder gefragt wird', () async {
    moodle.kursAktivitaeten[40] = (name: 'ZZ Kaputt', modul: 'quiz', abschnitt: 5); // Zusammenstellung: 404
    await expectLater(
      los(),
      throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'meldung',
          allOf(contains('nichts gelöscht'), contains('ZZ Kaputt'), contains('lässt sich nicht lesen')))),
    );
    expect(freigaben.aktuell, isNull);
    expect(dateien(), isEmpty);
    expect(kursAktion('cm_delete'), isFalse);
  });

  test('Eine Kategorie mit nur verborgenen Fragen zählt 0, wird nicht exportiert und gilt als leer', () async {
    moodle.legeKategorieAn(4, 'ZZ Nur Verborgen');
    final h = moodle.legeAn('shortanswer', 'ZZ Weg', 'zz-weg', kategorie: 4);
    moodle.versteckt.add(h.neueste.id);
    final f = los();
    final anfrage = await aufFreigabe();
    expect(anfrage.abhaken.where((t) => t.contains('ZZ Nur Verborgen')).single, contains('0 Fragen'));
    expect(moodle.exportAufrufe, isNot(contains(4)));
    expect(moodle.exportAufrufe, containsAll([1, 2]));
    freigaben.entscheiden(false);
    await f;
  });

  test('Scheitert der Export einer Kategorie mit Fragen, bricht es vor der Freigabe ab; nichts bleibt liegen', () async {
    moodle.exportAbgelehnt.add(2);
    await expectLater(
      los(),
      throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'meldung',
          allOf(contains('nichts gelöscht'), contains('lassen sich nicht sichern')))),
    );
    expect(freigaben.aktuell, isNull);
    expect(dateien(), isEmpty);
    expect(kursAktion('cm_delete'), isFalse);
  });

  test('Andere Aktivitäten fragen weiter erst ab „mittel", ohne Haken und ohne Sicherung', () async {
    moodle.kursAktivitaeten[31] = (name: 'ZZ Text', modul: 'page', abschnitt: 5);
    final f = loeschen(zugang, freigaben, kurs: 12, cmid: 31, name: 'ZZ Text', sicherungsOrdner: sicherungen.path);
    expect(await f, contains('verified: true'), reason: 'auf Stufe „keine" ohne Dialog');
    expect(dateien(), isEmpty);

    await stufeSetzen(Bestaetigungen.mittel);
    moodle.kursAktivitaeten[32] = (name: 'ZZ Text 2', modul: 'page', abschnitt: 5);
    final g = loeschen(zugang, freigaben, kurs: 12, cmid: 32, name: 'ZZ Text 2', sicherungsOrdner: sicherungen.path);
    final anfrage = await aufFreigabe();
    expect(anfrage.ab, Bestaetigungen.mittel);
    expect(anfrage.abhaken, isEmpty);
    freigaben.entscheiden(true);
    await g;
    expect(dateien(), isEmpty);
  });

  test('Steht die Sammlung in einem Abschnitt, der gelöscht wird, gilt dasselbe für sie', () async {
    // Nicht gemessen, ob Moodle eine Sammlung je in einem Abschnitt der Kursstruktur zeigt; der Weg gilt vorsorglich.
    moodle.kursAktivitaeten[12] = (name: 'ZZ Bank', modul: 'qbank', abschnitt: 5);
    final f = loeschen(zugang, freigaben, kurs: 12, abschnittId: 5, name: 'Thema 1', sicherungsOrdner: sicherungen.path);
    final anfrage = await aufFreigabe();
    expect(anfrage.ab, Bestaetigungen.keine);
    expect(anfrage.abhaken, hasLength(3));
    expect(dateien(), hasLength(1));
    freigaben.entscheiden(true);
    final bericht = await f;
    expect(bericht, contains('verified: true'));
    expect(bericht, contains(dateien().single.path));
    expect(kursAktion('section_delete'), isTrue);
  });

  test('Steht die Sammlung als Aktivität in der Kursstruktur, fragt auch dieser Weg mit Haken und Sicherung', () async {
    moodle.kursAktivitaeten[12] = (name: 'ZZ Bank', modul: 'qbank', abschnitt: 5);
    final f = los();
    final anfrage = await aufFreigabe();
    expect(anfrage.ab, Bestaetigungen.keine);
    expect(anfrage.abhaken, hasLength(3));
    expect(dateien(), hasLength(1));
    freigaben.entscheiden(false);
    expect(await f, contains('Nicht gelöscht'));
    expect(dateien(), isEmpty);
  });

  void unterabschnittAnlegen() {
    moodle.kursAbschnitte[7] = 'ZZ Unterabschnitt';
    moodle.kursAktivitaeten[60] = (name: 'ZZ Unterabschnitt', modul: 'subsection', abschnitt: 5);
    moodle.unterabschnitte[60] = 7;
    moodle.kursAktivitaeten[12] = (name: 'ZZ Bank', modul: 'qbank', abschnitt: 7);
  }

  test('Steht die Sammlung in einem Unterabschnitt des gelöschten Abschnitts, gilt dasselbe für sie', () async {
    unterabschnittAnlegen();
    final f = loeschen(zugang, freigaben, kurs: 12, abschnittId: 5, name: 'Thema 1', sicherungsOrdner: sicherungen.path);
    final anfrage = await aufFreigabe();
    expect(anfrage.ab, Bestaetigungen.keine);
    expect(anfrage.abhaken, hasLength(3));
    expect(dateien(), hasLength(1));
    freigaben.entscheiden(true);
    expect(await f, contains('verified: true'));
    expect(kursAktion('section_delete'), isTrue);
  });

  test('Wer den Unterabschnitt löscht, in dem die Sammlung steht, bekommt Haken und Sicherung', () async {
    unterabschnittAnlegen();
    final f = loeschen(zugang, freigaben, kurs: 12, cmid: 60, name: 'ZZ Unterabschnitt', sicherungsOrdner: sicherungen.path);
    final anfrage = await aufFreigabe();
    expect(anfrage.ab, Bestaetigungen.keine);
    expect(anfrage.abhaken, hasLength(3));
    expect(dateien(), hasLength(1));
    freigaben.entscheiden(false);
    expect(await f, contains('Nicht gelöscht'));
    expect(dateien(), isEmpty);
  });

  test('Ändert sich die Sammlung im gelöschten Abschnitt, während die Freigabe offen ist, wird nichts gelöscht', () async {
    moodle.kursAktivitaeten[12] = (name: 'ZZ Bank', modul: 'qbank', abschnitt: 5);
    final f = loeschen(zugang, freigaben, kurs: 12, abschnittId: 5, name: 'Thema 1', sicherungsOrdner: sicherungen.path);
    final erwartet =
        expectLater(f, throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'meldung', contains('nichts gelöscht'))));
    await aufFreigabe();
    moodle.legeAn('shortanswer', 'ZZ Neu dazu', 'zz-9');
    freigaben.entscheiden(true);
    await erwartet;
    expect(kursAktion('section_delete'), isFalse);
    expect(dateien(), isEmpty);
  });
}
