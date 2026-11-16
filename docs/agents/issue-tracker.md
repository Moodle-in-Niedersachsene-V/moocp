# Issue-Tracker: GitHub

Verbindliche Ablage für offene Punkte, Specs und daraus abgeleitete Umsetzungstickets sind die GitHub-Issues dieses Repositories.

## Zuweisung vor der Arbeit

Wer an einem Issue arbeitet, dem ist es zugewiesen; die Regel mit ihren drei Fällen steht am Anfang der [CLAUDE.md](../../CLAUDE.md) und geht allem hier vor. Abfragen: `gh issue view <Nr> --json assignees`; sich zuweisen: `gh issue edit <Nr> --add-assignee @me`. Ist die Arbeit fertig oder wird sie abgegeben, die Zuweisung wieder lösen (`--remove-assignee @me`), wenn das Issue offen bleibt.

## Offene Punkte

- Ein neuer offener Punkt (fehlende Funktion, Fehler, Aufgabe außerhalb des Codes, eine Lücke nach A6) wird als GitHub-Issue angelegt, nach Rückfrage bei der Lehrkraft.
- Messergebnisse und Befunde stehen als Kommentar am Quelltext oder in der ADR, nicht als Bericht im Issue.

## Specs veröffentlichen und pflegen

- `/to-spec` veröffentlicht die vollständige Spezifikation als GitHub-Issue. Das Issue ist maßgeblich; Änderungen werden dort nachgeführt.
- Fachlich geklärte, für die Umsetzung vorbereitete Specs erhalten `ready-for-agent`. Weitere Triage ist dafür nicht erforderlich.
- Lokale Markdown-Dateien sind höchstens vorläufige Entwürfe, keine alternative Spec-Ablage. Nach erfolgreicher Veröffentlichung werden sie entfernt oder durch einen Verweis auf das Issue ersetzt.
- Glossar, ADRs, technische Messungen und Begleitdokumentation bleiben im Repository. Sie ersetzen das Spec-Issue nicht.

## Umsetzungstickets

- `/to-tickets` legt die aus einer Spec abgeleiteten Tickets ebenfalls als GitHub-Issues an und verknüpft sie mit der Spec.
- Abhängigkeiten werden als native GitHub-Issue-Abhängigkeiten erfasst. Wenn diese nicht verfügbar sind, werden die blockierenden Issues ausdrücklich im Ticket verlinkt.

## Pull Requests in der Triage

**PRs as a request surface: no.** Pull Requests laufen nicht durch die Triage; `/triage` liest diesen Schalter.

## Zugriff und Fehler

- GitHub-Connector oder `gh` mit explizitem Repository (`-R <Eigentümer>/moocp`) verwenden. Für mehrzeilige Inhalte strukturierte Argumente oder `--body-file` verwenden. Issues anlegen, kommentieren oder schließen nur nach Rückfrage; die Git-Regel des Projekts steht in der CLAUDE.md (Kopfzeile Git).
- Nach einer Veröffentlichung Issue-URL und Label prüfen und der Lehrkraft nennen. Bei unklarem Ausgang vor einem erneuten Erstellen nach dem Issue suchen.
- Ist die Veröffentlichung blockiert, den konkreten Fehler melden und den Entwurf bis zur Klärung erhalten. Einen lokalen Entwurf nicht als veröffentlicht oder als eingerichteten lokalen Tracker ausgeben.
- Deaktivierte Issues oder fehlende Berechtigungen rechtfertigen keinen stillen Wechsel zu einem anderen Tracker.

Labels und Triage: [triage-labels.md](triage-labels.md).
