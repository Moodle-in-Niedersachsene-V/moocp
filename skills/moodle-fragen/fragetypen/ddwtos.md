# Fragetyp-Notiz: ddwtos
Moodle-Version: 5.1 für das XML-Muster; bei der Rundlaufprobe nicht ermittelt
Probe bestanden am: 2026-11-19
Beweis: Das XML-Muster aus test/daten/fragen/kerntypen-test.xml besteht auf der Testinstanz die vollständige Rundlaufprobe: Export und Vergleich, Bearbeitungsformular, Vorschau, unverändert als Entwurf speichern und Probeversion entfernen. Auch der Import geänderten XMLs als neue Version besteht diese Probe. Eine Notiz dieser Instanz geht der mitgelieferten vor.

## Minimalbeispiel
```xml
<question type="ddwtos">
  <name><text>ZZTEST ddwtos</text></name>
  <questiontext format="html"><text><![CDATA[<p>Die Leistung berechnet sich aus [[1]] mal [[2]].</p>]]></text></questiontext>
  <generalfeedback format="html"><text></text></generalfeedback>
  <defaultgrade>2.0000000</defaultgrade>
  <penalty>0.3333333</penalty>
  <hidden>0</hidden>
  <shuffleanswers>0</shuffleanswers>
  <correctfeedback format="html"><text>Richtig.</text></correctfeedback>
  <partiallycorrectfeedback format="html"><text>Teilweise richtig.</text></partiallycorrectfeedback>
  <incorrectfeedback format="html"><text>Falsch.</text></incorrectfeedback>
  <shownumcorrect/>
  <dragbox><text>Spannung</text><group>1</group></dragbox>
  <dragbox><text>Strom</text><group>1</group></dragbox>
  <dragbox><text>Widerstand</text><group>1</group></dragbox>
</question>
```

## Pflichtstruktur
Fragetext mit Lücken `[[1]]`, `[[2]]` und für jede Lücke ein `<dragbox>` mit `<group>`; weitere Ziehelemente sind Ablenker.

## Stolpersteine (Symptom, Ursache, Abhilfe)
- Symptom: Ein Ziehelement lässt sich nur einmal verwenden. Ursache: Jedes Element wird verbraucht. Abhilfe: `<infinite/>` in der `<dragbox>`.
- Symptom: Lücken im Code zeigen Unsinn. Ursache: Lücken in `<code>`. Abhilfe: Lücken nie in `<code>` setzen (references/fragetypen.md, „Lücken im Code“).

## Ausbaustufen
Lücken in Tabellenzellen, unbegrenzte Ziehelemente, mehrere Gruppen.
