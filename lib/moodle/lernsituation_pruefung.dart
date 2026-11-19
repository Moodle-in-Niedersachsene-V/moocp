// Werkzeug lernsituation_pruefen: prüft eine Lernsituation auf das, was sich
// prüfen lässt -- den Entwurf im Arbeitsordner oder den Stand eines
// Abschnitts in Moodle, wie der Skill moodle ihn gerade gelesen hat.
//
// Der Entwurf ist ein Ordner im Arbeitsordner der App, schon in der Form, die
// die Werkzeuge nehmen (references/vorlagen.md im Skill lernsituation):
// lernsituation.json mit dem Abschnitt und den Aktivitäten in ihrer
// Reihenfolge, je Aktivität ein Ordner mit page.html bzw. introeditor.html und
// dateien/, ein Buch mit kapitel.json und kapitel-<id>/content_editor.html.
// Die zweite Form prüft einen Abschnitt, den der Skill moodle gerade gelesen
// hat (kurs_uebersicht, aktivitaet_lesen je Aktivität, buch_lesen je Buch) --
// dieselben Prüfungen, dazu die Links zwischen den Blättern (unten, „Entwurf
// und Stand in Moodle").
//
// Geprüft wird die FORM aus references/vorlagen.md -- nicht, ob die
// Lernsituation gut ist. Das kann keine Prüfung. Was sie kann:
//
//   - Handreichung vorhanden, ohne SchuCu-Tabelle, mit eigenen Abschnitten zu
//     Lernumgebung und Leistungsbewertung (sie kommt ohne die Tabelle aus)
//   - Seite „SchuCu" mit nichts als der Tabelle nach einer der CD-Vorlagen
//     (references/schucu-*.html) -- Zeilen, Klassen und Kopflink unverändert,
//     jede Datenzelle gefüllt, keine Platzhalter; darunter die Absätze der
//     Vorlage, der KI-Hinweis wörtlich
//   - jedes Arbeitsblatt (auch Hilfe und Vertiefung) hat eine Lösung
//   - der Name jedes Blatts beginnt mit seiner Kennung („Arbeitsblatt 2: …")
//   - jedes Blatt außer den Lösungen steht mit seiner Kennung im Ablaufplan
//     oder mit seinem Namen in der Materialübersicht; jede genannte Kennung
//     gibt es
//   - Zeiten im Ablaufplan: Summenzeile stimmt, Summe passt zum Zeitrichtwert
//   - jede Aufgabe auf einem Arbeitsblatt trägt (n min · Sozialform · AFB x)
//   - Aufgabenzeiten je Blatt gegen „Zeit gesamt" im Kopf
//   - Lösung hat dieselben Aufgabennummern wie das Blatt
//   - Checkliste vollständig beantwortet, mit Begründung
//   - Links ausgeschrieben (kein „hier" als Linktext), keine protokollrelativen
//     Adressen
//   - Zeichnungen: eingebundene SVG vorhanden, mit <title> und <desc>
//   - jedes Blatt steht für sich: Abschnitte „1. …", Abbildungen und Aufgaben
//     zählen je Blatt ab 1 ohne Präfix; „Abb. n" ohne Blattkennung gibt es auf
//     dem eigenen Blatt; Verweise auf Abschnitte, Abbildungen und Aufgaben
//     anderer Blätter treffen etwas, das es dort gibt; jedes Infoblatt wird
//     von einem Arbeitsblatt unter „Dazu" oder in einer „Lies"-Zeile genannt
//   - jede weitere Aktivität (Board, Kanban, Wiki, Fortschrittsliste, Test,
//     Verzeichnis, Datei, Link) trägt keine Kennung und steht mit ihrem Namen
//     in Anführungszeichen im Ablaufplan oder in der Materialübersicht; was
//     dort in Anführungszeichen steht, gibt es
//   - nur im Entwurf: lernsituation.json vollständig, jeder Ordner darin
//     genannt, jedes Bild in dateien/ seines Blatts, die HTML-Regeln
//     (references/html.md), keine Formelfehler, keine Platzhalter, kein
//     Markdown, kein Name eines Ordners oder einer Zeichnung im Text; jede
//     weitere Aktivität mit dem, was ihre Übertragung braucht (Spalten,
//     Einträge, Seiten, Fragen mit Sachnummer und Ort, Dateien, Adresse)
//   - nur in Moodle: jede Nennung eines Blatts ist ein Link auf seine
//     Aktivität, mit passendem Text, ebenso der Name einer weiteren Aktivität
//     in Anführungszeichen, und keine für Lernende erreichbare Seite verlinkt
//     eine Lösung
//
// Das Ergebnis: 0 = keine Befunde, 1 = Befunde, 2 = nichts zu prüfen.
//
// Gelesen wird nur im Arbeitsordner, an Moodle geht keine Anfrage. Ein Pfad
// aus lernsituation.json oder seiten.json, der aus dem Arbeitsordner
// herausführt, gilt als nicht vorhanden: Die Befunde zitieren Text, und Text
// von außerhalb ginge so an die KI. Reiner Dart-Code ohne Flutter; die
// Vorlagen der SchuCu-Tabelle bekommt die Prüfung vom Aufrufer (main.dart
// lädt sie als Assets, die Tests aus dem Skill-Ordner).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'elemente.dart';
import 'formeln.dart';
import 'lernsituation_html.dart';

const _ustd = 45;

/// Wo die CD-Vorlagen der SchuCu-Tabelle liegen: im Skill, als Asset der App
/// unter demselben Pfad. Sie sind die einzige Quelle für den Aufbau der
/// Tabelle; die Prüfung liest sie, statt eine Abschrift zu führen.
const schucuVorlagenOrdner = 'skills/lernsituation/references';

/// Die Vorlagen nach Schulform, in der Reihenfolge, in der die Prüfung sie
/// vergleicht.
const schucuVorlagenDateien = {
  'Berufsschule': 'schucu-berufsschule.html',
  'Berufliches Gymnasium': 'schucu-bg.html',
};

/// Das Ergebnis einer Prüfung: [code] 0 = keine Befunde, 1 = Befunde, 2 =
/// nichts zu prüfen; [ausgabe] die Befunde und Hinweise.
class LernsituationErgebnis {
  const LernsituationErgebnis(this.code, this.ausgabe);
  final int code;
  final String ausgabe;

  /// Die Antwort des Werkzeugs: eine Zeile mit dem Ergebnis, dann die Ausgabe.
  String get antwort => '${switch (code) {
    0 => 'Ergebnis: keine Befunde.',
    1 => 'Ergebnis: Befunde -- siehe unten.',
    _ => 'Ergebnis: nichts zu prüfen.',
  }}\n\n${ausgabe.trimRight()}';
}

// Die Prüfform (unten, „Entwurf und Stand in Moodle") legt jede Aktivität als
// Textdatei ab; diese Namen trägt sie. Die Handreichung und die Seite
// „SchuCu" -- die SchuCu-Tabelle steht allein auf einer eigenen Seite, in
// Moodle der ersten Aktivität des Abschnitts, damit sie bei einer Inspektion
// sofort zu finden ist.
const _hand = '00-lehrerhandreichung.md';
const _schucu = '00-schucu.md';

// Die Tabelle samt den Absätzen, die die Vorlage darunter setzt (KI-Hinweis,
// im Beruflichen Gymnasium davor die Legende der Kompetenzbereiche).
final _tabelleRe = pyRe(
  r'<table class="lernsituation">.*?</table>(?:\s*<p\b[^>]*>.*?</p>)*',
  dotAll: true,
);

// ---- Jedes Blatt steht für sich --------------------------------------------
// Ein Blatt wird einzeln gedruckt, ausgeteilt und Wochen später einzeln
// nachgelesen; in Moodle ist es eine eigene Seite. Deshalb zählt jedes Blatt
// ab 1, und ein Bezug auf ein anderes Blatt nennt dessen Kennung und die
// Stelle. Die Formen sind fest (references/vorlagen.md), weil sich nur feste
// Formen prüfen lassen: „Abb. 1" ohne Kennung meint das eigene Blatt, eine
// Kennung irgendwo in der Nähe zählt nicht. Alle Muster erlauben Zeilenumbrüche
// zwischen den Wörtern.
//
// Die Kennung ist der Anfang des Namens der Aktivität -- so findet man jedes
// genannte Blatt in der Kursübersicht wieder: „Arbeitsblatt 2", „Infoblatt 1",
// „Hilfe zu Arbeitsblatt 3", „Vertiefung zu Arbeitsblatt 2", „Lösung zu
// Arbeitsblatt 2", „Lösung zur Hilfe zu Arbeitsblatt 3". In Moodle wird jeder
// Verweis ein Link mit der Kennung als Text -- online zum Klicken, gedruckt
// bleibt der Text. Dieselben Formen setzt links_setzen (links.dart); wer eine
// ändert, prüft beide.
const _blatt = r'(?:(?:Hilfe|Vertiefung)\s+zu\s+)?(?:Arbeitsblatt|Infoblatt)\s+\d+';
// Wie ein Verweis sein Ziel nennt: Kennung oder die Lösung dazu.
const _ziel = r'(?:Lösung\s+zur?\s+)?' + _blatt;

/// Wie ein Verweis ein Blatt nennt: die Kennung oder „Lösung zu" davor.
final blattZiel = pyRe(_ziel);

// Ein eingebundenes Bild in der Prüfform.
final _bild = pyRe(r'!\[[^\]]*\]\(([^)]+)\)');
// Nummern: „3", „1 und 4", „1 bis 3", „1–3", „1, 2 und 5".
const _nummern = r'\d+(?:\s*(?:,|und|bis|–|-)\s*\d+)*';

final _abschnittKopf = pyRe(r'^##\s+(\d+)\.\s', multiLine: true);
final _abbUnterschrift = pyRe(r'^\*Abb\.\s*([^:*\n]+?)\s*:', multiLine: true);
final _aufgabeKopf = pyRe(r'^##\s+Aufgabe\s+(\d+)', multiLine: true);
final _verweisAbschnitt = pyRe('($_ziel),\\s*Abschnitte?\\s+($_nummern)');
final _verweisAbb = pyRe('Abb\\.\\s*($_nummern)\\s+(?:auf|in(?:\\s+der)?)\\s+($_ziel)');
final _verweisAbbGanz = pyReGanz('Abb\\.\\s*($_nummern)\\s+(?:auf|in(?:\\s+der)?)\\s+($_ziel)');
final _verweisAufgabe = pyRe(
  '\\bAufgaben?\\s+($_nummern)\\s+(?:auf|von)\\s+($_ziel)|($_ziel),\\s*Aufgaben?\\s+($_nummern)',
);
// „**Lies:**", „**Lest noch einmal:**", „**Lesen Sie:**" -- je Anrede; bis zur
// Leerzeile. Nennt sie ein Lehrbuch oder eine Adresse statt eines Infoblatts,
// gibt es hier nichts zu prüfen; ebenso bei „**Recherchiere:**".
final _lies = pyRe(
  r'^\*\*(?:Lies|Lest|Lesen\s+Sie)\b[^*\n]*:\*\*(.*?)(?=\n[ \t]*\n|\Z)',
  multiLine: true,
  dotAll: true,
);
// Kopfzeile; sie darf umbrochen sein und endet am nächsten Feld.
final _dazu = pyRe(r'\*\*Dazu:\*\*(.*?)(?=·|\*\*|\n[ \t]*\n|\Z)', dotAll: true);

final _leer = pyRe(r'\s+');
final _ziffern = RegExp(r'^[0-9]+$');

/// Leerraum zu einem Leerzeichen, außen weg.
String textNorm(String t) => pyStrip(t.replaceAll('\xa0', ' ').replaceAll(_leer, ' '));

bool _istZahl(String s) => _ziffern.hasMatch(s);

final _nummernTeiler = pyRe(r',|\bund\b');
final _nummernBereich = pyReGanz(r'\s*(\d+)\s*(?:bis|–|-)\s*(\d+)\s*');

/// „1 und 4" -> [1, 4]; „1 bis 3" und „1–3" -> [1, 2, 3].
List<int> _nummernListe(String s) {
  final raus = <int>[];
  for (final teil in s.split(_nummernTeiler)) {
    final m = pyMatch(_nummernBereich, teil);
    if (m != null) {
      for (var n = int.parse(m[1]!); n <= int.parse(m[2]!); n++) {
        raus.add(n);
      }
    } else if (_istZahl(pyStrip(teil))) {
      raus.add(int.parse(pyStrip(teil)));
    }
  }
  return raus;
}

final _kennungDatei = pyRe(r'(AB|IB)-(\d+)-.*?(-hilfe|-vertiefung)?(-loesung)?\.md$');

/// Aus dem Namen in der Prüfform: AB-02-x-vertiefung.md ->
/// ('Vertiefung zu Arbeitsblatt 2', false), die Lösung dazu ->
/// ('Vertiefung zu Arbeitsblatt 2', true), AB-00-x.md ->
/// ('Handlungssituation', false), alles, was kein Blatt ist -> (null, false).
(String?, bool) _kennung(String datei) {
  final m = pyMatch(_kennungDatei, datei);
  if (m == null) return (null, false);
  final nr = int.parse(m[2]!);
  if (m[1] == 'AB' && nr == 0) return ('Handlungssituation', false);
  var k = '${m[1] == 'AB' ? 'Arbeitsblatt' : 'Infoblatt'} $nr';
  if (m[3] != null) k = '${m[3] == '-hilfe' ? 'Hilfe' : 'Vertiefung'} zu $k';
  return (k, m[4] != null);
}

/// Womit der Titel beginnt: die Kennung, bei einer Lösung mit
/// „Lösung zu" / „Lösung zur" davor.
String _titelSoll(String k, bool loesung) {
  if (!loesung) return k;
  return (k.startsWith('Hilfe') || k.startsWith('Vertiefung') ? 'Lösung zur ' : 'Lösung zu ') + k;
}

final _loesungZur = pyRe(r'^Lösung zur ');

/// Ein Verweisziel so, wie es im Verzeichnis der Blätter steht.
String verweisSchluessel(String s) => textNorm(s).replaceFirst(_loesungZur, 'Lösung zu ');

typedef _Gliederung = (List<int>, List<String>, List<int>);

/// Nummerierte Abschnitte, Bildunterschriften und Aufgaben eines Blatts.
_Gliederung _gliederung(String t) => (
  [for (final n in findeGruppe(_abschnittKopf, t)) int.parse(n)],
  findeGruppe(_abbUnterschrift, t),
  [for (final n in findeGruppe(_aufgabeKopf, t)) int.parse(n)],
);

bool _listenGleich<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---- SchuCu-Tabelle ----------------------------------------------------------

class _Zelle {
  _Zelle(this.klasse, this.colspan);
  final String? klasse;
  final String? colspan;
  String text = '';
  String span = '';
  final links = <List<String?>>[];
}

/// Zerlegt die SchuCu-Tabelle in Zeilen und Zellen.
///
/// Je Zelle: Klasse, colspan, Text ohne <span> (das ist die Beschriftung),
/// Text im <span>, Links (href, Text). Dazu die Absätze unter der Tabelle,
/// je als [style, Text].
class _SchucuLeser extends PyHtmlLeser {
  final zeilen = <List<_Zelle>>[];
  _Zelle? zelle;
  int span = 0;
  List<String?>? a;
  final absaetze = <(String?, String)>[];
  bool inP = false;

  @override
  void starttag(String tag, List<Attribut> attrs) {
    final at = attributMap(attrs);
    if (tag == 'tr') {
      zeilen.add([]);
    } else if (tag == 'td') {
      zelle = _Zelle(
        at.containsKey('class') ? at['class'] : '',
        at.containsKey('colspan') ? at['colspan'] : '1',
      );
      // Eine Zelle vor jeder Zeile gibt es in keiner Vorlage; sie steht dann
      // in einer eigenen Zeile und weicht so von der Vorlage ab.
      if (zeilen.isEmpty) zeilen.add([]);
      zeilen.last.add(zelle!);
    } else if (tag == 'span' && zelle != null) {
      span++;
    } else if (tag == 'a' && zelle != null) {
      a = [at.containsKey('href') ? at['href'] : '', ''];
      zelle!.links.add(a!);
    } else if (tag == 'br' && zelle != null) {
      zelle!.text += ' ';
    } else if (tag == 'p' && zelle == null) {
      inP = true;
      absaetze.add((at['style'], ''));
    } else if (tag == 'br' && inP) {
      final (s, t) = absaetze.last;
      absaetze.last = (s, '$t ');
    }
  }

  @override
  void endtag(String tag) {
    if (tag == 'td') {
      zelle = null;
    } else if (tag == 'span' && span > 0) {
      span--;
    } else if (tag == 'a') {
      a = null;
    } else if (tag == 'p') {
      inP = false;
    }
  }

