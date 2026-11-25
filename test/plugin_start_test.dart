// Ein angenommenes Plugin starten und seine Werkzeuge anbieten (E35): so, wie
// ein KI-Werkzeug es sieht -- über den MCP-Server der App, mit dem
// Beispiel-Plugin (example/example-plugin/) als echtem Kindprozess auf der anderen
// Seite. Wo kein echter Prozess nötig ist (Namensregeln, Abbruch), steht ein
// kleiner MCP-Server im Test an seiner Stelle. Alles in Temp-Ordnern, nie im
// Einstellungsordner der App.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:moocp/anmeldung.dart' show Instanz, mcpServerStarten;
import 'package:moocp/einstellungen.dart';
import 'package:moocp/einstellungen_dialog.dart' show pluginLaufHinweis;
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/mcp/testbetrieb.dart' show pluginDialogantwortenDatei;
import 'package:moocp/mcp/werkzeugquelle.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/plugin/app_adresse.dart';
import 'package:moocp/plugin/dialoge.dart';
import 'package:moocp/plugin/downloads.dart';
import 'package:moocp/plugin/laufende_plugins.dart';
import 'package:moocp/plugin/moodle_schreiben.dart' show datenschutzAutomatischKennzeichnung, testantwortenKennzeichnung, zusatzKennzeichnung;
import 'package:moocp/plugin/datenschutz.dart' show DatenschutzAusgang, Datenschutzwarnung, Herkunft;
import 'package:moocp/plugin/plugins.dart';
import 'package:moocp/plugin/verbindung.dart';
import 'package:moocp/plugin/werkzeugliste.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:moocp/testzugang.dart';
import 'package:path/path.dart' as p;

