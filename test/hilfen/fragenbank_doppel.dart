// Ein Moodle-Doppel mit Fragensammlung für die Rundlaufprobe (E38): Kategorien,
// Import und Export als XML, Bearbeitungsformular, Vorschau, die Seite des
// Plugins qbank_importasversion und das Löschen einzelner Versionen. Nur
// Moodle ist ersetzt (lokaler HTTP-Server auf 127.0.0.1); alles darüber läuft
// echt. Je Eintrag (Fragenbank-Eintrag) mehrere Versionen, wie in Moodle.
//
// Die Schalter oben im Doppel erzeugen die Fälle, die der Test braucht: Plugin
// da/fehlt, Abweichung im Export, Fehler im Formular oder in der Vorschau, ein
// Speichern, das Moodle ablehnt, und so weiter. Was Moodle wirklich tut, steht
// im Quelltext von rundlaufprobe.dart; das Doppel bildet nur das Gemessene und
// das Plugin nach, dessen Quelltext öffentlich ist.
import 'dart:convert';
import 'dart:io';

import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/protokoll.dart';
import 'package:xml/xml.dart';

class DoppelVersion {
  DoppelVersion(this.id, this.nr, this.xml, {this.status = 'ready'});
  final int id;
  final int nr;
  String xml;
  String status;
  String get name => XmlDocument.parse('<r>$xml</r>').findAllElements('name').first.innerText.trim();
}

class DoppelPlatz {
  DoppelPlatz(this.slotid, this.frage, this.seite, this.punkte);
  final int slotid;
  int frage;
  int seite;
  double punkte;

  /// Fragensammlung (cmid), aus der der Platz kommt: bei einem festen Platz das Abzeichen der
  /// geteilten Bank, bei einem Zufallsplatz der Link zur Bank; null: Bank des Tests selbst.
  int? bank;
  bool zufall = false;
}

class DoppelEintrag {
  DoppelEintrag(this.kategorie, this.idnummer, this.typ);
  int kategorie;
  final String idnummer;
  final String typ;
  final List<DoppelVersion> versionen = [];
  DoppelVersion get neueste => versionen.last;
}

class FragenbankDoppel {
  late HttpServer _server;
  final Set<String> _angemeldet = {};
  int _zaehler = 0;
  int _naechsteId = 100;

  static const benutzer = 'e.mustermann';
  static const passwort = 'test-geheim-38';
  static const sesskey = 'sk38';
  static const sammlung = 12;

  /// Kategorien: id -> Name.
  final Map<int, String> kategorien = {1: 'ZZ Probe'};

  /// Zu welcher Fragensammlung (cmid) eine Kategorie gehört; ohne Eintrag: [sammlung].
  final Map<int, int> bankVon = {};

  /// Die Sammlungen, die die Übersicht des Kurses (`banks.php`) nennt: cmid -> Name.
  final Map<int, String> kursBanken = {12: 'ZZ Bank'};

  /// Ein Schutzdienst hält die Übersicht der Sammlungen (`banks.php`) an.
  bool schutzBeiBanken = false;

  // --- Kursstruktur (core_courseformat_get_state / _update_course) ---------
  /// Aktivitäten der Kursstruktur: cmid -> Name, Modul, Abschnitt. Eine Fragensammlung steht
  /// dort nicht (Moodle 5 zeigt sie nicht auf der Kursseite); wer sie trotzdem braucht, trägt sie ein.
  final Map<int, ({String name, String modul, int abschnitt})> kursAktivitaeten = {};

  /// Abschnitte der Kursstruktur: id -> Titel.
  final Map<int, String> kursAbschnitte = {4: 'Allgemein', 5: 'Thema 1'};

  /// Unterabschnitte (mod_subsection): cmid der Aktivität -> id ihres delegierten Abschnitts, der in
  /// [kursAbschnitte] stehen muss; die Aktivität steht in `kursAktivitaeten` mit Modul `subsection`.
  final Map<int, int> unterabschnitte = {};

  /// Jeder Aufruf von core_courseformat_update_course: Aktion und ids.
  final List<({String aktion, List<int> ids})> kursAktionen = [];

  /// Die Löschaktionen melden Erfolg und ändern nichts.
  bool kursLoeschenWirktNicht = false;

  /// Wird aufgerufen, kurz bevor eine Kursaktion ausgeführt wird.
  void Function()? beiKursAktion;

  /// Zusammenstellung von Tests: cmid -> Plätze (`mod/quiz/edit.php`, `edit_rest.php`).
  final Map<int, List<DoppelPlatz>> testPlaetze = {};
  int _naechsterPlatz = 500;

  /// Wird aufgerufen, kurz bevor ein Platz in einen Test eingefügt wird.
  void Function()? beiPlatzEinfuegen;

  /// Legt einen Test an: Eintrag der Kursstruktur und Plätze (Frage, Seite, Punkte).
  void legeTestAn(int cmid, String name, List<(DoppelEintrag, int, double)> plaetze) {
    kursAktivitaeten[cmid] = (name: name, modul: 'quiz', abschnitt: 5);
    testPlaetze[cmid] = [for (final (e, seite, punkte) in plaetze) DoppelPlatz(_naechsterPlatz++, e.neueste.id, seite, punkte)];
  }

