// fragen_verschieben (E9, E20, E37): Fragen mit allen Versionen in eine andere
// Kategorie verschieben, im selben Kurs, auch in eine andere Fragensammlung.
//
// Moodle 5.1 bietet das nur als Fenster im Browser an, das den Dienst
// core_question_move_questions aufruft; die App ruft ihn selbst auf, wie der
// Browser es täte (E2). Der Dienst verschiebt den Fragenbank-EINTRAG: Alle
// Versionen, der Verlauf und die Verweise von Tests (sie zeigen auf den Eintrag)
// bleiben. Zufallsplätze eines Tests hängen dagegen an der Kategorie: Wer aus
// einer Kategorie verschiebt, die ein Zufallsplatz zieht, ändert dessen
// Fragenmenge -- die Freigabe sagt es.
//
// Nicht aus dem Quelltext von Moodle 5.1 belegt (questionlib.php liegt nicht
// vor) und am Testkurs zu messen, hier mit "nicht gemessen" markiert:
//  - dass je Eintrag genau eine questionid reicht und alle Versionen mitziehen;
//    mehrere Versionen desselben Eintrags in einem Aufruf hängen der Sachnummer
//    einen Suffix an (Beobachtung aus dem Quelltext von Coursepilot);
//  - dass Moodle eine Sachnummer-Kollision im Ziel still mit `_N` löst, statt
//    abzulehnen; die App prüft deshalb vorab und liest danach zurück;
//  - dass die questionid der neuesten Version beim Verschieben gleich bleibt
//    (das Zurücklesen sucht danach);
//  - wie sich Fragen verhalten, die in einem Test der Quell- und einem anderen
//    Kurs stecken (die App verschiebt nur im selben Kurs).

import '../freigabe.dart';
import 'formular_lesen.dart';
import 'formular_schreiben.dart';
import 'fragen.dart';
import 'fragen_xml.dart';
import 'kurs.dart';
import 'moodle_zugang.dart';
import 'schreibvorgang.dart';

/// Wie viele Fragen ein Aufruf verschieben darf: Die Freigabe nennt jede.
const verschiebenHoechstzahl = 50;

/// Eine zu verschiebende Frage mit dem, was die Vorabprüfung über sie weiß.
class _Frage {
  _Frage(this.frage, this.von);
  final FrageKurz frage;
  final Kategorie von;
}

/// Die Kategorie und die Fragen (neueste Version, nicht verborgen) jeder Kategorie einer Sammlung.
Future<Map<int, List<FrageKurz>>> _inhalt(MoodleZugang moodle, int sammlung, List<Kategorie> kategorien) async {
  final aus = <int, List<FrageKurz>>{};
  for (final k in kategorien) {
    aus[k.id] = k.anzahl == 0 ? <FrageKurz>[] : fragenAusXml(await exportieren(moodle, sammlung, k));
  }
  return aus;
}

String _kopf(FrageKurz f) =>
    '„${f.name}" (${f.typ}, questionid ${f.id}${(f.idnummer ?? '').isEmpty ? '' : ', Sachnummer ${f.idnummer}'})';

