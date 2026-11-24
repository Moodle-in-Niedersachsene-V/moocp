import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/kurshinweise.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/protokoll.dart';

class KursDoppel {
  late HttpServer server;
  final reihenfolge = <int>[10, 20, 30];
  bool vorhanden = true;
  String datei = 'Alt';
  String entwurf = 'Alt';
  String intro = 'Beschreibung';
  int verschiebungen = 0;
  bool verschiebungIgnorieren = false;
  String verzeichnisname = 'CLAUDE';
  Uri get basis => Uri.parse('http://127.0.0.1:${server.port}');

  Future<void> starten() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final bytes = await r.fold<List<int>>([], (a, b) => a..addAll(b));
      final body = utf8.decode(bytes, allowMalformed: true);
      final q = r.uri.queryParameters;
      String antwort = '';
      if (r.uri.path == '/login/index.php') {
        if (r.method == 'POST' || q.containsKey('testsession')) {
          r.response.redirect(
            Uri.parse(
              r.method == 'POST' ? '/login/index.php?testsession=1' : '/my/',
            ),
            status: 303,
          );
          await r.response.close();
          return;
        }
        r.response.cookies.add(Cookie('MoodleSession', 'test'));
        antwort = r.cookies.isEmpty
            ? '<form><input name="logintoken" value="tok"></form>'
            : '<script>M.cfg = {"sesskey":"sk"};</script>Angemeldet';
      } else if (r.uri.path == '/lib/ajax/service.php') {
        final call = (jsonDecode(body) as List).single as Map;
        final args = call['args'] as Map;
        Object data;
        if (call['methodname'] == 'core_courseformat_get_state') {
          data = {
            'section': [
              {
                'id': 1,
                'number': 0,
                'title': 'Allgemeines',
                'visible': 1,
                'cmlist': reihenfolge,
              },
            ],
            'cm': [
              for (final id in reihenfolge)
                {
                  'id': id,
                  'module': id == 20 ? 'folder' : 'page',
                  'name': id == 20 ? verzeichnisname : 'Seite $id',
                  'visible': 0,
                  'sectionid': 1,
                },
            ],
          };
        } else if (call['methodname'] == 'core_courseformat_update_course') {
          if (!verschiebungIgnorieren) {
            reihenfolge.remove(20);
            reihenfolge.insert(
              reihenfolge.indexOf(args['targetcmid'] as int),
              20,
            );
          }
          verschiebungen++;
          data = <String, Object>{};
        } else {
          data = {
            'courses': [
              {'id': 12, 'fullname': 'Musterkurs', 'shortname': 'Muster'},
            ],
          };
        }
        antwort = jsonEncode([
          {'error': false, 'data': data},
        ]);
      } else if (r.uri.path == '/course/modedit.php') {
        if (r.method == 'POST') {
          datei = entwurf;
          intro = Uri.splitQueryString(body)['introeditor[text]'] ?? intro;
          if (!vorhanden) {
            vorhanden = true;
            reihenfolge.add(20);
          }
          r.response.redirect(Uri.parse('/course/view.php?id=12'), status: 303);
          await r.response.close();
          return;
        }
        antwort =
            '''<script>M.cfg = {"sesskey":"sk","courseId":12,"contextid":"55"}; var repos = [{"id":"4","type":"upload"}];</script>
<form class="mform" action="/course/modedit.php" method="post">
<input name="_qf__mod_folder_mod_form" value="1"><input name="sesskey" value="sk"><input name="course" value="12"><input name="update" value="20"><input name="modulename" value="folder"><input name="name" value="CLAUDE"><input name="files" value="9">
<textarea name="introeditor[text]">${const HtmlEscape().convert(intro)}</textarea><input name="introeditor[itemid]" value="9"><input name="introeditor[format]" value="1">
<div class="row fitem" id="fitem_id_display"><label class="col-form-label">Anzeige</label><div class="felement" data-fieldtype="select"><select name="display"><option value="1" selected>Inhalt anzeigen</option></select></div></div>
<div class="row fitem" id="fitem_id_showdescription"><label class="col-form-label">Beschreibung</label><div class="felement" data-fieldtype="advcheckbox"><input type="checkbox" name="showdescription" value="1" checked></div></div>
<script>M.form_filemanager.init(Y, {"target":"id_files","itemid":9,"client_id":"c","list":[${vorhanden ? '{"type":"file","filepath":"/","filename":"CLAUDE.md","size":${utf8.encode(datei).length},"url":"$basis/draftfile.php/5/user/draft/9/CLAUDE.md"}' : ''}]});</script>
<input type="submit" name="submitbutton" value="Speichern"></form>''';
      } else if (r.uri.path == '/repository/draftfiles_ajax.php') {
        antwort = '{}';
      } else if (r.uri.path == '/repository/repository_ajax.php') {
        final match = RegExp(r'\r\n\r\n([^\r\n]+)\r\n--[^\r\n]+--')
            .firstMatch(body);
        entwurf = match?.group(1) ?? '';
        antwort = jsonEncode({
          'url': '$basis/draftfile.php/5/user/draft/9/CLAUDE.md',
        });
      } else if (r.uri.path.startsWith('/draftfile.php/')) {
        antwort = datei;
      } else {
        antwort = '<script>M.cfg = {"sesskey":"sk"};</script>Musterkurs';
      }
      r.response.headers.contentType = ContentType.html;
      r.response.write(antwort);
      await r.response.close();
    });
  }
}