  /// Die Zusammenstellungsseiten von Tests (`mod/quiz/edit.php`): cmid -> HTML.
  final Map<int, String> quizSeiten = {};

  /// Legt eine Kategorie an (Kontext-id 60 + cmid, die erste Sammlung hat 55);
  /// ohne [eltern] liegt sie unter der Top-Kategorie ihrer Sammlung.
  void legeKategorieAn(int id, String name, {int bank = sammlung, int? eltern}) {
    kategorien[id] = name;
    bankVon[id] = eltern == null ? bank : _bank(eltern);
    if (eltern != null) this.eltern[id] = eltern;
  }

  /// Elternkategorie je Kategorie; ohne Eintrag liegt sie unter der Top-Kategorie.
  final Map<int, int> eltern = {};

  /// Beschreibung und Sachnummer je Kategorie (roh, wie das Formular sie lädt).
  final Map<int, String> kategorieInfo = {};
  final Map<int, String> kategorieIdnummer = {};

  /// Die Top-Kategorie einer Sammlung (steht nicht in `kategorien`).
  static int topId(int bank) => 900 + bank;
  static bool istTop(int id) => id >= 900 && id < 1000;

  /// Das Formular „rendert" die Beschreibung beim Speichern (format_text) und hängt `<p>` an.
  bool infoRendert = false;

  /// Der Export zeigt keine Top-Kategorie (dann ist sie nicht zu ermitteln).
  bool exportOhneTop = false;

  /// Der Dienst zum Verschieben von Kategorien antwortet mit einem Fehler / meldet Erfolg und ändert nichts.
  bool kategorieVerschiebenAbgelehnt = false;
  bool kategorieVerschiebenWirktNicht = false;

  /// Das Formular nimmt einen neuen Namen nicht an (meldet aber Erfolg).
  bool kategorieUmbenennenWirktNicht = false;

  /// Wird aufgerufen, kurz bevor ein Dienst eine Kategorie ändert.
  void Function()? beiKategorieAenderung;

  /// Die Argumente jedes Aufrufs von qbank_managecategories_move_category und
  /// die abgesendeten Felder jedes Speicherns des Kategorieformulars.
  final List<Map<String, dynamic>> kategorieVerschiebeAufrufe = [];
  final List<Map<String, String>> kategorieFormulare = [];

  bool _unter(int kat, int vorfahr) {
    for (int? k = kat; k != null; k = eltern[k]) {
      if (k == vorfahr) return true;
    }
    return false;
  }

  /// Wie Moodles Kategorieliste: verborgene (in einem Test benutzte, „gelöschte") Fragen zählen nicht
  /// (auf Moodle 5.1 gemessen).
  int _eintraegeIn(int kat) =>
      eintraege.where((e) => e.kategorie == kat && e.versionen.isNotEmpty && !versteckt.contains(e.neueste.id)).length;

  int _bank(int kategorie) => bankVon[kategorie] ?? sammlung;
  static int _kontext(int bank) => bank == sammlung ? 55 : 60 + bank;
  final List<DoppelEintrag> eintraege = [];

  // --- Schalter -------------------------------------------------------------
  bool pluginDa = true;
  bool statusFeld = true;
  bool formularFehler = false;
  bool vorschauFehler = false;
  bool entwurfAbgelehnt = false;
  int entwurfAblehnungStatus = 200;
  bool entwurfOhneNummer = false;
  String? stackTestHtml;

  /// Das Plugin weist die Datei ab: Es leitet um, legt aber nichts an.
  bool pluginLegtNichtAn = false;

  /// Verändert das gespeicherte XML einer Version beim Import (Moodle „verliert" etwas).
  String Function(String xml)? beimSpeichern;

  /// Verändert den Export einer Version (Moodle liefert etwas anderes aus).
  String Function(String xml)? beimExport;

  /// Verändert das XML der Entwurfs-Probeversion gegenüber der Vorlage.
  String Function(String xml)? beimEntwurf;

  /// Löscht „alle Versionen", auch wenn nur eine gewählt war (Moodle ohne die erwartete Wirkung).
  bool loeschtAlles = false;

  /// Kategorien, deren Export Moodle ohne Download beantwortet (Formular ohne Umleitung).
  final Set<int> exportAbgelehnt = {};

  /// Die Kategorien, die als Export angefordert wurden.
  final List<int> exportAufrufe = [];

  /// Das Löschen wirkt nicht.
  bool loeschenWirktNicht = false;

  /// Versions-ids, die ein Test nutzt: Moodle markiert sie in der Rückfrage mit
  /// `* ` und verbirgt sie beim Löschen nur. Eine so verborgene Frage fehlt danach
  /// im Export ihrer Kategorie, lässt sich aber noch einzeln nach id exportieren
  /// (auf Moodle 5.1 gemessen).
  final Set<int> inBenutzung = {};

  /// Die Rückfrage nennt die Version wie ältere Moodle-Versionen: „Name (Version n)".
  bool alteVersionsschreibweise = false;

  /// Das Verbergen wirkt nicht: Die benutzte Frage bleibt in ihrer Kategorie.
  bool verbergenWirktNicht = false;

  /// Versionen, die Moodle in der Fragensammlung ausgeblendet hat.
  final Set<int> versteckt = {};

  /// Verborgene Versionen: Moodle exportiert sie nicht (Fehlerseite mit anderem Code).
  final Set<int> verborgen = {};

