// Werkzeuge für die Prüfung einer Lernsituation (lernsituation_pruefung.dart):
// ein HTML-Leser, der Tags, Attribute und Text genau so zerlegt wie
// `html.parser` aus der Standardbibliothek von Python, das Auflösen von
// Zeichenreferenzen wie `html.unescape` und reguläre Ausdrücke mit der
// Bedeutung, die `\s`, `\w`, `\b`, `.`, `^` und `$` in Python haben.
//
// Warum nachgebaut und nicht `package:html`: Der HTML5-Parser dort baut einen
// Baum und räumt dabei auf (verschiebt Absätze aus Tabellen, schließt Tags,
// macht aus `<du / Sie>` etwas anderes). Die Prüfung sucht aber gerade das,
// was liegen geblieben ist – Platzhalter in spitzen Klammern, Text, der nach
// einem rohen `<` verschluckt wird, ein Tag zwischen Anfang und Ende einer
// Formel. Dafür braucht es die Folge der Tags, wie sie im Text steht, und
// genau die Grenzen, an denen der Leser der Vorlagen trennt. Nur reiner Dart,
// ohne Flutter.
library;

// Die Tabelle der benannten Zeichenreferenzen aus HTML5 ist dieselbe wie
// html.entities.html5 in Python (2231 Namen, mit und ohne Semikolon);
// package:html veröffentlicht sie nur unter src/.
import 'dart:convert';

// ignore: implementation_imports
import 'package:html/src/constants.dart' show entities;

// ---- Python-Zeichenketten --------------------------------------------------

/// Die Zeichen, die Pythons `str.isspace()` und `\s` als Leerraum zählen.
/// Anders als Darts `trim()`: dort zählt U+FEFF dazu, hier U+001C–U+001F.
const _leerraum =
    r'\t\n\v\f\r \x1c-\x1f\x85\xa0  -     　';

/// Wortzeichen wie `\w` in Python: Buchstaben und Ziffern jeder Schrift.
const _wortzeichen = r'\p{L}\p{N}_';

final _leerAnfang = RegExp('^[$_leerraum]+', unicode: true);
final _leerEnde = RegExp('[$_leerraum]+\$', unicode: true);

/// `s.strip()` in Python.
String pyStrip(String s) => s.replaceFirst(_leerAnfang, '').replaceFirst(_leerEnde, '');

/// `s.lstrip()` in Python.
String pyLstrip(String s) => s.replaceFirst(_leerAnfang, '');

/// `s.split()` ohne Trennzeichen in Python: an Folgen von Leerraum, ohne leere Teile.
List<String> pySplit(String s) {
  final t = pyStrip(s);
  return t.isEmpty ? const [] : t.split(RegExp('[$_leerraum]+', unicode: true));
}

/// Die ersten [n] Zeichen, gezählt wie in Python (Codepunkte, nicht UTF-16).
String pyKurz(String s, int n) {
  final r = s.runes;
  return r.length <= n ? s : String.fromCharCodes(r.take(n));
}

/// Länge wie `len()` in Python.
int pyLen(String s) => s.runes.length;

/// `'%-40s' % s` in Python: rechts mit Leerzeichen auf [n] Zeichen aufgefüllt.
String pyLinks(String s, int n) {
  final l = pyLen(s);
  return l >= n ? s : s + ' ' * (n - l);
}

/// Ob ein Wert in Python als wahr gilt (`if x:`).
bool pyWahr(Object? x) => switch (x) {
  null => false,
  bool b => b,
  num z => z != 0,
  String s => s.isNotEmpty,
  Iterable<Object?> l => l.isNotEmpty,
  Map<Object?, Object?> m => m.isNotEmpty,
  _ => true,
};

