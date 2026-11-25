// kategorie_aendern (E9, E20, E37): eine Fragenkategorie umbenennen oder mit
// ihren Unterkategorien und Fragen unter eine andere Kategorie verschieben,
// im selben Kurs, auch in eine andere Fragensammlung. Nichts wird gelöscht.
//
// Zwei Wege, wie ihn der Browser geht (E2):
//  - Umbenennen über das dynamische Bearbeitungsformular der Kategorie. Die
//    App schickt das Formular so zurück, wie sie es geladen hat, nur mit dem
//    neuen Namen: Beschreibung (roh, `info[text]`), Sachnummer und Eltern
//    bleiben, wie Moodle sie lieferte. Moodle schickt die Beschreibung beim
//    Speichern durch format_text und speichert das Ergebnis; ob sich dadurch
//    etwas ändert, zeigt das Zurücklesen (nicht gemessen, Befund wird genannt).
//  - Verschieben über den Dienst qbank_managecategories_move_category, den die
//    Verwaltungsoberfläche per Ziehen und Ablegen aufruft: Name, Beschreibung
//    und Sachnummer bleiben dabei unverändert. Wer beides verlangt, verschiebt
//    zuerst und benennt danach um (zwei Rücklesungen).
//
// Moodle schützt nicht vor Zyklen, nicht vor gleichen Namen unter einem
// Elternteil und ignoriert den Elternwechsel still, wenn die Kategorie das
// einzige Kind der obersten Kategorie ist; die App prüft das vorher und liest
// danach zurück. Nicht aus dem Quelltext von Moodle 5.1 belegt (questionlib.php
// liegt nicht vor) und am Testkurs zu messen, hier mit "nicht gemessen" markiert:
//  - dass die Top-Kategorie einer Sammlung als zusätzliche Option im Exportformular
//    steht (`select[name=category]`, Eintrag, der im Importformular fehlt);
//    sonst ist "oberste Ebene" nicht zu ermitteln und das Werkzeug bricht ab;
//  - dass `question_move_category_to_context` Dateien der Fragen und alle
//    Unterkategorien mitnimmt, dass Zufallsplätze von Tests, die aus einer
//    Unterkategorie ziehen, mitziehen und dass Quiz-Verweise (feste Fragen)
//    halten: die Antwort nennt das "nicht geprüft";
//  - dass Moodle bei einem Wechsel der Sammlung die Sachnummern der
//    Unterkategorien im Zielkontext prüft: die App prüft sie vorab selbst
//    (nur lesbar über das Formular jeder Kategorie).

import 'package:html/parser.dart' as html_parser;

import '../freigabe.dart';
import 'formular.dart';
import 'formular_lesen.dart';
import 'formular_schreiben.dart';
import 'fragen.dart';
import 'kurs.dart';
import 'moodle_zugang.dart';
import 'schreibvorgang.dart';

const _formMarke = '_qf__qbank_managecategories_form_question_category_edit_form';

/// Die Kategorie samt ihrem Teilbaum, wie ihn die Liste der Sammlung zeigt.
class _Baum {
  _Baum(this.alle, this.index);
  final List<Kategorie> alle;
  final int index;
  Kategorie get wurzel => alle[index];

  /// Die Wurzel und alles darunter (Einträge der Liste mit größerer Tiefe).
  List<Kategorie> get teil {
    final aus = [wurzel];
    for (var i = index + 1; i < alle.length && alle[i].tiefe > wurzel.tiefe; i++) {
      aus.add(alle[i]);
    }
    return aus;
  }

  /// Der Elternteil in der Liste; null: die oberste Ebene (Top-Kategorie).
  Kategorie? get eltern {
    for (var i = index - 1; i >= 0; i--) {
      if (alle[i].tiefe == wurzel.tiefe - 1) return alle[i];
    }
    return null;
  }

  /// Namen der Kinder des Elternteils [eltern] (null: der obersten Ebene).
  static List<Kategorie> kinder(List<Kategorie> alle, Kategorie? eltern) {
    final aus = <Kategorie>[];
    var i = eltern == null ? 0 : alle.indexWhere((k) => k.id == eltern.id) + 1;
    final tiefe = eltern == null ? 0 : eltern.tiefe + 1;
    for (; i < alle.length; i++) {
      if (eltern != null && alle[i].tiefe <= eltern.tiefe) break;
      if (alle[i].tiefe == tiefe) aus.add(alle[i]);
    }
    return aus;
  }
}

