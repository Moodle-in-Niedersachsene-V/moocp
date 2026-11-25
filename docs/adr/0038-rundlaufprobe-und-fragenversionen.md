# E38 Rundlaufprobe und neue Fragenversionen aus XML

Status: gilt. Ersetzt in [E9](0009-fragen-und-tests.md) die Liste durchgemessener Fragetypen als Voraussetzung für das Anlegen; ergänzt [E17](0017-moodle-ist-massgeblich.md) und [E37](0037-unklarer-schreibausgang.md).

## Entscheidung

**Rundlaufprobe.** Jede Frage, die die App per Import anlegt, und jede Fragenversion, die sie aus XML einspielt, besteht eine Rundlaufprobe, bevor das Werkzeug `verified` meldet. Das Urteil fällt das Werkzeug (A3). Die Probe hat vier Teile:

1. Die gespeicherte Frage wird wieder als Moodle-XML exportiert und mit der Eingabe verglichen, nach Normalisierung. Was Moodle beim Speichern selbst ergänzt, ist erlaubt (Eingabe ⊆ Ausgabe); was fehlt oder anders ist, nicht.
2. Das Bearbeitungsformular der Frage öffnet sich ohne Fehlermeldung.
3. Die Vorschau der Frage lädt ohne Moodle-Fehler.
4. Das Bearbeitungsformular wird einmal unverändert gespeichert, mit dem Status „Entwurf“. Moodle muss es annehmen. Die so entstandene Probeversion wird exportiert, mit der geprüften Version verglichen und wieder gelöscht. Lehnt Moodle das Speichern ab oder weicht die Probeversion ab, ist die Probe nicht bestanden: Die Frage ließe sich von Hand nicht weiterbearbeiten oder würde beim nächsten Speichern verändert. Lässt sich der Status nicht auf „Entwurf“ setzen, wird nicht gespeichert und die Antwort nennt diesen Teil „nicht geprüft“; eine Probe greift nie in laufende Tests ein, die die neueste bereite Version ziehen.

Besteht eine Frage die Probe nicht, gibt das Werkzeug den Befund an die KI. Automatisch entfernt wird nur, was diesem Aufruf direkt als angelegt gemeldet wurde; fehlt der Herkunftsnachweis oder ist ein Schreibausgang unklar, bleibt das Objekt zur manuellen Prüfung stehen. Die Antwort nennt, dass es weiterhin in Tests aktiv sein kann.

**Löschen nur, was derselbe Aufruf angelegt hat.** Ein Importwerkzeug löscht ausschließlich Fragen und Versionen, deren Nummer Moodle ihm in diesem Aufruf beim Import oder Speichern direkt genannt hat, und prüft Nummer und Version unmittelbar vorher. Eine erst im Kategorieexport gefundene Nummer belegt die Herkunft nicht: Zwischen Schreiben und Export kann jemand anderes gespeichert haben. Solche Fragen und Versionen werden weder automatisch gelöscht noch auf Entwurf gesetzt. Das gilt insbesondere für `qbank_importasversion`: Seine Importseite leitet ohne neue Versionsnummer zurück. Der Import bleibt nutzbar, indem die App den zurückgelesenen Zielinhalt und seine Rundlaufprobe bestätigt; `verified` bestätigt dabei den Inhalt, nicht die Herkunft der Versionsnummer. Bei Abweichungen nennt die Antwort die Nummer zur manuellen Prüfung. Scheitert das Löschen einer direkt bestätigten Probeversion, wird sie gemeldet; nur bei bestätigtem Entwurfsstatus heißt sie „Entwurf“, sonst bleibt der Status ausdrücklich ungeprüft. Einen zweiten Löschweg gibt es nicht. Das Löschen gehört zum Werkzeugaufruf und fällt unter dessen Freigabe (E20); der Freigabedialog nennt es.

**Jeder Fragetyp.** Anlegbar ist jeder Fragetyp, den die Instanz kennt, wenn er die Rundlaufprobe besteht. Eine Liste von Entwicklern gemessener Typen ist keine Voraussetzung mehr. Zusatznachweise bleiben: STACK nur mit gelaufenen Fragetests, CodeRunner erst nach einmaligem Speichern über das Formular (nur dort läuft die Musterlösung durch die Sandbox). Prototypen werden nie angelegt.

**Neue Version aus XML.** Eine Fragenversion aus XML spielt die App nur über die Seite des Moodle-Plugins `qbank_importasversion` ein. Ob es die Seite gibt, ermittelt sie zur Laufzeit an genau der Frage, um die es geht (A9). Fehlt sie, meldet das Werkzeug mit einem festen Satz, dass das Plugin fehlt und eine neue Version aus XML auf dieser Instanz nicht geht, und nennt die Wege, die bleiben: ändern über das Formular (`aendern`) oder als neue Frage ohne gemeinsamen Verlauf. Einen Ersatzweg über Sicherungen oder Löschen und neu Anlegen gibt es nicht (A6).

