// Texte importierter Aktivitäten zurücklesen und mit der Quellaufnahme vergleichen (E2, E17).
//
// Quelle: die Sicherungsdatei (wie bei den Anhängen, `wiederherstellung_anhaenge.dart`). Je
// eindeutig zugeordneter Aktivität steht ihr Text in `<modul>.xml` ihres Verzeichnisses.
// Ziel: die Editorfelder im Bearbeitungsformular (`/course/modedit.php?update=cmid`,
// Positivliste), `name="…[text]"`. Die Prüfung liest nur und repariert nichts.
//
// Abgedeckt sind je Art diese Textfelder (Archiv-Element -> Formularfeld):
//   page      intro -> introeditor, content -> page
//   label     intro -> introeditor
//   assign    intro -> introeditor, activity -> activityeditor
//   folder, url, resource, quiz, qbank, wiki, board, kanban, checklist, subsection
//             intro -> introeditor
// Prüflücke bleibt, was nicht in einem Editorfeld des Formulars der Aktivität steht:
//   book      Kapitel (eigene Bearbeitungsseiten)
//   wiki      Wikiseiten;  board: Karten;  kanban: Karten;  checklist: Listenpunkte
//   quiz      Fragetexte (der Fragenvergleich prüft nur Anzahl und Namen)
// Einstellungen werden hier nie verglichen; der Bericht nennt das ausdrücklich.
//
// Vor dem Vergleich wird nur normalisiert, was sich beim Wiederherstellen von selbst ändert:
// die Adresse der Instanz (Quelle und Ziel), Platzhalter und Pfade für Dateien,
// Zeilenenden und Leerraum. Ohne belegte Zuordnung bleiben Objektkennungen erhalten;
// Wiederherstellungsplatzhalter für Objektlinks bleiben eine Prüflücke. Alles andere
// (Wörter, Tags, Linkziele, Dateinamen) bleibt, ein Unterschied dort ist eine Abweichung.
// Ein Platzhalter der Sicherung, den die App nicht kennt, ist eine Prüflücke, nie Gleichheit.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'formular_lesen.dart' show hauptformular;
import 'moodle_zugang.dart';
import 'sicherung.dart';
import 'wiederherstellung_anhaenge.dart' show sicherungsquelleLesen;
import 'wiederherstellung_regeln.dart' show WiederhergestellteAktivitaet, archivAktivitaetsElemente;

/// Ein Textfeld einer Art: Element in `<modul>.xml`, Feld im Formular, Anzeigename im Bericht.
typedef _Feld = ({String element, String formular, String anzeige});

const _beschreibung = (element: 'intro', formular: 'introeditor[text]', anzeige: 'Beschreibung');

const Map<String, List<_Feld>> _felder = {
  'page': [_beschreibung, (element: 'content', formular: 'page[text]', anzeige: 'Seiteninhalt')],
  'label': [_beschreibung],
  'assign': [_beschreibung, (element: 'activity', formular: 'activityeditor[text]', anzeige: 'Aufgabentext')],
  'folder': [_beschreibung],
  'url': [_beschreibung],
  'resource': [_beschreibung],
  'quiz': [_beschreibung],
  'qbank': [_beschreibung],
  'wiki': [_beschreibung],
  'board': [_beschreibung],
  'kanban': [_beschreibung],
  'checklist': [_beschreibung],
  'subsection': [_beschreibung],
  'book': [_beschreibung],
};

/// Texte, die zur Art gehören, aber nicht in einem Feld ihres Formulars stehen.
const Map<String, String> _ungelesen = {
  'book': 'Kapitel',
  'wiki': 'Wikiseiten',
  'board': 'Karten',
  'kanban': 'Karten',
  'checklist': 'Listenpunkte',
};

/// Ergebnis für alle Aktivitäten zusammen.
class TextPruefung {
  TextPruefung(this.befunde, {required this.vollstaendig, this.abweichend = false});

  /// Mindestens ein Text unterscheidet sich von der Quelle (nicht nur eine Prüflücke).
  final bool abweichend;

  /// Je Fund ein Satz mit Aktivität und Feldname, nie mit Inhalt.
  final List<String> befunde;

  /// Nur wahr, wenn jedes Feld übereinstimmt und nichts ungelesen blieb.
  final bool vollstaendig;

  String get text => vollstaendig
      ? 'Texte: verglichen, übereinstimmend.'
      : 'Texte nicht vollständig verifiziert: ${befunde.join('; ')}. Nichts wurde repariert.';
}

