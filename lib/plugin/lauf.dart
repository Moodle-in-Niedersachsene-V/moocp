// Ein Lauf (E36): Ein Plugin meldet bei der App an, um welche Aktivität es
// gerade geht; erst dann liest es über seine Zusatzadressen mit der Art
// „lesen“. Hinter jeder Zusatzadresse ist mit Namen zu rechnen, denn sie hebt
// die Sperrliste auf. Darum ermittelt die App beim Beginn selbst den Kurs der
// Aktivität, liest selbst die Namen seiner Teilnehmenden, nur für die letzte
// Sperre (namenssperre.dart), und bindet jede Anfrage des Laufs an diesen
// Kurs und diese Aktivität ([laufBindungVerletzt]).
//
// Ein Lauf gehört zu einem Plugin, einem Instanzprofil und einem Aufruf; je
// Aufruf läuft höchstens einer zugleich. Er endet, wenn das Plugin ihn beendet
// oder der Aufruf endet oder abgebrochen wird, auch weil das Plugin abstürzt.
// Die Namen bleiben danach für die Datenschutzprüfung geladen, bis die App endet;
// was der Lauf über Zusatzadressen heruntergeladen hat (downloads.dart),
// löscht sein Ende. Die Funktionen der Adresse der App stehen in
// app_adresse.dart, das Lesen selbst in moodle_schreiben.dart (ZusatzLeser);
// hier stehen der Beginn und die Regeln.
//
// Der Beginn hält sich an „im Zweifel kein Lauf“: Lässt sich der Kurs nicht
// ermitteln, die Teilnehmendenseite nicht lesen oder nicht sicher auswerten,
// beginnt kein Lauf, und lesende Zusatzadressen bleiben gesperrt. Ein Lauf mit
// unvollständiger Namensliste wäre schlimmer als keiner.
//
// Keine Meldung hier nennt einen Namen oder die Zahl der Teilnehmenden: Sie
// gehen an das Plugin und ins Protokoll.

import 'dart:async';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../moodle/formular_lesen.dart' show Seitenangaben;
import '../moodle/moodle_zugang.dart';
import 'adressmuster.dart';
import 'namenssperre.dart';

/// Warum ein Lauf nicht beginnen kann, als deutscher Satz ohne Namen und
/// ohne Zahl der Teilnehmenden.
class LaufFehler implements Exception {
  const LaufFehler(this.grund);
  final String grund;

  /// Ohne den Grund: Ein Fehler, der versehentlich in einer Ausgabe landet,
  /// trägt nichts aus Moodle mit (E11).
  @override
  String toString() => 'LaufFehler';
}

/// Ein Lauf: Kurs und Aktivität, die die App selbst ermittelt hat, und die
/// Kontexte, die zu ihnen gehören, soweit Moodle sie genannt hat.
class Lauf {
  Lauf({required this.kurs, required this.cmid, this.kurskontext, this.modulkontext});

  final int kurs;
  final int cmid;

  /// Der Kontext des Kurses (aus der Teilnehmendenseite) und der Aktivität
  /// (aus ihrem Bearbeitungsformular); null, wenn die Seite ihn nicht nannte.
  /// Ohne ihn lehnt der Lauf jede Anfrage ab, die einen Kontext nennt.
  final int? kurskontext;
  final int? modulkontext;

  final _ende = Completer<void>();

  /// Erfüllt sich, wenn der Lauf endet; was das Plugin dann noch liest, geht
  /// nicht mehr hinaus.
  Future<void> get ende => _ende.future;
  bool get vorbei => _ende.isCompleted;

  /// Die Dateien, die dieser Lauf über Zusatzadressen lädt oder geladen hat
  /// (downloads.dart).
  final _dateien = <File>[];

  /// Merkt sich [datei], bevor sie geladen wird: [beenden] löscht sie und
  /// ihren unfertigen Teil (`.teil`). Ist der Lauf schon vorbei, gleich.
  void dateiMerken(File datei) {
    _dateien.add(datei);
    if (vorbei) _dateienLoeschen();
  }

