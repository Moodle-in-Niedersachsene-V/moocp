// Die Rechte der Einstellungsdatei (0600, Ordner 0700, E6): Gelingt das Setzen
// nicht, steht es im Protokoll, statt still zu bleiben.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/plattform/datei_rechte.dart';
import 'package:path/path.dart' as p;

/// Ein Dateisystem, das keine Rechte ändern lässt (etwa eine fremde Einbindung).
class _KeinChmod implements DateiRechte {
  final versucht = <String>[];

  @override
  DateiEintrag? eintrag(String pfad) => null;

  @override
  void chmod(String pfad, int modus) {
    versucht.add(pfad);
    throw const FileSystemException('Operation not permitted');
  }
}

void main() {
  late Directory wurzel;
  setUp(() => wurzel = Directory.systemTemp.createTempSync('moocp_rechte_'));
  tearDown(() {
    Einstellungen.rechteMelder = null;
    wurzel.deleteSync(recursive: true);
  });

  test('dateiPrivat: ein Satz mit Pfad und Art des Fehlers, wenn chmod scheitert, sonst null', () {
    final datei = File(p.join(wurzel.path, 'e.json'))..writeAsStringSync('{}');
    final r = _KeinChmod();
    final satz = dateiPrivat(datei.path, rechte: r);
    expect(satz, allOf(contains(datei.path), contains('FileSystemException'), contains('andere Konten')));
    expect(r.versucht, [datei.path]);
    expect(dateiPrivat(datei.path), isNull);
    expect(FileStat.statSync(datei.path).mode & 0x1ff, 0x180);
  }, skip: Platform.isWindows);

  test('dateiRechteSetzen: Datei und Ordner melden je ihren Fehler, an den Melder', () {
    final datei = File(p.join(wurzel.path, 'e.json'))..writeAsStringSync('{}');
    final gemeldet = <String>[];
    Einstellungen.rechteMelder = gemeldet.add;
    final r = Einstellungen.dateiRechteSetzen(datei, rechte: _KeinChmod());
    expect(r, hasLength(2));
    expect(gemeldet, r);
    expect(gemeldet[1], contains('Ordner'));
  }, skip: Platform.isWindows);

  test('was vor dem Protokoll gemeldet wird, geht an den Melder, sobald er da ist', () {
    final datei = File(p.join(wurzel.path, 'e.json'))..writeAsStringSync('{}');
    Einstellungen.dateiRechteSetzen(datei, rechte: _KeinChmod());
    final gemeldet = <String>[];
    Einstellungen.rechteMelder = gemeldet.add;
    expect(gemeldet, hasLength(2));
    Einstellungen.rechteMelder = gemeldet.add;
    expect(gemeldet, hasLength(2), reason: 'nur einmal');
  }, skip: Platform.isWindows);

  test('gelingt es, bleibt alles still', () {
    final datei = File(p.join(wurzel.path, 'e.json'))..writeAsStringSync('{}');
    final gemeldet = <String>[];
    Einstellungen.rechteMelder = gemeldet.add;
    expect(Einstellungen.dateiRechteSetzen(datei), isEmpty);
    expect(gemeldet, isEmpty);
  }, skip: Platform.isWindows);
}
