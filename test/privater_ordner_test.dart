// Der private Ordner unter Linux (lib/plattform/privater_ordner.dart): Arbeitsordner
// und Ordner für Downloads der Plugins liegen unter einem Grundordner, den nur
// der Benutzer betreten kann. Fremde Besitzer und Rechte werden über die Naht
// [PrivatSystem] nachgestellt, die echten Rechte am echten Dateisystem geprüft.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/arbeitsordner.dart';
import 'package:moocp/plattform/privater_ordner.dart';
import 'package:moocp/plugin/downloads.dart';
import 'package:path/path.dart' as p;

/// Das echte Dateisystem, mit überschriebenem Besitzer oder Rechten für einzelne
/// Pfade, und eine Liste der Ordner, die angelegt wurden.
class _System implements PrivatSystem {
  final echt = UnixPrivatSystem();
  final besitzer = <String, int>{};
  final modi = <String, int>{};
  final angelegt = <String>[];

  @override
  int get uid => echt.uid;

  @override
  DateiAngabe? angabe(String pfad) {
    final a = echt.angabe(pfad);
    if (a == null || !a.ordner) return a;
    return DateiAngabe(ordner: true, verknuepfung: false, uid: besitzer[pfad] ?? a.uid, modus: modi[pfad] ?? a.modus);
  }

  @override
  void anlegen(String pfad) {
    angelegt.add(pfad);
    echt.anlegen(pfad);
  }
}

int _modus(String pfad) => FileStat.statSync(pfad).mode & 0xfff;

