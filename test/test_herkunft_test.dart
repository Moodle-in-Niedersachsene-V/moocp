// Woher die Fragen eines Tests kommen (#114): test_lesen sagt je Platz, ob die
// Frage in der eigenen Bank des Tests liegt oder in einer geteilten Bank, und
// ob diese Bank zum Kurs gehört. Das Abzeichen und der Link der Zufallsplätze
// werden nur gelesen, nie abgerufen (A1: /question/edit.php zeigt Namen).
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/moodle/kurs.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/moodle/test.dart';

import 'hilfen/fragenbank_doppel.dart';

String _seite(String plaetze, {int quizid = 77, int kurs = 12}) =>
    '''<html><body><script>M.cfg = {"courseId":$kurs,"sesskey":"x"};</script><script>var x = {"quizid":"$quizid"};</script>
<ul><li class="pagenumber" id="page-1">Seite 1</li>$plaetze</ul>
<p>Summe der Punkte: 2,00</p><input name="maxgrade" value="2,00"></body></html>''';

String _eigen(int slot, int frage, String name) =>
    '<li class="activity slot qtype_truefalse" id="slot-$slot"><span class="activityname">$name</span>'
    '<a href="/question/bank/editquestion/question.php?cmid=5002&id=$frage">bearbeiten</a>'
    '<span class="instancemaxmark">1,00</span></li>';

String _geteilt(int slot, int frage, String name, int bank, String bankName, {int version = 0}) =>
    '<li class="activity slot qtype_multichoice" id="slot-$slot"><span class="activityname">$name</span>'
    '<a href="/question/bank/editquestion/question.php?cmid=5002&id=$frage">bearbeiten</a>'
    '<div class="sharedbank"><a href="/question/edit.php?cmid=$bank&cat=7%2C99"><span class="badge bg-primary text-light ms-2 mt-1">$bankName</span></a></div>'
    '<select id="version-$slot" name="version" class="form-select version-selection"><option value="0"${version == 0 ? ' selected' : ''}>Always latest</option>'
    '<option value="2"${version == 2 ? ' selected' : ''}>v2</option></select>'
    '<span class="instancemaxmark">1,00</span></li>';

String _zufall(int slot, int bank) =>
    '<li class="activity slot qtype_random" id="slot-$slot"><span class="activityname">Zufallsfrage (Kat)</span>'
    '<a class="mod_quiz_random_qbank_link" href="/question/edit.php?cmid=$bank&filter=%7B%22category%22%3A1%7D">Kat</a>'
    '<span class="instancemaxmark">1,00</span></li>';

