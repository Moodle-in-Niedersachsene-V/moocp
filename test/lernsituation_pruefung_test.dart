// Prüft die Prüfung einer Lernsituation (lib/moodle/lernsituation_pruefung.dart).
//
// Das Beispiel in skills/lernsituation/references/beispiel/ muss ohne Befund
// durchgehen. Dann wird es kopiert und gezielt beschädigt -- und jede
// Beschädigung muss als Befund erscheinen. Eine Prüfung, die nur das Gute
// durchwinkt, ist nicht geprüft. Dasselbe am Stand in Moodle: das Beispiel so
// abgelegt, wie die App einen Abschnitt nach dem Lesen hinterlässt. Am Ende
// das Werkzeug lernsituation_pruefen über MCP.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/moodle/lernsituation_html.dart';
import 'package:moocp/moodle/lernsituation_pruefung.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'mcp_client.dart';

const _beispiel = 'skills/lernsituation/references/beispiel';
const _manifest = 'lernsituation.json';
const _hand = 'lehrerhandreichung/page.html';
const _schucu = 'schucu/page.html';
const _ab1 = 'ab-01-auftrag/page.html';
const _ab1l = 'ab-01-auftrag-loesung/page.html';
const _hilfe1 = 'ab-01-auftrag-hilfe/page.html';
const _ab2 = 'ab-02-umsetzung/page.html';
const _ab2l = 'ab-02-umsetzung-loesung/page.html';
const _vert2 = 'ab-02-umsetzung-vertiefung/page.html';
const _ib1 = 'ib-01-vlan-grundlagen/page.html';
const _svg = 'Z-01-netz-vorher.svg';
const _ki = '\n<p>Inhalte können teilweise mit KI generiert sein.</p>';

/// Die Vorlagen, wie main.dart sie als Assets lädt -- hier aus dem Skill.
final _vorlagen = {
  for (final MapEntry(key: art, value: datei) in schucuVorlagenDateien.entries)
    art: File(p.join(schucuVorlagenOrdner, datei)).readAsStringSync(),
};

// ---- Werkzeuge an der Kopie ------------------------------------------------

String _lies(String pfad) => File(pfad).readAsStringSync();

void _schreib(String ordner, String datei, String text) {
  final f = File(p.join(ordner, datei));
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(text);
}

void _kopiere(String von, String nach) {
  Directory(nach).createSync(recursive: true);
  for (final e in Directory(von).listSync()) {
    final ziel = p.join(nach, p.basename(e.path));
    if (e is Directory) {
      _kopiere(e.path, ziel);
    } else if (e is File) {
      e.copySync(ziel);
    }
  }
}

void _ersetze(String ordner, String datei, String alt, String neu) {
  final pfad = p.join(ordner, datei);
  final t = _lies(pfad);
  expect(t.contains(alt), isTrue, reason: 'Anker fehlt in $datei: $alt');
  File(pfad).writeAsStringSync(t.replaceFirst(alt, neu));
}

void _manifestAendern(String ordner, void Function(Map<String, dynamic>) f) {
  final pfad = p.join(ordner, _manifest);
  final m = jsonDecode(_lies(pfad)) as Map<String, dynamic>;
  f(m);
  File(pfad).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(m));
}

List<dynamic> _aktivitaeten(Map<String, dynamic> m) => m['aktivitaeten'] as List;

Map _eintrag(Map<String, dynamic> m, String ordner) =>
    _aktivitaeten(m).firstWhere((e) => (e as Map)['ordner'] == ordner) as Map;

void _setze(String entwurf, String welcher, Map<String, Object?> werte) =>
    _manifestAendern(entwurf, (m) => _eintrag(m, welcher).addAll(werte));

/// Nimmt eine Aktivität aus dem Entwurf: Eintrag und Ordner.
void _weg(String ordner, String welcher) {
  _manifestAendern(ordner, (m) => _aktivitaeten(m).remove(_eintrag(m, welcher)));
  Directory(p.join(ordner, welcher)).deleteSync(recursive: true);
}

/// Nimmt einen Eintrag in lernsituation.json auf, hinter [nach] oder ans Ende.
void _dazu(String ordner, Map<String, Object?> neu, {String? nach}) => _manifestAendern(ordner, (m) {
  final a = _aktivitaeten(m);
  a.insert(nach != null ? a.indexOf(_eintrag(m, nach)) + 1 : a.length, neu);
});

/// Ersetzt die SchuCu-Tabelle samt Absätzen darunter durch [neu] -- auf
/// der SchuCu-Seite steht nichts anderes.
void _tauscheTabelle(String ordner, String neu) => _schreib(ordner, _schucu, '$neu\n');

/// Der alte Aufbau: Tabelle oben in der Handreichung, keine Seite SchuCu.
void _zurueckInHandreichung(String ordner) {
  final t = _lies(p.join(ordner, _schucu));
  _weg(ordner, 'schucu');
  _ersetze(ordner, _hand, '<h3>Thematische Einführung', '$t<h3>Thematische Einführung');
}

/// `re.split` mit einer Gruppe: die Treffer bleiben als eigene Teile stehen.
List<String> _teilen(RegExp re, String s) {
  final raus = <String>[];
  var i = 0;
  for (final m in re.allMatches(s)) {
    raus
      ..add(s.substring(i, m.start))
      ..add(m[0]!);
    i = m.end;
  }
  raus.add(s.substring(i));
  return raus;
}

/// Die Handreichung als Buch, so wie der Entwurf es schreibt: je <h3> ein
/// Kapitel, unter „Die Schritte im Einzelnen" je Schritt ein Unterkapitel,
/// weitere <h4> werden <h3> im Kapitel.
void _alsBuch(String ordner) {
  final d = p.join(ordner, 'lehrerhandreichung');
  final h = _lies(p.join(d, 'page.html'));
  File(p.join(d, 'page.html')).deleteSync();
  final kapitel = <(String, bool, StringBuffer)>[];
  String? oben;
  final kopf = RegExp(r'^<h([34])>(.*?)</h\1>$');
  for (final teil in _teilen(RegExp(r'<h[34]>.*?</h[34]>'), h)) {
    final m = kopf.firstMatch(teil);
    if (m != null && m[1] == '3') {
      oben = m[2];
      kapitel.add((oben!, false, StringBuffer()));
    } else if (m != null && oben == 'Die Schritte im Einzelnen') {
      kapitel.add((m[2]!, true, StringBuffer()));
    } else if (m != null) {
      kapitel.last.$3.write('<h3>${m[2]}</h3>');
    } else if (teil.trim().isNotEmpty) {
      kapitel.last.$3.write(teil);
    }
  }
  final inhalte = [
    for (final (_, _, b) in kapitel)
      b.toString().trim().isEmpty
          ? '<p>Je Schritt ein Unterkapitel: was genau passiert und worauf zu achten ist.</p>\n'
          : b.toString(),
  ];
  _schreib(
    ordner,
    'lehrerhandreichung/kapitel.json',
    const JsonEncoder.withIndent('  ').convert([
      for (var i = 0; i < kapitel.length; i++)
        {'id': i + 1, 'titel': kapitel[i].$1, 'unterkapitel': kapitel[i].$2},
    ]),
  );
  for (var i = 0; i < kapitel.length; i++) {
    _schreib(ordner, 'lehrerhandreichung/kapitel-${i + 1}/content_editor.html', '${inhalte[i].trim()}\n');
  }
  _setze(ordner, 'lehrerhandreichung', {
    'typ': 'book',
    'einstellungen': {'numbering': 'Keine'},
  });
}

/// Ein Blatt als Aufgabe: der Inhalt in introeditor.html.
void _alsAufgabe(String ordner, String welcher) {
  final d = p.join(ordner, welcher);
  File(p.join(d, 'page.html')).renameSync(p.join(d, 'introeditor.html'));
  _setze(ordner, welcher, {'typ': 'assign'});
}

// Die BG-Vorlage, so ausgefüllt, wie der Skill es tun soll -- Werte für
// Informatik, weil die Vorlage von dort kam.
const _bgWerte = [
  (
    '<td class="lssubhead">Titel:</td>\n      <td class="lsdata">&nbsp;</td>',
    '<td class="lssubhead">Titel:</td>\n      <td class="lsdata">Firmennetz in VLANs trennen</td>',
  ),
  (
    '<td class="lssubhead">gepl. Zeitrichtwert:</td>\n      <td class="lsdata">&nbsp;</td>',
    '<td class="lssubhead">gepl. Zeitrichtwert:</td>\n      <td class="lsdata">4 UStd (180 min)</td>',
  ),
  (
    '<td class="lssubhead">Autor*(en):</td>\n      <td class="lsdata">&nbsp;</td>',
    '<td class="lssubhead">Autor*(en):</td>\n      <td class="lsdata">vom Nutzer zu ergänzen</td>',
  ),
  (
    'href="&lt;Adresse des Lehrplans&gt;">&lt;Lehrplan des Fachs&gt;</a>',
    'href="https://bildungsportal-niedersachsen.de/index.php?eID=dumpFile&amp;t=f&amp;f=12491'
        '&amp;token=e4b30f8cbc2433cb9cd08302a10e9a966f5a3719">Lehrplan\n            berufliche Informatik</a>',
  ),
  (
    '<td class="lsdata">&lt;Vorgaben aus RRL, Modulen, Lernfelder, ...&gt;</td>',
    '<td class="lsdata">vom Nutzer zu ergänzen</td>',
  ),
  (
    '<td class="lsdata">&lt;verkürzt - für KuK als\n        Zusammenfassung&gt;<br>&lt;Kern der '
        'Lernsituation, bildet den Rahmen des\n        Unterrichts&gt;</td>',
    '<td class="lsdata">Die Muster GmbH trennt ihr Netz in Abteilungsnetze.</td>',
  ),
  ('<td class="lsdata" colspan="2">...</td>', '<td class="lsdata" colspan="2">VLAN-Konzept mit Zeichnung</td>'),
  ('<li>...</li>', '<li>im Team entscheiden</li>'),
  ('<li>...</li>', '<li>VLANs konfigurieren</li>'),
  ('&lt;nur die abgedeckten Buchstaben&gt;', 'A B'),
  (
    '&lt;alle Kompetenzbereiche des Kerncurriculums mit Buchstaben&gt;',
    'A: Kommunizieren, argumentieren und kooperieren; B:\n  Algorithmisieren und implementieren'
        '<br>\n  C: Strukturieren, modellieren und\n  darstellen, D: Analysieren, bewerten und testen',
  ),
];

