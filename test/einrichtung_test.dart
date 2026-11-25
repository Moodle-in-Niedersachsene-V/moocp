// Offline prüfbar: die Einrichtung der KI-Werkzeuge an einem nachgebauten
// Ordnerbaum -- Werkzeuge finden, die MCP-Einträge von Claude Code, Codex
// und LM Studio prüfen und schreiben, Skills vergleichen und installieren.
//
// Läuft auf Windows und auf dem Mac. Die Fälle mit Windows-Pfaden (C:\…,
// .exe, „;" im PATH) sind als Windows-Annahme markiert und übersprungen, wo
// die Plattform sie nicht erzeugt; der macOS-Zweig steht in
// test/macos_test.dart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einrichtung.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/plattform/signatur_windows.dart';
import 'package:path/path.dart' as p;

late Directory tmp;

/// Ein Ort, an dem die App die claude-Programmdatei findet: unter Windows die Ablage von
/// Claude Desktop, sonst `~/.local/bin` (dort sucht die App auf allen Plattformen).
final claudeOrt = Platform.isWindows
    ? 'lokal/Packages/Claude_pzs8sxrjxfjjc/LocalCache/Roaming/Claude/claude-code/2.1.9/claude.exe'
    : 'heim/.local/bin/claude';

File datei(String rel, [String inhalt = 'x']) {
  final f = File(p.joinAll([tmp.path, ...rel.split('/')]));
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(inhalt);
  return f;
}

List<int> zip(Map<String, String> dateien) {
  final a = Archive();
  dateien.forEach((name, inhalt) => a.addFile(ArchiveFile.bytes(name, utf8.encode(inhalt))));
  return ZipEncoder().encodeBytes(a);
}

