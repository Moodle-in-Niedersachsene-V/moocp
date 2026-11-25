# moocp

Begriffe für die Arbeit an Moodle-Kursen sowie deren Sicherung und Wiederherstellung.

Jeder Begriff nennt unter _Englisch_ das Wort, das in Issues, Pull Requests und Commits gilt; dort wird englisch geschrieben ([CONTRIBUTING.md](CONTRIBUTING.md)).

## Sprache

**Aktivität**:
Ein konkretes Element in einem Moodle-Kurs, etwa eine bestimmte Textseite, Aufgabe oder ein Test.
_Englisch_: activity

**Aktivitätsart**:
Die Art einer Aktivität, etwa Textseite, Aufgabe oder Test.
_Englisch_: activity type
_Vermeiden_: Aktivitätstyp

**Gruppierung**:
Eine benannte Zusammenstellung von Gruppen eines Kurses. Eine Aktivität kann auf eine Gruppierung beschränkt sein. Sicherungen ohne Nutzerdaten enthalten weder Gruppen noch Gruppierungen; die App liest nur Namen, nie Mitglieder.
_Englisch_: grouping

**Schutzdienst**:
Ein Dienst vor einer Moodle-Instanz (etwa Cloudflare), der Anfragen prüft oder abweist, bevor Moodle sie sieht. Er verlangt eine Prüfung, die nur ein Mensch im Browser besteht, oder weist die Anfrage gleich ab. Die App umgeht ihn nie.
_Englisch_: protection service

**Übergabe**:
Hält ein Schutzdienst das Speichern an, speichert die Lehrkraft selbst im Browser; die App führt sie durch die Schritte und liest danach zurück, ob Moodle den Stand zeigt. Keine Freigabe: Sie kommt auf jeder Stufe.
_Englisch_: handover

**Sichern**:
Ausgewählte Kursinhalte über Moodles Sicherungsfunktion in eine Sicherungsdatei ausgeben. „Exportieren“ ist dafür eine verständliche Formulierung im Gespräch.
_Englisch_: back up

**Sicherungsdatei**:
Eine von Moodle erzeugte `.mbz`-Datei mit den ausgewählten Kursinhalten. Sie kann aufbewahrt und unabhängig von ihrer Erstellung wiederhergestellt werden.
_Englisch_: backup file
_Vermeiden_: Aktivitäts-XML als Bezeichnung für eine vollständige Sicherungsdatei

**Sicherungsordner**:
Der dauerhafte Ordner der App für Sicherungsdateien, außerhalb des Arbeitsordners. Die App leert ihn nicht.
_Englisch_: backup folder
_Nicht zu verwechseln mit_: Arbeitsordner.

**Wiederherstellen**:
Inhalte einer Sicherungsdatei über Moodles Wiederherstellungsfunktion in einen neuen oder bestehenden Kurs übernehmen. „Importieren“ ist dafür eine verständliche Formulierung im Gespräch.
_Englisch_: restore

**Kursimport**:
Moodles gesonderte Übernahme von Inhalten aus einem anderen Kurs derselben Instanz.
_Englisch_: course import
_Vermeiden_: Kursimport als Bezeichnung für die Wiederherstellung einer Datei aus einer anderen Instanz

**Unterrichtsverteilung**:
Die Übertragung bereitgestellter Unterrichtsinhalte aus einem Quellkurs in einen oder mehrere Durchführungskurse. Die Lehrkraft erstellt die Inhalte zentral; sie selbst oder andere Lehrkräfte führen den Unterricht damit durch.
_Englisch_: content distribution

**Quellkurs**:
Der Kurs, aus dem die ausgewählten Unterrichtsinhalte gesichert werden.
_Englisch_: source course

**Durchführungskurs**:
Ein Zielkurs, in dem bereitgestellte Unterrichtsinhalte mit einer Lerngruppe genutzt werden. Zu einem Quellkurs können mehrere Durchführungskurse auf derselben Zielinstanz gehören.
_Englisch_: delivery course

## Werkzeuge, Freigabe und Einrichtung

**MCP-Server**
Der Dienst, den die App selbst anbietet: lokal auf `127.0.0.1`, geschützt durch einen Zugangsschlüssel. KI-Werkzeuge sprechen ihn direkt an.
_Englisch_: MCP server
_Nicht zu verwechseln mit_: Brücke.

**Brücke**
Ein kleines Zusatzprogramm, das nur für Bionic gebraucht wird. Bionic startet Server nur als lokalen Befehl, deshalb nimmt die Brücke diese Aufrufe entgegen und reicht sie an den MCP-Server weiter.
_Englisch_: bridge
_Nicht zu verwechseln mit_: MCP-Server.

