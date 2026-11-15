# E14 AGPL ab Version 3, auch für Plugins; nur freizügige Abhängigkeiten

Status: gilt. Die Regeln dazu stehen im Index der [CLAUDE.md](../../CLAUDE.md).

## Entscheidung

moocp steht unter der GNU Affero General Public License, Version 3 oder später (`LICENSE.md`; Rechteinhaber Tobias Steinmann und Matthias Grünwald). Das gilt ab Version 0.12.0; was davor unter MIT veröffentlicht wurde, bleibt unter MIT verfügbar. Beiträge zum Projekt stehen unter derselben Lizenz.

Plugins sind ebenfalls Open Source: Ein Plugin für moocp darf nur mit seinem vollständigen Quelltext und unter der AGPL ab Version 3 oder einer damit verträglichen Lizenz weitergegeben werden. `LICENSE.md` sagt das ausdrücklich. Das Beispiel-Plugin steht wie die App unter der AGPL.

Jedes Paket, auch jedes indirekte in `pubspec.lock`, braucht eine freizügige Lizenz (MIT, BSD, Apache 2.0) – vor dem Hinzufügen die LICENSE-Datei im Pub-Cache ansehen. Diese Lizenzen vertragen sich mit der AGPL; ein Paket unter einer Lizenz, die sich nicht mit ihr verträgt, könnte die App nicht mehr weitergeben. Die Pflicht, die Hinweise mit der App weiterzugeben, erfüllt Flutters Lizenzseite im Dialog „Über“.

## Begründung

Der Quelltext von moocp soll allen zur Verfügung stehen, und was jemand daran ändert, um es zu nutzen oder weiterzugeben, soll wieder allen zugutekommen. Niemand soll den Code nehmen, ändern und für sich behalten. Eine freizügige Lizenz wie MIT erlaubt genau das: einen geschlossenen Ableger. Die AGPL verlangt bei jeder Weitergabe einer geänderten Version den Quelltext unter derselben Lizenz, auch wenn die Version nur als Dienst über ein Netz angeboten wird.

Kommerzielle Nutzung bleibt erlaubt und ist gewollt: Wer moocp verkauft, betreibt, dafür schult oder Unterstützung anbietet, darf das, solange der Quelltext frei bleibt. So gehört der Code keinem einzelnen Anbieter, und jede Weiterentwicklung kommt allen zugute.

Dasselbe gilt für Plugins, und aus demselben Grund. Ein Plugin ist für die Schnittstelle von moocp geschrieben, wird von moocp gestartet und arbeitet nur zusammen mit moocp; es darf das, weil moocp offen ist. Dürften Plugins geschlossen und nur gegen Bezahlung verbreitet werden, entstünde über die Plugin-Schnittstelle genau das, was der Wechsel weg von MIT verhindern soll: Die wertvollen Funktionen wanderten in geschlossene Plugins, und die offene App wäre nur noch deren Unterbau. Deshalb betrachten die Rechteinhaber ein Plugin und moocp als ein zusammengesetztes Werk im Sinne der AGPL.

## Folgen

- Ob ein eigenständiges Programm, das nur über eine lokale Schnittstelle mit moocp spricht, rechtlich ein abgeleitetes Werk ist, ist nicht geklärt. Die Regel für Plugins ist die erklärte Auslegung der Rechteinhaber und steht in `LICENSE.md`; eine zusätzliche Beschränkung über die AGPL hinaus ist sie nicht und soll sie nicht sein. Die App prüft die Lizenz eines Plugins nicht.
- Kostenpflichtige Plugins sind möglich, geschlossene nicht: Wer ein Plugin verkauft, gibt den Quelltext unter einer verträglichen Lizenz mit.
- Der Windows-Installer und die Linux-Pakete zeigen die Lizenz zur Kenntnis; zum Benutzen verlangt die AGPL keine Zustimmung.
- Der NSIS-Installer (zlib-Lizenz) und die VC++-Laufzeit (Systembibliothek) vertragen sich mit der AGPL.

## Verworfen

MIT beibehalten: erlaubt geschlossene Ableger der App.

Eine Lizenz, die kommerzielle Nutzung verbietet (PolyForm Noncommercial, CC BY-NC): Sie wäre keine Open-Source-Lizenz, die Grenze von „kommerziell“ ist schon bei Schulträgern und Fortbildungsanbietern unscharf, und Unterstützung gegen Bezahlung soll möglich bleiben.

Plugins unter beliebiger Lizenz, mit dem Beispiel-Plugin unter MIT als Vorlage: Das ließe geschlossene, kostenpflichtige Plugins zu.