  @override
  void daten(String d) {
    final z = zelle;
    if (z != null) {
      if (span > 0) {
        z.span += d;
      } else {
        z.text += d;
      }
      if (a != null) a![1] = '${a![1]}$d';
    } else if (inP) {
      final (s, t) = absaetze.last;
      absaetze.last = (s, t + d);
    }
  }
}

(List<List<_Zelle>>, List<(String?, String)>) _liesTabelle(String roh) {
  final l = _SchucuLeser()..lesen(roh);
  for (final z in l.zeilen) {
    for (final c in z) {
      c.text = textNorm(c.text);
      c.span = textNorm(c.span);
      for (final link in c.links) {
        link[1] = textNorm(link[1]!);
      }
    }
  }
  return (l.zeilen, [for (final (s, t) in l.absaetze) (s, textNorm(t))]);
}

typedef _Geruest = List<List<(String?, String?, String?)>>;

/// Aufbau ohne Inhalt: je Zelle Klasse, colspan und -- außer bei
/// Datenzellen -- die Beschriftung.
_Geruest _geruestVon(List<List<_Zelle>> zeilen) => [
  for (final z in zeilen)
    [for (final c in z) (c.klasse, c.colspan, c.klasse == 'lsdata' ? null : c.text)],
];

bool _zeileGleich(List<(String?, String?, String?)> a, List<(String?, String?, String?)> b) =>
    _listenGleich(a, b);

bool _linksGleich(List<List<String?>> a, List<List<String?>> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_listenGleich(a[i], b[i])) return false;
  }
  return true;
}

typedef _Vorlage = (_Geruest, List<List<_Zelle>>, List<(String?, String)>);

String _zeilenumbrueche(String t) => t.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

// ---- Die Prüfform ----------------------------------------------------------

/// Eine Datei der Prüfform: ein Text, den die Prüfung geschrieben hat, oder
/// eine Datei aus dateien/ einer Aktivität, die dorthin kopiert wäre.
class _Pruefdatei {
  _Pruefdatei.text(String this.text) : pfad = null;
  _Pruefdatei.kopie(String this.pfad) : text = null;
  final String? text;
  final String? pfad;
}

class _Pruefung {
  /// [bilddateien]: ob ein eingebundenes Bild, das in der Prüfform fehlt,
  /// ein Befund ist. Am Entwurf nicht -- dort meldet [_EntwurfLeser]
  /// genauer, in welchem dateien/ es fehlt. [weitere]: {Name: wie ein Befund
  /// sie nennt} der weiteren Aktivitäten (_weitere), die keine Blätter sind.
  _Pruefung(
    this.ordner,
    this.vorlagen,
    this.aus, {
    this.bilddateien = true,
    Map<String, String> weitere = const {},
  }) : weitere = Map.of(weitere);

  final Map<String, _Pruefdatei> ordner;
  final Map<String, _Vorlage> vorlagen;
  final StringBuffer aus;
  final bool bilddateien;
  final Map<String, String> weitere;
  // Namen in Anführungszeichen in Ablaufplan und Materialübersicht.
  final zitiert = <String>{};
  final befunde = <(String, String)>[];
  final hinweise = <String>[];

  void befund(String datei, String text) {
    // Derselbe Verweis kann auf einem Blatt mehrmals stehen; ein Befund genügt.
    if (!befunde.contains((datei, text))) befunde.add((datei, text));
  }

  void hinweis(String text) => hinweise.add(text);

  String lies(String name) {
    final d = ordner[name]!;
    return _zeilenumbrueche(d.text ?? utf8.decode(File(d.pfad!).readAsBytesSync()));
  }

  // ---- Tabellen -------------------------------------------------------------

  /// Alle Markdown-Tabellen als Liste von Zeilenlisten (Zellen getrimmt).
  static List<List<List<String>>> tabellen(String text) {
    final raus = <List<List<String>>>[];
    var akt = <List<String>>[];
    for (final z in text.split('\n')) {
      final s = pyStrip(z);
      if (s.startsWith('|')) {
        akt.add([for (final c in _stripZeichen(s, '|').split('|')) pyStrip(c)]);
      } else {
        if (akt.isNotEmpty) raus.add(akt);
        akt = [];
      }
    }
    if (akt.isNotEmpty) raus.add(akt);
    return raus;
  }

  static String _stripZeichen(String s, String z) {
    var a = 0, e = s.length;
    while (a < e && s[a] == z) {
      a++;
    }
    while (e > a && s[e - 1] == z) {
      e--;
    }
    return s.substring(a, e);
  }

  static final _trenner = pyReGanz(r':?-{2,}:?');

  static bool istTrenner(List<String> zeile) =>
      zeile.where((c) => c.isNotEmpty).every((c) => _trenner.hasMatch(c));

  // ---- Handreichung ---------------------------------------------------------
  static const checkliste = [
    'realistische Handlungssituation', 'konkrete Problemstellung',
    'mehrere Lösungswege', 'Entscheidungen', 'Phasen der vollständigen Handlung',
    'Handlungsergebnis', 'Personalkompetenzen', 'selbstständig',
    'kooperative', 'Reflexionsphase', 'Dienen die Inhalte', 'Rahmen',
    'schulische Entscheidungen',
  ];

  static final _materialKennung = pyRe('(?:Lösung\\s+zur?\\s+)?$_blatt|Handlungssituation');
  static final _schritt = pyRe(r'^###\s+Schritt\s+\d+', multiLine: true);
  static final _phasen = pyRe(r'^##\s+Phasen', multiLine: true);

  /// Prüft die Handreichung; [richt] ist der Zeitrichtwert aus der
  /// SchuCu-Tabelle in Minuten (oder null).
  (Set<String>, List<String>) handreichung(String name, int? richt) {
    // Eine SchuCu-Tabelle hier meldet schon, wer die Seiten liest (unten,
    // „Entwurf und Stand in Moodle") -- die Prüfform hat keine Tags mehr.
    final t = lies(name);
    platzhalter(name, t);
    final tabs = tabellen(t);

    // Ablaufplan
    List<List<String>>? plan;
    for (final tab in tabs) {
      final kopf = [for (final c in tab[0]) c.toLowerCase()];
      if (kopf.any((c) => c.contains('zeit')) && kopf.any((c) => c.contains('material'))) {
        plan = tab;
        break;
      }
    }
    final genannt = <String>{};
    if (plan == null) {
      befund(name, 'Ablaufplan-Tabelle (Spalten Zeit und Material) fehlt');
    } else {
      final kopf = [for (final c in plan[0]) c.toLowerCase()];
      final iz = kopf.indexWhere((c) => c.contains('zeit'));
      final im = kopf.indexWhere((c) => c.contains('material'));
      final ip = kopf.indexWhere((c) => c.contains('phase'));
      final isf = kopf.indexWhere((c) => c.contains('sozialform'));
      var summe = 0, nr = 0;
      int? summenzeile;
      final groesster = iz > im ? iz : im;
      // Eine Zeile mit weniger Zellen als der Kopf hat in der Spalte nichts.
      String zelle(List<String> z, int i) => i < z.length ? z[i] : '';
      for (final z in plan.skip(1)) {
        if (istTrenner(z) || z.length <= groesster) continue;
        final zeit = pyStrip(z[iz].replaceAll('*', ''));
        if (z.join(' ').toLowerCase().contains('summe')) {
          summenzeile = _istZahl(zeit) ? int.parse(zeit) : null;
          continue;
        }
        nr++;
        if (!_istZahl(zeit)) {
          befund(name, 'Ablaufplan Zeile $nr: Zeit ist keine Zahl (${pyRepr(zeit)})');
        } else {
          summe += int.parse(zeit);
        }
        if (ip >= 0 && pyStrip(zelle(z, ip)).isEmpty) {
          befund(name, 'Ablaufplan Zeile $nr: Phase fehlt');
        }
        if (isf >= 0 && pyStrip(zelle(z, isf)).isEmpty) {
          befund(name, 'Ablaufplan Zeile $nr: Sozialform fehlt');
        }
        // Material: Kennungen und Namen weiterer Aktivitäten in
        // Anführungszeichen, durch Komma getrennt, oder „—".
        for (final k in findeAlle(_materialKennung, z[im])) {
          genannt.add(verweisSchluessel(k));
        }
        for (final q in findeGruppe(_zitiert, z[im])) {
          zitiert.add(textNorm(q));
        }
      }
      if (summenzeile == null) {
        befund(name, 'Ablaufplan: Summenzeile fehlt oder nicht lesbar');
      } else if (summenzeile != summe) {
        befund(name, 'Ablaufplan: Summenzeile sagt $summenzeile, die Zeilen ergeben $summe');
      }
      if (richt != null && summe != 0) {
        final abw = summe - richt;
        if (abw.abs() > richt * 0.1) {
          befund(
            name,
            'Ablaufplan: $summe min geplant bei Zeitrichtwert $richt min (${abw >= 0 ? '+' : ''}$abw)',
          );
        } else {
          hinweis('Ablaufplan: $summe min bei Richtwert $richt min');
        }
      }
      // Je Zeile ein Detailabschnitt? In der Textseite <h4>, im Buch
      // ein Unterkapitel -- beides ### in der Prüfform.
      final schritte = _schritt.allMatches(t).length;
      if (schritte < nr) {
        befund(
          name,
          'Ablaufplan hat $nr Zeilen, aber nur $schritte Schritte -- je Zeile eine '
          'Überschrift „Schritt n: …" unter „Die Schritte im Einzelnen"',
        );
      }
    }

    // Materialübersicht: je Zeile der Name eines Blatts, so wie er im Titel
    // steht und in Moodle heißt -- dort wird er ein Link mit genau diesem
    // Text. Zeichnungen stehen nicht darin; sie gehören zu ihrem Blatt.
    final namen = <String>[];
    for (final tab in tabs) {
      final kopf = [for (final c in tab[0]) c.toLowerCase()];
      if (kopf.isNotEmpty && kopf[0].contains('datei')) {
        befund(
          name,
          'Materialübersicht nennt Dateien -- in Moodle gibt es nur '
          'Aktivitäten; erste Spalte "Blatt" mit dem Namen des Blatts',
        );
      }
      if (kopf.isNotEmpty && kopf[0] == 'blatt') {
        for (final z in tab.skip(1)) {
          if (istTrenner(z) || pyStrip(z[0]).isEmpty) continue;
          if (_verweisAbbGanz.hasMatch(pyStrip(z[0]))) {
            befund(
              name,
              'Materialübersicht: "${textNorm(z[0])}" -- Zeichnungen gehören zu ihrem '
              'Blatt und stehen hier nicht',
            );
            continue;
          }
          final q = pyMatch(_zitiertGanz, pyStrip(z[0]));
          if (q != null) {
            // eine weitere Aktivität
            zitiert.add(textNorm(q[1]!));
            continue;
          }
          namen.add(textNorm(z[0]));
        }
      }
    }

    // Checkliste
    var gefunden = 0;
    for (final tab in tabs) {
      final kopf = tab[0].join(' ').toLowerCase();
      if (kopf.contains('frage') && kopf.contains('ja/nein')) {
        for (final z in tab.skip(1)) {
          if (istTrenner(z) || z.length < 2) continue;
          gefunden++;
          final antwort = pyStrip(z[1]).toLowerCase();
          if (antwort != 'ja' && antwort != 'nein') {
            befund(name, 'Checkliste: "${pyKurz(z[0], 50)}" ohne Ja/Nein');
          }
          if (z.length < 3 || pyLen(pyStrip(z[2])) < 8) {
            befund(name, 'Checkliste: "${pyKurz(z[0], 50)}" ohne Begründung');
          }
        }
      }
    }
    if (gefunden < checkliste.length) {
      befund(name, 'Checkliste: $gefunden von ${checkliste.length} Fragen gefunden');
    }

    // Phasen genannt?
    if (!_phasen.hasMatch(t)) {
      befund(name, 'Abschnitt „Phasen der vollständigen Handlung" fehlt');
    }

    // Die Handreichung kommt ohne die SchuCu-Tabelle aus: Was dort nur
    // kurz steht, steht hier ausführlich.
    for (final abschnitt in ['Lernumgebung', 'Leistungsfeststellung und -bewertung']) {
      if (!pyRe('^##\\s+${pyEscape(abschnitt)}\\s*\$', multiLine: true).hasMatch(t)) {
        befund(
          name,
          'Abschnitt „$abschnitt" fehlt -- die Handreichung muss ohne '
          'die SchuCu-Tabelle auskommen',
        );
      }
    }

    links(name, t);
    // Auch die Handreichung verweist auf Abbildungen der Blätter; ohne
    // Kennung meint „Abb. n" ihre eigene.
    fuerSich(name, t);
    return (genannt, namen);
  }

  // ---- SchuCu-Tabelle -------------------------------------------------------

  /// Prüft die SchuCu-Seite: Überschrift, nichts als die Tabelle, die
  /// Tabelle selbst. Gibt den Zeitrichtwert in Minuten zurück (oder null).
  int? schucuSeite(List<String> dateien) {
    const name = _schucu;
    if (!dateien.contains(name)) {
      befund(
        name,
        'Seite „SchuCu" fehlt -- die Tabelle aus references/schucu-*.html '
        'steht allein auf einer Textseite dieses Namens, als erster Aktivität',
      );
      return null;
    }
    final t = lies(name);
    final umbruch = t.indexOf('\n');
    final kopf = umbruch < 0 ? t : t.substring(0, umbruch);
    final rumpf = umbruch < 0 ? '' : t.substring(umbruch + 1);
    if (pyStrip(kopf) != '# SchuCu') {
      befund(name, 'Die Seite mit der SchuCu-Tabelle muss „SchuCu" heißen');
    }
    final tabellen = findeAlle(_tabelleRe, rumpf);
    final rest = pyStrip(rumpf.replaceAll(_tabelleRe, ''));
    if (tabellen.isNotEmpty && rest.isNotEmpty) {
      befund(name, 'Auf der SchuCu-Seite steht mehr als die Tabelle: "${pyKurz(_htmlText(rest), 60)}"');
    }
    return schucu(name, tabellen);
  }

  static final _markdownLink = pyRe(r'\[[^\]]+\]\(');
  static final _platzhalterTag = pyRe(r'<[^>]+>');
  static final _punkte = pyRe(r'\.\.\.|…');
  static final _minuten = pyRe(r'(\d+)\s*min');
  static final _stunden = pyRe(r'(\d+)\s*UStd');
  static final _legende = pyRe(r'\b([A-Z]):');
  static final _bereich = pyRe(r'[^\s,;]+');