  // --- core_question_move_questions ------------------------------------------
  /// Moodle legt bei einer Sachnummer-Kollision im Ziel still `_1` an (Messung der Quelle, nicht der Instanz).
  bool kollisionMitSuffix = false;

  /// Der Dienst antwortet mit einem Fehler und ändert nichts.
  /// Pro Dienstaufruf (Nummer ab 1): null normal, 'schutz' (Schutzdienst vor Moodle),
  /// 'wirkung-dann-fehler' (Moodle verschiebt, meldet aber einen Fehler).
  String? Function(int aufruf)? verschiebeVerhalten;

  bool verschiebenAbgelehnt = false;

  /// Der Dienst meldet Erfolg und ändert nichts.
  bool verschiebenWirktNicht = false;

  /// Wird aufgerufen, kurz bevor ein Dienstaufruf verschiebt.
  void Function()? beiVerschieben;

  /// Die Argumente jedes Aufrufs von core_question_move_questions.
  final List<Map<String, dynamic>> verschiebeAufrufe = [];

  /// Wird aufgerufen, kurz bevor ein bestätigtes Löschen ausgeführt wird.
  void Function()? beiLoeschen;

  /// Nach dem ersten Import als Version greift ein „Anderer" ein: eine weitere Version.
  void Function(FragenbankDoppel d)? nachPluginImport;

  // --- Aufzeichnung ---------------------------------------------------------
  final List<String> anfragen = [];
  final List<int> geloescht = [];

  /// Der Status, mit dem das Bearbeitungsformular gespeichert wurde, je Speichern.
  final List<String?> gespeichertMitStatus = [];
  final List<String> pluginAufrufe = [];
  List<int>? _hochgeladen;

