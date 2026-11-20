// Instanzprofile sind ein Sonderfall für wenige: Wer nur eine Moodle-Instanz
// hat -- fast jeder --, sieht von Profilen nichts (E32). Erst ab zwei Profilen
// erscheinen die Auswahl und die Namen in Titelzeile und Dialogen; eine weitere
// Instanz verbindet man über die Einstellungen. Dazu: die Stufe „keine" eines
// Profils im Hintergrund bleibt sichtbar (E20), und ein veraltetes
// gespeichertes Passwort erzeugt genau einen Fehlversuch (E7).
//
// Die Einstellungen schreiben hier nichts: Eine Unterklasse ersetzt `speichern`,
// denn sonst überschriebe der Test die echte Einstellungsdatei der App.
//
// Am Ende stehen die Dialoge zu Plugins (Zustimmung beim Start, Eintrag
// „Plugins“ in den Einstellungen): Auch sie zeigen Profile erst ab dem zweiten
// (E32), und die Zustimmung ist wie eine Freigabe nur mit der Maus und erst
// nach der Wartezeit zu entscheiden (E4). Ebenso der Dialog vor dem Anhängen
// eines Entwicklungs-Plugins (`--plugin-entwicklung`), der bei jedem Start
// fragt und nichts speichert.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/arbeitsordner.dart';
import 'package:moocp/einrichtung.dart';
import 'package:moocp/einrichtung_dialog.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/einstellungen_dialog.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/main.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/plugin/adressmuster.dart';
import 'package:moocp/plugin/beschreibung.dart';
import 'package:moocp/plugin/entscheidung.dart';
import 'package:moocp/plugin/entwicklung.dart';
import 'package:moocp/plugin/laufende_plugins.dart';
import 'package:moocp/plugin/plugins.dart';
import 'package:moocp/plugin/schnittstelle.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'hilfen/nur_maus.dart';

class _EinstellungenOhneDatei extends Einstellungen {
  _EinstellungenOhneDatei({super.profile, super.plugins, required super.schluessel});
  int gespeichert = 0;

  @override
  Future<void> speichern() async => gespeichert++;
}

/// Ein Zugang, der sich nicht ins Netz wagt: zählt die Versuche und lehnt auf
/// Wunsch ausdrücklich ab, wie Moodle bei einem falschen Passwort.
class _Zugang extends MoodleZugang {
  _Zugang(super.protokoll, {this.ablehnen = false});
  final bool ablehnen;
  int versuche = 0;

  @override
  Future<void> anmelden(String adresse, String benutzer, String passwort) async {
    versuche++;
    if (ablehnen) {
      throw MoodleAnmeldungAbgelehnt('Anmeldung fehlgeschlagen. Benutzername oder Passwort prüfen.');
    }
  }
}

Profil _profil(String kennung, String name, String mcp, int port, {Bestaetigungen stufe = Bestaetigungen.mittel}) =>
    Profil(
      kennung: kennung,
      name: name,
      adresse: 'https://$mcp.schule.example',
      port: port,
      mcpName: mcp,
      bestaetigungen: stufe,
      schluessel: kennung == Profil.standardKennung ? '' : 'schluessel-$kennung',
    );

Instanz _instanz(Einstellungen e, Protokoll protokoll, Profil profil, {bool ablehnen = false}) {
  final ansicht = protokoll.fuer(profil.name);
  final zugang = _Zugang(ansicht, ablehnen: ablehnen);
  final freigaben = Freigaben(ansicht, stufe: profil.bestaetigungen);
  return Instanz(zugang, freigaben, McpDienst(e, zugang, ansicht, freigaben, 'arbeitsordner', profil: profil));
}

/// Alles eingerichtet: Die echte Prüfung sähe auf dem Rechner nach.
Future<Einrichtungsstand> _eingerichtet() async => Einrichtungsstand(
      werkzeuge: [
        Werkzeugstand(
          werkzeug: ClaudeCode(const {}),
          gewaehlt: true,
          verbindung: Verbindung.aktuell,
          skills: const [],
          stand: const {},
          entfernen: const {},
        ),
      ],
      skills: const [],
    );

class _Aufbau {
  _Aufbau(this.einstellungen, this.protokoll, this.instanzen);
  final _EinstellungenOhneDatei einstellungen;
  final Protokoll protokoll;
  final List<Instanz> instanzen;
}

/// Ein gefundenes Plugin, ohne dass etwas auf der Platte liegt: Prüfsumme und
/// Beschreibung stehen fest im Speicher.
PluginEintrag _pluginEintrag({
  String ordner = 'beispiel',
  String version = '1.0',
  List<Zusatzadresse> adressen = const [],
  List<String> quellen = const [],
  String? fehler,
  int schnittstelle = 1,
}) {
  if (fehler != null) return PluginEintrag(ordner: ordner, pfad: 'plugins/$ordner', fehler: fehler);
  final urteil = schnittstelleUrteil(schnittstelle);
  return PluginEintrag(
    ordner: ordner,
    pfad: 'plugins/$ordner',
    pruefsumme: 'summe-$version',
    beschreibung: PluginBeschreibung(
      name: 'Beispiel-Plugin',
      kurzname: 'beispiel',
      version: version,
      schnittstelle: schnittstelle,
      programm: 'beispiel.exe',
      herkunft: 'Beispiel-Projekt',
      zusatzadressen: adressen,
      updateQuellen: quellen,
    ),
    fehler: urteil == SchnittstellenUrteil.passt ? null : schnittstelleGrund(urteil, schnittstelle),
    unpassend: urteil == SchnittstellenUrteil.passt ? null : urteil,
  );
}

final _lesen = Zusatzadresse(Adressmuster.parsen('/mod/beispiel/*'), ZugriffsArt.lesen, 'Liest die Seiten der Aktivität.');
final _schreiben = Zusatzadresse(Adressmuster.parsen('/mod/beispiel/save.php'), ZugriffsArt.schreiben, 'Speichert die Einstellungen.');

/// Laufende Plugins, die nichts starten und sich nirgends verbinden: Sie
/// halten nur fest, was die App von ihnen verlangt.
class _Laufende extends LaufendePlugins {
  _Laufende(super.protokoll);
  final angehaengt = <EntwicklungsPlugin>[];
  int gestartet = 0;

  @override
  Future<void> anhaengen(EntwicklungsPlugin plugin, {required Set<String> eingebaut}) async => angehaengt.add(plugin);

  @override
  Future<void> starten(Plugins plugins, {required Set<String> eingebaut}) async => gestartet++;
}

/// Ein Entwicklungs-Plugin wie nach entwicklungVorbereiten.
EntwicklungsPlugin _entwicklungsPlugin({List<Zusatzadresse> adressen = const []}) => EntwicklungsPlugin(
      'geheimer-schluessel-des-tests',
      ordner: r'C:\Entwicklung\beispiel',
      port: 47900,
      beschreibung: PluginBeschreibung(
        name: 'Beispiel-Plugin',
        kurzname: 'beispiel',
        version: '1.0',
        schnittstelle: 1,
        programm: 'beispiel.exe',
        herkunft: 'Beispiel-Projekt',
        zusatzadressen: adressen,
        entwicklungsPort: 47900,
      ),
    );

/// Zugestimmt, für den Stand, den [_pluginEintrag] liefert.
PluginEntscheidung _zugestimmt(Set<String> profile, {bool ja = true}) =>
    PluginEntscheidung(version: '1.0', pruefsumme: 'summe-1.0', zugestimmt: ja, profile: profile);

