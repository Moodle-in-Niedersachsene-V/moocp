# Fragetyp-Notiz: gapselect
Moodle-Version: 5.1 für das XML-Muster; bei der Rundlaufprobe nicht ermittelt
Probe bestanden am: 2026-11-19
Beweis: Das XML-Muster aus test/daten/fragen/kerntypen-test.xml besteht auf der Testinstanz die vollständige Rundlaufprobe: Export und Vergleich, Bearbeitungsformular, Vorschau, unverändert als Entwurf speichern und Probeversion entfernen. Auch der Import geänderten XMLs als neue Version besteht diese Probe. Eine Notiz dieser Instanz geht der mitgelieferten vor.

## Minimalbeispiel
```xml
<question type="gapselect">
  <name><text>ZZTEST gapselect</text></name>
  <questiontext format="html"><text><![CDATA[<p>Der [[1]] begrenzt den Strom, der [[2]] schützt vor Fehlerstroemen.</p>]]></text></questiontext>
  <generalfeedback format="html"><text></text></generalfeedback>
  <defaultgrade>2.0000000</defaultgrade>
  <penalty>0.3333333</penalty>
  <hidden>0</hidden>
  <shuffleanswers>0</shuffleanswers>
  <correctfeedback format="html"><text>Richtig.</text></correctfeedback>
  <partiallycorrectfeedback format="html"><text>Teilweise richtig.</text></partiallycorrectfeedback>
  <incorrectfeedback format="html"><text>Falsch.</text></incorrectfeedback>
  <shownumcorrect/>
  <selectoption><text>Leitungsschutzschalter</text><group>1</group></selectoption>
  <selectoption><text>FI-Schalter</text><group>1</group></selectoption>
  <selectoption><text>Trenntrafo</text><group>1</group></selectoption>
</question>
```

## Pflichtstruktur
Fragetext mit Lücken `[[1]]`, `[[2]]`; die `<selectoption>`-Elemente liefern in ihrer Reihenfolge die richtigen Antworten, weitere sind Ablenker; `<group>` fasst austauschbare Optionen zusammen.

## Stolpersteine (Symptom, Ursache, Abhilfe)
- Symptom: Die Zuordnung der Lücken stimmt nicht. Ursache: Die Reihenfolge der `<selectoption>` bestimmt, welche Option zu welcher Lücke gehört. Abhilfe: Reihenfolge prüfen, richtige Antworten zuerst.

## Ausbaustufen
Mehrere Gruppen mit getrennten Optionsvorräten.
