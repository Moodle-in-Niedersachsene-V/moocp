// fragen_loeschen (E9, E20) gegen das Moodle-Doppel mit Fragensammlung:
// Die Freigabe kommt auf jeder Stufe, jede Frage wird einzeln abgehakt, vor
// dem ersten Löschen liegt eine XML-Sicherung der aktuellen Versionen in einem
// dauerhaften Ordner, und die Antwort trennt gelöscht von nur verborgen.
// Nur Moodle ist ersetzt; Prüfung, Freigabe, Sicherung und Rücklesen laufen echt.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/fragen.dart';
import 'package:moocp/moodle/fragen_xml.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'hilfen/fragenbank_doppel.dart';

void main() {
  late FragenbankDoppel moodle;
  late MoodleZugang zugang;
  late Directory ao;
  late Directory sicherungen;
  late Directory vorgaenge;
  late Freigaben freigaben;

  setUp(() async {
    moodle = FragenbankDoppel();
    await moodle.starten();
    ao = Directory.systemTemp.createTempSync('loeschen-');
    sicherungen = Directory.systemTemp.createTempSync('loeschen-sicherung-');
    vorgaenge = Directory.systemTemp.createTempSync('loeschen-vorgaenge-');
    // Auch auf der niedrigsten Stufe muss die Freigabe kommen.
    freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
    zugang = await MoodleZugang.fuerTest(Protokoll(), moodle.basis,
        benutzer: FragenbankDoppel.benutzer, passwort: FragenbankDoppel.passwort, schreibvorgaengeOrdner: vorgaenge.path);
  });

  tearDown(() async {
    await moodle.stoppen();
    for (final d in [ao, sicherungen, vorgaenge]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  Future<String> los(List<DoppelEintrag> fragen, {String? ordner, Map<int, String> namen = const {}}) => fragenLoeschen(
        zugang,
        freigaben,
        ao.path,
        sammlung: FragenbankDoppel.sammlung,
        fragen: [for (final e in fragen) (e.neueste.id, namen[e.neueste.id] ?? e.neueste.name)],
        sicherungsOrdner: ordner ?? sicherungen.path,
      );

  Future<FreigabeAnfrage> aufFreigabe() async {
    for (var i = 0; i < 400 && freigaben.aktuell == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return freigaben.aktuell!;
  }

  int loeschAnfragen() => moodle.anfragen.where((a) => a.startsWith('POST') && a.contains('deletequestion')).length;

  List<File> dateien() => sicherungen.existsSync()
      ? sicherungen.listSync(recursive: true).whereType<File>().toList()
      : <File>[];

  test('Auf jeder Stufe: Freigabe mit einem Haken je Frage, Sicherung vor dem Löschen, dann gelöscht', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final b = moodle.legeAn('shortanswer', 'ZZ Zwei', 'zz-2');
    final ids = [a.neueste.id, b.neueste.id];
    // Beim ersten Löschen muss die Sicherung schon vollständig da sein.
    var beimLoeschen = <String>[];
    moodle.beiLoeschen = () => beimLoeschen = [for (final f in dateien()) f.readAsStringSync()];

    final f = los([a, b]);
    final anfrage = await aufFreigabe();
    expect(freigaben.stufe, Bestaetigungen.keine);
    expect(anfrage.ab, Bestaetigungen.keine);
    expect(anfrage.abhaken, hasLength(2));
    expect(anfrage.abhaken.join(' '), allOf(contains('ZZ Eins'), contains('ZZ Zwei')));
    expect(anfrage.punkte.join(' '), allOf(contains(sicherungen.path), contains('aktuelle Version')));
    expect(loeschAnfragen(), 0, reason: 'bis zur Freigabe wird nichts gelöscht');
    freigaben.entscheiden(true);
    final bericht = await f;

    expect(bericht, contains('verified: true'));
    expect(bericht, contains(sicherungen.path));
    expect(moodle.geloescht, containsAll(ids));
    expect(beimLoeschen, hasLength(1), reason: 'die Sicherung lag vor dem Löschen da');
    final fragen = fragenAusXml(beimLoeschen.single);
    expect([for (final x in fragen) x.id], unorderedEquals(ids));
    expect(dateien().single.lengthSync(), greaterThan(0));
    expect(p.basename(dateien().single.path), endsWith('.xml'));
  });

  test('Eine Frage allein wird ebenfalls gesichert', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final f = los([a]);
    await aufFreigabe();
    freigaben.entscheiden(true);
    expect(await f, contains('verified: true'));
    expect(dateien(), hasLength(1));
  });

  test('Abgelehnt: nichts gelöscht, keine Sicherungsdatei bleibt liegen', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final f = los([a]);
    await aufFreigabe();
    freigaben.entscheiden(false);
    expect(await f, contains('Nicht gelöscht'));
    expect(loeschAnfragen(), 0);
    expect(moodle.geloescht, isEmpty);
    expect(dateien(), isEmpty);
  });

  test('Lässt sich eine Frage nicht exportieren, kommt keine Freigabe und wird nichts gelöscht', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final b = moodle.legeAn('shortanswer', 'ZZ Zwei', 'zz-2');
    moodle.verborgen.add(b.neueste.id);
    await expectLater(
      los([a, b]),
      throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'meldung', allOf(contains('${b.neueste.id}'), contains('Sicherung')))),
    );
    expect(freigaben.aktuell, isNull);
    expect(loeschAnfragen(), 0);
    expect(dateien(), isEmpty);
    expect(a.versionen, hasLength(1));
  });

  test('Ein Name, der nicht passt, bricht ab, bevor etwas geschieht', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    await expectLater(los([a], namen: {a.neueste.id: 'ZZ Falsch'}), throwsA(isA<MoodleFehler>()));
    expect(freigaben.aktuell, isNull);
    expect(loeschAnfragen(), 0);
    expect(dateien(), isEmpty);
  });

  test('Eine Sicherung, die sich nicht schreiben lässt, verhindert das Löschen', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final blockiert = File(p.join(ao.path, 'datei'))..writeAsStringSync('x');
    await expectLater(
      los([a], ordner: p.join(blockiert.path, 'unter')),
      throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'meldung', contains('Sicherung'))),
    );
    expect(freigaben.aktuell, isNull);
    expect(loeschAnfragen(), 0);
  });

  test('Ändert sich eine Frage während die Freigabe offen ist, wird nichts gelöscht', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final f = los([a]);
    final erwartet = expectLater(f, throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'meldung', contains('nichts gelöscht'))));
    await aufFreigabe();
    a.neueste.xml = a.neueste.xml.replaceAll('ZZ Eins', 'ZZ Umbenannt');
    freigaben.entscheiden(true);
    await erwartet;
    expect(loeschAnfragen(), 0);
    expect(dateien(), isEmpty);
  });

  test('Steckt eine Frage in einem Test, sagt es die Freigabe vorher und die Antwort nachher: nur verborgen', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final b = moodle.legeAn('shortanswer', 'ZZ Zwei', 'zz-2');
    final idA = a.neueste.id;
    moodle.inBenutzung.add(b.neueste.id);
    final f = los([a, b]);
    final anfrage = await aufFreigabe();
    final zeileB = anfrage.abhaken.firstWhere((z) => z.contains('ZZ Zwei'));
    expect(zeileB, contains('verbirgt'));
    expect(anfrage.abhaken.firstWhere((z) => z.contains('ZZ Eins')), isNot(contains('verbirgt')));
    freigaben.entscheiden(true);
    final bericht = await f;
    expect(bericht, contains('verified: false'));
    expect(bericht, contains('gelöscht: „ZZ Eins"'));
    expect(bericht, contains('nur verborgen: „ZZ Zwei"'));
    expect(moodle.geloescht, [idA]);
  });

  test('Mehr Fragen als der Dialog sinnvoll zeigt: Abbruch mit Hinweis auf Teilaufrufe', () async {
    final alle = [for (var i = 0; i < 26; i++) moodle.legeAn('shortanswer', 'ZZ F$i', 'zz-$i')];
    await expectLater(los(alle), throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'meldung', contains('25'))));
    expect(freigaben.aktuell, isNull);
  });
}
