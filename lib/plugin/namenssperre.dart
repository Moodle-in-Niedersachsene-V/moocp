// Die Regel, nach der moocp einen Text auf mögliche Namen prüft (E36): Jede
// Antwort eines Plugins an die KI und jede Zeile, die ein Plugin ins Protokoll
// schreibt, prüft die App gegen alle Namen, die sie seit ihrem Start für
// dieses Plugin geladen hat. Ein Treffer sperrt nichts von selbst: Bei einer
// Antwort entscheidet die Lehrkraft in einer Datenschutzwarnung, ob sie
// trotzdem an die KI geht (datenschutz.dart); eine Protokollzeile erscheint
// nur als Platzhalter. Hier steht die Regel selbst, ohne Flutter und ohne Ein-
// und Ausgabe; wo geprüft wird, steht in datenschutz.dart (Antworten,
// Pfade), laufende_plugins.dart und app_adresse.dart.
//
// Die Regel ist bewusst einfach; Tippfehler, Dateiformate und alles Weitere
// fängt das Plugin ab, und falsche Treffer kosten die Lehrkraft nur einen
// Klick:
//
// - Ein Wort ist eine ununterbrochene Folge von Buchstaben, Ziffern und
//   Zeichen, die zu einem Buchstaben gehören (kombinierende Akzente, Unicode
//   \p{L}, \p{N}, \p{M}), dazu unsichtbare Formatzeichen (\p{Cf}, etwa das
//   weiche Trennzeichen), die beim Vergleich wegfallen. Alles andere trennt:
//   Leerraum, Zeilenwechsel, Satzzeichen, Bindestrich, Apostroph, Punkt,
//   Komma, Schrägstrich, Unterstrich, Klammern, Anführungszeichen, Zeichen
//   aus HTML und JSON. Der Unterstrich trennt, damit `erika_mustermann` in
//   einem Dateinamen trifft; der Apostroph, damit „Brien“ auch allein trifft.
// - Namen zerfallen nach derselben Regel in Teile, und jeder Teil trifft für
//   sich, schon der Vorname allein: „Müller-Lüdenscheidt“ trifft
//   „Müller-Lüdenscheidt“, „Müller“ und „Lüdenscheidt“. Wer die Klasse kennt,
//   erkennt eine Person oft am Vornamen.
// - Getroffen wird nur ein ganzes Wort („Max“ trifft nicht „Maximal“), ohne
//   Mindestlänge (auch „Li“ und „Jo“ treffen), gleich in welcher Groß- und
//   Kleinschreibung.
// - Die Schreibweise von Umlauten und Akzenten zählt nicht: ä, ö, ü treffen
//   ae, oe, ue und auch a, o, u, ß trifft ss, und Akzente fallen weg („René“
//   = „Rene“). Ob ein Akzent als eigenes Zeichen kommt oder mit dem
//   Buchstaben verbunden (Unicode-Normalform NFD oder NFC), ist gleich.
// - Falsche Treffer sind in Kauf genommen: Ein Max in der Klasse trifft auch
//   „max. 10 Punkte“. Deshalb sieht die Lehrkraft das Wort im Zusammenhang
//   und entscheidet.
// - Leere Teile und reine Satzzeichen treffen nichts.
// - Einfache Kodierungen zählen nicht ([kodierungenAufgeloest]): Geprüft wird
//   der Text, wie er ist, und dazu in den Formen, die sich durch Auflösen von
//   Unicode-Escapes (Backslash, `u` und vier Hexadezimalziffern wie in JSON,
//   `\u{fc}` wie in JavaScript) und HTML-Zeichenreferenzen (`&#252;`,
//   `&#xfc;`, `&uuml;`) ergeben, auch ineinander geschachtelt bis zu einer
//   festen Tiefe. Was sich nicht auflösen lässt, bleibt stehen, wie es ist;
//   ungültige Kodierung wirft nie und lässt nie etwas durch, denn die Rohform
//   zählt immer mit. Prozentkodierung löst die Prüfung nicht auf: Sie kommt in
//   Antworten von Plugins kaum vor, und falsche Treffer wären häufiger als
//   echte. Das Wort für die Warnung ist das, wie es aufgelöst dasteht.
//
// Nicht abgedeckt: Namen, die ohne Trennung in einem längeren Wort stecken
// („ErikaMustermann“, „Erikas“), Schreibweisen über das hinaus, was die
// Tabelle unten kennt (Vollbreitenbuchstaben, Ligaturen wie „ﬁ“, Buchstaben
// außerhalb der lateinischen Schrift bleiben, wie sie sind, und treffen nur
// sich selbst), andere Kodierungen (Prozent, Base64, Kompression, eigene
// Formate), tiefer geschachtelte Kodierungen und Tippfehler. Base64 bleibt
// mit Absicht draußen: Jede Folge von Buchstaben ließe sich als Base64 lesen,
// und die Prüfung träfe beliebige Wörter.
//
// Schnell auch bei vielen Namen und langen Texten: Jedes Wort des Texts wird
// einmal in seine Vergleichsform gebracht und in einer Menge nachgeschlagen;
// kein regulärer Ausdruck je Name.
//
// Die Namen stehen nur im Arbeitsspeicher, bis die App endet: in keiner Datei,
// keinem Protokoll, keiner Einstellung, keiner Fehlermeldung und keiner
// Antwort. Darum hat keine Klasse hier ein toString, das sie nennt, und es gibt
// keinen Weg, sie auszulesen oder zu entfernen.

