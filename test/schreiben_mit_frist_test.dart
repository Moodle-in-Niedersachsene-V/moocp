// Das Schreiben in die Pipe unter Windows (mcp/kanal_windows.dart) wartet auf
// eine Gegenseite, die nie liest, nicht ewig: Die Logik dazu steht ohne
// Windows-Aufrufe in mcp/schreiben_mit_frist.dart, hier mit einer gespielten
// Gegenseite.
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/mcp/schreiben_mit_frist.dart';

/// Eine Pipe, die [schreibt] Bytes je Aufruf annimmt: sofort, nach dem Warten
/// oder gar nicht (dann hält der Aufruf an, bis die Frist abläuft).
class _Pipe {
  _Pipe({this.proAufruf = 1 << 30, this.haengt = false, this.startFehler = false, this.ergebnisFehler = false});

  final int proAufruf;
  final bool haengt;
  final bool startFehler;
  final bool ergebnisFehler;
  int laenge = 0;
  int geschrieben = 0;
  int abgebrochen = 0;
  int ergebnisse = 0;
  final fristen = <Duration>[];
  int _ausstehend = 0;

  int _naechster(int offen) => laenge - offen < proAufruf ? laenge - offen : proAufruf;

  SchreibStart beginnen(int offen) {
    if (startFehler) return SchreibStart.fehler;
    if (haengt) return SchreibStart.ausstehend;
    _ausstehend = _naechster(offen);
    return SchreibStart.ausstehend;
  }

  bool warten(Duration frist) {
    fristen.add(frist);
    return !haengt;
  }

  int? ergebnis() {
    ergebnisse++;
    if (haengt) return null; // nach dem Abbruch: abgebrochen, nichts geschrieben
    if (ergebnisFehler) return null;
    geschrieben += _ausstehend;
    return _ausstehend;
  }

  void abbrechen() => abgebrochen++;
}

void main() {
  const frist = Duration(seconds: 5);

  SchreibUrteil schreiben(_Pipe p, int laenge) {
    p.laenge = laenge;
    return schreibenMitFrist(
      laenge: laenge,
      frist: frist,
      beginnen: p.beginnen,
      warten: p.warten,
      ergebnis: p.ergebnis,
      abbrechen: p.abbrechen,
    );
  }

  test('eine Gegenseite, die liest: alles geschrieben, nichts abgebrochen', () {
    final p = _Pipe();
    expect(schreiben(p, 1000), SchreibUrteil.fertig);
    expect(p.geschrieben, 1000);
    expect(p.abgebrochen, 0);
  });

  test('Teilstücke werden fortgesetzt, bis alles geschrieben ist', () {
    final p = _Pipe(proAufruf: 300);
    expect(schreiben(p, 1000), SchreibUrteil.fertig);
    expect(p.geschrieben, 1000);
    expect(p.fristen, everyElement(frist), reason: 'jeder Anlauf wartet höchstens die Frist');
  });

  test('eine Gegenseite, die nie liest: nach der Frist abgebrochen und aufgegeben', () {
    final p = _Pipe(haengt: true);
    expect(schreiben(p, 1000), SchreibUrteil.frist);
    expect(p.abgebrochen, 1);
    expect(p.ergebnisse, 1, reason: 'der Abbruch wird abgeholt, bevor das Ereignis wieder benutzt wird');
    expect(p.geschrieben, 0);
  });

  test('ein Fehler beim Beginnen oder beim Abholen ist ein Fehler, keine Frist', () {
    expect(schreiben(_Pipe(startFehler: true), 10), SchreibUrteil.fehler);
    expect(schreiben(_Pipe(ergebnisFehler: true), 10), SchreibUrteil.fehler);
  });

  test('ein Anlauf ohne ein einziges Byte endet, statt ewig zu kreisen', () {
    final p = _Pipe(proAufruf: 0);
    expect(schreiben(p, 10), SchreibUrteil.fehler);
  });

  test('nichts zu schreiben: fertig, ohne die Pipe zu berühren', () {
    final p = _Pipe(haengt: true);
    expect(schreiben(p, 0), SchreibUrteil.fertig);
    expect(p.fristen, isEmpty);
  });
}
