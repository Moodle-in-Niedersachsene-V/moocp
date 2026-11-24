// sicherung_loeschen: eine eigene Sicherungsdatei in Moodle löschen, die übrigen nachweislich
// erhalten. Nur Moodle wird durch einen lokalen HTTP-Server ersetzt, der Moodles Verhalten
// nachbildet, auf das es ankommt: Der Dateimanager legt einen Entwurf mit Kopien aller
// Dateien an, das Speichern gleicht den Bereich mit dem Entwurf ab und löscht, was fehlt.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/moodle/sicherung.dart';
import 'package:moocp/moodle/sicherung_loeschen.dart';
import 'package:moocp/moodle/sicherung_regeln.dart';
import 'package:moocp/protokoll.dart';

class _Moodle {
  late HttpServer server;
  List<String> bereich = ['a-cm1.mbz', 'ZZ-eigene.mbz', 'c-cm3.mbz'];
  List<String> entwurf = [];
  int speichern = 0;
  int dateimanager = 0;
  int entwurfLoeschen = 0;

  /// Eingriffe, die eine zweite Sitzung der Lehrkraft nachbilden.
  void Function()? beimEntwurfLoeschen;

  /// Moodle meldet Erfolg, löscht aber mehr, als im Entwurf fehlt.
  bool loeschtZuViel = false;
  bool ordnerImEntwurf = false;

  Uri get basis => Uri.parse('http://127.0.0.1:${server.port}');
  String _seite(String body) => '<script>M.cfg = {"sesskey":"sk","courseId":12,"contextid":"55"};</script>$body';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final body = await const Utf8Decoder(allowMalformed: true).bind(r).join();
      final felder = Uri.splitQueryString(body.replaceAll('+', '%20'));
      final path = r.uri.path;
      String antwort;
      if (path == '/login/index.php') {
        if (r.method == 'POST' || r.uri.queryParameters.containsKey('testsession')) {
          r.response.redirect(Uri.parse(r.method == 'POST' ? '/login/index.php?testsession=1' : '/my/'), status: 303);
          await r.response.close();
          return;
        }
        r.response.cookies.add(Cookie('MoodleSession', 'test'));
        antwort = r.cookies.isNotEmpty ? _seite('Angemeldet') : '<form><input name="logintoken" value="tok"></form>';
      } else if (path == '/my/') {
        antwort = _seite('<p>ZZ</p>');
      } else if (path == '/backup/restorefile.php') {
        antwort = _seite([
          for (final n in bereich) '<a href="http://127.0.0.1:${server.port}/pluginfile.php/77/user/backup/$n?forcedownload=1">$n</a>',
        ].join('<br>'));
      } else if (path == '/backup/backupfilesedit.php' && r.method == 'GET') {
        dateimanager++;
        entwurf = [...bereich];
        final liste = [
          for (final n in entwurf) {'filename': n, 'filepath': '/'},
          if (ordnerImEntwurf) {'filename': 'Ordner', 'filepath': '/', 'type': 'folder'},
        ];
        final q = r.uri.queryParameters;
        antwort = _seite(
          '<form class="mform" action="/backup/backupfilesedit.php?currentcontext=${q['currentcontext']}&amp;contextid=${q['contextid']}&amp;component=user&amp;filearea=backup" method="post">'
          '<input type="hidden" name="sesskey" value="sk"><input type="hidden" name="_qf__backup_files_edit_form" value="1">'
          '<input type="hidden" name="files_filemanager" id="id_files_filemanager" value="9001">'
          '<input type="hidden" name="contextid" value="${q['contextid']}"><input type="hidden" name="currentcontext" value="${q['currentcontext']}">'
          '<input type="hidden" name="filearea" value="backup"><input type="hidden" name="component" value="user">'
          '<input type="hidden" name="returnurl" value="${q['returnurl']}"></form>'
          '<script>M.form_filemanager.init(Y, ${jsonEncode({'target': 'id_files_filemanager', 'itemid': 9001, 'client_id': 'cl1', 'list': liste})});</script>',
        );
      } else if (path == '/backup/backupfilesedit.php') {
        speichern++;
        var neu = [...entwurf];
        if (loeschtZuViel && neu.length > 1) neu = neu.sublist(1);
        bereich = neu;
        r.response.redirect(Uri.parse('/backup/restorefile.php?contextid=55'), status: 303);
        await r.response.close();
        return;
      } else if (path == '/repository/draftfiles_ajax.php' && r.uri.queryParameters['action'] == 'delete') {
        entwurfLoeschen++;
        entwurf.remove(felder['filename']);
        beimEntwurfLoeschen?.call();
        antwort = jsonEncode({'filepath': '/', 'filename': felder['filename']});
      } else if (path == '/repository/draftfiles_ajax.php') {
        antwort = jsonEncode({
          'list': [for (final n in entwurf) {'filename': n, 'filepath': '/'}],
        });
      } else {
        antwort = _seite('');
      }
      r.response.write(antwort);
      await r.response.close();
    });
  }
}

