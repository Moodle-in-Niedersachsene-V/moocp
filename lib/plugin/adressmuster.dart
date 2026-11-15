// Adressmuster der Zusatzadressen eines Plugins (E36) und die Bereiche der
// Moodle-Instanz, die für jedes Plugin gesperrt bleiben.
//
// Ein Muster ist ein Pfad, der mit „/" beginnt, mit „*" als einzigem
// Platzhalter (beliebige Zeichen, auch „/" und nichts). Es ist kein regulärer
// Ausdruck und sagt nichts über Parameter. Gegen ein Muster gehalten wird der
// NORMALISIERTE Pfad einer Anfrage ([pfadNormalisieren]): ohne
// Prozentkodierung, „//", „.", „..". Wer ein Muster mit einer Adresse
// vergleicht, muss sie vorher so normalisieren; sonst käme „/mod/../admin/x"
// an einem Muster „/mod/*" vorbei in den Adminbereich.
//
// Die Sperre prüft hier nicht Adressen, sondern Muster: Ein Muster, das einen
// gesperrten Bereich treffen KANN, hält das Plugin vom Laden ab
// ([sperrbereichBeruehrt]). Das ist strenger als nötig und mit Absicht so:
// „/*" oder „/a*" sind Freibriefe, auch wenn sie „nur" Pfade nennen.

/// Ein Bereich der Moodle-Instanz, den kein Plugin erreicht: Adminbereich,
/// Anmeldung und alle Seiten, die Zugangsdaten betreffen (E36). Die Liste ist
/// kurz und fest; sie gilt vor jeder Zusatzadresse.
class Sperrbereich {
  const Sperrbereich(this.name, this.pfad);

  /// Der Name für die Meldung an die Lehrkraft.
  final String name;

  /// Der Pfad in Kleinbuchstaben. Mit „/" am Ende ein Verzeichnis, dessen
  /// ganzer Inhalt und dessen Name selbst („/admin") gesperrt sind; ohne eine
  /// einzelne Seite samt allem, was dahinter steht (Pfadzusatz).
  final String pfad;

  bool get verzeichnis => pfad.endsWith('/');

  /// Der Name des Verzeichnisses ohne „/" am Ende: Auch die Adresse „/admin"
  /// führt (über eine Umleitung) hinein.
  String get ohneSchluss => verzeichnis ? pfad.substring(0, pfad.length - 1) : pfad;
}

const List<Sperrbereich> sperrbereiche = [
  Sperrbereich('Adminbereich', '/admin/'),
  Sperrbereich('Anmeldung', '/login/'),
  Sperrbereich('Anmeldeverfahren', '/auth/'),
  Sperrbereich('Web-Services', '/webservice/'),
  Sperrbereich('Seite für Zugangsschlüssel', '/user/managetoken.php'),
];

class Adressmuster {
  const Adressmuster._(this.text);

  /// Das Muster, wie es in der Beschreibungsdatei steht.
  final String text;

  /// Prüft [text] und liefert das Muster; wirft [FormatException] mit dem
  /// Grund auf Deutsch. Der Grund nennt nie den Inhalt des Musters.
  factory Adressmuster.parsen(String text) {
    if (text.isEmpty) throw const FormatException('Das Muster ist leer.');
    final stufen = _stufen(text);
    if (stufen.any(_hatSteuerzeichen)) {
      throw const FormatException('Das Muster enthält ein Steuerzeichen.');
    }
    if (text.contains('?') || text.contains('#')) {
      throw const FormatException(
        'Ein Muster nennt nur den Pfad; Parameter („?“) und Anker („#“) gehören nicht hinein.',
      );
    }
    if (!text.startsWith('/')) {
      throw const FormatException(
        'Ein Muster beginnt mit „/“: Es nennt nur den Pfad, ohne Schema und Rechnernamen.',
      );
    }
    if (text.startsWith('//')) {
      throw const FormatException('Ein Muster nennt keinen Rechnernamen („//“ am Anfang).');
    }
    if (stufen.any((s) => s.contains('..'))) {
      throw const FormatException('Ein Muster enthält „..“.');
    }
    return Adressmuster._(text);
  }

  /// Ob der (normalisierte, [pfadNormalisieren]) Pfad zum Muster passt. Groß-
  /// und Kleinschreibung zählt: Moodle-Server unterscheiden sie meist, und ein
  /// Muster, das zu viel träfe, wäre das größere Übel.
  bool passt(String pfad) => _gleitend(text, pfad);

  @override
  String toString() => text;
}

