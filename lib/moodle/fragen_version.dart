// fragen_version_importieren (E38): Fragen aus einer Moodle-XML-Datei als NEUE
// VERSION der vorhandenen Fragen einspielen, mit Verlauf, Sachnummer und
// Plätzen in Tests. Gebaut auf der Seite des Moodle-Plugins
// `qbank_importasversion` (öffentlicher Quelltext: import.php): Sie nimmt genau
// eine Frage je Datei und legt sie als nächste Version des Eintrags an, dessen
// questionid in der Adresse steht.
//
// Reihenfolge, damit bis zur Freigabe nichts geschieht:
//   1. Datei prüfen, jede Frage über ihre Sachnummer EINER Frage der Kategorie
//      zuordnen (kein Treffer, mehrdeutig oder anderer Typ: Abbruch).
//   2. Stand prüfen: Die Version, von der die KI ausging, muss noch die neueste
//      sein (E17); sonst Abbruch, es sei denn, der Aufruf nennt genau die
//      neuere ausdrücklich (`uebergehen`).
//   3. Gibt es die Plugin-Seite? Sonst der feste Satz [pluginFehlt].
//   4. Eine Freigabe für die ganze Datei, mit Zeilenvergleich je Frage.
//   5. Je Frage: Stand erneut prüfen, Datei mit genau dieser Frage senden,
//      Rundlaufprobe; die nur durch Rücklesen ermittelte Version nie löschen.
//
// Das Plugin meldet Erfolg und Fehler nur als Hinweis auf der Seite, auf die es
// umleitet (die Fragenübersicht, die Klarnamen zeigt -- ihr folgt die App
// nicht, A1). Ob eine Version entstanden ist, zeigt deshalb allein der Export.
// Das ist kein Herkunftsnachweis: Ein paralleles Speichern kann die neueste
// Version austauschen. Daher berechtigt diese Nummer weder zum Löschen noch
// zum Setzen auf Entwurf. Nur die direkt gemeldete Probeversion wird gelöscht.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../freigabe.dart';
import 'formular.dart';
import 'formular_lesen.dart';
import 'formular_schreiben.dart';
import 'fragen.dart';
import 'fragen_vergleich.dart';
import 'fragen_xml.dart';
import 'moodle_zugang.dart';
import 'rundlaufprobe.dart';
import 'schreibvorgang.dart';
import 'stack.dart';
import 'zeilenvergleich.dart';

/// Der feste Satz, wenn die Instanz keine neue Version aus XML kann. Die KI
/// gibt ihn weiter und improvisiert nichts (A6).
const String pluginFehlt =
    'Auf dieser Moodle-Instanz fehlt das Plugin „Import question as new version" (qbank_importasversion), oder es '
    'ist abgeschaltet. Eine neue Version aus XML ist hier deshalb nicht möglich; geändert wurde nichts. Es bleiben '
    'zwei Wege: die Frage über das Bearbeitungsformular ändern (frage_lesen, dann aendern -- auch das legt eine '
    'neue Version an) oder sie als neue Frage ohne gemeinsamen Verlauf einspielen (frage_ersetzen). Die Lehrkraft '
    'kann ihre Moodle-Administration bitten, das Plugin zu installieren.';

const _typNamen = {'matching': 'match', 'cloze': 'multianswer'};
String _typ(String t) => _typNamen[t] ?? t;

/// Eine Frage der Datei samt ihrer Entsprechung in Moodle.
class _Zuordnung {
  _Zuordnung(this.datei, this.element, this.aktuell, this.ausgang);

  /// Die Frage in der Datei (Typ, Name, Sachnummer, evtl. Ausgangsnummer).
  final FrageKurz datei;
  final XmlElement element;

  /// Die neueste Version in Moodle.
  final FrageKurz aktuell;

  /// Die questionid, von der die KI ausging.
  final int ausgang;
}