**KI-Werkzeug**
Ein Programm, das die Werkzeuge der App für eine KI nutzbar macht. Unterstützt werden Claude Code, Codex CLI und Bionic (LM Studio).
_Englisch_: AI tool

**Freigabe**
Der Dialog in der App, in dem die Lehrkraft einen Schreibvorgang in Moodle bestätigt. Wie viele Freigaben kommen, stellt die Lehrkraft ein. Auch ein Plugin kann um eine Freigabe bitten; Titel und Beschreibung stammen dann vom Plugin, alle Regeln einer Freigabe gelten.
_Englisch_: approval
_Nicht zu verwechseln mit_: Bestätigungen (die Einstellung, die bestimmt, wie oft der Dialog erscheint).

**Bestätigungen**
Das Feld in der Titelzeile der App, in dem die Lehrkraft die Stufe der Freigaben einstellt: „alle", „mittel" (Voreinstellung) oder „keine".
_Englisch_: approval level
_Nicht zu verwechseln mit_: Freigabe (der einzelne Dialog).

**Rückfrage**
Eine Klärung vor dem Schreiben, wenn der Auftrag unklar ist (Ziel unklar, Wiederherstellung in einen bestehenden Kurs, Dateien mit möglichen Nutzerdaten, eine fehlende Gruppierung). Sie kommt auf jeder Stufe und ist keine Freigabe.
_Englisch_: clarification
_Nicht zu verwechseln mit_: Freigabe.

**Instanzprofil**
Eine angebundene Moodle-Instanz mit eigenem Anzeigenamen, Port, MCP-Server, Zugangsschlüssel, Anmeldung und Freigabestufe. Das Standardprofil heißt „Moodle"; weitere Profile tragen eigene Namen und sind erst ab dem zweiten in der Oberfläche zu sehen.
_Englisch_: instance profile

**Arbeitsordner**
Der feste Ordner der App, in dem gelesene Kursinhalte, Bildschirmfotos und Entwürfe liegen. Die App leert ihn beim Start und beim Beenden.
_Englisch_: working folder
_Nicht zu verwechseln mit_: Arbeitsbereich (der Abschnitt oder die Seite, an der die KI gerade arbeitet).

**Arbeitsbereich**
Was die Lehrkraft zuletzt genannt hat, innerhalb des Kurses: ein Abschnitt, eine Lernsituation oder eine einzelne Seite.
_Englisch_: working area
_Nicht zu verwechseln mit_: Arbeitsordner.

**Sperrliste**
Die Liste im Code, die Adressen und Inhalte mit personenbezogenen Daten von jedem Zugriff ausschließt, auch wenn eine Positivregel sie erfasst.
_Englisch_: block-list
_Nicht zu verwechseln mit_: Positivliste.

**Positivliste**
Die Liste im Code, die festlegt, welche Moodle-Adressen die App überhaupt anfragen darf. Sie ist die eigentliche Grenze für den Zugriff auf Moodle.
_Englisch_: allow-list
_Nicht zu verwechseln mit_: Sperrliste.

**Lesender Teil der Positivliste**
Die Regeln der Positivliste, die eine Seite oder Datei zeigen, ohne in Moodle etwas zu ändern, und kein Schritt eines Schreibvorgangs sind. Nur sie gelten für ein Plugin, das Moodle über die Adresse der App liest. Schreiben kann ein Plugin, was die Positivliste erlaubt, nur über die eingebauten Werkzeuge; was darüber hinausgeht, nur über eine Zusatzadresse der Art „schreiben“, mit einer Freigabe auf jeder Stufe.
_Englisch_: read-only part of the allow-list
_Nicht zu verwechseln mit_: Zusatzadresse (geht über die Positivliste hinaus und braucht die Zustimmung der Lehrkraft).

**Protokoll**
Der Verlauf in der App, in dem jede Anfrage an Moodle mit Methode, Pfad und Status steht, ohne Formularwerte und ohne Zugangsdaten.
_Englisch_: log

**Bildschirmfoto**
Eine Aufnahme nur des Inhalts einer Seite, wie sie im Browser aussieht, als Bilddatei im Arbeitsordner. Jedes Bild braucht eine eigene Freigabe.
_Englisch_: screenshot
_Nicht zu verwechseln mit_: einem Bildschirmfoto des ganzen Rechners oder der App.

