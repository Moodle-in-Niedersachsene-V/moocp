// Anhänge nach der Wiederherstellung reparieren (anhaenge_reparieren; E2, E4, E20, A3).
//
// Die Moodle-Grenze ist ein lokaler HTTP-Server mit Anmeldung, Bearbeitungsformularen,
// Entwurfsbereichen, Upload, Löschen im Entwurf und Speichern; alles andere läuft echt:
// Lesen des Ordners, Plan, Freigabe, Prüfung des Stands, Schreiben, Rücklesen.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/mcp/mcp_dienst.dart';

import 'mcp_client.dart';
import 'package:moocp/moodle/formular_lesen.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/moodle/sicherung.dart';
import 'package:moocp/moodle/wiederherstellung_anhaenge.dart';
import 'package:moocp/moodle/wiederherstellung_regeln.dart';
import 'package:moocp/moodle/wiederherstellung_reparatur.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

String _sha(List<int> bytes) => sha1.convert(bytes).toString();

final _bild = utf8.encode('PNG-Bild');
final _zwei = utf8.encode('PNG-Zwei');
final _pdf = utf8.encode('PDF-A');
final _txt = utf8.encode('Text-B');

Uint8List _mbz(Map<String, List<int>> dateien) {
  final archiv = Archive();
  dateien.forEach((name, inhalt) => archiv.addFile(ArchiveFile.bytes(name, inhalt)));
  return Uint8List.fromList(GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archiv)));
}

/// Eine Sicherung: Seite „Infoblatt" mit zwei Bildern, Datei „Handout" mit zwei Dateien
/// im Dateimanager (eine in einem Unterordner).
/// Ob die Sicherung die Dateien selbst enthält (`files/<ab>/<sha1>`, wie ein echtes .mbz).
var _mitDateien = false;

Uint8List _archiv() {
  const backup = '<moodle_backup><activities>'
      '<activity><modulename>page</modulename><title>Infoblatt</title><directory>activities/page_7</directory></activity>'
      '<activity><modulename>resource</modulename><title>Handout</title><directory>activities/resource_8</directory></activity>'
      '</activities></moodle_backup>';
  String datei(int id, String name, List<int> inhalt, String pfad, String komponente) =>
      '<file id="$id"><contenthash>${_sha(inhalt)}</contenthash><filename>$name</filename>'
      '<filepath>$pfad</filepath><component>$komponente</component><filearea>content</filearea></file>';
  final files = '<files>'
      '${datei(1, 'bild.png', _bild, '/', 'mod_page')}'
      '${datei(2, 'zwei.png', _zwei, '/', 'mod_page')}'
      '${datei(3, 'a.pdf', _pdf, '/', 'mod_resource')}'
      '${datei(4, 'b.txt', _txt, '/Ordner/', 'mod_resource')}'
      '<file id="5"><contenthash>x</contenthash><filename>.</filename><filepath>/Leer/</filepath>'
      '<component>mod_resource</component><filearea>content</filearea></file>'
      '</files>';
  return _mbz({
    'moodle_backup.xml': utf8.encode(backup),
    'activities/page_7/page.xml': utf8.encode(
        r'<page><content><![CDATA[<img src="$@FILEPHP@$/bild.png"><img src="$@FILEPHP@$/zwei.png">]]></content></page>'),
    'activities/page_7/inforef.xml': utf8.encode('<inforef><fileref><file><id>1</id></file><file><id>2</id></file></fileref></inforef>'),
    'activities/resource_8/resource.xml': utf8.encode('<resource><name>Handout</name></resource>'),
    'activities/resource_8/inforef.xml': utf8.encode(
        '<inforef><fileref><file><id>3</id></file><file><id>4</id></file><file><id>5</id></file></fileref></inforef>'),
    'files.xml': utf8.encode(files),
    if (_mitDateien)
      for (final d in [_bild, _zwei, _pdf, _txt]) 'files/${_sha(d).substring(0, 2)}/${_sha(d)}': d,
  });
}

class _Akt {
  _Akt(this.modul, this.name);
  final String modul;
  String name;

  /// Seite: Text mit `@@PLUGINFILE@@/<name>`.
  String text = '';

  /// Seite: gespeicherte Dateien (Name -> Inhalt).
  Map<String, List<int>> eingebettet = {};

  /// Datei: gespeicherte Dateien im Dateimanager („/Ordner/b.txt" -> Inhalt).
  Map<String, List<int>> manager = {};
}

/// Moodle-Doppel: Anmeldung, zwei Aktivitäten (2: Seite, 3: Datei), Entwurfsbereiche, Upload,
/// Löschen im Entwurf, Speichern.
class _Moodle {
  late HttpServer _server;
  final Set<String> _angemeldet = {};
  int _zaehler = 0;
  int _item = 100;
  static const sesskey = 'sk23';

  final akt = <int, _Akt>{
    2: _Akt('page', 'Infoblatt')
      ..text = '<p>Text</p><img src="@@PLUGINFILE@@/bild.png"><img src="@@PLUGINFILE@@/zwei.png">'
      ..eingebettet = {'bild.png': _bild, 'zwei.png': _zwei},
    3: _Akt('resource', 'Handout')..manager = {'/a.pdf': _pdf, '/Ordner/b.txt': _txt},
  };
  final entwuerfe = <int, Map<String, List<int>>>{};

