# E14 AGPLv3 mit Zusatz für Plugins, verträgliche Abhängigkeiten

Status: gilt. Die Regeln dazu stehen im Index der [CLAUDE.md](../../CLAUDE.md).

## Entscheidung

Die App steht unter der GNU Affero General Public License, Version 3 oder später (`LICENSE.md`, Tobias Steinmann), mit einer zusätzlichen Erlaubnis nach Abschnitt 7: Plugins (E35), also eigene Programme, die nur über die Plugin-Schnittstelle mit moocp sprechen, dürfen unter jeder Lizenz stehen. Das Beispiel-Plugin steht unter MIT (`example/example-plugin/LICENSE`).

Jedes Paket, auch jedes indirekte in `pubspec.lock`, braucht eine Lizenz, die mit der AGPLv3 verträglich ist – vor dem Hinzufügen die LICENSE-Datei im Pub-Cache ansehen. Verträglich sind die freizügigen (MIT, BSD, Apache 2.0) und GPLv3, LGPLv3 und AGPLv3; nicht verträglich ist „GPLv2 only“. Die Pakete des Beispiel-Plugins brauchen eine freizügige Lizenz, sonst wäre es keine Vorlage für Plugins unter beliebiger Lizenz. Die Pflicht, die Hinweise mit der App weiterzugeben, erfüllt Flutters Lizenzseite im Dialog „Über“.

## Begründung

Die AGPLv3 hält moocp und jede veränderte Version offen: Wer sie weitergibt oder über ein Netzwerk anbietet, muss den Quelltext unter derselben Lizenz zugänglich machen; ein geschlossener Ableger ist nicht möglich. Kommerzielle Nutzung schränkt sie nicht ein – das tut keine freie Lizenz, und eine nicht-freie passte nicht zu einem öffentlichen Open-Source-Projekt. „Oder später“, weil so Code unter einer künftigen Version der AGPL verträglich bleibt.

Die Erlaubnis für Plugins, weil sonst offen bliebe, ob ein Plugin, das moocp startet und mit dem es über MCP spricht, ein abgeleitetes Werk ist; wer ein Plugin schreibt, braucht dafür Rechtssicherheit. Aus demselben Grund steht das Beispiel-Plugin unter MIT: Plugins entstehen aus ihm als Vorlage.

Die Quelltexte jeder Version liegen im Tag des Releases neben dem Installer auf GitHub (E12); das erfüllt die Pflicht, mit dem Installer den Quelltext zugänglich zu machen.
