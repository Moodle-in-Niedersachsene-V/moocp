// Rundlaufprobe, Teil 1 (E38): Ist das, was die KI als Moodle-XML geschrieben
// hat, nach dem Speichern und erneuten Exportieren noch vollständig da?
//
// „Eingabe ⊆ Ausgabe": Was Moodle beim Speichern selbst ergänzt (Standardwerte,
// Schlagwörter, leere Felder, Zeitstempel), ist erlaubt. Was die Eingabe nennt
// und die Ausgabe nicht oder anders trägt, ist ein Befund. Verglichen wird der
// ganze Elementbaum, nicht eine Auswahl von Kernfeldern: Lücken, Ablagebereiche,
// Teilfragen und Rückmeldebäume hängen je nach Fragetyp an anderen Elementen,
// und eine Liste von Feldern je Typ wäre genau die Messung, die E38 ersetzt.
//
// Normalisiert wird nur, was Moodle ohne Bedeutung ändert: Leerraum in Texten,
// die Schreibweise von Zahlen (`1`, `1.0`, `1.0000000`) und zwei Typnamen, die
// der Export anders schreibt als der Import (fragen_xml.dart, fragenAusXml).
// Ein leeres Eingabefeld heißt „nicht angegeben": Moodle darf es füllen.
//
// Reine Funktionen ohne Moodle-Zugriff (test/fragen_vergleich_test.dart).

import 'package:xml/xml.dart';

/// Vergleicht die Fragen einer Eingabedatei mit denen eines Exports: Jede Frage
/// der Eingabe muss in der Ausgabe eine Entsprechung haben, zugeordnet über die
/// Sachnummer, sonst über Typ und Namen. Gibt die Befunde, leer wenn alles
/// stimmt. Kategorie-Einträge (`type="category"`) zählen nicht.
List<String> fragenVergleichen(String eingabe, String ausgabe) {
  final ein = _fragen(XmlDocument.parse(eingabe));
  final aus = _fragen(XmlDocument.parse(ausgabe));
  final befunde = <String>[];
  final benutzt = <XmlElement>{};
  for (final e in ein) {
    final name = _titel(e);
    final idn = _text(e.getElement('idnumber'));
    final kandidaten = [
      for (final a in aus)
        if (!benutzt.contains(a) && _typ(a) == _typ(e) && (idn.isNotEmpty ? _text(a.getElement('idnumber')) == idn : _titel(a) == name)) a,
    ];
    if (kandidaten.isEmpty) {
      befunde.add('Frage „$name" (${_typ(e)}) fehlt im Export.');
      continue;
    }
    benutzt.add(kandidaten.first);
    befunde.addAll(frageVergleichen(e, kandidaten.first));
  }
  return befunde;
}

/// Vergleicht genau eine Frage der Eingabe mit der einen im Export.
List<String> frageVergleichen(XmlElement eingabe, XmlElement ausgabe) {
  final befunde = <String>[];
  _befunde(eingabe, [ausgabe], 'question', befunde);
  return befunde;
}

List<XmlElement> _fragen(XmlDocument d) => [
  for (final q in d.rootElement.findElements('question'))
    if (q.getAttribute('type') != 'category') q,
];

String _titel(XmlElement q) => _text(q.getElement('name')?.getElement('text') ?? q.getElement('name'));

const _typNamen = {'match': 'matching', 'multianswer': 'cloze'};
String _typ(XmlElement q) {
  final t = q.getAttribute('type') ?? '';
  return _typNamen[t] ?? t;
}

/// Der Text eines Elements ohne Kindelemente, im Leerraum vereinheitlicht.
String _text(XmlElement? e) => e == null ? '' : _norm(e.innerText);

String _norm(String s) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  // 1, 1.0 und 1.0000000 sind dieselbe Zahl; nur ganze Zeichenketten, die
  // eine Zahl SIND, werden umgeschrieben (nie ein Text mit Ziffern darin).
  if (RegExp(r'^-?\d+(\.\d+)?$').hasMatch(t)) {
    final d = double.parse(t);
    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
  }
  return t;
}

String _wert(XmlElement e, String attribut) {
  final w = e.getAttribute(attribut) ?? '';
  return attribut == 'type' ? (_typNamen[w] ?? w) : _norm(w);
}

bool _hatKinder(XmlElement e) => e.childElements.isNotEmpty;

/// Ob [e] (Eingabe) in [a] (Ausgabe) enthalten ist.
bool _passt(XmlElement e, XmlElement a) {
  if (e.name.local != a.name.local) return false;
  for (final at in e.attributes) {
    if (_wert(e, at.name.local) != _wert(a, at.name.local)) return false;
  }
  if (!_hatKinder(e)) {
    final t = _text(e);
    return t.isEmpty || t == _text(a);
  }
  final frei = [...a.childElements];
  for (final k in e.childElements) {
    final i = frei.indexWhere((x) => _passt(k, x));
    if (i < 0) return false;
    frei.removeAt(i);
  }
  return true;
}

/// Sucht zu [e] eine Entsprechung unter [kandidaten] und beschreibt, wo es
/// abweicht, wenn keine passt. [pfad] ist der Weg bis hierher.
void _befunde(XmlElement e, List<XmlElement> kandidaten, String pfad, List<String> aus) {
  if (kandidaten.any((a) => _passt(e, a))) return;
  final gleich = kandidaten.where((a) => a.name.local == e.name.local).toList();
  if (gleich.isEmpty) {
    aus.add('$pfad fehlt im Export.');
    return;
  }
  // Die am besten passende Entsprechung ist die mit den meisten
  // übereinstimmenden Kindern; an ihr wird der Unterschied beschrieben.
  gleich.sort((x, y) => _treffer(e, y).compareTo(_treffer(e, x)));
  final a = gleich.first;
  for (final at in e.attributes) {
    if (_wert(e, at.name.local) != _wert(a, at.name.local)) {
      aus.add('$pfad, Attribut ${at.name.local}: erwartet „${_kurz(_wert(e, at.name.local))}", '
          'im Export „${_kurz(_wert(a, at.name.local))}".');
    }
  }
  if (!_hatKinder(e)) {
    if (_text(e).isNotEmpty && _text(e) != _text(a)) {
      aus.add('$pfad: erwartet „${_kurz(_text(e))}", im Export „${_kurz(_text(a))}".');
    }
    return;
  }
  final frei = [...a.childElements];
  final zaehler = <String, int>{};
  for (final k in e.childElements) {
    final n = k.name.local;
    final nr = zaehler[n] = (zaehler[n] ?? 0) + 1;
    final i = frei.indexWhere((x) => _passt(k, x));
    if (i >= 0) {
      frei.removeAt(i);
    } else {
      _befunde(k, frei, '$pfad/$n[$nr]', aus);
    }
  }
}

int _treffer(XmlElement e, XmlElement a) =>
    e.childElements.where((k) => a.childElements.any((x) => _passt(k, x))).length +
    e.attributes.where((at) => _wert(e, at.name.local) == _wert(a, at.name.local)).length;

String _kurz(String s) => s.length > 80 ? '${s.substring(0, 80)}…' : s;