/// Alles, was vor der Freigabe und noch einmal danach feststehen muss. Wirft
/// [MoodleFehler], ohne etwas geschrieben zu haben.
Future<({List<_Frage> fragen, Kategorie ziel, List<Fragensammlung> banken, List<Kategorie> zielKategorien})> _pruefen(
    MoodleZugang moodle,
    {required int kurs,
    required int sammlung,
    required List<(int, String)> fragen,
    required int zielSammlung,
    required String zielKategorie}) async {
  if (fragen.isEmpty) throw MoodleFehler('Keine Fragen genannt.');
  final ids = [for (final (id, _) in fragen) id];
  if (ids.toSet().length != ids.length) throw MoodleFehler('Eine Frage ist doppelt genannt.');

  // Nur im selben Kurs: Beide Sammlungen müssen auf der Übersicht dieses Kurses stehen.
  final banken = await fragensammlungenLesen(moodle, kurs);
  for (final (s, was) in [(sammlung, 'Die Quellsammlung'), (zielSammlung, 'Die Zielsammlung')]) {
    if (!banken.any((b) => b.cmid == s)) {
      throw MoodleFehler('Abgebrochen, nichts verschoben: $was (cmid $s) gehört nicht zu Kurs $kurs. '
          'Verschoben wird nur innerhalb eines Kurses; die Sammlungen mit fragensammlungen nachsehen.');
    }
  }

  // Wo steht jede Frage? Der Einzelexport prüft die Sammlung nicht, der Export der Kategorien schon.
  final quellKategorien = await kategorienLesen(moodle, sammlung);
  final quelle = await _inhalt(moodle, sammlung, quellKategorien);
  final gefunden = <_Frage>[];
  for (final (id, name) in fragen) {
    final k = quellKategorien.where((k) => quelle[k.id]!.any((f) => f.id == id)).firstOrNull;
    if (k == null) {
      throw MoodleFehler('Abgebrochen, nichts verschoben: Frage $id steht in keiner Kategorie der Sammlung $sammlung '
          '(oder ist verborgen, dann zeigt sie der Export nicht). Nummern mit fragen_lesen prüfen; gebraucht wird '
          'die aktuelle questionid.');
    }
    final f = quelle[k.id]!.firstWhere((f) => f.id == id);
    nameBestaetigen(name, f.name, 'Frage $id');
    gefunden.add(_Frage(f, k));
  }

  final zielKategorien = zielSammlung == sammlung ? quellKategorien : await kategorienLesen(moodle, zielSammlung);
  final ziel = kategorieWaehlen(zielKategorien, zielKategorie);
  if (ziel.kontext == null) throw MoodleFehler('Abgebrochen, nichts verschoben: Der Kontext der Zielkategorie „${ziel.name}" ist nicht erkennbar.');
  if (gefunden.any((g) => g.von.id == ziel.id)) {
    throw MoodleFehler('Abgebrochen, nichts verschoben: Eine der Fragen steht schon in der Kategorie „${ziel.name}".');
  }

  // Sachnummern sind je Kategorie eindeutig; Moodle prüft das beim Verschieben nicht, sondern hängt
  // still einen Suffix an. Nicht geprüft werden kann, was der Export nicht zeigt (verborgene Fragen).
  final imZiel = (await _inhalt(moodle, zielSammlung, [ziel]))[ziel.id]!;
  final belegt = <String, String>{};
  for (final f in imZiel) {
    if ((f.idnummer ?? '').isNotEmpty) belegt[f.idnummer!] = 'Frage ${f.id} „${f.name}"';
  }
  for (final g in gefunden) {
    final n = g.frage.idnummer ?? '';
    if (n.isEmpty) continue;
    final da = belegt[n];
    if (da != null) {
      throw MoodleFehler('Abgebrochen, nichts verschoben: Die Sachnummer „$n" von „${g.frage.name}" ist in der Kategorie '
          '„${ziel.name}" schon vergeben ($da). Eine der beiden Fragen vorher mit aendern umnummerieren.');
    }
    belegt[n] = 'Frage ${g.frage.id} „${g.frage.name}" (wird mit verschoben)';
  }
  return (fragen: gefunden, ziel: ziel, banken: banken, zielKategorien: zielKategorien);
}

