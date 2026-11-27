// Plugins finden und ihnen zustimmen (E35): Die Beschreibungsdateien werden
// gelesen, ohne etwas auszuführen; die Zustimmung gilt für genau einen Stand,
// erkannt an Version und SHA-256-Prüfsumme über alle Dateien des Ordners.
// Jede Abweichung heißt „noch nicht entschieden“. Die Tests laufen in
// Temp-Ordnern, nie im Einstellungsordner der App.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/einstellungen_ort.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/plugin/beschreibung.dart';
import 'package:moocp/plugin/entscheidung.dart';
import 'package:moocp/plugin/pruefsumme.dart';
import 'package:moocp/plugin/plugins.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:moocp/testschalter.dart';
import 'package:path/path.dart' as p;

class _EinstellungenOhneDatei extends Einstellungen {
  _EinstellungenOhneDatei({super.profile, super.plugins}) : super();
  int gespeichert = 0;
  bool speichernScheitert = false;

  @override
  Future<void> speichern() async {
    if (speichernScheitert) throw const FileSystemException('nicht schreibbar');
    gespeichert++;
  }
}

Map<String, Object?> _manifest({String version = '1.0', String kurzname = 'beispiel', Object? zusatzadressen}) => {
      'name': 'Beispiel',
      'kurzname': kurzname,
      'version': version,
      'schnittstelle': 1,
      'programm': 'beispiel.exe',
      'herkunft': 'Beispiel-Projekt',
      'zusatzadressen': ?zusatzadressen,
    };

/// Legt `<wurzel>/<ordner>` mit Beschreibungsdatei und Dateien an.
Directory _plugin(
  Directory wurzel,
  String ordner, {
  Map<String, Object?>? manifest,
  Map<String, String> dateien = const {'beispiel.exe': 'Programm'},
}) {
  final d = Directory(p.join(wurzel.path, ordner))..createSync(recursive: true);
  File(p.join(d.path, 'plugin.json')).writeAsStringSync(jsonEncode(manifest ?? _manifest()));
  dateien.forEach((name, inhalt) {
    final f = File(p.join(d.path, name))..parent.createSync(recursive: true);
    f.writeAsStringSync(inhalt);
  });
  return d;
}

Profil _profil(String kennung, String name) => Profil(
      kennung: kennung,
      name: name,
      adresse: 'https://$kennung.moodle.schule.example',
      port: 47811,
      mcpName: name.toLowerCase(),
    );

