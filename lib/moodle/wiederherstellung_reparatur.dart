// Fehlende oder abweichende Anhänge einer wiederhergestellten Aktivität reparieren
// (Werkzeug anhaenge_reparieren; E2, E4, E17, E20, A3).
//
// Die Anhangsprüfung (wiederherstellung_anhaenge.dart) vergleicht die Quellaufnahme
// der Wiederherstellung mit dem Bearbeitungsformular der Aktivität und schreibt nie.
// Die Reparatur ist ein eigener Schritt mit eigener Freigabe:
//
//   1. Zuordnung: Vorgang, Kurs, Nummer und Name der Aktivität müssen zusammenpassen,
//      und die Aktivität muss in der Quelle wie im Kurs eindeutig sein.
//   2. Plan: Je Datei der Quelle, die im Ziel fehlt oder im Inhalt (SHA-1) abweicht und
//      sich eindeutig einer Stelle zuordnen lässt, ein Eintrag. Alles andere (fremde,
//      mehrdeutige, unbekannte, nicht lesbare Ziele) bleibt unangetastet und steht
//      als Befund in der Antwort.
//   3. Die Reparaturdateien kommen ausschließlich aus dem gelesenen Ordner der Aktivität
//      im Arbeitsordner (`dateien/<name>`, `bereiche/<feld>/<pfad>`), und ihr Inhalt muss
//      genau der Quellaufnahme entsprechen (SHA-1). Eine Datei, die nicht passt, bricht ab,
//      bevor etwas geschieht; die Meldung nennt, was fehlt.
//   4. Freigabe wie bei aendern (gleiche Stufe, gleiche Sperre des Ordners): Die Übersicht
//      nennt je Datei Name, Ort und Aktion. Danach prüft die App Moodle und den Ordner
//      erneut und schreibt nur, wenn alles noch dem Freigegebenen entspricht.
//   5. Geschrieben wird über den Weg von aendern (Entwurfsbereich, Formular, Rückleseprobe,
//      Prüfung des Stands beim Lesen); es kommt keine Adresse zur Positivliste dazu. Der
//      Ordner darf nichts anderes ändern: weder Text noch Einstellungen noch andere Dateien,
//      und nichts wird gelöscht.
//   6. Rücklesen: Die Anhangsprüfung läuft noch einmal. `verified` gilt nur, wenn die
//      Rückleseprobe von aendern bestanden ist und jede reparierte Datei im Ziel mit dem
//      Inhalt der Quelle übereinstimmt.
//
// Nicht Teil der Reparatur: leere Verzeichnisse im Dateimanager, Dubletten löschen,
// Verweise im Text ändern, Dateien, die nur über Adressen außerhalb von /pluginfile.php
// und /draftfile.php eingebunden sind. Das bleibt eine Prüflücke und wird genannt.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../freigabe.dart';
import 'formular_lesen.dart' show Formularziel, Zielart, ordnerSperre, ordnerSchluessel;
import 'formular_schreiben.dart';
import 'kurs.dart';
import 'moodle_zugang.dart';
import 'sicherung.dart';
import 'wiederherstellung_anhaenge.dart';
import 'wiederherstellung_regeln.dart' show WiederherstellungStand;

/// Eine Datei, die die Reparatur ergänzt oder ersetzt.
class ReparaturEintrag {
  ReparaturEintrag({
    required this.schluessel,
    required this.name,
    required this.dateibereich,
    required this.feld,
    required this.pfad,
    required this.ersetzen,
    required this.sha1,
    required this.ist,
    this.felder = const [],
  });

  /// Stabile Kennung der Quelldatei (unabhängig vom Namen im Ziel), um vorher und nachher zu vergleichen.
  final String schluessel;

  /// Dateiname im Ziel (bei einem Moodle-Zähler „bild (1).png“ der des Ziels, nicht der der Quelle).
  final String name;

  /// Dateibereich ([feld] ist dann sein Feldname) oder im Text eingebundene Datei ([felder]).
  final bool dateibereich;
  final String feld;

  /// Pfad im Dateibereich („/“, „/Unterordner/“); bei einer eingebundenen Datei „/“.
  final String pfad;

  /// ersetzen: die Datei gibt es im Ziel, mit anderem Inhalt oder nicht abrufbar; sonst hinzufügen.
  final bool ersetzen;

