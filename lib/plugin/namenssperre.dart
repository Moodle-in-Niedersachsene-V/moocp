// Die letzte Sperre gegen Namen (E36): Jede Antwort eines Plugins an die KI
// und jede Zeile, die ein Plugin ins Protokoll schreibt, prüft die App gegen
// alle Namen, die sie seit ihrem Start für dieses Plugin geladen hat. Hier
// steht die Regel selbst, ohne Flutter und ohne Ein- und Ausgabe; wo geprüft
// wird, steht in laufende_plugins.dart (Antworten, Werkzeugliste nach einem
// Neustart), app_adresse.dart (Protokollzeilen, Aufrufe eingebauter
// Werkzeuge, Pfade an Moodle) und entwicklung.dart (Werkzeugliste beim
// Wiederverbinden eines Entwicklungs-Plugins).
//
// Ebenso, für jedes Plugin, der Pfad des Ordners, in dem die App die Downloads
// der Plugins ablegt (downloads.dart, [LetzteSperre.pfadSperren]): Wer ihn
// kennt, kann die Dateien darin mit eigenen Mitteln lesen. Ein Treffer darauf
// wird behandelt wie einer auf einen Namen; nur die Warnung an die Lehrkraft
// nennt statt des Worts den Ordner.
//
// Die Regel ist bewusst einfach, weil sie die letzte Sperre ist, nicht die
// erste; Tippfehler, Dateiformate und alles Weitere fängt das Plugin ab:
//
// - Ein Wort ist eine ununterbrochene Folge von Buchstaben, Ziffern und
//   Zeichen, die zu einem Buchstaben gehören (kombinierende Akzente, Unicode
//   \p{L}, \p{N}, \p{M}), dazu unsichtbare Formatzeichen (\p{Cf}, etwa das
//   weiche Trennzeichen), die beim Vergleich wegfallen. Alles andere trennt:
//   Leerraum, Zeilenwechsel, Satzzeichen, Bindestrich, Apostroph, Punkt,
//   Komma, Schrägstrich, Unterstrich, Klammern, Anführungszeichen, Zeichen
//   aus HTML und JSON. Der Unterstrich trennt, damit `erika_mustermann` in
//   einem Dateinamen trifft; der Apostroph, damit „Brien“ auch allein trifft.
// - Namen zerfallen nach derselben Regel in Teile, und jeder Teil sperrt für
//   sich, schon der Vorname allein: „Müller-Lüdenscheidt“ sperrt
//   „Müller-Lüdenscheidt“, „Müller“ und „Lüdenscheidt“. Wer die Klasse kennt,
//   erkennt eine Person oft am Vornamen.
// - Getroffen wird nur ein ganzes Wort („Max“ trifft nicht „Maximal“), ohne
//   Mindestlänge (auch „Li“ und „Jo“ sperren), gleich in welcher Groß- und
//   Kleinschreibung.
// - Die Schreibweise von Umlauten und Akzenten zählt nicht: ä, ö, ü treffen
//   ae, oe, ue und auch a, o, u, ß trifft ss, und Akzente fallen weg („René“
//   = „Rene“). Ob ein Akzent als eigenes Zeichen kommt oder mit dem
//   Buchstaben verbunden (Unicode-Normalform NFD oder NFC), ist gleich.
// - Falsche Treffer sind in Kauf genommen: Ein Max in der Klasse sperrt auch
//   „max. 10 Punkte“. Deshalb sieht die Lehrkraft das Wort, das getroffen hat.
// - Leere Teile und reine Satzzeichen sperren nichts.
// - Einfache Kodierungen zählen nicht ([kodierungenAufgeloest]): Geprüft wird
//   der Text, wie er ist, und dazu in den Formen, die sich durch Auflösen von
//   Prozentkodierung (mit `+` als Leerzeichen), Unicode-Escapes (Backslash,
//   `u` und vier Hexadezimalziffern wie in JSON, `\u{fc}` wie in JavaScript)
//   und HTML-Zeichenreferenzen (`&#252;`, `&#xfc;`, `&uuml;`)
//   ergeben, auch ineinander geschachtelt bis zu einer festen Tiefe. Was sich
//   nicht auflösen lässt, bleibt stehen, wie es ist; ungültige Kodierung
//   wirft nie und lässt nie etwas durch, denn die Rohform zählt immer mit.
//   Das Wort für die Warnung ist das, wie es aufgelöst dasteht.
//
// Nicht abgedeckt: Namen, die ohne Trennung in einem längeren Wort stecken
// („ErikaMustermann“, „Erikas“), Schreibweisen über das hinaus, was die
// Tabelle unten kennt (Vollbreitenbuchstaben, Ligaturen wie „ﬁ“, Buchstaben
// außerhalb der lateinischen Schrift bleiben, wie sie sind, und treffen nur
// sich selbst), andere Kodierungen (Base64, Kompression, eigene Formate),
// tiefer geschachtelte Kodierungen und Tippfehler. Base64 bleibt mit
// Absicht draußen: Jede Folge von Buchstaben ließe sich als Base64 lesen, und
// die Sperre träfe beliebige Wörter.
//
// Schnell auch bei vielen Namen und langen Texten: Jedes Wort des Texts wird
// einmal in seine Vergleichsform gebracht und in einer Menge nachgeschlagen;
// kein regulärer Ausdruck je Name.
//
// Die Namen stehen nur im Arbeitsspeicher, bis die App endet: in keiner Datei,
// keinem Protokoll, keiner Einstellung, keiner Fehlermeldung und keiner
// Antwort. Darum hat keine Klasse hier ein toString, das sie nennt, und es gibt
// keinen Weg, sie abzufragen oder zu entfernen.