/// Die Texte einer Aktivität aus der Quellaufnahme: Formularfeld -> Text. [luecke] nennt den
/// Grund, wenn sich die Quelle nicht eindeutig lesen lässt; [wwwroot] die Adresse der Quellinstanz.
class QuellTexte {
  QuellTexte(this.felder, {this.luecke, this.wwwroot});
  final Map<String, String> felder;
  final String? luecke;
  final String? wwwroot;
}

String? _kind(XmlElement e, String name) => e.getElement(name)?.innerText;

/// Liest die Texte von [modul] „[titel]" aus dem Archiv. Nicht eindeutig oder nicht lesbar:
/// [QuellTexte.luecke] ist gesetzt.
QuellTexte quelltexteAus(Uint8List mbz, {required String modul, required String titel}) {
  QuellTexte luecke(String grund) => QuellTexte(const {}, luecke: grund);
  final felder = _felder[modul];
  if (felder == null) return luecke('Texte dieser Art werden nicht verglichen');
  final Map<String, Uint8List> dateien;
  try {
    final tar = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(mbz));
    dateien = {
      for (final f in tar.files)
        if (f.isFile) f.name: Uint8List.fromList(f.content as List<int>),
    };
  } catch (_) {
    return luecke('Quellaufnahme nicht lesbar');
  }
  final backup = dateien['moodle_backup.xml'];
  if (backup == null) return luecke('Quellaufnahme nicht lesbar');
  try {
    final doc = XmlDocument.parse(utf8.decode(backup, allowMalformed: true));
    final verzeichnisse = [
      for (final a in archivAktivitaetsElemente(doc))
        if (a.getElement('modulename')?.innerText.trim() == modul && a.getElement('title')?.innerText.trim() == titel)
          a.getElement('directory')?.innerText.trim() ?? '',
    ];
    if (verzeichnisse.length != 1) return luecke('Aktivität nicht eindeutig im Archiv');
    final verz = verzeichnisse.single;
    if (verz.isEmpty || verz.startsWith('/') || verz.contains('..')) return luecke('Aktivität nicht eindeutig im Archiv');
    final xml = dateien['$verz/$modul.xml'];
    if (xml == null) return luecke('Aktivitätsdatei fehlt im Archiv');
    final wurzel = XmlDocument.parse(utf8.decode(xml, allowMalformed: true)).rootElement;
    // `<modul>` steht unter `<activity>`; das Element mit den Feldern ist das erste mit dem Modulnamen.
    final knoten = wurzel.name.local == modul ? wurzel : wurzel.findAllElements(modul).firstOrNull;
    if (knoten == null) return luecke('Aktivitätsdatei nicht lesbar');
    final root = doc.findAllElements('original_wwwroot').firstOrNull?.innerText.trim();
    return QuellTexte({for (final f in felder) f.formular: _kind(knoten, f.element) ?? ''},
        wwwroot: root == null || root.isEmpty ? null : root);
  } on XmlException {
    return luecke('Archiv nicht lesbar');
  }
}

/// Die Editorfelder der Aktivität aus dem Bearbeitungsformular: Feldname -> Text. null, wenn
/// das Formular nicht lesbar ist.
Future<Map<String, String>?> zieltexteLesen(MoodleZugang moodle, int cmid) async {
  final Antwort form;
  try {
    form = await moodle.lesen('/course/modedit.php?update=$cmid');
  } on MoodleFehler {
    return null;
  }
  if (form.status != 200) return null;
  final haupt = hauptformular(html_parser.parse(form.text));
  if (haupt == null) return null;
  return {
    for (final f in haupt.querySelectorAll('textarea[name]'))
      if (f.attributes['name']!.endsWith('[text]')) f.attributes['name']!: f.text,
  };
}

final RegExp _restToken = RegExp(r'\$@[A-Z0-9_*]+@\$');
final RegExp _pluginfile = RegExp(r'/pluginfile\.php/\d+/[^/\s"\x27<>]+/[^/\s"\x27<>]+/(?:\d+/)?');
final RegExp _draftfile = RegExp(r'/draftfile\.php/\d+/user/draft/\d+/');
/// Moodle hängt bei Namensgleichheit im Dateibereich „ (n)“ vor die Endung an; der Text nennt dann
/// den Namen mit Zähler. Ob es dieselbe Datei ist, belegt der Inhaltsvergleich der Anhänge.
final RegExp _zaehler = RegExp(r'(@@PLUGINFILE@@/[^"\x27<>?#\s]*?)%20(?:%28|\()\d+(?:%29|\))(?=\.|["\x27<>?#\s]|$)');

