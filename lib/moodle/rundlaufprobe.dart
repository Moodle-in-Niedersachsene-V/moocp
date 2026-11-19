// Die Rundlaufprobe (E38): Jede Frage, die die App per Import anlegt, und jede
// Version, die sie aus XML einspielt, besteht sie, bevor ein Werkzeug
// `verified` meldet. Das Urteil fällt dieses Modul, nicht die KI (A3).
//
// Vier Teile:
//   1. Export und Vergleich: Eingabe ⊆ Ausgabe (fragen_vergleich.dart).
//   2. Das Bearbeitungsformular öffnet sich ohne Fehler.
//   3. Die Vorschau lädt ohne Moodle-Fehler.
//   4. Das Formular wird einmal unverändert als ENTWURF gespeichert; die
//      Probeversion wird exportiert, mit der geprüften Version verglichen und
//      gelöscht. Das beweist, dass sich die Frage von Hand weiterbearbeiten
//      lässt, ohne dass das Speichern sie verändert. Entwurf, damit die
//      Probeversion nie in einen laufenden Test gerät, der die neueste BEREITE
//      Version zieht. Lässt sich der Status nicht auf Entwurf setzen, wird
//      nicht gespeichert: Der Teil heißt dann „nicht geprüft".
//
// Löschen nur, was derselbe Aufruf angelegt hat ([Angelegt]): Das Löschen
// nimmt nur Nummern, die Moodle diesem Aufruf selbst genannt hat, und prüft
// sie unmittelbar vorher. Ältere Versionen und andere Fragen sind hier nicht
// löschbar, einen zweiten Weg gibt es nicht.

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'formular.dart';
import 'formular_schreiben.dart';
import 'fragen.dart';
import 'fragen_vergleich.dart';
import 'fragen_xml.dart';
import 'moodle_zugang.dart';

/// Die Fragennummern, die Moodle einem Aufruf als angelegt gemeldet hat --
/// die Quelle der Löschberechtigung. Nur [melden] nimmt etwas hinein.
class Angelegt {
  final Map<int, String> _namen = {};

  void melden(int id, String name) => _namen[id] = name;
  bool enthaelt(int id) => _namen.containsKey(id);
  String? name(int id) => _namen[id];
  Iterable<int> get ids => _namen.keys;
}

class ProbeErgebnis {
  ProbeErgebnis();

  /// Was nicht stimmt: Abweichungen, Fehler im Formular oder in der Vorschau,
  /// ein abgelehntes Speichern. Nicht leer heißt: Probe nicht bestanden.
  final List<String> befunde = [];

  /// Teile, die sich nicht prüfen ließen.
  final List<String> nichtGeprueft = [];

  /// Weitere Auskünfte, etwa eine Probeversion, die stehen bleibt.
  final List<String> hinweise = [];

  /// Die Moodle-Version, soweit die Vorschauseite sie nennt (nur für die
  /// Fragetyp-Notiz, fragetyp_notizen.dart); null, wenn sie nicht darin steht.
  String? moodleVersion;

  /// Eine Probeversion, die nicht gelöscht werden konnte. Sie liegt als
  /// Entwurf in der Fragenbank und gehört in die Antwort.
  bool probeBleibt = false;

  bool get bestanden => befunde.isEmpty;

  /// `verified` heißt: alle vier Teile liefen und bestanden.
  bool get verified => befunde.isEmpty && nichtGeprueft.isEmpty && !probeBleibt;

  String text() {
    final b = StringBuffer();
    for (final x in befunde) {
      b.writeln('  Befund: $x');
    }
    for (final x in nichtGeprueft) {
      b.writeln('  nicht geprüft: $x');
    }
    for (final x in hinweise) {
      b.writeln('  Hinweis: $x');
    }
    return b.toString();
  }
}