String _pfad(List<Kategorie> alle, Kategorie? k, String bank) {
  if (k == null) return 'oberste Ebene von „$bank"';
  final namen = <String>[k.name];
  var tiefe = k.tiefe;
  for (var i = alle.indexWhere((x) => x.id == k.id) - 1; i >= 0 && tiefe > 0; i--) {
    if (alle[i].tiefe == tiefe - 1) {
      namen.insert(0, alle[i].name);
      tiefe--;
    }
  }
  return '„$bank" › ${namen.join(' › ')}';
}

/// Das Bearbeitungsformular einer Kategorie, wie Moodle es liefert.
Future<Felder> _formular(MoodleZugang moodle, int sammlung, Kategorie k) async {
  final r = await moodle.dienst('core_form_dynamic_form', {
    'form': kategorieFormular,
    'formdata': 'cmid=$sammlung&contextid=${k.kontext}&courseid=0&categoryid=${k.id}&actiontype=edit',
  });
  final html = (r is Map ? r['html'] : null) as String? ?? '';
  if (html.isEmpty) throw MoodleFehler('Das Formular der Kategorie „${k.name}" (id ${k.id}) ließ sich nicht laden.');
  final d = html_parser.parse(html);
  return formularFelder(d.querySelector('form') ?? d.body!);
}

String? _feld(Felder f, String name) => f.where((e) => e.key == name).map((e) => e.value).lastOrNull;

/// Die oberste Kategorie einer Sammlung, ohne Namen zu raten: Das Exportformular
/// bietet sie (mit `top: true`) zusätzlich an, das Importformular nicht.
/// Nicht gemessen: ob Moodle 5.1 das so tut; sonst Abbruch.
Future<String> _topWert(MoodleZugang moodle, int sammlung, List<Kategorie> kats) async {
  final r = await moodle.lesen('/question/bank/exportquestions/export.php?cmid=$sammlung');
  final sel = html_parser.parse(r.text).querySelector('select[name="category"]');
  final bekannt = {for (final k in kats) k.wert};
  final mehr = [
    for (final o in sel?.querySelectorAll('option') ?? const [])
      if (o.attributes['value'] != null && !bekannt.contains(o.attributes['value'])) o.attributes['value']!
  ];
  if (mehr.length != 1) {
    throw MoodleFehler('Abgebrochen, nichts geändert: Die oberste Ebene der Sammlung $sammlung ist nicht zu ermitteln '
        '(das Exportformular nennt sie nicht eindeutig). Eine Kategorie der Sammlung als Ziel nennen, oder in Moodle '
        'verschieben.');
  }
  return mehr.single;
}

/// Alles, was vor der Freigabe und noch einmal danach feststehen muss.
class _Plan {
  _Plan({
    required this.baum,
    required this.neuerName,
    required this.verschieben,
    required this.sammlung,
    required this.zielSammlung,
    required this.zielKats,
    required this.zielEltern,
    required this.zielWert,
    required this.banken,
    required this.formular,
  });
  final _Baum baum;
  final String? neuerName;
  final bool verschieben;
  final int sammlung, zielSammlung;
  final List<Kategorie> zielKats;

  /// Der neue Elternteil; null: die oberste Ebene der Zielsammlung.
  final Kategorie? zielEltern;

  /// `<id>,<kontext>` des neuen Elternteils (bei der obersten Ebene der Top-Kategorie).
  final String zielWert;
  final List<Fragensammlung> banken;

  /// Das Formular der Kategorie, wie es vor dem Schreiben geladen wurde.
  final Felder formular;

  Kategorie get k => baum.wurzel;
  String get endName => neuerName ?? k.name;
  String bank(int cmid) => banken.firstWhere((b) => b.cmid == cmid).name;

  /// Was die Freigabe gesehen hat und was nach ihr noch gelten muss.
  String get unterschrift => [
        k.id,
        baum.eltern?.id,
        zielEltern?.id ?? zielWert,
        neuerName,
        for (final x in baum.teil) '${x.id}/${x.name}/${x.anzahl}/${x.tiefe}',
        _feld(formular, 'idnumber'),
        _feld(formular, 'info[text]'),
      ].join('|');
}

