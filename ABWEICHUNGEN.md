# Abweichungen von der Spec „Plugin-Infrastruktur“ (#60)

Arbeitsdatei für den Zweig `feature/plugin-infrastructure`: Hier steht jede Stelle, an der die Umsetzung von der Spec #60 oder einem ihrer Tickets abweicht und die nicht behoben wird. Vor dem Zusammenführen wird jede Zeile auf Showstopper geprüft; danach wird die Datei gelöscht, sie gehört nicht nach main.

Spalte „Prüfen“: woran sich entscheidet, ob die Abweichung ein Showstopper ist. Spalte „Stand“: *offen* (noch nicht beurteilt), *bestätigt* (vom Maintainer so gewollt), *an der Instanz zu prüfen* (entscheidet sich erst beim Durchspielen, #84).

## Strenger als die Spec

| Nr. | Ticket | Spec | Umsetzung | Mögliche Folge | Prüfen | Stand |
|---|---|---|---|---|---|---|
| S1 | #77, #80 | Eine Antwort enthält nie Cookies oder den `sesskey` über das hinaus, was die Seite selbst enthält. | Ein Plugin bekommt von einer HTML-Seite nur den Hauptbereich (`#region-main`); hat die Seite keinen, bekommt es nichts. | Seiten mit ungewöhnlichem Layout oder Theme sind für Plugins nicht lesbar. | Haben die Seiten, die ein Plugin braucht, auf der Instanz einen `#region-main`? | an der Instanz zu prüfen |
| S2 | #77, #80 | wie S1 | Der `sesskey` wird aus jedem Text an ein Plugin entfernt, auch aus JSON und reinem Text. | Ein Plugin kann keine Schreibanfrage selbst vorbereiten; das ist gewollt. Fällt eine Antwort auf, in der eine zufällig gleiche Zeichenfolge fehlt? | Durchspielen mit dem Beispiel-Plugin. | offen |
| S3 | #80 | Im Lauf wird abgelehnt, was eine *andere* Kurs- oder Aktivitätsnummer trägt. | Abgelehnt wird auch, was *keine erkennbare* Kurs-, Aktivitäts- oder Kontextnummer trägt. | Eine Zusatzadresse, die nur etwa `attempt=7` oder `userid=3` trägt, lässt sich nicht lesen. | Braucht ein geplantes Plugin solche Adressen? | offen |
| S4 | #80 | wie S3 | Erkannt werden die üblichen Parameter (`id`, `course`, `cmid`, Kontext und ähnliche). Nummern anderer Art und Nummern im Pfad erkennt die App nicht. | Ein Plugin kann über eine solche Nummer an Daten eines anderen Kurses kommen, wenn die Seite dahinter es zulässt. | Ist das für die Datensperre (A1) hinnehmbar? Die README nennt die Grenze. | offen |
| S5 | #81 | Umleitungsziele werden wie die Adresse selbst geprüft. | Ein Download über eine Zusatzadresse folgt keiner Umleitung; sie endet als Fehler. | Skripte, die erst auf die Datei umleiten, liefern nichts. | Leiten die Exporte der Instanz um? | an der Instanz zu prüfen |
| S6 | #77 | Ein Plugin darf über die Positivliste GET und POST zu den Regeln der eingebauten Werkzeuge. | Roh über die Adresse der App nur lesen; schreiben nur über die eingebauten Werkzeuge oder eine Zusatzadresse „schreiben“ (E36, ADR 0036). | Ein Plugin kann nichts schreiben, wofür es kein eingebautes Werkzeug und keine Zusatzadresse gibt. | Texte von Spec und Ticket #77 anpassen? | bestätigt |

## Anders als die Spec

| Nr. | Ticket | Spec | Umsetzung | Mögliche Folge | Prüfen | Stand |
|---|---|---|---|---|---|---|
| A1 | #82 | Skill-Pakete als `skills/*.skill`, im selben Format wie die eigenen. | Ordner `skills/<name>/`, Pflicht-Skills im neuen Feld `skills` der Beschreibungsdatei. | Wer sein Paket mit dem Bauskript von moocp erzeugt, muss es entpackt ausliefern. | Reicht die Beschreibung in der README? Text der Spec anpassen? | bestätigt |
| A2 | #72 | `--werkzeugliste` enthält die gemerkte Liste jedes Plugins mit Zustimmung. | Nur für Plugins des Standardprofils und nur bei unveränderter Prüfsumme. | Keine: Die Brücke kennt nur den Server `moodle`. | – | bestätigt |
| A3 | #73 | Ein abgestürztes Plugin wird einmal neu gestartet. | Einmal je Lauf der App, nicht einmal je Absturz. | Nach dem zweiten Absturz bleibt das Plugin bis zum Neustart der App aus. | Ist das beim Arbeiten lästig? | offen |
| A4 | #76 | Dialog „Ordner- oder Dateiwahl“. | Eigener einfacher Dialog der App statt des Dialogs des Betriebssystems (kein neues Paket). | Weniger Komfort (keine Favoriten, keine Netzlaufwerke in der Seitenleiste). | Genügt das den Lehrkräften? | offen |
| A5 | #82 | Skills eines Plugins mit Zustimmung werden eingerichtet. | Maßgeblich ist die Zustimmung, nicht das Einschalten je Profil. | Ein in allen Profilen ausgeschaltetes Plugin behält seine Skills. | Stört das? | offen |
| A6 | #81 | – | Ein Download über eine Zusatzadresse nimmt auch Dateien ohne Größenangabe an; die Grenze von 200 MB wird beim Laden gezählt. | Keine bekannte. | – | offen |
| A7 | #81 | – | Die Endung einer heruntergeladenen Datei kommt aus einer festen Liste, sonst `bin`. | Ein Plugin muss das Format am Inhalt erkennen, wenn die Endung nicht in der Liste steht. | Fehlt eine wichtige Endung? | offen |
| A8 | #83 | Bei unpassender Schnittstelle bietet ein Dialog das Update der zu alten Seite an. | Für ein zu altes Plugin wird nur gesucht, wenn seinem jetzigen Stand zugestimmt ist; sonst nur der Hinweis ohne Angebot. | Wer ein zu altes Plugin frisch installiert, muss das neue selbst holen. | Hinnehmbar? Das Kriterium „nur für zugestimmte Plugins“ verlangt es so. | offen |
| A9 | #83 | – | Ein Plugin mit unpassender Schnittstelle gilt als nicht geladen: Die App verwirft seine gemerkte Werkzeugliste, und die Einrichtung bietet seine Skills zum Entfernen an. Kein Test deckt das. | Nach einem Update von moocp, das ein Plugin zu alt macht, erscheint der Einrichtungsdialog mit dem Entfernen der Skills. | Ist das Entfernen dann erwünscht oder verwirrend? | offen |
| A10 | #83 | Der Installer eines Plugins läuft sichtbar nach ausdrücklichem Ja. | Die App wartet auf sein Ende und läuft dabei weiter; der Installer bekommt keine Parameter. | Der Installer eines Plugins muss mit laufender App zurechtkommen (steht in der README). | Für Plugin-Autoren zumutbar? | offen |
| A11 | #83 | – | Nach Updates von Plugins wird nur gesucht, wo sich moocp selbst aktualisieren kann: nicht im Entwicklerbau, nicht auf dem Mac, nicht mit `--kein-update`. | Im Entwicklerbau lässt sich die Update-Prüfung eines Plugins nicht durchspielen. | Wie wird sie dann in #84 geprüft? | offen |
| A12 | #83 | – | Der Dialog „Plugin bleibt aus“ erscheint bei jedem Start, solange die Schnittstelle nicht passt. | Lästig, wenn es kein Update gibt; abstellen lässt er sich nur durch Entfernen des Plugins. | Stört das? | offen |
| A13 | #83 | – | Aus dem Dialog zur Schnittstelle sucht ein Klick einmalig nach einem Update von moocp, auch wenn die tägliche Prüfung aus ist. | Eine Anfrage an GitHub ohne das allgemeine Ja; der Klick gilt als Ja, wie bei „Jetzt nach Updates suchen“. | Mit E19 vereinbar? | offen |
| A14 | #82 | – | Ist ein Entwicklungs-Plugin angehängt, gelten nur seine Skills; ein installiertes Plugin mit demselben Kurznamen bringt in diesem Lauf keine mit. | Nennt das installierte einen Skill, den der Entwicklungsordner nicht mehr hat, bietet der Einrichtungsdialog ihn zum Entfernen an; beim nächsten Start ohne Parameter wird er wieder installiert. | Lästig für Plugin-Entwickler? | offen |
| A15 | #82 | – | Ein unbrauchbares Skill-Paket gilt als gesehen, sobald die Lehrkraft den Einrichtungsdialog mit „Weiter“ verlässt, gleich warum er erschien; der gesehene Stand ist je Plugin eine Prüfsumme über Plugin-Stand und Gründe, beim Entwicklungs-Plugin über Kurzname und Gründe. | Ein Entwicklungs-Plugin mit demselben Fehler öffnet den Dialog nach einer Änderung seiner Dateien nicht erneut. | Hinnehmbar? | offen |

## Grenzen, die die Umsetzung hat

| Nr. | Ticket | Grenze | Mögliche Folge | Prüfen | Stand |
|---|---|---|---|---|---|
| G1 | #78, #81 | Die letzte Sperre erkennt Namen und den Pfad des Ordners für Downloads nicht in Prozentkodierung, Unicode-Escapes oder Base64. | Ein Plugin, das so kodiert, kommt an der Sperre vorbei; sie ist die letzte, nicht die erste. | Hinnehmbar nach E36? | offen |
| G2 | #80 | Sieht die Lehrkraft bei getrennten Gruppen nur ihre Gruppe, lädt die App nur deren Namen; das fällt nicht auf. | Namen anderer Gruppen sind nicht gesperrt. | An der Instanz mit getrennten Gruppen prüfen. | an der Instanz zu prüfen |
| G3 | #80 | Das Auswerten der Teilnehmendenseite ist nur gegen Testdoppel geprüft (elf Punkte für #84). | Stimmt etwas nicht, beginnt kein Lauf. | Durchspielen im Testkurs. | an der Instanz zu prüfen |
| G4 | #82 | Zwischen der Prüfsumme und dem Lesen der Skill-Dateien liegt ein kurzes Zeitfenster. | Eine in diesem Moment getauschte Datei würde installiert. | Im Review am Ende beurteilen. | offen |
| G5 | #75 | `status`, über ein Plugin aufgerufen, zeigt „Verbunden über: unbekannt“. | Schönheitsfehler. | – | offen |
| G6 | #73 | Der Dialog „Plugins“ zeigt während eines Neustarts eines Plugins kurz einen falschen Text. | Schönheitsfehler. | – | offen |
| G7 | #81, #82 | Die Änderungen am Installer-Skript sind nur am Text geprüft. | Die Deinstallation könnte den Ordner für Downloads oder die Skills der Plugins stehen lassen. | Am gebauten Installer prüfen, wenn ein Bau beauftragt ist. | offen |
| G8 | #74 | Der Test, dass kein Programm an `lib/plattform/kindprozess.dart` vorbei startet, sieht nur `Process.start`, `Process.run` und `Process.runSync` im Quelltext unter `lib/`; Pakete von Dritten prüft er nicht. | Startete ein Paket selbst ein Programm, erbte es den Schlüssel eines Entwicklungs-Plugins. | Startet eines der Pakete in `pubspec.yaml` Programme? | offen |

## Zur Behebung vorgeschlagen, noch nicht entschieden

Wird ein Punkt behoben, verschwindet er hier; wird er nicht behoben, wandert er in eine der Tabellen oben.

| Nr. | Ticket | Abweichung | Vorschlag |
|---|---|---|---|