import '../datenschutzwarnung.dart' show Herkunft;

/// Ein Wort im Sinn der Sperre (siehe oben).
final _wort = RegExp(r'[\p{L}\p{N}\p{M}\p{Cf}]+', unicode: true);

/// Wie oft die Prüfung Kodierungen ineinander auflöst: genug für eine
/// dreifach verschachtelte Referenz, und klein genug, dass ein langer Text
/// schnell geprüft ist (höchstens drei Formen zusätzlich).
const _kodierTiefe = 3;

/// [text], wie er ist, und danach jede verschiedene Form, die sich durch
/// Auflösen von Unicode-Escapes und HTML-Zeichenreferenzen
/// ([_escapesAufgeloest]) ergibt, Stufe für Stufe bis zur [_kodierTiefe].
/// Faul: Wer schon in der Rohform trifft, löst nichts auf.
Iterable<String> kodierungenAufgeloest(String text) sync* {
  yield text;
  var aktuell = text;
  for (var i = 0; i < _kodierTiefe; i++) {
    final neu = _escapesAufgeloest(aktuell);
    if (identical(neu, aktuell) || neu == aktuell) return;
    yield neu;
    aktuell = neu;
  }
}

/// Unicode-Escapes wie in JSON und JavaScript (`\uXXXX`, `\u{X…}`) und
/// HTML-Zeichenreferenzen (`&#…;`, `&#x…;`, benannte aus [_benannt]).
final _escape = RegExp(
  r'\\u\{([0-9A-Fa-f]{1,8})\}|\\u([0-9A-Fa-f]{4})|&#[xX]([0-9A-Fa-f]{1,8});|&#([0-9]{1,10});|&([A-Za-z][A-Za-z0-9]{1,7});',
);

/// Die benannten HTML-Zeichenreferenzen, die die Sperre kennt: die
/// Buchstaben aus Latin-1 (U+00C0 bis U+00FF, in dieser Reihenfolge, mit
/// `times` und `divide` an ihren Plätzen), einige aus Latin Extended-A und die
/// Zeichen, die selbst kodieren (`&amp;`, damit `&amp;#69;` aufgeht).
final Map<String, String> _benannt = () {
  const latin1 =
      'Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml '
      'ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig '
      'agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml '
      'eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml';
  final namen = latin1.split(' ');
  return {
    for (var i = 0; i < namen.length; i++) namen[i]: String.fromCharCode(0xC0 + i),
    'OElig': String.fromCharCode(0x152),
    'oelig': String.fromCharCode(0x153),
    'Scaron': String.fromCharCode(0x160),
    'scaron': String.fromCharCode(0x161),
    'Yuml': String.fromCharCode(0x178),
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': ' ',
  };
}();

/// Ein Zeichen aus seinem Code-Punkt; jenseits von Unicode das Ersatzzeichen
/// U+FFFD, das wie jedes Nicht-Buchstabenzeichen trennt. Ein einzelnes
/// Ersatzzeichen-Halbteil (Surrogat) bleibt eine Code-Einheit: Zwei
/// nebeneinander (`\ud83d\ude00`) ergeben so ein Zeichen, eines allein trennt.
String _zeichen(int wert) => wert > 0x10FFFF ? String.fromCharCode(0xFFFD) : String.fromCharCode(wert);