  /// SHA-1 der Quelle: Das muss die Reparaturdatei haben.
  final String sha1;

  /// Was Moodle jetzt zeigt, als Text („fehlt“, „HTTP 404“, „Inhalt weicht ab“).
  final String ist;

  /// Die Editorfelder, deren Text die Datei einbindet.
  final List<String> felder;

  /// Wo die Reparaturdatei im gelesenen Ordner liegt, relativ zu ihm.
  String get lokal => dateibereich ? 'bereiche/$feld$pfad$name' : 'dateien/$name';

  String get ort => dateibereich ? 'Dateibereich $feld${pfad == '/' ? '' : ', Ordner $pfad'}' : 'Text im Feld ${felder.join(', ')}';

  String get zeile =>
      '„${dateibereich ? '${pfad.substring(1)}$name' : name}" ($ort): ${ersetzen ? 'wird ersetzt' : 'wird hinzugefügt'}'
      ' (jetzt in Moodle: $ist)';
}

/// Was die Reparatur tun würde und was sie nicht anfasst.
class ReparaturPlan {
  ReparaturPlan(this.eintraege, this.offen, this.inOrdnung, this.signatur);

  final List<ReparaturEintrag> eintraege;

  /// Befunde, die die Reparatur nicht behebt: Kennung der Quelldatei und Text.
  final List<({String schluessel, String text})> offen;

  /// Wie viele Dateien der Quelle schon übereinstimmen.
  final int inOrdnung;

  /// Zusammenfassung des Plans samt Zustand in Moodle: Ändert sie sich zwischen Freigabe und Schreiben, wird nichts geschrieben.
  final String signatur;
}