void main() {
  test(
    'Unveränderte Konventionen ordnen das vorhandene Verzeichnis ein',
    () async {
      final d = KursDoppel();
      await d.starten();
      final ordner = await Directory.systemTemp.createTemp('claude-position-');
      final protokoll = Protokoll();
      final moodle = await MoodleZugang.fuerTest(
        protokoll,
        d.basis,
        benutzer: 'muster',
        passwort: 'muster',
      );
      try {
        await claudeSchreiben(
          moodle,
          Freigaben(protokoll, stufe: Bestaetigungen.keine),
          kurs: 12,
          inhalt: 'Alt',
          arbeitsordner: ordner.path,
        );
        expect(d.reihenfolge, [20, 10, 30]);
      } finally {
        moodle.abmelden();
        await d.server.close(force: true);
        await ordner.delete(recursive: true);
      }
    },
  );
  Future<(KursDoppel, Directory, MoodleZugang, Freigaben)> vorbereiten({
    Bestaetigungen stufe = Bestaetigungen.keine,
  }) async {
    final d = KursDoppel();
    await d.starten();
    final ordner = await Directory.systemTemp.createTemp('claude-position-');
    final protokoll = Protokoll();
    final moodle = await MoodleZugang.fuerTest(
      protokoll,
      d.basis,
      benutzer: 'muster',
      passwort: 'muster',
    );
    return (d, ordner, moodle, Freigaben(protokoll, stufe: stufe));
  }

  Future<void> aufraeumen(
    KursDoppel d,
    Directory ordner,
    MoodleZugang moodle,
  ) async {
    moodle.abmelden();
    await d.server.close(force: true);
    await ordner.delete(recursive: true);
  }

  test('Abgelehnte Verschiebung lässt die Reihenfolge unverändert', () async {
    final (d, ordner, moodle, freigaben) = await vorbereiten(
      stufe: Bestaetigungen.mittel,
    );
    freigaben.addListener(() {
      final frage = freigaben.aktuell;
      if (frage != null) {
        scheduleMicrotask(
          () => freigaben.entscheiden(frage.titel != 'Verschieben?'),
        );
      }
    });
    try {
      final bericht = await claudeSchreiben(
        moodle,
        freigaben,
        kurs: 12,
        inhalt: 'Neu',
        arbeitsordner: ordner.path,
      );
      expect(d.reihenfolge, [10, 20, 30]);
      expect(d.verschiebungen, 0);
      expect(bericht, contains('Nicht verschoben'));
    } finally {
      await aufraeumen(d, ordner, moodle);
    }
  });

  test('Geänderter Abschnitt nach Freigabe verhindert Verschieben', () async {
    final (d, ordner, moodle, freigaben) = await vorbereiten(
      stufe: Bestaetigungen.mittel,
    );
    freigaben.addListener(() {
      final frage = freigaben.aktuell;
      if (frage != null) {
        scheduleMicrotask(() {
          if (frage.titel == 'Verschieben?') d.reihenfolge.insert(0, 40);
          freigaben.entscheiden(true);
        });
      }
    });
    try {
      await expectLater(
        claudeSchreiben(
          moodle,
          freigaben,
          kurs: 12,
          inhalt: 'Neu',
          arbeitsordner: ordner.path,
        ),
        throwsA(isA<MoodleFehler>()),
      );
      expect(d.reihenfolge, [40, 10, 20, 30]);
      expect(d.verschiebungen, 0);
    } finally {
      await aufraeumen(d, ordner, moodle);
    }
  });

  test('Umbenennung nach Freigabe verhindert Verschieben', () async {
    final (d, ordner, moodle, freigaben) = await vorbereiten(
      stufe: Bestaetigungen.alle,
    );
    freigaben.addListener(() {
      final frage = freigaben.aktuell;
      if (frage != null) {
        scheduleMicrotask(() {
          if (frage.titel == 'Verschieben?')
            d.verzeichnisname = 'Anderes Verzeichnis';
          freigaben.entscheiden(true);
        });
      }
    });
    try {
      await expectLater(
        claudeSchreiben(
          moodle,
          freigaben,
          kurs: 12,
          inhalt: 'Neu',
          arbeitsordner: ordner.path,
        ),
        throwsA(isA<MoodleFehler>()),
      );
      expect(d.verschiebungen, 0);
      expect(d.reihenfolge, [10, 20, 30]);
    } finally {
      await aufraeumen(d, ordner, moodle);
    }
  });

  test('Nicht ausgeführtes Verschieben wird beim Rücklesen gemeldet', () async {
    final (d, ordner, moodle, freigaben) = await vorbereiten();
    d.verschiebungIgnorieren = true;
    try {
      final bericht = await claudeSchreiben(
        moodle,
        freigaben,
        kurs: 12,
        inhalt: 'Neu',
        arbeitsordner: ordner.path,
      );
      expect(d.reihenfolge, [10, 20, 30]);
      expect(
        bericht,
        contains(
          'Position des Verzeichnisses am Abschnittsanfang: verified: false',
        ),
      );
    } finally {
      await aufraeumen(d, ordner, moodle);
    }
  });
  test('Neues CLAUDE steht nach dem Anlegen am Anfang', () async {
    final d = KursDoppel()
      ..vorhanden = false
      ..datei = '';
    d.reihenfolge.remove(20);
    await d.starten();
    final ordner = await Directory.systemTemp.createTemp('claude-position-');
    final protokoll = Protokoll();
    final moodle = await MoodleZugang.fuerTest(
      protokoll,
      d.basis,
      benutzer: 'muster',
      passwort: 'muster',
    );
    final freigaben = Freigaben(protokoll, stufe: Bestaetigungen.keine);
    try {
      final bericht = await claudeSchreiben(
        moodle,
        freigaben,
        kurs: 12,
        inhalt: 'Neu',
        arbeitsordner: ordner.path,
      );
      expect(d.reihenfolge, [20, 10, 30]);
      expect(d.datei, 'Neu');
      expect(bericht, contains('verified: true'));
    } finally {
      moodle.abmelden();
      await d.server.close(force: true);
      await ordner.delete(recursive: true);
    }
  });
  test(
    'Bestehendes CLAUDE steht nach dem Schreiben vor den anderen Aktivitäten',
    () async {
      final d = KursDoppel();
      await d.starten();
      final ordner = await Directory.systemTemp.createTemp('claude-position-');
      final protokoll = Protokoll();
      final moodle = await MoodleZugang.fuerTest(
        protokoll,
        d.basis,
        benutzer: 'muster',
        passwort: 'muster',
      );
      final freigaben = Freigaben(protokoll, stufe: Bestaetigungen.keine);
      try {
        final bericht = await claudeSchreiben(
          moodle,
          freigaben,
          kurs: 12,
          inhalt: 'Neu',
          arbeitsordner: ordner.path,
        );
        expect(d.reihenfolge, [20, 10, 30]);
        expect(d.datei, 'Neu');
        expect(bericht, contains('verified: true'));
      } finally {
        moodle.abmelden();
        await d.server.close(force: true);
        await ordner.delete(recursive: true);
      }
    },
  );
}