  Uri get basis => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> starten() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_antworte);
  }

  Future<void> stoppen() => _server.close(force: true);

  Future<MoodleZugang> zugang() =>
      MoodleZugang.fuerTest(Protokoll(), basis, benutzer: benutzer, passwort: passwort);

  /// Legt einen Eintrag mit einer ersten Version an (wie ein Import).
  DoppelEintrag legeAn(String typ, String name, String idnummer, {String antwort = 'A', int kategorie = 1}) {
    final e = DoppelEintrag(kategorie, idnummer, typ);
    e.versionen.add(DoppelVersion(_naechsteId++, 1, frageXml(typ, name, idnummer, antwort)));
    eintraege.add(e);
    return e;
  }

  /// Eine weitere Version, wie sie ein Mensch im Browser speichert.
  DoppelVersion neueVersion(DoppelEintrag e, {String? antwort, String status = 'ready'}) {
    final v = DoppelVersion(
        _naechsteId++, e.neueste.nr + 1, antwort == null ? e.neueste.xml : e.neueste.xml.replaceAll(RegExp(r'<text>[^<]*</text></answer>'), '<text>$antwort</text></answer>'),
        status: status);
    e.versionen.add(v);
    return v;
  }

  static String frageXml(String typ, String name, String idnummer, String antwort) => '''<question type="$typ">
  <name><text>$name</text></name>
  <questiontext format="html"><text><![CDATA[<p>Frage $name</p>]]></text></questiontext>
  <defaultgrade>1.0000000</defaultgrade>
  <hidden>0</hidden>
  <idnumber>$idnummer</idnumber>
  <answer fraction="100" format="html"><text>$antwort</text></answer>
</question>''';

  DoppelVersion? version(int id) {
    for (final e in eintraege) {
      for (final v in e.versionen) {
        if (v.id == id) return v;
      }
    }
    return null;
  }

  DoppelEintrag? eintragVon(int versionId) =>
      eintraege.where((e) => e.versionen.any((v) => v.id == versionId)).firstOrNull;

  String _seite(String body) =>
      '<html><body><script>M.cfg = {"sesskey":"$sesskey","courseId":12,"contextid":"55"};</script>'
      '<script>var r = {"id":"3","name":"x","type":"upload"};</script>$body</body></html>';

  Future<void> _antworte(HttpRequest r) async {
    final id = r.cookies.where((c) => c.name == 'MoodleSession').map((c) => c.value).firstOrNull;
    final ein = id != null && _angemeldet.contains(id);
    final pfad = r.uri.path;
    if (pfad == '/login/index.php' && r.method == 'GET') {
      if (r.uri.queryParameters.containsKey('testsession')) return _um(r, ein ? '/my/' : '/login/index.php');
      if (ein) return _text(r, _seite('<p>Sie sind bereits angemeldet</p>'));
      r.response.cookies.add(Cookie('MoodleSession', 's${_zaehler++}'));
      return _text(r, '<form><input name="logintoken" value="tok"></form>');
    }
    if (pfad == '/login/index.php' && r.method == 'POST') {
      final f = Uri.splitQueryString(await utf8.decoder.bind(r).join());
      if (id != null && f['username'] == benutzer && f['password'] == passwort && f['logintoken'] == 'tok') {
        _angemeldet.add(id);
        return _um(r, '/login/index.php?testsession=1');
      }
      return _um(r, '/login/index.php');
    }
    if (!ein) return _um(r, '/login/index.php');
    final bytes = await r.fold<List<int>>([], (a, b) => a..addAll(b));
    final koerper = utf8.decode(bytes, allowMalformed: true);
    if (pfad != '/my/') anfragen.add('${r.method} ${r.uri}');
    if (pfad == '/my/') return _text(r, _seite('<p>Start</p>'));

    if (pfad == '/question/bank/importquestions/import.php') {
      final cmid = int.tryParse(r.uri.queryParameters['cmid'] ?? '') ?? sammlung;
      if (r.method == 'GET') {
        return _text(r, _seite('''<form class="mform" method="post" action="/question/bank/importquestions/import.php?cmid=$cmid">
<input type="hidden" name="sesskey" value="$sesskey"><input type="hidden" name="_qf__qbank_importquestions_import_form" value="1">
<input type="hidden" name="newfile" value="9">
<select name="category">${_optionen(cmid)}</select><select name="format"><option value="xml" selected>xml</option></select>
<input type="hidden" name="catfromfile" value="1"><input type="hidden" name="contextfromfile" value="1"><input type="hidden" name="matchgrades" value="error"><input type="hidden" name="stoponerror" value="1">
</form>'''));
      }
      final f = Uri.splitQueryString(koerper);
      final kat = int.parse(f['category']!.split(',').first);
      final xml = utf8.decode(_hochgeladen ?? const [], allowMalformed: true);
      for (final q in XmlDocument.parse(xml).rootElement.findElements('question')) {
        final idn = q.getElement('idnumber')?.innerText.trim() ?? '';
        final e = DoppelEintrag(kat, idn, q.getAttribute('type')!);
        final roh = q.toXmlString();
        e.versionen.add(DoppelVersion(_naechsteId++, 1, beimSpeichern?.call(roh) ?? roh));
        eintraege.add(e);
      }
      return _text(r, _seite('<p>Import fertig</p>'));
    }
    if (pfad == '/repository/repository_ajax.php') {
      final s = koerper;
      final a = s.indexOf('<?xml');
      final b = s.lastIndexOf('</quiz>');
      if (a >= 0 && b > a) _hochgeladen = utf8.encode(s.substring(a, b + 7));
      final m = RegExp(r'filename="([^"]+)"').firstMatch(s)?.group(1) ?? 'f.xml';
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode({'url': '$basis/draftfile.php/55/user/draft/9/$m'}));
      return r.response.close();
    }
    if (pfad == '/question/bank/exportquestions/export.php') {
      final cmid = int.tryParse(r.uri.queryParameters['cmid'] ?? '') ?? sammlung;
      if (r.method == 'GET') {
        return _text(r, _seite('''<form class="mform" method="post" action="/question/bank/exportquestions/export.php?cmid=$cmid">
<input type="hidden" name="sesskey" value="$sesskey"><input type="hidden" name="_qf__qbank_exportquestions_export_form" value="1">
<select name="category">${_optionen(cmid, top: !exportOhneTop)}</select><select name="format"><option value="xml" selected>xml</option></select>
<input type="hidden" name="cattofile" value="1"><input type="hidden" name="contexttofile" value="1"></form>'''));
      }
      final f = Uri.splitQueryString(koerper);
      final kat = f['category']!.split(',').first;
      exportAufrufe.add(int.parse(kat));
      if (exportAbgelehnt.contains(int.parse(kat))) return _text(r, _seite('<p>Export nicht möglich</p>'));
      return _um(r, '/pluginfile.php/${_kontext(_bank(int.parse(kat)))}/question/export/$kat/export.xml');
    }
    if (RegExp(r'^/pluginfile\.php/\d+/question/export/').hasMatch(pfad)) {
      final kat = int.parse(pfad.split('/')[5]);
      final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<quiz>\n');
      for (final e in eintraege.where((e) => e.kategorie == kat)) {
        if (e.versionen.isEmpty || versteckt.contains(e.neueste.id)) continue;
        b.writeln('<!-- question: ${e.neueste.id}  -->');
        b.writeln(_ausgeliefert(e.neueste));
      }
      b.write('</quiz>');
      return _text(r, b.toString());
    }
    if (pfad == '/mod/quiz/edit.php') {
      final cmid = int.tryParse(r.uri.queryParameters['cmid'] ?? '');
      final plaetze = testPlaetze[cmid];
      if (plaetze != null && r.uri.queryParameters.containsKey('addquestion')) {
        beiPlatzEinfuegen?.call();
        final seite = int.tryParse(r.uri.queryParameters['addonpage'] ?? '') ?? 0;
        final letzte = plaetze.fold<int>(1, (m, x) => x.seite > m ? x.seite : m);
        final s = seite == 0 ? letzte : seite;
        final nach = plaetze.lastIndexWhere((x) => x.seite == s);
        plaetze.insert(nach < 0 ? plaetze.length : nach + 1,
            DoppelPlatz(_naechsterPlatz++, int.parse(r.uri.queryParameters['addquestion']!), s, 1));
        return _um(r, '/mod/quiz/edit.php?cmid=$cmid');
      }
      final seite = plaetze != null ? _testSeite(cmid!, plaetze) : quizSeiten[cmid];
      if (seite == null) {
        r.response.statusCode = 404;
        return _text(r, _seite('<p>nicht gefunden</p>'));
      }
      return _text(r, seite);
    }
    if (pfad == '/mod/quiz/edit_rest.php') {
      final f = Uri.splitQueryString(koerper);
      final plaetze = testPlaetze.values.firstWhere((l) => l.any((x) => '${x.slotid}' == f['id']), orElse: () => []);
      final platz = plaetze.where((x) => '${x.slotid}' == f['id']).firstOrNull;
      r.response.headers.contentType = ContentType.json;
      if (platz == null) {
        r.response.write(jsonEncode({'error': 'Platz ${f['id']} gibt es nicht'}));
        return r.response.close();
      }
      if (f['action'] == 'DELETE') {
        plaetze.remove(platz);
      } else if (f['field'] == 'move') {
        final davor = plaetze.where((x) => '${x.slotid}' == f['previousid']).firstOrNull;
        plaetze.remove(platz);
        platz.seite = int.tryParse(f['page'] ?? '') ?? platz.seite;
        plaetze.insert(davor == null ? 0 : plaetze.indexOf(davor) + 1, platz);
      } else if (f['field'] == 'updatemaxmark') {
        platz.punkte = double.parse(f['maxmark']!);
      }
      r.response.write('{}');
      return r.response.close();
    }
    if (pfad == '/question/banks.php') {
      if (schutzBeiBanken) {
        r.response.headers.set('server', 'cloudflare');
        r.response.headers.set('cf-mitigated', 'challenge');
        return _text(r, '<html><title>Just a moment...</title></html>', status: 403);
      }
      return _text(r, _seite('<div id="region-main">${[
        for (final b in kursBanken.entries) '<a href="/mod/qbank/view.php?id=${b.key}">${b.value}</a>'
      ].join()}</div>'));
    }
    if (pfad == '/lib/ajax/service.php') {
      final aufruf = (jsonDecode(koerper) as List).single as Map;
      r.response.headers.contentType = ContentType.json;
      final fehler = {
        'error': true,
        'exception': {'errorcode': 'cannotfindcate', 'message': 'Abgelehnt'}
      };
      if (aufruf['methodname'] == 'core_form_dynamic_form') {
        r.response.write(jsonEncode([_kategorieFormular((aufruf['args'] as Map).cast<String, dynamic>(), fehler)]));
        return r.response.close();
      }
      if (aufruf['methodname'] == 'core_courseformat_get_state') {
        r.response.write(jsonEncode([
          {'error': false, 'data': jsonEncode(_kursZustand())}
        ]));
        return r.response.close();
      }
      if (aufruf['methodname'] == 'core_courseformat_update_course') {
        final a = (aufruf['args'] as Map).cast<String, dynamic>();
        final ids = [for (final x in a['ids'] as List) (x as num).toInt()];
        kursAktionen.add((aktion: '${a['action']}', ids: ids));
        beiKursAktion?.call();
        if (!kursLoeschenWirktNicht) {
          if (a['action'] == 'cm_delete') {
            for (final id in ids) {
              _aktivitaetWeg(id);
            }
          } else if (a['action'] == 'section_delete') {
            for (final id in ids) {
              for (final c in [for (final e in kursAktivitaeten.entries) if (e.value.abschnitt == id) e.key]) {
                _aktivitaetWeg(c);
              }
              kursAbschnitte.remove(id);
            }
          }
        }
        r.response.write(jsonEncode([
          {'error': false, 'data': '[]'}
        ]));
        return r.response.close();
      }
      if (aufruf['methodname'] == 'qbank_managecategories_move_category') {
        r.response.write(jsonEncode([_kategorieVerschieben((aufruf['args'] as Map).cast<String, dynamic>(), fehler)]));
        return r.response.close();
      }
      if (aufruf['methodname'] != 'core_question_move_questions') {
        r.response.write(jsonEncode([fehler]));
        return r.response.close();
      }
      final a = (aufruf['args'] as Map).cast<String, dynamic>();
      verschiebeAufrufe.add(a);
      final kat = a['newcategoryid'] as int;
      final verhalten = verschiebeVerhalten?.call(verschiebeAufrufe.length);
      if (verhalten == 'schutz') {
        r.response.headers.set('server', 'cloudflare');
        r.response.headers.set('cf-mitigated', 'challenge');
        return _text(r, '<html><title>Just a moment...</title></html>', status: 403);
      }
      final fehlerNachWirkung = verhalten == 'wirkung-dann-fehler';
      if (verschiebenAbgelehnt || !kategorien.containsKey(kat) || _kontext(_bank(kat)) != a['newcontextid']) {
        r.response.write(jsonEncode([fehler]));
        return r.response.close();
      }
      beiVerschieben?.call();
      final antwortFehler = fehlerNachWirkung;
      for (final s in '${a['questionids']}'.split(',')) {
        final e = eintragVon(int.parse(s));
        if (e == null || verschiebenWirktNicht) continue;
        e.kategorie = kat;
        // Eine Sachnummer-Kollision löst Moodle selbst; der Dienst fragt nicht.
        if (kollisionMitSuffix &&
            eintraege.any((x) => x != e && x.kategorie == kat && x.idnummer == e.idnummer)) {
          eintraege[eintraege.indexOf(e)] = DoppelEintrag(kat, '${e.idnummer}_1', e.typ)
            ..versionen.addAll(e.versionen.map((v) =>
                DoppelVersion(v.id, v.nr, v.xml.replaceAll('<idnumber>${e.idnummer}</idnumber>', '<idnumber>${e.idnummer}_1</idnumber>'))));
        }
      }
      if (antwortFehler) {
        r.response.write(jsonEncode([fehler]));
        return r.response.close();
      }
      r.response.write(jsonEncode([
        {'error': false, 'data': '/question/edit.php?cmid=${a['newcontextid']}&cat=$kat'}
      ]));
      return r.response.close();
    }
    if (pfad == '/question/bank/exporttoxml/exportone.php') {
      final v = version(int.parse(r.uri.queryParameters['id']!));
      if (v != null && verborgen.contains(v.id)) {
        return _text(r, _seite('<div class="errormessage">Datei nicht gefunden</div><a href="https://docs.moodle.org/501/de/error/moodle/filenotfound">Mehr</a>'),
            status: 404);
      }
      if (v == null) {
        return _text(r, _seite('<div class="errormessage">Ungültiger Datensatz</div><a href="https://docs.moodle.org/501/de/error/moodle/invalidrecord">Mehr</a>'),
            status: 500);
      }
      return _text(r, '<?xml version="1.0" encoding="UTF-8"?>\n<quiz>\n<!-- question: ${v.id}  -->\n${_ausgeliefert(v)}\n</quiz>');
    }
    if (pfad == '/question/bank/editquestion/question.php') {
      final q = r.uri.queryParameters['id'];
      final v = q == null ? null : version(int.parse(q));
      if (formularFehler || v == null) {
        return _text(r, _seite('<div class="errormessage">Fehler beim Lesen aus der Datenbank</div>'), status: formularFehler ? 200 : 404);
      }
      if (r.method == 'GET') {
        return _text(r, _seite('''<form class="mform" method="post" action="/question/bank/editquestion/question.php?cmid=$sammlung&id=${v.id}">
<input type="hidden" name="sesskey" value="$sesskey"><input type="hidden" name="id" value="${v.id}"><input type="hidden" name="cmid" value="$sammlung">
<input type="hidden" name="_qf__qtype_multichoice_edit_form" value="1">
<input type="text" name="name" value="${v.name}">
${statusFeld ? '<select name="status"><option value="ready"${v.status == 'ready' ? ' selected' : ''}>Bereit</option><option value="draft"${v.status == 'draft' ? ' selected' : ''}>Entwurf</option></select>' : ''}
<input type="submit" name="submitbutton" value="Änderungen speichern"></form>'''));
      }
      if (entwurfAbgelehnt) {
        return _text(r, _seite('<form class="mform" method="post"><div class="fitem"><div class="col-form-label">Status</div><div class="alert-danger">Nicht speicherbar</div></div></form>'), status: entwurfAblehnungStatus);
      }
      final f = Uri.splitQueryString(koerper);
      final e = eintragVon(v.id)!;
      final roh = beimEntwurf?.call(v.xml) ?? v.xml;
      gespeichertMitStatus.add(f['status']);
      final nv = DoppelVersion(_naechsteId++, e.neueste.nr + 1, roh, status: f['status'] ?? 'ready');
      e.versionen.add(nv);
      return _um(r, '/question/edit.php?cmid=$sammlung${entwurfOhneNummer ? '' : '&lastchanged=${nv.id}'}');
    }
    if (pfad == '/question/bank/previewquestion/preview.php') {
      if (vorschauFehler) return _text(r, _seite('<div class="errormessage">Frage nicht darstellbar</div>'));
      return _text(r, _seite('<div class="que"><p>Vorschau</p></div>'));
    }
    if (pfad == '/question/type/stack/questiontestrun.php' && stackTestHtml != null) {
      return _text(r, stackTestHtml!);
    }
    if (pfad == '/question/bank/importasversion/import.php') {
      pluginAufrufe.add('${r.method} ${r.uri.query}');
      if (!pluginDa) return _text(r, 'nicht gefunden', status: 404);
      if (r.method == 'GET') {
        final q = int.parse(r.uri.queryParameters['id']!);
        return _text(r, _seite('''<form class="mform" method="post" action="/question/bank/importasversion/import.php">
<input type="hidden" name="sesskey" value="$sesskey"><input type="hidden" name="_qf__qbank_importasversion_form_import_form" value="1">
<input type="hidden" name="newfile" value="9"><input type="hidden" name="force" value="0">
<input type="hidden" name="id" value="$q"><input type="hidden" name="courseid" value="0"><input type="hidden" name="cmid" value="$sammlung"><input type="hidden" name="returnurl" value="/question/edit.php?cmid=$sammlung">
<input type="submit" name="submitbutton" value="Importieren"></form>'''));
      }
      final f = Uri.splitQueryString(koerper);
      final e = eintragVon(int.parse(f['id']!));
      final xml = utf8.decode(_hochgeladen ?? const [], allowMalformed: true);
      final fragen = XmlDocument.parse(xml).rootElement.findElements('question').toList();
      if (e != null && fragen.length == 1 && !pluginLegtNichtAn) {
        final roh = fragen.single.toXmlString();
        e.versionen.add(DoppelVersion(_naechsteId++, e.neueste.nr + 1, beimSpeichern?.call(roh) ?? roh));
        nachPluginImport?.call(this);
      }
      return _um(r, '/question/edit.php?cmid=$sammlung');
    }
    if (pfad == '/question/bank/deletequestion/delete.php') {
      final q = {...r.uri.queryParameters, if (koerper.isNotEmpty) ...Uri.splitQueryString(koerper)};
      if (!q.containsKey('confirm')) {
        final ids = q.keys.where((k) => RegExp(r'^q\d+$').hasMatch(k)).map((k) => k.substring(1)).join(',');
        // Gemessen auf Moodle 5.1 (deutsche Oberfläche): Aufbau der Rückfrage wörtlich.
        final zeilen = [
          for (final s in ids.split(','))
            if (eintragVon(int.parse(s)) case final e?)
              for (final v in e.versionen)
                '${inBenutzung.contains(v.id) ? '* ' : ''}${v.name} ${alteVersionsschreibweise ? '(Version ${v.nr})' : 'v${v.nr}'}',
        ].join('<br />');
        return _text(r, _seite('''<div role="alert" data-aria-autofocus="true" id="modal-body" class="box py-3 modal-body"><p>Die folgende Fragen und alle ihre Versionen werden gelöscht: <br /><br />$zeilen<br /><br />* Fragen, die in Verwendung sind und nicht gelöscht werden können, werden hiermit gekennzeichnet. Stattdessen werden sie in der Fragensammlung ausgeblendet, außer die Option "Verborgene Fragen anzeigen" ist gewählt.</p></div><form method="post" action="/question/bank/deletequestion/delete.php">
<input type="hidden" name="sesskey" value="$sesskey"><input type="hidden" name="cmid" value="$sammlung">
<input type="hidden" name="deleteselected" value="$ids"><input type="hidden" name="deleteall" value="${q['deleteall'] ?? '0'}">
<input type="hidden" name="confirm" value="${'a' * 32}"><input type="submit" name="x" value="Löschen"></form>'''));
      }
      beiLoeschen?.call();
      for (final s in q['deleteselected']!.split(',')) {
        final id = int.parse(s);
        if (inBenutzung.contains(id)) {
          if (!verbergenWirktNicht) versteckt.add(id);
          continue;
        }
        geloescht.add(id);
        if (loeschenWirktNicht) continue;
        final e = eintragVon(id);
        if (e == null) continue;
        if (loeschtAlles || q['deleteall'] == '1') {
          e.versionen.clear();
        } else {
          e.versionen.removeWhere((v) => v.id == id);
        }
      }
      return _um(r, '/question/edit.php?cmid=$sammlung');
    }
    return _text(r, 'nicht gefunden', status: 404);
  }

  Map<String, dynamic> _kategorieFormular(Map<String, dynamic> a, Map<String, dynamic> fehler) {
    final daten = Uri.splitQueryString('${a['formdata']}');
    final id = int.tryParse(daten['categoryid'] ?? daten['id'] ?? '');
    if (id == null || !kategorien.containsKey(id)) return fehler;
    final bank = _bank(id);
    if (daten.containsKey('name') && daten.containsKey('_qf__qbank_managecategories_form_question_category_edit_form')) {
      beiKategorieAenderung?.call();
      kategorieFormulare.add(daten);
      if (!kategorieUmbenennenWirktNicht) kategorien[id] = daten['name']!;
      final info = daten['info[text]'] ?? '';
      kategorieInfo[id] = infoRendert && info.isNotEmpty && !info.startsWith('<p>') ? '<p>$info</p>' : info;
      kategorieIdnummer[id] = daten['idnumber'] ?? '';
      final parent = daten['parent'];
      if (parent != null) {
        final neu = int.parse(parent.split(',').first);
        final alt = eltern[id] ?? topId(bank);
        if (neu != alt && !istTop(neu) && !_unter(neu, id) && _bank(neu) == bank) eltern[id] = neu;
        if (neu != alt && istTop(neu) && neu == topId(bank)) eltern.remove(id);
      }
      return {'error': false, 'data': {'submitted': true}};
    }
    final nurKind = eltern[id] == null && kategorien.keys.where((k) => eltern[k] == null && _bank(k) == bank).length == 1;
    final optionen = StringBuffer('<option value="${topId(bank)},${_kontext(bank)}"${eltern[id] == null ? ' selected' : ''}>Top</option>');
    for (final k in kategorien.keys.where((k) => _bank(k) == bank && !_unter(k, id))) {
      optionen.write('<option value="$k,${_kontext(bank)}"${eltern[id] == k ? ' selected' : ''}>${kategorien[k]}</option>');
    }
    final html = '''<form class="mform" autocomplete="off"><input type="hidden" name="contextid" value="${_kontext(bank)}">
<input type="hidden" name="cmid" value="$bank"><input type="hidden" name="courseid" value="0"><input type="hidden" name="id" value="$id">
<input type="hidden" name="questioncount" value="${_eintraegeIn(id)}"><input type="hidden" name="sortorder" value="1">
<input type="hidden" name="_qf__qbank_managecategories_form_question_category_edit_form" value="1">
${nurKind ? '' : '<select name="parent">$optionen</select>'}
<input type="text" name="name" value="${kategorien[id]}"><textarea name="info[text]">${kategorieInfo[id] ?? ''}</textarea>
<input type="hidden" name="info[format]" value="1"><input type="text" name="idnumber" value="${kategorieIdnummer[id] ?? ''}"></form>''';
    return {'error': false, 'data': {'html': html}};
  }

  Map<String, dynamic> _kategorieVerschieben(Map<String, dynamic> a, Map<String, dynamic> fehler) {
    kategorieVerschiebeAufrufe.add(a);
    final id = a['categoryid'] as int, ziel = a['targetparentid'] as int;
    final zielBank = istTop(ziel) ? ziel - 900 : (kategorien.containsKey(ziel) ? _bank(ziel) : null);
    if (kategorieVerschiebenAbgelehnt || !kategorien.containsKey(id) || zielBank == null) return fehler;
    beiKategorieAenderung?.call();
    if (!kategorieVerschiebenWirktNicht) {
      for (final k in kategorien.keys.where((k) => _unter(k, id))) {
        bankVon[k] = zielBank;
      }
      if (istTop(ziel)) {
        eltern.remove(id);
      } else {
        eltern[id] = ziel;
      }
    }
    return {'error': false, 'data': <Object?>[]};
  }

  /// Löscht eine Aktivität; eine Fragensammlung nimmt Kategorien und Fragen mit.
  void _aktivitaetWeg(int cmid) {
    kursAktivitaeten.remove(cmid);
    testPlaetze.remove(cmid);
    if (kursBanken.remove(cmid) != null) {
      for (final k in [for (final k in kategorien.keys) if (_bank(k) == cmid) k]) {
        for (final e in eintraege.where((e) => e.kategorie == k)) {
          e.versionen.clear();
        }
        kategorien.remove(k);
      }
    }
  }

  Map<String, dynamic> _kursZustand() => {
        'course': {'sectionlist': kursAbschnitte.keys.map((i) => '$i').toList()},
        'section': [
          for (final a in kursAbschnitte.entries)
            {
              'id': '${a.key}',
              'number': kursAbschnitte.keys.toList().indexOf(a.key),
              'title': a.value,
              'visible': true,
              if (unterabschnitte.containsValue(a.key)) ...{
                'component': 'mod_subsection',
                'parentsectionid': '${kursAktivitaeten[unterabschnitte.entries.firstWhere((e) => e.value == a.key).key]?.abschnitt ?? 0}',
              },
              'cmlist': [for (final c in kursAktivitaeten.entries) if (c.value.abschnitt == a.key) '${c.key}'],
            }
        ],
        'cm': [
          for (final c in kursAktivitaeten.entries)
            {
              'id': '${c.key}',
              'name': c.value.name,
              'module': c.value.modul,
              'visible': true,
              'sectionid': '${c.value.abschnitt}',
              if (unterabschnitte.containsKey(c.key)) 'delegatesectionid': '${unterabschnitte[c.key]}',
            }
        ],
      };

  String _testSeite(int cmid, List<DoppelPlatz> plaetze) {
    final b = StringBuffer();
    var seite = 0;
    var summe = 0.0;
    for (final x in plaetze) {
      while (seite < x.seite) {
        seite++;
        b.write('<li class="pagenumber" id="page-$seite"></li>');
      }
      final v = version(x.frage);
      summe += x.punkte;
      final herkunft = x.bank == null
          ? ''
          : x.zufall
              ? '<a class="mod_quiz_random_qbank_link" href="/question/edit.php?cmid=${x.bank}">Bank</a>'
              : '<div class="sharedbank"><a href="/question/edit.php?cmid=${x.bank}">Bank</a></div>';
      b.write('<li class="slot ${x.zufall ? 'qtype_random' : 'qtype_shortanswer'}" id="slot-${x.slotid}">'
          '${x.zufall ? '' : '<a href="/question/bank/editquestion/question.php?cmid=$sammlung&id=${x.frage}">Bearbeiten</a>'}'
          '$herkunft<span class="questionname">${v?.name ?? 'unbekannt'}</span>'
          '<span class="instancemaxmark">${x.punkte.toStringAsFixed(2).replaceAll('.', ',')}</span></li>');
    }
    return _seite('<script>var q = {"quizid":"7"};</script><ul>$b</ul>'
        '<p>Summe der Punkte: ${summe.toStringAsFixed(2).replaceAll('.', ',')}</p>');
  }

  String _ausgeliefert(DoppelVersion v) => beimExport?.call(v.xml) ?? v.xml;

  String _optionen(int cmid, {bool top = false}) {
    final b = StringBuffer();
    if (top) b.write('<option value="${topId(cmid)},${_kontext(cmid)}">Top für ZZ</option>');
    void ast(int k, int tiefe) {
      b.write('<option value="$k,${_kontext(cmid)}">${'\u00a0' * 3 * tiefe}${kategorien[k]} (${_eintraegeIn(k)})</option>');
      for (final kind in kategorien.keys.where((x) => eltern[x] == k && _bank(x) == cmid)) {
        ast(kind, tiefe + 1);
      }
    }

    for (final k in kategorien.keys.where((k) => eltern[k] == null && _bank(k) == cmid)) {
      ast(k, 0);
    }
    return b.toString();
  }

  Future<void> _um(HttpRequest r, String ziel) async {
    r.response.redirect(Uri.parse(ziel), status: HttpStatus.seeOther);
    await r.response.close();
  }

  Future<void> _text(HttpRequest r, String body, {int status = HttpStatus.ok}) async {
    r.response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..write(body);
    await r.response.close();
  }
}