/// Leitet aus Quelle und Ziel ab, was die Reparatur eindeutig tun kann. Rein: liest und schreibt nichts.
ReparaturPlan reparaturPlanen({required List<QuellDateiOrt> quelle, required ZielAufnahme ziel}) {
  final eintraege = <ReparaturEintrag>[];
  final offen = <({String schluessel, String text})>[];
  var inOrdnung = 0;

  // Quellname -> Inhalte (SHA-1) in der Quelle.
  final namen = <String, Set<String>>{};
  for (final q in quelle) {
    namen.putIfAbsent(q.name, () => {}).add(q.sha1);
  }
  final zaehler = RegExp(r'^(.*) \((\d+)\)(\.[^.]*)?$');
  String? quellname(String name) {
    if (namen.containsKey(name)) return name;
    final m = zaehler.firstMatch(name);
    if (m == null) return null;
    final grund = '${m.group(1)}${m.group(3) ?? ''}';
    return namen.containsKey(grund) ? grund : null;
  }

  // Im Text eingebundene Dateien: je Name ein Eintrag.
  final eingebettet = <String>{for (final namenImFeld in ziel.feldNamen.values) ...namenImFeld};
  final zugeordnet = <String>{};
  for (final n in eingebettet.toList()..sort()) {
    final qn = quellname(n);
    final felder = [for (final e in ziel.feldNamen.entries) if (e.value.contains(n)) e.key]..sort();
    final abrufe = {for (final a in ziel.abrufe) if (a.name == n) (a.status, a.sha1)};
    if (qn == null) {
      if (abrufe.any((a) => a.$1 != 200)) {
        offen.add((schluessel: 'emb|$n', text: '„$n": nicht in Moodle abrufbar und der Quellaufnahme unbekannt; nicht angefasst'));
      }
      continue;
    }
    zugeordnet.add(qn);
    final quellen = quelle.where((q) => q.name == qn).toList();
    // Eine Datei, die nur im Dateimanager liegt, wird dort behandelt.
    if (quellen.every((q) => q.dateimanager)) continue;
    final schluessel = 'emb|$qn';
    if (namen[qn]!.length > 1) {
      offen.add((schluessel: schluessel, text: '„$n": mehrdeutig, gleicher Name mit verschiedenem Inhalt in der Quelle; nicht angefasst'));
      continue;
    }
    if (abrufe.length != 1) {
      offen.add((schluessel: schluessel, text: '„$n": mehrere Verweise mit verschiedenem Ergebnis; nicht angefasst'));
      continue;
    }
    final (status, sha) = abrufe.single;
    final soll = namen[qn]!.single;
    if (status == null || status >= 500) {
      offen.add((schluessel: schluessel, text: '„$n": Abruf fehlgeschlagen (${status == null ? 'keine Antwort' : 'HTTP $status'}), nicht entscheidbar; nicht angefasst'));
    } else if (status == 200 && sha == soll) {
      inOrdnung++;
    } else if (!_sicherName(n)) {
      offen.add((schluessel: schluessel, text: '„$n": Dateiname nicht zulässig; nicht angefasst'));
    } else {
      eintraege.add(ReparaturEintrag(
        schluessel: schluessel,
        name: n,
        dateibereich: false,
        feld: felder.first,
        pfad: '/',
        ersetzen: status == 200,
        sha1: soll,
        ist: status == 200 ? 'Inhalt weicht ab' : 'HTTP $status',
        felder: felder,
      ));
    }
  }
  // Eingebundene Dateien der Quelle, auf die der Text im Ziel nicht verweist: Der Text müsste sich ändern.
  for (final q in quelle.where((q) => !q.dateimanager)) {
    if (!zugeordnet.contains(q.name)) {
      offen.add((
        schluessel: 'emb|${q.name}',
        text: '„${q.name}": fehlt im Ziel, kein Verweis im Text; ihn zu ergänzen ändert den Text und gehört nicht zur Reparatur',
      ));
      zugeordnet.add(q.name);
    }
  }

  // Dateien im Dateimanager: Datei und Ordner.
  final gesehen = <String>{};
  for (final q in quelle.where((q) => q.dateimanager)) {
    final pfad = _pfad(q.pfad);
    final schluessel = 'mgr|$pfad${q.name}';
    if (!gesehen.add(schluessel)) {
      offen.add((schluessel: schluessel, text: '„${pfad.substring(1)}${q.name}": mehrfach in der Quelle; nicht angefasst'));
      continue;
    }
    final gleich = quelle.where((x) => x.dateimanager && _pfad(x.pfad) == pfad && x.name == q.name).map((x) => x.sha1).toSet();
    if (gleich.length > 1) {
      offen.add((schluessel: schluessel, text: '„${pfad.substring(1)}${q.name}": mehrdeutig, verschiedener Inhalt unter einem Namen; nicht angefasst'));
      continue;
    }
    const feld = 'files';
    final liste = ziel.bereiche[feld];
    if (liste == null) {
      offen.add((schluessel: schluessel, text: '„${pfad.substring(1)}${q.name}": Das Formular hat keinen Dateibereich $feld; nicht angefasst'));
      continue;
    }
    if (!_sicherPfad(pfad) || !_sicherName(q.name)) {
      offen.add((schluessel: schluessel, text: '„${pfad.substring(1)}${q.name}": Pfad oder Name nicht zulässig; nicht angefasst'));
      continue;
    }
    final im = liste.where((d) => d.pfad == pfad && d.name == q.name).toList();
    if (im.isEmpty && ziel.bereichsLuecken.containsKey(feld) && pfad != '/') {
      offen.add((
        schluessel: schluessel,
        text: '„${pfad.substring(1)}${q.name}": Ordner im Dateibereich $feld nicht vollständig gelesen '
            '(${ziel.bereichsLuecken[feld]}); nicht angefasst',
      ));
    } else if (im.isEmpty) {
      eintraege.add(ReparaturEintrag(
        schluessel: schluessel,
        name: q.name,
        dateibereich: true,
        feld: feld,
        pfad: pfad,
        ersetzen: false,
        sha1: q.sha1,
        ist: 'fehlt',
      ));
    } else if (im.single.status == null || im.single.status! >= 500) {
      offen.add((schluessel: schluessel, text: '„${pfad.substring(1)}${q.name}": Abruf fehlgeschlagen, nicht entscheidbar; nicht angefasst'));
    } else if (im.single.status == 200 && im.single.sha1 == q.sha1) {
      inOrdnung++;
    } else {
      eintraege.add(ReparaturEintrag(
        schluessel: schluessel,
        name: q.name,
        dateibereich: true,
        feld: feld,
        pfad: pfad,
        ersetzen: true,
        sha1: q.sha1,
        ist: im.single.status == 200 ? 'Inhalt weicht ab' : 'HTTP ${im.single.status}',
      ));
    }
  }
  final signatur = [
    for (final e in eintraege) '${e.schluessel}|${e.name}|${e.ersetzen}|${e.sha1}|${e.ist}|${e.felder.join(',')}',
    for (final o in offen) 'offen|${o.schluessel}|${o.text}',
    'ok|$inOrdnung',
  ].join('\n');
  return ReparaturPlan(eintraege, offen, inOrdnung, signatur);
}

