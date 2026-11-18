// Die Sperre des Arbeitsordners (ordnerSperre) hält `aendern` nicht während
// der Freigabe, die bis zu 30 Minuten auf die Lehrkraft wartet. Unter der
// Sperre wird vor dem Schreiben geprüft, dass der Ordner derselbe ist und
// Moodle noch den gelesenen Stand zeigt (E17). Moodle ist ein lokales
// Test-Doppel auf 127.0.0.1, der Arbeitsordner ein Temp-Verzeichnis.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/formular_lesen.dart';
import 'package:moocp/moodle/formular_schreiben.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

class _Doppel {
  late HttpServer _server;
  final Set<String> _angemeldet = {};
  int _zaehler = 0;
  /// Anfragen, die Moodle als Speichern erhalten hat; bleibt leer, weil
  /// geprüft wird, dass vorher abgebrochen wird.
  final List<String> speichern = [];

  /// Der Text der Seite in Moodle; ein Test ändert ihn „von Hand".
  String text = '<p>ZZ Text</p>';
  bool antwortAbbrechen = false;
  bool speichernAnwenden = false;
  bool ruecklesenAbbrechen = false;

  static const benutzer = 'e.mustermann';
  static const passwort = 'test-geheim-23';
  static const sesskey = 'sk23';

  String get _seite =>
      '''<form class="mform" method="post" action="/course/modedit.php">
<input type="hidden" name="sesskey" value="$sesskey">
<input type="hidden" name="modulename" value="page">
<input type="hidden" name="_qf__mod_page_mod_form" value="1">
<input type="hidden" name="course" value="12">
<input type="hidden" name="update" value="101">
<div id="fitem_id_name" class="mb-3 row fitem"><div class="col-md-9 felement" data-fieldtype="text"><input type="text" name="name" id="id_name" value="ZZ Seite"></div></div>
<div id="fitem_id_intro" class="mb-3 row fitem"><div class="col-md-9 felement" data-fieldtype="editor"><textarea name="page[text]">$text</textarea><input type="hidden" name="page[itemid]" value="777"></div></div>
</form>''';

  Uri get basis => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> starten() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_antworte);
  }

  Future<void> stoppen() => _server.close(force: true);

  String _html(String body) =>
      '<html><body><script>M.cfg = {"sesskey":"$sesskey","courseId":12,"contextid":"55"};</script>$body</body></html>';

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
      return _text(r, '<form><input name="logintoken" value="tok"></form>');
    }
    if (pfad == '/login/index.php' && r.method == 'POST') {
      final f = Uri.splitQueryString(await utf8.decoder.bind(r).join());
      if (id != null &&
          f['username'] == benutzer &&
          f['password'] == passwort &&
          f['logintoken'] == 'tok') {
        _angemeldet.add(id);
        return _umleiten(r, '/login/index.php?testsession=1');
      }
      return _umleiten(r, '/login/index.php');
    }
    if (!eingeloggt) return _umleiten(r, '/login/index.php');
    if (pfad == '/course/modedit.php' && r.method == 'POST') {
      speichern.add(r.uri.query);
      final f = Uri.splitQueryString(await utf8.decoder.bind(r).join());
      if (speichernAnwenden) text = f['page[text]']!;
      if (antwortAbbrechen) {
        final socket = await r.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      return _umleiten(r, '/course/view.php?id=12');
    }
    if (pfad == '/course/modedit.php' &&
        r.uri.queryParameters['update'] == '101') {
      if (ruecklesenAbbrechen && speichern.isNotEmpty) {
        final socket = await r.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      return _text(r, _html(_seite));
    }
    return _text(r, 'nicht gefunden', status: HttpStatus.notFound);
  }

  Future<void> _umleiten(HttpRequest r, String ziel) async {
    r.response.redirect(Uri.parse(ziel), status: HttpStatus.seeOther);
    await r.response.close();
  }

  Future<void> _text(HttpRequest r, String body,
      {int status = HttpStatus.ok}) async {
    r.response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..write(body);
    await r.response.close();
  }
}