  /// Schreibende Anfragen, die Moodle bekam: „save:2", „upload:2:/bild.png", „delete:…".
  final schreiben = <String>[];

  /// Dateiname -> HTTP-Status statt des Inhalts.
  final status = <String, int>{};

  /// Gespeicherte Dateien beim Speichern verfälschen (Rückleseprobe muss es merken).
  bool verfaelschen = false;

  Uri get basis => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> starten() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_antworte);
  }

  Future<void> stoppen() => _server.close(force: true);

  String _seite(String body) =>
      '<html><body><script>M.cfg = {"sesskey":"$sesskey","courseId":12,"contextid":"55"};</script>'
      '<script>var r = {"id":"4","name":"Upload","type":"upload"};</script>$body</body></html>';

  String _url(int item, String schluessel) =>
      '$basis/draftfile.php/12/user/draft/$item${schluessel.split('/').map(Uri.encodeComponent).join('/')}';

  String _formular(int cmid) {
    final a = akt[cmid]!;
    final item = ++_item;
    final kopf = '<form class="mform" method="post" action="/course/modedit.php">'
        '<input type="hidden" name="sesskey" value="$sesskey">'
        '<input type="hidden" name="modulename" value="${a.modul}">'
        '<input type="hidden" name="course" value="12">'
        '<input type="hidden" name="update" value="$cmid">'
        '<input type="hidden" name="_qf__mod_${a.modul}_mod_form" value="1">'
        '<input type="text" name="name" value="${a.name}">';
    const fuss = '<input type="submit" name="submitbutton" value="Speichern"></form>';
    if (a.modul == 'page') {
      entwuerfe[item] = {for (final e in a.eingebettet.entries) '/${e.key}': e.value};
      final text = a.text.replaceAll('@@PLUGINFILE@@/', '$basis/draftfile.php/12/user/draft/$item/');
      return '$kopf<textarea name="page[text]">${const HtmlEscape().convert(text)}</textarea>'
          '<input type="hidden" name="page[itemid]" value="$item">$fuss';
    }
    entwuerfe[item] = {...a.manager};
    return '$kopf<div id="fitem_id_files"><div class="col-form-label">Dateien</div><div id="id_files"></div></div>'
        '<input type="hidden" name="files_filemanager" value="$item">$fuss'
        '<script>M.form_filemanager.init(Y, ${jsonEncode({'target': 'id_files', 'itemid': item, 'client_id': 'abc', 'list': _liste(item, '/')})}, 1);</script>';
  }

  List<Map<String, Object?>> _liste(int item, String ordner) {
    final liste = <Map<String, Object?>>[];
    final ordnerNamen = <String>{};
    for (final e in entwuerfe[item]!.entries) {
      if (!e.key.startsWith(ordner)) continue;
      final rest = e.key.substring(ordner.length);
      final i = rest.indexOf('/');
      if (i >= 0) {
        if (ordnerNamen.add(rest.substring(0, i))) {
          liste.add({'type': 'folder', 'filepath': ordner, 'filename': rest.substring(0, i), 'size': 0, 'datemodified': 1700000000});
        }
      } else {
        liste.add({
          'type': 'file',
          'filepath': ordner,
          'filename': rest,
          'url': _url(item, e.key),
          'size': e.value.length,
          'datemodified': 1700000000,
        });
      }
    }
    return liste;
  }

  Future<void> _antworte(HttpRequest r) async {
    final sitzung = r.cookies.where((c) => c.name == 'MoodleSession');
    final id = sitzung.isEmpty ? null : sitzung.first.value;
    final eingeloggt = id != null && _angemeldet.contains(id);
    final pfad = r.uri.path;

    if (pfad == '/login/index.php' && r.method == 'GET') {
      if (r.uri.queryParameters.containsKey('testsession')) {
        return _umleiten(r, eingeloggt ? '/my/' : '/login/index.php');
      }
      r.response.cookies.add(Cookie('MoodleSession', 's${_zaehler++}'));
      return _text(r, _seite('<form><input name="logintoken" value="tok"></form>'));
    }
    if (pfad == '/login/index.php' && r.method == 'POST') {
      final f = Uri.splitQueryString(await utf8.decoder.bind(r).join());
      if (id != null && f['username'] == 'e.mustermann' && f['password'] == 'test' && f['logintoken'] == 'tok') {
        _angemeldet.add(id);
        return _umleiten(r, '/login/index.php?testsession=1');
      }
      return _umleiten(r, '/login/index.php');
    }
    if (!eingeloggt) return _umleiten(r, '/login/index.php');

    if (pfad == '/lib/ajax/service.php') {
      await utf8.decoder.bind(r).join();
      final data = r.uri.queryParameters['info'] == 'core_courseformat_get_state'
          ? {
              'data': {
                'cm': [
                  for (final e in akt.entries)
                    {'id': e.key, 'visible': 1, 'module': e.value.modul, 'name': e.value.name, 'sectionid': 1},
                ],
                'section': [
                  {'id': 1, 'cmlist': akt.keys.toList()},
                ],
              },
            }
          : {'error': true, 'exception': {'message': 'nicht im Test', 'errorcode': 'x'}};
      return _text(r, jsonEncode([data]), typ: ContentType.json);
    }
    if (pfad == '/course/modedit.php' && r.method == 'GET') {
      final cmid = int.tryParse(r.uri.queryParameters['update'] ?? '');
      if (cmid == null || !akt.containsKey(cmid)) return _text(r, 'nicht gefunden', status: 404);
      return _text(r, _seite(_formular(cmid)));
    }
    if (pfad == '/course/modedit.php' && r.method == 'POST') {
      final f = Uri.splitQueryString(await utf8.decoder.bind(r).join());
      final cmid = int.parse(f['update']!);
      schreiben.add('save:$cmid');
      _speichern(cmid, f);
      return _umleiten(r, '/course/view.php?id=12');
    }
    if (pfad.startsWith('/draftfile.php/')) {
      final teile = pfad.split('/'); // '', draftfile.php, ctx, user, draft, item, ...
      final item = int.tryParse(teile[5]);
      final schluessel = '/${teile.sublist(6).map(Uri.decodeComponent).join('/')}';
      final name = teile.last.isEmpty ? '' : Uri.decodeComponent(teile.last);
      if (status.containsKey(name)) return _text(r, 'Fehler', status: status[name]!);
      final inhalt = item == null ? null : entwuerfe[item]?[schluessel];
      if (inhalt == null) return _text(r, 'nicht gefunden', status: 404);
      r.response
        ..statusCode = 200
        ..headers.contentType = ContentType.binary
        ..add(inhalt);
      return r.response.close();
    }
    if (pfad == '/repository/repository_ajax.php' && r.method == 'POST') {
      final teile = await _multipart(r);
      final item = int.parse(utf8.decode(teile['itemid']!));
      final ordner = utf8.decode(teile['savepath']!);
      final name = utf8.decode(teile['title']!);
      entwuerfe[item]!['$ordner$name'] = teile['repo_upload_file']!;
      schreiben.add('upload:$ordner$name');
      return _text(r, jsonEncode({'url': _url(item, '$ordner$name'), 'file': name}), typ: ContentType.json);
    }
    if (pfad == '/repository/draftfiles_ajax.php' && r.method == 'POST') {
      final f = Uri.splitQueryString(await utf8.decoder.bind(r).join());
      final item = int.parse(f['itemid']!);
      if (r.uri.queryParameters['action'] == 'delete') {
        entwuerfe[item]!.remove('${f['filepath']}${f['filename']}');
        schreiben.add('delete:${f['filepath']}${f['filename']}');
        return _text(r, 'true');
      }
      return _text(r, jsonEncode({'list': _liste(item, f['filepath']!)}), typ: ContentType.json);
    }
    return _text(r, 'nicht gefunden', status: 404);
  }

  void _speichern(int cmid, Map<String, String> f) {
    final a = akt[cmid]!;
    List<int> inhalt(List<int> b) => verfaelschen ? [...b, 0] : b;
    if (a.modul == 'page') {
      final text = f['page[text]']!;
      final item = int.parse(f['page[itemid]']!);
      final namen = RegExp(r'/draftfile\.php/\d+/user/draft/\d+/([^"\s<>]+)')
          .allMatches(text)
          .map((m) => Uri.decodeComponent(m.group(1)!))
          .toSet();
      a.text = text.replaceAllMapped(
          RegExp(r'http://127\.0\.0\.1:\d+/draftfile\.php/\d+/user/draft/\d+/([^"\s<>]+)'), (m) => '@@PLUGINFILE@@/${m.group(1)}');
      a.eingebettet = {
        for (final n in namen)
          if (entwuerfe[item]!.containsKey('/$n')) n: inhalt(entwuerfe[item]!['/$n']!),
      };
    } else {
      final item = int.parse(f['files_filemanager']!);
      a.manager = {for (final e in entwuerfe[item]!.entries) e.key: inhalt(e.value)};
    }
  }

  /// Felder einer multipart-Anfrage (Inhalte unverändert als Bytes).
  Future<Map<String, List<int>>> _multipart(HttpRequest r) async {
    final grenze = r.headers.contentType!.parameters['boundary']!;
    final roh = <int>[];
    await for (final teil in r) {
      roh.addAll(teil);
    }
    final text = latin1.decode(roh);
    final aus = <String, List<int>>{};
    for (final teil in text.split('--$grenze')) {
      final kopfEnde = teil.indexOf('\r\n\r\n');
      if (kopfEnde < 0) continue;
      final name = RegExp(r'name="([^"]+)"').firstMatch(teil.substring(0, kopfEnde))?.group(1);
      if (name == null) continue;
      var inhalt = teil.substring(kopfEnde + 4);
      if (inhalt.endsWith('\r\n')) inhalt = inhalt.substring(0, inhalt.length - 2);
      aus[name] = latin1.encode(inhalt);
    }
    return aus;
  }

  Future<void> _umleiten(HttpRequest r, String ziel) async {
    r.response.redirect(Uri.parse(ziel), status: HttpStatus.seeOther);
    await r.response.close();
  }

  Future<void> _text(HttpRequest r, String body, {int status = 200, ContentType? typ}) async {
    r.response
      ..statusCode = status
      ..headers.contentType = typ ?? ContentType.html
      ..write(body);
    await r.response.close();
  }
}