  /// Beendet den Lauf und löscht, was er geladen hat, gleich und ohne zu
  /// warten: Wer danach nachsieht, findet nichts mehr. Eine Datei, die gerade
  /// noch geschrieben wird, löscht das Laden selbst, wenn es abbricht
  /// (MoodleZugang.herunterladenAls), oder die Adresse der App, wenn es im
  /// selben Augenblick fertig wurde (app_adresse.dart).
  void beenden() {
    if (!_ende.isCompleted) _ende.complete();
    _dateienLoeschen();
  }

  void _dateienLoeschen() {
    for (final d in _dateien) {
      for (final f in [d, File('${d.path}.teil')]) {
        try {
          if (f.existsSync()) f.deleteSync();
        } on FileSystemException {
          // In Benutzung: Das Laden räumt seinen Teil selbst weg, und spätestens
          // das Beenden der App leert den Ordner.
        }
      }
    }
  }
}

/// Was der Beginn eines Laufs ermittelt hat: der Lauf und die Namen der
/// Teilnehmenden für die Datenschutzprüfung. Die Namen gehen nur an die letzte
/// Sperre, nie an das Plugin, in ein Protokoll oder eine Datei.
typedef LaufBeginn = ({Lauf lauf, List<String> namen});

/// Beginnt einen Lauf für die Aktivität [cmid] mit der Sitzung von [moodle]:
/// zuerst der Kurs ([kursAusFormular]), dann die Namen seiner Teilnehmenden
/// ([teilnehmendeAuswerten]). Wirft [LaufFehler], wenn etwas davon nicht
/// sicher gelingt, und [MoodleFehler], wenn Moodle nicht antwortet.
Future<LaufBeginn> laufVorbereiten(MoodleZugang moodle, int cmid) async {
  // Mit den eingebauten Werkzeugen der App: Das Bearbeitungsformular steht für
  // sie auf der Positivliste, und das Plugin sieht es nicht.
  final formular = await moodle.lesen('/course/modedit.php?update=$cmid');
  final (:kurs, :modulkontext) = kursAusFormular(formular, cmid);
  final seite = await moodle.teilnehmendenseiteLesen(kurs);
  final (:namen, :kurskontext) = teilnehmendeAuswerten(seite, kurs);
  return (
    lauf: Lauf(kurs: kurs, cmid: cmid, kurskontext: kurskontext, modulkontext: modulkontext),
    namen: namen,
  );
}

/// Der Kurs der Aktivität [cmid] aus ihrem Bearbeitungsformular
/// (`/course/modedit.php?update=<cmid>`), nie aus einer Angabe des Plugins.
/// Zwei Merkmale müssen übereinstimmen: `courseId` in `M.cfg` der Seite und
/// das versteckte Feld `course` des Formulars, das auch das Feld
/// `coursemodule` mit genau dieser Aktivität trägt (moodleform_mod setzt
/// beide). Dazu der Kontext der Aktivität aus `M.cfg` (`contextid`); fehlt er,
/// bleibt er unbekannt. Wirft [LaufFehler].
({int kurs, int? modulkontext}) kursAusFormular(Antwort r, int cmid) {
  if (r.status != 200 || r.adresse.path != '/course/modedit.php' || r.inhaltstyp != 'text/html') {
    throw LaufFehler(
      'Der Kurs der Aktivität ließ sich nicht ermitteln: Ihr Bearbeitungsformular ist nicht abrufbar '
      '(HTTP ${r.status}). Gibt es die Aktivität, und darf das angemeldete Konto sie bearbeiten?',
    );
  }
  final seite = Seitenangaben.aus(r.text);
  final doc = html_parser.parse(r.text);
  final formulare = [
    for (final f in doc.querySelectorAll('form'))
      if (f.querySelector('input[name="coursemodule"]') != null) f,
  ];
  String? wert(dom.Element f, String name) => f.querySelector('input[name="$name"]')?.attributes['value'];
  final kurs = seite.kurs;
  if (kurs == null ||
      formulare.length != 1 ||
      wert(formulare.single, 'coursemodule') != '$cmid' ||
      wert(formulare.single, 'course') != '$kurs') {
    throw const LaufFehler(
      'Der Kurs der Aktivität ließ sich nicht sicher ermitteln: Das Bearbeitungsformular nennt ihn nicht '
      'eindeutig.',
    );
  }
  return (kurs: kurs, modulkontext: _zahl(seite.kontext));
}