void main() {
  late _Doppel doppel;
  late Directory arbeitsordner;
  late MoodleZugang zugang;
  late Freigaben freigaben;

  setUp(() async {
    doppel = _Doppel();
    await doppel.starten();
    arbeitsordner = Directory.systemTemp.createTempSync('aendern-sperre-');
    freigaben = Freigaben(Protokoll());
    zugang = await MoodleZugang.fuerTest(
      Protokoll(),
      doppel.basis,
      benutzer: _Doppel.benutzer,
      passwort: _Doppel.passwort,
      schreibvorgaengeOrdner: p.join(arbeitsordner.path, 'vorgaenge'),
    );
  });

  tearDown(() async {
    await doppel.stoppen();
    if (arbeitsordner.existsSync()) arbeitsordner.deleteSync(recursive: true);
  });

  Future<String> geaendertStarten() async {
    await formularLesen(zugang, Formularziel.aktivitaet(101), arbeitsordner.path);
    final datei = File(p.join(arbeitsordner.path, 'cm-101', 'page.html'));
    datei.writeAsStringSync('${datei.readAsStringSync()}<p>ZZ Zusatz</p>');
    return 'cm-101';
  }

  Future<void> aufFreigabe() async {
    for (var i = 0; i < 200 && freigaben.aktuell == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(freigaben.aktuell, isNotNull, reason: 'Die Freigabe wurde nicht gefragt');
  }

  test('Verbindungsabbruch nach POST meldet unklar und sperrt Wiederholung', () async {
    final ordner = await geaendertStarten();
    doppel.antwortAbbrechen = true;
    final ergebnis = aendern(zugang, freigaben,
        ordner: ordner, arbeitsordner: arbeitsordner.path);
    await aufFreigabe();
    freigaben.entscheiden(true);
    final bericht = await ergebnis;
    expect(bericht, contains('Ausgang unklar'));
    final nummer = RegExp(r'Vorgang ([a-f0-9]{64})').firstMatch(bericht)!.group(1)!;
    final status = await aendernStatus(zugang, vorgang: nummer, arbeitsordner: arbeitsordner.path);
    expect(status, contains('Ausgangsstand unverändert'));
    expect(status, contains('verified: false'));
    doppel.text = '<p>ZZ Fremde Änderung</p>';
    final abweichend = await aendernStatus(zugang, vorgang: nummer, arbeitsordner: arbeitsordner.path);
    expect(abweichend, contains('Stand weicht vom Ausgangs- und Zielstand ab'));
    expect(abweichend, contains('verified: false'));
    // Auch ein erneutes Lesen ersetzt weder den Vorgang noch den Nachweis.
    await formularLesen(zugang, Formularziel.aktivitaet(101), arbeitsordner.path);
    final wiederholt = await aendern(zugang, freigaben,
        ordner: ordner, arbeitsordner: arbeitsordner.path);
    expect(wiederholt, contains('aendern_status'));
    expect(doppel.speichern, hasLength(1));
  });

  for (final ruecklesefehler in [false, true]) {
    test('Gespeicherte Änderung nach ${ruecklesefehler ? "Rückleseabbruch" : "POST-Abbruch"} wird lesend bestätigt', () async {
      final ordner = await geaendertStarten();
      doppel.speichernAnwenden = true;
      doppel.antwortAbbrechen = !ruecklesefehler;
      doppel.ruecklesenAbbrechen = ruecklesefehler;
      final ergebnis = aendern(zugang, freigaben,
          ordner: ordner, arbeitsordner: arbeitsordner.path);
      await aufFreigabe();
      freigaben.entscheiden(true);
      final bericht = await ergebnis;
      expect(bericht, contains('Ausgang unklar'));
      final nummer = RegExp(r'Vorgang ([a-f0-9]{64})').firstMatch(bericht)!.group(1)!;
      doppel.ruecklesenAbbrechen = false;
      // Ein neuer Zugang verwendet dieselbe dauerhafte Ablage.
      final neuerZugang = await MoodleZugang.fuerTest(Protokoll(), doppel.basis,
          benutzer: _Doppel.benutzer, passwort: _Doppel.passwort,
          schreibvorgaengeOrdner: zugang.schreibvorgaengeOrdner);
      final status = await aendernStatus(neuerZugang, vorgang: nummer, arbeitsordner: arbeitsordner.path);
      expect(status, contains('Zielstand bestätigt (verified: true)'));
      expect(doppel.speichern, hasLength(1));
      expect(File(p.join(arbeitsordner.path, ordner, 'page.html')).readAsStringSync(), contains('ZZ Zusatz'));
    });
  }

  test('Identischer Ausgangs- und Zielstand belegt nach Abbruch kein Prozessende', () async {
    await formularLesen(zugang, Formularziel.aktivitaet(101), arbeitsordner.path);
    doppel.antwortAbbrechen = true;
    doppel.speichernAnwenden = true;
    final ergebnis = aendern(zugang, freigaben,
        ordner: 'cm-101', arbeitsordner: arbeitsordner.path, neuSpeichern: true);
    await aufFreigabe();
    freigaben.entscheiden(true);
    final bericht = await ergebnis;
    final nummer = RegExp(r'Vorgang ([a-f0-9]{64})').firstMatch(bericht)!.group(1)!;
    final status = await aendernStatus(zugang, vorgang: nummer, arbeitsordner: arbeitsordner.path);
    expect(status, contains('verified: false'));
    expect(status, contains('Ausgangsstand unverändert'));
    expect(doppel.speichern, hasLength(1));
  });

  test('Offene Freigabe hält ein Lesen desselben Ordners nicht auf; die freigegebene Änderung ist dann weg und wird nicht geschrieben', () async {
    final ordner = await geaendertStarten();
    final ergebnis = aendern(zugang, freigaben,
        ordner: ordner, arbeitsordner: arbeitsordner.path);
    await aufFreigabe();

    // Ohne Sperre während der Freigabe kommt das Lesen sofort durch.
    await formularLesen(zugang, Formularziel.aktivitaet(101), arbeitsordner.path)
        .timeout(const Duration(seconds: 10));

    freigaben.entscheiden(true);
    final text = await ergebnis;
    expect(text, contains('Nicht gespeichert'));
    expect(text, contains('neu gelesen'));
    expect(doppel.speichern, isEmpty);
  });

  test('Ändert sich Moodle zwischen Freigabe und Schreiben, bricht aendern unter der Sperre ab', () async {
    final ordner = await geaendertStarten();
    final ergebnis = aendern(zugang, freigaben,
        ordner: ordner, arbeitsordner: arbeitsordner.path);
    await aufFreigabe();

    doppel.text = '<p>ZZ Von Hand geändert</p>';
    freigaben.entscheiden(true);

    await expectLater(
      ergebnis,
      throwsA(isA<MoodleFehler>().having(
          (e) => e.meldung, 'Meldung', contains('seit dem Lesen geändert'))),
    );
    expect(doppel.speichern, isEmpty);
  });
}