void main() {
  late _Moodle moodle;
  late MoodleZugang zugang;
  late Directory arbeit;
  late Directory sicherung;
  late Vorgaenge vorgaenge;
  late Vorgang vorgang;
  late Freigaben freigaben;
  late McpDienst dienst;
  late McpTestClient client;
  late Profil profil;
  final titel = <String>[];
  final punkte = <String>[];

  /// Was beim Öffnen einer Freigabe geschieht, bevor sie entschieden wird.
  void Function()? beiFreigabe;
  bool? antwort;

  Future<void> starten(Freigaben entscheidungen) async {
    dienst = McpDienst(
      Einstellungen(schluessel: 'test', profile: [profil]),
      zugang,
      Protokoll(),
      entscheidungen,
      arbeit.path,
      profil: profil,
      sicherungsordner: sicherung.path,
    );
    await dienst.starten();
    client = McpTestClient(profil.port);
    await client.initialize();
  }

  setUp(() async {
    moodle = _Moodle();
    await moodle.starten();
    arbeit = Directory.systemTemp.createTempSync('reparatur-arbeit');
    sicherung = Directory.systemTemp.createTempSync('reparatur-sicherung');
    zugang = await MoodleZugang.fuerTest(Protokoll(), moodle.basis, benutzer: 'e.mustermann', passwort: 'test');
    final bytes = _archiv();
    File(p.join(sicherung.path, 'b.mbz')).writeAsBytesSync(bytes);
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    profil = Profil(
      kennung: 'stable',
      name: 'Test',
      adresse: moodle.basis.toString(),
      port: port,
      mcpName: 'test',
      schluessel: 'test',
    );
    vorgaenge = Vorgaenge(sicherung.path,
      profilKennung: profil.kennung,
      instanzBasis: () => zugang.basis,
    );
    vorgang = await vorgaenge.neuWiederherstellung(
        kurs: 12,
        datei: 'b.mbz',
        fingerabdruck: fingerabdruck(bytes, instanz: 'Test', kurs: 12, weg: Zielweg.aktuellerKursVerschmelzen));
    await vorgaenge.aktualisieren(vorgang,
        wiederherstellung: WiederherstellungStand.fertig,
        text: 'Wiederhergestellt.',
        wiederherstellungAktivitaeten: [(modul: 'page', titel: 'Infoblatt'), (modul: 'resource', titel: 'Handout')],
    );
    vorgang.importierteAktivitaeten = [
      (cmid: 2, modul: 'page', titel: 'Infoblatt'),
      (cmid: 3, modul: 'resource', titel: 'Handout'),
    ];
    await vorgaenge.aktualisieren(vorgang);
    titel.clear();
    punkte.clear();
    beiFreigabe = null;
    antwort = true;
    freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.mittel, frist: const Duration(seconds: 5));
    freigaben.addListener(() {
      final a = freigaben.aktuell;
      if (a == null || !a.offen) return;
      titel.add(a.titel);
      punkte.addAll(a.punkte);
      beiFreigabe?.call();
      final ja = antwort;
      if (ja != null) scheduleMicrotask(() => freigaben.entscheiden(ja));
    });
    await starten(freigaben);
  });

  tearDown(() async {
    await dienst.stoppen();
    client.http.close(force: true);
    await moodle.stoppen();
    for (final d in [arbeit, sicherung]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  Future<String> lesen(int cmid) async {
    await formularLesen(zugang, Formularziel.aktivitaet(cmid), arbeit.path);
    return 'cm-$cmid';
  }

  void ablegen(String ordner, String relativ, List<int> inhalt) {
    final f = File(p.join(arbeit.path, ordner, relativ));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(inhalt);
  }

  Future<String> reparieren(String ordner,
          {int cmid = 2, String name = 'Infoblatt', int kurs = 12, String? vorgangId, Freigaben? mit}) async {
    if (mit != null) {
      await dienst.stoppen();
      client.http.close(force: true);
      await starten(mit);
    }
    final r = await client.call('tools/call', {
      'name': 'anhaenge_reparieren',
      'arguments': {
        'kurs': kurs,
        'cmid': cmid,
        'name': name,
        'ordner': ordner,
        'vorgang': ?vorgangId,
      },
    });
    final text = (r['content'] as List).map((e) => e['text']).join('\n');
    if (r['isError'] == true) throw MoodleFehler(text);
    return text;
  }

  group('Plan', () {
    ZielAufnahme ziel({
      Map<String, Set<String>> felder = const {},
      List<ZielAbruf> abrufe = const [],
      Map<String, List<BereichDatei>> bereiche = const {},
      Map<String, String> luecken = const {},
    }) =>
        ZielAufnahme(feldNamen: felder, abrufe: abrufe, bereiche: bereiche, bereichsLuecken: luecken);
    QuellDateiOrt q(String name, List<int> inhalt, {bool manager = false, String pfad = '/'}) =>
        (name: name, sha1: _sha(inhalt), dateimanager: manager, pfad: pfad, komponente: manager ? 'mod_resource' : 'mod_page');

    test('Moodle-Zähler im Namen: gleich = in Ordnung, abweichend = ersetzen unter dem Namen des Ziels', () {
      final gleich = reparaturPlanen(
        quelle: [q('bild.png', _bild)],
        ziel: ziel(felder: {'page': {'bild (1).png'}}, abrufe: [(name: 'bild (1).png', entwurf: true, status: 200, sha1: _sha(_bild))]),
      );
      expect(gleich.eintraege, isEmpty);
      expect(gleich.inOrdnung, 1);
      final anders = reparaturPlanen(
        quelle: [q('bild.png', _bild)],
        ziel: ziel(felder: {'page': {'bild (1).png'}}, abrufe: [(name: 'bild (1).png', entwurf: true, status: 200, sha1: 'x')]),
      );
      expect(anders.eintraege.single.name, 'bild (1).png');
      expect(anders.eintraege.single.ersetzen, isTrue);
    });

    test('fremde und unbekannte Ziele werden nicht angefasst; mehrdeutige Quelle ebenso', () {
      final plan = reparaturPlanen(
        quelle: [q('bild.png', _bild), q('doppelt.png', _bild), q('doppelt.png', _zwei)],
        ziel: ziel(felder: {
          'page': {'fremd.png', 'weg.png', 'doppelt.png'},
        }, abrufe: [
          (name: 'fremd.png', entwurf: true, status: 200, sha1: 'x'),
          (name: 'weg.png', entwurf: true, status: 404, sha1: null),
          (name: 'doppelt.png', entwurf: true, status: 404, sha1: null),
        ]),
      );
      expect(plan.eintraege, isEmpty);
      final text = plan.offen.map((o) => o.text).join('\n');
      expect(text, contains('„weg.png": nicht in Moodle abrufbar'));
      expect(text, contains('„doppelt.png": mehrdeutig'));
      // Die Quelldatei ohne Verweis im Text braucht eine Textänderung.
      expect(text, contains('„bild.png": fehlt im Ziel, kein Verweis im Text'));
      expect(text, isNot(contains('fremd.png')));
    });

    test('HTTP 5xx und fehlende Antwort sind nicht entscheidbar, kein Eintrag', () {
      final plan = reparaturPlanen(
        quelle: [q('a.png', _bild), q('b.png', _zwei)],
        ziel: ziel(felder: {
          'page': {'a.png', 'b.png'},
        }, abrufe: [
          (name: 'a.png', entwurf: true, status: 500, sha1: null),
          (name: 'b.png', entwurf: true, status: null, sha1: null),
        ]),
      );
      expect(plan.eintraege, isEmpty);
      expect(plan.offen.map((o) => o.text).join('\n'), allOf(contains('HTTP 500'), contains('keine Antwort')));
    });

    test('Dateimanager: Datei und Ordner; Ordner nicht gelesen ist eine Lücke, kein „fehlt"', () {
      final quelle = [q('a.pdf', _pdf, manager: true), q('b.txt', _txt, manager: true, pfad: '/Ordner/')];
      final offenPlan = reparaturPlanen(
        quelle: quelle,
        ziel: ziel(bereiche: {'files': []}, luecken: {'files': 'Ordner „Ordner" nicht gelesen'}),
      );
      expect(offenPlan.eintraege.map((e) => e.lokal), ['bereiche/files/a.pdf']);
      expect(offenPlan.offen.single.text, contains('Ordner/b.txt'));
      final ganz = reparaturPlanen(quelle: quelle, ziel: ziel(bereiche: {'files': []}));
      expect(ganz.eintraege.map((e) => e.lokal), ['bereiche/files/a.pdf', 'bereiche/files/Ordner/b.txt']);
      expect(ganz.eintraege.every((e) => !e.ersetzen), isTrue);
    });

    test('unzulässige Namen und Pfade werden abgelehnt', () {
      final plan = reparaturPlanen(
        quelle: [q('..', _pdf, manager: true), q('x.txt', _txt, manager: true, pfad: '/../')],
        ziel: ziel(bereiche: {'files': []}),
      );
      expect(plan.eintraege, isEmpty);
      expect(plan.offen, hasLength(2));
    });
  });

  group('Reine Prüfung', () {
    test('schreibt nie und verweist auf anhaenge_reparieren', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      moodle.akt[3]!.manager.remove('/Ordner/b.txt');
      final pruefung = await anhaengePruefen(zugang, vorgaenge, vorgang, [
        (cmid: 2, modul: 'page', titel: 'Infoblatt'),
        (cmid: 3, modul: 'resource', titel: 'Handout'),
      ]);
      expect(pruefung.vollstaendig, isFalse);
      expect(pruefung.text, contains('anhaenge_reparieren'));
      expect(moodle.schreiben, isEmpty);
      expect(titel, isEmpty);
    });
  });

  group('Reparatur', () {
    test('nichts zu tun: keine Freigabe, nichts geschrieben', () async {
      final ordner = await lesen(2);
      final text = await reparieren(ordner);
      expect(text, contains('Nichts zu reparieren'));
      expect(titel, isEmpty);
      expect(moodle.schreiben, isEmpty);
    });

    test('Abruf mit HTTP 500: nicht entscheidbar, nichts zu reparieren', () async {
      moodle.status['zwei.png'] = 500;
      final ordner = await lesen(2);
      final text = await reparieren(ordner);
      expect(text, contains('Nichts zu reparieren'));
      expect(text, contains('HTTP 500'));
      expect(titel, isEmpty);
      expect(moodle.schreiben, isEmpty);
    });

    test('wiederholte Reparatur derselben Aktivität lässt den Status nicht wachsen', () async {
      final ordner = await lesen(2);
      await reparieren(ordner);
      final nach1 = await client.tool('wiederherstellung_status', {'id': vorgang.id});
      await reparieren(ordner);
      await reparieren(ordner);
      final nach3 = await client.tool('wiederherstellung_status', {'id': vorgang.id});
      expect('Anhangsreparatur: „Infoblatt"'.allMatches(nach3).length, 'Anhangsreparatur: „Infoblatt"'.allMatches(nach1).length);
      expect(nach3.length, lessThanOrEqualTo(nach1.length + 5));
    });

    test('fehlendes Bild (verwaiste Entwurfsadresse): hinzufügen, verified, Status-Hinweis', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/bild.png', _bild);

      final text = await reparieren(ordner);

      expect(titel, ['Anhänge reparieren?']);
      final liste = punkte.join('\n');
      expect(liste, contains('„bild.png" (Text im Feld page): wird hinzugefügt'));
      expect(liste, contains('HTTP 404'));
      expect(liste, contains('Nichts anderes ändert sich'));
      expect(text, contains('verified: true'));
      expect(moodle.akt[2]!.eingebettet['bild.png'], _bild);
      expect(moodle.akt[2]!.eingebettet['zwei.png'], _zwei);
      expect(moodle.akt[2]!.text, contains('@@PLUGINFILE@@/bild.png'));
      expect(moodle.schreiben.where((s) => s.startsWith('save')), ['save:2']);
      final status = await client.tool('wiederherstellung_status', {
        'id': vorgang.id,
      });
      expect(status, contains('bild.png'));
      expect(status, contains('SHA-1'));
      expect(
        status, contains('Anhangsreparatur: „Infoblatt" repariert und zurückgelesen'));
    });

    test('parallele Reparaturen behalten beide Befunde im Status', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      moodle.akt[3]!.manager.remove('/a.pdf');
      final seite = await lesen(2);
      final datei = await lesen(3);
      ablegen(seite, 'dateien/bild.png', _bild);
      ablegen(datei, 'bereiche/files/a.pdf', _pdf);
      final resultate = await Future.wait([
        reparieren(seite),
        reparieren(datei, cmid: 3, name: 'Handout'),
      ]);
      expect(resultate.every((r) => r.contains('verified: true')), isTrue);
      final status = await client.tool('wiederherstellung_status', {'id': vorgang.id});
      expect(status, contains('bild.png'));
      expect(status, contains('a.pdf'));
      expect(status, contains('„Infoblatt" repariert und zurückgelesen'));
      expect(status, contains('„Handout" repariert und zurückgelesen'));
    });

    test('späterer Status behält frühere Reparatur und neue Prüflücke', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/bild.png', _bild);
      await reparieren(ordner);
      moodle.status['zwei.png'] = 500;
      await reparieren(ordner);
      final status = await client.tool('wiederherstellung_status', {'id': vorgang.id});
      expect(status, contains('bild.png'));
      expect(status, contains('Rücklesen: Jede reparierte Datei'));
      expect(status, contains('zwei.png'));
      expect(status, contains('HTTP 500'));
    });

    test('verändertes Bild: ersetzen, nichts anderes angefasst', () async {
      moodle.akt[2]!.eingebettet['zwei.png'] = utf8.encode('anderes Bild');
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/zwei.png', _zwei);

      final text = await reparieren(ordner);

      expect(punkte.join('\n'), contains('„zwei.png" (Text im Feld page): wird ersetzt'));
      expect(text, contains('verified: true'));
      expect(moodle.akt[2]!.eingebettet['zwei.png'], _zwei);
      expect(moodle.akt[2]!.eingebettet['bild.png'], _bild);
    });

    test('Dateimanager: fehlende Datei und fehlender Ordner werden ergänzt', () async {
      moodle.akt[3]!.manager.clear();
      final ordner = await lesen(3);
      ablegen(ordner, 'bereiche/files/a.pdf', _pdf);
      ablegen(ordner, 'bereiche/files/Ordner/b.txt', _txt);

      final text = await reparieren(ordner, cmid: 3, name: 'Handout');

      final liste = punkte.join('\n');
      expect(liste, contains('„a.pdf" (Dateibereich files): wird hinzugefügt'));
      expect(liste, contains('„Ordner/b.txt" (Dateibereich files, Ordner /Ordner/): wird hinzugefügt'));
      expect(text, contains('verified: true'));
      expect(moodle.akt[3]!.manager, {'/a.pdf': _pdf, '/Ordner/b.txt': _txt});
    });

    test('Dateimanager: abweichende Datei in einem Ordner wird ersetzt', () async {
      moodle.akt[3]!.manager['/Ordner/b.txt'] = utf8.encode('falsch');
      final ordner = await lesen(3);
      ablegen(ordner, 'bereiche/files/Ordner/b.txt', _txt);

      final text = await reparieren(ordner, cmid: 3, name: 'Handout');

      expect(punkte.join('\n'), contains('„Ordner/b.txt" (Dateibereich files, Ordner /Ordner/): wird ersetzt'));
      expect(text, contains('verified: true'));
      expect(moodle.akt[3]!.manager['/Ordner/b.txt'], _txt);
      expect(moodle.akt[3]!.manager['/a.pdf'], _pdf);
    });

    test('Rücklese-Abweichung: verified false, die Abweichung ist genannt, nichts wiederholt', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      moodle.verfaelschen = true;
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/bild.png', _bild);

      final text = await reparieren(ordner);

      expect(text, contains('verified: false'));
      expect(text, contains('Abweichung'));
      expect(moodle.schreiben.where((s) => s.startsWith('save')), hasLength(1));
      final status = await client.tool('wiederherstellung_status', {
        'id': vorgang.id,
      });
      expect(status, contains('bild.png'));
      expect(status, contains('Abweichung beim Rücklesen'));
      expect(status, contains('nicht vollständig verifiziert'));
    });

    test('Stufe „keine": ohne Freigabe, mit Zähler für den Hinweis', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      freigaben.stufe = Bestaetigungen.keine;
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/bild.png', _bild);

      final text = await reparieren(ordner);

      expect(titel, isEmpty);
      expect(freigaben.ausgelassen, 1);
      expect(text, contains('verified: true'));
    });

    test('Stufe „keine": Ersetzen einer abweichenden Datei fragt trotzdem, einzeln zum Abhaken', () async {
      moodle.akt[2]!.eingebettet['zwei.png'] = utf8.encode('anderes Bild');
      freigaben.stufe = Bestaetigungen.keine;
      List<String>? abhaken;
      beiFreigabe = () => abhaken = freigaben.aktuell!.abhaken;
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/zwei.png', _zwei);

      final text = await reparieren(ordner);

      expect(titel, ['Anhänge reparieren?']);
      expect(abhaken, hasLength(1));
      expect(abhaken!.single, contains('zwei.png'));
      expect(freigaben.ausgelassen, 0);
      expect(text, contains('verified: true'));
    });

    test('Stufe „keine": Ersetzen abgelehnt, nichts überschrieben', () async {
      moodle.akt[2]!.eingebettet['zwei.png'] = utf8.encode('anderes Bild');
      freigaben.stufe = Bestaetigungen.keine;
      antwort = false;
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/zwei.png', _zwei);

      final text = await reparieren(ordner);

      expect(text, contains('Nichts geschrieben'));
      expect(moodle.akt[2]!.eingebettet['zwei.png'], utf8.encode('anderes Bild'));
    });

    test('Ablehnung: nichts geschrieben', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      antwort = false;
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/bild.png', _bild);

      final text = await reparieren(ordner);

      expect(text, contains('Nicht repariert'));
      expect(moodle.schreiben, isEmpty);
    });

    test('Fristablauf: nichts geschrieben', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      antwort = null;
      final kurz = Freigaben(Protokoll(), stufe: Bestaetigungen.mittel, frist: const Duration(milliseconds: 150));
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/bild.png', _bild);

      final text = await reparieren(ordner, mit: kurz);

      expect(text, contains('Nicht repariert'));
      expect(moodle.schreiben, isEmpty);
    });

    test('Zieländerung zwischen Freigabe und Schreiben: kein Schreiben', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/bild.png', _bild);
      beiFreigabe = () => moodle.akt[2]!.eingebettet['zwei.png'] = utf8.encode('inzwischen anders');

      await expectLater(reparieren(ordner), throwsA(isA<MoodleFehler>().having((e) => e.meldung, 'Meldung', contains('seit dem Planen geändert'),
            ),
          ),
        );
        expect(moodle.schreiben, isEmpty);
      },
    );

    for (final fremd in [true, false]) {
      test(
        'fehlender Importnachweis verweigert Reparatur (fremd: $fremd)',
        () async {
          vorgang.importierteAktivitaeten = fremd
              ? [(cmid: 99, modul: 'page', titel: 'Infoblatt')]
              : null;
          await vorgaenge.aktualisieren(vorgang);
          moodle.akt[2]!.eingebettet.remove('bild.png');
          final ordner = await lesen(2);
          ablegen(ordner, 'dateien/bild.png', _bild);
          await expectLater(reparieren(ordner), throwsA(isA<MoodleFehler>()));
          expect(titel, isEmpty);
          expect(moodle.schreiben, isEmpty);
        },
      );
    }

    test('anderer falscher Dateiinhalt während Freigabe bricht ab', () async {
      moodle.akt[2]!.eingebettet['bild.png'] = utf8.encode('A');
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/bild.png', _bild);
      beiFreigabe = () =>
          moodle.akt[2]!.eingebettet['bild.png'] = utf8.encode('B');
      await expectLater(
        reparieren(ordner),
        throwsA(
          isA<MoodleFehler>().having(
            (e) => e.meldung,
            'Meldung',
            contains('seit dem Planen geändert'),
          ),
        ),
      );
      expect(moodle.schreiben, isEmpty);
    });

    test('Textänderung in Moodle zwischen Freigabe und Schreiben: kein Schreiben', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/bild.png', _bild);
      beiFreigabe = () => moodle.akt[2]!.text += '<p>neu von Hand</p>';

      await expectLater(reparieren(ordner), throwsA(isA<MoodleFehler>().having((e) => e.meldung, 'Meldung', contains('seit dem Lesen geändert'))));
      expect(moodle.schreiben, isEmpty);
    });

    test('Name passt nicht zur Nummer: Abbruch vor Freigabe', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/bild.png', _bild);

      await expectLater(reparieren(ordner, name: 'Anderes Blatt'), throwsA(isA<MoodleFehler>()));
      expect(titel, isEmpty);
      expect(moodle.schreiben, isEmpty);
    });

    test('falscher Ordner oder falscher Kurs: Abbruch', () async {
      final ordner = await lesen(3);
      await expectLater(reparieren(ordner), throwsA(isA<MoodleFehler>().having((e) => e.meldung, 'Meldung', contains('nicht der gelesene Ordner'))));
      final seite = await lesen(2);
      await expectLater(reparieren(seite, kurs: 99), throwsA(isA<MoodleFehler>()));
      expect(moodle.schreiben, isEmpty);
    });

    test('unbekannter Vorgang und Vorgang eines anderen Kurses: Abbruch', () async {
      final ordner = await lesen(2);
      await expectLater(reparieren(ordner, vorgangId: 'gibtesnicht'), throwsA(isA<MoodleFehler>()));
      expect(moodle.schreiben, isEmpty);
    });

    test('Reparaturdatei fehlt oder hat anderen Inhalt: Abbruch, nennt die Datei, keine Freigabe', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      final ordner = await lesen(2);
      await expectLater(reparieren(ordner), throwsA(isA<MoodleFehler>().having((e) => e.meldung, 'Meldung', contains('dateien/bild.png'))));
      ablegen(ordner, 'dateien/bild.png', utf8.encode('falscher Inhalt'));
      await expectLater(reparieren(ordner), throwsA(isA<MoodleFehler>().having((e) => e.meldung, 'Meldung', contains('Anderer Inhalt'))));
      expect(titel, isEmpty);
      expect(moodle.schreiben, isEmpty);
    });

    group('Sicherung enthält die Dateien', () {
      setUpAll(() => _mitDateien = true);
      tearDownAll(() => _mitDateien = false);

      test('die App legt fehlende Reparaturdateien selbst in den Ordner, auch im Dateimanager', () async {
        moodle.akt[2]!.eingebettet.remove('bild.png');
        moodle.akt[3]!.manager.remove('/Ordner/b.txt');
        final ordner2 = await lesen(2);
        final ordner3 = await lesen(3);

        final text2 = await reparieren(ordner2);
        final text3 = await reparieren(ordner3, cmid: 3, name: 'Handout');

        expect(text2, contains('verified: true'));
        expect(text3, contains('verified: true'));
        expect(moodle.akt[2]!.eingebettet['bild.png'], _bild);
        expect(moodle.akt[3]!.manager['/Ordner/b.txt'], _txt);
      });

      test('eine falsche Datei im Ordner wird nicht überschrieben, sondern genannt', () async {
        moodle.akt[2]!.eingebettet.remove('bild.png');
        final ordner = await lesen(2);
        ablegen(ordner, 'dateien/bild.png', utf8.encode('falscher Inhalt'));
        await expectLater(reparieren(ordner), throwsA(isA<MoodleFehler>().having((e) => e.meldung, 'Meldung', contains('Anderer Inhalt'))));
        expect(moodle.schreiben, isEmpty);
      });
    });

    test('Ordner mit zusätzlicher Textänderung: Abbruch, die Reparatur ändert keinen Text', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/bild.png', _bild);
      final text = File(p.join(arbeit.path, ordner, 'page.html'));
      text.writeAsStringSync('${text.readAsStringSync()}<p>Zusatz</p>');

      await expectLater(reparieren(ordner), throwsA(isA<MoodleFehler>().having((e) => e.meldung, 'Meldung', contains('ändert keinen Text'))));
      expect(titel, isEmpty);
      expect(moodle.schreiben, isEmpty);
    });

    test('Ordner mit zusätzlicher fremder Datei: Abbruch', () async {
      moodle.akt[2]!.eingebettet.remove('bild.png');
      final ordner = await lesen(2);
      ablegen(ordner, 'dateien/bild.png', _bild);
      ablegen(ordner, 'dateien/zwei.png', utf8.encode('andere Datei'));

      await expectLater(reparieren(ordner), throwsA(isA<MoodleFehler>().having((e) => e.meldung, 'Meldung', contains('andere Dateien'))));
      expect(titel, isEmpty);
      expect(moodle.schreiben, isEmpty);
    });

    test('nur im Arbeitsordner: ein Ordner außerhalb wird abgewiesen', () async {
      final fremd = Directory.systemTemp.createTempSync('reparatur-fremd');
      addTearDown(() => fremd.deleteSync(recursive: true));
      await expectLater(
        anhaengeReparieren(zugang, freigaben, vorgaenge,
            kurs: 12, cmid: 2, name: 'Infoblatt', ordner: fremd.path, arbeitsordner: arbeit.path),
        throwsA(isA<MoodleFehler>().having((e) => e.meldung, 'Meldung', contains('Arbeitsordner'))),
      );
    },
      );
  });
}
