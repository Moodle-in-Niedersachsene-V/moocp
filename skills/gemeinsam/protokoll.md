## Was geschrieben wurde: das Protokoll der App

Der Plan ist gezeigt und bestätigt (Abschnitt davor). Was dann geschieht,
hält die App selbst fest: jeden Werkzeugaufruf, jede Anfrage an Moodle, jede
Freigabe — im Fenster der App und in `%APPDATA%\moocp\protokoll.log`.
Du musst nichts nachmelden.

Fragt der Nutzer, was zuletzt geschah — beim Aufräumen, beim Weiterarbeiten
am nächsten Tag, wenn etwas schiefgegangen ist —, ist die Protokolldatei die
erste Quelle. Sie enthält Adressen, Nummern und Namen von Kursinhalten, keine
Personendaten und keine Zugangsdaten.

**Es macht nichts rückgängig.** Es beantwortet nur „was wurde hier angefasst". Jede Antwort eines schreibenden Werkzeugs nennt ohnehin, was angelegt oder geändert wurde, mit Nummer und Rückleseprobe (`verified`) — diese Nummern gehören in deine Antwort an den Nutzer.

**Die Rückleseprobe ersetzt dein eigenes Nachlesen.** Das Werkzeug hat schon aus Moodle zurückgelesen und mit dem verglichen, was es schreiben sollte. `verified: true` heißt: angekommen. Lies dann nicht noch einmal, um zu prüfen. Ein gelesener Ordner zeigt nach dem Schreiben schon den neuen Stand, und die nächste Änderung baut auf ihm auf. Neu lesen musst du nur, wenn das Werkzeug es verlangt, wenn die Antwort etwas als „nicht geprüft" nennt, auf das es ankommt, oder wenn du sehen willst, wie es aussieht (`bildschirmfoto`). Bei `verified: false` nennt die Antwort, was abweicht.

Meldet `aendern` „Ausgang unklar“, kann Moodle bereits gespeichert haben.
Frage mit `aendern_status` und der genannten Vorgangsnummer lesend nach;
wiederhole den Schreibauftrag nicht. Auch ein noch unveränderter Ausgangsstand
gibt keine Wiederholung frei, denn Moodle könnte den Auftrag noch verarbeiten.
Ein erneutes Lesen oder Neustarten der App hebt diese Sperre nicht auf.
Hat die Lehrkraft in Moodle nachgesehen und will das Objekt wieder ändern
lassen (die Anfrage kam nie an, sie hat es von Hand in Ordnung gebracht, oder
bei einer Frage ist der Stand nicht prüfbar), ruf `aendern_status` mit
`sperre_aufheben` auf: Die App fragt dann die Lehrkraft, du entscheidest es
nicht und bietest es nie von dir aus an. Lehnt Moodle ein Formular nur ab oder
weicht der zurückgelesene Stand ab, gibt es keine Sperre; lies frisch und plane
neu.
