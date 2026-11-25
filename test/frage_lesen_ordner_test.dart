// Wiederholtes und gleichzeitiges Fragenlesen über den
// Weg des Werkzeugs frage_lesen (frageLesen -> formularLesen). Die Moodle-Grenze
// ist ein lokales Test-Doppel auf 127.0.0.1; der Arbeitsordner ist ein
// Temp-Verzeichnis. Es geht um den Arbeitsordner frage-<id>, der beim Lesen
// neu angelegt wird.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/moodle/formular_lesen.dart';
import 'package:moocp/moodle/fragen.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

/// Ein Moodle-Doppel mit Anmeldung, Bearbeitungsformular einer Frage, einer
/// eingebetteten Bilddatei und dem Einzelexport als XML.
class _Doppel {
  late HttpServer _server;
  final Set<String> _angemeldet = {};
  int _zaehler = 0;

  /// Wie oft die Frage-Seite abgerufen wurde.
  int formulare = 0;

  /// Das Bild bricht mitten im Lesen ab (Verbindung zu), solange gesetzt.
  bool bildAbbrechen = false;

  /// Ein zweites Bild im Formular. Ein einzelnes Bild ohne Antwort ist nur ein
  /// Befund an der Datei; erst das zweite in Folge bricht das Lesen ab.
  bool zweitesBild = false;

  /// Hält die Antwort auf das Bild an, bis es sich erfüllt; [bildAngefragt]
  /// meldet, dass die Anfrage da ist.
  Completer<void>? bildHalten;
  Completer<void>? bildAngefragt;

  static const benutzer = 'e.mustermann';
  static const passwort = 'test-geheim-47';
  static const sesskey = 'sk1';
  static final bild = Uint8List.fromList(List<int>.generate(64, (i) => i));