Future<String> fragenVersionImportieren(
  MoodleZugang moodle,
  Freigaben freigaben,
  String arbeitsordner, {
  required int sammlung,
  required String kategorie,
  required String datei,
  int? uebergehen,
  BeiBestanden? beiBestanden,
}) async {
  // --- 1. Prüfen; nichts wird geschrieben ------------------------------------
  final pfad = imArbeitsordner(datei, arbeitsordner);
  final f0 = File(pfad);
  if (!f0.existsSync()) throw MoodleFehler('Datei $pfad gibt es nicht.');
  final roh = await f0.readAsString(encoding: utf8);
  final (xml, _) = fragenXmlPruefen(roh, dateiordner: p.join(p.dirname(pfad), 'dateien'));
  final k = kategorieWaehlen(await kategorienLesen(moodle, sammlung), kategorie);
  final zuordnungen = await _zuordnen(moodle, arbeitsordner, sammlung, k, roh, xml);

  // --- 2. Stand ---------------------------------------------------------------
  _standPruefen(zuordnungen, uebergehen);

  // --- 3. Plugin --------------------------------------------------------------
  await _pluginFormular(moodle, sammlung, zuordnungen.first.aktuell.id!);

  // --- 4. Freigabe ------------------------------------------------------------
  final vergleich = <Zeile>[];
  for (final z in zuordnungen) {
    final alt = await frageExport(moodle, sammlung, z.aktuell.id!);
    vergleich.add(Zeile(ZeilenArt.gleich, '── „${z.aktuell.name}" (Sachnummer ${z.aktuell.idnummer}, alte Version ${z.aktuell.id}) ──'));
    vergleich.addAll(zeilenVergleich(_ohneKommentare(alt.xml ?? ''), _ohneKommentare(z.element.toXmlString(pretty: true))).zeilen);
  }
  final ja = await freigaben.anfragen(FreigabeAnfrage(
    titel: zuordnungen.length == 1 ? 'Neue Version einer Frage einspielen?' : '${zuordnungen.length} Fragen als neue Version einspielen?',
    punkte: [
      'In Kategorie „${k.name}" der Fragensammlung cmid $sammlung, aus ${p.basename(pfad)}:',
      for (final z in zuordnungen)
        '„${z.aktuell.name}" (${z.aktuell.typ}, Sachnummer ${z.aktuell.idnummer}): neue Version nach questionid ${z.aktuell.id}',
      'Verlauf, Sachnummer und Plätze in Tests bleiben; Tests mit „neueste Version" nehmen die neue Version sofort.',
      if (uebergehen != null) 'ACHTUNG: Eine inzwischen gespeicherte Version $uebergehen wird übergangen; sie bleibt im Verlauf.',
      'Danach prüft moocp jede Frage (Export, Formular, Vorschau, einmal unverändert als Entwurf speichern). '
          'Die Probeversion wird aufgeräumt. Das Plugin meldet die importierte Versionsnummer nicht direkt; '
          'deshalb bleibt eine durchgefallene importierte Version zur manuellen Prüfung stehen und kann in Tests aktiv sein.',
    ],
    vergleich: vergleich,
    knopf: 'Einspielen',
    ohneEntscheidung: 'wird nichts geändert',
  ));
  if (!ja) {
    return 'Nicht eingespielt: in der App abgelehnt oder nicht innerhalb von ${freigaben.frist.inMinutes} Minuten '
        'freigegeben. Nichts geändert.';
  }

  // --- 5. Je Frage -------------------------------------------------------------
  final b = StringBuffer();
  var alleOk = true, verified = true;
  for (final (i, z) in zuordnungen.indexed) {
    final r = await _eine(moodle, arbeitsordner, sammlung, k, z, beiBestanden);
    b.writeln(r.text);
    if (!r.verified) verified = false;
    if (!r.ok) {
      alleOk = false;
      final rest = zuordnungen.length - i - 1;
      if (rest > 0) b.writeln('Abgebrochen: die übrigen $rest Frage(n) wurden nicht angefasst.');
      break;
    }
  }
  return '${alleOk ? 'Neue Version(en) eingespielt' : 'NICHT alles eingespielt'}: Sammlung cmid $sammlung, '
      'Kategorie „${k.name}". verified: ${alleOk && verified}\n$b';
}

String _ohneKommentare(String xml) => xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '').trim();