  /// Prüft die SchuCu-Tabelle gegen die CD-Vorlagen; gibt den
  /// Zeitrichtwert in Minuten zurück (oder null).
  int? schucu(String name, List<String> tabellen) {
    if (tabellen.isEmpty) {
      befund(
        name,
        'SchuCu-Tabelle fehlt (<table class="lernsituation"> '
        'aus references/schucu-*.html)',
      );
      return null;
    }
    if (tabellen.length > 1) {
      befund(name, 'SchuCu-Tabelle steht ${tabellen.length}-mal da');
    }
    final roh = tabellen[0];
    if (roh.contains('**') || _markdownLink.hasMatch(roh)) {
      befund(
        name,
        'Markdown in der SchuCu-Tabelle wird nicht umgesetzt -- '
        '<strong> und <a href> verwenden',
      );
    }

    final (zeilen, absaetze) = _liesTabelle(roh);
    final ger = _geruestVon(zeilen);
    String? art;
    for (final e in vorlagen.entries) {
      if (_listenGleichMit(e.value.$1, ger)) {
        art = e.key;
        break;
      }
    }
    if (art == null) {
      // Die nächste Vorlage suchen, um die erste Abweichung zu nennen.
      int gleich(_Geruest g) {
        var n = 0;
        while (n < g.length && n < ger.length && _zeileGleich(g[n], ger[n])) {
          n++;
        }
        return n;
      }

      // Wie max() in Python: bei Gleichstand die erste.
      late String naechste;
      late _Geruest g;
      var bester = -1;
      for (final e in vorlagen.entries) {
        final n = gleich(e.value.$1);
        if (n > bester) {
          bester = n;
          naechste = e.key;
          g = e.value.$1;
        }
      }
      final i = gleich(g);
      String zeig(List<(String?, String?, String?)> zl) =>
          [for (final x in zl) (x.$3 != null && x.$3!.isNotEmpty) ? x.$3 : x.$1].join(' | ');
      final soll = i < g.length ? zeig(g[i]) : '(Ende)';
      final ist = i < ger.length ? zeig(ger[i]) : '(Ende)';
      befund(
        name,
        'SchuCu-Tabelle weicht von der Vorlage $naechste ab, Zeile ${i + 1}: '
        'erwartet "$soll", steht da "$ist"',
      );
      return null;
    }
    hinweis('SchuCu-Tabelle: Vorlage $art');
    final (_, vorlage, vorlageAbs) = vorlagen[art]!;

    // Kopflink unverändert
    if (!_linksGleich(zeilen[0][0].links, vorlage[0][0].links)) {
      befund(name, 'SchuCu-Kopf: Link "offizielle Erläuterungen" geändert');
    }

    // Absätze unter der Tabelle wie in der Vorlage: dieselbe Zahl und
    // dieselbe Form. Einer ohne Platzhalter (der KI-Hinweis) steht
    // wörtlich da, einer mit Platzhalter wird ausgefüllt (die Legende).
    final ausgefuellt = <String>[];
    if (!_listenGleich([for (final (s, _) in absaetze) s], [for (final (s, _) in vorlageAbs) s])) {
      befund(
        name,
        'SchuCu: unter der Tabelle stehen nicht die Absätze der Vorlage '
        '$art -- erwartet ${[for (final (_, v) in vorlageAbs) '"$v"'].join(' + ')}',
      );
    } else {
      for (var i = 0; i < absaetze.length; i++) {
        final ist = absaetze[i].$2, soll = vorlageAbs[i].$2;
        if (soll.contains('<')) {
          ausgefuellt.add(ist);
        } else if (ist != soll) {
          befund(name, 'SchuCu: Absatz unter der Tabelle geändert -- erwartet "$soll"');
        }
      }
    }

    // Datenzellen: gefüllt, ohne Platzhalter der Vorlage
    final werte = <String?, String>{};
    String? titel;
    String ohneDoppelpunkt(String? t) => _rechtsOhne(t ?? 'None', ':');
    for (final z in zeilen) {
      for (final c in z) {
        if (c.klasse == 'lshead' || c.klasse == 'lssubhead') {
          titel = c.text;
        } else if (c.klasse == 'lsdata') {
          werte[titel] = c.text;
          if (pyStrip(c.text.replaceAll(_punkte, '')).isEmpty) {
            befund(name, 'SchuCu-Zeile leer: ${ohneDoppelpunkt(titel)}');
          } else if (_platzhalterTag.hasMatch(c.text)) {
            befund(name, 'SchuCu-Zeile mit Platzhalter der Vorlage: ${ohneDoppelpunkt(titel)}');
          }
        }
      }
    }

    // Zeitrichtwert
    int? richt;
    final w = werte['gepl. Zeitrichtwert:'] ?? '';
    final mm = _minuten.firstMatch(w);
    final us = _stunden.firstMatch(w);
    if (mm != null) {
      richt = int.parse(mm[1]!);
    } else if (us != null) {
      richt = int.parse(us[1]!) * _ustd;
    }
    if (richt == null) {
      befund(name, 'Zeitrichtwert nicht lesbar (erwartet "n UStd" oder "n min")');
    }

    if (art == 'Berufliches Gymnasium') {
      // Lehrplan des Fachs unter „Curricularer Bezug"
      final bezug = zeilen
          .expand((z) => z)
          .firstWhere((c) => c.klasse == 'lssubhead' && c.text == 'Curricularer Bezug:');
      for (final link in bezug.links) {
        final href = link[0], text = link[1]!;
        if (href == null || !href.startsWith('http') || '$href$text'.contains('<') || text.isEmpty) {
          befund(name, 'SchuCu: Link zum Lehrplan des Fachs nicht ausgefüllt');
        }
      }
      if (bezug.links.isEmpty && (bezug.span.isEmpty || bezug.span.contains('<'))) {
        befund(name, 'SchuCu: Lehrplan des Fachs fehlt unter "Curricularer Bezug"');
      }
      // Kompetenzbereiche: nur abgedeckte Buchstaben, jeder in der Legende
      var legende = <String>{};
      final absatz = ausgefuellt.isNotEmpty ? ausgefuellt[0] : null;
      if (absatz == null || absatz.isEmpty || absatz.contains('<')) {
        befund(name, 'SchuCu: Legende der Kompetenzbereiche unter der Tabelle fehlt');
      } else {
        legende = findeGruppe(_legende, absatz).toSet();
      }
      final bereiche = werte['Abgedeckte Kompetenzbereiche'] ?? '';
      if (legende.isNotEmpty && bereiche.isNotEmpty && !bereiche.contains('<')) {
        final falsch = [
          for (final b in findeAlle(_bereich, bereiche))
            if (!legende.contains(b)) b,
        ];
        if (falsch.isNotEmpty) {
          befund(
            name,
            'SchuCu: Kompetenzbereich(e) ${falsch.join(', ')} stehen nicht in der '
            'Legende',
          );
        }
      }
    }
    return richt;
  }

  static bool _listenGleichMit(_Geruest a, _Geruest b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_zeileGleich(a[i], b[i])) return false;
    }
    return true;
  }

  static String _rechtsOhne(String s, String z) {
    var e = s.length;
    while (e > 0 && s[e - 1] == z) {
      e--;
    }
    return s.substring(0, e);
  }

  // ---- Blätter --------------------------------------------------------------
  static final _aufgabe = pyRe(r'^##\s+Aufgabe\s+(\d+)\s*\(([^)]*)\)', multiLine: true);
  static final _klammerTeiler = pyRe(r'[·•]');
  static final _zeitMin = pyReGanz(r'(\d+)\s*min');
  static final _afb = pyReGanz(r'AFB\s*(I{1,3})');
  static final _zeitGesamt = pyRe(r'Zeit gesamt:\*?\*?\s*(\d+)\s*min');

  /// Prüft ein Arbeitsblatt, eine Hilfe oder Vertiefung; gibt die
  /// Nummern seiner Aufgaben zurück.
  List<int> arbeitsblatt(String name) {
    final t = lies(name);
    titel(name, t);
    fuerSich(name, t);
    final aufgaben = [for (final m in _aufgabe.allMatches(t)) (m[1]!, m[2]!)];
    if (aufgaben.isEmpty) {
      befund(name, 'keine Aufgabe in der Form <h3>Aufgabe n (n min · Sozialform · AFB x)</h3>');
      return [];
    }
    final nummern = [for (final (nr, _) in aufgaben) int.parse(nr)];
    if (!_listenGleich(nummern, [for (var i = 1; i <= nummern.length; i++) i])) {
      befund(name, 'Aufgaben ${nummern.join(', ')} -- jedes Blatt zählt seine Aufgaben ab 1, ohne Lücke');
    }
    var summe = 0;
    for (final (nr, klammer) in aufgaben) {
      final teile = [for (final x in klammer.split(_klammerTeiler)) pyStrip(x)];
      if (teile.length != 3) {
        befund(name, 'Aufgabe $nr: Klammer braucht drei Teile (Zeit · Sozialform · AFB)');
        continue;
      }
      final [zeit, sozial, afb] = teile;
      final m = pyMatch(_zeitMin, zeit);
      if (m == null) {
        befund(name, 'Aufgabe $nr: Zeit fehlt oder nicht "n min" (${pyRepr(zeit)})');
      } else {
        summe += int.parse(m[1]!);
      }
      if (sozial.isEmpty) befund(name, 'Aufgabe $nr: Sozialform fehlt');
      if (pyMatch(_afb, afb) == null) {
        befund(name, 'Aufgabe $nr: AFB fehlt oder nicht I/II/III (${pyRepr(afb)})');
      }
    }
    final m = _zeitGesamt.firstMatch(t);
    if (m == null) {
      befund(name, 'Kopf: "Zeit gesamt: n min" fehlt');
    } else if (int.parse(m[1]!) != summe) {
      befund(name, 'Kopf sagt ${m[1]} min, die Aufgaben ergeben $summe');
    }
    platzhalter(name, t);
    links(name, t);
    bilder(name, t);
    return nummern;
  }

  /// [blatt] sind die Aufgabennummern des Blatts.
  void loesung(String name, List<int> blatt) {
    final t = lies(name);
    titel(name, t);
    fuerSich(name, t);
    final n = [for (final x in findeGruppe(_aufgabeKopf, t)) int.parse(x)];
    if (n.length != blatt.length) {
      befund(name, 'Lösung hat ${n.length} Aufgabenabschnitte, das Blatt ${blatt.length}');
    } else if (!_listenGleich(n, blatt)) {
      befund(name, 'Lösung hat die Aufgaben ${n.join(', ')}, das Blatt ${blatt.join(', ')}');
    }
    platzhalter(name, t);
    links(name, t);
    bilder(name, t);
  }

  void infoblatt(String name) {
    final t = lies(name);
    titel(name, t);
    fuerSich(name, t);
    if (_aufgabe.hasMatch(t)) {
      befund(name, 'Informationsblatt enthält Aufgaben — die gehören auf ein Arbeitsblatt');
    }
    platzhalter(name, t);
    links(name, t);
    bilder(name, t);
  }

  // ---- Jedes Blatt steht für sich -------------------------------------------

  /// Der Name beginnt mit der Kennung: Unter diesem Namen steht das
  /// Blatt in der Kursübersicht, und mit ihr verweisen die anderen
  /// Blätter hierher.
  void titel(String name, String t) {
    final (k, loes) = _kennung(name);
    final soll = _titelSoll(k!, loes);
    final erste = pyLstrip(t).split('\n').first;
    if (pyMatch(pyRe('#\\s+${pyEscape(soll)}(?::|\\s*\$)'), erste) == null) {
      befund(
        name,
        'Name muss mit „$soll:" beginnen -- mit dieser Kennung verweisen '
        'andere Blätter hierher',
      );
    }
  }

  static final _abbOhneKennung = pyRe(r'\bAbb\.\s*([A-Za-z]?\d+)');

  /// Zählung ab 1 und „Abb. n" ohne Kennung -- was sich an einem Blatt
  /// allein prüfen lässt.
  void fuerSich(String name, String t) {
    final (abschnitte, abb, _) = _gliederung(t);
    if (!_listenGleich(abschnitte, [for (var i = 1; i <= abschnitte.length; i++) i])) {
      befund(name, 'Abschnitte ${abschnitte.join(', ')} -- jedes Blatt zählt seine Abschnitte ab 1, ohne Lücke');
    }
    if (!_listenGleich(abb, [for (var i = 1; i <= abb.length; i++) '$i'])) {
      befund(
        name,
        'Abbildungen ${[for (final a in abb) 'Abb. $a'].join(', ')} -- jedes Blatt zählt ab Abb. 1, fortlaufend, ohne '
        'Präfix',
      );
    }
    final rest = t.replaceAll(_abbUnterschrift, ' ').replaceAll(_verweisAbb, ' ');
    for (final m in _abbOhneKennung.allMatches(rest)) {
      final n = m[1]!;
      if (!abb.contains(n)) {
        befund(
          name,
          '"Abb. $n" ohne Blattkennung, aber dieses Blatt hat keine Abb. $n '
          '-- auf einem anderen Blatt: "Abb. $n auf Infoblatt n"',
        );
      }
    }
  }

  static final _infoblattNennung = pyRe(r'Infoblatt\s+\d+');

  /// Verweise zwischen den Blättern. [texte]: Name in der Prüfform ->
  /// Inhalt, alle Seiten außer der SchuCu-Seite.
  void querverweise(Map<String, String> texte) {
    final verzeichnis = <String, String>{}; // Kennung und „Lösung zu …" -> Datei
    for (final d in texte.keys.toList()..sort()) {
      final (k, loes) = _kennung(d);
      if (k != null) {
        final schl = loes ? 'Lösung zu $k' : k;
        if (verzeichnis.containsKey(schl)) {
          befund(d, 'dieselbe Kennung "$schl" wie ${verzeichnis[schl]} -- ein Verweis darauf wäre mehrdeutig');
        }
        verzeichnis[schl] = d;
      }
    }
    final glied = {for (final e in texte.entries) e.key: _gliederung(e.value)};
    final gemeldet = <(String, String)>{}; // (Datei, Kennung) schon als fehlend gemeldet

    String? ziel(String roh, String d) {
      final z = verzeichnis[verweisSchluessel(roh)];
      if (z == null) gemeldet.add((d, verweisSchluessel(roh)));
      return z;
    }

    // Verweise auf Abschnitte, Abbildungen und Aufgaben anderer Blätter
    // treffen etwas, das es dort gibt -- nach einer Teilung oder
    // Umnummerierung zeigen sie sonst ins Leere.
    for (final MapEntry(key: d, value: t) in texte.entries) {
      for (final m in _verweisAbschnitt.allMatches(t)) {
        final z = ziel(m[1]!, d);
        if (z == null) {
          befund(d, '"${textNorm(m[0]!)}": dieses Blatt gibt es nicht');
          continue;
        }
        final fehlt = [
          for (final n in _nummernListe(m[2]!))
            if (!glied[z]!.$1.contains(n)) n,
        ];
        if (fehlt.isNotEmpty) {
          befund(d, '"${textNorm(m[0]!)}": dort gibt es keinen Abschnitt ${fehlt.join(', ')}');
        }
      }
      for (final m in _verweisAbb.allMatches(t)) {
        final z = ziel(m[2]!, d);
        if (z == null) {
          befund(d, '"${textNorm(m[0]!)}": dieses Blatt gibt es nicht');
          continue;
        }
        final fehlt = [
          for (final n in _nummernListe(m[1]!))
            if (!glied[z]!.$2.contains('$n')) n,
        ];
        if (fehlt.isNotEmpty) {
          befund(d, '"${textNorm(m[0]!)}": dort gibt es keine Abb. ${fehlt.join(', ')}');
        }
      }
      for (final m in _verweisAufgabe.allMatches(t)) {
        final (nrn, blatt) = m[1] != null ? (m[1]!, m[2]!) : (m[4]!, m[3]!);
        final z = ziel(blatt, d);
        if (z == null) {
          befund(d, '"${textNorm(m[0]!)}": dieses Blatt gibt es nicht');
          continue;
        }
        final fehlt = [
          for (final n in _nummernListe(nrn))
            if (!glied[z]!.$3.contains(n)) n,
        ];
        if (fehlt.isNotEmpty) {
          befund(d, '"${textNorm(m[0]!)}": dort gibt es keine Aufgabe ${fehlt.join(', ')}');
        }
      }
      // Jede Kennung, die irgendwo steht, gibt es -- auch im Ablaufplan
      // und in „hilft die Vertiefung zu Arbeitsblatt 3". In Moodle wird
      // daraus ein Link, und der braucht ein Ziel.
      for (final m in blattZiel.allMatches(t)) {
        final s = verweisSchluessel(m[0]!);
        if (!verzeichnis.containsKey(s) && !gemeldet.contains((d, s))) {
          gemeldet.add((d, s));
          befund(d, '"${textNorm(m[0]!)}": dieses Blatt gibt es nicht');
        }
      }
    }

    // Jedes Infoblatt nennt ein Arbeitsblatt (auch Hilfe oder Vertiefung)
    // unter „Dazu" oder in einer „Lies"-Zeile -- eines, das keines nennt,
    // liest niemand. Verwiesen wird nur in diese Richtung; Rückverweise
    // auf dem Infoblatt stünden doppelt und veralteten still.
    final genannt = <String>{};
    for (final MapEntry(key: d, value: t) in texte.entries) {
      final (k, loes) = _kennung(d);
      if (k == null || loes || !k.contains('Arbeitsblatt')) continue;
      final m = _dazu.firstMatch(t);
      final zeilen = [?m?[1], ...findeGruppe(_lies, t)];
      for (final zeile in zeilen) {
        genannt.addAll(findeAlle(_infoblattNennung, zeile).map(textNorm));
      }
    }
    for (final k in verzeichnis.keys.toList()..sort()) {
      if (k.startsWith('Infoblatt') && !genannt.contains(k)) {
        befund(verzeichnis[k]!, 'kein Arbeitsblatt nennt $k unter "Dazu" oder in einer "Lies"-Zeile');
      }
    }
  }

  // ---- Querschnitt ----------------------------------------------------------
  static const _html = {'ul', '/ul', 'li', '/li', 'br', 'br/', 'br /'};
  static final _spitz = pyRe(r'<([^>\n]+)>');

  void platzhalter(String name, String t) {
    // Alles in spitzen Klammern, was kein erlaubtes HTML-Element ist,
    // ist ein Platzhalter aus der Vorlage -- auch <n> und <du / Sie>.
    for (final m in _spitz.allMatches(t)) {
      final innen = pyStrip(m[1]!);
      if (_html.contains(innen.toLowerCase()) || innen.startsWith('http')) continue;
      befund(name, 'Platzhalter steht noch da: <${pyKurz(innen, 60)}>');
      return;
    }
  }

  static final _mdLink = pyRe(r'\[([^\]]*)\]\((https?://[^)]+)\)');
  static final _protokollrelativ = pyRe(r'\(//[a-z0-9.-]+/');

  void links(String name, String t) {
    for (final m in _mdLink.allMatches(t)) {
      final text = pyStrip(m[1]!), url = m[2]!;
      if (!text.contains(url) && const ['hier', 'link', 'video', 'dokument', 'mehr', ''].contains(text.toLowerCase())) {
        befund(name, 'Link ohne ausgeschriebene Adresse im Text: [$text](${pyKurz(url, 40)})');
      }
    }
    if (_protokollrelativ.hasMatch(t)) {
      befund(name, 'protokollrelative Adresse (//…) — auf Papier unvollständig');
    }
  }

  static final _bildMitAlt = pyRe(r'!\[([^\]]*)\]\(([^)]+)\)');
  static final _xmlns = pyRe(r'xmlns="[^"]+"');

  void bilder(String name, String t) {
    for (final m in _bildMitAlt.allMatches(t)) {
      final alt = pyStrip(m[1]!), datei = pyStrip(m[2]!);
      if (alt.isEmpty) befund(name, 'Bild ohne Beschreibung: $datei');
      final da = ordner[datei];
      final vorhanden = da != null && (da.text != null || File(da.pfad!).existsSync());
      if (!vorhanden) {
        if (bilddateien) befund(name, 'eingebundene Datei fehlt: $datei');
      } else if (datei.toLowerCase().endsWith('.svg')) {
        final svg = lies(datei);
        if (!svg.contains('<title') || !svg.contains('<desc')) {
          befund(datei, 'SVG ohne <title> und <desc>');
        }
        if (svg.contains('<script') || svg.replaceAll(_xmlns, '').contains('http')) {
          befund(datei, 'SVG mit Skript oder externem Verweis');
        }
      }
    }
  }

  // ---- Hauptlauf ------------------------------------------------------------

  /// Schreibt Hinweise und Befunde; [anzeige] übersetzt die Namen der
  /// Prüfform in das, was der Leser kennt: die Aktivität mit ihrem Ordner
  /// im Entwurf oder ihrer cmid in Moodle.
  int ausgabe(String was, [String Function(String)? anzeige]) {
    for (final h in hinweise) {
      aus.writeln('  $h');
    }
    if (befunde.isEmpty) {
      aus.writeln(
        'OK -- $was, Form vollständig. Ob die Lernsituation trägt, '
        'sagt die Checkliste, nicht diese Prüfung.',
      );
      return 0;
    }
    aus.writeln('${befunde.length} Befund(e):');
    for (var (datei, text) in befunde) {
      if (anzeige != null) {
        datei = anzeige(datei);
        text = text.replaceAllMapped(_entwurfImText, (m) => anzeige(m[0]!));
      }
      aus.writeln('  ${pyLinks(datei, 40)} $text');
    }
    return 1;
  }

  static final _ab00 = pyRe(r'AB-00-.*\.md$');
  static final _abDatei = pyRe(r'AB-\d+-.*\.md$');
  static final _ibDatei = pyRe(r'IB-\d+-.*\.md$');
  static final _materialName = pyRe('$_ziel|Handlungssituation');

  /// Alle Prüfungen an der Prüfform; [imTextVerboten] sind Namen des
  /// Entwurfs, die in keinem Text stehen dürfen. Gibt die Dateien der
  /// Prüfform zurück, null: nichts zu prüfen.
  List<String>? pruefen([Set<String> imTextVerboten = const {}]) {
    final dateien = ordner.keys.where((d) => !d.startsWith('.')).toList()..sort();
    const hand = _hand;
    if (!dateien.contains(hand)) {
      aus.writeln('Keine Lehrerhandreichung -- ohne sie ist nichts zu prüfen.');
      return null;
    }

    final richt = schucuSeite(dateien);
    final (genannt, namen) = handreichung(hand, richt);

    // AB-00 ist die Handlungssituation für sich: keine Aufgaben, keine Lösung.
    final situation = [for (final d in dateien) if (pyMatch(_ab00, d) != null) d];
    final abs = [
      for (final d in dateien)
        if (pyMatch(_abDatei, d) != null && !situation.contains(d) && !d.endsWith('-loesung.md')) d,
    ];
    final ibs = [for (final d in dateien) if (pyMatch(_ibDatei, d) != null) d];
    if (abs.isEmpty) {
      befund('(Lernsituation)', 'kein Arbeitsblatt -- eine Aktivität „Arbeitsblatt 1: …"');
    }
    for (final d in situation) {
      final t = lies(d);
      titel(d, t);
      fuerSich(d, t);
      platzhalter(d, t);
      links(d, t);
      bilder(d, t);
    }
    for (final ab in abs) {
      final n = arbeitsblatt(ab);
      final loes = '${ab.substring(0, ab.length - 3)}-loesung.md';
      if (!dateien.contains(loes)) {
        final (k, _) = _kennung(ab);
        befund(ab, 'Lösung fehlt: „${_titelSoll(k!, true)}: …"');
      } else if (n.isNotEmpty) {
        loesung(loes, n);
      }
    }
    for (final ib in ibs) {
      infoblatt(ib);
    }
    querverweise({
      for (final d in dateien)
        if (d.endsWith('.md') && d != _schucu) d: lies(d),
    });

    // Die Materialübersicht nennt jedes Blatt mit seinem Namen, so wie er
    // in Moodle heißt; ein veralteter Name wäre dort ein Link mit falschem
    // Text.
    final titelVon = <String, String>{}; // Kennung -> Titel des Blatts
    for (final d in dateien) {
      final (k, loes) = _kennung(d);
      if (k != null && d.endsWith('.md')) {
        final erste = pyLstrip(lies(d)).split('\n').first;
        titelVon[loes ? 'Lösung zu $k' : k] = textNorm(_linksOhne(erste, '#'));
      }
    }
    for (final n in namen) {
      final m = pyMatch(_materialName, n);
      final s = m != null ? verweisSchluessel(m[0]!) : null;
      if (s != null && titelVon[s] == n) {
        genannt.add(s);
      } else {
        befund(
          hand,
          'Materialübersicht: "${pyKurz(n, 60)}" ist nicht der Name eines Blatts -- '
          'dort steht der Titel, wie er in Moodle heisst',
        );
      }
    }

    // Jedes Blatt kommt in der Handreichung vor.
    for (final d in dateien) {
      if (d == hand || d == _schucu || d.endsWith('-loesung.md')) continue;
      final (k, _) = _kennung(d);
      if (k != null && !genannt.contains(k)) {
        befund(d, 'steht weder im Ablaufplan noch in der Materialübersicht');
      }
    }
    // Ebenso jede weitere Aktivität, mit ihrem Namen in Anführungszeichen --
    // und was dort in Anführungszeichen steht, gibt es.
    for (final MapEntry(key: n, value: wo) in weitere.entries) {
      if (!zitiert.contains(n)) {
        befund(
          wo,
          'steht weder im Ablaufplan noch in der Materialübersicht -- dort mit ihrem '
          'Namen in Anführungszeichen („$n")',
        );
      }
    }
    for (final n in zitiert.where((n) => !weitere.containsKey(n)).toList()..sort()) {
      befund(
        hand,
        '„$n" in Ablaufplan oder Materialübersicht ist keine Aktivität dieser Lernsituation '
        '-- in Anführungszeichen steht dort nur der Name einer weiteren Aktivität',
      );
    }

    // Kein Name aus dem Entwurf im Text: In Moodle gibt es nur Aktivitäten,
    // und ein Blatt heißt dort nach seiner Kennung.
    final muster = [
      for (final n in imTextVerboten.toList()..sort())
        (n, pyRe('(?<![\\w.-])${pyEscape(n)}(?![\\w-])')),
    ];
    for (final d in dateien) {
      if (d.endsWith('.md')) {
        final t = lies(d).replaceAll(_bild, ' ');
        for (final (n, m) in muster) {
          if (m.hasMatch(t)) {
            befund(
              d,
              'Name aus dem Entwurf im Text: $n -- in Moodle gibt es ihn nicht; '
              'ein Blatt mit seiner Kennung nennen („Arbeitsblatt 1")',
            );
          }
        }
      }
    }
    return dateien;
  }

  static String _linksOhne(String s, String z) {
    var a = 0;
    while (a < s.length && s[a] == z) {
      a++;
    }
    return s.substring(a);
  }
}

