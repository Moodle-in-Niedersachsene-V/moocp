import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/moodle/lernsituation_pruefung.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory wurzel;
  late String entwurf;
  final vorlagen = {
    for (final e in schucuVorlagenDateien.entries)
      e.key: File(p.join(schucuVorlagenOrdner, e.value)).readAsStringSync(),
  };

  setUp(() {
    wurzel = Directory.systemTemp.createTempSync('ls-regression-');
    entwurf = p.join(wurzel.path, 'entwurf');
    void kopieren(Directory quelle, String ziel) {
      Directory(ziel).createSync(recursive: true);
      for (final e in quelle.listSync()) {
        final name = p.join(ziel, p.basename(e.path));
        if (e is Directory) kopieren(e, name);
        if (e is File) e.copySync(name);
      }
    }
    kopieren(Directory('skills/lernsituation/references/beispiel'), entwurf);
  });
  tearDown(() => wurzel.deleteSync(recursive: true));

  test('Unicode vor parent bleibt ein Bezeichner statt Moodle-Zugriff', () {
    final seite = File(p.join(entwurf, 'ab-01-auftrag/page.html'));
    seite.writeAsStringSync('${seite.readAsStringSync()}\n'
        '<iframe sandbox="allow-scripts" src="@@PLUGINFILE@@/zz-element.html" title="Z" height="100"></iframe>');
    File(p.join(entwurf, 'ab-01-auftrag/dateien/zz-element.html')).writeAsStringSync(
        '<!DOCTYPE html><html lang="de"><head><title>Z</title></head>'
        '<body><script>éparent.x</script></body></html>');
    final e = entwurfPruefen(entwurf, arbeitsordner: wurzel.path, vorlagen: vorlagen, anzeige: 'Entwurf');
    expect(e.ausgabe, isNot(contains('Zugriff auf die Moodle-Seite')), reason: e.ausgabe);
    expect(e.code, 0, reason: e.ausgabe);
  });
  test('Erster Dateibefund behält das body-Attribut', () {
    final seite = File(p.join(entwurf, 'ab-01-auftrag/page.html'));
    seite.writeAsStringSync('${seite.readAsStringSync()}\n<a href="@@PLUGINFILE@@/zz-datei.html">Datei öffnen</a>');
    File(p.join(entwurf, 'ab-01-auftrag/dateien/zz-datei.html')).writeAsStringSync(
        '<html><body onload="los()"><table><tr><td><script>los()</script></td></tr>'
        '<div onclick="los()">Z</div></table></body></html>');
    final e = entwurfPruefen(entwurf, arbeitsordner: wurzel.path, vorlagen: vorlagen, anzeige: 'Entwurf');
    expect(e.code, 1);
    expect(e.ausgabe, contains('Datei zz-datei.html enthält Code (onload an <body>)'));
  });
  test('Erster Dateibefund folgt der Quelle statt dem reparierten HTML-Baum', () {
    final seite = File(p.join(entwurf, 'ab-01-auftrag/page.html'));
    seite.writeAsStringSync('${seite.readAsStringSync()}\n<a href="@@PLUGINFILE@@/zz-datei.html">Datei öffnen</a>');
    File(p.join(entwurf, 'ab-01-auftrag/dateien/zz-datei.html')).writeAsStringSync(
        '<table><tr><td><script>los()</script></td></tr>'
        '<div onclick="los()">Z</div></table>');
    final e = entwurfPruefen(entwurf, arbeitsordner: wurzel.path, vorlagen: vorlagen, anzeige: 'Entwurf');
    expect(e.code, 1);
    expect(e.ausgabe, contains('Datei zz-datei.html enthält Code (<script>)'));
  });
}