int? _zahl(String? s) => s != null && RegExp(r'^[1-9]\d{0,9}$').hasMatch(s) ? int.parse(s) : null;

/// Die Namen aller Teilnehmenden des Kurses [kurs] aus seiner
/// Teilnehmendenseite (`/user/index.php?id=<Kurs>&perpage=5000&tifirst=&tilast=`,
/// MoodleZugang.teilnehmendenseiteLesen), dazu der Kontext des Kurses aus
/// `M.cfg`. Wirft [LaufFehler], wenn die Seite nicht sicher auszuwerten ist.
///
/// Was hier über die Seite angenommen ist, nach Moodles Standardseite (Moodle
/// 4.x, Theme Boost), nicht an einer Instanz gemessen:
///
/// - Die Tabelle hat die id `participants` (oder die eindeutige Kennung der
///   Tabelle, `user-index-participants-<Kurs>`); jede Person steht in einer Zeile
///   von `tbody`, mit einem Link auf `/user/view.php?id=<Person>&course=<Kurs>`,
///   dessen Text der volle Name ist. Davor steht im Link das Bild (`img`) oder
///   ein Kürzel aus den Initialen (`span.userinitials`, mit dem vollen Namen
///   in `title`); beides gehört nicht zum Namen. Zeilen mit der Klasse
///   `emptyrow` füllt Moodle leer auf.
/// - Über der Tabelle steht die Gesamtzahl (`data-region="participant-count"`,
///   „N Teilnehmer/innen gefunden“). Sie muss genau eine Zahl enthalten und
///   gleich der Zahl der gelesenen Personen sein.
/// - `perpage=5000` ist Moodles „alle zeigen“; gibt es dennoch eine zweite
///   Seite (Links mit `page=` größer 0 oder `data-page-number` größer 1),
///   ist die Liste unvollständig.
/// - Moodle merkt sich einen Filter nach Anfangsbuchstaben je Tabelle;
///   `tifirst=&tilast=` setzt ihn zurück, und ist dennoch ein anderer
///   Buchstabe als „Alle“ gewählt (`.initialbar` mit aktivem Eintrag außer
///   `initialbarall`), ist die Liste unvollständig.
/// - Inaktive und gesperrte Einschreibungen zeigt die Seite einer Lehrkraft
///   mit dem Recht `moodle/course:enrolreview` mit an; ob ein Standardfilter
///   sie ausblendet, ist nicht gemessen. Ohne `moodle/site:accessallgroups`
///   zeigt Moodle in Kursen mit getrennten Gruppen nur die eigenen Gruppen;
///   die Gesamtzahl zählt dann dieselbe Auswahl, das fällt hier nicht auf.
///
/// Jede Abweichung von diesem Aufbau führt zum Abbruch, nie zu einer Liste mit
/// weniger Namen: keine Gesamtzahl, Zahl passt nicht, eine Zeile ohne Link auf
/// eine Person oder mit mehreren, ein Link auf einen anderen Kurs, ein Name
/// ohne Buchstaben, ein Kürzel, dessen Name nicht zum Link passt. Ein Kurs ohne
/// Teilnehmende (Gesamtzahl 0, keine Person auf der Seite) ist kein Fehler.
({List<String> namen, int? kurskontext}) teilnehmendeAuswerten(Antwort r, int kurs) {
  if (r.status != 200 || r.adresse.path != '/user/index.php' || r.inhaltstyp != 'text/html') {
    throw LaufFehler('Die Teilnehmendenseite des Kurses ist nicht abrufbar (HTTP ${r.status}).');
  }
  final text = r.text;
  final seite = Seitenangaben.aus(text);
  if (seite.kurs != kurs) {
    throw const LaufFehler('Die Teilnehmendenseite gehört nicht zum Kurs der Aktivität.');
  }
  final doc = html_parser.parse(text);

  final zahlen = doc.querySelectorAll('[data-region="participant-count"]');
  if (zahlen.length != 1) {
    throw const LaufFehler(
      'Die Teilnehmendenseite nennt die Gesamtzahl nicht an der erwarteten Stelle; moocp kann nicht prüfen, '
      'ob die Liste vollständig ist.',
    );
  }
  final ziffern = RegExp(r'\d+').allMatches(zahlen.single.text).toList();
  if (ziffern.length != 1 || ziffern.single[0]!.length > 7) {
    throw const LaufFehler('Die Gesamtzahl auf der Teilnehmendenseite ist nicht eindeutig zu lesen.');
  }
  final gesamt = int.parse(ziffern.single[0]!);
  if (gesamt > MoodleZugang.teilnehmendeHoechstens) {
    throw const LaufFehler(
      'Der Kurs hat mehr Teilnehmende, als Moodle auf einer Seite zeigt; moocp liest die Liste nicht in Teilen.',
    );
  }

  for (final aktiv in doc.querySelectorAll('.initialbar .active, .initialbar [aria-current]')) {
    final eintrag = aktiv.localName == 'li' ? aktiv : (aktiv.parent ?? aktiv);
    if (!eintrag.classes.contains('initialbarall') && !aktiv.classes.contains('initialbarall')) {
      throw const LaufFehler(
        'Auf der Teilnehmendenseite ist ein Filter nach Anfangsbuchstaben gesetzt; die Liste wäre unvollständig.',
      );
    }
  }
  for (final e in doc.querySelectorAll('[data-page-number]')) {
    final n = int.tryParse(e.attributes['data-page-number'] ?? '');
    if (n == null || n > 1) throw _mehrereSeiten;
  }
  for (final a in doc.querySelectorAll('a[href]')) {
    final u = Uri.tryParse(a.attributes['href'] ?? '');
    if (u == null || !u.path.endsWith('/user/index.php')) continue;
    final page = u.queryParameters['page'];
    if (page != null && page != '0') throw _mehrereSeiten;
  }

  final tabellen = doc.querySelectorAll('table#participants, table[id^="user-index-participants-"]');
  if (tabellen.length > 1) {
    throw const LaufFehler('Die Teilnehmendenseite zeigt mehr als eine Teilnehmertabelle.');
  }
  final tabelle = tabellen.firstOrNull;
  final personen = <String, String>{};
  if (tabelle != null) {
    for (final zeile in tabelle.querySelectorAll('tbody tr')) {
      if (zeile.classes.contains('emptyrow')) continue;
      final links = [
        for (final a in zeile.querySelectorAll('a[href]'))
          if (_person(a) case final p?) (a: a, id: p.id, kurs: p.kurs),
      ];
      final ids = {for (final l in links) l.id};
      if (ids.length != 1) {
        throw const LaufFehler(
          'Eine Zeile der Teilnehmertabelle hat nicht genau einen Link auf eine Person; der Aufbau der Seite ist '
          'nicht der erwartete.',
        );
      }
      if (links.any((l) => l.kurs != '$kurs')) {
        throw const LaufFehler('Die Teilnehmertabelle verweist auf einen anderen Kurs als den der Aktivität.');
      }
      final name = _nameIn(links.first.a);
      if (!Namenssperre.hatTeile(name)) {
        throw const LaufFehler('In der Teilnehmertabelle steht ein Name ohne Buchstaben und Ziffern.');
      }
      personen.putIfAbsent(ids.single, () => name);
    }
  } else if (gesamt > 0) {
    throw const LaufFehler('Die Teilnehmendenseite zeigt keine Teilnehmertabelle an der erwarteten Stelle.');
  }
  // Nur im Hauptbereich: Ein Block wie „Personen online“ verweist auch auf
  // Personen des Kurses, ohne dass sie in der Liste fehlten.
  final haupt = doc.querySelector('#region-main') ?? doc.documentElement!;
  if (gesamt == 0 && haupt.querySelectorAll('a[href]').any((a) => _person(a)?.kurs == '$kurs')) {
    throw const LaufFehler('Die Teilnehmendenseite nennt keine Teilnehmenden, zeigt aber welche.');
  }
  if (personen.length != gesamt) {
    throw const LaufFehler(
      'Die Zahl der gelesenen Namen passt nicht zur Gesamtzahl, die die Teilnehmendenseite nennt.',
    );
  }
  return (namen: personen.values.toList(), kurskontext: _zahl(seite.kontext));
}

