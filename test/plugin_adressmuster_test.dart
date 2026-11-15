// Adressmuster der Zusatzadressen eines Plugins (E36) und die Bereiche, die für
// jedes Plugin gesperrt bleiben. Ein Muster, das einen gesperrten Bereich
// treffen KANN, hält das Plugin vom Laden ab; geprüft wird hier, dass keine
// Schreibweise daran vorbeikommt und dass harmlose Muster nicht abgewiesen
// werden.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/plugin/adressmuster.dart';

String? _fehler(String text) {
  try {
    Adressmuster.parsen(text);
    return null;
  } on FormatException catch (e) {
    return e.message;
  }
}

Sperrbereich? _beruehrt(String text) => sperrbereichBeruehrt(Adressmuster.parsen(text));

void main() {
  group('Gültigkeit eines Musters', () {
    test('ein Pfad mit „/" am Anfang und „*" als einzigem Platzhalter ist gültig', () {
      for (final text in [
        '/mod/beispiel/view.php',
        '/pluginfile.php/*',
        '/mod/beispiel/*',
        '/a/b*c',
        '/mod/*/view.php',
        '/dateien/mit%20leerzeichen.pdf',
      ]) {
        expect(_fehler(text), isNull, reason: text);
      }
    });

    test('ungültig sind: leer, ohne „/" am Anfang, Schema oder Rechner, „?", „#", „..", Steuerzeichen', () {
      final ungueltig = <String, String>{
        'leer': '',
        'ohne Schrägstrich am Anfang': 'mod/beispiel/view.php',
        'Schema': 'https://moodle.schule.example/mod/x',
        'Rechner ohne Schema': '//moodle.schule.example/mod/x',
        'Rechner ohne Schrägstrich': 'moodle.schule.example/mod/x',
        'Parameter': '/mod/x/view.php?id=1',
        'Anker': '/mod/x/view.php#abschnitt',
        'Elternordner': '/mod/../x',
        'Elternordner am Ende': '/mod/..',
        'Elternordner prozentkodiert': '/mod/%2e%2e/x',
        'Elternordner doppelt prozentkodiert': '/mod/%252e%252e/x',
        'Nullzeichen': '/mod/x\u0000',
        'Zeilenumbruch': '/mod/x\n/y',
        'Tabulator': '/mod/\tx',
        'Steuerzeichen prozentkodiert': '/mod/x%0a',
        'Löschzeichen': '/mod/x\u007f',
      };
      ungueltig.forEach((was, text) {
        final grund = _fehler(text);
        expect(grund, isNotNull, reason: was);
        expect(grund, isNotEmpty, reason: was);
      });
    });

    test('die Meldung nennt den Grund, nicht den Inhalt des Musters', () {
      expect(_fehler('/mod/x?geheim=1'), isNot(contains('geheim')));
      expect(_fehler('/mod/x?geheim=1'), contains('Parameter'));
    });
  });

  group('Wann ein Muster auf einen Pfad passt', () {
    bool passt(String muster, String pfad) => Adressmuster.parsen(muster).passt(pfad);

    test('ohne Platzhalter nur genau dieser Pfad', () {
      expect(passt('/mod/beispiel/view.php', '/mod/beispiel/view.php'), isTrue);
      expect(passt('/mod/beispiel/view.php', '/mod/beispiel/view.php2'), isFalse);
      expect(passt('/mod/beispiel/view.php', '/x/mod/beispiel/view.php'), isFalse);
      expect(passt('/mod/beispiel/view.php', '/mod/beispiel'), isFalse);
    });

    test('„*" steht für beliebige Zeichen, auch für „/" und für nichts', () {
      expect(passt('/pluginfile.php/*', '/pluginfile.php/12/mod_x/content/0/a/b.png'), isTrue);
      expect(passt('/pluginfile.php/*', '/pluginfile.php/'), isTrue);
      expect(passt('/pluginfile.php/*', '/pluginfile.php'), isFalse);
      expect(passt('/a*c', '/ac'), isTrue);
      expect(passt('/a*c', '/abbc'), isTrue);
      expect(passt('/a*c', '/ab'), isFalse);
      expect(passt('/mod/*/view.php', '/mod/x/y/view.php'), isTrue);
      expect(passt('/mod/*/view.php', '/mod/view.php'), isFalse);
      expect(passt('/*/*/x', '/a/b/x'), isTrue);
    });

    test('keine regulären Ausdrücke: alles außer „*" ist ein gewöhnliches Zeichen', () {
      expect(passt('/mod/a.b', '/mod/axb'), isFalse);
      expect(passt('/mod/a.b', '/mod/a.b'), isTrue);
      expect(passt('/mod/a+b', '/mod/aab'), isFalse);
      expect(passt('/mod/(a|b)', '/mod/a'), isFalse);
      expect(passt('/mod/[ab]', '/mod/a'), isFalse);
      expect(passt('/mod/[ab]', '/mod/[ab]'), isTrue);
    });

    test('Groß- und Kleinschreibung zählt, wie sie in der Adresse steht', () {
      expect(passt('/mod/Beispiel', '/mod/beispiel'), isFalse);
    });

    test('lange Muster mit vielen Platzhaltern bleiben schnell (kein Rückwärtsabgleich ins Unendliche)', () {
      final muster = '/${List.filled(40, 'a*').join()}b';
      final pfad = '/${'a' * 400}';
      final uhr = Stopwatch()..start();
      expect(Adressmuster.parsen(muster).passt(pfad), isFalse);
      expect(uhr.elapsedMilliseconds, lessThan(2000));
    });
  });

  group('Gesperrte Bereiche eines Musters', () {
    test('Muster, die einen gesperrten Bereich treffen können, werden erkannt', () {
      final gesperrt = <String, String>{
        '/admin/index.php': '/admin/',
        '/admin/*': '/admin/',
        '/admin': '/admin/',
        '/*': '/admin/',
        '/a*': '/admin/',
        '/ad*': '/admin/',
        '/*/x.php': '/admin/',
        '/*.php': '/admin/',
        '/login*': '/login/',
        '/login': '/login/',
        '/login/index.php': '/login/',
        '/log*': '/login/',
        '/auth/*': '/auth/',
        '/auth/oauth2/*': '/auth/',
        '/webservice/rest/server.php': '/webservice/',
        '/web*': '/webservice/',
        '/user/managetoken.php': '/user/managetoken.php',
        '/user/managetoken.php*': '/user/managetoken.php',
        '/user/*': '/user/managetoken.php',
        '/user/m*': '/user/managetoken.php',
        '/u*': '/user/managetoken.php',
      };
      gesperrt.forEach((muster, pfad) {
        expect(_beruehrt(muster)?.pfad, pfad, reason: muster);
      });
    });

    test('Groß- und Kleinschreibung spielt keine Rolle', () {
      expect(_beruehrt('/ADMIN/x'), isNotNull);
      expect(_beruehrt('/Login/index.php'), isNotNull);
      expect(_beruehrt('/User/ManageToken.php'), isNotNull);
      expect(_beruehrt('/A*'), isNotNull);
    });

    test('Prozentkodierung, Schrägstrich-Schreibweisen und Punktsegmente helfen nicht', () {
      for (final muster in [
        '/%61dmin/x', // „a" kodiert
        '/ad%6din/x', // „m" kodiert
        '/%2561dmin/x', // doppelt kodiert
        r'/\admin\x',
        r'/admin\x',
        '/./admin/x',
      ]) {
        expect(_beruehrt(muster), isNotNull, reason: muster);
      }
      expect(_beruehrt('/mod/./x'), isNull, reason: 'ein Punktsegment allein macht ein Muster nicht verdächtig');
    });

    test('doppelte Schrägstriche vor dem Bereich helfen nicht', () {
      // „//admin/x" ist als Muster wegen des Rechnernamens ungültig; in der
      // Mitte eines Musters faltet die Normalisierung sie weg.
      expect(_beruehrt('/*//admin/x'), isNotNull);
      expect(_beruehrt('/./admin/x'), isNotNull);
    });

    test('harmlose Muster bleiben erlaubt', () {
      for (final muster in [
        '/mod/beispiel/view.php',
        '/pluginfile.php/*',
        '/mod/*',
        '/mod/beispiel/*',
        '/course/view.php',
        '/user/profile.php',
        '/user/pix.php/*',
        '/administration/x.php',
        '/loginhilfe/x.php',
        '/authentik/x',
        '/webserviceplus/x',
        '/m*',
        '/p*',
        '/course/*/admin/x',
        '/mod/a*',
      ]) {
        expect(_beruehrt(muster), isNull, reason: muster);
      }
    });

    test('jedes Muster, das einen gesperrten Pfad trifft, wird erkannt', () {
      // Aus gesperrten Adressen werden zufällig Muster abgeleitet, indem ein
      // Stück durch „*" ersetzt wird; jedes davon passt auf die Adresse und
      // muss deshalb als gesperrt gelten.
      final adressen = [
        '/admin/index.php',
        '/admin/settings.php',
        '/admin',
        '/login/index.php',
        '/login/logout.php',
        '/auth/oauth2/login.php',
        '/webservice/rest/server.php',
        '/user/managetoken.php',
        '/user/managetoken.php/x',
      ];
      final zufall = Random(42);
      var geprueft = 0;
      for (final adresse in adressen) {
        for (var i = 0; i < 300; i++) {
          final von = 1 + zufall.nextInt(adresse.length);
          final bis = von + zufall.nextInt(adresse.length - von + 1);
          final muster = '${adresse.substring(0, von)}*${adresse.substring(bis)}'.replaceAll(RegExp(r'\*+'), '*');
          if (_fehler(muster) != null) continue;
          expect(Adressmuster.parsen(muster).passt(adresse), isTrue, reason: '$muster passt auf $adresse');
          expect(_beruehrt(muster), isNotNull, reason: '$muster trifft $adresse');
          geprueft++;
        }
      }
      expect(geprueft, greaterThan(1000));
    });
  });

  group('Gesperrte Bereiche einer Adresse', () {
    test('Adressen in gesperrten Bereichen, in jeder Schreibweise', () {
      for (final pfad in [
        '/admin/index.php',
        '/ADMIN/x',
        '/admin',
        '/admin/',
        '/login/index.php',
        '/login',
        '/auth/oauth2/login.php',
        '/webservice/rest/server.php',
        '/user/managetoken.php',
        '/user/managetoken.php/x',
        '/%61dmin/x',
        '/admin%2fx',
        '/mod/../admin/x',
        '/./admin/x',
        '//admin/x',
        r'\admin\x',
      ]) {
        expect(sperrbereichDerAdresse(pfad), isNotNull, reason: pfad);
      }
    });

    test('alles andere ist frei', () {
      for (final pfad in [
        '/mod/page/view.php',
        '/administration/x',
        '/pluginfile.php/1/mod_page/content/0/a.png',
        '/user/profile.php',
        '/course/admin/x',
        '/',
      ]) {
        expect(sperrbereichDerAdresse(pfad), isNull, reason: pfad);
      }
    });

    test('jeder Bereich hat einen Namen für die Meldung', () {
      expect(sperrbereichDerAdresse('/admin/x')!.name, 'Adminbereich');
      expect(sperrbereichDerAdresse('/login/x')!.name, 'Anmeldung');
      expect(sperrbereiche.every((b) => b.name.isNotEmpty && b.pfad.startsWith('/')), isTrue);
    });
  });

  group('Pfade vor dem Vergleich normalisieren', () {
    test('Kodierung, Schrägstriche und Punktsegmente werden aufgelöst', () {
      expect(pfadNormalisieren('/mod//page/./view.php'), '/mod/page/view.php');
      expect(pfadNormalisieren('/mod/x/../page'), '/mod/page');
      expect(pfadNormalisieren('/mod/a%20b'), '/mod/a b');
      expect(pfadNormalisieren('/mod/%2561'), '/mod/a');
      expect(pfadNormalisieren(r'\mod\x'), '/mod/x');
      expect(pfadNormalisieren('/../../x'), '/x', reason: 'über die Wurzel hinaus bleibt es an der Wurzel');
      expect(pfadNormalisieren('/mod/x/'), '/mod/x/', reason: 'ein Schrägstrich am Ende bleibt');
    });
  });
}
