# E9 Fragen und Tests

Status: gilt. Die Regeln dazu stehen im Index der [CLAUDE.md](../../CLAUDE.md).

## Entscheidung

Die Entscheidung gilt für `moodle-fragen` und beim Portieren in die App. Fragen werden per Moodle-XML-Import angelegt und über das Bearbeitungsformular geändert (das erzeugt eine neue Version mit neuer `questionid`); die Sachnummer (`idnumber`) ist die stabile Kennung, Mehrdeutigkeit wird gemeldet, nicht aufgelöst.

Welche Fragetypen anlegbar sind und wie eine neue Version aus XML entsteht, regelt [E38](0038-rundlaufprobe-und-fragenversionen.md): jeder Typ der Instanz, der die Rundlaufprobe besteht, mit den Zusatznachweisen für STACK und CodeRunner. Prototypen werden nie angelegt.

Fragen löschen geht nur mit allen Versionen, nach Freigabe und mit Namensprüfung (`fragen_loeschen`); steckt eine Frage in einem Test, verbirgt Moodle sie nur, und das Werkzeug meldet es. Leere Kategorien löscht die App nicht.
