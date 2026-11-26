// Das Schreiben in eine Pipe unter Windows (kanal_windows.dart), ohne
// Windows-Aufrufe, damit es sich mit einer gespielten Gegenseite prüfen lässt.
//
// Ohne Ende zu warten wäre falsch: Eine Gegenseite desselben Kontos, die nie
// liest, hielte sonst das Handle und die beiden Isolate der Verbindung für
// immer fest, denn der Schreiber käme nie dazu, das Ende der Verbindung zu
// bemerken. Darum gilt für jeden Anlauf eine Frist; läuft sie ab, bricht das
// Schreiben ab (CancelIoEx), holt den Abbruch ab und gibt auf.

/// Wie ein überlappendes Schreiben angelaufen ist.
enum SchreibStart {
  /// Schon fertig; [schreibenMitFrist] holt die Zahl der Bytes über `ergebnis`.
  fertig,

  /// Läuft noch: Warten, bis das Ereignis kommt.
  ausstehend,

  /// Der Aufruf selbst ist gescheitert (Pipe geschlossen o. Ä.).
  fehler,
}

enum SchreibUrteil {
  /// Alles geschrieben.
  fertig,

  /// Die Gegenseite hat in der Frist nichts abgenommen; abgebrochen.
  frist,

  /// Ein Fehler der Pipe: Die Verbindung ist nicht mehr zu gebrauchen.
  fehler,
}

/// Schreibt [laenge] Bytes in Stücken, so viel die Gegenseite annimmt.
///
/// [beginnen] startet das Schreiben des Rests ab `offen` Bytes; [warten]
/// wartet höchstens [frist] auf sein Ereignis und sagt, ob es kam; [ergebnis]
/// holt die Zahl der geschriebenen Bytes (null bei einem Fehler oder nach
/// einem Abbruch) und wartet dabei, bis der Vorgang wirklich vorbei ist;
/// [abbrechen] bricht den laufenden Vorgang ab.
SchreibUrteil schreibenMitFrist({
  required int laenge,
  required Duration frist,
  required SchreibStart Function(int offen) beginnen,
  required bool Function(Duration frist) warten,
  required int? Function() ergebnis,
  required void Function() abbrechen,
}) {
  var offen = 0;
  while (offen < laenge) {
    final start = beginnen(offen);
    if (start == SchreibStart.fehler) return SchreibUrteil.fehler;
    if (start == SchreibStart.ausstehend && !warten(frist)) {
      abbrechen();
      // Erst abholen, wenn der Abbruch durch ist: Das Ereignis und der
      // OVERLAPPED-Block gehören dem Vorgang, bis er zu Ende ist.
      ergebnis();
      return SchreibUrteil.frist;
    }
    final n = ergebnis();
    if (n == null || n <= 0) return SchreibUrteil.fehler;
    offen += n;
  }
  return SchreibUrteil.fertig;
}
