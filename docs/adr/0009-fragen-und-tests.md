# E9 Fragen und Tests

Status: gilt. Die Regeln dazu stehen im Index der [CLAUDE.md](../../CLAUDE.md).

## Entscheidung

Die Entscheidung gilt für `moodle-fragen` und beim Portieren in die App. Fragen werden per Moodle-XML-Import angelegt und über das Bearbeitungsformular geändert (das erzeugt eine neue Version mit neuer `questionid`); die Sachnummer (`idnumber`) ist die stabile Kennung, Mehrdeutigkeit wird gemeldet, nicht aufgelöst.

Welche Fragetypen anlegbar sind und wie eine neue Version aus XML entsteht, regelt [E38](0038-rundlaufprobe-und-fragenversionen.md): jeder Typ der Instanz, der die Rundlaufprobe besteht, mit den Zusatznachweisen für STACK und CodeRunner. Prototypen werden nie angelegt.

Fragen löschen geht nur mit allen Versionen, mit Namensprüfung und mit einer Freigabe auf jeder Stufe (`fragen_loeschen`, ebenso `frage_ersetzen`, wenn es die alte Frage löscht): jede Frage mit Name, Typ und Nummer einzeln abgehakt, höchstens 25 je Aufruf. Vor der Freigabe legt die App die aktuelle Version jeder Frage als Moodle-XML in `fragen-sicherungen/<Profil>` im Einstellungsordner ab (außerhalb des Arbeitsordners, damit sie dessen Leeren übersteht), liest die Datei zurück und löscht erst danach; lässt sich eine Frage nicht exportieren (auch eine verborgene nicht) oder die Datei nicht schreiben, wird nichts gelöscht. Gesichert ist nur die aktuelle Version: Den Verlauf kennt die App nicht (A1); zurück kommt die Frage über `fragen_importieren`. Nach der Freigabe prüft die App Namen und Export noch einmal und bricht ab, wenn sich etwas geändert hat. Steckt eine Frage in einem Test, verbirgt Moodle sie nur; die Rückfrage von Moodle kennzeichnet solche Versionen, die Freigabe sagt es vorher, und die Antwort trennt „gelöscht“ von „nur verborgen“ (dann `verified: false`). Leere Kategorien löscht die App nicht.