**Einrichtung**
Der Vorgang, mit dem die App die KI-Werkzeuge für Moodle einrichtet: Verbindung und Skills. Er läuft beim Start, wenn etwas fehlt, und lässt sich über die Titelzeile erneut öffnen.
_Englisch_: setup
_Nicht zu verwechseln mit_: Anmeldung (bei Moodle).

**Skill**
Ein Paket aus Anleitungen und Regeln, das ein KI-Werkzeug bei Bedarf lädt. Die App bringt die Skills `moodle`, `moodle-fragen` und `lernsituation` mit.
_Englisch_: skill
_Nicht zu verwechseln mit_: Werkzeug (eine Funktion der App, die die KI aufruft).

**Werkzeug**
Eine Funktion der App, die ein KI-Werkzeug über den MCP-Server aufruft, etwa zum Lesen oder Ändern eines Kurses.
_Englisch_: tool
_Nicht zu verwechseln mit_: Skill.

**Plugin**
Eine zusätzlich installierbare Erweiterung der App aus einem eigenen Projekt, die eigene Werkzeuge und Skills mitbringt. Die App nutzt ein Plugin erst, nachdem die Lehrkraft genau diesem Stand zugestimmt hat (Zustimmung).
_Englisch_: plugin
_Nicht zu verwechseln mit_: Moodle-Plugin (eine Erweiterung der Moodle-Instanz; die App setzt keines voraus).
_Vermeiden_: internes Plugin, Modul als Bezeichnung für Teile der App selbst

**Zustimmung**
Das Annehmen eines Plugins durch die Lehrkraft, für genau eine Version und einen Stand der Dateien, mit der Wahl der Instanzprofile, in denen es eingeschaltet ist. Eine Zustimmung gibt nur die Lehrkraft in der App.
_Englisch_: consent
_Nicht zu verwechseln mit_: Freigabe (nur der Schreibvorgang in Moodle).
_Vermeiden_: Freigabe für ein Plugin, Installieren für das Annehmen

**Entwicklungs-Plugin**
Ein Plugin, das sein Entwickler selbst gestartet hat und das die App mit `--plugin-entwicklung <Ordner>` anhängt, statt es zu starten. Statt einer Zustimmung fragt bei jedem Start der App ein eigener Dialog; die Antwort wird nicht gespeichert.
_Englisch_: development plugin
_Nicht zu verwechseln mit_: ein installiertes Plugin, dem die Lehrkraft zugestimmt hat.

**Beschreibungsdatei**
Die Datei `plugin.json` im Ordner eines Plugins: Name, Kurzname, Version, Zusatzadressen und weitere Angaben, die die App vor jeder Zustimmung liest, ohne Code des Plugins auszuführen.
_Englisch_: plugin manifest

**Zusatzadresse**
Eine Seite der Moodle-Instanz, die ein Plugin über die Sperrliste der App hinaus braucht: ein Adressmuster, die Angabe „lesen“ oder „schreiben“ und ein Grund in einem Satz. Die Lehrkraft stimmt der Liste mit der Version des Plugins zu. Sie hebt die Sperrliste nur für dieses Plugin auf; über eine Zusatzadresse mit „schreiben“ schreibt es nur mit einer Freigabe, auf jeder Stufe, über eine mit „lesen“ liest es nur in einem Lauf.
_Englisch_: additional address

**Lauf**
Die Zeit, in der ein Plugin während eines Aufrufs über seine Zusatzadressen mit „lesen“ liest oder herunterlädt, angemeldet mit der Aktivität, um die es geht. Die App ermittelt den Kurs selbst, lädt die Namen seiner Teilnehmenden für die Datenschutzprüfung und lehnt jede Anfrage ab, die nicht zu Kurs und Aktivität passt. Er endet mit seinem Beenden oder dem Ende des Aufrufs und löscht dann, was er in den Ordner für Downloads geladen hat; die Namen bleiben gesperrt, bis die App endet.
_Englisch_: plugin run
_Nicht zu verwechseln mit_: der Aufruf eines Werkzeugs (ein Lauf liegt in einem Aufruf, höchstens einer zugleich).

**Ordner für Downloads**
Der Ordner im Temp-Verzeichnis, in den die App legt, was ein Plugin in einem Lauf über eine Zusatzadresse herunterlädt, je Plugin und Instanzprofil getrennt. Die App leert ihn beim Start und beim Beenden; sein Pfad geht nie an die KI und steht in keinem Protokoll.
_Englisch_: downloads folder
_Nicht zu verwechseln mit_: Arbeitsordner (dort liest die KI) und dem Unterordner `plugin-<Kurzname>` darin.

