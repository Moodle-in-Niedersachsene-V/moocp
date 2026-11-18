// Einrückung (indent) einer Aktivität setzen: je Aufruf eine Stufe mit cm_moveright/cm_moveleft, danach
// frisch zurücklesen. Moodle ist hier ein Doppel; ob die echte Instanz die Aktionen so kennt, ist ungemessen.
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/formular_schreiben.dart';
import 'package:moocp/moodle/kurs_aendern.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/protokoll.dart';

class _Kurs extends MoodleZugang {
  _Kurs() : super(Protokoll());

  final Map<int, int> einzug = {11: 0, 12: 2};
  final Map<int, String> namen = {11: 'ZZ Aufgabe', 12: 'ZZ Chatbot'};
  final aktionen = <String>[];

  /// Moodle ändert die Einrückung nicht (Kursformat kennt sie nicht) -- die Aktion „gelingt" folgenlos.
  var ignoriert = false;

  /// Unbekannte Aktion: Moodle antwortet mit dem Fehler der Kursformate.
  var unbekannt = false;

  /// Höchste Stufe, die Moodle annimmt.
  var grenze = 16;

  @override
  Future<Object?> dienst(String name, Map<String, Object?> args) async {
    switch (name) {
      case 'core_course_get_enrolled_courses_by_timeline_classification':
        return {'courses': <Object?>[]};
      case 'core_courseformat_get_state':
        return {
          'cm': [
            for (final e in einzug.entries)
              {
                'id': e.key,
                'module': 'page',
                'name': namen[e.key],
                'visible': 1,
                'indent': e.value,
                'sectionid': 1,
              },
          ],
          'section': [
            {'id': 1, 'number': 1, 'title': 'ZZ Abschnitt', 'visible': true, 'cmlist': einzug.keys.toList()},
          ],
        };
      case 'core_courseformat_update_course':
        final aktion = args['action'] as String;
        final ids = (args['ids'] as List).cast<int>();
        aktionen.add('$aktion ${ids.join(',')}');
        if (unbekannt && aktion.startsWith('cm_move') && aktion != 'cm_move') {
          throw MoodleFehler('Invalid course state action $aktion');
        }
        switch (aktion) {
          case 'cm_moveright':
            if (!ignoriert) einzug[ids.single] = (einzug[ids.single]! + 1).clamp(0, grenze);
          case 'cm_moveleft':
            if (!ignoriert) einzug[ids.single] = (einzug[ids.single]! - 1).clamp(0, grenze);
          case 'cm_move':
            break;
          default:
            throw StateError('Unerwartete Aktion $aktion');
        }
        return <String, Object?>{};
    }
    throw StateError('Unerwarteter Dienst $name');
  }
}

