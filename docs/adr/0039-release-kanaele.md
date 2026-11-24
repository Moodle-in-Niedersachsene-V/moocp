# E39 Release-Kanäle: stabil und Nightly

Status: gilt. Die Regeln dazu stehen im Index der [CLAUDE.md](../../CLAUDE.md). Ergänzt E12 (wie eine Version entsteht), E19 (Update-Prüfung) und E24 (Plattformen); wie Maintainer zusammenarbeiten, steht in [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Entscheidung

Es gibt zwei Kanäle: **Stabil** und **Nightly**. Wer Neues früh ausprobieren will, wählt in der App „Testversionen (Nightly)“; alle anderen bleiben auf „Stabil“. Damit tragen die Tester die Prüfung im Betrieb, und die Maintainer können ausliefern, ohne einander bei jedem Pull Request aufzuhalten. Die Sorgfalt geht dabei nicht verloren, sie liegt an anderer Stelle: im Review nach dem Merge, in der Schranke vor jeder stabilen Version und in den Pfaden, die immer vor dem Merge geprüft werden.

### Woher eine Nightly kommt

Eine Nightly ist ein Stand von `main`. Gebaut und veröffentlicht wird sie von GitHub Actions, einmal täglich, wenn `main` seit der letzten Nightly einen neuen Commit hat, und jederzeit von Hand durch einen Maintainer – so kommt eine Korrektur, die schon getestet ist, ohne Warten zu den Testern. Einen eigenen Zweig für Nightlies gibt es nicht.

Der Tag heißt `v<kommende Version>-nightly.<JJJJMMTT>.<n>`, etwa `v0.13.0-nightly.20261120.1`; das Release ist bei GitHub als Vorabversion markiert. Die kommende Version ist die, die in `pubspec.yaml` auf `main` steht, und sie ist immer die nächste **Nebenversion** (0.13.0 nach 0.12.0): Die Fehlerversionen (0.12.**1**) bleiben den Hotfixes vorbehalten. Für den Vergleich gilt `0.13.0-nightly.…` < `0.13.0`: Wer eine Nightly hat, bekommt die stabile Version derselben Nummer als Update. Als Text des Releases trägt die Nightly den Abschnitt der kommenden Version aus `CHANGELOG.md`, wie er auf diesem Stand steht; die Lehrkraft sieht deutsche Zeilen, keine englischen Titel von Pull Requests.

### Wie eine Nightly stabil wird

Ein Maintainer wählt eine veröffentlichte Nightly – nicht zwingend die letzte – und startet in GitHub Actions die stabile Version aus genau ihrem Commit. Gebaut wird also nur, was Tester schon in der Hand hatten, und `main` arbeitet daneben weiter. Die Schranke:

- die Nightly ist mindestens 14 Tage veröffentlicht (bei zwei Maintainern und in den Ferien kommt in kürzerer Zeit zu wenig Rückmeldung);
- kein offenes Issue mit den Labels `nightly` und `bug` betrifft diese oder eine frühere Nightly;
- jeder Pull Request bis zu diesem Commit trägt das Label `post-reviewed`;
- der andere Maintainer bestätigt im GitHub-Environment `stable`, dass er die Nightly selbst lange genug benutzt hat.

Danach wird die Version Tag `v<Version>` und Release wie in E12, und `main` springt auf die nächste Nebenversion; was nach dem gewählten Commit gemergt wurde, gehört zu ihr.

### Reviews: Ship, Show, Ask

Jeder Pull Request gehört zu einer von drei Arten (nach Rouan Wilsenach, „Ship / Show / Ask“):

- **Show** (Vorgabe): Wer ihn gestellt hat, merged selbst, sobald `flutter analyze` und `flutter test` grün sind; der andere Maintainer reviewt danach und setzt `post-reviewed`. Was er findet, wird ein Folge-Issue oder ein Folge-PR.
- **Ask**: Der Pull Request wartet auf das Review des anderen. Pflicht für die Pfade in `.github/CODEOWNERS` (Sperrliste und Positivliste, Elemente, Freigabe, Anmeldung und Anmeldedaten, Update und Installer, CLAUDE.md, AGENTS.md, ADRs), für jeden Hotfix und für jede Änderung an diesen Regeln.
- **Ship**: Tippfehler und reine Textkorrekturen, kein Review.

Ein Issue, ein Pull Request: Kleine Pull Requests lassen sich nach dem Merge einzeln ansehen, ein großer Sammel-PR macht daraus das Riesen-Review, das diese Regel vermeiden soll. Ein KI-Review läuft an jedem Pull Request mit; was davon übernommen wird, entscheidet ein Mensch. Datenschutz und Freigaben (A1, A3) sind in jeder Nightly so geschützt wie in einer stabilen Version, weil ihre Pfade immer „Ask“ sind.

### Hotfix: einen Fehler der stabilen Version beheben

Wird in der stabilen Version ein Fehler gefunden, während auf `main` schon Neues liegt, soll die Korrektur zu den Nutzern, ohne das Neue mitzunehmen. Dafür entsteht ein Release-Zweig, und zwar erst, wenn er gebraucht wird:

```
main           A ── B ── C ── F′ ── D     F′ = die Korrektur, zuerst hier
               │
               └── Tag v0.13.0
release/0.13   A ── F                     F = F′ per Cherry-Pick → Tag v0.13.1
```

1. Die Korrektur kommt wie jede Änderung per Pull Request nach `main` (F′), also auch in die nächste Nightly.
2. Aus dem Tag der stabilen Version entsteht `release/0.13`. Ein Cherry-Pick übernimmt genau den Commit der Korrektur auf diesen Zweig, sonst nichts von `main`; weil eine Korrektur klein ist, gibt es dabei selten Konflikte. Dieser Pull Request ist „Ask“.
3. Auf den Stand des Zweigs kommt der Tag `v0.13.1`, und daraus entsteht das Release wie bei jeder stabilen Version, ohne Wartezeit.

Stabile Nutzer bekommen 0.13.1; Nightly-Nutzer (0.14.0-nightly…) haben die Korrektur schon und bekommen es nicht angeboten. Ein Release-Zweig wird nie nach `main` gemergt und bleibt stehen; der nächste Hotfix derselben Version setzt dort fort.

### In der App

Die Einstellung „Update-Kanal“ steht bei der Update-Prüfung, voreingestellt „Stabil“; sie gilt für die ganze App, nicht je Instanzprofil, und nur für moocp, nicht für Plugins (deren Update-Quellen liefern weiter nur stabile Releases, E35). Wer auf Nightly wechselt, sieht einmal einen Hinweis: Nightlies können deutlich mehr Fehler enthalten, weil sie deutlich weniger geprüft sind; Datenschutz und Freigaben gelten unverändert; so geht es zurück. Im Kanal Nightly zählt die höchste Version aus stabilen Releases und Nightlies, im Kanal Stabil nur stabile Releases. Die Adressen prüft dieselbe Positivliste wie bisher (E19).

Die Rückkehr zur stabilen Version geht jederzeit, auch wenn sie eine kleinere Nummer hat: Wer arbeiten muss, darf nicht an einer kaputten Nightly hängen. Dafür liest jede Version Einstellungen und gespeicherte Daten, die sie nicht kennt, ohne Fehler und lässt sie stehen, statt sie beim Speichern zu verwerfen. Eine neue Funktion bringt ohnehin neue Einträge und ändert keine alten; ändert eine Nightly doch ein Format so, dass die letzte stabile Version es nicht lesen kann, sagt die App vor der Rückkehr, was danach nicht mehr geht und wie es sich beheben lässt. Das ist die Ausnahme und ein Pflichtpunkt im Review.

Gesucht wird stündlich im Hintergrund, solange die App läuft, mit bedingten Anfragen (ETag), damit viele Rechner hinter einer IP-Adresse eines Schulnetzes nicht an die Grenze der GitHub-API stoßen; ohne das Ja zum Nachsehen weiter keine Anfrage (E19). Wer dem täglichen Nachsehen zugestimmt hat, wird einmal mit dem neuen Text gefragt; bis zur Antwort bleibt es bei täglich. Eine neue Version zeigt ein Pfeil in der Titelzeile, kein Dialog, der sich vordrängt; ein Klick zeigt die Neuerungen und „Installieren“. Installiert wird nur nach diesem Klick, nie ungefragt; nach dem Neustart sagt die App einmal, auf welche Version sie aktualisiert wurde.

Wo sich die App selbst ersetzen kann (Windows, künftig der Installer je Benutzer und das AppImage unter Linux), installiert „Installieren“ die Version; sonst öffnet es das Paket im Browser (E19). Auf dem Mac bleibt es dabei, bis die App signiert und beglaubigt ist.

Probleme mit einer Nightly melden Tester über die Issue-Vorlage „Problem in einer Nightly“ mit der genauen Version; sie trägt das Label `nightly`.

## Verworfen

- **Ein eigener Zweig `nightly` neben `main`:** Er läuft auseinander, Korrekturen müssten in beide Richtungen, und der Pull Request von `nightly` nach `main` wäre bei jeder Version ein Riesen-Review über alles, was Tester ohnehin schon hatten.
- **Pflicht-Review vor jedem Merge, wie bisher:** Zwei Maintainer halten sich gegenseitig auf, und wer warten muss, sammelt mehrere Issues in einem großen Pull Request – das Gegenteil dessen, was ein Review leisten kann.
- **Gar kein Review mehr, nur Tester:** Tester finden Fehler im Verhalten, nicht nachlassende Qualität im Code; ohne zweiten Blick zerfiele der Code nach und nach.
- **Ein Review des ganzen Unterschieds vor jeder stabilen Version:** bei einigen hunderttausend Zeichen nicht in vertretbarer Zeit zu leisten; die Schranke verlangt stattdessen, dass jeder kleine Pull Request schon reviewt ist.
- **Ein eigener Hotfix-Kanal:** Eine Korrektur für Nightly-Nutzer ist eine Nightly von Hand, eine für stabile Nutzer eine Fehlerversion aus dem Release-Zweig; ein dritter Kanal brächte nichts.
- **Die stabile Version immer aus der letzten Nightly:** Dann dürfte bis zur Veröffentlichung nichts Neues nach `main`.
- **Rückkehr nur, bis die stabile Version die Nightly überholt:** Wer in einer kaputten Nightly arbeiten muss, wäre bis dahin aufgeschmissen.
- **Automatisch installieren ohne Klick:** Wer eine Version ungefragt ausgetauscht bekommt, fühlt sich bevormundet, und eine laufende KI-Sitzung verlöre die App mitten im Auftrag.
- **Nightlies auch für Plugins:** Ein Plugin ist ein eigenes Projekt mit eigenen Releases; ob es einen Testkanal anbietet, wäre eine Erweiterung der Schnittstelle (E35).