void main() {
  late Directory wurzel;
  setUp(() => wurzel = Directory.systemTemp.createTempSync('moocp_plugins_'));
  tearDown(() => wurzel.deleteSync(recursive: true));

  group('Prüfsumme über alle Dateien des Plugin-Ordners', () {
    Future<String> summe(Directory d) => pluginPruefsumme(d);

    test('gleiche Dateien, gleiche Summe: auch an anderem Ort und in anderer Reihenfolge angelegt', () async {
      final a = _plugin(wurzel, 'a', dateien: {'beispiel.exe': 'P', 'skills/eins.skill': 'S1', 'skills/zwei.skill': 'S2'});
      final b = _plugin(wurzel, 'b', dateien: {'skills/zwei.skill': 'S2', 'skills/eins.skill': 'S1', 'beispiel.exe': 'P'});
      final s = await summe(a);
      expect(s, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(await summe(b), s);
      expect(await summe(a), s, reason: 'stabil von Aufruf zu Aufruf');
    });

    test('ein ausgetauschtes Programm ändert die Summe, auch bei gleicher Version', () async {
      final d = _plugin(wurzel, 'a');
      final vorher = await summe(d);
      File(p.join(d.path, 'beispiel.exe')).writeAsStringSync('Anderes Programm');
      expect(await summe(d), isNot(vorher));
    });

    test('jede Änderung zählt: Beschreibungsdatei, neue Datei, entfernte Datei, Umbenennung', () async {
      final d = _plugin(wurzel, 'a', dateien: {'beispiel.exe': 'P', 'skills/eins.skill': 'S1'});
      final ausgang = await summe(d);

      final manifest = File(p.join(d.path, 'plugin.json'));
      final alt = manifest.readAsStringSync();
      manifest.writeAsStringSync(jsonEncode(_manifest(version: '1.1')));
      final neueVersion = await summe(d);
      expect(neueVersion, isNot(ausgang));
      manifest.writeAsStringSync(alt);
      expect(await summe(d), ausgang, reason: 'zurückgesetzt ist es wieder derselbe Stand');

      final neu = File(p.join(d.path, 'skills', 'neu.skill'))..writeAsStringSync('N');
      final mitNeuer = await summe(d);
      expect(mitNeuer, isNot(ausgang));
      neu.deleteSync();
      expect(await summe(d), ausgang);

      File(p.join(d.path, 'skills', 'eins.skill')).renameSync(p.join(d.path, 'skills', 'umbenannt.skill'));
      expect(await summe(d), isNot(ausgang), reason: 'gleicher Inhalt, anderer Name');

      File(p.join(d.path, 'skills', 'umbenannt.skill')).deleteSync();
      expect(await summe(d), isNot(ausgang));
    });

    test('Pfad und Inhalt lassen sich nicht gegeneinander verschieben', () async {
      final a = _plugin(wurzel, 'a', dateien: {'ab': 'c'});
      final b = _plugin(wurzel, 'b', dateien: {'a': 'bc'});
      // Beide Ordner unterscheiden sich in plugin.json nicht.
      expect(await summe(a), isNot(await summe(b)));
    });

    test('eine Verknüpfung im Ordner hält das Plugin vom Laden ab: ihr Ziel läge außerhalb der Summe', () async {
      final d = _plugin(wurzel, 'a');
      final ziel = Directory(p.join(wurzel.path, 'woanders'))..createSync();
      try {
        Link(p.join(d.path, 'verweis')).createSync(ziel.path);
      } on FileSystemException {
        markTestSkipped('Verknüpfungen lassen sich hier nicht anlegen (fehlendes Recht).');
        return;
      }
      await expectLater(summe(d), throwsA(isA<PluginFehler>()));
    });
  });

  group('Plugins finden', () {
    Future<List<PluginEintrag>> finden() => pluginsFinden(Directory(p.join(wurzel.path, 'plugins')));
    Directory plugins() => Directory(p.join(wurzel.path, 'plugins'))..createSync(recursive: true);

    test('ohne Ordner oder mit leerem Ordner: nichts, ohne Fehler', () async {
      expect(await finden(), isEmpty);
      plugins();
      expect(await finden(), isEmpty);
    });

    test('eine Datei im Ordner ist kein Plugin', () async {
      File(p.join(plugins().path, 'notizen.txt')).writeAsStringSync('x');
      expect(await finden(), isEmpty);
    });

    test('ein gültiges Plugin: Beschreibung, Prüfsumme, geladen', () async {
      _plugin(plugins(), 'beispiel');
      final e = (await finden()).single;
      expect(e.ordner, 'beispiel');
      expect(e.ladbar, isTrue);
      expect(e.fehler, isNull);
      expect(e.beschreibung!.kurzname, 'beispiel');
      expect(e.pruefsumme, await pluginPruefsumme(Directory(e.pfad)));
      expect(e.anzeigename, 'Beispiel');
      expect(e.programmPfad, p.join(e.pfad, 'beispiel.exe'));
    });

    test('die Beschreibungsdatei darf eine Byte-Order-Mark haben', () async {
      final d = _plugin(plugins(), 'beispiel');
      File(p.join(d.path, 'plugin.json')).writeAsStringSync('\uFEFF${jsonEncode(_manifest())}');
      expect((await finden()).single.ladbar, isTrue);
    });

    test('ohne Beschreibungsdatei, ohne gültiges JSON, mit Regelbruch: nicht geladen, mit Grund', () async {
      Directory(p.join(plugins().path, 'leer')).createSync();
      final kaputt = _plugin(plugins(), 'kaputt');
      File(p.join(kaputt.path, 'plugin.json')).writeAsStringSync('geheimer Inhalt {');
      _plugin(plugins(), 'lang', manifest: _manifest(kurzname: 'abcdefghijklm'));
      _plugin(plugins(), 'gesperrt', manifest: _manifest(zusatzadressen: [
        {'muster': '/admin/*', 'art': 'lesen', 'grund': 'Liest alles.'},
      ]));
      final nach = {for (final e in await finden()) e.ordner: e};
      expect(nach.keys, containsAll(['leer', 'kaputt', 'lang', 'gesperrt']));
      for (final e in nach.values) {
        expect(e.ladbar, isFalse, reason: e.ordner);
        expect(e.fehler, isNotEmpty, reason: e.ordner);
        expect(e.pruefsumme, isNull, reason: 'ein Plugin, das nicht lädt, wird nicht erst gelesen');
      }
      expect(nach['leer']!.fehler, contains('plugin.json'));
      expect(nach['kaputt']!.fehler, isNot(contains('geheimer')));
      expect(nach['lang']!.fehler, contains('12'));
      expect(nach['gesperrt']!.fehler, contains('Adminbereich'));
      expect(nach['gesperrt']!.fehler, contains('Zusatzadresse 1'));
    });

    test('ein Programm, das fehlt, hält das Plugin vom Laden ab', () async {
      _plugin(plugins(), 'beispiel', dateien: const {});
      final e = (await finden()).single;
      expect(e.ladbar, isFalse);
      expect(e.fehler, contains('Programm'));
    });

    test('gleicher Kurzname: Das spätere Plugin in der Reihenfolge der Ordner lädt nicht, mit Grund', () async {
      _plugin(plugins(), 'b-zweites');
      _plugin(plugins(), 'A-erstes');
      final liste = await finden();
      expect([for (final e in liste) e.ordner], ['A-erstes', 'b-zweites'], reason: 'alphabetisch, ohne Rücksicht auf Groß und Klein');
      expect(liste[0].ladbar, isTrue);
      expect(liste[1].ladbar, isFalse);
      expect(liste[1].fehler, contains('A-erstes'));
      expect(liste[1].fehler, contains('Kurzname'));
    });

    test('ein Plugin mit Regelbruch blockiert den Kurznamen nicht', () async {
      _plugin(plugins(), 'a-kaputt', manifest: {..._manifest(), 'schnittstelle': 'x'});
      _plugin(plugins(), 'b-gut');
      final liste = await finden();
      expect(liste[0].ladbar, isFalse);
      expect(liste[1].ladbar, isTrue);
    });

    test('eine Verknüpfung statt eines Ordners ist kein stilles Überspringen wert', () async {
      final ziel = _plugin(wurzel, 'woanders');
      try {
        Link(p.join(plugins().path, 'verweis')).createSync(ziel.path);
      } on FileSystemException {
        markTestSkipped('Verknüpfungen lassen sich hier nicht anlegen (fehlendes Recht).');
        return;
      }
      final e = (await finden()).single;
      expect(e.ladbar, isFalse);
      expect(e.fehler, contains('Verknüpfung'));
    });
  });

  group('Zustand und Zustimmung', () {
    late _EinstellungenOhneDatei einstellungen;
    late Protokoll protokoll;
    late Plugins plugins;

    Future<void> aufbauen({Map<String, PluginEntscheidung>? gespeichert}) async {
      einstellungen = _EinstellungenOhneDatei(plugins: gespeichert);
      protokoll = Protokoll();
      final ordner = Directory(p.join(wurzel.path, 'plugins'));
      plugins = await Plugins.laden(einstellungen, protokoll, ordner);
    }

    PluginEintrag beispiel() => plugins.eintraege.firstWhere((e) => e.ordner == 'beispiel');
    PluginZustand zustand(PluginEintrag e) => plugins.stand(e).zustand;

    setUp(() {
      _plugin(Directory(p.join(wurzel.path, 'plugins')), 'beispiel');
    });

    test('ohne gespeicherte Entscheidung: noch nicht entschieden, auch im Testbetrieb', () async {
      expect(testbetriebAktiv, isTrue, reason: 'flutter_test_config schaltet den Testbetrieb ein');
      await aufbauen();
      expect(zustand(beispiel()), PluginZustand.offen);
      expect(plugins.offene.map((s) => s.eintrag.ordner), ['beispiel']);
      expect(plugins.aktivIn('standard'), isEmpty);
      expect(einstellungen.gespeichert, 0);
    });

    test('Zustimmen wird gespeichert und gilt für genau diesen Stand', () async {
      await aufbauen();
      await plugins.entscheiden(beispiel(), zugestimmt: true, profile: {'standard'});
      expect(zustand(beispiel()), PluginZustand.zugestimmt);
      expect(einstellungen.gespeichert, 1);
      final gespeichert = einstellungen.plugins['beispiel']!;
      expect(gespeichert.version, '1.0');
      expect(gespeichert.pruefsumme, beispiel().pruefsumme);
      expect(gespeichert.zugestimmt, isTrue);
      expect(gespeichert.profile, {'standard'});
      expect(plugins.offene, isEmpty);
    });

    test('Ablehnen wird ebenfalls gespeichert, damit nicht bei jedem Start gefragt wird', () async {
      await aufbauen();
      await plugins.entscheiden(beispiel(), zugestimmt: false);
      expect(zustand(beispiel()), PluginZustand.abgelehnt);
      expect(plugins.offene, isEmpty);
      expect(einstellungen.plugins['beispiel']!.zugestimmt, isFalse);
      expect(einstellungen.plugins['beispiel']!.profile, isEmpty);
      expect(plugins.aktivIn('standard'), isEmpty);
    });

    test('beim nächsten Start gilt die gespeicherte Entscheidung', () async {
      await aufbauen();
      await plugins.entscheiden(beispiel(), zugestimmt: true, profile: {'standard'});
      final json = jsonDecode(jsonEncode(einstellungen.zuJson())) as Map<String, dynamic>;
      final neu = Einstellungen.aus(json, Einstellungen());
      final nachNeustart = Plugins(neu, Protokoll(), plugins.eintraege);
      expect(nachNeustart.stand(beispiel()).zustand, PluginZustand.zugestimmt);
      expect(nachNeustart.aktivIn('standard').map((s) => s.eintrag.ordner), ['beispiel']);
    });

    test('eine neue Version fragt neu, auch wenn die Zusatzadressen gleich bleiben', () async {
      await aufbauen();
      await plugins.entscheiden(beispiel(), zugestimmt: true, profile: {'standard'});
      final d = Directory(beispiel().pfad);
      File(p.join(d.path, 'plugin.json')).writeAsStringSync(jsonEncode(_manifest(version: '1.1')));
      final neu = Plugins(einstellungen, protokoll, await pluginsFinden(d.parent));
      expect(neu.stand(neu.eintraege.single).zustand, PluginZustand.offen);
      expect(neu.aktivIn('standard'), isEmpty);
    });

    test('ein ausgetauschtes Programm mit gleicher Versionsnummer fragt neu', () async {
      await aufbauen();
      await plugins.entscheiden(beispiel(), zugestimmt: true, profile: {'standard'});
      final d = Directory(beispiel().pfad);
      File(p.join(d.path, 'beispiel.exe')).writeAsStringSync('Ein ganz anderes Programm');
      final neu = Plugins(einstellungen, protokoll, await pluginsFinden(d.parent));
      expect(neu.eintraege.single.beschreibung!.version, '1.0');
      expect(neu.stand(neu.eintraege.single).zustand, PluginZustand.offen);
    });

    test('auch eine Ablehnung gilt nur für den abgelehnten Stand', () async {
      await aufbauen();
      await plugins.entscheiden(beispiel(), zugestimmt: false);
      final d = Directory(beispiel().pfad);
      File(p.join(d.path, 'plugin.json')).writeAsStringSync(jsonEncode(_manifest(version: '2.0')));
      final neu = Plugins(einstellungen, protokoll, await pluginsFinden(d.parent));
      expect(neu.stand(neu.eintraege.single).zustand, PluginZustand.offen);
    });

    test('ein Plugin, das nicht lädt, ist nie zugestimmt, auch wenn eine Entscheidung gespeichert ist', () async {
      await aufbauen(gespeichert: {
        'kaputt': const PluginEntscheidung(version: '1.0', pruefsumme: 'abc', zugestimmt: true, profile: {'standard'}),
      });
      final d = _plugin(Directory(p.join(wurzel.path, 'plugins')), 'kaputt', manifest: {..._manifest(), 'schnittstelle': 0});
      final neu = Plugins(einstellungen, protokoll, await pluginsFinden(d.parent));
      final kaputt = neu.eintraege.firstWhere((e) => e.ordner == 'kaputt');
      expect(neu.stand(kaputt).zustand, PluginZustand.nichtGeladen);
      expect(neu.aktivIn('standard'), isEmpty);
      expect(neu.offene.map((s) => s.eintrag.ordner), ['beispiel'], reason: 'nach einem Plugin, das nicht lädt, wird nicht gefragt');
    });

    test('Fehler beim Laden stehen mit Ordner und Grund im Protokoll, nie mit Inhalten', () async {
      final d = _plugin(Directory(p.join(wurzel.path, 'plugins')), 'kaputt');
      File(p.join(d.path, 'plugin.json')).writeAsStringSync('geheimer Inhalt');
      await aufbauen();
      final texte = protokoll.eintraege.map((e) => e.text).join('\n');
      expect(texte, contains('„kaputt“'));
      expect(texte, contains('nicht geladen'));
      expect(texte, isNot(contains('geheimer')));
      expect(protokoll.eintraege.every((e) => e.art == Art.fehler), isTrue);
    });

    test('ohne Plugin-Ordner steht nichts im Protokoll', () async {
      Directory(p.join(wurzel.path, 'plugins')).deleteSync(recursive: true);
      await aufbauen();
      expect(plugins.eintraege, isEmpty);
      expect(protokoll.eintraege, isEmpty);
    });

    test('Entscheidungen stehen im Protokoll, mit Ordner, ohne Inhalte aus der Beschreibungsdatei', () async {
      await aufbauen();
      await plugins.entscheiden(beispiel(), zugestimmt: true, profile: {'standard'});
      await plugins.entscheiden(beispiel(), zugestimmt: false);
      final texte = protokoll.eintraege.map((e) => e.text).toList();
      expect(texte, hasLength(2));
      expect(texte[0], allOf(contains('„beispiel“'), contains('Zustimmung')));
      expect(texte[1], allOf(contains('„beispiel“'), contains('abgelehnt')));
    });

    test('scheitert das Speichern, gilt die Entscheidung für diesen Lauf, und das Protokoll nennt nur den Typ', () async {
      await aufbauen();
      einstellungen.speichernScheitert = true;
      await plugins.entscheiden(beispiel(), zugestimmt: true, profile: {'standard'});
      expect(zustand(beispiel()), PluginZustand.zugestimmt);
      final fehler = protokoll.eintraege.where((e) => e.art == Art.fehler).single.text;
      expect(fehler, contains('FileSystemException'));
      expect(fehler, isNot(contains('nicht schreibbar')));
    });
  });

  group('Je Instanzprofil einschalten', () {
    late _EinstellungenOhneDatei einstellungen;
    late Plugins plugins;

    setUp(() async {
      _plugin(Directory(p.join(wurzel.path, 'plugins')), 'beispiel');
      einstellungen = _EinstellungenOhneDatei(profile: [_profil('standard', 'Moodle'), _profil('k2', 'Moodle Test')]);
      plugins = await Plugins.laden(einstellungen, Protokoll(), Directory(p.join(wurzel.path, 'plugins')));
    });

    test('aktiv ist ein Plugin nur in den Profilen, die bei der Zustimmung gewählt wurden', () async {
      await plugins.entscheiden(plugins.eintraege.single, zugestimmt: true, profile: {'k2'});
      expect(plugins.aktivIn('k2').map((s) => s.eintrag.ordner), ['beispiel']);
      expect(plugins.aktivIn('standard'), isEmpty);
      expect(plugins.aktivIn('unbekannt'), isEmpty);
    });

    test('später lässt es sich je Profil aus- und einschalten, ohne neue Zustimmung', () async {
      final e = plugins.eintraege.single;
      await plugins.entscheiden(e, zugestimmt: true, profile: {'standard', 'k2'});
      await plugins.profilSchalten(e, 'k2', false);
      expect(plugins.aktivIn('k2'), isEmpty);
      expect(plugins.aktivIn('standard'), isNotEmpty);
      expect(plugins.stand(e).zustand, PluginZustand.zugestimmt);
      await plugins.profilSchalten(e, 'k2', true);
      expect(plugins.aktivIn('k2'), isNotEmpty);
      expect(einstellungen.plugins['beispiel']!.profile, {'standard', 'k2'});
    });

    test('ohne Zustimmung lässt sich kein Profil einschalten', () async {
      final e = plugins.eintraege.single;
      await plugins.profilSchalten(e, 'standard', true);
      expect(plugins.aktivIn('standard'), isEmpty);
      await plugins.entscheiden(e, zugestimmt: false);
      await plugins.profilSchalten(e, 'standard', true);
      expect(plugins.aktivIn('standard'), isEmpty);
      expect(einstellungen.plugins['beispiel']!.profile, isEmpty);
    });

    test('ein Profil, das später dazukommt, schaltet jedes angenommene Plugin ein, kein abgelehntes', () async {
      final e = plugins.eintraege.single;
      await plugins.entscheiden(e, zugestimmt: true, profile: {'standard'});
      einstellungen.plugins = {
        ...einstellungen.plugins,
        'abgelehnt': const PluginEntscheidung(version: '1', pruefsumme: 'aa', zugestimmt: false),
      };
      final alt = einstellungen.plugins;
      einstellungen.profile = [...einstellungen.profile, _profil('neu', 'Moodle Neu')];
      expect(plugins.aktivIn('neu'), isEmpty, reason: 'das Profil allein schaltet nichts ein');

      einstellungen.plugins = pluginEntscheidungenMitProfil(alt, 'neu');

      expect(plugins.aktivIn('neu').map((s) => s.eintrag.ordner), ['beispiel']);
      expect(einstellungen.plugins['beispiel']!.profile, {'standard', 'neu'});
      expect(einstellungen.plugins['abgelehnt']!.profile, isEmpty);
      expect(alt['beispiel']!.profile, {'standard'}, reason: 'die Eingabe bleibt unverändert');
      // Abschalten geht weiter im Dialog „Plugins“.
      await plugins.profilSchalten(e, 'neu', false);
      expect(plugins.aktivIn('neu'), isEmpty);
    });

    test('ein gelöschtes Profil verschwindet aus den Mengen', () async {
      final e = plugins.eintraege.single;
      await plugins.entscheiden(e, zugestimmt: true, profile: {'standard', 'k2'});
      final ohne = pluginEntscheidungenOhneProfil(einstellungen.plugins, 'k2');
      expect(ohne['beispiel']!.profile, {'standard'});
      expect(ohne['beispiel']!.zugestimmt, isTrue, reason: 'die Zustimmung bleibt');
      expect(einstellungen.plugins['beispiel']!.profile, {'standard', 'k2'}, reason: 'die Eingabe bleibt unverändert');
    });
  });

  group('Gespeichert in den Einstellungen', () {
    test('ohne Plugins steht nichts in der Datei', () {
      expect(Einstellungen().zuJson().containsKey('plugins'), isFalse);
    });

    test('Hin und zurück: Version, Prüfsumme, Entscheidung und Profile', () {
      final e = Einstellungen(plugins: {
        'eins': const PluginEntscheidung(version: '1.0', pruefsumme: 'aa', zugestimmt: true, profile: {'k2', 'standard'}),
        'zwei': const PluginEntscheidung(version: '2', pruefsumme: 'bb', zugestimmt: false),
      });
      final json = jsonDecode(jsonEncode(e.zuJson())) as Map<String, dynamic>;
      final neu = Einstellungen.aus(json, Einstellungen());
      expect(neu.plugins.keys, ['eins', 'zwei']);
      expect(neu.plugins['eins']!.version, '1.0');
      expect(neu.plugins['eins']!.pruefsumme, 'aa');
      expect(neu.plugins['eins']!.zugestimmt, isTrue);
      expect(neu.plugins['eins']!.profile, {'k2', 'standard'});
      expect(neu.plugins['zwei']!.zugestimmt, isFalse);
      expect(neu.plugins['zwei']!.profile, isEmpty);
    });

    test('Beschädigtes zählt als nicht entschieden: Es wird nie zur Zustimmung', () {
      final j = <String, dynamic>{
        'schluessel': 'x',
        'plugins': {
          'text': 'kaputt',
          'ohneVersion': {'pruefsumme': 'aa', 'zugestimmt': true},
          'ohneSumme': {'version': '1', 'zugestimmt': true},
          'zugestimmtKeinBool': {'version': '1', 'pruefsumme': 'aa', 'zugestimmt': 'ja'},
          'ohneEntscheidung': {'version': '1', 'pruefsumme': 'aa'},
          'profileKeineListe': {'version': '1', 'pruefsumme': 'aa', 'zugestimmt': true, 'profile': 'standard'},
          'gut': {'version': '1', 'pruefsumme': 'aa', 'zugestimmt': true, 'profile': ['standard', 5]},
        },
      };
      final e = Einstellungen.aus(j, Einstellungen());
      expect(e.plugins.keys, ['gut']);
      expect(e.plugins['gut']!.profile, {'standard'});
      expect(Einstellungen.aus({'schluessel': 'x', 'plugins': 'kaputt'}, Einstellungen()).plugins, isEmpty);
    });
  });

  group('Wo die Plugins liegen', () {
    test('unter Windows im Einstellungsordner, wie auf dem Mac', () {
      expect(
        pluginsOrdnerFuer({'APPDATA': r'C:\Users\x\AppData\Roaming'}, macos: false),
        p.join(r'C:\Users\x\AppData\Roaming', 'moocp', 'plugins'),
      );
      expect(
        pluginsOrdnerFuer({'HOME': '/Users/x'}, macos: true),
        p.join('/Users/x', 'Library', 'Application Support', 'moocp', 'plugins'),
      );
    });
  });

  group('Kein Weg für die KI', () {
    test('kein Quelltext der MCP-Schicht oder der Moodle-Anbindung kennt die Plugin-Zustimmung', () {
      final treffer = <String>[];
      for (final ordner in ['lib/mcp', 'lib/moodle']) {
        for (final f in Directory(ordner).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
          final text = f.readAsStringSync();
          if (RegExp(r'''import\s+['"][^'"]*plugin/''').hasMatch(text) ||
              text.contains('PluginEntscheidung') ||
              text.contains('pluginsFinden')) {
            treffer.add(f.path);
          }
        }
      }
      expect(treffer, isEmpty);
    });

    test('kein MCP-Werkzeug nennt Plugins oder Zustimmung', () async {
      final protokoll = Protokoll();
      final dienst = McpDienst(
        Einstellungen(),
        MoodleZugang(protokoll),
        protokoll,
        Freigaben(protokoll),
        '',
        profil: Profil.migriert(''),
      );
      final liste = await dienst.werkzeugliste();
      final namen = [for (final t in (liste['tools'] as Map)['tools'] as List) (t as Map)['name'] as String];
      expect(namen, isNotEmpty);
      expect(namen.where((n) => n.contains('plugin') || n.contains('zustimm')), isEmpty);
    });
  });
}
