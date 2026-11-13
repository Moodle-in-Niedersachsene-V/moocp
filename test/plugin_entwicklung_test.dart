// Ein Entwicklungs-Plugin anhängen (E35, „Entwickeln“): `--plugin-entwicklung
// <Ordner>` auf der Kommandozeile, die Beschreibungsdatei aus diesem Ordner,
// der Schlüssel aus der Umgebung, und die Verbindung zu einem Plugin, das
// schon läuft. Auf der anderen Seite steht das Beispiel-Plugin
// (beispiele/plugin/) als Prozess, den der Test selbst startet, wie ein
// Entwickler es täte; wo eine andere Werkzeugliste gebraucht wird, ein kleiner
// MCP-Server im Test. Den Dialog davor prüft test/profile_ausblenden_test.dart.
// Alles in Temp-Ordnern, nie im Einstellungsordner der App.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/plugin/beschreibung.dart';
import 'package:moocp/plugin/dialoge.dart';
import 'package:moocp/plugin/entwicklung.dart';
import 'package:moocp/plugin/laufende_plugins.dart';
import 'package:moocp/plugin/plugins.dart';
import 'package:moocp/plugin/verbindung.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'mcp_client.dart';

class _EinstellungenOhneDatei extends Einstellungen {
  _EinstellungenOhneDatei({super.profile}) : super(schluessel: 'test');

  /// Wie oft die App ihre Einstellungen geschrieben hätte.
  int gespeichert = 0;

  @override
  Future<void> speichern() async => gespeichert++;
}

/// Das `dart` des Flutter-SDK (wie in test/plugin_start_test.dart).
String _dart() {
  final exe = Platform.isWindows ? 'dart.exe' : 'dart';
  final wurzel = Platform.environment['FLUTTER_ROOT'];
  if (wurzel != null) {
    final f = File(p.join(wurzel, 'bin', 'cache', 'dart-sdk', 'bin', exe));
    if (f.existsSync()) return f.path;
  }
  var d = File(Platform.resolvedExecutable).parent;
  while (d.parent.path != d.path) {
    final f = File(p.join(d.path, 'dart-sdk', 'bin', exe));
    if (f.existsSync()) return f.path;
    d = d.parent;
  }
  throw StateError('Das dart des Flutter-SDK ist nicht zu finden.');
}

Profil _profil(String kennung, String mcpName, int port) => Profil(
  kennung: kennung,
  name: mcpName,
  adresse: 'https://$kennung.moodle.schule.example',
  port: port,
  mcpName: mcpName,
  schluessel: 'test',
);

Future<int> _freierPort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

Future<Set<String>> _eingebaut() {
  final protokoll = Protokoll();
  return McpDienst(
    Einstellungen(schluessel: ''),
    MoodleZugang(protokoll),
    protokoll,
    Freigaben(protokoll),
    '',
    profil: Profil.migriert(''),
  ).eingebauteWerkzeugnamen();
}