**Adresse der App (für Plugins)**
Die lokale Adresse, unter der ein Plugin die App erreicht, getrennt vom MCP-Server der KI-Werkzeuge: Protokollzeile, Arbeitsordner, eingebaute Werkzeuge, Dialoge, Freigaben, Lesen in Moodle und Schreiben über eine Zusatzadresse. Das Plugin meldet sich mit seinem Schlüssel an und nennt das Token des Aufrufs, in dem es gerade arbeitet.
_Englisch_: app endpoint (for plugins)
_Nicht zu verwechseln mit_: Zusatzadresse (eine Seite der Moodle-Instanz).
_Vermeiden_: Host-Schnittstelle, Callback-Server

**Dialog eines Plugins**
Ein Dialog, den ein Plugin über die Adresse der App beschreibt und die App zeigt, mit dem Plugin als Absender: Auswahl, Eingabe, Ordner- oder Dateiwahl, Hinweis. Er liefert die Antwort oder „abgebrochen“.
_Englisch_: plugin dialog
_Nicht zu verwechseln mit_: Freigabe (bestätigt einen Schreibvorgang; ein Dialog eines Plugins tut das nie).
_Vermeiden_: Fenster des Plugins (ein Plugin sollte kein eigenes Fenster öffnen)

**Aufruf-Token**
Ein zufälliges Geheimnis, das die App einem Plugin bei jedem Aufruf eines seiner Werkzeuge mitgibt. Es wählt das Instanzprofil und gilt an der Adresse der App nur für dieses Plugin und nur, solange der Aufruf läuft.
_Englisch_: call token
_Nicht zu verwechseln mit_: Schlüssel (gilt für das Plugin, solange sein Programm läuft).

**Kennung einer Freigabe**
Ein zufälliges Geheimnis, das ein Plugin bekommt, wenn die Lehrkraft einen Schreibvorgang über eine seiner Zusatzadressen freigegeben hat. Es gilt für genau diesen Schreibvorgang (Methode, Adresse mit Parametern, Formularfelder), einmal und nur im selben Aufruf.
_Englisch_: approval token
_Nicht zu verwechseln mit_: Aufruf-Token (gilt für alles, was das Plugin während eines Aufrufs tut), Kennung eines Instanzprofils.

**Datenschutzwarnung**
Das Fenster, das die App zeigt, wenn eine Antwort eines Plugins an die KI ein Wort enthält, das der Name einer Person sein könnte, oder den Pfad eines Ordners, in dem Daten von Personen liegen können. Es zeigt Plugin, Werkzeug, Herkunft und jeden Treffer in seiner Umgebung; die Lehrkraft entscheidet einmal für diese Antwort. Nichts wird gemerkt.
_Englisch_: privacy warning
_Nicht zu verwechseln mit_: Freigabe (sie betrifft einen Schreibvorgang in Moodle), Sperrliste (sperrt Adressen in Moodle).
_Vermeiden_: Namensfilter, Schwärzen (geschwärzt wird nichts)

**Datenschutzsperre**
Das Ergebnis, wenn die Lehrkraft in der Datenschutzwarnung „Sperren“ wählt oder nicht entscheidet: Die Antwort geht nicht an die KI, auch nicht in Teilen; die KI erfährt nur, dass gesperrt wurde. Wählt die Lehrkraft „Kein Name – trotzdem an die KI geben“, gibt es keine Datenschutzsperre. Ohne Rückfrage gilt sie auch für den Aufruf eines eingebauten Werkzeugs und eine Anfrage an Moodle, in denen ein Treffer steht (Antwort 422), und für eine Protokollzeile eines Plugins (Platzhalter).
_Englisch_: privacy block

**Fragensammlung**
Die Moodle-Aktivität, in der Fragen und ihre Kategorien liegen. Der Test verweist auf sie.
_Englisch_: question bank

**Fortschrittsliste**
Eine Moodle-Aktivität mit Einträgen, die man abhaken kann. Die App liest nur die Einträge, nie, wer sie abgehakt hat.
_Englisch_: checklist

**Board**
Eine Moodle-Aktivität mit Spalten und eigenen Notizen, die jede Person für sich führt. Nicht im Einzelnutzermodus.
_Englisch_: board
_Nicht zu verwechseln mit_: Kanban-Board.

**Kanban-Board**
Eine Moodle-Aktivität mit Spalten und Karten, die alle Teilnehmenden gemeinsam nutzen.
_Englisch_: Kanban board
_Nicht zu verwechseln mit_: Board.