/// [s] mit aufgelösten Unicode-Escapes und HTML-Zeichenreferenzen. Unbekannte
/// benannte Referenzen bleiben stehen. Ohne `\u` und `&` kommt [s] selbst
/// zurück.
String _escapesAufgeloest(String s) {
  if (!s.contains(r'\u') && !s.contains('&')) return s;
  return s.replaceAllMapped(_escape, (m) {
    if (m[1] case final h?) return _zeichen(int.parse(h, radix: 16));
    if (m[2] case final h?) return _zeichen(int.parse(h, radix: 16));
    if (m[3] case final h?) return _zeichen(int.parse(h, radix: 16));
    if (m[4] case final d?) return _zeichen(int.parse(d));
    return _benannt[m[5]!] ?? m[0]!;
  });
}

/// Zeichen, die beim Vergleich wegfallen: kombinierende Zeichen und
/// unsichtbare Formatzeichen.
final _wegfallend = RegExp(r'^[\p{M}\p{Cf}]$', unicode: true);

/// Das kombinierende Trema (U+0308): nach a, o oder u ein Umlaut.
const _trema = 0x0308;

/// Kleinbuchstaben mit Akzent oder Sonderform und ihre Vergleichsformen:
/// zuerst die Form mit e für Umlaute, dann die ohne. Abgedeckt sind die
/// Buchstaben aus Latin-1 und Latin Extended-A und die rumänischen ș und ț
/// sowie ǎ, ǐ, ǒ, ǔ aus Latin Extended-B.
final Map<int, (String, String)> _tabelle = () {
  final t = <int, (String, String)>{
    'ä'.runes.single: ('ae', 'a'),
    'ö'.runes.single: ('oe', 'o'),
    'ü'.runes.single: ('ue', 'u'),
    'ß'.runes.single: ('ss', 'ss'),
    'ẞ'.runes.single: ('ss', 'ss'),
    'æ'.runes.single: ('ae', 'ae'),
    'œ'.runes.single: ('oe', 'oe'),
    'þ'.runes.single: ('th', 'th'),
    'ĳ'.runes.single: ('ij', 'ij'),
  };
  const einfach = {
    'a': 'àáâãåāăąǎ',
    'c': 'çćĉċč',
    'd': 'ďđð',
    'e': 'èéêëēĕėęě',
    'g': 'ĝğġģ',
    'h': 'ĥħ',
    'i': 'ìíîïĩīĭįıǐ',
    'j': 'ĵ',
    'k': 'ķĸ',
    'l': 'ĺļľŀł',
    'n': 'ñńņňŉŋ',
    'o': 'òóôõøōŏőǒ',
    'r': 'ŕŗř',
    's': 'śŝşšșſ',
    't': 'ţťŧț',
    'u': 'ùúûũūŭůűųǔ',
    'w': 'ŵ',
    'y': 'ýÿŷ',
    'z': 'źżž',
  };
  for (final MapEntry(key: basis, value: zeichen) in einfach.entries) {
    for (final r in zeichen.runes) {
      t[r] = (basis, basis);
    }
  }
  return t;
}();

/// Die beiden Vergleichsformen eines Worts: klein geschrieben, ohne Akzente,
/// ohne unsichtbare Zeichen; in der ersten Umlaute als ae, oe, ue, in der
/// zweiten als a, o, u. Leer, wenn nichts bleibt.
(String, String) _formen(String wort) {
  final klein = wort.toLowerCase();
  // Der häufige Fall: nur ASCII, beide Formen gleich.
  if (!klein.runes.any((r) => r > 0x7f)) return (klein, klein);
  final mitE = StringBuffer();
  final ohne = StringBuffer();
  var letzte = -1;
  for (final r in klein.runes) {
    if (r <= 0x7f) {
      mitE.writeCharCode(r);
      ohne.writeCharCode(r);
      letzte = r;
      continue;
    }
    final ersatz = _tabelle[r];
    if (ersatz != null) {
      mitE.write(ersatz.$1);
      ohne.write(ersatz.$2);
      letzte = -1;
      continue;
    }
    if (_wegfallend.hasMatch(String.fromCharCode(r))) {
      // „u“ mit kombinierendem Trema ist ein ü: in der ersten Form „ue“.
      if (r == _trema && (letzte == 0x61 || letzte == 0x6f || letzte == 0x75)) mitE.write('e');
      letzte = -1;
      continue;
    }
    mitE.writeCharCode(r);
    ohne.writeCharCode(r);
    letzte = -1;
  }
  return (mitE.toString(), ohne.toString());
}