Future<bool> _laeuft(int pid) async {
  if (Platform.isWindows) {
    final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return '${r.stdout}'.contains(' $pid ');
  }
  return (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;
}

/// Wartet, bis [bedingung] gilt, höchstens [frist].
Future<void> _bis(bool Function() bedingung, {Duration frist = const Duration(seconds: 15)}) async {
  final ende = DateTime.now().add(frist);
  while (!bedingung()) {
    if (DateTime.now().isAfter(ende)) fail('Die Bedingung trat nicht binnen ${frist.inSeconds} Sekunden ein.');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

const _schluessel = 'entwicklungs-schluessel-0123456789abcdefghijklmnop';

/// Die Werkzeuge des Beispiel-Plugins in der Reihenfolge seiner Liste.
const _beispielWerkzeuge = [
  'beispiel_echo',
  'beispiel_absturz',
  'beispiel_protokoll',
  'beispiel_datei',
  'beispiel_status',
  'beispiel_auswahl',
  'beispiel_eingabe',
  'beispiel_pfad',
  'beispiel_hinweis',
  'beispiel_freigabe',
  'beispiel_moodle_lesen',
  'beispiel_moodle_gesperrt',
  'beispiel_moodle_schreiben',
  'beispiel_lauf',
  'beispiel_download',
  'beispiel_namen',
];

void main() {
  group('Die Kommandozeile', () {
    test('ohne den Schalter: nichts', () {
      expect(entwicklungsOrdnerAus(const []), isNull);
      expect(entwicklungsOrdnerAus(const ['--kein-update']), isNull);
    });

    test('mit Ordner: der Ordner, auch zwischen anderen Schaltern', () {
      expect(entwicklungsOrdnerAus(const ['--plugin-entwicklung', r'C:\plugins\beispiel']), r'C:\plugins\beispiel');
      expect(
        entwicklungsOrdnerAus(const ['--kein-update', '--plugin-entwicklung', '/home/e.mustermann/beispiel', '--x']),
        '/home/e.mustermann/beispiel',
      );
    });

    test('ohne Ordner dahinter: leer, und das Vorbereiten nennt den Grund', () {
      expect(entwicklungsOrdnerAus(const ['--plugin-entwicklung']), '');
      expect(entwicklungsOrdnerAus(const ['--plugin-entwicklung', '--kein-update']), '');
      expect(
        () => entwicklungVorbereiten('', const {schluesselVariable: _schluessel}),
        throwsA(isA<PluginFehler>().having((f) => f.grund, 'grund', contains('fehlt der Ordner'))),
      );
    });
  });

  group('Vorbereiten: Beschreibungsdatei und Schlüssel', () {
    late Directory wurzel;
    setUp(() => wurzel = Directory.systemTemp.createTempSync('moocp_entwicklung_'));
    tearDown(() => wurzel.deleteSync(recursive: true));

    Map<String, Object?> manifest({Object? port = 47900, Object? zusatzadressen, String kurzname = 'beispiel'}) => {
      'name': 'Beispiel',
      'kurzname': kurzname,
      'version': '1.0.0',
      'schnittstelle': 1,
      'programm': 'beispiel.exe',
      'herkunft': 'Beispiel-Projekt',
      'entwicklungsPort': ?port,
      'zusatzadressen': ?zusatzadressen,
    };

    String ordner(Map<String, Object?> m) {
      final d = Directory(p.join(wurzel.path, 'beispiel'))..createSync();
      File(p.join(d.path, 'plugin.json')).writeAsStringSync(jsonEncode(m));
      return d.path;
    }

    Matcher grund(String teil) => throwsA(isA<PluginFehler>().having((f) => f.grund, 'grund', contains(teil)));

    test('gelingt mit Beschreibungsdatei, Entwicklungsport und Schlüssel; das Programm muss nicht im Ordner liegen', () {
      final plugin = entwicklungVorbereiten(
        ordner(manifest(zusatzadressen: [
          {'muster': '/mod/beispiel/view.php', 'art': 'lesen', 'grund': 'Liest die Seite.'},
        ])),
        const {schluesselVariable: _schluessel},
      );
      expect(plugin.name, 'Beispiel');
      expect(plugin.kurzname, 'beispiel');
      expect(plugin.port, 47900);
      expect(p.isAbsolute(plugin.ordner), isTrue);
      expect(plugin.beschreibung.zusatzadressen.single.muster.text, '/mod/beispiel/view.php');
      expect('$plugin', isNot(contains(_schluessel)));
    });

    test('ohne Schlüssel oder mit leerem keine Verbindung: Das Vorbereiten scheitert und nennt die Variable', () {
      final o = ordner(manifest());
      expect(() => entwicklungVorbereiten(o, const {}), grund(schluesselVariable));
      expect(() => entwicklungVorbereiten(o, const {schluesselVariable: ''}), grund('fehlt oder ist leer'));
      expect(() => entwicklungVorbereiten(o, const {schluesselVariable: '  '}), grund('fehlt oder ist leer'));
    });

    test('ein fehlender Ordner, eine fehlende oder ungültige Beschreibungsdatei, kein Entwicklungsport', () {
      const umgebung = {schluesselVariable: _schluessel};
      expect(() => entwicklungVorbereiten(p.join(wurzel.path, 'fehlt'), umgebung), grund('gibt es nicht'));
      final leer = Directory(p.join(wurzel.path, 'leer'))..createSync();
      expect(() => entwicklungVorbereiten(leer.path, umgebung), grund('plugin.json fehlt'));
      File(p.join(leer.path, 'plugin.json')).writeAsStringSync('{kaputt');
      expect(() => entwicklungVorbereiten(leer.path, umgebung), grund('keine gültige JSON-Datei'));
      expect(() => entwicklungVorbereiten(ordner(manifest(port: null)), umgebung), grund('entwicklungsPort'));
    });

    test('dieselben Regeln wie für ein installiertes Plugin: gesperrte Bereiche, Länge des Kurznamens', () {
      const umgebung = {schluesselVariable: _schluessel};
      expect(
        () => entwicklungVorbereiten(
          ordner(manifest(zusatzadressen: [
            {'muster': '/admin/*', 'art': 'lesen', 'grund': 'x'},
          ])),
          umgebung,
        ),
        grund('gesperrten Bereich'),
      );
      Directory(p.join(wurzel.path, 'beispiel')).deleteSync(recursive: true);
      expect(() => entwicklungVorbereiten(ordner(manifest(kurzname: 'vielzulangername')), umgebung), grund('zu lang'));
    });
  });

  group('Das angehängte Beispiel-Plugin', () {
    late Directory vorlage;
    late String exe;
    late Set<String> eingebaut;

    setUpAll(() async {
      vorlage = Directory.systemTemp.createTempSync('moocp_beispiel_');
      exe = p.join(vorlage.path, 'beispiel.exe');
      final r = await Process.run(_dart(), ['compile', 'exe', p.join('beispiele', 'plugin', 'beispiel.dart'), '-o', exe]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      eingebaut = await _eingebaut();
    });
    tearDownAll(() => vorlage.deleteSync(recursive: true));

    late Directory wurzel;
    late Protokoll protokoll;
    late _EinstellungenOhneDatei einstellungen;
    late int port;
    late String ordner;
    final prozesse = <Process>[];
    final laufende = <LaufendePlugins>[];
    final dienste = <McpDienst>[];
    final clients = <McpTestClient>[];
    final stopps = <Future<void> Function()>[];

    setUp(() async {
      wurzel = Directory.systemTemp.createTempSync('moocp_entwicklung_');
      protokoll = Protokoll();
      port = await _freierPort();
      // Der Ordner des Entwicklers: Beschreibungsdatei mit freiem
      // Entwicklungsport, kein Programm darin -- es läuft schon.
      ordner = (Directory(p.join(wurzel.path, 'entwicklung'))..createSync()).path;
      final m = jsonDecode(File(p.join('beispiele', 'plugin', 'plugin.json')).readAsStringSync()) as Map;
      m['entwicklungsPort'] = port;
      // Viele Tests stellen an die Stelle des Beispiels einen Server mit
      // anderen Werkzeugen; ohneAnmeldung nennt deshalb keines (sonst ließe
      // die App ihn nicht zu). Die Tests dazu setzen sie selbst
      // (ohneAnmeldungSetzen).
      m['ohneAnmeldung'] = <String>[];
      File(p.join(ordner, 'plugin.json')).writeAsStringSync(jsonEncode(m));
      einstellungen = _EinstellungenOhneDatei(profile: [
        _profil('standard', 'moodle', await _freierPort()),
        _profil('k2', 'moodle-test', await _freierPort()),
      ]);
    });

    tearDown(() async {
      for (final c in clients) {
        c.http.close(force: true);
      }
      clients.clear();
      for (final d in dienste) {
        await d.stoppen();
      }
      dienste.clear();
      for (final l in laufende) {
        await l.beenden();
      }
      laufende.clear();
      for (final s in stopps) {
        await s();
      }
      stopps.clear();
      for (final pr in prozesse) {
        pr.kill();
        await pr.exitCode;
      }
      prozesse.clear();
      wurzel.deleteSync(recursive: true);
    });

    /// Startet das Beispiel-Plugin, wie ein Entwickler es tut: auf dem
    /// Entwicklungsport, mit dem Schlüssel in der Umgebung, mit
    /// `--entwicklung`.
    Future<Process> pluginStarten({String schluessel = _schluessel}) async {
      final pr = await Process.start(
        exe,
        ['--port', '$port', '--entwicklung'],
        environment: {schluesselVariable: schluessel},
      );
      pr.stdout.listen((_) {});
      pr.stderr.listen((_) {});
      prozesse.add(pr);
      return pr;
    }

    Future<void> pluginBeenden(Process pr) async {
      pr.kill();
      await pr.exitCode;
      prozesse.remove(pr);
    }

    LaufendePlugins neueLaufende({void Function()? gestartet}) {
      final l = LaufendePlugins(
        protokoll,
        entwicklungsIntervall: const Duration(milliseconds: 200),
        entwicklungsFrist: const Duration(seconds: 2),
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) {
          gestartet?.call();
          throw const ProcessException('nie', []);
        },
      );
      laufende.add(l);
      return l;
    }

    EntwicklungsPlugin vorbereitet() => entwicklungVorbereiten(ordner, const {schluesselVariable: _schluessel});

    Future<McpTestClient> verbinden(Profil profil, LaufendePlugins quelle) async {
      final d = McpDienst(
        einstellungen,
        MoodleZugang(protokoll),
        protokoll,
        Freigaben(protokoll),
        '',
        profil: profil,
        werkzeugquellen: [quelle],
      );
      dienste.add(d);
      await d.starten();
      final c = McpTestClient(profil.port);
      clients.add(c);
      await c.initialize();
      return c;
    }

    Future<List<String>> werkzeugnamen(McpTestClient c) async => [
      for (final t in (await c.call('tools/list'))['tools'] as List) (t as Map)['name'] as String,
    ];

    Future<Map> aufruf(McpTestClient c, String name, [Map<String, Object?> args = const {}]) =>
        c.call('tools/call', {'name': name, 'arguments': args});

    String text(Map r) => ((r['content'] as List).single as Map)['text'] as String;

    List<String> zeilen() => [for (final e in protokoll.eintraege) e.text];

    test('ohne Anhängen keine Verbindung: Das laufende Plugin bekommt keine Anfrage, und es gibt keine Werkzeuge', () async {
      var anfragen = 0;
      final fremd = await _fremderServer(port, const ['beispiel_echo'], gezaehlt: () => anfragen++);
      stopps.add(fremd);
      final l = neueLaufende();
      final client = await verbinden(einstellungen.profile.first, l);

      expect(await werkzeugnamen(client), isNot(contains('beispiel_echo')));
      expect(l.entwicklung, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(anfragen, 0);
    });

    test('nach dem Anhängen: verbunden, in jedem Profil eingeschaltet, nichts in den Einstellungen, kein Schlüssel im Protokoll',
        () async {
      await pluginStarten();
      final l = neueLaufende();

      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);

      expect(l.entwicklung, (name: 'Beispiel', verbunden: true));
      final a = await verbinden(einstellungen.profile[0], l);
      final b = await verbinden(einstellungen.profile[1], l);
      expect(await werkzeugnamen(a), containsAll(['beispiel_echo', 'beispiel_absturz']));
      expect(await a.tool('beispiel_echo', {'text': 'a'}), 'Echo: a\nProfil: moodle\nAufruf-Token: erhalten\nSchnittstelle: 1');
      expect(await b.tool('beispiel_echo', {'text': 'b'}), contains('Profil: moodle-test\n'));
      expect(zeilen(), contains('Entwicklungs-Plugin „Beispiel“ verbunden (16 Werkzeuge)'));
      expect(zeilen().join('\n'), isNot(contains(_schluessel)));
      expect(einstellungen.gespeichert, 0);
      expect(einstellungen.plugins, isEmpty);
    });

    test('auch ein angehängtes Plugin erreicht die Adresse der App, mit dem Schlüssel aus der Umgebung', () async {
      await pluginStarten();
      final l = neueLaufende();
      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);
      final client = await verbinden(einstellungen.profile.first, l);

      expect(await client.tool('beispiel_protokoll', {'text': 'aus der Entwicklung'}), 'Die Zeile steht im Protokoll von moocp.');
      expect(await client.tool('beispiel_status', {}), contains('Angemeldet: nein -- bitte in der App anmelden'));
      expect(zeilen(), contains('Plugin „Beispiel“: aus der Entwicklung'));
      expect(zeilen(), contains('status({}) -- Aufrufer: Plugin „Beispiel“'));
      expect(zeilen().join('\n'), isNot(contains(_schluessel)));
    });

    /// Schreibt die Beschreibungsdatei im Ordner des Entwicklers mit
    /// [ohneAnmeldung] neu.
    void ohneAnmeldungSetzen(List<String> ohneAnmeldung) {
      final datei = File(p.join(ordner, 'plugin.json'));
      final m = jsonDecode(datei.readAsStringSync()) as Map;
      datei.writeAsStringSync(jsonEncode({...m, 'ohneAnmeldung': ohneAnmeldung}));
    }

    test('Werkzeuge ohne Anmeldung: der Server startet vor der Anmeldung, schon bevor das Plugin verbunden ist', () async {
      ohneAnmeldungSetzen(['beispiel_echo', 'beispiel_protokoll']);
      final l = neueLaufende();
      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);
      expect(l.entwicklung?.verbunden, isFalse);
      expect(l.ohneAnmeldungIn(einstellungen.profile[0]), isTrue, reason: 'nach der Beschreibungsdatei');
      expect(l.ohneAnmeldungIn(einstellungen.profile[1]), isTrue, reason: 'in jedem Profil eingeschaltet');

      await pluginStarten();
      await _bis(() => l.entwicklung?.verbunden == true);
      expect(
        [for (final w in l.werkzeuge(einstellungen.profile.first)) if (w.ohneAnmeldung) w.name],
        ['beispiel_echo', 'beispiel_protokoll'],
      );
    });

    test('nennt ohneAnmeldung ein Werkzeug, das das Plugin nicht hat, verbindet sich die App nicht', () async {
      ohneAnmeldungSetzen(['beispiel_echo', 'beispiel_gibtesnicht']);
      await pluginStarten();
      final l = neueLaufende();
      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);

      expect(l.entwicklung, (name: 'Beispiel', verbunden: false));
      expect(l.werkzeuge(einstellungen.profile.first), isEmpty);
      expect(
        zeilen(),
        contains(
          'Entwicklungs-Plugin „Beispiel“ nicht verbunden: Das Feld „ohneAnmeldung“ nennt das Werkzeug '
          '„beispiel_gibtesnicht“, das das Plugin nicht hat.',
        ),
      );
    });

    test('mit einem anderen Schlüssel beim Plugin keine Verbindung', () async {
      await pluginStarten(schluessel: 'ein-anderer-schluessel');
      final l = neueLaufende();

      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);

      expect(l.entwicklung, (name: 'Beispiel', verbunden: false));
      expect(l.werkzeuge(einstellungen.profile.first), isEmpty);
    });

    test('neu gestartet: Die App verbindet sich wieder, mit demselben Schlüssel; dazwischen nennen die Werkzeuge den Grund',
        () async {
      final erster = await pluginStarten();
      final l = neueLaufende();
      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);
      final client = await verbinden(einstellungen.profile.first, l);
      expect(await client.tool('beispiel_echo', {'text': 'vorher'}), startsWith('Echo: vorher'));

      await pluginBeenden(erster);
      await _bis(() => l.entwicklung?.verbunden == false);

      final r = await aufruf(client, 'beispiel_echo', {'text': 'weg'});
      expect(r['isError'], true);
      expect(text(r), contains('Entwicklungs-Plugin „Beispiel“ ist gerade nicht verbunden'));
      final neu = McpTestClient(einstellungen.profile.first.port);
      clients.add(neu);
      await neu.initialize();
      expect(await werkzeugnamen(neu), contains('beispiel_echo'), reason: 'die zuletzt bekannten bleiben gelistet');
      expect(l.entwicklung, (name: 'Beispiel', verbunden: false));

      await pluginStarten();
      await _bis(() => l.entwicklung?.verbunden == true);

      expect(await client.tool('beispiel_echo', {'text': 'nachher'}), startsWith('Echo: nachher'));
      expect(zeilen(), contains(startsWith('Verbindung zum Entwicklungs-Plugin „Beispiel“ verloren')));
      expect(zeilen(), contains('Entwicklungs-Plugin „Beispiel“ wieder verbunden (16 Werkzeuge)'));
      expect(zeilen().join('\n'), isNot(contains(_schluessel)));
      expect(einstellungen.gespeichert, 0);
    });

    test('ein Neustart mit anderen Werkzeugen: die neue Liste gilt ab der nächsten Sitzung, die Namensregeln neu', () async {
      final erster = await pluginStarten();
      final l = neueLaufende();
      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);
      expect(l.werkzeuge(einstellungen.profile.first).map((w) => w.name), _beispielWerkzeuge);

      await pluginBeenden(erster);
      await _bis(() => l.entwicklung?.verbunden == false);
      // Neu gebaut, jetzt mit einem Werkzeug, das einen eingebauten Namen
      // trägt: Die Regeln greifen auch beim Wiederverbinden.
      final regelwidrig = await _fremderServer(port, const ['beispiel_echo', 'kurs_uebersicht']);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(l.entwicklung?.verbunden, isFalse);
      // Die Meldung nennt den Verstoß, nicht den Namen aus dem Plugin.
      expect(zeilen(), contains('Entwicklungs-Plugin „Beispiel“ nicht verbunden: Ein Werkzeug beginnt nicht mit „beispiel_“.'));
      expect(zeilen().join('\n'), isNot(contains('kurs_uebersicht')));
      await regelwidrig();

      final neu = await _fremderServer(port, const ['beispiel_neu']);
      stopps.add(neu);
      await _bis(() => l.entwicklung?.verbunden == true);

      expect(l.werkzeuge(einstellungen.profile.first).map((w) => w.name), ['beispiel_neu']);
      final client = await verbinden(einstellungen.profile.first, l);
      expect(await werkzeugnamen(client), contains('beispiel_neu'));
      expect(await werkzeugnamen(client), isNot(contains('beispiel_echo')));
      expect(await client.tool('beispiel_neu', {}), 'ok');
    });

    test('letzte Sperre: Antwort, Fehlertext und andere Inhalte eines angehängten Plugins gehen nur ohne Namen an die KI', () async {
      final server = await _sperrServer(port);
      stopps.add(server);
      final hinweise = SperrHinweise();
      final l = LaufendePlugins(
        protokoll,
        entwicklungsIntervall: const Duration(milliseconds: 200),
        sperrHinweise: hinweise,
      );
      laufende.add(l);
      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);
      l.sperre.namenHinzufuegen('beispiel', ['Erika Mustermann']);
      final client = await verbinden(einstellungen.profile.first, l);

      final mitName = await aufruf(client, 'beispiel_probe', {'fall': 'text', 'text': 'Abgabe von Erika'});
      final fehler = await aufruf(client, 'beispiel_probe', {'fall': 'fehler', 'text': 'Keine Abgabe von Mustermann'});
      final struktur = await aufruf(client, 'beispiel_probe', {'fall': 'struktur'});
      final andere = await aufruf(client, 'beispiel_probe', {'fall': 'andere'});
      final frei = await aufruf(client, 'beispiel_probe', {'fall': 'text', 'text': 'Abgabe vollständig'});

      for (final r in [mitName, fehler]) {
        expect(r['isError'], true);
        expect(text(r), gesperrtText('Beispiel', 'beispiel_probe'));
      }
      // Strukturierte Inhalte und alles außer Text gibt moocp ohnehin nicht
      // weiter; der Text daneben geht durch, wenn er keinen Namen trägt.
      expect(struktur['isError'], isNot(true));
      expect(text(struktur), 'Ohne Namen.');
      expect(andere['isError'], isNot(true));
      expect(text(andere), startsWith('Ohne Namen.\n'));
      expect(text(andere), contains('2 Inhalte'));
      expect(text(frei), 'Abgabe vollständig');
      for (final r in [mitName, fehler, struktur, andere]) {
        expect(jsonEncode(r).toLowerCase(), isNot(contains('erika')));
        expect(jsonEncode(r).toLowerCase(), isNot(contains('mustermann')));
      }
      final ohneArgumente = zeilen().where((z) => !z.startsWith('beispiel_probe({'));
      expect(ohneArgumente.join('\n').toLowerCase(), isNot(contains('erika')));
      expect(ohneArgumente.join('\n').toLowerCase(), isNot(contains('mustermann')));
      expect(
        zeilen().where(
          (z) => z == 'Plugin „Beispiel“, Werkzeug beispiel_probe: Antwort an die KI gesperrt (letzte Sperre: könnte einen Namen enthalten)',
        ),
        hasLength(2),
      );
      expect([for (final t in hinweise.offen) t.wort], ['Erika', 'Mustermann']);
    });

    test('letzte Sperre beim Wiederverbinden: die Namen bleiben, eine Werkzeugliste mit einem Namen nimmt die App nicht', () async {
      final erster = await _sperrServer(port);
      final hinweise = SperrHinweise();
      final l = LaufendePlugins(
        protokoll,
        entwicklungsIntervall: const Duration(milliseconds: 200),
        sperrHinweise: hinweise,
      );
      laufende.add(l);
      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);
      l.sperre.namenHinzufuegen('beispiel', ['Erika Mustermann']);
      await erster();
      await _bis(() => l.entwicklung?.verbunden == false);

      // Neu gebaut, jetzt mit dem Namen in der Beschreibung eines Werkzeugs.
      final mitName = await _sperrServer(port, beschreibung: 'Probe für Erika');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(l.entwicklung?.verbunden, isFalse);
      await mitName();
      final gesperrt = zeilen().where((z) => z.contains('Werkzeugliste gesperrt')).toList();
      expect(
        gesperrt,
        ['Entwicklungs-Plugin „Beispiel“: Werkzeugliste gesperrt (letzte Sperre: könnte einen Namen enthalten)'],
        reason: 'einmal, nicht bei jedem Versuch',
      );
      expect([for (final t in hinweise.offen) (t.stelle, t.wort)], [(SperrStelle.werkzeugliste, 'Erika')]);

      final ohneName = await _sperrServer(port);
      stopps.add(ohneName);
      await _bis(() => l.entwicklung?.verbunden == true);
      final client = await verbinden(einstellungen.profile.first, l);
      final r = await aufruf(client, 'beispiel_probe', {'fall': 'text', 'text': 'Erika'});

      expect(r['isError'], true);
      expect(text(r), gesperrtText('Beispiel', 'beispiel_probe'));
      expect(zeilen().where((z) => !z.startsWith('beispiel_probe({')).join('\n'), isNot(contains('Erika')));
    });

    test('noch nicht erreichbar beim Start: Die App verbindet sich später, Werkzeuge ab der ersten Verbindung', () async {
      final l = neueLaufende();

      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);
      expect(l.entwicklung, (name: 'Beispiel', verbunden: false));
      expect(l.werkzeuge(einstellungen.profile.first), isEmpty);

      await pluginStarten();
      await _bis(() => l.entwicklung?.verbunden == true);
      expect(l.werkzeuge(einstellungen.profile.first).map((w) => w.name), contains('beispiel_echo'));
      expect(zeilen(), contains('Entwicklungs-Plugin „Beispiel“ verbunden (16 Werkzeuge)'));
    });

    test('ein Absturz ist hier kein Ausfall: kein Neustart durch die App, keine Ausfallanzeige', () async {
      await pluginStarten();
      var starts = 0;
      final l = neueLaufende(gestartet: () => starts++);
      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);
      final client = await verbinden(einstellungen.profile.first, l);

      final r = await aufruf(client, 'beispiel_absturz');

      expect(r['isError'], true);
      expect(text(r), contains('gerade nicht verbunden'));
      expect(starts, 0);
      expect(l.ausgefalleneNamen, isEmpty);
      expect(l.entwicklung, (name: 'Beispiel', verbunden: false));
    });

    test('ein installiertes Plugin mit demselben Kurznamen startet nicht; seine Zustimmung bleibt unberührt', () async {
      await pluginStarten();
      final installiert = Directory(p.join(wurzel.path, 'plugins', 'beispiel'))..createSync(recursive: true);
      File(exe).copySync(p.join(installiert.path, 'beispiel.exe'));
      File(p.join('beispiele', 'plugin', 'plugin.json')).copySync(p.join(installiert.path, 'plugin.json'));
      final plugins = await Plugins.laden(einstellungen, protokoll, Directory(p.join(wurzel.path, 'plugins')));
      await plugins.entscheiden(plugins.eintraege.single, zugestimmt: true, profile: {'standard'});
      final vorher = jsonEncode(einstellungen.zuJson());
      final gespeichert = einstellungen.gespeichert;
      var starts = 0;
      final l = neueLaufende(gestartet: () => starts++);

      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);
      await l.starten(plugins, eingebaut: eingebaut);

      final e = plugins.eintraege.single;
      expect(starts, 0);
      expect(l.laeuft(e), isFalse);
      expect(l.startfehler(e), contains('Entwicklungs-Plugin mit demselben Kurznamen'));
      expect(l.werkzeuge(einstellungen.profile.first).map((w) => w.name), _beispielWerkzeuge);
      expect(jsonEncode(einstellungen.zuJson()), vorher);
      expect(einstellungen.gespeichert, gespeichert);
      expect(einstellungen.plugins['beispiel']!.zugestimmt, isTrue);
    });

    test('beim Beenden der App trennt sie nur die Verbindung; das Plugin gehört seinem Entwickler und läuft weiter', () async {
      final pr = await pluginStarten();
      final l = neueLaufende();
      await l.anhaengen(vorbereitet(), eingebaut: eingebaut);

      await l.beenden();

      expect(await _laeuft(pr.pid), isTrue);
      expect(zeilen(), contains('Verbindung zum Entwicklungs-Plugin „Beispiel“ getrennt'));
      expect(l.entwicklung, (name: 'Beispiel', verbunden: false));
    });
  });
}

