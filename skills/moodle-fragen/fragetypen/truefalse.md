# Fragetyp-Notiz: truefalse
Moodle-Version: 5.1 (Testinstanz)
Beweis: Import, Export und Vergleich sowie Vorschau auf der Testinstanz (Messung der Beispieldatei test/daten/fragen/kerntypen-test.xml). Die Rundlaufprobe mit Speichern des Formulars (E38) ist für diesen Typ noch nicht gelaufen; eine Notiz dieser Instanz, die nach bestandener Probe entsteht, geht dieser vor.

## Minimalbeispiel
```xml
<question type="truefalse">
  <name><text>ZZTEST truefalse</text></name>
  <questiontext format="html"><text><![CDATA[<p>Ein Fehlerstromschutzschalter schuetzt auch vor Kurzschluss.</p>]]></text></questiontext>
  <generalfeedback format="html"><text></text></generalfeedback>
  <defaultgrade>1.0000000</defaultgrade>
  <penalty>1.0000000</penalty>
  <hidden>0</hidden>
  <answer fraction="0" format="moodle_auto_format"><text>true</text><feedback format="html"><text>Nein, dafuer ist der Leitungsschutzschalter zustaendig.</text></feedback></answer>
  <answer fraction="100" format="moodle_auto_format"><text>false</text><feedback format="html"><text>Richtig.</text></feedback></answer>
</question>
```

## Pflichtstruktur
Genau zwei Antworten, deren Text wörtlich `true` und `false` lautet (nicht „wahr“/„falsch“); die richtige trägt `fraction` 100.

## Stolpersteine (Symptom, Ursache, Abhilfe)
- Symptom: Die Frage zeigt keine Auswahl oder bewertet falsch. Ursache: Antworttexte auf Deutsch statt `true`/`false`. Abhilfe: wörtlich `true` und `false`.

## Ausbaustufen
Rückmeldung je Antwort; `penalty` üblicherweise 1.
