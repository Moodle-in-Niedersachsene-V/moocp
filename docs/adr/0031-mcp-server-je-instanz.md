# E31 Ein MCP-Server je Moodle-Instanz

Status: gilt. Ergänzt [E1](0001-werkzeugschicht-und-skills.md) und [E13](0013-ki-werkzeuge-einrichten.md) um die Trennung der Instanzen. Die Oberfläche bleibt ein gemeinsames Fenster ([E32](0032-ein-fenster-fuer-instanzprofile.md)). Die Regeln dazu stehen im Index der [CLAUDE.md](../../CLAUDE.md).

## Entscheidung

Jede angebundene Moodle-Instanz ist ein Profil und bekommt einen eigenen MCP-Server mit eigenem Kanal ([E6](0006-nur-lokal.md): Unix-Socket oder Named Pipe, benannt nach dem technischen Profilnamen) und eigenem Namen. Ein Server mit der Instanz als Werkzeugparameter wird nicht gebaut.

Namen: Das Standardprofil heißt „Moodle“ (technischer Name `moodle`) und steht für die Instanz, die die Lehrkraft nutzt. Weitere Profile tragen eigene Namen, etwa „Moodle Test“ (`moodle-test`). Der Anzeigename darf Leerzeichen enthalten, der technische Name nicht: Ein Werkzeug heißt `mcp__<name>__…`, und Leerzeichen sind darin nicht zulässig. Deshalb gibt es beide Namen. Der technische Name wird aus dem Anzeigenamen abgeleitet, bei einem neuen Profil auf höchstens 17 Zeichen gekürzt, auch mit einer angehängten Unterscheidung (so passt jedes Werkzeug eines Plugins samt `mcp__<name>__` in die 64 Zeichen, die Claude Code zulässt, E35), und dann gespeichert, damit ein Umbenennen die Einrichtung in den KI-Werkzeugen nicht still verstellt; er steht in der Konfiguration (Claude, Codex, Bionic) und ist das Argument `--profil` der Brücke, der Anzeigename steht in der App. Beide stehen nicht im Code fest, sondern im Profil.

## Folgen

- Welcher Server zu welcher Instanz gehört, richtet jeder für sich ein; wer zwei Instanzen anbindet, gibt dem Profil der Testinstanz einen unterscheidbaren Namen. Zum Testen wird nie über einen Server geschrieben, dessen Instanz nicht der des genannten Testkurses entspricht (A10); sonst schriebe ein Test-Aufruf versehentlich in die falsche Instanz.
- Die Freigabestufe (E20) und die Positivliste (E3) gelten je Instanz, nicht global.
- Jeder Server hat seinen eigenen Endpunkt (E6): Eine Verbindung zum Kanal eines Profils erreicht nie den Server eines anderen, der auf eine andere Moodle-Instanz schreibt. Ein neues Profil bekommt einen Eintrag mit seinem Namen in jedem KI-Werkzeug (die Brücke mit `--profil <Name>`); ein Eintrag, dessen Brücke ein anderes Profil bedient, gilt als veraltet, und „KI-Werkzeuge einrichten“ erneuert ihn. Zugangsschlüssel gibt es nicht; die Einstellungsdatei hält keinen, einer aus früheren Dateien wird beim Laden verworfen und die Datei ohne ihn neu geschrieben. Der Port eines Profils bleibt in der Datei, je Profil verschieden, damit eine ältere Version sie lesen kann (E39); dem MCP-Server dient er nicht.
- Die Skills müssen nicht wissen, welche Domain hinter einem Server liegt.
- Die Domain einer Instanz steht nur im Instanzprofil der App, nicht im Repository (A11).

## Verworfen

- **Je Profil ein Port und ein Schlüssel:** Ein Port sagt nicht, wer ihn bedient (E6).
- **Ein Server, Instanz als Parameter aller Werkzeuge:** Alle Werkzeugaufrufe und Skills müssten sich ändern, und ein fehlender Parameter wäre eine Verwechslungsquelle.
- **Namen aus der Domain:** Lang, ändert sich bei einem Umzug, und sagt einer Lehrkraft nicht, welche Instanz gemeint ist.
- **Namen mit Leerzeichen als technischer Name:** Nicht als Werkzeugpräfix zulässig.
