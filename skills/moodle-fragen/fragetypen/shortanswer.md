# Fragetyp-Notiz: shortanswer
Moodle-Version: 5.1 (Testinstanz)
Beweis: Import, Export und Vergleich sowie Vorschau auf der Testinstanz (Messung der Beispieldatei test/daten/fragen/kerntypen-test.xml). Die Rundlaufprobe mit Speichern des Formulars (E38) ist für diesen Typ noch nicht gelaufen; eine Notiz dieser Instanz, die nach bestandener Probe entsteht, geht dieser vor.

## Minimalbeispiel
```xml
<question type="shortanswer">
  <name><text>ZZTEST shortanswer</text></name>
  <questiontext format="html"><text><![CDATA[<p>Welche Einheit hat der elektrische Widerstand? (Zeichen)</p>]]></text></questiontext>
  <generalfeedback format="html"><text></text></generalfeedback>
  <defaultgrade>1.0000000</defaultgrade>
  <penalty>0.3333333</penalty>
  <hidden>0</hidden>
  <usecase>0</usecase>
  <answer fraction="100" format="moodle_auto_format"><text>Ohm</text><feedback format="html"><text>Richtig.</text></feedback></answer>
  <answer fraction="100" format="moodle_auto_format"><text>Ω</text><feedback format="html"><text>Richtig.</text></feedback></answer>
</question>
```

## Pflichtstruktur
Mindestens eine Antwort mit `fraction` 100; weitere Schreibweisen als eigene Antworten. `usecase` steuert die Groß- und Kleinschreibung.

## Stolpersteine (Symptom, Ursache, Abhilfe)
- Symptom: Richtige Eingaben gelten als falsch. Ursache: Die Antwortliste ist zu eng (Einheit „Ohm“, „ohm“, „Ω“). Abhilfe: alle zulässigen Schreibweisen oder `*` als Platzhalter.

## Ausbaustufen
Teilpunkte für Schreibweisen (`fraction` kleiner 100), Rückmeldungen.