const _mehrereSeiten = LaufFehler(
  'Die Teilnehmendenseite hat mehr als eine Seite; moocp liest die Liste nicht in Teilen.',
);

/// Die Person, auf die [a] verweist: `/user/view.php` mit `id` und `course`
/// als Zahl; sonst null.
({String id, String? kurs})? _person(dom.Element a) {
  final u = Uri.tryParse(a.attributes['href'] ?? '');
  if (u == null || !u.path.endsWith('/user/view.php')) return null;
  final id = u.queryParameters['id'];
  if (id == null || !RegExp(r'^\d+$').hasMatch(id)) return null;
  return (id: id, kurs: u.queryParameters['course']);
}

/// Der Name im Link einer Person: sein Text ohne Kürzel (`span.userinitials`)
/// und Bild. Trägt das Kürzel den Namen in `title` oder `aria-label`, muss er
/// den Text enthalten; sonst wirft es [LaufFehler].
String _nameIn(dom.Element link) {
  final kopie = link.clone(true);
  final kuerzel = kopie.querySelectorAll('.userinitials');
  for (final e in [...kuerzel, ...kopie.querySelectorAll('img')]) {
    e.remove();
  }
  final name = _einzeilig(kopie.text);
  for (final k in kuerzel) {
    for (final attr in ['title', 'aria-label']) {
      final v = k.attributes[attr];
      if (v != null && v.trim().isNotEmpty && !_einzeilig(v).contains(name)) {
        throw const LaufFehler(
          'In der Teilnehmertabelle passt der Name im Kürzel nicht zum Namen im Link; der Aufbau der Seite ist '
          'nicht der erwartete.',
        );
      }
    }
  }
  return name;
}

