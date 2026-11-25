// Fragensammlungen und Fragen: Werkzeuge fragensammlungen, fragen_lesen,
// frage_lesen, fragen_importieren, kategorie_anlegen, fragetypen,
// stack_xml, coderunner_xml. Eine Frage ändert das allgemeine aendern
// (formular_schreiben.dart) über ihr Bearbeitungsformular.
//
// Anlegen per Moodle-XML-Import, ändern über das Formular: Der Import legt
// IMMER neu an -- es gibt keinen Weg, ein XML als neue Version einer
// vorhandenen Frage einzuspielen. Speichern im Formular erzeugt eine neue
// Version mit NEUER questionid; die alte Nummer zeigt danach auf die alte
// Version. Stabil ist die Sachnummer (idnumber): Sie hängt am
// Fragenbank-Eintrag, nicht an der Version. Tests ziehen standardmäßig die
// neueste Version -- eine Änderung wirkt sofort in jedem Test, der die Frage
// benutzt.
//
// Gelesen wird über den Moodle-XML-Export: vollständig und ohne
// Personendaten (nachgemessen: kein createdby, kein Name). Die Fragenübersicht
// der Sammlung (question/edit.php) zeigt dagegen „Erstellt von" und „Geändert
// von" mit Klarnamen -- die ruft die App nicht auf.

import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

import '../freigabe.dart';
import 'formular.dart';
import 'formular_lesen.dart';
import 'formular_schreiben.dart';
import 'fragen_sicherung.dart';
import 'fragen_xml.dart';
import 'moodle_zugang.dart';

class Kategorie {
  Kategorie(this.wert, this.name, this.anzahl, this.tiefe);

  /// `<kategorieid>,<kontextid>` -- so will es das Import- und Exportformular.
  final String wert;
  final String name;
  final int anzahl;
  final int tiefe;
  int get id => int.parse(wert.split(',').first);
  int? get kontext => int.tryParse(wert.split(',').last);
}

/// Kategorien einer Sammlung. Die Auswahlliste des Importformulars ist die
/// zuverlässigste Quelle: Sie führt die Fragenanzahl mit.
Future<List<Kategorie>> kategorienLesen(MoodleZugang moodle, int sammlung) async {
  final r = await moodle.lesen('/question/bank/importquestions/import.php?cmid=$sammlung');
  final sel = html_parser.parse(r.text).querySelector('select[name="category"]');
  if (sel == null) throw MoodleFehler('Keine Kategorieliste für cmid $sammlung. sammlung muss eine Fragensammlung auf der aktuell angesprochenen Instanz sein. Mit fragensammlungen auf dieser Instanz ermitteln; außerdem die Importberechtigung prüfen.');
  return [
    for (final o in sel.querySelectorAll('option'))
      () {
        final roh = o.text.replaceAll(' ', ' ');
        final tiefe = (roh.length - roh.trimLeft().length) ~/ 3;
        final text = roh.replaceAll(RegExp(r'\s+'), ' ').trim();
        final m = RegExp(r'^(.*?)\s*\((\d+)\)$').firstMatch(text);
        return Kategorie(o.attributes['value'] ?? '', m?.group(1) ?? text, int.tryParse(m?.group(2) ?? '') ?? 0, tiefe);
      }()
  ];
}