/// Ein kleiner MCP-Server an Stelle des Plugins auf [port] mit dem Werkzeug
/// `beispiel_probe`: Je nach `fall` gibt es `text` zurück, als Antwort oder
/// als Fehler, oder Text ohne Namen neben strukturierten oder anderen
/// Inhalten, die einen Namen tragen. [beschreibung] ist die Beschreibung des
/// Werkzeugs in der Liste.
Future<Future<void> Function()> _sperrServer(int port, {String beschreibung = 'Probe'}) async {
  final server = StreamableMcpServer(
    serverFactory: (_) {
      final s = McpServer(const Implementation(name: 'sperre', version: '1'));
      s.registerTool(
        'beispiel_probe',
        description: beschreibung,
        inputSchema: JsonSchema.object(properties: {'fall': JsonSchema.string(), 'text': JsonSchema.string()}),
        callback: (args, extra) async => switch (args['fall']) {
          'fehler' => CallToolResult(content: [TextContent(text: '${args['text']}')], isError: true),
          'struktur' => CallToolResult(
            content: [const TextContent(text: 'Ohne Namen.')],
            structuredContent: const {'wer': 'Erika Mustermann'},
          ),
          'andere' => CallToolResult.fromContent([
            const TextContent(text: 'Ohne Namen.'),
            const ImageContent(data: 'iVBORw0KGgo=', mimeType: 'image/png'),
            const EmbeddedResource(
              resource: TextResourceContents(uri: 'file:///abgabe.txt', text: 'Abgabe von Erika Mustermann'),
            ),
          ]),
          _ => CallToolResult.fromContent([TextContent(text: '${args['text']}')]),
        },
      );
      return s;
    },
    host: '127.0.0.1',
    port: port,
    path: '/mcp',
    enableJsonResponse: true,
    authenticator: (r) => r.headers.value(HttpHeaders.authorizationHeader) == 'Bearer $_schluessel',
  );
  await server.start();
  return server.stop;
}

/// Ein kleiner MCP-Server an Stelle des Plugins auf [port], mit dem Schlüssel
/// der Tests, der die Werkzeuge [namen] anbietet und `ok` antwortet.
/// [gezaehlt] erfährt jede Anfrage, auch eine ohne Schlüssel.
Future<Future<void> Function()> _fremderServer(int port, List<String> namen, {void Function()? gezaehlt}) async {
  final server = StreamableMcpServer(
    serverFactory: (_) {
      final s = McpServer(const Implementation(name: 'fremd', version: '1'));
      for (final n in namen) {
        s.registerTool(
          n,
          description: 'Probe',
          inputSchema: JsonSchema.object(properties: {}),
          callback: (args, extra) async => CallToolResult.fromContent([const TextContent(text: 'ok')]),
        );
      }
      return s;
    },
    host: '127.0.0.1',
    port: port,
    path: '/mcp',
    enableJsonResponse: true,
    authenticator: (r) {
      gezaehlt?.call();
      return r.headers.value(HttpHeaders.authorizationHeader) == 'Bearer $_schluessel';
    },
  );
  await server.start();
  return server.stop;
}