/// `str(x)` in Python für Werte aus JSON.
String pyStr(Object? x) => switch (x) {
  null => 'None',
  bool b => b ? 'True' : 'False',
  String s => s,
  double d => _pyFloat(d),
  num z => '$z',
  List<Object?> l => '[${l.map(pyRepr).join(', ')}]',
  Map<Object?, Object?> m =>
    '{${m.entries.map((e) => '${pyRepr(e.key)}: ${pyRepr(e.value)}').join(', ')}}',
  _ => '$x',
};

String _pyFloat(double d) {
  if (d.isNaN) return 'nan';
  if (d.isInfinite) return d > 0 ? 'inf' : '-inf';
  final t = d.toString();
  return t.contains('.') || t.contains('e') ? t : '$t.0';
}

final _nichtDruckbar = RegExp(r'[\p{C}\p{Z}]', unicode: true);

/// `repr(x)` in Python für Werte aus JSON: Text in Anführungszeichen, mit
/// Escapes für Steuer- und Leerzeichen außer dem Leerzeichen selbst.
String pyRepr(Object? x) {
  if (x is! String) return pyStr(x);
  final q = x.contains("'") && !x.contains('"') ? '"' : "'";
  final b = StringBuffer(q);
  for (final r in x.runes) {
    final c = String.fromCharCode(r);
    if (c == '\\') {
      b.write(r'\\');
    } else if (c == q) {
      b.write('\\$q');
    } else if (r == 10) {
      b.write(r'\n');
    } else if (r == 13) {
      b.write(r'\r');
    } else if (r == 9) {
      b.write(r'\t');
    } else if (r != 32 && _nichtDruckbar.hasMatch(c)) {
      b.write(
        r < 0x100
            ? '\\x${r.toRadixString(16).padLeft(2, '0')}'
            : r < 0x10000
            ? '\\u${r.toRadixString(16).padLeft(4, '0')}'
            : '\\U${r.toRadixString(16).padLeft(8, '0')}',
      );
    } else {
      b.write(c);
    }
  }
  b.write(q);
  return b.toString();
}

/// `urllib.parse.unquote` in Python: %XX als UTF-8-Bytes gelesen, Ungültiges
/// ersetzt, ein Prozentzeichen ohne zwei Hexziffern bleibt stehen.
String pyUnquote(String s) {
  if (!s.contains('%')) return s;
  final hex = RegExp(r'^[0-9a-fA-F]{2}');
  final raus = StringBuffer();
  final bytes = <int>[];
  var i = 0;
  while (i < s.length) {
    if (s[i] == '%' && hex.hasMatch(s.substring(i + 1))) {
      bytes.add(int.parse(s.substring(i + 1, i + 3), radix: 16));
      i += 3;
      continue;
    }
    if (bytes.isNotEmpty) {
      raus.write(utf8.decode(bytes, allowMalformed: true));
      bytes.clear();
    }
    raus.write(s[i]);
    i++;
  }
  if (bytes.isNotEmpty) raus.write(utf8.decode(bytes, allowMalformed: true));
  return raus.toString();
}

// ---- Reguläre Ausdrücke mit Pythons Bedeutung ------------------------------

/// Ein regulärer Ausdruck, geschrieben wie in Python, übersetzt in einen
/// Dart-Ausdruck mit derselben Bedeutung: `\s` und `\w` Unicode-weit wie in
/// Python, `\b` an der Grenze solcher Wortzeichen, `\d` nur 0–9, `.` ohne
/// [dotAll] alles außer `\n`, `^`/`$` mit [multiLine] nur an `\n`, `$` ohne
/// auch vor einem letzten `\n`, `\Z` am Ende. Was sonst in Python und Dart
/// gleich gilt, bleibt stehen; Muster mit Escapes, die Dart im Unicode-Modus
/// nicht kennt (`\'`), schreibt man hier ohne.
RegExp pyRe(
  String muster, {
  bool multiLine = false,
  bool dotAll = false,
  bool caseSensitive = true,
}) => RegExp(
  _uebersetzen(muster, multiLine: multiLine, dotAll: dotAll),
  unicode: true,
  dotAll: dotAll,
  caseSensitive: caseSensitive,
);