void main() {
  setUp(() {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    // ignore: invalid_use_of_visible_for_testing_member
    FlutterSecureStorage.setMockInitialValues({});
    // ignore: invalid_use_of_visible_for_testing_member
    PackageInfo.setMockInitialValues(
        appName: 'moocp', packageName: 'moocp', version: '0.9.4', buildNumber: '1', buildSignature: '');
  });

  /// Startet die App wie `main`: das erste Profil ist das Hauptprofil, die
  /// übrigen kommen als `weitere`, und `instanzErstellen` gibt es immer.
  Future<_Aufbau> starten(
    WidgetTester tester,
    List<Profil> profile, {
    List<bool> ablehnen = const [],
    List<PluginEintrag> plugins = const [],
    Map<String, PluginEntscheidung> entscheidungen = const {},
    List<String>? ablauf,
    EntwicklungsPlugin Function()? entwicklung,
    LaufendePlugins? laufende,
    double breite = 2000,
  }) async {
    tester.view.physicalSize = Size(breite, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final einstellungen = _EinstellungenOhneDatei(profile: profile, plugins: entscheidungen, schluessel: 'global');
    final protokoll = Protokoll();
    final instanzen = [
      for (var i = 0; i < einstellungen.profile.length; i++)
        _instanz(einstellungen, protokoll, einstellungen.profile[i], ablehnen: i < ablehnen.length && ablehnen[i]),
    ];
    await tester.pumpWidget(MoocpApp(
      einstellungen,
      protokoll,
      instanzen.first.moodle,
      instanzen.first.dienst,
      instanzen.first.freigaben,
      const Arbeitsordner('arbeitsordner'),
      weitere: instanzen.sublist(1),
      instanzErstellen: (neu) => _instanz(einstellungen, protokoll, neu),
      einrichtungsstand: () {
        ablauf?.add('einrichtung');
        return _eingerichtet();
      },
      pluginsLaden: plugins.isEmpty
          ? null
          : () async {
              ablauf?.add('plugins');
              return Plugins(einstellungen, protokoll, plugins);
            },
      laufendePlugins: laufende,
      entwicklungVorbereiten: entwicklung == null
          ? null
          : () {
              ablauf?.add('entwicklung');
              return entwicklung();
            },
    ));
    await tester.pumpAndSettle();
    return _Aufbau(einstellungen, protokoll, instanzen);
  }

  final standard = _profil(Profil.standardKennung, 'Moodle', 'moodle', 47811);
  final test = _profil('k2', 'Moodle Test', 'moodle-test', 47812);

  group('Ein Profil: die App sieht aus wie vor den Profilen', () {
    testWidgets('keine Profilkarte, kein Profilname in der Titelzeile, keine Auswahl', (tester) async {
      await starten(tester, [standard]);

      expect(find.text('moocp'), findsOneWidget, reason: 'die Titelzeile heißt nur moocp');
      expect(find.textContaining('Moodle-Profil'), findsNothing);
      expect(find.text('Profil hinzufügen'), findsNothing);
      expect(find.text('Profil bearbeiten'), findsNothing);
      expect(find.byType(DropdownButtonFormField<int>), findsNothing);
      expect(find.textContaining('(moodle)'), findsNothing);
      expect(find.text('MCP startet nach der Anmeldung'), findsOneWidget);
      expect(find.text('Moodle-Anmeldung'), findsOneWidget);
    });

    testWidgets('bei 700 px Breite läuft die Kopfzeile nicht über (Protokollspalte fest 460 px)', (tester) async {
      await starten(tester, [standard], breite: 700);

      expect(tester.takeException(), isNull, reason: 'kein Überlauf der Titelzeile oder der Spalten');
    });

    testWidgets('die Hilfe zu den Stufen nennt kein Profil', (tester) async {
      await starten(tester, [standard]);
      await tester.tap(find.byIcon(Icons.help_outline));
      await tester.pumpAndSettle();
      expect(find.text('Bestätigungen vor Änderungen'), findsOneWidget);
    });

    testWidgets('Einstellungen und KI-Werkzeuge einrichten nennen kein Profil', (tester) async {
      await starten(tester, [standard]);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Einstellungen'), findsOneWidget);
      expect(find.byKey(const Key('delete-profile')), findsNothing, reason: 'eines bleibt immer');

      await tester.tap(find.text('Verbindung und Skills prüfen'));
      await tester.pumpAndSettle();
      expect(find.text('KI-Werkzeuge einrichten'), findsOneWidget);
      expect(find.textContaining('(moodle)'), findsNothing);
    });

    testWidgets('die Einstellungen bieten unten eine weitere Instanz an; sie führt zum Profil-Dialog', (tester) async {
      final a = await starten(tester, [standard]);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Weitere Moodle-Instanz verbinden …'), findsOneWidget);

      await tester.tap(find.byKey(const Key('add-profile')));
      await tester.pumpAndSettle();
      expect(find.text('Moodle-Profil hinzufügen'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('profile-name')), 'Moodle Test');
      await tester.enterText(find.byKey(const Key('profile-address')), 'https://test.schule.example');
      await tester.tap(find.text('Hinzufügen'));
      await tester.pumpAndSettle();

      // Das neue Profil richtet die KI-Werkzeuge mit seinem Namen ein; erst jetzt steht er im Titel.
      expect(find.textContaining('Moodle Test (moodle-test)'), findsWidgets);
      await tester.tap(find.text('Weiter'));
      await tester.pumpAndSettle();

      expect(find.text('Moodle-Profil'), findsOneWidget, reason: 'ab zwei Profilen die Auswahl');
      expect(find.text('moocp — Moodle Test (moodle-test)'), findsOneWidget);
      expect(a.einstellungen.profile, hasLength(2));
      final neu = a.einstellungen.profile.last;
      expect(neu.schluessel, hasLength(64), reason: 'jedes neue Profil bekommt einen eigenen Schlüssel');
      expect(neu.schluessel, isNot(a.einstellungen.schluessel));
      expect(a.einstellungen.gespeichert, greaterThan(0));
    });
  });

  group('Ab zwei Profilen erscheinen Auswahl und Namen', () {
    testWidgets('bei 800 px läuft die Titelzeile mit zwei Profilen nicht über', (tester) async {
      await starten(tester, [standard, test], breite: 800);

      expect(tester.takeException(), isNull, reason: 'kein Überlauf der Titelzeile oder der Spalten');
    });

    testWidgets('Karte „Moodle-Profil", Profilname in der Titelzeile, Löschen in den Einstellungen', (tester) async {
      await starten(tester, [standard, test]);

      expect(find.text('Moodle-Profil'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
      expect(find.text('Profil bearbeiten'), findsOneWidget);
      expect(find.text('moocp — Moodle (moodle)'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Einstellungen — Moodle (moodle)'), findsOneWidget);
      expect(find.byKey(const Key('delete-profile')), findsNothing,
          reason: 'das Standardprofil bleibt: Brücke und Eintrag „moodle" hängen daran');
    });

    testWidgets('die Auswahl wechselt den Titel', (tester) async {
      await starten(tester, [standard, test]);
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Moodle Test (moodle-test)').last);
      await tester.pumpAndSettle();
      expect(find.text('moocp — Moodle Test (moodle-test)'), findsOneWidget);
    });

    testWidgets('ein weiteres Profil lässt sich löschen', (tester) async {
      await starten(tester, [standard, test]);
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Moodle Test (moodle-test)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-profile')), findsOneWidget);
    });
  });

  group('Stufe „keine" bleibt sichtbar (E20)', () {
    final testOhneRueckfrage = _profil('k2', 'Moodle Test', 'moodle-test', 47812, stufe: Bestaetigungen.keine);

    testWidgets('beim Start steht jedes Profil mit „keine" im Protokoll, auch das nicht angezeigte', (tester) async {
      final a = await starten(tester, [standard, testOhneRueckfrage]);
      final texte = a.protokoll.eintraege.map((e) => e.text).toList();
      expect(texte.where((t) => t.contains('[Moodle Test] Bestätigungen: keine')), hasLength(1));
      expect(texte.where((t) => t.contains('[Moodle] Bestätigungen')), isEmpty, reason: 'mittel: kein Eintrag');
    });

    testWidgets('mit zwei Profilen auf „keine" stehen beide im Protokoll', (tester) async {
      final beide = _profil(Profil.standardKennung, 'Moodle', 'moodle', 47811, stufe: Bestaetigungen.keine);
      final a = await starten(tester, [beide, testOhneRueckfrage]);
      final texte = a.protokoll.eintraege.map((e) => e.text).toList();
      expect(texte.where((t) => t.contains('Bestätigungen: keine')), hasLength(2));
    });

    testWidgets('die Auswahl zeigt das Profil mit „keine" rot, während ein anderes aktiv ist', (tester) async {
      await starten(tester, [standard, testOhneRueckfrage]);
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();

      final eintrag = find.text('Moodle Test (moodle-test) – Bestätigungen: keine');
      expect(eintrag, findsWidgets);
      final farbe = Theme.of(tester.element(eintrag.last)).colorScheme.error;
      expect(tester.widget<Text>(eintrag.last).style?.color, farbe);
      // Das aktive Profil steht auf „mittel" und ist nicht rot.
      final normal = find.text('Moodle (moodle)');
      expect(tester.widget<Text>(normal.first).style?.color, isNull);
    });

    testWidgets('die Stufe eines weiteren Profils überschreibt das alte globale Feld nicht, die des Standardprofils schon',
        (tester) async {
      final a = await starten(tester, [standard, test]);
      expect(a.einstellungen.bestaetigungen, Bestaetigungen.mittel);

      // Weiteres Profil wählen und auf „keine" stellen.
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Moodle Test (moodle-test)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<Bestaetigungen>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('keine').last);
      await tester.pumpAndSettle();

      expect(a.einstellungen.profile[1].bestaetigungen, Bestaetigungen.keine);
      expect(a.einstellungen.bestaetigungen, Bestaetigungen.mittel,
          reason: 'ein älterer Stand läse sonst die Stufe des Testprofils als die der Instanz');

      // Das Standardprofil dagegen führt das alte Feld weiter.
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Moodle (moodle)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<Bestaetigungen>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('alle').last);
      await tester.pumpAndSettle();

      expect(a.einstellungen.profile[0].bestaetigungen, Bestaetigungen.alle);
      expect(a.einstellungen.bestaetigungen, Bestaetigungen.alle);
    });
  });

  group('Ein abgelehntes gespeichertes Passwort erzeugt genau einen Fehlversuch (E7)', () {
    const sicher = FlutterSecureStorage();

    void gespeichert(String kennung, {String passwort = 'altes-passwort'}) {
      final suffix = kennung == Profil.standardKennung ? '' : '.$kennung';
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({
        'anmeldung.merken$suffix': true,
        'anmeldung.benutzer$suffix': 'e.mustermann',
      });
      // ignore: invalid_use_of_visible_for_testing_member
      FlutterSecureStorage.setMockInitialValues({'moodle.passwort$suffix': passwort});
    }

    testWidgets('der Start versucht es einmal, verwirft das Passwort, und Profilwechsel melden nicht wieder an', (tester) async {
      gespeichert(Profil.standardKennung);
      final a = await starten(tester, [standard, test], ablehnen: [true, false]);

      expect((a.instanzen[0].moodle as _Zugang).versuche, 1, reason: 'der Start meldet mit dem gespeicherten Passwort an');
      expect(await sicher.read(key: 'moodle.passwort'), isNull, reason: 'abgelehnt: verworfen');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('anmeldung.merken'), isTrue, reason: 'Haken und Benutzername bleiben');
      expect(prefs.getString('anmeldung.benutzer'), 'e.mustermann');
      final texte = a.protokoll.eintraege.map((e) => e.text).join('\n');
      expect(texte, contains('Gespeichertes Passwort verworfen'));
      expect(texte, isNot(contains('altes-passwort')));

      // Wechsel zum anderen Profil und zurück: kein zweiter Fehlversuch.
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Moodle Test (moodle-test)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Moodle (moodle)').last);
      await tester.pumpAndSettle();
      expect((a.instanzen[0].moodle as _Zugang).versuche, 1, reason: 'ohne neues Passwort meldet der Wechsel nicht an');
    });

    testWidgets('der Start meldet auch das nicht sichtbare Profil an und verwirft dessen Passwort, wenn Moodle es ablehnt', (tester) async {
      gespeichert('k2', passwort: 'veraltet');
      final a = await starten(tester, [standard, test], ablehnen: [false, true]);
      expect((a.instanzen[1].moodle as _Zugang).versuche, 1, reason: 'der Start meldet jedes Profil mit gespeicherten Anmeldedaten an');
      expect(await sicher.read(key: 'moodle.passwort.k2'), isNull, reason: 'abgelehnt: verworfen');

      Future<void> wechseln(String eintrag) async {
        await tester.tap(find.byType(DropdownButtonFormField<int>));
        await tester.pumpAndSettle();
        await tester.tap(find.text(eintrag).last);
        await tester.pumpAndSettle();
      }

      await wechseln('Moodle Test (moodle-test)');
      await wechseln('Moodle (moodle)');
      await wechseln('Moodle Test (moodle-test)');
      expect((a.instanzen[1].moodle as _Zugang).versuche, 1, reason: 'jeder Wechsel wäre ein weiterer Fehlversuch');
    });
  });

  group('Der Dialog „KI-Werkzeuge einrichten" schreibt den Schlüssel des Profils', () {
    late Directory heim;
    setUp(() => heim = Directory.systemTemp.createTempSync('moocp_einrichtung_'));
    tearDown(() => heim.deleteSync(recursive: true));

    testWidgets('ein Eintrag mit dem Schlüssel eines anderen Profils ist veraltet, „Installieren" erneuert ihn', (tester) async {
      // USERPROFILE gilt unter Windows, HOME auf dem Mac.
      final env = {'USERPROFILE': heim.path, 'HOME': heim.path};
      final codex = CodexCli(env);
      // Ein Eintrag aus der Zeit, als alle Profile den globalen Schlüssel teilten.
      expect(await codex.eintragen(47812, 'global', name: 'moodle-test'), isNull);

      Future<Einrichtungsstand> pruefen() => einrichtungPruefen(
            umgebung: env,
            port: 47812,
            schluessel: 'eigener',
            name: 'moodle-test',
            skills: const [],
            wahlSkills: const {},
            gefunden: [codex],
          );
      final stand = await pruefen();
      expect(stand.werkzeuge.single.verbindung, Verbindung.veraltet);

      await tester.pumpWidget(MaterialApp(
        home: EinrichtungDialog(
          stand: stand,
          pruefen: pruefen,
          einstellungen: Einstellungen(schluessel: 'global'),
          protokoll: Protokoll(),
          port: 47812,
          schluessel: 'eigener',
          servername: 'moodle-test',
          profilname: 'Moodle Test',
        ),
      ));
      expect(find.text('Moodle Test (moodle-test) — KI-Werkzeuge einrichten'), findsOneWidget);
      await tester.tap(find.text('Aktualisieren'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();

      final toml = File(p.join(heim.path, '.codex', 'config.toml')).readAsStringSync();
      expect(toml, contains('[mcp_servers.moodle-test]'));
      expect(toml, contains('Bearer eigener'));
      expect(toml, isNot(contains('Bearer global')));
      expect((await pruefen()).werkzeuge.single.verbindung, Verbindung.aktuell);
    });
  });

  // Die wählbaren Skills im Dialog: Haken nur für sie, mit ihrer Beschreibung;
  // „Installieren" richtet nur das Gewählte ein und entfernt das Abgewählte.
  group('Der Dialog „KI-Werkzeuge einrichten": wählbare Skills', () {
    const beschreibung = 'Für berufsbildende Schulen: Lernsituationen mit SchuCu-Tabelle, Ablaufplan, Arbeits- '
        'und Informationsblättern entwerfen.';
    late Directory heim;
    late Map<String, String> env;
    late CodexCli codex;
    late _EinstellungenOhneDatei einstellungen;
    final moodle = SkillPaket('moodle', {'SKILL.md': utf8.encode('Kurs')}, herkunft: SkillHerkunft.app);
    final lernsituation =
        SkillPaket('lernsituation', {'SKILL.md': utf8.encode('Lernsituation')}, herkunft: SkillHerkunft.app);
    Directory skillOrdner(String name) => Directory(p.join(codex.skillOrdner.path, name));
    final haken = find.widgetWithText(CheckboxListTile, 'Skill lernsituation');

    // Codex mit Verbindung und dem festen Skill moodle: Es fehlt nichts außer dem, was gewählt wird.
    Future<void> aufbauen(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1600);
      addTearDown(tester.view.reset);
      heim = Directory.systemTemp.createTempSync('moocp_wahlskills_');
      addTearDown(() => heim.deleteSync(recursive: true));
      env = {'USERPROFILE': heim.path, 'HOME': heim.path};
      codex = CodexCli(env);
      expect(await codex.eintragen(47811, 'abc'), isNull);
      expect(skillInstallieren(moodle, skillOrdner('moodle')), isEmpty);
      einstellungen = _EinstellungenOhneDatei(schluessel: 'abc');
    }

    // Wie die App prüft: die gespeicherte Wahl, solange es eine gibt.
    Future<Einrichtungsstand> pruefen() => einrichtungPruefen(
          umgebung: env,
          port: 47811,
          schluessel: 'abc',
          skills: [moodle, lernsituation],
          wahlSkills: appWahlSkills,
          gewaehlt: einstellungen.wahlSkills ?? const {},
          gefunden: [codex],
        );

    Future<void> zeigen(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: EinrichtungDialog(
          stand: await pruefen(),
          pruefen: pruefen,
          einstellungen: einstellungen,
          protokoll: Protokoll(),
          port: 47811,
          schluessel: 'abc',
        ),
      ));
    }

    Future<void> abwarten(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
    }

    testWidgets('jedes Werkzeug sagt, wo die Verbindung wirkt, im Dialog und im Abschluss', (tester) async {
      await aufbauen(tester);
      await zeigen(tester);

      const text = 'Wirkt in Codex und in Codex-Sitzungen der ChatGPT-App, nicht im normalen Chat der App.';
      expect(find.text(text), findsOneWidget, reason: 'unter dem Namen des Werkzeugs');
      expect(find.text('Verbindung und Skills sind aktuell.'), findsOneWidget);
      expect(find.text('Codex CLI: $text'), findsOneWidget, reason: 'und im Abschluss');
      expect(ClaudeCode(const {}).wirkt,
          'Wirkt in Claude Code und im Reiter „Code“ von Claude Desktop, nicht im normalen Chat.');
      expect(LmStudio(const {}, bruecke: 'b').wirkt, 'Wirkt im Agenten Bionic, nicht im klassischen LM Studio.');
    });

    testWidgets('nur der wählbare Skill hat einen Haken mit seiner Beschreibung, vorgegeben aus', (tester) async {
      await aufbauen(tester);
      await zeigen(tester);

      expect(find.text('Wählbare Skills'), findsOneWidget);
      expect(find.text(beschreibung), findsOneWidget);
      expect(find.widgetWithText(CheckboxListTile, 'Skill moodle'), findsNothing);
      expect(tester.widget<CheckboxListTile>(haken).value, isFalse);
      expect(find.text('Skills (moodle)'), findsOneWidget, reason: 'gewollt ist nur der feste Skill');
      expect(find.text('Verbindung und Skills sind aktuell.'), findsOneWidget);
    });

    // Steht schon etwas von der App in einem KI-Werkzeug, heißt der Knopf
    // „Aktualisieren" (die Tests unten); nur beim ersten Einrichten
    // „Installieren".
    testWidgets('beim ersten Einrichten, ohne Eintrag und ohne Skills, heißt der Knopf „Installieren"', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1600);
      addTearDown(tester.view.reset);
      heim = Directory.systemTemp.createTempSync('moocp_erstes_einrichten_');
      addTearDown(() => heim.deleteSync(recursive: true));
      env = {'USERPROFILE': heim.path, 'HOME': heim.path};
      codex = CodexCli(env);
      einstellungen = _EinstellungenOhneDatei(schluessel: 'abc');
      await zeigen(tester);

      expect(find.text('Installieren'), findsOneWidget);
      expect(find.text('Aktualisieren'), findsNothing);
    });

    testWidgets('Wählen speichert die Wahl, „Installieren" richtet ihn ein; Abwählen und „Installieren" entfernt ihn',
        (tester) async {
      await aufbauen(tester);
      await zeigen(tester);

      await tester.tap(haken);
      await abwarten(tester);
      expect(einstellungen.wahlSkills, {'lernsituation'});
      expect(einstellungen.gespeichert, 1);
      expect(find.text('Skills (moodle, lernsituation)'), findsOneWidget);
      expect(find.text('nicht installiert: lernsituation'), findsOneWidget);

      await tester.tap(find.text('Aktualisieren'));
      await abwarten(tester);
      expect(File(p.join(skillOrdner('lernsituation').path, 'SKILL.md')).existsSync(), isTrue);
      expect(find.text('erledigt – installiert: lernsituation'), findsOneWidget, reason: 'die Zeile sagt, was geschehen ist');
      expect(find.text('Eingerichtet. Im KI-Werkzeug eine neue Sitzung starten, damit die Änderungen wirken.'),
          findsOneWidget);

      await tester.tap(haken);
      await abwarten(tester);
      expect(einstellungen.wahlSkills, isEmpty);
      expect(einstellungen.gespeichert, 2);
      expect(find.text('werden entfernt: lernsituation'), findsOneWidget);

      await tester.tap(find.text('Aktualisieren'));
      await abwarten(tester);
      expect(skillOrdner('lernsituation').existsSync(), isFalse);
      expect(find.text('erledigt – entfernt: lernsituation'), findsOneWidget);
      expect(File(p.join(skillOrdner('moodle').path, 'SKILL.md')).existsSync(), isTrue, reason: 'der feste bleibt');
    });

    testWidgets('Skills eines Plugins: wählbar mit Plugin und Beschreibung, Verwaistes wird entfernt, '
        'ein unbrauchbares Paket nur genannt', (tester) async {
      await aufbauen(tester);
      final pflicht = SkillPaket('beispiel', {'SKILL.md': utf8.encode('Beispiel')},
          herkunft: SkillHerkunft.plugin, plugin: 'Beispiel');
      final wahl = SkillPaket('beispiel-vorlage', {'SKILL.md': utf8.encode('Vorlage')},
          herkunft: SkillHerkunft.plugin, plugin: 'Beispiel');
      expect(skillInstallieren(SkillPaket('alt-skill', {'SKILL.md': utf8.encode('Alt')}, herkunft: SkillHerkunft.plugin),
          skillOrdner('alt-skill')), isEmpty);
      const fehler = 'Plugin „Beispiel“: Der Skill beispiel-fehlt wird nicht installiert: '
          'Der Ordner skills/beispiel-fehlt fehlt im Plugin-Ordner.';
      Future<Einrichtungsstand> mitPlugin() => einrichtungPruefen(
            umgebung: env,
            port: 47811,
            schluessel: 'abc',
            skills: [moodle, lernsituation, pflicht, wahl],
            wahlSkills: {...appWahlSkills, 'beispiel-vorlage': 'Eine Vorlage zum Ausprobieren.'},
            gewaehlt: einstellungen.wahlSkills ?? const {},
            verwaist: const {'alt-skill'},
            // In Codex hat moocp ihn installiert; nur dort wird er entfernt.
            pluginSkills: const {'codex/alt-skill'},
            skillFehler: const [fehler],
            gefunden: [codex],
          );
      await tester.pumpWidget(MaterialApp(
        home: EinrichtungDialog(
          stand: await mitPlugin(),
          pruefen: mitPlugin,
          einstellungen: einstellungen,
          protokoll: Protokoll(),
          port: 47811,
          schluessel: 'abc',
        ),
      ));

      final pluginHaken = find.widgetWithText(CheckboxListTile, 'Skill beispiel-vorlage (Plugin „Beispiel“)');
      expect(pluginHaken, findsOneWidget);
      expect(find.text('Eine Vorlage zum Ausprobieren.'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(pluginHaken).value, isFalse);
      expect(find.text(fehler), findsOneWidget);
      expect(find.text('nicht installiert: beispiel; werden entfernt: alt-skill'), findsOneWidget);

      await tester.tap(find.text('Aktualisieren'));
      await abwarten(tester);
      expect(File(p.join(skillOrdner('beispiel').path, 'SKILL.md')).existsSync(), isTrue);
      expect(skillOrdner('beispiel-vorlage').existsSync(), isFalse);
      expect(skillOrdner('alt-skill').existsSync(), isFalse);
      expect(find.text('Verbindung und Skills sind aktuell.'), findsNothing);
      expect(find.text('Eingerichtet. Im KI-Werkzeug eine neue Sitzung starten, damit die Änderungen wirken.'),
          findsOneWidget, reason: 'das unbrauchbare Paket hält nichts auf');
    });

    testWidgets('ein ungesehenes unbrauchbares Paket bei sonst fertiger Einrichtung: nur „Weiter"', (tester) async {
      await aufbauen(tester);
      const fehler = 'Plugin „Beispiel“: Der Skill beispiel-fehlt wird nicht installiert: '
          'Der Ordner skills/beispiel-fehlt fehlt im Plugin-Ordner.';
      Future<Einrichtungsstand> mitFehler() => einrichtungPruefen(
            umgebung: env,
            port: 47811,
            schluessel: 'abc',
            skills: [moodle],
            wahlSkills: const {},
            skillFehler: const [fehler],
            skillFehlerNeu: true,
            gefunden: [codex],
          );
      final stand = await mitFehler();
      expect(stand.brauchtEtwas, isTrue, reason: 'der Dialog erscheint beim Start');
      bool? ergebnis;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => ergebnis = await showDialog<bool>(
              context: context,
              builder: (_) => EinrichtungDialog(
                stand: stand,
                pruefen: mitFehler,
                einstellungen: einstellungen,
                protokoll: Protokoll(),
                port: 47811,
                schluessel: 'abc',
              ),
            ),
            child: const Text('öffnen'),
          ),
        ),
      ));
      await tester.tap(find.text('öffnen'));
      await tester.pumpAndSettle();

      expect(find.text(fehler), findsOneWidget);
      expect(find.text('Beenden'), findsNothing);
      expect(find.text('Installieren'), findsNothing);
      expect(find.text('Aktualisieren'), findsNothing);
      expect(find.textContaining('mit „Weiter" arbeitet die App ohne sie'), findsOneWidget);
      await tester.tap(find.text('Weiter'));
      await tester.pumpAndSettle();
      expect(ergebnis, isTrue);
    });
  });

  group('Freigabedialog', () {
    testWidgets('nennt das Profil nur, wenn es mehrere gibt', (tester) async {
      final f = Freigaben(Protokoll());
      unawaited(f.anfragen(FreigabeAnfrage(titel: 'Änderung speichern?', punkte: const [], vergleich: const [])));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: FreigabeDialog(f.aktuell!, f))));
      expect(find.text('Änderung speichern?'), findsOneWidget);
      expect(find.textContaining('(moodle'), findsNothing);

      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: FreigabeDialog(f.aktuell!, f, profilname: 'Moodle Test', mcpName: 'moodle-test'))));
      expect(find.text('Moodle Test (moodle-test)'), findsOneWidget);

      // Die Frist läuft sonst weiter und hielte den Test an.
      f.entscheiden(false);
      await tester.pumpAndSettle();
    });
  });

  group('Plugins: Dialog „Plugin zulassen“', () {
    final zweiProfile = [standard, test];

    /// Zeigt den Dialog wie die App: als Dialog über einer Seite.
    Future<_Antwort> zeigen(
      WidgetTester tester,
      PluginEintrag eintrag,
      List<Profil> profile, {
      Set<String>? vorgewaehlt,
    }) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final antwort = _Antwort();
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showDialog<PluginAntwort>(
                context: context,
                barrierDismissible: false,
                builder: (_) => PluginZustimmungDialog(eintrag: eintrag, profile: profile, vorgewaehlt: vorgewaehlt),
              ).then((w) {
                antwort.wert = w;
                antwort.fertig = true;
              }),
              child: const Text('öffnen'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('öffnen'));
      await tester.pumpAndSettle();
      return antwort;
    }

    testWidgets('nennt Name, Version, Herkunft, jede Zusatzadresse mit Art und Grund und den Satz zur Verantwortung',
        (tester) async {
      await zeigen(tester, _pluginEintrag(adressen: [_lesen, _schreiben]), [standard]);

      expect(find.text('Plugin zulassen'), findsOneWidget);
      expect(find.text('Beispiel-Plugin'), findsOneWidget);
      expect(find.text('Version 1.0'), findsOneWidget);
      expect(find.text('Herkunft laut Plugin: Beispiel-Projekt'), findsOneWidget);
      expect(find.text('Zusatzadressen'), findsOneWidget);
      for (final text in [
        'lesen',
        '/mod/beispiel/*',
        'Liest die Seiten der Aktivität.',
        'schreiben',
        '/mod/beispiel/save.php',
        'Speichert die Einstellungen.',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(find.textContaining('Die Zusagen von moocp gelten für moocp und für alles, was durch moocp zu Moodle geht.'),
          findsOneWidget);
      expect(find.textContaining('Für die Fehler des Plugins, für Schäden und für seine eigenen Datenwege steht sein Autor ein'),
          findsOneWidget);
      expect(find.textContaining('moocp gibt dafür keine Gewähr'), findsOneWidget);
      expect(find.textContaining('genau diese Version'), findsOneWidget);
    });

    testWidgets('der Satz zur Verantwortung steht auch ohne Zusatzadressen jedes Mal da', (tester) async {
      await zeigen(tester, _pluginEintrag(), [standard]);
      expect(find.textContaining('Zusatzadressen: keine'), findsOneWidget);
      expect(find.textContaining('moocp gibt dafür keine Gewähr'), findsOneWidget);
    });

    testWidgets('in der Wartezeit nimmt kein Knopf etwas an; danach entscheidet die Maus', (tester) async {
      final antwort = await zeigen(tester, _pluginEintrag(), [standard]);

      await tester.tap(find.text('Zustimmen'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(antwort.fertig, isFalse, reason: 'Klick in der Wartezeit');
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Zustimmen')).onPressed, isNull);

      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Zustimmen'));
      await tester.pumpAndSettle();
      expect(antwort.fertig, isTrue);
      expect(antwort.wert!.zugestimmt, isTrue);
    });

    testWidgets('Return, Enter, Leertaste und Escape entscheiden nichts, auch nicht auf dem Knopf mit dem Fokus',
        (tester) async {
      final antwort = await zeigen(tester, _pluginEintrag(), [standard]);
      await tester.pump(Sperrzeit.dauerVorgabe);
      final knopf = find.widgetWithText(FilledButton, 'Zustimmen');
      Focus.of(tester.element(find.descendant(of: knopf, matching: find.text('Zustimmen')))).requestFocus();
      await tester.pump();
      for (final taste in [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.escape,
      ]) {
        await tester.sendKeyEvent(taste);
        await tester.pumpAndSettle();
      }
      await tabUndTasten(tester, ['Zustimmen', 'Ablehnen']);
      expect(antwort.fertig, isFalse);
      expect(find.text('Plugin zulassen'), findsOneWidget, reason: 'der Dialog ist noch offen');

      await tester.tap(find.text('Ablehnen'));
      await tester.pumpAndSettle();
      expect(antwort.wert!.zugestimmt, isFalse, reason: 'mit der Maus geht es');
    });

    testWidgets('mit nur einem Profil gibt es keine Auswahl; die Zustimmung gilt für dieses Profil', (tester) async {
      final antwort = await zeigen(tester, _pluginEintrag(), [standard]);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.textContaining('Moodle-Instanz'), findsNothing);
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Zustimmen'));
      await tester.pumpAndSettle();
      expect(antwort.wert!.profile, {Profil.standardKennung});
    });

    testWidgets('mit zwei Profilen sind alle vorgewählt, und die Lehrkraft wählt ab', (tester) async {
      final antwort = await zeigen(tester, _pluginEintrag(), zweiProfile);
      final eins = find.widgetWithText(CheckboxListTile, 'Moodle (moodle)');
      final zwei = find.widgetWithText(CheckboxListTile, 'Moodle Test (moodle-test)');
      expect(tester.widget<CheckboxListTile>(eins).value, isTrue);
      expect(tester.widget<CheckboxListTile>(zwei).value, isTrue);

      await tester.tap(zwei);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(zwei).value, isFalse);
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Zustimmen'));
      await tester.pumpAndSettle();
      expect(antwort.wert!.zugestimmt, isTrue);
      expect(antwort.wert!.profile, {Profil.standardKennung});
    });

    testWidgets('Ablehnen gibt keine Profile weiter', (tester) async {
      final antwort = await zeigen(tester, _pluginEintrag(), zweiProfile);
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Ablehnen'));
      await tester.pumpAndSettle();
      expect(antwort.wert!.zugestimmt, isFalse);
      expect(antwort.wert!.profile, isEmpty);
    });

    testWidgets('beim Ändern einer Zustimmung ist vorgewählt, was eingeschaltet war', (tester) async {
      await zeigen(tester, _pluginEintrag(), zweiProfile, vorgewaehlt: {'k2'});
      expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Moodle (moodle)')).value, isFalse);
      expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Moodle Test (moodle-test)')).value, isTrue);
    });
  });

  group('Plugins: Start und Einstellungen', () {
    final zweiProfile = [standard, test];

    testWidgets('ohne Plugins ändert sich nichts: keine Frage, kein Eintrag in den Einstellungen', (tester) async {
      final ablauf = <String>[];
      await starten(tester, [standard], ablauf: ablauf);
      expect(find.text('Plugin zulassen'), findsNothing);
      expect(ablauf, ['einrichtung']);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Einstellungen'), findsOneWidget);
      expect(find.text('Plugins'), findsNothing);
      expect(find.text('Plugins ansehen und ändern …'), findsNothing);
    });

    testWidgets('ein Plugin ohne Entscheidung: Der Dialog kommt vor der Einrichtung, die Zustimmung wird gespeichert',
        (tester) async {
      final ablauf = <String>[];
      final a = await starten(tester, [standard], plugins: [_pluginEintrag()], ablauf: ablauf);
      expect(find.text('Plugin zulassen'), findsOneWidget);
      expect(ablauf, ['plugins'], reason: 'die Einrichtung wartet auf die Entscheidung');
      expect(a.einstellungen.plugins, isEmpty, reason: 'auch im Testbetrieb stimmt nichts von selbst zu');

      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Zustimmen'));
      await tester.pumpAndSettle();
      expect(find.text('Plugin zulassen'), findsNothing);
      expect(ablauf, ['plugins', 'einrichtung']);
      expect(a.einstellungen.plugins['beispiel']!.zugestimmt, isTrue);
      expect(a.einstellungen.plugins['beispiel']!.profile, {Profil.standardKennung});
      expect(a.einstellungen.gespeichert, greaterThan(0));
    });

    testWidgets('Ablehnen wird gespeichert, die App läuft ohne das Plugin weiter', (tester) async {
      final ablauf = <String>[];
      final a = await starten(tester, [standard], plugins: [_pluginEintrag()], ablauf: ablauf);
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Ablehnen'));
      await tester.pumpAndSettle();
      expect(a.einstellungen.plugins['beispiel']!.zugestimmt, isFalse);
      expect(ablauf, ['plugins', 'einrichtung']);
      expect(find.text('Moodle-Anmeldung'), findsOneWidget);
    });

    for (final ja in [true, false]) {
      testWidgets('eine gespeicherte ${ja ? 'Zustimmung' : 'Ablehnung'} für diesen Stand fragt nicht noch einmal', (tester) async {
        final ablauf = <String>[];
        await starten(tester, [standard],
            plugins: [_pluginEintrag()], entscheidungen: {'beispiel': _zugestimmt({Profil.standardKennung}, ja: ja)}, ablauf: ablauf);
        expect(find.text('Plugin zulassen'), findsNothing);
        expect(ablauf, ['plugins', 'einrichtung']);
      });
    }

    testWidgets('eine neue Version fragt neu', (tester) async {
      await starten(tester, [standard],
          plugins: [_pluginEintrag(version: '1.1')], entscheidungen: {'beispiel': _zugestimmt({Profil.standardKennung})});
      expect(find.text('Plugin zulassen'), findsOneWidget);
      expect(find.text('Version 1.1'), findsOneWidget);
    });

    testWidgets('ein Plugin, das nicht lädt, kommt nicht in den Dialog; die App läuft weiter', (tester) async {
      final ablauf = <String>[];
      await starten(tester, [standard], plugins: [_pluginEintrag(fehler: 'Die Beschreibungsdatei plugin.json fehlt.')], ablauf: ablauf);
      expect(find.text('Plugin zulassen'), findsNothing);
      expect(ablauf, ['plugins', 'einrichtung']);
    });

    testWidgets('mehrere offene Plugins kommen nacheinander', (tester) async {
      final a = await starten(tester, [standard], plugins: [_pluginEintrag(ordner: 'a'), _pluginEintrag(ordner: 'b')]);
      for (final ordner in ['a', 'b']) {
        expect(find.text('Plugin zulassen'), findsOneWidget);
        await tester.pump(Sperrzeit.dauerVorgabe);
        await tester.tap(find.text(ordner == 'a' ? 'Zustimmen' : 'Ablehnen'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Plugin zulassen'), findsNothing);
      expect(a.einstellungen.plugins['a']!.zugestimmt, isTrue);
      expect(a.einstellungen.plugins['b']!.zugestimmt, isFalse);
    });

    testWidgets('Einstellungen: „Plugins“ erscheint, wenn es welche gibt, und zeigt den Stand ohne Profilauswahl', (tester) async {
      await starten(tester, [standard],
          plugins: [_pluginEintrag()], entscheidungen: {'beispiel': _zugestimmt({Profil.standardKennung})});
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Plugins'), findsOneWidget);
      await tester.tap(find.text('Plugins ansehen und ändern …'));
      await tester.pumpAndSettle();

      expect(find.text('Beispiel-Plugin'), findsOneWidget);
      expect(find.text('Version 1.0'), findsOneWidget);
      expect(find.text('Zugestimmt'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing, reason: 'mit einem Profil gibt es keine Auswahl');
    });

    testWidgets('die Zustimmung ändern öffnet denselben Dialog: nur mit der Maus, nach der Wartezeit', (tester) async {
      final a = await starten(tester, [standard],
          plugins: [_pluginEintrag()], entscheidungen: {'beispiel': _zugestimmt({Profil.standardKennung})});
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plugins ansehen und ändern …'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Zustimmung ändern …'));
      await tester.pumpAndSettle();
      expect(find.text('Plugin zulassen'), findsOneWidget);
      await tester.tap(find.text('Ablehnen'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Plugin zulassen'), findsOneWidget, reason: 'Klick in der Wartezeit');
      expect(a.einstellungen.plugins['beispiel']!.zugestimmt, isTrue);

      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Ablehnen'));
      await tester.pumpAndSettle();
      expect(find.text('Plugin zulassen'), findsNothing);
      expect(find.text('Abgelehnt'), findsOneWidget);
      expect(a.einstellungen.plugins['beispiel']!.zugestimmt, isFalse);
      expect(a.einstellungen.plugins['beispiel']!.profile, isEmpty);
    });

    testWidgets('mit zwei Profilen lässt sich das Plugin je Profil ein- und ausschalten, ohne neue Zustimmung', (tester) async {
      final a = await starten(tester, zweiProfile,
          plugins: [_pluginEintrag()], entscheidungen: {'beispiel': _zugestimmt({Profil.standardKennung, 'k2'})});
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plugins ansehen und ändern …'));
      await tester.pumpAndSettle();

      final zwei = find.widgetWithText(CheckboxListTile, 'Moodle Test (moodle-test)');
      expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Moodle (moodle)')).value, isTrue);
      expect(tester.widget<CheckboxListTile>(zwei).value, isTrue);
      final vorher = a.einstellungen.gespeichert;

      await tester.tap(zwei);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(zwei).value, isFalse);
      expect(a.einstellungen.plugins['beispiel']!.profile, {Profil.standardKennung});
      expect(a.einstellungen.plugins['beispiel']!.zugestimmt, isTrue);
      expect(a.einstellungen.gespeichert, vorher + 1);
      expect(find.text('Plugin zulassen'), findsNothing, reason: 'Ein- und Ausschalten fragt nicht neu');

      await tester.tap(zwei);
      await tester.pumpAndSettle();
      expect(a.einstellungen.plugins['beispiel']!.profile, {Profil.standardKennung, 'k2'});
    });

    testWidgets('ein abgelehntes Plugin ist in keinem Profil einzuschalten; „Zustimmung ändern“ bleibt der Weg', (tester) async {
      await starten(tester, zweiProfile,
          plugins: [_pluginEintrag()], entscheidungen: {'beispiel': _zugestimmt(const {}, ja: false)});
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plugins ansehen und ändern …'));
      await tester.pumpAndSettle();
      expect(find.text('Abgelehnt'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text('Zustimmung ändern …'), findsOneWidget);
    });

    testWidgets('ein Plugin, das nicht lädt, steht mit dem Grund da und lässt sich nicht annehmen', (tester) async {
      await starten(tester, [standard], plugins: [_pluginEintrag(fehler: 'Die Beschreibungsdatei plugin.json fehlt.')]);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plugins ansehen und ändern …'));
      await tester.pumpAndSettle();
      expect(find.text('Wird nicht geladen'), findsOneWidget);
      expect(find.text('Die Beschreibungsdatei plugin.json fehlt.'), findsOneWidget);
      expect(find.text('Zustimmung ändern …'), findsNothing);
      expect(find.text('Entscheiden …'), findsNothing);
    });

    testWidgets('je Plugin lässt sich die Update-Prüfung abschalten, gespeichert in den Einstellungen', (tester) async {
      final a = await starten(tester, [standard],
          plugins: [_pluginEintrag(quellen: ['beispiel-org/beispiel-plugin'])],
          entscheidungen: {'beispiel': _zugestimmt({Profil.standardKennung})});
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plugins ansehen und ändern …'));
      await tester.pumpAndSettle();

      final schalter = find.byKey(const Key('plugin-update-beispiel'));
      expect(tester.widget<CheckboxListTile>(schalter).value, isTrue, reason: 'vorgegeben ist an');
      expect(find.textContaining('beispiel-org/beispiel-plugin'), findsOneWidget);
      final vorher = a.einstellungen.gespeichert;
      await tester.tap(schalter);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(schalter).value, isFalse);
      expect(a.einstellungen.pluginUpdates['beispiel']?.aus, isTrue);
      expect(a.einstellungen.gespeichert, vorher + 1);
      expect(find.text('Plugin zulassen'), findsNothing, reason: 'der Schalter fragt nicht nach der Zustimmung');
    });

    testWidgets('ohne Update-Quellen gibt es keinen Schalter', (tester) async {
      await starten(tester, [standard],
          plugins: [_pluginEintrag()], entscheidungen: {'beispiel': _zugestimmt({Profil.standardKennung})});
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plugins ansehen und ändern …'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plugin-update-beispiel')), findsNothing);
    });

    testWidgets('passt die Schnittstelle nicht, sagt es ein Dialog vor der Zustimmung; das Plugin bleibt aus', (tester) async {
      final ablauf = <String>[];
      final a = await starten(tester, [standard], plugins: [_pluginEintrag(schnittstelle: 2)], ablauf: ablauf);
      expect(find.text('Plugin „Beispiel-Plugin“ bleibt aus'), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('moocp ist zu alt')),
          findsOneWidget);
      expect(find.text('Plugin zulassen'), findsNothing);
      expect(ablauf, ['plugins'], reason: 'die Einrichtung wartet');

      await tester.tap(find.text('Ohne das Plugin weiter'));
      await tester.pumpAndSettle();
      expect(find.text('Plugin zulassen'), findsNothing, reason: 'ein unpassendes Plugin wird nicht gefragt');
      expect(ablauf, ['plugins', 'einrichtung']);
      expect(a.einstellungen.plugins, isEmpty);
    });
  });

  group('Plugins: Entwicklungs-Plugin anhängen', () {
    /// Zeigt den Dialog wie die App: als Dialog über einer Seite.
    Future<_EntwicklungsAntwort> zeigen(WidgetTester tester, EntwicklungsPlugin plugin) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final antwort = _EntwicklungsAntwort();
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => EntwicklungsPluginDialog(plugin: plugin),
              ).then((w) {
                antwort.wert = w;
                antwort.fertig = true;
              }),
              child: const Text('öffnen'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('öffnen'));
      await tester.pumpAndSettle();
      return antwort;
    }

    testWidgets('nennt Ordner, Port, Name und Zusatzadressen, warnt vor dem fremden Programm, nie den Schlüssel',
        (tester) async {
      await zeigen(tester, _entwicklungsPlugin(adressen: [_lesen, _schreiben]));

      expect(find.text('Entwicklungs-Plugin anhängen'), findsOneWidget);
      expect(find.text('Beispiel-Plugin'), findsOneWidget);
      expect(find.text(r'Ordner: C:\Entwicklung\beispiel'), findsOneWidget);
      expect(find.text('Port: 127.0.0.1:47900'), findsOneWidget);
      for (final text in [
        'lesen',
        '/mod/beispiel/*',
        'Liest die Seiten der Aktivität.',
        'schreiben',
        '/mod/beispiel/save.php',
        'Speichert die Einstellungen.',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(find.textContaining('außerhalb der Installation von moocp'), findsOneWidget);
      expect(find.textContaining('nur an, wenn Sie es selbst so gestartet haben'), findsOneWidget);
      expect(find.textContaining('Ein fremdes Programm'), findsOneWidget);
      expect(find.textContaining('wird nicht gespeichert'), findsOneWidget);
      expect(find.textContaining('moocp gibt dafür keine Gewähr'), findsOneWidget);
      expect(find.textContaining('geheimer-schluessel'), findsNothing);
    });

    testWidgets('in der Wartezeit nimmt kein Knopf etwas an; Tasten entscheiden nie, die Maus danach schon', (tester) async {
      final antwort = await zeigen(tester, _entwicklungsPlugin());

      await tester.tap(find.text('Anhängen'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(antwort.fertig, isFalse, reason: 'Klick in der Wartezeit');
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Anhängen')).onPressed, isNull);

      await tester.pump(Sperrzeit.dauerVorgabe);
      final knopf = find.widgetWithText(FilledButton, 'Anhängen');
      Focus.of(tester.element(find.descendant(of: knopf, matching: find.text('Anhängen')))).requestFocus();
      await tester.pump();
      for (final taste in [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.escape,
      ]) {
        await tester.sendKeyEvent(taste);
        await tester.pumpAndSettle();
      }
      await tabUndTasten(tester, ['Anhängen', 'Ablehnen']);
      expect(antwort.fertig, isFalse);
      expect(find.text('Entwicklungs-Plugin anhängen'), findsOneWidget);

      await tester.tap(find.text('Anhängen'));
      await tester.pumpAndSettle();
      expect(antwort.wert, isTrue);
    });

    testWidgets('beim Start: der Dialog vor der Einrichtung; angenommen hängt die App an, gespeichert wird nichts',
        (tester) async {
      final ablauf = <String>[];
      final laufende = _Laufende(Protokoll());
      final a = await starten(tester, [standard], entwicklung: _entwicklungsPlugin, laufende: laufende, ablauf: ablauf);
      expect(find.text('Entwicklungs-Plugin anhängen'), findsOneWidget);
      expect(ablauf, ['entwicklung'], reason: 'die Einrichtung wartet auf die Entscheidung');
      expect(laufende.angehaengt, isEmpty, reason: 'ohne Antwort keine Verbindung, auch nicht im Testbetrieb');

      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Anhängen'));
      await tester.pumpAndSettle();
      // Die Namen der eingebauten Werkzeuge ermittelt die App echt asynchron.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();

      expect(find.text('Entwicklungs-Plugin anhängen'), findsNothing);
      expect(ablauf, ['entwicklung', 'einrichtung']);
      expect(laufende.angehaengt.single.name, 'Beispiel-Plugin');
      expect(a.einstellungen.gespeichert, 0);
      expect(a.einstellungen.plugins, isEmpty);
      final zeilen = [for (final e in a.protokoll.eintraege) e.text];
      expect(zeilen, contains(r'Entwicklungs-Plugin angefragt: „Beispiel-Plugin“ aus C:\Entwicklung\beispiel, Port 47900'));
      expect(zeilen, contains('Entwicklungs-Plugin „Beispiel-Plugin“: angenommen, für diesen Lauf'));
      expect(zeilen.join('\n'), isNot(contains('geheimer-schluessel')));
    });

    testWidgets('abgelehnt: keine Verbindung, nichts gespeichert, die App läuft ohne das Plugin weiter', (tester) async {
      final ablauf = <String>[];
      final laufende = _Laufende(Protokoll());
      final a = await starten(tester, [standard], entwicklung: _entwicklungsPlugin, laufende: laufende, ablauf: ablauf);

      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Ablehnen'));
      await tester.pumpAndSettle();

      expect(laufende.angehaengt, isEmpty);
      expect(ablauf, ['entwicklung', 'einrichtung']);
      expect(find.text('Moodle-Anmeldung'), findsOneWidget);
      expect(a.einstellungen.gespeichert, 0);
      expect(
        [for (final e in a.protokoll.eintraege) e.text],
        contains('Entwicklungs-Plugin „Beispiel-Plugin“: abgelehnt; moocp läuft ohne es'),
      );
    });

    testWidgets('ein Fehler davor, etwa ohne Schlüssel: ein Hinweis mit dem Grund, kein Dialog, keine Verbindung',
        (tester) async {
      final ablauf = <String>[];
      final laufende = _Laufende(Protokoll());
      final a = await starten(
        tester,
        [standard],
        entwicklung: () => throw const PluginFehler('Die Umgebungsvariable fehlt.'),
        laufende: laufende,
        ablauf: ablauf,
      );

      expect(find.text('Entwicklungs-Plugin nicht angehängt'), findsOneWidget);
      expect(find.textContaining('Die Umgebungsvariable fehlt. moocp läuft ohne dieses Plugin.'), findsOneWidget);
      expect(find.text('Entwicklungs-Plugin anhängen'), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(laufende.angehaengt, isEmpty);
      expect(ablauf, ['entwicklung', 'einrichtung']);
      expect(
        [for (final e in a.protokoll.eintraege) e.text],
        contains('Entwicklungs-Plugin nicht angehängt: Die Umgebungsvariable fehlt.'),
      );
    });

    testWidgets('angehängt: kein Dialog für ein installiertes Plugin mit demselben Kurznamen, dessen Zustimmung bleibt offen',
        (tester) async {
      final laufende = _Laufende(Protokoll());
      final a = await starten(tester, [standard],
          plugins: [_pluginEintrag()], entwicklung: _entwicklungsPlugin, laufende: laufende);
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Anhängen'));
      await tester.pumpAndSettle();
      // Die Namen der eingebauten Werkzeuge ermittelt die App echt asynchron.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();

      expect(find.text('Plugin zulassen'), findsNothing);
      expect(a.einstellungen.plugins, isEmpty);
      expect(laufende.angehaengt, hasLength(1));
      expect(laufende.gestartet, 1, reason: 'die übrigen Plugins starten wie sonst');
    });

    testWidgets('abgelehnt: ein installiertes Plugin mit demselben Kurznamen wird wie sonst gefragt', (tester) async {
      await starten(tester, [standard],
          plugins: [_pluginEintrag()], entwicklung: _entwicklungsPlugin, laufende: _Laufende(Protokoll()));
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Ablehnen'));
      await tester.pumpAndSettle();
      expect(find.text('Plugin zulassen'), findsOneWidget);
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Ablehnen'));
      await tester.pumpAndSettle();
    });

    testWidgets('Die Anzeige in der Titelzeile: deutlich, ohne Verbindung rot, bei Platzmangel gekürzt', (tester) async {
      Future<void> zeigen({required bool verbunden, String name = 'Beispiel'}) => tester.pumpWidget(MaterialApp(
            home: Scaffold(
              appBar: AppBar(
                actions: [
                  Flexible(child: EntwicklungsPluginAnzeige(name: name, verbunden: verbunden)),
                  BestaetigungenFeld(stufe: Bestaetigungen.mittel, aendern: (_) async {}),
                ],
              ),
            ),
          ));
      expect(entwicklungsPluginText('Beispiel', verbunden: true), 'Entwicklungs-Plugin: Beispiel');
      expect(entwicklungsPluginText('Beispiel', verbunden: false), 'Entwicklungs-Plugin: Beispiel (nicht verbunden)');
      final anzeige = find.byType(EntwicklungsPluginAnzeige);
      Color farbe() => tester.widget<Material>(find.descendant(of: anzeige, matching: find.byType(Material)).first).color!;

      await zeigen(verbunden: true);
      expect(find.text('Entwicklungs-Plugin: Beispiel'), findsOneWidget);
      expect(farbe(), ThemeData().colorScheme.tertiary);
      await zeigen(verbunden: false);
      expect(find.text('Entwicklungs-Plugin: Beispiel (nicht verbunden)'), findsOneWidget);
      expect(farbe(), ThemeData().colorScheme.error);
      expect(
        tester.widget<Tooltip>(find.descendant(of: anzeige, matching: find.byType(Tooltip))).message,
        contains('außerhalb der Installation'),
      );

      tester.view.physicalSize = const Size(520, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await zeigen(verbunden: false, name: 'Ein Plugin mit einem sehr langen Namen');
      expect(tester.takeException(), isNull, reason: 'kein Überlauf der Titelzeile');
      expect(tester.widget<Text>(find.textContaining('Entwicklungs-Plugin:')).overflow, TextOverflow.ellipsis);
    });
  });
}

class _Antwort {
  PluginAntwort? wert;
  bool fertig = false;
}

class _EntwicklungsAntwort {
  bool? wert;
  bool fertig = false;
}