// ---------------------------------------------------------------------------
// Entwurf und Stand in Moodle
// ---------------------------------------------------------------------------
// Der Entwurf hat schon die Form, die die Werkzeuge der App nehmen, und was
// der Skill moodle aus einem Abschnitt liest, liegt in derselben Form im
// Arbeitsordner: je Aktivität page.html bzw. introeditor.html und dateien/,
// ein Buch als kapitel.json mit kapitel-<id>/content_editor.html. Im Entwurf
// nennt lernsituation.json Reihenfolge, Typ und Name; in Moodle tut es
// kurs-<kurs>.json (von kurs_uebersicht, die Antwort von
// core_courseformat_get_state), und aktivitaet_lesen legt cm-<cmid>/ an,
// buch_lesen buch-<cmid>/. Beide werden deshalb gleich gelesen und gleich
// geprüft -- maßgeblich ist, was in Moodle steht, und die Lehrkraft ändert
// dort auch von Hand.
//
// Geprüft wird an einer Prüfform: je Aktivität ein Text, das HTML in die
// Schreibweise gebracht, an der sich die festen Formen der Vorlagen am
// einfachsten lesen lassen (_ZuMarkdown). Niemand schreibt sie; sie lebt nur
// während der Prüfung, im Speicher. Welche Rolle eine Aktivität hat, sagt ihr
// Name -- die Kennung, „SchuCu", „Lehrerhandreichung", „Handlungssituation" --
// oder ihr Inhalt (SchuCu-Tabelle, Ablaufplan).
//
// Nur am Entwurf: lernsituation.json, die Ordner und die HTML-Regeln. In
// Moodle meldet die App Verstöße gegen die HTML-Regeln selbst beim Lesen, und
// was die Lehrkraft im Editor gestaltet, ist ihre Sache. Nur in Moodle: die
// Links zwischen den Blättern, die erst nach dem Anlegen entstehen können.

const _manifest = 'lernsituation.json';

/// Weitere Aktivitäten: keine Blätter und ohne Kennung. Ihr Name sagt, wozu
/// sie da sind, und Blätter wie Handreichung nennen ihn in Anführungszeichen
/// (references/vorlagen.md, „Weitere Aktivitäten im Entwurf"); in Moodle wird
/// genau diese Nennung ein Link (links_setzen). Was im Ordner liegt, prüft
/// _weitereAktivitaet.
const weitereTypen = {
  'board', 'kanban', 'checklist', 'wiki', 'quiz', 'folder', 'resource', 'url', 'learningmap',
};
// Dieselben Anführungszeichen sucht links_setzen (links.dart).
const _zitiertMuster = r'[„“"»]([^„“”"«»\n]+?)[“”"«]';
final _zitiert = pyRe(_zitiertMuster);
final _zitiertGanz = pyReGanz(_zitiertMuster);

/// Ein Name in Anführungszeichen: so nennen Blätter eine weitere Aktivität.
final zitierterName = _zitiert;

// Der Name einer Aktivität, die ein Blatt ist: Kennung, dann Doppelpunkt.
final _rolle = pyRe(
  r'(Lösung\s+zur?\s+)?(?:(Hilfe|Vertiefung)\s+zu\s+)?(Arbeitsblatt|Infoblatt)\s+(\d+)\s*(?::|$)',
);
// Die Namen der Prüfform, wenn sie in einem Befund stehen.
final _entwurfImText = pyRe(
  r'\b(?:AB|IB)-\d+-x\d*(?:-hilfe|-vertiefung)?(?:-loesung)?\.md\b'
  r'|\b00-(?:schucu|lehrerhandreichung)\.md\b',
);
final _aktivitaetslink = pyRe(r'/mod/\w+/view\.php\?id=\d+');

/// Wo der Inhalt einer Aktivität steht, in dieser Reihenfolge; das erste Feld
/// braucht der Entwurf, damit aktivitaet_anlegen einen Inhalt findet.
const inhaltsFelder = {
  'page': ['page'],
  'assign': ['introeditor', 'activityeditor'],
  'label': ['introeditor'],
};
// Rollen ohne Kennung, am Namen erkannt.
const _nameSchucu = 'SchuCu', _nameHand = 'Lehrerhandreichung', _nameSituation = 'Handlungssituation';

final _tag = pyRe(r'<[^>]+>');

String _htmlText(String? s) => textNorm(pyUnescape((s ?? '').replaceAll(_tag, ' ')));

bool _wahrMoodle(Object? x) => x == true || x == 1 || x == '1' || x == 'true';

/// `str(x or '')` in Python.
String _str(Object? x) => pyWahr(x) ? pyStr(x) : '';

/// `int(x)` in Python für Werte aus JSON.
int _pyInt(Object? x) => switch (x) {
  int i => i,
  double d => d.truncate(),
  bool b => b ? 1 : 0,
  String s => int.parse(pyStrip(s)),
  _ => throw FormatException('keine Zahl: ${pyRepr(x)}'),
};

/// `for x in wert` in Python für Werte aus JSON: eine Liste je Element, ein
/// Objekt je Schlüssel, ein Text je Zeichen.
Iterable<Object?> _pyIter(Object? x) => switch (x) {
  List<Object?> l => l,
  Map<Object?, Object?> m => m.keys,
  String s => s.runes.map(String.fromCharCode),
  _ => const [],
};

/// Der Zugang zu den Dateien: nur im Arbeitsordner. Was außerhalb liegt
/// (auch über eine Verknüpfung), gibt es für die Prüfung nicht.
class _Dateien {
  _Dateien(String wurzel) : _wurzel = _echt(wurzel) ?? p.normalize(p.absolute(wurzel));
  final String _wurzel;

