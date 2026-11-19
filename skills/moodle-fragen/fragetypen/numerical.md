# Fragetyp-Notiz: numerical
Moodle-Version: 5.1 (Testinstanz)
Beweis: Import, Export und Vergleich sowie Vorschau auf der Testinstanz (Messung der Beispieldatei test/daten/fragen/kerntypen-test.xml). Die Rundlaufprobe mit Speichern des Formulars (E38) ist für diesen Typ noch nicht gelaufen; eine Notiz dieser Instanz, die nach bestandener Probe entsteht, geht dieser vor.

## Minimalbeispiel
```xml
<question type="numerical">
  <name><text>ZZTEST numerical</text></name>
  <questiontext format="html"><text><![CDATA[<p>Ein Widerstand von 100 Ohm liegt an 230 V. Welcher Strom fliesst in A?</p>]]></text></questiontext>
  <generalfeedback format="html"><text><![CDATA[<p>I = U / R</p>]]></text></generalfeedback>
  <defaultgrade>2.0000000</defaultgrade>
  <penalty>0.3333333</penalty>
  <hidden>0</hidden>
  <answer fraction="100" format="moodle_auto_format"><text>2.3</text><feedback format="html"><text>Richtig.</text></feedback><tolerance>0.05</tolerance></answer>
  <units><unit><multiplier>1</multiplier><unit_name>A</unit_name></unit></units>
  <unitgradingtype>0</unitgradingtype>
  <unitpenalty>0.1000000</unitpenalty>
  <showunits>3</showunits>
  <unitsleft>0</unitsleft>
</question>
```

## Pflichtstruktur
Mindestens eine Antwort mit Zahl in `<text>` und `<tolerance>`. Dezimaltrenner im XML ist der Punkt.

## Stolpersteine (Symptom, Ursache, Abhilfe)
- Symptom: Ein gerundetes Ergebnis gilt als falsch. Ursache: Ohne `<tolerance>` wird exakt verglichen. Abhilfe: absolute Toleranz von einer halben Einheit der letzten verlangten Stelle.
- Symptom: Einheit wird verlangt, obwohl der Fragetext sie nennt. Ursache: `showunits` falsch. Abhilfe: `showunits` 3 (keine Einheit verlangt) und die Einheit in den Fragetext.

## Ausbaustufen
Mehrere Antworten mit Teilpunkten, Einheiten mit `<units>`.
