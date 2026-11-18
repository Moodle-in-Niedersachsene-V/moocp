// Die Update-Prüfung ohne Netz: Tag lesen, Versionen vergleichen, die
// Datei im Release finden, und die Grenzen, innerhalb derer überhaupt
// geprüft wird.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/update/update.dart';

void main() {
  group('Tag eines Releases', () {
    test('das Schema der Tags (v<Version>)', () {
      expect(versionAusTag('v0.9.4'), '0.9.4');
      expect(versionAusTag('0.9.4'), '0.9.4');
      expect(versionAusTag(' v1.2.3 '), '1.2.3');
      expect(versionAusTag('v1.0'), '1.0');
    });

    test('die alte Form der ersten Versionen wird geduldet', () {
      expect(versionAusTag('github-v0.9.2'), '0.9.2');
    });

    test('was nicht passt, wird nicht geraten', () {
      expect(versionAusTag('Release 2'), isNull);
      expect(versionAusTag('v0.9.4-beta'), isNull);
      expect(versionAusTag(''), isNull);
    });
  });

  group('Versionen vergleichen', () {
    test('kleiner, gleich, größer', () {
      expect(versionVergleich('0.9.4', '0.9.5'), -1);
      expect(versionVergleich('0.9.5', '0.9.4'), 1);
      expect(versionVergleich('0.9.4', '0.9.4'), 0);
    });

    test('zählt Zahlen, nicht Zeichen', () {
      expect(versionVergleich('0.10.0', '0.9.9'), 1);
      expect(versionVergleich('1.0.0', '0.99.99'), 1);
    });

    test('fehlende Stellen sind 0, die Buildnummer zählt nicht', () {
      expect(versionVergleich('1.0', '1.0.0'), 0);
      expect(versionVergleich('1.0.1', '1.0'), 1);
      expect(versionVergleich('0.9.4+7', '0.9.4+1'), 0);
    });
  });

  group('Datei im Release', () {
    Map<String, dynamic> anhang(String name) => {'name': name, 'browser_download_url': 'https://x/$name'};

    test('die zur Version passende Datei', () {
      final gefunden = releaseDatei([
        anhang('quelltext.zip'),
        anhang('moocp_setup_0.9.4.exe'),
        anhang('moocp_setup_0.9.5.exe'),
      ], '0.9.5');
      expect(gefunden?['name'], 'moocp_setup_0.9.5.exe');
      expect(installerName('0.9.5'), 'moocp_setup_0.9.5.exe');
    });

    test('heißt sie anders, wird die erste Setup-Datei genommen', () {
      final gefunden = releaseDatei([anhang('moocp_setup0.9.5+1.exe')], '0.9.5');
      expect(gefunden?['name'], 'moocp_setup0.9.5+1.exe');
    });

    test('ohne Installer kein Treffer', () {
      expect(releaseDatei([anhang('quelltext.zip'), anhang('moocp.txt')], '0.9.5'), isNull);
      expect(releaseDatei([], '0.9.5'), isNull);
    });
  });

  group('Datei im Release nach einem anderen Namensmuster', () {
    Map<String, dynamic> anhang(String name) => {'name': name, 'browser_download_url': 'https://x/$name'};

    test('der Name setzt sich aus Anfang, Version und .exe zusammen', () {
      expect(installerName('1.2.0', anfang: 'zusatz_setup'), 'zusatz_setup_1.2.0.exe');
      expect(installerName('1.2.0'), 'moocp_setup_1.2.0.exe');
    });

    test('die zur Version passende Datei, nicht die von moocp', () {
      final gefunden = releaseDatei([
        anhang('moocp_setup_1.2.0.exe'),
        anhang('zusatz_setup_1.1.0.exe'),
        anhang('zusatz_setup_1.2.0.exe'),
      ], '1.2.0', anfang: 'zusatz_setup');
      expect(gefunden?['name'], 'zusatz_setup_1.2.0.exe');
    });

    test('heißt sie anders, wird die erste Datei mit diesem Anfang genommen', () {
      final gefunden = releaseDatei(
          [anhang('moocp_setup_1.2.0.exe'), anhang('zusatz_setup1.2.0+1.exe')], '1.2.0',
          anfang: 'zusatz_setup');
      expect(gefunden?['name'], 'zusatz_setup1.2.0+1.exe');
    });

    test('ohne Datei mit diesem Anfang kein Treffer', () {
      expect(releaseDatei([anhang('moocp_setup_1.2.0.exe')], '1.2.0', anfang: 'zusatz_setup'), isNull);
    });
  });

  group('Wann überhaupt geprüft wird', () {
    test('unter macOS nie: es gibt keinen Installer zum Selbstersetzen', () {
      expect(updateMoeglich([], {'LOCALAPPDATA': '/x', 'HOME': '/Users/x'}), isFalse);
    }, skip: Platform.isMacOS ? null : 'nur unter macOS');

    test('der Schalter schaltet ab', () {
      expect(updateMoeglich([keinUpdateSchalter], {'LOCALAPPDATA': r'C:\x'}), isFalse);
    });

    test('nur aus dem Installationsverzeichnis', () {
      // Hier läuft der Test, nicht die installierte App: Ein Update ersetzte
      // diese Datei nicht, also wird nicht geprüft.
      expect(updateMoeglich([], {'LOCALAPPDATA': r'C:\irgendwo\anders'}), isFalse);
      expect(updateMoeglich([], {}), isFalse);
    });
  });

  group('Mac und Linux: welches Paket, und nur installiert', () {
    UpdatePaket? paket(String system, String programm,
            {Map<String, String> umgebung = const {'HOME': '/Users/e'},
            List<String> argumente = const [],
            Set<String> dateien = const {}}) =>
        updatePaket(argumente, umgebung,
            system: system, programm: programm, gibtEs: dateien.contains);

    test('Mac: nur aus einem der Programme-Ordner', () {
      expect(paket('macos', '/Applications/moocp.app/Contents/MacOS/moocp'), UpdatePaket.dmg);
      expect(paket('macos', '/Users/e/Applications/moocp.app/Contents/MacOS/moocp'), UpdatePaket.dmg);
      // Entwicklungsbau, direkt aus dem Disk-Image, von macOS verlegt:
      expect(paket('macos', '/Users/e/moocp/build/macos/Build/Products/Release/moocp.app/Contents/MacOS/moocp'),
          isNull);
      expect(paket('macos', '/Volumes/moocp/moocp.app/Contents/MacOS/moocp'), isNull);
      expect(paket('macos', '/private/var/folders/x/AppTranslocation/y/d/moocp.app/Contents/MacOS/moocp'), isNull);
    });

    test('Linux: AppImage, .deb, Installer je Benutzer; sonst nicht', () {
      expect(paket('linux', '/tmp/.mount_x/usr/bin/moocp', umgebung: {'APPIMAGE': '/home/e/moocp.AppImage'}),
          UpdatePaket.appImage);
      expect(paket('linux', '/opt/moocp/moocp'), UpdatePaket.deb);
      expect(paket('linux', '/home/e/.local/opt/moocp/moocp', dateien: {'/home/e/.local/opt/moocp/.moocp-installiert'}),
          UpdatePaket.run);
      expect(paket('linux', '/home/e/moocp/build/linux/x64/release/bundle/moocp'), isNull);
    });

    test('der Schalter schaltet auch hier ab, und Windows hat kein Paket', () {
      expect(paket('macos', '/Applications/moocp.app/Contents/MacOS/moocp', argumente: [keinUpdateSchalter]), isNull);
      expect(paket('linux', '/opt/moocp/moocp', argumente: [keinUpdateSchalter]), isNull);
      expect(paket('windows', r'C:\Users\e\AppData\Local\Programs\moocp\moocp.exe'), isNull);
    });

    test('die Namen der Pakete wie die Skripte sie bauen', () {
      expect(UpdatePaket.dmg.dateiname('1.2.3'), 'moocp_1.2.3_macos.dmg');
      expect(UpdatePaket.run.dateiname('1.2.3'), 'moocp_setup_1.2.3.run');
      expect(UpdatePaket.appImage.dateiname('1.2.3'), 'moocp_1.2.3-x86_64.AppImage');
      expect(UpdatePaket.deb.dateiname('1.2.3'), 'moocp_1.2.3_amd64.deb');
    });
  });

  group('Einmal am Tag', () {
    test('Datum als Text', () {
      expect(tagesdatum(DateTime(2026, 10, 3)), '2026-10-03');
      expect(tagesdatum(DateTime(2026, 1, 1)), '2026-01-01');
    });

    test('heute schon geprüft', () {
      final e = Einstellungen(schluessel: 'x');
      final jetzt = DateTime(2026, 10, 3, 18);
      expect(heuteSchonGeprueft(e, jetzt), isFalse);
      e.updateZuletzt = '2026-10-03';
      expect(heuteSchonGeprueft(e, jetzt), isTrue);
      expect(heuteSchonGeprueft(e, DateTime(2026, 10, 4)), isFalse);
    });
  });

  group('Die Prüfung bleibt von Moodle getrennt', () {
    // A2/A1: Die Update-Prüfung hat ihre eigene Verbindung. Käme sie je an
    // MoodleZugang, ginge das Sitzungscookie an GitHub -- deshalb hält der
    // Test die Datei darauf fest, so wie sperrliste_test.dart die Listen
    // gegeneinander hält.
    test('update.dart kennt weder MoodleZugang noch Cookies', () {
      // Ohne die Kommentare: Die erklären gerade, dass es beides nicht gibt.
      final code = File('lib/update/update.dart')
          .readAsLinesSync()
          .where((z) => !z.trimLeft().startsWith('//'))
          .join('\n')
          .toLowerCase();
      expect(code.contains('moodle'), isFalse, reason: 'kein Bezug auf Moodle');
      expect(code.contains('cookie'), isFalse, reason: 'keine Cookies an GitHub');
    });
  });

  group('Keine Adresse an der Positivliste vorbei', () {
    String ohneKommentare(String pfad) =>
        File(pfad).readAsLinesSync().where((z) => !z.trimLeft().startsWith('//')).join('\n');

    test('update.dart fragt an genau einer Stelle an, und dort erst nach der Positivliste', () {
      final code = ohneKommentare('lib/update/update.dart');
      expect(RegExp(r'\.getUrl\(').allMatches(code).length, 1, reason: 'nur _holen fragt an');
      expect(RegExp(r'\.(openUrl|postUrl|putUrl|get|post|open)\(').hasMatch(code), isFalse);
      final holen = code.indexOf('Future<HttpClientResponse> _holen(');
      final pruefung = code.indexOf('updateGesperrt(uri', holen);
      final anfrage = code.indexOf('.getUrl(', holen);
      expect(holen, greaterThan(0));
      expect(pruefung, greaterThan(holen));
      expect(anfrage, greaterThan(pruefung), reason: 'erst die Liste, dann die Anfrage; ebenso für jedes Umleitungsziel');
      expect(code.contains('followRedirects = false'), isTrue, reason: 'Umleitungen nur von Hand, jede geprüft');
    });

    test('die Prüfung der Plugins hat keine eigene Verbindung, sondern nimmt die von update.dart', () {
      final code = ohneKommentare('lib/plugin/plugin_update.dart');
      for (final verboten in ['HttpClient', 'getUrl', 'Uri.parse', 'Uri.https', 'package:http', 'HttpOverrides']) {
        expect(code.contains(verboten), isFalse, reason: verboten);
      }
      expect(code.toLowerCase().contains('cookie'), isFalse);
      expect(code.contains('moodle_zugang'), isFalse);
      // Veränderlich sind nur die Repositorys (quellen) aus der
      // Beschreibungsdatei; Rechner und Form der Adressen stehen in
      // updateliste.dart.
      expect(code.contains('quellen: b.updateQuellen'), isTrue);
    });
  });
}
