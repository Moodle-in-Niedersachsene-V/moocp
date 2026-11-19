// Rundlaufprobe, Teil 1: Eingabe ⊆ Ausgabe (lib/moodle/fragen_vergleich.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/moodle/fragen_vergleich.dart';

String _quiz(String fragen) => '<?xml version="1.0" encoding="UTF-8"?><quiz>$fragen</quiz>';

const _eingabe = '''
<question type="multichoice">
  <name><text>ZZ Frage</text></name>
  <questiontext format="html"><text><![CDATA[<p>Was ist 1+1?</p>]]></text></questiontext>
  <defaultgrade>1</defaultgrade>
  <idnumber>zz-1</idnumber>
  <single>true</single>
  <answer fraction="100" format="html"><text>2</text></answer>
  <answer fraction="0" format="html"><text>3</text></answer>
</question>''';

// Moodle ergänzt Standardwerte, schreibt Zahlen anders und bricht Zeilen um.
const _ausgabe = '''
<!-- question: 55 -->
<question type="multichoice">
  <name><text>ZZ Frage</text></name>
  <questiontext format="html"><text><![CDATA[<p>Was   ist 1+1?</p>]]></text></questiontext>
  <generalfeedback format="html"><text></text></generalfeedback>
  <defaultgrade>1.0000000</defaultgrade>
  <penalty>0.3333333</penalty>
  <hidden>0</hidden>
  <idnumber>zz-1</idnumber>
  <single>true</single>
  <answer fraction="100.0000000" format="html"><text>2</text><feedback format="html"><text></text></feedback></answer>
  <answer fraction="0" format="html"><text>3</text></answer>
  <tags><tag><text>x</text></tag></tags>
</question>''';

void main() {
  test('Was Moodle ergänzt oder anders schreibt, ist kein Befund', () {
    expect(fragenVergleichen(_quiz(_eingabe), _quiz(_ausgabe)), isEmpty);
  });

  test('Eine fehlende Antwort wird mit Fundort benannt', () {
    final aus = _ausgabe.replaceFirst('<answer fraction="0" format="html"><text>3</text></answer>', '');
    final b = fragenVergleichen(_quiz(_eingabe), _quiz(aus));
    expect(b, hasLength(1));
    expect(b.single, contains('question/answer[2]'));
  });

  test('Ein abweichender Text nennt erwartet und gefunden', () {
    final aus = _ausgabe.replaceFirst('<text>2</text>', '<text>4</text>');
    final b = fragenVergleichen(_quiz(_eingabe), _quiz(aus));
    expect(b.join(' '), allOf(contains('erwartet „2"'), contains('im Export „4"')));
  });

  test('Eine abweichende Bewertung (Attribut) ist ein Befund', () {
    final aus = _ausgabe.replaceFirst('fraction="100.0000000"', 'fraction="50"');
    expect(fragenVergleichen(_quiz(_eingabe), _quiz(aus)).join(' '), contains('Attribut fraction'));
  });

  test('Eine Frage, die im Export fehlt, wird gemeldet', () {
    expect(fragenVergleichen(_quiz(_eingabe), _quiz('')).single, contains('fehlt im Export'));
  });

  test('Typnamen des Exports (matching/cloze) gelten als gleich', () {
    const e = '<question type="match"><name><text>M</text></name><subquestion format="html"><text>a</text><answer><text>b</text></answer></subquestion></question>';
    const a = '<question type="matching"><name><text>M</text></name><subquestion format="html"><text>a</text><answer><text>b</text></answer></subquestion></question>';
    expect(fragenVergleichen(_quiz(e), _quiz(a)), isEmpty);
  });

  test('Ein Unterelement tief im Baum (Lücke, Ablagebereich) fällt auf', () {
    const e = '<question type="ddwtos"><name><text>D</text></name><dragbox><text>Hund</text><group>1</group></dragbox></question>';
    const a = '<question type="ddwtos"><name><text>D</text></name><dragbox><text>Hund</text><group>2</group></dragbox></question>';
    expect(fragenVergleichen(_quiz(e), _quiz(a)).join(' '), contains('dragbox[1]/group[1]'));
  });
}
