// Ein angenommenes Plugin starten und seine Werkzeuge anbieten (E35): so, wie
// ein KI-Werkzeug es sieht -- über den MCP-Server der App, mit dem
// Beispiel-Plugin (beispiele/plugin/) als echtem Kindprozess auf der anderen
// Seite. Wo kein echter Prozess nötig ist (Namensregeln, Abbruch), steht ein
// kleiner MCP-Server im Test an seiner Stelle. Alles in Temp-Ordnern, nie im
// Einstellungsordner der App.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/mcp/werkzeugquelle.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/plugin/laufende_plugins.dart';
import 'package:moocp/plugin/plugins.dart';
import 'package:moocp/plugin/verbindung.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'mcp_client.dart';

class _EinstellungenOhneDatei extends Einstellungen {
  _EinstellungenOhneDatei({super.profile}) : super(schluessel: 'test');

  @override
  Future<void> speichern() async {}
}

/// Das `dart` des Flutter-SDK, mit dem die Tests laufen: `flutter test`
/// führt die Tests im flutter_tester aus, nicht in dart; das SDK liegt
/// darüber in `bin/cache/dart-sdk`.
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

/// Die Namen der eingebauten Werkzeuge, wie die App sie beim Start ermittelt.
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

/// Ob ein Prozess mit dieser Nummer noch läuft.
Future<bool> _laeuft(int pid) async {
  if (Platform.isWindows) {
    final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return '${r.stdout}'.contains(' $pid ');
  }
  return (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;
}

/// Alle Nachkommen von [pid] (nur Windows), sobald einer davon [name] heißt;
/// höchstens etwa zehn Sekunden lang gesucht.
Future<List<int>> _nachkommen(int pid, String name) async {
  for (var i = 0; i < 50; i++) {
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'$alle = Get-CimInstance Win32_Process; $offen = @(' '$pid' r'); $treffer = @(); '
          r'while ($offen.Count) { $k = @($alle | Where-Object { $offen -contains $_.ParentProcessId }); '
          r'$treffer += $k; $offen = @($k | ForEach-Object { $_.ProcessId }) }; '
          r'$treffer | ForEach-Object { "$($_.ProcessId) $($_.Name)" }',
    ]);
    final zeilen = [
      for (final z in LineSplitter.split('${r.stdout}'))
        if (z.trim().isNotEmpty) z.trim(),
    ];
    if (zeilen.any((z) => z.toLowerCase().endsWith(' ${name.toLowerCase()}'))) {
      return [for (final z in zeilen) int.parse(z.split(' ').first)];
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return const [];
}

void main() {
  late Directory vorlage;
  late Set<String> eingebaut;

  // Einmal übersetzen, wie ein Plugin-Autor es tut (`dart compile exe`), in
  // einen Plugin-Ordner mit der Beschreibungsdatei aus dem Repository: So
  // läuft der Weg über `programm` wie bei einem installierten Plugin.
  setUpAll(() async {
    vorlage = Directory.systemTemp.createTempSync('moocp_beispiel_');
    final ziel = p.join(vorlage.path, 'beispiel.exe');
    final r = await Process.run(_dart(), [
      'compile',
      'exe',
      p.join('beispiele', 'plugin', 'beispiel.dart'),
      '-o',
      ziel,
    ]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    File(p.join('beispiele', 'plugin', 'plugin.json')).copySync(p.join(vorlage.path, 'plugin.json'));
    eingebaut = await _eingebaut();
  });
  tearDownAll(() => vorlage.deleteSync(recursive: true));

  late Directory wurzel;
  late Protokoll protokoll;
  late _EinstellungenOhneDatei einstellungen;
  final laufende = <LaufendePlugins>[];
  final dienste = <McpDienst>[];
  final clients = <McpTestClient>[];

  setUp(() {
    wurzel = Directory.systemTemp.createTempSync('moocp_plugins_');
    protokoll = Protokoll();
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
    wurzel.deleteSync(recursive: true);
  });

  /// Legt das übersetzte Beispiel-Plugin unter `plugins/beispiel` an und
  /// stimmt ihm zu, eingeschaltet in [aktiv].
  Future<Plugins> beispielAngenommen(List<Profil> profile, {Set<String>? aktiv}) async {
    final ordner = Directory(p.join(wurzel.path, 'plugins', 'beispiel'))..createSync(recursive: true);
    for (final f in vorlage.listSync().whereType<File>()) {
      f.copySync(p.join(ordner.path, p.basename(f.path)));
    }
    einstellungen = _EinstellungenOhneDatei(profile: profile);
    final plugins = await Plugins.laden(einstellungen, protokoll, Directory(p.join(wurzel.path, 'plugins')));
    expect(plugins.eintraege.single.fehler, isNull);
    await plugins.entscheiden(
      plugins.eintraege.single,
      zugestimmt: true,
      profile: aktiv ?? {for (final pr in profile) pr.kennung},
    );
    return plugins;
  }

  Future<LaufendePlugins> starten(Plugins plugins, {LaufendePlugins? mit}) async {
    final l = mit ?? LaufendePlugins(protokoll);
    laufende.add(l);
    await l.starten(plugins, eingebaut: eingebaut);
    return l;
  }

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

  group('Das Beispiel-Plugin als Kindprozess', () {
    test('sein Werkzeug steht in der Werkzeugliste und läuft mit Profil, Token und Schnittstelle', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      final client = await verbinden(profil, l);

      expect(await werkzeugnamen(client), contains('beispiel_echo'));
      final text = await client.tool('beispiel_echo', {'text': 'Hallo'});

      expect(text, 'Echo: Hallo\nProfil: moodle\nAufruf-Token: erhalten\nSchnittstelle: 1');
      final zeilen = [for (final e in protokoll.eintraege) e.text];
      expect(zeilen, contains('Plugin „Beispiel“ 1.0.0 gestartet (1 Werkzeuge)'));
      expect(zeilen, contains('beispiel_echo({"text":"Hallo"})'));
      expect(zeilen, contains('beispiel_echo: Echo: Hallo'));
    });

    test('es läuft einmal je App, auch mit zwei Profilen; jeder Aufruf trägt sein Profil', () async {
      final eins = _profil('standard', 'moodle', await _freierPort());
      final zwei = _profil('k2', 'moodle-test', await _freierPort());
      final plugins = await beispielAngenommen([eins, zwei]);
      final l = await starten(plugins);
      await l.starten(plugins, eingebaut: eingebaut);

      final a = await verbinden(eins, l);
      final b = await verbinden(zwei, l);

      expect(await a.tool('beispiel_echo', {'text': 'a'}), contains('Profil: moodle\n'));
      expect(await b.tool('beispiel_echo', {'text': 'b'}), contains('Profil: moodle-test\n'));
      expect(protokoll.eintraege.where((e) => e.text.contains('gestartet')), hasLength(1));
    });

    test('ausgeschaltet in einem Profil: dort nicht in der Liste und nicht aufrufbar, im anderen schon', () async {
      final eins = _profil('standard', 'moodle', await _freierPort());
      final zwei = _profil('k2', 'moodle-test', await _freierPort());
      final plugins = await beispielAngenommen([eins, zwei], aktiv: {'standard'});
      final l = await starten(plugins);

      final a = await verbinden(eins, l);
      final b = await verbinden(zwei, l);

      expect(await werkzeugnamen(a), contains('beispiel_echo'));
      expect(await werkzeugnamen(b), isNot(contains('beispiel_echo')));
    });

    test('ausschalten wirkt für Aufrufe sofort, in der Werkzeugliste ab der nächsten Sitzung', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final plugins = await beispielAngenommen([profil]);
      final l = await starten(plugins);
      final client = await verbinden(profil, l);
      expect(await werkzeugnamen(client), contains('beispiel_echo'));

      await plugins.profilSchalten(plugins.eintraege.single, 'standard', false);

      final r = await client.call('tools/call', {
        'name': 'beispiel_echo',
        'arguments': {'text': 'x'},
      });
      expect(r['isError'], true);
      expect(((r['content'] as List).single as Map)['text'], contains('nicht eingeschaltet'));
      final neu = McpTestClient(profil.port);
      clients.add(neu);
      await neu.initialize();
      expect(await werkzeugnamen(neu), isNot(contains('beispiel_echo')));
    });

    test('es nimmt keine Anfrage ohne seinen Schlüssel an', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      int? port;
      final l = LaufendePlugins(
        protokoll,
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) {
          port = int.parse(argumente[argumente.indexOf('--port') + 1]);
          return Process.start(programm, argumente, environment: umgebung, workingDirectory: arbeitsordner);
        },
      );
      final plugins = await beispielAngenommen([profil]);
      await starten(plugins, mit: l);
      expect(l.laeuft(plugins.eintraege.single), isTrue);

      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      Future<int> status(String? kopf) async {
        final r = await http.postUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
        r.headers
          ..set('Accept', 'application/json, text/event-stream')
          ..contentType = ContentType.json;
        if (kopf != null) r.headers.set('Authorization', kopf);
        r.write(jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {
            'protocolVersion': '2025-06-18',
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'fremd', 'version': '1'},
          },
        }));
        final antwort = await r.close();
        await antwort.drain<void>();
        return antwort.statusCode;
      }

      expect(await status(null), anyOf(401, 403));
      expect(await status('Bearer falsch'), anyOf(401, 403));
    });

    test('der Schlüssel steht nicht auf der Kommandozeile des Plugin-Prozesses, der Port schon', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      late Process prozess;
      late String schluessel;
      final l = LaufendePlugins(
        protokoll,
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async {
          schluessel = umgebung[schluesselVariable]!;
          return prozess = await Process.start(programm, argumente, environment: umgebung, workingDirectory: arbeitsordner);
        },
      );
      await starten(await beispielAngenommen([profil]), mit: l);

      // Was jedes Programm des Benutzers über den Prozess sieht.
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '(Get-CimInstance Win32_Process -Filter "ProcessId=${prozess.pid}").CommandLine',
      ]);
      final zeile = '${r.stdout}'.trim();
      expect(zeile, contains('beispiel.exe'));
      expect(zeile, contains('--port'));
      expect(schluessel.length, greaterThanOrEqualTo(40));
      expect(zeile, isNot(contains(schluessel)));
      expect([for (final e in protokoll.eintraege) e.text].join('\n'), isNot(contains(schluessel)));
    }, skip: Platform.isWindows ? false : 'misst die Prozessliste von Windows');

    test('nach dem Beenden läuft kein Plugin-Prozess mehr', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      late Process prozess;
      final l = LaufendePlugins(
        protokoll,
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async =>
            prozess = await Process.start(programm, argumente, environment: umgebung, workingDirectory: arbeitsordner),
      );
      await starten(await beispielAngenommen([profil]), mit: l);
      expect(await _laeuft(prozess.pid), isTrue);

      await l.beenden();

      expect(await _laeuft(prozess.pid), isFalse);
      expect([for (final e in protokoll.eintraege) e.text], contains('Plugin „Beispiel“ 1.0.0 beendet'));
    });

    test('endet die App, während ein Plugin noch startet, bleibt auch dessen Prozess nicht zurück', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final plugins = await beispielAngenommen([profil]);
      final gestartet = Completer<Process>();
      // Ein Plugin, das nie lauscht und selbst ein Programm startet. Unter
      // Windows endet ein Kind nicht mit seinem Elternprozess; das ping muss
      // trotzdem mit fort.
      final warten = File(p.join(wurzel.path, 'warten.dart'))
        ..writeAsStringSync(
          "import 'dart:io';\n"
          'Future<void> main() async {\n'
          "  if (Platform.isWindows) await Process.start('ping', ['-n', '120', '127.0.0.1']);\n"
          '  await Future<void>.delayed(const Duration(minutes: 5));\n'
          '}\n',
        );
      final l = LaufendePlugins(
        protokoll,
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async {
          final prozess = await Process.start(_dart(), [warten.path]);
          gestartet.complete(prozess);
          return prozess;
        },
      );
      laufende.add(l);
      final start = l.starten(plugins, eingebaut: eingebaut);
      final prozess = await gestartet.future;
      final kinder = Platform.isWindows ? await _nachkommen(prozess.pid, 'PING.EXE') : const <int>[];
      if (Platform.isWindows) expect(kinder, isNotEmpty);

      await l.beenden();
      await start.timeout(const Duration(seconds: 10));

      expect(await _laeuft(prozess.pid), isFalse);
      for (final k in kinder) {
        expect(await _laeuft(k), isFalse, reason: 'Kindprozess $k');
      }
      expect(l.laeuft(plugins.eintraege.single), isFalse);
    });

    test('haben sich seine Dateien seit der Suche geändert, startet es nicht', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final plugins = await beispielAngenommen([profil]);
      var gestartet = false;
      File(p.join(plugins.eintraege.single.pfad, 'beispiel.exe')).writeAsBytesSync([1, 2, 3], mode: FileMode.append);
      final l = LaufendePlugins(
        protokoll,
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) {
          gestartet = true;
          return Process.start(programm, argumente, environment: umgebung);
        },
      );

      await starten(plugins, mit: l);

      expect(gestartet, isFalse);
      expect(l.laeuft(plugins.eintraege.single), isFalse);
      expect(l.startfehler(plugins.eintraege.single), contains('geändert'));
      expect(l.werkzeuge(profil), isEmpty);
    });

    test('antwortet es nicht binnen der Frist, gilt es als nicht gestartet, und sein Prozess endet', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final plugins = await beispielAngenommen([profil]);
      late Process prozess;
      // Ein Programm, das läuft, aber nie lauscht: die Standardeingabe von
      // `dart` ohne Skript-Server -- hier ein Dart-Programm, das nur wartet.
      final warten = File(p.join(wurzel.path, 'warten.dart'))
        ..writeAsStringSync('Future<void> main() => Future<void>.delayed(const Duration(minutes: 5));\n');
      final l = LaufendePlugins(
        protokoll,
        startfrist: const Duration(seconds: 2),
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async =>
            prozess = await Process.start(_dart(), [warten.path]),
      );

      await starten(plugins, mit: l);

      expect(l.laeuft(plugins.eintraege.single), isFalse);
      expect(l.startfehler(plugins.eintraege.single), contains('nicht binnen 2 Sekunden'));
      expect(await _laeuft(prozess.pid), isFalse);
      expect(
        [for (final e in protokoll.eintraege) e.text],
        contains(startsWith('Plugin „Beispiel“ nicht gestartet: Das Plugin hat nicht binnen 2 Sekunden')),
      );
    });
  });

  group('Werkzeugnamen eines Plugins', () {
    test('jeder Verstoß hält das Plugin vom Laden ab und nennt das Werkzeug', () {
      void verstoss(List<String> namen, String grund, {Set<String> vergeben = const {}}) => expect(
        () => werkzeugnamenPruefen(namen, 'beispiel', vergeben),
        throwsA(isA<Object>().having((e) => e.toString(), 'grund', contains(grund))),
        reason: '$namen',
      );

      verstoss(['echo'], '„echo“ beginnt nicht mit „beispiel_“');
      verstoss(['beispielecho'], 'beginnt nicht mit');
      verstoss(['beispiel_${'x' * 32}'], 'länger als 40 Zeichen');
      verstoss(['beispiel_ä'], 'Zeichen im Namen');
      verstoss(['beispiel_a b'], 'Zeichen im Namen');
      verstoss(['beispiel_a.b'], 'Zeichen im Namen');
      verstoss(['beispiel_echo', 'beispiel_echo'], '„beispiel_echo“ gibt es schon');
      verstoss(['beispiel_status'], '„beispiel_status“ gibt es schon', vergeben: {'beispiel_status'});
      werkzeugnamenPruefen(['beispiel_echo', 'beispiel_a_b-c', 'beispiel_${'x' * 31}'], 'beispiel', {'status'});
    });

    test('ein Werkzeug außerhalb des Kurznamens bricht die Verbindung ab und nennt das Werkzeug', () async {
      final fremd = await _fremderServer(['beispiel_echo', 'kurs_uebersicht']);
      addTearDown(fremd.stop);

      await expectLater(
        PluginVerbindung.verbinden(
          port: fremd.port,
          schluessel: 'k',
          kurzname: 'beispiel',
          vergeben: eingebaut,
          frist: const Duration(seconds: 5),
        ),
        throwsA(isA<Object>().having((e) => e.toString(), 'grund', contains('„kurs_uebersicht“'))),
      );
    });

    test('trägt ein Werkzeug einen vergebenen Namen, lädt das Plugin nicht, und sein Prozess endet', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final plugins = await beispielAngenommen([profil]);
      late Process prozess;
      final l = LaufendePlugins(
        protokoll,
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async =>
            prozess = await Process.start(programm, argumente, environment: umgebung, workingDirectory: arbeitsordner),
      );
      laufende.add(l);

      await l.starten(plugins, eingebaut: {...eingebaut, 'beispiel_echo'});

      expect(l.laeuft(plugins.eintraege.single), isFalse);
      expect(l.startfehler(plugins.eintraege.single), contains('„beispiel_echo“ gibt es schon'));
      expect(l.werkzeuge(profil), isEmpty);
      expect(await _laeuft(prozess.pid), isFalse);
    });
  });

  group('Ein Aufruf beim Plugin', () {
    test('bricht der Client ab, kommt der Abbruch beim Plugin an', () async {
      final angekommen = Completer<void>();
      final abgebrochen = Completer<void>();
      final fremd = await _fremderServer(['beispiel_warten'], werkzeug: (args, extra) async {
        angekommen.complete();
        await extra.signal.onAbort.first;
        abgebrochen.complete();
        return CallToolResult.fromContent([const TextContent(text: 'zu spät')]);
      });
      addTearDown(fremd.stop);
      final v = await PluginVerbindung.verbinden(
        port: fremd.port,
        schluessel: 'k',
        kurzname: 'beispiel',
        vergeben: const {},
        frist: const Duration(seconds: 5),
      );
      addTearDown(v.schliessen);
      final abbruch = Completer<void>();

      final aufruf = v.aufrufen(
        WerkzeugAufruf(
          name: 'beispiel_warten',
          args: const {},
          profil: _profil('standard', 'moodle', 1),
          token: aufrufToken(),
          abbruch: abbruch.future,
        ),
      );
      await angekommen.future.timeout(const Duration(seconds: 5));
      abbruch.complete();

      await expectLater(aufruf, throwsA(isA<MoodleFehler>()));
      await abgebrochen.future.timeout(const Duration(seconds: 5));
      expect(abgebrochen.isCompleted, isTrue);
    });

    test('nur Text geht weiter; andere Inhalte nennt die Antwort, ein Fehler des Plugins wird ein Werkzeugfehler', () async {
      final fremd = await _fremderServer(['beispiel_bild', 'beispiel_fehler'], werkzeug: (args, extra) async {
        if (args['fehler'] == true) {
          return CallToolResult(content: [const TextContent(text: 'Geht nicht.')], isError: true);
        }
        return CallToolResult.fromContent([
          const TextContent(text: 'Hier ist ein Bild.'),
          const ImageContent(data: 'iVBORw0KGgo=', mimeType: 'image/png'),
        ]);
      });
      addTearDown(fremd.stop);
      final v = await PluginVerbindung.verbinden(
        port: fremd.port,
        schluessel: 'k',
        kurzname: 'beispiel',
        vergeben: const {},
        frist: const Duration(seconds: 5),
      );
      addTearDown(v.schliessen);
      WerkzeugAufruf aufruf(String name, Map<String, dynamic> args) => WerkzeugAufruf(
        name: name,
        args: args,
        profil: _profil('standard', 'moodle', 1),
        token: aufrufToken(),
        abbruch: Completer<void>().future,
      );

      final text = await v.aufrufen(aufruf('beispiel_bild', const {}));
      expect(text, startsWith('Hier ist ein Bild.\n'));
      expect(text, contains('1 Inhalt'));
      expect(text, isNot(contains('iVBORw0KGgo')));
      await expectLater(
        v.aufrufen(aufruf('beispiel_fehler', const {'fehler': true})),
        throwsA(isA<MoodleFehler>().having((f) => f.meldung, 'meldung', 'Geht nicht.')),
      );
    });
  });
}

/// Ein kleiner MCP-Server an Stelle eines Plugins, mit Schlüssel `k`, der die
/// Werkzeuge [namen] anbietet.
Future<({int port, Future<void> Function() stop})> _fremderServer(
  List<String> namen, {
  FutureOr<CallToolResult> Function(Map<String, dynamic> args, RequestHandlerExtra extra)? werkzeug,
}) async {
  final port = await _freierPort();
  final server = StreamableMcpServer(
    serverFactory: (_) {
      final s = McpServer(const Implementation(name: 'fremd', version: '1'));
      for (final n in namen) {
        s.registerTool(
          n,
          description: 'Probe',
          inputSchema: JsonSchema.object(properties: {}),
          callback: (args, extra) async =>
              werkzeug == null ? CallToolResult.fromContent([const TextContent(text: 'ok')]) : await werkzeug(args, extra),
        );
      }
      return s;
    },
    host: '127.0.0.1',
    port: port,
    path: '/mcp',
    enableJsonResponse: true,
    authenticator: (r) => r.headers.value(HttpHeaders.authorizationHeader) == 'Bearer k',
  );
  await server.start();
  return (port: port, stop: server.stop);
}
