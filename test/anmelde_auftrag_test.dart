import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/anmeldedaten.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/anmeldung.dart' show weitereProfileAnmelden;
import 'package:moocp/main.dart'
    show AnmeldeAuftrag, Instanz, gespeicherteAnmeldedatenVerwenden;
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';

void main() {
  test(
    'verwendet gespeicherte Zugangsdaten nach Profilwechsel nicht weiter',
    () async {
      final begonnen = Completer<void>();
      final fortsetzen = Completer<void>();
      var aktivesProfil = 'profil-a';
      final felderVonB = <String>['lehrkraft-b:passwort-b'];

      final laden = gespeicherteAnmeldedatenVerwenden(
        laden: () async {
          begonnen.complete();
          await fortsetzen.future;
          return const Anmeldedaten(true, 'lehrkraft-a', 'passwort-a');
        },
        zielIstAktiv: () => aktivesProfil == 'profil-a',
        anwenden: (daten) =>
            felderVonB.add('${daten.benutzer}:${daten.passwort}'),
      );
      await begonnen.future;
      aktivesProfil = 'profil-b';
      fortsetzen.complete();
      await laden;

      expect(felderVonB, ['lehrkraft-b:passwort-b']);
    },
  );

  test(
    'behält Profil und Formulareingaben während einer verzögerten Anmeldung',
    () async {
      final protokoll = Protokoll();
      final einstellungen = Einstellungen(schluessel: 'test');
      final freigaben = Freigaben(protokoll);
      final moodle = MoodleZugang(protokoll);
      final profil = Profil(
        kennung: 'profil-a',
        name: 'A',
        adresse: 'https://a.schule.example',
        port: 47811,
        mcpName: 'a',
      );
      final instanz = Instanz(
        moodle,
        freigaben,
        McpDienst(
          einstellungen,
          moodle,
          protokoll,
          freigaben,
          'test-arbeitsordner',
          profil: profil,
        ),
      );
      final auftrag = AnmeldeAuftrag(
        instanz: instanz,
        profil: profil,
        adresse: profil.adresse,
        benutzer: 'lehrkraft-a',
        passwort: 'passwort-a',
        merken: true,
      );
      final begonnen = Completer<void>();
      final fortsetzen = Completer<void>();
      var ausgewaehltesProfil = 'profil-a';

      final anmeldung = () async {
        begonnen.complete();
        await fortsetzen.future;
        expect(auftrag.instanz, same(instanz));
        expect(auftrag.profil.kennung, 'profil-a');
        expect(auftrag.adresse, 'https://a.schule.example');
        expect(auftrag.benutzer, 'lehrkraft-a');
        expect(auftrag.passwort, 'passwort-a');
        expect(auftrag.merken, isTrue);
      }();
      await begonnen.future;
      ausgewaehltesProfil = 'profil-b';
      fortsetzen.complete();
      await anmeldung;

      expect(ausgewaehltesProfil, 'profil-b');
    },
  );

  group('weitere Profile beim Start', () {
    Instanz instanz(String kennung, {String? adresse}) {
      final protokoll = Protokoll();
      final freigaben = Freigaben(protokoll);
      final moodle = MoodleZugang(protokoll);
      final profil = Profil(
        kennung: kennung,
        name: kennung,
        adresse: adresse ?? 'https://$kennung.schule.example',
        port: 47811,
        mcpName: kennung,
      );
      return Instanz(
        moodle,
        freigaben,
        McpDienst(Einstellungen(schluessel: 'test'), moodle, protokoll, freigaben, 'test-arbeitsordner', profil: profil),
      );
    }

    test('meldet jedes Profil mit gespeicherten Anmeldedaten an, nicht das sichtbare', () async {
      final a = instanz('a'), b = instanz('b'), c = instanz('c'), d = instanz('d', adresse: '');
      final angemeldet = <String>[];
      await weitereProfileAnmelden(
        [a, b, c, d],
        sichtbar: a,
        laden: (p) async => p.kennung == 'c'
            ? const Anmeldedaten(false, null, null)
            : Anmeldedaten(true, 'lehrkraft-${p.kennung}', 'passwort-${p.kennung}'),
        passwortVerwerfen: (p) async => fail('nichts zu verwerfen'),
        anmelden: (i, adresse, benutzer, passwort) async => angemeldet.add('$adresse|$benutzer|$passwort'),
      );
      // a ist das sichtbare, c hat keinen Haken, d keine Adresse.
      expect(angemeldet, ['https://b.schule.example|lehrkraft-b|passwort-b']);
    });

    test('abgelehntes Passwort wird verworfen, ein Fehler hält die übrigen nicht auf', () async {
      final a = instanz('a'), b = instanz('b'), c = instanz('c'), d = instanz('d');
      final verworfen = <String>[];
      final versucht = <String>[];
      await weitereProfileAnmelden(
        [a, b, c, d],
        sichtbar: a,
        laden: (p) async => Anmeldedaten(true, 'lehrkraft', 'passwort'),
        passwortVerwerfen: (p) async => verworfen.add(p.kennung),
        anmelden: (i, adresse, benutzer, passwort) async {
          final k = i.dienst.profil.kennung;
          versucht.add(k);
          if (k == 'b') throw MoodleAnmeldungAbgelehnt('abgelehnt');
          if (k == 'c') throw MoodleNichtErreichbar('nicht erreichbar');
        },
      );
      expect(versucht, ['b', 'c', 'd']);
      // Nur das ausdrücklich abgelehnte; war Moodle nicht erreichbar, bleibt es (E7).
      expect(verworfen, ['b']);
    });

    test('ohne lesbares Passwort geht nichts an Moodle', () async {
      final a = instanz('a'), b = instanz('b');
      await weitereProfileAnmelden(
        [a, b],
        sichtbar: a,
        laden: (p) async => const Anmeldedaten(true, 'lehrkraft', null),
        passwortVerwerfen: (p) async => fail('nichts zu verwerfen'),
        anmelden: (i, adresse, benutzer, passwort) async => fail('kein Versuch ohne Passwort'),
      );
    });
  });
}
