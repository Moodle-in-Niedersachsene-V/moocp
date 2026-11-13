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
//
// Nicht abgedeckt: Namen, die ohne Trennung in einem längeren Wort stecken
// („ErikaMustermann“, „Erikas“), Schreibweisen über das hinaus, was die
// Tabelle unten kennt (Vollbreitenbuchstaben, Ligaturen wie „ﬁ“, Buchstaben
// außerhalb der lateinischen Schrift bleiben, wie sie sind, und treffen nur
// sich selbst), Kodierungen (HTML-Entitäten wie `&#69;`, `ü` in JSON,
// Prozentkodierung, Base64) und Tippfehler.
//
// Schnell auch bei vielen Namen und langen Texten: Jedes Wort des Texts wird
// einmal in seine Vergleichsform gebracht und in einer Menge nachgeschlagen;
// kein regulärer Ausdruck je Name.
//
// Die Namen stehen nur im Arbeitsspeicher, bis die App endet: in keiner Datei,
// keinem Protokoll, keiner Einstellung, keiner Fehlermeldung und keiner
// Antwort. Darum hat keine Klasse hier ein toString, das sie nennt, und es gibt
// keinen Weg, sie abzufragen oder zu entfernen.

/// Ein Wort im Sinn der Sperre (siehe oben).
final _wort = RegExp(r'[\p{L}\p{N}\p{M}\p{Cf}]+', unicode: true);

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

  /// Das erste Wort in [text], das einen Namensteil trifft, so wie es im
  /// Text steht; null ohne Treffer.
  String? treffer(String text) {
    if (_teile.isEmpty || text.isEmpty) return null;
    for (final m in _wort.allMatches(text)) {
      final w = m[0]!;
      final (mitE, ohne) = _formen(w);
      if (mitE.isEmpty) continue;
      if (_teile.contains(mitE) || _teile.contains(ohne)) return w;
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
  /// `file:///`. Nicht erkannt werden andere Kodierungen (Prozentkodierung,
  /// Unicode-Escapes, Base64) und Kurznamen für einen anderen Teil des Pfads als den
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

  /// Der gesperrte Pfad, den [text] nennt, so wie er gesperrt wurde; sonst
  /// null.
  String? _pfadIn(String text) {
    if (_pfade.isEmpty || text.isEmpty) return null;
    final klein = text.toLowerCase();
    String? form;
    for (final MapEntry(key: f, value: (:pfad, :letzter)) in _pfade.entries) {
      if (!klein.contains(letzter)) continue;
      form ??= _pfadform(text);
      if (form.contains(f)) return pfad;
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
