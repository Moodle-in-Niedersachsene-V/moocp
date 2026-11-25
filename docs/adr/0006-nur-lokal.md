# E6 Nur lokal, nur für das eigene Konto

Status: gilt. Die Regeln dazu stehen im Index der [CLAUDE.md](../../CLAUDE.md).

## Entscheidung

Die KI-Werkzeuge erreichen die App nur über einen Kanal, den allein das Betriebssystem-Konto öffnen kann, unter dem die App läuft, und über die Brücke `moocp-bruecke` ([E21](0021-drei-ki-werkzeuge.md)). Es gibt keinen Port auf `127.0.0.1` für sie und keinen Zugangsschlüssel.

Der Kanal je Instanzprofil ([E31](0031-mcp-server-je-instanz.md)):

- **Linux und macOS:** ein Unix-Socket `<Profilname>.sock` in einem Ordner, der dem Konto allein gehört: Besitzer ist die laufende Kennung, die Rechte sind genau 0700, der Eintrag ist keine Verknüpfung (`lstat`). Unter Linux liegt er im Laufzeitordner der Sitzung (`$XDG_RUNTIME_DIR/moocp/kanal`, sonst `/run/user/<Kennung>/moocp/kanal`), wenn dieser dem Konto allein gehört, sonst in `<temp>/moocp-<Kennung>/kanal`; auf dem Mac in `kanal` im Einstellungsordner. Die Kennung kommt vom System, nie aus `$USER`. Den Socket legt die App mit 0600 an, der Besitz ist geprüft.
- **Windows:** eine Named Pipe `\\.\pipe\moocp-<SID>-<Profilname>`. Die erste Instanz entsteht mit `FILE_FLAG_FIRST_PIPE_INSTANCE`, damit ein anderes Konto, das den Namen vorher belegt hat, den Start scheitern lässt, statt dass die App neben einer fremden Pipe lauscht; `PIPE_REJECT_REMOTE_CLIENTS` schließt Fernzugriffe aus; die Zugriffsliste (`D:P(A;;GA;;;<SID>)`) erlaubt nur dem Konto etwas.

Beide Seiten prüfen die Gegenseite, bevor ein Byte fließt. Die App liest von einer angenommenen Verbindung nichts, bevor die Kennung der Gegenseite feststeht (SO_PEERCRED unter Linux, LOCAL_PEERCRED auf dem Mac, die SID im Token des Client-Prozesses unter Windows); bei einer anderen schließt sie die Verbindung und protokolliert nur den Grund. Die Brücke prüft zuerst Ordner und Socket (Besitzer, Rechte, keine Verknüpfung), dann nach dem Verbinden die Kennung des Kontos, das den Socket bedient, unter Windows die SID des Prozesses hinter der Pipe, und öffnet die Pipe mit `SECURITY_IDENTIFICATION`, damit ein Server sie nicht nachahmen kann. Fällt eine Prüfung durch, sendet sie nichts; die KI bekommt den Grund als Ergebnis des Werkzeugs.

Eine Verbindung ist eine MCP-Sitzung: JSON-RPC, eine Nachricht je Zeile. Endet sie, bricht ein laufender Aufruf ab, ein offener Freigabedialog schließt sich ([E4](0004-freigabe-in-der-app.md)). Die Einstellungsdatei und ihr Ordner gehören dem Konto allein (0600 und 0700 unter Linux und macOS). Der Server wird nie von außen erreichbar gemacht (siehe in [E21](0021-drei-ki-werkzeuge.md) verworfen: die ChatGPT-App über einen Tunnel).

## Verworfen

- **Streamable HTTP auf `127.0.0.1` mit einem Schlüssel als Bearer-Token:** Ein Port sagt nicht, wer ihn bedient. Belegt ein anderes Konto auf demselben Rechner ihn vor der App (die Reihenfolge des Starts entscheidet), bekäme es den Schlüssel und jeden Werkzeugaufruf, den ein KI-Werkzeug dorthin schickt; und jedes Konto kann sich mit dem Port verbinden. Ein Schlüssel im Klartext in den Einstellungen und in der Konfiguration der KI-Werkzeuge macht es nicht besser. Host- und Origin-Prüfung gegen DNS-Rebinding schützen nur vor Webseiten, nicht vor einem anderen Konto.
- **Ein Ordner im offenen Temp-Bereich als Ort des Sockets:** Dort legt jedes Konto an, was es will; wer den Namen zuerst belegt, bestimmt den Ort. Gilt nur als Rückfall, mit Prüfung von Besitzer und Rechten (sonst bricht der Start ab).
- **Ein Kanal ohne Prüfung der Gegenseite:** Auch ein privater Ordner schützt nur den Weg dorthin; die Prüfung der Kennung hält auch dann, wenn der Ordner einmal falsch angelegt wurde.