void main() {
  late _Moodle moodle;
  late Directory ordner;
  late Freigaben freigaben;
  late MoodleZugang zugang;
  late Vorgaenge vorgaenge;
  late Vorgang vorgang;
  var antwortenAuf = true;
  void Function()? beiFreigabe;

  setUp(() async {
    moodle = _Moodle();
    await moodle.start();
    ordner = Directory.systemTemp.createTempSync('sicherung-loeschen-');
    final log = Protokoll();
    freigaben = Freigaben(log);
    antwortenAuf = true;
    beiFreigabe = null;
    freigaben.addListener(() {
      if (freigaben.aktuell == null) return;
      scheduleMicrotask(() {
        beiFreigabe?.call();
        freigaben.entscheiden(antwortenAuf);
      });
    });
    zugang = await MoodleZugang.fuerTest(log, moodle.basis, benutzer: 'e.mustermann', passwort: 'test');
    vorgaenge = Vorgaenge(ordner.path);
    vorgang = await vorgaenge.neu(kurs: 12, cmid: 5, datei: 'x.mbz');
    await vorgaenge.aktualisieren(vorgang,
        stand: SicherungStand.fertig, kontext: 55, dateiname: 'ZZ-eigene.mbz', verified: true);
  });
  tearDown(() async {
    await moodle.server.close(force: true);
    ordner.deleteSync(recursive: true);
  });

  Future<String> loeschen({String? id, String name = 'ZZ-eigene.mbz'}) =>
      sicherungLoeschen(zugang, freigaben, vorgaenge, id: id ?? vorgang.id, name: name);

  group('Regeln', () {
    test('sicherungsBereich liest Kontext und Namen, ohne Doppelte, URL-dekodiert', () {
      final b = sicherungsBereich(
        '<a href="/pluginfile.php/77/user/backup/b%20x.mbz?forcedownload=1">1</a>'
        '<a href="/pluginfile.php/77/user/backup/a.mbz?forcedownload=1&amp;x=1">2</a>'
        '<a href="/pluginfile.php/77/user/backup/a.mbz?forcedownload=1">3</a>'
        '<a href="/pluginfile.php/55/backup/course/z.mbz?forcedownload=1">anderer Bereich</a>',
      );
      expect(b.kontext, 77);
      expect(b.namen, ['a.mbz', 'b x.mbz']);
    });
    test('mehrere Benutzerkontexte sind nicht eindeutig', () {
      final b = sicherungsBereich(
        '<a href="/pluginfile.php/77/user/backup/a.mbz?forcedownload=1">1</a>'
        '<a href="/pluginfile.php/78/user/backup/b.mbz?forcedownload=1">2</a>',
      );
      expect(b.kontext, -1);
    });
    test('entwurfsNamen lehnt Ordner und Unterpfade ab', () {
      expect(entwurfsNamen([{'filename': 'b', 'filepath': '/'}, {'filename': 'a', 'filepath': '/'}]), ['a', 'b']);
      expect(entwurfsNamen([{'filename': 'x', 'filepath': '/', 'type': 'folder'}]), isNull);
      expect(entwurfsNamen([{'filename': 'x', 'filepath': '/u/'}]), isNull);
      expect(entwurfsNamen('kaputt'), isNull);
    });
    test('Positivliste: nur Sicherungsbereich, nur die Felder des Dateimanagers', () {
      final get = Uri.parse(dateimanagerAdresse(kontext: 55, benutzerKontext: 77));
      expect(zugang.erlaubt('GET', get), isTrue);
      expect(zugang.erlaubt('GET', Uri.parse(get.toString().replaceFirst('filearea=backup', 'filearea=course'))), isFalse);
      expect(zugang.erlaubt('GET', Uri.parse('/backup/backupfilesedit.php?currentcontext=55&contextid=77&filearea=backup&component=user')), isFalse);
      final post = Uri.parse('/backup/backupfilesedit.php?currentcontext=55&contextid=77&component=user&filearea=backup');
      List<MapEntry<String, String>> felder([Map<String, String> extra = const {}]) => [
            const MapEntry('sesskey', 'sk'),
            const MapEntry('_qf__backup_files_edit_form', '1'),
            const MapEntry('files_filemanager', '9001'),
            const MapEntry('contextid', '77'),
            const MapEntry('currentcontext', '55'),
            const MapEntry('filearea', 'backup'),
            const MapEntry('component', 'user'),
            const MapEntry('returnurl', '/backup/restorefile.php?contextid=55'),
            const MapEntry('submitbutton', 'x'),
            ...extra.entries,
          ];
      expect(zugang.erlaubt('POST', post, felder()), isTrue);
      expect(zugang.erlaubt('POST', post, felder({'fremd': '1'})), isFalse);
      expect(zugang.erlaubt('POST', post, [for (final e in felder()) e.key == 'filearea' ? const MapEntry('filearea', 'course') : e]), isFalse);
      expect(zugang.erlaubt('POST', Uri.parse(post.toString().replaceFirst('filearea=backup', 'filearea=course')), felder()), isFalse);
    });
  });

  group('Ablauf', () {
    test('löscht genau die eine Datei, die übrigen bleiben, verified: true', () async {
      final r = await loeschen();
      expect(moodle.bereich, ['a-cm1.mbz', 'c-cm3.mbz']);
      expect(moodle.speichern, 1);
      expect(r, contains('verified: true'));
      expect(r, contains('Gelöscht: ZZ-eigene.mbz'));
      expect(r, contains('2 Dateien'));
    });

    test('die Freigabe nennt die Datei, die bleibenden Dateien und die Restgefahr', () async {
      String? punkte;
      beiFreigabe = () => punkte = freigaben.aktuell!.punkte.join('\n');
      await loeschen();
      expect(punkte, contains('ZZ-eigene.mbz'));
      expect(punkte, contains('a-cm1.mbz'));
      expect(punkte, contains('c-cm3.mbz'));
      expect(punkte, contains('ganzen Bereich neu'));
      expect(punkte, contains('verloren gehen'));
    });

    test('letzte Datei: Bereich ist danach leer, verified: true', () async {
      moodle.bereich = ['ZZ-eigene.mbz'];
      final r = await loeschen();
      expect(moodle.bereich, isEmpty);
      expect(r, contains('keine Datei mehr'));
      expect(r, contains('verified: true'));
    });

    test('abgelehnt: nichts geschrieben, der Dateimanager wird nicht einmal geöffnet', () async {
      antwortenAuf = false;
      final r = await loeschen();
      expect(r, contains('Nicht gelöscht'));
      expect(moodle.dateimanager, 0);
      expect(moodle.speichern, 0);
      expect(moodle.bereich, hasLength(3));
    });

    test('falscher Name: Abbruch vor jeder Freigabe', () async {
      await expectLater(loeschen(name: 'a-cm1.mbz'), throwsA(isA<MoodleFehler>()));
      expect(moodle.dateimanager, 0);
      expect(moodle.bereich, hasLength(3));
    });

    test('unbekannte Nummer, Wiederherstellung und unfertige Sicherung werden abgewiesen', () async {
      await expectLater(loeschen(id: 'gibtsnicht'), throwsA(isA<MoodleFehler>()));
      final laufend = await vorgaenge.neu(kurs: 12, cmid: 6, datei: 'y.mbz');
      await vorgaenge.aktualisieren(laufend, stand: SicherungStand.laufend, kontext: 55, dateiname: 'ZZ-eigene.mbz');
      await expectLater(loeschen(id: laufend.id), throwsA(isA<MoodleFehler>()));
      expect(moodle.dateimanager, 0);
    });

    test('Datei steht nicht in Moodle: nichts gelöscht', () async {
      moodle.bereich = ['a-cm1.mbz'];
      await expectLater(loeschen(), throwsA(isA<MoodleFehler>()));
      expect(moodle.dateimanager, 0);
    });

    test('Bereich ändert sich während der Freigabe: Abbruch, nichts geschrieben', () async {
      beiFreigabe = () => moodle.bereich = [...moodle.bereich, 'neu-von-woanders.mbz'];
      await expectLater(loeschen(), throwsA(isA<MoodleFehler>()));
      expect(moodle.speichern, 0);
      expect(moodle.bereich, contains('neu-von-woanders.mbz'));
    });

    test('Datei kommt zwischen Entwurf und Speichern dazu: Abbruch vor dem Speichern, nichts verloren', () async {
      moodle.beimEntwurfLoeschen = () => moodle.bereich = [...moodle.bereich, 'neu-von-woanders.mbz'];
      await expectLater(loeschen(), throwsA(isA<MoodleFehler>()));
      expect(moodle.speichern, 0);
      expect(moodle.bereich, hasLength(4));
    });

    test('Entwurf mit Ordner: Abbruch, ohne am Entwurf etwas zu entfernen', () async {
      moodle.ordnerImEntwurf = true;
      await expectLater(loeschen(), throwsA(isA<MoodleFehler>()));
      expect(moodle.entwurfLoeschen, 0);
      expect(moodle.speichern, 0);
    });

    test('Moodle löscht mehr als gewollt: Rücklesen meldet verified: false und nennt die Datei', () async {
      moodle.loeschtZuViel = true;
      final r = await loeschen();
      expect(r, contains('verified: false'));
      expect(r, contains('Abweichung'));
      expect(r, contains('a-cm1.mbz'));
      expect(r, isNot(contains('verified: true')));
    });
  });
}