  Uri get basis => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> starten() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_antworte);
  }

  Future<void> stoppen() => _server.close(force: true);

  String _seite(String body) =>
      '<html><body><script>M.cfg = {"sesskey":"$sesskey","courseId":12,"contextid":"55"};</script>$body</body></html>';

  Future<void> _antworte(HttpRequest r) async {
    final id = r.cookies.where((c) => c.name == 'MoodleSession').map((c) => c.value).firstOrNull;
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
      if (id != null && f['username'] == benutzer && f['password'] == passwort && f['logintoken'] == 'tok') {
        _angemeldet.add(id);
        return _umleiten(r, '/login/index.php?testsession=1');
      }
      return _umleiten(r, '/login/index.php');
    }
    if (!eingeloggt) return _umleiten(r, '/login/index.php');
    if (pfad == '/my/') return _text(r, _seite('<p>Startseite</p>'));
    if (pfad == '/mod/book/edit.php') {
      return _text(r, _seite('''<form class="mform" method="post">
<input type="hidden" name="sesskey" value="$sesskey">
<div id="fitem_id_title"><label for="id_title">Kapiteltitel</label><input type="text" name="title" id="id_title" value="ZZ Kapitel"></div>
<textarea name="content_editor[text]"><p>ZZ Kapiteltext</p></textarea>
</form>'''));
    }
    if (pfad == '/question/bank/editquestion/question.php') {
      formulare++;
      return _text(r, _seite('''<form class="mform" method="post">
<input type="hidden" name="sesskey" value="$sesskey">
<div id="fitem_id_name"><label for="id_name">Fragenname</label><input type="text" name="name" id="id_name" value="ZZ Frage"></div>
<input type="hidden" name="qtype" value="multichoice">
<textarea name="questiontext[text]"><p>ZZ Text</p><img src="${basis.resolve('/draftfile.php/55/user/draft/9/bild.png')}" alt="ZZ Bild">${zweitesBild ? '<img src="${basis.resolve('/draftfile.php/55/user/draft/9/bild2.png')}" alt="ZZ Bild 2">' : ''}</textarea>
</form>'''));
    }
    if (pfad == '/draftfile.php/55/user/draft/9/bild.png' ||
        pfad == '/draftfile.php/55/user/draft/9/bild2.png') {
      if (bildAbbrechen) {
        final socket = await r.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      if (bildHalten != null) {
        if (bildAngefragt?.isCompleted == false) bildAngefragt!.complete();
        await bildHalten!.future;
      }
      r.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('image', 'png')
        ..add(bild);
      return r.response.close();
    }
    if (pfad == '/question/bank/exporttoxml/exportone.php') {
      return _text(r, '<?xml version="1.0" encoding="UTF-8"?><quiz><question type="multichoice"/></quiz>');
    }
    return _text(r, 'nicht gefunden', status: HttpStatus.notFound);
  }

  Future<void> _umleiten(HttpRequest r, String ziel) async {
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

// Zum bekannten gelegentlichen Fehlschlag dieser Datei: Eine Ursache ist nicht
// nachgewiesen. Mit dem Lesen in einen Nachbarordner entfällt der Verdacht,
// ein Lesen lösche den Ordner unter einem anderen weg (ausgeschlossen: Sperre
// je Ordner, Austausch statt Löschen, die Tests unten belegen es). Übrig
// bleiben zwei lastabhängige Möglichkeiten, die sich hier nicht erzwingen
// ließen: die 30-Sekunden-Grenze eines Tests auf der ausgelasteten Box und
// „Directory not empty" beim Aufräumen im tearDown.
void main() {
  late _Doppel doppel;
  late Directory arbeitsordner;
  late MoodleZugang zugang;

  setUp(() async {
    doppel = _Doppel();
    await doppel.starten();
    arbeitsordner = Directory.systemTemp.createTempSync('ticket22-');
    zugang = await MoodleZugang.fuerTest(Protokoll(), doppel.basis,
        benutzer: _Doppel.benutzer, passwort: _Doppel.passwort);
  });

  tearDown(() async {
    await doppel.stoppen();
    // Unter Last meldet macOS beim Löschen gelegentlich „Directory not empty",
    // solange der Dateidienst noch etwas hält; ein zweiter Versuch genügt.
    for (var versuch = 0; arbeitsordner.existsSync(); versuch++) {
      try {
        arbeitsordner.deleteSync(recursive: true);
      } on FileSystemException {
        if (versuch >= 4) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  /// Der vollständige Stand einer gelesenen Frage: Quelltext, Bild, XML, Übersicht.
  void erwarteStand(String ordner) {
    expect(File(p.join(ordner, 'questiontext.html')).readAsStringSync(), contains('ZZ Text'));
    expect(File(p.join(ordner, 'dateien', 'bild.png')).readAsBytesSync(), _Doppel.bild);
    expect(File(p.join(ordner, 'frage.xml')).existsSync(), isTrue);
    expect(File(p.join(ordner, '.stand', 'ziel.json')).existsSync(), isTrue);
    expect(File(p.join(ordner, 'uebersicht.json')).existsSync(), isTrue);
    expect(File(p.join(ordner, '.stand', 'dateien', 'bild.png')).existsSync(), isTrue);
  }

  test('Wiederholtes Lesen derselben Frage ergibt jedes Mal den vollständigen Stand', () async {
    for (var i = 0; i < 3; i++) {
      final g = await frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: 34);
      expect(g, contains('frage.xml'));
      erwarteStand(p.join(arbeitsordner.path, 'frage-34'));
    }
  });

  test('Gleichzeitiges Lesen derselben Frage: alle Aufrufe liefern einen vollständigen Stand', () async {
    final ergebnisse = await Future.wait([
      for (var i = 0; i < 30; i++) frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: 34),
    ]);
    expect(ergebnisse, hasLength(30));
    erwarteStand(p.join(arbeitsordner.path, 'frage-34'));
  });

  test('Gleichzeitiges Lesen unterschiedlicher Fragen: jede Frage bekommt ihren Ordner', () async {
    await Future.wait([
      for (final f in [34, 35, 36, 37])
        frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: f),
    ]);
    for (final f in [34, 35, 36, 37]) {
      erwarteStand(p.join(arbeitsordner.path, 'frage-$f'));
    }
  });

  group('Austausch statt Löschen', () {
    String ordner() => p.join(arbeitsordner.path, 'frage-34');

    /// Reste im Arbeitsordner: Nachbarordner dürfen nach dem Lesen nicht bleiben.
    void keineReste() {
      final namen = arbeitsordner
          .listSync()
          .map((e) => p.basename(e.path))
          .toList();
      expect(namen.where((n) => n.startsWith('.lesen-')), isEmpty);
    }

    test('Ein Fehler mitten im Lesen erhält den vorherigen vollständigen Stand', () async {
      await frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: 34);
      doppel.bildAbbrechen = true;
      doppel.zweitesBild = true;
      await expectLater(
        frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: 34),
        throwsA(isA<MoodleFehler>()),
      );
      erwarteStand(ordner());
      keineReste();
      // Danach geht das Lesen wieder.
      doppel.bildAbbrechen = false;
      doppel.zweitesBild = false;
      await frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: 34);
      erwarteStand(ordner());
    });

    test('Ein Fehler beim ersten Lesen hinterlässt keinen Ergebnisordner', () async {
      doppel.bildAbbrechen = true;
      doppel.zweitesBild = true;
      await expectLater(
        frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: 34),
        throwsA(isA<MoodleFehler>()),
      );
      expect(Directory(ordner()).existsSync(), isFalse);
      keineReste();
    });

    test('Ein Abbruch mitten im Lesen erhält den vorherigen Stand, und der Ordner ist während des Lesens da', () async {
      await frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: 34);
      doppel.bildHalten = Completer<void>();
      doppel.bildAngefragt = Completer<void>();
      final abbruch = Completer<void>();
      final ziel = Formularziel.frage(12, 34);
      final lesen = formularLesen(zugang, ziel, arbeitsordner.path, abbruch: abbruch.future);
      final ergebnis = expectLater(lesen, throwsA(isA<MoodleFehler>()));
      await doppel.bildAngefragt!.future;
      // Mitten im Lesen: der alte Stand ist unberührt vollständig lesbar.
      erwarteStand(ordner());
      abbruch.complete();
      await ergebnis;
      doppel.bildHalten!.complete();
      erwarteStand(ordner());
      keineReste();
    });

    test('Ein folgendes Lesen derselben Frage wartet auf das abgebrochene und liest vollständig', () async {
      doppel.bildHalten = Completer<void>();
      doppel.bildAngefragt = Completer<void>();
      final abbruch = Completer<void>();
      final ziel = Formularziel.frage(12, 34);
      final erstes = formularLesen(zugang, ziel, arbeitsordner.path, abbruch: abbruch.future);
      final erstesErgebnis = expectLater(erstes, throwsA(isA<MoodleFehler>()));
      await doppel.bildAngefragt!.future;
      final zweites = frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: 34);
      doppel.bildHalten!.complete(); // gilt ab jetzt für alle Bildanfragen
      abbruch.complete();
      await erstesErgebnis;
      await zweites;
      erwarteStand(ordner());
      keineReste();
    });

    test('Ein Rest eines hart beendeten Lesens stört das nächste nicht', () async {
      final rest = Directory(p.join(arbeitsordner.path, '.lesen-frage-34'))..createSync();
      File(p.join(rest.path, 'halb.html')).writeAsStringSync('x');
      Directory('${rest.path}-alt').createSync();
      await frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: 34);
      erwarteStand(ordner());
      expect(File(p.join(ordner(), 'halb.html')).existsSync(), isFalse);
      keineReste();
    });

    test('Ein Buchkapitel lässt sich lesen, bevor es den Ordner seines Buchs gibt', () async {
      await formularLesen(zugang, Formularziel.buchkapitel(5, 7), arbeitsordner.path);
      final kapitel = p.join(arbeitsordner.path, 'buch-5', 'kapitel-7');
      expect(File(p.join(kapitel, 'content_editor.html')).existsSync(), isTrue);
      keineReste();
      // Ein zweites Lesen tauscht den Stand im Buchordner aus.
      await formularLesen(zugang, Formularziel.buchkapitel(5, 7), arbeitsordner.path);
      expect(File(p.join(kapitel, 'content_editor.html')).existsSync(), isTrue);
      expect(Directory(p.join(arbeitsordner.path, 'buch-5')).listSync().map((e) => p.basename(e.path)), ['kapitel-7']);
      keineReste();
    });

    test('Ein gescheitertes Lesen einer Frage lässt eine gleichzeitig gelesene andere vollständig', () async {
      await frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: 35);
      doppel.bildAbbrechen = true;
      doppel.zweitesBild = true;
      final ergebnisse = await Future.wait([
        frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: 34).then((_) => 'ok', onError: (_) => 'fehler'),
        frageLesen(zugang, arbeitsordner.path, sammlung: 12, frage: 35).then((_) => 'ok', onError: (_) => 'fehler'),
      ]);
      expect(ergebnisse, ['fehler', 'fehler']);
      erwarteStand(p.join(arbeitsordner.path, 'frage-35'));
      keineReste();
    });
  });
}
