// kategorie_aendern (E9, E20, E37) gegen das Moodle-Doppel: Umbenennen über das
// Bearbeitungsformular, Verschieben über den Dienst der Verwaltungsoberfläche,
// Vorab-Prüfungen ohne Schreiben, Freigabe ab „mittel", Zurücklesen.
// Nur Moodle ist ersetzt; Prüfung, Freigabe, Vorgangsdatei und Rücklesen laufen echt.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/fragen_kategorie.dart';
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
    // Sammlung 12: Probe(1) > Unter(5) > Enkel(6); Ziel(2). Sammlung 13: Ziel zwei(3), Andere(7). Sammlung 14: nur Einzig(8).
    moodle.legeKategorieAn(2, 'ZZ Ziel');
    moodle.kursBanken[13] = 'ZZ Zweite Bank';
    moodle.kursBanken[14] = 'ZZ Dritte Bank';
    moodle.legeKategorieAn(3, 'ZZ Ziel zwei', bank: 13);
    moodle.legeKategorieAn(7, 'ZZ Andere', bank: 13);
    moodle.legeKategorieAn(8, 'ZZ Einzig', bank: 14);
    moodle.legeKategorieAn(5, 'ZZ Unter', eltern: 1);
    moodle.legeKategorieAn(6, 'ZZ Enkel', eltern: 5);
    moodle.legeAn('shortanswer', 'ZZ Frage Unter', 'zz-u', kategorie: 5);
    moodle.legeAn('shortanswer', 'ZZ Frage Enkel', 'zz-e', kategorie: 6);
    vorgaenge = Directory.systemTemp.createTempSync('kategorie-vorgaenge-');
    freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.mittel);
    zugang = await MoodleZugang.fuerTest(Protokoll(), moodle.basis,
        benutzer: FragenbankDoppel.benutzer, passwort: FragenbankDoppel.passwort, schreibvorgaengeOrdner: vorgaenge.path);
  });

  tearDown(() async {
    await moodle.stoppen();
    if (vorgaenge.existsSync()) vorgaenge.deleteSync(recursive: true);
  });

  Future<String> los({
    int kategorie = 5,
    String name = 'ZZ Unter',
    String? neuerName,
    int? zielSammlung,
    String? zielEltern,
    int sammlung = FragenbankDoppel.sammlung,
    int kurs = 5,
  }) =>
      kategorieAendern(zugang, freigaben,
          kurs: kurs,
          sammlung: sammlung,
          kategorie: kategorie,
          name: name,
          neuerName: neuerName,
          zielSammlung: zielSammlung,
          zielEltern: zielEltern);

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

  void nichtsGeschrieben() {
    expect(moodle.kategorieVerschiebeAufrufe, isEmpty);
    expect(moodle.kategorieFormulare, isEmpty);
    expect(freigaben.aktuell, isNull);
  }

  test('Umbenennen: Freigabe ab „mittel", Formular mit unveränderter Beschreibung, Sachnummer und Eltern, verified', () async {
    moodle.kategorieInfo[5] = '<p>Roh <b>bleibt</b></p>';
    moodle.kategorieIdnummer[5] = 'kat-5';
    final f = los(neuerName: 'ZZ Unter neu');
    final anfrage = await aufFreigabe();
    expect(anfrage.ab, Bestaetigungen.mittel);
    final text = anfrage.punkte.join('\n');
    expect(text, allOf(contains('ZZ Probe'), contains('ZZ Unter'), contains('ZZ Unter neu'), contains('ZZ Enkel'), contains('(1 Fragen)')));
    expect(moodle.kategorieFormulare, isEmpty, reason: 'vor der Freigabe wird nichts gespeichert');
    freigaben.entscheiden(true);
    final bericht = await f;

    expect(moodle.kategorieVerschiebeAufrufe, isEmpty, reason: 'reines Umbenennen braucht den Verschiebedienst nicht');
    final form = moodle.kategorieFormulare.single;
    expect(form['name'], 'ZZ Unter neu');
    expect(form['info[text]'], '<p>Roh <b>bleibt</b></p>');
    expect(form['idnumber'], 'kat-5');
    expect(form['parent'], '1,55');
    expect(moodle.kategorien[5], 'ZZ Unter neu');
    expect(bericht, contains('verified: true'));
    expect(bericht, contains('Nicht geprüft'));
  });

  test('Rendert Moodle die Beschreibung beim Speichern um, ist es nicht verified und sagt es', () async {
    moodle.infoRendert = true;
    moodle.kategorieInfo[5] = 'Text';
    final bericht = await freigegeben(los(neuerName: 'ZZ Unter neu'));
    expect(bericht, contains('verified: false'));
    expect(bericht, contains('Beschreibung'));
  });

  test('Nimmt Moodle den neuen Namen nicht an: nicht verified', () async {
    moodle.kategorieUmbenennenWirktNicht = true;
    final bericht = await freigegeben(los(neuerName: 'ZZ Unter neu'));
    expect(bericht, contains('verified: false'));
  });

  test('Verschieben in derselben Sammlung: ein Dienstaufruf mit genauen Schlüsseln, Teilbaum bleibt darunter', () async {
    final f = los(zielEltern: 'ZZ Ziel');
    final anfrage = await aufFreigabe();
    expect(anfrage.ab, Bestaetigungen.mittel);
    final text = anfrage.punkte.join('\n');
    expect(text, allOf(contains('ZZ Probe'), contains('ZZ Unter'), contains('ZZ Ziel'), contains('ZZ Enkel'), contains('(1 Fragen)')));
    expect(moodle.kategorieVerschiebeAufrufe, isEmpty);
    freigaben.entscheiden(true);
    final bericht = await f;

    expect(moodle.kategorieVerschiebeAufrufe.single, {
      'pagecontextid': 55,
      'categoryid': 5,
      'targetparentid': 2,
      'precedingsiblingid': null,
    });
    expect(moodle.kategorieFormulare, isEmpty, reason: 'ohne neuen Namen kein Formular-Speichern');
    expect(moodle.eltern[5], 2);
    expect(moodle.eltern[6], 5);
    expect(bericht, contains('verified: true'));
    expect(bericht, contains('Nicht geprüft'));
  });

  test('Auf die oberste Ebene einer anderen Sammlung: Top-Kategorie aus dem Exportformular', () async {
    final bericht = await freigegeben(los(zielSammlung: 13));
    expect(moodle.kategorieVerschiebeAufrufe.single['targetparentid'], FragenbankDoppel.topId(13));
    expect(moodle.kategorieVerschiebeAufrufe.single['pagecontextid'], 55);
    expect(moodle.eltern[5], isNull);
    expect(moodle.bankVon[5], 13);
    expect(moodle.bankVon[6], 13, reason: 'Unterkategorien ziehen mit');
    expect(moodle.eltern[6], 5);
    expect(bericht, contains('verified: true'));
  });

  test('Unter eine Kategorie einer anderen Sammlung', () async {
    final bericht = await freigegeben(los(zielSammlung: 13, zielEltern: 'ZZ Ziel zwei'));
    expect(moodle.kategorieVerschiebeAufrufe.single['targetparentid'], 3);
    expect(moodle.eltern[5], 3);
    expect(bericht, contains('verified: true'));
  });

  test('Auf die oberste Ebene derselben Sammlung', () async {
    final bericht = await freigegeben(los(zielSammlung: 12));
    expect(moodle.kategorieVerschiebeAufrufe.single['targetparentid'], FragenbankDoppel.topId(12));
    expect(moodle.eltern[5], isNull);
    expect(bericht, contains('verified: true'));
  });

  test('Verschieben und Umbenennen: erst verschieben, dann das Formular der neuen Sammlung', () async {
    final bericht = await freigegeben(los(neuerName: 'ZZ Neu', zielSammlung: 13, zielEltern: '3'));
    expect(moodle.kategorieVerschiebeAufrufe, hasLength(1));
    final form = moodle.kategorieFormulare.single;
    expect(form['name'], 'ZZ Neu');
    expect(form['cmid'], '13');
    expect(form['parent'], '3,73');
    expect(moodle.kategorien[5], 'ZZ Neu');
    expect(moodle.eltern[5], 3);
    expect(bericht, contains('verified: true'));
  });

  group('Abbruch vor der Freigabe, ohne etwas zu schreiben', () {
    Future<void> abbruch(Future<String> f, [Pattern? meldung]) async {
      await expectLater(f, throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'meldung', contains(meldung ?? ''))));
      nichtsGeschrieben();
    }

    test('Name passt nicht', () => abbruch(los(name: 'ZZ Falsch', neuerName: 'X')));
    test('Nichts zu ändern', () => abbruch(los(), 'Nichts'));
    test('Neuer Name gleich dem alten', () => abbruch(los(neuerName: 'ZZ Unter'), 'Nichts'));
    test('Sammlung nicht im Kurs', () => abbruch(los(sammlung: 99, neuerName: 'X'), 'Kurs'));
    test('Zielsammlung nicht im Kurs', () => abbruch(los(zielSammlung: 99), 'Kurs'));
    test('Top-Kategorie', () => abbruch(los(kategorie: FragenbankDoppel.topId(12), name: 'top', neuerName: 'X'), 'oberste'));
    test('Unbekannte Kategorie', () => abbruch(los(kategorie: 77, name: 'X', neuerName: 'Y')));

    test('Zyklus: unter einen Nachkommen', () => abbruch(los(kategorie: 1, name: 'ZZ Probe', zielEltern: '6'), 'sich selbst'));
    test('Zyklus: unter sich selbst', () => abbruch(los(zielEltern: '5'), 'sich selbst'));
    test('Schon dort', () => abbruch(los(zielEltern: '1'), 'schon'));
    test('Schon auf der obersten Ebene', () => abbruch(los(kategorie: 2, name: 'ZZ Ziel', zielSammlung: 12), 'schon'));

    test('Einziges Kind der Top-Kategorie lässt sich nicht verschieben', () async {
      await abbruch(
          kategorieAendern(zugang, freigaben,
              kurs: 5, sammlung: 14, kategorie: 8, name: 'ZZ Einzig', zielSammlung: 12, zielEltern: 'ZZ Ziel'),
          'einzige');
    });

    test('Das einzige Kind lässt sich umbenennen, das Formular hat dann kein Feld parent', () async {
      final bericht = await freigegeben(kategorieAendern(zugang, freigaben,
          kurs: 5, sammlung: 14, kategorie: 8, name: 'ZZ Einzig', neuerName: 'ZZ Einzig neu'));
      expect(moodle.kategorieFormulare.single.containsKey('parent'), isFalse);
      expect(moodle.kategorien[8], 'ZZ Einzig neu');
      expect(bericht, contains('verified: true'));
    });

    test('Gleicher Name unter dem Ziel', () async {
      moodle.legeKategorieAn(9, 'ZZ Unter', eltern: 2);
      await abbruch(los(zielEltern: 'ZZ Ziel'), 'ZZ Unter');
    });

    test('Umbenennen auf den Namen eines Geschwisters', () async {
      moodle.legeKategorieAn(9, 'ZZ Geschwister', eltern: 1);
      await abbruch(los(neuerName: 'ZZ Geschwister'), 'ZZ Geschwister');
    });

    test('Verschieben und Umbenennen: der neue Name kollidiert unter dem Ziel', () async {
      moodle.legeKategorieAn(9, 'ZZ Neu', eltern: 2);
      await abbruch(los(neuerName: 'ZZ Neu', zielEltern: 'ZZ Ziel'), 'ZZ Neu');
    });

    test('Zielkategorie unbekannt', () => abbruch(los(zielEltern: 'ZZ Gibt es nicht')));

    test('Sachnummer der Kategorie im Zielkontext schon vergeben', () async {
      moodle.kategorieIdnummer[5] = 'kat-x';
      moodle.kategorieIdnummer[7] = 'kat-x';
      await abbruch(los(zielSammlung: 13), 'kat-x');
    });

    test('Sachnummer einer Unterkategorie im Zielkontext schon vergeben', () async {
      moodle.kategorieIdnummer[6] = 'kat-y';
      moodle.kategorieIdnummer[3] = 'kat-y';
      await abbruch(los(zielSammlung: 13), 'kat-y');
    });

    test('Oberste Ebene der Zielsammlung nicht zu ermitteln', () async {
      moodle.exportOhneTop = true;
      await abbruch(los(zielSammlung: 13), 'oberste');
    });
  });

  test('Abgelehnt: nichts geschrieben', () async {
    final f = los(zielEltern: 'ZZ Ziel');
    await aufFreigabe();
    freigaben.entscheiden(false);
    expect(await f, contains('Nicht'));
    expect(moodle.kategorieVerschiebeAufrufe, isEmpty);
    expect(moodle.eltern[5], 1);
  });

  test('Auf der Stufe „keine" fragt die App nicht', () async {
    freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
    final bericht = await los(zielEltern: 'ZZ Ziel');
    expect(freigaben.aktuell, isNull);
    expect(moodle.kategorieVerschiebeAufrufe, hasLength(1));
    expect(bericht, contains('verified: true'));
  });

  test('Ändert sich der Baum, während die Freigabe offen ist, wird nichts geschrieben', () async {
    final f = los(zielEltern: 'ZZ Ziel');
    final erwartet = expectLater(f, throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'm', contains('Seit der Freigabe'))));
    await aufFreigabe();
    moodle.legeKategorieAn(9, 'ZZ Unter', eltern: 2);
    freigaben.entscheiden(true);
    await erwartet;
    expect(moodle.kategorieVerschiebeAufrufe, isEmpty);
  });

  test('Meldet Moodle Erfolg, die Kategorie bleibt aber: nicht verified, und der Vorgang sperrt (E37)', () async {
    moodle.kategorieVerschiebenWirktNicht = true;
    final bericht = await freigegeben(los(zielEltern: 'ZZ Ziel'));
    expect(bericht, contains('verified: false'));
    expect(bericht, contains('Vorgang'));
    moodle.kategorieVerschiebenWirktNicht = false;
    await expectLater(los(zielEltern: 'ZZ Ziel'), throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'm', contains('Nicht erneut'))));
    expect(moodle.kategorieVerschiebeAufrufe, hasLength(1));
  });

  test('Lehnt Moodle den Dienst ab: nicht verified', () async {
    moodle.kategorieVerschiebenAbgelehnt = true;
    final bericht = await freigegeben(los(zielEltern: 'ZZ Ziel'));
    expect(bericht, contains('verified: false'));
  });

  test('Positivliste: der Dienst nur mit genau diesen Schlüsseln und Zahlen', () {
    bool dienst(Map<String, Object?> args) => zugang.erlaubt(
        'POST',
        Uri.parse('${moodle.basis}/lib/ajax/service.php?sesskey=x&info=qbank_managecategories_move_category'),
        null,
        jsonEncode([
          {'index': 0, 'methodname': 'qbank_managecategories_move_category', 'args': args}
        ]));
    final ok = {'pagecontextid': 55, 'categoryid': 5, 'targetparentid': 2, 'precedingsiblingid': null};
    expect(dienst(ok), isTrue);
    expect(dienst({...ok, 'precedingsiblingid': 4}), isTrue);
    expect(dienst({...ok, 'extra': 1}), isFalse);
    expect(dienst({...ok}..remove('categoryid')), isFalse);
    expect(dienst({...ok, 'categoryid': '5'}), isFalse);
    expect(dienst({...ok, 'precedingsiblingid': 'x'}), isFalse);
  });
}