String _einzeilig(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Die Parameter, die als Kursnummer gelten, als Aktivitätsnummer und als
/// Kontext, nach [_parametername].
const _kursParameter = {'course', 'courseid'};
const _aktivitaetParameter = {'cmid', 'cm', 'coursemodule', 'coursemoduleid'};
const _kontextParameter = {'contextid'};

/// Skripte, in denen `id` eine Person meint, keine Kurs- oder
/// Aktivitätsnummer. Dort zählt `id` nicht; die Anfrage braucht eine andere
/// Nummer, die zum Lauf passt (etwa `course`).
const _idIstPerson = {
  '/user/view.php',
  '/user/profile.php',
  '/report/log/user.php',
  '/report/outline/user.php',
};

/// Der Name eines Parameters, wie die Regel ihn vergleicht: Prozentkodierung
/// aufgelöst, klein geschrieben, ohne den Teil ab „[“ (PHP liest `course[]` als
/// `course`) und nur noch Buchstaben und Ziffern. So kommt ein Plugin mit
/// `Course`, `%63ourse` oder `course.` nicht an der Regel vorbei; dass dabei
/// auch Namen zählen, die PHP anders liest (`course_id`), ist strenger als
/// nötig und so gewollt.
String _parametername(String roh) => prozentAufgeloest(
  roh.replaceAll('+', ' '),
).toLowerCase().split('[').first.replaceAll(RegExp('[^a-z0-9]'), '');

/// Ob eine Anfrage des Laufs [lauf] auf [uri] zu seinem Kurs und seiner
/// Aktivität passt; null, wenn ja, sonst der Grund (ohne Werte).
///
/// Die Regel (E36): Jede Nummer, die die App als Kurs-, Aktivitäts- oder
/// Kontextnummer erkennt, muss zum Lauf passen, jedes Vorkommen, auch doppelt
/// genannte Parameter; der Wert muss aus Ziffern bestehen. Und mindestens eine
/// muss da sein, sonst lässt sich die Anfrage keinem Kurs zuordnen, und die
/// App lehnt sie ab. Als solche Nummer gilt:
///
/// - Kurs: `course`, `courseid`; `id` in `/mod/<Modul>/index.php` (die Liste
///   der Aktivitäten eines Kurses) und in jedem Skript außerhalb von
///   `/mod/`, außer in denen aus [_idIstPerson], wo `id` eine Person meint.
/// - Aktivität: `cmid`, `cm`, `coursemodule`, `coursemoduleid`; `id` in jedem
///   anderen Skript unter `/mod/`.
/// - Kontext: `contextid`, die erste Zahl nach `/pluginfile.php/` oder
///   `/draftfile.php/` und nach `/` im Parameter `file` dieser beiden
///   Skripte. Erlaubt ist der Kontext des Kurses oder der Aktivität, soweit
///   Moodle ihn beim Beginn genannt hat.
///
/// Mehrdeutig ist bei Moodle vor allem `id`: Je nach Skript ist es Kurs,
/// Aktivität, Person oder ein Datensatz. Die Regel deutet `id` so, dass ein
/// Irrtum ablehnt statt durchlässt: Außerhalb von `/mod/` gilt `id` als
/// Kursnummer, auch wo es eine Person oder etwas anderes meint (dann lehnt die
/// App zu viel ab, nie zu wenig); nur wo `id` sicher eine Person ist, zählt
/// es nicht. Unter `/mod/` gilt es als Aktivität, außer in `index.php`.
///
/// Was die App an der Adresse nicht erkennen kann: Nummern anderer Art
/// (`d`, `f`, `a`, `instance`, `attempt`, `userid`, `groupid`, `itemid`,
/// `areaid` und alle, die ein Plugin-Skript selbst festlegt), Nummern in
/// einem Pfad hinter dem Skriptnamen außer bei Dateien, und ein Skript unter
/// `/mod/`, das `id` anders liest als Moodle üblich (etwa als Nummer einer
/// Instanz oder eines Kurses). Damit kann ein Plugin über eine seiner
/// Zusatzadressen an Daten eines anderen Kurses kommen, wenn das Skript dahinter
/// es zulässt; die Datenschutzprüfung kennt dann nur die Namen dieses Kurses. Dafür
/// steht das Plugin ein, das die Zusatzadresse angemeldet hat (E35).
///
/// [felder] sind die Formularfelder eines POST. Moodle liest ein Feld vor dem
/// gleichnamigen Parameter der Adresse (`optional_param` fragt `$_POST`
/// zuerst), also gilt für sie dieselbe Regel: Jedes Feld, dessen Name die App
/// als Kurs-, Aktivitäts- oder Kontextnummer erkennt, muss zum Lauf passen.
/// Bei der Klammerschreibweise zählt jeder Teil für sich (`data[course]`
/// prüft `data` und `course`): strenger als PHP, und so gewollt. Ein Feld
/// ersetzt nicht die Nummer in der Adresse; die braucht die Adresse selbst.
String? laufBindungVerletzt(Lauf lauf, Uri uri, {Felder felder = const []}) {
  final pfad = pfadNormalisieren(uri.path);
  final skript = _skriptKlein(pfad);
  final kontexte = {?lauf.kurskontext, ?lauf.modulkontext};
  var erkannt = 0;

  String? kontextPruefen(String? wert, [String wer = 'Die Adresse']) {
    erkannt++;
    final n = wert == null ? null : _zahl(wert);
    return n != null && kontexte.contains(n)
        ? null
        : '$wer nennt einen anderen Kontext als den des Kurses oder der Aktivität des Laufs.';
  }

  final datei = skript == '/pluginfile.php' || skript == '/draftfile.php';
  if (datei) {
    final m = RegExp(r'^/(?:pluginfile|draftfile)\.php/([^/]*)').firstMatch(pfad);
    if (m != null) {
      if (kontextPruefen(m[1]) case final grund?) return grund;
    }
  }
  final idArt = switch (skript) {
    final s when RegExp(r'^/mod/[^/]+/index\.php$').hasMatch(s) => _Art.kurs,
    final s when s.startsWith('/mod/') => _Art.aktivitaet,
    final s when _idIstPerson.contains(s) => null,
    _ => _Art.kurs,
  };

  // Prüft eine Nummer mit dem verglichenen Namen und ihrem Wert; `feld` sagt,
  // ob sie aus einem Formularfeld kommt statt aus der Adresse.
  String? nummerPruefen(String name, String wert, {bool feld = false}) {
    final wer = feld ? 'Ein Formularfeld' : 'Die Adresse';
    final woher = feld ? 'Feld' : 'Parameter';
    final art = _kursParameter.contains(name)
        ? _Art.kurs
        : _aktivitaetParameter.contains(name)
        ? _Art.aktivitaet
        : _kontextParameter.contains(name)
        ? _Art.kontext
        : name == 'id'
        ? idArt
        : datei && name == 'file'
        ? _Art.datei
        : null;
    switch (art) {
      case null:
        return null;
      case _Art.kurs:
        erkannt++;
        if (_zahl(wert) != lauf.kurs) {
          return '$wer nennt eine andere Kursnummer ($woher „$name“) als der Kurs der Aktivität des Laufs.';
        }
      case _Art.aktivitaet:
        erkannt++;
        if (_zahl(wert) != lauf.cmid) {
          return '$wer nennt eine andere Aktivität ($woher „$name“) als die des Laufs.';
        }
      case _Art.kontext:
        return kontextPruefen(wert, wer);
      case _Art.datei:
        return kontextPruefen(RegExp(r'^/([^/]*)').firstMatch(wert)?[1], wer);
    }
    return null;
  }

  if (uri.hasQuery) {
    for (final teil in uri.query.split('&')) {
      if (teil.isEmpty) continue;
      final i = teil.indexOf('=');
      final name = _parametername(i < 0 ? teil : teil.substring(0, i));
      final wert = prozentAufgeloest((i < 0 ? '' : teil.substring(i + 1)).replaceAll('+', ' '));
      if (nummerPruefen(name, wert) case final grund?) return grund;
    }
  }
  if (erkannt == 0) {
    return 'Die Adresse nennt keine Kurs-, Aktivitäts- oder Kontextnummer, an der moocp sie dem Kurs des Laufs '
        'zuordnen kann.';
  }
  for (final MapEntry(key: roh, value: wert) in felder) {
    for (final name in _feldnamen(roh)) {
      if (nummerPruefen(name, wert, feld: true) case final grund?) return grund;
    }
  }
  return null;
}

/// Die Namen, die ein Formularfeld für die Regel trägt: der Name vor der
/// ersten Klammer und jeder Schlüssel in Klammern (`data[course][]` ergibt
/// `data` und `course`), je wie [_parametername] sie vergleicht; leere
/// Schlüssel fallen weg.
Iterable<String> _feldnamen(String roh) sync* {
  final i = roh.indexOf('[');
  yield _parametername(i < 0 ? roh : roh.substring(0, i));
  if (i < 0) return;
  for (final m in RegExp(r'\[([^\]]*)\]').allMatches(roh.substring(i))) {
    final n = _parametername(m[1]!);
    if (n.isNotEmpty) yield n;
  }
}

enum _Art { kurs, aktivitaet, kontext, datei }

/// Der normalisierte Pfad bis zum Skriptnamen, klein geschrieben.
String _skriptKlein(String pfad) {
  final teile = <String>[];
  for (final t in pfad.split('/')) {
    teile.add(t);
    if (t.toLowerCase().endsWith('.php')) break;
  }
  return teile.join('/').toLowerCase();
}