import 'dart:convert';

/// Ein Wort im Sinn der Sperre (siehe oben).
final _wort = RegExp(r'[\p{L}\p{N}\p{M}\p{Cf}]+', unicode: true);

/// Wie oft die Sperre Kodierungen ineinander auflöst: genug für eine dreifach
/// prozentkodierte Folge oder eine prozentkodierte HTML-Referenz, und klein
/// genug, dass ein langer Text schnell geprüft ist (höchstens 15 Formen).
const _kodierTiefe = 3;

/// [text], wie er ist, und danach jede verschiedene Form, die sich durch
/// Auflösen von Prozentkodierung ([_prozentAufgeloest]) oder von
/// Unicode-Escapes und HTML-Zeichenreferenzen ([_escapesAufgeloest])
/// ergibt, Stufe für Stufe bis zur [_kodierTiefe]. Faul: Wer schon in der
/// Rohform trifft, löst nichts auf.
Iterable<String> kodierungenAufgeloest(String text) sync* {
  yield text;
  final gesehen = <String>{text};
  var stufe = [text];
  for (var i = 0; i < _kodierTiefe && stufe.isNotEmpty; i++) {
    final naechste = <String>[];
    for (final t in stufe) {
      for (final neu in [_prozentAufgeloest(t), _escapesAufgeloest(t)]) {
        if (identical(neu, t) || !gesehen.add(neu)) continue;
        naechste.add(neu);
        yield neu;
      }
    }
    stufe = naechste;
  }
}

/// Der Wert einer Hexadezimalziffer (Code-Einheit [c]); -1, wenn [c] keine ist.
int _hexwert(int c) => switch (c) {
  >= 0x30 && <= 0x39 => c - 0x30,
  >= 0x41 && <= 0x46 => c - 0x41 + 10,
  >= 0x61 && <= 0x66 => c - 0x61 + 10,
  _ => -1,
};

/// [s] mit aufgelöster Prozentkodierung und `+` als Leerzeichen, wie ein
/// Formular oder eine Adresse es meint. Folgen von `%HH` gelten als UTF-8;
/// was darin kein gültiges UTF-8 ist, wird zum Ersatzzeichen U+FFFD, und ein
/// `%` ohne zwei Hexadezimalziffern bleibt stehen. Ohne `%` und `+` kommt
/// [s] selbst zurück.
String _prozentAufgeloest(String s) {
  if (!s.contains('%') && !s.contains('+')) return s;
  final aus = StringBuffer();
  final bytes = <int>[];
  void leeren() {
    if (bytes.isEmpty) return;
    aus.write(utf8.decode(bytes, allowMalformed: true));
    bytes.clear();
  }

  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x25 && i + 2 < s.length) {
      final hoch = _hexwert(s.codeUnitAt(i + 1));
      final tief = _hexwert(s.codeUnitAt(i + 2));
      if (hoch >= 0 && tief >= 0) {
        bytes.add(hoch << 4 | tief);
        i += 2;
        continue;
      }
    }
    leeren();
    aus.write(c == 0x2b ? ' ' : s[i]);
  }
  leeren();
  return aus.toString();
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

