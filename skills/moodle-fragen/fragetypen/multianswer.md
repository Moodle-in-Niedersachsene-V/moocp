# Fragetyp-Notiz: multianswer
Moodle-Version: 5.1 (Testinstanz)
Beweis: Import, Export und Vergleich sowie Vorschau auf der Testinstanz (Messung der Beispieldatei test/daten/fragen/kerntypen-test.xml). Die Rundlaufprobe mit Speichern des Formulars (E38) ist für diesen Typ noch nicht gelaufen; eine Notiz dieser Instanz, die nach bestandener Probe entsteht, geht dieser vor.

## Minimalbeispiel
```xml
<question type="multianswer">
  <name><text>ZZTEST multianswer cloze</text></name>
  <questiontext format="html"><text><![CDATA[<p>Das Ohmsche Gesetz lautet U = {1:SHORTANSWER:=R*I~%50%I*R} und die Einheit der Spannung ist {1:MULTICHOICE:=Volt~Ampere~Ohm}.</p>]]></text></questiontext>
  <generalfeedback format="html"><text></text></generalfeedback>
  <penalty>0.3333333</penalty>
  <hidden>0</hidden>
</question>
```

## Pflichtstruktur
Kein `defaultgrade`; die Punkte ergeben sich aus den eingebetteten Lücken `{Gewicht:TYP:Antworten}` im Fragetext. Im Export heißt der Typ `cloze`.

## Stolpersteine (Symptom, Ursache, Abhilfe)
- Symptom: Eine ganze Einreichung wird ohne Bewertung verworfen. Ursache: Eine einzige unbrauchbare Lücke (etwa `NUMERICAL` mit Punkt statt Komma auf deutscher Oberfläche). Abhilfe: Komma für Zahlen auf deutscher Oberfläche oder `SHORTANSWER`.
- Symptom: Formeln zerbrechen in einer Lücke. Ursache: `\{` in einer Lücke. Abhilfe: nur schließende Klammern maskieren (`\}`).

## Ausbaustufen
Alle dreizehn Lückenarten (references/fragetypen.md, „Lückentext / Cloze“).
