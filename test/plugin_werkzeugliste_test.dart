// Die Werkzeugliste eines Plugins merken und mit `moocp.exe --werkzeugliste`
// ausgeben (E35, E21): Die App hält fest, was ein zugestimmtes Plugin beim
// Start als Werkzeuge nannte, gebunden an den Stand der Zustimmung; die
// Brücke bekommt die Liste daraus, ohne dass ein Plugin gestartet wird. Die
// Tests laufen in Temp-Ordnern, nie im Einstellungsordner der App, und ohne
// ein Plugin-Programm: Was hier gemerkt wird, kommt aus der Hand der Tests.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/mcp/werkzeugquelle.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/plugin/entscheidung.dart';
import 'package:moocp/plugin/laufende_plugins.dart';
import 'package:moocp/plugin/plugins.dart';
import 'package:moocp/plugin/pruefsumme.dart';
import 'package:moocp/plugin/werkzeugliste.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

class _EinstellungenOhneDatei extends Einstellungen {
  _EinstellungenOhneDatei() : super(schluessel: 'schluessel');
  int gespeichert = 0;
  bool speichernScheitert = false;

  @override
  Future<void> speichern() async {
    if (speichernScheitert) throw const FileSystemException('nicht schreibbar');
    gespeichert++;
  }
}

/// Eine Quelle, die nur ihre Werkzeuge nennt: so, wie der Server die Liste
/// eines laufenden Plugins sieht.
class _Quelle implements WerkzeugQuelle {
  _Quelle(this.liste);
  final List<WerkzeugBeschreibung> liste;

  @override
  List<WerkzeugBeschreibung> werkzeuge(Profil profil) => liste;

  @override
  Future<String> aufrufen(WerkzeugAufruf aufruf) => throw UnimplementedError();
}

WerkzeugBeschreibung _werkzeug(String name, {String? titel, bool nurLesen = false, bool zerstoerend = false}) =>
    WerkzeugBeschreibung(
      name: name,
      titel: titel,
      beschreibung: 'Beschreibung von $name.',
      eingabeSchema: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': 'Was ausgegeben wird.'},
          'anzahl': {'type': 'integer'},
        },
        'required': ['text'],
      },
      nurLesen: nurLesen,
      zerstoerend: zerstoerend,
    );

/// Legt `<plugins>/<ordner>` mit Beschreibungsdatei und Programm an.
Directory _plugin(
  Directory plugins,
  String ordner, {
  String kurzname = 'beispiel',
  String version = '1.0',
  String programm = 'Programm',
}) {
  final d = Directory(p.join(plugins.path, ordner))..createSync(recursive: true);
  File(p.join(d.path, 'plugin.json')).writeAsStringSync(
    jsonEncode({
      'name': 'Plugin $ordner',
      'kurzname': kurzname,
      'version': version,
      'schnittstelle': 1,
      'programm': 'plugin.exe',
      'herkunft': 'Beispiel-Projekt',
    }),
  );
  File(p.join(d.path, 'plugin.exe')).writeAsStringSync(programm);
  return d;
}

List<String> _namen(Map<String, dynamic> liste) => [
  for (final t in (liste['tools'] as Map)['tools'] as List) (t as Map)['name'] as String,
];

