// Die Positivliste der Update-Prüfung: Was nicht ausdrücklich erlaubt ist,
// fragt die App nicht an -- auch kein Umleitungsziel.

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/update/updateliste.dart';

void main() {
  String? sperre(String adresse, {bool download = false}) =>
      updateGesperrt(Uri.parse(adresse), download: download);

  group('Abfrage der Version', () {
    test('genau die Abfrage je Herkunft ist erlaubt, der Verein zuerst', () {
      expect(herkuenfte, ['Moodle-in-Niedersachsene-V/moocp', 'topse/moocp']);
      expect(
          sperre('https://api.github.com/repos/Moodle-in-Niedersachsene-V/moocp/releases/latest'),
          isNull);
      expect(sperre('https://api.github.com/repos/topse/moocp/releases/latest'), isNull);
    });

    test('die Umleitung eines umgezogenen Repositorys nicht', () {
      expect(sperre('https://api.github.com/repositories/401025/releases/latest'), isNotNull);
    });

    test('alles andere bei GitHub nicht', () {
      // Ein anderes Repository, eine Liste aller Releases, die Suche nach
      // Nutzern: Für die Update-Prüfung braucht es nichts davon.
      expect(sperre('https://api.github.com/repos/fremd/moocp/releases/latest'), isNotNull);
      expect(sperre('https://api.github.com/repos/topse/moocp/releases'), isNotNull);
      expect(sperre('https://api.github.com/repos/topse/moocp/releases/latest?x=1'), isNotNull);
      expect(sperre('https://api.github.com/users/topse'), isNotNull);
    });

    test('kein http, kein fremder Rechner', () {
      expect(sperre('http://api.github.com/repos/topse/moocp/releases/latest'), 'kein https');
      expect(sperre('https://beispiel.test/repos/topse/moocp/releases/latest'), isNotNull);
    });
  });

  group('Download des Installers', () {
    test('das Release jeder Herkunft', () {
      expect(
          sperre('https://github.com/topse/moocp/releases/download/v0.9.5/moocp_setup_0.9.5.exe',
              download: true),
          isNull);
      expect(
          sperre(
              'https://github.com/Moodle-in-Niedersachsene-V/moocp/releases/download/v0.9.5/moocp_setup_0.9.5.exe',
              download: true),
          isNull);
    });

    test('ein fremdes Repository nicht', () {
      expect(
          sperre('https://github.com/fremd/moocp/releases/download/v1.0/setup.exe', download: true),
          isNotNull);
      // Auch nicht irgendeine andere Seite auf github.com.
      expect(sperre('https://github.com/topse/moocp/archive/main.zip', download: true), isNotNull);
    });

    test('die Speicherdienste, auf die GitHub umleitet', () {
      expect(sperre('https://objects.githubusercontent.com/x?token=abc', download: true), isNull);
      expect(sperre('https://release-assets.githubusercontent.com/x', download: true), isNull);
    });

    test('ein Rechner, der nur so heißt, nicht', () {
      expect(sperre('https://githubusercontent.com.beispiel.test/x', download: true), isNotNull);
      expect(sperre('https://boese-githubusercontent.com/x', download: true), isNotNull);
    });

    test('kein http und keine Anmeldedaten in der Adresse', () {
      expect(
          sperre('http://github.com/topse/moocp/releases/download/v1/moocp_setup_1.exe', download: true),
          'kein https');
      expect(
          sperre('https://wer:was@github.com/topse/moocp/releases/download/v1/moocp_setup_1.exe',
              download: true),
          'Adresse mit Anmeldedaten');
    });

    test('die Abfrageadresse ist kein Download und umgekehrt', () {
      expect(updateGesperrt(releaseAbfrage(herkuenfte.first), download: true), isNotNull);
      expect(
          sperre('https://github.com/topse/moocp/releases/download/v1/moocp_setup_1.exe',
              download: false),
          isNotNull);
    });
  });

  group('Eine andere Liste von Herkünften', () {
    const quellen = ['beispiel-org/zusatz', 'beispiel-org/zusatz.alt'];

    String? sperreFuer(String adresse, {bool download = false}) =>
        updateGesperrt(Uri.parse(adresse), download: download, quellen: quellen);

    test('erlaubt genau die Abfrage und den Download ihrer Repositorys', () {
      expect(sperreFuer('https://api.github.com/repos/beispiel-org/zusatz/releases/latest'), isNull);
      expect(sperreFuer('https://api.github.com/repos/beispiel-org/zusatz.alt/releases/latest'), isNull);
      expect(
          sperreFuer('https://github.com/beispiel-org/zusatz/releases/download/v1.0/zusatz_setup_1.0.exe',
              download: true),
          isNull);
      // Die Speicherdienste, auf die GitHub dabei umleitet, bleiben dieselben.
      expect(sperreFuer('https://objects.githubusercontent.com/x?token=abc', download: true), isNull);
    });

    test('lässt die Repositorys von moocp dann nicht mehr zu', () {
      expect(sperreFuer('https://api.github.com/repos/topse/moocp/releases/latest'), isNotNull);
      expect(
          sperreFuer('https://github.com/topse/moocp/releases/download/v1/moocp_setup_1.exe',
              download: true),
          isNotNull);
    });

    test('die erlaubten Rechner und die Form der Adresse bleiben', () {
      expect(sperreFuer('http://api.github.com/repos/beispiel-org/zusatz/releases/latest'), 'kein https');
      expect(sperreFuer('https://beispiel.test/repos/beispiel-org/zusatz/releases/latest'), isNotNull);
      expect(sperreFuer('https://api.github.com/repos/beispiel-org/zusatz/releases'), isNotNull);
      expect(sperreFuer('https://github.com/beispiel-org/zusatz/archive/main.zip', download: true), isNotNull);
      expect(sperreFuer('https://githubusercontent.com.beispiel.test/x', download: true), isNotNull);
    });
  });

  group('Was als Herkunft gilt', () {
    test('schlicht „Besitzer/Name“', () {
      for (final herkunft in [
        'topse/moocp',
        'Moodle-in-Niedersachsene-V/moocp',
        'a/b',
        'beispiel-org/zusatz_1.2-x',
        'beispiel-org/.github',
      ]) {
        expect(herkunftGueltig(herkunft), isTrue, reason: herkunft);
      }
    });

    test('alles andere nicht', () {
      for (final herkunft in [
        '',
        'topse',
        'topse/',
        '/moocp',
        'a/b/c',
        'topse/moocp/',
        'topse/..',
        'topse/.',
        '../moocp',
        'a/b/../../c',
        'x/y/../../../users/z',
        'topse/moocp?x=1',
        'topse/moocp#anker',
        'topse/moocp\n',
        'topse/moo cp',
        'topse\\moocp',
        'topse/moocp%2f..',
        'wer@host/moocp',
        'https://beispiel.test/x',
        '-topse/moocp',
        'topse-/moocp',
        'tøpse/moocp',
        'topse/møocp',
      ]) {
        expect(herkunftGueltig(herkunft), isFalse, reason: herkunft);
      }
    });

    test('aus einem anderen Namen entsteht keine Abfrageadresse', () {
      // Uri.parse faltet „..“ weg: Aus der Herkunft unten würde ohne die Regel
      // genau die Adresse https://api.github.com/users/z/releases/latest.
      expect(() => releaseAbfrage('x/y/../../../users/z'), throwsArgumentError);
      expect(() => releaseAbfrage('topse/moocp?x=1'), throwsArgumentError);
      expect(releaseAbfrage('topse/moocp').toString(),
          'https://api.github.com/repos/topse/moocp/releases/latest');
    });

    test('ein Name, der keine Herkunft ist, öffnet auch in der Liste keine Adresse', () {
      // Die Regel prüft jeden Namen der Liste selbst; sonst bestimmte ein
      // Name, der aus dem Muster ausbricht, auch die Adresse, die dann gilt.
      const hinterlistig = ['x/y/../../../users/z'];
      expect(
          updateGesperrt(Uri.parse('https://api.github.com/users/z/releases/latest'),
              download: false, quellen: hinterlistig),
          isNotNull);
      expect(
          updateGesperrt(Uri.parse('https://api.github.com/repos/x/y/releases/latest'),
              download: false, quellen: hinterlistig),
          isNotNull);
      // Ein leerer Name ergäbe „//releases/download/“ auf github.com.
      expect(
          updateGesperrt(Uri.parse('https://github.com//releases/download/v1/setup.exe'),
              download: true, quellen: const ['']),
          isNotNull);
      // Ein einzelnes Wort ergäbe „/wort/releases/download/“, also irgendein
      // Repository namens „releases“.
      expect(
          updateGesperrt(Uri.parse('https://github.com/wort/releases/download/v1/setup.exe'),
              download: true, quellen: const ['wort']),
          isNotNull);
      // Ein gültiger Name daneben gilt weiter.
      expect(
          updateGesperrt(Uri.parse('https://api.github.com/repos/a/b/releases/latest'),
              download: false, quellen: const ['x/y/../../../users/z', 'a/b']),
          isNull);
    });
  });
}