/// Der Text ohne das, was sich beim Wiederherstellen von selbst ändert. [instanzen] sind die
/// Adressen der Quell- und der Zielinstanz (mit Schema, ohne Schrägstrich am Ende).
/// Unbekannte Platzhalter der Sicherung bleiben stehen und sind für den Aufrufer erkennbar
/// ([unbekannterPlatzhalter]).
String textNormalisiert(String roh, {Iterable<String> instanzen = const []}) {
  var t = roh.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // Platzhalter der Sicherung (Quelle) auf die Form im Formular (Ziel) bringen.
  t = t
      .replaceAll(r'$@FILEPHP@$', '@@PLUGINFILE@@')
      .replaceAll(r'$@SLASH@$', '/');
  for (final i in instanzen) {
    final ohneSchema = i.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '').replaceFirst(RegExp(r'/+$'), '');
    if (ohneSchema.isEmpty) continue;
    t = t.replaceAll(RegExp('https?://${RegExp.escape(ohneSchema)}', caseSensitive: false), '');
  }
  t = t
      .replaceAll(_pluginfile, '@@PLUGINFILE@@/')
      .replaceAll(_draftfile, '@@PLUGINFILE@@/')
      .replaceAllMapped(_zaehler, (m) => m.group(1)!);
  // Leerraum zwischen zwei Tags ändert die Darstellung nicht.
  return t.replaceAll(RegExp(r'>\s+<'), '><').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Bleibt nach der Normalisierung ein Platzhalter der Sicherung stehen, den die App nicht auflöst.
bool unbekannterPlatzhalter(String normalisiert) => _restToken.hasMatch(normalisiert);

/// Vergleicht die Texte einer Aktivität. [quelle] aus [quelltexteAus], [ziel] aus
/// [zieltexteLesen] (null: Formular nicht lesbar). Aktivitätsname [titel] nur für den Bericht.
({List<String> befunde, bool abweichend}) vergleicheTexte({
  required String modul,
  required String titel,
  required QuellTexte quelle,
  required Map<String, String>? ziel,
  Iterable<String> zielInstanzen = const [],
}) {
  final befunde = <String>[];
  var abweichend = false;
  final name = '„$titel"';
  if (quelle.luecke != null) {
    return (befunde: ['$name: Prüflücke: ${quelle.luecke}'], abweichend: false);
  }
  if (ziel == null) {
    return (befunde: ['$name: Prüflücke: Bearbeitungsformular nicht lesbar'], abweichend: false);
  }
  final instanzen = [?quelle.wwwroot, ...zielInstanzen];
  for (final f in _felder[modul]!) {
    final q = textNormalisiert(quelle.felder[f.formular] ?? '', instanzen: instanzen);
    final z = ziel[f.formular];
    if (unbekannterPlatzhalter(q)) {
      befunde.add('$name: Prüflücke: Feld „${f.anzeige}" enthält einen Platzhalter der Sicherung, den die App nicht kennt');
    } else if (z == null) {
      if (q.isNotEmpty) befunde.add('$name: Prüflücke: Feld „${f.anzeige}" nicht lesbar');
    } else if (textNormalisiert(z, instanzen: instanzen) != q) {
      abweichend = true;
      befunde.add('$name: Feld „${f.anzeige}" weicht von der Quelle ab');
    }
  }
  final offen = _ungelesen[modul];
  if (offen != null) befunde.add('$name: Prüflücke: $offen nicht verglichen');
  return (befunde: befunde, abweichend: abweichend);
}

/// Prüft die Texte der eindeutig zugeordneten Aktivitäten. Liest nur Quelle und Formulare.
Future<TextPruefung> textePruefen(MoodleZugang moodle, Vorgaenge vorgaenge, Vorgang vg,
    List<WiederhergestellteAktivitaet> aktivitaeten) async {
  final archiv = await sicherungsquelleLesen(vorgaenge, vg);
  final mbz = archiv.mbz;
  if (mbz == null) {
    return TextPruefung(['Prüflücke: ${archiv.grund}; Texte nicht verglichen'], vollstaendig: false);
  }
  final ziel = moodle.basis;
  final zielInstanzen = [if (ziel != null) ziel.origin];
  final befunde = <String>[];
  var abweichend = false;
  for (final a in aktivitaeten) {
    final quelle = quelltexteAus(mbz, modul: a.modul, titel: a.titel);
    vorgaenge.pruefeBindung(vg);
    final texte = quelle.luecke == null ? await zieltexteLesen(moodle, a.cmid) : null;
    final r = vergleicheTexte(
        modul: a.modul, titel: a.titel, quelle: quelle, ziel: texte, zielInstanzen: zielInstanzen);
    befunde.addAll(r.befunde);
    abweichend = abweichend || r.abweichend;
  }
  return TextPruefung(befunde, vollstaendig: befunde.isEmpty && aktivitaeten.isNotEmpty, abweichend: abweichend);
}