void main() {
  // Die Dateien hier sind leer und unsigniert; die echte Signaturprüfung
  // (vonAnthropic) braucht eine echte claude.exe und wird von Hand geprüft.
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('einrichtung_test');
    claudeSigniert = (_) => true;
    // Kein Programm außerhalb des Testordners: unabhängig vom Bestand des Rechners.
    festeProgrammOrdner = const [];
    festeAppOrdner = const [];
    festeBruecke = datei('app/$brueckeExe').path;
  });
  tearDown(() {
    claudeSigniert = vonAnthropic;
    festeProgrammOrdner = null;
    festeAppOrdner = null;
    festeBruecke = null;
    tmp.deleteSync(recursive: true);
  });

  group('claude.exe finden', () {
    const desktop = 'lokal/Packages/Claude_pzs8sxrjxfjjc/LocalCache/Roaming/Claude/claude-code';
    const daten = 'lokal/Claude-Data/claude_pzs8sxrjxfjjc/claude-code';
    Map<String, String> lokal() => {'LOCALAPPDATA': p.join(tmp.path, 'lokal')};

    test('neue Ablage von Claude Desktop: Prüfsummenordner, höchste Version, vor der alten', () {
      datei('$desktop/2.1.400/claude.exe');
      datei('$daten/2.1.308/c17a819afb40/claude.exe');
      datei('$daten/2.1.309/9078b9c1d466/claude.exe');
      expect(claudeFinden(lokal()), p.joinAll([tmp.path, ...daten.split('/'), '2.1.309', '9078b9c1d466', 'claude.exe']));
    });

    test('zwei Prüfsummenordner derselben Version: der mit .verified gewinnt', () {
      datei('$daten/2.1.309/aaaa/claude.exe');
      datei('$daten/2.1.309/bbbb/claude.exe');
      datei('$daten/2.1.309/bbbb/.verified');
      expect(claudeFinden(lokal()), contains('bbbb'));
    });

    test('unsignierte exe an bekanntem Ort und im Suchpfad wird verworfen, die signierte genommen', () {
      claudeSigniert = (exe) => !exe.contains('unsigniert');
      datei('$daten/2.1.400/unsigniert/claude.exe');
      datei('$daten/2.1.309/gut/claude.exe');
      expect(claudeFinden(lokal()), contains(p.join('2.1.309', 'gut')));
      datei('unsigniert/claude.exe');
      final bericht = <String>[];
      expect(claudeFinden({'PATH': p.join(tmp.path, 'unsigniert')}, bericht: bericht), isNull);
      expect(bericht.join(), contains('keine Signatur von Anthropic'));
    });

    test('breite Suche: unbekannter Aufbau, nur signiert, Version aus dem Vorfahren', () {
      datei('lokal/Claude-Data/claude_anders/x/9.9.9/y/claude.exe');
      datei('lokal/Claude-Data/claude_anders/x/9.9.10/y/claude.exe');
      expect(claudeFinden(lokal()), contains('9.9.10'));
      claudeSigniert = (exe) => !exe.contains('9.9.10');
      expect(claudeFinden(lokal()), contains('9.9.9'));
      claudeSigniert = (_) => false;
      final bericht = <String>[];
      expect(claudeFinden(lokal(), bericht: bericht), isNull);
      expect(bericht.first, contains('Claude-Data'));
      expect(bericht.last, contains('9.9.10'));
    });

    test('andere Verteilung: anderer Paketname und andere Kennung werden gefunden', () {
      datei('lokal/Packages/AnthropicPBC.Claude_abc/LocalCache/Roaming/Claude/claude-code/2.2.0/claude.exe');
      expect(claudeFinden(lokal()), contains('AnthropicPBC.Claude_abc'));
      datei('lokal/Claude-Data/claude_abc/claude-code/2.3.0/h/claude.exe');
      expect(claudeFinden(lokal()), contains(p.join('claude_abc', 'claude-code', '2.3.0')));
    });

    test('breite Suche überspringt Sitzungsordner', () {
      datei('lokal/Claude-Data/claude_pzs8sxrjxfjjc/claude-code-sessions/1.0.0/claude.exe');
      expect(claudeFinden(lokal()), isNull);
    });

    test('Claude Desktop (MSIX): höchste Version, als Zahl verglichen', () {
      datei('$desktop/2.1.9/claude.exe');
      datei('$desktop/2.1.10/claude.exe');
      datei('$desktop/2.1.11/anderes.txt'); // Ordner ohne claude.exe zählt nicht
      datei('$desktop/neu/claude.exe'); // keine Versionsnummer
      // Ein anderes Paket mit höherer Version: Der bekannte Ort geht vor, die
      // breite Suche kommt erst, wenn dort nichts ist.
      datei('lokal/Packages/Claude_fremd/LocalCache/Roaming/Claude/claude-code/9.9.9/claude.exe');
      final gefunden = claudeFinden({'LOCALAPPDATA': p.join(tmp.path, 'lokal')});
      expect(gefunden, p.join(tmp.path, 'lokal', 'Packages', 'Claude_pzs8sxrjxfjjc', 'LocalCache', 'Roaming',
          'Claude', 'claude-code', '2.1.10', 'claude.exe'));
    }, skip: Platform.isWindows ? null : 'Windows-Annahme: claude.exe, MSIX, VS Code, Bionic gibt es nur unter Windows');

    test('Reihenfolge: Claude Desktop vor klassischem Installer vor VS Code', () {
      datei('roaming/Claude/claude-code/3.0.0/claude.exe');
      datei('heim/.vscode/extensions/anthropic.claude-code-2.1.282-win32-x64/resources/native-binary/claude.exe');
      final u = {
        'LOCALAPPDATA': p.join(tmp.path, 'lokal'),
        'APPDATA': p.join(tmp.path, 'roaming'),
        'USERPROFILE': p.join(tmp.path, 'heim'),
      };
      expect(claudeFinden(u), endsWith(p.join('3.0.0', 'claude.exe')));
      datei('$desktop/2.1.281/claude.exe');
      expect(claudeFinden(u), endsWith(p.join('2.1.281', 'claude.exe')));
    });

    test('VS-Code-Erweiterung und Suchpfad', () {
      datei('heim/.vscode/extensions/anthropic.claude-code-2.1.9-win32-x64/resources/native-binary/claude.exe');
      datei('heim/.vscode/extensions/anthropic.claude-code-2.1.10-win32-x64/resources/native-binary/claude.exe');
      expect(claudeFinden({'USERPROFILE': p.join(tmp.path, 'heim'), 'HOME': p.join(tmp.path, 'heim')}), contains('2.1.10'));
      datei('bin/claude.exe');
      expect(claudeFinden({'USERPROFILE': p.join(tmp.path, 'heim'), 'HOME': p.join(tmp.path, 'heim'), 'PATH': 'C:\\gibtsnicht;${p.join(tmp.path, 'bin')}'}),
          p.join(tmp.path, 'bin', 'claude.exe'));
    }, skip: Platform.isWindows ? null : 'Windows-Annahme: claude.exe, MSIX, VS Code, Bionic gibt es nur unter Windows');

    test('nichts da, leere Umgebung', () {
      expect(claudeFinden({'LOCALAPPDATA': p.join(tmp.path, 'lokal')}), isNull);
      expect(claudeFinden({}), isNull);
    });
  }, skip: Platform.isWindows ? null : 'Windows-Annahme: claude.exe, MSIX, VS Code, Bionic gibt es nur unter Windows');

  test('Versionen vergleichen', () {
    expect(versionVergleichen([2, 10], [2, 9]), greaterThan(0));
    expect(versionVergleichen([2, 1, 281], [2, 1, 280]), greaterThan(0));
    expect(versionVergleichen([2, 1], [2, 1, 0]), 0);
  });

  /// Der Eintrag, wie ihn die App schreibt: die Brücke als lokaler Befehl mit
  /// dem Profil als Argument, kein Port und kein Schlüssel.
  Map eintrag({String name = 'moodle', String? typ = 'stdio', Object? timeout = 'wie eingetragen', String? befehl}) => {
        'mcpServers': {
          name: {
            'type': ?typ,
            'command': befehl ?? festeBruecke,
            'args': ['--profil', name],
            'env': {},
            if (timeout != null) 'timeout': timeout == 'wie eingetragen' ? clientZeitlimit.inMilliseconds : timeout,
          },
        },
      };

  /// Ein Eintrag aus früheren Versionen: Adresse und Schlüssel.
  Map alterEintrag({String name = 'moodle'}) => {
        'mcpServers': {
          name: {
            'type': 'http',
            'url': 'http://127.0.0.1:47811/mcp',
            'headers': {'Authorization': 'Bearer alt'},
            'timeout': clientZeitlimit.inMilliseconds,
          },
        },
      };

  group('Claude Code: MCP-Eintrag', () {
    ClaudeCode claude() => ClaudeCode({'USERPROFILE': tmp.path, 'HOME': tmp.path});
    File konfig(Object inhalt) => datei('.claude.json', inhalt is String ? inhalt : jsonEncode(inhalt));

    test('aktuell, veraltet, fehlt, unlesbar', () {
      expect(claude().verbindung(), Verbindung.fehlt);
      konfig({'mcpServers': {}});
      expect(claude().verbindung(), Verbindung.fehlt);
      konfig(eintrag());
      expect(claude().verbindung(), Verbindung.aktuell);
      konfig(eintrag(name: 'moodle-test'));
      expect(claude().verbindung(name: 'moodle-test'), Verbindung.aktuell);
      expect(claude().verbindung(), Verbindung.fehlt, reason: 'der Eintrag eines anderen Profils ist nicht der dieses');
      konfig('{"mcpServers": {"moodle": ');
      expect(claude().verbindung(), Verbindung.unlesbar);
    });

    test('ein Eintrag mit Adresse und Schlüssel ist veraltet: Er schickte an einen Port, den jedes Konto belegen kann', () {
      konfig(alterEintrag());
      expect(claude().verbindung(), Verbindung.veraltet);
      final e = eintrag();
      (e['mcpServers']['moodle'] as Map)['url'] = 'http://127.0.0.1:47811/mcp';
      konfig(e);
      expect(claude().verbindung(), Verbindung.veraltet, reason: 'eine Adresse neben dem Befehl');
    });

    test('Profil als Argument, Brücke und Zeitlimit müssen stimmen', () {
      konfig(eintrag(befehl: p.join(tmp.path, 'weg', brueckeExe)));
      expect(claude().verbindung(), Verbindung.veraltet, reason: 'die Brücke gibt es dort nicht mehr');
      konfig(eintrag(befehl: datei('app/anderes').path));
      expect(claude().verbindung(), Verbindung.veraltet, reason: 'der Befehl ist nicht die Brücke');
      final e = eintrag();
      (e['mcpServers']['moodle'] as Map)['args'] = ['--profil', 'moodle-test'];
      konfig(e);
      expect(claude().verbindung(), Verbindung.veraltet, reason: 'das Profil der Brücke ist ein anderes');
      (e['mcpServers']['moodle'] as Map)['args'] = <String>[];
      konfig(e);
      expect(claude().verbindung(), Verbindung.veraltet);
      konfig(eintrag(typ: 'http'));
      expect(claude().verbindung(), Verbindung.veraltet);
    });

    test('ohne Zeitlimit veraltet: Claude Code bräche jede Freigabe nach 60 Sekunden ab', () {
      konfig(eintrag(timeout: null));
      expect(claude().verbindung(), Verbindung.veraltet);
      konfig(eintrag(timeout: 60000));
      expect(claude().verbindung(), Verbindung.veraltet);
    });

    test('der Eintrag geht als ein JSON-Argument an claude mcp add-json, ohne Adresse und Schlüssel', () {
      final a = claude().addArgumente();
      expect(a.sublist(0, a.length - 1), ['mcp', 'add-json', '--scope', 'user', 'moodle']);
      expect(jsonDecode(a.last), (eintrag()['mcpServers'] as Map)['moodle']);
      expect(a.last, isNot(contains('http')));
      expect(a.last, isNot(contains('Bearer')));
      final b = claude().addArgumente('moodle-test');
      expect(jsonDecode(b.last), (eintrag(name: 'moodle-test')['mcpServers'] as Map)['moodle-test']);
    });

    test('Umstellung: nur der eigene Eintrag wird ersetzt, die Konfiguration schreibt allein claude', () async {
      final heim = p.join(tmp.path, 'heim');
      datei(claudeOrt);
      final fremd = {'type': 'stdio', 'command': 'npx', 'args': ['-y', 'foo']};
      final alt = alterEintrag();
      (alt['mcpServers'] as Map)['anderer'] = fremd;
      final f = datei('heim/.claude.json', jsonEncode(alt));
      final vorher = f.readAsStringSync();
      final aufrufe = <List<String>>[];
      final c = ClaudeCode({'USERPROFILE': heim, 'HOME': heim})
        ..ausfuehren = (programm, argumente) async {
          aufrufe.add(argumente);
          return 0;
        };
      expect(c.verbindung(), Verbindung.veraltet);
      expect(await c.eintragen(), isNull);
      expect(aufrufe, [
        ['mcp', 'remove', 'moodle', '--scope', 'user'],
        c.addArgumente(),
      ], reason: 'nur der eigene Name, der Eintrag „anderer" wird nie angefasst');
      expect(f.readAsStringSync(), vorher, reason: 'die Datei gehört Claude Code; die App schreibt nicht hinein');
    });

    test('ohne Brücke neben der App: nichts eintragen, sondern es sagen', () async {
      final heim = p.join(tmp.path, 'heim');
      datei(claudeOrt);
      final aufrufe = <List<String>>[];
      final c = ClaudeCode({'USERPROFILE': heim, 'HOME': heim}, bruecke: p.join(tmp.path, 'weg', brueckeExe))
        ..ausfuehren = (_, a) async {
          aufrufe.add(a);
          return 0;
        };
      expect(await c.eintragen(), contains('$brueckeExe fehlt'));
      expect(aufrufe, isEmpty);
    });

    test('Zeitlimit: länger als die Frist einer Freigabe', () {
      expect(clientZeitlimit, greaterThan(Freigaben.fristVorgabe));
    });

    test('CLAUDE_CONFIG_DIR verlegt Einstellungen und Skills', () {
      final o = ClaudeCode({'USERPROFILE': 'C:\\Users\\x', 'HOME': 'C:\\Users\\x', 'CLAUDE_CONFIG_DIR': 'D:\\claude'});
      expect(o.konfiguration.path, p.join('D:\\claude', '.claude.json'));
      expect(o.skillOrdner.path, p.join('D:\\claude', 'skills'));
      final n = ClaudeCode({'USERPROFILE': 'C:\\Users\\x', 'HOME': 'C:\\Users\\x'});
      expect(n.konfiguration.path, p.join('C:\\Users\\x', '.claude.json'));
      expect(n.skillOrdner.path, p.join('C:\\Users\\x', '.claude', 'skills'));
    });
  });

  group('Codex CLI: der Block in config.toml', () {
    String bruecke() => festeBruecke!;
    String unser([String name = 'moodle']) =>
        "[mcp_servers.$name]\ncommand = '${bruecke()}'\nargs = ['--profil', '$name']\ntool_timeout_sec = 2100\n";
    const alterBlock =
        '[mcp_servers.moodle]\nurl = "http://127.0.0.1:47811/mcp"\nhttp_headers = { Authorization = "Bearer alt" }\ntool_timeout_sec = 2100\n';

    test('in eine leere oder fehlende Datei', () {
      expect(tomlBlockSetzen('', 'moodle', bruecke(), ['--profil', 'moodle']), unser());
      expect(tomlBlockSetzen('\n\n', 'moodle', bruecke(), ['--profil', 'moodle']), unser());
    });

    test('angehängt: alles andere bleibt Zeichen für Zeichen', () {
      const alt = 'model = "gpt-5"\n\n# mein Server\n[mcp_servers.github]\nurl = "https://example.com/mcp"\n';
      final neu = tomlBlockSetzen(alt, 'moodle', bruecke(), ['--profil', 'moodle']);
      expect(neu, '$alt\n${unser()}');
      expect(tomlBlockEntfernen(neu, 'moodle'), alt);
    });

    test('ein alter Block mit Adresse und Schlüssel wird ersetzt, auch samt Unterblock; Fremdes bleibt', () {
      const alt = 'model = "gpt-5"\n\n'
          '[mcp_servers.moodle]\nurl = "http://127.0.0.1:1/mcp"\n'
          '[mcp_servers.moodle.http_headers]\nAuthorization = "Bearer alt"\n\n'
          '# mein Server\n[mcp_servers.github]\nurl = "https://example.com/mcp"\ntoken = "x"\n';
      final neu = tomlBlockSetzen(alt, 'moodle', bruecke(), ['--profil', 'moodle']);
      expect(
          neu,
          'model = "gpt-5"\n\n${unser()}\n'
          '# mein Server\n[mcp_servers.github]\nurl = "https://example.com/mcp"\ntoken = "x"\n');
      expect(neu, isNot(contains('Bearer')));
      expect(tomlBlockEntfernen(neu, 'moodle'),
          'model = "gpt-5"\n\n# mein Server\n[mcp_servers.github]\nurl = "https://example.com/mcp"\ntoken = "x"\n');
    });

    test('ein Server mit ähnlichem Namen bleibt unberührt', () {
      const alt = '[mcp_servers.moodle2]\nurl = "x"\n';
      expect(tomlBlock(alt, 'moodle'), isNull);
      expect(tomlBlockSetzen(alt, 'moodle', bruecke(), ['--profil', 'moodle']), '$alt\n${unser()}');
      expect(tomlBlockEntfernen(alt, 'moodle'), alt);
    });

    test('Anführungszeichen im Kopf: [mcp_servers."moodle"]', () {
      expect(tomlBlock('[mcp_servers."moodle"]\nurl = "x"\n', 'moodle'), isNotNull);
    });

    test('CRLF bleibt CRLF', () {
      const alt = 'model = "gpt-5"\r\n';
      final neu = tomlBlockSetzen(alt, 'moodle', bruecke(), ['--profil', 'moodle']);
      expect(neu, 'model = "gpt-5"\r\n\r\n${unser().replaceAll('\n', '\r\n')}');
      expect(neu.replaceAll('\r\n', ''), isNot(contains('\n')));
      expect(tomlBlockEntfernen(neu, 'moodle'), alt);
    });

    test('ein Pfad mit Hochkomma oder Backslash wird richtig geschrieben und gelesen', () async {
      for (final name in ["o'brien", r'C:\Users\x y\moocp-bruecke.exe']) {
        final neu = tomlBlockSetzen('', 'moodle', name, ['--profil', 'moodle']);
        final block = tomlBlock(neu, 'moodle')!;
        expect(block, contains('command = '));
        // Schreiben und Lesen sind Gegenstücke: Die Verbindung erkennt den Befehl wieder.
        final dir = Directory(p.join(tmp.path, 'x'))..createSync();
        final bin = File(p.join(dir.path, brueckeExe))..writeAsStringSync('x');
        final codex = CodexCli({'USERPROFILE': tmp.path, 'HOME': tmp.path}, bruecke: bin.path);
        expect(await codex.eintragen(), isNull);
        expect(codex.verbindung(), Verbindung.aktuell);
        dir.deleteSync(recursive: true);
        codex.konfiguration.deleteSync();
      }
    });

    test('Block allein entfernt ergibt eine leere Datei', () {
      expect(tomlBlockEntfernen(unser(), 'moodle'), '');
    });

    test('Verbindung: fehlt, aktuell, veraltet, Adresse und Kopf, Profil, Zeitlimit', () async {
      final codex = CodexCli({'USERPROFILE': tmp.path, 'HOME': tmp.path});
      expect(codex.verbindung(), Verbindung.fehlt);
      expect(await codex.eintragen(), isNull);
      expect(codex.verbindung(), Verbindung.aktuell);
      expect(File(codex.konfiguration.path).readAsStringSync(), unser());

      codex.konfiguration.writeAsStringSync(alterBlock);
      expect(codex.verbindung(), Verbindung.veraltet, reason: 'Adresse und Schlüssel von früher');
      codex.konfiguration.writeAsStringSync('${unser()}url = "http://127.0.0.1:47811/mcp"\n');
      expect(codex.verbindung(), Verbindung.veraltet, reason: 'eine Adresse neben dem Befehl');
      codex.konfiguration.writeAsStringSync('${unser()}http_headers = { Authorization = "Bearer x" }\n');
      expect(codex.verbindung(), Verbindung.veraltet, reason: 'ein Kopf neben dem Befehl');

      codex.konfiguration.writeAsStringSync(unser().replaceAll("'--profil', 'moodle'", "'--profil', 'anderes'"));
      expect(codex.verbindung(), Verbindung.veraltet, reason: 'ein anderes Profil');
      codex.konfiguration.writeAsStringSync(unser().replaceAll('2100', '60'));
      expect(codex.verbindung(), Verbindung.veraltet, reason: 'Codex bräche jede Freigabe nach 60 Sekunden ab');
      codex.konfiguration.writeAsStringSync(unser().replaceAll('2100', '21000'));
      expect(codex.verbindung(), Verbindung.veraltet);
      codex.konfiguration.writeAsStringSync(unser().replaceAll('2100', '2100.0'));
      expect(codex.verbindung(), Verbindung.aktuell);
      codex.konfiguration.writeAsStringSync(unser().replaceAll(RegExp(r"command = '[^']*'"), "command = '${p.join(tmp.path, 'weg', brueckeExe)}'"));
      expect(codex.verbindung(), Verbindung.veraltet, reason: 'die Brücke gibt es dort nicht mehr');

      codex.konfiguration.writeAsStringSync('[mcp_servers.moodle]\ntoken_url = "http://x"\n');
      expect(codex.verbindung(), Verbindung.veraltet);

      expect(await codex.austragen(), isNull);
      expect(codex.verbindung(), Verbindung.fehlt);
    });

    test('Umstellung: nur der eigene Block ändert sich, Fremdes bleibt Zeichen für Zeichen', () async {
      final codex = CodexCli({'USERPROFILE': tmp.path, 'HOME': tmp.path});
      const vorn = 'model = "gpt-5"\n\n# mein Server\n[mcp_servers.github]\nurl = "https://example.com/mcp"\n\n';
      const hinten = '\n[mcp_servers.moodle2]\nurl = "x"\n\n[projects."/home/x"]\ntrust_level = "trusted"\n';
      codex.konfiguration
        ..createSync(recursive: true)
        ..writeAsStringSync('$vorn$alterBlock$hinten');
      expect(codex.verbindung(), Verbindung.veraltet);
      expect(await codex.eintragen(), isNull);
      expect(codex.konfiguration.readAsStringSync(), '$vorn${unser()}$hinten');
      expect(codex.verbindung(), Verbindung.aktuell);
    });

    test('je Profil ein eigener Block mit seinem Profil als Argument; der des Standardprofils bleibt', () async {
      final codex = CodexCli({'USERPROFILE': tmp.path, 'HOME': tmp.path});
      expect(await codex.eintragen(), isNull);
      expect(await codex.eintragen(name: 'moodle-test'), isNull);
      expect(codex.verbindung(), Verbindung.aktuell);
      expect(codex.verbindung(name: 'moodle-test'), Verbindung.aktuell);
      expect(codex.konfiguration.readAsStringSync(), '${unser()}\n${unser('moodle-test')}');
      expect(await codex.austragen(name: 'moodle-test'), isNull);
      expect(codex.konfiguration.readAsStringSync(), unser());
    });

    test('ohne Brücke neben der App: nichts eintragen, sondern es sagen', () async {
      final codex = CodexCli({'USERPROFILE': tmp.path, 'HOME': tmp.path}, bruecke: p.join(tmp.path, 'weg', brueckeExe));
      expect(await codex.eintragen(), contains('$brueckeExe fehlt'));
      expect(codex.konfiguration.existsSync(), isFalse);
    });

    test('CODEX_HOME verlegt Konfiguration und Skills', () {
      final c = CodexCli({'USERPROFILE': 'C:\\Users\\x', 'HOME': 'C:\\Users\\x', 'CODEX_HOME': 'D:\\codex'});
      expect(c.konfiguration.path, p.join('D:\\codex', 'config.toml'));
      expect(c.skillOrdner.path, p.join('D:\\codex', 'skills'));
      expect(CodexCli({'USERPROFILE': 'C:\\Users\\x', 'HOME': 'C:\\Users\\x'}).skillOrdner.path, p.join('C:\\Users\\x', '.codex', 'skills'));
    });
  });

  group('LM Studio (Bionic): die Brücke in Bionics Liste', () {
    late String exe;
    setUp(() => exe = datei('app/$brueckeExe').path);
    const pfad = '.lmstudio/apps/bionic/.internal/ng-mcp.json';
    File liste(List<Map<String, Object?>> server, {Map<String, Object?> mehr = const {}}) =>
        datei(pfad, jsonEncode({'servers': server, ...mehr}));
    final zeitlimit = clientZeitlimit.inMilliseconds;
    Map<String, Object?> server(String befehl, List<String> args,
            {String name = 'moodle', String id = 'x', Object? timeoutMs = 'wie eingetragen'}) =>
        {
          'id': id,
          'name': name,
          'enabled': true,
          'connection': {
            'type': 'stdio',
            'command': befehl,
            'args': args,
            'env': {},
            if (timeoutMs != null) 'timeoutMs': timeoutMs == 'wie eingetragen' ? zeitlimit : timeoutMs,
          },
        };
    List gelesen() => (jsonDecode(File(p.join(tmp.path, pfad)).readAsStringSync()) as Map)['servers'] as List;
    LmStudio lm() => LmStudio({'USERPROFILE': tmp.path, 'HOME': tmp.path}, bruecke: exe);

    test('fehlt, aktuell, veraltet, unlesbar', () {
      expect(lm().verbindung(), Verbindung.fehlt);
      liste([server('cmd', ['/c', 'uvx', 'blender-mcp'], name: 'blender')]);
      expect(lm().verbindung(), Verbindung.fehlt, reason: 'nur ein fremder Server');
      liste([server(exe, ['--profil', 'moodle'])]);
      expect(lm().verbindung(), Verbindung.aktuell);
      liste([server(datei('app/moocp.exe').path, ['--mcp-stdio'])]);
      expect(lm().verbindung(), Verbindung.veraltet, reason: 'die App selbst ist nicht die Brücke');
      liste([server('cmd', ['/c', 'npx', '-y', 'mcp-remote', 'http://127.0.0.1:47811/mcp'])]);
      expect(lm().verbindung(), Verbindung.veraltet, reason: 'moodle, aber nicht über die Brücke');
      liste([server(p.join(tmp.path, 'weg', brueckeExe), ['--profil', 'moodle'])]);
      expect(lm().verbindung(), Verbindung.veraltet, reason: 'die Brücke gibt es dort nicht mehr');
      liste([server(exe, [], timeoutMs: 'wie eingetragen')]);
      expect(lm().verbindung(), Verbindung.veraltet, reason: 'ohne das Profil als Argument');
      liste([server(exe, ['--profil', 'anderes'])]);
      expect(lm().verbindung(), Verbindung.veraltet, reason: 'das Profil der Brücke ist ein anderes');
      liste([server(exe, ['--profil', 'moodle'], timeoutMs: null)]);
      expect(lm().verbindung(), Verbindung.veraltet, reason: 'ohne Zeitlimit: Bionics 60 Sekunden');
      liste([server(exe, ['--profil', 'moodle'], timeoutMs: 120000)]);
      expect(lm().verbindung(), Verbindung.veraltet, reason: 'ein anderes Zeitlimit');
      datei(pfad, '{"servers": [');
      expect(lm().verbindung(), Verbindung.unlesbar);
    });

    test('eintragen: neue Liste, Brücke ohne Schlüssel, keine Zwischendatei übrig', () async {
      expect(await lm().eintragen(), isNull);
      expect(lm().verbindung(), Verbindung.aktuell);
      final e = gelesen().single as Map;
      expect(e['id'], matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(e['connection'], {
        'type': 'stdio',
        'command': exe,
        'args': ['--profil', 'moodle'],
        'env': {},
        'timeoutMs': zeitlimit,
      });
      expect(File(p.join(tmp.path, pfad)).readAsStringSync(), isNot(contains('Bearer')));
      expect(File(p.join(tmp.path, '$pfad.moocp')).existsSync(), isFalse);
    });

    test('eintragen: Fremdes bleibt, ein alter „moodle" wird ersetzt und behält seine id', () async {
      liste([
        server('cmd', ['/c', 'uvx', 'blender-mcp'], name: 'blender', id: 'b'),
        server('cmd', ['/c', 'npx', 'mcp-remote'], id: 'alt'),
      ], mehr: {'version': 3});
      expect(await lm().eintragen(), isNull);
      final s = gelesen();
      expect(s.map((e) => (e as Map)['name']), ['blender', 'moodle']);
      expect((s.last as Map)['id'], 'alt');
      expect((s.first as Map)['connection'], (jsonDecode(jsonEncode(server('cmd', ['/c', 'uvx', 'blender-mcp']))) as Map)['connection']);
      expect((jsonDecode(File(p.join(tmp.path, pfad)).readAsStringSync()) as Map)['version'], 3);
      expect(lm().verbindung(), Verbindung.aktuell);
    });

    test('je Profil ein Eintrag mit seinem Profil als Argument; der des Standardprofils bleibt', () async {
      expect(await lm().eintragen(), isNull);
      expect(await lm().eintragen(name: 'moodle-test'), isNull);
      final s = gelesen().cast<Map>();
      expect(s.map((e) => e['name']), ['moodle', 'moodle-test']);
      expect((s.last['connection'] as Map)['args'], ['--profil', 'moodle-test']);
      expect(lm().verbindung(), Verbindung.aktuell);
      expect(lm().verbindung(name: 'moodle-test'), Verbindung.aktuell);
      expect(await lm().austragen(name: 'moodle-test'), isNull);
      expect(gelesen().cast<Map>().map((e) => e['name']), ['moodle']);
    });

    test('ohne Brücke neben der App: nichts eintragen, sondern es sagen', () async {
      final ohne = LmStudio({'USERPROFILE': tmp.path, 'HOME': tmp.path}, bruecke: p.join(tmp.path, 'weg', brueckeExe));
      expect(await ohne.eintragen(), contains('moocp-bruecke.exe fehlt'));
      expect(File(p.join(tmp.path, pfad)).existsSync(), isFalse);
    });

    test('eine unlesbare Liste wird nicht überschrieben', () async {
      final f = datei(pfad, '{"servers": [');
      expect(await lm().eintragen(), contains('nicht angefasst'));
      expect(await lm().austragen(), contains('nicht angefasst'));
      expect(f.readAsStringSync(), '{"servers": [');
    });

    test('austragen: nur „moodle" geht, Fremdes bleibt', () async {
      expect(await lm().austragen(), isNull, reason: 'keine Liste, nichts zu tun');
      liste([server('cmd', ['/c', 'uvx', 'blender-mcp'], name: 'blender'), server(exe, ['--profil', 'moodle'])]);
      expect(await lm().austragen(), isNull);
      expect(gelesen().map((e) => (e as Map)['name']), ['blender']);
      expect(lm().verbindung(), Verbindung.fehlt);
    });
  });

  group('feste Programmordner: von außen vorgegeben', () {
    test('claude und codex werden nur in den vorgegebenen Ordnern gefunden', () {
      final heim = p.join(tmp.path, 'heim');
      final u = {'USERPROFILE': heim, 'HOME': heim, 'PATH': ''};
      final dir = p.join(tmp.path, 'prog');
      File(p.join(dir, 'claude')).createSync(recursive: true);
      File(p.join(dir, 'codex')).createSync(recursive: true);
      // Unter Windows suchen diese Ordner nur Codex und nur im Suchpfad; die Naht gilt für Mac und Linux.
      festeProgrammOrdner = [dir];
      expect(claudeFinden(u), p.join(dir, 'claude'));
      expect(CodexCli(u).exe, p.join(dir, 'codex'));
      festeProgrammOrdner = [p.join(tmp.path, 'leer')];
      expect(claudeFinden(u), isNull);
      expect(CodexCli(u).exe, isNull);
    }, skip: Platform.isWindows ? 'Die festen Programmordner gibt es nur auf Mac und Linux' : null);
  });

  group('Codex in der ChatGPT-App', () {
    late String heim;
    late Map<String, String> u;
    setUp(() {
      heim = p.join(tmp.path, 'heim');
      u = {'USERPROFILE': heim, 'HOME': heim, 'PATH': ''};
      festeAppOrdner = [p.join(tmp.path, 'Applications'), p.join(heim, 'Applications')];
    });
    tearDown(() => festeAppOrdner = null);
    void app(String ort, {bool codex = true}) {
      if (codex) {
        datei('$ort/ChatGPT.app/Contents/Resources/codex-cli/bin/codex');
      } else {
        datei('$ort/ChatGPT.app/Contents/MacOS/ChatGPT');
      }
    }

    test('App mit codex-cli ohne ~/.codex: gefunden, mit Hinweis, nichts angelegt', () {
      app('Applications');
      final c = CodexCli(u);
      expect(c.gefunden, isTrue);
      expect(c.hinweis, contains('einmal'));
      expect(c.exe, isNull);
      expect(Directory(p.join(heim, '.codex')).existsSync(), isFalse);
    });

    test('App im Benutzerordner ~/Applications wird auch gefunden', () {
      app('heim/Applications');
      expect(CodexCli(u).gefunden, isTrue);
    });

    test('App und ~/.codex: gefunden, kein Hinweis', () {
      app('Applications');
      Directory(p.join(heim, '.codex')).createSync(recursive: true);
      final c = CodexCli(u);
      expect(c.gefunden, isTrue);
      expect(c.hinweis, isNull);
    });

    test('nur die CLI: wie bisher, kein Hinweis', () {
      datei('bin/codex');
      final c = CodexCli({...u, 'PATH': p.join(tmp.path, 'bin')});
      expect(c.gefunden, isTrue);
      expect(c.hinweis, isNull);
    }, skip: Platform.isWindows ? 'Windows sucht codex.exe, .cmd und .bat' : null);

    test('ChatGPT Classic ohne codex-cli: nicht gefunden', () {
      app('Applications', codex: false);
      final c = CodexCli(u);
      expect(c.gefunden, isFalse);
      expect(c.hinweis, isNull);
    });

    test('Name nennt App und CLI', () {
      expect(CodexCli(u).name, 'Codex (ChatGPT-App oder CLI)');
    });
  });

  group('gefunden', () {
    test('an Konfigurationsordnern oder Programmen', () {
      final u = {'USERPROFILE': p.join(tmp.path, 'heim'), 'HOME': p.join(tmp.path, 'heim'), 'LOCALAPPDATA': p.join(tmp.path, 'lokal')};
      expect(gefundeneWerkzeuge(u), isEmpty);
      Directory(p.join(tmp.path, 'heim', '.codex')).createSync(recursive: true);
      expect(gefundeneWerkzeuge(u).map((w) => w.id), ['codex']);
      Directory(p.join(tmp.path, 'heim', '.lmstudio')).createSync(recursive: true);
      expect(gefundeneWerkzeuge(u).map((w) => w.id), ['codex'], reason: 'LM Studio, aber Bionic lief nie');
      Directory(p.join(tmp.path, 'heim', '.lmstudio', 'apps', 'bionic')).createSync(recursive: true);
      datei('heim/.claude.json', '{}');
      // LM Studio mit Bionic gibt es nur unter Windows (E24).
      expect(gefundeneWerkzeuge(u).map((w) => w.id), ['claude', 'codex', if (Platform.isWindows) 'lmstudio']);
    });

    test('Codex auch nur über npm', () {
      datei('roaming/npm/codex.cmd');
      expect(CodexCli({'USERPROFILE': p.join(tmp.path, 'heim'), 'HOME': p.join(tmp.path, 'heim'), 'APPDATA': p.join(tmp.path, 'roaming')}).gefunden,
          isTrue);
    }, skip: Platform.isWindows ? null : 'Windows-Annahme: codex.cmd unter %APPDATA%\\npm');
  });

  group('Skills', () {
    final paket = SkillPaket.ausZip(
        'moodle',
        zip({
          'moodle/SKILL.md': 'Skill',
          'moodle/references/lesen.md': 'Lesen',
          'anderes/SKILL.md': 'gehört nicht dazu',
        }),
        herkunft: SkillHerkunft.app);

    test('Paket liest nur den eigenen Ordner', () {
      expect(paket.dateien.keys, unorderedEquals(['SKILL.md', 'references/lesen.md']));
    });

    test('Pakete der App: nur *.skill unter dem Asset-Pfad, Name aus dem Dateinamen, Herkunft App', () async {
      final assets = {
        '${skillAssets}moodle.skill': zip({'moodle/SKILL.md': 'Kurs'}),
        '${skillAssets}lernsituation.skill':
            zip({'lernsituation/SKILL.md': 'Lernsituation', 'lernsituation/references/a.md': 'A'}),
        '${skillAssets}notizen.txt': const [1, 2, 3],
        'LICENSE.md': const [4, 5, 6],
        'anderswo/dist/fremd.skill': zip({'fremd/SKILL.md': 'Fremd'}),
      };
      final geladen = <String>[];
      final pakete = await skillPaketeFinden(
          appAssets: assets.keys,
          laden: (a) async {
            geladen.add(a);
            return assets[a]!;
          });
      expect(pakete.map((x) => x.name), unorderedEquals(['moodle', 'lernsituation']));
      expect(pakete.every((x) => x.herkunft == SkillHerkunft.app), isTrue);
      expect(pakete.firstWhere((x) => x.name == 'lernsituation').dateien.keys,
          unorderedEquals(['SKILL.md', 'references/a.md']));
      expect(geladen, unorderedEquals(['${skillAssets}moodle.skill', '${skillAssets}lernsituation.skill']),
          reason: 'was kein Paket ist, wird nicht einmal geladen');
    });

    test('ohne Pakete: leere Liste', () async {
      expect(await skillPaketeFinden(appAssets: const ['LICENSE.md'], laden: (_) async => const []), isEmpty);
    });

    test('vergleichen, installieren, Verwaistes entfernen', () {
      final ziel = Directory(p.join(tmp.path, 'skills', 'moodle'));
      expect(skillVergleichen(paket, ziel).text, 'nicht installiert');

      expect(skillInstallieren(paket, ziel), isEmpty);
      expect(skillVergleichen(paket, ziel).aktuell, isTrue);
      expect(File(p.join(ziel.path, 'references', 'lesen.md')).readAsStringSync(), 'Lesen');

      // Handänderung, überzählige Datei, fehlende Datei
      File(p.join(ziel.path, 'SKILL.md')).writeAsStringSync('von Hand geändert');
      datei('skills/moodle/scripts/page-helpers.js');
      File(p.join(ziel.path, 'references', 'lesen.md')).deleteSync();
      final s = skillVergleichen(paket, ziel);
      expect((s.abweichend, s.ueberzaehlig, s.fehlend), (1, 1, 1));
      expect(s.text, 'muss aktualisiert werden');

      expect(skillInstallieren(paket, ziel), isEmpty);
      expect(skillVergleichen(paket, ziel).aktuell, isTrue);
      expect(Directory(p.join(ziel.path, 'scripts')).existsSync(), isFalse, reason: 'leer gewordener Ordner');
    });
  });

  group('Einrichtungsstand', () {
    final paket = SkillPaket('moodle', {'SKILL.md': utf8.encode('Skill')}, herkunft: SkillHerkunft.app);
    late String heim;
    late Map<String, String> u;
    setUp(() {
      heim = p.join(tmp.path, 'heim');
      u = {'USERPROFILE': heim, 'HOME': heim, 'LOCALAPPDATA': p.join(tmp.path, 'lokal')};
    });
    void claudeEintrag() => datei('heim/.claude.json', jsonEncode(eintrag()));
    Directory skills(String werkzeug, String name) => Directory(p.join(heim, werkzeug, 'skills', name));
    Future<Einrichtungsstand> pruefen({Set<String> abgewaehlt = const {}}) => einrichtungPruefen(
        umgebung: u,
        skills: [paket],
        wahlSkills: appWahlSkills,
        abgewaehlt: abgewaehlt);

    test('Dialog nur, wenn etwas zu tun ist', () async {
      claudeEintrag();
      final claudeDatei = datei(claudeOrt);
      var s = await pruefen();
      expect(s.brauchtEtwas, isTrue, reason: 'Skill fehlt');
      skillInstallieren(paket, skills('.claude', 'moodle'));
      s = await pruefen();
      expect(s.brauchtEtwas, isFalse);
      expect(s.bereit, isTrue);

      claudeDatei.deleteSync();
      s = await pruefen();
      expect((s.werkzeuge.single.werkzeug as ClaudeCode).exe, isNull);
      expect(s.brauchtEtwas, isFalse, reason: 'Eintrag stimmt schon, claude.exe braucht es nur zum Eintragen');
    });

    test('Ohne claude.exe einrichtbar sind nur die Skills', () async {
      datei('heim/.claude/skills/fremd/SKILL.md'); // Claude Code wird benutzt
      var s = await pruefen();
      expect(s.werkzeuge.single.verbindung, Verbindung.fehlt);
      expect(s.einrichtbar, isTrue, reason: 'die Skills gehen auch ohne claude.exe');
      expect(s.werkzeuge.single.werkzeug.hindernis, isNotNull);
      skillInstallieren(paket, skills('.claude', 'moodle'));
      s = await pruefen();
      expect(s.einrichtbar, isFalse, reason: 'nur noch die Verbindung, und die braucht claude.exe');
      skillEntfernen(skills('.claude', 'moodle'));

      claudeEintrag();
      s = await pruefen();
      expect(s.brauchtEtwas, isTrue, reason: 'Skill fehlt');
      expect(s.einrichtbar, isTrue, reason: 'Skills gehen ohne claude.exe');
    });

    test('kein Werkzeug gefunden: nicht bereit, nichts einzurichten', () async {
      final s = await pruefen();
      expect(s.werkzeuge, isEmpty);
      expect(s.bereit, isFalse);
      expect(s.brauchtEtwas, isTrue, reason: 'ohne Werkzeug läuft die App nicht');
      expect(s.einrichtbar, isFalse);
    });

    test('eines eingerichtet reicht zum Laufen; ein neues Werkzeug wird trotzdem angeboten', () async {
      claudeEintrag();
      skillInstallieren(paket, skills('.claude', 'moodle'));
      Directory(p.join(heim, '.codex')).createSync(recursive: true);
      var s = await pruefen();
      expect(s.werkzeuge.map((w) => w.werkzeug.id), ['claude', 'codex']);
      expect(s.bereit, isTrue);
      expect(s.brauchtEtwas, isTrue, reason: 'Codex ist gewählt und noch nicht eingerichtet');
      expect(s.einrichtbar, isTrue);

      // Abgewählt und nichts von uns darin: nichts zu tun.
      s = await pruefen(abgewaehlt: {'codex'});
      expect(s.brauchtEtwas, isFalse);

      // Eingerichtet: auch nichts.
      final codex = s.werkzeuge.last.werkzeug;
      expect(await codex.eintragen(), isNull);
      skillInstallieren(paket, skills('.codex', 'moodle'));
      s = await pruefen();
      expect(s.werkzeuge.every((w) => w.fertig), isTrue);
      expect(s.brauchtEtwas, isFalse);
    });

    test('ein abgewähltes Werkzeug wird geräumt: Eintrag und alle Skills', () async {
      claudeEintrag();
      skillInstallieren(paket, skills('.claude', 'moodle'));
      final codex = CodexCli(u);
      expect(await codex.eintragen(), isNull);
      skillInstallieren(paket, skills('.codex', 'moodle'));

      var s = await pruefen(abgewaehlt: {'codex'});
      final w = s.werkzeuge.firstWhere((x) => x.werkzeug.id == 'codex');
      expect(w.gewaehlt, isFalse);
      expect(w.entfernen, {'moodle'});
      expect(w.brauchtEtwas, isTrue);
      expect(s.bereit, isTrue, reason: 'Claude ist eingerichtet');

      expect(await codex.austragen(), isNull);
      skillEntfernen(skills('.codex', 'moodle'));
      s = await pruefen(abgewaehlt: {'codex'});
      expect(s.brauchtEtwas, isFalse);
    });

    test('LM Studio abgewählt: Eintrag und Skills werden geräumt', () async {
      claudeEintrag();
      skillInstallieren(paket, skills('.claude', 'moodle'));
      final exe = datei('app/$brueckeExe').path;
      datei('heim/.lmstudio/apps/bionic/.internal/ng-mcp.json', jsonEncode({
        'servers': [
          {
            'name': 'moodle',
            'connection': {
              'type': 'stdio',
              'command': exe,
              'args': [],
              'timeoutMs': clientZeitlimit.inMilliseconds,
            },
          },
        ],
      }));
      skillInstallieren(paket, skills('.lmstudio', 'moodle'));

      var s = await pruefen(abgewaehlt: {'lmstudio'});
      var w = s.werkzeuge.firstWhere((x) => x.werkzeug.id == 'lmstudio');
      expect(w.verbindung, Verbindung.aktuell);
      expect((w.brauchtEtwas, w.machbar), (true, true));
      skillEntfernen(skills('.lmstudio', 'moodle'));
      expect(await w.werkzeug.austragen(), isNull);
      s = await pruefen(abgewaehlt: {'lmstudio'});
      w = s.werkzeuge.firstWhere((x) => x.werkzeug.id == 'lmstudio');
      expect(w.brauchtEtwas, isFalse);
      expect(s.brauchtEtwas, isFalse);
    }, skip: Platform.isWindows ? null : 'LM Studio mit Bionic gibt es nur unter Windows (E24)');

    test('alles abgewählt: nicht bereit, auch wenn alles stimmt', () async {
      claudeEintrag();
      skillInstallieren(paket, skills('.claude', 'moodle'));
      final s = await pruefen(abgewaehlt: {'claude'});
      expect(s.bereit, isFalse);
      expect(s.brauchtEtwas, isTrue);
    });
  });

  test('Wählbare Skills: nur gewählt installiert, abgewählt entfernt, Vorgabe aus dem Bestand', () async {
    final heim = p.join(tmp.path, 'heim');
    datei('heim/.claude.json', jsonEncode(eintrag()));
    final u = {'USERPROFILE': heim, 'HOME': heim};
    final claude = ClaudeCode(u);
    final moodle = SkillPaket('moodle', {'SKILL.md': utf8.encode('Kurs')}, herkunft: SkillHerkunft.app);
    final ls = SkillPaket('lernsituation', {'SKILL.md': utf8.encode('Lernsituation')}, herkunft: SkillHerkunft.app);
    Directory ziel(String n) => Directory(p.join(claude.skillOrdner.path, n));
    Future<Einrichtungsstand> pruefen(Set<String> gewaehlt) => einrichtungPruefen(
        umgebung: u,
        skills: [moodle, ls],
        wahlSkills: appWahlSkills,
        gewaehlt: gewaehlt);
    Set<String> entfernen(Einrichtungsstand s) => s.werkzeuge.single.entfernen;

    // Neu angefangen: nichts gewählt, lernsituation gehört nicht dazu.
    expect(gewaehltVorgabe(u, appWahlSkills.keys), isEmpty);
    skillInstallieren(moodle, ziel('moodle'));
    var s = await pruefen(gewaehltVorgabe(u, appWahlSkills.keys));
    expect(s.gewollt.map((x) => x.name), ['moodle']);
    expect(s.brauchtEtwas, isFalse, reason: 'nicht gewählt und nicht installiert: nichts zu tun');

    // Gewählt, aber nicht installiert.
    s = await pruefen({'lernsituation'});
    expect(s.brauchtEtwas, isTrue);
    skillInstallieren(ls, ziel('lernsituation'));
    expect((await pruefen({'lernsituation'})).brauchtEtwas, isFalse);

    // Wer ihn schon hat und noch nichts gewählt hat, behält ihn.
    expect(gewaehltVorgabe(u, appWahlSkills.keys), {'lernsituation'});

    // Abgewählt: installiert, also entfernen.
    s = await pruefen({});
    expect(entfernen(s), {'lernsituation'});
    expect(s.brauchtEtwas, isTrue);
    expect(skillEntfernen(ziel('lernsituation')), isEmpty);
    s = await pruefen({});
    expect(entfernen(s), isEmpty);
    expect(s.brauchtEtwas, isFalse);
    expect(ziel('lernsituation').existsSync(), isFalse);
  });

  test('Die wählbaren Skills der App: nur lernsituation, mit dem Satz aus dem Dialog', () {
    expect(appWahlSkills, {
      'lernsituation': 'Für berufsbildende Schulen: Lernsituationen mit SchuCu-Tabelle, Ablaufplan, Arbeits- '
          'und Informationsblättern entwerfen.',
    });
  });

  group('Wählbare Skills sind Daten der Einrichtung', () {
    // lernsituation ist hier nicht wählbar, zusatz schon: Was wählbar ist, steht nicht in der Einrichtung.
    final fest = SkillPaket('lernsituation', {'SKILL.md': utf8.encode('Lernsituation')}, herkunft: SkillHerkunft.app);
    final zusatz = SkillPaket('zusatz', {'SKILL.md': utf8.encode('Zusatz')}, herkunft: SkillHerkunft.app);
    const wahl = {'zusatz': 'Ein Zusatz, der nicht jeder braucht.'};
    late Map<String, String> u;
    late CodexCli codex;
    setUp(() {
      final heim = p.join(tmp.path, 'heim');
      u = {'USERPROFILE': heim, 'HOME': heim};
      codex = CodexCli(u);
    });

    test('gewollt ist alles außer dem Wählbaren, das nicht gewählt ist; Abgewähltes wird entfernt', () async {
      Future<Einrichtungsstand> pruefen(Set<String> gewaehlt) => einrichtungPruefen(
          umgebung: u,
            skills: [fest, zusatz],
          wahlSkills: wahl,
          gewaehlt: gewaehlt,
          gefunden: [codex]);

      var s = await pruefen({});
      expect(s.wahlSkills, wahl);
      expect(s.gewollt.map((x) => x.name), ['lernsituation']);
      expect(s.werkzeuge.single.skills.map((x) => x.name), ['lernsituation']);

      s = await pruefen({'zusatz'});
      expect(s.gewollt.map((x) => x.name), ['lernsituation', 'zusatz']);
      expect(s.werkzeuge.single.skills.map((x) => x.name), ['lernsituation', 'zusatz']);

      skillInstallieren(zusatz, Directory(p.join(codex.skillOrdner.path, 'zusatz')));
      s = await pruefen({});
      expect(s.werkzeuge.single.entfernen, {'zusatz'});
    });

    test('die Vorgabe wählt, was wählbar und schon installiert ist', () {
      skillInstallieren(zusatz, Directory(p.join(codex.skillOrdner.path, 'zusatz')));
      skillInstallieren(fest, Directory(p.join(codex.skillOrdner.path, 'lernsituation')));
      expect(gewaehltVorgabe(u, wahl.keys), {'zusatz'});
      expect(gewaehltVorgabe(u, const []), isEmpty);
    });
  });

  group('Entfernen beim Deinstallieren', () {
    const fremd = {'type': 'http', 'url': 'http://127.0.0.1:2/mcp'};
    late Map<String, String> umgebung;
    late File konfig;
    setUp(() {
      umgebung = {
        'CLAUDE_CONFIG_DIR': p.join(tmp.path, 'cfg'),
        'LOCALAPPDATA': p.join(tmp.path, 'lokal'),
        'USERPROFILE': p.join(tmp.path, 'heim'),
        'HOME': p.join(tmp.path, 'heim'),
      };
      konfig = datei(
          'cfg/.claude.json',
          jsonEncode({
            'mcpServers': {
              'moodle': {'type': 'http', 'url': 'http://127.0.0.1:1/mcp'},
              'anderer': fremd,
            },
          }));
      datei('cfg/skills/moodle/SKILL.md');
      datei('cfg/skills/moodle/references/a.md');
      datei('cfg/skills/lernsituation/SKILL.md');
      datei('cfg/skills/fremd/SKILL.md');
    });

    // Tut, was `claude mcp remove moodle` tut, und merkt sich den Aufruf.
    final aufrufe = <List<String>>[];
    Future<int> claudeAttrappe(String programm, List<String> argumente) async {
      aufrufe.add([programm, ...argumente]);
      konfig.writeAsStringSync(jsonEncode({
        'mcpServers': {'anderer': fremd},
      }));
      return 0;
    }

    setUp(aufrufe.clear);

    List<KiWerkzeug> werkzeuge({Future<int> Function(String, List<String>)? ausfuehren}) =>
        [ClaudeCode(umgebung)..ausfuehren = ausfuehren ?? claudeAttrappe, CodexCli(umgebung), LmStudio(umgebung)];

    test('Eintrag über claude.exe, Skills der App gelöscht, fremde bleiben', () async {
      final exe = datei(claudeOrt).path;
      final e = await einrichtungEntfernen(umgebung: umgebung, skills: ['moodle', 'lernsituation'], werkzeuge: werkzeuge());
      expect(aufrufe, [
        [exe, 'mcp', 'remove', 'moodle', '--scope', 'user'],
      ]);
      expect(e.code, 0);
      expect(Directory(p.join(tmp.path, 'cfg/skills/moodle')).existsSync(), isFalse);
      expect(Directory(p.join(tmp.path, 'cfg/skills/lernsituation')).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'cfg/skills/fremd/SKILL.md')).existsSync(), isTrue);
    });

    test('ohne claude.exe: Eintrag bleibt und wird gemeldet, Skills trotzdem weg', () async {
      final e = await einrichtungEntfernen(umgebung: umgebung, skills: ['moodle'], werkzeuge: werkzeuge());
      expect(aufrufe, isEmpty);
      expect(e.eintragBleibt, ['claude']);
      expect(e.code, 1);
      expect(Directory(p.join(tmp.path, 'cfg/skills/moodle')).existsSync(), isFalse);
    });

    test('Exit-Code 0 von claude.exe zählt nicht, nur der Eintrag danach', () async {
      datei(claudeOrt);
      final e = await einrichtungEntfernen(
          umgebung: umgebung, skills: const [], werkzeuge: werkzeuge(ausfuehren: (_, _) async => 0));
      expect(e.code, 1);
    });

    test('ohne Eintrag wird claude.exe gar nicht gesucht', () async {
      konfig.writeAsStringSync(jsonEncode({'mcpServers': {}}));
      final e = await einrichtungEntfernen(umgebung: umgebung, skills: ['nicht-da'], werkzeuge: werkzeuge());
      expect(aufrufe, isEmpty);
      expect(e.code, 0);
    });

    test('entfernt jeden gefundenen Skill: Die Namen kommen aus derselben Entdeckung wie die der Einrichtung', () async {
      konfig.writeAsStringSync(jsonEncode({'mcpServers': {}}));
      final pakete = await skillPaketeFinden(
          appAssets: ['${skillAssets}moodle.skill', '${skillAssets}lernsituation.skill', 'LICENSE.md'],
          laden: (a) async => zip({'${p.basenameWithoutExtension(a)}/SKILL.md': 'x'}));
      final e = await einrichtungEntfernen(
          umgebung: umgebung, skills: [for (final s in pakete) s.name], werkzeuge: werkzeuge());
      expect(e.code, 0);
      expect(Directory(p.join(tmp.path, 'cfg/skills/moodle')).existsSync(), isFalse);
      expect(Directory(p.join(tmp.path, 'cfg/skills/lernsituation')).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'cfg/skills/fremd/SKILL.md')).existsSync(), isTrue);
    });

    test('Codex und LM Studio: Einträge und Skills weg, Fremdes bleibt', () async {
      konfig.writeAsStringSync(jsonEncode({'mcpServers': {}}));
      final toml = datei('heim/.codex/config.toml', 'model = "gpt-5"\n');
      await CodexCli(umgebung).eintragen();
      datei('heim/.codex/skills/moodle/SKILL.md');
      final liste = datei('heim/.lmstudio/apps/bionic/.internal/ng-mcp.json', jsonEncode({
        'servers': [
          {'name': 'blender', 'connection': {'type': 'stdio', 'command': 'cmd'}},
          {
            'name': 'moodle',
            'connection': {
              'type': 'stdio',
              'command': datei('app/$brueckeExe').path,
              'args': [],
            },
          },
        ],
      }));
      datei('heim/.lmstudio/skills/moodle/SKILL.md');
      datei('heim/.lmstudio/skills/fremd/SKILL.md');

      final e = await einrichtungEntfernen(umgebung: umgebung, skills: ['moodle'], werkzeuge: werkzeuge());
      expect(e.code, 0);
      expect(toml.readAsStringSync(), 'model = "gpt-5"\n');
      expect(((jsonDecode(liste.readAsStringSync()) as Map)['servers'] as List).map((s) => (s as Map)['name']),
          ['blender']);
      expect(Directory(p.join(tmp.path, 'heim/.codex/skills/moodle')).existsSync(), isFalse);
      expect(Directory(p.join(tmp.path, 'heim/.lmstudio/skills/moodle')).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'heim/.lmstudio/skills/fremd/SKILL.md')).existsSync(), isTrue);
    });
  });

  group('Profil löschen: Einträge in den Werkzeugen', () {
        late Map<String, String> umgebung;
    late File konfig;
    late File toml;
    final aufrufe = <List<String>>[];

    setUp(() async {
      aufrufe.clear();
      umgebung = {
        'CLAUDE_CONFIG_DIR': p.join(tmp.path, 'cfg'),
        'LOCALAPPDATA': p.join(tmp.path, 'lokal'),
        'USERPROFILE': p.join(tmp.path, 'heim'),
        'HOME': p.join(tmp.path, 'heim'),
      };
      konfig = datei(
          'cfg/.claude.json',
          jsonEncode({
            'mcpServers': {
              'moodle': {'type': 'http', 'url': 'http://127.0.0.1:1/mcp'},
              'moodle-test': {'type': 'http', 'url': 'http://127.0.0.1:2/mcp'},
            },
          }));
      toml = datei('heim/.codex/config.toml', 'model = "gpt-5"\n');
      await CodexCli(umgebung).eintragen(name: 'moodle');
      await CodexCli(umgebung).eintragen(name: 'moodle-test');
    });

    // Tut, was `claude mcp remove <name>` tut: nimmt genau den Namen heraus.
    Future<int> claudeAttrappe(String programm, List<String> argumente) async {
      aufrufe.add(argumente);
      final d = jsonDecode(konfig.readAsStringSync()) as Map;
      (d['mcpServers'] as Map).remove(argumente[2]);
      konfig.writeAsStringSync(jsonEncode(d));
      return 0;
    }

    List<KiWerkzeug> werkzeuge(Future<int> Function(String, List<String>) ausfuehren) =>
        [ClaudeCode(umgebung)..ausfuehren = ausfuehren, CodexCli(umgebung)];

    test('nimmt nur den Eintrag des gelöschten Profils heraus', () async {
      datei(claudeOrt);
      final rest = await profilEintragEntfernen(
          umgebung: umgebung, name: 'moodle-test', werkzeuge: werkzeuge(claudeAttrappe));
      expect(rest, isEmpty);
      expect(aufrufe, [
        ['mcp', 'remove', 'moodle-test', '--scope', 'user'],
      ]);
      expect(((jsonDecode(konfig.readAsStringSync()) as Map)['mcpServers'] as Map).keys, ['moodle']);
      expect(tomlBlock(toml.readAsStringSync(), 'moodle-test'), isNull);
      expect(tomlBlock(toml.readAsStringSync(), 'moodle'), isNotNull);
      expect(toml.readAsStringSync(), startsWith('model = "gpt-5"'));
    });

    test('bleibt ein Eintrag stehen, nennt die Rückgabe Werkzeug und Namen', () async {
      datei(claudeOrt);
      final rest = await profilEintragEntfernen(
          umgebung: umgebung, name: 'moodle-test', werkzeuge: werkzeuge((_, _) async => 0));
      expect(rest, ['Claude Code (moodle-test)']);
      // Codex wurde trotzdem aufgeräumt.
      expect(tomlBlock(toml.readAsStringSync(), 'moodle-test'), isNull);
    });

    test('Codex: Block des Profils samt Unterblöcken weg, der andere bleibt', () async {
      final rest = await profilEintragEntfernen(
          umgebung: umgebung, name: 'moodle-test', werkzeuge: [CodexCli(umgebung)]);
      expect(rest, isEmpty);
      expect(tomlBlock(toml.readAsStringSync(), 'moodle-test'), isNull);
      expect(toml.readAsStringSync(), isNot(contains('moodle-test')));
      expect(tomlBlock(toml.readAsStringSync(), 'moodle'), isNotNull);
      expect(toml.readAsStringSync(), startsWith('model = "gpt-5"'));
    });

    test('ohne Eintrag wird nichts aufgerufen', () async {
      final rest = await profilEintragEntfernen(
          umgebung: umgebung, name: 'gibt-es-nicht', werkzeuge: werkzeuge(claudeAttrappe));
      expect(rest, isEmpty);
      expect(aufrufe, isEmpty);
    });

    test('Deinstallation entfernt die Einträge aller Profile', () async {
      datei(claudeOrt);
      final e = await einrichtungEntfernen(
          umgebung: umgebung,
          skills: const [],
          mcpNamen: ['moodle', 'moodle-test'],
          werkzeuge: werkzeuge(claudeAttrappe));
      expect(e.code, 0);
      expect((jsonDecode(konfig.readAsStringSync()) as Map)['mcpServers'], isEmpty);
      expect(toml.readAsStringSync(), 'model = "gpt-5"\n');
    });
  });
}