/// Ein Wort in einer Form eines Texts, das einen Namensteil trifft, mit Anfang
/// und Ende (ausschließlich) in UTF-16-Codeeinheiten.
typedef NamenFund = ({int anfang, int ende, Set<Herkunft> herkunft});

/// Die Namen eines Plugins, gegen die die App seine Texte prüft. Namen
/// lassen sich nur hinzufügen, nie entfernen oder abfragen.
class Namenssperre {
  /// Die Vergleichsformen aller Namensteile, je mit ihrer Herkunft.
  final _teile = <String, Set<Herkunft>>{};

  /// Die verschiedenen Namen, je als Folge ihrer Teile; nur zum Zählen.
  final _namen = <String>{};

  /// Wie viele verschiedene Namen geladen sind (gleich geschrieben im Sinn
  /// der Regel zählt einmal).
  int get anzahl => _namen.length;

  /// Ob noch kein Name geladen ist.
  bool get leer => _teile.isEmpty;

  /// Ob [name] mindestens einen Teil hat, der trifft: nicht leer, nicht nur
  /// Satzzeichen.
  static bool hatTeile(String name) => _teileVon(name).isNotEmpty;

  /// Die Teile eines Namens als Paare von Vergleichsformen.
  static List<(String, String)> _teileVon(String name) => [
    for (final m in _wort.allMatches(name))
      if (_formen(m[0]!) case final f when f.$1.isNotEmpty) f,
  ];

  /// Nimmt [namen] aus [herkunft] auf; jeder Teil jedes Namens trifft von nun
  /// an für sich. Namen ohne Teile (leer, nur Satzzeichen) treffen nichts.
  void hinzufuegen(Iterable<String> namen, {Herkunft herkunft = Herkunft.pluginName}) {
    for (final name in namen) {
      final teile = _teileVon(name);
      if (teile.isEmpty) continue;
      _namen.add(teile.map((t) => t.$1).join(' '));
      for (final (mitE, ohne) in teile) {
        (_teile[mitE] ??= {}).add(herkunft);
        (_teile[ohne] ??= {}).add(herkunft);
      }
    }
  }

  Set<Herkunft>? _herkunft(String wort) {
    final (mitE, ohne) = _formen(wort);
    if (mitE.isEmpty) return null;
    final a = _teile[mitE];
    final b = _teile[ohne];
    if (a == null) return b;
    if (b == null || identical(a, b)) return a;
    return {...a, ...b};
  }

  /// Das erste Wort in [text] oder einer seiner aufgelösten Formen
  /// ([kodierungenAufgeloest]), das einen Namensteil trifft, so wie es dort
  /// steht; null ohne Treffer.
  String? treffer(String text) {
    if (_teile.isEmpty || text.isEmpty) return null;
    for (final form in kodierungenAufgeloest(text)) {
      for (final m in _wort.allMatches(form)) {
        if (_herkunft(m[0]!) != null) return m[0];
      }
    }
    return null;
  }

  /// Jedes Wort in [form], das einen Namensteil trifft, der Reihenfolge
  /// nach. [form] ist ein Text oder eine seiner aufgelösten Formen
  /// ([kodierungenAufgeloest]); die aufgelösten sieht diese Suche nicht.
  Iterable<NamenFund> fundeIn(String form) sync* {
    if (_teile.isEmpty || form.isEmpty) return;
    for (final m in _wort.allMatches(form)) {
      if (_herkunft(m[0]!) case final h?) yield (anfang: m.start, ende: m.end, herkunft: h);
    }
  }
}

/// Alle Texte in einem JSON-Wert: Schlüssel, Zeichenketten und Zahlen, in
/// beliebiger Tiefe. Geprüft wird jeder Text für sich, nicht das kodierte
/// JSON: Darin stünde ein Zeilenwechsel als `\n`, und das n klebte am
/// nächsten Wort.
Iterable<String> texteIn(Object? json) sync* {
  switch (json) {
    case final String s:
      yield s;
    case final num n:
      yield '$n';
    case final Map<Object?, Object?> m:
      for (final e in m.entries) {
        yield* texteIn(e.key);
        yield* texteIn(e.value);
      }
    case final Iterable<Object?> l:
      for (final x in l) {
        yield* texteIn(x);
      }
  }
}
