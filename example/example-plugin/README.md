# Beispiel-Plugin für moocp

Dieses Dart-Projekt ist das Beispiel-Plugin von moocp: eine Vorlage zum Ansehen und Kopieren für alle, die ein Plugin schreiben, und das Plugin, gegen das die Tests von moocp laufen. Es hat keine eigene Funktion; jedes seiner Werkzeuge zeigt einen Weg der Schnittstelle. Der Installer von moocp liefert es nicht mit.

Das Beispiel steht wie moocp unter der GNU Affero General Public License, Version 3 oder später (`LICENSE.md` im Hauptordner von moocp). Das gilt auch für ein Plugin, das daraus entsteht: Plugins für moocp sind Open Source, mit Quelltext und unter der AGPL oder einer damit verträglichen Lizenz.

Was ein Plugin ist, was die Beschreibungsdatei `plugin.json` enthält, was die Werkzeuge des Beispiels zeigen und wie moocp ein Plugin startet, steht in der README von moocp, Teil 4, Abschnitt „Plugins“. Der Quelltext in `bin/beispiel.dart` erklärt jeden Schritt.

## Voraussetzung

Das Dart-SDK, eigenständig oder als Teil des Flutter-SDK. Beim ersten Bauen oder Starten holt `dart` das Paket `mcp_dart` und seine Abhängigkeiten.

## Bauen

Die Bauskripte übersetzen das Programm und legen es mit `plugin.json` und `skills/` in einen fertigen Plugin-Ordner. Ohne Parameter ist das `build/beispiel` in diesem Projekt.

```
powershell -ExecutionPolicy Bypass -File example\example-plugin\bauen.ps1 [-Ziel <Zielordner>]
bash example/example-plugin/bauen.sh [<Zielordner>]
```

Installiert ist das Plugin, wenn der fertige Ordner als `plugins/beispiel` im Einstellungsordner von moocp liegt, unter Windows `%APPDATA%\moocp\plugins\beispiel`. Wer ihn dorthin legen will, nennt diesen Ordner als Zielordner; von sich aus schreibt das Skript dort nichts. moocp vorher beenden: Beim nächsten Start fragt moocp nach der Zustimmung zum geänderten Plugin. Ist der Zielordner nicht leer und enthält keine `plugin.json`, bricht das Skript ab, ohne etwas zu ändern.

## Installer

Der Installer ist eine Vorlage für den Installer eines eigenen Plugins; `installer/plugin.nsi` nennt in den Kommentaren, welche Regel von moocp jeder Abschnitt erfüllt. Gebaut wird er unter Windows mit Dart und NSIS 3 aus einer Eingabeaufforderung:

```
example\example-plugin\create_installer.bat
```

Das Skript baut das Plugin mit `bauen.ps1` neu nach `build\beispiel`, liest Kurzname, Version und Programm aus `plugin.json` und legt `installer\beispiel_setup_<Version>.exe` an. Unter genau diesem Namen, `<kurzname>_setup_<Version>.exe`, gehört der Installer eines Plugins in jedes Release seiner Update-Quellen; die Version steht nur in `plugin.json`.

Der Installer läuft für den angemeldeten Benutzer ohne Administratorrechte, ohne Parameter und auch bei laufender moocp. Er bricht ab, wenn moocp fehlt (weder `%APPDATA%\moocp` noch `%LOCALAPPDATA%\Programs\moocp\moocp.exe`), leert den Plugin-Ordner `%APPDATA%\moocp\plugins\beispiel` ganz und legt die neuen Dateien hinein; sonst liest und schreibt er nichts im Einstellungsordner von moocp. Läuft das Plugin noch, bittet er, moocp zu schließen, und beendet selbst nichts. Beim nächsten Start fragt moocp nach der Zustimmung zur neuen Version.

Deinstalliert wird unter „Installierte Apps“ („moocp-Plugin Beispiel“). Der Uninstaller liegt im Plugin-Ordner (`uninstall.exe`) und geht damit in die Prüfsumme der Zustimmung ein: Er ist bei jeder Installation derselben Version dieselbe Datei, und wer ihn austauscht, löst eine neue Frage nach der Zustimmung aus. Er entfernt den Plugin-Ordner und den Eintrag. Die Skills des Plugins in den KI-Werkzeugen bietet moocp beim nächsten Start im Dialog „KI-Werkzeuge einrichten“ zum Entfernen an. Wer moocp deinstalliert, entfernt den Plugin-Ordner mit und auch den Eintrag des Plugins unter „Installierte Apps“. moocp erkennt ihn daran, dass sein Installationsort (`InstallLocation`) oder sein Uninstaller (`UninstallString`) unter `%APPDATA%\moocp\plugins\` liegt; der Installer eines eigenen Plugins muss deshalb mindestens einen der beiden Werte so eintragen, sonst bleibt sein Eintrag stehen.

## Entwickeln

Die Startskripte starten das Beispiel aus dem Quelltext und hängen es an moocp an, ohne es zu installieren:

```
powershell -ExecutionPolicy Bypass -File example\example-plugin\entwickeln.ps1 [-Moocp <Pfad zur moocp.exe>]
bash example/example-plugin/entwickeln.sh [<Pfad zum Programm von moocp>]
```

Was sie dabei tun und was moocp dann fragt, steht in der README von moocp, Abschnitt „Ein Plugin entwickeln“.

## Ein eigenes Plugin daraus machen

Den Ordner kopieren und in `plugin.json` Name, Kurzname, Version, Herkunft, Update-Quellen, Zusatzadressen und Skills ersetzen; in `pubspec.yaml` den Namen; in den Skripten `bin/beispiel.dart` und den Vorgabeordner `build/beispiel`; in `installer/plugin.nsi` Anzeigename und Herausgeber. Die Werkzeuge beginnen mit dem neuen Kurznamen. Die Hilfsfunktionen `anMoocp` und `gleichInKonstanterZeit` lassen sich übernehmen; die Werkzeuge des Beispiels nicht, sie zeigen nur die Schnittstelle.