  static String? _echt(String pfad) {
    try {
      return File(pfad).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }

  bool _innen(String pfad) {
    final e = _echt(pfad);
    return e != null && (e == _wurzel || p.isWithin(_wurzel, e));
  }

  bool datei(String pfad) => FileSystemEntity.isFileSync(pfad) && _innen(pfad);
  bool ordner(String pfad) => FileSystemEntity.isDirectorySync(pfad) && _innen(pfad);

  /// Eine Textdatei, wie Python sie liest: UTF-8, Zeilenenden zu \n.
  String text(String pfad, {bool ersetzen = false}) {
    if (!_innen(pfad)) throw FileSystemException('außerhalb des Arbeitsordners', pfad);
    return _zeilenumbrueche(utf8.decode(File(pfad).readAsBytesSync(), allowMalformed: ersetzen));
  }

  List<int> bytes(String pfad) {
    if (!_innen(pfad)) throw FileSystemException('außerhalb des Arbeitsordners', pfad);
    return File(pfad).readAsBytesSync();
  }

  Object? json(String pfad) => jsonDecode(text(pfad));

  /// Die Namen in einem Ordner (`os.listdir`).
  List<String> liste(String pfad) => [
    for (final e in Directory(pfad).listSync(followLinks: false)) p.basename(e.path),
  ];

  /// `os.walk`: je Ordner (oben zuerst) seine Dateien, sortiert. Verknüpfte
  /// Ordner zählen als Ordner und werden nicht betreten.
  Iterable<(String, String)> walk(String pfad) sync* {
    final dateien = <String>[], unter = <String>[];
    for (final e in Directory(pfad).listSync(followLinks: false)) {
      final typ = FileSystemEntity.typeSync(e.path);
      final istOrdner = typ == FileSystemEntityType.directory ||
          (typ == FileSystemEntityType.link && FileSystemEntity.isDirectorySync(e.path));
      (istOrdner ? unter : dateien).add(p.basename(e.path));
    }
    for (final f in dateien..sort()) {
      yield (pfad, f);
    }
    for (final u in unter..sort()) {
      if (FileSystemEntity.typeSync(p.join(pfad, u), followLinks: false) == FileSystemEntityType.link) {
        continue;
      }
      yield* walk(p.join(pfad, u));
    }
  }
}

/// Eine Aktivität, wie beide Leser sie liefern. [ordner]: wo dateien/ und
/// in Moodle uebersicht.json liegen, bei einem Buch je Kapitel einer; [wo]:
/// wie ein Befund sie nennt.
class _Seite {
  _Seite(this.modul, this.name, this.erreichbar, this.h, this.md, this.ordner, this.wo);
  final String modul;
  final String name;
  final bool erreichbar;
  final String h;
  final String md;
  final List<String> ordner;
  final String wo;
}

/// Sucht im Arbeitsordner die kurs-*.json, die den Abschnitt enthält.
/// Gibt (Kurs, Titel, [(cmid, modul, name, erreichbar)]) in Moodles
/// Reihenfolge, Unterabschnitte eingeschlossen -- oder null.
(int, String, List<(int, String, String, bool)>)? _abschnittAusKurs(
  _Dateien fs,
  String ao,
  int abschnittId,
) {
  final kursDatei = pyReGanz(r'kurs-\d+\.json');
  for (final f in fs.liste(ao)..sort()) {
    if (!kursDatei.hasMatch(f)) continue;
    final z = fs.json(p.join(ao, f));
    final zm = z is Map ? z : const {};
    final abschnitte = <int, Map>{
      for (final s in _pyIter(zm['section']))
        if (s is Map && pyWahr(s['id'])) _pyInt(s['id']): s,
    };
    if (!abschnitte.containsKey(abschnittId)) continue;
    final cms = <int, Map>{
      for (final c in _pyIter(zm['cm']))
        if (c is Map && pyWahr(c['id'])) _pyInt(c['id']): c,
    };
    // Ein Unterabschnitt hängt über delegatesectionid an seiner Aktivität,
    // sonst über parentsectionid am Elternabschnitt (wie in kurs.dart).
    final kinder = <int, List<int>>{};
    for (final s in abschnitte.values) {
      if (pyWahr(s['parentsectionid'])) {
        kinder.putIfAbsent(_pyInt(s['parentsectionid']), () => []).add(_pyInt(s['id']));
      }
    }
    final liste = <(int, String, String, bool)>[];
    final gesehen = <int>{};
    final modPraefix = pyRe(r'^mod_');

    void sammle(int sid) {
      if (gesehen.contains(sid) || !abschnitte.containsKey(sid)) return;
      gesehen.add(sid);
      for (final x in _pyIter(abschnitte[sid]!['cmlist'])) {
        final c = cms[_pyInt(x)];
        if (c == null) continue;
        final plugin = _str(c['plugin']).replaceFirst(modPraefix, '');
        final modul = pyWahr(c['module'])
            ? pyStr(c['module'])
            : plugin.isNotEmpty
            ? plugin
            : '?';
        liste.add((_pyInt(c['id']), modul, _htmlText(_str(c['name'])), _wahrMoodle(c['visible'])));
        if (pyWahr(c['delegatesectionid'])) sammle(_pyInt(c['delegatesectionid']));
      }
      for (final k in kinder[sid] ?? const <int>[]) {
        sammle(k);
      }
    }

    sammle(abschnittId);
    final s = abschnitte[abschnittId]!;
    final titel = _htmlText(pyWahr(s['title']) ? pyStr(s['title']) : _str(s['rawtitle']));
    return (int.parse(f.substring(5, f.length - 5)), titel, liste);
  }
  return null;
}

/// HTML in die Prüfform: Überschriften als #, Tabellen mit |, <strong>
/// als **, Bilder als ![alt](name). In einer Textseite steht <h3> für ##, im
/// Buch ist ## das Kapitel und <h3> steht für ###. Links auf Aktivitäten
/// bleiben Text -- sie prüft _links eigens --, Links nach draußen werden
/// [Text](Adresse), damit „hier" als Linktext auffällt.
class _ZuMarkdown extends PyHtmlLeser {
  _ZuMarkdown({bool buch = false})
    : ebene = {for (final n in [3, 4, 5, 6]) 'h$n': '#' * (n - 1 + (buch ? 1 : 0))};

  final Map<String, String> ebene;
  final bloecke = <String>[];
  String zeile = '', kopf = '';
  List<List<String>>? tabelle;
  List<String>? zelle;
  final listen = <String>[];
  String? href;

  static final _leerraumKurz = RegExp(r'[ \t\r\n]+');

  void text(String t) {
    final z = zelle;
    if (z != null) {
      z[z.length - 1] += t;
    } else {
      zeile += t;
    }
  }

  void absatz() {
    final z = pyStrip(zeile);
    if (z.isNotEmpty) bloecke.add(kopf + z);
    zeile = '';
    kopf = '';
  }

  @override
  void starttag(String tag, List<Attribut> attrs) {
    final a = attributMap(attrs);
    if (tag == 'table') {
      absatz();
      tabelle = [];
    } else if (tag == 'tr' && tabelle != null) {
      tabelle!.add([]);
    } else if ((tag == 'td' || tag == 'th') && tabelle != null) {
      if (tabelle!.isEmpty) tabelle!.add([]);
      tabelle!.last.add('');
      zelle = tabelle!.last;
    } else if (ebene.containsKey(tag)) {
      absatz();
      kopf = '${ebene[tag]} ';
    } else if (tag == 'p' || tag == 'div' || tag == 'blockquote') {
      if (zelle == null) absatz();
    } else if (tag == 'ul' || tag == 'ol') {
      absatz();
      listen.add(tag);
    } else if (tag == 'li') {
      absatz();
      kopf = listen.isNotEmpty && listen.last == 'ol' ? '1. ' : '- ';
    } else if (tag == 'strong' || tag == 'b') {
      text('**');
    } else if (tag == 'em' || tag == 'i') {
      text('*');
    } else if (tag == 'br') {
      text(zelle != null ? ' ' : '\n');
    } else if (tag == 'img') {
      final src = _str(a['src']);
      text('![${_str(a['alt'])}](${pyUnquote(src.split('/').last)})');
    } else if (tag == 'a') {
      final h = _str(a['href']);
      href = h.startsWith('http') && !_aktivitaetslink.hasMatch(h) ? h : null;
      if (href != null && href!.isNotEmpty) text('[');
    }
  }

  @override
  void endtag(String tag) {
    if (tag == 'td' || tag == 'th') {
      zelle = null;
    } else if (tag == 'table' && tabelle != null) {
      final zeilen = [
        for (final z in tabelle!)
          if (z.isNotEmpty) [for (final c in z) textNorm(c)],
      ];
      if (zeilen.isNotEmpty) {
        final md = ['| ${zeilen[0].join(' | ')} |', '|${'---|' * zeilen[0].length}'];
        md.addAll([for (final z in zeilen.skip(1)) '| ${z.join(' | ')} |']);
        bloecke.add(md.join('\n'));
      }
      tabelle = null;
    } else if (ebene.containsKey(tag) || const ['p', 'div', 'blockquote', 'li'].contains(tag)) {
      if (zelle == null) absatz();
    } else if (tag == 'ul' || tag == 'ol') {
      absatz();
      if (listen.isNotEmpty) listen.removeLast();
    } else if (tag == 'strong' || tag == 'b') {
      text('**');
    } else if (tag == 'em' || tag == 'i') {
      text('*');
    } else if (tag == 'a' && href != null && href!.isNotEmpty) {
      text('](${href!})');
      href = null;
    }
  }

  @override
  void daten(String d) {
    if (zelle == null) {
      if (zeile.isEmpty && pyStrip(d).isEmpty) return;
      d = d.replaceAll(_leerraumKurz, ' ');
    }
    text(d);
  }

  String ergebnis() {
    absatz();
    return '${bloecke.join('\n\n')}\n';
  }
}

String _zuMarkdown(String h, {bool buch = false}) => (_ZuMarkdown(buch: buch)..lesen(h)).ergebnis();

/// Der Name des Blatts in der Prüfform, aus der Kennung am Anfang seines
/// Namens; null: kein Blatt.
String? _pruefname(String name, Map<String, _Seite> belegt) {
  final m = pyMatch(_rolle, name);
  if (m == null) return null;
  final loes = m[1], zusatz = m[2], art = m[3], nr = m[4]!;
  final kern = '${art == 'Arbeitsblatt' ? 'AB' : 'IB'}-${int.parse(nr).toString().padLeft(2, '0')}-x';
  final rest =
      (zusatz == 'Hilfe'
          ? '-hilfe'
          : zusatz != null && zusatz.isNotEmpty
          ? '-vertiefung'
          : '') +
      (loes != null && loes.isNotEmpty ? '-loesung' : '');
  // Zwei Aktivitäten mit derselben Kennung: getrennt ablegen, damit die
  // Prüfung „dieselbe Kennung" melden kann.
  var n = '';
  while (belegt.containsKey('$kern$n$rest.md')) {
    n = '${int.parse(n.isEmpty ? '1' : n) + 1}';
  }
  return '$kern$n$rest.md';
}

final _ablaufplanKopf = pyRe(r'^##\s+Ablaufplan\s*$', multiLine: true);

/// Der Name der Aktivität in der Prüfform; null: ohne Rolle in der
/// Lernsituation.
String? _rolleVon(String name, String h, String md, Map<String, _Seite> belegt) {
  if (name == _nameSchucu && !belegt.containsKey(_schucu)) return _schucu;
  final blatt = _pruefname(name, belegt);
  if (blatt != null) return blatt;
  if (name == _nameSituation && !belegt.containsKey('AB-00-x.md')) return 'AB-00-x.md';
  if ((name == _nameHand || _ablaufplanKopf.hasMatch(md)) && !belegt.containsKey(_hand)) {
    return _hand;
  }
  // Die Tabelle auf einer Seite mit anderem Namen: Die Prüfung sagt dann,
  // wie die Seite heißen muss.
  if (h.contains('<table class="lernsituation"') && !belegt.containsKey(_schucu)) return _schucu;
  return null;
}

String _liesFeld(_Dateien fs, String o, String modul) => [
  for (final f in inhaltsFelder[modul]!)
    if (fs.datei(p.join(o, '$f.html'))) fs.text(p.join(o, '$f.html')),
].join('\n');

/// Ein Buch aus kapitel.json und `kapitel-<id>/content_editor.html`, so wie
/// buch_lesen es ablegt und der Entwurf es schreibt: (HTML, Prüfform,
/// [(Ordner, HTML, Eintrag aus kapitel.json)]); null ohne kapitel.json.
(String, String, List<(String, String, Map)>)? _liesBuch(_Dateien fs, String o) {
  final pfad = p.join(o, 'kapitel.json');
  if (!fs.datei(pfad)) return null;
  final teile = <String>[], roh = <String>[];
  final kapitel = <(String, String, Map)>[];
  for (final k in _pyIter(fs.json(pfad))) {
    if (k is! Map) continue;
    final ko = p.join(o, 'kapitel-${pyStr(k['id'])}');
    final f = p.join(ko, 'content_editor.html');
    final h = fs.datei(f) ? fs.text(f) : '';
    teile.add(
      '${pyWahr(k['unterkapitel']) ? '###' : '##'} ${textNorm(_str(k['titel']))}\n\n'
      '${_zuMarkdown(h, buch: true)}',
    );
    roh.add(h);
    kapitel.add((ko, h, k));
  }
  return (roh.join('\n'), teile.join('\n'), kapitel);
}

// ---- Die HTML-Regeln am Entwurf -------------------------------------------
// Dieselben wie in references/html.md der Skills und in der Auswertung der
// App (auswertung.dart), die sie beim Lesen meldet: Hier fallen sie auf,
// bevor etwas in Moodle steht. Die Grenze für Rahmenlinien ist dieselbe wie
// _mehrAlsRahmen dort -- wer die eine ändert, ändert beide.
const _tabellenteile = {'table', 'thead', 'tbody', 'tfoot', 'tr', 'th', 'td', 'col', 'colgroup'};
final _rahmenEigenschaft = pyRe(r'^border(-(top|right|bottom|left))?(-(width|style))?$');
final _rahmenWert = pyRe(
  r'^(0|\d*\.?\d+(px|pt|em|rem)|thin|medium|thick|none|hidden|dotted|dashed|solid|double'
  r'|groove|ridge|inset|outset)$',
);
// Elemente, die in Moodle-Inhalten vorkommen. Alles andere in spitzen
// Klammern ist ein Platzhalter der Vorlagen: <Titel>, <n>, <du / Sie>.
final _htmlElemente =
    ('a abbr address article aside audio b bdi bdo blockquote br button caption center cite '
            'code col colgroup data dd del details dfn div dl dt em embed figcaption figure font footer h1 h2 h3 h4 h5 h6 '
            'header hr i iframe img input ins kbd label li main mark math nav object ol optgroup option p param picture pre '
            'q rp rt ruby s samp section select small source span strong sub summary sup svg table tbody td textarea tfoot th '
            'thead time tr track u ul var video wbr')
        .split(' ')
        .toSet();
const _block = {
  'p', 'div', 'li', 'td', 'th', 'tr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'br', 'table', 'ul', 'ol',
  'blockquote', 'figure', 'figcaption', 'hr', 'dd', 'dt', 'section', 'pre',
};
// Was aus Markdown hängen bleibt, wenn man HTML schreibt -- im Text außerhalb
// von <code> und <pre>.
final _markdown = [
  (pyRe(r'\*\*[^*\n]+\*\*'), '<strong>'),
  (pyRe(r'^[ \t]*#{1,6}[ \t]+\S.*', multiLine: true), '<h3> bzw. <h4>'),
  (pyRe(r'!?\[[^\]\n]*\]\([^)\s]+\)'), '<a href> bzw. <img>'),
  (pyRe(r'```'), '<pre> oder, zum Ausfüllen, eine Tabelle'),
  (pyRe(r'`[^`\n]+`'), '<code>'),
];

// Interaktive Elemente: Die Regeln stehen in elemente.dart (elementBefunde),
// derselben Prüfung, an der die App das Schreiben abbricht -- hier fällt der
// Befund schon am Entwurf auf. Bewusste Unterschiede zur App (E17, E22):
//  - Den Kopf (Content-Security-Policy, Wächter) setzt erst die App bei der
//    Übertragung; im Entwurf fehlt er, und das Gerüst mit <head> prüft die
//    App erst beim Einsetzen des Kopfes (elementeVorbereiten), der Entwurf
//    meldet es schon hier.
//  - Die Adresse wird wie in der Python-Vorlage gekürzt (pyKurz) und der
//    Satz endet ohne Punkt.
//  - Muster sind Dart-Ausdrücke der App, nicht mit pyRe übersetzt: \w und \s
//    in den Mustern der App meinen ASCII, nicht Unicode wie in Python.
final _kopfTag = pyRe(r'<head\b', caseSensitive: false);

/// Was in einem interaktiven Element nicht geht, je als Satz
/// (references/elemente.md).
List<String> _elementFehler(String text) {
  final raus = <String>[];
  if (!_kopfTag.hasMatch(ohneKopf(text))) {
    raus.add('braucht ein Gerüst mit <head> (<!DOCTYPE html><html lang="de"><head>…</head><body>…)');
  }
  for (final b in elementBefunde(text)) {
    final adresse = b.adresse;
    raus.add(
      adresse == null
          ? b.satz
          : 'Adresse „${pyKurz(adresse, 60)}": Ein Element lädt nichts und verweist nirgendwohin -- Bilder als SVG im '
                'Element, Verweise in den Text der Seite',
    );
  }
  return raus;
}

// Code in Dateien, die kein Element sind: dieselbe Grenze wie codeInDatei in
// elemente.dart (stellenInDatei). Moodle liefert HTML, SVG und XML direkt
// aus; über einen Link oder in einem neuen Tab geöffnet, liefe ihr Code in
// der Sitzung des Betrachters, und die App lädt so eine Datei nicht hoch.
// Unterschied zur App: Der Entwurf nennt nur die Art der Stelle, nicht ihren
// vollen Text (Befund, nicht Abbruchmeldung).

/// Die Stelle kurz: Tag und Art, ohne Inhalt.
String _stelleKurz(Skriptstelle s) => switch (s.art) {
  SkriptArt.skript => '<script>',
  SkriptArt.srcdoc => '<${s.tag} srcdoc>',
  SkriptArt.javascriptAdresse => 'javascript: an <${s.tag}>',
  SkriptArt.ereignis => '${ereignisName(s.attribut, s.wert)} an <${s.tag}>',
  SkriptArt.komprimiert => skriptstelleText(s),
};

/// Die Stellen mit Code in einer Datei, die der Browser als Dokument öffnet;
/// bei anderen Dateien leer.
List<String> _codeInDatei(String name, List<int> daten) => [
  for (final s in stellenInDatei(name, daten)) _stelleKurz(s),
];

// Formelfehler: Die Regeln stehen in formeln.dart (formelBlockPruefen),
// derselben Prüfung, die das Schreiben in Moodle abbricht -- hier fällt der
// Fehler schon am Entwurf auf. Bewusste Unterschiede zur App: Die Blöcke
// liest der Python-nachgebildete Leser (die SchuCu-Tabelle ist vorher
// entfernt), und die Sätze kürzen und normalisieren wie die Python-Vorlage,
// ohne Punkt am Ende.
class _FormelText extends PyHtmlLeser {
  final bloecke = <List<String>>[[]];
  int aus = 0;

