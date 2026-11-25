// Schnittstelle und Updates der Plugins (E35, E19), ohne Netz und ohne echten
// Installer: welche Seite zu alt ist, wann überhaupt gesucht wird, dass jedes
// Plugin für sich geprüft wird und ein Fehler kein anderes aufhält, und dass
// der Stand nach dem Installer eine neue Zustimmung braucht. Wie GitHub
// gefragt wird (Reihenfolge der Repositorys, Positivliste), steht in
// test/update_adressen_test.dart. Die Plugins liegen in Temp-Ordnern, nie im
// Einstellungsordner der App.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/plugin/beschreibung.dart';
import 'package:moocp/plugin/entscheidung.dart';
import 'package:moocp/plugin/plugin_update.dart';
import 'package:moocp/plugin/plugins.dart';
import 'package:moocp/plugin/schnittstelle.dart';
import 'package:moocp/protokoll.dart';
import 'package:moocp/update/update.dart';
import 'package:path/path.dart' as p;

class _EinstellungenOhneDatei extends Einstellungen {
  _EinstellungenOhneDatei() : super(updatePruefen: true);
  int gespeichert = 0;

  @override
  Future<void> speichern() async => gespeichert++;
}

Map<String, Object?> _manifest({
  String name = 'Beispiel',
  String kurzname = 'beispiel',
  String version = '1.0.0',
  int schnittstelle = 1,
  List<String> quellen = const ['beispiel-org/beispiel-plugin'],
}) => {
  'name': name,
  'kurzname': kurzname,
  'version': version,
  'schnittstelle': schnittstelle,
  'programm': 'plugin.exe',
  'herkunft': 'Beispiel-Projekt',
  'updateQuellen': quellen,
};

Directory _plugin(Directory wurzel, String ordner, Map<String, Object?> manifest) {
  final d = Directory(p.join(wurzel.path, ordner))..createSync(recursive: true);
  File(p.join(d.path, 'plugin.json')).writeAsStringSync(jsonEncode(manifest));
  File(p.join(d.path, 'plugin.exe')).writeAsStringSync('Programm $ordner');
  return d;
}

/// Eine Prüfung, die nie ins Netz geht: Sie liefert, was der Test vorgibt.
class _Update extends Update {
  _Update(super.protokoll, this.antwort) : super(quellen: const ['beispiel-org/beispiel-plugin']);
  final FutureOr<NeueVersion?> Function() antwort;
  int gefragt = 0;

  @override
  Future<NeueVersion?> pruefen(String eigene) async {
    gefragt++;
    return antwort();
  }
}

NeueVersion _neu(String version, String kurzname) => NeueVersion(
  version: version,
  datei: Uri.parse('https://github.com/beispiel-org/beispiel-plugin/releases/download/v$version/${kurzname}_setup_$version.exe'),
  dateiname: '${kurzname}_setup_$version.exe',
);

/// Merkt, was gefragt wurde, und antwortet, wie der Test es vorgibt.
class _Dialoge implements PluginPruefDialoge {
  final List<String> ablauf = [];
  bool schnittstelleJa = true;
  bool angebotJa = true;
  bool moocpInstallerLaeuft = true;
  final List<PluginUpdatePruefung?> schnittstellenPruefungen = [];
  final List<bool> moocpAngeboten = [];

  @override
  Future<bool> schnittstelle(PluginEintrag e, {bool moocpUpdate = false, PluginUpdatePruefung? pruefung}) async {
    ablauf.add('schnittstelle ${e.ordner}');
    schnittstellenPruefungen.add(pruefung);
    moocpAngeboten.add(moocpUpdate);
    return schnittstelleJa;
  }

  @override
  Future<bool> moocpAktualisieren() async {
    ablauf.add('moocp');
    return moocpInstallerLaeuft;
  }

  @override
  Future<bool> angebot(PluginUpdatePruefung p) async {
    ablauf.add('angebot ${p.eintrag.ordner} ${p.neu!.version}');
    return angebotJa;
  }

