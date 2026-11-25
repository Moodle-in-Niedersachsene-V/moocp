// Die Datenschutzwarnung (E36): Enthält eine Antwort eines Plugins an die KI
// ein Wort, das der Name einer Person sein könnte, oder den Pfad eines
// Ordners, in dem Daten von Personen liegen können, hält die App die Antwort
// an und fragt die Lehrkraft, ob sie trotzdem an die KI geht
// ([Datenschutzwarnung]). Sagt sie „Sperren“, ist das die Datenschutzsperre:
// Die KI erfährt nur, dass etwas gesperrt wurde. Nichts wird gemerkt; die
// nächste Antwort wird neu geprüft.
//
// Hier steht, was geprüft und gefunden wird, ohne Flutter und ohne Ein- und
// Ausgabe: die Namen und Pfade je Plugin ([Datenschutzpruefung]) und die
// Treffer mit Herkunft und Umgebung ([Fund]). Die Regel für Wörter steht in
// namenssperre.dart; wo geprüft und gefragt wird, in laufende_plugins.dart
// (Antworten) und app_adresse.dart (Protokollzeilen).
//
// Pfade: Wer den Pfad eines Ordners kennt, kann die Dateien darin mit eigenen
// Mitteln lesen, an moocp vorbei. Es gibt zwei Quellen, beide in
// [Datenschutzpruefung]: den Ordner für Downloads (downloads.dart, für jedes
// Plugin) und Pfade, die ein Plugin selbst meldet (je Plugin). Eine neue
// Quelle ist ein weiterer Aufruf von [Datenschutzpruefung.pfadSperren] oder
// [Datenschutzpruefung.pfadHinzufuegen] mit einer [Herkunft].
//
// Alles steht nur im Arbeitsspeicher, bis die App endet, und in keiner
// Ausgabe: Keine Klasse hier hat ein `toString`, das ein Wort, eine Umgebung
// oder einen Pfad nennt.

import '../datenschutzwarnung.dart';
import 'namenssperre.dart';

export '../datenschutzwarnung.dart';

/// Ein gesperrter Pfad als Muster, das Trenner gleich behandelt.
class _Pfad {
  _Pfad(this.muster, this.letzter, this.herkunft);

  final RegExp muster;

  /// Der letzte Teil in Kleinbuchstaben für die schnelle Vorprüfung.
  final String letzter;
  final Herkunft herkunft;
}

/// Die Namen und Pfade, gegen die die App Texte der Plugins prüft: Namen je
/// Plugin (nach Kurzname) getrennt, Pfade für alle und je Plugin. Eine Menge
/// für die ganze App, über alle Instanzprofile; sie überlebt das Ende eines
/// Aufrufs, einen Neustart des Plugins und das Wiederverbinden eines
/// Entwicklungs-Plugins und endet mit der App.
class Datenschutzpruefung {
  final _je = <String, Namenssperre>{};
  final _pfade = <_Pfad>[];
  final _pfadeJe = <String, List<_Pfad>>{};

  /// Nimmt [namen] für das Plugin [kurzname] auf, aus [herkunft].
  void namenHinzufuegen(String kurzname, Iterable<String> namen, {Herkunft herkunft = Herkunft.pluginName}) =>
      (_je[kurzname] ??= Namenssperre()).hinzufuegen(namen, herkunft: herkunft);

  /// Wie viele verschiedene Namen für das Plugin [kurzname] geladen sind.
  int anzahl(String kurzname) => _je[kurzname]?.anzahl ?? 0;

  /// Nimmt den Pfad eines Ordners für jedes Plugin auf (der Ordner für
  /// Downloads, downloads.dart): Jeder Text, der ihn enthält, trifft.
  /// Verglichen wird als Teil des Texts, ohne Rücksicht auf Groß- und
  /// Kleinschreibung, mit `\` und `/` als gleichwertigen Trennern, auch
  /// doppelt (`\\` in JSON) oder gemischt. So trifft auch eine Datei darin und
  /// eine Adresse mit `file:///`. Wie bei Namen zählen die aufgelösten Formen
  /// des Texts mit ([kodierungenAufgeloest]). Nicht erkannt werden
  /// Prozentkodierung, Base64 und Kurznamen für einen anderen Teil des Pfads
  /// als den genannten.
  void pfadSperren(String pfad, {Herkunft herkunft = Herkunft.downloadOrdner}) {
    final p = _pfadAus(pfad, herkunft);
    if (p != null) _pfade.add(p);
  }

  /// Wie [pfadSperren], aber nur für Texte des Plugins [kurzname]: ein Pfad,
  /// den das Plugin selbst gemeldet hat. Pfade lassen sich nur hinzufügen.
  void pfadHinzufuegen(String kurzname, String pfad, {Herkunft herkunft = Herkunft.pluginPfad}) {
    final p = _pfadAus(pfad, herkunft);
    if (p != null) (_pfadeJe[kurzname] ??= []).add(p);
  }

  static _Pfad? _pfadAus(String pfad, Herkunft herkunft) {
    var f = pfad.toLowerCase().replaceAll(RegExp(r'[\\/]+'), '/');
    while (f.endsWith('/')) {
      f = f.substring(0, f.length - 1);
    }
    final teile = f.split('/');
    final letzter = teile.last;
    // Ein Laufwerk oder die Wurzel allein träfe jeden Pfad.
    if (letzter.isEmpty || teile.length < 2) return null;
    final muster = RegExp(teile.map(RegExp.escape).join(r'[\\/]+'), caseSensitive: false);
    return _Pfad(muster, letzter, herkunft);
  }

