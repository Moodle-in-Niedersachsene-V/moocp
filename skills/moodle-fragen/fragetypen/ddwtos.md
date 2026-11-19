# Fragetyp-Notiz: ddwtos
Moodle-Version: 5.1 (Testinstanz)
Beweis: Import, Export und Vergleich sowie Vorschau auf der Testinstanz (Messung der Beispieldatei test/daten/fragen/kerntypen-test.xml). Die Rundlaufprobe mit Speichern des Formulars (E38) ist für diesen Typ noch nicht gelaufen; eine Notiz dieser Instanz, die nach bestandener Probe entsteht, geht dieser vor.

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