/// Löscht [id], wenn dieser Aufruf sie angelegt hat; sonst nie. Prüft
/// unmittelbar vorher Nummer und Namen gegen Moodle. [ersteVersion]: Die
/// Nummer einer Version, die danach noch da sein muss (beim Löschen einer
/// einzelnen Version, nicht des ganzen Eintrags).
Future<({bool weg, String text})> loescheAngelegtes(
  MoodleZugang moodle,
  String arbeitsordner,
  int sammlung,
  Angelegt angelegt,
  int id, {
  required bool alleVersionen,
  int? verbleibend,
}) async {
  if (!angelegt.enthaelt(id)) {
    // Ein Programmierfehler, kein Zustand von Moodle: nie löschen.
    throw StateError('Frage $id hat dieser Aufruf nicht angelegt.');
  }
  final e = await frageExport(moodle, sammlung, id);
  final f = e.xml == null ? null : fragenAusXml(e.xml!).where((x) => x.id == id).firstOrNull;
  if (f == null) return (weg: true, text: 'Frage $id gibt es nicht mehr.');
  if (f.name != angelegt.name(id)) {
    return (weg: false, text: 'Nicht gelöscht: Frage $id heißt jetzt „${f.name}", nicht mehr „${angelegt.name(id)}".');
  }
  final (zeilen, alleWeg) = await loeschenOhneFreigabe(moodle, arbeitsordner, sammlung, [f], alleVersionen: alleVersionen);
  var text = zeilen.trim();
  if (alleWeg && verbleibend != null) {
    final rest = await frageExport(moodle, sammlung, verbleibend);
    if (rest.xml == null) {
      return (weg: true, text: '$text\nACHTUNG: Die ältere Version $verbleibend ist nach dem Löschen nicht mehr da.');
    }
  }
  return (weg: alleWeg, text: text);
}

/// Wird gerufen, wenn eine Frage die Probe in allen vier Teilen bestanden hat
/// (verified): Fragetyp, das geprüfte XML und die Moodle-Version (oder null).
/// Daraus entsteht der Nachweis für eine Fragetyp-Notiz (fragetyp_notizen.dart).
typedef BeiBestanden = void Function(String typ, String xml, String? moodleVersion);

/// Die Fehlermeldung einer Moodle-Seite, oder null. Ein Hinweiskasten im
/// Text der Frage (Bootstrap `alert-danger`, A8) ist keine Fehlermeldung.
String? seitenFehler(String html) {
  final d = html_parser.parse(html);
  bool imText(dom.Element e) {
    for (dom.Element? p = e.parent; p != null; p = p.parent) {
      if (p.classes.contains('que') || p.classes.contains('formulation')) return true;
    }
    return false;
  }

  for (final e in d.querySelectorAll('.errormessage, .errorbox, [data-rel="fatalerror"], .alert-danger')) {
    if (imText(e)) continue;
    final t = e.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isNotEmpty) return t;
  }
  return null;
}