Future<_Plan> _pruefen(MoodleZugang moodle,
    {required int kurs,
    required int sammlung,
    required int kategorie,
    required String name,
    required String? neuerName,
    required int? zielSammlung,
    required String? zielEltern}) async {
  final wirdVerschoben = zielSammlung != null || (zielEltern != null && zielEltern.isNotEmpty);
  if (neuerName != null && neuerName.trim().isEmpty) throw MoodleFehler('Der neue Name ist leer.');
  final ziel = zielSammlung ?? sammlung;

  final banken = await fragensammlungenLesen(moodle, kurs);
  for (final (s, was) in [(sammlung, 'Die Sammlung'), (ziel, 'Die Zielsammlung')]) {
    if (!banken.any((b) => b.cmid == s)) {
      throw MoodleFehler('Abgebrochen, nichts geändert: $was (cmid $s) gehört nicht zu Kurs $kurs. '
          'Verschoben wird nur innerhalb eines Kurses; die Sammlungen mit fragensammlungen nachsehen.');
    }
  }

  final kats = await kategorienLesen(moodle, sammlung);
  final i = kats.indexWhere((k) => k.id == kategorie);
  if (i < 0) {
    throw MoodleFehler('Abgebrochen, nichts geändert: Kategorie $kategorie gibt es in Sammlung $sammlung nicht. Die oberste '
        'Kategorie einer Sammlung lässt sich weder umbenennen noch verschieben. Vorhanden:\n'
        '${kats.map((k) => '  ${k.id} „${k.name}" (${k.anzahl})').join('\n')}');
  }
  final baum = _Baum(kats, i);
  final k = baum.wurzel;
  nameBestaetigen(name, k.name, 'Kategorie $kategorie');
  if (k.kontext == null) {
    throw MoodleFehler('Abgebrochen, nichts geändert: Der Kontext der Kategorie „${k.name}" ist nicht erkennbar.');
  }
  final umbenennen = neuerName != null && neuerName != k.name;
  if (!umbenennen && !wirdVerschoben) {
    throw MoodleFehler('Nichts zu ändern: Weder ein neuer Name noch ein neuer Elternteil genannt (oder der Name ist schon so).');
  }
  final endName = umbenennen ? neuerName : k.name;

  // Namen unter dem jetzigen Elternteil (Umbenennen ohne Verschieben).
  if (umbenennen && !wirdVerschoben) {
    final geschwister = _Baum.kinder(kats, baum.eltern).where((x) => x.id != k.id);
    if (geschwister.any((x) => x.name == endName)) {
      throw MoodleFehler('Abgebrochen, nichts geändert: Unter „${baum.eltern?.name ?? 'der obersten Ebene'}" gibt es schon eine '
          'Kategorie „$endName".');
    }
  }

  var zielKats = kats;
  Kategorie? zielK;
  var zielWert = '';
  if (wirdVerschoben) {
    if (k.tiefe == 0 && kats.where((x) => x.tiefe == 0).length == 1) {
      throw MoodleFehler('Abgebrochen, nichts geändert: „${k.name}" ist die einzige Kategorie unter der obersten Ebene der '
          'Sammlung und lässt sich nicht verschieben (Moodle ließe die Sammlung ohne Kategorie). Umbenennen geht.');
    }
    zielKats = ziel == sammlung ? kats : await kategorienLesen(moodle, ziel);
    if (zielEltern == null || zielEltern.isEmpty) {
      zielWert = await _topWert(moodle, ziel, zielKats);
    } else {
      zielK = kategorieWaehlen(zielKats, zielEltern);
      zielWert = zielK.wert;
      if (ziel == sammlung && baum.teil.any((x) => x.id == zielK!.id)) {
        throw MoodleFehler('Abgebrochen, nichts geändert: Eine Kategorie lässt sich nicht in sich selbst oder in eine ihrer '
            'Unterkategorien verschieben („${zielK.name}" liegt darin).');
      }
    }
    final schon = ziel == sammlung && (zielK == null ? k.tiefe == 0 : baum.eltern?.id == zielK.id);
    if (schon) {
      throw MoodleFehler('Abgebrochen, nichts geändert: „${k.name}" steht schon unter '
          '„${zielK?.name ?? 'der obersten Ebene'}". Soll nur der Name wechseln, ohne Ziel aufrufen.');
    }
    if (_Baum.kinder(zielKats, zielK).any((x) => x.name == endName)) {
      throw MoodleFehler('Abgebrochen, nichts geändert: Unter „${zielK?.name ?? 'der obersten Ebene'}" gibt es schon eine '
          'Kategorie „$endName". Moodle erlaubt das, aber die Kategorien wären nicht mehr zu unterscheiden; einen anderen Namen wählen.');
    }
  }

  final formular = await _formular(moodle, sammlung, k);
  if (_feld(formular, 'name') == null) {
    throw MoodleFehler('Abgebrochen, nichts geändert: Das Formular der Kategorie „${k.name}" hat kein Feld „name".');
  }

  // Sachnummern sind je Fragensammlung (Kontext) eindeutig. Beim Wechsel der Sammlung prüft Moodle das für die
  // Kategorie selbst, für ihre Unterkategorien nicht (nicht gemessen): Die App liest sie vorab und vergleicht.
  if (wirdVerschoben && ziel != sammlung) {
    final meine = <String, String>{};
    for (final x in baum.teil) {
      final n = x.id == k.id ? _feld(formular, 'idnumber') : _feld(await _formular(moodle, sammlung, x), 'idnumber');
      if (n != null && n.isNotEmpty) meine[n] = x.name;
    }
    if (meine.isNotEmpty) {
      for (final x in zielKats) {
        final n = _feld(await _formular(moodle, ziel, x), 'idnumber');
        if (n != null && meine.containsKey(n)) {
          throw MoodleFehler('Abgebrochen, nichts geändert: Die Sachnummer „$n" von „${meine[n]}" ist in der Zielsammlung '
              'schon an „${x.name}" vergeben. Eine der beiden Kategorien in Moodle umnummerieren.');
        }
      }
    }
  }

  return _Plan(
    baum: baum,
    neuerName: umbenennen ? neuerName : null,
    verschieben: wirdVerschoben,
    sammlung: sammlung,
    zielSammlung: ziel,
    zielKats: zielKats,
    zielEltern: zielK,
    zielWert: zielWert,
    banken: banken,
    formular: formular,
  );
}

/// Was beim Zurücklesen herauskam.
class _Stand {
  _Stand(this.erreicht, this.befunde, this.nichtGeprueft);

  /// Die Kategorie steht dort, mit dem Namen und unter dem Elternteil, die verlangt waren.
  final bool erreicht;
  final List<String> befunde, nichtGeprueft;
  bool get gut => erreicht && befunde.isEmpty;
}

/// Liest zurück, wo die Kategorie jetzt steht. [sammlung]: wo sie stehen soll;
/// [name]: wie sie heißen soll; [eltern]: unter wem (null: oberste Ebene).
Future<_Stand> _zuruecklesen(MoodleZugang moodle, _Plan p,
    {required int sammlung, required String name, required Kategorie? eltern, required String elternWert}) async {
  final befunde = <String>[], nicht = <String>[];
  try {
    final kats = await kategorienLesen(moodle, sammlung);
    final i = kats.indexWhere((x) => x.id == p.k.id);
    if (i < 0) {
      return _Stand(false, ['Die Kategorie steht nicht (mehr) in Sammlung $sammlung.'], nicht);
    }
    final jetzt = _Baum(kats, i);
    var ort = true;
    if (jetzt.wurzel.name != name) {
      ort = false;
      befunde.add('Der Name ist „${jetzt.wurzel.name}", verlangt war „$name".');
    }
    if (eltern == null ? jetzt.wurzel.tiefe != 0 : jetzt.eltern?.id != eltern.id) {
      ort = false;
      befunde.add('Sie steht unter „${jetzt.eltern?.name ?? 'der obersten Ebene'}", nicht dort, wo sie hin sollte.');
    }
    // Teilbaum: gleiche Unterkategorien in gleicher Anordnung und mit gleicher Fragenzahl.
    String form(List<Kategorie> t, int basis, String wurzelName) => [
          for (final (n, x) in t.indexed) '${x.tiefe - basis}|${n == 0 ? wurzelName : x.name}|${x.anzahl}'
        ].join('\n');
    if (form(jetzt.teil, jetzt.wurzel.tiefe, name) != form(p.baum.teil, p.k.tiefe, name)) {
      befunde.add('Die Unterkategorien oder ihre Fragenzahlen weichen ab (jetzt: '
          '${jetzt.teil.map((x) => '„${x.name}" (${x.anzahl})').join(', ')}).');
    }
    if (sammlung != p.sammlung) {
      final quelle = await kategorienLesen(moodle, p.sammlung);
      if (quelle.any((x) => p.baum.teil.any((t) => t.id == x.id))) {
        befunde.add('In der Quellsammlung steht noch mindestens eine der Kategorien.');
      }
    }
    // Das Formular: Eltern exakt, Beschreibung und Sachnummer unverändert.
    try {
      final f = await _formular(moodle, sammlung, jetzt.wurzel);
      if (_feld(f, 'name') != name) {
        ort = false;
        befunde.add('Das Formular zeigt den Namen „${_feld(f, 'name')}".');
      }
      final eltern0 = _feld(f, 'parent');
      if (eltern0 == null) {
        nicht.add('der Elternteil im Formular (es zeigt ihn nicht)');
      } else if (eltern0.split(',').first != elternWert.split(',').first) {
        ort = false;
        befunde.add('Das Formular zeigt einen anderen Elternteil ($eltern0).');
      }
      if ((_feld(f, 'idnumber') ?? '') != (_feld(p.formular, 'idnumber') ?? '')) {
        befunde.add('Die Sachnummer der Kategorie hat sich geändert.');
      }
      if ((_feld(f, 'info[text]') ?? '') != (_feld(p.formular, 'info[text]') ?? '')) {
        befunde.add('Die Beschreibung der Kategorie hat sich geändert (Moodle bereitet sie beim Speichern auf).');
      }
    } on MoodleFehler catch (e) {
      nicht.add('Elternteil, Beschreibung und Sachnummer im Formular (${e.meldung})');
    }
    return _Stand(ort, befunde, nicht);
  } on MoodleFehler catch (e) {
    return _Stand(false, ['Das Zurücklesen scheiterte (${e.meldung}).'], nicht);
  }
}

Future<String> kategorieAendern(MoodleZugang moodle, Freigaben freigaben,
    {required int kurs,
    required int sammlung,
    required int kategorie,
    required String name,
    String? neuerName,
    int? zielSammlung,
    String? zielEltern}) async {
  Future<_Plan> pruefen() => _pruefen(moodle,
      kurs: kurs,
      sammlung: sammlung,
      kategorie: kategorie,
      name: name,
      neuerName: neuerName,
      zielSammlung: zielSammlung,
      zielEltern: zielEltern);
  final p = await pruefen();
  final k = p.k;
  final vorgang = Schreibvorgang(moodle, Formularziel.kategorie(sammlung, k.id));
  if (vorgang.offen) throw MoodleFehler(vorgang.hinweis);

  final von = _pfad(p.baum.alle, p.baum.eltern, p.bank(sammlung));
  final nach = _pfad(p.zielKats, p.zielEltern, p.bank(p.zielSammlung));
  final teil = p.baum.teil.skip(1).toList();
  final ja = await freigaben.anfragen(FreigabeAnfrage(
    titel: p.verschieben ? (p.neuerName == null ? 'Kategorie verschieben?' : 'Kategorie verschieben und umbenennen?') : 'Kategorie umbenennen?',
    punkte: [
      'Kategorie „${k.name}" (id ${k.id}, ${k.anzahl} Fragen) in Sammlung „${p.bank(sammlung)}" (cmid $sammlung)',
      if (p.verschieben) 'Von: $von' else 'Lage: $von',
      if (p.verschieben) 'Nach: $nach',
      if (p.neuerName != null) 'Neuer Name: „${p.neuerName}" (bisher „${k.name}")',
      teil.isEmpty
          ? 'Keine Unterkategorien.'
          : 'Mit ihren Unterkategorien: ${teil.map((x) => '„${x.name}" (${x.anzahl} Fragen)').join(', ')}',
      'Nichts wird gelöscht; Fragen und Unterkategorien bleiben in der Kategorie.',
      if (p.verschieben && p.zielSammlung != sammlung)
        'Andere Fragensammlung: Die Kategorien und ihre Fragen gehören danach zu „${p.bank(p.zielSammlung)}".',
      if (p.verschieben)
        'Zieht ein Zufallsplatz eines Tests Fragen aus dieser Kategorie oder einer Unterkategorie, kann er sich ändern: '
            'nicht geprüft.',
    ],
    vergleich: const [],
    knopf: p.verschieben ? 'Verschieben' : 'Umbenennen',
  ));
  if (!ja) return 'Nicht geändert: in der App abgelehnt oder nicht rechtzeitig freigegeben.';

  // Die Freigabe darf lange offen gewesen sein: Was freigegeben wurde, muss das sein, was jetzt geschieht (A3).
  try {
    if ((await pruefen()).unterschrift != p.unterschrift) throw MoodleFehler('die Kategorien oder das Formular haben sich geändert');
  } on MoodleFehler catch (e) {
    throw MoodleFehler('Abgebrochen, nichts geändert: Seit der Freigabe hat sich etwas geändert (${e.meldung}). '
        'Neu lesen und neu freigeben lassen.');
  }

  final elternVorher = _feld(p.formular, 'parent') ?? '';
  vorgang.beginnen(
    {'ort': schreibPruefsumme('${p.baum.eltern?.id}|${k.name}')},
    {'ort': schreibPruefsumme('${p.zielEltern?.id ?? p.zielWert}|${p.endName}')},
  );
  final b = StringBuffer();
  String? ursache;
  Future<void> versuche(Future<void> Function() tun) async {
    ursache = null;
    try {
      await tun();
    } on SitzungAbgelaufen {
      vorgang.verwerfen();
      rethrow;
    } on SchutzPruefung {
      vorgang.verwerfen();
      rethrow;
    } on MoodleFehler catch (x) {
      ursache = x.meldung;
    } catch (x) {
      ursache = '${x.runtimeType}';
    }
  }

  var bank = sammlung;
  var elternK = p.baum.eltern;
  var elternWert = elternVorher;
  var stand = _Stand(true, const [], const []);
  if (p.verschieben) {
    await versuche(() async {
      await moodle.dienst('qbank_managecategories_move_category', {
        'pagecontextid': k.kontext,
        'categoryid': k.id,
        'targetparentid': int.parse(p.zielWert.split(',').first),
        // Ganz oben unter dem neuen Elternteil; die Reihenfolge der Geschwister ist nicht Sache dieses Werkzeugs.
        'precedingsiblingid': null,
      });
    });
    bank = p.zielSammlung;
    elternK = p.zielEltern;
    elternWert = p.zielWert;
    // Beim Verschieben bleibt der Name, wie er war.
    stand = await _zuruecklesen(moodle, p, sammlung: bank, name: k.name, eltern: elternK, elternWert: elternWert);
    if (ursache != null || !stand.erreicht) {
      b.writeln('UNKLAR: Moodle hat den Aufruf abgelehnt oder die Kategorie steht nicht dort${ursache == null ? '' : ' ($ursache)'}.');
      for (final x in stand.befunde) {
        b.writeln('  $x');
      }
      b.writeln('  ${vorgang.hinweis}');
      return 'NICHT wie freigegeben verschoben: Kategorie „${k.name}" (id ${k.id}). verified: false\n$b';
    }
  }

  if (p.neuerName != null) {
    await versuche(() async {
      // Das Formular der Kategorie dort, wo sie jetzt steht; Beschreibung, Sachnummer und Eltern bleiben, wie geliefert.
      final felder = await _formular(moodle, bank, (await kategorienLesen(moodle, bank)).firstWhere((x) => x.id == k.id));
      setze(felder, 'name', p.neuerName!);
      setze(felder, _formMarke, '1');
      final daten = felder.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
      final r = await moodle.dienst('core_form_dynamic_form', {'form': kategorieFormular, 'formdata': daten});
      if (r is! Map || r['submitted'] != true) throw MoodleFehler('Moodle hat das Formular nicht angenommen.');
    });
    stand = await _zuruecklesen(moodle, p, sammlung: bank, name: p.endName, eltern: elternK, elternWert: elternWert);
  }

  final alt = p.verschieben ? ' (vorher: $von)' : '';
  if (stand.erreicht) vorgang.abschliessen();
  if (ursache != null) b.writeln('Moodle meldete beim Umbenennen: $ursache');
  for (final x in stand.befunde) {
    b.writeln('Befund: $x');
  }
  if (!stand.erreicht) b.writeln(vorgang.hinweis);
  final gut = stand.gut && ursache == null;
  b.writeln('Nicht geprüft: ${[
    ...stand.nichtGeprueft,
    'Zufallsplätze und feste Fragen in Tests',
    if (p.verschieben && p.zielSammlung != sammlung) 'Dateien der Fragen (Bilder in Fragetexten) nach dem Wechsel der Sammlung',
    'die Reihenfolge unter den Geschwistern',
  ].join('; ')}.');
  return '${gut ? 'Geändert' : 'Nicht alles wie freigegeben geändert'}: Kategorie „${p.endName}" (id ${k.id})'
      '${p.verschieben ? ' nach $nach' : ''}$alt. verified: $gut\n$b';
}