void main() {
  late Directory wurzel;
  late Directory pluginOrdner;
  late File datei;
  late Protokoll protokoll;
  late _EinstellungenOhneDatei einstellungen;

  setUp(() {
    wurzel = Directory.systemTemp.createTempSync('moocp_werkzeugliste_');
    pluginOrdner = Directory(p.join(wurzel.path, 'plugins'))..createSync();
    datei = File(p.join(wurzel.path, 'einstellungen.json'));
    protokoll = Protokoll();
    einstellungen = _EinstellungenOhneDatei();
  });
  tearDown(() => wurzel.deleteSync(recursive: true));

  Future<Plugins> laden() => Plugins.laden(einstellungen, protokoll, pluginOrdner);

  PluginEintrag eintrag(Plugins plugins, String ordner) => plugins.eintraege.firstWhere((e) => e.ordner == ordner);

  /// Stimmt dem Plugin zu und merkt seine Werkzeuge, wie es der Start tut.
  Future<void> annehmen(
    Plugins plugins,
    String ordner, {
    Set<String> profile = const {'standard'},
    List<WerkzeugBeschreibung>? werkzeuge,
  }) async {
    final e = eintrag(plugins, ordner);
    await plugins.entscheiden(e, zugestimmt: true, profile: profile);
    if (werkzeuge != null) await plugins.werkzeugeMerken(e, werkzeuge);
  }

  group('Merken und Verwerfen', () {
    setUp(() => _plugin(pluginOrdner, 'beispiel'));

    test('ein zugestimmtes Plugin: Die Liste steht beim Plugin-Eintrag in den Einstellungen', () async {
      final plugins = await laden();
      await annehmen(plugins, 'beispiel', werkzeuge: [_werkzeug('beispiel_echo', titel: 'Echo', nurLesen: true)]);

      final gemerkt = einstellungen.plugins['beispiel']!;
      expect(gemerkt.werkzeuge!.map((w) => w.name), ['beispiel_echo']);
      expect(gemerkt.zugestimmt, isTrue);
      expect(gemerkt.profile, {'standard'});
      expect(einstellungen.gespeichert, 2, reason: 'Zustimmung und Liste');
      expect(
        protokoll.eintraege.map((e) => e.text),
        contains(allOf(contains('„beispiel“'), contains('Werkzeugliste gemerkt'), contains('1 Werkzeug'))),
      );
    });

    test('nach dem Neustart: alles, was ein Werkzeug beschreibt, kommt aus der Datei zurück', () async {
      final plugins = await laden();
      final eins = _werkzeug('beispiel_echo', titel: 'Echo', nurLesen: true);
      final zwei = _werkzeug('beispiel_loeschen', zerstoerend: true);
      await annehmen(plugins, 'beispiel', werkzeuge: [eins, zwei]);

      final json = jsonDecode(jsonEncode(einstellungen.zuJson())) as Map<String, dynamic>;
      final neu = Einstellungen.aus(json, Einstellungen(schluessel: 'x'));

      final liste = neu.plugins['beispiel']!.werkzeuge!;
      expect(liste, hasLength(2));
      for (final (i, w) in [eins, zwei].indexed) {
        expect(liste[i].name, w.name);
        expect(liste[i].beschreibung, w.beschreibung);
        expect(liste[i].titel, w.titel);
        expect(liste[i].nurLesen, w.nurLesen);
        expect(liste[i].zerstoerend, w.zerstoerend);
        expect(jsonEncode(liste[i].eingabeSchema), jsonEncode(w.eingabeSchema));
      }
      // Die Entscheidung selbst bleibt, wie sie war.
      expect(neu.plugins['beispiel']!.zugestimmt, isTrue);
      expect(neu.plugins['beispiel']!.profile, {'standard'});
    });

    test('dieselbe Liste noch einmal gemerkt: nichts wird erneut gespeichert', () async {
      final plugins = await laden();
      await annehmen(plugins, 'beispiel', werkzeuge: [_werkzeug('beispiel_echo')]);
      final vorher = einstellungen.gespeichert;
      final protokollvorher = protokoll.eintraege.length;

      await plugins.werkzeugeMerken(eintrag(plugins, 'beispiel'), [_werkzeug('beispiel_echo')]);

      expect(einstellungen.gespeichert, vorher);
      expect(protokoll.eintraege.length, protokollvorher);
    });

    test('eine andere Liste desselben Stands ersetzt die gemerkte', () async {
      final plugins = await laden();
      await annehmen(plugins, 'beispiel', werkzeuge: [_werkzeug('beispiel_echo')]);

      await plugins.werkzeugeMerken(eintrag(plugins, 'beispiel'), [_werkzeug('beispiel_echo'), _werkzeug('beispiel_zwei')]);

      expect(einstellungen.plugins['beispiel']!.werkzeuge!.map((w) => w.name), ['beispiel_echo', 'beispiel_zwei']);
    });

    test('ohne Zustimmung für diesen Stand wird nichts gemerkt', () async {
      final plugins = await laden();
      final e = eintrag(plugins, 'beispiel');

      await plugins.werkzeugeMerken(e, [_werkzeug('beispiel_echo')]);
      expect(einstellungen.plugins, isEmpty, reason: 'noch nicht entschieden');

      await plugins.entscheiden(e, zugestimmt: false);
      await plugins.werkzeugeMerken(e, [_werkzeug('beispiel_echo')]);
      expect(einstellungen.plugins['beispiel']!.werkzeuge, isNull, reason: 'abgelehnt');
    });

    test('Ablehnen verwirft die Liste', () async {
      final plugins = await laden();
      await annehmen(plugins, 'beispiel', werkzeuge: [_werkzeug('beispiel_echo')]);

      await plugins.entscheiden(eintrag(plugins, 'beispiel'), zugestimmt: false);

      expect(einstellungen.plugins['beispiel']!.zugestimmt, isFalse);
      expect(einstellungen.plugins['beispiel']!.werkzeuge, isNull);
    });

    test('dieselbe Zustimmung noch einmal (etwa mit anderen Profilen) behält die Liste', () async {
      final plugins = await laden();
      await annehmen(plugins, 'beispiel', werkzeuge: [_werkzeug('beispiel_echo')]);

      await plugins.entscheiden(eintrag(plugins, 'beispiel'), zugestimmt: true, profile: {'standard', 'k2'});

      expect(einstellungen.plugins['beispiel']!.profile, {'standard', 'k2'});
      expect(einstellungen.plugins['beispiel']!.werkzeuge!.map((w) => w.name), ['beispiel_echo']);
    });

    test('ein Profil ein- und ausschalten oder löschen behält die Liste', () async {
      final plugins = await laden();
      await annehmen(plugins, 'beispiel', profile: {'standard', 'k2'}, werkzeuge: [_werkzeug('beispiel_echo')]);

      await plugins.profilSchalten(eintrag(plugins, 'beispiel'), 'k2', false);
      expect(einstellungen.plugins['beispiel']!.werkzeuge, isNotNull);
      final ohne = pluginEntscheidungenOhneProfil(einstellungen.plugins, 'standard');
      expect(ohne['beispiel']!.werkzeuge!.map((w) => w.name), ['beispiel_echo']);
    });

    test('ändert sich der Stand, ist die Liste nichts mehr wert: Aufräumen verwirft sie, die Zustimmung zählt nicht mehr', () async {
      var plugins = await laden();
      await annehmen(plugins, 'beispiel', werkzeuge: [_werkzeug('beispiel_echo')]);
      File(p.join(pluginOrdner.path, 'beispiel', 'plugin.exe')).writeAsStringSync('Ein anderes Programm');
      plugins = await laden();
      expect(plugins.stand(eintrag(plugins, 'beispiel')).zustand, PluginZustand.offen);

      await plugins.werkzeugeAufraeumen();

      expect(einstellungen.plugins['beispiel']!.werkzeuge, isNull);
    });

    test('stimmt die Lehrkraft einem neuen Stand zu, beginnt die Liste leer', () async {
      var plugins = await laden();
      await annehmen(plugins, 'beispiel', werkzeuge: [_werkzeug('beispiel_echo')]);
      File(p.join(pluginOrdner.path, 'beispiel', 'plugin.exe')).writeAsStringSync('Ein anderes Programm');
      plugins = await laden();

      await plugins.entscheiden(eintrag(plugins, 'beispiel'), zugestimmt: true, profile: {'standard'});

      expect(einstellungen.plugins['beispiel']!.werkzeuge, isNull, reason: 'bis das neue Plugin gestartet ist');
    });

    test('ein Plugin, das es nicht mehr gibt, verliert seine Liste', () async {
      var plugins = await laden();
      await annehmen(plugins, 'beispiel', werkzeuge: [_werkzeug('beispiel_echo')]);
      Directory(p.join(pluginOrdner.path, 'beispiel')).deleteSync(recursive: true);
      plugins = await laden();
      expect(plugins.eintraege, isEmpty);

      await plugins.werkzeugeAufraeumen();

      expect(einstellungen.plugins['beispiel']!.werkzeuge, isNull);
      expect(einstellungen.plugins['beispiel']!.zugestimmt, isTrue, reason: 'die Zustimmung bleibt, wie sie war');
    });

    test('ein Plugin, das nicht mehr lädt, verliert seine Liste', () async {
      var plugins = await laden();
      await annehmen(plugins, 'beispiel', werkzeuge: [_werkzeug('beispiel_echo')]);
      File(p.join(pluginOrdner.path, 'beispiel', 'plugin.json')).writeAsStringSync('{ kaputt');
      plugins = await laden();
      expect(plugins.stand(eintrag(plugins, 'beispiel')).zustand, PluginZustand.nichtGeladen);

      await plugins.werkzeugeAufraeumen();

      expect(einstellungen.plugins['beispiel']!.werkzeuge, isNull);
    });

    test('Aufräumen lässt die Liste eines zugestimmten Plugins stehen und speichert dann nichts', () async {
      final plugins = await laden();
      await annehmen(plugins, 'beispiel', werkzeuge: [_werkzeug('beispiel_echo')]);
      final vorher = einstellungen.gespeichert;

      await plugins.werkzeugeAufraeumen();

      expect(einstellungen.plugins['beispiel']!.werkzeuge, isNotNull);
      expect(einstellungen.gespeichert, vorher);
    });

    test('der Start der Plugins räumt auf: Ein Plugin, das fort ist, verliert seine Liste', () async {
      var plugins = await laden();
      await annehmen(plugins, 'beispiel', werkzeuge: [_werkzeug('beispiel_echo')]);
      Directory(p.join(pluginOrdner.path, 'beispiel')).deleteSync(recursive: true);
      plugins = await laden();

      await LaufendePlugins(protokoll).starten(plugins, eingebaut: const {});

      expect(einstellungen.plugins['beispiel']!.werkzeuge, isNull);
    });

    test('scheitert das Speichern, gilt die Liste für diesen Lauf, und das Protokoll nennt nur den Typ', () async {
      final plugins = await laden();
      await annehmen(plugins, 'beispiel');
      einstellungen.speichernScheitert = true;

      await plugins.werkzeugeMerken(eintrag(plugins, 'beispiel'), [_werkzeug('beispiel_echo')]);

      expect(einstellungen.plugins['beispiel']!.werkzeuge, isNotNull);
      final fehler = protokoll.eintraege.where((e) => e.art == Art.fehler).single.text;
      expect(fehler, contains('FileSystemException'));
      expect(fehler, isNot(contains('nicht schreibbar')));
    });
  });

  group('In der Einstellungsdatei', () {
    test('ohne gemerkte Liste steht kein Schlüssel `werkzeuge` in der Datei', () {
      final e = Einstellungen(
        schluessel: 'x',
        plugins: {'eins': const PluginEntscheidung(version: '1', pruefsumme: 'aa', zugestimmt: true)},
      );
      expect((e.zuJson()['plugins'] as Map)['eins'], isNot(contains('werkzeuge')));
    });

    test('eine beschädigte Liste fällt weg, die Entscheidung bleibt: nie wird daraus eine Zustimmung oder eine Ablehnung', () {
      Map<String, dynamic> eintrag(Object? werkzeuge) => {
        'version': '1',
        'pruefsumme': 'aa',
        'zugestimmt': true,
        'profile': ['standard'],
        'werkzeuge': werkzeuge,
      };
      Map<String, Object?> gut() => {
        'name': 'beispiel_echo',
        'beschreibung': 'Gibt aus.',
        'eingabeSchema': {'type': 'object'},
      };
      final j = <String, dynamic>{
        'schluessel': 'x',
        'plugins': {
          'text': eintrag('kaputt'),
          'keinName': eintrag([
            {...gut()}..remove('name'),
          ]),
          'leererName': eintrag([
            {...gut(), 'name': ''},
          ]),
          'schemaText': eintrag([
            {...gut(), 'eingabeSchema': 'x'},
          ]),
          'schemaKeinObjekt': eintrag([
            {...gut(), 'eingabeSchema': {'type': 'string'}},
          ]),
          'titelKeinText': eintrag([
            {...gut(), 'titel': 5},
          ]),
          'eineKaputte': eintrag([gut(), 'x']),
          'heil': eintrag([gut()]),
        },
      };

      final neu = Einstellungen.aus(j, Einstellungen(schluessel: 'x'));

      for (final k in ['text', 'keinName', 'leererName', 'schemaText', 'schemaKeinObjekt', 'titelKeinText', 'eineKaputte']) {
        expect(neu.plugins[k], isNotNull, reason: k);
        expect(neu.plugins[k]!.werkzeuge, isNull, reason: k);
        expect(neu.plugins[k]!.zugestimmt, isTrue, reason: k);
        expect(neu.plugins[k]!.profile, {'standard'}, reason: k);
      }
      expect(neu.plugins['heil']!.werkzeuge!.single.name, 'beispiel_echo');
    });
  });

  group('--werkzeugliste', () {
    /// Was `moocp.exe --werkzeugliste` ausgibt, mit den Orten dieses Tests.
    Future<Map<String, dynamic>> liste() =>
        werkzeuglisteFuerBruecke(einstellungen: () => datei, plugins: () => pluginOrdner);

    void speichern() => datei.writeAsStringSync(jsonEncode(einstellungen.zuJson()));

    McpDienst dienst(List<WerkzeugQuelle> quellen) => McpDienst(
      Einstellungen(schluessel: ''),
      MoodleZugang(protokoll),
      protokoll,
      Freigaben(protokoll),
      '',
      profil: Profil.migriert(''),
      werkzeugquellen: quellen,
    );

    Future<List<String>> eingebaut() async => _namen(await dienst(const []).werkzeugliste());

    /// Ein Plugin im Ordner, angenommen, mit gemerkter Liste, in der Datei.
    Future<void> gemerkt(
      String ordner,
      List<WerkzeugBeschreibung> werkzeuge, {
      String kurzname = 'beispiel',
      Set<String> profile = const {'standard'},
    }) async {
      _plugin(pluginOrdner, ordner, kurzname: kurzname);
      final plugins = await laden();
      await annehmen(plugins, ordner, profile: profile, werkzeuge: werkzeuge);
      speichern();
    }

    test('ein Werkzeug, dessen Name mit dem Profilnamen davor über 64 Zeichen käme, fehlt in diesem Profil', () {
      WerkzeugBeschreibung w(String name) =>
          WerkzeugBeschreibung(name: name, beschreibung: 'Probe', eingabeSchema: const {'type': 'object'});
      final quelle = GemerkteWerkzeuge('standard', [w('beispiel_echo'), w('beispiel_moodle_schreiben')]);
      Profil profil(String mcpName) =>
          Profil(kennung: 'standard', name: 'Moodle', adresse: '', port: 1, mcpName: mcpName);

      expect([for (final x in quelle.werkzeuge(profil('moodle'))) x.name], ['beispiel_echo', 'beispiel_moodle_schreiben']);
      expect([for (final x in quelle.werkzeuge(profil('moodle-${'x' * 33}'))) x.name], ['beispiel_echo']);
    });

    test('ohne Plugin ist die Ausgabe Byte für Byte die, die sie vor den Plugins war', () async {
      final bisher = jsonEncode(await dienst([LaufendePlugins(protokoll)]).werkzeugliste());
      expect(jsonEncode(await dienst(const []).werkzeugliste()), bisher);

      // Keine Einstellungsdatei, keine Plugins.
      expect(jsonEncode(await liste()), bisher);
      // Eine Datei ohne Plugins.
      speichern();
      expect(jsonEncode(await liste()), bisher);
      // Ein zugestimmtes Plugin ohne gemerkte Liste: noch nie gestartet.
      _plugin(pluginOrdner, 'beispiel');
      await annehmen(await laden(), 'beispiel');
      speichern();
      expect(jsonEncode(await liste()), bisher);
    });

    test('ein gemerktes Plugin im Standardprofil steht nach den eingebauten, wie der Server es nennen würde', () async {
      final werkzeuge = [
        _werkzeug('beispiel_echo', titel: 'Echo', nurLesen: true),
        _werkzeug('beispiel_aufraeumen', zerstoerend: true),
      ];
      await gemerkt('beispiel', werkzeuge);

      final ausgabe = await liste();

      expect(_namen(ausgabe), [...await eingebaut(), 'beispiel_echo', 'beispiel_aufraeumen']);
      expect(jsonEncode(ausgabe), jsonEncode(await dienst([_Quelle(werkzeuge)]).werkzeugliste()));
    });

    test('mehrere Plugins: in der Reihenfolge der Ordner', () async {
      await gemerkt('b-zweites', [_werkzeug('zwei_x')], kurzname: 'zwei');
      _plugin(pluginOrdner, 'a-erstes', kurzname: 'eins');
      final plugins = await laden();
      await annehmen(plugins, 'a-erstes', werkzeuge: [_werkzeug('eins_x')]);
      speichern();

      expect(_namen(await liste()).skip((await eingebaut()).length), ['eins_x', 'zwei_x']);
    });

    test('ist das Plugin nur in einem anderen Profil eingeschaltet, fehlt es', () async {
      await gemerkt('beispiel', [_werkzeug('beispiel_echo')], profile: {'k2'});

      expect(jsonEncode(await liste()), jsonEncode(await dienst(const []).werkzeugliste()));
    });

    test('in beiden Profilen eingeschaltet, steht es in der Liste des Standardprofils', () async {
      await gemerkt('beispiel', [_werkzeug('beispiel_echo')], profile: {'standard', 'k2'});

      expect(_namen(await liste()), contains('beispiel_echo'));
    });

    test('weicht die Prüfsumme ab, fehlt das Plugin, die eingebauten bleiben', () async {
      await gemerkt('beispiel', [_werkzeug('beispiel_echo')]);
      File(p.join(pluginOrdner.path, 'beispiel', 'plugin.exe')).writeAsStringSync('Ein ausgetauschtes Programm');

      expect(jsonEncode(await liste()), jsonEncode(await dienst(const []).werkzeugliste()));
    });

    test('weicht die Version ab, fehlt das Plugin', () async {
      await gemerkt('beispiel', [_werkzeug('beispiel_echo')]);
      _plugin(pluginOrdner, 'beispiel', version: '1.1');

      expect(_namen(await liste()), isNot(contains('beispiel_echo')));
    });

    test('abgelehnt: fehlt, auch wenn noch eine Liste in der Datei steht', () async {
      _plugin(pluginOrdner, 'beispiel');
      final e = eintrag(await laden(), 'beispiel');
      einstellungen.plugins = {
        'beispiel': PluginEntscheidung(
          version: '1.0',
          pruefsumme: e.pruefsumme!,
          zugestimmt: false,
          werkzeuge: [_werkzeug('beispiel_echo')],
        ),
      };
      speichern();

      expect(_namen(await liste()), isNot(contains('beispiel_echo')));
    });

    test('der Ordner des Plugins fehlt: ohne es, die anderen Plugins bleiben', () async {
      await gemerkt('weg', [_werkzeug('weg_x')], kurzname: 'weg');
      await gemerkt('da', [_werkzeug('da_x')], kurzname: 'da');
      Directory(p.join(pluginOrdner.path, 'weg')).deleteSync(recursive: true);

      final namen = _namen(await liste());

      expect(namen, contains('da_x'));
      expect(namen, isNot(contains('weg_x')));
      expect(namen, containsAll(await eingebaut()));
    });

    test('der Plugin-Ordner selbst fehlt: nur die eingebauten', () async {
      await gemerkt('beispiel', [_werkzeug('beispiel_echo')]);
      pluginOrdner.deleteSync(recursive: true);

      expect(jsonEncode(await liste()), jsonEncode(await dienst(const []).werkzeugliste()));
    });

    test('eine Verknüpfung statt des Ordners: ohne das Plugin, die anderen bleiben', () async {
      await gemerkt('da', [_werkzeug('da_x')], kurzname: 'da');
      await gemerkt('verweis', [_werkzeug('verweis_x')], kurzname: 'verweis');
      final ziel = Directory(p.join(wurzel.path, 'woanders'));
      Directory(p.join(pluginOrdner.path, 'verweis')).renameSync(ziel.path);
      try {
        Link(p.join(pluginOrdner.path, 'verweis')).createSync(ziel.path);
      } on FileSystemException {
        markTestSkipped('Verknüpfungen lassen sich hier nicht anlegen (fehlendes Recht).');
        return;
      }

      final namen = _namen(await liste());

      expect(namen, contains('da_x'));
      expect(namen, isNot(contains('verweis_x')));
    });

    test('eine Datei, die sich nicht lesen lässt, hält das Plugin zurück und sonst nichts', () async {
      await gemerkt('da', [_werkzeug('da_x')], kurzname: 'da');
      await gemerkt('kaputt', [_werkzeug('kaputt_x')], kurzname: 'kaputt');
      File(p.join(pluginOrdner.path, 'kaputt', 'plugin.json')).writeAsBytesSync([0xff, 0xfe, 0x00, 0x80]);

      final namen = _namen(await liste());

      expect(namen, contains('da_x'));
      expect(namen, isNot(contains('kaputt_x')));
    });

    test('ein Werkzeugname, der nicht zum Kurznamen passt oder einem eingebauten gleicht, hält das Plugin zurück', () async {
      await gemerkt('da', [_werkzeug('da_x')], kurzname: 'da');
      // `kurs_filter` ist ein eingebautes Werkzeug.
      await gemerkt('eng', [_werkzeug('kurs_filter')], kurzname: 'kurs');
      await gemerkt('fremd', [_werkzeug('status')], kurzname: 'fremd');

      final ausgabe = await liste();
      final namen = _namen(ausgabe);

      expect(namen, [...await eingebaut(), 'da_x']);
      expect(namen.where((n) => n == 'kurs_filter'), hasLength(1));
    });

    test('eine beschädigte Einstellungsdatei: die eingebauten Werkzeuge, wie sonst', () async {
      await gemerkt('beispiel', [_werkzeug('beispiel_echo')]);
      datei.writeAsStringSync('{ das ist kein JSON');

      expect(jsonEncode(await liste()), jsonEncode(await dienst(const []).werkzeugliste()));
    });

    test('eine Liste, deren Schema kein Objekt beschreibt, wird nicht ausgegeben', () async {
      await gemerkt('beispiel', [_werkzeug('beispiel_echo')]);
      final j = jsonDecode(datei.readAsStringSync()) as Map<String, dynamic>;
      ((((j['plugins'] as Map)['beispiel'] as Map)['werkzeuge'] as List).single as Map)['eingabeSchema'] = {'type': 'string'};
      datei.writeAsStringSync(jsonEncode(j));

      expect(jsonEncode(await liste()), jsonEncode(await dienst(const []).werkzeugliste()));
    });

    test('ein Schema, das der Server nicht annimmt, nimmt der Brücke nicht die eingebauten Werkzeuge', () async {
      await gemerkt('beispiel', [_werkzeug('beispiel_echo')]);
      final j = jsonDecode(datei.readAsStringSync()) as Map<String, dynamic>;
      ((((j['plugins'] as Map)['beispiel'] as Map)['werkzeuge'] as List).single as Map)['eingabeSchema'] = {
        'type': 'object',
        'properties': 5,
      };
      datei.writeAsStringSync(jsonEncode(j));

      expect(jsonEncode(await liste()), jsonEncode(await dienst(const []).werkzeugliste()));
    });

    test('die Ausgabe ist eine Zeile JSON und enthält nur Namen, Beschreibungen und Parameter', () async {
      await gemerkt('beispiel', [_werkzeug('beispiel_echo', titel: 'Echo')]);

      final zeile = jsonEncode(await liste());

      expect(zeile, isNot(contains('\n')));
      expect(zeile, isNot(contains(einstellungen.schluessel)));
      expect(zeile, isNot(contains(einstellungen.plugins['beispiel']!.pruefsumme)));
    });

    test('der Quelltext liest und startet nichts: kein Prozess, keine laufenden Plugins', () {
      final text = File('lib/plugin/werkzeugliste.dart').readAsStringSync();

      expect(text, isNot(contains('Process')));
      expect(text, isNot(contains('laufende_plugins')));
      expect(text, isNot(contains('LaufendePlugins')));
    });

    test('das Plugin-Programm wird weder gelesen noch ausgeführt: nur die Prüfsumme sieht es', () async {
      await gemerkt('beispiel', [_werkzeug('beispiel_echo')]);
      final programm = File(p.join(pluginOrdner.path, 'beispiel', 'plugin.exe'));
      final vorher = await pluginPruefsumme(Directory(p.join(pluginOrdner.path, 'beispiel')));

      await liste();

      expect(await pluginPruefsumme(Directory(p.join(pluginOrdner.path, 'beispiel'))), vorher, reason: 'nichts geschrieben');
      expect(programm.readAsStringSync(), 'Programm');
    });
  });
}