/// `re.fullmatch`: dasselbe Muster, aber nur ganz.
RegExp pyReGanz(String muster, {bool dotAll = false, bool caseSensitive = true}) =>
    RegExp(
      '^(?:${_uebersetzen(muster, multiLine: false, dotAll: dotAll)})\$',
      unicode: true,
      dotAll: dotAll,
      caseSensitive: caseSensitive,
    );

/// `re.escape` für Muster aus [pyRe]: nur, was im Unicode-Modus von Dart
/// escapt werden darf und muss.
String pyEscape(String s) =>
    s.replaceAllMapped(RegExp(r'[\\^$.*+?()[\]{}|/]'), (m) => '\\${m[0]}');

String _uebersetzen(String m, {required bool multiLine, required bool dotAll}) {
  const wort = '[$_wortzeichen]';
  const nichtWort = '[^$_wortzeichen]';
  final b = StringBuffer();
  var klasse = false;
  var i = 0;
  while (i < m.length) {
    final c = m[i];
    if (c == '\\' && i + 1 < m.length) {
      final n = m[i + 1];
      i += 2;
      if (klasse) {
        switch (n) {
          case 's':
            b.write(_leerraum);
          case 'w':
            b.write(_wortzeichen);
          case 'd':
            b.write('0-9');
          case 'S' || 'W' || 'D':
            throw ArgumentError('\\$n in einer Zeichenklasse: $m');
          default:
            b.write('\\$n');
        }
        continue;
      }
      switch (n) {
        case 's':
          b.write('[$_leerraum]');
        case 'S':
          b.write('[^$_leerraum]');
        case 'w':
          b.write(wort);
        case 'W':
          b.write(nichtWort);
        case 'd':
          b.write('[0-9]');
        case 'D':
          b.write('[^0-9]');
        case 'b':
          b.write('(?:(?<=$wort)(?!$wort)|(?<!$wort)(?=$wort))');
        case 'Z':
          b.write(r'(?![\s\S])');
        default:
          b.write('\\$n');
      }
      continue;
    }
    if (klasse) {
      if (c == ']') klasse = false;
      b.write(c);
      i++;
      continue;
    }
    if (c == '[') {
      klasse = true;
      b.write(c);
      i++;
      if (i < m.length && m[i] == '^') {
        b.write('^');
        i++;
      }
      continue;
    }
    if (c == '.' && !dotAll) {
      b.write(r'[^\n]');
    } else if (c == '^' && multiLine) {
      b.write(r'(?<![^\n])');
    } else if (c == r'$') {
      b.write(multiLine ? r'(?![^\n])' : r'(?=\n?(?![\s\S]))');
    } else {
      b.write(c);
    }
    i++;
  }
  return b.toString();
}

/// `re.findall` mit genau einer Gruppe: die Gruppe je Treffer.
List<String> findeGruppe(RegExp re, String s, [int gruppe = 1]) => [
  for (final m in re.allMatches(s)) m[gruppe] ?? '',
];

/// `re.findall` ohne Gruppe: der ganze Treffer.
List<String> findeAlle(RegExp re, String s) => [for (final m in re.allMatches(s)) m[0]!];

/// `re.match` ab Anfang (oder [start]).
RegExpMatch? pyMatch(RegExp re, String s, [int start = 0]) =>
    re.matchAsPrefix(s, start) as RegExpMatch?;

// ---- html.unescape ---------------------------------------------------------

final _zeichenreferenz = RegExp(
  r'&(#[0-9]+;?|#[xX][0-9a-fA-F]+;?|[^\t\n\f <&#;]{1,32};?)',
  unicode: true,
);