  @override
  void starttag(String tag, List<Attribut> attrs) {
    if (formelAuslassen.contains(tag)) {
      aus++;
    } else if (formelBloecke.contains(tag)) {
      bloecke.add([]);
    }
  }

  @override
  void endtag(String tag) {
    if (formelAuslassen.contains(tag)) {
      aus = aus > 0 ? aus - 1 : 0;
    } else if (formelBloecke.contains(tag)) {
      bloecke.add([]);
    }
  }

  @override
  void daten(String d) {
    if (aus == 0) bloecke.last.add(d);
  }
}

String _formelSatz(FormelBefund b) {
  String kurz40(String t) => pyKurz(textNorm(t), 40);
  return switch (b.art) {
    FormelArt.ohneEndeVorAnfang =>
      'Formel ohne Ende: „${kurz40(b.text)}" -- vor dem nächsten Formelanfang fehlt ${b.ende}',
    FormelArt.endeOhneAnfang => 'Formelende „${b.ende}" ohne Anfang: „${textNorm(b.text)}"',
    FormelArt.htmlInFormel =>
      'HTML in der Formel „${kurz40(b.text)}": Zwischen Anfang und Ende steht '
          'ein Tag -- Hervorhebung und Zeilenumbruch macht LaTeX selbst',
    FormelArt.ohneEnde =>
      'Formel ohne Ende: „${kurz40(b.text)}" -- ${b.ende} fehlt im '
          'selben Absatz. Steht ein rohes < darin? Als &lt; oder \\lt schreiben',
    FormelArt.einfacheDollar =>
      'LaTeX zwischen einfachen \$ wird nicht gesetzt: „${kurz40(b.text)}" -- \\( … \\) schreiben',
  };
}

/// Die Formelfehler eines Felds (references/html.md, „Formeln"). Die
/// SchuCu-Tabelle muss vorher heraus.
List<String> _formelFehler(String h) {
  final f = _FormelText()..lesen(h);
  return [
    for (final b in f.bloecke)
      if (b.isNotEmpty)
        for (final x in formelBlockPruefen(b)) _formelSatz(x),
  ];
}

/// Was in einem style-Attribut über Rahmenlinien hinausgeht -- dieselbe
/// Grenze wie _mehrAlsRahmen in auswertung.dart: nur Stärke und Art der
/// Linie, keine Farbe.
List<String> _mehrAlsRahmen(String style) {
  final raus = <String>[];
  for (final d in style.split(';')) {
    final doppel = d.indexOf(':');
    if (doppel < 0) {
      if (pyStrip(d).isNotEmpty) raus.add(pyStrip(d));
      continue;
    }
    final name = pyStrip(d.substring(0, doppel)).toLowerCase();
    final wert = pyStrip(d.substring(doppel + 1)).toLowerCase();
    if (pyMatch(_rahmenEigenschaft, name) == null) {
      raus.add(name);
    } else if (pySplit(wert).any((w) => pyMatch(_rahmenWert, w) == null)) {
      raus.add('$name: $wert');
    }
  }
  return raus;
}

final _ueberschrift = pyReGanz(r'h[3-6]');
final _htmlDatei = pyRe(r'\.html?$', caseSensitive: false);

/// Prüft ein Feld des Entwurfs gegen die HTML-Regeln: keine
/// style-Attribute außer Rahmenlinien an Tabellen, Überschriften ab <h3>,
/// Bilder mit Alternativtext und img-fluid aus dateien/, Tabellen mit
/// Klasse, <strong>/<em> statt <b>/<i>/<u>, keine leeren Absätze, keine
/// &nbsp;-Ketten, keine Word-Reste, keine übersprungene Überschriftenebene,
/// https statt http, höchstens zwei Kastenarten -- dieselben Befunde wie in
/// auswertung.dart. Dazu Platzhalter der Vorlagen und Markdown-Reste.
/// Sammelt die Dateien, auf die @@PLUGINFILE@@ zeigt. Die SchuCu-Tabelle
/// folgt ihrer Vorlage und kommt vorher heraus.
class _HtmlRegeln extends PyHtmlLeser {
  final befunde = <String>[];
  final dateien = <String>[];
  final textStuecke = <String>[];
  final elemente = <String>{}; // Dateien, die ein Rahmen als Element einbindet
  int svg = 0, code = 0;
  int ebene = 2;
  final kaesten = <String>{};
  (int, bool)? absatz;

  void befund(String t) {
    if (!befunde.contains(t)) befunde.add(t);
  }

  @override
  void starttag(String tag, List<Attribut> attrs) {
    element(tag, attributMap(attrs), starttagText ?? tag);
    if (tag == 'svg') {
      svg++;
    } else if ((tag == 'code' || tag == 'pre') && svg == 0) {
      code++;
    }
  }

  @override
  void startendtag(String tag, List<Attribut> attrs) =>
      element(tag, attributMap(attrs), starttagText ?? tag);

  @override
  void endtag(String tag) {
    if (tag == 'svg' && svg > 0) {
      svg--;
    } else if ((tag == 'code' || tag == 'pre') && code > 0 && svg == 0) {
      code--;
    }
    if (tag == 'p' && absatz != null && svg == 0) {
      final (anfang, mitInhalt) = absatz!;
      if (!mitInhalt && pyStrip(textStuecke.skip(anfang).join().replaceAll('\xa0', ' ')).isEmpty) {
        befund('leerer Absatz -- Abstand kommt aus den Stylesheets, nicht aus leeren Zeilen');
      }
      absatz = null;
    }
    if (_block.contains(tag)) textStuecke.add('\n');
  }

  @override
  void daten(String d) {
    if (svg > 0) return;
    if (d.contains('\xa0\xa0')) befund('&nbsp;-Kette zum Einrücken -- eine Liste oder ein neuer Absatz');
    if (code == 0) textStuecke.add(d);
  }

  void element(String tag, Map<String, String?> a, String roh) {
    // Code im Text: dieselbe Grenze wie skripteImTextPruefen in elemente.dart
    // -- die App schriebe das Blatt nicht. Auch in einer eingebetteten
    // Zeichnung, die sonst eigene Regeln hat.
    if (tag == 'script') {
      befund('Code im Text (<script>) -- Interaktives als Element in einen Rahmen (references/elemente.md)');
      return;
    }
    for (final MapEntry(key: k, value: w0) in a.entries) {
      final w = w0 ?? '';
      // Welche Attribute Code sind, entscheidet die App (skriptArtVonAttribut);
      // die Sätze sind die des Entwurfs.
      switch (skriptArtVonAttribut(k, w)) {
        case SkriptArt.ereignis:
          befund(
            'Code im Text (${ereignisName(k, w)} an <$tag>) -- Interaktives als Element '
            '(references/elemente.md)',
          );
        case SkriptArt.srcdoc:
          befund('<$tag srcdoc>: Der Moodle-Editor löscht ihn -- als Elementdatei in dateien/ einbinden');
        case SkriptArt.javascriptAdresse:
          befund('javascript:-Adresse an <$tag> -- Code gehört in ein Element');
        case _:
          break;
      }
    }
    if (svg > 0) return; // eine eingebettete Zeichnung hat eigene Elemente
    if (_block.contains(tag)) textStuecke.add('\n');
    if (tag == 'iframe') {
      final src = _str(a['src']);
      if (src.startsWith('@@PLUGINFILE@@/') && _htmlDatei.hasMatch(src)) {
        elemente.add(pyUnquote(src.substring('@@PLUGINFILE@@/'.length)));
        final sandbox = pySplit(_str(a['sandbox']).isEmpty ? '-' : _str(a['sandbox'])).toSet().toList()..sort();
        if (sandbox.join(' ') != 'allow-scripts') {
          befund('Element ${src.substring(15)} ohne sandbox="allow-scripts" -- die App schreibt es so nicht');
        }
        if (pyStrip(_str(a['title'])).isEmpty) {
          befund('Element ${src.substring(15)} ohne title -- er sagt Screenreadern, was es ist');
        }
      }
    }
    if (!_htmlElemente.contains(tag)) {
      befund('Platzhalter steht noch da: ${pyKurz(textNorm(roh), 60)}');
      return;
    }
    final style = a['style'];
    if (style != null) {
      if (!_tabellenteile.contains(tag)) {
        befund('style-Attribut an <$tag> -- das Aussehen kommt aus den Stylesheets von Moodle');
      } else if (_mehrAlsRahmen(style).isNotEmpty) {
        befund('style-Attribut an <$tag> mit mehr als Rahmenlinien (${_mehrAlsRahmen(style).join(', ')})');
      }
    }
    final klassen = pySplit(_str(a['class']));
    if (klassen.any((k) => k.startsWith('Mso'))) {
      befund('Word-Rest class="Mso…" -- das HTML neu schreiben, nicht übernehmen');
    }
    if (tag == 'p') {
      absatz = (textStuecke.length, false);
    } else if (const ['img', 'iframe', 'video', 'audio', 'object'].contains(tag) && absatz != null) {
      absatz = (absatz!.$1, true);
    }
    if (klassen.contains('alert')) {
      kaesten.addAll(klassen.where((k) => k.startsWith('alert-')));
    }
    if (tag == 'h1' || tag == 'h2') {
      befund('<$tag>: Überschriften beginnen bei <h3>, h1 und h2 sind Moodle vorbehalten');
    } else if (_ueberschrift.hasMatch(tag)) {
      final n = int.parse(tag[1]);
      if (n > ebene + 1) befund('<$tag> folgt auf <h$ebene>: Ebene übersprungen');
      ebene = n;
    } else if (const ['b', 'i', 'font', 'center'].contains(tag)) {
      befund('<$tag> -- zur Hervorhebung <strong> oder <em>, sonst nichts');
    } else if (tag == 'u') {
      befund('<u> -- Unterstrichenes hält jeder für einen Link; <strong> oder <em>');
    } else if (tag == 'table' && !klassen.contains('table')) {
      befund('Tabelle ohne class="table" (etwa "table table-bordered")');
    } else if (tag == 'img') {
      final src = _str(a['src']);
      if (pyStrip(_str(a['alt'])).isEmpty) befund('Bild ohne Alternativtext: ${pyKurz(src, 60)}');
      if (!klassen.contains('img-fluid')) befund('Bild ohne class="img-fluid": ${pyKurz(src, 60)}');
      if (!src.startsWith('@@PLUGINFILE@@/')) {
        befund(
          'Bild „${pyKurz(src, 60)}": src="@@PLUGINFILE@@/<name>" und die Datei in dateien/ -- '
          'Moodle speichert sie so selbst',
        );
      }
    }
    for (final attr in ['href', 'src']) {
      final w = _str(a[attr]);
      if (w.startsWith('@@PLUGINFILE@@/')) {
        dateien.add(pyUnquote(w.substring('@@PLUGINFILE@@/'.length)));
      } else if (w.startsWith('//')) {
        befund('protokollrelative Adresse ${pyKurz(w, 60)} -- mit https: davor, auf Papier sonst unvollständig');
      } else if (w.startsWith('http://')) {
        befund('unverschlüsselte Adresse ${pyKurz(w, 60)} -- https://');
      }
    }
  }

  List<String> ergebnis() {
    if (kaesten.length > 2) {
      befund('mehr als zwei Kastenarten: ${(kaesten.toList()..sort()).join(', ')} -- höchstens zwei je Seite');
    }
    final text = textStuecke.join();
    for (final (muster, ersatz) in _markdown) {
      final m = muster.firstMatch(text);
      if (m != null) befund('Markdown im HTML: „${pyKurz(textNorm(m[0]!), 40)}" -- $ersatz');
    }
    return befunde;
  }
}

// ---- Die beiden Leser ------------------------------------------------------

typedef _Entwurf = ({
  String titel,
  List<_Seite> seiten,
  List<String> ohneInhalt,
  List<(String, String)> vorab,
  Set<String> verboten,
  Map<String, String> weitere,
});

final _bildEndung = pyRe(r'\.(svg|png|jpe?g|gif|webp)$', caseSensitive: false);
final _modulTyp = pyReGanz(r'[a-z]+');
final _strichOderZiffer = pyRe(r'[-\d]');

/// Liest den Entwurf. Gibt Titel, Seiten, die ohne Inhalt, die Befunde am
/// Entwurf, die Namen, die in keinem Text stehen dürfen, und die weiteren
/// Aktivitäten -- oder einen Text, warum nichts zu prüfen ist.
class _EntwurfLeser {
  _EntwurfLeser(this.fs, this.ordner);
  final _Dateien fs;
  final String ordner;
  final vorab = <(String, String)>[];
  final seiten = <_Seite>[];
  final ohneInhalt = <String>[];
  final verboten = <String>{};
  final genutzt = <String>{};
  final weitere = <String, String>{}; // Name -> wie ein Befund sie nennt
  List<Object?> liste = const [];

  void befund(String wo, String text) => vorab.add((wo, text));

  String rel(String o) => p.relative(o, from: ordner).replaceAll(p.separator, '/');

  /// HTML-Regeln und dateien/ an einem Feld oder Kapitel: Jede Datei, auf
  /// die es zeigt, liegt in dateien/ desselben Ordners -- von dort lädt die
  /// App sie in den Entwurfsbereich dieses Felds --, und jede Datei dort
  /// wird gebraucht.
  void htmlPruefen(String o, String h, String wo) {
    final r = _HtmlRegeln()..lesen(h.replaceAll(_tabelleRe, ' '));
    for (final t in r.ergebnis()) {
      befund(wo, t);
    }
    // Ein Formelfehler ist ein Syntaxfehler: Die App bricht das Schreiben
    // dieses Felds ab, bis er behoben ist.
    for (final t in _formelFehler(h.replaceAll(_tabelleRe, ' '))) {
      befund(wo, 'Formelfehler: $t');
    }
    final da = p.join(o, 'dateien');
    final daIst = fs.ordner(da)
        ? (fs.liste(da).where((f) => fs.datei(p.join(da, f))).toList()..sort())
        : <String>[];
    for (final n in r.dateien.toSet().toList()..sort()) {
      if (!daIst.contains(n)) {
        befund(wo, '$n liegt nicht in ${rel(o)}/dateien/ -- jedes Blatt bringt seine Bilder selbst mit');
      } else if (r.elemente.contains(n)) {
        for (final t in _elementFehler(fs.text(p.join(da, n), ersetzen: true))) {
          befund(wo, 'Element $n: $t');
        }
      } else {
        final stellen = _codeInDatei(n, fs.bytes(p.join(da, n)));
        if (stellen.isNotEmpty) {
          befund(
            wo,
            'Datei $n enthält Code (${stellen[0]}) und ist kein Element -- die App lädt sie so nicht hoch '
            '(references/elemente.md)',
          );
        }
      }
    }
    for (final f in daIst) {
      if (!r.dateien.contains(f)) befund(wo, '${rel(o)}/dateien/$f wird nicht eingebunden');
      if (_bildEndung.hasMatch(f)) verboten.add(f);
    }
  }

  Object? jsonIn(String d, String datei, String wo) {
    final pfad = p.join(d, datei);
    if (!fs.datei(pfad)) {
      befund(wo, '$datei fehlt in ${rel(d)}');
      return null;
    }
    try {
      return fs.json(pfad);
    } on FormatException catch (x) {
      befund(wo, '$datei ist kein gültiges JSON: ${x.message}');
      return null;
    }
  }

