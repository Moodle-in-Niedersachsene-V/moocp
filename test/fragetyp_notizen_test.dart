// Fragetyp-Notizen (E38): geliefert mit dem Skill, lokal je Instanzprofil; die
// lokale gilt; geschrieben wird nur nach bestandener Rundlaufprobe, mit dem
// Beispiel aus dieser Probe.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/moodle/fragetyp_notizen.dart';
import 'package:moocp/moodle/moodle_zugang.dart';

void main() {
  late Directory ordner;
  late FragetypNotizen n;
  const geliefert = {'multichoice': '# Fragetyp-Notiz: multichoice\nMoodle-Version: 5.1\nProbe bestanden am: 2026-11-19\n\n## Stolpersteine\nGeliefert.\n'};

  setUp(() {
    ordner = Directory.systemTemp.createTempSync('notizen-');
    n = FragetypNotizen(lokalerOrdner: ordner.path, geliefert: (t) async => geliefert[t], heute: () => DateTime(2026, 11, 20));
  });
  tearDown(() => ordner.deleteSync(recursive: true));

  test('Ohne Notiz sagt die Antwort es und nennt den Weg', () async {
    expect(await n.lesen('ddwtos'), allOf(contains('Keine Notiz'), contains('Beispielfrage')));
  });

  test('Eine mitgelieferte Notiz nennt ihre Quelle', () async {
    final t = await n.lesen('multichoice');
    expect(t, allOf(contains('Quelle: Skill'), contains('Geliefert.'), contains('Moodle-Version: 5.1')));
  });

  test('Schreiben ohne bestandene Probe in diesem Profil wird verweigert', () async {
    await expectLater(
      n.schreiben('multichoice', pflichtstruktur: 'x', stolpersteine: 'y', ausbaustufen: 'z'),
      throwsA(isA<MoodleFehler>().having((e) => e.meldung, 'm', contains('Rundlaufprobe'))),
    );
    expect(Directory(ordner.path).listSync().whereType<File>(), isEmpty);
  });

  test('Nach der Probe schreibt die App die Notiz mit dem Beispiel aus der Probe; die lokale gilt', () async {
    n.nachweis('multichoice', '<quiz><question type="multichoice"/></quiz>', '5.2');
    final pfad = await n.schreiben('multichoice',
        pflichtstruktur: 'Mindestens zwei Antworten.', stolpersteine: 'Symptom: x. Ursache: y. Abhilfe: z.', ausbaustufen: 'Mehrere richtig.');
    expect(File(pfad).existsSync(), isTrue);
    final t = await n.lesen('multichoice');
    expect(t, allOf(contains('Quelle: Instanz'), contains('Moodle-Version: 5.2'), contains('Probe bestanden am: 2026-11-20'), contains('<question type="multichoice"/>'), contains('Mindestens zwei Antworten.')));
    expect(t, isNot(contains('Geliefert.')));
  });

  test('Der Nachweis gilt je Typ: Für einen anderen Typ lässt sich nichts schreiben', () async {
    n.nachweis('multichoice', '<quiz/>', null);
    await expectLater(n.schreiben('ddwtos', pflichtstruktur: 'a', stolpersteine: 'b', ausbaustufen: 'c'), throwsA(isA<MoodleFehler>()));
  });

  test('Typnamen sind nur Kleinbuchstaben: Kein Pfad aus dem Typ', () async {
    await expectLater(n.lesen('../x'), throwsA(isA<MoodleFehler>()));
    expect(() => n.nachweis('../x', '<quiz/>', null), throwsA(isA<MoodleFehler>()));
  });

  test('Zu lange Angaben werden abgewiesen', () async {
    n.nachweis('multichoice', '<quiz/>', null);
    await expectLater(n.schreiben('multichoice', pflichtstruktur: 'a' * 20000, stolpersteine: 'b', ausbaustufen: 'c'), throwsA(isA<MoodleFehler>()));
  });
}