/// Steuerzeichen, die HTML5 bei numerischen Referenzen nach Windows-1252 liest.
const _ungueltigeReferenzen = {
  0x00: '�', 0x0d: '\r', 0x80: '€', 0x81: '\x81', 0x82: '‚',
  0x83: 'ƒ', 0x84: '„', 0x85: '…', 0x86: '†', 0x87: '‡',
  0x88: 'ˆ', 0x89: '‰', 0x8a: 'Š', 0x8b: '‹', 0x8c: 'Œ',
  0x8d: '\x8d', 0x8e: 'Ž', 0x8f: '\x8f', 0x90: '\x90', 0x91: '‘',
  0x92: '’', 0x93: '“', 0x94: '”', 0x95: '•', 0x96: '–',
  0x97: '—', 0x98: '˜', 0x99: '™', 0x9a: 'š', 0x9b: '›',
  0x9c: 'œ', 0x9d: '\x9d', 0x9e: 'ž', 0x9f: 'Ÿ',
};

bool _ungueltigerCodepunkt(int n) =>
    (n >= 0x1 && n <= 0x8) ||
    (n >= 0xe && n <= 0x1f) ||
    (n >= 0x7f && n <= 0x9f) ||
    (n >= 0xfdd0 && n <= 0xfdef) ||
    n == 0xb ||
    (n & 0xfffe) == 0xfffe && n <= 0x10ffff;

/// `html.unescape` in Python: benannte und numerische Zeichenreferenzen nach
/// den Regeln von HTML5, auch ohne Semikolon, wo HTML5 das erlaubt.
String pyUnescape(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_zeichenreferenz, (m) {
    final t = m[1]!;
    if (t.startsWith('#')) {
      final hex = t.length > 1 && (t[1] == 'x' || t[1] == 'X');
      final ziffern = (hex ? t.substring(2) : t.substring(1)).replaceAll(';', '');
      final zahl = BigInt.parse(ziffern, radix: hex ? 16 : 10);
      if (zahl > BigInt.from(0x10ffff)) return '�';
      final n = zahl.toInt();
      final ersatz = _ungueltigeReferenzen[n];
      if (ersatz != null) return ersatz;
      if (n >= 0xd800 && n <= 0xdfff) return '�';
      if (_ungueltigerCodepunkt(n)) return '';
      return String.fromCharCode(n);
    }
    final w = entities[t];
    if (w != null) return w;
    // Der längste Anfang, den HTML5 auch ohne Semikolon kennt.
    final r = t.runes.toList();
    for (var x = r.length - 1; x > 1; x--) {
      final anfang = String.fromCharCodes(r.take(x));
      final v = entities[anfang];
      if (v != null) return v + String.fromCharCodes(r.skip(x));
    }
    return '&$t';
  });
}

final _attrReferenz = RegExp(r'&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*)[;=]?');

/// Zeichenreferenzen in einem Attributwert: benannte nur, wenn sie genau
/// passen und kein `=` folgt (HTML5, „named character reference state").
String _attrUnescape(String s) => s.replaceAllMapped(_attrReferenz, (m) {
  final ref = m[0]!;
  if (ref.startsWith('&#')) return pyUnescape(ref);
  if (!ref.endsWith('=') && entities.containsKey(ref.substring(1))) {
    return pyUnescape(ref);
  }
  return ref;
});

// ---- html.parser.HTMLParser ------------------------------------------------

