import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/anmeldedaten.dart';
import 'package:moocp/anmeldung.dart' show Instanz, weitereProfileAnmelden;
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/protokoll.dart';
import 'package:moocp/profil.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'Testzugang gilt nur für die zugeordnete Profilkennung und Moodle-Adresse',
    () {
      const zuordnung = <String, ({String datei, String adresse})>{
        'testprofil': (
          datei: 'testzugang.env',
          adresse: 'HTTPS://MOODLE.SCHULE.EXAMPLE/',
        ),
      };
      final testprofil = Profil(
        kennung: 'testprofil',
        name: 'Test',
        adresse: 'https://moodle.schule.example',
        port: 47811,
        mcpName: 'test',
      );
      final produktivprofil = testprofil.copyWith(
        adresse: 'https://produktiv.schule.example',
      );
      final anderesMoodleUnterverzeichnis = testprofil.copyWith(
        adresse: 'https://moodle.schule.example/Moodle',
      );
      final testpfad = testprofil.copyWith(
        adresse: 'https://moodle.schule.example/test',
      );
      final query = testprofil.copyWith(
        adresse: 'https://moodle.schule.example/?next=/test',
      );
      final anderesProfil = Profil(
        kennung: 'anderes-profil',
        name: 'Anderes Profil',
        adresse: testprofil.adresse,
        port: 47812,
        mcpName: 'anderes',
      );

      expect(
        Anmeldedaten.testzugangZuordnungPasst(testprofil, zuordnung),
        isTrue,
      );
      expect(
        Anmeldedaten.testzugangZuordnungPasst(produktivprofil, zuordnung),
        isFalse,
      );
      expect(
        Anmeldedaten.testzugangZuordnungPasst(
          anderesMoodleUnterverzeichnis,
          zuordnung,
        ),
        isFalse,
      );
      expect(
        Anmeldedaten.testzugangZuordnungPasst(testpfad, zuordnung),
        isFalse,
      );
      expect(Anmeldedaten.testzugangZuordnungPasst(query, zuordnung), isFalse);
      expect(
        Anmeldedaten.testzugangZuordnungPasst(
          testprofil.copyWith(adresse: 'https://moodle.schule.example/test'),
          const {
            'testprofil': (
              datei: 'testzugang.env',
              adresse: 'https://moodle.schule.example/test',
            ),
          },
        ),
        isFalse,
      );
      expect(
        Anmeldedaten.testzugangZuordnungPasst(anderesProfil, zuordnung),
        isFalse,
      );
    },
  );

  group('Testzugang schreibt und löscht nichts Gemeinsames', () {
    // Das Testprofil trägt die Kennung des Standardprofils und liest seine
    // Zugangsdaten aus einer Datei. Haken, Benutzername und Passwort der echten
    // Anmeldung lägen unter denselben Schlüsseln: Der Testbetrieb darf sie
    // weder überschreiben noch löschen.
    const adresse = 'https://test.schule.example';
    const sicher = FlutterSecureStorage();

    setUp(() {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({
        'anmeldung.merken': true,
        'anmeldung.benutzer': 'e.mustermann',
        'anmeldung.herkunft': 'https://moodle.schule.example:443',
      });
      // ignore: invalid_use_of_visible_for_testing_member
      FlutterSecureStorage.setMockInitialValues({'moodle.passwort': 'echtes-passwort'});
    });

    tearDown(() => Anmeldedaten.testprofileErsatz = null);

    void testzugangBinden() => Anmeldedaten.testprofileErsatz = {
          Profil.standardKennung: (datei: 'testzugang.env', adresse: adresse),
        };

    Future<void> gemeinsamUnveraendert() async {
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('anmeldung.merken'), isTrue);
      expect(prefs.getString('anmeldung.benutzer'), 'e.mustermann');
      expect(prefs.getString('anmeldung.herkunft'), 'https://moodle.schule.example:443');
      expect(await sicher.read(key: 'moodle.passwort'), 'echtes-passwort');
    }

    test('speichern im Testzugang schreibt weder Haken und Benutzername noch Passwort', () async {
      testzugangBinden();
      await Anmeldedaten.speichern('testlehrkraft', 'test-passwort', adresse: adresse);
      await gemeinsamUnveraendert();
    });

    test('loeschen im Testzugang löscht nichts, auch nicht das vorhandene Passwort', () async {
      testzugangBinden();
      await Anmeldedaten.loeschen(adresse: adresse);
      await gemeinsamUnveraendert();
    });

    test('merkenSetzen im Testzugang (auch „aus") und das Verwerfen des Passworts lassen alles stehen', () async {
      testzugangBinden();
      await Anmeldedaten.merkenSetzen(false, adresse: adresse);
      await Anmeldedaten.passwortVerwerfen(adresse: adresse);
      await gemeinsamUnveraendert();
    });

    test('ohne Testzugang (andere Adresse) gilt alles wie gewohnt', () async {
      testzugangBinden();
      const echt = 'https://moodle.schule.example';
      await Anmeldedaten.speichern('e.mustermann', 'neues-passwort', adresse: echt);
      expect(await sicher.read(key: 'moodle.passwort'), 'neues-passwort');
      await Anmeldedaten.passwortVerwerfen(adresse: echt);
      expect(await sicher.read(key: 'moodle.passwort'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('anmeldung.merken'), isTrue, reason: 'Haken und Benutzername bleiben');
      expect(prefs.getString('anmeldung.benutzer'), 'e.mustermann');
      await Anmeldedaten.loeschen(adresse: echt);
      expect(prefs.getBool('anmeldung.merken'), isFalse);
      expect(prefs.getString('anmeldung.benutzer'), isNull);
    });
  });

  group('Gespeicherte Anmeldedaten gelten nur für die bestätigte Herkunft', () {
    const a = 'https://moodle.schule.example';
    const b = 'https://moodle2.schule.example';
    const sicher = FlutterSecureStorage();

    setUp(() {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      // ignore: invalid_use_of_visible_for_testing_member
      FlutterSecureStorage.setMockInitialValues({});
    });

    tearDown(() => Anmeldedaten.testprofileErsatz = null);

    Future<Anmeldedaten> ladenFuer(String adresse, {String kennung = Profil.standardKennung}) =>
        Anmeldedaten.laden(kennung: kennung, adresse: adresse);

    test('die Herkunft wird normalisiert: Groß-/Kleinschreibung, Standardport, Pfad, Benutzerkennung', () {
      expect(Anmeldedaten.herkunftVon('https://moodle.schule.example'), 'https://moodle.schule.example:443');
      expect(Anmeldedaten.herkunftVon('HTTPS://Moodle.Schule.EXAMPLE:443/'), 'https://moodle.schule.example:443');
      expect(Anmeldedaten.herkunftVon('https://moodle.schule.example./moodle?x=1#y'), 'https://moodle.schule.example:443');
      expect(Anmeldedaten.herkunftVon(' https://u:p@moodle.schule.example:8443/ '), 'https://moodle.schule.example:8443');
      expect(Anmeldedaten.herkunftVon('https://[2001:db8::1]/'), 'https://[2001:db8::1]:443');
    });

    test('keine Herkunft für Unbrauchbares: kein https, kein Host, ungültiger Port', () {
      for (final x in ['', 'moodle.schule.example', 'http://moodle.schule.example', 'https://', 'https://:8443', 'ftp://x.example', 'https://x.example:0', '::::']) {
        expect(Anmeldedaten.herkunftVon(x), isNull, reason: x);
      }
    });

    test('gleiche Herkunft: das Passwort wird gelesen, auch in anderer Schreibweise', () async {
      await Anmeldedaten.speichern('e.mustermann', 'geheim', adresse: a);
      for (final x in [a, '$a/', '$a:443', 'HTTPS://MOODLE.SCHULE.EXAMPLE:443/kurs']) {
        final d = await ladenFuer(x);
        expect(d.passwort, 'geheim', reason: x);
        expect(d.herkunftHinweis, isNull, reason: x);
      }
    });

    test('anderer Host: das Passwort wird nicht gelesen, die Lehrkraft bekommt einen Hinweis', () async {
      await Anmeldedaten.speichern('e.mustermann', 'geheim', adresse: a);
      final d = await ladenFuer(b);
      expect(d.passwort, isNull);
      expect(d.benutzer, 'e.mustermann');
      expect(d.herkunftHinweis, isNotNull);
      expect(d.herkunftHinweis, contains('neu anmelden'));
    });

    test('anderer Port: das Passwort wird nicht gelesen', () async {
      await Anmeldedaten.speichern('e.mustermann', 'geheim', adresse: a);
      expect((await ladenFuer('$a:8443')).passwort, isNull);
      expect((await ladenFuer('$a:8443')).herkunftHinweis, isNotNull);
    });

    test('eine fehlgeschlagene Anmeldung verschiebt die Bindung nie: auch nach einem Neustart bleibt das Passwort gesperrt', () async {
      await Anmeldedaten.speichern('e.mustermann', 'geheim', adresse: a);
      // Die Adresse ist geändert, die manuelle Anmeldung scheitert: speichern
      // wird nie aufgerufen. Nach dem „Neustart" gilt weiter die alte Herkunft.
      expect((await ladenFuer(b)).passwort, isNull);
      expect((await ladenFuer(b)).passwort, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('anmeldung.herkunft'), 'https://moodle.schule.example:443');
      expect(await sicher.read(key: 'moodle.passwort'), 'geheim');
      // Zurück zur alten Adresse: wieder erlaubt.
      expect((await ladenFuer(a)).passwort, 'geheim');
    });

    test('der Start meldet kein Profil an, dessen Adresse nicht zur gespeicherten Herkunft passt', () async {
      Instanz instanz(String kennung, String adresse) {
        final protokoll = Protokoll();
        final freigaben = Freigaben(protokoll);
        final moodle = MoodleZugang(protokoll);
        final profil = Profil(kennung: kennung, name: kennung, adresse: adresse, port: 47811, mcpName: kennung);
        return Instanz(
          moodle,
          freigaben,
          McpDienst(Einstellungen(), moodle, protokoll, freigaben, 'test-arbeitsordner', profil: profil),
        );
      }

      await Anmeldedaten.speichern('e.mustermann', 'geheim-p', adresse: a, kennung: 'p');
      await Anmeldedaten.speichern('e.mustermann', 'geheim-q', adresse: a, kennung: 'q');
      final sichtbar = instanz('s', a);
      final p = instanz('p', b); // Adresse geändert
      final q = instanz('q', '$a:443/'); // gleiche Herkunft
      final gesendet = <String>[];
      await weitereProfileAnmelden(
        [sichtbar, p, q],
        sichtbar: sichtbar,
        anmelden: (i, adresse, benutzer, passwort) async => gesendet.add('${i.dienst.profil.kennung}|$adresse|$passwort'),
      );
      expect(gesendet, ['q|$a:443/|geheim-q']);
    });

    test('Umbenennen behält die Bindung: sie hängt an der Kennung, nicht am Namen', () async {
      await Anmeldedaten.speichern('e.mustermann', 'geheim', adresse: a, kennung: 'profil-1');
      final umbenannt = Profil(kennung: 'profil-1', name: 'Neuer Name', adresse: a, port: 47811, mcpName: 'x');
      final d = await ladenFuer(umbenannt.adresse, kennung: umbenannt.kennung);
      expect(d.passwort, 'geheim');
      // Ein anderes Profil sieht die Bindung nicht.
      expect((await ladenFuer(a, kennung: 'profil-2')).merken, isFalse);
    });

    test('Altbestand ohne Herkunft: manuelle Anmeldung nötig, danach gilt die neue Bindung', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({'anmeldung.merken': true, 'anmeldung.benutzer': 'e.mustermann'});
      // ignore: invalid_use_of_visible_for_testing_member
      FlutterSecureStorage.setMockInitialValues({'moodle.passwort': 'altes-passwort'});
      final alt = await ladenFuer(a);
      expect(alt.passwort, isNull);
      expect(alt.herkunftHinweis, isNotNull);
      await Anmeldedaten.speichern('e.mustermann', 'neues-passwort', adresse: b);
      expect((await ladenFuer(a)).passwort, isNull);
      final neu = await ladenFuer(b);
      expect(neu.passwort, 'neues-passwort');
      expect(neu.herkunftHinweis, isNull);
    });

    test('eine nicht lesbare oder nicht-https-Herkunft im Speicher gilt wie keine', () async {
      for (final kaputt in ['http://moodle.schule.example:80', 'unsinn', '']) {
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({
          'anmeldung.merken': true,
          'anmeldung.benutzer': 'e.mustermann',
          'anmeldung.herkunft': kaputt,
        });
        // ignore: invalid_use_of_visible_for_testing_member
        FlutterSecureStorage.setMockInitialValues({'moodle.passwort': 'geheim'});
        expect((await ladenFuer(a)).passwort, isNull, reason: kaputt);
      }
    });

    test('ohne Adresse oder mit nicht-https-Adresse wird nichts gelesen', () async {
      await Anmeldedaten.speichern('e.mustermann', 'geheim', adresse: a);
      expect((await ladenFuer('')).passwort, isNull);
      expect((await ladenFuer('http://moodle.schule.example')).passwort, isNull);
    });

    test('Speichern mit unbrauchbarer Adresse legt keine Bindung an', () async {
      await Anmeldedaten.speichern('e.mustermann', 'geheim', adresse: a);
      await Anmeldedaten.speichern('e.mustermann', 'anderes', adresse: 'http://moodle.schule.example');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('anmeldung.herkunft'), isNull);
      expect((await ladenFuer(a)).passwort, isNull);
    });

    test('Löschen und Haken weg entfernen auch die Bindung', () async {
      await Anmeldedaten.speichern('e.mustermann', 'geheim', adresse: a);
      await Anmeldedaten.merkenSetzen(false, adresse: a);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('anmeldung.herkunft'), isNull);
    });

    test('ein verworfenes Passwort lässt die Bindung stehen, es gibt aber nichts zu lesen', () async {
      await Anmeldedaten.speichern('e.mustermann', 'geheim', adresse: a);
      await Anmeldedaten.passwortVerwerfen(adresse: a);
      expect((await ladenFuer(a)).passwort, isNull);
    });

    test('weitere Profile tragen eigene Schlüssel für die Herkunft', () async {
      await Anmeldedaten.speichern('e.mustermann', 'geheim', adresse: a, kennung: 'profil-1');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('anmeldung.herkunft.profil-1'), 'https://moodle.schule.example:443');
      expect(prefs.getString('anmeldung.herkunft'), isNull);
    });
  });
}