  /// Eine Lernlandkarte (learningmap): lernlandkarte.json, Hintergrundbild
  /// und die Ziele ihrer Orte (references/vorlagen.md, „Weitere Aktivitäten
  /// im Entwurf"). Die Regeln der Datei sind die der App
  /// (lernlandkarte_entwurf.dart): Sie weist alles andere beim Anlegen ab,
  /// und dann stünde der Entwurf schon halb im Kurs. Die Ziele stehen im
  /// Eintrag (`"ziele": {"p1": "<Name einer Aktivität>"}`), nicht in der Datei,
  /// denn dort weist die App sie ab; gesetzt werden sie erst nach dem
  /// Anlegen aller Aktivitäten.
  void karte(String d, Map e, String wo) {
    bool zahl(Object? x, num bis) => x is num && x >= 0 && x <= bis;

    final j = jsonIn(d, 'lernlandkarte.json', wo);
    final ids = <String>[];
    if (j is Map) {
      if (j.keys.any((k) => k != 'orte' && k != 'wege')) {
        befund(wo, 'lernlandkarte.json: erlaubt sind nur "orte" und "wege"');
      }
      var orte = j['orte'], wege = j['wege'];
      if (orte is! List || orte.isEmpty || orte.length > 64) {
        befund(wo, 'lernlandkarte.json braucht "orte", eine Liste von 1 bis 64 Orten');
        orte = <Object?>[];
      }
      if (wege is! List || wege.length > 128) {
        befund(wo, 'lernlandkarte.json braucht "wege", eine Liste von höchstens 128 Wegen (auch leer)');
        wege = <Object?>[];
      }
      var i = 0;
      for (final o in orte) {
        i++;
        final titel = o is Map ? (o.containsKey('titel') ? o['titel'] : '') : null;
        if (o is! Map || o.keys.any((k) => !const ['id', 'x', 'y', 'titel'].contains(k))) {
          befund(
            wo,
            'lernlandkarte.json: Ort $i darf nur id, x, y und titel enthalten -- ein Ziel steht '
            'im Eintrag unter "ziele"',
          );
        } else if (o['id'] != 'p$i') {
          befund(
            wo,
            'lernlandkarte.json: Ort $i muss "p$i" heißen -- die Kennungen laufen von p1 an '
            'ohne Lücke',
          );
        } else if (!zahl(o['x'], 1000) || !zahl(o['y'], 560)) {
          befund(wo, 'lernlandkarte.json: ${o['id']} braucht x von 0 bis 1000 und y von 0 bis 560');
        } else if (titel is! String || pyLen(titel) > 80) {
          befund(wo, 'lernlandkarte.json: der Titel von ${o['id']} ist kein Text von höchstens 80 Zeichen');
        } else {
          ids.add(o['id'] as String);
        }
      }
      final gesehen = <(Object?, Object?)>{};
      i = 0;
      for (final w in wege) {
        i++;
        if (w is! Map || w.keys.any((k) => k != 'von' && k != 'nach')) {
          befund(wo, 'lernlandkarte.json: Weg $i darf nur von und nach enthalten');
        } else if (!ids.contains(w['von']) ||
            !ids.contains(w['nach']) ||
            ids.indexOf(w['von'] as String) >= ids.indexOf(w['nach'] as String)) {
          befund(
            wo,
            'lernlandkarte.json: Weg $i (${pyStr(w['von'])} nach ${pyStr(w['nach'])}) verbindet keine zwei Orte der '
            'Karte, und "von" hat die kleinere Nummer',
          );
        } else if (gesehen.contains((w['von'], w['nach']))) {
          befund(wo, 'lernlandkarte.json: der Weg von ${w['von']} nach ${w['nach']} steht zweimal');
        } else {
          gesehen.add((w['von'], w['nach']));
        }
      }
    }
    // Das Hintergrundbild ist ein Pflichtfeld des Formulars (Moodle speichert die Karte sonst nicht).
    final b = p.join(d, 'bereiche', 'backgroundfile');
    final bilder = fs.ordner(b) ? fs.walk(b).toList() : <(String, String)>[];
    if (bilder.isEmpty) {
      befund(
        wo,
        'Lernlandkarte ohne Hintergrundbild -- es liegt in ${rel(d)}/bereiche/backgroundfile/, sonst '
        'speichert Moodle die Karte nicht',
      );
    }
    for (final (w, f) in bilder) {
      final stellen = _codeInDatei(f, fs.bytes(p.join(w, f)));
      if (stellen.isNotEmpty) {
        befund(
          wo,
          '${rel(p.join(w, f))} enthält Code (${stellen[0]}) -- die App lädt sie so nicht hoch (references/elemente.md)',
        );
      }
    }
    // Jeder Ort braucht ein Ziel: Ohne erscheint er nicht in der Karte.
    final ziele = e['ziele'];
    if (ziele is! Map) {
      befund(
        wo,
        'Lernlandkarte ohne Ziele: "ziele": {"p1": "<Name einer Aktivität dieser Lernsituation>"} im '
        'Eintrag -- ein Ort ohne Ziel erscheint nicht in der Karte',
      );
      return;
    }
    final namen = {
      for (final x in liste)
        if (x is Map) textNorm(_str(x['name'])),
    };
    final eigen = textNorm(_str(e['name']));
    for (final MapEntry(key: k, value: v) in ziele.entries) {
      if (ids.isNotEmpty && !ids.contains(k)) {
        befund(wo, 'ziele nennt „${pyStr(k)}", einen Ort, den lernlandkarte.json nicht hat');
      }
      final vn = textNorm(pyStr(v));
      Object? zielTyp;
      for (final x in liste) {
        if (x is Map && textNorm(_str(x['name'])) == vn) {
          zielTyp = x['typ'];
          break;
        }
      }
      if (!namen.contains(vn) || vn == eigen || zielTyp == 'learningmap') {
        befund(
          wo,
          'ziele: „$vn" für ${pyStr(k)} ist keine andere Aktivität dieser Lernsituation (der Name steht in '
          '$_manifest)',
        );
      }
    }
    for (final k in ids) {
      if (!ziele.containsKey(k)) {
        befund(wo, '$k hat kein Ziel in "ziele" -- ein Ort ohne Ziel erscheint nicht in der Karte');
      }
    }
  }