  List<_Pfad> _pfadeFuer(String kurzname) => [..._pfade, ...?_pfadeJe[kurzname]];

  /// Ob [texte] des Plugins [kurzname] einen Namen und ob sie einen Pfad
  /// treffen; schneller als [pruefen], weil beim ersten Treffer jeder Art
  /// Schluss ist. Für Zeilen, die nur durch einen Platzhalter ersetzt werden.
  ({bool name, bool pfad}) trifft(String kurzname, Iterable<String> texte) {
    final s = _je[kurzname];
    final namen = s != null && !s.leer;
    final pfade = _pfadeFuer(kurzname);
    var name = false;
    var pfad = false;
    for (final t in texte) {
      if (t.isEmpty) continue;
      if (!name && namen && s.treffer(t) != null) name = true;
      if (!pfad && pfade.isNotEmpty) {
        pfad = kodierungenAufgeloest(t).any((form) => _pfadFunde(pfade, form).isNotEmpty);
      }
      if (name && pfad) break;
    }
    return (name: name, pfad: pfad);
  }

  /// Das erste Wort (oder der erste Pfad) in [texte], das trifft, so wie es
  /// dort steht; null ohne Treffer. Kurz für Tests und Aufrufer, die nur das
  /// Ja oder Nein brauchen.
  String? treffer(String kurzname, Iterable<String> texte) => pruefen(kurzname, texte).firstOrNull?.wort;

  /// Alle Treffer in [texte] des Plugins [kurzname], je Text in der
  /// Reihenfolge, in der sie dort stehen (Namen und Pfade zusammen). Ein
  /// Wort, das in einer aufgelösten Form nur wieder auftaucht, weil schon die
  /// Rohform es trägt, zählt nicht doppelt.
  List<Fund> pruefen(String kurzname, Iterable<String> texte) {
    final s = _je[kurzname];
    final pfade = _pfadeFuer(kurzname);
    final aus = <Fund>[];
    for (final text in texte) {
      if (text.isEmpty) continue;
      // Wie oft jedes Wort in einer früheren Form stand: Nur mehr Vorkommen
      // sind neu.
      final bisher = <String, int>{};
      for (final form in kodierungenAufgeloest(text)) {
        final treffer = <(int, int, Set<Herkunft>, bool)>[
          if (s != null) for (final n in s.fundeIn(form)) (n.anfang, n.ende, n.herkunft, false),
          if (pfade.isNotEmpty)
            for (final (anfang, ende, h) in _pfadFunde(pfade, form)) (anfang, ende, {h}, true),
        ]..sort((a, b) => a.$1.compareTo(b.$1));
        final je = <String, int>{};
        for (final (anfang, ende, herkunft, pfad) in treffer) {
          final schluessel = '${pfad ? 'p' : 'n'}${form.substring(anfang, ende).toLowerCase()}';
          final n = je[schluessel] = (je[schluessel] ?? 0) + 1;
          if (n > (bisher[schluessel] ?? 0)) aus.add(_fund(form, anfang, ende, herkunft, pfad));
        }
        for (final MapEntry(:key, :value) in je.entries) {
          if (value > (bisher[key] ?? 0)) bisher[key] = value;
        }
      }
    }
    return aus;
  }

  static Iterable<(int, int, Herkunft)> _pfadFunde(List<_Pfad> pfade, String form) sync* {
    final klein = form.toLowerCase();
    for (final p in pfade) {
      if (!klein.contains(p.letzter)) continue;
      for (final m in p.muster.allMatches(form)) {
        yield (m.start, m.end, p.herkunft);
      }
    }
  }

  static Fund _fund(String form, int anfang, int ende, Set<Herkunft> herkunft, bool pfad) {
    var von = anfang - umgebungZeichen;
    final davorGekuerzt = von > 0;
    if (von < 0) von = 0;
    // Nicht mitten in einem Ersatzzeichen-Paar beginnen oder enden.
    if (von > 0 && von < anfang && _istNiederesHalb(form.codeUnitAt(von))) von++;
    var bis = ende + umgebungZeichen;
    final danachGekuerzt = bis < form.length;
    if (bis > form.length) bis = form.length;
    if (bis < form.length && bis > ende && _istHohesHalb(form.codeUnitAt(bis - 1))) bis--;
    String einzeilig(String t) => t.replaceAll(RegExp(r'\s+'), ' ');
    return Fund(
      wort: form.substring(anfang, ende),
      pfad: pfad,
      herkunft: herkunft.toList(),
      davor: einzeilig(form.substring(von, anfang)),
      danach: einzeilig(form.substring(ende, bis)),
      davorGekuerzt: davorGekuerzt,
      danachGekuerzt: danachGekuerzt,
    );
  }

  static bool _istNiederesHalb(int c) => c & 0xFC00 == 0xDC00;
  static bool _istHohesHalb(int c) => c & 0xFC00 == 0xD800;

  @override
  String toString() => 'Datenschutzpruefung()';
}