Future<List<_Zuordnung>> _zuordnen(
    MoodleZugang moodle, String arbeitsordner, int sammlung, Kategorie k, String roh, String xml) async {
  final dateiFragen = fragenAusXml(roh);
  final elemente = XmlDocument.parse(xml).rootElement.findElements('question').where((q) => q.getAttribute('type') != 'category').toList();
  if (dateiFragen.isEmpty || dateiFragen.length != elemente.length) {
    throw MoodleFehler('Abgebrochen, nichts geschrieben: Die Datei enthält keine Fragen oder sie ließen sich nicht lesen.');
  }
  final aktuell = fragenAusXml(await exportieren(moodle, sammlung, k));
  // Der Stand beim Lesen: die Datei, die fragen_lesen im Arbeitsordner abgelegt hat.
  final gelesen = File(p.join(arbeitsordner, 'fragen-$sammlung', 'kategorie-${k.id}.xml'));
  final snapshot = gelesen.existsSync() ? fragenAusXml(gelesen.readAsStringSync()) : const <FrageKurz>[];
  final aus = <_Zuordnung>[];
  for (final (i, d) in dateiFragen.indexed) {
    final idn = d.idnummer;
    if (idn == null) {
      throw MoodleFehler('Abgebrochen, nichts geschrieben: Die Frage „${d.name}" hat keine Sachnummer (<idnumber>); '
          'ohne sie ist nicht zu sagen, welche Frage eine neue Version bekommt.');
    }
    final treffer = aktuell.where((f) => f.idnummer == idn).toList();
    if (treffer.isEmpty) {
      throw MoodleFehler('Abgebrochen, nichts geschrieben: Zur Sachnummer $idn („${d.name}") gibt es in Kategorie '
          '„${k.name}" keine Frage. Neue Fragen legt fragen_importieren an.');
    }
    if (treffer.length > 1) {
      throw MoodleFehler('Abgebrochen, nichts geschrieben: Die Sachnummer $idn ist in Kategorie „${k.name}" mehrdeutig '
          '(${treffer.map((f) => f.id).join(', ')}). Nicht raten: Die Lehrkraft entscheidet, welche gemeint ist.');
    }
    final t = treffer.single;
    if (_typ(t.typ) != _typ(d.typ)) {
      throw MoodleFehler('Abgebrochen, nichts geschrieben: „${d.name}" (Sachnummer $idn) ist in Moodle eine Frage vom '
          'Typ ${t.typ}, die Datei sagt ${d.typ}. Ein Typwechsel geht nur mit frage_ersetzen (der Verlauf geht dabei verloren).');
    }
    if (t.id == null) throw MoodleFehler('Die questionid zu Sachnummer $idn ist nicht zu ermitteln.');
    // Ausgang: die Nummer im Kommentar der Datei, sonst die beim Lesen.
    final ausgang = d.id ?? snapshot.where((f) => f.idnummer == idn).map((f) => f.id).firstOrNull;
    if (ausgang == null) {
      throw MoodleFehler('Abgebrochen, nichts geschrieben: Es ist unbekannt, von welcher Version der Frage „${d.name}" '
          '(Sachnummer $idn) die Datei ausgeht. Erst fragen_lesen für diese Kategorie aufrufen und die Datei daraus '
          'ableiten (der Kommentar „question: <id>" bleibt in der Datei stehen).');
    }
    aus.add(_Zuordnung(d, elemente[i], t, ausgang));
  }
  return aus;
}

/// Die Stand-Prüfung: Ist seit dem Lesen eine neuere Version gespeichert, bricht
/// das Werkzeug ab und nennt sie; nur [uebergehen] mit genau dieser Nummer
/// erlaubt es trotzdem (E17, E38).
void _standPruefen(List<_Zuordnung> zs, int? uebergehen) {
  for (final z in zs) {
    final neu = z.aktuell.id!;
    if (neu == z.ausgang) continue;
    if (uebergehen == neu) continue;
    throw MoodleFehler('Abgebrochen, nichts geschrieben: Von „${z.aktuell.name}" (Sachnummer ${z.aktuell.idnummer}) ist '
        'inzwischen eine neuere Version gespeichert (questionid $neu; die Datei geht von ${z.ausgang} aus), vermutlich '
        'von Hand. Die Lehrkraft entscheidet: neu lesen und die Änderung auf dem neuen Stand wiederholen, oder die '
        'Version $neu bewusst übergehen -- dann den Aufruf mit uebergehen: $neu wiederholen; sie bleibt im Verlauf.');
  }
}