/// Die Namen eines Plugins, gegen die die App seine Texte prüft. Namen
/// lassen sich nur hinzufügen, nie entfernen oder abfragen.
class Namenssperre {
  /// Die Vergleichsformen aller Namensteile.
  final _teile = <String>{};

  /// Die verschiedenen Namen, je als Folge ihrer Teile; nur zum Zählen.
  final _namen = <String>{};

  /// Wie viele verschiedene Namen geladen sind (gleich geschrieben im Sinn
  /// der Regel zählt einmal).
  int get anzahl => _namen.length;

  /// Ob noch kein Name geladen ist.
  bool get leer => _teile.isEmpty;

  /// Ob [name] mindestens einen Teil hat, der sperrt: nicht leer, nicht nur
  /// Satzzeichen.
  static bool hatTeile(String name) => _teileVon(name).isNotEmpty;

  /// Die Teile eines Namens als Paare von Vergleichsformen.
  static List<(String, String)> _teileVon(String name) => [
    for (final m in _wort.allMatches(name))
      if (_formen(m[0]!) case final f when f.$1.isNotEmpty) f,
  ];

  /// Nimmt [namen] auf; jeder Teil jedes Namens sperrt von nun an für sich.
  /// Namen ohne Teile (leer, nur Satzzeichen) sperren nichts.
  void hinzufuegen(Iterable<String> namen) {
    for (final name in namen) {
      final teile = _teileVon(name);
      if (teile.isEmpty) continue;
      _namen.add(teile.map((t) => t.$1).join(' '));
      for (final (mitE, ohne) in teile) {
        _teile
          ..add(mitE)
          ..add(ohne);
      }
    }
  }

  /// Das erste Wort in [text] oder einer seiner aufgelösten Formen
  /// ([kodierungenAufgeloest]), das einen Namensteil trifft, so wie es dort
  /// steht; null ohne Treffer.
  String? treffer(String text) {
    if (_teile.isEmpty || text.isEmpty) return null;
    for (final form in kodierungenAufgeloest(text)) {
      for (final m in _wort.allMatches(form)) {
        final w = m[0]!;
        final (mitE, ohne) = _formen(w);
        if (mitE.isEmpty) continue;
        if (_teile.contains(mitE) || _teile.contains(ohne)) return w;
      }
    }
    return null;
  }
}

/// Wo die letzte Sperre gegriffen hat, wie es die Warnung an die Lehrkraft
/// nennt.
enum SperrStelle {
  ergebnis('Antwort an die KI'),
  protokollzeile('Protokollzeile'),
  werkzeugliste('Werkzeugliste'),
  werkzeugaufruf('Aufruf eines Werkzeugs von moocp'),
  moodle('Anfrage an Moodle');

  const SperrStelle(this.text);
  final String text;
}

/// Ein Treffer der letzten Sperre, für die Warnung an die Lehrkraft: Plugin,
/// Werkzeug (null, wenn es keinen Aufruf gab), die Stelle und das Wort, so
/// wie es im Text stand. Nur für die Anzeige in der App; das Wort geht in
/// kein Protokoll und an keine KI. Bei [pfad] hat nicht ein Name getroffen,
/// sondern der Pfad des Ordners für Downloads (downloads.dart); [wort] ist
/// dann dieser Pfad.
class SperrTreffer {
  SperrTreffer({
    required this.plugin,
    required this.werkzeug,
    required this.stelle,
    required this.wort,
    this.pfad = false,
    DateTime? zeit,
  }) : zeit = zeit ?? DateTime.now();

  /// Der Anzeigename des Plugins.
  final String plugin;
  final String? werkzeug;
  final SperrStelle stelle;
  final String wort;
  final bool pfad;
  final DateTime zeit;

  /// Ohne das Wort: Ein Treffer, der versehentlich in einer Ausgabe landet,
  /// trägt den Namen nicht mit.
  @override
  String toString() => 'SperrTreffer(${stelle.name})';
}

/// Die Namen aller Plugins, je Plugin (nach Kurzname) getrennt: Namen, die
/// ein Plugin geladen hat, sperren nur seine eigenen Texte. Eine Menge für
/// die ganze App, über alle Instanzprofile; sie überlebt das Ende eines
/// Aufrufs, einen Neustart des Plugins und das Wiederverbinden eines
/// Entwicklungs-Plugins und endet mit der App.
class LetzteSperre {
  LetzteSperre({this.melden});