/// Die Probe für eine gespeicherte Frage oder Version [frage]. [eingabe] ist
/// das XML, aus dem sie entstanden ist (mit genau dieser einen Frage).
/// [angelegt] muss [frage] schon kennen, wenn es um etwas geht, das dieser
/// Aufruf angelegt hat; die Probeversion trägt die Probe selbst ein.
Future<ProbeErgebnis> rundlaufProbe(
  MoodleZugang moodle,
  String arbeitsordner, {
  required int sammlung,
  required int frage,
  required String eingabe,
  required Angelegt angelegt,
}) async {
  final r = ProbeErgebnis();

  // 1. Export und Vergleich.
  final aus = await frageExport(moodle, sammlung, frage);
  if (aus.xml == null) {
    r.befunde.add('Die gespeicherte Frage $frage lässt sich nicht wieder exportieren'
        '${aus.meldung.isEmpty ? '' : ' (Moodle: ${aus.meldung})'}.');
    return r;
  }
  r.befunde.addAll(fragenVergleichen(eingabe, aus.xml!));
  if (r.befunde.isNotEmpty) return r;

  // 2. Bearbeitungsformular.
  Formular form;
  try {
    form = await formularHolen(moodle, '/question/bank/editquestion/question.php?cmid=$sammlung&id=$frage');
  } on MoodleFehler catch (x) {
    r.befunde.add('Das Bearbeitungsformular der Frage öffnet sich nicht: ${x.meldung}');
    return r;
  }
  final formFehler = seitenFehler(form.form.outerHtml);
  if (formFehler != null) {
    r.befunde.add('Das Bearbeitungsformular zeigt eine Fehlermeldung: $formFehler');
    return r;
  }

  // Das Plugin speichert eine Version mit Warnungen nur als Entwurf; den
  // Status zeigt das Formular. Eine Entwurfsversion ist keine fertige Frage.
  final gewaehlt = form.form.querySelector('select[name="status"] option[selected]')?.attributes['value'];
  if (gewaehlt == 'draft') {
    r.befunde.add('Moodle hat die Frage nur als Entwurf gespeichert, nicht als bereit (das Plugin tut das bei '
        'Warnungen zum Import). Tests ziehen sie so nicht.');
    return r;
  }

  // 3. Vorschau.
  try {
    var a = await moodle.lesen('/question/bank/previewquestion/preview.php?id=$frage&cmid=$sammlung');
    // Der erste Aufruf legt den Vorschauversuch an und leitet auf dieselbe
    // Adresse mit previewid um.
    for (var i = 0; i < 2; i++) {
      final ziel = moodle.umleitungsziel(a);
      if (ziel == null) break;
      a = await moodle.lesen('${ziel.path}${ziel.hasQuery ? '?${ziel.query}' : ''}');
    }
    r.moodleVersion = RegExp(r'"(?:moodleversion|moodle_version|release)"\s*:\s*"([0-9][0-9.]*)').firstMatch(a.text)?.group(1);
    final fehler = a.status != 200 ? 'HTTP ${a.status}' : seitenFehler(a.text);
    if (fehler != null) {
      r.befunde.add('Die Vorschau der Frage zeigt einen Fehler: $fehler');
      return r;
    }
  } on MoodleFehler catch (x) {
    r.befunde.add('Die Vorschau der Frage lässt sich nicht laden: ${x.meldung}');
    return r;
  }

  // 4. Unverändert als Entwurf speichern.
  final status = form.form.querySelector('select[name="status"]');
  final kannEntwurf = status != null && status.querySelectorAll('option').any((o) => o.attributes['value'] == 'draft');
  if (!kannEntwurf) {
    r.nichtGeprueft.add('Speichern des Bearbeitungsformulars: Der Status der Frage lässt sich nicht auf „Entwurf" '
        'setzen. Gespeichert wird dann nicht, weil die Probeversion sonst in laufenden Tests landen könnte.');
    return r;
  }
  setze(form.felder, 'status', 'draft');
  int? probe;
  try {
    final antwort = await absenden(moodle, form, knoepfe: const ['submitbutton']);
    probe = int.tryParse(moodle.umleitungsziel(antwort)?.queryParameters['lastchanged'] ?? '');
  } on MoodleFehler catch (x) {
    r.befunde.add('Moodle nimmt das unveränderte Speichern des Bearbeitungsformulars nicht an: ${x.meldung}. '
        'Ohne KI ließe sich die Frage von Hand nicht weiterbearbeiten.');
    return r;
  }
  if (probe == null || probe == frage) {
    r.befunde.add('Das Speichern des Bearbeitungsformulars hat keine erkennbare Probeversion ergeben; ob eine '
        'Entwurfsversion stehen geblieben ist, ist unklar. In der Fragenbank nachsehen.');
    r.probeBleibt = true;
    return r;
  }
  // Ab hier gehört die Probeversion diesem Aufruf.
  final probeName = _nameAus(aus.xml!) ?? '';
  angelegt.melden(probe, probeName);
  final probeExport = await frageExport(moodle, sammlung, probe);
  if (probeExport.xml == null) {
    r.befunde.add('Die Probeversion $probe lässt sich nicht exportieren.');
  } else {
    // Gleich bis auf den Status: Ein Entwurf darf sich in hidden niederschlagen.
    final a = _ohneStatus(aus.xml!), b = _ohneStatus(probeExport.xml!);
    final abweichung = [...fragenVergleichen(a, b), ...fragenVergleichen(b, a)];
    for (final x in abweichung.toSet()) {
      r.befunde.add('Unverändert gespeichert weicht die Frage ab: $x');
    }
  }
  final weg = await loescheAngelegtes(moodle, arbeitsordner, sammlung, angelegt, probe,
      alleVersionen: false, verbleibend: frage);
  if (!weg.weg) {
    r.probeBleibt = true;
    r.hinweise.add('Die Probeversion $probe ließ sich nicht löschen und liegt als Entwurf in der Fragenbank '
        '(von keinem Test benutzt): ${weg.text}');
  } else if (weg.text.contains('ACHTUNG')) {
    r.befunde.add(weg.text);
  }
  return r;
}

