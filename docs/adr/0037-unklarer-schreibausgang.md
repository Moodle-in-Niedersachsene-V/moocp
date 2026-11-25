# E37 Unklaren Schreibausgang klären

Status: gilt. Ergänzt [E17](0017-moodle-ist-massgeblich.md).

## Entscheidung

Vor dem Absenden einer Änderung hält die App Ziel, Ausgangsstand und erwarteten Zielstand als Prüfsummen in einem dauerhaften Vorgang fest. Zugangsdaten, Formularwerte und Dateiinhalte stehen nicht darin. Die Ablage gehört zur Instanz und zum Zielobjekt, unabhängig vom Namen des Profils und vom Arbeitsordner. Jeder Schreibvorgang hat eine eigene Nummer; spätere Vorgänge ersetzen weder seine Nummer noch seinen Status. Die Objektsperre verweist auf den aktuellen Vorgang.

Ein Abbruch beim Absenden oder Rücklesen ohne Antwort bedeutet „Ausgang unklar“. Solange der Vorgang offen ist, sendet die App keine weitere Änderung an dasselbe Objekt. Ein lesender Folgeaufruf vergleicht den aktuellen Stand mit Ausgangs- und Zielstand. Nur ein eindeutig bestätigter, vom Ausgangsstand verschiedener Zielstand schließt den Vorgang ab. Der unveränderte Ausgangsstand erlaubt keine Wiederholung: Moodle könnte den ursprünglichen Auftrag noch verarbeiten. Abweichungen und nicht prüfbare Ziele bleiben gesperrt. Die App wiederholt keinen POST automatisch nach einem Transportfehler.

Nicht jeder Fehler ist ein unklarer Ausgang. Lehnt Moodle das Formular mit einer Antwort ab (Prüffehler im Formular, 403 von Moodle oder einem Filter davor, Schutzdienst, abgelaufene Sitzung) oder hat die App die Anfrage gar nicht gesendet (Sperrliste, nicht angemeldet), steht fest, dass nichts gespeichert ist: Der Vorgang ist „nicht gespeichert“ und sperrt nicht. Findet die Rückleseprobe nach einem angenommenen Formular Abweichungen, kennt die App den Stand in Moodle: Der Vorgang ist „zurückgelesen“, sperrt nicht, und vor der nächsten Änderung wird ohnehin frisch gelesen (E17). Eine Antwort ab HTTP 500 bleibt unklar, weil der Server vorher gespeichert haben kann.

Ein Ausweg aus einer echten Sperre ist die Entscheidung der Lehrkraft, nie der KI: `aendern_status` mit `sperre_aufheben` fragt sie in der App, auf jeder Stufe (`ab: keine`), mit dem Befund des lesenden Vergleichs, mit ausdrücklichem Abhaken, dass sie in Moodle nachgesehen hat. Das ist der Weg, wenn die Anfrage nie ankam, die Lehrkraft das Objekt von Hand in Ordnung gebracht hat oder der Stand nicht prüfbar ist (Fragen). Die Frage räumt ein, dass eine noch laufende Anfrage später oder doppelt wirken kann; das Aufheben bestätigt nichts und meldet `verified: false`. Abgeschlossene Vorgänge löscht die App nach 30 Tagen und beim Löschen des Profils ihrer Instanz; offene bleiben, weil sie sperren.

Alternativ öffnet die Lehrkraft in den Einstellungen „Offene Sperren ansehen …“. Auch dort verlangt das Aufheben einen Mausklick nach Wartezeit und das ausdrückliche Abhaken, dass sie in Moodle nachgesehen hat. Das Aufheben steht im Protokoll, bestätigt keinen Speichererfolg und verlangt danach frisches Lesen. Eine Chat-Antwort allein hebt keine Sperre auf.

## Verworfen

Ein höheres Zeitlimit oder eine automatische Wiederholung ersetzt keinen Zustandsnachweis und könnte einen bereits ausgeführten Vorgang doppelt ausführen. Eine Sperre nur im Arbeitsordner ginge beim erneuten Lesen oder Neustarten verloren. Eine Sperre ohne Ausweg (jeder Fehler nach dem Beginn des Vorgangs) sperrte Objekte nach gewöhnlichen Prüffehlern auf Dauer. Ein Zeitablauf, der die Sperre von selbst löst, wäre ein Nachweis ohne Nachweis: Moodle könnte den Auftrag danach noch ausführen.