void main() {
  late _Kurs moodle;
  late Freigaben freigaben;
  late List<FreigabeAnfrage> gefragt;
  var antwort = true;

  setUp(() {
    moodle = _Kurs();
    freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.mittel);
    gefragt = [];
    antwort = true;
    freigaben.addListener(() {
      final a = freigaben.aktuell;
      if (a == null) return;
      gefragt.add(a);
      Future.microtask(() => freigaben.entscheiden(antwort));
    });
  });

  Future<String> rueck(int cmid, int? e, {int? ziel, int? vor}) => verschieben(moodle, freigaben,
      kurs: 5, cmid: cmid, name: moodle.namen[cmid]!, einrueckung: e, zielAbschnittId: ziel, vorCmid: vor);

  test('einrücken: Stufe für Stufe cm_moveright, nur die Einrückung, kein cm_move; Freigabe nennt sie', () async {
    final text = await rueck(11, 2);
    expect(moodle.aktionen, ['cm_moveright 11', 'cm_moveright 11']);
    expect(moodle.einzug[11], 2);
    expect(text, contains('verified: true'));
    expect(gefragt.single.punkte.join('\n'), contains('Einrückung von 0 auf 2'));
  });

  test('ausrücken: cm_moveleft, so oft wie Stufen fehlen', () async {
    final text = await rueck(12, 0);
    expect(moodle.aktionen, ['cm_moveleft 12', 'cm_moveleft 12']);
    expect(moodle.einzug[12], 0);
    expect(text, contains('verified: true'));
  });

  test('Verschieben mit neuem Ort und Einrückung: cm_move, dann Einrückung', () async {
    final text = await rueck(11, 1, ziel: 1);
    expect(moodle.aktionen, ['cm_move 11', 'cm_moveright 11']);
    expect(gefragt, hasLength(1));
    expect(text, contains('Einrückung von 0 auf 1 gesetzt. verified: true'));
  });

  test('schon auf der gewünschten Stufe: keine Freigabe, nichts geschrieben', () async {
    final text = await rueck(12, 2);
    expect(gefragt, isEmpty);
    expect(moodle.aktionen, isEmpty);
    expect(text, contains('nichts geändert'));
  });

  test('größer als 16 und kleiner als 0 brechen vor der Freigabe ab', () async {
    for (final e in [17, -1]) {
      await expectLater(rueck(11, e),
          throwsA(isA<MoodleFehler>().having((x) => x.meldung, 'meldung', contains('0 und 16'))));
    }
    expect(gefragt, isEmpty);
    expect(moodle.aktionen, isEmpty);
  });

  test('Grenze 16 wird erreicht', () async {
    final text = await rueck(11, 16);
    expect(moodle.aktionen, hasLength(16));
    expect(moodle.einzug[11], 16);
    expect(text, contains('verified: true'));
  });

  test('Moodle ändert nichts: verified false, nicht wiederholt', () async {
    moodle.ignoriert = true;
    final text = await rueck(11, 3);
    expect(text, contains('verified: false'));
    expect(text, contains('Nicht wiederholt'));
    expect(moodle.aktionen, hasLength(3), reason: 'je Stufe ein Aufruf, kein zweiter Anlauf');
  });

  test('Moodle nimmt nur bis zu einer Grenze an: verified false mit gelesenem Stand', () async {
    moodle.grenze = 2;
    final text = await rueck(11, 4);
    expect(text, contains('jetzt 2'));
    expect(text, contains('verified: false'));
  });

  test('Kursformat kennt die Aktion nicht: klare Meldung, verified false', () async {
    moodle.unbekannt = true;
    final text = await rueck(11, 1);
    expect(text, contains('Das Kursformat dieses Kurses kennt die Aktion cm_moveright nicht'));
    expect(text, contains('verified: false'));
  });

  test('Freigabe abgelehnt: nichts geschrieben', () async {
    antwort = false;
    final text = await rueck(11, 2);
    expect(text, startsWith('Nicht verschoben'));
    expect(moodle.aktionen, isEmpty);
    expect(moodle.einzug[11], 0);
  });

  test('ohne Ort und ohne Einrückung bleibt es bei der Fehlermeldung', () async {
    await expectLater(rueck(11, null), throwsA(isA<MoodleFehler>()));
    expect(gefragt, isEmpty);
  });

  test('für einen Abschnitt gilt einrueckung nicht', () async {
    await expectLater(
        verschieben(moodle, freigaben, kurs: 5, abschnittId: 1, name: 'ZZ Abschnitt', nachAbschnittId: 1, einrueckung: 1),
        throwsA(isA<MoodleFehler>()));
    expect(moodle.aktionen, isEmpty);
  });

  test('Anlegen: Einrückung außerhalb 0-16 bricht ab, bevor etwas gelesen oder gefragt wird', () async {
    for (final e in [17, -1]) {
      await expectLater(
          aktivitaetAnlegen(moodle, freigaben,
              kurs: 5, abschnittId: 1, typ: 'page', name: 'ZZ Neu', arbeitsordner: '.', einrueckung: e),
          throwsA(isA<MoodleFehler>()));
    }
    expect(gefragt, isEmpty);
    expect(moodle.aktionen, isEmpty);
  });

  test('die Positivliste kennt die beiden Aktionen', () {
    for (final a in ['cm_moveright', 'cm_moveleft']) {
      expect(MoodleZugang.kursAktionen, contains(a));
    }
  });
}