void main() {
  group('Ausgabe von stat', () {
    test('Linux: Sonderbits stehen vorn und machen den Ordner unprivat', () {
      expect(statAuswerten('1000:700\n', mac: false), (uid: 1000, modus: 448));
      expect(statAuswerten('1000:1700\n', mac: false)!.modus, isNot(privaterModus), reason: 'Sticky');
      expect(statAuswerten('1000:4700\n', mac: false)!.modus, isNot(privaterModus), reason: 'setuid');
      expect(statAuswerten('1000:2700\n', mac: false)!.modus, isNot(privaterModus), reason: 'setgid');
    });

    test('Mac: Dateityp wird abgeschnitten, Sonderbits bleiben', () {
      expect(statAuswerten('501:40700\n', mac: true), (uid: 501, modus: 448));
      expect(statAuswerten('501:41700\n', mac: true)!.modus, isNot(privaterModus), reason: 'Sticky');
      expect(statAuswerten('501:42700\n', mac: true)!.modus, isNot(privaterModus), reason: 'setgid');
      expect(statAuswerten('501:40755\n', mac: true)!.modus, isNot(privaterModus));
    });

    test('Unbrauchbares: null (die Prüfung scheitert)', () {
      for (final a in ['', 'x:y', '1000', '1000:89', 'stat: Fehler\n']) {
        expect(statAuswerten(a, mac: false), isNull, reason: a);
      }
    });
  });

  if (Platform.isWindows) return;

  late Directory tmp;
  late _System sys;
  late String grund;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zz_privat_');
    sys = _System();
    grund = p.join(tmp.path, 'moocp-${sys.uid}');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  (Arbeitsordner, int) ao({Map<String, String> umgebung = const {}}) =>
      Arbeitsordner.einrichten(temp: tmp.path, linux: true, umgebung: umgebung, system: sys);
  (PluginDownloads, int) dl({Map<String, String> umgebung = const {}}) =>
      PluginDownloads.einrichten(basis: tmp.path, linux: true, umgebung: umgebung, system: sys);

  group('Anlegen', () {
    test('ohne XDG_RUNTIME_DIR: Grundordner mit der Benutzernummer im Temp-Verzeichnis, alles 700', () {
      final (a, _) = ao();
      final (d, _) = dl();
      expect(p.dirname(a.pfad), grund);
      expect(p.dirname(d.wurzel), grund);
      for (final o in [grund, a.pfad, d.wurzel]) {
        expect(_modus(o), 448, reason: o);
      }
      expect(sys.angelegt, hasLength(3), reason: 'Grundordner, Arbeitsordner, Downloads: jeder mit mkdir 0700');
    });

    test('Arbeitsordner und Downloads sind getrennte Geschwister, nie ineinander', () {
      final (a, _) = ao();
      final (d, _) = dl();
      expect(p.isWithin(a.pfad, d.wurzel), isFalse);
      expect(p.isWithin(d.wurzel, a.pfad), isFalse);
    });

    test('mit einem brauchbaren XDG_RUNTIME_DIR liegt alles darunter in moocp', () {
      final x = Directory(p.join(tmp.path, 'lauf'))..createSync();
      Process.runSync('chmod', ['700', x.path]);
      final (a, _) = ao(umgebung: {'XDG_RUNTIME_DIR': x.path});
      final (d, _) = dl(umgebung: {'XDG_RUNTIME_DIR': x.path});
      expect(p.dirname(a.pfad), p.join(x.resolveSymbolicLinksSync(), 'moocp'));
      expect(p.dirname(d.wurzel), p.join(x.resolveSymbolicLinksSync(), 'moocp'));
      expect(Directory(grund).existsSync(), isFalse);
    });

    test('der Ort ist über Neustarts stabil und der Inhalt wird beim Start geleert', () {
      final (a, _) = ao();
      File(p.join(a.pfad, 'cm-1', 'page.html')).createSync(recursive: true);
      final (b, geblieben) = ao();
      expect(b.pfad, a.pfad);
      expect(geblieben, 0);
      expect(Directory(b.pfad).listSync(), isEmpty);
    });

    test('ein vorhandener, privater Ordner wird benutzt, ohne ihn neu anzulegen', () {
      ao();
      sys.angelegt.clear();
      ao();
      expect(sys.angelegt, isEmpty);
    });
  });

  group('XDG_RUNTIME_DIR, das nicht taugt, wird übergangen', () {
    for (final (name, umgebung) in <(String, Map<String, String> Function(String))>[
      ('nicht gesetzt', (_) => {}),
      ('relativ', (_) => {'XDG_RUNTIME_DIR': 'lauf'}),
      ('leer', (_) => {'XDG_RUNTIME_DIR': ''}),
      ('nicht vorhanden', (t) => {'XDG_RUNTIME_DIR': p.join(t, 'gibt-es-nicht')}),
    ]) {
      test(name, () {
        final (a, _) = ao(umgebung: umgebung(tmp.path));
        expect(p.dirname(a.pfad), grund);
      });
    }

    test('fremder Besitzer', () {
      final x = Directory(p.join(tmp.path, 'lauf'))..createSync();
      Process.runSync('chmod', ['700', x.path]);
      sys.besitzer[x.path] = sys.uid + 1;
      final (a, _) = ao(umgebung: {'XDG_RUNTIME_DIR': x.path});
      expect(p.dirname(a.pfad), grund);
    });

    test('zu weite Rechte', () {
      final x = Directory(p.join(tmp.path, 'lauf'))..createSync();
      Process.runSync('chmod', ['755', x.path]);
      final (a, _) = ao(umgebung: {'XDG_RUNTIME_DIR': x.path});
      expect(p.dirname(a.pfad), grund);
    });

    test('eine Verknüpfung', () {
      final echt = Directory(p.join(tmp.path, 'echt'))..createSync();
      Process.runSync('chmod', ['700', echt.path]);
      final x = p.join(tmp.path, 'lauf');
      Link(x).createSync(echt.path);
      final (a, _) = ao(umgebung: {'XDG_RUNTIME_DIR': x});
      expect(p.dirname(a.pfad), grund);
      expect(Directory(p.join(echt.path, 'moocp')).existsSync(), isFalse);
    });
  });

  group('Ablehnen: Fehler, bevor etwas geschrieben oder gelöscht wird', () {
    /// Ein Ordner mit Inhalt, dessen Prüfung scheitern soll; nach dem Versuch
    /// ist der Inhalt unverändert und es wurde nichts angelegt.
    void abgelehnt(String pfad, void Function() versuch) {
      final datei = File(p.join(pfad, 'fremd.txt'))..writeAsStringSync('bleibt');
      final vorher = sys.angelegt.length;
      expect(versuch, throwsA(isA<PrivaterOrdnerFehler>()));
      expect(datei.readAsStringSync(), 'bleibt');
      expect(sys.angelegt.length, vorher);
    }

    test('Grundordner ist eine Verknüpfung', () {
      final fremd = Directory(p.join(tmp.path, 'fremd'))..createSync();
      Link(grund).createSync(fremd.path);
      abgelehnt(fremd.path, ao);
      abgelehnt(fremd.path, dl);
      expect(fremd.listSync().whereType<Directory>(), isEmpty);
    });

    test('Grundordner gehört einem anderen Benutzer', () {
      Directory(grund).createSync();
      Process.runSync('chmod', ['700', grund]);
      sys.besitzer[grund] = sys.uid + 1;
      abgelehnt(grund, ao);
      abgelehnt(grund, dl);
      expect(_modus(grund), 448, reason: 'nicht angepasst');
    });

    test('Grundordner für die Gruppe oder alle offen (kein chmod, kein Übernehmen)', () {
      for (final m in ['770', '750', '707', '755', '777', '1700']) {
        if (Directory(grund).existsSync()) Directory(grund).deleteSync(recursive: true);
        Directory(grund).createSync();
        Process.runSync('chmod', [m, grund]);
        final vorher = _modus(grund);
        abgelehnt(grund, ao);
        abgelehnt(grund, dl);
        expect(_modus(grund), vorher, reason: 'Rechte $m bleiben, wie sie sind');
      }
    });

    test('Arbeitsordner ist eine Verknüpfung, gehört fremd oder ist offen', () {
      final (a, _) = ao();
      final fremd = Directory(p.join(tmp.path, 'fremd'))..createSync();
      Directory(a.pfad).deleteSync();
      Link(a.pfad).createSync(fremd.path);
      abgelehnt(fremd.path, ao);
      Link(a.pfad).deleteSync();
      Directory(a.pfad).createSync();
      Process.runSync('chmod', ['770', a.pfad]);
      abgelehnt(a.pfad, ao);
      Process.runSync('chmod', ['700', a.pfad]);
      sys.besitzer[a.pfad] = sys.uid + 7;
      abgelehnt(a.pfad, ao);
    });

    test('Ordner für Downloads: Verknüpfung, fremder Besitzer, offene Rechte', () {
      final (d, _) = dl();
      final fremd = Directory(p.join(tmp.path, 'fremd'))..createSync();
      Directory(d.wurzel).deleteSync();
      Link(d.wurzel).createSync(fremd.path);
      abgelehnt(fremd.path, dl);
      Link(d.wurzel).deleteSync();
      Directory(d.wurzel).createSync();
      sys.besitzer[d.wurzel] = sys.uid + 1;
      Process.runSync('chmod', ['700', d.wurzel]);
      abgelehnt(d.wurzel, dl);
      sys.besitzer.clear();
      Process.runSync('chmod', ['707', d.wurzel]);
      abgelehnt(d.wurzel, dl);
    });

    test('die Meldung ist deutsch, klar und nennt den Pfad der Downloads nicht', () {
      Directory(grund).createSync();
      Process.runSync('chmod', ['755', grund]);
      try {
        dl();
        fail('hätte werfen müssen');
      } on PrivaterOrdnerFehler catch (e) {
        expect(e.meldung, contains('nicht privat'));
        expect(e.meldung, contains('Administrator'), reason: 'ein fremd angelegter Ordner lässt sich nicht selbst entfernen');
        expect(e.meldung, isNot(contains(PluginDownloads.ordnername)));
      }
      Directory(grund).deleteSync(recursive: true);
      Process.runSync('chmod', ['700', tmp.path]);
      final (_, _) = dl();
      final (d, _) = dl();
      sys.besitzer[d.wurzel] = sys.uid + 1;
      try {
        dl();
        fail('hätte werfen müssen');
      } on PrivaterOrdnerFehler catch (e) {
        expect(e.meldung, isNot(contains(d.wurzel)));
        expect(e.meldung, isNot(contains(PluginDownloads.ordnername)));
      }
    });
  });

  group('Leeren bleibt im geprüften Ordner', () {
    test('Arbeitsordner: nach dem Austausch durch einen fremden Ordner wird nichts gelöscht', () {
      final (a, _) = ao();
      final datei = File(p.join(a.pfad, 'x.txt'))..writeAsStringSync('x');
      sys.besitzer[a.pfad] = sys.uid + 1;
      expect(a.leeren, throwsA(isA<PrivaterOrdnerFehler>()));
      expect(datei.existsSync(), isTrue);
    });

    test('Downloads: nach dem Austausch durch einen fremden Ordner wird nichts gelöscht, auch nichts angelegt', () {
      final (d, _) = dl();
      final datei = File(p.join(d.wurzel, 'a', 'B', '1.csv'))..createSync(recursive: true);
      sys.modi[d.wurzel] = 493; // 0755
      expect(d.leeren, throwsA(isA<PrivaterOrdnerFehler>()));
      expect(() => d.neueDatei('a', 'C', Uri.parse('https://m.example/x.csv')), throwsA(isA<PrivaterOrdnerFehler>()));
      expect(datei.existsSync(), isTrue);
      expect(Directory(p.join(d.wurzel, 'a', 'C')).existsSync(), isFalse);
    });

    test('Verknüpfungen werden beim Leeren nicht verfolgt', () {
      final (a, _) = ao();
      final draussen = Directory(p.join(tmp.path, 'draussen'))..createSync();
      final wichtig = File(p.join(draussen.path, 'wichtig.txt'))..writeAsStringSync('bleibt');
      Link(p.join(a.pfad, 'oben')).createSync(draussen.path);
      expect(a.leeren(), 0);
      expect(wichtig.existsSync(), isTrue);
    });

    test('der ältere Ort unter /tmp bleibt unberührt', () {
      final alt = Directory(p.join(tmp.path, 'moocp_arbeitsordner_e.mustermann'))..createSync();
      final neu = Directory(p.join(tmp.path, 'moocp_plugin_downloads'))..createSync();
      final a = File(p.join(alt.path, 'alt.txt'))..writeAsStringSync('alt');
      final b = File(p.join(neu.path, 'alt.txt'))..writeAsStringSync('alt');
      ao(umgebung: {'USER': 'e.mustermann'});
      dl();
      expect(a.existsSync(), isTrue);
      expect(b.existsSync(), isTrue);
    });
  });

  group('Downloads', () {
    test('Pfadformen für die Datenschutzprüfung nennen den neuen Pfad', () {
      final (d, _) = dl();
      expect(d.pfadformen, contains(d.wurzel));
      expect(d.pfadformen.every((f) => p.isWithin(grund, f) || p.isWithin(Directory(grund).resolveSymbolicLinksSync(), f)), isTrue);
    });

    test('je Plugin und Profil ein Ordner darunter, Lebensdauer wie bisher: beim Einrichten leer', () {
      final (d, _) = dl();
      final f = d.neueDatei('beispiel', 'A', Uri.parse('https://m.example/x.pdf'));
      expect(p.isWithin(d.wurzel, f.path), isTrue);
      f.writeAsStringSync('x');
      expect(d.leeren(), 0);
      expect(Directory(d.wurzel).listSync(), isEmpty);
    });
  });
}