Future<String> fragenVerschieben(MoodleZugang moodle, Freigaben freigaben,
    {required int kurs,
    required int sammlung,
    required List<(int, String)> fragen,
    required int zielSammlung,
    required String zielKategorie}) async {
  if (fragen.length > verschiebenHoechstzahl) {
    throw MoodleFehler('Höchstens $verschiebenHoechstzahl Fragen je Aufruf. Nichts verschoben.');
  }
  final p = await _pruefen(moodle,
      kurs: kurs, sammlung: sammlung, fragen: fragen, zielSammlung: zielSammlung, zielKategorie: zielKategorie);
  final ziel = p.ziel;
  final vorgaenge = {for (final g in p.fragen) g.frage.id!: Schreibvorgang(moodle, Formularziel.frage(sammlung, g.frage.id!))};
  for (final g in p.fragen) {
    if (vorgaenge[g.frage.id]!.offen) throw MoodleFehler('Frage ${g.frage.id}: ${vorgaenge[g.frage.id]!.hinweis}');
  }
  String bank(int cmid) => p.banken.firstWhere((b) => b.cmid == cmid).name;

  final ja = await freigaben.anfragen(FreigabeAnfrage(
    titel: fragen.length == 1 ? 'Frage verschieben?' : '${fragen.length} Fragen verschieben?',
    punkte: [
      'Von: Sammlung „${bank(sammlung)}" (cmid $sammlung)',
      'Nach: Sammlung „${bank(zielSammlung)}" (cmid $zielSammlung), Kategorie „${ziel.name}" (id ${ziel.id})',
      for (final g in p.fragen) '${_kopf(g.frage)} aus „${g.von.name}", mit allen Versionen',
      'Tests behalten die Frage (ihre Verweise zeigen auf die Frage, nicht auf die Kategorie). Zieht ein Zufallsplatz '
          'eines Tests Fragen aus einer der Quellkategorien, hat er danach weniger zur Auswahl.',
      'Nicht geprüft: Fragen, die der Export nicht zeigt (verborgene), auf eine gleiche Sachnummer im Ziel.',
    ],
    vergleich: const [],
    knopf: 'Verschieben',
  ));
  if (!ja) return 'Nicht verschoben: in der App abgelehnt oder nicht rechtzeitig freigegeben.';

  // Die Freigabe darf lange offen gewesen sein: Was freigegeben wurde, muss das sein, was jetzt verschoben würde (A3).
  try {
    final frisch = await _pruefen(moodle,
        kurs: kurs, sammlung: sammlung, fragen: fragen, zielSammlung: zielSammlung, zielKategorie: zielKategorie);
    if (frisch.ziel.id != ziel.id ||
        [for (final g in frisch.fragen) '${g.frage.id}/${g.von.id}'].join(',') !=
            [for (final g in p.fragen) '${g.frage.id}/${g.von.id}'].join(',')) {
      throw MoodleFehler('die Kategorien haben sich geändert');
    }
  } on MoodleFehler catch (e) {
    throw MoodleFehler('Abgebrochen, nichts verschoben: Seit der Freigabe hat sich etwas geändert (${e.meldung}). '
        'Neu lesen und neu freigeben lassen.');
  }

  // Eine Frage je Aufruf, die questionid der neuesten Version; der Eintrag zieht mit allen Versionen.
  // Nach der ersten Frage, deren Ausgang nicht eindeutig gut ist, hört die Schleife auf: Ein Fehler
  // an der Sitzung, am Schutzdienst, am Ziel oder an der Instanz wiederholte sich sonst für jede Frage.
  final b = StringBuffer();
  var alleGut = true;
  var fertig = 0;
  Object? abbruch;
  for (final g in p.fragen) {
    final vorgang = vorgaenge[g.frage.id]!;
    final kopf = _kopf(g.frage);
    vorgang.beginnen(
      {'kategorie': schreibPruefsumme('${g.von.id}|${g.frage.idnummer ?? ''}')},
      {'kategorie': schreibPruefsumme('${ziel.id}|${g.frage.idnummer ?? ''}')},
    );
    String? ursache;
    try {
      await moodle.dienst('core_question_move_questions', {
        'newcontextid': ziel.kontext,
        'newcategoryid': ziel.id,
        'questionids': '${g.frage.id}',
        // Pflicht: Ohne returnurl bricht Moodle 5.1 den Dienst mit einem Typfehler ab. Die Adresse wird nicht abgerufen.
        'returnurl': '/question/edit.php?cmid=$zielSammlung',
      });
    } on SitzungAbgelaufen catch (x) {
      // Der Aufruf kam vielleicht nicht an: Der Ausgang steht erst nach dem Zurücklesen fest, das ohne Sitzung scheitert.
      abbruch = x;
      ursache = x.meldung;
    } on SchutzPruefung catch (x) {
      abbruch = x;
      ursache = x.meldung;
    } on MoodleFehler catch (x) {
      ursache = x.meldung;
    } catch (x) {
      ursache = '${x.runtimeType}';
    }
    // Zurücklesen, auch nach einem Fehler: Der Ausgang muss feststehen (E37).
    final r = await _zuruecklesen(moodle, sammlung, zielSammlung, ziel, g);
    if (r.verschoben && r.gut) {
      // Eindeutig: Die Frage steht im Ziel, wie sie sein soll -- auch wenn Moodle einen Fehler meldete.
      vorgang.abschliessen();
      b.writeln('  verschoben${ursache == null ? '' : ', obwohl Moodle einen Fehler meldete ($ursache)'}: $kopf -- ${r.text}');
      fertig++;
      if (abbruch != null) break;
      continue;
    }
    alleGut = false;
    // Sitzung und Schutzdienst weisen den Aufruf ab, bevor Moodle etwas tut (wie vorher): Der Vorgang
    // bleibt dort nicht offen, eine Wiederholung nach neuer Anmeldung ist erlaubt.
    if (abbruch != null && !r.verschoben) vorgang.verwerfen();
    if (ursache != null) {
      b.writeln('  UNKLAR: $kopf -- Moodle hat den Aufruf abgelehnt oder er ist gescheitert ($ursache). ${r.text} ${vorgang.hinweis}');
    } else {
      b.writeln('  ${r.verschoben ? 'verschoben, aber Befund' : 'NICHT verschoben'}: $kopf -- ${r.text}');
      if (r.verschoben) {
        vorgang.abschliessen();
      } else {
        b.writeln('    ${vorgang.hinweis}');
      }
    }
    fertig++;
    break;
  }
  final offen = p.fragen.length - fertig;
  if (offen > 0) {
    alleGut = false;
    b.writeln('  Angehalten: $offen weitere Frage(n) wurden nicht angefasst, weil die letzte nicht eindeutig gut ausging. '
        'Mit fragen_lesen nachsehen, was wo steht, dann den Rest neu aufrufen.');
  }
  return '${alleGut ? 'Verschoben' : 'Nicht alles wie freigegeben verschoben'}: ${p.fragen.length} Frage(n) nach „${ziel.name}" '
      '(Sammlung $zielSammlung). verified: $alleGut\n$b'
      'Nicht geprüft: die Anzahl und der Inhalt älterer Versionen (ihr Verlauf ist gesperrt, A1) und die Verweise '
      'bestehender Tests; Moodle verschiebt den Eintrag mit allen Versionen und lässt Tests auf ihn zeigen.';
}