  /// Was eine weitere Aktivität braucht, damit die Übertragung sie anlegen
  /// und füllen kann (references/vorlagen.md, „Weitere Aktivitäten im
  /// Entwurf"). [d]: ihr Ordner, null bei einem Link ohne Ordner.
  void weitereAktivitaet(String typ, String? d, Map e, String wo) {
    final einst = e['einstellungen'] is Map ? e['einstellungen'] as Map : const {};
    if (typ == 'url' && !_str(einst['externalurl']).startsWith('https://')) {
      befund(wo, 'Link ohne Adresse: "einstellungen": {"externalurl": "https://…"}');
    }
    if (d == null) return;
    final texte = <String>[];
    final intro = p.join(d, 'introeditor.html');
    if (fs.datei(intro)) texte.add(fs.text(intro));
    if (typ == 'board' || typ == 'kanban') {
      final j = jsonIn(d, '$typ.json', wo);
      if (j != null) {
        final roh = j is Map ? j['spalten'] : null;
        var spalten = <String>[];
        if (roh is! List ||
            roh.isEmpty ||
            !roh.every((s) => s is String && textNorm(s).isNotEmpty)) {
          befund(wo, '$typ.json braucht "spalten", eine Liste von Namen');
        } else {
          spalten = roh.cast<String>();
          if ({for (final s in spalten) textNorm(s)}.length != spalten.length) {
            befund(wo, '$typ.json: zwei Spalten mit demselben Namen');
          }
        }
        final was = typ == 'board' ? 'notizen' : 'karten';
        final namen = {for (final s in spalten) textNorm(s)};
        for (final x in j is Map ? _pyIter(pyWahr(j[was]) ? j[was] : const []) : const <Object?>[]) {
          if (x is! Map || !namen.contains(textNorm(_str(x['spalte'])))) {
            befund(wo, '$typ.json: ${typ == 'board' ? 'eine Notiz' : 'eine Karte'} nennt keine Spalte, die es gibt');
          } else if (typ == 'kanban' && textNorm(_str(x['titel'])).isEmpty) {
            befund(wo, 'kanban.json: eine Karte ohne "titel"');
          }
        }
      }
    } else if (typ == 'checklist') {
      final j = jsonIn(d, 'eintraege.json', wo);
      if (j != null && (j is! List || j.isEmpty)) {
        befund(wo, 'eintraege.json braucht eine Liste von Einträgen');
      } else if (j is List) {
        var vorher = -1;
        var i = 0;
        for (final x in j) {
          i++;
          if (x is! Map || textNorm(_str(x['text'])).isEmpty) {
            befund(wo, 'eintraege.json: Eintrag $i ohne "text"');
            continue;
          }
          // Wie isinstance(…, int) in Python: Wahrheitswerte zählen als 0 und 1.
          final roh = x.containsKey('tiefe') ? x['tiefe'] : 0;
          final tiefeZahl = roh is bool ? (roh ? 1 : 0) : roh;
          int tiefe;
          if (tiefeZahl is! int || tiefeZahl < 0 || tiefeZahl > vorher + 1) {
            befund(
              wo,
              'eintraege.json: „${textNorm(pyStr(x['text']))}" springt in der Einrückung -- höchstens eine Stufe '
              'tiefer als der Eintrag davor',
            );
            tiefe = vorher + 1;
          } else {
            tiefe = tiefeZahl;
          }
          vorher = tiefe;
          final zustand = x['zustand'];
          if (!const [null, 'pflicht', 'optional', 'ueberschrift'].contains(zustand)) {
            befund(
              wo,
              'eintraege.json: „${textNorm(pyStr(x['text']))}" hat "zustand" ${pyRepr(zustand)} -- möglich sind '
              'pflicht, optional, ueberschrift',
            );
          }
        }
      }
    } else if (typ == 'wiki') {
      final j = jsonIn(d, 'seiten.json', wo);
      if (j != null && (j is! List || j.isEmpty)) {
        befund(wo, 'seiten.json braucht eine Liste von Seiten');
      } else if (j is List) {
        final titel = <String>[];
        var i = 0;
        for (final x in j) {
          i++;
          final t = x is Map ? textNorm(_str(x['titel'])) : '';
          final f = x is Map ? x['datei'] : null;
          if (t.isEmpty || f is! String || !fs.datei(p.join(d, f))) {
            befund(wo, 'seiten.json: Seite $i braucht "titel" und eine "datei", die im Ordner liegt');
            continue;
          }
          titel.add(t);
          texte.add(fs.text(p.join(d, f)));
        }
        if (titel.toSet().length != titel.length) {
          befund(wo, 'seiten.json: zwei Seiten mit demselben Titel');
        }
        final start = textNorm(_str(einst['firstpagetitle']));
        if (titel.isNotEmpty && start != titel[0]) {
          befund(
            wo,
            'die erste Seite „${titel[0]}" ist die Startseite und muss heißen wie "firstpagetitle" in den '
            'Einstellungen${start.isNotEmpty ? ' („$start")' : ' -- dort fehlt er'}',
          );
        }
      }
    } else if (typ == 'quiz') {
      final fr = e['fragen'];
      if (fr is! Map || textNorm(_str(fr['sammlung'])).isEmpty || textNorm(_str(fr['kategorie'])).isEmpty) {
        befund(wo, 'Test ohne Ort für seine Fragen: "fragen": {"sammlung": "…", "kategorie": "…"} im Eintrag');
      }
      final pfad = p.join(d, 'fragen.xml');
      XmlElement? wurzel;
      if (!fs.datei(pfad)) {
        befund(wo, 'fragen.xml fehlt -- die Fragen schreibt der Skill moodle-fragen');
      } else {
        try {
          // Ein Byte-Order-Mark am Anfang überliest ElementTree.
          final t = fs.text(pfad);
          wurzel = XmlDocument.parse(t.startsWith('\ufeff') ? t.substring(1) : t).rootElement;
        } on XmlException catch (x) {
          befund(wo, 'fragen.xml ist kein gültiges XML: ${x.message}');
        } on FormatException catch (x) {
          befund(wo, 'fragen.xml ist kein gültiges XML: ${x.message}');
        }
      }
      if (wurzel != null) {
        final fragen = [
          for (final q in [wurzel, ...wurzel.descendantElements])
            if (q.name.qualified == 'question' && q.getAttribute('type') != 'category') q,
        ];
        if (fragen.isEmpty) befund(wo, 'fragen.xml enthält keine Frage');
        final gesehen = <String>{};
        for (final q in fragen) {
          final idn = textNorm(_findtext(q, ['idnumber']) ?? '');
          if (idn.isEmpty) {
            final name = textNorm(_findtext(q, ['name', 'text']) ?? '');
            befund(
              wo,
              'Frage „${name.isEmpty ? '?' : name}" ohne Sachnummer (<idnumber>) -- sie ist die einzige Kennung, die '
              'eine Änderung überlebt',
            );
          } else if (gesehen.contains(idn)) {
            befund(wo, 'Sachnummer $idn steht zweimal in fragen.xml');
          }
          gesehen.add(idn);
        }
      }
    } else if (typ == 'learningmap') {
      karte(d, e, wo);
    } else if (typ == 'folder' || typ == 'resource') {
      final b = p.join(d, 'bereiche', 'files');
      final dateien = fs.ordner(b) ? fs.walk(b).toList() : <(String, String)>[];
      final n = dateien.length;
      if (typ == 'folder' && n == 0) {
        befund(wo, 'Verzeichnis ohne Dateien -- sie liegen in ${rel(d)}/bereiche/files/');
      }
      if (typ == 'resource' && n != 1) {
        befund(wo, 'eine Datei braucht genau eine Datei in ${rel(d)}/bereiche/files/ (gefunden: $n)');
      }
      for (final (w, f) in dateien) {
        final stellen = _codeInDatei(f, fs.bytes(p.join(w, f)));
        if (stellen.isNotEmpty) {
          befund(
            wo,
            '${rel(p.join(w, f))} enthält Code (${stellen[0]}) -- die App lädt sie so nicht hoch (references/elemente.md)',
          );
        }
      }
    }
    if (texte.isNotEmpty) htmlPruefen(d, texte.join('\n'), wo);
  }

  /// Liest den Entwurf; ein Text sagt, warum es nichts zu prüfen gibt.
  Object lesen() {
    final pfad = p.join(ordner, _manifest);
    if (!fs.datei(pfad)) {
      return 'Kein Entwurf: $_manifest fehlt in $_anzeigeOrdner (references/vorlagen.md, „Der Entwurf")';
    }
    Object? m;
    try {
      m = fs.json(pfad);
    } on FormatException catch (e) {
      return '$_manifest ist kein gültiges JSON: ${e.message}';
    }
    final ab = m is Map ? m['abschnitt'] : null;
    final l = m is Map ? m['aktivitaeten'] : null;
    if (ab is! Map || textNorm(_str(ab['name'])).isEmpty || l is! List || l.isEmpty) {
      return '$_manifest braucht "abschnitt" mit "name" und eine nicht leere Liste "aktivitaeten"';
    }
    liste = l;

    // Die Beschreibung des Abschnitts: die Kurzfassung der Handlungssituation.
    final titel = textNorm(pyStr(ab['name']));
    final ao = ab['ordner'];
    if (ao is! String || !fs.datei(p.join(ordner, ao, 'summary_editor.html'))) {
      befund(
        _manifest,
        'Beschreibung des Abschnitts fehlt: "abschnitt" braucht "ordner" mit '
        'summary_editor.html, der Kurzfassung der Handlungssituation',
      );
    } else {
      genutzt.add(ao);
      final h = fs.text(p.join(ordner, ao, 'summary_editor.html'));
      if (_htmlText(h).isEmpty) befund('Abschnitt ($ao)', 'Beschreibung ist leer');
      htmlPruefen(p.join(ordner, ao), h, 'Abschnitt ($ao)');
    }

    final namen = <String>{};
    var i = 0;
    for (final e in l) {
      i++;
      if (e is! Map) {
        befund(_manifest, 'Eintrag $i in "aktivitaeten" ist kein Objekt');
        continue;
      }
      final typ = e['typ'];
      final name = textNorm(_str(e['name']));
      final o = e['ordner'];
      final wo = name.isNotEmpty
          ? (o is String && o.isNotEmpty ? '„$name" ($o)' : '„$name"')
          : 'Eintrag $i';
      if (name.isEmpty) {
        befund(wo, 'ohne "name" -- er wird der Name der Aktivität');
        continue;
      }
      if (namen.contains(name)) befund(wo, 'derselbe Name steht zweimal in $_manifest');
      namen.add(name);
      if (e.containsKey('einstellungen') && e['einstellungen'] is! Map) {
        befund(wo, '"einstellungen" muss ein Objekt sein, wie bei aktivitaet_anlegen');
      }
      if (typ == 'subsection') continue; // ohne Inhalt; die Einträge danach kommen hinein
      if (typ is! String || pyMatch(_modulTyp, typ) == null) {
        befund(wo, '"typ" fehlt oder ist kein Moodle-Typ (page, assign, label, book, subsection …)');
        continue;
      }
      if (weitereTypen.contains(typ)) {
        weitere[name] = wo;
        if (pyMatch(_rolle, name) != null || const [_nameSchucu, _nameHand, _nameSituation].contains(name)) {
          befund(wo, 'ist kein Blatt und trägt keine Kennung -- der Name sagt, wozu die Aktivität da ist');
        }
      }
      if (typ == 'url' && !pyWahr(o)) {
        weitereAktivitaet(typ, null, e, wo); // ein Link braucht keinen Ordner
        continue;
      }
      if (o is! String || o.isEmpty || !fs.ordner(p.join(ordner, o))) {
        befund(wo, o is String && o.isNotEmpty ? 'Ordner fehlt' : 'ohne "ordner"');
        continue;
      }
      genutzt.add(o);
      if (_strichOderZiffer.hasMatch(o)) verboten.add(o);
      final d = p.join(ordner, o);
      if (typ == 'book') {
        final b = _liesBuch(fs, d);
        if (b == null) {
          befund(wo, 'Buch ohne kapitel.json -- die Kapitel stehen in kapitel-<id>/content_editor.html');
          continue;
        }
        final (h, md, kapitel) = b;
        if (kapitel.isEmpty) {
          befund(wo, 'Buch ohne Kapitel');
        } else if (pyWahr(kapitel[0].$3['unterkapitel'])) {
          befund(wo, 'das erste Kapitel kann kein Unterkapitel sein');
        }
        for (final (ko, kh, k) in kapitel) {
          final kwo = '$wo, Kapitel „${textNorm(_str(k['titel']))}"';
          if (textNorm(_str(k['titel'])).isEmpty) befund(kwo, 'Kapitel ohne "titel" in kapitel.json');
          if (!fs.datei(p.join(ko, 'content_editor.html'))) {
            befund(kwo, '${rel(ko)}/content_editor.html fehlt');
          } else if (_htmlText(kh).isEmpty) {
            befund(kwo, 'Kapitel ohne Inhalt -- Moodle verlangt in jedem Kapitel Text');
          } else {
            htmlPruefen(ko, kh, kwo);
          }
        }
        seiten.add(_Seite(typ, name, false, h, md, [for (final k in kapitel) k.$1], wo));
      } else if (weitereTypen.contains(typ)) {
        weitereAktivitaet(typ, d, e, wo);
      } else if (inhaltsFelder.containsKey(typ)) {
        final erstes = '${inhaltsFelder[typ]![0]}.html';
        if (!fs.datei(p.join(d, erstes))) {
          befund(wo, '$erstes fehlt in $o -- dort sucht aktivitaet_anlegen den Inhalt');
          continue;
        }
        final h = _liesFeld(fs, d, typ);
        htmlPruefen(d, h, wo);
        seiten.add(_Seite(typ, name, false, h, _zuMarkdown(h), [d], wo));
      } else {
        ohneInhalt.add('„$name" ($typ)');
      }
    }

    // Was nicht in lernsituation.json steht, kommt nicht in den Kurs.
    for (final f in fs.liste(ordner)..sort()) {
      if (f.startsWith('.') || f == _manifest || genutzt.contains(f)) continue;
      if (FileSystemEntity.isDirectorySync(p.join(ordner, f))) {
        befund(f, 'steht nicht in $_manifest -- kommt nicht in den Kurs');
      } else {
        befund(f, 'hat im Entwurf keinen Platz -- neben $_manifest gibt es nur die Ordner der Aktivitäten');
      }
    }
    return (
      titel: titel,
      seiten: seiten,
      ohneInhalt: ohneInhalt,
      vorab: vorab,
      verboten: verboten,
      weitere: weitere,
    );
  }

  String _anzeigeOrdner = '';
}

/// `findtext` von ElementTree: der Text des Kindes auf dem Pfad (nur der
/// Text vor dem ersten Unterelement), '' bei einem leeren, null ohne Kind.
String? _findtext(XmlElement e, List<String> pfad) {
  XmlElement? akt = e;
  for (final n in pfad) {
    akt = akt!.childElements.where((c) => c.name.qualified == n).firstOrNull;
    if (akt == null) return null;
  }
  final b = StringBuffer();
  for (final c in akt!.children) {
    if (c is XmlElement) break;
    if (c is XmlText || c is XmlCDATA) b.write(c.value);
  }
  return b.toString();
}

typedef _Moodle = ({
  String titel,
  int kurs,
  List<_Seite> seiten,
  List<String> ohneInhalt,
  List<String> fehlen,
  Map<int, String> ziele,
  Map<String, String> weitere,
});

/// Liest den Abschnitt aus dem Arbeitsordner: Titel, Kurs, Seiten, die
/// ohne Inhalt, was noch zu lesen ist, {cmid: Name} aller Aktivitäten des
/// Abschnitts und die weiteren -- oder null, wenn keine kurs-*.json ihn
/// enthält.
_Moodle? _liesMoodle(_Dateien fs, String ao, int abschnittId) {
  final gefunden = fs.ordner(ao) ? _abschnittAusKurs(fs, ao, abschnittId) : null;
  if (gefunden == null) return null;
  final (kurs, titel, cms) = gefunden;
  final seiten = <_Seite>[], ohneInhalt = <String>[], fehlen = <String>[];
  final weitere = <String, String>{};
  for (final (cmid, modul, name, erreichbar) in cms) {
    final wo = '„$name" (cm $cmid)';
    if (modul == 'subsection') continue;
    if (weitereTypen.contains(modul)) {
      // Ihr Inhalt steht nicht im Formular; geprüft wird, dass die
      // Handreichung sie nennt und jede Nennung ein Link ist.
      weitere[name] = wo;
      continue;
    }
    if (modul == 'book') {
      final b = _liesBuch(fs, p.join(ao, 'buch-$cmid'));
      if (b == null) {
        fehlen.add('buch_lesen($cmid) für „$name"');
        continue;
      }
      final (h, md, kapitel) = b;
      seiten.add(_Seite(modul, name, erreichbar, h, md, [for (final k in kapitel) k.$1], wo));
    } else if (inhaltsFelder.containsKey(modul)) {
      final o = p.join(ao, 'cm-$cmid');
      if (!fs.datei(p.join(o, 'uebersicht.json'))) {
        fehlen.add('aktivitaet_lesen($cmid) für „$name"');
        continue;
      }
      final h = _liesFeld(fs, o, modul);
      seiten.add(_Seite(modul, name, erreichbar, h, _zuMarkdown(h), [o], wo));
    } else {
      ohneInhalt.add(wo);
    }
  }
  return (
    titel: titel,
    kurs: kurs,
    seiten: seiten,
    ohneInhalt: ohneInhalt,
    fehlen: fehlen,
    ziele: {for (final (cmid, _, name, _) in cms) cmid: name},
    weitere: weitere,
  );
}

// ---- Die Prüfung -----------------------------------------------------------

Map<String, _Vorlage> _vorlagenLesen(Map<String, String> vorlagen) {
  final raus = <String, _Vorlage>{};
  for (final art in schucuVorlagenDateien.keys) {
    final roh = vorlagen[art];
    if (roh == null) throw StateError('Die Vorlage der SchuCu-Tabelle „$art" fehlt.');
    final (zeilen, absaetze) = _liesTabelle(_zeilenumbrueche(roh));
    raus[art] = (_geruestVon(zeilen), zeilen, absaetze);
  }
  return raus;
}

/// Prüft die Seiten an der Prüfform und schreibt das Ergebnis. [ziele]
/// ({cmid: Name}) gibt es nur in Moodle; dann werden auch die Links geprüft.
int _pruefe(
  _Dateien fs,
  StringBuffer aus,
  Map<String, String> vorlagenRoh,
  String kopf,
  List<_Seite> seiten,
  List<String> ohneInhalt, {
  List<(String, String)> vorab = const [],
  Set<String> verboten = const {},
  Map<int, String>? ziele,
  Map<String, String> weitere = const {},
}) {
  final belegt = <String, _Seite>{};
  final ohneRolle = <_Seite>[];
  final ordner = <String, _Pruefdatei>{};
  for (final s in seiten) {
    final datei = _rolleVon(s.name, s.h, s.md, belegt);
    if (datei == null) {
      ohneRolle.add(s);
      continue;
    }
    belegt[datei] = s;
    final inhalt = datei == _schucu ? pyStrip(s.h) : s.md;
    ordner[datei] = _Pruefdatei.text('# ${s.name}\n\n$inhalt\n');
    for (final o in s.ordner) {
      final d = p.join(o, 'dateien');
      if (!fs.ordner(d)) continue;
      for (final f in fs.liste(d)) {
        if (fs.datei(p.join(d, f))) ordner[f] = _Pruefdatei.kopie(p.join(d, f));
      }
    }
  }

  aus.writeln(kopf);
  if (!belegt.containsKey(_hand)) {
    aus.writeln(
      'Keine Lehrerhandreichung: keine Seite „$_nameHand" und keine mit dem Abschnitt „Ablaufplan" -- '
      'ohne sie ist nichts zu prüfen.',
    );
    for (final (wo, text) in vorab) {
      aus.writeln('  ${pyLinks(wo, 40)} $text');
    }
    return 2;
  }
  final pr = _Pruefung(ordner, _vorlagenLesen(vorlagenRoh), aus, bilddateien: ziele != null, weitere: weitere);
  if (pr.pruefen(verboten) == null) return 2;
  for (final (wo, text) in vorab) {
    pr.befund(wo, text);
  }
  if (belegt[_hand]!.h.contains('<table class="lernsituation"')) {
    pr.befund(_hand, 'SchuCu-Tabelle steht in der Handreichung -- sie gehört allein auf die Seite „$_nameSchucu"');
  }
  if (ziele != null) _links(fs, pr, belegt, ziele, weitere);
  for (final s in ohneRolle) {
    if (ziele == null) {
      pr.befund(
        s.wo,
        'Name ohne Kennung -- ein Blatt heißt „Arbeitsblatt n: …", „Infoblatt n: …", '
        '„Hilfe zu …", „Vertiefung zu …", „Lösung zu …"; dazu gibt es nur „$_nameSchucu", '
        '„$_nameHand" und „$_nameSituation"',
      );
    } else {
      pr.hinweis('ohne Rolle in der Lernsituation, nicht geprüft: ${s.wo}');
    }
  }
  for (final w in ohneInhalt) {
    pr.hinweis('ohne Rolle in der Lernsituation, nicht geprüft: $w');
  }

  String anzeige(String d) {
    final s = belegt[d];
    if (s != null) return s.wo;
    final (k, loes) = _kennung(d);
    return k != null ? (loes ? 'Lösung zu $k' : k) : d;
  }

  return pr.ausgabe(
    '${seiten.length + ohneInhalt.length + weitere.length} Aktivitäten, '
    '${belegt.length + weitere.length} davon Teil der Lernsituation',
    anzeige,
  );
}

final _aMitInhalt = pyRe(r'<a\b[^>]*>.*?</a>', dotAll: true, caseSensitive: false);
final _zellgrenze = pyRe(r'<(?:/?(?:td|th|tr|p|li|div|h\d)\b[^>]*|br\s*/?)>');
final _loesungAnfang = pyRe(r'Lösung\b');
final _zielGanz = pyReGanz(_ziel);

/// Die Links in Moodle: Ziel im Abschnitt, Text wie der Name des Ziels
/// (Kennung oder ganzer Name), keine Lösung von einer Seite aus, die
/// Lernende sehen -- und jede Nennung eines Blatts ist ein Link.
void _links(
  _Dateien fs,
  _Pruefung pr,
  Map<String, _Seite> belegt,
  Map<int, String> ziele,
  Map<String, String> weitere,
) {
  final kennungen = {
    for (final n in ziele.values)
      if (pyMatch(blattZiel, n) case final m?) verweisSchluessel(m[0]!),
  };
  for (final MapEntry(key: datei, value: s) in belegt.entries) {
    final verweise = <Map>[];
    for (final o in s.ordner) {
      final u = p.join(o, 'uebersicht.json');
      if (!fs.datei(u)) continue;
      final j = fs.json(u);
      final auswertung = j is Map && pyWahr(j['auswertung']) ? j['auswertung'] : const {};
      final felder = auswertung is Map && pyWahr(auswertung['felder']) ? auswertung['felder'] : const [];
      for (final feld in _pyIter(felder)) {
        if (feld is! Map) continue;
        for (final v in _pyIter(pyWahr(feld['verweise']) ? feld['verweise'] : const [])) {
          if (v is Map && v['art'] == 'aktivitaet') verweise.add(v);
        }
      }
    }
    for (final v in verweise) {
      final text = textNorm(_str(v['text']));
      final ziel = v['cmid'];
      if (ziel is! num || !ziele.containsKey(ziel)) {
        if (_zielGanz.hasMatch(text)) {
          pr.befund(
            datei,
            'Link "$text" zeigt auf cm ${pyStr(ziel)} „${pyWahr(v['zielTitel']) ? pyStr(v['zielTitel']) : '?'}" '
            'ausserhalb dieses Abschnitts -- nach einem Duplizieren auf das Gegenstück hier umstellen',
          );
        }
        continue;
      }
      final zname = ziele[ziel]!;
      final kennungZiel = zname.contains(':') ? pyStrip(zname.split(':').first) : null;
      if (text != textNorm(zname) && text != kennungZiel) {
        pr.befund(datei, 'Link "$text" auf „$zname": Der Text passt nicht zum Namen -- Kennung oder ganzer Name');
      }
      if (s.erreichbar && pyMatch(_loesungAnfang, zname) != null) {
        pr.befund(datei, 'für Lernende erreichbar und verlinkt die Lösung „$zname"');
      }
    }
    // Jede Nennung eines Blatts ist ein Link -- außer auf der SchuCu-Seite,
    // die für sich steht, und auf das eigene Blatt.
    if (datei == _schucu) continue;
    final eigenM = pyMatch(blattZiel, s.name);
    final eigen = eigenM != null ? verweisSchluessel(eigenM[0]!) : null;
    // Zellen und Absätze bleiben getrennt: „Arbeitsblatt" in der Spalte Art
    // und „1–4" daneben sind keine Nennung.
    var ohneLinks = s.h.replaceAll(_aMitInhalt, ' ');
    ohneLinks = _htmlText(ohneLinks.replaceAll(_zellgrenze, ' ¦ '));
    for (final m in blattZiel.allMatches(ohneLinks)) {
      final k = verweisSchluessel(m[0]!);
      if (k != eigen && kennungen.contains(k)) {
        pr.befund(datei, 'nennt "${textNorm(m[0]!)}" ohne Link');
      }
    }
    // Ebenso der Name einer weiteren Aktivität in Anführungszeichen.
    for (final m in _zitiert.allMatches(ohneLinks)) {
      if (weitere.containsKey(textNorm(m[1]!))) {
        pr.befund(datei, 'nennt „${textNorm(m[1]!)}" ohne Link');
      }
    }
  }
}

/// Prüft den Entwurf im Ordner [ordner] (absolut, im Arbeitsordner
/// [arbeitsordner]); [anzeige] ist, wie der Kopf ihn nennt. [vorlagen] sind
/// die CD-Vorlagen der SchuCu-Tabelle, Schulform -> HTML
/// ([schucuVorlagenDateien]).
LernsituationErgebnis entwurfPruefen(
  String ordner, {
  required String arbeitsordner,
  required Map<String, String> vorlagen,
  String? anzeige,
}) {
  final fs = _Dateien(arbeitsordner);
  final aus = StringBuffer();
  final leser = _EntwurfLeser(fs, ordner).._anzeigeOrdner = anzeige ?? ordner;
  final gelesen = leser.lesen();
  if (gelesen is String) {
    aus.writeln(gelesen);
    return LernsituationErgebnis(2, aus.toString());
  }
  final e = gelesen as _Entwurf;
  final code = _pruefe(
    fs,
    aus,
    vorlagen,
    'Entwurf: Abschnitt „${e.titel}" (${anzeige ?? ordner})',
    e.seiten,
    e.ohneInhalt,
    vorab: e.vorab,
    verboten: e.verboten,
    weitere: e.weitere,
  );
  return LernsituationErgebnis(code, aus.toString());
}

/// Prüft den Abschnitt [abschnittId], wie der Skill moodle ihn in den
/// Arbeitsordner [arbeitsordner] gelesen hat (kurs_uebersicht,
/// aktivitaet_lesen, buch_lesen).
LernsituationErgebnis moodlePruefen(
  String arbeitsordner,
  int abschnittId, {
  required Map<String, String> vorlagen,
}) {
  final fs = _Dateien(arbeitsordner);
  final aus = StringBuffer();
  final gelesen = _liesMoodle(fs, arbeitsordner, abschnittId);
  if (gelesen == null) {
    aus.writeln(
      'Abschnitt $abschnittId steht in keiner kurs-*.json im Arbeitsordner $arbeitsordner -- zuerst '
      'kurs_uebersicht(kurs).',
    );
    return LernsituationErgebnis(2, aus.toString());
  }
  if (gelesen.fehlen.isNotEmpty) {
    aus.writeln('Erst lesen, dann prüfen -- es fehlt: ${gelesen.fehlen.join('; ')}');
    return LernsituationErgebnis(2, aus.toString());
  }
  final code = _pruefe(
    fs,
    aus,
    vorlagen,
    'Stand in Moodle: Abschnitt „${gelesen.titel}" (id $abschnittId, Kurs ${gelesen.kurs})',
    gelesen.seiten,
    gelesen.ohneInhalt,
    ziele: gelesen.ziele,
    weitere: gelesen.weitere,
  );
  return LernsituationErgebnis(code, aus.toString());
}