/// Der gesperrte Bereich, den [muster] treffen kann; null, wenn keiner. Ein
/// Muster trifft einen Bereich, wenn irgendein Pfad in ihm zum Muster passt.
/// Dazu wird das Muster so gelesen, wie es ein Server läse: Prozentkodierung
/// aufgelöst (auch doppelte), „\" als „/", „//" und „.“ gefaltet, Groß- und
/// Kleinschreibung gleichgesetzt.
Sperrbereich? sperrbereichBeruehrt(Adressmuster muster) {
  for (final stufe in _stufen(muster.text)) {
    final p = _falten(stufe).toLowerCase();
    for (final bereich in sperrbereiche) {
      if (_kannBeginnenMit(p, bereich.pfad)) return bereich;
      if (bereich.verzeichnis && _gleitend(p, bereich.ohneSchluss)) return bereich;
    }
  }
  return null;
}

/// Der gesperrte Bereich, in dem die Adresse liegt; null, wenn keiner. Der
/// Pfad wird vorher normalisiert und kleingeschrieben.
Sperrbereich? sperrbereichDerAdresse(String pfad) {
  final p = pfadNormalisieren(pfad).toLowerCase();
  for (final bereich in sperrbereiche) {
    if (p.startsWith(bereich.pfad)) return bereich;
    if (bereich.verzeichnis && p == bereich.ohneSchluss) return bereich;
  }
  return null;
}

/// Der Pfad einer Adresse, wie ein Server ihn verstünde: Prozentkodierung
/// aufgelöst (so oft, bis nichts mehr zu lösen ist), „\" als „/", doppelte
/// Schrägstriche und „." entfernt, „.." aufgelöst (nie über die Wurzel
/// hinaus). Ein „/" am Ende bleibt.
String pfadNormalisieren(String pfad) => _falten(_stufen(pfad).last);

/// Der Text mit aufgelöster Prozentkodierung, so oft, bis nichts mehr zu
/// lösen ist (wie in [pfadNormalisieren]), sonst unverändert.
String prozentAufgeloest(String text) => _stufen(text).last;

/// Der Text nach jeder Runde Prozentdekodierung, der erste unverändert. Eine
/// Kodierung wird mehrfach aufgelöst, weil „%252e" nach der ersten Runde
/// „%2e" und nach der zweiten „." ist; ein Muster, das dahinter etwas
/// versteckt, soll nicht vorbeikommen.
List<String> _stufen(String text) {
  final ergebnis = [text];
  for (var i = 0; i < 5; i++) {
    final neu = ergebnis.last.replaceAllMapped(
      RegExp('%([0-9a-fA-F]{2})'),
      (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
    );
    if (neu == ergebnis.last) break;
    ergebnis.add(neu);
  }
  return ergebnis;
}

bool _hatSteuerzeichen(String s) => s.codeUnits.any((c) => c < 0x20 || c == 0x7f);

/// „\" als „/", doppelte Schrägstriche und „." entfernen, „.." auflösen.
/// „*" ist hier ein gewöhnliches Zeichen, damit sich auch Muster falten lassen.
String _falten(String pfad) {
  final segmente = <String>[];
  for (final s in pfad.replaceAll(r'\', '/').split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (segmente.isNotEmpty) segmente.removeLast();
      continue;
    }
    segmente.add(s);
  }
  final ende = pfad.endsWith('/') || pfad.endsWith(r'\') || pfad.endsWith('/.') || pfad.endsWith('/..');
  final ergebnis = '/${segmente.join('/')}';
  return ende && segmente.isNotEmpty ? '$ergebnis/' : ergebnis;
}

/// Ob ein Pfad, der mit [anfang] beginnt, zum Muster [p] passen kann. [p]
/// bestimmt den Anfang des Pfads Zeichen für Zeichen, bis ein „*" kommt: Von
/// da an kann es alles liefern, auch den Rest von [anfang].
bool _kannBeginnenMit(String p, String anfang) {
  for (var i = 0; i < anfang.length; i++) {
    if (i >= p.length) return false;
    if (p[i] == '*') return true;
    if (p[i] != anfang[i]) return false;
  }
  return true;
}

/// Der Abgleich von Muster und Text mit „*" als einzigem Platzhalter. Er merkt
/// sich nur den letzten Stern und dehnt ihn bei einem Fehlschlag aus, statt
/// alle Möglichkeiten durchzuprobieren; so braucht er höchstens Länge des
/// Musters mal Länge des Textes Schritte, auch bei Mustern mit vielen Sternen.
bool _gleitend(String muster, String text) {
  var m = 0;
  var t = 0;
  var stern = -1;
  var weiter = 0;
  while (t < text.length) {
    if (m < muster.length && muster[m] == '*') {
      stern = m++;
      weiter = t;
    } else if (m < muster.length && muster[m] == text[t]) {
      m++;
      t++;
    } else if (stern >= 0) {
      m = stern + 1;
      t = ++weiter;
    } else {
      return false;
    }
  }
  while (m < muster.length && muster[m] == '*') {
    m++;
  }
  return m == muster.length;
}
