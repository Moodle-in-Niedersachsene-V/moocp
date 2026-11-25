// fragen_verschieben (E9, E20, E37) gegen das Moodle-Doppel mit zwei
// Fragensammlungen: Vorab-Prüfungen ohne Schreiben, Freigabe ab „mittel", ein
// Dienstaufruf je Frage mit genau einer questionid, Zurücklesen je Frage.
// Nur Moodle ist ersetzt; Prüfung, Freigabe, Vorgangsdatei und Rücklesen laufen echt.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/fragen_verschieben.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/protokoll.dart';

import 'hilfen/fragenbank_doppel.dart';

void main() {
  late FragenbankDoppel moodle;
  late MoodleZugang zugang;
  late Directory vorgaenge;
  late Freigaben freigaben;

  setUp(() async {
    moodle = FragenbankDoppel();
    await moodle.starten();
    moodle.legeKategorieAn(2, 'ZZ Ziel'); // gleiche Sammlung
    moodle.kursBanken[13] = 'ZZ Zweite Bank';
    moodle.legeKategorieAn(3, 'ZZ Ziel zwei', bank: 13);
    vorgaenge = Directory.systemTemp.createTempSync('verschieben-vorgaenge-');
    freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.mittel);
    zugang = await MoodleZugang.fuerTest(Protokoll(), moodle.basis,
        benutzer: FragenbankDoppel.benutzer, passwort: FragenbankDoppel.passwort, schreibvorgaengeOrdner: vorgaenge.path);
  });

  tearDown(() async {
    await moodle.stoppen();
    if (vorgaenge.existsSync()) vorgaenge.deleteSync(recursive: true);
  });

  Future<String> los(List<DoppelEintrag> fragen,
          {int ziel = FragenbankDoppel.sammlung,
          String kategorie = 'ZZ Ziel',
          int kurs = 5,
          Map<int, String> namen = const {}}) =>
      fragenVerschieben(zugang, freigaben,
          kurs: kurs,
          sammlung: FragenbankDoppel.sammlung,
          fragen: [for (final e in fragen) (e.neueste.id, namen[e.neueste.id] ?? e.neueste.name)],
          zielSammlung: ziel,
          zielKategorie: kategorie);

  Future<FreigabeAnfrage> aufFreigabe() async {
    for (var i = 0; i < 400 && freigaben.aktuell == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return freigaben.aktuell!;
  }

  Future<String> freigegeben(Future<String> f) async {
    await aufFreigabe();
    freigaben.entscheiden(true);
    return f;
  }

  int dienstAnfragen() => moodle.anfragen.where((a) => a.startsWith('POST /lib/ajax/service.php')).length;

  test('Gleiche Sammlung: Freigabe ab „mittel", ein Aufruf mit einer questionid, verified mit „nicht geprüft"', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    moodle.neueVersion(a);
    final f = los([a]);
    final anfrage = await aufFreigabe();
    expect(anfrage.ab, Bestaetigungen.mittel);
    expect(anfrage.punkte.join(' '), allOf(contains('ZZ Probe'), contains('ZZ Ziel'), contains('ZZ Eins')));
    expect(dienstAnfragen(), 0, reason: 'bis zur Freigabe wird nichts verschoben');
    freigaben.entscheiden(true);
    final bericht = await f;

    expect(moodle.verschiebeAufrufe, hasLength(1));
    final aufruf = moodle.verschiebeAufrufe.single;
    expect(aufruf['questionids'], '${a.neueste.id}');
    expect(aufruf['newcategoryid'], 2);
    expect(aufruf['newcontextid'], 55);
    expect(aufruf['returnurl'], '/question/edit.php?cmid=12');
    expect(a.kategorie, 2);
    expect(a.versionen, hasLength(2), reason: 'alle Versionen ziehen mit');
    expect(bericht, contains('verified: true'));
    expect(bericht, contains('Nicht geprüft'));
    expect(bericht, contains('ZZ Eins'));
  });

  test('Mehrere Fragen: je Frage ein eigener Aufruf mit genau einer questionid', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final b = moodle.legeAn('shortanswer', 'ZZ Zwei', 'zz-2');
    final bericht = await freigegeben(los([a, b]));
    expect([for (final x in moodle.verschiebeAufrufe) x['questionids']], ['${a.neueste.id}', '${b.neueste.id}']);
    expect(bericht, contains('verified: true'));
    expect([a.kategorie, b.kategorie], [2, 2]);
  });

  test('Andere Sammlung desselben Kurses: Kontext der Zielsammlung', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final bericht = await freigegeben(los([a], ziel: 13, kategorie: 'ZZ Ziel zwei'));
    expect(moodle.verschiebeAufrufe.single['newcontextid'], 73);
    expect(moodle.verschiebeAufrufe.single['returnurl'], '/question/edit.php?cmid=13');
    expect(a.kategorie, 3);
    expect(bericht, contains('verified: true'));
  });

  test('Zielsammlung nicht im Kurs: Abbruch ohne Dialog und ohne Dienstaufruf', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    await expectLater(los([a], ziel: 99), throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'm', contains('Kurs'))));
    expect(freigaben.aktuell, isNull);
    expect(dienstAnfragen(), 0);
  });

  test('Ein Name, der nicht passt, bricht ab, bevor etwas geschieht', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    await expectLater(los([a], namen: {a.neueste.id: 'ZZ Falsch'}), throwsA(isA<MoodleFehler>()));
    expect(freigaben.aktuell, isNull);
    expect(dienstAnfragen(), 0);
  });

  test('Frage nicht in der Quellsammlung: Abbruch', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    await expectLater(
      fragenVerschieben(zugang, freigaben,
          kurs: 5, sammlung: 12, fragen: [(a.neueste.id + 500, 'ZZ Eins')], zielSammlung: 12, zielKategorie: 'ZZ Ziel'),
      throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'm', contains('nicht'))),
    );
    expect(dienstAnfragen(), 0);
  });

  test('Quelle gleich Ziel: Abbruch', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    await expectLater(los([a], kategorie: 'ZZ Probe'), throwsA(isA<MoodleFehler>()));
    expect(freigaben.aktuell, isNull);
    expect(dienstAnfragen(), 0);
  });

  test('Sachnummer im Ziel schon vergeben: Abbruch vor der Freigabe, nennt die andere Frage', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final andere = moodle.legeAn('shortanswer', 'ZZ Schon da', 'zz-1', kategorie: 2);
    await expectLater(
      los([a]),
      throwsA(isA<MoodleFehler>().having(
          (x) => x.meldung, 'm', allOf(contains('zz-1'), contains('ZZ Schon da'), contains('${andere.neueste.id}')))),
    );
    expect(freigaben.aktuell, isNull);
    expect(dienstAnfragen(), 0);
    expect(a.kategorie, 1);
  });

  test('Zwei zu verschiebende Fragen mit derselben Sachnummer: Abbruch', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    moodle.legeKategorieAn(4, 'ZZ Quelle zwei');
    final b = moodle.legeAn('shortanswer', 'ZZ Zwei', 'zz-1', kategorie: 4);
    await expectLater(los([a, b]), throwsA(isA<MoodleFehler>()));
    expect(dienstAnfragen(), 0);
  });

  test('Abgelehnt: nichts verschoben', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final f = los([a]);
    await aufFreigabe();
    freigaben.entscheiden(false);
    expect(await f, contains('Nicht verschoben'));
    expect(dienstAnfragen(), 0);
    expect(a.kategorie, 1);
  });

  test('Auf der Stufe „keine" fragt die App nicht, die Antwort sagt es nicht selbst, verschoben wird trotzdem', () async {
    freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final bericht = await los([a]);
    expect(freigaben.aktuell, isNull);
    expect(dienstAnfragen(), 1);
    expect(bericht, contains('verified: true'));
  });

  test('Ändert sich das Ziel, während die Freigabe offen ist, wird nichts verschoben', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final f = los([a]);
    final erwartet = expectLater(f, throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'm', contains('Seit der Freigabe'))));
    await aufFreigabe();
    moodle.legeAn('shortanswer', 'ZZ Neu im Ziel', 'zz-1', kategorie: 2);
    freigaben.entscheiden(true);
    await erwartet;
    expect(dienstAnfragen(), 0);
  });

  test('Hängt Moodle der Sachnummer einen Suffix an, ist es nicht verified', () async {
    moodle.kollisionMitSuffix = true;
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    // Taucht erst nach der Prüfung auf, etwa als verborgene Frage, die kein Export zeigt.
    moodle.beiVerschieben = () => moodle.legeAn('shortanswer', 'ZZ Unsichtbar', 'zz-1', kategorie: 2);
    final bericht = await freigegeben(los([a]));
    expect(bericht, contains('verified: false'));
    expect(bericht, contains('zz-1_1'));
  });

  test('Meldet Moodle Erfolg, die Frage liegt aber noch in der Quelle: nicht verified', () async {
    moodle.verschiebenWirktNicht = true;
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final bericht = await freigegeben(los([a]));
    expect(bericht, contains('verified: false'));
    expect(bericht, contains('noch in der Quelle'));
  });

  test('Lehnt Moodle ab, bleibt der Vorgang offen: keine zweite Schreibung an dieser Frage (E37)', () async {
    moodle.verschiebenAbgelehnt = true;
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final bericht = await freigegeben(los([a]));
    expect(bericht, contains('verified: false'));
    expect(bericht, contains('Vorgang'));
    moodle.verschiebenAbgelehnt = false;
    await expectLater(los([a]), throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'm', contains('Nicht erneut'))));
    expect(freigaben.aktuell, isNull, reason: 'die Sperre gilt schon vor der Freigabe');
    expect(moodle.verschiebeAufrufe, hasLength(1));
  });

  test('Schutzdienst bei Frage 2 von 3: Frage 1 ist als verschoben gemeldet, Frage 3 unberührt, die Schleife hält an', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final b = moodle.legeAn('shortanswer', 'ZZ Zwei', 'zz-2');
    final c = moodle.legeAn('shortanswer', 'ZZ Drei', 'zz-3');
    moodle.verschiebeVerhalten = (n) => n == 2 ? 'schutz' : null;
    final bericht = await freigegeben(los([a, b, c]));
    expect(bericht, contains('verified: false'));
    expect(bericht, contains('verschoben: „ZZ Eins"'));
    expect(bericht, contains('UNKLAR: „ZZ Zwei"'));
    expect(bericht, contains('Angehalten: 1 weitere'));
    expect(moodle.verschiebeAufrufe, hasLength(2), reason: 'Frage 3 wird nicht angefasst');
    expect(a.kategorie, 2);
    expect(c.kategorie, 1);
  });

  test('Moodle meldet Fehler, die Frage steht aber im Ziel: verschoben, Vorgang geschlossen (E37)', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    moodle.verschiebeVerhalten = (n) => 'wirkung-dann-fehler';
    final bericht = await freigegeben(los([a]));
    expect(bericht, contains('verified: true'));
    expect(bericht, contains('obwohl Moodle einen Fehler meldete'));
    moodle.verschiebeVerhalten = null;
    // Der Vorgang ist zu: Die Frage lässt sich wieder zurückverschieben.
    moodle.legeKategorieAn(4, 'ZZ Zurück');
    final f = los([a], kategorie: 'ZZ Zurück');
    await aufFreigabe();
    freigaben.entscheiden(true);
    expect(await f, contains('verified: true'));
  });

  test('Ein Fehler bei Frage 1 von 2 hält die Schleife an', () async {
    final a = moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    final b = moodle.legeAn('shortanswer', 'ZZ Zwei', 'zz-2');
    moodle.verschiebenAbgelehnt = true;
    final bericht = await freigegeben(los([a, b]));
    expect(bericht, contains('Angehalten: 1 weitere'));
    expect(moodle.verschiebeAufrufe, hasLength(1));
  });

  test('Positivliste: der Dienst nur mit einer questionid und der lokalen returnurl', () {
    bool dienst(Map<String, Object?> args) => zugang.erlaubt(
        'POST',
        Uri.parse('${moodle.basis}/lib/ajax/service.php?sesskey=x&info=core_question_move_questions'),
        null,
        jsonEncode([
          {'index': 0, 'methodname': 'core_question_move_questions', 'args': args}
        ]));
    final ok = {
      'newcontextid': 55,
      'newcategoryid': 2,
      'questionids': '101',
      'returnurl': '/question/edit.php?cmid=12',
    };
    expect(dienst(ok), isTrue);
    expect(dienst({...ok, 'questionids': '101,102'}), isFalse, reason: 'eine Frage je Aufruf');
    expect(dienst({...ok, 'returnurl': 'https://fremd.example/'}), isFalse);
    expect(dienst({...ok, 'returnurl': '/question/edit.php?cmid=12&x=1'}), isFalse);
    expect(dienst({...ok, 'extra': 1}), isFalse);
    expect(dienst({...ok}..remove('returnurl')), isFalse, reason: 'ohne returnurl bricht Moodle mit einem Fehler ab');
  });
}