Eine Datei darf mehrere Fragen enthalten. Jede wird über ihre Sachnummer der vorhandenen Frage derselben Kategorie zugeordnet, das Plugin wird je Frage einmal aufgerufen. Fehlt der Treffer, ist die Sachnummer mehrdeutig oder weicht der Fragetyp ab, bricht das Werkzeug ab, bevor es irgendetwas schreibt. Eine Freigabe gilt für die ganze Datei, ab „mittel“ wie Ändern, mit Zeilenvergleich alte gegen neue Version.

Die Stand-Prüfung (E17) verlangt, dass die Version, von der die KI ausging, noch die neueste ist. Ist inzwischen eine neuere gespeichert, bricht das Werkzeug ab und nennt sie. Nur wenn der Aufruf genau diese Versionsnummer ausdrücklich nennt, spielt es die neue Version darüber; die übergangene Version bleibt im Verlauf.

`frage_ersetzen` bleibt für einen Wechsel des Fragetyps und für Instanzen ohne das Plugin, mit dem Hinweis, dass der Verlauf der alten Frage nicht übergeht. Der Skill schlägt es nicht vor, wo eine neue Version möglich ist.

**Bildschirmfoto.** Ein Bildschirmfoto ist nicht Teil der Probe, weil jedes Bild eine Freigabe braucht (E18). Der Skill schlägt eines vor, wenn es zum Fragetyp noch keine Fragetyp-Notiz gibt.

**Fragetyp-Notizen.** Wissen über einen Fragetyp steht in einer Fragetyp-Notiz: Kopf mit Fragetyp, Moodle-Version und Tag der bestandenen Probe; Minimalbeispiel; Pflichtstruktur; Stolpersteine (Symptom, Ursache, Abhilfe); Ausbaustufen. Ausgeliefert werden Notizen mit dem Skill `moodle-fragen`; dazu kommen lokale Notizen je Instanzprofil in einem dauerhaften Ordner der App, außerhalb des Arbeitsordners (E5). Gilt für einen Typ beides, gilt die lokale. Eine lokale Notiz schreibt nur die App, und nur nachdem die Rundlaufprobe für diesen Typ im selben Instanzprofil bestanden ist; das Minimalbeispiel setzt die App aus dieser Probe ein, die KI schreibt es nicht ab. Vor dem Schreiben fragt die KI die Lehrkraft im Chat. Bewährte lokale Notizen kommen über ein Issue oder einen Pull Request in den Skill.

## Verworfen

- **Nur von Entwicklern gemessene Fragetypen anlegen:** Hielt jeden Typ fern, den Moodle importieren kann, bis jemand ihn von Hand durchgemessen hatte, und prüfte nur die Instanz, auf der gemessen wurde. Die Probe prüft jede Frage auf der Instanz, auf der sie entsteht.
- **Nur Kernfelder vergleichen** (Name, Text, Antworten): Typspezifisches wie Drag-and-drop-Plätze, Lücken oder Rückmeldebäume fiele durch.
- **Das Formular nicht speichern:** Eine Frage, die sich von Hand nicht abschließen lässt, bliebe unentdeckt, bis sie jemand ohne KI bearbeiten will.
- **Das Formular speichern und die Probeversion stehen lassen:** Jede Änderung hinterließe zwei Versionen; ohne den Status „Entwurf“ läge die Probeversion kurz in laufenden Tests.
- **Bildschirmfoto in jeder Probe:** Jedes Bild braucht eine Freigabe (E18); die Probe käme nie ohne Klick aus.
- **Mehrere Versionen einer Frage in einer XML-Datei:** Moodle-XML kennt keine Versionen; der Import legt gleiche Sachnummern als getrennte Fragen an.
- **Neue Version über eine Sicherung:** Dass eine Wiederherstellung Versionen an eine vorhandene Frage anhängt, ist nicht belegt, und eine von der KI gebaute Sicherungsdatei widerspricht E29.
- **`qbank_gitsync`:** braucht einen Web-Service-Token (E23).
- **Fragetyp-Notizen im Kontextbereich oder in Moodle:** Der Kontextbereich gehört zu einem Plugin (E35); die App muss ohne es auskommen.
- **Fragetyp-Notizen frei von der KI geschrieben:** Ein ungeprüftes Minimalbeispiel trüge einen Fehler in den nächsten Versuch; ein falsches Beispiel ist schlimmer als keines.
