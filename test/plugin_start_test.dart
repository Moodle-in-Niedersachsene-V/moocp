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
import 'package:moocp/plugin/app_adresse.dart';
import 'package:moocp/plugin/dialoge.dart';
import 'package:moocp/plugin/laufende_plugins.dart';
import 'package:moocp/plugin/moodle_schreiben.dart' show zusatzKennzeichnung;
import 'package:moocp/plugin/plugins.dart';
import 'package:moocp/plugin/verbindung.dart';
import 'package:moocp/plugin/werkzeugliste.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'mcp_client.dart';
import 'plugin_moodle_test.dart' show PluginTestMoodle, sitzungsCookie;

class _EinstellungenOhneDatei extends Einstellungen {
  _EinstellungenOhneDatei({super.profile}) : super(schluessel: 'test');

  /// Wie oft die App ihre Einstellungen geschrieben hätte.
  int gespeichert = 0;

  @override
  Future<void> speichern() async => gespeichert++;
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
  'beispiel_namen',
];

/// Eine Protokollzeile an die Adresse der App (`/v1/protokoll`), wie von einem Plugin mit
/// [schluessel]; liefert den HTTP-Status.
Future<int> _protokollzeile(Uri adresse, String schluessel, String text) async {
  final http = HttpClient();
  try {
    final r = await http.postUrl(adresse.resolve(pfadProtokoll));
    r.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $schluessel')
      ..contentType = ContentType.json;
    r.write(jsonEncode({'text': text}));
    final antwort = await r.close();
    await antwort.drain<void>();
    return antwort.statusCode;
  } finally {
    http.close(force: true);
  }
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

  Future<McpTestClient> verbinden(
    Profil profil,
    LaufendePlugins quelle, {
    String arbeitsordner = '',
    Freigaben? freigaben,
    MoodleZugang? moodle,
  }) async {
    final d = McpDienst(
      einstellungen,
      moodle ?? MoodleZugang(protokoll),
      protokoll,
      freigaben ?? Freigaben(protokoll),
      arbeitsordner,
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
      expect(zeilen, contains('Plugin „Beispiel“ 1.0.0 gestartet (14 Werkzeuge)'));
      expect(zeilen, contains('beispiel_echo({"text":"Hallo"})'));
      expect(zeilen, contains('beispiel_echo: Echo: Hallo'));
    });

    test('über die Adresse der App: Protokollzeile, Datei im Arbeitsordner und das eingebaute status', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      final ordner = Directory(p.join(wurzel.path, 'arbeitsordner'))..createSync();
      final client = await verbinden(profil, l, arbeitsordner: ordner.path);

      final protokolliert = await client.tool('beispiel_protokoll', {'text': 'Hallo\nmoocp'});
      final datei = await client.tool('beispiel_datei', {'text': 'Inhalt der Datei'});
      final status = await client.tool('beispiel_status', {});

      final zeilen = [for (final e in protokoll.eintraege) e.text];
      expect(protokolliert, 'Die Zeile steht im Protokoll von moocp.');
      expect(zeilen, contains('Plugin „Beispiel“: Hallo moocp'));
      final pfad = p.join(ordner.path, 'plugin-beispiel', 'beispiel.txt');
      expect(datei, 'Datei abgelegt: $pfad');
      expect(File(pfad).readAsStringSync(), 'Inhalt der Datei');
      expect(status, contains('Angemeldet: nein -- bitte in der App anmelden'));
      expect(status, contains('Profil: moodle (moodle)'));
      expect(zeilen, contains('status({}) -- Aufrufer: Plugin „Beispiel“'));
      expect(l.appAdresse?.host, '127.0.0.1');
    });

    test('Dialoge und Freigabe: jede Art über die Adresse der App, die Antwort kommt beim Plugin an', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final gewaehlt = Directory(p.join(wurzel.path, 'gewaehlt'))..createSync();
      File(p.join(gewaehlt.path, 'eins.txt')).writeAsStringSync('1');
      File(p.join(gewaehlt.path, 'zwei.txt')).writeAsStringSync('22');
      // An Stelle der Oberfläche: Jeder Dialog wird beantwortet, sobald er
      // offen ist, wie von der Lehrkraft.
      final dialoge = PluginDialoge();
      dialoge.addListener(() {
        final d = dialoge.aktuell;
        if (d == null || !d.offen) return;
        scheduleMicrotask(
          () => dialoge.beantworten(d, switch (d) {
            AuswahlDialog() => AuswahlDialog.antwort([0, 2]),
            final EingabeDialog e => EingabeDialog.antwort(e.link ? 'https://moodle.schule.example' : 'Hallo'),
            final PfadDialog w => PfadDialog.antwort(w.ordner ? gewaehlt.path : p.join(gewaehlt.path, 'zwei.txt')),
            HinweisDialog() => const {},
          }),
        );
      });
      final freigaben = Freigaben(protokoll);
      var ja = true;
      freigaben.addListener(() {
        if (freigaben.aktuell?.offen == true) scheduleMicrotask(() => freigaben.entscheiden(ja));
      });
      final l = await starten(await beispielAngenommen([profil]), mit: LaufendePlugins(protokoll, dialoge: dialoge));
      final client = await verbinden(profil, l, freigaben: freigaben);

      expect(await client.tool('beispiel_auswahl', {'mehrfach': true}), 'Gewählt: Rot, Blau');
      expect(await client.tool('beispiel_eingabe', {'link': true}), 'Eingegeben: https://moodle.schule.example');
      expect(await client.tool('beispiel_pfad', {}), 'Der gewählte Ordner hat 2 Einträge.');
      expect(await client.tool('beispiel_pfad', {'datei': true}), 'Die gewählte Datei hat 2 Bytes.');
      expect(await client.tool('beispiel_hinweis', {'text': 'Fertig.'}), 'Bestätigt.');
      expect(await client.tool('beispiel_freigabe', {'ab': 'mittel'}), 'Ausgang: freigegeben');
      ja = false;
      expect(await client.tool('beispiel_freigabe', {'ab': 'mittel'}), 'Ausgang: abgelehnt');
      // Lässt die Stufe die Frage aus, erfährt es das Plugin und, in der
      // Antwort auf seinen Aufruf, die KI.
      freigaben.stufe = Bestaetigungen.keine;
      final ohne = await client.tool('beispiel_freigabe', {'ab': 'mittel'});
      expect(ohne, startsWith('Ausgang: freigegeben (ohne Frage, wegen der Stufe)'));
      expect(ohne, contains('Ohne Freigabe ausgeführt (1 Vorgang)'));
      expect(await client.tool('beispiel_freigabe', {'ab': 'keine'}), 'Ausgang: abgelehnt');

      final zeilen = [for (final e in protokoll.eintraege) e.text];
      for (final art in ['Auswahl', 'Eingabe', 'Ordner- oder Dateiwahl', 'Hinweis']) {
        expect(zeilen, contains('Plugin „Beispiel“: Dialog „$art“ beantwortet'));
      }
      expect(zeilen, contains('Plugin „Beispiel“: Freigabe ab Stufe „mittel“ -- ohne Frage erteilt'));
      expect(zeilen.join('\n'), isNot(contains(gewaehlt.path)));
      expect(dialoge.aktuell, isNull);
      expect(freigaben.aktuell, isNull);
    });

    test('Moodle über die Adresse der App: eine erlaubte Seite gelesen, der Adminbereich ohne Dialog abgelehnt', () async {
      final moodle = PluginTestMoodle();
      await moodle.starten();
      addTearDown(() => moodle.server.close(force: true));
      final zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
      moodle.angefragt.clear();
      final profil = _profil('standard', 'moodle', await _freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      final client = await verbinden(profil, l, moodle: zugang);

      final gelesen = await client.tool('beispiel_moodle_lesen', {'kurs': 12});
      final gesperrt = await client.tool('beispiel_moodle_gesperrt', {});

      expect(gelesen, matches(RegExp(r'^Moodle antwortet mit Status 200 \(text/html, \d+ Zeichen\)\.$')));
      expect(gesperrt, startsWith('Abgelehnt (HTTP 403): Gesperrt für jedes Plugin: /admin/index.php'));
      expect(moodle.angefragt, ['GET /question/banks.php?courseid=12']);
      final zeilen = [for (final e in protokoll.eintraege) e.text];
      expect(zeilen, contains('Plugin „Beispiel“: GET /question/banks.php?courseid=… → 200'));
      expect(zeilen, contains('Plugin „Beispiel“: Gesperrt für Plugins: GET /admin/index.php (Bereich Adminbereich)'));
      expect(zeilen.join('\n'), isNot(contains(sitzungsCookie)));
    });

    test('Schreiben über eine Zusatzadresse: Freigabe auf jeder Stufe, ein POST, Antwort an die KI gekennzeichnet', () async {
      final moodle = PluginTestMoodle();
      await moodle.starten();
      addTearDown(() => moodle.server.close(force: true));
      final zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
      await zugang.sesskey();
      moodle.angefragt.clear();
      final freigaben = Freigaben(protokoll)..stufe = Bestaetigungen.keine;
      final gezeigt = <FreigabeAnfrage>[];
      var ja = true;
      freigaben.addListener(() {
        final f = freigaben.aktuell;
        if (f != null && f.offen && !gezeigt.contains(f)) {
          gezeigt.add(f);
          scheduleMicrotask(() => freigaben.entscheiden(ja));
        }
      });
      final profil = _profil('standard', 'moodle', await _freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      final client = await verbinden(profil, l, moodle: zugang, freigaben: freigaben);

      final geschrieben = await client.tool('beispiel_moodle_schreiben', {'id': 7, 'notiz': 'Hallo'});

      expect(
        geschrieben,
        '${zusatzKennzeichnung('Beispiel', 1)}\n\nGeschrieben und vom Plugin geprüft: Die Notiz steht auf der Seite.',
      );
      expect(geschrieben, isNot(contains('verified')));
      expect(moodle.angefragt, ['POST /mod/beispiel/speichern.php?id=7', 'GET /mod/beispiel/speichern.php?id=7&gespeichert=1']);
      expect(moodle.rumpfe[moodle.rumpfe.length - 2], 'notiz=Hallo&sesskey=abc123');
      final f = gezeigt.single;
      expect(f.ab, Bestaetigungen.keine);
      expect(f.aufrufer, 'Plugin „Beispiel“');
      expect(f.vomPlugin, 'Das Beispiel-Plugin speichert diese Notiz:\nHallo');
      expect(f.punkte, contains(startsWith('Grund dieser Zusatzadresse aus der Beschreibungsdatei')));
      expect(f.punkte.last, isNot(contains('Hallo')));
      final zeilen = [for (final e in protokoll.eintraege) e.text];
      expect(zeilen, contains('Plugin „Beispiel“, Zusatzadresse: POST /mod/beispiel/speichern.php?id=… → 303'));
      expect(zeilen, contains('Plugin „Beispiel“, Zusatzadresse: GET /mod/beispiel/speichern.php?id=…&gespeichert=… → 200'));
      expect(zeilen.join('\n'), isNot(contains('abc123')));
      expect(zeilen.join('\n'), isNot(contains(sitzungsCookie)));

      // Ein Werkzeugfehler des Plugins nach dem Schreiben trägt die
      // Kennzeichnung ebenso: Die Umleitung auf den Adminbereich liest moocp
      // nicht, das Plugin kann nicht nachsehen.
      final ungeprueft = await client.call('tools/call', {
        'name': 'beispiel_moodle_schreiben',
        'arguments': {'id': 13, 'notiz': 'Hallo'},
      });
      expect(ungeprueft['isError'], true);
      expect(
        ((ungeprueft['content'] as List).single as Map)['text'],
        '${zusatzKennzeichnung('Beispiel', 1)}\n\n'
        'Gesendet, aber nicht geprüft: Das Plugin konnte die Seite danach nicht lesen.',
      );

      // Abgelehnt: nichts gesendet, und die Antwort bleibt, wie das Plugin
      // sie gibt, ohne Kennzeichnung.
      ja = false;
      moodle.angefragt.clear();
      final abgelehnt = await client.tool('beispiel_moodle_schreiben', {'id': 7, 'notiz': 'Nein'});
      expect(abgelehnt, 'Nicht geschrieben: Die Lehrkraft hat nicht freigegeben (abgelehnt).');
      expect(moodle.angefragt, isEmpty);
    });

    test('letzte Sperre: Das Beispiel nennt einen Namen, seine Antwort und seine Protokollzeile damit gehen nicht hinaus', () async {
      final eins = _profil('standard', 'moodle', await _freierPort());
      final zwei = _profil('k2', 'moodle-test', await _freierPort());
      final hinweise = SperrHinweise();
      final l = await starten(await beispielAngenommen([eins, zwei]), mit: LaufendePlugins(protokoll, sperrHinweise: hinweise));
      final a = await verbinden(eins, l);
      final b = await verbinden(zwei, l);

      final r = await a.call('tools/call', {'name': 'beispiel_namen', 'arguments': <String, Object?>{}});

      expect(r['isError'], true);
      expect(((r['content'] as List).single as Map)['text'], gesperrtText('Beispiel', 'beispiel_namen'));
      expect(jsonEncode(r), isNot(contains('Erika')));
      expect(jsonEncode(r), isNot(contains('Mustermann')));
      // Die Sperre gilt nach dem Ende des Aufrufs weiter, in jedem Profil, für
      // jeden Teil des Namens; was keinen Namen trägt, geht durch.
      for (final (client, text) in [(a, 'Erika'), (b, 'MUSTERMANN'), (b, 'Frau Mustermann')]) {
        final g = await client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': text}});
        expect(g['isError'], true, reason: text);
        expect(((g['content'] as List).single as Map)['text'], gesperrtText('Beispiel', 'beispiel_echo'));
      }
      expect(await b.tool('beispiel_echo', {'text': 'Hallo'}), startsWith('Echo: Hallo'));
      expect(await a.tool('beispiel_protokoll', {'text': 'Aufgabe 3 fertig'}), 'Die Zeile steht im Protokoll von moocp.');

      final zeilen = [for (final e in protokoll.eintraege) e.text];
      expect(zeilen, contains('Plugin „Beispiel“: 1 Name zum Sperren genannt'));
      expect(zeilen, contains('Plugin „Beispiel“, Werkzeug beispiel_namen: Protokollzeile gesperrt (letzte Sperre: könnte einen Namen enthalten)'));
      expect(zeilen, contains('Plugin „Beispiel“, Werkzeug beispiel_namen: Antwort an die KI gesperrt (letzte Sperre: könnte einen Namen enthalten)'));
      expect(zeilen, contains('beispiel_namen: ${gesperrtText('Beispiel', 'beispiel_namen')}'));
      expect(zeilen, contains('Plugin „Beispiel“: Aufgabe 3 fertig'));
      // Die Namen stehen in keiner Zeile, außer in den Argumenten, die die KI
      // selbst geschickt hat.
      final ohneArgumente = zeilen.where((z) => !z.startsWith('beispiel_echo({'));
      expect(ohneArgumente.join('\n').toLowerCase(), isNot(contains('erika')));
      expect(ohneArgumente.join('\n').toLowerCase(), isNot(contains('mustermann')));
      // Die Lehrkraft sieht jedes Wort, gesammelt.
      expect([for (final t in hinweise.offen) (t.werkzeug, t.stelle, t.wort)], [
        ('beispiel_namen', SperrStelle.protokollzeile, 'Erika'),
        ('beispiel_namen', SperrStelle.ergebnis, 'Erika'),
        ('beispiel_echo', SperrStelle.ergebnis, 'Erika'),
        ('beispiel_echo', SperrStelle.ergebnis, 'MUSTERMANN'),
        ('beispiel_echo', SperrStelle.ergebnis, 'Mustermann'),
      ]);
      expect(hinweise.offen.map((t) => t.plugin).toSet(), {'Beispiel'});
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

    test('antwortet es zweimal nicht binnen der Frist, ist es ausgefallen, und beide Prozesse enden', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final plugins = await beispielAngenommen([profil]);
      final prozesse = <Process>[];
      // Ein Programm, das läuft, aber nie lauscht: ein Dart-Programm, das nur
      // wartet.
      final warten = File(p.join(wurzel.path, 'warten.dart'))
        ..writeAsStringSync('Future<void> main() => Future<void>.delayed(const Duration(minutes: 5));\n');
      final l = LaufendePlugins(
        protokoll,
        startfrist: const Duration(seconds: 2),
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async {
          final prozess = await Process.start(_dart(), [warten.path]);
          prozesse.add(prozess);
          return prozess;
        },
      );

      await starten(plugins, mit: l);

      final e = plugins.eintraege.single;
      expect(prozesse, hasLength(2), reason: 'genau ein zweiter Versuch');
      expect(l.laeuft(e), isFalse);
      expect(l.ausgefallen(e), isTrue);
      expect(l.ausgefalleneNamen, ['Beispiel']);
      expect(l.startfehler(e), contains('nicht binnen 2 Sekunden'));
      expect(l.werkzeuge(profil), isEmpty, reason: 'es hat nie Werkzeuge genannt');
      for (final prozess in prozesse) {
        expect(await _laeuft(prozess.pid), isFalse);
      }
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(
        zeilen,
        contains(startsWith('Plugin „Beispiel“ nicht gestartet: Das Plugin hat nicht binnen 2 Sekunden')),
      );
      expect(zeilen, contains(startsWith('Plugin „Beispiel“ 1.0.0 ausgefallen: Das Plugin hat nicht binnen 2 Sekunden')));
    });

    test('antwortet es beim ersten Versuch nicht, startet der zweite; einen Absturz danach fängt kein Neustart mehr auf', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final plugins = await beispielAngenommen([profil]);
      final warten = File(p.join(wurzel.path, 'warten.dart'))
        ..writeAsStringSync('Future<void> main() => Future<void>.delayed(const Duration(minutes: 5));\n');
      final prozesse = <Process>[];
      final l = LaufendePlugins(
        protokoll,
        startfrist: const Duration(seconds: 2),
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async {
          final prozess = prozesse.isEmpty
              ? await Process.start(_dart(), [warten.path])
              : await Process.start(programm, argumente, environment: umgebung, workingDirectory: arbeitsordner);
          prozesse.add(prozess);
          return prozess;
        },
      );

      await starten(plugins, mit: l);
      final e = plugins.eintraege.single;
      expect(l.laeuft(e), isTrue);
      expect(await _laeuft(prozesse.first.pid), isFalse);
      final client = await verbinden(profil, l);
      expect(await client.tool('beispiel_echo', {'text': 'a'}), startsWith('Echo: a'));

      final r = await client.call('tools/call', {'name': 'beispiel_absturz', 'arguments': <String, Object?>{}});

      expect(r['isError'], true);
      expect(prozesse, hasLength(2), reason: 'Startversuch und Neustart teilen sich den einen');
      expect(l.ausgefallen(e), isTrue);
      expect(l.ausgefalleneNamen, ['Beispiel']);
    });
  });

  group('Absturz eines laufenden Plugins', () {
    /// Startet das Beispiel-Plugin mit einem Starter, der jeden Prozess
    /// sammelt, und verbindet einen Client über den MCP-Server des Profils.
    Future<({LaufendePlugins laufende, McpTestClient client, Plugins plugins, List<Process> prozesse, List<String> starts})>
    gestartet(Profil profil) async {
      final prozesse = <Process>[];
      final starts = <String>[];
      final l = LaufendePlugins(
        protokoll,
        startfrist: const Duration(seconds: 10),
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async {
          starts.add('${argumente.last} ${umgebung[schluesselVariable]}');
          final prozess = await Process.start(programm, argumente, environment: umgebung, workingDirectory: arbeitsordner);
          prozesse.add(prozess);
          return prozess;
        },
      );
      final plugins = await beispielAngenommen([profil]);
      await starten(plugins, mit: l);
      expect(l.laeuft(plugins.eintraege.single), isTrue);
      final client = await verbinden(profil, l);
      return (laufende: l, client: client, plugins: plugins, prozesse: prozesse, starts: starts);
    }

    Future<Map> absturz(McpTestClient c) =>
        c.call('tools/call', {'name': 'beispiel_absturz', 'arguments': <String, Object?>{}});

    String text(Map r) => ((r['content'] as List).single as Map)['text'] as String;

    void ausfallMeldung(Map r) {
      expect(r['isError'], true);
      expect(text(r), contains('„Beispiel“'));
      expect(text(r), contains('ausgefallen'));
      expect(text(r), contains('moocp neu gestartet'));
    }

    test('ein Absturz: der laufende Aufruf bekommt sofort den Fehler, ein Neustart mit neuem Port und Schlüssel, danach arbeitet es wieder', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final g = await gestartet(profil);

      final uhr = Stopwatch()..start();
      final r = await absturz(g.client);
      uhr.stop();

      ausfallMeldung(r);
      expect(uhr.elapsed, lessThan(const Duration(seconds: 5)), reason: 'sofort, nicht erst nach einem Zeitlimit');
      // Ein neuer Aufruf wartet auf den Neustart und geht dann durch.
      expect(await g.client.tool('beispiel_echo', {'text': 'wieder'}), startsWith('Echo: wieder'));
      expect(g.laufende.laeuft(g.plugins.eintraege.single), isTrue);
      expect(g.laufende.ausgefalleneNamen, isEmpty);
      expect(g.starts, hasLength(2));
      expect(g.starts.toSet(), hasLength(2), reason: 'neuer Port und neuer Schlüssel');
      expect(g.starts[0].split(' ').first, isNot(g.starts[1].split(' ').first));
      expect(g.starts[0].split(' ').last, isNot(g.starts[1].split(' ').last));
      expect(await _laeuft(g.prozesse.first.pid), isFalse);
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(zeilen, contains('Plugin „Beispiel“ 1.0.0 unerwartet beendet (Exit-Code 3)'));
      expect(zeilen, contains('Plugin „Beispiel“ 1.0.0 neu gestartet (14 Werkzeuge)'));
      for (final s in g.starts) {
        expect(zeilen.join('\n'), isNot(contains(s.split(' ').last)), reason: 'kein Schlüssel im Protokoll');
      }
    });

    test('nach dem Neustart gilt an der Adresse der App nur der neue Schlüssel', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final g = await gestartet(profil);
      final adresse = g.laufende.appAdresse!;
      final alt = g.starts.single.split(' ').last;
      expect(await _protokollzeile(adresse, alt, 'vorher'), 200);

      ausfallMeldung(await absturz(g.client));
      expect(await g.client.tool('beispiel_echo', {'text': 'wieder'}), startsWith('Echo: wieder'));

      final neu = g.starts.last.split(' ').last;
      expect(neu, isNot(alt));
      expect(await _protokollzeile(adresse, alt, 'mit altem Schlüssel'), 401);
      expect(await _protokollzeile(adresse, neu, 'mit neuem Schlüssel'), 200);
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(zeilen, isNot(contains('Plugin „Beispiel“: mit altem Schlüssel')));
      expect(zeilen, contains('Plugin „Beispiel“: mit neuem Schlüssel'));
    });

    test('ein zweiter Absturz: ausgefallen, jedes Werkzeug nennt das Plugin und bleibt gelistet', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final g = await gestartet(profil);

      ausfallMeldung(await absturz(g.client));
      ausfallMeldung(await absturz(g.client));

      final e = g.plugins.eintraege.single;
      expect(g.laufende.ausgefallen(e), isTrue);
      expect(g.laufende.ausgefalleneNamen, ['Beispiel']);
      expect(g.starts, hasLength(2), reason: 'nur ein Neustart je Lauf');
      ausfallMeldung(await g.client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'x'}}));
      final neu = McpTestClient(profil.port);
      clients.add(neu);
      await neu.initialize();
      expect(await werkzeugnamen(neu), containsAll(['beispiel_echo', 'beispiel_absturz']));
      ausfallMeldung(await neu.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'x'}}));
      for (final prozess in g.prozesse) {
        expect(await _laeuft(prozess.pid), isFalse);
      }
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(zeilen.where((z) => z == 'Plugin „Beispiel“ 1.0.0 unerwartet beendet (Exit-Code 3)'), hasLength(2));
      expect(zeilen, contains(startsWith('Plugin „Beispiel“ 1.0.0 ausgefallen: ')));
    });

    test('haben sich seine Dateien vor dem Neustart geändert, startet es nicht neu und ist ausgefallen', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final g = await gestartet(profil);
      final e = g.plugins.eintraege.single;
      File(p.join(e.pfad, 'neu.txt')).writeAsStringSync('dazugekommen');

      ausfallMeldung(await absturz(g.client));
      ausfallMeldung(await g.client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'x'}}));

      expect(g.starts, hasLength(1), reason: 'kein Neustart');
      expect(g.laufende.ausgefallen(e), isTrue);
      expect(g.laufende.startfehler(e), contains('geändert'));
      expect(
        [for (final z in protokoll.eintraege) z.text],
        contains(allOf(startsWith('Plugin „Beispiel“ 1.0.0 ausgefallen: '), contains('geändert'))),
      );
    });

    test('die Namen überstehen einen Neustart: Auch das neu gestartete Plugin bleibt gesperrt', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final g = await gestartet(profil);
      final r = await g.client.call('tools/call', {'name': 'beispiel_namen', 'arguments': <String, Object?>{}});
      expect(r['isError'], true);

      ausfallMeldung(await absturz(g.client));
      final danach = await g.client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'Erika'}});

      expect(g.starts, hasLength(2), reason: 'neu gestartet');
      expect(danach['isError'], true);
      expect(text(danach), gesperrtText('Beispiel', 'beispiel_echo'));
      expect(await g.client.tool('beispiel_echo', {'text': 'Hallo'}), startsWith('Echo: Hallo'));
    });

    test('nennt das Plugin nach einem Neustart eine Werkzeugliste mit einem gesperrten Namen, startet es nicht und ist ausgefallen', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      // Der Neustart ist ein anderes Programm: ein kleiner MCP-Server, dessen
      // Werkzeugbeschreibung den Namen trägt.
      // Außerhalb des Plugin-Ordners und mit eigenem Aufräumen: Das dart des
      // SDK startet die VM als eigenen Prozess, der die Datei noch einen
      // Augenblick offen hält, nachdem dart selbst geendet hat.
      final skriptOrdner = Directory.systemTemp.createTempSync('moocp_liste_');
      addTearDown(() async {
        for (var i = 0; i < 50 && skriptOrdner.existsSync(); i++) {
          try {
            skriptOrdner.deleteSync(recursive: true);
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }
      });
      final skript = File(p.join(skriptOrdner.path, 'liste.dart'))
        ..writeAsStringSync('''
import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
Future<void> main(List<String> a) async {
  final port = int.parse(a[a.indexOf('--port') + 1]);
  final key = Platform.environment['$schluesselVariable']!;
  final server = StreamableMcpServer(
    serverFactory: (_) => McpServer(const Implementation(name: 'liste', version: '1'))
      ..registerTool('beispiel_echo', description: 'Nur für Erika.', inputSchema: JsonSchema.object(properties: {}),
          callback: (args, extra) async => CallToolResult.fromContent([const TextContent(text: 'ok')])),
    host: '127.0.0.1', port: port, path: '/mcp', enableJsonResponse: true,
    authenticator: (r) => r.headers.value(HttpHeaders.authorizationHeader) == 'Bearer \$key');
  await server.start();
  stdin.listen((_) {}, onDone: () async { await server.stop(); exit(0); });
}
''');
      final pakete = File(p.join('.dart_tool', 'package_config.json')).absolute.path;
      final prozesse = <Process>[];
      final hinweise = SperrHinweise();
      final l = LaufendePlugins(
        protokoll,
        sperrHinweise: hinweise,
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async {
          final prozess = prozesse.isEmpty
              ? await Process.start(programm, argumente, environment: umgebung, workingDirectory: arbeitsordner)
              : await Process.start(_dart(), ['--packages=$pakete', skript.path, ...argumente], environment: umgebung);
          prozesse.add(prozess);
          return prozess;
        },
      );
      final plugins = await beispielAngenommen([profil]);
      await starten(plugins, mit: l);
      final client = await verbinden(profil, l);
      expect((await client.call('tools/call', {'name': 'beispiel_namen', 'arguments': <String, Object?>{}}))['isError'], true);

      ausfallMeldung(await absturz(client));
      ausfallMeldung(await client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'x'}}));

      final e = plugins.eintraege.single;
      expect(prozesse, hasLength(2));
      expect(l.ausgefallen(e), isTrue);
      expect(l.startfehler(e), werkzeuglisteGesperrt);
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(zeilen, contains('Plugin „Beispiel“: Werkzeugliste gesperrt (letzte Sperre: könnte einen Namen enthalten)'));
      expect(zeilen.join('\n'), isNot(contains('Erika')));
      expect(hinweise.offen.last.stelle, SperrStelle.werkzeugliste);
      expect(hinweise.offen.last.wort, 'Erika');
      expect(hinweise.offen.last.werkzeug, isNull);
      expect(einstellungen.plugins['beispiel']!.werkzeuge!.map((w) => w.beschreibung).join(), isNot(contains('Erika')));
      for (final prozess in prozesse) {
        expect(await _laeuft(prozess.pid), isFalse);
      }
    });

    test('das reguläre Beenden ist kein Absturz: kein Neustart, keine Anzeige', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final g = await gestartet(profil);

      await g.laufende.beenden();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(g.starts, hasLength(1));
      expect(g.laufende.ausgefalleneNamen, isEmpty);
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(zeilen, isNot(contains(contains('unerwartet'))));
      expect(zeilen, isNot(contains(contains('ausgefallen'))));
    });
  });

  group('Die Werkzeugliste für die Brücke', () {
    /// Ob ein Prozess dieses Programms läuft (nur Windows).
    Future<bool> programmLaeuft(String name) async {
      final r = await Process.run('tasklist', ['/FI', 'IMAGENAME eq $name', '/NH']);
      return '${r.stdout}'.toLowerCase().contains(name.toLowerCase());
    }

    test('nach dem Start ist die Liste gemerkt; --werkzeugliste nennt sie wie der Server, ohne ein Plugin zu starten', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      final client = await verbinden(profil, l);
      final vomServer = [
        for (final t in (await client.call('tools/list'))['tools'] as List)
          if ((t as Map)['name'] == 'beispiel_echo') t,
      ].single;
      expect(einstellungen.plugins['beispiel']!.werkzeuge!.map((w) => w.name), _beispielWerkzeuge);

      // Die App ist zu und das Plugin mit ihr; die Datei bleibt.
      await l.beenden();
      expect(await programmLaeuft('beispiel.exe'), isFalse);
      final datei = File(p.join(wurzel.path, 'einstellungen.json'))..writeAsStringSync(jsonEncode(einstellungen.zuJson()));
      final ausgabe = await werkzeuglisteFuerBruecke(
        einstellungen: () => datei,
        plugins: () => Directory(p.join(wurzel.path, 'plugins')),
      );

      final echo = [
        for (final t in (ausgabe['tools'] as Map)['tools'] as List)
          if ((t as Map)['name'] == 'beispiel_echo') t,
      ].single;
      expect(jsonEncode(echo), jsonEncode(vomServer), reason: 'dieselbe Beschreibung wie beim laufenden Plugin');
      expect(await programmLaeuft('beispiel.exe'), isFalse, reason: '--werkzeugliste startet kein Plugin');
    }, skip: Platform.isWindows ? false : 'prüft die Prozessliste von Windows');

    test('beim nächsten Start der App ist dieselbe Liste schon gemerkt: nichts wird erneut geschrieben', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      await l.beenden();
      final json = jsonDecode(jsonEncode(einstellungen.zuJson())) as Map<String, dynamic>;
      einstellungen = _EinstellungenOhneDatei(profile: [profil])
        ..plugins = Einstellungen.aus(json, Einstellungen(schluessel: 'x')).plugins;

      final plugins = await Plugins.laden(einstellungen, protokoll, Directory(p.join(wurzel.path, 'plugins')));
      final neu = await starten(plugins);

      expect(neu.laeuft(plugins.eintraege.single), isTrue);
      expect(einstellungen.plugins['beispiel']!.werkzeuge!.map((w) => w.name), _beispielWerkzeuge);
      expect(einstellungen.gespeichert, 0);
    });

    test('wird das Plugin ausgetauscht, fehlt seine Liste, bis es mit neuer Zustimmung gestartet ist', () async {
      final profil = _profil('standard', 'moodle', await _freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      await l.beenden();
      File(p.join(wurzel.path, 'plugins', 'beispiel', 'plugin.json'))
          .writeAsStringSync(File(p.join('beispiele', 'plugin', 'plugin.json')).readAsStringSync().replaceFirst('1.0.0', '1.0.1'));

      final plugins = await Plugins.laden(einstellungen, protokoll, Directory(p.join(wurzel.path, 'plugins')));
      final neu = await starten(plugins);

      expect(neu.laeuft(plugins.eintraege.single), isFalse, reason: 'ohne Zustimmung zu diesem Stand läuft nichts');
      expect(einstellungen.plugins['beispiel']!.werkzeuge, isNull);
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
        throwsA(isA<PluginErgebnisFehler>().having((f) => f.meldung, 'meldung', 'Geht nicht.')),
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
