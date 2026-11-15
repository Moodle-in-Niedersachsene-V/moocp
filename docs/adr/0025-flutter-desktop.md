# E25 Flutter als Rahmen der Desktop-App

Status: gilt. Die Regeln dazu stehen im Index der [CLAUDE.md](../../CLAUDE.md).

## Entscheidung

moocp ist eine Flutter-Desktop-App mit einem Code für Windows und macOS. Die App enthält Fenster (Anmeldung, Freigabedialog, Protokoll, Einstellungen), den MCP-Server auf `127.0.0.1` (E6) und die Moodle-Sitzung in einem Prozess. Die Skills sind keine Flutter-Teile, sondern Pakete von `skills/build.py` (E8, E13).

Folgen für den Code:

- **Keine nachgeladene Logik im Prozess der App.** Alles, was die App tut, steht im ausgelieferten Code. Es gibt kein Werkzeug, das beliebigen Code ausführt oder beliebige Adressen anfragt (A1, E3). Erweiterungen gibt es nur als Plugin: ein eigenes Programm neben der App, das erst nach Zustimmung der Lehrkraft läuft (E35).
- **Wenige Pakete, nur freizügige Lizenzen** (E14). Wo ein Paket auf einer Plattform fehlt oder native Teile mitbrächte (WebView, TOML), wird es nicht aufgenommen (E18, E21).
- **Native Teile nur aus dem, was ohnehin dabei ist.** Native Teile bringen die Pakete mit, die die App ohnehin braucht: das Fensterpaket `window_manager` samt seiner Grundlage `nativeapi` (ein C++-Kern, der beim Bauen mit übersetzt wird), dazu Einstellungen, Zugangsdaten und Version. Braucht die App sonst etwas Natives, nimmt sie es von dort, wie Text und HTML zugleich in der Zwischenablage (E34), oder ruft eine Systembibliothek über `dart:ffi`, wie bei der Signaturprüfung der `claude.exe`. Ein weiteres Paket oder ein eigenes Plattform-Plugin für einen einzelnen Zweck hieße: mehr nativer Code, der je Plattform zu pflegen ist und mit jeder Flutter-Version brechen kann. `nativeapi` ist dafür direkte Abhängigkeit in der Version, die `window_manager` verlangt, und nur hinter einer Naht in `lib/plattform/` benutzt.
- **Eigenes Programm innerhalb dieses Projekts nur dort, wo ein Client es offen hält:** Die Brücke ist darum ohne Flutter geschrieben (E21).

## Verworfen

Eine Webanwendung oder ein Browser-Plugin (die Sitzung der Lehrkraft und die Datensperre ließen sich nicht im Code der App erzwingen, E1 verwirft die Chrome-Erweiterung). Ein Python- oder Node-Dienst (brächte eine Laufzeit auf den Rechner der Lehrkraft, die zu installieren und zu aktualisieren wäre). Ein MCP-Server ohne Fenster (die Freigabe in der App, E4, braucht eine Oberfläche).