  @override
  Future<void> adressenWeg(PluginUpdatePruefung p) async => ablauf.add('adressen weg ${p.eintrag.ordner}');
}

/// Ein Installer, der nie gestartet wird: Er hält fest, wie er aufgerufen
/// wurde, und tut, was der Test vorgibt, bevor er endet.
class _Prozess extends Fake implements Process {
  _Prozess(this._code);
  final Future<int> _code;

  @override
  Future<int> get exitCode => _code;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();
}

void main() {
  group('Schnittstelle', () {
    test('die App bietet heute genau Version 1', () {
      expect(angeboteneSchnittstellen, {1});
      expect(schnittstelleUrteil(1), SchnittstellenUrteil.passt);
    });

    test('verlangt das Plugin mehr, ist moocp zu alt', () {
      expect(schnittstelleUrteil(2), SchnittstellenUrteil.moocpZuAlt);
      expect(schnittstelleUrteil(4, angeboten: {2, 3}), SchnittstellenUrteil.moocpZuAlt);
    });

    test('verlangt es eine Version, die moocp nicht mehr bietet, ist das Plugin zu alt', () {
      expect(schnittstelleUrteil(1, angeboten: {2, 3}), SchnittstellenUrteil.pluginZuAlt);
      expect(schnittstelleUrteil(2, angeboten: {1, 3}), SchnittstellenUrteil.pluginZuAlt, reason: 'eine Lücke ist nicht neuer');
      expect(schnittstelleUrteil(3, angeboten: {2, 3}), SchnittstellenUrteil.passt);
    });

    test('der Grund sagt, welche Seite zu alt ist, und nennt nur Zahlen', () {
      expect(schnittstelleGrund(SchnittstellenUrteil.moocpZuAlt, 2), startsWith('moocp ist zu alt'));
      expect(schnittstelleGrund(SchnittstellenUrteil.moocpZuAlt, 2), contains('Version 2'));
      expect(schnittstelleGrund(SchnittstellenUrteil.pluginZuAlt, 1, angeboten: {2, 3}), startsWith('Das Plugin ist zu alt'));
      expect(schnittstelleGrund(SchnittstellenUrteil.pluginZuAlt, 1, angeboten: {3, 2}), contains('moocp bietet 2, 3'));
    });
  });

  group('Ein Plugin mit unpassender Schnittstelle', () {
    late Directory wurzel;
    setUp(() => wurzel = Directory.systemTemp.createTempSync('moocp_plugin_update_'));
    tearDown(() => wurzel.deleteSync(recursive: true));

    test('lädt nicht, wird nicht gefragt, behält aber Beschreibung und Prüfsumme', () async {
      _plugin(wurzel, 'neu', _manifest(schnittstelle: 2));
      _plugin(wurzel, 'passend', _manifest(kurzname: 'passend'));
      final plugins = await Plugins.laden(_EinstellungenOhneDatei(), Protokoll(), wurzel);
      final neu = plugins.eintraege.firstWhere((e) => e.ordner == 'neu');
      expect(neu.ladbar, isFalse);
      expect(neu.unpassend, SchnittstellenUrteil.moocpZuAlt);
      expect(neu.fehler, startsWith('moocp ist zu alt'));
      expect(neu.beschreibung, isNotNull);
      expect(neu.pruefsumme, isNotNull);
      expect(plugins.stand(neu).zustand, PluginZustand.nichtGeladen);
      expect(plugins.offene.map((s) => s.eintrag.ordner), ['passend']);
    });

    test('ein Plugin für eine Version, die moocp nicht mehr bietet', () async {
      _plugin(wurzel, 'alt', _manifest());
      final eintraege = await pluginsFinden(wurzel, angeboten: {2});
      expect(eintraege.single.unpassend, SchnittstellenUrteil.pluginZuAlt);
      expect(eintraege.single.fehler, startsWith('Das Plugin ist zu alt'));
    });

    test('auch nach der Zustimmung startet es nicht, die Zustimmung zum Stand bleibt aber erkennbar', () async {
      _plugin(wurzel, 'alt', _manifest());
      final einstellungen = _EinstellungenOhneDatei();
      final vorher = await Plugins.laden(einstellungen, Protokoll(), wurzel);
      await vorher.entscheiden(vorher.eintraege.single, zugestimmt: true, profile: {'standard'});
      // Eine spätere moocp bietet Version 1 nicht mehr.
      final plugins = Plugins(einstellungen, Protokoll(), await pluginsFinden(wurzel, angeboten: {2}));
      final e = plugins.eintraege.single;
      expect(plugins.stand(e).zustand, PluginZustand.nichtGeladen);
      expect(plugins.aktivIn('standard'), isEmpty);
      expect(plugins.zugestimmtFuerStand(e), isTrue);
    });
  });

  group('Wann nach einem Update eines Plugins gesucht wird', () {
    late Directory wurzel;
    late _EinstellungenOhneDatei einstellungen;
    late Plugins plugins;
    final heute = DateTime(2026, 11, 13, 8);
    setUp(() async {
      wurzel = Directory.systemTemp.createTempSync('moocp_plugin_update_');
      _plugin(wurzel, 'beispiel', _manifest());
      einstellungen = _EinstellungenOhneDatei();
      plugins = await Plugins.laden(einstellungen, Protokoll(), wurzel);
      await plugins.entscheiden(plugins.eintraege.single, zugestimmt: true, profile: {'standard'});
    });
    tearDown(() => wurzel.deleteSync(recursive: true));

    String? grund({bool updatefaehig = true, DateTime? jetzt}) =>
        pluginUpdateAusgelassen(plugins, plugins.eintraege.single, einstellungen, updatefaehig: updatefaehig, jetzt: jetzt ?? heute);

    test('zugestimmt, mit Quellen, tägliche Suche erlaubt: es wird gesucht', () {
      expect(grund(), isNull);
    });

    test('nicht auf dem Mac und nicht mit --kein-update, aber unabhängig davon, ob moocp sich selbst ersetzen kann', () {
      expect(grund(updatefaehig: false), isNotNull);
      expect(pluginUpdateMoeglich(const [], windows: true), isTrue, reason: 'auch im Entwicklerbau');
      expect(pluginUpdateMoeglich(const ['--irgendwas'], windows: true), isTrue);
      expect(pluginUpdateMoeglich(const [keinUpdateSchalter], windows: true), isFalse);
      expect(pluginUpdateMoeglich(const [], windows: false), isFalse, reason: 'kein Installer-Format auf dem Mac');
    });

    test('nur nach dem Ja zur täglichen Suche, ohne eigenes Ja je Plugin', () {
      einstellungen.updatePruefen = null;
      expect(grund(), isNotNull);
      einstellungen.updatePruefen = false;
      expect(grund(), isNotNull);
    });

    test('nur für ein Plugin, dessen jetzigem Stand zugestimmt ist', () async {
      await plugins.entscheiden(plugins.eintraege.single, zugestimmt: false);
      expect(grund(), isNotNull);
      einstellungen.plugins = {};
      expect(grund(), isNotNull);
    });

    test('nicht ohne Update-Quellen', () async {
      File(p.join(wurzel.path, 'beispiel', 'plugin.json')).writeAsStringSync(jsonEncode(_manifest(quellen: [])));
      plugins = await Plugins.laden(einstellungen, Protokoll(), wurzel);
      await plugins.entscheiden(plugins.eintraege.single, zugestimmt: true, profile: {'standard'});
      expect(grund(), isNotNull);
    });

    test('der Schalter je Plugin schaltet ab, gespeichert und über eine neue Zustimmung hinaus', () async {
      final e = plugins.eintraege.single;
      expect(plugins.updateEingeschaltet(e), isTrue);
      await plugins.updateSchalten(e, false);
      expect(plugins.updateEingeschaltet(e), isFalse);
      expect(grund(), isNotNull);
      expect(einstellungen.zuJson()['pluginUpdates'], {'beispiel': {'aus': true}});

      // Eine neue Version des Plugins, neu zugestimmt: Der Schalter bleibt aus.
      File(p.join(wurzel.path, 'beispiel', 'plugin.json')).writeAsStringSync(jsonEncode(_manifest(version: '1.1.0')));
      plugins = await Plugins.laden(einstellungen, Protokoll(), wurzel);
      await plugins.entscheiden(plugins.eintraege.single, zugestimmt: true, profile: {'standard'});
      expect(plugins.updateEingeschaltet(plugins.eintraege.single), isFalse);

      await plugins.updateSchalten(plugins.eintraege.single, true);
      expect(grund(), isNull);
    });

    test('einmal am Tag je Plugin; der Tag wird auch nach einem Fehlversuch gemerkt', () async {
      final protokoll = Protokoll();
      final update = _Update(protokoll, () => throw UpdateFehler('GitHub ist nicht erreichbar.'));
      final erste = await pluginUpdatePruefen(plugins, plugins.eintraege.single, einstellungen, protokoll,
          updatefaehig: true, jetzt: heute, erzeugen: (_, _) => update);
      expect(erste?.fehler, 'GitHub ist nicht erreichbar.');
      expect(einstellungen.pluginUpdates['beispiel']?.zuletzt, '2026-11-13');
      final zweite = await pluginUpdatePruefen(plugins, plugins.eintraege.single, einstellungen, protokoll,
          updatefaehig: true, jetzt: heute.add(const Duration(hours: 3)), erzeugen: (_, _) => update);
      expect(zweite, isNull);
      expect(update.gefragt, 1);
      expect(grund(jetzt: DateTime(2026, 11, 14)), isNull, reason: 'am nächsten Tag wieder');
    });

    test('Tag und Schalter überstehen das Speichern und Laden der Einstellungen', () {
      einstellungen.pluginUpdates = {
        'a': const PluginUpdateStand(aus: true),
        'b': const PluginUpdateStand(zuletzt: '2026-11-13'),
      };
      final gelesen = Einstellungen.aus(jsonDecode(jsonEncode(einstellungen.zuJson())) as Map<String, dynamic>,
          Einstellungen());
      expect(gelesen.pluginUpdates['a']?.aus, isTrue);
      expect(gelesen.pluginUpdates['b']?.aus, isFalse);
      expect(gelesen.pluginUpdates['b']?.zuletzt, '2026-11-13');
      expect(pluginUpdatesAus({'x': 'kaputt', 'y': {'aus': 'ja'}})['y']?.aus, isFalse);
    });
  });

  group('Versionen eines Plugins', () {
    test('die Version aus plugin.json gegen den Tag des Releases, Zahl für Zahl', () {
      expect(versionVergleich(versionAusTag('v1.10.0')!, '1.9.3'), 1);
      expect(versionVergleich(versionAusTag('v1.0')!, '1.0.0'), 0);
      expect(versionVergleich(versionAusTag('v0.9.9')!, '1.0.0'), -1);
    });

    test('der Installer heißt <kurzname>_setup_<Version>.exe, die Datei im Temp-Verzeichnis nicht wie die von moocp', () {
      final b = PluginBeschreibung.ausJson(_manifest(kurzname: 'update'));
      final u = pluginUpdate(b, Protokoll());
      expect(installerName('1.2.0', anfang: u.installerAnfang), 'update_setup_1.2.0.exe');
      expect(u.quellen, ['beispiel-org/beispiel-plugin']);
      final datei = p.basename(installerDatei('1.2.0', praefix: u.dateiPraefix).path);
      expect(datei, 'moocp_plugin_update_update_1.2.0.exe');
      expect(datei, isNot(startsWith('moocp_update_')));
      expect(p.basename(installerDatei('1.2.0').path), 'moocp_update_1.2.0.exe', reason: 'moocp wie bisher');
    });
  });

  group('Jedes Plugin für sich', () {
    late Directory wurzel;
    late _EinstellungenOhneDatei einstellungen;
    late Protokoll protokoll;
    setUp(() {
      wurzel = Directory.systemTemp.createTempSync('moocp_plugin_update_');
      einstellungen = _EinstellungenOhneDatei();
      protokoll = Protokoll();
    });
    tearDown(() => wurzel.deleteSync(recursive: true));

    Future<Plugins> laden({Set<String> zustimmen = const {}}) async {
      final plugins = await Plugins.laden(einstellungen, protokoll, wurzel);
      for (final e in plugins.eintraege) {
        if (zustimmen.contains(e.ordner)) await plugins.entscheiden(e, zugestimmt: true, profile: {'standard'});
      }
      return plugins;
    }

    Future<PluginPruefErgebnis> pruefen(
      Plugins plugins,
      _Dialoge dialoge,
      Map<String, FutureOr<NeueVersion?> Function()> antworten, {
      Set<String>? nur,
      bool moocpUpdateMoeglich = true,
      List<String>? erzeugt,
      String appVersion = '0.11.0',
    }) => pluginsPruefen(
      plugins: plugins,
      einstellungen: einstellungen,
      protokoll: protokoll,
      updatefaehig: true,
      moocpUpdateMoeglich: moocpUpdateMoeglich,
      appVersion: appVersion,
      dialoge: dialoge,
      uhr: () => DateTime(2026, 11, 13, 8),
      erzeugen: (b, pr) {
        erzeugt?.add(b.kurzname);
        return _Update(pr, antworten[b.kurzname]!);
      },
      nur: nur,
    );

    test('ein scheiterndes Update neben einem funktionierenden: das eine gemeldet, das andere angeboten', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha'));
      _plugin(wurzel, 'b', _manifest(name: 'Beta', kurzname: 'beta'));
      final plugins = await laden(zustimmen: {'a', 'b'});
      final dialoge = _Dialoge();
      final ergebnis = await pruefen(plugins, dialoge, {
        'alpha': () => throw UpdateFehler('GitHub nimmt gerade keine Anfragen an (403).'),
        'beta': () => _neu('1.1.0', 'beta'),
      });
      expect(dialoge.ablauf, ['angebot b 1.1.0'], reason: 'der Fehler bei Alpha bleibt still, Beta wird angeboten');
      expect(ergebnis.aktualisiert, {'b'});
      expect(ergebnis.beenden, isFalse);
      expect(protokoll.eintraege.map((e) => e.text),
          contains('Plugin „Alpha“: Update nicht möglich (GitHub nimmt gerade keine Anfragen an (403).)'));
    });

    test('auch ein unerwarteter Fehler bei einem Plugin hält das nächste nicht auf', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha'));
      _plugin(wurzel, 'b', _manifest(name: 'Beta', kurzname: 'beta'));
      final plugins = await laden(zustimmen: {'a', 'b'});
      final dialoge = _Dialoge();
      await pruefen(plugins, dialoge, {
        'alpha': () => throw StateError('kaputt'),
        'beta': () => _neu('1.1.0', 'beta'),
      });
      expect(dialoge.ablauf, ['angebot b 1.1.0']);
      expect(protokoll.eintraege.map((e) => e.text),
          contains('Plugin „Alpha“: Update nicht möglich (unerwarteter Fehler (StateError))'));
    });

    test('keine Update-Adresse mehr: ein Hinweis für dieses Plugin', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha'));
      final plugins = await laden(zustimmen: {'a'});
      final dialoge = _Dialoge();
      await pruefen(plugins, dialoge, {'alpha': () => throw UpdateAdressenWeg()});
      expect(dialoge.ablauf, ['adressen weg a']);
    });

    test('ohne Zustimmung zum Stand wird nicht gesucht, und es fragt nichts', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha'));
      final plugins = await laden();
      final erzeugt = <String>[];
      final dialoge = _Dialoge();
      await pruefen(plugins, dialoge, {'alpha': () => _neu('2.0.0', 'alpha')}, erzeugt: erzeugt);
      expect(erzeugt, isEmpty);
      expect(dialoge.ablauf, isEmpty);
    });

    test('ist die laufende Version die neueste, fragt nichts', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha'));
      final plugins = await laden(zustimmen: {'a'});
      final dialoge = _Dialoge();
      final ergebnis = await pruefen(plugins, dialoge, {'alpha': () => null});
      expect(dialoge.ablauf, isEmpty);
      expect(ergebnis.aktualisiert, isEmpty);
    });

    test('„Jetzt nicht“: kein Update, nichts zum Neuladen', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha'));
      final plugins = await laden(zustimmen: {'a'});
      final dialoge = _Dialoge()..angebotJa = false;
      final ergebnis = await pruefen(plugins, dialoge, {'alpha': () => _neu('1.1.0', 'alpha')});
      expect(dialoge.ablauf, ['angebot a 1.1.0']);
      expect(ergebnis.aktualisiert, isEmpty);
    });

    test('moocp zu alt: der Dialog bietet das Update von moocp an; läuft dessen Installer, endet die Prüfung', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha', schnittstelle: 2));
      _plugin(wurzel, 'b', _manifest(name: 'Beta', kurzname: 'beta'));
      final plugins = await laden(zustimmen: {'b'});
      final erzeugt = <String>[];
      final dialoge = _Dialoge();
      final ergebnis = await pruefen(plugins, dialoge, {'beta': () => _neu('1.1.0', 'beta')}, erzeugt: erzeugt);
      expect(dialoge.ablauf, ['schnittstelle a', 'moocp']);
      expect(dialoge.moocpAngeboten, [true]);
      expect(ergebnis.beenden, isTrue);
      expect(erzeugt, isEmpty, reason: 'nach dem Installer von moocp wird nichts mehr gesucht');
    });

    test('moocp zu alt, ohne Update von moocp: nur der Hinweis, das nächste Plugin kommt dran', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha', schnittstelle: 2));
      _plugin(wurzel, 'b', _manifest(name: 'Beta', kurzname: 'beta'));
      final plugins = await laden(zustimmen: {'b'});
      final dialoge = _Dialoge();
      final ergebnis = await pruefen(plugins, dialoge, {'beta': () => _neu('1.1.0', 'beta')}, moocpUpdateMoeglich: false);
      expect(dialoge.moocpAngeboten, [false]);
      expect(dialoge.ablauf, ['schnittstelle a', 'angebot b 1.1.0']);
      expect(ergebnis.beenden, isFalse);
    });

    test('Plugin zu alt und zugestimmt: es wird gesucht, und der Dialog bietet das Update des Plugins an', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha'));
      final plugins = await laden(zustimmen: {'a'});
      // Eine spätere moocp bietet Version 1 nicht mehr.
      final spaeter = Plugins(einstellungen, protokoll, await pluginsFinden(wurzel, angeboten: {2}));
      final dialoge = _Dialoge();
      final ergebnis = await pruefen(spaeter, dialoge, {'alpha': () => _neu('2.0.0', 'alpha')});
      expect(plugins.eintraege, isNotEmpty);
      expect(dialoge.ablauf, ['schnittstelle a', 'angebot a 2.0.0']);
      expect(dialoge.schnittstellenPruefungen.single?.neu?.version, '2.0.0');
      expect(dialoge.moocpAngeboten, [false]);
      expect(ergebnis.aktualisiert, {'a'});
    });

    test('Plugin zu alt ohne Zustimmung zum Stand: nur der Hinweis, ohne Suche und ohne Angebot', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha'));
      final spaeter = Plugins(einstellungen, protokoll, await pluginsFinden(wurzel, angeboten: {2}));
      final erzeugt = <String>[];
      final dialoge = _Dialoge();
      await pruefen(spaeter, dialoge, {'alpha': () => _neu('2.0.0', 'alpha')}, erzeugt: erzeugt);
      expect(erzeugt, isEmpty);
      expect(dialoge.ablauf, ['schnittstelle a']);
      expect(dialoge.schnittstellenPruefungen.single, isNull);
    });

    test('„Plugin bleibt aus“ ohne Update-Angebot: einmal je Stand des Plugins und Version der App', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha', schnittstelle: 2));
      var plugins = await laden();
      final dialoge = _Dialoge()..schnittstelleJa = false;

      await pruefen(plugins, dialoge, {});
      await pruefen(plugins, dialoge, {});
      expect(dialoge.ablauf, ['schnittstelle a'], reason: 'beim zweiten Start nicht noch einmal');
      expect(einstellungen.schnittstelleGesehen, hasLength(1));
      expect(
        protokoll.eintraege.where((z) => z.text.startsWith('Plugin „Alpha“ bleibt aus')),
        hasLength(2),
        reason: 'das Protokoll nennt es bei jedem Start',
      );

      // Eine andere Version der App: wieder einmal.
      await pruefen(plugins, dialoge, {}, appVersion: '0.12.0');
      expect(dialoge.ablauf, ['schnittstelle a', 'schnittstelle a']);

      // Ein anderer Stand des Plugins: wieder einmal.
      File(p.join(wurzel.path, 'a', 'plugin.exe')).writeAsStringSync('anders');
      plugins = await laden();
      await pruefen(plugins, dialoge, {}, appVersion: '0.12.0');
      await pruefen(plugins, dialoge, {}, appVersion: '0.12.0');
      expect(dialoge.ablauf, ['schnittstelle a', 'schnittstelle a', 'schnittstelle a']);
      expect(einstellungen.schnittstelleGesehen, hasLength(1), reason: 'je Plugin nur der letzte Stand');

      final gelesen = Einstellungen.aus(
        jsonDecode(jsonEncode(einstellungen.zuJson())) as Map<String, dynamic>,
        Einstellungen(),
      );
      expect(gelesen.schnittstelleGesehen, einstellungen.schnittstelleGesehen);
    });

    test('„Plugin bleibt aus“ mit Update-Angebot erscheint weiter nach den Regeln der Update-Prüfung', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha'));
      await laden(zustimmen: {'a'});
      final spaeter = Plugins(einstellungen, protokoll, await pluginsFinden(wurzel, angeboten: {2}));
      final dialoge = _Dialoge()
        ..schnittstelleJa = false;
      var tag = DateTime(2026, 11, 13, 8);
      Future<void> pruefenAm() => pluginsPruefen(
        plugins: spaeter,
        einstellungen: einstellungen,
        protokoll: protokoll,
        updatefaehig: true,
        moocpUpdateMoeglich: false,
        appVersion: '0.11.0',
        dialoge: dialoge,
        uhr: () => tag,
        erzeugen: (b, pr) => _Update(pr, () => _neu('2.0.0', 'alpha')),
      );

      await pruefenAm();
      expect(dialoge.ablauf, ['schnittstelle a']);
      await pruefenAm();
      expect(dialoge.ablauf, ['schnittstelle a'], reason: 'heute schon gesucht: kein Angebot, und gesehen');
      tag = DateTime(2026, 11, 14, 8);
      await pruefenAm();
      expect(dialoge.ablauf, ['schnittstelle a', 'schnittstelle a'], reason: 'am nächsten Tag wieder mit Angebot');
      expect(dialoge.schnittstellenPruefungen.last?.neu?.version, '2.0.0');
    });

    test('nach einem Update nur die aktualisierten Plugins', () async {
      _plugin(wurzel, 'a', _manifest(name: 'Alpha', kurzname: 'alpha', schnittstelle: 2));
      _plugin(wurzel, 'b', _manifest(name: 'Beta', kurzname: 'beta', schnittstelle: 2));
      final plugins = await laden();
      final dialoge = _Dialoge()..schnittstelleJa = false;
      await pruefen(plugins, dialoge, {}, nur: {'b'});
      expect(dialoge.ablauf, ['schnittstelle b']);
    });
  });

  group('Der Installer eines Plugins', () {
    late Directory wurzel;
    setUp(() => wurzel = Directory.systemTemp.createTempSync('moocp_plugin_update_'));
    tearDown(() => wurzel.deleteSync(recursive: true));

    test('läuft sichtbar und ohne /UPDATE, die App wartet; der neue Stand braucht eine neue Zustimmung', () async {
      final ordner = _plugin(wurzel, 'beispiel', _manifest());
      final einstellungen = _EinstellungenOhneDatei();
      final protokoll = Protokoll();
      final plugins = await Plugins.laden(einstellungen, protokoll, wurzel);
      await plugins.entscheiden(plugins.eintraege.single, zugestimmt: true, profile: {'standard'});
      expect(plugins.stand(plugins.eintraege.single).zustand, PluginZustand.zugestimmt);

      final installer = File(p.join(wurzel.path, 'beispiel_setup_1.1.0.exe'))..writeAsStringSync('Installer');
      final aufrufe = <(String, List<String>, ProcessStartMode)>[];
      final ende = Completer<int>();
      final code = pluginInstallerAusfuehren(
        installer,
        plugins.eintraege.single.beschreibung!,
        '1.1.0',
        protokoll,
        starter: (pfad, argumente, {mode = ProcessStartMode.normal}) async {
          aufrufe.add((pfad, argumente, mode));
          return _Prozess(ende.future);
        },
      );
      // Solange der Installer läuft, wartet die App.
      await Future<void>.delayed(Duration.zero);
      expect(aufrufe.single.$1, installer.path);
      expect(aufrufe.single.$2, isEmpty);
      expect(aufrufe.single.$3, ProcessStartMode.normal, reason: 'nicht losgelöst: die App wartet auf das Ende');
      // Der Installer legt die neue Version in den Plugin-Ordner.
      File(p.join(ordner.path, 'plugin.json')).writeAsStringSync(jsonEncode(_manifest(version: '1.1.0')));
      File(p.join(ordner.path, 'plugin.exe')).writeAsStringSync('Programm 1.1.0');
      ende.complete(0);
      expect(await code, 0);
      expect(installer.existsSync(), isFalse, reason: 'die geladene Datei fliegt weg');
      final texte = protokoll.eintraege.map((e) => e.text).toList();
      expect(texte, contains('Plugin „Beispiel“, Update: Installer für Version 1.1.0 gestartet'));
      expect(texte, contains('Plugin „Beispiel“, Update: Installer beendet (Exit-Code 0)'));

      final danach = await Plugins.laden(einstellungen, protokoll, wurzel);
      expect(danach.stand(danach.eintraege.single).zustand, PluginZustand.offen);
      expect(danach.aktivIn('standard'), isEmpty);
    });

    test('der Installer von moocp nimmt denselben Weg, wie bisher losgelöst mit /UPDATE', () async {
      final einstellungen = _EinstellungenOhneDatei();
      final protokoll = Protokoll();
      final installer = File(p.join(wurzel.path, 'moocp_update_0.12.0.exe'))..writeAsStringSync('Installer');
      final aufrufe = <(List<String>, ProcessStartMode)>[];
      await updateInstallerStarten(installer, '0.12.0', einstellungen, protokoll,
          starter: (pfad, argumente, {mode = ProcessStartMode.normal}) async {
        aufrufe.add((argumente, mode));
        return _Prozess(Completer<int>().future);
      });
      expect(aufrufe.single.$1, ['/UPDATE']);
      expect(aufrufe.single.$2, ProcessStartMode.detached);
      expect(einstellungen.updateErwartet, '0.12.0');
      expect(einstellungen.gespeichert, 1);
      expect(protokoll.eintraege.map((e) => e.text), contains('Update: Installer für Version 0.12.0 gestartet'));
    });

    test('Reste geladener Installer von Plugins räumt der Start weg', () {
      final rest = File(p.join(Directory.systemTemp.path, 'moocp_plugin_zztest_update_9.9.9.exe'))
        ..writeAsStringSync('Rest');
      addTearDown(() => wegwerfen(rest));
      resteWegraeumen();
      expect(rest.existsSync(), isFalse);
    });
  });

  group('Kein Weg für die KI', () {
    test('die Prüfung der Plugins hängt an keinem MCP-Code', () {
      for (final datei in Directory('lib/mcp').listSync(recursive: true).whereType<File>()) {
        final text = datei.readAsStringSync();
        expect(text.contains('plugin_update.dart'), isFalse, reason: datei.path);
        expect(text.contains('update/update.dart'), isFalse, reason: datei.path);
      }
    });
  });
}
