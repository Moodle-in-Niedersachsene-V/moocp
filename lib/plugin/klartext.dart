// Text von einem Plugin als reiner Text: für Protokollzeilen und für alles,
// was ein Plugin in einem Dialog oder einer Freigabe zeigen lässt
// (app_adresse.dart, dialoge.dart). Ein Plugin bestimmt so keine Formatierung
// und fälscht keine Zeile: Steuerzeichen und Richtungszeichen fallen weg, die
// Länge ist begrenzt. Angezeigt wird das Ergebnis als schlichter Text, nie
// als Markdown, HTML oder Link.

/// Steuerzeichen außer Zeilenwechseln, die unsichtbaren Zeichen, die die
/// Schreibrichtung umstellen, und die Nullbreitenzeichen (U+200B–U+200D,
/// U+2060, U+FEFF): Mit ihnen ließe sich ein Text anders anzeigen, als er im
/// Protokoll steht, oder ein Wort unsichtbar teilen.
const _unsichtbar =
    '\\x00-\\x09\\x0b-\\x1f\\x7f-\\x9f\\u061c\\u200b-\\u200f\\u202a-\\u202e\\u2060\\u2066-\\u2069\\ufeff';

/// Die Nullbreitenzeichen aus [_unsichtbar].
const _nullbreite = '\\u200b-\\u200d\\u2060\\ufeff';

/// Zeilenwechsel in allen Schreibweisen außer `\n`.
final _zeilenwechsel = RegExp('\\r\\n|[\\r\\x0b\\x0c\\x85\\u2028\\u2029]');

/// Kürzt [t] auf höchstens [hoechstens] Zeichen; was abgeschnitten ist,
/// endet mit „…“.
String _gekuerzt(String t, int hoechstens) {
  final zeichen = t.runes.toList();
  if (zeichen.length <= hoechstens) return t;
  return '${String.fromCharCodes(zeichen.take(hoechstens - 1))}…';
}

/// Bringt einen Text von außen auf eine Zeile: Steuerzeichen, Zeilen- und
/// Absatztrenner und Richtungszeichen werden zu Leerzeichen, Leerraum fällt
/// zusammen, und was über [hoechstens] Zeichen hinausgeht, endet mit „…“. So
/// fälscht ein Plugin keine Zeile im Protokoll.
String einzeilig(String text, int hoechstens) => _gekuerzt(
  text
      // Nullbreitenzeichen fallen ganz weg, statt ein Wort zu trennen.
      .replaceAll(RegExp('[$_nullbreite]'), '')
      .replaceAll(RegExp('[$_unsichtbar\\n\\u2028\\u2029]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim(),
  hoechstens,
);

/// Ein mehrzeiliger Text von außen: Zeilenwechsel bleiben (einheitlich als
/// `\n`, höchstens eine Leerzeile in Folge), Tabulatoren werden zu
/// Leerzeichen, andere Steuerzeichen und Richtungszeichen fallen weg, und was
/// über [hoechstens] Zeichen hinausgeht, endet mit „…“.
String mehrzeilig(String text, int hoechstens) => _gekuerzt(
  text
      .replaceAll(_zeilenwechsel, '\n')
      .replaceAll('\t', ' ')
      .replaceAll(RegExp('[$_unsichtbar]'), '')
      .replaceAll(RegExp(r'[ ]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim(),
  hoechstens,
);