/// Die Kategorie mit ihrem jetzigen Stand (Fragenzahl): Nach dem Schreiben ist
/// die früher gelesene veraltet, und eine leer gelesene Kategorie wird nicht exportiert.
Future<Kategorie> _frisch(MoodleZugang moodle, int sammlung, Kategorie k) async =>
    (await kategorienLesen(moodle, sammlung)).firstWhere((x) => x.id == k.id);

/// Liest zurück, wo die Frage jetzt steht und ob ihre Sachnummer gleich blieb.
Future<({bool verschoben, bool gut, String text})> _zuruecklesen(
    MoodleZugang moodle, int sammlung, int zielSammlung, Kategorie ziel, _Frage g) async {
  try {
    final zielJetzt = await _frisch(moodle, zielSammlung, ziel);
    final imZiel = (await _inhalt(moodle, zielSammlung, [zielJetzt]))[ziel.id]!.where((f) => f.id == g.frage.id).firstOrNull;
    if (imZiel == null) {
      // Nicht gemessen: ob die questionid beim Verschieben gleich bleibt; fehlt sie im Ziel, gilt die Frage dort als nicht gefunden.
      final nochDa = (await _inhalt(moodle, sammlung, [await _frisch(moodle, sammlung, g.von)]))[g.von.id]!.any((f) => f.id == g.frage.id);
      return (
        verschoben: false,
        gut: false,
        text: nochDa ? 'Sie steht noch in der Quelle „${g.von.name}".' : 'Sie ist weder im Ziel noch in der Quelle zu finden; in Moodle nachsehen.'
      );
    }
    final alt = g.frage.idnummer ?? '', neu = imZiel.idnummer ?? '';
    if (alt != neu) {
      return (
        verschoben: true,
        gut: false,
        text: 'Sie steht im Ziel, aber Moodle hat die Sachnummer von „$alt" in „$neu" geändert (Kollision mit einer Frage, '
            'die der Export nicht zeigt, etwa einer verborgenen). Mit aendern in Ordnung bringen.'
      );
    }
    if (imZiel.name != g.frage.name || imZiel.typ != g.frage.typ) {
      return (verschoben: true, gut: false, text: 'Sie steht im Ziel, aber Name oder Typ weichen ab („${imZiel.name}", ${imZiel.typ}).');
    }
    return (verschoben: true, gut: true, text: 'steht im Ziel, Sachnummer unverändert.');
  } on MoodleFehler catch (e) {
    return (verschoben: false, gut: false, text: 'Das Zurücklesen scheiterte (${e.meldung}).');
  }
}