final _starttagAuf = RegExp(r'<[a-zA-Z]');
final _endtagAuf = RegExp(r'</[a-zA-Z]');
final _kommentarZu = RegExp(r'--!?>');
final _kommentarJaeh = RegExp(r'-?>');
final _tagName = RegExp(r'([a-zA-Z][^\t\n\r\f />]*)(?:[\t\n\r\f ]|/(?!>))*');
final _attribut = RegExp(
  r'''((?<=['"\t\n\r\f /])[^\t\n\r\f />][^\t\n\r\f /=>]*)'''
  r'''([\t\n\r\f ]*=[\t\n\r\f ]*('[^']*'|"[^"]*"|(?!['"])[^>\t\n\r\f ]*))?'''
  r'''(?:[\t\n\r\f ]|/(?!>))*''',
);
final _tagEnde = RegExp(
  r'''[a-zA-Z][^\t\n\r\f />]*[\t\n\r\f /]*'''
  r'''(?:(?<=['"\t\n\r\f /])[^\t\n\r\f />][^\t\n\r\f /=>]*'''
  r'''(?:[\t\n\r\f ]*=[\t\n\r\f ]*(?:'[^']*'|"[^"]*"|(?!['"])[^>\t\n\r\f ]*))?'''
  r'''[\t\n\r\f /]*)*>?''',
);

/// Elemente, deren Inhalt der Leser als rohen Text weitergibt (RAWTEXT).
const _cdataElemente = {'script', 'style', 'xmp', 'iframe', 'noembed', 'noframes'};

/// Elemente, deren Inhalt Text mit Zeichenreferenzen ist (RCDATA).
const _rcdataElemente = {'textarea', 'title'};

/// Ein Attribut, wie der Leser es liefert: Name klein, Wert ohne
/// Anführungszeichen und aufgelöst, `null` bei einem Attribut ohne Wert.
typedef Attribut = (String, String?);

/// Die Attribute als Map wie `dict(attrs)` in Python: Ein doppeltes Attribut
/// behält den Platz des ersten und den Wert des letzten.
Map<String, String?> attributMap(List<Attribut> attrs) => {
  for (final (k, w) in attrs) k: w,
};

/// Der HTML-Leser von Python (`html.parser.HTMLParser` mit
/// `convert_charrefs=True`), zum Ableiten: [starttag], [endtag],
/// [startendtag] und [daten] überschreiben, dann [lesen] mit dem ganzen Text
/// (feed und close in einem). Kommentare, Deklarationen und Verarbeitungs-
/// anweisungen fallen weg.
abstract class PyHtmlLeser {
  String _roh = '';
  String? _starttagText;
  RegExp? _interessant;
  bool _maskierbar = true;

  /// Der Quelltext des letzten Start-Tags (`get_starttag_text()`).
  String? get starttagText => _starttagText;

  void starttag(String tag, List<Attribut> attrs) {}
  void endtag(String tag) {}
  void daten(String d) {}

  /// `<tag … />`: in Python ohne Überschreiben Start und Ende.
  void startendtag(String tag, List<Attribut> attrs) {
    starttag(tag, attrs);
    endtag(tag);
  }

  void _cdataSetzen(String elem, {required bool maskierbar}) {
    _maskierbar = maskierbar;
    _interessant = elem == 'plaintext'
        ? RegExp(r'$')
        : RegExp('</$elem(?=[\\t\\n\\r\\f />])', caseSensitive: false);
  }

  void _cdataEnde() {
    _interessant = null;
    _maskierbar = true;
  }

  void _text(String s) => daten(_maskierbar ? pyUnescape(s) : s);

  /// Liest [html] ganz (`feed` und `close`).
  void lesen(String html) {
    _roh = html;
    final raw = html;
    final n = raw.length;
    var i = 0;
    while (i < n) {
      int j;
      if (_interessant == null) {
        j = raw.indexOf('<', i);
        if (j < 0) j = n;
      } else {
        final m = _interessant!.allMatches(raw, i).firstOrNull;
        if (m == null) break;
        j = m.start;
      }
      if (i < j) _text(raw.substring(i, j));
      i = j;
      if (i == n) break;
      int k;
      if (_starttagAuf.matchAsPrefix(raw, i) != null) {
        k = _starttag(i);
      } else if (raw.startsWith('</', i)) {
        k = _endtag(i);
      } else if (raw.startsWith('<!--', i)) {
        k = _kommentar(i);
      } else if (raw.startsWith('<?', i)) {
        k = _bis(i + 2, '>');
      } else if (raw.startsWith('<!', i)) {
        k = _deklaration(i);
      } else {
        daten('<');
        k = i + 1;
      }
      if (k < 0) {
        // Am Ende ohne Abschluss: Ein angefangenes Tag fällt weg, „</" am
        // Schluss ist Text, alles andere ein Kommentar.
        if (_starttagAuf.matchAsPrefix(raw, i) == null &&
            raw.startsWith('</', i) &&
            i + 2 == n) {
          daten('</');
        }
        k = n;
      }
      i = k;
    }
    if (i < n) _text(raw.substring(i));
    _roh = '';
  }