Kategorie kategorieWaehlen(List<Kategorie> alle, String? wunsch) {
  if (wunsch == null || wunsch.isEmpty) return alle.first;
  final k = alle.where((k) => k.wert == wunsch || '${k.id}' == wunsch || k.name == wunsch).toList();
  if (k.length != 1) {
    throw MoodleFehler('Kategorie „$wunsch" ${k.isEmpty ? 'gibt es nicht' : 'ist mehrdeutig'}. Vorhanden:\n'
        '${alle.map((k) => '  ${k.id} „${k.name}" (${k.anzahl})').join('\n')}');
  }
  return k.single;
}

/// Eine Kategorie als Moodle-XML exportieren.
Future<String> exportieren(MoodleZugang moodle, int sammlung, Kategorie k) async {
  final f = await formularHolen(moodle, '/question/bank/exportquestions/export.php?cmid=$sammlung');
  setze(f.felder, 'format', 'xml');
  setze(f.felder, 'category', k.wert);
  // Kategorie und Kontext NICHT in die Datei: Beim Import soll die Zielkategorie gelten.
  f.felder.removeWhere((e) => e.key == 'cattofile' || e.key == 'contexttofile');
  final felder = [...f.felder, const MapEntry('submitbutton', '1')];
  final antwort = await moodle.senden(f.aktion, felder);
  final ziel = moodle.umleitungsziel(antwort);
  String? link;
  if (ziel != null && ziel.path.contains('/pluginfile.php/')) {
    link = ziel.toString();
  } else {
    link = html_parser.parse(antwort.text).querySelector('a[href*="pluginfile.php"]')?.attributes['href'];
  }
  if (link == null) throw MoodleFehler('Kein Download in der Exportantwort -- Kategorie leer oder Recht fehlt?');
  final x = await moodle.lesen(link);
  if (!x.text.trimLeft().startsWith('<?xml')) throw MoodleFehler('Der Export lieferte kein XML.');
  return x.text;
}

/// Eine Kategorie einer Sammlung mit ihrem Pfad ([pfad]: Namen von oben nach unten), der Fragenzahl,
/// die Moodles Kategorieliste nennt ([Kategorie.anzahl]), und ihrem Export; [xml] ist bei einer leeren
/// Kategorie null. [exportiert] sind die Fragen, die der Export wirklich enthält.
typedef SammlungsKategorie = ({Kategorie kat, List<String> pfad, String? xml, int exportiert});

/// Liest alle Kategorien einer Sammlung samt Export, für die Sicherung vor dem Löschen der ganzen
/// Sammlung. Eine Frage, die in einem Test benutzt und „gelöscht" wurde, ist in Moodle nur verborgen
/// (auf Moodle 5.1 gemessen): Moodles Kategorieliste zählt sie nicht mit, und der Export der Kategorie
/// liefert sie nicht. Eine Kategorie mit Zahl 0 wird deshalb nicht angefragt und gilt als leer; verborgene
/// Fragen sind nie in der Sicherung. Moodle zerstört sie beim Löschen der Sammlung nicht, sondern verschiebt
/// sie nach kurzer Zeit in eine geteilte Fragensammlung des Kurses, die die Tests weiter benutzen (siehe
/// `_testsLesen` in kurs_aendern.dart). Scheitert der Export einer Kategorie mit Zahl über 0 (etwa weil
/// Moodle keinen Download nennt), bricht das Lesen ab; sie gilt nie stillschweigend als leer.
Future<List<SammlungsKategorie>> sammlungExportieren(MoodleZugang moodle, int sammlung) async {
  final kats = await kategorienLesen(moodle, sammlung);
  final namen = <String>[];
  final aus = <SammlungsKategorie>[];
  for (final k in kats) {
    // Die Einrückung der Liste ist die Tiefe: Der Pfad ist die Kette der Namen bis hierher.
    if (k.tiefe < namen.length) namen.removeRange(k.tiefe, namen.length);
    while (namen.length < k.tiefe) {
      namen.add('');
    }
    namen.add(k.name);
    final xml = k.anzahl == 0 ? null : await exportieren(moodle, sammlung, k);
    aus.add((
      kat: k,
      pfad: List.of(namen),
      xml: xml,
      exportiert: xml == null ? 0 : fragenAusXml(xml).length,
    ));
  }
  return aus;
}

String _sammlungsOrdner(String arbeitsordner, int sammlung) => p.join(arbeitsordner, 'fragen-$sammlung');

// ---------------------------------------------------------------------------
// fragen_lesen
// ---------------------------------------------------------------------------

Future<String> fragenLesen(MoodleZugang moodle, String arbeitsordner,
    {required int sammlung, String? kategorie, bool alle = false, String? idnummer}) async {
  final kats = await kategorienLesen(moodle, sammlung);
  final ordner = _sammlungsOrdner(arbeitsordner, sammlung);
  await Directory(ordner).create(recursive: true);
  final b = StringBuffer('Sammlung cmid $sammlung, Kategorien (id „Name" (Anzahl)):\n');
  for (final k in kats) {
    b.writeln('  ${'  ' * k.tiefe}${k.id} „${k.name}" (${k.anzahl})');
  }
  final ziel = alle ? kats.where((k) => k.anzahl > 0).toList() : [kategorieWaehlen(kats, kategorie)];
  final treffer = <(Kategorie, FrageKurz)>[];
  for (final k in ziel) {
    if (k.anzahl == 0) {
      b.writeln('\nKategorie „${k.name}" ist leer.');
      continue;
    }
    final xml = await exportieren(moodle, sammlung, k);
    final datei = File(p.join(ordner, 'kategorie-${k.id}.xml'));
    await datei.writeAsString(xml, encoding: utf8);
    final fragen = fragenAusXml(xml);
    if (idnummer != null) {
      treffer.addAll([for (final f in fragen) if (f.idnummer == idnummer) (k, f)]);
      continue;
    }
    b.writeln('\nKategorie „${k.name}" (${fragen.length} Fragen) -> ${datei.path}');
    for (final f in fragen) {
      b.writeln('  ${f.zeile()}');
    }
  }
  if (idnummer != null) {
    if (treffer.isEmpty) {
      b.writeln('\nSachnummer $idnummer: nicht gefunden${alle ? '' : ' in dieser Kategorie (alle: true sucht überall)'}.');
    } else if (treffer.length > 1) {
      // Mehrdeutigkeit wird gemeldet, nicht aufgelöst: Die falsche Frage zu
      // ändern ist teurer als eine Rückfrage.
      b.writeln('\nSachnummer $idnummer: MEHRDEUTIG, ${treffer.length} Fragen -- nicht raten, nachfragen:');
      for (final (k, f) in treffer) {
        b.writeln('  in „${k.name}": ${f.zeile()}');
      }
    } else {
      final (k, f) = treffer.single;
      b.writeln('\nSachnummer $idnummer: in „${k.name}", aktuelle questionid ${f.id}\n  ${f.zeile()}\n'
          'Nach einer Änderung ist die questionid eine andere, die Sachnummer nicht.');
    }
  }
  b.writeln('\nEine Frage bearbeiten: frage_lesen(sammlung, frage_id), dann aendern.');
  return b.toString();
}

/// Die Nummern der Fragen namens [name] in der Sammlung, je Frage die der
/// neuesten Version: So viel führt der Export einer Kategorie. Gebraucht,
/// wenn nicht die App gespeichert hat, sondern die Lehrkraft im Browser
/// (_uebergeben, formular_schreiben.dart) -- dann fehlt die Umleitung, die
/// die neue Nummer nennt. Gefragt wird davor und danach: Speichern legt
/// immer eine neue Nummer an, und genau die kommt hinzu, mit oder ohne
/// Sachnummer, auch wenn es den Namen mehrfach gibt. Gesucht wird in allen
/// Kategorien: Das Bearbeitungsformular nennt die Kategorie nicht immer
/// (gemessen: gapselect ohne Feld category).
Future<Set<int>> fragenNamens(MoodleZugang moodle, {required int sammlung, required String name}) async => {
  for (final k in await kategorienLesen(moodle, sammlung))
    if (k.anzahl > 0)
      for (final f in fragenAusXml(await exportieren(moodle, sammlung, k)))
        if (f.name == name && f.id != null) f.id!,
};

// ---------------------------------------------------------------------------
// frage_lesen
// ---------------------------------------------------------------------------

/// Die Sperre des Ordners umfasst das Lesen, das frage.xml-Schreiben und
/// damit auch die Zeit bis zum Ende des Lesens; sonst lösche ein Parallelaufruf den Ordner.
Future<String> frageLesen(MoodleZugang moodle, String arbeitsordner, {required int sammlung, required int frage}) {
  final ziel = Formularziel.frage(sammlung, frage);
  return ordnerSperre(ordnerSchluessel(ziel, arbeitsordner), () => _frageLesenOhneSperre(moodle, arbeitsordner, ziel, sammlung, frage));
}

Future<String> _frageLesenOhneSperre(
    MoodleZugang moodle, String arbeitsordner, Formularziel ziel, int sammlung, int frage) async {
  // Dazu die Frage als XML: vollständig, auch für Typen mit vielen Feldern.
  // Sie geht in den Stand vor dem Austausch, damit der Ergebnisordner nie ohne
  // sie veröffentlicht wird.
  var xmlHinweis = '';
  final g = await formularLesenOhneSperre(moodle, ziel, arbeitsordner,
      vorVeroeffentlichung: (stand, g) => _frageXmlLegen(moodle, stand, g, sammlung, frage, (h) => xmlHinweis = h));
  final z = g.zusammenfassung();
  return '$z\n${xmlHinweis}Speichern erzeugt eine NEUE Version mit neuer questionid; Tests mit '
      '„neueste Version" nutzen sie sofort. Strukturänderungen desselben Typs (andere Antwortzahl, neue Lücken) '
      'gehen über fragen_version_importieren mit bearbeitetem XML. Nur bei Typwechsel oder fehlendem '
      'Versionsimport-Plugin frage_ersetzen verwenden; dabei geht der gemeinsame Verlauf verloren.';
}

Future<void> _frageXmlLegen(
    MoodleZugang moodle, String stand, FormularGelesen g, int sammlung, int frage, void Function(String) hinweis) async {
  var xmlHinweis = '';
  try {
    final s = await moodle.sesskey();
    final r = await moodle.lesen('/question/bank/exporttoxml/exportone.php?id=$frage&cmid=$sammlung&sesskey=$s');
    var xml = r.text;
    if (!xml.trimLeft().startsWith('<?xml')) {
      final link = html_parser.parse(xml).querySelector('a[href*="pluginfile.php"]')?.attributes['href'];
      xml = link == null ? '' : (await moodle.lesen(link)).text;
    }
    if (xml.trimLeft().startsWith('<?xml')) {
      await File(p.join(stand, 'frage.xml')).writeAsString(xml, encoding: utf8);
      // Der Einzelexport lässt die Datensätze einer berechneten Frage weg
      // (gemessen: calculated mit geteilten Datensätzen); vollständig stehen
      // sie im Export ihrer Kategorie.
      xmlHinweis = 'Die Frage als Moodle-XML (nur zum Lesen): frage.xml'
          '${g.modul == 'calculated' ? ' -- ohne ihre Datensätze; vollständig im Export ihrer Kategorie (fragen_lesen)' : ''}\n';
    }
  } on MoodleFehler catch (x) {
    xmlHinweis = 'Einzelexport nicht möglich (${x.meldung}).\n';
  }
  hinweis(xmlHinweis);
}

// ---------------------------------------------------------------------------
// fragen_importieren
// ---------------------------------------------------------------------------

/// Ergebnis eines Imports, für die Nachweise danach (STACK, CodeRunner).
class Importiert {
  Importiert(this.text, this.neu, this.ok, this.xml);
  final String text;
  final List<FrageKurz> neu;
  final bool ok;

  /// Das geprüfte XML, das hochgeladen wurde (Eingabe der Rundlaufprobe).
  final String xml;
}

Future<Importiert> fragenImportieren(MoodleZugang moodle, Freigaben freigaben, String arbeitsordner,
    {required int sammlung, required String kategorie, required String datei}) async {
  final pfad = imArbeitsordner(datei, arbeitsordner);
  final f0 = File(pfad);
  if (!f0.existsSync()) throw MoodleFehler('Datei $pfad gibt es nicht.');
  final (xml, fragen) =
      fragenXmlPruefen(await f0.readAsString(encoding: utf8), dateiordner: p.join(p.dirname(pfad), 'dateien'));

  final kats = await kategorienLesen(moodle, sammlung);
  final k = kategorieWaehlen(kats, kategorie);

  // Eine Freigabe für die ganze Datei, nicht je Frage: Der Import ist ein
  // Vorgang, und er bricht beim ersten Fehler als Ganzes ab. Erst bei
  // Bestätigungen „alle" -- Lernende sehen eine Frage erst in einem Test.
  final ja = await freigaben.anfragen(FreigabeAnfrage(
    titel: '${fragen.length} Frage(n) anlegen?',
    punkte: [
      'In Kategorie „${k.name}" der Fragensammlung cmid $sammlung',
      'Aus ${p.basename(pfad)}; die Fragen sind neu, vorhandene werden nicht ersetzt.',
      for (final f in fragen.take(20)) '${f.typ}: „${f.name}"',
      if (fragen.length > 20) '… und ${fragen.length - 20} weitere',
      'Lernende sehen eine Frage erst, wenn sie in einem Test steht.',
    ],
    vergleich: const [],
    knopf: 'Anlegen',
    ohneEntscheidung: 'wird nichts angelegt',
    ab: Bestaetigungen.alle,
  ));
  if (!ja) {
    throw MoodleFehler('Der Import wurde in der App abgelehnt oder nicht innerhalb von '
        '${freigaben.frist.inMinutes} Minuten freigegeben. Nichts angelegt.');
  }
  return importAusfuehren(moodle, sammlung, k, p.basename(pfad), xml, fragen.length);
}

/// Der Import selbst, nach der Freigabe: hochladen, absenden, nachzählen.
/// Auch für frage_ersetzen, das die Freigabe selbst einholt.
Future<Importiert> importAusfuehren(
    MoodleZugang moodle, int sammlung, Kategorie k, String dateiname, String xml, int erwartet) async {
  final vorherIds = k.anzahl == 0 ? <int>{} : {for (final f in fragenAusXml(await exportieren(moodle, sammlung, k))) f.id};

  Future<String> versuch() async {
    final f = await formularHolen(moodle, '/question/bank/importquestions/import.php?cmid=$sammlung');
    final itemid = wertIn(f.felder, 'newfile');
    if (itemid == null) throw MoodleFehler('Im Importformular fehlt der Entwurfsbereich (newfile).');
    await hochladen(moodle, f, itemid, '/', dateiname, utf8.encode(xml));
    setze(f.felder, 'format', 'xml');
    setze(f.felder, 'category', k.wert);
    // Kategorie aus dem Formular, nicht aus der Datei; bei unpassenden
    // Punkten abbrechen statt runden; beim ersten Fehler aufhören.
    setze(f.felder, 'catfromfile', '0');
    setze(f.felder, 'contextfromfile', '0');
    setze(f.felder, 'matchgrades', 'error');
    setze(f.felder, 'stoponerror', '1');
    final a = await moodle.senden(f.aktion, [...f.felder, const MapEntry('submitbutton', '1')]);
    final d = html_parser.parse(a.text);
    return d
        .querySelectorAll('.alert-danger, .notifyproblem, .errorbox, .error')
        .map((e) => e.text.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((t) => t.isNotEmpty)
        .join(' | ');
  }

  String probleme;
  try {
    probleme = await versuch();
  } on SitzungAbgelaufen {
    probleme = await versuch();
  }
  // Nachzählen ist der eigentliche Nachweis: Moodle meldet Erfolge, die keine sind.
  final nachher = fragenAusXml(await exportieren(moodle, sammlung, k));
  final neu = nachher.where((f) => !vorherIds.contains(f.id)).toList();
  final ok = neu.length == erwartet && probleme.isEmpty;
  final b = StringBuffer()
    ..writeln('${ok ? 'Importiert' : 'Import UNVOLLSTÄNDIG'}: ${neu.length} von $erwartet Fragen in '
        '„${k.name}" (Sammlung cmid $sammlung). nachgezählt: $ok')
    ..writeln([for (final f in neu) '  ${f.zeile()}'].join('\n'));
  if (probleme.isNotEmpty) b.writeln('Moodle meldet: $probleme');
  return Importiert(b.toString(), neu, ok, xml);
}

// ---------------------------------------------------------------------------
// kategorie_anlegen
// ---------------------------------------------------------------------------

const String kategorieFormular = r'qbank_managecategories\form\question_category_edit_form';

/// Legt eine Kategorie IN einer Sammlung an -- nicht die Sammlung selbst; die
/// ist eine Aktivität (`aktivitaet_anlegen`, Typ `qbank`). Die Meldung nennt
/// deshalb die Sammlung mit: Wer „Fragensammlung" sagte und eine Kategorie
/// bekommt, erkennt die Verwechslung nur, wenn das Ziel dabeisteht.
Future<String> kategorieAnlegen(MoodleZugang moodle, Freigaben freigaben,
    {required int sammlung, required String name, String? eltern, String? beschreibung}) async {
  final kats = await kategorienLesen(moodle, sammlung);
  final kontext = kats.first.kontext;
  final elternK = eltern == null ? null : kategorieWaehlen(kats, eltern);
  if (kats.any((k) => k.name == name)) {
    throw MoodleFehler('Eine Kategorie „$name" gibt es in dieser Sammlung schon.');
  }
  // Eine Kategorie ist Gliederung in der Fragensammlung; Lernende sehen sie
  // nie. Freigabe deshalb erst bei Bestätigungen „alle".
  final ja = await freigaben.anfragen(FreigabeAnfrage(
    titel: 'Kategorie anlegen?',
    punkte: [
      'Kategorie „$name" in der Fragensammlung cmid $sammlung'
          '${elternK == null ? '' : ', unter „${elternK.name}"'}',
      'Gliederung der Fragensammlung; Lernende sehen Kategorien nicht.',
    ],
    vergleich: const [],
    knopf: 'Anlegen',
    ohneEntscheidung: 'wird nichts angelegt',
    ab: Bestaetigungen.alle,
  ));
  if (!ja) {
    return 'Nicht angelegt: in der App abgelehnt oder nicht innerhalb von '
        '${freigaben.frist.inMinutes} Minuten freigegeben.';
  }
  final leer = await moodle.dienst('core_form_dynamic_form',
      {'form': kategorieFormular, 'formdata': 'cmid=$sammlung&contextid=$kontext&courseid=0&actiontype=add'});
  final html = (leer is Map ? leer['html'] : null) as String? ?? '';
  final form = html_parser.parse(html).querySelector('form') ?? html_parser.parse(html).body!;
  final felder = formularFelder(form);
  setze(felder, 'name', name);
  if (beschreibung != null) setze(felder, 'info[text]', beschreibung);
  if (elternK != null) setze(felder, 'parent', elternK.wert);
  setze(felder, '_qf__qbank_managecategories_form_question_category_edit_form', '1');
  final daten = felder.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
  final r = await moodle.dienst('core_form_dynamic_form', {'form': kategorieFormular, 'formdata': daten});
  final nachher = await kategorienLesen(moodle, sammlung);
  final neu = nachher.where((k) => k.name == name).toList();
  final ok = r is Map && r['submitted'] == true && neu.length == 1;
  return '${ok ? 'Angelegt' : 'NICHT angelegt'}: Kategorie „$name"${neu.isEmpty ? '' : ' (id ${neu.single.id})'}'
      '${elternK == null ? '' : ' unter „${elternK.name}"'} in Sammlung cmid $sammlung. verified: $ok';
}

// ---------------------------------------------------------------------------
// fragetypen: STACK-Version und CodeRunner-Prototypen der Instanz
// ---------------------------------------------------------------------------

/// Die STACK-Version der Instanz, aus dem Formular einer neuen STACK-Frage --
/// die einzige Quelle ohne Administrationsrechte. Sie gehört in jede neue
/// Frage: Eine ältere Nummer markiert die Frage in STACK dauerhaft als
/// nachbesserungsbedürftig.
Future<String?> stackVersion(MoodleZugang moodle, int sammlung) async {
  final k = (await kategorienLesen(moodle, sammlung)).first;
  final r = await moodle.lesen('/question/bank/editquestion/question.php?cmid=$sammlung&qtype=stack'
      '&category=${Uri.encodeQueryComponent(k.wert)}');
  return RegExp(r'name="stackversion"[^>]*value="(\d+)"').firstMatch(r.text)?.group(1) ??
      RegExp(r'value="(\d+)"[^>]*name="stackversion"').firstMatch(r.text)?.group(1);
}

Future<String> fragetypen(MoodleZugang moodle, int sammlung) async {
  final b = StringBuffer()
    ..writeln('Anlegbar ist jeder Typ, den diese Moodle-Instanz kennt, wenn er die Rundlaufprobe besteht (Export und '
        'Vergleich, Formular, Vorschau, unverändert als Entwurf speichern). Prototypen nie. Gemessenes XML und '
        'Hilfen gibt es für: ${[...kernAnlegbar.where((t) => t != 'matching' && t != 'cloze'), ...zusatzAnlegbar].join(", ")}; '
        'sonst eine Beispielfrage aus der Fragensammlung exportieren und daran bauen.');
  try {
    final v = await stackVersion(moodle, sammlung);
    b.writeln('STACK: ${v == null ? 'nicht gefunden (nicht installiert?)' : 'Version $v'}');
  } on MoodleFehler catch (x) {
    b.writeln('STACK: nicht abrufbar (${x.meldung})');
  }
  try {
    final k = (await kategorienLesen(moodle, sammlung)).first;
    final r = await moodle.lesen('/question/bank/editquestion/question.php?cmid=$sammlung&qtype=coderunner'
        '&category=${Uri.encodeQueryComponent(k.wert)}');
    final sel = html_parser.parse(r.text).querySelector('[name="coderunnertype"]');
    if (sel == null) {
      b.writeln('CodeRunner: nicht installiert.');
    } else {
      final alle = [
        for (final o in sel.querySelectorAll('option'))
          if ((o.attributes['value'] ?? '').isNotEmpty && o.attributes['value'] != 'Undefined') o.attributes['value']!
      ];
      b.writeln('CodeRunner-Prototypen: gemessen ${alle.where(coderunnerGemessen.contains).join(", ")}; '
          'ungemessen ${alle.where((x) => !coderunnerGemessen.contains(x)).join(", ")} '
          '(gehen wahrscheinlich genauso, sind aber nicht nachgesehen).');
    }
  } on MoodleFehler catch (x) {
    b.writeln('CodeRunner: nicht abrufbar (${x.meldung})');
  }
  return b.toString();
}

// ---------------------------------------------------------------------------
// stack_xml und coderunner_xml: bauen, als Datei ablegen
// ---------------------------------------------------------------------------

Map<String, List<int>> _dateienIn(String ordner) {
  final d = Directory(p.join(ordner, 'dateien'));
  if (!d.existsSync()) return const {};
  return {for (final f in d.listSync().whereType<File>()) p.basename(f.path): f.readAsBytesSync()};
}

Future<String> xmlBauen(MoodleZugang moodle, String arbeitsordner,
    {required String art, required List<Map<String, Object?>> fragen, required String datei, int? sammlung}) async {
  final pfad = imArbeitsordner(datei, arbeitsordner);
  if (!pfad.toLowerCase().endsWith('.xml')) throw MoodleFehler('datei muss auf .xml enden.');
  final dateien = _dateienIn(p.dirname(pfad));
  final teile = <String>[];
  if (art == 'stack') {
    if (sammlung == null) throw MoodleFehler('sammlung fehlt: Die STACK-Version kommt aus der Instanz.');
    final v = await stackVersion(moodle, sammlung);
    if (v == null) throw MoodleFehler('STACK-Version nicht gefunden -- ist STACK installiert?');
    for (final f in fragen) {
      teile.add(stackXml(f, version: v, dateien: dateien));
    }
  } else {
    for (final f in fragen) {
      teile.add(coderunnerXml(f, dateien: dateien));
    }
  }
  final xml = quizXml(teile);
  fragenXmlPruefen(xml, dateiordner: p.join(p.dirname(pfad), 'dateien'));
  await File(pfad).parent.create(recursive: true);
  await File(pfad).writeAsString(xml, encoding: utf8);
  return 'Gebaut und geprüft: ${fragen.length} ${art == 'stack' ? 'STACK' : 'CodeRunner'}-Frage(n) in $pfad. '
      'Anlegen mit fragen_importieren(sammlung, kategorie, datei).';
}

// ---------------------------------------------------------------------------
// Nachweise nach dem Import
// ---------------------------------------------------------------------------

/// STACK-Fragen: Fragetests laufen lassen. CodeRunner-Fragen: einmal über das
/// Formular speichern -- nur dort schickt Moodle die Musterlösung durch die
/// Sandbox (gemessen am 10.09.2026: Der Import nahm eine falsche Musterlösung
/// klaglos an, erst das Speichern meldete „Erwartet 5, Erhalten -1").
///
/// [ok] heißt: jeder Nachweis bestanden. [neueIds]: Das Speichern einer
/// CodeRunner-Frage legt eine neue Version an; hier steht, welche Nummer
/// danach gilt (alte -> neue).
Future<({String text, bool ok, Map<int, int> neueIds})> importNachweise(MoodleZugang moodle, int sammlung,
    List<FrageKurz> neu, Future<String> Function(int frage) stackTesten) async {
  final b = StringBuffer();
  var ok = true;
  final neueIds = <int, int>{};
  for (final f in neu.where((f) => f.typ == 'stack' && f.id != null)) {
    final bericht = await stackTesten(f.id!);
    // Die Zeile „verified: …" setzt stackTestBericht (stack.dart).
    if (!bericht.contains('verified: true')) ok = false;
    b.writeln('\nNachweis STACK „${f.name}":\n$bericht');
  }
  for (final f in neu.where((f) => f.typ == 'coderunner' && f.id != null)) {
    try {
      final form = await formularHolen(moodle, '/question/bank/editquestion/question.php?cmid=$sammlung&id=${f.id}');
      final antwort = await absenden(moodle, form, knoepfe: const ['submitbutton']);
      final id = int.tryParse(moodle.umleitungsziel(antwort)?.queryParameters['lastchanged'] ?? '');
      if (id != null) neueIds[f.id!] = id;
      b.writeln('\nNachweis CodeRunner „${f.name}": Musterlösung besteht alle Testfälle (über das Formular '
          'gespeichert, neue Version${id == null ? '' : ' $id'}). geprueft: true');
    } on MoodleFehler catch (x) {
      ok = false;
      b.writeln('\nNachweis CodeRunner „${f.name}": NICHT bestanden -- ${x.meldung}. geprueft: false. '
          'Musterlösung oder erwartete Ausgabe nachbessern (frage_lesen, aendern).');
    }
  }
  return (text: b.toString(), ok: ok, neueIds: neueIds);
}

// ---------------------------------------------------------------------------
// fragen_loeschen
// ---------------------------------------------------------------------------

/// Eine Frage einzeln als Moodle-XML, oder die Fehlerseite, mit der Moodle
/// den Export ablehnt.
Future<({String? xml, String? fehlercode, String meldung})> frageExport(
    MoodleZugang moodle, int sammlung, int frage) async {
  final s = await moodle.sesskey();
  final r = await moodle.lesen('/question/bank/exporttoxml/exportone.php?id=$frage&cmid=$sammlung&sesskey=$s');
  var text = r.text;
  if (!text.trimLeft().startsWith('<?xml')) {
    final link = html_parser.parse(text).querySelector('a[href*="pluginfile.php"]')?.attributes['href'];
    if (link != null) text = (await moodle.lesen(link)).text;
  }
  if (text.trimLeft().startsWith('<?xml')) return (xml: text, fehlercode: null, meldung: '');
  // Moodles Fehlerseite: die Meldung und, im Verweis auf die Doku
  // (…/error/<komponente>/<code>), der Fehlercode.
  final d = html_parser.parse(text);
  final meldung = (d.querySelector('.errormessage') ?? d.querySelector('#region-main .alert'))?.text.trim() ?? '';
  final doku = d.querySelectorAll('a[href*="/error/"]').map((a) => a.attributes['href'] ?? '').firstOrNull;
  final code = doku == null ? null : Uri.tryParse(doku)?.pathSegments.lastOrNull;
  return (xml: null, fehlercode: code, meldung: meldung.replaceAll(RegExp(r'\s+'), ' '));
}

/// Die Fehlercodes, mit denen Moodle den Export einer Frage ablehnt, die es
/// nicht mehr gibt. Nur sie zählen beim Zurücklesen als „gelöscht"; jede
/// andere Ablehnung (etwa ein fehlendes Recht) heißt: unklar.
const _frageFehlt = {'invalidrecord', 'invalidrecordunknown', 'questiondoesnotexist'};

/// Wie viele Fragen ein Aufruf löschen darf: Jede bekommt im Dialog einen
/// eigenen Haken, und die Lehrkraft muss alle lesen können.
const loeschenHoechstzahl = 25;

/// Löscht Fragen einer Sammlung mit allen Versionen, so wie die
/// Fragensammlung es anbietet: Rückfrage von delete.php holen, ihr Formular
/// nach der Freigabe absenden, wie es dasteht. Steckt eine Frage in einem
/// Test, löscht Moodle sie nicht, sondern verbirgt sie nur; das Zurücklesen
/// meldet das.
///
/// Fragt auf jeder Stufe (E20), jede Frage einzeln mit Haken. Vor dem
/// Löschen liegt die aktuelle Version jeder Frage als XML in
/// [sicherungsOrdner] (fragen_sicherung.dart); lässt sich eine Frage nicht
/// exportieren oder die Datei nicht schreiben, wird nichts gelöscht.
///
/// Vor allem anderen wird jede Frage einzeln exportiert und ihr Name gegen
/// den genannten geprüft -- eine vertauschte Nummer löscht so nichts.
Future<String> fragenLoeschen(MoodleZugang moodle, Freigaben freigaben, String arbeitsordner,
    {required int sammlung, required List<(int, String)> fragen, required String sicherungsOrdner}) async {
  if (fragen.length > loeschenHoechstzahl) {
    throw MoodleFehler('Höchstens $loeschenHoechstzahl Fragen je Aufruf, damit die Lehrkraft jede einzeln prüfen '
        'kann; die Fragen auf mehrere Aufrufe verteilen. Nichts gelöscht.');
  }
  final geprueft = await loeschenPruefen(moodle, sammlung, fragen);
  final gefunden = [for (final g in geprueft) g.frage];
  final r = await _loeschRueckfrage(moodle, arbeitsordner, sammlung, gefunden);
  final benutzung = fragenInBenutzung(r.zeilen, gefunden);

  // Die Sicherung entsteht vor der Freigabe, damit der Dialog ihren Ort nennt;
  // sie wird vor dem Löschen noch einmal gegen den Stand geprüft.
  final sicherung = await fragenSichern(
      sicherungsOrdner, sammlung, [for (final g in geprueft) (id: g.frage.id!, xml: g.xml)]);
  void verwerfen() {
    final d = File(sicherung);
    if (d.existsSync()) d.deleteSync();
  }

  bool ja;
  try {
    ja = await freigaben.anfragen(FreigabeAnfrage(
      titel: fragen.length == 1 ? 'Frage endgültig löschen?' : '${fragen.length} Fragen endgültig löschen?',
      punkte: [
        'Aus der Fragensammlung cmid $sammlung, jeweils mit allen Versionen:',
        for (final f in gefunden) '„${f.name}" (${f.typ}, questionid ${f.id}${f.idnummer == null ? '' : ', ${f.idnummer}'})',
        'Vorher gesichert als XML: $sicherung -- gesichert ist die aktuelle Version jeder Frage, nicht ihr '
            'Verlauf. Zurück kommt sie mit fragen_importieren.',
        'Steckt eine Frage in einem Test, löscht Moodle sie nicht, sondern verbirgt sie nur.',
        if (r.hinweis != null && r.hinweis!.isNotEmpty) 'Moodle fragt: ${r.hinweis}',
      ],
      vergleich: const [],
      knopf: 'Löschen',
      // Löschen fragt auf jeder Stufe, und hier jede Frage einzeln (E20).
      ab: Bestaetigungen.keine,
      abhaken: [
        for (final f in gefunden)
          'Ich habe geprüft: „${f.name}" (${f.typ}, questionid ${f.id}${f.idnummer == null ? '' : ', ${f.idnummer}'}) '
              '${benutzung.contains(f.id) ? 'steckt in einem Test; Moodle verbirgt sie nur und löscht sie nicht.' : 'wird mit allen Versionen endgültig gelöscht.'}',
      ],
    ));
    if (ja) {
      // Die Freigabe darf lange offen gewesen sein: Was freigegeben wurde,
      // muss das sein, was jetzt gelöscht würde (A3).
      try {
        final frisch = await loeschenPruefen(moodle, sammlung, fragen);
        for (var i = 0; i < frisch.length; i++) {
          if (frisch[i].xml != geprueft[i].xml) {
            throw MoodleFehler('Frage ${frisch[i].frage.id} „${frisch[i].frage.name}" ist nicht mehr, wie sie war');
          }
        }
      } on MoodleFehler catch (e) {
        throw MoodleFehler('Abgebrochen, nichts gelöscht: Seit der Freigabe hat sich etwas geändert (${e.meldung}). '
            'Neu lesen und neu freigeben lassen.');
      }
    }
  } catch (_) {
    verwerfen();
    rethrow;
  }
  if (!ja) {
    verwerfen();
    return 'Nicht gelöscht: in der App abgelehnt oder nicht rechtzeitig freigegeben. '
        'Die Rückfrage von Moodle liegt unter ${r.seite}.';
  }
  final (b, alleWeg) = await _loeschAbsenden(moodle, sammlung, gefunden, r, inBenutzung: benutzung);
  return '${alleWeg ? 'Gelöscht' : 'Nicht alles gelöscht'}: ${fragen.length} Frage(n) aus Sammlung $sammlung. '
      'verified: $alleWeg\nSicherung (aktuelle Version jeder Frage, vor dem Löschen angelegt): $sicherung\n$b';
}

/// Welche der Fragen laut Moodles Rückfrage in Benutzung sind. Gemessen auf
/// Moodle 5.1 (deutsche Oberfläche): Die Rückfrage steht in `#modal-body`,
/// jede Version in einer Zeile, getrennt mit `<br />`, als „Name v1"; Moodle
/// setzt vor jede benutzte Version ein `* `. Am Ende steht, ebenfalls mit
/// `* `, der Erklärsatz „* Fragen, die in Verwendung sind …", der zu keiner Frage
/// passt. Die ältere Schreibweise „Name (Version n)" wird weiter erkannt.
/// Die Zuordnung läuft über den ganzen Namen vor dem Versionszusatz; Fragen mit
/// gleichem Namen lassen sich so nicht trennen, dann gelten vorsichtig beide als
/// benutzt. Fehlt die Liste, gilt keine Frage als benutzt, und das Zurücklesen
/// entscheidet.
Set<int?> fragenInBenutzung(List<String> zeilen, List<FrageKurz> fragen) {
  final aus = <int?>{};
  for (final z in zeilen) {
    if (!z.startsWith('* ')) continue;
    final text = z.substring(2).trim();
    // Nur der Name davor zählt, damit „Frage" nicht „Frage 2" mitmeint.
    final name = RegExp(r'^(.*?)\s*(?:v\d+|\(Version\s*\d+\))$').firstMatch(text)?.group(1) ?? text;
    for (final f in fragen) {
      if (name == f.name.trim()) aus.add(f.id);
    }
  }
  return aus;
}

/// Exportiert jede genannte Frage einzeln und prüft ihren Namen; schreibt
/// nichts. Gibt die gefundenen Fragen in der genannten Reihenfolge, mit
/// ihrem Export (für die Sicherung).
Future<List<({FrageKurz frage, String xml})>> loeschenPruefen(
    MoodleZugang moodle, int sammlung, List<(int, String)> fragen) async {
  if (fragen.isEmpty) throw MoodleFehler('Keine Fragen genannt.');
  final ids = [for (final (id, _) in fragen) id];
  if (ids.toSet().length != ids.length) throw MoodleFehler('Eine Frage ist doppelt genannt.');
  final gefunden = <({FrageKurz frage, String xml})>[];
  for (final (id, name) in fragen) {
    final e = await frageExport(moodle, sammlung, id);
    final f = e.xml == null ? null : fragenAusXml(e.xml!).where((x) => x.id == id).firstOrNull;
    if (f == null) {
      throw MoodleFehler('Abgebrochen, nichts gelöscht: Frage $id ist in Sammlung $sammlung nicht zu finden '
          'oder lässt sich nicht exportieren${e.meldung.isEmpty ? '' : ' (Moodle: ${e.meldung})'}. Ohne Export '
          'gibt es keine Sicherung, und ohne Sicherung löscht die App nicht (verborgene Fragen lassen sich nicht '
          'exportieren). Nummern mit fragen_lesen prüfen.');
    }
    nameBestaetigen(name, f.name, 'Frage $id');
    gefunden.add((frage: f, xml: e.xml!));
  }
  // Der Einzelexport nimmt jede Version und prüft die Sammlung nicht: Eine ältere Version
  // würde als „aktuelle" gesichert, eine Frage aus einer anderen Sammlung gelöscht, obwohl
  // `sammlung` etwas anderes sagt. Gelöscht wird nur, was der Export der Kategorien dieser
  // Sammlung als neueste Version zeigt.
  final kategorien = await kategorienLesen(moodle, sammlung);
  final aktuell = <int?>{};
  for (final k in kategorien) {
    if (k.anzahl == 0) continue;
    aktuell.addAll(fragenAusXml(await exportieren(moodle, sammlung, k)).map((x) => x.id));
  }
  for (final g in gefunden) {
    if (!aktuell.contains(g.frage.id)) {
      throw MoodleFehler('Abgebrochen, nichts gelöscht: Frage ${g.frage.id} „${g.frage.name}" ist nicht die neueste '
          'Version einer Frage in Sammlung $sammlung (ältere Version oder andere Sammlung). Gebraucht wird die '
          'aktuelle questionid aus fragen_lesen dieser Sammlung.');
    }
  }
  return gefunden;
}

/// Moodles Rückfrage zum Löschen: ihr Formular oder ihr Bestätigungslink und
/// was sie zur Auswahl sagt. Die Rückfrage ändert nichts.
typedef _Rueckfrage = ({Uri adresse, dom.Element? form, Uri? link, String? hinweis, String seite, List<String> zeilen});

Future<_Rueckfrage> _loeschRueckfrage(
    MoodleZugang moodle, String arbeitsordner, int sammlung, List<FrageKurz> fragen,
    {bool alleVersionen = true}) async {
  final ids = [for (final f in fragen) f.id!];
  // Die Rückfrage liegt danach im Arbeitsordner, damit sich nachsehen lässt,
  // was Moodle gefragt hat.
  final ordner = _sammlungsOrdner(arbeitsordner, sammlung);
  await Directory(ordner).create(recursive: true);
  // Die Auswahl wie das Formular der Sammlung: q<id>=1 je Frage. returnurl
  // ist Pflicht, sonst bricht Moodle 5.1 die Rückfrage mit einem Fehler ab;
  // aufgerufen wird sie nicht (moodle_zugang.dart, _loeschRueckfrage).
  final zurueck = Uri.encodeQueryComponent('/question/edit.php?cmid=$sammlung');
  final r = await moodle.lesen('/question/bank/deletequestion/delete.php?cmid=$sammlung&deleteselected=1'
      '&deleteall=${alleVersionen ? 1 : 0}&returnurl=$zurueck&${ids.map((i) => 'q$i=1').join('&')}');
  final seite = File(p.join(ordner, 'loeschen-rueckfrage.html'));
  await seite.writeAsString(r.text, encoding: utf8);
  final doc = html_parser.parse(r.text);
  final form = doc
      .querySelectorAll('form')
      .where((f) => f.querySelector('input[name="confirm"]') != null)
      .firstOrNull;
  final link = doc
      .querySelectorAll('a[href*="deletequestion/delete.php"]')
      .map((a) => r.adresse.resolve(a.attributes['href'] ?? ''))
      .where((u) => u.queryParameters.containsKey('confirm'))
      .firstOrNull;
  if (form == null && link == null) {
    throw MoodleFehler('Moodle hat nicht nach einer Bestätigung gefragt, nichts gelöscht. Fehlt das Recht? '
        'Die Antwort liegt unter ${seite.path}.');
  }
  // Was die Bestätigung löschen würde, muss genau das Genannte sein.
  final bestaetigt = form != null
      ? form.querySelector('input[name="deleteselected"]')?.attributes['value']
      : link!.queryParameters['deleteselected'];
  final bestaetigtIds = (bestaetigt ?? '').split(',').map((x) => int.tryParse(x.trim())).toSet();
  if (bestaetigtIds.length != ids.length || !bestaetigtIds.containsAll(ids)) {
    throw MoodleFehler('Abgebrochen, nichts gelöscht: Moodles Bestätigung nennt andere Fragen ($bestaetigt) als '
        'die genannten (${ids.join(',')}). Die Rückfrage liegt unter ${seite.path}.');
  }
  // Was Moodle zur Auswahl sagt, etwa zu Fragen in Tests, mit in die Freigabe.
  final hinweis = (doc.querySelector('#modal-body') ?? doc.querySelector('.confirmation-message') ??
          doc.querySelector('#region-main .box'))
      ?.text
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // Moodle trennt die Versionen mit <br />; das Zählen und Erkennen der benutzten
  // Versionen braucht die Zeilen einzeln (der flache Text oben verliert sie).
  final zeilen = [
    for (final t in (doc.querySelector('#modal-body')?.innerHtml ?? '').split(RegExp(r'<br\s*/?>')))
      html_parser.parseFragment(t).text?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '',
  ].where((z) => z.isNotEmpty).toList();
  return (adresse: r.adresse, form: form, link: link, hinweis: hinweis, seite: seite.path, zeilen: zeilen);
}

/// Sendet die Rückfrage ab und liest jede Frage nach. Gibt je Frage eine
/// Zeile und ob alle wirklich weg sind.
Future<(String, bool)> _loeschAbsenden(
    MoodleZugang moodle, int sammlung, List<FrageKurz> fragen, _Rueckfrage r,
    {Set<int?> inBenutzung = const {}}) async {
  // Absenden, wie Moodle es anbietet. Der Umleitung danach (auf die
  // Fragenübersicht, die Klarnamen zeigt) folgt die App nicht.
  final form = r.form;
  if (form != null) {
    final felder = <MapEntry<String, String>>[
      for (final i in form.querySelectorAll('input[type="hidden"]'))
        if ((i.attributes['name'] ?? '').isNotEmpty) MapEntry(i.attributes['name']!, i.attributes['value'] ?? ''),
    ];
    final ziel = r.adresse.resolve(form.attributes['action'] ?? '');
    if ((form.attributes['method'] ?? 'get').toLowerCase() == 'post') {
      await moodle.senden(ziel.hasQuery ? '${ziel.path}?${ziel.query}' : ziel.path, felder);
    } else {
      await moodle.aufrufen(ziel.replace(queryParameters: {for (final e in felder) e.key: e.value}).toString());
    }
  } else {
    await moodle.aufrufen('${r.link!.path}?${r.link!.query}');
  }

  final b = StringBuffer();
  var alleWeg = true;
  // Gemessen auf Moodle 5.1: Eine benutzte Frage verbirgt Moodle nur. Sie fehlt dann
  // im Export ihrer Kategorie und in der Fragenliste, lässt sich aber weiter einzeln
  // nach id exportieren. Das Urteil „nur verborgen" braucht deshalb beides, und die
  // Kategorien werden nur gelesen, wenn eine benutzte Frage noch einzeln zu holen ist.
  Set<int?>? inKategorien;
  Future<Set<int?>> kategorieFragen() async {
    final aus = <int?>{};
    for (final k in await kategorienLesen(moodle, sammlung)) {
      if (k.anzahl == 0) continue;
      aus.addAll(fragenAusXml(await exportieren(moodle, sammlung, k)).map((x) => x.id));
    }
    return aus;
  }

  for (final f in fragen) {
    final e = await frageExport(moodle, sammlung, f.id!);
    if (e.xml == null && _frageFehlt.contains(e.fehlercode)) {
      b.writeln('  gelöscht: „${f.name}" (${f.id})');
    } else if (e.xml == null && inBenutzung.contains(f.id)) {
      // Nicht gemessen: ob Moodle den Einzelexport einer verborgenen Frage je ablehnt (auf
      // Moodle 5.1 liefert er sie). Hier zählt, dass sie laut Rückfrage benutzt war und der
      // Export nicht mehr „gibt es nicht" sagt; das gilt als unklar, nicht als erwartetes Ergebnis.
      alleWeg = false;
      b.writeln('  nur verborgen: „${f.name}" (${f.id}) -- steckt in einem Test, Moodle hat sie nicht gelöscht, '
          'sondern verborgen (Export abgelehnt mit ${e.fehlercode ?? 'unbekanntem Fehler'}).');
    } else if (e.xml != null && inBenutzung.contains(f.id) && !(inKategorien ??= await kategorieFragen()).contains(f.id)) {
      b.writeln('  nur verborgen: „${f.name}" (${f.id}) -- steckt in einem Test, Moodle hat sie wie angekündigt '
          'nicht gelöscht, sondern in der Fragensammlung ausgeblendet.');
    } else if (e.xml != null) {
      alleWeg = false;
      b.writeln('  NOCH DA: „${f.name}" (${f.id}) -- ${inBenutzung.contains(f.id) ? 'steckt in einem Test und steht noch in ihrer Kategorie, ist also nicht einmal verborgen' : 'nicht als benutzt gemeldet und trotzdem nicht gelöscht'}.');
    } else {
      alleWeg = false;
      b.writeln('  UNKLAR: „${f.name}" (${f.id}) -- Export abgelehnt mit ${e.fehlercode ?? 'unbekanntem Fehler'}'
          '${e.meldung.isEmpty ? '' : ' (${e.meldung})'}');
    }
  }
  return (b.toString(), alleWeg);
}

/// Löscht bereits geprüfte Fragen ohne eigene Freigabe -- für frage_ersetzen,
/// dessen Freigabe das Löschen schon zeigt. Moodles Rückfrage wird erst jetzt
/// geholt, weil sie davon abhängt, ob die Frage noch in einem Test steckt.
///
/// Mit [alleVersionen] false wählt die Rückfrage nur die genannte Version
/// (`deleteall=0`), nicht den ganzen Fragenbank-Eintrag mit seinem Verlauf --
/// so löscht die Rundlaufprobe (rundlaufprobe.dart) ihre Probeversion.
Future<(String, bool)> loeschenOhneFreigabe(
        MoodleZugang moodle, String arbeitsordner, int sammlung, List<FrageKurz> fragen,
        {bool alleVersionen = true}) async =>
    _loeschAbsenden(
        moodle, sammlung, fragen, await _loeschRueckfrage(moodle, arbeitsordner, sammlung, fragen, alleVersionen: alleVersionen));