String _pfad(String roh) {
  var pfad = roh.startsWith('/') ? roh : '/$roh';
  if (!pfad.endsWith('/')) pfad = '$pfad/';
  return pfad;
}

bool _sicherName(String name) => name.isNotEmpty && name != '.' && name != '..' && !name.contains('/') && !name.contains(r'\');

bool _sicherPfad(String pfad) => !pfad.split('/').any((s) => s == '..') && !pfad.contains(r'\');

String _sha1(List<int> bytes) => sha1.convert(bytes).toString();

/// Prüft, dass jede Reparaturdatei im Ordner liegt und genau den Inhalt der Quelle hat.
/// Wirft eine Meldung, die nennt, was fehlt oder nicht passt.
void _dateienPruefen(String quelle, ReparaturPlan plan) {
  final fehlen = <String>[];
  final falsch = <String>[];
  for (final e in plan.eintraege) {
    final datei = File(p.join(quelle, e.lokal));
    if (!datei.existsSync()) {
      fehlen.add('${e.lokal} (SHA-1 ${e.sha1})');
    } else if (_sha1(datei.readAsBytesSync()) != e.sha1) {
      falsch.add(e.lokal);
    }
  }
  if (fehlen.isEmpty && falsch.isEmpty) return;
  throw MoodleFehler(
    'Die Reparaturdateien im Ordner passen nicht zur Quellaufnahme. Nichts geschrieben, keine Freigabe. '
    '${fehlen.isEmpty ? '' : 'Es fehlen: ${fehlen.join('; ')}. '}'
    '${falsch.isEmpty ? '' : 'Anderer Inhalt als in der Quelle: ${falsch.join('; ')}. '}'
    'Die Dateien müssen genau die der Quelle sein (Inhalt, SHA-1); sie gehören unter dem genannten Pfad in den gelesenen Ordner.',
  );
}

/// Prüft, dass die vorbereitete Änderung nur die Reparatur enthält und nichts sonst.
void _aenderungPruefen(Aenderung a, ReparaturPlan plan) {
  const nichts = 'Nichts geschrieben.';
  final geplant = {for (final e in plan.eintraege) if (!e.dateibereich) e.name};
  final ist = {...a.neu, ...a.geaendert};
  if (geplant.length != ist.length || !geplant.every(ist.contains)) {
    throw MoodleFehler(
        'Der Ordner enthält andere Dateien in dateien/ als die Reparatur braucht '
        '(erwartet: ${geplant.isEmpty ? 'keine' : geplant.join(', ')}; im Ordner neu oder geändert: '
        '${ist.isEmpty ? 'keine' : ist.join(', ')}). $nichts');
  }
  final geplantBereich = {for (final e in plan.eintraege) if (e.dateibereich) '${e.feld}${e.pfad}${e.name}'};
  final istBereich = <String>{};
  for (final b in a.bereiche) {
    if (b.weg.isNotEmpty) {
      throw MoodleFehler('Im Ordner fehlt, was in Moodle im Dateibereich ${b.feld} liegt: ${b.weg.join(', ')}. '
          'Die Reparatur löscht nichts. $nichts');
    }
    for (final k in [...b.neu, ...b.geaendert]) {
      istBereich.add('${b.feld}$k');
    }
  }
  if (geplantBereich.length != istBereich.length || !geplantBereich.every(istBereich.contains)) {
    throw MoodleFehler('Der Ordner enthält andere Dateien in bereiche/ als die Reparatur braucht '
        '(erwartet: ${geplantBereich.isEmpty ? 'keine' : geplantBereich.join(', ')}; im Ordner neu oder geändert: '
        '${istBereich.isEmpty ? 'keine' : istBereich.join(', ')}). $nichts');
  }
  final alt = felderIn(a.stand);
  for (final k in a.zuSchreiben) {
    if (normalisiert(alt[k] ?? '') != normalisiert(a.lokal[k] ?? '')) {
      throw MoodleFehler('Der Text von $k.html im Ordner weicht vom gelesenen Stand ab; die Reparatur ändert keinen Text. $nichts');
    }
  }
  if (a.einstellungen.isNotEmpty) {
    throw MoodleFehler('Die Reparatur ändert keine Einstellungen. $nichts');
  }
}

/// Prüft Aktivität und Zuordnung vor jedem Schritt: Formular lesbar, Nummer, Name und Art
/// der Aktivität stimmen im Formular und in der Kursstruktur, die Aktivität ist im Kurs
/// eindeutig. Gibt das Formular zurück.
Future<ZielAufnahme> _zuordnungPruefen(
  MoodleZugang moodle, {
  required int kurs,
  required int cmid,
  required String name,
}) async {
  final ziel = await zielAufnahmeLesen(moodle, cmid, unterordner: true);
  if (ziel.fehler != null) {
    throw MoodleFehler('${ziel.fehler}. Nichts geschrieben.');
  }
  nameBestaetigen(name, ziel.name ?? '', 'Aktivität $cmid');
  if (ziel.kurs != kurs) {
    throw MoodleFehler('Aktivität $cmid gehört laut Formular nicht zu Kurs $kurs. Nichts geschrieben.');
  }
  final struktur = await kursLesen(moodle, kurs);
  final akt = struktur.nachCmid[cmid];
  if (akt == null) {
    throw MoodleFehler('Aktivität $cmid gibt es in Kurs $kurs nicht. Nichts geschrieben.');
  }
  nameBestaetigen(name, akt.name, 'Aktivität $cmid');
  final gleichnamige = struktur.nachCmid.values
      .where((x) => x.modul == akt.modul && nameNormal(x.name) == nameNormal(name))
      .length;
  if (gleichnamige > 1 || (ziel.modul != null && ziel.modul != akt.modul)) {
    throw MoodleFehler('„$name" ist im Kurs nicht eindeutig (gleichnamige Aktivität gleicher Art); die Zuordnung zur '
        'Quelle ist unsicher. Nichts geschrieben.');
  }
  return ziel;
}

/// Der Wiederherstellungsvorgang, dessen Quellaufnahme zugrunde liegt: der genannte, sonst der eine
/// fertige Vorgang des Kurses, der diese Aktivität enthält.
Future<Vorgang> _vorgang(
  Vorgaenge vorgaenge, {
  required String? id,
  required int kurs,
  required String modul,
  required String name,
}) async {
  bool enthaelt(Vorgang v) => (v.wiederherstellungAktivitaeten ?? const []).where((a) => a.modul == modul && nameNormal(a.titel) == nameNormal(name)).length == 1;
  Vorgang? vg;
  if (id != null && id.trim().isNotEmpty) {
    vg = await vorgaenge.finde(id.trim());
    if (vg == null || vg.wiederherstellung == null) {
      throw MoodleFehler('Keine Wiederherstellung mit der Nummer $id. Nichts geschrieben.');
    }
  } else {
    final kandidaten = [
      for (final v in await vorgaenge.alle())
        if (v.wiederherstellung == WiederherstellungStand.fertig && v.kurs == kurs && enthaelt(v)) v,
    ];
    if (kandidaten.length != 1) {
      throw MoodleFehler(kandidaten.isEmpty
          ? 'Kein abgeschlossener Wiederherstellungsvorgang dieses Kurses enthält „$name". Die Nummer der '
              'Wiederherstellung als vorgang angeben. Nichts geschrieben.'
          : 'Mehrere Wiederherstellungen dieses Kurses enthalten „$name" (${kandidaten.map((v) => v.id).join(', ')}). '
              'Die Nummer als vorgang angeben. Nichts geschrieben.');
    }
    vg = kandidaten.single;
  }
  vorgaenge.pruefeBindung(vg);
  if (vg.kurs != kurs) {
    throw MoodleFehler('Die Wiederherstellung ${vg.id} gehört nicht zu Kurs $kurs. Nichts geschrieben.');
  }
  if (vg.wiederherstellung != WiederherstellungStand.fertig) {
    throw MoodleFehler('Die Wiederherstellung ${vg.id} ist noch nicht abgeschlossen (${vg.wiederherstellung!.text}). '
        'Erst wiederherstellung_status. Nichts geschrieben.');
  }
  if (!enthaelt(vg)) {
    throw MoodleFehler('Die Wiederherstellung ${vg.id} enthält „$name" nicht genau einmal; die Zuordnung zur Quelle ist unsicher. '
        'Nichts geschrieben.');
  }
  return vg;
}

/// Ergänzt oder ersetzt fehlende und abweichende Anhänge der Aktivität [cmid] aus Dateien im
/// gelesenen Ordner [ordner], nach Freigabe. Siehe die Kopfzeilen dieser Datei.
Future<String> anhaengeReparieren(
  MoodleZugang moodle,
  Freigaben freigaben,
  Vorgaenge vorgaenge, {
  required int kurs,
  required int cmid,
  required String name,
  required String ordner,
  required String arbeitsordner,
  String? vorgang,
}) async {
  final quelle = imArbeitsordner(ordner, arbeitsordner);
  final ziel = Formularziel.ausOrdner(quelle);
  if (ziel.art != Zielart.aktivitaet || ziel.id != cmid) {
    throw MoodleFehler('Der Ordner $ordner ist nicht der gelesene Ordner der Aktivität $cmid. Nichts geschrieben.');
  }
  return await ordnerSperre(
    ordnerSchluessel(ziel, arbeitsordner),
    () => _reparieren(moodle, freigaben, vorgaenge,
        kurs: kurs, cmid: cmid, name: name, ordner: ordner, quelle: quelle, arbeitsordner: arbeitsordner, vorgang: vorgang),
  );
}

Future<String> _reparieren(
  MoodleZugang moodle,
  Freigaben freigaben,
  Vorgaenge vorgaenge, {
  required int kurs,
  required int cmid,
  required String name,
  required String ordner,
  required String quelle,
  required String arbeitsordner,
  required String? vorgang,
}) async {
  // 1. Zuordnung.
  final ziel0 = await _zuordnungPruefen(moodle, kurs: kurs, cmid: cmid, name: name);
  final vg = await _vorgang(vorgaenge, id: vorgang, kurs: kurs, modul: ziel0.modul ?? '', name: name);

  // 2. Quellaufnahme und Plan.
  final geladen = await quelleLaden(vorgaenge, vg);
  final mbz = geladen.mbz;
  if (mbz == null) {
    throw MoodleFehler('${geladen.luecke} Nichts geschrieben.');
  }
  final quelleDateien = quelldateienMitOrt(mbz, modul: ziel0.modul ?? '', titel: name);
  if (quelleDateien == null) {
    throw MoodleFehler('Die Quellaufnahme der Wiederherstellung ${vg.id} enthält „$name" nicht eindeutig oder ihre '
        'Dateiliste fehlt: Prüflücke, keine Reparatur. Nichts geschrieben.');
  }
  final plan = reparaturPlanen(quelle: quelleDateien, ziel: ziel0);
  String offenText(ReparaturPlan pl) =>
      pl.offen.isEmpty ? '' : ' Nicht repariert (Prüflücke): ${pl.offen.map((o) => o.text).join('; ')}.';
  if (plan.eintraege.isEmpty) {
    return 'Nichts zu reparieren: ${plan.inOrdnung} Datei(en) stimmen mit der Quellaufnahme überein, nichts '
        'Eindeutiges fehlt oder weicht ab. Nichts geschrieben, keine Freigabe.${offenText(plan)}';
  }

  // 3. Reparaturdateien und Änderung: nur die Reparatur.
  _dateienPruefen(quelle, plan);
  final a = await aenderungVorbereiten(moodle, ordner: ordner, arbeitsordner: arbeitsordner);
  if (a == null) {
    throw MoodleFehler('Der Ordner unterscheidet sich nicht vom gelesenen Stand, die Reparaturdateien fehlen also '
        'noch: ${plan.eintraege.map((e) => e.lokal).join(', ')}. Nichts geschrieben.');
  }
  _aenderungPruefen(a, plan);

  // 4. Freigabe.
  final ja = await freigaben.anfragen(
    FreigabeAnfrage(
      titel: 'Anhänge reparieren?',
      punkte: [
        a.kopf(),
        'Quelle: Wiederherstellung ${vg.id} (Sicherungsdatei ${vg.datei}). Verglichen wurde der Inhalt (SHA-1), nicht die Adresse.',
        for (final e in plan.eintraege) e.zeile,
        'Die Dateien kommen aus dem gelesenen Ordner im Arbeitsordner und haben genau den Inhalt der Quelle.',
        'Nichts anderes ändert sich: kein Text, keine Einstellung, nichts wird gelöscht.',
      ],
      vergleich: a.vergleich,
      knopf: 'Reparieren',
      ab: await fuellenAb(moodle, a.vorab.kurs, [a.cmid]),
    ),
  );
  if (!ja) {
    return 'Nicht repariert: Die Reparatur wurde in der App abgelehnt oder nicht innerhalb von '
        '${freigaben.frist.inMinutes} Minuten freigegeben. Nichts geschrieben.';
  }

  // 5. Stand erneut prüfen: Moodle, Zuordnung und Ordner müssen noch das Freigegebene sein.
  final ziel1 = await _zuordnungPruefen(moodle, kurs: kurs, cmid: cmid, name: name);
  final plan1 = reparaturPlanen(quelle: quelleDateien, ziel: ziel1);
  if (plan1.signatur != plan.signatur) {
    throw MoodleFehler('Moodle hat sich seit dem Planen geändert (Dateien der Aktivität sind anders als bei der Freigabe). '
        'Nichts geschrieben; erneut prüfen und den Ordner neu lesen.');
  }
  _dateienPruefen(quelle, plan1);
  final b = await aenderungVorbereiten(moodle, ordner: ordner, arbeitsordner: arbeitsordner);
  if (b == null) {
    throw MoodleFehler('Der Ordner unterscheidet sich seit der Freigabe nicht mehr vom gelesenen Stand. Nichts geschrieben.');
  }
  _aenderungPruefen(b, plan1);

  // 6. Schreiben über den Weg von aendern (er prüft den Stand beim Lesen noch einmal) und zurücklesen.
  final String schreibText;
  final bool probeOk;
  try {
    (schreibText, probeOk) = await aenderungSchreiben(moodle, b, arbeitsordner);
  } on SchutzPruefung catch (e) {
    return '${e.meldung}\nDie Reparatur kann nicht übergeben werden (Dateien lassen sich nicht über die Zwischenablage '
        'übernehmen) und wurde nicht wiederholt (verified: false). Die Lehrkraft lädt die Dateien selbst in Moodle '
        'hoch: ${plan.eintraege.map((e) => e.zeile).join('; ')}.';
  }
  final ziel2 = await zielAufnahmeLesen(moodle, cmid, unterordner: true);
  final plan2 = reparaturPlanen(quelle: quelleDateien, ziel: ziel2);
  final nochOffen = {for (final e in plan2.eintraege) e.schluessel, for (final o in plan2.offen) o.schluessel};
  final nichtBehoben = [for (final e in plan.eintraege) if (nochOffen.contains(e.schluessel)) e];
  final namePasst = ziel2.fehler == null && nameNormal(ziel2.name ?? '') == nameNormal(name) && ziel2.kurs == kurs;
  final verified = probeOk && ziel2.fehler == null && namePasst && nichtBehoben.isEmpty;
  final befund = ziel2.fehler != null
      ? 'Rücklesen nicht möglich: ${ziel2.fehler}.'
      : nichtBehoben.isEmpty
          ? 'Rücklesen: Jede reparierte Datei stimmt jetzt im Inhalt (SHA-1) mit der Quellaufnahme überein.'
          : 'Abweichung beim Rücklesen: ${nichtBehoben.map((e) => e.zeile).join('; ')}.';
  final bericht = [
    'Anhänge repariert (Wiederherstellung ${vg.id}): ${plan.eintraege.map((e) => e.zeile).join('; ')}.',
    schreibText,
    befund,
    if (!namePasst) 'Name oder Kurs der Aktivität passen nach dem Schreiben nicht mehr zu den Angaben.',
    if (plan2.offen.isNotEmpty) offenText(plan2).trim(),
    verified ? 'verified: true (Dateien der Reparatur zurückgelesen und verglichen).' : 'verified: false.',
  ].join('\n');
  // Der Vorgang behält sein Urteil; die Reparatur steht als eigener Befund im Status.
  final text = vg.text.replaceFirst(RegExp(r' Anhangsreparatur:.*$'), '');
  await vorgaenge.aktualisieren(vg,
      text: '$text Anhangsreparatur: „$name" ${verified ? 'repariert und zurückgelesen' : 'nicht vollständig verifiziert'}.');
  return bericht;
}
