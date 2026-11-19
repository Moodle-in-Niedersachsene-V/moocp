// Die Rundlaufprobe (E38) gegen ein Moodle-Doppel mit Fragensammlung
// (test/hilfen/fragenbank_doppel.dart). Geprüft wird, was von außen sichtbar
// ist: das Urteil der Probe und die Anfragen, die Moodle bekommen hat.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/moodle/rundlaufprobe.dart';
import 'package:moocp/moodle/formular_lesen.dart';
import 'package:moocp/moodle/schreibvorgang.dart';

import 'hilfen/fragenbank_doppel.dart';

String _quiz(String frage) => '<?xml version="1.0" encoding="UTF-8"?><quiz>$frage</quiz>';

void main() {
  late FragenbankDoppel moodle;
  late MoodleZugang zugang;
  late Directory ordner;
  late DoppelEintrag eintrag;
  late String eingabe;

  setUp(() async {
    moodle = FragenbankDoppel();
    await moodle.starten();
    zugang = await moodle.zugang();
    ordner = Directory.systemTemp.createTempSync('probe-');
    eintrag = moodle.legeAn('shortanswer', 'ZZ Probe 1', 'zz-1');
    eingabe = _quiz(eintrag.neueste.xml);
  });

  tearDown(() async {
    await moodle.stoppen();
    ordner.deleteSync(recursive: true);
  });

  Future<ProbeErgebnis> probe() => rundlaufProbe(zugang, ordner.path,
      sammlung: FragenbankDoppel.sammlung, frage: eintrag.neueste.id, eingabe: eingabe, angelegt: Angelegt());

  test('Alles in Ordnung: verified, und die Probeversion ist wieder weg', () async {
    final vorher = eintrag.neueste.id;
    final r = await probe();
    expect(r.befunde, isEmpty);
    expect(r.verified, isTrue);
    expect(eintrag.versionen.map((v) => v.id), [vorher], reason: 'keine Probeversion bleibt');
    expect(moodle.geloescht, hasLength(1), reason: 'genau eine Version gelöscht: die Probe');
    expect(moodle.geloescht.single, isNot(vorher));
  });

  test('Die Probeversion ist ein Entwurf', () async {
    await probe();
    expect(moodle.gespeichertMitStatus, ['draft']);
  });

  test('Eine Abweichung im Export besteht die Probe nicht, und es wird weder gespeichert noch gelöscht', () async {
    moodle.beimExport = (x) => x.replaceAll('<text>A</text></answer>', '<text>B</text></answer>');
    final r = await probe();
    expect(r.bestanden, isFalse);
    expect(r.befunde.join(' '), contains('erwartet „A"'));
    expect(moodle.geloescht, isEmpty);
    expect(moodle.anfragen.where((a) => a.startsWith('POST /question/bank/editquestion')), isEmpty);
  });

  test('Ein Bearbeitungsformular mit Fehlermeldung besteht nicht', () async {
    moodle.formularFehler = true;
    final r = await probe();
    expect(r.befunde.join(' '), contains('Bearbeitungsformular'));
    expect(moodle.geloescht, isEmpty);
  });

  test('Eine Vorschau mit Moodle-Fehler besteht nicht', () async {
    moodle.vorschauFehler = true;
    final r = await probe();
    expect(r.befunde.join(' '), contains('Vorschau'));
    expect(moodle.anfragen.where((a) => a.startsWith('POST /question/bank/editquestion')), isEmpty);
  });

  test('Ohne Entwurfsstatus wird nicht gespeichert: nicht geprüft, nicht verified, aber nicht durchgefallen', () async {
    moodle.statusFeld = false;
    final r = await probe();
    expect(r.bestanden, isTrue);
    expect(r.verified, isFalse);
    expect(r.nichtGeprueft.join(' '), contains('Entwurf'));
    expect(moodle.anfragen.where((a) => a.startsWith('POST /question/bank/editquestion')), isEmpty);
    expect(moodle.geloescht, isEmpty);
  });

  test('Lehnt Moodle das Speichern ab, besteht die Probe nicht', () async {
    moodle.entwurfAbgelehnt = true;
    final r = await probe();
    expect(r.befunde.join(' '), contains('Speichern'));
    expect(moodle.geloescht, isEmpty);
    expect(r.ausgangUnklar, isTrue);
    expect(Schreibvorgang(zugang, Formularziel.frage(FragenbankDoppel.sammlung, eintrag.neueste.id)).offen, isTrue);
  });

  test('Weicht die Probeversion vom Zielstand ab, bleibt die Sperre und es wird nicht weiter geschrieben', () async {
    moodle.beimEntwurf = (x) => x.replaceAll('<text>A</text></answer>', '<text>Z</text></answer>');
    final r = await probe();
    expect(r.befunde.join(' '), contains('Unverändert gespeichert'));
    expect(r.ausgangUnklar, isTrue);
    expect(moodle.geloescht, isEmpty);
    expect(eintrag.versionen, hasLength(2));
  });

  test('Fehlt die Nummer nach dem Speichern, sperrt ein neuer Aufruf weitere Änderungen', () async {
    final frage = eintrag.neueste.id;
    moodle.entwurfOhneNummer = true;
    final r = await probe();
    expect(r.verified, isFalse);
    expect(r.ausgangUnklar, isTrue);
    expect(moodle.geloescht, isEmpty);
    expect(Schreibvorgang(zugang, Formularziel.frage(FragenbankDoppel.sammlung, frage)).offen, isTrue);
    final zweiter = await rundlaufProbe(zugang, ordner.path,
        sammlung: FragenbankDoppel.sammlung, frage: frage, eingabe: eingabe, angelegt: Angelegt());
    expect(zweiter.text(), contains('Nicht erneut schreiben'));
    expect(moodle.gespeichertMitStatus, ['draft']);
  });

  test('Lässt sich die Probeversion nicht löschen, sagt die Antwort es', () async {
    moodle.loeschenWirktNicht = true;
    final r = await probe();
    expect(r.probeBleibt, isTrue);
    expect(r.verified, isFalse);
    expect(r.hinweise.join(' '), contains('liegt als Entwurf'));
  });

  test('Löscht Moodle mehr als die Probeversion, wird der Verlust gemeldet', () async {
    moodle.loeschtAlles = true;
    final r = await probe();
    expect(r.befunde.join(' '), contains('ACHTUNG'));
  });

  test('Nur was dieser Aufruf angelegt hat, ist löschbar', () async {
    await expectLater(
      loescheAngelegtes(zugang, ordner.path, FragenbankDoppel.sammlung, Angelegt(), eintrag.neueste.id, alleVersionen: true),
      throwsStateError,
    );
    expect(moodle.geloescht, isEmpty);
  });
}
