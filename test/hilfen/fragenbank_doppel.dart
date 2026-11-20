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

class DoppelEintrag {
  DoppelEintrag(this.kategorie, this.idnummer, this.typ);
  final int kategorie;
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

  /// Das Löschen wirkt nicht.
  bool loeschenWirktNicht = false;

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
      if (r.method == 'GET') {
        return _text(r, _seite('''<form class="mform" method="post" action="/question/bank/importquestions/import.php?cmid=$sammlung">
<input type="hidden" name="sesskey" value="$sesskey"><input type="hidden" name="_qf__qbank_importquestions_import_form" value="1">
<input type="hidden" name="newfile" value="9">
<select name="category">${_optionen()}</select><select name="format"><option value="xml" selected>xml</option></select>
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
      if (r.method == 'GET') {
        return _text(r, _seite('''<form class="mform" method="post" action="/question/bank/exportquestions/export.php?cmid=$sammlung">
<input type="hidden" name="sesskey" value="$sesskey"><input type="hidden" name="_qf__qbank_exportquestions_export_form" value="1">
<select name="category">${_optionen()}</select><select name="format"><option value="xml" selected>xml</option></select>
<input type="hidden" name="cattofile" value="1"><input type="hidden" name="contexttofile" value="1"></form>'''));
      }
      final f = Uri.splitQueryString(koerper);
      return _um(r, '/pluginfile.php/55/question/export/${f['category']!.split(',').first}/export.xml');
    }
    if (pfad.startsWith('/pluginfile.php/55/question/export/')) {
      final kat = int.parse(pfad.split('/')[5]);
      final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<quiz>\n');
      for (final e in eintraege.where((e) => e.kategorie == kat)) {
        if (e.versionen.isEmpty) continue;
        b.writeln('<!-- question: ${e.neueste.id}  -->');
        b.writeln(_ausgeliefert(e.neueste));
      }
      b.write('</quiz>');
      return _text(r, b.toString());
    }
    if (pfad == '/question/bank/exporttoxml/exportone.php') {
      final v = version(int.parse(r.uri.queryParameters['id']!));
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
        return _text(r, _seite('''<form method="post" action="/question/bank/deletequestion/delete.php">
<input type="hidden" name="sesskey" value="$sesskey"><input type="hidden" name="cmid" value="$sammlung">
<input type="hidden" name="deleteselected" value="$ids"><input type="hidden" name="deleteall" value="${q['deleteall'] ?? '0'}">
<input type="hidden" name="confirm" value="${'a' * 32}"><input type="submit" name="x" value="Löschen"></form>'''));
      }
      for (final s in q['deleteselected']!.split(',')) {
        final id = int.parse(s);
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

  String _ausgeliefert(DoppelVersion v) => beimExport?.call(v.xml) ?? v.xml;

  String _optionen() => [
        for (final k in kategorien.entries)
          '<option value="${k.key},55">${k.value} (${eintraege.where((e) => e.kategorie == k.key && e.versionen.isNotEmpty).length})</option>'
      ].join();

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
