# Fragetyp-Notiz: multichoice
Moodle-Version: 5.1 für das XML-Muster; bei der Rundlaufprobe nicht ermittelt
Probe bestanden am: 2026-11-19
Beweis: Das XML-Muster aus test/daten/fragen/kerntypen-test.xml besteht auf der Testinstanz die vollständige Rundlaufprobe: Export und Vergleich, Bearbeitungsformular, Vorschau, unverändert als Entwurf speichern und Probeversion entfernen. Auch der Import geänderten XMLs als neue Version besteht diese Probe. Eine Notiz dieser Instanz geht der mitgelieferten vor.

## Minimalbeispiel
```xml
<question type="multichoice">
  <name><text>ZZTEST multichoice</text></name>
  <questiontext format="html"><text><![CDATA[<p>Welche Spannung hat das oeffentliche Niederspannungsnetz zwischen Aussenleiter und Neutralleiter?</p>]]></text></questiontext>
  <generalfeedback format="html"><text><![CDATA[<p>230 V ist der Effektivwert.</p>]]></text></generalfeedback>
  <defaultgrade>2.0000000</defaultgrade>
  <penalty>0.3333333</penalty>
  <hidden>0</hidden>
  <idnumber></idnumber>
  <single>true</single>
  <shuffleanswers>true</shuffleanswers>
  <answernumbering>abc</answernumbering>
  <showstandardinstruction>0</showstandardinstruction>
  <correctfeedback format="html"><text>Richtig.</text></correctfeedback>
  <partiallycorrectfeedback format="html"><text>Teilweise richtig.</text></partiallycorrectfeedback>
  <incorrectfeedback format="html"><text>Leider falsch.</text></incorrectfeedback>
  <shownumcorrect/>
  <answer fraction="100" format="html"><text><![CDATA[<p>230 V</p>]]></text><feedback format="html"><text>Richtig.</text></feedback></answer>
  <answer fraction="0" format="html"><text><![CDATA[<p>400 V</p>]]></text><feedback format="html"><text>Das ist die Aussenleiterspannung.</text></feedback></answer>
  <answer fraction="0" format="html"><text><![CDATA[<p>24 V</p>]]></text><feedback format="html"><text>Das ist Schutzkleinspannung.</text></feedback></answer>
</question>
```

## Pflichtstruktur
Name, Fragetext, `single`, mindestens zwei Antworten mit `fraction`. Bei `single` true genau eine richtige Antwort (100); bei false summieren sich die positiven Anteile auf 100.

## Stolpersteine (Symptom, Ursache, Abhilfe)
- Symptom: Moodle bewertet Ankreuzen aller Optionen als gut. Ursache: Bei `single` false fehlen negative Anteile für falsche Antworten. Abhilfe: falsche Antworten mit negativem `fraction`.
- Symptom: Der Import meldet Fehler bei den Anteilen. Ursache: `matchgrades` steht auf `error`, ein Anteil passt nicht zu einem Moodle-Wert. Abhilfe: Anteile aus der Liste der Moodle-Bewertungsstufen wählen (100, 50, 33.33333, 25, 20 …).

## Ausbaustufen
Rückmeldungen je Antwort, `answernumbering`, mehrere richtige Antworten (`single` false).
