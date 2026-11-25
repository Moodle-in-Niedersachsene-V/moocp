// Offline prüfbar: Instanzprofile (E31). Altbestand-Migration der
// Einstellungen, Port und Servername je Profil, und die Registry der Zugänge.
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/einstellungen_ort.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/instanzen.dart';
import 'package:moocp/plugin/verbindung.dart' show mcpWerkzeugnameHoechstens, werkzeugnameHoechstens;
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';

Einstellungen _standard() => Einstellungen(schluessel: 'x');

final _a = Profil(
    kennung: 'a1b2c3d4', name: 'Schule A', adresse: 'https://a.schule.example', port: 47811, mcpName: 'schule-a');
final _b = Profil(
    kennung: 'e5f6a7b8', name: 'Schule B', adresse: 'https://b.schule.example', port: 47812, mcpName: 'schule-b');

void main() {
  group('Altbestand und Einstellungen', () {
    test('beschädigte Einstellungsdatei fällt auf Vorgaben zurück und wird ersetzt', () async {
      final ordner = await Directory.systemTemp.createTemp('moocp_einstellungen_test_');
      addTearDown(() => ordner.delete(recursive: true));
      final datei = File('${ordner.path}/einstellungen.json');
      await datei.writeAsString('{ ungültiges JSON');

      final geladen = await Einstellungen.laden(datei: datei);

      expect(geladen.profile, isEmpty);
      expect(geladen.port, standardPort);
      expect(geladen.bestaetigungen, Bestaetigungen.vorgabe);
      expect(geladen.updatePruefen, isNull);
      expect(geladen.schluessel, matches(RegExp(r'^[0-9a-f]{64}$')));
      final erneut = await Einstellungen.laden(datei: datei);
      expect(erneut.zuJson(), geladen.zuJson());
    });

    test('nur moodleAdresse wird zum Standardprofil mit Port 47811 und Servername moodle', () {
      final e = Einstellungen.aus({'moodleAdresse': 'https://moodle.schule.example'}, _standard());
      expect(e.profile, hasLength(1));
      expect(e.profile.first.kennung, Profil.standardKennung);
      expect(e.profile.first.adresse, 'https://moodle.schule.example');
      expect(e.profile.first.port, standardPort);
      expect(e.profile.first.mcpName, 'moodle');
      expect(e.port, standardPort);
      expect(e.moodleAdresse, 'https://moodle.schule.example');
    });

    test('ein alter Port aus der Datei bleibt beim Standardprofil', () {
      final e = Einstellungen.aus({'moodleAdresse': 'https://moodle.schule.example', 'port': 47831}, _standard());
      expect(e.profile.first.port, 47831);
      expect(e.port, 47831);
    });

    test('ohne Adresse und ohne Profile gibt es kein Profil', () {
      final e = Einstellungen.aus({}, _standard());
      expect(e.profile, isEmpty);
      expect(e.moodleAdresse, '');
      expect(e.port, standardPort);
    });

    test('eine vorhandene Profilliste gewinnt über moodleAdresse', () {
      final e = Einstellungen.aus({
        'moodleAdresse': 'https://alt.schule.example',
        'profile': [_a.toJson(), _b.toJson()],
      }, _standard());
      expect(e.profile.map((p) => p.kennung), ['a1b2c3d4', 'e5f6a7b8']);
      expect(e.moodleAdresse, 'https://a.schule.example');
      expect(e.profile.map((p) => p.port), [47811, 47812]);
    });

    test('ein unbrauchbares Profil fällt weg, die anderen bleiben', () {
      final e = Einstellungen.aus({
        'profile': [
          {'kennung': '', 'name': 'kaputt', 'adresse': 'https://x.schule.example'},
          _b.toJson(),
        ],
      }, _standard());
      expect(e.profile.map((p) => p.kennung), ['e5f6a7b8']);
    });

    test('unbekannte Einstellungen und Profilfelder überstehen das Speichern', () {
      final e = Einstellungen.aus({
        'profile': [
          {..._a.toJson(), 'rolle': 'quelle'},
          {..._b.toJson(), 'rolle': 'ziel'},
        ],
        'projektkontext': {
          'quelle': {'profil': 'a1b2c3d4', 'kurs': 12},
          'durchfuehrung': [
            {'profil': 'e5f6a7b8', 'kurs': 34},
          ],
        },
      }, _standard());
      expect(e.profile.map((p) => p.kennung), ['a1b2c3d4', 'e5f6a7b8']);
      final neu = e.zuJson();
      expect(neu['projektkontext'], {
        'quelle': {'profil': 'a1b2c3d4', 'kurs': 12},
        'durchfuehrung': [{'profil': 'e5f6a7b8', 'kurs': 34}],
      });
      expect((neu['profile']! as List).map((p) => (p as Map)['rolle']), ['quelle', 'ziel']);
    });

    test('unbekannte Pluginfelder bleiben bei Änderungen erhalten, bekannte Werte werden validiert', () {
      final e = Einstellungen.aus({
        'plugins': {
          'beispiel': {'version': '1', 'pruefsumme': 'abc', 'zugestimmt': true, 'neu': [1, null]},
          'ungueltig': {'version': '1', 'pruefsumme': 'abc', 'zugestimmt': 'ja'},
        },
        'pluginUpdates': {'beispiel': {'aus': 'ungültig', 'neu': {'x': true}}},
      }, _standard());
      expect(e.pluginUpdates['beispiel']!.aus, isFalse);
      expect(e.plugins.containsKey('ungueltig'), isFalse);
      e.plugins['beispiel'] = e.plugins['beispiel']!.mitProfilen({'standard'});
      e.pluginUpdates['beispiel'] = e.pluginUpdates['beispiel']!.mit(aus: true);
      final j = e.zuJson();
      expect((j['plugins'] as Map)['beispiel']['neu'], [1, null]);
      expect((j['pluginUpdates'] as Map)['beispiel'], {'aus': true, 'neu': {'x': true}});
    });

    test('unbekannte Profilfelder bleiben auch bei gleichen Kennungen beim jeweiligen Profil', () {
      final e = Einstellungen.aus({
        'profile': [
          {..._a.toJson(), 'neu': 'erstes'},
          {..._a.toJson(), 'neu': 'zweites'},
        ],
      }, _standard());
      e.profile = [e.profile.last.copyWith(name: 'Neu'), e.profile.first];
      final profile = e.zuJson()['profile'] as List;
      expect(profile.map((p) => (p as Map)['neu']), ['zweites', 'erstes']);
      expect((profile.first as Map)['name'], 'Neu');
    });

    test('fehlender Port und Servername werden vergeben, Namen bleiben eindeutig', () {
      final e = Einstellungen.aus({
        'profile': [
          {'kennung': 'k1', 'name': 'Test', 'adresse': 'https://t.schule.example'},
          {'kennung': 'k2', 'name': 'test', 'adresse': 'https://u.schule.example'},
        ],
      }, _standard());
      expect(e.profile.map((p) => p.port), [standardPort, standardPort + 1]);
      expect(e.profile.map((p) => p.mcpName), ['test', 'test-2']);
    });

    test('gleiche Ports werden auseinandergezogen, das erste behält seinen', () {
      final e = Einstellungen(profile: [
        Profil(kennung: 'k1', name: 'Eins', adresse: 'https://e.schule.example', port: 47900, mcpName: 'eins'),
        Profil(kennung: 'k2', name: 'Zwei', adresse: 'https://z.schule.example', port: 47900, mcpName: 'zwei'),
      ], schluessel: 'x');
      expect(e.profile.map((p) => p.port), [47900, 47811]);
    });

    test('Bestätigungsstufen bleiben je Profil getrennt gespeichert', () {
      final e = Einstellungen(profile: [
        Profil(
          kennung: 'k1',
          name: 'Moodle',
          adresse: 'https://moodle.schule.example',
          port: 47811,
          mcpName: 'moodle',
          bestaetigungen: Bestaetigungen.alle,
        ),
        Profil(
          kennung: 'k2',
          name: 'Moodle Test',
          adresse: 'https://test.schule.example',
          port: 47812,
          mcpName: 'moodle-test',
          bestaetigungen: Bestaetigungen.keine,
        ),
      ], schluessel: 'x');

      final geladen = Einstellungen.aus(e.zuJson(), _standard());

      expect(geladen.profile.map((p) => p.bestaetigungen), [
        Bestaetigungen.alle,
        Bestaetigungen.keine,
      ]);
    });

    test('alte globale Bestätigungsstufe wird in alle alten Profile übernommen', () {
      final erstes = _a.toJson()..remove('bestaetigungen');
      final zweites = _b.toJson()..remove('bestaetigungen');
      final e = Einstellungen.aus({
        'bestaetigungen': 'keine',
        'profile': [erstes, zweites],
      }, _standard());

      expect(e.profile.map((p) => p.bestaetigungen), [
        Bestaetigungen.keine,
        Bestaetigungen.keine,
      ]);
    });

    test('speichern schreibt Profile und moodleAdresse, Rückführung ist verlustfrei', () {
      final e = Einstellungen.aus({'moodleAdresse': 'https://moodle.schule.example'}, _standard());
      final j = e.zuJson();
      expect(j['moodleAdresse'], 'https://moodle.schule.example');
      expect(j['port'], standardPort, reason: 'ältere Versionen lesen den Port oben');
      final zurueck = Einstellungen.aus(j, _standard());
      expect(zurueck.profile.single.kennung, Profil.standardKennung);
      expect(zurueck.profile.single.adresse, 'https://moodle.schule.example');
      expect(zurueck.profile.single.mcpName, 'moodle');
    });

    test('Setzen der Adresse ändert das erste Profil und behält die Kennung', () {
      final e = Einstellungen.aus({'profile': [_a.toJson(), _b.toJson()]}, _standard());
      e.moodleAdresse = 'https://neu.schule.example';
      expect(e.profile.first.adresse, 'https://neu.schule.example');
      expect(e.profile.first.kennung, 'a1b2c3d4');
      expect(e.profile.first.mcpName, 'schule-a');
      expect(e.profile.last.adresse, 'https://b.schule.example');
    });

    test('Setzen einer Adresse ohne Profil legt das Standardprofil an', () {
      final e = _standard();
      e.moodleAdresse = 'https://moodle.schule.example';
      expect(e.profile.single.kennung, Profil.standardKennung);
      expect(e.profile.single.port, standardPort);
      e.moodleAdresse = '';
      expect(e.profile.single.adresse, '');
    });
  });

  group('Zugangsschlüssel je Profil (E6)', () {
    test('das Standardprofil behält den globalen Schlüssel und hat keinen eigenen', () {
      final e = Einstellungen.aus({
        'schluessel': 'global',
        'moodleAdresse': 'https://moodle.schule.example',
      }, _standard());
      expect(e.profile.single.istStandard, isTrue);
      expect(e.profile.single.schluessel, isEmpty);
      expect(e.schluesselFuer(e.profile.single), 'global');
      expect(((e.zuJson()['profile']! as List).single as Map).containsKey('schluessel'), isFalse,
          reason: 'der globale Schlüssel steht schon oben in der Datei; kein zweiter Ort');
    });

    test('weitere Profile ohne Schlüssel bekommen beim Laden je einen eigenen, verschieden vom globalen', () {
      final e = Einstellungen.aus({
        'schluessel': 'global',
        'profile': [
          {'kennung': Profil.standardKennung, 'name': 'Moodle', 'adresse': 'https://a.schule.example'},
          {'kennung': 'k2', 'name': 'Zwei', 'adresse': 'https://b.schule.example'},
          {'kennung': 'k3', 'name': 'Drei', 'adresse': 'https://c.schule.example'},
        ],
      }, _standard());
      final standard = e.profile[0], zwei = e.profile[1], drei = e.profile[2];
      expect(e.schluesselFuer(standard), 'global');
      expect(zwei.schluessel, hasLength(64));
      expect(drei.schluessel, hasLength(64));
      expect({zwei.schluessel, drei.schluessel, 'global'}, hasLength(3));
      expect(e.schluesselFuer(zwei), zwei.schluessel);
    });

    test('ein vergebener Schlüssel übersteht Speichern und Laden unverändert', () {
      final e = Einstellungen.aus({
        'profile': [
          {'kennung': Profil.standardKennung, 'name': 'Moodle', 'adresse': 'https://a.schule.example'},
          {'kennung': 'k2', 'name': 'Zwei', 'adresse': 'https://b.schule.example'},
        ],
      }, _standard());
      final j = e.zuJson();
      expect(Einstellungen.schluesselFehlen(j), isFalse, reason: 'die Datei hat ihn jetzt');
      final zurueck = Einstellungen.aus(j, _standard());
      expect(zurueck.profile[1].schluessel, e.profile[1].schluessel);
    });

    test('schluesselFehlen: nur ein Profil außer dem Standardprofil ohne Schlüssel verlangt ein Speichern', () {
      expect(Einstellungen.schluesselFehlen({}), isFalse);
      expect(Einstellungen.schluesselFehlen({'moodleAdresse': 'https://a.schule.example'}), isFalse);
      expect(Einstellungen.schluesselFehlen({
        'profile': [
          {'kennung': Profil.standardKennung, 'name': 'Moodle', 'adresse': 'https://a.schule.example'},
        ],
      }), isFalse);
      expect(Einstellungen.schluesselFehlen({
        'profile': [
          {'kennung': 'k2', 'name': 'Zwei', 'adresse': 'https://b.schule.example'},
        ],
      }), isTrue);
      expect(Einstellungen.schluesselFehlen({
        'profile': [
          {'kennung': 'k2', 'name': 'Zwei', 'adresse': 'https://b.schule.example', 'schluessel': 'abc'},
        ],
      }), isFalse);
    });

    test('ändern am Profil (Name, Adresse, Stufe) behält den Schlüssel', () {
      final p = Profil(
          kennung: 'k2', name: 'Zwei', adresse: 'https://b.schule.example', port: 47812, mcpName: 'zwei', schluessel: 'meiner');
      expect(p.copyWith(adresse: 'https://c.schule.example').schluessel, 'meiner');
      expect(p.mitBestaetigungen(Bestaetigungen.alle).schluessel, 'meiner');
    });
  });

  group('Servername', () {
    test('aus dem Anzeigenamen: Kleinbuchstaben, Bindestriche, keine Leerzeichen', () {
      expect(Profil.mcpNameAus('Moodle Test'), 'moodle-test');
      expect(Profil.mcpNameAus('  Schule (Süd) 2 '), 'schule-s-d-2');
      expect(Profil.mcpNameAus('Ä Ö'), '');
    });

    test('gültig nur nach dem Muster, das mcpNameAus liefert', () {
      expect(Profil.mcpNameGueltig('moodle-test'), isTrue);
      expect(Profil.mcpNameGueltig('Moodle Test'), isFalse);
      expect(Profil.mcpNameGueltig('-x'), isFalse);
    });

    test('ohne brauchbaren Namen zählt die Kennung', () {
      expect(Profil.mcpNameFuer('Ä', 'k9'), 'moodle-k9');
    });

    test('ein neues Profil: höchstens 17 Zeichen, auch mit Unterscheidung, gültig und eindeutig', () {
      expect(Profil.neuerMcpNameHoechstens, 17);
      // So passt jedes Werkzeug eines Plugins: mcp__<Profil>__ davor, und ein
      // Werkzeugname hat höchstens 40 Zeichen (plugin/verbindung.dart).
      expect(Profil.neuerMcpNameHoechstens, mcpWerkzeugnameHoechstens - 'mcp____'.length - werkzeugnameHoechstens);
      expect(Profil.neuerMcpName('moodle-test', const {}), 'moodle-test');
      expect(Profil.neuerMcpName('moodle-test', const {'moodle-test'}), 'moodle-test-2');
      final lang = Profil.mcpNameAus('Berufsbildende Schulen Musterstadt');
      expect(Profil.neuerMcpName(lang, const {}), 'berufsbildende-sc');
      // Endet die Kürzung auf einem Bindestrich, fällt er weg.
      expect(Profil.neuerMcpName('moodle-schule-abc-def', const {}), 'moodle-schule-abc');
      expect(Profil.neuerMcpName('abcdefghijklmnop-qrs', const {}), 'abcdefghijklmnop');
      final vergeben = <String>{'berufsbildende-sc'};
      for (var i = 2; i <= 12; i++) {
        final n = Profil.neuerMcpName(lang, vergeben);
        expect(n.length, lessThanOrEqualTo(17), reason: n);
        expect(Profil.mcpNameGueltig(n), isTrue, reason: n);
        expect(vergeben.add(n), isTrue, reason: n);
      }
      expect(vergeben, containsAll(['berufsbildende-2', 'berufsbildende-12']));
    });
  });

  group('Registry', () {
    test('je Kennung ein eigener Zugang, bei gleicher Kennung derselbe', () {
      final r = MoodleInstanzen(Protokoll());
      final a = r.zugang(_a);
      final b = r.zugang(_b);
      expect(identical(a, b), isFalse);
      expect(identical(a, r.zugang(_a)), isTrue);
      expect(r.hat(_b.kennung), isTrue);
    });

    test('entfernen vergisst nur den einen Zugang', () {
      final r = MoodleInstanzen(Protokoll());
      final a = r.zugang(_a);
      r.zugang(_b);
      r.entfernen(_b.kennung);
      expect(r.hat(_b.kennung), isFalse);
      expect(r.hat(_a.kennung), isTrue);
      expect(identical(a, r.zugang(_a)), isTrue);
    });
  });

  test('neue Kennungen sind acht Hexziffern und ändern sich nicht', () {
    final k = Profil.neueKennung(Random(7));
    expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(k), isTrue);
    expect(Profil.neueKennung(Random(7)), k);
  });
}