/// Das Formular des Plugins für genau diese Frage. Alles außer einem Formular
/// mit Dateifeld heißt: Das Plugin fehlt oder ist abgeschaltet ([pluginFehlt]).
/// Eine Fehlerseite und ein fehlendes Skript bieten keinen verwendbaren
/// Upload; beide Fälle liefern deshalb denselben festen Hinweis.
Future<Formular> _pluginFormular(MoodleZugang moodle, int sammlung, int frage) async {
  final Formular f;
  try {
    f = await formularHolen(moodle, '/question/bank/importasversion/import.php?id=$frage&cmid=$sammlung');
  } on MoodleFehler {
    throw MoodleFehler(pluginFehlt);
  }
  if (wertIn(f.felder, 'newfile') == null || wertIn(f.felder, '_qf__qbank_importasversion_form_import_form') == null) {
    throw MoodleFehler(pluginFehlt);
  }
  return f;
}

Future<({bool ok, bool verified, String text})> _eine(MoodleZugang moodle, String arbeitsordner, int sammlung, Kategorie k,
    _Zuordnung z, BeiBestanden? beiBestanden) async {
  final name = z.aktuell.name, idn = z.aktuell.idnummer;
  final kopf = '„$name" (Sachnummer $idn)';
  final vorgang = Schreibvorgang(moodle, Formularziel.frage(sammlung, z.aktuell.id!));
  if (vorgang.offen) return (ok: false, verified: false, text: '$kopf: ${vorgang.hinweis}');

  // Nach der Freigabe noch einmal: Seitdem kann jemand gespeichert haben.
  final jetzt = fragenAusXml(await exportieren(moodle, sammlung, k)).where((f) => f.idnummer == idn).toList();
  if (jetzt.length != 1 || jetzt.single.id != z.aktuell.id) {
    return (ok: false, verified: false, text: '$kopf: Seit der Freigabe hat sich die Frage in Moodle geändert (neueste questionid jetzt '
        '${jetzt.map((f) => f.id).join(', ')}). Nichts geschrieben; neu lesen.');
  }
  final vorherIds = {for (final f in jetzt) f.id};

  final eingabe = quizXml([z.element.toXmlString()]);
  final form = await _pluginFormular(moodle, sammlung, z.aktuell.id!);
  final itemid = wertIn(form.felder, 'newfile')!;
  await hochladen(moodle, form, itemid, '/', 'frage.xml', utf8.encode(eingabe));
  // Genau die Datei, nie force oder Schlagwörter zusammenführen (Positivliste).
  setze(form.felder, 'force', '0');

  final alt = await frageExport(moodle, sammlung, z.aktuell.id!);
  vorgang.beginnen(
    {'xml': schreibPruefsumme(_ohneKommentare(alt.xml ?? ''))},
    {'xml': schreibPruefsumme(_ohneKommentare(eingabe))},
  );
  try {
    await absenden(moodle, form, knoepfe: const ['submitbutton']);
  } on SitzungAbgelaufen {
    vorgang.verwerfen();
    rethrow;
  } on SchutzPruefung {
    vorgang.verwerfen();
    rethrow;
  } on MoodleFehler catch (x) {
    if (x is FormularAbgelehnt || x is AnfrageGesperrt || x is NichtAngemeldet) {
      vorgang.verwerfen();
      return (ok: false, verified: false, text: '$kopf: Import abgelehnt, nichts gespeichert: ${x.meldung}');
    }
    // Nach dem Beginn ist auch eine Ablehnung ohne Beleg kein Nachweis, dass
    // nichts geschrieben wurde (E37).
    return (ok: false, verified: false, text: '$kopf: ${vorgang.hinweis}\nUrsache: ${x.meldung}');
  } catch (x) {
    return (ok: false, verified: false, text: '$kopf: ${vorgang.hinweis}\nUrsache: ${x.runtimeType}');
  }

  // Zurücklesen: Das Plugin meldet nur auf der Seite, auf die es umleitet.
  final nachher = fragenAusXml(await exportieren(moodle, sammlung, k)).where((f) => f.idnummer == idn).toList();
  if (nachher.length != 1 || vorherIds.contains(nachher.single.id)) {
    return (ok: false, verified: false, text: '$kopf: Moodle hat keine neue Version angelegt (das Plugin hat die Datei abgewiesen oder '
        'der Stand ist nicht eindeutig). ${vorgang.hinweis}');
  }
  final neu = nachher.single;
  if (neu.id == null) {
    return (ok: false, verified: false, text: '$kopf: Die neue Versionsnummer ist nicht erkennbar. ${vorgang.hinweis}');
  }
  final export = await frageExport(moodle, sammlung, neu.id!);
  final abweichungen = export.xml == null ? ['Die zurückgelesene Version lässt sich nicht exportieren.']
      : fragenVergleichen(eingabe, export.xml!);
  if (abweichungen.isNotEmpty) {
    if (export.xml != null) vorgang.rueckgelesen();
    return (ok: false, verified: false, text: '$kopf: Rundlaufprobe NICHT bestanden. '
        'Zurückgelesene Version ${neu.id}: ${abweichungen.join(' ')} '
        'Ihre Herkunft ist nicht direkt bestätigt; sie wurde weder gelöscht noch auf Entwurf gesetzt '
        'und kann in Tests aktiv sein. Die Lehrkraft prüft sie in der Fragenbank. '
        '${export.xml == null ? vorgang.hinweis : 'Frisch lesen und neu planen.'}');
  }
  // Bestätigt den beobachteten Zielinhalt, nicht die Herkunft der Version.
  vorgang.abschliessen();
  final angelegt = Angelegt();

  // Eine vom Plugin nicht direkt gemeldete Nummer ist keine Löschberechtigung.
  final probe = await rundlaufProbe(moodle, arbeitsordner, sammlung: sammlung, frage: neu.id!, eingabe: eingabe, angelegt: angelegt);
  final b = StringBuffer();
  if (probe.ausgangUnklar) {
    return (ok: false, verified: false, text: '$kopf: Ausgang der Probe unklar; nichts weiter geschrieben oder gelöscht. '
        'Version ${neu.id} bleibt zur manuellen Prüfung stehen und kann in Tests aktiv sein.\n${probe.text()}');
  }
  if (probe.bestanden && neu.typ == 'stack') {
    try {
      final nachweis = await stackTesten(moodle, sammlung: sammlung, frage: neu.id!);
      b.writeln('Nachweis STACK:\n$nachweis');
      if (!nachweis.contains('verified: true')) {
        probe.befunde.add('Die STACK-Fragetests sind nicht bestanden.');
      }
    } on MoodleFehler catch (x) {
      probe.befunde.add('Die STACK-Fragetests ließen sich nicht prüfen: ${x.meldung}');
    }
  }
  if (!probe.bestanden) {
    b.writeln('$kopf: Rundlaufprobe NICHT bestanden. Zurückgelesene Version ${neu.id} '
        'wurde weder gelöscht noch auf Entwurf gesetzt: Das Plugin bestätigt ihre Herkunft nicht direkt. '
        'Sie kann in Tests aktiv sein; die Lehrkraft prüft sie in der Fragenbank.');
    b.write(probe.text());
    return (ok: false, verified: false, text: b.toString().trimRight());
  }
  if (probe.verified) beiBestanden?.call(z.aktuell.typ, eingabe, probe.moodleVersion);
  b.writeln('$kopf: zurückgelesene Version ${neu.id} nach ${z.aktuell.id}. Rundlaufprobe ${probe.verified ? 'bestanden' : 'ohne Befund, aber nicht vollständig'}. '
      'Die Versionsnummer wurde durch Rücklesen ermittelt; das Plugin liefert keinen direkten Herkunftsnachweis.');
  b.write(probe.text());
  return (ok: true, verified: probe.verified, text: b.toString().trimRight());
}