void Function(String) _bg([List<(String, String)> aenderungen = const []]) => (ordner) {
  var t = _vorlagen['Berufliches Gymnasium']!;
  for (final (alt, neu) in [..._bgWerte, ...aenderungen]) {
    expect(t.contains(alt), isTrue, reason: 'BG-Anker fehlt: $alt');
    t = t.replaceFirst(alt, neu);
  }
  _tauscheTabelle(ordner, t.replaceFirst(RegExp(r'\n+$'), ''));
};

const _lies4 = '<strong>Lies:</strong> Infoblatt 1, Abschnitt 4.';

/// Kein Arbeitsblatt nennt Infoblatt 1 mehr, nur noch die Handreichung.
void _ohneInfoblatt(String ordner) {
  for (final d in [_ab1, _hilfe1, _ab2]) {
    final pfad = p.join(ordner, d);
    final t = _lies(pfad);
    expect(t.contains('Infoblatt 1'), isTrue, reason: 'Anker fehlt in $d');
    File(pfad).writeAsStringSync(t.replaceAll('Infoblatt 1', 'das Tabellenbuch'));
  }
}

const _bildAlt =
    'alt="Netz der Muster GmbH vor der Umstellung: zwei Switches, alle Geräte in einem Segment" class="img-fluid"';

const _pinnwand = 'Unsere VLAN-Aufteilung';
const _reflexion = '<td>Plenum</td><td>—</td>';

typedef _Weitere = (String, String, String, Map<String, String>, Map<String, Object?>);

