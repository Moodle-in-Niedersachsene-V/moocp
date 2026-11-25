// Der Ordner, in dem der Kanal zwischen Brücke und App liegt, gehört dem
// angemeldeten Konto und sonst niemandem (lib/plattform/privater_ordner.dart):
// Besitzer, Rechte, keine Verknüpfung -- mit nachgebautem Dateisystem für die
// Fälle, die sich ohne zweites Konto nicht herstellen lassen, und gegen das
// echte für den Rest.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/plattform/privater_ordner.dart';
import 'package:path/path.dart' as p;

class _Attrappe implements PosixDatei {
  _Attrappe({this.uid = 1000});
  @override
  final int uid;
  final eintraege = <String, PosixEintrag>{};
  final angelegt = <String>[];
  final geaendert = <String, int>{};

  @override
  PosixEintrag? lstat(String pfad) => eintraege[pfad];

  @override
  void ordnerAnlegen(String pfad) {
    angelegt.add(pfad);
    eintraege[pfad] = PosixEintrag(uid: uid, modus: 0x1ed, art: FileSystemEntityType.directory);
  }

  @override
  void chmod(String pfad, int modus) {
    geaendert[pfad] = modus;
    final e = eintraege[pfad]!;
    eintraege[pfad] = PosixEintrag(uid: e.uid, modus: modus, art: e.art);
  }
}

PosixEintrag _ordner({int uid = 1000, int modus = 0x1c0}) =>
    PosixEintrag(uid: uid, modus: modus, art: FileSystemEntityType.directory);

void main() {
  group('privatPruefen (nachgebautes Dateisystem)', () {
    test('eigener Ordner mit 0700 ist in Ordnung', () {
      final z = _Attrappe()..eintraege['/k'] = _ordner();
      expect(privatPruefen('/k', posix: z), isNull);
    });

    test('Ordner eines anderen Kontos wird abgelehnt, auch mit 0700', () {
      final z = _Attrappe()..eintraege['/k'] = _ordner(uid: 1001);
      expect(privatPruefen('/k', posix: z), isNotNull);
    });

    test('Rechte für Gruppe oder andere werden abgelehnt', () {
      for (final modus in [0x1ed /*0755*/, 0x1f8 /*0770*/, 0x1c1 /*0701*/, 0x1ff]) {
        final z = _Attrappe()..eintraege['/k'] = _ordner(modus: modus);
        expect(privatPruefen('/k', posix: z), isNotNull, reason: modus.toRadixString(8));
      }
    });

    test('eine Verknüpfung wird abgelehnt, auch auf einen eigenen 0700-Ordner', () {
      final z = _Attrappe()
        ..eintraege['/k'] = PosixEintrag(uid: 1000, modus: 0x1c0, art: FileSystemEntityType.link);
      expect(privatPruefen('/k', posix: z), isNotNull);
    });

    test('eine Datei statt eines Ordners wird abgelehnt', () {
      final z = _Attrappe()..eintraege['/k'] = PosixEintrag(uid: 1000, modus: 0x1c0, art: FileSystemEntityType.file);
      expect(privatPruefen('/k', posix: z), isNotNull);
    });

    test('ein fehlender Ordner wird gemeldet, nicht angelegt', () {
      final z = _Attrappe();
      expect(privatPruefen('/k', posix: z), isNotNull);
      expect(z.angelegt, isEmpty);
    });

    test('die Meldung nennt den Pfad nicht (E11)', () {
      final z = _Attrappe()..eintraege['/geheim/k'] = _ordner(uid: 7);
      expect(privatPruefen('/geheim/k', posix: z), isNot(contains('geheim')));
    });
  });

  group('privatHerstellen (nachgebautes Dateisystem)', () {
    test('legt einen fehlenden Ordner mit 0700 an', () {
      final z = _Attrappe();
      expect(privatHerstellen('/k', posix: z), isNull);
      expect(z.angelegt, ['/k']);
      expect(z.eintraege['/k']!.modus & 0x1ff, 0x1c0);
    });

    test('zieht einen eigenen Ordner mit zu weiten Rechten auf 0700 zusammen', () {
      final z = _Attrappe()..eintraege['/k'] = _ordner(modus: 0x1ed);
      expect(privatHerstellen('/k', posix: z), isNull);
      expect(z.geaendert['/k'], 0x1c0);
    });

    test('fasst einen fremden Ordner nicht an', () {
      final z = _Attrappe()..eintraege['/k'] = _ordner(uid: 1001, modus: 0x1ed);
      expect(privatHerstellen('/k', posix: z), isNotNull);
      expect(z.geaendert, isEmpty);
    });

    test('fasst eine Verknüpfung nicht an', () {
      final z = _Attrappe()
        ..eintraege['/k'] = PosixEintrag(uid: 1000, modus: 0x1ed, art: FileSystemEntityType.link);
      expect(privatHerstellen('/k', posix: z), isNotNull);
      expect(z.geaendert, isEmpty);
    });
  }, skip: Platform.isWindows ? 'POSIX' : null);

  group('mit dem echten Dateisystem', () {
    late Directory wurzel;
    setUp(() => wurzel = Directory.systemTemp.createTempSync('moocp_privat_'));
    tearDown(() => wurzel.deleteSync(recursive: true));

    test('herstellen legt einen Ordner an, den privatPruefen annimmt', () {
      final k = p.join(wurzel.path, 'kanal');
      expect(privatHerstellen(k), isNull);
      expect(privatPruefen(k), isNull);
      expect(FileStat.statSync(k).mode & 0x1ff, 0x1c0);
    });

    test('ein Ordner mit 0777 wird abgelehnt, herstellen zieht ihn zusammen', () {
      final k = Directory(p.join(wurzel.path, 'weit'))..createSync();
      Process.runSync('chmod', ['777', k.path]);
      expect(privatPruefen(k.path), isNotNull);
      expect(privatHerstellen(k.path), isNull);
      expect(privatPruefen(k.path), isNull);
    });

    test('eine Verknüpfung auf einen eigenen privaten Ordner wird abgelehnt', () {
      final echt = p.join(wurzel.path, 'echt');
      expect(privatHerstellen(echt), isNull);
      final link = p.join(wurzel.path, 'link');
      Link(link).createSync(echt);
      expect(privatPruefen(link), isNotNull);
      expect(privatHerstellen(link), isNotNull);
    });

    test('dateiPrivat setzt 0600', () {
      final f = File(p.join(wurzel.path, 'e.json'))..writeAsStringSync('{}');
      Process.runSync('chmod', ['644', f.path]);
      dateiPrivat(f.path);
      expect(FileStat.statSync(f.path).mode & 0x1ff, 0x180);
    });
  }, skip: Platform.isWindows ? 'POSIX' : null);
}