void main() {
  group('Auswerten der Seite', () {
    test('Abzeichen gibt cmid und Namen der geteilten Bank, Zufallslink die Bank des Platzes', () {
      final t = testAuswerten(5001, _seite(_eigen(1, 11, 'ZZ Eigen') + _geteilt(2, 12, 'ZZ Geteilt', 31, 'ZZ Bank') + _zufall(3, 31)));
      expect([for (final p in t.plaetze) '${p.slotid}:${p.bankCmid}:${p.bankName}:${p.zufallBankCmid}'],
          ['1:null:null:null', '2:31:ZZ Bank:null', '3:null:null:31']);
    });

    test('Eine gepinnte Version wird erkannt', () {
      final t = testAuswerten(5001, _seite(_geteilt(2, 12, 'ZZ Geteilt', 31, 'ZZ Bank', version: 2)));
      expect(t.plaetze.single.festeVersion, isTrue);
    });
  });

  group('Herkunftstext', () {
    test('alle Fragen in der eigenen Bank', () {
      final t = testAuswerten(5001, _seite(_eigen(1, 11, 'ZZ A') + _eigen(2, 12, 'ZZ B')));
      expect(t.herkunftText(), 'Alle Fragen liegen in der eigenen Bank des Tests.');
    });

    test('geteilte Bank im Kurs wird mit Namen genannt, fremde als Bank in einem anderen Kurs', () {
      final t = testAuswerten(5001, _seite(_geteilt(1, 11, 'ZZ A', 31, 'ZZ Bank') + _geteilt(2, 12, 'ZZ B', 40, 'ZZ Fremd') + _geteilt(3, 13, 'ZZ C', 40, 'ZZ Fremd')))
        ..kursBanken = {31: Fragensammlung(31, 'ZZ Bank', true)};
      final text = t.herkunftText();
      expect(text, contains('1 Platz verweist auf Bank „ZZ Bank" (cmid 31) in diesem Kurs'));
      expect(text, contains('2 Plätze verweisen auf Bank in einem anderen Kurs (cmid 40, „ZZ Fremd")'));
      expect(text, isNot(contains('Alle Fragen liegen')));
    });

    test('Zufallsplätze: eigene Bank des Tests oder Bank mit cmid', () {
      final t = testAuswerten(5001, _seite(_zufall(1, 5001) + _zufall(2, 31)))..kursBanken = {31: Fragensammlung(31, 'ZZ Bank', true)};
      final text = t.herkunftText();
      expect(text, contains('1 Zufallsplatz zieht aus der eigenen Bank des Tests'));
      expect(text, contains('1 Zufallsplatz zieht aus Bank „ZZ Bank" (cmid 31) in diesem Kurs'));
    });

    test('Kurs der Bank unbekannt, wenn die Bankliste fehlt', () {
      final t = testAuswerten(5001, _seite(_geteilt(1, 11, 'ZZ A', 31, 'ZZ Bank')));
      expect(t.herkunftText(), contains('Kurs der Bank nicht ermittelt'));
    });

    test('Vergleich mit dem Original: gleiche questionid, andere questionid, gepinnte Version', () {
      final quelle = testAuswerten(4001, _seite(_eigen(1, 11, 'ZZ A') + _eigen(2, 12, 'ZZ B') + _geteilt(3, 13, 'ZZ C', 31, 'ZZ Bank')));
      final kopie = testAuswerten(5001, _seite(_eigen(1, 21, 'ZZ A') + _eigen(2, 12, 'ZZ B') + _geteilt(3, 23, 'ZZ C', 31, 'ZZ Bank', version: 2)));
      final text = kopie.herkunftText(quelle: quelle);
      expect(text, contains('1 Platz zeigt auf dieselbe Frage wie im Original (cmid 4001)'));
      expect(text, contains('1 Platz hat eine eigene Frage'));
      expect(text, contains('1 Platz mit fester Version: nicht entscheidbar'));
    });

    test('Vergleich: alle Fragen eigene Kopien', () {
      final quelle = testAuswerten(4001, _seite(_eigen(1, 11, 'ZZ A')));
      final kopie = testAuswerten(5001, _seite(_eigen(1, 21, 'ZZ A')));
      expect(kopie.herkunftText(quelle: quelle), contains('Alle Fragen sind eigene Kopien'));
    });

    test('test_lesen-Text nennt die Herkunft je Platz und die Zusammenfassung', () {
      final t = testAuswerten(5001, _seite(_eigen(1, 11, 'ZZ A') + _geteilt(2, 12, 'ZZ B', 31, 'ZZ Bank')))..kursBanken = {};
      final text = t.text();
      expect(text, contains('Herkunft:'));
      expect(text, contains('Bank in einem anderen Kurs (cmid 31, „ZZ Bank")'));
    });
  });

  group('Lesen gegen das Moodle-Doppel', () {
    late FragenbankDoppel moodle;
    late MoodleZugang zugang;
    setUp(() async {
      moodle = FragenbankDoppel();
      await moodle.starten();
      zugang = await moodle.zugang();
    });
    tearDown(() => moodle.stoppen());

    test('liest die Bankliste des Kurses und ruft nie den Link des Abzeichens oder der Zufallsplätze ab', () async {
      moodle.kursBanken
        ..clear()
        ..[31] = 'ZZ Bank';
      moodle.quizSeiten[5001] = _seite(_geteilt(1, 11, 'ZZ A', 31, 'ZZ Bank') + _geteilt(2, 12, 'ZZ B', 40, 'ZZ Fremd') + _zufall(3, 40));
      final t = await testLesen(zugang, 5001, banken: true);
      expect(t.herkunftText(), allOf(contains('in diesem Kurs'), contains('in einem anderen Kurs (cmid 40')));
      expect(moodle.anfragen.where((a) => a.contains('/question/edit.php')), isEmpty);
      expect(moodle.anfragen.any((a) => a.contains('/question/banks.php?courseid=12')), isTrue);
    });

    test('ohne banken: keine Anfrage an die Bankliste', () async {
      moodle.quizSeiten[5001] = _seite(_eigen(1, 11, 'ZZ A'));
      final t = await testLesen(zugang, 5001);
      expect(t.kursBanken, isNull);
      expect(moodle.anfragen.where((a) => a.contains('banks.php')), isEmpty);
    });
  });
}