/// Weitere Aktivitäten in den Entwurf: je (ordner, typ, name, {datei: inhalt},
/// extra) ein Ordner mit seinen Dateien und ein Eintrag hinter der Pinnwand;
/// im Ablaufplan stehen sie bei Schritt 7 als Material.
void _weitere(String ordner, List<_Weitere> eintraege) {
  var nach = 'pinnwand-aufteilung';
  for (final (o, typ, name, dateien, extra) in eintraege) {
    for (final MapEntry(key: d, value: inhalt) in dateien.entries) {
      _schreib(ordner, '$o/$d', inhalt);
    }
    // Ein Link ohne Beschreibung braucht keinen Ordner.
    final e = <String, Object?>{if (dateien.isNotEmpty) 'ordner': o, 'typ': typ, 'name': name, ...extra};
    _dazu(ordner, e, nach: nach);
    if (dateien.isNotEmpty) nach = o;
  }
  _ersetze(ordner, _hand, _reflexion, '<td>Plenum</td><td>${[for (final e in eintraege) '„${e.$3}"'].join(', ')}</td>');
}

const _intro = {'introeditor.html': '<p>Für die Reflexion.</p>\n'};
const _karteOrte = [
  {'id': 'p1', 'x': 120, 'y': 280, 'titel': 'Grundlagen'},
  {'id': 'p2', 'x': 500, 'y': 180, 'titel': 'Aufteilung'},
  {'id': 'p3', 'x': 880, 'y': 280, 'titel': 'Umsetzung'},
];
const _karteWege = [
  {'von': 'p1', 'nach': 'p2'},
  {'von': 'p2', 'nach': 'p3'},
];
const _karteBild =
    '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="560" viewBox="0 0 1000 560">'
    '<rect width="1000" height="560" fill="#eef2f7"/></svg>';
const _karteZiele = {
  'p1': 'Infoblatt 1: VLAN-Grundlagen',
  'p2': 'Unsere VLAN-Aufteilung',
  'p3': 'Arbeitsblatt 2: Umsetzung und Prüfung',
};

String _karteJson({List<Map<String, Object?>>? orte, List<Map<String, Object?>>? wege}) =>
    jsonEncode({'orte': orte ?? _karteOrte, 'wege': wege ?? _karteWege});

final List<_Weitere> _alleWeiteren = [
  (
    'kanban-plan',
    'kanban',
    'Unser Arbeitsplan',
    {
      ..._intro,
      'kanban.json':
          '{"spalten": ["Zu erledigen", "Erledigt"], "karten": [{"spalte": "Zu erledigen", "titel": "Ports"}]}',
    },
    {},
  ),
  (
    'liste-pruefen',
    'checklist',
    'Prüfliste zum VLAN-Konzept',
    {
      'eintraege.json':
          '[{"text": "Planung", "zustand": "ueberschrift"}, {"text": "Jede Abteilung hat ein VLAN", "tiefe": 1}, '
          '{"text": "Gäste getrennt", "tiefe": 1, "zustand": "optional"}]',
    },
    {},
  ),
  (
    'wiki-begriffe',
    'wiki',
    'Begriffe der Klasse',
    {
      'seiten.json': '[{"titel": "Begriffe", "datei": "begriffe.html"}, {"titel": "Tagging", "datei": "tagging.html"}]',
      'begriffe.html': '<p>Siehe [[Tagging]].</p>\n',
      'tagging.html': '<p>Ein Tag kennzeichnet den Rahmen.</p>\n',
    },
    {
      'einstellungen': {'firstpagetitle': 'Begriffe'},
    },
  ),
  (
    'test-uebung',
    'quiz',
    'Übung zu VLANs',
    {
      'fragen.xml':
          '<?xml version="1.0" encoding="UTF-8"?>\n<quiz><question type="truefalse"><name><text>Tag</text></name>'
          '<idnumber>vlan-01</idnumber></question></quiz>\n',
    },
    {
      'fragen': {'sammlung': 'VLAN-Segmentierung', 'kategorie': 'Übung'},
    },
  ),
  ('material', 'folder', 'Vorlagen für die Konfiguration', {'bereiche/files/plan.ods': 'x'}, {}),
  ('vorlage', 'resource', 'Netzplan zum Weiterarbeiten', {'bereiche/files/netz.pkt': 'x'}, {}),
  (
    'hersteller',
    'url',
    'Herstellerdokumentation',
    {},
    {
      'einstellungen': {'externalurl': 'https://example.org/vlan'},
    },
  ),
  (
    'lernweg',
    'learningmap',
    'Lernweg zur VLAN-Segmentierung',
    {'lernlandkarte.json': _karteJson(), 'bereiche/backgroundfile/hintergrund.svg': _karteBild},
    {'ziele': _karteZiele},
  ),
];

/// Eine der weiteren Aktivitäten aus [_alleWeiteren], verändert.
void Function(String) _eineWeitere(
  int nr, {
  Map<String, String> dateien = const {},
  Map<String, Object?> extra = const {},
}) {
  final (o, typ, name, d, e) = _alleWeiteren[nr];
  return (ordner) => _weitere(ordner, [
    (o, typ, name, {...d, ...dateien}, {...e, ...extra}),
  ]);
}

const _elementGut =
    '<!DOCTYPE html><html lang="de"><head><title>Z</title></head>'
    '<body><button type="button" class="btn btn-primary">Z</button></body></html>';

/// Ein interaktives Element auf Arbeitsblatt 1 (references/elemente.md).
void Function(String) _mitElement(String rahmen, [String datei = _elementGut]) => (o) {
  _ersetze(o, _ab1, '<p>Erkläre in je einem Satz', '$rahmen\n<p>Erkläre in je einem Satz');
  _schreib(o, 'ab-01-auftrag/dateien/zz-element.html', datei);
};

void Function(String) _r(String datei, String alt, String neu) => (o) => _ersetze(o, datei, alt, neu);

typedef _Fall = (String, void Function(String), String);

final List<_Fall> _faelle = [
  (
    'Lösung gelöscht',
    (o) => _weg(o, 'ab-02-umsetzung-vertiefung-loesung'),
    r'Lösung fehlt: „Lösung zur Vertiefung zu Arbeitsblatt 2: …"',
  ),
  ('Summenzeile falsch', _r(_hand, '<strong>180</strong>', '<strong>170</strong>'), r'Summenzeile sagt 170'),
  (
    'Zeitrichtwert überzogen',
    _r(_hand, '<td>Durchführen</td><td>50</td>', '<td>Durchführen</td><td>100</td>'),
    r'geplant bei Zeitrichtwert',
  ),
  (
    'Platzhalter vergessen',
    _r(
      _hand,
      'Anrede der Lernenden auf den Blättern: <strong>du</strong>.',
      'Anrede der Lernenden auf den Blättern: &lt;du / Sie&gt;.',
    ),
    r'Platzhalter steht noch da: <du / Sie>',
  ),
  (
    'Platzhalter als Element',
    _r(_ab1, '<p>Erkläre in je einem Satz', '<p><Aufgabenstellung mit Operator> Erkläre in je einem Satz'),
    r'Platzhalter steht noch da: <Aufgabenstellung mit Operator>',
  ),
  (
    'Aufgabe ohne AFB',
    _r(_ab1, '<h3>Aufgabe 2 (10 min · Einzel · AFB II)</h3>', '<h3>Aufgabe 2 (10 min · Einzel)</h3>'),
    r'Aufgabe 2: Klammer',
  ),
  (
    'Kopfzeit stimmt nicht',
    _r(_ab1, '<strong>Zeit gesamt:</strong> 65 min', '<strong>Zeit gesamt:</strong> 60 min'),
    r'Kopf sagt 60',
  ),
  (
    'Blatt nicht in der Handreichung',
    (o) {
      _kopiere(p.join(o, 'ib-01-vlan-grundlagen'), p.join(o, 'ib-02-verwaist'));
      _dazu(o, {'ordner': 'ib-02-verwaist', 'typ': 'page', 'name': 'Infoblatt 2: Verwaist'});
    },
    r'„Infoblatt 2: Verwaist" \(ib-02-verwaist\)\s+steht weder im Ablaufplan',
  ),
  (
    'Zeichnung fehlt ganz',
    (o) {
      File(p.join(o, 'ab-01-auftrag', 'dateien', _svg)).deleteSync();
      File(p.join(o, 'ib-01-vlan-grundlagen', 'dateien', _svg)).deleteSync();
    },
    r'Z-01-netz-vorher.svg liegt nicht in ab-01-auftrag/dateien/',
  ),
  (
    'Zeichnung nur auf dem anderen Blatt',
    (o) => Directory(p.join(o, 'ib-01-vlan-grundlagen', 'dateien')).deleteSync(recursive: true),
    r'ib-01-vlan-grundlagen\)\s+Z-01-netz-vorher.svg liegt nicht in ib-01-vlan-grundlagen/dateien/',
  ),
  (
    'Zeichnung nicht eingebunden',
    (o) => File(
      p.join(o, 'ab-01-auftrag', 'dateien', _svg),
    ).copySync(p.join(o, 'ab-01-auftrag', 'dateien', 'Z-02-extra.svg')),
    r'ab-01-auftrag/dateien/Z-02-extra.svg wird nicht eingebunden',
  ),
  // ---- Namen des Entwurfs gibt es in Moodle nicht ----
  (
    'Ordnername im Text',
    _r(_hand, '<strong>Material:</strong> Arbeitsblatt 1, ab Beginn.', '<strong>Material:</strong> ab-01-auftrag, ab Beginn.'),
    r'Name aus dem Entwurf im Text: ab-01-auftrag --',
  ),
  (
    'Zeichnung im Text',
    _r(_ib1, '<p>Sobald Geräte', '<p>Siehe Z-01-netz-vorher.svg. Sobald Geräte'),
    r'Name aus dem Entwurf im Text: Z-01-netz-vorher.svg',
  ),
  (
    'Materialübersicht mit Dateien',
    _r(_hand, '<th>Blatt</th><th>Art</th>', '<th>Datei</th><th>Art</th>'),
    r'Materialübersicht nennt Dateien',
  ),
  (
    'Name in Materialübersicht alt',
    _r(_hand, '<td>Infoblatt 1: VLAN-Grundlagen</td>', '<td>Infoblatt 1: VLAN-Basics</td>'),
    r'"Infoblatt 1: VLAN-Basics" ist nicht der Name eines Blatts',
  ),
  (
    'Kennung ohne Blatt',
    _r(_hand, '<td>Einzel</td><td>Infoblatt 1</td>', '<td>Einzel</td><td>Infoblatt 1, Infoblatt 3</td>'),
    r'"Infoblatt 3": dieses Blatt gibt es nicht',
  ),
  // ---- lernsituation.json und die Ordner ----
  ('Fremde Datei im Entwurf', (o) => _schreib(o, 'notizen.txt', 'x'), r'notizen.txt\s+hat im Entwurf keinen Platz'),
  (
    'Ordner nicht genannt',
    (o) => _kopiere(p.join(o, 'ab-02-umsetzung'), p.join(o, 'ab-03-rest')),
    r'ab-03-rest\s+steht nicht in lernsituation.json',
  ),
  (
    'Name ohne Kennung',
    (o) => _setze(o, 'ab-02-umsetzung', {'name': 'AB-02: Umsetzung und Prüfung'}),
    r'„AB-02: Umsetzung und Prüfung" \(ab-02-umsetzung\)\s+Name ohne Kennung',
  ),
  (
    'Ordner fehlt',
    (o) => _setze(o, 'ab-01-auftrag-hilfe', {'ordner': 'ab-01-hilfe'}),
    r'\(ab-01-hilfe\)\s+Ordner fehlt(.|\n)*ab-01-auftrag-hilfe\s+steht nicht in',
  ),
  (
    'Inhalt im falschen Feld',
    (o) => File(p.join(o, _hilfe1)).renameSync(p.join(o, 'ab-01-auftrag-hilfe', 'introeditor.html')),
    r'page.html fehlt in ab-01-auftrag-hilfe',
  ),
  (
    'Beschreibung des Abschnitts fehlt',
    (o) => Directory(p.join(o, 'abschnitt')).deleteSync(recursive: true),
    r'Beschreibung des Abschnitts fehlt',
  ),
  (
    'Kennung doppelt',
    (o) {
      _kopiere(p.join(o, 'ab-02-umsetzung'), p.join(o, 'ab-02-zweites'));
      _dazu(o, {'ordner': 'ab-02-zweites', 'typ': 'page', 'name': 'Arbeitsblatt 2: Zweites'});
    },
    r'dieselbe Kennung "Arbeitsblatt 2"',
  ),
  (
    'Name doppelt',
    (o) => _dazu(o, {'ordner': 'ab-02-umsetzung', 'typ': 'page', 'name': 'Arbeitsblatt 2: Umsetzung und Prüfung'}),
    r'derselbe Name steht zweimal',
  ),
  // ---- HTML-Regeln ----
  (
    'style-Attribut',
    _r(_ab1, '<h3>Die Situation</h3>', '<h3 style="color: red">Die Situation</h3>'),
    r'style-Attribut an <h3>',
  ),
  (
    'Rahmenlinie mit Farbe',
    _r(_ab1l, '<tr><td>Trunk</td>', '<tr><td style="border-top: 2px solid red">Trunk</td>'),
    r'mit mehr als Rahmenlinien \(border-top: 2px solid red\)',
  ),
  (
    'Überschrift h2',
    _r(_ib1, '<h3>4. Was ein VLAN nicht ist</h3>', '<h2>4. Was ein VLAN nicht ist</h2>'),
    r'<h2>: Überschriften beginnen bei <h3>',
  ),
  ('Bild ohne alt und img-fluid', _r(_ab1, _bildAlt, ''), r'Bild ohne Alternativtext(.|\n)*Bild ohne class="img-fluid"'),
  (
    'Bild vom fremden Server',
    _r(_ib1, 'src="@@PLUGINFILE@@/Z-01-netz-vorher.svg"', 'src="https://example.org/netz.svg"'),
    r'Bild „https://example.org/netz.svg": src="@@PLUGINFILE@@/<name>"',
  ),
  ('Tabelle ohne Klasse', _r(_ab2, '<table class="table table-bordered">', '<table>'), r'Tabelle ohne class="table"'),
  (
    '<b> statt <strong>',
    _r(_ab2l, '<strong>auf beiden Switches</strong>', '<b>auf beiden Switches</b>'),
    r'<b> -- zur Hervorhebung <strong>',
  ),
  (
    '<u> und Word-Rest',
    _r(_ab2l, '<strong>auf beiden Switches</strong>', '<u class="MsoNormal">auf beiden Switches</u>'),
    r'Word-Rest class="Mso…"(.|\n)*<u> -- Unterstrichenes',
  ),
  (
    'Leerer Absatz',
    _r(_ib1, '<h3>Zum Nachschlagen</h3>', '<p>&nbsp;</p>\n<h3>Zum Nachschlagen</h3>'),
    r'leerer Absatz',
  ),
  ('&nbsp;-Kette', _r(_vert2, '<p>Nennt drei', '<p>&nbsp;&nbsp;&nbsp;Nennt drei'), r'&nbsp;-Kette zum Einrücken'),
  ('Ebene übersprungen', _r(_hand, '<h4>Quellen</h4>', '<h5>Quellen</h5>'), r'<h5> folgt auf <h3>: Ebene übersprungen'),
  (
    'http statt https',
    _r(_ib1, 'href="https://standards', 'href="http://standards'),
    r'unverschlüsselte Adresse http://standards',
  ),
  (
    'Drei Kastenarten',
    _r(
      _ib1,
      '<h3>Zum Nachschlagen</h3>',
      '<div class="alert alert-info"><p>Merke: a</p></div>\n'
          '<div class="alert alert-warning"><p>Achtung: b</p></div>\n'
          '<div class="alert alert-danger"><p>Gefahr: c</p></div>\n'
          '<h3>Zum Nachschlagen</h3>',
    ),
    r'mehr als zwei Kastenarten: alert-danger, alert-info, alert-warning',
  ),
  ('Markdown im HTML', _r(_vert2, '<p>Nennt drei', '<p>**Nennt** drei'), r'Markdown im HTML: „\*\*Nennt\*\*"'),
  (
    'Markdown-Codeblock',
    _r(_ab2, '<p>Beurteilt zum Schluss', '<p>```\nshow vlan\n```</p>\n<p>Beurteilt zum Schluss'),
    r'Markdown im HTML: „```"',
  ),
  (
    'Formel mit rohem <',
    _r(_ab2, '<p>Beurteilt zum Schluss', '<p>Es gilt \\(x<y\\) für alle.</p>\n<p>Beurteilt zum Schluss'),
    r'Formelfehler: Formel ohne Ende',
  ),
  (
    'Formel über zwei Absätze',
    _r(_ab2, '<p>Beurteilt zum Schluss', '<p>\\( a + b</p>\n<p>c \\)</p>\n<p>Beurteilt zum Schluss'),
    r'Formelfehler: Formelende „\\\)" ohne Anfang',
  ),
  (
    'LaTeX zwischen \$',
    _r(_ab2, '<p>Beurteilt zum Schluss', '<p>Es gilt \$\\frac{a}{b}\$.</p>\n<p>Beurteilt zum Schluss'),
    r'Formelfehler: LaTeX zwischen einfachen \$',
  ),
  (
    'Checkliste ohne Begründung',
    _r(
      _hand,
      '<td>Gibt es eine Reflexionsphase?</td><td>Ja</td><td>Schritt 7, Frage nach der schwersten Entscheidung</td>',
      '<td>Gibt es eine Reflexionsphase?</td><td>Ja</td><td></td>',
    ),
    r'ohne Begründung',
  ),
  (
    'Link "hier"',
    _r(_ib1, '>https://standards.ieee.org/ieee/802.1Q/10323/</a>', '>hier</a>'),
    r'Link ohne ausgeschriebene Adresse',
  ),
  (
    'Lösung mit weniger Aufgaben',
    _r(_ab2l, '<h3>Aufgabe 4</h3>', '<h3>Aufgabe vier</h3>'),
    r'Lösung hat 3 Aufgabenabschnitte',
  ),
  (
    'Aufgabe auf dem IB',
    _r(
      _ib1,
      '<h3>Zum Nachschlagen</h3>',
      '<h3>Aufgabe 1 (5 min · Einzel · AFB I)</h3>\n<p>x</p>\n<h3>Zum Nachschlagen</h3>',
    ),
    r'Informationsblatt enthält Aufgaben',
  ),
  (
    'Handreichung ohne Lernumgebung',
    _r(_hand, '<h3>Lernumgebung</h3>', '<h3>Raum</h3>'),
    r'Abschnitt „Lernumgebung" fehlt',
  ),
  (
    'Handreichung ohne Bewertung',
    _r(_hand, '<h3>Leistungsfeststellung und -bewertung</h3>', '<h3>Bewertung</h3>'),
    r'Abschnitt „Leistungsfeststellung und -bewertung" fehlt',
  ),
  (
    'Schritt ohne Überschrift',
    _r(_hand, '<h4>Schritt 8: Puffer</h4>', '<p>Schritt 8: Puffer</p>'),
    r'Ablaufplan hat 8 Zeilen, aber nur 7 Schritte',
  ),
  (
    'Buch: Kapitel leer',
    (o) {
      _alsBuch(o);
      _schreib(o, 'lehrerhandreichung/kapitel-3/content_editor.html', '');
    },
    r'Kapitel „Lernumgebung"\s+Kapitel ohne Inhalt',
  ),
  // ---- SchuCu-Seite ----
  (
    'SchuCu: noch in der Handreichung',
    _zurueckInHandreichung,
    r'Seite „SchuCu" fehlt(.|\n)*SchuCu-Tabelle steht in der Handreichung',
  ),
  (
    'SchuCu: mehr auf der Seite',
    _r(_schucu, _ki, '$_ki\n<h3>Thematische Einführung</h3>\n<p>Text</p>'),
    r'mehr als die Tabelle',
  ),
  (
    'SchuCu: anderer Name',
    (o) => _setze(o, 'schucu', {'name': 'Lernsituation: Abteilungsnetze'}),
    r'Die Seite mit der SchuCu-Tabelle muss „SchuCu" heißen',
  ),
  (
    'SchuCu: Tabelle ohne Vorlage',
    (o) => _tauscheTabelle(o, '<table class="table"><tbody><tr><td>Titel</td><td>x</td></tr></tbody></table>'),
    r'SchuCu-Tabelle fehlt',
  ),
  ('SchuCu: KI-Hinweis fehlt', _r(_schucu, _ki, ''), r'nicht die Absätze der Vorlage Berufsschule'),
  (
    'SchuCu: KI-Hinweis geändert',
    _r(_schucu, 'teilweise mit KI generiert', 'mit KI erstellt'),
    r'Absatz unter der Tabelle geändert',
  ),
  // ---- SchuCu-Tabelle nach CD-Vorlage ----
  (
    'SchuCu: Titel leer',
    _r(
      _schucu,
      '<td class="lsdata">Abteilungsnetze für die Muster GmbH — ein Firmennetz in VLANs trennen</td>',
      '<td class="lsdata">&nbsp;</td>',
    ),
    r'SchuCu-Zeile leer: Titel',
  ),
  (
    'SchuCu: Platzhalter stehen gelassen',
    _r(_schucu, '<td class="lsdata">vom Nutzer zu ergänzen</td>', '<td class="lsdata">&lt;Name&gt;</td>'),
    r'Platzhalter der Vorlage: Autor',
  ),
  (
    'SchuCu: Zeile entfernt',
    _r(_schucu, '<td class="lshead" colspan="3">Lernumgebung</td>', '<td class="lshead" colspan="3">Raum</td>'),
    r'weicht von der Vorlage Berufsschule ab, Zeile 15',
  ),
  (
    'SchuCu: Klasse getauscht',
    _r(_schucu, '<td class="lssubhead">Titel:</td>', '<td class="table">Titel:</td>'),
    r'weicht von der Vorlage',
  ),
  (
    'SchuCu: Kopflink geändert',
    _r(_schucu, '201809_g-A_Lernsituationen_BBS.pdf', 'anderes.pdf'),
    r'Link "offizielle Erläuterungen" geändert',
  ),
  (
    'SchuCu: Markdown in der Tabelle',
    _r(_schucu, '<strong>Planen und Entscheiden</strong>', '**Planen und Entscheiden**'),
    r'Markdown in der SchuCu-Tabelle',
  ),
  (
    'SchuCu: Zeitrichtwert fehlt',
    _r(_schucu, '<td class="lsdata">4 UStd (180 min)</td>', '<td class="lsdata">ein Vormittag</td>'),
    r'Zeitrichtwert nicht lesbar',
  ),
  ('BG: Bereich nicht in der Legende', _bg([('>A B</td>', '>A E</td>')]), r'Kompetenzbereich\(e\) E stehen nicht'),
  ('BG: Lehrplan-Link offen', _bg([('href="https://bildungsportal', 'href="&lt;x&gt;')]), r'Link zum Lehrplan'),
  ('BG: Legende fehlt', _bg([('A: Kommunizieren', '&lt;y&gt; A: Kommunizieren')]), r'Legende der Kompetenzbereiche'),
  ('BG: KI-Hinweis fehlt', _bg([(_ki, '')]), r'nicht die Absätze der Vorlage Berufliches Gymnasium'),
  (
    'BG: Vereinbarungen aus der BS-Vorlage',
    _bg([
      (
        '<td class="lshead" colspan="3">Abgedeckte Kompetenzbereiche</td>',
        '<td class="lshead" colspan="3">Vereinbarungen zur Umsetzung der Lernsituation</td>',
      ),
    ]),
    r'weicht von der Vorlage',
  ),
  // ---- Jedes Blatt steht für sich ----
  (
    'Abschnitte beginnen nicht bei 1',
    _r(_ib1, '<h3>1. Was ein VLAN ist</h3>', '<h3>5. Was ein VLAN ist</h3>'),
    r'\(ib-01-vlan-grundlagen\)\s+Abschnitte 5, 2, 3, 4',
  ),
  (
    'Abbildung zählt über Blätter',
    _r(_ib1, '<em>Abb. 1: Zwei Switches', '<em>Abb. 2: Zwei Switches'),
    r'\(ib-01-vlan-grundlagen\)\s+Abbildungen Abb. 2 --',
  ),
  (
    'Abbildung mit Präfix',
    _r(_ab1, '<em>Abb. 1: Das Netz vor', '<em>Abb. L1: Das Netz vor'),
    r'\(ab-01-auftrag\)\s+Abbildungen Abb. L1 --',
  ),
  (
    'Abb. ohne Kennung',
    _r(_hilfe1, 'Kreist sie in Abb. 1 auf Arbeitsblatt 1 ein.', 'Kreist sie in Abb. 1 ein.'),
    r'\(ab-01-auftrag-hilfe\)\s+"Abb. 1" ohne Blattkennung',
  ),
  (
    'Abb. ohne Kennung (Handreichung)',
    _r(_hand, 'Abb. 1 auf Arbeitsblatt 1 —', 'Abb. 1 —'),
    r'„Lehrerhandreichung" \(lehrerhandreichung\)\s+"Abb. 1" ohne Blattkennung',
  ),
  (
    'Verweis auf fehlenden Abschnitt',
    _r(_ab1, _lies4, _lies4.replaceFirst('4.', '5.')),
    r'\(ab-01-auftrag\)\s+"Infoblatt 1, Abschnitt 5": dort gibt es keinen Abschnitt 5',
  ),
  (
    'Verweis auf einen riesigen Bereich',
    _r(_ab1, _lies4, '<strong>Lies:</strong> Infoblatt 1, Abschnitte 1 bis 999999999999999999999.'),
    r'\(ab-01-auftrag\)\s+"Infoblatt 1, Abschnitte 1 bis 999999999999999999999": dort gibt es keinen Abschnitt -1',
  ),
  (
    'Aufgabe mit riesiger Nummer',
    _r(_ab2, '<h3>Aufgabe 1 (', '<h3>Aufgabe 99999999999999999999 ('),
    r'\(ab-02-umsetzung\)\s+Aufgaben -1, ',
  ),
  (
    'Verweis auf fehlende Abbildung',
    _r(_ab2, 'aus Abb. 1 auf Arbeitsblatt 1.', 'aus Abb. 2 auf Arbeitsblatt 1.'),
    r'dort gibt es keine Abb. 2',
  ),
  (
    'Verweis auf fehlende Aufgabe',
    _r(_hand, 'Aufgabe 4 auf Arbeitsblatt 2 (Prüfliste)', 'Aufgabe 5 auf Arbeitsblatt 2 (Prüfliste)'),
    r'\(lehrerhandreichung\)\s+"Aufgabe 5 auf Arbeitsblatt 2": dort gibt es keine Aufgabe 5',
  ),
  (
    'Verweis auf fehlendes Blatt',
    _r(_ab1, _lies4, '<strong>Lies:</strong> Infoblatt 2, Abschnitt 1.'),
    r'"Infoblatt 2, Abschnitt 1": dieses Blatt gibt es nicht',
  ),
  (
    'Aufgaben beginnen nicht bei 1',
    _r(_vert2, '<h3>Aufgabe 1 (15 min', '<h3>Aufgabe 2 (15 min'),
    r'\(ab-02-umsetzung-vertiefung\)\s+Aufgaben 2 --',
  ),
  (
    'Lösung mit anderen Nummern',
    _r(_ab2l, '<h3>Aufgabe 4</h3>', '<h3>Aufgabe 5</h3>'),
    r'Lösung hat die Aufgaben 1, 2, 3, 5, das Blatt 1, 2, 3, 4',
  ),
  (
    'Infoblatt von keinem Arbeitsblatt genannt',
    _ohneInfoblatt,
    r'\(ib-01-vlan-grundlagen\)\s+kein Arbeitsblatt nennt Infoblatt 1',
  ),
  (
    'Zeichnung in der Materialübersicht',
    _r(
      _hand,
      '<tr><td>Infoblatt 1: VLAN-Grundlagen</td>',
      '<tr><td>Abb. 1 auf Infoblatt 1</td><td>Zeichnung</td><td>2</td><td>Netz</td></tr>\n'
          '<tr><td>Infoblatt 1: VLAN-Grundlagen</td>',
    ),
    r'Materialübersicht: "Abb. 1 auf Infoblatt 1" -- Zeichnungen gehören zu ihrem Blatt',
  ),
  // ---- Weitere Aktivitäten ----
  (
    'Pinnwand nicht im Ablaufplan',
    (o) {
      _ersetze(o, _hand, 'Arbeitsblatt 1, „Unsere VLAN-Aufteilung"</td>', 'Arbeitsblatt 1</td>');
      _ersetze(o, _hand, '<tr><td>„Unsere VLAN-Aufteilung"</td>', '<tr><td>Unsere VLAN-Aufteilung</td>');
    },
    r'„Unsere VLAN-Aufteilung" \(pinnwand-aufteilung\)\s+steht weder im Ablaufplan',
  ),
  (
    'Name in Anführungszeichen ohne Aktivität',
    _r(_hand, _reflexion, '<td>Plenum</td><td>„Unsere Pinnwand"</td>'),
    r'„Unsere Pinnwand" in Ablaufplan oder Materialübersicht ist keine Aktivität',
  ),
  (
    'Weitere Aktivität mit Kennung',
    (o) => _setze(o, 'pinnwand-aufteilung', {'name': 'Arbeitsblatt 3: Pinnwand'}),
    r'ist kein Blatt und trägt keine Kennung',
  ),
  (
    'Board ohne Spalten',
    (o) => _schreib(o, 'pinnwand-aufteilung/board.json', '{"spalten": []}'),
    r'board.json braucht "spalten"',
  ),
  (
    'Board ohne board.json',
    (o) => File(p.join(o, 'pinnwand-aufteilung', 'board.json')).deleteSync(),
    r'board.json fehlt in pinnwand-aufteilung',
  ),
  (
    'Kanban: Karte ohne Spalte',
    _eineWeitere(
      0,
      dateien: {'kanban.json': '{"spalten": ["Zu erledigen"], "karten": [{"spalte": "Später", "titel": "Ports"}]}'},
    ),
    r'kanban.json: eine Karte nennt keine Spalte',
  ),
  (
    'Fortschrittsliste springt',
    _eineWeitere(1, dateien: {'eintraege.json': '[{"text": "A"}, {"text": "B", "tiefe": 2}]'}),
    r'„B" springt in der Einrückung',
  ),
  (
    'Fortschrittsliste: Zustand',
    _eineWeitere(1, dateien: {'eintraege.json': '[{"text": "A", "zustand": "kür"}]'}),
    r'"zustand" .kür.',
  ),
  (
    'Wiki: Startseite heißt anders',
    _eineWeitere(
      2,
      extra: {
        'einstellungen': {'firstpagetitle': 'Start'},
      },
    ),
    r'die erste Seite „Begriffe" ist die Startseite',
  ),
  (
    'Wiki: Seite fehlt',
    _eineWeitere(2, dateien: {'seiten.json': '[{"titel": "Begriffe", "datei": "fehlt.html"}]'}),
    r'Seite 1 braucht "titel" und eine "datei"',
  ),
  (
    'Test ohne Sachnummer',
    _eineWeitere(
      3,
      dateien: {'fragen.xml': '<quiz><question type="truefalse"><name><text>Tag</text></name></question></quiz>'},
    ),
    r'Frage „Tag" ohne Sachnummer',
  ),
  ('Test ohne Ort der Fragen', _eineWeitere(3, extra: {'fragen': {}}), r'Test ohne Ort für seine Fragen'),
  ('Test: kaputtes XML', _eineWeitere(3, dateien: {'fragen.xml': '<quiz><question>'}), r'fragen.xml ist kein gültiges XML'),
  (
    'Verzeichnis leer',
    (o) {
      _eineWeitere(4)(o);
      File(p.join(o, 'material', 'bereiche', 'files', 'plan.ods')).deleteSync();
    },
    r'Verzeichnis ohne Dateien',
  ),
  (
    'Datei: zwei Dateien',
    _eineWeitere(5, dateien: {'bereiche/files/zweite.pkt': 'y'}),
    r'genau eine Datei .*gefunden: 2',
  ),
  (
    'Lernlandkarte: Ort ohne Ziel',
    _eineWeitere(
      7,
      extra: {'ziele': Map.fromEntries(_karteZiele.entries.take(2))},
    ),
    r'p3 hat kein Ziel',
  ),
  (
    'Lernlandkarte: Ziel gibt es nicht',
    _eineWeitere(
      7,
      extra: {
        'ziele': {..._karteZiele, 'p3': 'Arbeitsblatt 9: Gibt es nicht'},
      },
    ),
    r'„Arbeitsblatt 9: Gibt es nicht" für p3 ist keine andere Aktivität',
  ),
  (
    'Lernlandkarte: Ziel ist die Karte selbst',
    _eineWeitere(
      7,
      extra: {
        'ziele': {..._karteZiele, 'p3': 'Lernweg zur VLAN-Segmentierung'},
      },
    ),
    r'für p3 ist keine andere Aktivität',
  ),
  (
    'Lernlandkarte: Ziel eines unbekannten Orts',
    _eineWeitere(
      7,
      extra: {
        'ziele': {..._karteZiele, 'p7': 'Unsere VLAN-Aufteilung'},
      },
    ),
    r'nennt „p7", einen Ort, den lernlandkarte.json nicht hat',
  ),
  (
    'Lernlandkarte: Weg rückwärts',
    _eineWeitere(
      7,
      dateien: {
        'lernlandkarte.json': _karteJson(
          wege: [
            {'von': 'p2', 'nach': 'p1'},
          ],
        ),
      },
    ),
    r'Weg 1 \(p2 nach p1\)',
  ),
  (
    'Lernlandkarte: Kennung mit Lücke',
    _eineWeitere(
      7,
      dateien: {
        'lernlandkarte.json': _karteJson(
          orte: [
            _karteOrte[0],
            {..._karteOrte[1], 'id': 'p3'},
          ],
          wege: [],
        ),
      },
    ),
    r'Ort 2 muss "p2" heißen',
  ),
  (
    'Lernlandkarte: Ziel in der Datei',
    _eineWeitere(
      7,
      dateien: {
        'lernlandkarte.json': _karteJson(
          orte: [
            {..._karteOrte[0], 'linkedActivity': 5},
            ..._karteOrte.skip(1),
          ],
        ),
      },
    ),
    r'Ort 1 darf nur id, x, y und titel enthalten',
  ),
  (
    'Lernlandkarte: Ort außerhalb',
    _eineWeitere(
      7,
      dateien: {
        'lernlandkarte.json': _karteJson(
          orte: [
            {..._karteOrte[0], 'x': 1200},
            ..._karteOrte.skip(1),
          ],
        ),
      },
    ),
    r'p1 braucht x von 0 bis 1000',
  ),
  (
    'Lernlandkarte ohne Hintergrundbild',
    (o) {
      _eineWeitere(7)(o);
      File(p.join(o, 'lernweg', 'bereiche', 'backgroundfile', 'hintergrund.svg')).deleteSync();
    },
    r'Lernlandkarte ohne Hintergrundbild',
  ),
  ('Lernlandkarte ohne Ziele', _eineWeitere(7, extra: {'ziele': 'p1'}), r'Lernlandkarte ohne Ziele'),
  (
    'Link ohne https',
    _eineWeitere(
      6,
      extra: {
        'einstellungen': {'externalurl': 'http://example.org'},
      },
    ),
    r'Link ohne Adresse',
  ),
  (
    'Skript im Text',
    _r(_ab1, '<p>Erkläre in je einem Satz', '<script>los()</script>\n<p>Erkläre in je einem Satz'),
    r'Code im Text \(<script>\)',
  ),
  (
    'Element ohne sandbox',
    _mitElement('<iframe src="@@PLUGINFILE@@/zz-element.html" title="Z"></iframe>'),
    r'Element zz-element.html ohne sandbox',
  ),
  (
    'Element lädt',
    _mitElement(
      '<iframe sandbox="allow-scripts" src="@@PLUGINFILE@@/zz-element.html" title="Z" height="100"></iframe>',
      _elementGut.replaceFirst('</body>', '<script>fetch("/x");</script></body>'),
    ),
    r'Element zz-element.html: Im Code steht fetch',
  ),
  (
    'Verlinkte Datei mit Code',
    _mitElement(
      '<p><a href="@@PLUGINFILE@@/zz-element.html">Zum Ausprobieren</a></p>',
      _elementGut.replaceFirst('</body>', '<script>los()</script></body>'),
    ),
    r'Datei zz-element.html enthält Code \(<script>\) und ist kein Element',
  ),
  (
    'Skript in eingebetteter Zeichnung',
    _r(
      _ab1,
      '<p>Erkläre in je einem Satz',
      '<svg xmlns="http://www.w3.org/2000/svg"><circle r="2" onclick="los()"/></svg>\n<p>Erkläre in je einem Satz',
    ),
    r'Code im Text \(onclick an <circle>\)',
  ),
];

/// Die Handlungssituation als Textfeld hinter der Handreichung, im
/// Ablaufplan als Material genannt.
void _mitSituation(String ordner) {
  _schreib(ordner, 'handlungssituation/introeditor.html', '<p>Die Muster GmbH zieht um.</p>\n');
  _dazu(ordner, {
    'ordner': 'handlungssituation',
    'typ': 'label',
    'name': 'Handlungssituation',
  }, nach: 'lehrerhandreichung');
  _ersetze(
    ordner,
    _hand,
    '<td>Plenum</td><td>Arbeitsblatt 1</td>',
    '<td>Plenum</td><td>Handlungssituation, Arbeitsblatt 1</td>',
  );
}

/// Eine Datei zum Herunterladen: Ihr Name darf im Text stehen.
void _mitDownload(String ordner) {
  _schreib(ordner, 'ab-02-umsetzung/dateien/netz-vorher.pkt', 'x');
  _ersetze(
    ordner,
    _ab2,
    'die Datei <code>netz-vorher.pkt</code>.',
    'die Datei <a href="@@PLUGINFILE@@/netz-vorher.pkt">netz-vorher.pkt</a>.',
  );
}

// Muss ohne Befund durchgehen: dieselbe Lernsituation in zulässigen Varianten.
final List<_Fall> _gute = [
  ('BG-Vorlage ausgefüllt', _bg(), r'Vorlage Berufliches Gymnasium'),
  ('"Lies"-Zeile in der Sie-Form', _r(_ab1, _lies4, _lies4.replaceFirst('Lies:', 'Lesen Sie:')), r'OK --'),
  (
    'Verweis über einen Zeilenumbruch',
    _r(_hilfe1, 'Kreist sie in Abb. 1 auf Arbeitsblatt 1 ein.', 'Kreist sie in Abb. 1 auf\nArbeitsblatt 1 ein.'),
    r'OK --',
  ),
  ('Handlungssituation als Textfeld', _mitSituation, r'OK -- 13 Aktivitäten, 13 davon'),
  (
    '"Lies"-Zeile mit Lehrbuch',
    _r(
      _ab1,
      _lies4,
      '<strong>Lies:</strong> Infoblatt 1, Abschnitt 4, und im Lehrbuch der Klasse das Kapitel „Netzsicherheit".',
    ),
    r'OK --',
  ),
  (
    'Rahmenlinie ohne Farbe',
    _r(_ab1l, '<tr><td>Trunk</td>', '<tr><td style="border-top: 2px solid">Trunk</td>'),
    r'OK --',
  ),
  ('Arbeitsblatt als Aufgabe', (o) => _alsAufgabe(o, 'ab-02-umsetzung'), r'OK --'),
  ('Handreichung als Buch', _alsBuch, r'OK --'),
  ('Datei zum Herunterladen', _mitDownload, r'OK --'),
  (
    'Unterabschnitt',
    (o) => _dazu(o, {'typ': 'subsection', 'name': 'Durchführen'}, nach: 'ab-01-auftrag-hilfe-loesung'),
    r'OK --',
  ),
  ('alle weiteren Aktivitäten', (o) => _weitere(o, _alleWeiteren), r'OK -- 20 Aktivitäten, 20 davon'),
];

// ---- Der Stand in Moodle ---------------------------------------------------
// Das Beispiel, übertragen, wie der Skill moodle es tut -- ohne Moodle: jede
// Aktivität mit dem Inhalt ihres Ordners, die Nennungen der Blätter als Links,
// abgelegt so, wie die App liest (kurs-<kurs>.json, cm-<cmid>/ mit
// uebersicht.json samt Verweisen, ein Buch als buch-<cmid>/). Das muss ohne
// Befund durchgehen; dann wird es beschädigt.

const _kurs = 99, _abschnitt = 500, _host = 'https://moodle.schule.example';
final List<String> _ordner = [
  for (final e in (jsonDecode(_lies(p.join(_beispiel, _manifest))) as Map)['aktivitaeten'] as List)
    (e as Map)['ordner'] as String,
];

int _cmVon(String ordner) => 1000 + _ordner.indexOf(ordner);

String _url(int cmid, [String typ = 'page']) => '$_host/mod/$typ/view.php?id=$cmid';

final _escape = const HtmlEscape(HtmlEscapeMode.element);

/// Jede Nennung eines anderen Blatts wird ein Link, wie der Skill moodle es
/// nach dem Anlegen tut: in der Materialübersicht mit dem ganzen Namen, sonst
/// mit der Kennung; eine weitere Aktivität mit ihrem Namen in
/// Anführungszeichen. [namen]/[kennungen]/[weitere] zeigen auf (cmid, typ).
/// Gibt HTML und [(cmid, Linktext)].
(String, List<(int, String)>) _verlinke(
  String h,
  String? eigen,
  Map<String, (int, String)> namen,
  Map<String, (int, String)> kennungen,
  Map<String, (int, String)> weitere,
) {
  final links = <(int, String)>[];
  // Nach Länge absteigend, bei gleicher Länge in der Reihenfolge der Einträge.
  final sortiert = namen.entries.toList();
  final reihe = {for (var i = 0; i < sortiert.length; i++) sortiert[i].key: i};
  sortiert.sort((a, b) {
    final l = b.key.length.compareTo(a.key.length);
    return l != 0 ? l : reihe[a.key]!.compareTo(reihe[b.key]!);
  });
  for (final MapEntry(key: name, value: (cmid, typ)) in sortiert) {
    final e = _escape.convert(name);
    if (h.contains('<td>$e</td>')) {
      h = h.replaceAll('<td>$e</td>', '<td><a href="${_url(cmid, typ)}">$e</a></td>');
      links.add((cmid, name));
    }
  }

  String zitat(Match m) {
    final (cmid, typ) = weitere[m[2]]!;
    links.add((cmid, m[2]!));
    return '${m[1]}<a href="${_url(cmid, typ)}">${m[2]}</a>${m[3]}';
  }

  String kennung(Match m) {
    final s = verweisSchluessel(m[0]!);
    if (s == eigen || !kennungen.containsKey(s)) return m[0]!;
    links.add((kennungen[s]!.$1, textNorm(m[0]!)));
    return '<a href="${_url(kennungen[s]!.$1, kennungen[s]!.$2)}">${m[0]}</a>';
  }

  final wn = weitere.keys.toList();
  final wr = {for (var i = 0; i < wn.length; i++) wn[i]: i};
  wn.sort((a, b) {
    final l = b.length.compareTo(a.length);
    return l != 0 ? l : wr[a]!.compareTo(wr[b]!);
  });
  final zitiert = weitere.isEmpty ? null : RegExp('([„“"])(${wn.map(RegExp.escape).join('|')})([“”"])');
  final raus = StringBuffer();
  var inA = 0;
  for (var t in _teilen(RegExp(r'<[^>]+>'), h)) {
    if (t.startsWith('<')) {
      inA += RegExp(r'^<a\b').hasMatch(t)
          ? 1
          : t.startsWith('</a')
          ? -1
          : 0;
    } else if (inA == 0) {
      // Erst die Namen in Anführungszeichen, dann die Kennungen -- nur
      // außerhalb der eben gesetzten Links.
      final teile = _teilen(RegExp(r'<a\b[^>]*>.*?</a>'), zitiert != null ? t.replaceAllMapped(zitiert, zitat) : t);
      t = [for (final x in teile) x.startsWith('<a') ? x : x.replaceAllMapped(blattZiel, kennung)].join();
    }
    raus.write(t);
  }
  return (raus.toString(), links);
}

/// Überträgt den Entwurf in einen Arbeitsordner, wie ihn die App nach
/// kurs_uebersicht, aktivitaet_lesen und buch_lesen hinterlässt.
void _nachMoodle(String entwurf, String ao) {
  Directory(ao).createSync(recursive: true);
  final eintraege = [
    for (final e in (jsonDecode(_lies(p.join(entwurf, _manifest))) as Map)['aktivitaeten'] as List)
      if ((e as Map)['ordner'] != null) e,
  ];
  final seiten = [for (final e in eintraege) (_cmVon(e['ordner'] as String), e)];
  final namen = {
    for (final (cmid, e) in seiten)
      if (!weitereTypen.contains(e['typ'])) e['name'] as String: (cmid, e['typ'] as String),
  };
  final weitere = {
    for (final (cmid, e) in seiten)
      if (weitereTypen.contains(e['typ'])) e['name'] as String: (cmid, e['typ'] as String),
  };
  final kennungen = {
    for (final (cmid, e) in seiten)
      if (pyMatch(blattZiel, e['name'] as String) case final m?) verweisSchluessel(m[0]!): (cmid, e['typ'] as String),
  };
  final ziele = {for (final (cmid, e) in seiten) cmid: e['name'] as String};

  /// Setzt die Links in einem Feld und legt uebersicht.json daneben.
  void verlinkt(String o, String feld, Map e) {
    final pfad = p.join(o, '$feld.html');
    var h = _lies(pfad);
    var links = <(int, String)>[];
    if (e['name'] != 'SchuCu') {
      final m = pyMatch(blattZiel, e['name'] as String);
      (h, links) = _verlinke(h, m != null ? verweisSchluessel(m[0]!) : null, namen, kennungen, weitere);
    }
    File(pfad).writeAsStringSync(h);
    File(p.join(o, 'uebersicht.json')).writeAsStringSync(
      jsonEncode({
        'name': e['name'],
        'auswertung': {
          'felder': [
            {
              'feld': feld,
              'verweise': [
                for (final (c, text) in links) {'art': 'aktivitaet', 'cmid': c, 'text': text, 'zielTitel': ziele[c]},
              ],
            },
          ],
        },
      }),
    );
  }

  final cms = <Map<String, Object?>>[];
  for (final (cmid, e) in seiten) {
    final quelle = p.join(entwurf, e['ordner'] as String);
    if (weitereTypen.contains(e['typ'])) {
      // Ihr Inhalt steht nicht im Formular; kurs_uebersicht nennt sie.
    } else if (e['typ'] == 'book') {
      final o = p.join(ao, 'buch-$cmid');
      _kopiere(quelle, o);
      for (final k in jsonDecode(_lies(p.join(o, 'kapitel.json'))) as List) {
        verlinkt(p.join(o, 'kapitel-${(k as Map)['id']}'), 'content_editor', e);
      }
    } else {
      final o = p.join(ao, 'cm-$cmid');
      _kopiere(quelle, o);
      verlinkt(o, inhaltsFelder[e['typ']]![0], e);
    }
    cms.add({'id': cmid, 'name': e['name'], 'module': e['typ'], 'visible': 0});
  }
  File(p.join(ao, 'kurs-$_kurs.json')).writeAsStringSync(
    jsonEncode({
      'section': [
        {'id': _abschnitt, 'title': 'ZZ Abteilungsnetze', 'cmlist': [for (final c in cms) c['id']]},
      ],
      'cm': cms,
    }),
  );
}

void _seiteAendern(String ao, String ordner, String alt, String neu) =>
    _ersetze(p.join(ao, 'cm-${_cmVon(ordner)}'), 'page.html', alt, neu);

void _jsonAendern(String ao, String datei, void Function(Map) f) {
  final pfad = p.join(ao, datei);
  final j = jsonDecode(_lies(pfad)) as Map;
  f(j);
  File(pfad).writeAsStringSync(jsonEncode(j));
}

void _cm(String ao, String ordner, Map<String, Object?> werte) => _jsonAendern(ao, 'kurs-$_kurs.json', (j) {
  for (final c in j['cm'] as List) {
    if ((c as Map)['id'] == _cmVon(ordner)) c.addAll(werte);
  }
});

void _loesungSichtbarVerlinkt(String ao) {
  final loes = _cmVon('ab-01-auftrag-loesung');
  _seiteAendern(ao, 'ab-01-auftrag', '</h3>', '</h3>\n<p><a href="${_url(loes)}">Lösung zu Arbeitsblatt 1</a></p>');
  _cm(ao, 'ab-01-auftrag', {'visible': 1});
  _jsonAendern(ao, 'cm-${_cmVon('ab-01-auftrag')}/uebersicht.json', (j) {
    ((((j['auswertung'] as Map)['felder'] as List)[0] as Map)['verweise'] as List).add({
      'art': 'aktivitaet',
      'cmid': loes,
      'text': 'Lösung zu Arbeitsblatt 1',
      'zielTitel': '?',
    });
  });
}

void _linkHinaus(String ao) => _jsonAendern(ao, 'cm-${_cmVon('ab-02-umsetzung')}/uebersicht.json', (j) {
  ((((j['auswertung'] as Map)['felder'] as List)[0] as Map)['verweise'] as List)[0]['cmid'] = 777;
});

final _ib1Link = '<a href="${_url(_cmVon('ib-01-vlan-grundlagen'))}">Infoblatt 1</a>';

// (Name, Änderung am Entwurf vor der Übertragung, Änderung danach, Ergebnis, Muster)
final List<(String, void Function(String)?, void Function(String)?, int, String)> _faelleMoodle = [
  ('Moodle: Beispiel übertragen', null, null, 0, r'OK --'),
  ('Moodle: Handreichung als Buch', _alsBuch, null, 0, r'OK --'),
  (
    'Moodle: Nennung ohne Link',
    null,
    (o) => _seiteAendern(o, 'ab-01-auftrag', _ib1Link, 'Infoblatt 1'),
    1,
    r'nennt "Infoblatt 1" ohne Link',
  ),
  (
    'Moodle: Blatt umbenannt',
    null,
    (o) => _cm(o, 'ib-01-vlan-grundlagen', {'name': 'Infoblatt 1: VLAN-Basics'}),
    1,
    r'"Infoblatt 1: VLAN-Grundlagen" ist nicht der Name(.|\n)*Der Text passt nicht zum Namen',
  ),
  (
    'Moodle: sichtbar verlinkt Lösung',
    null,
    _loesungSichtbarVerlinkt,
    1,
    r'für Lernende erreichbar und verlinkt die Lösung „Lösung zu Arbeitsblatt 1',
  ),
  ('Moodle: Link aus dem Abschnitt', null, _linkHinaus, 1, r'ausserhalb dieses Abschnitts'),
  (
    'Moodle: Aufgabe ohne AFB',
    null,
    (o) => _seiteAendern(o, 'ab-01-auftrag', '(10 min · Einzel · AFB II)', '(10 min · Einzel)'),
    1,
    r'Aufgabe 2: Klammer',
  ),
  (
    'Moodle: Pinnwand ohne Link',
    null,
    (o) => _seiteAendern(
      o,
      'ab-01-auftrag',
      '<a href="${_url(_cmVon('pinnwand-aufteilung'), 'board')}">$_pinnwand</a>',
      _pinnwand,
    ),
    1,
    r'nennt „Unsere VLAN-Aufteilung" ohne Link',
  ),
  (
    'Moodle: nicht gelesen',
    null,
    (o) => Directory(p.join(o, 'cm-${_cmVon('ab-02-umsetzung')}')).deleteSync(recursive: true),
    2,
    r'Erst lesen, dann prüfen',
  ),
];

/// Ein frischer Ordner für einen Fall; [Directory.systemTemp] ist auf dem Mac
/// eine Verknüpfung, die Prüfung löst sie auf.
Directory _tmp() => Directory.systemTemp.createTempSync('ls-');

LernsituationErgebnis _amEntwurf(String wurzel, String entwurf) =>
    entwurfPruefen(entwurf, arbeitsordner: wurzel, vorlagen: _vorlagen, anzeige: entwurf);

void main() {
  test('das Beispiel geht ohne Befund durch', () {
    final e = entwurfPruefen(
      p.absolute(_beispiel),
      arbeitsordner: p.absolute('skills'),
      vorlagen: _vorlagen,
      anzeige: _beispiel,
    );
    expect(e.code, 0, reason: e.ausgabe);
    expect(
      e.ausgabe,
      'Entwurf: Abschnitt „Abteilungsnetze für die Muster GmbH" ($_beispiel)\n'
      '  SchuCu-Tabelle: Vorlage Berufsschule\n'
      '  Ablaufplan: 180 min bei Richtwert 180 min\n'
      'OK -- 12 Aktivitäten, 12 davon Teil der Lernsituation, Form vollständig. Ob die Lernsituation trägt, '
      'sagt die Checkliste, nicht diese Prüfung.\n',
    );
    expect(e.antwort, startsWith('Ergebnis: keine Befunde.\n\nEntwurf: Abschnitt'));
  });

  group('am Entwurf', () {
    void fall(String name, void Function(String) aendern, int soll, String erwartet) {
      test(name, () {
        final t = _tmp();
        try {
          final ziel = p.join(t.path, 'entwurf');
          _kopiere(_beispiel, ziel);
          aendern(ziel);
          final e = _amEntwurf(t.path, ziel);
          expect(e.code, soll, reason: e.ausgabe);
          expect(e.ausgabe, matches(RegExp(erwartet)), reason: e.ausgabe);
        } finally {
          t.deleteSync(recursive: true);
        }
      });
    }

    group('jede Beschädigung ist ein Befund', () {
      for (final (name, kaputt, erwartet) in _faelle) {
        fall(name, kaputt, 1, erwartet);
      }
    });
    group('zulässige Varianten gehen ohne Befund durch', () {
      for (final (name, bau, erwartet) in _gute) {
        fall(name, bau, 0, erwartet);
      }
    });
  });

  group('am Stand in Moodle', () {
    for (final (name, vorher, kaputt, soll, erwartet) in _faelleMoodle) {
      test(name, () {
        final t = _tmp();
        try {
          final entwurf = p.join(t.path, 'entwurf'), ao = p.join(t.path, 'arbeitsordner');
          _kopiere(_beispiel, entwurf);
          vorher?.call(entwurf);
          _nachMoodle(entwurf, ao);
          kaputt?.call(ao);
          final e = moodlePruefen(ao, _abschnitt, vorlagen: _vorlagen);
          expect(e.code, soll, reason: e.ausgabe);
          expect(e.ausgabe, matches(RegExp(erwartet)), reason: e.ausgabe);
        } finally {
          t.deleteSync(recursive: true);
        }
      });
    }
  });

  group('Grenzen', () {
    test('ein Ordner außerhalb des Arbeitsordners gilt als nicht vorhanden', () {
      final t = _tmp();
      try {
        final wurzel = p.join(t.path, 'arbeitsordner'), draussen = p.join(t.path, 'draussen');
        final entwurf = p.join(wurzel, 'entwurf');
        _kopiere(_beispiel, entwurf);
        _kopiere(p.join(_beispiel, 'ab-02-umsetzung'), p.join(draussen, 'blatt'));
        _setze(entwurf, 'ab-02-umsetzung', {'ordner': '../../draussen/blatt'});
        final e = _amEntwurf(wurzel, entwurf);
        expect(e.code, 1);
        expect(e.ausgabe, contains('(../../draussen/blatt)'));
        expect(e.ausgabe, contains('Ordner fehlt'));
      } finally {
        t.deleteSync(recursive: true);
      }
    });

    test('ohne kurs-*.json ist in Moodle nichts zu prüfen', () {
      final t = _tmp();
      try {
        final e = moodlePruefen(t.path, 7, vorlagen: _vorlagen);
        expect(e.code, 2);
        expect(e.antwort, startsWith('Ergebnis: nichts zu prüfen.\n\nAbschnitt 7 steht in keiner kurs-*.json'));
      } finally {
        t.deleteSync(recursive: true);
      }
    });
  });

  group('HTML-Leser wie html.parser', () {
    List<String> folge(String html) {
      final l = _Mitschrift()..lesen(html);
      return l.ereignisse;
    }

    test('Platzhalter in spitzen Klammern sind Tags mit ihrem Quelltext', () {
      expect(folge('<p><du / Sie> x</p>'), ['start p', 'start du <du / Sie>', 'daten  x', 'ende p']);
    });

    test('ein rohes < verschluckt den Text bis zum nächsten >', () {
      expect(folge(r'<p>\(x<y\) a</p><p>b</p>'), [
        'start p',
        r'daten \(x',
        r'start y\) <y\) a</p>',
        'start p',
        'daten b',
        'ende p',
      ]);
    });

    test('Zeichenreferenzen wie html.unescape, Inhalt von script roh', () {
      expect(folge('a&nbsp;&lt;b&gt;&amp;c&#x41;&notit;<script>x &lt; y</script>'), [
        'daten a\u00a0<b>&cA\u00acit;',
        'start script',
        'daten x &lt; y',
        'ende script',
      ]);
    });
  });

  group('Werkzeug lernsituation_pruefen', () {
    late Directory ao;
    late McpDienst dienst;
    late McpTestClient client;

    setUp(() async {
      ao = _tmp();
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      final protokoll = Protokoll();
      dienst = McpDienst(
        Einstellungen(),
        MoodleZugang(protokoll),
        protokoll,
        Freigaben(protokoll),
        ao.path,
        profil: Profil(
          kennung: 'test',
          name: 'Test',
          adresse: 'https://moodle.schule.example',
          port: port,
          mcpName: 'test',
        ),
        schucuVorlagen: () async => _vorlagen,
      );
      await dienst.starten();
      client = McpTestClient(port);
      await client.initialize();
    });

    tearDown(() async {
      client.schliessen();
      await dienst.stoppen();
      ao.deleteSync(recursive: true);
    });

    test('steht in der Werkzeugliste als nur lesend', () async {
      final liste = await dienst.werkzeugliste();
      final werkzeug = ((liste['tools'] as Map)['tools'] as List).cast<Map>().firstWhere(
        (t) => t['name'] == 'lernsituation_pruefen',
      );
      expect((werkzeug['annotations'] as Map)['readOnlyHint'], true);
      expect((werkzeug['annotations'] as Map)['destructiveHint'], false);
      expect(((werkzeug['inputSchema'] as Map)['properties'] as Map).keys, {'entwurf', 'abschnitt_id'});
    });

    test('prüft einen Entwurf im Arbeitsordner, relativ angegeben', () async {
      _kopiere(_beispiel, p.join(ao.path, 'entwurf'));
      final antwort = await client.tool('lernsituation_pruefen', {'entwurf': 'entwurf'});
      expect(antwort, startsWith('Ergebnis: keine Befunde.\n\nEntwurf: Abschnitt „Abteilungsnetze'));
      expect(antwort, contains('OK -- 12 Aktivitäten'));
    });

    test('meldet Befunde mit dem Ergebnis in der ersten Zeile', () async {
      final entwurf = p.join(ao.path, 'entwurf');
      _kopiere(_beispiel, entwurf);
      _ersetze(entwurf, _hand, '<strong>180</strong>', '<strong>170</strong>');
      final antwort = await client.tool('lernsituation_pruefen', {'entwurf': entwurf});
      expect(antwort, startsWith('Ergebnis: Befunde -- siehe unten.\n\n'));
      expect(antwort, contains('Summenzeile sagt 170, die Zeilen ergeben 180'));
    });

    test('prüft einen gelesenen Abschnitt', () async {
      final t = _tmp();
      try {
        _kopiere(_beispiel, p.join(t.path, 'entwurf'));
        _nachMoodle(p.join(t.path, 'entwurf'), ao.path);
      } finally {
        t.deleteSync(recursive: true);
      }
      final antwort = await client.tool('lernsituation_pruefen', {'abschnitt_id': _abschnitt});
      expect(antwort, startsWith('Ergebnis: keine Befunde.\n\nStand in Moodle: Abschnitt „ZZ Abteilungsnetze"'));
    });

    test('verlangt genau eines von entwurf und abschnitt_id', () async {
      for (final args in [
        <String, Object?>{},
        {'entwurf': 'entwurf', 'abschnitt_id': 5},
      ]) {
        final antwort = await client.tool('lernsituation_pruefen', args);
        expect(antwort, contains('Genau eines angeben'));
      }
    });

    test('liest nicht außerhalb des Arbeitsordners', () async {
      final antwort = await client.tool('lernsituation_pruefen', {'entwurf': p.absolute(_beispiel)});
      expect(antwort, contains('Gesperrt: Der Ordner muss im Arbeitsordner liegen'));
    });
  });
}

/// Schreibt mit, was der Leser meldet.
class _Mitschrift extends PyHtmlLeser {
  final ereignisse = <String>[];

  @override
  void starttag(String tag, List<Attribut> attrs) =>
      ereignisse.add(starttagText == '<$tag>' ? 'start $tag' : 'start $tag $starttagText');

  @override
  void endtag(String tag) => ereignisse.add('ende $tag');

  @override
  void daten(String d) => ereignisse.add('daten $d');
}
