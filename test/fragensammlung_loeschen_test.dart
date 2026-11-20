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

  test('Eine nicht exportierbare (verborgene) Frage steht nicht in der Sicherung, und der Dialog sagt es', () async {
    final verborgen = moodle.eintraege.firstWhere((e) => e.neueste.name == 'ZZ Zwei');
    moodle.versteckt.add(verborgen.neueste.id);
    final f = los();
    final anfrage = await aufFreigabe();
    expect(anfrage.punkte.join('\n'), contains('Verborgene Fragen'));
    freigaben.entscheiden(true);
    expect(await f, contains('verified: true'));
    expect([for (final q in fragenAusXml(dateien().single.readAsStringSync())) q.name], isNot(contains('ZZ Zwei')));
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
}