import 'hilfen/beispiel_plugin.dart';
import 'hilfen/zugang.dart';
import 'mcp_client.dart';
import 'plugin_moodle_test.dart' show PluginTestMoodle, exportGroesse, lehrkraftImDoppel, sitzungsCookie;

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
    await beispielUebersetzen(p.join(vorlage.path, 'beispiel.exe'));
    File(p.join(beispielOrdner, 'plugin.json')).copySync(p.join(vorlage.path, 'plugin.json'));
    eingebaut = await eingebauteWerkzeuge();
  });
  tearDownAll(() => ordnerLoeschen(vorlage));

  late Directory wurzel;
  late Protokoll protokoll;
  late EinstellungenOhneDatei einstellungen;

  /// Jede Datenschutzwarnung, die die Lehrkraft in diesem Test gesehen hat,
  /// und wie sie antwortet (null: gar nicht, bis die Frist oder der Abbruch
  /// sie beendet).
  final warnungen = <Datenschutzwarnung>[];
  bool? Function() warnantwort = () => false;
  final laufende = <LaufendePlugins>[];
  final dienste = <McpDienst>[];
  final clients = <McpTestClient>[];

  setUp(() {
    wurzel = Directory.systemTemp.createTempSync('moocp_plugins_');
    protokoll = Protokoll();
    warnungen.clear();
    warnantwort = () => false;
  });

  /// Freigaben, die eine Datenschutzwarnung wie die Lehrkraft beantworten:
  /// [warnantwort] sagt true (senden), false (Sperren) oder null (keine
  /// Entscheidung). Jede andere Anfrage lehnt sie ab.
  Freigaben fragendeFreigaben({Duration frist = Freigaben.fristVorgabe}) {
    final f = Freigaben(protokoll, frist: frist);
    f.addListener(() {
      final a = f.aktuell;
      if (a == null || !a.offen) return;
      final w = a.datenschutz;
      if (w != null) warnungen.add(w);
      final antwort = w == null ? false : warnantwort();
      if (antwort != null) scheduleMicrotask(() => f.entscheiden(antwort));
    });
    return f;
  }

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
    await ordnerLoeschen(wurzel);
  });

  /// Legt das übersetzte Beispiel-Plugin unter `plugins/beispiel` an und
  /// stimmt ihm zu, eingeschaltet in [aktiv].
  Future<Plugins> beispielAngenommen(List<Profil> profile, {Set<String>? aktiv}) async {
    final ordner = Directory(p.join(wurzel.path, 'plugins', 'beispiel'))..createSync(recursive: true);
    for (final f in vorlage.listSync().whereType<File>()) {
      f.copySync(p.join(ordner.path, p.basename(f.path)));
    }
    einstellungen = EinstellungenOhneDatei(profile: profile);
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
    Testzugang? testzugang,
  }) async {
    final d = McpDienst(
      einstellungen,
      moodle ?? MoodleZugang(protokoll),
      protokoll,
      freigaben ?? fragendeFreigaben(),
      arbeitsordner,
      profil: profil,
      testzugang: testzugang,
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
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      final client = await verbinden(profil, l);

      expect(await werkzeugnamen(client), contains('beispiel_echo'));
      final text = await client.tool('beispiel_echo', {'text': 'Hallo'});

      expect(text, 'Echo: Hallo\nProfil: moodle\nAufruf-Token: erhalten\nSchnittstelle: 1');
      final zeilen = [for (final e in protokoll.eintraege) e.text];
      expect(zeilen, contains('Plugin „Beispiel“ 1.0.0 gestartet (18 Werkzeuge)'));
      expect(zeilen, contains('beispiel_echo({"text":"Hallo"})'));
      expect(zeilen, contains('beispiel_echo: Echo: Hallo'));
    });

    test('über die Adresse der App: Protokollzeile, Datei im Arbeitsordner und das eingebaute status', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
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
      expect(status, contains('Verbunden über: Plugin „Beispiel“'));
      expect(zeilen, contains('status({}) -- Aufrufer: Plugin „Beispiel“'));
      expect(l.appAdresse?.host, '127.0.0.1');
    });

    test('mit eingeschaltetem Plugin startet der MCP-Server erst nach Einrichtung und Anmeldung und bleibt dann an', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      expect(l.werkzeuge(profil), isNotEmpty, reason: 'das Plugin läuft und ist in diesem Profil eingeschaltet');
      final zugang = SchaltbarerZugang(protokoll);
      final freigaben = Freigaben(protokoll);
      final d = McpDienst(einstellungen, zugang, protokoll, freigaben, '', profil: profil, werkzeugquellen: [l]);
      dienste.add(d);
      final instanzen = [Instanz(zugang, freigaben, d)];
      Future<void> serverStarten({bool eingerichtet = true}) =>
          mcpServerStarten(instanzen, eingerichtet: eingerichtet, protokoll: protokoll);

      // Eingerichtet, aber nicht angemeldet: kein Server, auch mit Plugin.
      await serverStarten();
      expect(d.laeuft, isFalse);
      await expectLater(Socket.connect('127.0.0.1', profil.port), throwsA(isA<SocketException>()));
      // Angemeldet, aber nicht eingerichtet: ebenso nicht.
      zugang.an = true;
      await serverStarten(eingerichtet: false);
      expect(d.laeuft, isFalse);

      await serverStarten();
      expect(d.laeuft, isTrue);
      final client = McpTestClient(profil.port);
      clients.add(client);
      await client.initialize();
      expect(await werkzeugnamen(client), containsAll([...beispielWerkzeuge, 'status']));

      // Nach dem Abmelden bleibt er an, und die Sitzung des KI-Werkzeugs hält.
      zugang.an = false;
      await serverStarten();
      expect(d.laeuft, isTrue);
      expect(await client.tool('beispiel_echo', {'text': 'Hallo'}), startsWith('Echo: Hallo'));
      expect(zugang.anmeldeversuche, 0, reason: 'der Start der Server meldet nie selbst an');
      expect([for (final e in protokoll.eintraege) e.text].where((z) => z.startsWith('MCP-Server läuft auf')), hasLength(1));
    });

    test('Dialoge und Freigabe: jede Art über die Adresse der App, die Antwort kommt beim Plugin an', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
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
      expect(ohne, contains('Ohne Freigabe ausgeführt (1 Vorgang, Aufrufer: Plugin „Beispiel“)'));
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
      final profil = beispielProfil('standard', 'moodle', await freierPort());
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
      // Die Seite trug in der Anmeldezeile den Namen der Lehrkraft: Er sperrt
      // von nun an jede Antwort dieses Plugins an die KI.
      final g = await client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'Frau Musterlehrerin'}});
      expect(g['isError'], true);
      expect(((g['content'] as List).single as Map)['text'], gesperrtText('Beispiel', 'beispiel_echo'));
    });

    test('eine Datei über die Positivliste: landet im Unterordner des Plugins im Arbeitsordner', () async {
      final moodle = PluginTestMoodle();
      await moodle.starten();
      addTearDown(() => moodle.server.close(force: true));
      final zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
      moodle.angefragt.clear();
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      final ordner = Directory(p.join(wurzel.path, 'arbeitsordner'))..createSync();
      final client = await verbinden(profil, l, arbeitsordner: ordner.path, moodle: zugang);

      final geladen = await client.tool('beispiel_moodle_datei', {'pfad': '/pluginfile.php/55/mod_folder/content/0/blatt.pdf'});
      final gesperrt = await client.call('tools/call', {
        'name': 'beispiel_moodle_datei',
        'arguments': {'pfad': '/admin/tool/x/datei.pdf'},
      });

      final ziel = p.join(ordner.path, 'plugin-beispiel', 'blatt.pdf');
      expect(geladen, 'Datei geladen: $ziel (2048 Bytes)');
      expect(File(ziel).lengthSync(), 2048);
      expect(gesperrt['isError'], true);
      expect(moodle.angefragt, ['GET /pluginfile.php/55/mod_folder/content/0/blatt.pdf']);
      final zeilen = [for (final e in protokoll.eintraege) e.text];
      expect(zeilen, contains('Plugin „Beispiel“: GET /pluginfile.php/55/mod_folder/content/0/blatt.pdf → 200'));
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
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      final client = await verbinden(profil, l, moodle: zugang, freigaben: freigaben);

      // Ohne Lauf: geschrieben, aber den Inhalt der Seite danach bekommt das
      // Plugin nicht und kann nicht nachsehen.
      final ohneLauf = await client.tool('beispiel_moodle_schreiben', {'id': 7, 'notiz': 'Hallo'});
      expect(
        ohneLauf,
        '${zusatzKennzeichnung('Beispiel', 1)}\n\nGesendet; Moodle antwortet mit Status 200. Nicht geprüft: Ohne '
        'Lauf liefert moocp den Inhalt der Seite nicht.',
      );
      expect(moodle.angefragt, ['POST /mod/beispiel/speichern.php?id=7', 'GET /mod/beispiel/speichern.php?id=7&gespeichert=1']);
      expect(moodle.notiz, 'Hallo');
      moodle.angefragt.clear();
      gezeigt.clear();

      // Im Lauf für die Aktivität: geschrieben und vom Plugin nachgesehen.
      final geschrieben = await client.tool('beispiel_moodle_schreiben', {'id': 501, 'notiz': 'Hallo', 'lauf': true});

      expect(
        geschrieben,
        '${zusatzKennzeichnung('Beispiel', 1)}\n\nGeschrieben und vom Plugin geprüft: Die Notiz steht auf der Seite.',
      );
      expect(geschrieben, isNot(contains('verified')));
      expect(
        moodle.angefragt.where((x) => x.contains('/mod/beispiel/')),
        ['POST /mod/beispiel/speichern.php?id=501', 'GET /mod/beispiel/speichern.php?id=501&gespeichert=1'],
      );
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

    test('Testbetrieb: ein Dialog des Beispiels aus der vorbereiteten Antwort, und die Antwort an die KI sagt es', () async {
      final moodle = PluginTestMoodle();
      await moodle.starten();
      addTearDown(() => moodle.server.close(force: true));
      final zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
      final dialoge = PluginDialoge();
      var gezeigt = 0;
      dialoge.addListener(() {
        final d = dialoge.aktuell;
        if (d != null && d.offen) {
          gezeigt++;
          scheduleMicrotask(() => dialoge.beantworten(d, null));
        }
      });
      final profil = Profil(
        kennung: 'standard',
        name: 'moodle',
        adresse: moodle.basis.toString(),
        port: await freierPort(),
        mcpName: 'moodle',
        schluessel: 'test',
      );
      // Erfunden: Die Zugangsdatei selbst liest hier niemand, nur ihr Ordner zählt.
      final testzugang = Testzugang(
        kennung: 'standard',
        datei: p.join(wurzel.path, 'testzugang.env'),
        adresse: profil.adresse,
        kurse: const {12},
      );
      File(p.join(wurzel.path, pluginDialogantwortenDatei)).writeAsStringSync(
        jsonEncode({
          'antworten': [
            {'plugin': 'beispiel', 'art': 'hinweis', 'titel': 'Hinweis des Beispiels', 'antwort': <String, Object?>{}},
          ],
        }),
      );
      final l = await starten(await beispielAngenommen([profil]), mit: LaufendePlugins(protokoll, dialoge: dialoge));
      final client = await verbinden(profil, l, moodle: zugang, testzugang: testzugang);

      expect(
        await client.tool('beispiel_hinweis', {'text': 'Fertig.'}),
        '${testantwortenKennzeichnung('Beispiel', 1)}\n\nBestätigt.',
      );
      expect(gezeigt, 0);
      // Ohne passende Antwort erscheint der Dialog, und die Antwort bleibt, wie sie ist.
      expect(await client.tool('beispiel_auswahl', {}), isNot(contains('Hinweis von moocp')));
      expect(gezeigt, 1);
    });

    test('Testbetrieb: Schreiben in einem Lauf im Testkurs, automatisch freigegeben, die KI erfährt es', () async {
      final moodle = PluginTestMoodle();
      await moodle.starten();
      addTearDown(() => moodle.server.close(force: true));
      final zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
      await zugang.sesskey();
      moodle.angefragt.clear();
      final freigaben = Freigaben(protokoll);
      final gezeigt = <FreigabeAnfrage>[];
      freigaben.addListener(() {
        final f = freigaben.aktuell;
        if (f != null && f.offen && !gezeigt.contains(f)) {
          gezeigt.add(f);
          scheduleMicrotask(() => freigaben.entscheiden(false));
        }
      });
      final profil = Profil(
        kennung: 'standard',
        name: 'moodle',
        adresse: moodle.basis.toString(),
        port: await freierPort(),
        mcpName: 'moodle',
        schluessel: 'test',
      );
      // Erfunden: Die Zugangsdatei selbst liest hier niemand.
      final testzugang = Testzugang(
        kennung: 'standard',
        datei: p.join(wurzel.path, 'testzugang.env'),
        adresse: profil.adresse,
        kurse: const {12},
      );
      final l = await starten(await beispielAngenommen([profil]));
      final client = await verbinden(profil, l, moodle: zugang, freigaben: freigaben, testzugang: testzugang);

      final text = await client.tool('beispiel_moodle_schreiben', {'id': 501, 'notiz': 'Hallo', 'lauf': true});

      expect(gezeigt, isEmpty);
      expect(freigaben.testfreigaben, 1);
      expect(
        text,
        startsWith(
          '${zusatzKennzeichnung('Beispiel', 1, automatisch: 1)}\n\n'
          'Geschrieben und vom Plugin geprüft: Die Notiz steht auf der Seite.',
        ),
      );
      expect(text, contains(testfreigabeHinweis));
      expect(moodle.angefragt.where((x) => x.startsWith('POST ')), ['POST /mod/beispiel/speichern.php?id=501']);

      // Außerhalb eines Laufs kennt moocp den Kurs nicht: der Dialog.
      final ohneLauf = await client.tool('beispiel_moodle_schreiben', {'id': 501, 'notiz': 'Nein'});
      expect(ohneLauf, 'Nicht geschrieben: Die Lehrkraft hat nicht freigegeben (abgelehnt).');
      expect(gezeigt, hasLength(1));
    });

    test('ein Lauf: ohne abgelehnt, im Lauf gelesen, danach abgelehnt; die Namen des Kurses sperren jede Antwort', () async {
      final moodle = PluginTestMoodle();
      await moodle.starten();
      addTearDown(() => moodle.server.close(force: true));
      final zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
      moodle.angefragt.clear();
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      final client = await verbinden(profil, l, moodle: zugang);

      final lauf = await client.tool('beispiel_lauf', {'cmid': 501});

      expect(
        lauf,
        matches(
          RegExp(
            r'^Ohne Lauf: abgelehnt \(HTTP 403\)\.\nLauf begonnen für Kurs 12\.\n'
            r'Im Lauf: Moodle antwortet mit Status 200 \(text/html, \d+ Zeichen\)\.\nLauf beendet\.\n'
            r'Nach dem Lauf: abgelehnt \(HTTP 403\)\.$',
          ),
        ),
      );
      expect(moodle.angefragt, [
        'GET /course/modedit.php?update=501',
        'GET /user/index.php?id=12&perpage=5000&tifirst=&tilast=',
        'GET /mod/beispiel/bericht.php?id=501',
      ]);
      // Nach dem Lauf sperrt jeder Name des Kurses, auch der Lehrkraft, jede
      // Antwort dieses Plugins an die KI; was keinen Namen trägt, geht durch.
      for (final name in ['Erika', 'Lieschen Mueller', 'Max', lehrkraftImDoppel]) {
        final g = await client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': name}});
        expect(g['isError'], true, reason: name);
        expect(((g['content'] as List).single as Map)['text'], gesperrtText('Beispiel', 'beispiel_echo'), reason: name);
      }
      expect(await client.tool('beispiel_echo', {'text': 'Aufgabe 3'}), startsWith('Echo: Aufgabe 3'));
      final zeilen = [for (final e in protokoll.eintraege) e.text];
      expect(zeilen, contains('Plugin „Beispiel“: Lauf begonnen, 4 Namen zum Sperren geladen'));
      expect(zeilen, contains('Plugin „Beispiel“, Zusatzadresse: GET /mod/beispiel/bericht.php?id=… → 200'));
      expect(zeilen, contains('Plugin „Beispiel“: Lauf beendet'));
      // Kein Name in einer Zeile, außer in den Argumenten, die die KI selbst
      // geschickt hat.
      final ohneArgumente = zeilen.where((z) => !z.startsWith('beispiel_echo({')).join('\n').toLowerCase();
      for (final n in ['erika', 'mustermann', 'lieschen', 'müller', 'paula', 'musterlehrerin']) {
        expect(ohneArgumente, isNot(contains(n)), reason: n);
      }
      expect(ohneArgumente, isNot(contains('abc123')));
    });

    test('ein Download im Lauf: nicht im Arbeitsordner, nach dem Lauf gelöscht; der Pfad sperrt jede Antwort', () async {
      final moodle = PluginTestMoodle();
      await moodle.starten();
      addTearDown(() => moodle.server.close(force: true));
      final zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
      moodle.angefragt.clear();
      final (downloads, _) = PluginDownloads.einrichten(basis: p.join(wurzel.path, 'temp'));
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final arbeitsordner = Directory(p.join(wurzel.path, 'arbeitsordner'))..createSync();
      final l = await starten(
        await beispielAngenommen([profil]),
        mit: LaufendePlugins(protokoll, downloads: downloads),
      );
      final client = await verbinden(profil, l, moodle: zugang, arbeitsordner: arbeitsordner.path);

      final text = await client.tool('beispiel_download', {'cmid': 501});

      expect(
        text,
        'Im Lauf heruntergeladen: $exportGroesse Bytes, die Datei hat $exportGroesse Bytes.\n'
        'Nach dem Lauf: Die Datei ist gelöscht.',
      );
      expect(moodle.angefragt, contains('GET /mod/beispiel/export.php?id=501'));
      expect(arbeitsordner.listSync(recursive: true).whereType<File>(), isEmpty);
      expect(Directory(downloads.wurzel).listSync(recursive: true).whereType<File>(), isEmpty);
      final zeilen = [for (final e in protokoll.eintraege) e.text];
      expect(zeilen, contains('Plugin „Beispiel“, Zusatzadresse: GET /mod/beispiel/export.php?id=… → 200'));
      expect(zeilen.join('\n').toLowerCase(), isNot(contains(PluginDownloads.ordnername)));

      // Nennt eine Antwort des Plugins den Ordner, in welcher Schreibweise
      // auch immer, geht sie nicht an die KI.
      for (final t in [
        p.join(downloads.wurzel, 'beispiel', 'standard', '1.bin'),
        downloads.wurzel.toUpperCase().replaceAll(r'\', '/'),
      ]) {
        final g = await client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': t}});
        expect(g['isError'], true, reason: t);
        expect(((g['content'] as List).single as Map)['text'], gesperrtText('Beispiel', 'beispiel_echo'), reason: t);
      }
      expect(warnungen, hasLength(2));
      expect([for (final w in warnungen) w.hatPfade && !w.hatNamen], [true, true]);
      expect(await client.tool('beispiel_echo', {'text': 'Aufgabe 3'}), startsWith('Echo: Aufgabe 3'));
    });

    test('Datenschutzwarnung: Das Beispiel nennt einen Namen; seine Protokollzeile wird zum Platzhalter, seine Antwort fragt, Sperren hält sie an', () async {
      final eins = beispielProfil('standard', 'moodle', await freierPort());
      final zwei = beispielProfil('k2', 'moodle-test', await freierPort());
      final l = await starten(await beispielAngenommen([eins, zwei]));
      final a = await verbinden(eins, l);
      final b = await verbinden(zwei, l);

      final r = await a.call('tools/call', {'name': 'beispiel_namen', 'arguments': <String, Object?>{}});

      expect(r['isError'], true);
      expect(((r['content'] as List).single as Map)['text'], gesperrtText('Beispiel', 'beispiel_namen'));
      expect(jsonEncode(r), isNot(contains('Erika')));
      expect(jsonEncode(r), isNot(contains('Mustermann')));
      expect(warnungen, hasLength(1));
      expect(warnungen.single.plugin, 'Beispiel');
      expect(warnungen.single.werkzeug, 'beispiel_namen');
      // Die Entscheidung gilt für diese eine Antwort: Die nächste fragt wieder,
      // in jedem Profil, für jeden Teil des Namens; was keinen Namen trägt,
      // geht ohne Frage durch.
      for (final (client, text) in [(a, 'Erika'), (b, 'MUSTERMANN'), (b, 'Frau Mustermann')]) {
        final g = await client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': text}});
        expect(g['isError'], true, reason: text);
        expect(((g['content'] as List).single as Map)['text'], gesperrtText('Beispiel', 'beispiel_echo'));
      }
      expect(warnungen, hasLength(4));
      expect(await b.tool('beispiel_echo', {'text': 'Hallo'}), startsWith('Echo: Hallo'));
      expect(warnungen, hasLength(4), reason: 'ohne Treffer keine Frage');
      expect(await a.tool('beispiel_protokoll', {'text': 'Aufgabe 3 fertig'}), 'Die Zeile steht im Protokoll von moocp.');

      final zeilen = [for (final e in protokoll.eintraege) e.text];
      expect(zeilen, contains('Plugin „Beispiel“: 1 Name zum Sperren genannt'));
      expect(zeilen, contains('Plugin „Beispiel“: [gesperrt: möglicher Name]'));
      expect(zeilen, contains('Plugin „Beispiel“, Werkzeug beispiel_namen: Datenschutzwarnung, 2 Treffer, gesperrt'));
      expect(zeilen, contains('beispiel_namen: ${gesperrtText('Beispiel', 'beispiel_namen')}'));
      expect(zeilen, contains('Plugin „Beispiel“: Aufgabe 3 fertig'));
      // Kein Wort in einer Zeile, außer in den Argumenten, die die KI selbst
      // geschickt hat.
      final ohneArgumente = zeilen.where((z) => !z.startsWith('beispiel_echo({'));
      expect(ohneArgumente.join('\n').toLowerCase(), isNot(contains('erika')));
      expect(ohneArgumente.join('\n').toLowerCase(), isNot(contains('mustermann')));
    });

    test('Datenschutzwarnung: „trotzdem senden“ gibt die Antwort unverändert hinaus, die nächste fragt wieder', () async {
      final eins = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([eins]));
      final a = await verbinden(eins, l);
      await a.call('tools/call', {'name': 'beispiel_namen', 'arguments': <String, Object?>{}});
      warnungen.clear();
      warnantwort = () => true;

      final erste = await a.tool('beispiel_echo', {'text': 'Abgabe von Erika'});
      final zweite = await a.tool('beispiel_echo', {'text': 'Abgabe von Erika'});

      expect(erste, startsWith('Echo: Abgabe von Erika'));
      expect(zweite, startsWith('Echo: Abgabe von Erika'));
      expect(warnungen, hasLength(2), reason: 'nichts wird gemerkt');
      final f = warnungen.first.funde.single;
      expect([f.wort, f.davor, f.pfad], ['Erika', 'Echo: Abgabe von ', false]);
      expect(
        [for (final e in protokoll.eintraege) e.text],
        contains('Plugin „Beispiel“, Werkzeug beispiel_echo: Datenschutzwarnung, 1 Treffer, trotzdem gesendet'),
      );
    });

    test('Testbetrieb: die Datenschutzwarnung aus der vorbereiteten Antwort, der Lauf geht nach einer Sperre weiter', () async {
      final moodle = PluginTestMoodle();
      await moodle.starten();
      addTearDown(() => moodle.server.close(force: true));
      final zugang = await MoodleZugang.fuerTest(protokoll, moodle.basis, benutzer: 'e.mustermann', passwort: 'geheim');
      final profil = Profil(
        kennung: 'standard',
        name: 'moodle',
        adresse: moodle.basis.toString(),
        port: await freierPort(),
        mcpName: 'moodle',
        schluessel: 'test',
      );
      // Erfunden: Die Zugangsdatei selbst liest hier niemand, nur ihr Ordner zählt.
      final testzugang = Testzugang(
        kennung: 'standard',
        datei: p.join(wurzel.path, 'testzugang.env'),
        adresse: profil.adresse,
        kurse: const {12},
      );
      void antwort(String? ausgang) => File(p.join(wurzel.path, pluginDialogantwortenDatei)).writeAsStringSync(
        jsonEncode({
          'antworten': [
            if (ausgang != null)
              {'plugin': 'beispiel', 'art': 'datenschutz', 'titel': 'beispiel_echo', 'antwort': {'ausgang': ausgang}},
          ],
        }),
      );
      final l = await starten(await beispielAngenommen([profil]));
      final client = await verbinden(profil, l, moodle: zugang, testzugang: testzugang);
      await client.call('tools/call', {'name': 'beispiel_namen', 'arguments': <String, Object?>{}});
      warnungen.clear();
      Future<Map> echo() async => (await client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'Abgabe von Erika'}}));
      String text(Map r) => ((r['content'] as List).single as Map)['text'] as String;

      antwort('sperren');
      final gesperrt = await echo();
      expect(gesperrt['isError'], true);
      expect(text(gesperrt), '${datenschutzAutomatischKennzeichnung('Beispiel', gesendet: false)}\n\n${gesperrtText('Beispiel', 'beispiel_echo')}');
      expect(text(gesperrt), isNot(contains('Erika')));

      // Nach der Sperre läuft es weiter: Die nächste Antwort geht, mit „senden“ unverändert.
      antwort('senden');
      expect(
        (await echo())['isError'],
        isNot(true),
      );
      antwort('senden');
      expect(
        text(await echo()),
        startsWith('${datenschutzAutomatischKennzeichnung('Beispiel', gesendet: true)}\n\nEcho: Abgabe von Erika'),
      );

      // Ohne vorbereitete Antwort: gesperrt, ohne dass die Lehrkraft gefragt wird.
      antwort(null);
      final ohne = await echo();
      expect(ohne['isError'], true);
      expect(text(ohne), contains(gesperrtText('Beispiel', 'beispiel_echo')));
      expect(warnungen, isEmpty, reason: 'im Testbetrieb erscheint kein Dialog');

      final zeilen = [for (final e in protokoll.eintraege) e.text];
      expect(zeilen, contains('Plugin „Beispiel“, Werkzeug beispiel_echo: Datenschutzwarnung, 1 Treffer, gesperrt (automatisch, ohne Lehrkraft)'));
      expect(zeilen, contains('Plugin „Beispiel“, Werkzeug beispiel_echo: Datenschutzwarnung, 1 Treffer, trotzdem gesendet (automatisch, ohne Lehrkraft)'));
      expect(zeilen, contains(contains('Testbetrieb, ohne Lehrkraft beantwortet: Datenschutzwarnung von Plugin „Beispiel“')));
      // Ein vom Plugin gemeldeter Name bleibt ein Platzhalter, auch im Testbetrieb.
      expect(zeilen, contains(contains('1 Treffer ([gesperrt: möglicher Name]) -- gesperrt')));
      final ohneArgumente = zeilen.where((z) => !z.startsWith('beispiel_echo({') && !z.startsWith('beispiel_echo: Echo:'));
      expect(ohneArgumente.join('\n').toLowerCase(), isNot(contains('erika')));
    });

    test('ohne Testbetrieb (kein Testzugang) fragt die Lehrkraft, auch wenn eine Datei mit Antworten daliegt', () async {
      File(p.join(wurzel.path, pluginDialogantwortenDatei)).writeAsStringSync(
        jsonEncode({
          'antworten': [
            {'plugin': 'beispiel', 'art': 'datenschutz', 'titel': 'beispiel_echo', 'antwort': {'ausgang': 'senden'}},
          ],
        }),
      );
      final eins = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([eins]));
      final a = await verbinden(eins, l);
      await a.call('tools/call', {'name': 'beispiel_namen', 'arguments': <String, Object?>{}});
      warnungen.clear();

      final r = await a.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'Erika'}});

      expect(r['isError'], true);
      expect(warnungen, hasLength(1));
      expect(((r['content'] as List).single as Map)['text'], gesperrtText('Beispiel', 'beispiel_echo'));
    });

    test('Datenschutzwarnung: ohne Entscheidung bis zur Frist oder bei Abbruch des Clients wird gesperrt', () async {
      final eins = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([eins]));
      final freigaben = fragendeFreigaben(frist: const Duration(milliseconds: 300));
      final a = await verbinden(eins, l, freigaben: freigaben);
      await a.call('tools/call', {'name': 'beispiel_namen', 'arguments': <String, Object?>{}});
      warnungen.clear();
      warnantwort = () => null;

      final frist = await a.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'Erika'}});

      expect(frist['isError'], true);
      expect(((frist['content'] as List).single as Map)['text'], gesperrtText('Beispiel', 'beispiel_echo'));
      expect(freigaben.aktuell, isNull, reason: 'der Dialog hat sich geschlossen');
      expect(warnungen, hasLength(1));
      expect([for (final e in protokoll.eintraege) e.text], contains(contains('Frist abgelaufen')));
    });

    test('Datenschutzwarnung: Bricht der Client den Aufruf ab, verfällt die offene Frage: gesperrt, der Dialog schließt sich', () async {
      final eins = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([eins]));
      final freigaben = fragendeFreigaben();
      warnantwort = () => null;
      await verbinden(eins, l, freigaben: freigaben);
      final abbruch = Completer<void>();
      final warnung = Datenschutzwarnung(plugin: 'Beispiel', werkzeug: 'beispiel_echo', funde: const []);

      final aus = dienste.last.datenschutzwarnung(warnung: warnung, abbruch: abbruch.future, aufrufer: 'Plugin „Beispiel“');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(freigaben.aktuell?.datenschutz, same(warnung));
      abbruch.complete();

      expect(await aus, DatenschutzAusgang.sperren);
      expect(freigaben.aktuell, isNull);
      expect([for (final e in protokoll.eintraege) e.text], contains(contains('Die KI wartet nicht mehr')));
    });

    test('Datenschutzwarnung: Name und Pfad in einer Antwort sind eine Anfrage; sie fragt auch auf der Stufe „keine“', () async {
      final moodle = PluginTestMoodle();
      await moodle.starten();
      addTearDown(() => moodle.server.close(force: true));
      final (downloads, _) = PluginDownloads.einrichten(basis: p.join(wurzel.path, 'temp'));
      final eins = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([eins]), mit: LaufendePlugins(protokoll, downloads: downloads));
      final freigaben = fragendeFreigaben()..stufe = Bestaetigungen.keine;
      final a = await verbinden(eins, l, freigaben: freigaben);
      await a.call('tools/call', {'name': 'beispiel_namen', 'arguments': <String, Object?>{}});
      warnungen.clear();

      final r = await a.call('tools/call', {
        'name': 'beispiel_echo',
        'arguments': {'text': 'Erika liegt in ${downloads.wurzel}'},
      });

      expect(r['isError'], true);
      expect(warnungen, hasLength(1));
      expect(warnungen.single.anzahl, greaterThanOrEqualTo(2), reason: 'Name und Pfad zusammen');
      expect([warnungen.single.hatNamen, warnungen.single.hatPfade], [true, true]);
      expect(freigaben.ausgelassen, 0, reason: 'diese Freigabe lässt keine Stufe aus');
    });

    test('Datenschutzwarnung: Das Beispiel nennt einen Pfad; seine Protokollzeile wird zum Platzhalter, seine Antwort fragt, Sperren hält sie an', () async {
      final eins = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([eins]));
      final a = await verbinden(eins, l);

      final r = await a.call('tools/call', {'name': 'beispiel_pfade', 'arguments': <String, Object?>{}});

      expect(r['isError'], true);
      expect(((r['content'] as List).single as Map)['text'], gesperrtText('Beispiel', 'beispiel_pfade'));
      expect(jsonEncode(r), isNot(contains('Abgaben')));
      expect(warnungen, hasLength(1));
      expect([warnungen.single.hatPfade, warnungen.single.hatNamen], [true, false]);
      expect(warnungen.single.funde.single.herkunft, [Herkunft.pluginPfad]);
      expect(warnungen.single.funde.single.wort, '/home/e.mustermann/Klasse 9b/Abgaben');
      final zeilen = [for (final e in protokoll.eintraege) e.text];
      expect(zeilen, contains('Plugin „Beispiel“: 1 Pfad zum Sperren genannt'));
      expect(zeilen, contains('Plugin „Beispiel“: [gesperrt: Pfad]'));
      expect(zeilen, contains('Plugin „Beispiel“, Werkzeug beispiel_pfade: Datenschutzwarnung, 1 Treffer, gesperrt'));
      expect(zeilen.join('\n'), isNot(contains('Abgaben')));
    });

    test('Datenschutzwarnung: Name, Pfad des Plugins und Ordner für Downloads in einer Antwort sind eine Warnung; „trotzdem senden“ gilt nur für diese Antwort', () async {
      final (downloads, _) = PluginDownloads.einrichten(basis: p.join(wurzel.path, 'temp'));
      final eins = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([eins]), mit: LaufendePlugins(protokoll, downloads: downloads));
      final a = await verbinden(eins, l);
      await a.call('tools/call', {'name': 'beispiel_namen', 'arguments': <String, Object?>{}});
      await a.call('tools/call', {'name': 'beispiel_pfade', 'arguments': <String, Object?>{}});
      warnungen.clear();
      final text = 'Erika: /home/e.mustermann/Klasse 9b/Abgaben/x.pdf und ${downloads.wurzel}';

      final gesperrt = await a.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': text}});
      warnantwort = () => true;
      final gesendet = await a.tool('beispiel_echo', {'text': text});
      warnantwort = () => false;
      final wieder = await a.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': text}});

      expect(gesperrt['isError'], true);
      expect(gesendet, startsWith('Echo: $text'), reason: 'unverändert, erst nach ausdrücklichem Senden');
      expect(wieder['isError'], true, reason: 'nichts wird gemerkt');
      expect(warnungen, hasLength(3));
      final w = warnungen.first;
      expect([w.hatNamen, w.hatPfade], [true, true]);
      expect(w.funde.expand((f) => f.herkunft).toSet(), {
        Herkunft.pluginName,
        Herkunft.pluginPfad,
        Herkunft.downloadOrdner,
      });
    });

    test('es läuft einmal je App, auch mit zwei Profilen; jeder Aufruf trägt sein Profil', () async {
      final eins = beispielProfil('standard', 'moodle', await freierPort());
      final zwei = beispielProfil('k2', 'moodle-test', await freierPort());
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
      final eins = beispielProfil('standard', 'moodle', await freierPort());
      final zwei = beispielProfil('k2', 'moodle-test', await freierPort());
      final plugins = await beispielAngenommen([eins, zwei], aktiv: {'standard'});
      final l = await starten(plugins);

      final a = await verbinden(eins, l);
      final b = await verbinden(zwei, l);

      expect(await werkzeugnamen(a), contains('beispiel_echo'));
      expect(await werkzeugnamen(b), isNot(contains('beispiel_echo')));
    });

    test('ausschalten wirkt für Aufrufe sofort, in der Werkzeugliste ab der nächsten Sitzung', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
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
      final profil = beispielProfil('standard', 'moodle', await freierPort());
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
      final profil = beispielProfil('standard', 'moodle', await freierPort());
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
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      late Process prozess;
      final l = LaufendePlugins(
        protokoll,
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async =>
            prozess = await Process.start(programm, argumente, environment: umgebung, workingDirectory: arbeitsordner),
      );
      await starten(await beispielAngenommen([profil]), mit: l);
      expect(await prozessLaeuft(prozess.pid), isTrue);

      await l.beenden();

      expect(await prozessLaeuft(prozess.pid), isFalse);
      expect([for (final e in protokoll.eintraege) e.text], contains('Plugin „Beispiel“ 1.0.0 beendet'));
    });

    test('endet die App, während ein Plugin noch startet, bleibt auch dessen Prozess nicht zurück', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
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
          final prozess = await Process.start(dartDesSdk(), [warten.path]);
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

      expect(await prozessLaeuft(prozess.pid), isFalse);
      for (final k in kinder) {
        expect(await prozessLaeuft(k), isFalse, reason: 'Kindprozess $k');
      }
      expect(l.laeuft(plugins.eintraege.single), isFalse);
    });

    test('haben sich seine Dateien seit der Suche geändert, startet es nicht', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
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
      final profil = beispielProfil('standard', 'moodle', await freierPort());
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
          final prozess = await Process.start(dartDesSdk(), [warten.path]);
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
        expect(await prozessLaeuft(prozess.pid), isFalse);
      }
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(
        zeilen,
        contains(startsWith('Plugin „Beispiel“ nicht gestartet: Das Plugin hat nicht binnen 2 Sekunden')),
      );
      expect(zeilen, contains(startsWith('Plugin „Beispiel“ 1.0.0 ausgefallen: Das Plugin hat nicht binnen 2 Sekunden')));
    });

    test('antwortet es beim ersten Versuch nicht, startet der zweite; ein Absturz danach startet es neu', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final plugins = await beispielAngenommen([profil]);
      final warten = File(p.join(wurzel.path, 'warten.dart'))
        ..writeAsStringSync('Future<void> main() => Future<void>.delayed(const Duration(minutes: 5));\n');
      final prozesse = <Process>[];
      final l = LaufendePlugins(
        protokoll,
        startfrist: const Duration(seconds: 2),
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async {
          final prozess = prozesse.isEmpty
              ? await Process.start(dartDesSdk(), [warten.path])
              : await Process.start(programm, argumente, environment: umgebung, workingDirectory: arbeitsordner);
          prozesse.add(prozess);
          return prozess;
        },
      );

      await starten(plugins, mit: l);
      final e = plugins.eintraege.single;
      expect(l.laeuft(e), isTrue);
      expect(await prozessLaeuft(prozesse.first.pid), isFalse);
      final client = await verbinden(profil, l);
      expect(await client.tool('beispiel_echo', {'text': 'a'}), startsWith('Echo: a'));

      final r = await client.call('tools/call', {'name': 'beispiel_absturz', 'arguments': <String, Object?>{}});

      expect(r['isError'], true);
      expect(await client.tool('beispiel_echo', {'text': 'b'}), startsWith('Echo: b'));
      expect(prozesse, hasLength(3), reason: 'der zweite Startversuch zählt nicht als Neustart nach einem Absturz');
      expect(l.laeuft(e), isTrue);
      expect(l.ausgefalleneNamen, isEmpty);
    });
  });

  group('Absturz eines laufenden Plugins', () {
    /// Startet das Beispiel-Plugin mit einem Starter, der jeden Prozess
    /// sammelt, und verbindet einen Client über den MCP-Server des Profils.
    Future<({LaufendePlugins laufende, McpTestClient client, Plugins plugins, List<Process> prozesse, List<String> starts})>
    gestartet(Profil profil, {Duration neustartFrist = const Duration(minutes: 1)}) async {
      final prozesse = <Process>[];
      final starts = <String>[];
      final l = LaufendePlugins(
        protokoll,
        startfrist: const Duration(seconds: 10),
        neustartFrist: neustartFrist,
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

    // Der Aufruf, der beim Absturz lief: Er sagt, was geschehen ist, und nicht,
    // das Plugin sei ausgefallen -- moocp startet es ja gleich neu.
    void absturzMeldung(Map r) {
      expect(r['isError'], true);
      expect(text(r), contains('„Beispiel“'));
      expect(text(r), contains('unerwartet beendet'));
      expect(text(r), contains('nicht wiederholt'));
      expect(text(r), isNot(contains('ist ausgefallen')));
    }

    test('ein Absturz: der laufende Aufruf bekommt sofort den Fehler, ein Neustart mit neuem Port und Schlüssel, danach arbeitet es wieder', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final g = await gestartet(profil);

      final uhr = Stopwatch()..start();
      final r = await absturz(g.client);
      uhr.stop();

      absturzMeldung(r);
      expect(uhr.elapsed, lessThan(const Duration(seconds: 5)), reason: 'sofort, nicht erst nach einem Zeitlimit');
      // Ein neuer Aufruf wartet auf den Neustart und geht dann durch.
      expect(await g.client.tool('beispiel_echo', {'text': 'wieder'}), startsWith('Echo: wieder'));
      expect(g.laufende.laeuft(g.plugins.eintraege.single), isTrue);
      expect(g.laufende.ausgefalleneNamen, isEmpty);
      expect(g.starts, hasLength(2));
      expect(g.starts.toSet(), hasLength(2), reason: 'neuer Port und neuer Schlüssel');
      expect(g.starts[0].split(' ').first, isNot(g.starts[1].split(' ').first));
      expect(g.starts[0].split(' ').last, isNot(g.starts[1].split(' ').last));
      expect(await prozessLaeuft(g.prozesse.first.pid), isFalse);
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(zeilen, contains('Plugin „Beispiel“ 1.0.0 unerwartet beendet (Exit-Code 3)'));
      expect(zeilen, contains('Plugin „Beispiel“ 1.0.0 neu gestartet (18 Werkzeuge)'));
      for (final s in g.starts) {
        expect(zeilen.join('\n'), isNot(contains(s.split(' ').last)), reason: 'kein Schlüssel im Protokoll');
      }
    });

    test('während des Neustarts sagt der Dialog „Plugins“, dass es neu gestartet wird', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final weiter = Completer<void>();
      var n = 0;
      final l = LaufendePlugins(
        protokoll,
        startfrist: const Duration(seconds: 10),
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async {
          // Der Neustart wartet, bis der Test nachgesehen hat.
          if (n++ == 1) await weiter.future;
          return Process.start(programm, argumente, environment: umgebung, workingDirectory: arbeitsordner);
        },
      );
      final plugins = await beispielAngenommen([profil]);
      await starten(plugins, mit: l);
      final e = plugins.eintraege.single;
      final client = await verbinden(profil, l);
      expect(pluginLaufHinweis(l, e), isNull, reason: 'es läuft');

      absturzMeldung(await absturz(client));
      for (var i = 0; i < 50 && !l.startetNeu(e); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(l.startetNeu(e), isTrue);
      final hinweis = pluginLaufHinweis(l, e)!;
      expect(hinweis.text, contains('wird gerade neu gestartet'));
      expect(hinweis.text, isNot(contains('nächsten Start')));
      expect(hinweis.fehler, isFalse);
      weiter.complete();
      expect(await client.tool('beispiel_echo', {'text': 'x'}), startsWith('Echo: x'));
      expect(l.startetNeu(e), isFalse);
      expect(pluginLaufHinweis(l, e), isNull);
    });

    test('nach dem Neustart gilt an der Adresse der App nur der neue Schlüssel', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final g = await gestartet(profil);
      final adresse = g.laufende.appAdresse!;
      final alt = g.starts.single.split(' ').last;
      expect(await _protokollzeile(adresse, alt, 'vorher'), 200);

      absturzMeldung(await absturz(g.client));
      expect(await g.client.tool('beispiel_echo', {'text': 'wieder'}), startsWith('Echo: wieder'));

      final neu = g.starts.last.split(' ').last;
      expect(neu, isNot(alt));
      expect(await _protokollzeile(adresse, alt, 'mit altem Schlüssel'), 401);
      expect(await _protokollzeile(adresse, neu, 'mit neuem Schlüssel'), 200);
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(zeilen, isNot(contains('Plugin „Beispiel“: mit altem Schlüssel')));
      expect(zeilen, contains('Plugin „Beispiel“: mit neuem Schlüssel'));
    });

    test('stürzt es nach jedem Neustart erst nach der Frist wieder ab, startet es jedes Mal neu', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final g = await gestartet(profil, neustartFrist: Duration.zero);

      for (var i = 0; i < 3; i++) {
        absturzMeldung(await absturz(g.client));
      }

      expect(await g.client.tool('beispiel_echo', {'text': 'wieder'}), startsWith('Echo: wieder'));
      final e = g.plugins.eintraege.single;
      expect(g.laufende.laeuft(e), isTrue);
      expect(g.laufende.ausgefalleneNamen, isEmpty);
      expect(g.starts, hasLength(4), reason: 'der Start und drei Neustarts');
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(zeilen.where((z) => z == 'Plugin „Beispiel“ 1.0.0 neu gestartet (18 Werkzeuge)'), hasLength(3));
    });

    test('stürzt es binnen der Frist nach einem Neustart wieder ab: ausgefallen, jedes Werkzeug nennt das Plugin und bleibt gelistet', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final g = await gestartet(profil);

      absturzMeldung(await absturz(g.client));
      absturzMeldung(await absturz(g.client));

      final e = g.plugins.eintraege.single;
      expect(g.laufende.ausgefallen(e), isTrue);
      expect(g.laufende.ausgefalleneNamen, ['Beispiel']);
      expect(g.laufende.startfehler(e), contains('binnen einer Minute'));
      expect(g.starts, hasLength(2), reason: 'kein zweiter Neustart binnen der Frist');
      ausfallMeldung(await g.client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'x'}}));
      final neu = McpTestClient(profil.port);
      clients.add(neu);
      await neu.initialize();
      expect(await werkzeugnamen(neu), containsAll(['beispiel_echo', 'beispiel_absturz']));
      ausfallMeldung(await neu.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'x'}}));
      for (final prozess in g.prozesse) {
        expect(await prozessLaeuft(prozess.pid), isFalse);
      }
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(zeilen.where((z) => z == 'Plugin „Beispiel“ 1.0.0 unerwartet beendet (Exit-Code 3)'), hasLength(2));
      expect(zeilen, contains(startsWith('Plugin „Beispiel“ 1.0.0 ausgefallen: ')));
    });

    /// Startet das Beispiel-Plugin; der Starter gibt für die Starts, deren
    /// Nummer (ab 0) in [haengt] steht, ein Programm zurück, das läuft, aber
    /// nie lauscht.
    Future<({LaufendePlugins laufende, McpTestClient client, Plugins plugins, List<Process> prozesse})> mitHaenger(
      Profil profil,
      Set<int> haengt,
    ) async {
      final warten = File(p.join(wurzel.path, 'warten.dart'))
        ..writeAsStringSync('Future<void> main() => Future<void>.delayed(const Duration(minutes: 5));\n');
      final prozesse = <Process>[];
      final l = LaufendePlugins(
        protokoll,
        startfrist: const Duration(seconds: 2),
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async {
          final prozess = haengt.contains(prozesse.length)
              ? await Process.start(dartDesSdk(), [warten.path])
              : await Process.start(programm, argumente, environment: umgebung, workingDirectory: arbeitsordner);
          prozesse.add(prozess);
          return prozess;
        },
      );
      final plugins = await beispielAngenommen([profil]);
      await starten(plugins, mit: l);
      expect(l.laeuft(plugins.eintraege.single), isTrue);
      return (laufende: l, client: await verbinden(profil, l), plugins: plugins, prozesse: prozesse);
    }

    test('scheitert der Neustart nach einem Absturz, bekommt er einen zweiten Versuch', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      // Start 0 läuft, Start 1 (der Neustart) antwortet nicht, Start 2 läuft.
      final g = await mitHaenger(profil, {1});

      absturzMeldung(await absturz(g.client));

      expect(await g.client.tool('beispiel_echo', {'text': 'wieder'}), startsWith('Echo: wieder'));
      final e = g.plugins.eintraege.single;
      expect(g.laufende.laeuft(e), isTrue);
      expect(g.laufende.ausgefalleneNamen, isEmpty);
      expect(g.prozesse, hasLength(3));
      expect(await prozessLaeuft(g.prozesse[1].pid), isFalse, reason: 'der hängende Versuch ist beendet');
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(
        zeilen,
        contains(allOf(startsWith('Plugin „Beispiel“ nicht neu gestartet: '), endsWith('moocp versucht es noch einmal.'))),
      );
      expect(zeilen, contains('Plugin „Beispiel“ 1.0.0 neu gestartet (18 Werkzeuge)'));
    });

    test('scheitert auch der zweite Versuch des Neustarts, ist es ausgefallen', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final g = await mitHaenger(profil, {1, 2});

      absturzMeldung(await absturz(g.client));
      ausfallMeldung(await g.client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'x'}}));

      final e = g.plugins.eintraege.single;
      expect(g.prozesse, hasLength(3), reason: 'der Start und genau zwei Versuche des Neustarts');
      expect(g.laufende.ausgefallen(e), isTrue);
      expect(g.laufende.startfehler(e), contains('nicht binnen 2 Sekunden'));
      for (final prozess in g.prozesse) {
        expect(await prozessLaeuft(prozess.pid), isFalse);
      }
    });

    test('haben sich seine Dateien vor dem Neustart geändert, startet es nicht neu und ist ausgefallen', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final g = await gestartet(profil);
      final e = g.plugins.eintraege.single;
      File(p.join(e.pfad, 'neu.txt')).writeAsStringSync('dazugekommen');

      absturzMeldung(await absturz(g.client));
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
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final g = await gestartet(profil);
      final r = await g.client.call('tools/call', {'name': 'beispiel_namen', 'arguments': <String, Object?>{}});
      expect(r['isError'], true);

      absturzMeldung(await absturz(g.client));
      final danach = await g.client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'Erika'}});

      expect(g.starts, hasLength(2), reason: 'neu gestartet');
      expect(danach['isError'], true);
      expect(text(danach), gesperrtText('Beispiel', 'beispiel_echo'));
      expect(await g.client.tool('beispiel_echo', {'text': 'Hallo'}), startsWith('Echo: Hallo'));
    });

    test('nennt das Plugin nach einem Neustart eine Werkzeugliste mit einem Namen, läuft es weiter: Die Liste wird nicht geprüft', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
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
      final l = LaufendePlugins(
        protokoll,
        // Der Neustart übersetzt ein Skript samt mcp_dart in einer frischen
        // Dart-VM; unter Emulation (Windows auf ARM) dauert das 10 bis 25 s und
        // lag nahe an der Startfrist von 20 s und am Testlimit von 30 s.
        // Der Test prüft den Erfolgsweg, eine längere Frist verdeckt nichts.
        startfrist: const Duration(seconds: 90),
        starter: (programm, argumente, {required umgebung, required arbeitsordner}) async {
          final prozess = prozesse.isEmpty
              ? await Process.start(programm, argumente, environment: umgebung, workingDirectory: arbeitsordner)
              : await Process.start(dartDesSdk(), ['--packages=$pakete', skript.path, ...argumente], environment: umgebung);
          prozesse.add(prozess);
          return prozess;
        },
      );
      final plugins = await beispielAngenommen([profil]);
      await starten(plugins, mit: l);
      final client = await verbinden(profil, l);
      expect((await client.call('tools/call', {'name': 'beispiel_namen', 'arguments': <String, Object?>{}}))['isError'], true);

      absturzMeldung(await absturz(client));
      final danach = await client.call('tools/call', {'name': 'beispiel_echo', 'arguments': {'text': 'x'}});

      final e = plugins.eintraege.single;
      expect(prozesse, hasLength(2));
      expect(l.ausgefallen(e), isFalse);
      expect(text(danach), 'ok');
      final zeilen = [for (final z in protokoll.eintraege) z.text];
      expect(zeilen.where((z) => z.contains('Werkzeugliste gesperrt')), isEmpty);
      for (final prozess in prozesse) {
        expect(await prozessLaeuft(prozess.pid), prozess == prozesse.last);
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('das reguläre Beenden ist kein Absturz: kein Neustart, keine Anzeige', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
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
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      final client = await verbinden(profil, l);
      final vomServer = [
        for (final t in (await client.call('tools/list'))['tools'] as List)
          if ((t as Map)['name'] == 'beispiel_echo') t,
      ].single;
      expect(einstellungen.plugins['beispiel']!.werkzeuge!.map((w) => w.name), beispielWerkzeuge);

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
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      await l.beenden();
      final json = jsonDecode(jsonEncode(einstellungen.zuJson())) as Map<String, dynamic>;
      einstellungen = EinstellungenOhneDatei(profile: [profil])
        ..plugins = Einstellungen.aus(json, Einstellungen(schluessel: 'x')).plugins;

      final plugins = await Plugins.laden(einstellungen, protokoll, Directory(p.join(wurzel.path, 'plugins')));
      final neu = await starten(plugins);

      expect(neu.laeuft(plugins.eintraege.single), isTrue);
      expect(einstellungen.plugins['beispiel']!.werkzeuge!.map((w) => w.name), beispielWerkzeuge);
      expect(einstellungen.gespeichert, 0);
    });

    test('wird das Plugin ausgetauscht, fehlt seine Liste, bis es mit neuer Zustimmung gestartet ist', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
      final l = await starten(await beispielAngenommen([profil]));
      await l.beenden();
      File(p.join(wurzel.path, 'plugins', 'beispiel', 'plugin.json'))
          .writeAsStringSync(File(p.join(beispielOrdner, 'plugin.json')).readAsStringSync().replaceFirst('1.0.0', '1.0.1'));

      final plugins = await Plugins.laden(einstellungen, protokoll, Directory(p.join(wurzel.path, 'plugins')));
      final neu = await starten(plugins);

      expect(neu.laeuft(plugins.eintraege.single), isFalse, reason: 'ohne Zustimmung zu diesem Stand läuft nichts');
      expect(einstellungen.plugins['beispiel']!.werkzeuge, isNull);
    });
  });

  group('Werkzeugnamen eines Plugins', () {
    test('jeder Verstoß hält das Plugin vom Laden ab; der Grund nennt die Art, nie den Namen', () {
      void verstoss(List<String> namen, String grund, {Set<String> vergeben = const {}}) => expect(
        () => werkzeugnamenPruefen(namen, 'beispiel', vergeben),
        throwsA(
          isA<Object>()
              .having((e) => e.toString(), 'grund', contains(grund))
              .having((e) => e.toString().toLowerCase(), 'ohne Namen', isNot(contains('erika'))),
        ),
        reason: '$namen',
      );

      verstoss(['erika'], 'Ein Werkzeug beginnt nicht mit „beispiel_“');
      verstoss(['beispielerika'], 'beginnt nicht mit');
      verstoss(['beispiel_erika${'x' * 27}'], 'länger als 40 Zeichen');
      verstoss(['beispiel_ä_erika'], 'Zeichen im Namen');
      verstoss(['beispiel_erika b'], 'Zeichen im Namen');
      verstoss(['beispiel_erika.b'], 'Zeichen im Namen');
      verstoss(['beispiel_erika${String.fromCharCode(10)}'], 'Zeichen im Namen');
      verstoss(['beispiel_erika', 'beispiel_erika'], 'Zwei Werkzeuge tragen denselben Namen');
      verstoss(['beispiel_erika'], 'schon gibt', vergeben: {'beispiel_erika'});
      werkzeugnamenPruefen(['beispiel_echo', 'beispiel_a_b-c', 'beispiel_${'x' * 31}'], 'beispiel', {'status'});
    });

    test('mit langem Profilnamen über 64 Zeichen: Das Werkzeug fehlt nur in diesem Profil, einmal im Protokoll', () async {
      final kurz = beispielProfil('standard', 'moodle', await freierPort());
      // 40 Zeichen: mcp__ und __ dazu sind 47, beispiel_echo passt noch.
      final lang = beispielProfil('lang', 'moodle-${'x' * 33}', await freierPort());
      final plugins = await beispielAngenommen([kurz, lang]);
      final l = await starten(plugins);

      List<String> namen(Profil profil) => [for (final w in l.werkzeuge(profil)) w.name];
      expect(namen(kurz), beispielWerkzeuge);
      final imLangen = namen(lang);
      expect(imLangen, containsAll(['beispiel_echo', 'beispiel_hinweis']));
      expect(imLangen, isNot(contains('beispiel_moodle_schreiben')));
      for (final n in imLangen) {
        expect('mcp__${lang.mcpName}__$n'.length, lessThanOrEqualTo(64), reason: n);
      }
      final fehlen = beispielWerkzeuge.length - imLangen.length;
      expect(fehlen, greaterThan(0));
      // Noch einmal gefragt, etwa von einer zweiten Sitzung: keine zweite Zeile.
      namen(lang);
      final zeilen = [for (final z in protokoll.eintraege) if (z.text.contains('64 Zeichen')) z.text];
      expect(zeilen, [
        'Plugin „Beispiel“: $fehlen Werkzeuge fehlen im Profil „${lang.name}“ (${lang.mcpName}); mit '
            'mcp__${lang.mcpName}__ davor wären ihre Namen länger als 64 Zeichen.',
      ]);
      final hinweis = l.zuLangeWerkzeuge(plugins.eintraege.single, [kurz, lang]);
      expect(hinweis, hasLength(1));
      expect(hinweis.single, contains('„${lang.name}“'));
      expect(hinweis.single, contains('$fehlen Werkzeuge'));
    });

    test('ein Werkzeug außerhalb des Kurznamens bricht die Verbindung ab, ohne das Werkzeug zu nennen', () async {
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
        throwsA(
          isA<Object>()
              .having((e) => e.toString(), 'grund', contains('beginnt nicht mit „beispiel_“'))
              .having((e) => e.toString(), 'ohne Namen', isNot(contains('kurs_uebersicht'))),
        ),
      );
    });

    test('trägt ein Werkzeug einen vergebenen Namen, lädt das Plugin nicht, und sein Prozess endet', () async {
      final profil = beispielProfil('standard', 'moodle', await freierPort());
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
      expect(l.startfehler(plugins.eintraege.single), contains('schon gibt'));
      expect(l.startfehler(plugins.eintraege.single), isNot(contains('beispiel_echo')));
      expect(l.werkzeuge(profil), isEmpty);
      expect(await prozessLaeuft(prozess.pid), isFalse);
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
          profil: beispielProfil('standard', 'moodle', 1),
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
        profil: beispielProfil('standard', 'moodle', 1),
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
  final port = await freierPort();
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