String? _nameAus(String xml) {
  try {
    return fragenAusXml(xml).firstOrNull?.name;
  } on XmlException {
    return null;
  }
}

/// Das XML ohne `<hidden>` und ohne die Kommentare (Fragennummer).
String _ohneStatus(String xml) {
  final d = XmlDocument.parse(xml);
  for (final h in d.findAllElements('hidden').toList()) {
    h.remove();
  }
  return d.toXmlString();
}

/// Die Rundlaufprobe für jede Frage, die ein Import gerade angelegt hat
/// ([i]), samt dem Aufräumen: Was durchfällt, löscht dieser Aufruf wieder --
/// die neue Frage mit allen ihren Versionen, die es nur durch diesen Aufruf
/// gibt, nie etwas anderes. [neueIds]: Das Speichern einer CodeRunner-Frage
/// über das Formular (importNachweise) hat eine neuere Version angelegt; sie
/// gehört zu diesem Aufruf und wird geprüft statt der importierten.
/// [xml] ist das geprüfte XML der Datei.
Future<({String text, bool ok, bool verified})> importProben(
  MoodleZugang moodle,
  String arbeitsordner,
  int sammlung,
  Importiert i,
  Map<int, int> neueIds,
  String xml, {
  BeiBestanden? beiBestanden,
}) async {
  final doc = XmlDocument.parse(xml);
  final eingaben = [for (final q in doc.rootElement.findElements('question')) if (q.getAttribute('type') != 'category') q];
  final b = StringBuffer();
  var ok = true, verified = true;
  for (final f in i.neu.where((f) => f.id != null)) {
    final angelegt = Angelegt()..melden(f.id!, f.name);
    final ziel = neueIds[f.id] ?? f.id!;
    if (ziel != f.id) angelegt.melden(ziel, f.name);
    final q = eingaben.where((e) {
      final idn = e.getElement('idnumber')?.innerText.trim() ?? '';
      final name = e.getElement('name')?.getElement('text')?.innerText.trim() ?? '';
      return f.idnummer != null ? idn == f.idnummer : name == f.name;
    }).firstOrNull;
    if (q == null) {
      ok = verified = false;
      b.writeln('Rundlaufprobe „${f.name}" (${f.id}): Die Frage steht nicht mehr in der Eingabe; nicht geprüft.');
      continue;
    }
    final r = await rundlaufProbe(moodle, arbeitsordner,
        sammlung: sammlung, frage: ziel, eingabe: quizXml([q.toXmlString()]), angelegt: angelegt);
    if (r.bestanden) {
      b.writeln('Rundlaufprobe „${f.name}" (${r.verified ? 'bestanden' : 'ohne Befund, nicht vollständig'}):');
      b.write(r.text());
      if (!r.verified) verified = false;
      if (r.verified) beiBestanden?.call(f.typ, quizXml([q.toXmlString()]), r.moodleVersion);
      continue;
    }
    ok = verified = false;
    final weg = await loescheAngelegtes(moodle, arbeitsordner, sammlung, angelegt, ziel, alleVersionen: true);
    b.writeln('Rundlaufprobe „${f.name}" NICHT bestanden; die neue Frage wurde '
        '${weg.weg ? 'wieder gelöscht' : 'NICHT gelöscht und liegt noch in der Fragenbank'}:');
    b.write(r.text());
    if (!weg.weg) b.writeln('  ${weg.text}');
  }
  return (text: b.toString(), ok: ok, verified: verified);
}