**Lernsituation**
Ein didaktischer Entwurf für berufsbildende Schulen, der in Moodle genau einem Kursabschnitt entspricht.
_Englisch_: learning situation
_Nicht zu verwechseln mit_: Abschnitt (der Moodle-Gliederungsteil des Kurses, ohne Didaktik).

**Entwurf**
Der Zwischenstand einer Lernsituation im Arbeitsordner, bevor sie in den Kurs übertragen ist. Maßgeblich ist danach, was in Moodle steht.
_Englisch_: draft
_Nicht zu verwechseln mit_: Entwurfsbereich (der Moodle-Ablageort für Dateien eines Felds).

**Interaktives Element**
Eine kleine HTML-Anwendung zum Ausprobieren oder Üben, die in einem abgeschotteten Rahmen eines Textes läuft. Keine Bewertung, kein Gedächtnis.
_Englisch_: interactive element
_Nicht zu verwechseln mit_: Aktivität (eine Moodle-Aktivität wie Test oder Board).

**Verborgen / sichtbar**
Die Moodle-Sichtbarkeit einer Aktivität oder eines Abschnitts. Verborgenes erscheint für Lernende nicht auf der Kursseite; Voraussetzungen können den Zugang zusätzlich einschränken.
_Englisch_: hidden / visible

**Sichtbarkeitswahl bei Wiederherstellungen**
Ob wiederhergestellte Inhalte ihre Sichtbarkeit aus der Quelle behalten („wie Quelle“) oder die neuen Aktivitäten nachträglich verborgen werden („verborgen“). Die Voraussetzungen der Quelle bleiben in beiden Fällen erhalten. Eine Vorgabe gibt es nicht: Fehlt die Angabe, fragt das Werkzeug zurück, und die Lehrkraft entscheidet.
_Englisch_: restore visibility choice
_Code_: `WiederherstellungsSichtbarkeit`

**Druckaufbereitung**
Eine Funktion einer Moodle-Instanz, die Aufgabenblätter zum Drucken aufbereitet. Ob sie vorhanden ist, erkennt die App, sie wird nicht eingestellt.
_Englisch_: print preparation

**SchuCu**
Das „Schulische Curriculum Berufsbildende Schulen“, eine Leitlinie für die BBS. Die SchuCu-Tabelle einer Lernsituation stützt sich darauf und weist ihre Fachbezüge aus. Das Gymnasium und die IGS haben ihr eigenes schulinternes Curriculum, das hier nicht gemeint ist.
_Englisch_: SchuCu (school curriculum)

**KI-Sitzung**
Die Verbindung eines KI-Werkzeugs zur App über den MCP-Server.
_Englisch_: AI session
_Nicht zu verwechseln mit_: Moodle-Sitzung.

**Moodle-Sitzung**
Die Anmeldung bei Moodle, die die App über ein Sitzungscookie hält. Läuft sie ab, meldet sich die App neu an.
_Englisch_: Moodle session
_Nicht zu verwechseln mit_: KI-Sitzung.

## Versionen und Updates

**Kanal**:
Die Reihe von Versionen, aus der eine installierte App ihre Updates bekommt: „Stabil“ oder „Nightly“. Die Lehrkraft wählt ihn; er gilt für die App, nicht je Instanzprofil.
_Englisch_: update channel
_Vermeiden_: Zweig (für den Kanal), Ring

**Stabile Version**:
Eine Version, die vorher als Nightly bei Testern lief und danach als stabil veröffentlicht wurde. Nur sie bekommt, wer den Kanal „Stabil“ gewählt hat.
_Englisch_: stable release
_Vermeiden_: Release (allein, für die stabile Version)

**Nightly**:
Eine Version aus dem aktuellen Stand von `main`, zum Testen, gebaut einmal täglich, wenn sich etwas geändert hat, oder sofort auf Anstoß eines Maintainers. Ihre Änderungen sind vor der Veröffentlichung nicht unbedingt vom zweiten Maintainer gesehen. In der App heißt sie „Testversion (Nightly)“.
_Englisch_: nightly
_Vermeiden_: Lightning, Beta, Vorabversion (das ist nur das Feld bei GitHub)

**Hotfix**:
Eine Fehlerbehebung für die zuletzt veröffentlichte stabile Version, die ohne die neuen Funktionen aus `main` als eigene Fehlerversion erscheint.
_Englisch_: hotfix

**Rückkehr zur stabilen Version**:
Der Wechsel einer App von einer Nightly auf die letzte stabile Version, auch wenn diese eine kleinere Versionsnummer hat.
_Englisch_: return to stable
_Vermeiden_: Downgrade (im Text für Lehrkräfte)
