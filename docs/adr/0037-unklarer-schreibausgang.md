# E37 Unklaren Schreibausgang klären

Status: gilt. Ergänzt [E17](0017-moodle-ist-massgeblich.md).

## Entscheidung

Vor dem Absenden einer Änderung hält die App Ziel, Ausgangsstand und erwarteten
Zielstand als Prüfsummen in einem dauerhaften Vorgang fest. Zugangsdaten,
Formularwerte und Dateiinhalte stehen nicht darin. Die Ablage gehört zur Instanz
und zum Zielobjekt, unabhängig vom Namen des Profils und vom Arbeitsordner.
Jeder Schreibvorgang hat eine eigene Nummer; spätere Vorgänge ersetzen weder
seine Nummer noch seinen Status. Die Objektsperre verweist auf den aktuellen Vorgang.

Ein Abbruch beim Absenden oder Rücklesen bedeutet „Ausgang unklar“. Solange der
Vorgang offen ist, sendet die App keine weitere Änderung an dasselbe Objekt.
Ein lesender Folgeaufruf vergleicht den aktuellen Stand mit Ausgangs- und
Zielstand. Nur ein eindeutig bestätigter, vom Ausgangsstand verschiedener
Zielstand schließt den Vorgang ab. Der unveränderte Ausgangsstand erlaubt keine
Wiederholung: Moodle könnte den ursprünglichen Auftrag noch verarbeiten.
Abweichungen und nicht prüfbare Ziele bleiben gesperrt. Die App wiederholt
keinen POST automatisch nach einem Transportfehler.

Eine Sperre, die sich nicht klärt, kann die Lehrkraft in der App aufheben: mit
der Maus und mit Wartezeit wie bei einer Freigabe (E4), nie über MCP. Die nächste
Änderung beginnt danach mit frischem Lesen (E17); die Aufhebung steht im Protokoll.

## Verworfen

Ein höheres Zeitlimit oder eine automatische Wiederholung ersetzt keinen
Zustandsnachweis und könnte einen bereits ausgeführten Vorgang doppelt ausführen.
Eine Sperre nur im Arbeitsordner ginge beim erneuten Lesen oder Neustarten verloren.
Eine Sperre ohne Ausweg ließe die Lehrkraft machtlos vor einem Objekt, das sie
selbst schon geprüft hat. Das Aufheben im Chat ist verworfen: Die KI könnte das Ja
selbst geben.