  int _bis(int ab, String zeichen) {
    final p = _roh.indexOf(zeichen, ab);
    return p < 0 ? -1 : p + zeichen.length;
  }

  int _deklaration(int i) {
    final raw = _roh;
    if (raw.startsWith('<![CDATA[', i)) {
      final j = raw.indexOf(']]>', i + 9);
      return j < 0 ? -1 : j + 3;
    }
    if (raw.length >= i + 9 && raw.substring(i, i + 9).toLowerCase() == '<!doctype') {
      final gt = raw.indexOf('>', i + 9);
      return gt < 0 ? -1 : gt + 1;
    }
    return _bis(i + 2, '>');
  }

  int _kommentar(int i) {
    final jaeh = _kommentarJaeh.matchAsPrefix(_roh, i + 4);
    if (jaeh != null) return jaeh.end;
    final m = _kommentarZu.allMatches(_roh, i + 4).firstOrNull;
    return m == null ? -1 : m.end;
  }

  int _starttag(int i) {
    final raw = _roh;
    _starttagText = null;
    final ende = _tagEnde.matchAsPrefix(raw, i + 1)!.end;
    if (raw[ende - 1] != '>') return -1;
    _starttagText = raw.substring(i, ende);
    final attrs = <Attribut>[];
    final kopf = _tagName.matchAsPrefix(raw, i + 1)!;
    var k = kopf.end;
    final tag = kopf[1]!.toLowerCase();
    while (k < ende) {
      final m = _attribut.matchAsPrefix(raw, k);
      if (m == null) break;
      var wert = m[2] == null ? null : m[3];
      if (wert != null &&
          wert.length >= 2 &&
          ((wert.startsWith("'") && wert.endsWith("'")) ||
              (wert.startsWith('"') && wert.endsWith('"')))) {
        wert = wert.substring(1, wert.length - 1);
      }
      if (wert != null && wert.isNotEmpty) wert = _attrUnescape(wert);
      attrs.add((m[1]!.toLowerCase(), wert));
      k = m.end;
    }
    final schluss = pyStrip(raw.substring(k, ende));
    if (schluss != '>' && schluss != '/>') {
      daten(raw.substring(i, ende));
      return ende;
    }
    if (schluss.endsWith('/>')) {
      startendtag(tag, attrs);
    } else {
      starttag(tag, attrs);
      if (_cdataElemente.contains(tag) || tag == 'plaintext') {
        _cdataSetzen(tag, maskierbar: false);
      } else if (_rcdataElemente.contains(tag)) {
        _cdataSetzen(tag, maskierbar: true);
      }
    }
    return ende;
  }

  int _endtag(int i) {
    final raw = _roh;
    if (raw.indexOf('>', i + 2) < 0) return -1;
    if (_endtagAuf.matchAsPrefix(raw, i) == null) {
      if (raw.length > i + 2 && raw[i + 2] == '>') return i + 3;
      return _bis(i + 2, '>');
    }
    final j = _tagEnde.matchAsPrefix(raw, i + 2)!.end;
    if (raw[j - 1] != '>') return -1;
    endtag(_tagName.matchAsPrefix(raw, i + 2)![1]!.toLowerCase());
    _cdataEnde();
    return j;
  }
}
