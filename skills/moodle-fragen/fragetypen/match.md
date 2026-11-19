# Fragetyp-Notiz: match
Moodle-Version: 5.1 (Testinstanz)
Beweis: Import, Export und Vergleich sowie Vorschau auf der Testinstanz (Messung der Beispieldatei test/daten/fragen/kerntypen-test.xml). Die Rundlaufprobe mit Speichern des Formulars (E38) ist für diesen Typ noch nicht gelaufen; eine Notiz dieser Instanz, die nach bestandener Probe entsteht, geht dieser vor.

## Minimalbeispiel
```xml
<question type="match">
  <name><text>ZZTEST match</text></name>
  <questiontext format="html"><text><![CDATA[<p>Ordnen Sie Groesse und Einheit zu.</p>]]></text></questiontext>
  <generalfeedback format="html"><text></text></generalfeedback>
  <defaultgrade>3.0000000</defaultgrade>
  <penalty>0.3333333</penalty>
  <hidden>0</hidden>
  <shuffleanswers>true</shuffleanswers>
  <correctfeedback format="html"><text>Richtig.</text></correctfeedback>
  <partiallycorrectfeedback format="html"><text>Teilweise richtig.</text></partiallycorrectfeedback>
  <incorrectfeedback format="html"><text>Falsch.</text></incorrectfeedback>
  <shownumcorrect/>
  <subquestion format="html"><text><![CDATA[<p>Spannung</p>]]></text><answer><text>Volt</text></answer></subquestion>
  <subquestion format="html"><text><![CDATA[<p>Stromstaerke</p>]]></text><answer><text>Ampere</text></answer></subquestion>
  <subquestion format="html"><text><![CDATA[<p>Widerstand</p>]]></text><answer><text>Ohm</text></answer></subquestion>
  <subquestion format="html"><text></text><answer><text>Watt</text></answer></subquestion>
</question>
```

## Pflichtstruktur
Mindestens zwei vollständige Paare (Frage und Antwort) und insgesamt drei Antworten; im Export heißt der Typ `matching`.

## Stolpersteine (Symptom, Ursache, Abhilfe)
- Symptom: Der Import lehnt die Frage ab. Ursache: weniger als zwei vollständige Paare oder weniger als drei Antworten. Abhilfe: ein weiteres Paar oder ein `<subquestion>` mit leerem `<text>` und nur einer Antwort als Ablenker.

## Ausbaustufen
Zusätzliche Ablenker über Teilfragen mit leerem Text.
