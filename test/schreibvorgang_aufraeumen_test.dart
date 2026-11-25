// E37: Abgeschlossene Schreibvorgänge liegen nicht länger als nötig; offene
// bleiben immer, weil sie sperren.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/moodle/formular_lesen.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/moodle/schreibvorgang.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory ordner;
  late MoodleZugang moodle;
  late HttpServer server;

  setUp(() async {
    ordner = Directory.systemTemp.createTempSync('schreibvorgang-aufraeumen-');
    // Nur die Anmeldung: Die Vorgänge brauchen von Moodle nichts außer der Adresse.
    final angemeldet = <String>{};
    var zaehler = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final id = r.cookies.where((c) => c.name == 'MoodleSession').map((c) => c.value).firstOrNull;
      Future<void> umleiten(String ziel) async {
        r.response.redirect(Uri.parse(ziel), status: HttpStatus.seeOther);
        await r.response.close();
      }
      if (r.method == 'POST') {
        await utf8.decoder.bind(r).join();
        angemeldet.add(id ?? '');
        return umleiten('/login/index.php?testsession=1');
      }
      if (r.uri.queryParameters.containsKey('testsession')) {
        return umleiten(angemeldet.contains(id) ? '/my/' : '/login/index.php');
      }
      r.response
        ..cookies.add(Cookie('MoodleSession', 's${zaehler++}'))
        ..headers.contentType = ContentType.html
        ..write('<form><input name="logintoken" value="tok"></form>');
      await r.response.close();
    });
    moodle = await MoodleZugang.fuerTest(
      Protokoll(),
      Uri.parse('http://127.0.0.1:${server.port}'),
      benutzer: 'e.mustermann',
      passwort: 'x',
      schreibvorgaengeOrdner: ordner.path,
    );
  });

  tearDown(() async {
    await server.close(force: true);
    ordner.deleteSync(recursive: true);
  });

  Schreibvorgang neu(int cmid) {
    final v = Schreibvorgang(moodle, Formularziel.aktivitaet(cmid));
    v.beginnen({'text:a.html': 'a' * 64}, {'text:a.html': 'b' * 64});
    return v;
  }

  int dateien() => ordner.listSync().whereType<File>().where((f) => !f.path.endsWith('.tmp')).length;

  test('eine Instanz zu löschen entfernt abgeschlossene Vorgänge samt Sperre, nie offene', () {
    neu(1).abschliessen();
    neu(2).verwerfen();
    neu(3).rueckgelesen();
    final offen = neu(4);
    expect(dateien(), 8);

    Schreibvorgang.abgeschlosseneLoeschen(moodle, dieserInstanz: true);

    expect(dateien(), 2);
    expect(offen.offen, isTrue);
  });

  test('Alter: nur was länger zurückliegt, als aufbewahrt wird', () {
    neu(1).abschliessen();
    Schreibvorgang.abgeschlosseneLoeschen(moodle, aelterAls: const Duration(days: 1));
    expect(dateien(), 2);
    Schreibvorgang.abgeschlosseneLoeschen(moodle, aelterAls: Duration.zero);
    expect(dateien(), 0);
  });

  test('ohne Angabe wird nichts gelöscht', () {
    neu(1).abschliessen();
    Schreibvorgang.abgeschlosseneLoeschen(moodle);
    expect(dateien(), 2);
    expect(p.basename(ordner.path), isNotEmpty);
  });
}