  /// Bekommt jeden Treffer, für die Warnung an die Lehrkraft; null ohne
  /// Oberfläche (Tests). Gesperrt wird auch ohne.
  final void Function(SperrTreffer treffer)? melden;

  final _je = <String, Namenssperre>{};

  /// Die gesperrten Pfade in ihrer Vergleichsform ([_pfadform]), mit dem
  /// Pfad, wie er genannt wurde, und dem letzten Teil der Vergleichsform für
  /// die schnelle Vorprüfung.
  final _pfade = <String, ({String pfad, String letzter})>{};

  /// Nimmt [namen] für das Plugin [kurzname] auf.
  void namenHinzufuegen(String kurzname, Iterable<String> namen) =>
      (_je[kurzname] ??= Namenssperre()).hinzufuegen(namen);

  /// Sperrt den Pfad eines Ordners (der Ordner für Downloads, downloads.dart)
  /// für jedes Plugin: Jeder Text, der ihn enthält, trifft. Verglichen wird
  /// als Teil des Texts, ohne Rücksicht auf Groß- und Kleinschreibung, mit
  /// `\` und `/` als gleichwertigen Trennern, auch doppelt (`\\` in JSON) oder
  /// gemischt. So trifft auch eine Datei darin und eine Adresse mit
  /// `file:///`. Wie bei Namen zählen die aufgelösten Formen des Texts mit
  /// ([kodierungenAufgeloest]: Prozentkodierung, Unicode-Escapes,
  /// HTML-Zeichenreferenzen). Nicht erkannt werden andere Kodierungen
  /// (Base64) und Kurznamen für einen anderen Teil des Pfads als den
  /// gesperrten; die Sperre bleibt die letzte, nicht die erste.
  void pfadSperren(String pfad) {
    var f = _pfadform(pfad);
    while (f.endsWith('/')) {
      f = f.substring(0, f.length - 1);
    }
    final letzter = f.split('/').last;
    // Ein Laufwerk oder die Wurzel allein sperrte jeden Pfad.
    if (letzter.isEmpty || !f.contains('/')) return;
    _pfade[f] = (pfad: pfad, letzter: letzter);
  }

  static String _pfadform(String s) => s.toLowerCase().replaceAll(RegExp(r'[\\/]+'), '/');

  /// Der gesperrte Pfad, den [text] oder eine seiner aufgelösten Formen
  /// ([kodierungenAufgeloest]) nennt, so wie er gesperrt wurde; sonst null.
  String? _pfadIn(String text) {
    if (_pfade.isEmpty || text.isEmpty) return null;
    for (final t in kodierungenAufgeloest(text)) {
      final klein = t.toLowerCase();
      String? form;
      for (final MapEntry(key: f, value: (:pfad, :letzter)) in _pfade.entries) {
        if (!klein.contains(letzter)) continue;
        form ??= _pfadform(t);
        if (form.contains(f)) return pfad;
      }
    }
    return null;
  }

  /// Wie viele verschiedene Namen für das Plugin [kurzname] geladen sind.
  int anzahl(String kurzname) => _je[kurzname]?.anzahl ?? 0;

  /// Das erste Wort aus [texte], das einen Namen des Plugins [kurzname]
  /// trifft, oder der gesperrte Pfad, den einer der Texte nennt; null ohne
  /// Treffer.
  String? treffer(String kurzname, Iterable<String> texte) => _suchen(kurzname, texte)?.wort;

  ({String wort, bool pfad})? _suchen(String kurzname, Iterable<String> texte) {
    final s = _je[kurzname];
    final namen = s != null && !s.leer;
    if (!namen && _pfade.isEmpty) return null;
    for (final t in texte) {
      final w = namen ? s.treffer(t) : null;
      if (w != null) return (wort: w, pfad: false);
      final pfad = _pfadIn(t);
      if (pfad != null) return (wort: pfad, pfad: true);
    }
    return null;
  }

  /// Prüft [texte] des Plugins [kurzname] und meldet einen Treffer der
  /// Lehrkraft ([melden]). Liefert true, wenn gesperrt ist.
  bool gesperrt(
    String kurzname,
    Iterable<String> texte, {
    required String plugin,
    required String? werkzeug,
    required SperrStelle stelle,
  }) {
    final t = _suchen(kurzname, texte);
    if (t == null) return false;
    melden?.call(SperrTreffer(plugin: plugin, werkzeug: werkzeug, stelle: stelle, wort: t.wort, pfad: t.pfad));
    return true;
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
