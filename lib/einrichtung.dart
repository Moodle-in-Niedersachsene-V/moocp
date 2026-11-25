// Einrichtung der KI-Werkzeuge: die Verbindung zur App und die Skills.
//
// Damit ein KI-Werkzeug mit der App arbeitet, braucht es zweierlei: einen
// MCP-Eintrag „moodle" mit Adresse und Schlüssel dieser App, und die Skills in
// genau der Version, die zu dieser App gehört -- ändert sich ein Werkzeug,
// ändert sich der Skill mit. Beides prüft die App beim Start für jedes
// gefundene KI-Werkzeug; geschrieben wird erst nach einem Klick im Dialog
// „KI-Werkzeuge einrichten", wie bei den Freigaben. Beim Deinstallieren
// entfernt die App beides wieder ([einrichtungEntfernen]).
//
// Eingerichtet werden Claude Code, Codex (ChatGPT-App oder CLI) und LM Studio. Alle drei sind
// MCP-Clients, die auf demselben Rechner laufen, Skills im Format
// `SKILL.md` laden und eigene Werkzeuge für Dateien haben -- mehr braucht
// diese App von einem Client nicht. Der Chat der ChatGPT-App gehört nicht
// dazu (das in ihr mitgelieferte Codex schon, es teilt `~/.codex` mit der
// CLI): Er erreicht nur öffentliche HTTPS-Server, und der Weg über OpenAIs Tunnel
// führte unsere Werkzeuge aus dem Netz erreichbar heraus (E6) und brächte
// trotzdem keinen Zugriff auf den Arbeitsordner (E5). Ollama ist ein
// Modellserver und gar kein MCP-Client.
//
// Hier steht nur die Logik, ohne Oberfläche, damit sie sich an einem
// nachgebauten Ordnerbaum prüfen lässt (test/einrichtung_test.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'plattform/kindprozess.dart';
import 'plattform/signatur_mac.dart';
import 'plattform/signatur_windows.dart';

/// Die Skills, die die App mitbringt, liegen als Pakete von skills/build.py
/// unter diesem Asset-Pfad (pubspec.yaml).
const skillAssets = 'skills/dist/';

/// Der Name des MCP-Eintrags in jedem KI-Werkzeug.
const mcpName = 'moodle';

/// Skills der App, die die Lehrkraft im Dialog „KI-Werkzeuge einrichten"
/// wählt, mit dem Satz, der dort dabeisteht. Alle anderen Skills der App sind
/// immer dabei. lernsituation ist für berufsbildende Schulen gebaut; anderswo
/// stünde er nur im Weg, denn seine Beschreibung zieht bei jedem
/// „Arbeitsblatt".
///
/// Die Einrichtung liest diese Liste nicht selbst, sondern bekommt die
/// wählbaren Skills als Daten (`wahlSkills`) von ihrem Aufrufer (main.dart);
/// so muss sie nicht wissen, woher ein Skill kommt.
const appWahlSkills = {
  'lernsituation': 'Für berufsbildende Schulen: Lernsituationen mit SchuCu-Tabelle, Ablaufplan, Arbeits- '
      'und Informationsblättern entwerfen.',
};

String? _v(Map<String, String> umgebung, String name) {
  final w = umgebung[name];
  return w == null || w.trim().isEmpty ? null : w;
}

/// Die Verzeichnisse aus PATH, in der Reihenfolge, in der das Betriebssystem sucht.
List<String> _pfad(Map<String, String> umgebung) => [
      for (final d in (_v(umgebung, 'PATH') ?? '').split(Platform.isWindows ? ';' : ':'))
        if (d.trim().isNotEmpty) d.trim(),
    ];

/// Das Benutzerverzeichnis: USERPROFILE unter Windows, sonst HOME.
String? _heimOrdner(Map<String, String> umgebung) => _v(umgebung, Platform.isWindows ? 'USERPROFILE' : 'HOME');

/// Das Benutzerverzeichnis für Orte, die ohne es nicht bestimmbar sind (Konfiguration
/// der KI-Werkzeuge). Ohne es lösten sie sich relativ zum Arbeitsverzeichnis auf, und
/// die App schriebe Konfigurationsdateien in einen beliebigen Ordner (E29).
String _heimPflicht(Map<String, String> umgebung) =>
    _heimOrdner(umgebung) ??
    (throw StateError('Der Benutzerordner (${Platform.isWindows ? 'USERPROFILE' : 'HOME'}) ist nicht gesetzt; '
        'die KI-Werkzeuge lassen sich nicht einrichten.'));

/// Der Dateiname eines Programms: unter Windows mit .exe, auf dem Mac nackt.
String _programm(String name) => Platform.isWindows ? '$name.exe' : name;

/// Wo Homebrew und ein Installer unter macOS Programme ablegen, die nicht im
/// PATH einer App liegen (eine Finder-gestartete App erbt den PATH der Shell nicht).
const _macVerzeichnisse = ['/opt/homebrew/bin', '/usr/local/bin'];

/// Dasselbe unter Linux: Eine Sitzung über xrdp oder ein Starter im Menü erbt
/// den PATH der Shell ebenfalls nicht. Dazu die Orte, an die npm ohne
/// Administratorrechte installiert (`~/.npm-global`, `~/.local/bin`), und
/// Homebrew für Linux.
List<String> _linuxVerzeichnisse(String? heim) => [
  '/usr/local/bin',
  '/usr/bin',
  '/home/linuxbrew/.linuxbrew/bin',
  if (heim != null) ...[p.join(heim, '.local', 'bin'), p.join(heim, '.npm-global', 'bin'), p.join(heim, '.bun', 'bin')],
];

/// Ersetzt die festen Programmordner außerhalb von PATH (null: die der
/// Plattform). Nur für die Tests, damit die Werkzeugsuche nicht vom
/// installierten Bestand des Rechners abhängt. Bewusst keine Umgebungsvariable:
/// Wer sie setzen kann, bestimmte, welches Programm die App startet und
/// welchem sie den Zugangsschlüssel gibt (vgl. [claudeSigniert]).
List<String>? festeProgrammOrdner;

/// Ersetzt die Ordner, in denen die App nach der ChatGPT-App sucht (null: unter
/// macOS `/Applications` und `~/Applications`, sonst keine). Nur für die Tests,
/// aus demselben Grund wie [festeProgrammOrdner].
List<String>? festeAppOrdner;

/// Die festen Programmordner dieser Plattform außerhalb von PATH.
List<String> _unixVerzeichnisse(String? heim) =>
    festeProgrammOrdner ?? (Platform.isLinux ? _linuxVerzeichnisse(heim) : _macVerzeichnisse);

// ---------------------------------------------------------------------------
// Die Verbindung: der MCP-Eintrag „moodle"
// ---------------------------------------------------------------------------

enum Verbindung { aktuell, fehlt, veraltet, unlesbar }

String mcpAdresse(int port) => 'http://127.0.0.1:$port/mcp';

String mcpKopf(String schluessel) => 'Bearer $schluessel';

/// Das Zeitlimit je Werkzeugaufruf, das die App in jedes KI-Werkzeug
/// einträgt. Jedes hat ein eigenes, ab dem Aufruf gemessenes, und bricht
/// danach ab, auch während eine Freigabe offen ist: Claude Code und Codex
/// nach 60 Sekunden, Bionic ebenso (Einzelheiten je Werkzeug unten). Lesen
/// und Schreiben eines größeren Abschnitts brauchen schon je fast so lange.
/// Länger als die Frist einer Freigabe (`Freigaben.fristVorgabe`), die wie
/// das Zeitlimit ab der Anfrage läuft, auch hinter einer anderen: So endet
/// die Freigabe zuerst und meldet das selbst, und nach einer späten Freigabe
/// bleibt Zeit zum Schreiben und Zurücklesen.
const clientZeitlimit = Duration(minutes: 35);

// ---------------------------------------------------------------------------
// Ein KI-Werkzeug
// ---------------------------------------------------------------------------

/// Ein KI-Werkzeug, das die App einrichten kann. Je Werkzeug steht hier, wo
/// es liegt, wie sein MCP-Eintrag geprüft und geschrieben wird und wohin
/// seine Skills gehören. Alles Übrige -- Vergleich der Skills, Reihenfolge,
/// Dialog -- ist für alle gleich.
abstract class KiWerkzeug {
  KiWerkzeug(this.umgebung);

  final Map<String, String> umgebung;

  /// Kurzname, unter dem die Wahl in den Einstellungen steht.
  String get id;

  /// Name für die Anzeige.
  String get name;

  /// Wohin die Inhalte gehen, die dieses Werkzeug aus der App liest. Steht im
  /// Dialog neben dem Namen. Bewusst vom eingestellten Modell her gesagt,
  /// nicht vom Werkzeug: Claude Code und Codex lassen sich auf andere Anbieter
  /// umstellen, und LM Studio kann neben lokalen Modellen auch Cloud-Modelle
  /// benutzen. Der Hinweis zum Datenschutz (README, Installer) gilt deshalb
  /// für jedes Werkzeug, auch für LM Studio.
  String get datenziel;

  /// Wo die Verbindung zur App wirkt, in einem Satz. Steht im Dialog unter
  /// dem Namen und im Abschluss. Nur Clients auf diesem Rechner erreichen die
  /// App (E6); der normale Chat von Claude Desktop und der ChatGPT-App ist
  /// keiner, ChatGPT und Claude im Browser auch nicht.
  String get wirkt;

  /// Ob das Werkzeug auf diesem Rechner benutzt wird. Nicht gefundene
  /// Werkzeuge erscheinen nicht im Dialog und werden nicht eingerichtet.
  bool get gefunden;

  /// Der Ordner, aus dem das Werkzeug persönliche Skills lädt.
  Directory get skillOrdner;

  /// Ob die App Eintrag und Austrag selbst vornehmen kann. Fehlt etwa die
  /// claude.exe, lässt sich bei Claude Code nichts eintragen -- die Skills
  /// aber schon.
  bool get bedienbar;

  /// Was fehlt, wenn [bedienbar] false ist; sonst null.
  String? get hindernis;

  /// Ein Hinweis für den Dialog, der nichts verhindert; sonst null.
  String? get hinweis => null;

  /// Der Stand des MCP-Eintrags [name] (E31: je Instanzprofil einer) in diesem Werkzeug.
  Verbindung verbindung(int port, String schluessel, {String name = mcpName});

  /// Trägt die App ein. null bei Erfolg, sonst eine Beschreibung -- nie mit
  /// der Ausgabe eines Programms, denn die kann den Schlüssel enthalten.
  Future<String?> eintragen(int port, String schluessel, {String name = mcpName});

  /// Entfernt den Eintrag [name] wieder. null bei Erfolg.
  Future<String?> austragen({String name = mcpName});


  /// Der Stand der Verbindung in Worten für den Dialog.
  String verbindungText(Verbindung v) => switch (v) {
        Verbindung.aktuell => 'aktuell',
        Verbindung.fehlt => 'nicht eingetragen',
        Verbindung.veraltet => 'Schlüssel muss aktualisiert werden',
        Verbindung.unlesbar => 'Konfiguration nicht lesbar, wird neu eingetragen',
      };
}

// ---------------------------------------------------------------------------
// Claude Code
// ---------------------------------------------------------------------------

// Welche claude.exe die App startet (und ihr damit den Zugangsschlüssel gibt),
// entscheidet unter Windows die Signatur, nicht der Ort: Nur eine Datei mit
// gültiger Authenticode-Signatur von Anthropic zählt (vonAnthropic,
// lib/plattform/signatur_windows.dart). Der Ort beschleunigt nur die Suche;
// Claude Desktop hat seine Ablage schon geändert und wird es wieder tun.
//
// Bekannte Ablagen von Claude Desktop (MSIX, Paketfamilie aus Anthropics
// Herausgebernamen, bei Verteilung über die Webseite):
// - %LOCALAPPDATA%\Claude-Data\claude_pzs8sxrjxfjjc\claude-code\<Version>\
//   <Prüfsumme>\claude.exe, außerhalb der MSIX-Umleitung; neben der exe
//   liegen .payload und .verified (undokumentiert, vermutlich nach geprüftem
//   Download gesetzt);
// - früher %LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\
//   Claude\claude-code\<Version>\claude.exe (das umgeleitete %APPDATA%).
// Claude Desktop lädt Claude Code nach und behält ältere Versionen. Findet
// sich an keinem bekannten Ort eine signierte exe, sucht die App breiter
// (_breiteSuche), auch für eine andere Verteilung, etwa ein Store-Paket mit
// anderem Namen.
//
// macOS: Claude Desktop legt Claude Code unter
// ~/Library/Application Support/Claude/claude-code/<Version>/<Prüfsumme>/
// claude.app/Contents/MacOS/claude ab. Dort zählt nur eine Datei mit gültiger
// Signatur von Anthropic (vonAnthropicMac, lib/plattform/signatur_mac.dart).
// Die übrigen Orte (Suchpfad, ~/.local/bin, Homebrew) bleiben ohne Prüfung, wie
// bisher; Linux prüft nichts.
const _claudeDesktopPaket = 'Claude_pzs8sxrjxfjjc';

/// Prüft unter Windows, ob eine gefundene claude.exe von Anthropic stammt.
/// Austauschbar für die Tests, die mit leeren Dateien arbeiten.
bool Function(String exe) claudeSigniert = vonAnthropic;

/// Dasselbe unter macOS, aber nur für die Ablage von Claude Desktop.
bool Function(String exe) claudeSigniertMac = vonAnthropicMac;

/// Sucht die claude.exe: Claude Desktop (neue, dann alte Ablage, dann
/// klassischer Installer), der Suchpfad, der eigenständige Installer, die
/// VS-Code-Erweiterung -- in dieser Reihenfolge, je Ort die höchste Version;
/// unter Windows zuletzt die breite Suche. null, wenn nichts da ist. In
/// [bericht] landen dann die durchsuchten Orte und die verworfenen Dateien
/// (nur Pfade, E11) für das Protokoll.
String? claudeFinden(Map<String, String> umgebung, {List<String>? bericht}) {
  final lokal = _v(umgebung, 'LOCALAPPDATA');
  final roaming = _v(umgebung, 'APPDATA');
  final heim = _heimOrdner(umgebung);
  final verworfen = <String>[];
  bool gut(String exe) {
    if (!File(exe).existsSync()) return false;
    if (!Platform.isWindows || claudeSigniert(exe)) return true;
    verworfen.add(exe);
    return false;
  }

  bool gutMac(String exe) {
    if (!File(exe).existsSync()) return false;
    if (claudeSigniertMac(exe)) return true;
    verworfen.add(exe);
    return false;
  }

  final macDesktop =
      Platform.isMacOS && heim != null ? p.join(heim, 'Library', 'Application Support', 'Claude', 'claude-code') : null;
  final orte = [
    if (Platform.isWindows && lokal != null)
      p.join(lokal, 'Claude-Data', _claudeDesktopPaket.toLowerCase(), 'claude-code'),
    if (Platform.isWindows && lokal != null)
      p.join(lokal, 'Packages', _claudeDesktopPaket, 'LocalCache', 'Roaming', 'Claude', 'claude-code'),
    if (Platform.isWindows && roaming != null) p.join(roaming, 'Claude', 'claude-code'),
  ];
  final kandidaten = <String? Function()>[
    for (final o in orte) () => _neuesteVersion(o, gut),
    if (macDesktop != null) () => _neuesteVersion(macDesktop, gutMac, datei: _claudeMacProgramm),
    for (final d in _pfad(umgebung)) () => _einzeln(p.join(d, _programm('claude')), gut),
    if (heim != null) () => _einzeln(p.join(heim, '.local', 'bin', _programm('claude')), gut),
    if (!Platform.isWindows) for (final d in _unixVerzeichnisse(heim)) () => _einzeln(p.join(d, 'claude'), gut),
    if (Platform.isWindows && heim != null) () => _vsCode(p.join(heim, '.vscode', 'extensions'), gut),
  ];
  for (final k in kandidaten) {
    final exe = k();
    if (exe != null) return exe;
  }
  final wurzeln = [
    if (Platform.isWindows && lokal != null) ..._unterordner(p.join(lokal, 'Claude-Data')),
    if (Platform.isWindows && lokal != null)
      ..._unterordner(p.join(lokal, 'Packages')).where((d) => p.basename(d).toLowerCase().contains('claude')),
    if (Platform.isWindows && roaming != null) p.join(roaming, 'Claude'),
  ];
  final breit = _besteVersion(_breiteSuche(wurzeln), gut);
  if (breit != null) return breit;
  bericht?.addAll([
    'durchsucht: ${{...orte, ...wurzeln, ?macDesktop}.join('; ')}${orte.isEmpty && macDesktop == null ? '' : '; dazu Suchpfad, .local/bin und VS Code'}',
    if (verworfen.isNotEmpty) 'verworfen, keine Signatur von Anthropic: ${verworfen.join('; ')}',
  ]);
  return null;
}

String? _einzeln(String exe, bool Function(String) gut) => gut(exe) ? exe : null;

List<String> _unterordner(String ordner) {
  try {
    return [for (final e in Directory(ordner).listSync().whereType<Directory>()) e.path];
  } on FileSystemException {
    return const [];
  }
}

/// Vergleicht Versionsnummern Stelle für Stelle als Zahlen: 2.10 kommt nach
/// 2.9, anders als beim Textvergleich.
int versionVergleichen(List<int> a, List<int> b) {
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

List<int>? _version(String text) {
  final teile = text.split('.');
  final zahlen = teile.map(int.tryParse).toList();
  return zahlen.any((z) => z == null) ? null : zahlen.cast<int>();
}

/// Ein Fund: Version (leer, wenn keine bekannt), ob `.verified` daneben
/// liegt, Änderungszeit, Pfad.
typedef _Fund = (List<int>, bool, DateTime, String);

_Fund _fund(List<int> version, String exe) => (
      version,
      FileSystemEntity.typeSync(p.join(p.dirname(exe), '.verified')) != FileSystemEntityType.notFound,
      File(exe).lastModifiedSync(),
      exe,
    );

/// Die erste Datei, die [gut] besteht: höchste Version zuerst, bei gleicher
/// Version die mit `.verified`, dann die neueste.
String? _besteVersion(Iterable<_Fund> funde, bool Function(String) gut) {
  final liste = funde.toList()
    ..sort((a, b) {
      final v = versionVergleichen(b.$1, a.$1);
      if (v != 0) return v;
      if (a.$2 != b.$2) return a.$2 ? -1 : 1;
      return b.$3.compareTo(a.$3);
    });
  for (final f in liste) {
    if (gut(f.$4)) return f.$4;
  }
  return null;
}

// Je Version ein Ordner; die exe liegt darin oder eine Ebene tiefer in einem
// Ordner mit einer Prüfsumme (<Version>\<Prüfsumme>\claude.exe).
const _claudeMacProgramm = 'claude.app/Contents/MacOS/claude';

String? _neuesteVersion(String ordner, bool Function(String) gut, {String datei = 'claude.exe'}) {
  final funde = <_Fund>[];
  for (final d in _unterordner(ordner)) {
    final ver = _version(p.basename(d));
    if (ver == null) continue;
    for (final o in [d, ..._unterordner(d)]) {
      final exe = p.joinAll([o, ...datei.split('/')]);
      if (File(exe).existsSync()) funde.add(_fund(ver, exe));
    }
  }
  return _besteVersion(funde, gut);
}

// Ordner, in denen Claude Desktop Sitzungen, Zwischenspeicher und Protokolle
// ablegt: groß und ohne Programme, darum nicht durchlaufen.
const _nichtDurchsuchen = {
  'claude-code-sessions', 'cache', 'code cache', 'gpucache', 'dawncache', 'logs', 'indexeddb',
  'local storage', 'session storage', 'service worker', 'blob_storage', 'crashpad', 'node_modules',
};

/// Jede claude.exe unter [wurzeln] bis Tiefe 6, unabhängig vom Ordneraufbau.
/// Die Version kommt aus dem nächsten Vorfahren mit einer Versionsnummer als
/// Namen; sonst bleibt sie leer, und die Änderungszeit entscheidet.
Iterable<_Fund> _breiteSuche(List<String> wurzeln) sync* {
  for (final w in wurzeln) {
    yield* _durchlaufen(w, const [], 0);
  }
}

Iterable<_Fund> _durchlaufen(String ordner, List<int> version, int tiefe) sync* {
  final exe = p.join(ordner, 'claude.exe');
  if (File(exe).existsSync()) yield _fund(version, exe);
  if (tiefe >= 6) return;
  for (final d in _unterordner(ordner)) {
    final name = p.basename(d).toLowerCase();
    if (_nichtDurchsuchen.contains(name) || name.endsWith('-sessions')) continue;
    yield* _durchlaufen(d, _version(p.basename(d)) ?? version, tiefe + 1);
  }
}

// Die Erweiterung legt je Version einen Ordner
// anthropic.claude-code-<Version>-win32-x64 an, die claude.exe darin unter
// resources\native-binary.
String? _vsCode(String erweiterungen, bool Function(String) gut) {
  final muster = RegExp(r'^anthropic\.claude-code-([0-9.]+)-win32-');
  final funde = <_Fund>[];
  for (final d in _unterordner(erweiterungen)) {
    final m = muster.firstMatch(p.basename(d));
    final ver = m == null ? null : _version(m.group(1)!);
    final exe = p.join(d, 'resources', 'native-binary', 'claude.exe');
    if (ver != null && File(exe).existsSync()) funde.add(_fund(ver, exe));
  }
  return _besteVersion(funde, gut);
}

/// Claude Code. Eingetragen wird nur über die eigene Kommandozeile, nie durch
/// Schreiben in `.claude.json`: Die Datei gehört Claude Code und wird dort
/// ständig neu geschrieben. CLAUDE_CONFIG_DIR verlegt Konfiguration und
/// Skills; sonst liegen sie im Benutzerverzeichnis. MSIX leitet diese Orte
/// nicht um -- Claude Desktop und VS Code lesen dieselben.
class ClaudeCode extends KiWerkzeug {
  ClaudeCode(super.umgebung)
      : _eigen = umgebung['CLAUDE_CONFIG_DIR'];

  final String? _eigen;

  @override
  String get id => 'claude';
  @override
  String get name => 'Claude Code';
  @override
  String get datenziel => 'Inhalte gehen an das eingestellte Modell, in der Regel bei Anthropic';
  // Claude Desktop bringt Claude Code im Reiter „Code“ mit und teilt dessen
  // Konfiguration; der normale Chat sieht die Einträge nicht.
  @override
  String get wirkt => 'Wirkt in Claude Code und im Reiter „Code“ von Claude Desktop, nicht im normalen Chat.';

  /// Pfad der claude-Programmdatei (unter Windows claude.exe); null, wenn sie nicht gefunden wurde.
  String? get exe {
    if (!_gesucht) {
      _exe = claudeFinden(umgebung, bericht: suchbericht);
      _gesucht = true;
    }
    return _exe;
  }

  String? _exe;
  bool _gesucht = false;

  /// Wo gesucht und was verworfen wurde, wenn [exe] null ist; für das
  /// Protokoll.
  final List<String> suchbericht = [];

  File get konfiguration => File(p.join(_eigen ?? _heimPflicht(umgebung), '.claude.json'));

  @override
  Directory get skillOrdner => Directory(p.join(_eigen ?? p.join(_heimPflicht(umgebung), '.claude'), 'skills'));

  // Auch ohne claude.exe gefunden: Wer `.claude.json` hat, benutzt Claude
  // Code -- dann soll der Dialog es zeigen und sagen, was fehlt, statt es
  // stillschweigend auszulassen.
  @override
  bool get gefunden => exe != null || konfiguration.existsSync() || skillOrdner.existsSync();

  @override
  bool get bedienbar => exe != null;

  @override
  String? get hindernis => bedienbar
      ? null
      : 'Claude Code nicht gefunden. Claude Desktop installieren und dort einmal den Bereich '
          '„Code" öffnen, danach „Nochmal prüfen".';

  @override
  Verbindung verbindung(int port, String schluessel, {String name = mcpName}) {
    if (!konfiguration.existsSync()) return Verbindung.fehlt;
    try {
      final d = jsonDecode(konfiguration.readAsStringSync());
      final server = (d is Map) ? d['mcpServers'] : null;
      final e = (server is Map) ? server[name] : null;
      if (e is! Map) return Verbindung.fehlt;
      final kopf = e['headers'] is Map ? (e['headers'] as Map)['Authorization'] : null;
      final passt = e['type'] == 'http' &&
          e['url'] == mcpAdresse(port) &&
          kopf == mcpKopf(schluessel) &&
          e['timeout'] == clientZeitlimit.inMilliseconds;
      return passt ? Verbindung.aktuell : Verbindung.veraltet;
    } catch (_) {
      // Auch ein halb geschriebener Stand, wenn Claude Code gerade speichert.
      return Verbindung.unlesbar;
    }
  }

  /// Die Argumente für `claude mcp add-json`. Der Schlüssel steht darin --
  /// sie gehen an die claude.exe, nie in Protokoll oder Anzeige.
  ///
  /// add-json statt add, weil nur der JSON-Eintrag `timeout` kennt: Ohne
  /// bricht Claude Code jede Anfrage an einen HTTP-Server ab, die nach 60
  /// Sekunden noch keine Antwort hat, und die App antwortet erst, wenn das
  /// Werkzeug fertig ist (enableJsonResponse, mcp_dienst.dart). `timeout`
  /// gilt für den ganzen Werkzeugaufruf, Fortschrittsmeldungen verlängern ihn
  /// nicht ([clientZeitlimit]).
  List<String> addArgumente(int port, String schluessel, [String name = mcpName]) => [
        'mcp', 'add-json', '--scope', 'user', name, //
        jsonEncode({
          'type': 'http',
          'url': mcpAdresse(port),
          'headers': {'Authorization': mcpKopf(schluessel)},
          'timeout': clientZeitlimit.inMilliseconds,
        }),
      ];

  @override
  Future<String?> eintragen(int port, String schluessel, {String name = mcpName}) async {
    if (exe == null) return '${_programm('claude')} nicht gefunden';
    // Fehlt der Eintrag, endet remove mit Fehler; das ist hier der Normalfall.
    await ausfuehren(exe!, ['mcp', 'remove', name, '--scope', 'user']);
    final code = await ausfuehren(exe!, addArgumente(port, schluessel, name));
    return code == 0 ? null : 'claude mcp add endete mit Code $code';
  }

  @override
  Future<String?> austragen({String name = mcpName}) async {
    if (verbindung(0, '', name: name) == Verbindung.fehlt) return null;
    if (exe == null) return '${_programm('claude')} nicht gefunden';
    final code = await ausfuehren(exe!, ['mcp', 'remove', name, '--scope', 'user']);
    return code == 0 ? null : 'claude mcp remove endete mit Code $code';
  }

  /// Nur für die Tests: ersetzt das Starten der claude.exe.
  Future<int> Function(String programm, List<String> argumente) ausfuehren = _ausfuehren;
}

/// Startet ein Programm ohne Konsole und wartet höchstens eine Minute. Die
/// Ausgabe wird gelesen (sonst kann ein voller Puffer den Prozess anhalten)
/// und verworfen.
Future<int> _ausfuehren(String programm, List<String> argumente) async {
  final pr = await prozessStarten(programm, argumente);
  unawaited(pr.stdout.drain<void>());
  unawaited(pr.stderr.drain<void>());
  return pr.exitCode.timeout(const Duration(minutes: 1), onTimeout: () {
    pr.kill();
    return -1;
  });
}

// ---------------------------------------------------------------------------
// Codex (ChatGPT-App oder CLI)
// ---------------------------------------------------------------------------

/// Codex von OpenAI, als CLI oder in der ChatGPT-App. Der Eintrag wird in `~/.codex/config.toml`
/// geschrieben, nicht über `codex mcp add`: Dessen Kommandozeile kennt nur
/// `--bearer-token-env-var`, das den Schlüssel in eine dauerhafte
/// Umgebungsvariable zwänge, die jedes Programm des Benutzers liest. Ein
/// statischer Kopf (`http_headers`) steht dagegen nur in dieser Datei, die
/// Codex nicht von selbst neu schreibt. Angefasst wird ausschließlich der
/// Block `[mcp_servers.moodle]`; alles andere darin bleibt Zeichen für
/// Zeichen stehen.
class CodexCli extends KiWerkzeug {
  CodexCli(super.umgebung);

  @override
  String get id => 'codex';
  @override
  String get name => 'Codex (ChatGPT-App oder CLI)';
  @override
  // Der Schlüssel für Moodle steht bei Codex im Klartext in der Datei
  // (ADR 0021, 0013): Das muss die Anzeige sagen, bevor die Lehrkraft
  // „Installieren" klickt.
  String get datenziel =>
      'Inhalte gehen an das eingestellte Modell, in der Regel bei OpenAI. Der Moodle-Schlüssel steht im '
      'Klartext in config.toml im Codex-Ordner (in der Regel ~/.codex)';

  // Codex-Sitzungen der ChatGPT-App teilen ~/.codex mit der Kommandozeile und
  // sehen die Einträge; der normale Chat der App ist kein Client.
  @override
  String get wirkt => 'Wirkt in Codex und in Codex-Sitzungen der ChatGPT-App, nicht im normalen Chat der App.';

  /// CODEX_HOME verlegt Konfiguration und Skills; sonst `~/.codex`.
  Directory get heim => Directory(_v(umgebung, 'CODEX_HOME') ?? p.join(_heimPflicht(umgebung), '.codex'));

  File get konfiguration => File(p.join(heim.path, 'config.toml'));

  @override
  Directory get skillOrdner => Directory(p.join(heim.path, 'skills'));

  /// Die codex.exe braucht die App nicht (sie schreibt die Konfiguration
  /// selbst), wohl aber einen Hinweis darauf, dass Codex benutzt wird. Über
  /// npm installiert, liegt nur ein .cmd im Suchpfad.
  String? get exe {
    final dirs = [
      ..._pfad(umgebung),
      if (Platform.isWindows && _v(umgebung, 'APPDATA') != null) p.join(umgebung['APPDATA']!, 'npm'),
      if (!Platform.isWindows) ..._unixVerzeichnisse(_heimOrdner(umgebung)),
    ];
    final namen = Platform.isWindows ? const ['codex.exe', 'codex.cmd', 'codex.bat'] : const ['codex'];
    for (final d in dirs) {
      for (final n in namen) {
        if (File(p.join(d, n)).existsSync()) return p.join(d, n);
      }
    }
    return null;
  }

  /// Das mitgelieferte Codex der ChatGPT-App unter macOS
  /// (`ChatGPT.app/Contents/Resources/codex-cli/bin/codex`); „ChatGPT Classic"
  /// hat es nicht. App und CLI teilen sich `~/.codex` (Konfiguration und
  /// Skills). Erkannt wird nur der Ort, das Programm wird nie gestartet. Nur
  /// macOS (E24): Unter Windows ist es nicht gemessen, unter Linux gibt es die App nicht.
  String? get chatgptApp {
    final h = _heimOrdner(umgebung);
    final orte = festeAppOrdner ?? (Platform.isMacOS ? ['/Applications', if (h != null) p.join(h, 'Applications')] : const <String>[]);
    for (final o in orte) {
      final f = p.join(o, 'ChatGPT.app', 'Contents', 'Resources', 'codex-cli', 'bin', 'codex');
      if (File(f).existsSync()) return f;
    }
    return null;
  }

  @override
  bool get gefunden => heim.existsSync() || exe != null || chatgptApp != null;

  @override
  String? get hinweis => !heim.existsSync() && exe == null && chatgptApp != null
      ? 'Codex aus der ChatGPT-App hat seinen Ordner ${heim.path} noch nicht angelegt. Öffnen Sie Codex in der '
          'ChatGPT-App einmal, bevor Sie installieren; sonst legt moocp den Ordner selbst an.'
      : null;

  @override
  bool get bedienbar => true;
  @override
  String? get hindernis => null;

  @override
  Verbindung verbindung(int port, String schluessel, {String name = mcpName}) {
    if (!konfiguration.existsSync()) return Verbindung.fehlt;
    final String text;
    try {
      text = konfiguration.readAsStringSync();
    } catch (_) {
      return Verbindung.unlesbar;
    }
    final block = tomlBlock(text, name);
    if (block == null) return Verbindung.fehlt;
    final url = _tomlWert(block, 'url');
    final kopf = _tomlWert(block, 'Authorization');
    if (url == null || kopf == null) return Verbindung.veraltet;
    return url == mcpAdresse(port) &&
            kopf == mcpKopf(schluessel) &&
            _tomlZahl(block, 'tool_timeout_sec') == clientZeitlimit.inSeconds
        ? Verbindung.aktuell
        : Verbindung.veraltet;
  }

  @override
  Future<String?> eintragen(int port, String schluessel, {String name = mcpName}) async {
    try {
      final alt = konfiguration.existsSync() ? konfiguration.readAsStringSync() : '';
      final neu = tomlBlockSetzen(alt, name, mcpAdresse(port), mcpKopf(schluessel));
      konfiguration.parent.createSync(recursive: true);
      konfiguration.writeAsStringSync(neu, flush: true);
      return null;
    } catch (x) {
      return 'config.toml nicht geschrieben (${x.runtimeType})';
    }
  }

  @override
  Future<String?> austragen({String name = mcpName}) async {
    if (!konfiguration.existsSync()) return null;
    try {
      final alt = konfiguration.readAsStringSync();
      if (tomlBlock(alt, name) == null) return null;
      konfiguration.writeAsStringSync(tomlBlockEntfernen(alt, name), flush: true);
      return null;
    } catch (x) {
      return 'config.toml nicht geschrieben (${x.runtimeType})';
    }
  }
}

// Der Kopf eines Blocks: [mcp_servers.moodle] oder [mcp_servers."moodle"],
// auch mit Unterblöcken wie [mcp_servers.moodle.http_headers].
RegExp _tomlKopf(String name) =>
    RegExp(r'^[ \t]*\[[ \t]*mcp_servers[ \t]*\.[ \t]*"?' + RegExp.escape(name) + r'"?[ \t]*(\.[^\]]*)?\][ \t]*$');

bool _istKopf(String zeile) => RegExp(r'^[ \t]*\[').hasMatch(zeile);

bool _leerOderKommentar(String zeile) {
  final z = zeile.trim();
  return z.isEmpty || z.startsWith('#');
}

/// Der Text des Blocks `[mcp_servers.<name>]` samt seiner Unterblöcke, oder
/// null, wenn es ihn nicht gibt. Bewusst kein vollständiger TOML-Leser: Es
/// geht nur um einen Block, den diese App selbst geschrieben hat, und jede
/// Abhängigkeit müsste nach E14 auf ihre Lizenz geprüft werden.
String? tomlBlock(String text, String name) {
  final zeilen = text.replaceAll('\r\n', '\n').split('\n');
  final (von, bis) = _tomlGrenzen(zeilen, name);
  return von < 0 ? null : zeilen.sublist(von, bis).join('\n');
}

/// Erste und hinter der letzten Zeile des Blocks. Leerzeilen und Kommentare
/// vor dem nächsten Kopf gehören zu diesem, nicht zu unserem Block: Wer über
/// `[mcp_servers.github]` notiert hat, wofür er ist, soll das behalten.
(int, int) _tomlGrenzen(List<String> zeilen, String name) {
  final kopf = _tomlKopf(name);
  final von = zeilen.indexWhere(kopf.hasMatch);
  if (von < 0) return (-1, -1);
  var bis = von + 1;
  while (bis < zeilen.length && !(_istKopf(zeilen[bis]) && !kopf.hasMatch(zeilen[bis]))) {
    bis++;
  }
  while (bis > von + 1 && _leerOderKommentar(zeilen[bis - 1])) {
    bis--;
  }
  return (von, bis);
}

/// Liest einen Wert in Anführungszeichen aus einem Blocktext, gleich ob er
/// als eigener Schlüssel, in einer Inline-Tabelle oder in einem Unterblock
/// steht: `url = "…"`, `http_headers = { Authorization = "…" }` und
/// `[mcp_servers.moodle.http_headers]` mit `Authorization = "…"` ergeben
/// dasselbe. Der Schlüssel muss für sich stehen, `token_url` ist nicht `url`.
String? _tomlWert(String block, String schluessel) =>
    RegExp(r'(?<![\w-])' + RegExp.escape(schluessel) + r'[ \t]*=[ \t]*"([^"]*)"').firstMatch(block)?.group(1);

/// Eine Zahl aus einem Blocktext wie `tool_timeout_sec = 2100`, auch als
/// `2100.0`; null, wenn sie fehlt oder keine ganze Zahl ist.
num? _tomlZahl(String block, String schluessel) {
  final m = RegExp(r'(?<![\w-])' + RegExp.escape(schluessel) + r'[ \t]*=[ \t]*([0-9]+(\.0+)?)(?![\w.])')
      .firstMatch(block);
  return m == null ? null : num.parse(m.group(1)!);
}

/// Wendet [aendern] auf die Zeilen an und behält die Zeilenenden der Datei:
/// Wer CRLF hat, bekommt CRLF zurück.
String _zeilenweise(String text, List<String> Function(List<String> zeilen) aendern) {
  final crlf = text.contains('\r\n');
  final neu = aendern(text.replaceAll('\r\n', '\n').split('\n')).join('\n');
  return crlf ? neu.replaceAll('\n', '\r\n') : neu;
}

/// Setzt den Block `[mcp_servers.<name>]` auf Adresse, Kopf und Zeitlimit
/// dieser App und lässt alles andere unberührt. Einen vorhandenen Block
/// ersetzt er samt Unterblöcken, sonst hängt er ihn an. Ohne
/// `tool_timeout_sec` bricht Codex jeden Werkzeugaufruf nach 60 Sekunden ab
/// ([clientZeitlimit]).
String tomlBlockSetzen(String text, String name, String url, String kopf) {
  final block = [
    '[mcp_servers.$name]',
    'url = "$url"',
    'http_headers = { Authorization = "$kopf" }',
    'tool_timeout_sec = ${clientZeitlimit.inSeconds}',
  ];
  return _zeilenweise(text, (zeilen) {
    final (von, bis) = _tomlGrenzen(zeilen, name);
    if (von >= 0) return [...zeilen.sublist(0, von), ...block, ...zeilen.sublist(bis)];
    while (zeilen.isNotEmpty && zeilen.last.trim().isEmpty) {
      zeilen.removeLast();
    }
    return [...zeilen, if (zeilen.isNotEmpty) '', ...block, ''];
  });
}

/// Entfernt den Block `[mcp_servers.<name>]` samt Unterblöcken und den
/// Leerzeilen, die davor standen.
String tomlBlockEntfernen(String text, String name) => _zeilenweise(text, (zeilen) {
      final (von, bis) = _tomlGrenzen(zeilen, name);
      if (von < 0) return zeilen;
      var anfang = von;
      while (anfang > 0 && zeilen[anfang - 1].trim().isEmpty) {
        anfang--;
      }
      final rest = [...zeilen.sublist(0, anfang), ...zeilen.sublist(bis)];
      while (rest.isNotEmpty && rest.last.trim().isEmpty) {
        rest.removeLast();
      }
      return rest.isEmpty ? [] : [...rest, ''];
    });

// ---------------------------------------------------------------------------
// LM Studio
// ---------------------------------------------------------------------------

/// LM Studio mit seinem Agenten Bionic, einem eigenen Programm
/// (`%LOCALAPPDATA%\Programs\Bionic\Bionic.exe`) neben dem klassischen LM
/// Studio; beide teilen den Datenordner `~/.lmstudio`. Gemessen:
/// - Bionic liest `~/.lmstudio/mcp.json` nicht (die gehört zum klassischen
///   LM Studio), sondern führt seine Server in
///   `apps/bionic/.internal/ng-mcp.json`:
///   `{"servers": [{id, name, enabled, connection: {type: "stdio", command, args, env, timeoutMs}}]}`.
/// - Sein Dialog kennt nur lokale Befehle (stdio). Darum kommt die Brücke
///   hinein (mcp/bruecke.dart): `moocp-bruecke.exe`, ohne Schlüssel.
/// - Weder `lmstudio://add_mcp` (geht an das klassische LM Studio) noch
///   `bionic://add_mcp` legen dort etwas an. Von Hand eintragen wäre der
///   dokumentierte Weg, ist aber für Lehrkräfte zu viel.
/// - Bionic liest die Liste im laufenden Betrieb neu: Ein Eintrag von außen
///   erscheint sofort und bleibt über einen Neustart.
/// - `timeoutMs` ist das Zeitlimit je Anfrage an den Server (in Bionic
///   „Request timeout" unter den erweiterten Optionen): fehlt es, 60
///   Sekunden; erlaubt ist jede positive ganze Zahl bis 2³¹−1. Danach bricht
///   Bionic den Werkzeugaufruf ab, auch während eine Freigabe offen ist --
///   darum trägt die App [clientZeitlimit] ein.
/// - Bilder aus Werkzeugergebnissen gibt Bionic nicht ans Modell weiter,
///   weder als Bildinhalt noch als eingebettete Ressource (darum legt
///   `bildschirmfoto` Dateien ab).
/// - Bionic verlangt in jeder Sitzung eine Erlaubnis für den Arbeitsordner;
///   sie lässt sich nicht vorab eintragen.
/// - Die Skills liegen in `~/.lmstudio/skills`, wie bei den anderen Werkzeugen
///   im eigenen Ordner: Claude Code liest keinen gemeinsamen, und nur so
///   bleibt das Deinstallieren eindeutig.
///
/// Also schreibt die App selbst hinein, ohne dass Bionic beendet werden muss.
/// Weil die Datei intern und nicht dokumentiert ist, so vorsichtig wie
/// möglich: Angefasst werden nur Einträge namens „moodle", alles andere
/// bleibt; geschrieben wird über eine Zwischendatei, damit Bionic nie eine
/// halbe liest; eine Liste, die sich nicht lesen lässt, wird nicht
/// überschrieben. Ob Bionic den Eintrag auch annimmt, sieht die App erst an
/// der Verbindung („KI-Werkzeug verbunden" im Protokoll); der Dialog sagt
/// deshalb „eingetragen", nicht mehr.
class LmStudio extends KiWerkzeug {
  LmStudio(super.umgebung, {String? bruecke})
      : bruecke = bruecke ?? p.join(p.dirname(Platform.resolvedExecutable), brueckeExe);

  /// Die Brücke, die eingetragen wird: die neben der laufenden moocp.exe.
  final String bruecke;

  @override
  String get id => 'lmstudio';
  @override
  String get name => 'LM Studio (Bionic)';
  @override
  String get datenziel => 'Inhalte gehen an das eingestellte Modell, lokal oder in der Cloud';
  @override
  String get wirkt => 'Wirkt im Agenten Bionic, nicht im klassischen LM Studio.';

  Directory get heim => Directory(p.join(_heimPflicht(umgebung), '.lmstudio'));

  /// Bionics Liste der MCP-Server.
  File get liste => File(p.join(heim.path, 'apps', 'bionic', '.internal', 'ng-mcp.json'));

  @override
  Directory get skillOrdner => Directory(p.join(heim.path, 'skills'));

  /// Gefunden ist LM Studio, sobald Bionic einmal gelaufen ist: Erst dann
  /// gibt es seine Liste, und erst Bionic arbeitet mit Werkzeugen und Skills.
  /// Bionic gibt es nur unter Windows; auf dem Mac wird es nicht angeboten,
  /// denn die Brücke ist eine .exe.
  @override
  bool get gefunden => Platform.isWindows && Directory(p.join(heim.path, 'apps', 'bionic')).existsSync();

  @override
  bool get bedienbar => true;
  @override
  String? get hindernis => null;

  @override
  String verbindungText(Verbindung v) => switch (v) {
        Verbindung.aktuell => 'eingetragen',
        Verbindung.fehlt => 'nicht eingetragen',
        Verbindung.veraltet => 'der Eintrag „moodle" weicht ab, wird ersetzt',
        Verbindung.unlesbar => 'Liste der MCP-Server von Bionic nicht lesbar',
      };

  /// Liest Bionics Liste. Fehlt sie, ist sie leer; lässt sie sich nicht
  /// lesen, wirft es -- dann wird nichts geschrieben.
  Map<String, dynamic> _lesen() {
    if (!liste.existsSync()) return {'servers': []};
    final text = liste.readAsStringSync().trim();
    if (text.isEmpty) return {'servers': []};
    final d = jsonDecode(text);
    if (d is! Map || d['servers'] is! List) throw const FormatException('ng-mcp.json ohne servers');
    return d.cast<String, dynamic>();
  }

  /// Schreibt die Liste über eine Zwischendatei: Bionic beobachtet sie und
  /// soll nie eine halb geschriebene lesen. Eingerückt wie von Bionic selbst.
  void _schreiben(Map<String, dynamic> daten) {
    liste.parent.createSync(recursive: true);
    final zwischen = File('${liste.path}.moocp');
    zwischen.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(daten), flush: true);
    zwischen.renameSync(liste.path);
  }

  static bool _unser(Object? e) => e is Map && e['name'] == mcpName;

  /// Ob ein Eintrag so dasteht, wie [eintragen] ihn schreibt: ein lokaler
  /// Befehl, eine vorhandene [brueckeExe], [clientZeitlimit]. Welche Brücke,
  /// ist gleich -- installierte App und eigener Bau teilen Einstellungen und
  /// Port, die Brücke der einen erreicht auch die andere. Ob der Eintrag in
  /// Bionic eingeschaltet ist, entscheidet die Lehrkraft dort; eingetragen
  /// ist er so oder so.
  bool _passt(Map e) {
    final c = e['connection'];
    if (c is! Map) return false;
    final befehl = c['command'];
    return (c['type'] ?? 'stdio') == 'stdio' &&
        befehl is String &&
        p.basename(befehl).toLowerCase() == brueckeExe &&
        File(befehl).existsSync() &&
        c['timeoutMs'] == clientZeitlimit.inMilliseconds;
  }

  @override
  Verbindung verbindung(int port, String schluessel, {String name = mcpName}) {
    // Die Brücke kennt nur den Namen moodle.
    if (name != mcpName) return Verbindung.fehlt;
    try {
      final e = [for (final x in _lesen()['servers'] as List) if (_unser(x)) x as Map];
      if (e.isEmpty) return Verbindung.fehlt;
      return e.any(_passt) ? Verbindung.aktuell : Verbindung.veraltet;
    } catch (_) {
      return Verbindung.unlesbar;
    }
  }

  /// Ersetzt alle Einträge namens „moodle" durch die Brücke, wie `claude mcp
  /// remove` und `add` es bei Claude Code tun. Die id eines vorhandenen
  /// bleibt, damit Bionic, was es daran hängt, nicht verliert.
  @override
  Future<String?> eintragen(int port, String schluessel, {String name = mcpName}) async {
    if (name != mcpName) {
      return 'Die Brücke für Bionic kennt nur den Servernamen moodle; weitere Profile sind offen.';
    }
    if (!File(bruecke).existsSync()) return '$brueckeExe fehlt neben moocp.exe: moocp neu installieren.';
    try {
      final d = _lesen();
      final server = d['servers'] as List;
      final id = server.where(_unser).map((e) => (e as Map)['id']).whereType<String>().firstOrNull;
      d['servers'] = [
        ...server.where((e) => !_unser(e)),
        {
          'id': id ?? _neueId(),
          'name': mcpName,
          'enabled': true,
          'connection': {
            'type': 'stdio',
            'command': bruecke,
            'args': <String>[],
            'env': <String, String>{},
            'timeoutMs': clientZeitlimit.inMilliseconds,
          },
        },
      ];
      _schreiben(d);
      return null;
    } on FormatException {
      return 'Die Liste der MCP-Server von Bionic ist nicht lesbar und wurde nicht angefasst.';
    } catch (x) {
      return 'Bionics Liste nicht geschrieben (${x.runtimeType})';
    }
  }

  @override
  Future<String?> austragen({String name = mcpName}) async {
    if (name != mcpName) return null;
    try {
      final d = _lesen();
      final server = d['servers'] as List;
      if (!server.any(_unser)) return null;
      d['servers'] = [...server.where((e) => !_unser(e))];
      _schreiben(d);
      return null;
    } on FormatException {
      return 'Die Liste der MCP-Server von Bionic ist nicht lesbar und wurde nicht angefasst.';
    } catch (x) {
      return 'Bionics Liste nicht geschrieben (${x.runtimeType})';
    }
  }
}

/// Eine zufällige UUID (Version 4), wie Bionic sie als id seiner Einträge
/// führt.
String _neueId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Alle Werkzeuge, in der Reihenfolge, in der sie im Dialog stehen.
List<KiWerkzeug> alleWerkzeuge(Map<String, String> umgebung) =>
    [ClaudeCode(umgebung), CodexCli(umgebung), LmStudio(umgebung)];

/// Nur die, die auf diesem Rechner benutzt werden.
List<KiWerkzeug> gefundeneWerkzeuge(Map<String, String> umgebung) =>
    [for (final w in alleWerkzeuge(umgebung)) if (w.gefunden) w];

/// Die gewählten Skills, solange die Lehrkraft noch nichts gewählt hat: die
/// wählbaren, die in einem der Werkzeuge schon installiert sind. So entfernt
/// ein Update nichts, was jemand bisher benutzt hat; wer neu anfängt, hat
/// keinen.
Set<String> gewaehltVorgabe(Map<String, String> umgebung, Iterable<String> wahlNamen) => {
      for (final n in wahlNamen)
        if (gefundeneWerkzeuge(umgebung).any((w) => skillInstalliert(w, n))) n,
    };

/// Installiert heißt: SKILL.md ist da. Ein leerer Ordner, den ein laufendes
/// KI-Werkzeug offen hält, zählt nicht -- ohne SKILL.md lädt es nichts.
bool skillInstalliert(KiWerkzeug w, String name) => File(p.join(w.skillOrdner.path, name, 'SKILL.md')).existsSync();

// ---------------------------------------------------------------------------
// Die Skills
// ---------------------------------------------------------------------------

/// Woher ein Skill-Paket kommt. Die Herkunft muss jedes Paket angeben, damit
/// kein Paket stillschweigend als das der App gilt.
enum SkillHerkunft {
  /// Die App selbst: die Pakete von skills/build.py unter [skillAssets].
  app,

  /// Ein Plugin, dem die Lehrkraft zugestimmt hat (plugin/skills.dart).
  plugin,
}

final RegExp _skillName = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

/// Ob [name] als Name eines Skills taugt: Kleinbuchstaben, Ziffern und
/// einzelne Bindestriche, wie bei den Skills der App. Der Name wird zum
/// Ordnernamen im Skill-Ordner jedes KI-Werkzeugs; was hier durchgeht, kann
/// keinen Pfad nach außen bilden („..", Trenner, Laufwerk). Jeder Name, der
/// nicht von der App selbst kommt (Beschreibungsdatei eines Plugins, gemerkte
/// Namen in den Einstellungen), muss hier durch, bevor er einen Pfad bildet.
bool skillNameGueltig(String name) => name.length <= 64 && _skillName.hasMatch(name);

/// Ein Skill, wie ihn die Einrichtung installiert: Name, Herkunft und Dateien
/// (Pfad mit „/" relativ zum Skill-Ordner, Inhalt).
class SkillPaket {
  SkillPaket(this.name, this.dateien, {required this.herkunft, this.plugin});
  final String name;
  final Map<String, List<int>> dateien;
  final SkillHerkunft herkunft;

  /// Bei einem Skill eines Plugins dessen Anzeigename, für den Dialog.
  final String? plugin;

  /// Liest ein Paket von skills/build.py: ein ZIP mit dem Ordner `<name>/`.
  factory SkillPaket.ausZip(String name, List<int> zip, {required SkillHerkunft herkunft}) {
    final dateien = <String, List<int>>{};
    for (final f in ZipDecoder().decodeBytes(zip)) {
      if (!f.isFile || !f.name.startsWith('$name/')) continue;
      dateien[f.name.substring(name.length + 1)] = f.content;
    }
    return SkillPaket(name, dateien, herkunft: herkunft);
  }
}

/// Alle Skill-Pakete, die die Einrichtung kennt, aus jeder Herkunft: die
/// Einrichtung beim Start wie das Entfernen bei der Deinstallation
/// (`--claude-entfernen`) fragen hier und nirgends sonst, damit beide
/// dieselben Skills meinen.
///
/// Die Pakete der App sind die `*.skill` unter [skillAssets], der Name ist der
/// Dateiname ohne Endung. [appAssets] sind die Pfade aller Assets der App und
/// [laden] liest eines; beides reicht der Aufrufer herein (main.dart: das
/// AssetManifest und der rootBundle), weil dieser Code ohne Flutter laufen
/// muss -- die Brücke (mcp/bruecke.dart) bindet ihn ein.
Future<List<SkillPaket>> skillPaketeFinden({
  required Iterable<String> appAssets,
  required Future<List<int>> Function(String asset) laden,
}) async =>
    [
      for (final a in appAssets)
        if (a.startsWith(skillAssets) && a.endsWith('.skill'))
          SkillPaket.ausZip(p.basenameWithoutExtension(a), await laden(a), herkunft: SkillHerkunft.app),
    ];

class SkillStand {
  SkillStand({this.fehlend = 0, this.abweichend = 0, this.ueberzaehlig = 0, this.ordnerFehlt = false});
  final int fehlend;
  final int abweichend;
  final int ueberzaehlig;
  final bool ordnerFehlt;

  bool get aktuell => !ordnerFehlt && fehlend + abweichend + ueberzaehlig == 0;

  /// Für die Anzeige im Dialog, in Worten, die auch ohne Technikwissen
  /// verständlich sind -- ob eine Datei fehlt oder abweicht, ändert nichts
  /// daran, was zu tun ist.
  String get text {
    if (ordnerFehlt) return 'nicht installiert';
    if (aktuell) return 'aktuell';
    return 'muss aktualisiert werden';
  }
}

// Windows unterscheidet bei Pfaden nicht nach Groß- und Kleinschreibung.
String _schluessel(String rel) => rel.replaceAll('\\', '/').toLowerCase();

/// Die Dateien in einem installierten Skill. Verknüpfungen darin folgt die
/// App nicht: Was hinter ihnen liegt, gehört nicht zum Skill, und Aufräumen
/// löschte sonst dort.
Map<String, File> _vorhandene(Directory ziel) => {
      for (final f in ziel.listSync(recursive: true, followLinks: false).whereType<File>())
        _schluessel(p.relative(f.path, from: ziel.path)): f,
    };

/// Ob unter [pfad] ein echter Ordner liegt, keine Verknüpfung und keine Datei.
bool _echterOrdner(String pfad) =>
    FileSystemEntity.typeSync(pfad, followLinks: false) == FileSystemEntityType.directory;

bool _gleich(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Vergleicht den installierten Skill Datei für Datei mit dem Paket. Am
/// Inhalt, nicht an einer Versionsnummer: So fällt auch eine Handänderung
/// im installierten Ordner auf.
SkillStand skillVergleichen(SkillPaket paket, Directory ziel) {
  if (!ziel.existsSync()) return SkillStand(ordnerFehlt: true);
  final da = _vorhandene(ziel);
  var fehlend = 0, abweichend = 0;
  final gesehen = <String>{};
  for (final e in paket.dateien.entries) {
    final k = _schluessel(e.key);
    gesehen.add(k);
    final f = da[k];
    if (f == null) {
      fehlend++;
    } else if (!_gleich(f.readAsBytesSync(), e.value)) {
      abweichend++;
    }
  }
  return SkillStand(
      fehlend: fehlend, abweichend: abweichend, ueberzaehlig: da.keys.where((k) => !gesehen.contains(k)).length);
}

/// Installiert einen Skill so, wie ihn das Paket enthält. Datei für Datei
/// statt den Ordner zu löschen: Ein laufendes KI-Werkzeug hält den
/// Skill-Ordner offen, Löschen scheitert dann (WinError 32). Dateien, die
/// nicht zum Paket gehören (etwa aus der alten Browser-Version), werden
/// einzeln entfernt, leer gewordene Unterordner danach. Liefert die Pfade,
/// die sich nicht entfernen ließen.
///
/// Ist [ziel] selbst eine Verknüpfung, schreibt es durch sie hindurch: Für die
/// Skills der App ist das gewollt (ein Entwickler legt den Skill-Ordner etwa
/// auf das Repository und bekommt dort die Dateien des Pakets); bei Skills von
/// Plugins kommt es nicht dazu, denn dort gilt eine Verknüpfung an der Stelle
/// des Skill-Ordners als fremder Ordner ([einrichtungPruefen]). Beim
/// Auflisten und Aufräumen darin folgt es keiner Verknüpfung ([_vorhandene]).
List<String> skillInstallieren(SkillPaket paket, Directory ziel) {
  ziel.createSync(recursive: true);
  final gewollt = <String>{};
  for (final e in paket.dateien.entries) {
    final f = File(p.joinAll([ziel.path, ...e.key.split('/')]));
    // Steht an der Stelle einer Datei des Pakets eine Verknüpfung, schriebe
    // die App sonst durch sie hindurch; entfernt wird nur die Verknüpfung.
    if (FileSystemEntity.isLinkSync(f.path)) Link(f.path).deleteSync();
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(e.value, flush: true);
    gewollt.add(_schluessel(e.key));
  }
  return _aufraeumen(ziel, gewollt);
}

/// Entfernt einen installierten Skill: jede Datei einzeln, dann den Ordner,
/// wenn er leer ist -- ein laufendes KI-Werkzeug hält ihn offen, leer schadet
/// er nicht. Liefert die Dateien, die sich nicht löschen ließen. Ist der
/// Skill-Ordner selbst eine Verknüpfung, entfernt es nur sie, nie, was
/// dahinter liegt.
List<String> skillEntfernen(Directory ziel) {
  if (FileSystemEntity.isLinkSync(ziel.path)) {
    try {
      Link(ziel.path).deleteSync();
      return const [];
    } on FileSystemException {
      return [p.basename(ziel.path)];
    }
  }
  if (!ziel.existsSync()) return const [];
  final geblieben = _aufraeumen(ziel, const {});
  try {
    if (ziel.listSync().isEmpty) ziel.deleteSync();
  } on FileSystemException {
    // bleibt leer stehen
  }
  return geblieben;
}

/// Löscht in [ziel] jede Datei, die nicht in [behalten] steht, einzeln, dann
/// die leer gewordenen Unterordner. Liefert die Dateien, die sich nicht
/// löschen ließen. Verknüpfungen folgt es nicht; es entfernt sie selbst, nie,
/// was dahinter liegt.
List<String> _aufraeumen(Directory ziel, Set<String> behalten) {
  final geblieben = <String>[];
  for (final e in _vorhandene(ziel).entries) {
    if (behalten.contains(e.key)) continue;
    try {
      e.value.deleteSync();
    } on FileSystemException {
      geblieben.add(e.key);
    }
  }
  for (final l in ziel.listSync(recursive: true, followLinks: false).whereType<Link>()) {
    try {
      l.deleteSync();
    } on FileSystemException {
      geblieben.add(_schluessel(p.relative(l.path, from: ziel.path)));
    }
  }
  final ordner = ziel.listSync(recursive: true, followLinks: false).whereType<Directory>().toList()
    ..sort((a, b) => b.path.length.compareTo(a.path.length));
  for (final d in ordner) {
    try {
      if (d.listSync().isEmpty) d.deleteSync();
    } on FileSystemException {
      // bleibt eben stehen
    }
  }
  return geblieben;
}

// ---------------------------------------------------------------------------
// Entfernen, beim Deinstallieren
// ---------------------------------------------------------------------------

/// Der Schalter, mit dem die Deinstallation (installer/moocp.nsi) die
/// App aufruft: Einrichtung entfernen, ohne Fenster, dann enden (main.dart).
/// Steht auch in windows/runner/main.cpp: Dieser Aufruf läuft auch neben
/// einer laufenden App. Der alte Name bleibt, damit die Deinstallation einer
/// älteren Version weiter wirkt.
const claudeEntfernenSchalter = '--claude-entfernen';

/// Auskünfte der App über stdout, ohne Fenster (main.dart): die
/// Werkzeugliste für die Brücke (mcp/bruecke.dart) und die Version. Stehen
/// auch in windows/runner/main.cpp: ohne Einzelstart-Sperre und ohne
/// Konsole.
const werkzeuglisteSchalter = '--werkzeugliste';
const versionSchalter = '--version';

/// Die Brücke für KI-Werkzeuge, die MCP nur über stdio sprechen
/// (mcp/bruecke.dart): ein eigenes Programm neben moocp.exe, gebaut von
/// windows/bruecke.cmake.
const brueckeExe = 'moocp-bruecke.exe';

/// Was nach dem Entfernen noch da ist.
class Entfernt {
  Entfernt({required this.eintragBleibt, required this.dateienBleiben});

  /// Werkzeuge, in denen der Eintrag „moodle" noch steht.
  final List<String> eintragBleibt;

  /// Dateien der Skills, die noch da sind, mit Werkzeug davor.
  final List<String> dateienBleiben;

  /// Der Exit-Code für die Deinstallation: 0 alles entfernt, Bit 1 ein
  /// Eintrag „moodle" steht noch, Bit 2 Dateien der Skills sind noch da.
  /// Leere Skill-Ordner zählen nicht: Ohne SKILL.md lädt kein Werkzeug etwas.
  int get code => (eintragBleibt.isEmpty ? 0 : 1) | (dateienBleiben.isEmpty ? 0 : 2);
}

/// Entfernt, was die App in den KI-Werkzeugen eingerichtet hat: die
/// Einträge [mcpNamen] (je Instanzprofil einer, E31) und die Skills
/// der App [skills] in jedem Werkzeug, dazu die gemerkten Ordner der Plugins
/// [pluginOrdner] ([pluginSkillsGemerkt]) nur in ihrem Werkzeug. Danach wird
/// nachgesehen, statt dem Ergebnis zu glauben. Ein Name, der kein Skill-Name
/// sein kann ([skillNameGueltig]), bildet keinen Pfad und wird übergangen,
/// ebenso ein fremder Ordner aus [auslassen] ([fremderOrdner]).
Future<Entfernt> einrichtungEntfernen({
  required Map<String, String> umgebung,
  required List<String> skills,
  Set<String> pluginOrdner = const {},
  List<String> mcpNamen = const [mcpName],
  List<KiWerkzeug>? werkzeuge,
  Set<String> auslassen = const {},
}) async {
  final geblieben = <String>[];
  final eintraege = <String>[];
  for (final w in werkzeuge ?? alleWerkzeuge(umgebung)) {
    for (final eintrag in mcpNamen) {
      await w.austragen(name: eintrag);
      if (await _eintragDa(w, eintrag)) {
        eintraege.add(mcpNamen.length > 1 ? '${w.id} ($eintrag)' : w.id);
      }
    }
    final hier = {
      ...skills,
      for (final e in pluginOrdner)
        if (werkzeugSkillGueltig(e) && e.split('/')[0] == w.id) e.split('/')[1],
    };
    for (final name in hier.where(skillNameGueltig)) {
      if (auslassen.contains(fremderOrdner(w.id, name))) continue;
      geblieben.addAll(skillEntfernen(Directory(p.join(w.skillOrdner.path, name))).map((f) => '${w.id}: $name/$f'));
    }
  }
  return Entfernt(eintragBleibt: eintraege, dateienBleiben: geblieben);
}

/// Entfernt den Eintrag eines gelöschten Profils in jedem Werkzeug und liest
/// danach nach. Was stehen bleibt, kommt als Zeile „Werkzeug (Name)" zurück,
/// damit die Lehrkraft es von Hand entfernen kann.
Future<List<String>> profilEintragEntfernen({
  required Map<String, String> umgebung,
  required String name,
  List<KiWerkzeug>? werkzeuge,
}) async {
  final geblieben = <String>[];
  for (final w in werkzeuge ?? alleWerkzeuge(umgebung)) {
    if (!await _eintragDa(w, name)) continue;
    await w.austragen(name: name);
    if (await _eintragDa(w, name)) geblieben.add('${w.name} ($name)');
  }
  return geblieben;
}

/// Ob der Eintrag [name] (noch) steht, gleich mit welcher Adresse. Einen
/// halb geschriebenen Stand liest es kurz danach noch einmal; bleibt er
/// unlesbar, zählt der Eintrag als vorhanden.
Future<bool> _eintragDa(KiWerkzeug w, [String name = mcpName]) async {
  for (var i = 0; i < 3; i++) {
    final v = w.verbindung(0, '', name: name);
    if (v != Verbindung.unlesbar) return v != Verbindung.fehlt;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return true;
}

// ---------------------------------------------------------------------------
// Alles zusammen
// ---------------------------------------------------------------------------

/// Der Stand eines Werkzeugs: was dort fehlt und was „Installieren" dort tun
/// würde.
class Werkzeugstand {
  Werkzeugstand({
    required this.werkzeug,
    required this.gewaehlt,
    required this.verbindung,
    required this.skills,
    required this.stand,
    required this.entfernen,
  });

  final KiWerkzeug werkzeug;

  /// Ob die Lehrkraft dieses Werkzeug eingerichtet haben will.
  final bool gewaehlt;

  final Verbindung verbindung;

  /// Die Skills, die hier installiert sein sollen.
  final List<SkillPaket> skills;

  /// Stand je Skill, auch der nicht gewollten.
  final Map<String, SkillStand> stand;

  /// Skills, die hier weg sollen: die abgewählten, bei einem abgewählten
  /// Werkzeug alle, und in jedem Werkzeug die verwaisten Skills von Plugins
  /// (`verwaist` in [einrichtungPruefen]).
  final Set<String> entfernen;

  bool get verbunden => verbindung == Verbindung.aktuell;

  /// Ob hier alles steht, was es braucht -- die Bedingung dafür, dass die
  /// App überhaupt läuft (eines reicht).
  bool get fertig => gewaehlt && verbunden && skills.every((s) => stand[s.name]!.aktuell) && entfernen.isEmpty;

  /// Ob die App einen Eintrag in diesem Werkzeug selbst entfernen kann
  /// (Claude Code nur mit claude.exe).
  bool get austragbar => werkzeug.bedienbar;

  /// Ob „Installieren" hier etwas zu tun hat. Bei einem abgewählten Werkzeug
  /// zählt ein Eintrag nur, wenn die App ihn auch entfernen kann; sonst stünde
  /// der Dialog bei jedem Start da, und niemand könnte ihn mit einem Klick
  /// erledigen. Der Dialog sagt trotzdem, was von Hand zu tun ist.
  bool get brauchtEtwas => gewaehlt
      ? !fertig
      : (verbindung != Verbindung.fehlt && austragbar) || entfernen.isNotEmpty;

  /// Ob „Installieren" hier etwas bewirken kann: die Verbindung, wenn die
  /// App sie selbst einträgt, die Skills immer.
  bool get machbar =>
      (gewaehlt ? !verbunden && werkzeug.bedienbar : verbindung != Verbindung.fehlt && austragbar) ||
      skills.any((s) => !stand[s.name]!.aktuell) ||
      entfernen.isNotEmpty;
}

class Einrichtungsstand {
  Einrichtungsstand({
    required this.werkzeuge,
    required this.skills,
    this.wahlSkills = const {},
    this.gewaehlt = const {},
    this.skillFehler = const [],
    this.skillFehlerNeu = false,
    this.fremdeOrdner = const {},
    this.konfliktStand = const {},
  });

  /// Die fremden Ordner mit dem Namen eines Plugin-Skills ([einrichtungPruefen],
  /// [fremderOrdner]): Die App merkt sie sich (Einstellungen.fremdeSkillOrdner)
  /// und gibt sie der nächsten Prüfung mit.
  final Set<String> fremdeOrdner;

  /// Je fremdem Ordner ein Stand für Einstellungen.skillFehlerGesehen; ein
  /// gesehener öffnet den Dialog nicht noch einmal.
  final Set<String> konfliktStand;

  /// Je gefundenes KI-Werkzeug ein Stand; leer, wenn keines gefunden wurde.
  final List<Werkzeugstand> werkzeuge;

  /// Alle Skills, die die Einrichtung kennt ([skillPaketeFinden]).
  final List<SkillPaket> skills;

  /// Die wählbaren Skills mit dem Satz, der im Dialog dabeisteht; alle anderen
  /// in [skills] sind immer dabei.
  final Map<String, String> wahlSkills;

  /// Die gewählten unter den [wahlSkills].
  final Set<String> gewaehlt;

  /// Skill-Pakete von Plugins, die nicht installiert werden, weil sie sich
  /// nicht lesen lassen oder eine Regel brechen, und Plugin-Skills, die in
  /// einem Werkzeug wegen eines fremden Ordners gleichen Namens fehlen: je
  /// eines ein Satz mit Plugin und Grund, ohne Inhalte (E11). Sie halten
  /// nichts auf; der Dialog nennt sie nur.
  final List<String> skillFehler;

  /// Ob unter [skillFehler] etwas ist, das die Lehrkraft noch nicht gesehen
  /// hat (Einstellungen.skillFehlerGesehen): Dann erscheint der Dialog beim
  /// Start auch, wenn sonst alles eingerichtet ist.
  final bool skillFehlerNeu;

  /// Was installiert sein soll: jeder Skill, der nicht wählbar ist, und die
  /// gewählten.
  List<SkillPaket> get gewollt => _gewollt(skills, wahlSkills, gewaehlt);

  /// Ob mindestens ein Werkzeug fertig eingerichtet ist. Nur dann läuft die
  /// App (einrichtung_dialog.dart): Für Claude, Codex und LM Studio
  /// zusammen gilt, was E13 für Claude Code allein sagte -- einen Zustand
  /// „die App läuft, aber kein KI-Werkzeug kann mit ihr arbeiten" gibt es
  /// nicht.
  bool get bereit => werkzeuge.any((w) => w.fertig);

  /// Ob an Verbindung oder Skills noch etwas zu tun ist.
  bool get brauchtEinrichtung => !bereit || werkzeuge.any((w) => w.brauchtEtwas);

  /// Ob der Dialog erscheinen muss: weil etwas zu tun ist oder weil ein
  /// unbrauchbares Skill-Paket eines Plugins noch nicht gesehen ist
  /// ([skillFehlerNeu]).
  bool get brauchtEtwas => brauchtEinrichtung || skillFehlerNeu;

  /// Ob „Installieren" etwas bewirken kann.
  bool get einrichtbar => werkzeuge.any((w) => w.brauchtEtwas && w.machbar);

  /// Ob in irgendeinem KI-Werkzeug schon etwas von der App steht: ein Eintrag
  /// (auch ein veralteter) oder der Ordner eines Skills. Dann heißt der Knopf
  /// im Dialog „Aktualisieren" statt „Installieren" -- er bringt auf Stand
  /// oder entfernt, statt zum ersten Mal einzurichten.
  bool get schonEingerichtet => werkzeuge.any(
        (w) => w.verbindung != Verbindung.fehlt || w.stand.values.any((s) => !s.ordnerFehlt),
      );
}

/// Was installiert sein soll: jeder Skill, der nicht in [wahlSkills] steht, und
/// die gewählten.
List<SkillPaket> _gewollt(List<SkillPaket> skills, Map<String, String> wahlSkills, Set<String> gewaehlt) =>
    [for (final s in skills) if (!wahlSkills.containsKey(s.name) || gewaehlt.contains(s.name)) s];

/// Prüft jedes gefundene KI-Werkzeug. [skills] sind alle Skills, die es gibt
/// ([skillPaketeFinden] und die der Plugins); [wahlSkills] die darunter
/// wählbaren mit dem Satz für den Dialog, [gewaehlt] die davon gewählten. Ein
/// Skill, der nicht in [wahlSkills] steht, ist immer gewollt.
///
/// [verwaist] sind Skills, die die App für ein Plugin installiert hat, das
/// abgelehnt oder nicht mehr da ist (plugin/skills.dart, verwaisteSkills): Sie
/// werden in jedem Werkzeug, in dem sie stehen, zum Entfernen angeboten, auch
/// in einem abgewählten. [skillFehler] reicht der Dialog nur weiter;
/// [skillFehlerNeu] sagt, ob darunter Ungesehenes ist.
///
/// Fremde Ordner ([fremdeOrdner]): Im Skill-Ordner eines KI-Werkzeugs kann
/// schon ein Ordner mit dem Namen eines Plugin-Skills liegen, den nicht moocp
/// angelegt hat. Ihn überschreibt die Einrichtung nicht und räumt ihn nicht
/// auf; der Dialog nennt ihn, ohne die Einrichtung aufzuhalten, wie ein
/// unbrauchbares Paket. Fremd ist ein Ordner, wenn er vom Paket abweicht und
/// moocp ihn nicht in genau diesem Werkzeug installiert hat ([pluginSkills],
/// je Werkzeug, [werkzeugSkill], [pluginSkillsGemerkt]), oder wenn er in diesem Werkzeug
/// schon einmal fremd war ([fremd], die Liste aus der letzten Prüfung). Ein
/// verwaister Skill kommt nur dort zum Entfernen, wo moocp ihn installiert
/// hat. Eine Verknüpfung an seiner Stelle ist immer fremd; die App folgt ihr
/// nicht. Fremd ist er nicht mehr, wenn er fehlt
/// oder genau dem Paket entspricht. Für die Skills der App ändert sich nichts.
/// [gesehen] sind die Stände, die die Lehrkraft gesehen hat
/// (Einstellungen.skillFehlerGesehen); ein neuer fremder Ordner öffnet den
/// Dialog wie ein neues unbrauchbares Paket.
Future<Einrichtungsstand> einrichtungPruefen({
  required Map<String, String> umgebung,
  required int port,
  required String schluessel,
  String name = mcpName,
  required List<SkillPaket> skills,
  required Map<String, String> wahlSkills,
  Set<String> abgewaehlt = const {},
  Set<String> gewaehlt = const {},
  Set<String> verwaist = const {},
  Set<String> pluginSkills = const {},
  Set<String> fremd = const {},
  Set<String> gesehen = const {},
  List<String> skillFehler = const [],
  bool skillFehlerNeu = false,
  List<KiWerkzeug>? gefunden,
}) async {
  final gewollt = _gewollt(skills, wahlSkills, gewaehlt);
  // Was als Paket da ist, entscheidet die Wahl, nicht die Liste der
  // Verwaisten; ein Name, der kein Skill-Name ist, bildet keinen Pfad.
  final weg = [
    for (final n in verwaist)
      if (skillNameGueltig(n) && !skills.any((s) => s.name == n)) n,
  ];
  final liste = gefunden ?? gefundeneWerkzeuge(umgebung);
  // Gewählt ist jedes gefundene Werkzeug, das die Lehrkraft nicht abgewählt
  // hat. Wer ein KI-Werkzeug auf dem Rechner hat, soll damit auch in Moodle
  // arbeiten können, ohne es erst zu erlauben -- auch eines, das erst nach
  // der App dazukam. Abwählen kann es jeder im Dialog, und die Wahl bleibt.
  final gewaehlteWerkzeuge = {for (final w in liste) if (!abgewaehlt.contains(w.id)) w.id};
  final fremdeOrdner = <String>{};
  final konflikte = <String>[];
  final werkzeuge = <Werkzeugstand>[];
  // Ob moocp den Ordner [n] in [w] für ein Plugin installiert hat (je
  // Werkzeug gemerkt).
  bool eigen(String w, String n) => pluginSkills.contains(werkzeugSkill(w, n));
  for (final w in liste) {
    final stand = {for (final s in skills) s.name: skillVergleichen(s, Directory(p.join(w.skillOrdner.path, s.name)))};
    bool istFremd(SkillPaket s) {
      if (s.herkunft != SkillHerkunft.plugin) return false;
      final pfad = p.join(w.skillOrdner.path, s.name);
      final typ = FileSystemEntity.typeSync(pfad, followLinks: false);
      if (typ == FileSystemEntityType.notFound) return false;
      if (typ != FileSystemEntityType.directory) return true;
      if (stand[s.name]!.aktuell) return false;
      return !eigen(w.id, s.name) || fremd.contains(fremderOrdner(w.id, s.name));
    }

    final fremdHier = {for (final s in skills) if (istFremd(s)) s.name};
    for (final s in skills.where((s) => fremdHier.contains(s.name))) {
      fremdeOrdner.add(fremderOrdner(w.id, s.name));
      konflikte.add(
        '${w.name}: Den Ordner ${s.name} im Skill-Ordner gibt es schon, und er stammt nicht von moocp. Der Skill '
        '${s.name} des Plugins „${s.plugin ?? s.name}“ wird dort nicht installiert; der Ordner bleibt, wie er ist.',
      );
    }
    werkzeuge.add(
      Werkzeugstand(
        werkzeug: w,
        gewaehlt: gewaehlteWerkzeuge.contains(w.id),
        verbindung: w.verbindung(port, schluessel, name: name),
        skills: gewaehlteWerkzeuge.contains(w.id) ? [for (final s in gewollt) if (!fremdHier.contains(s.name)) s] : const [],
        stand: stand,
        entfernen: {
          for (final s in skills)
            if (!fremdHier.contains(s.name) &&
                skillInstalliert(w, s.name) &&
                (!gewaehlteWerkzeuge.contains(w.id) || !gewollt.contains(s)))
              s.name,
          // Verwaiste Plugin-Skills nur aus einem echten Ordner, den moocp in
          // diesem Werkzeug installiert hat und der nicht als fremd bekannt
          // ist.
          for (final n in weg)
            if (skillInstalliert(w, n) &&
                eigen(w.id, n) &&
                _echterOrdner(p.join(w.skillOrdner.path, n)) &&
                !fremd.contains(fremderOrdner(w.id, n)))
              n,
        },
      ),
    );
  }
  final konfliktStand = {for (final k in fremdeOrdner) 'fremd:$k'};
  return Einrichtungsstand(
    werkzeuge: werkzeuge,
    skills: skills,
    wahlSkills: wahlSkills,
    gewaehlt: gewaehlt,
    skillFehler: [...skillFehler, ...konflikte],
    skillFehlerNeu: (skillFehlerNeu && skillFehler.isNotEmpty) || !gesehen.containsAll(konfliktStand),
    fremdeOrdner: fremdeOrdner,
    konfliktStand: konfliktStand,
  );
}

/// Ein Ordner im Skill-Ordner eines KI-Werkzeugs, wie er in den Einstellungen
/// steht: Werkzeug und Skill-Name, `<Werkzeug>/<Name>`
/// (Einstellungen.pluginSkillOrdner, Einstellungen.fremdeSkillOrdner).
String werkzeugSkill(String werkzeug, String skill) => '$werkzeug/$skill';

/// Wie ein fremder Ordner ([einrichtungPruefen]) in den Einstellungen steht
/// ([werkzeugSkill]).
String fremderOrdner(String werkzeug, String skill) => werkzeugSkill(werkzeug, skill);

/// Ob [eintrag] die Form von [werkzeugSkill] hat: eine Werkzeug-Kennung aus
/// Kleinbuchstaben und Ziffern und ein gültiger Skill-Name. Aus einem solchen
/// Eintrag wird ein Pfad zum Löschen; anderes fällt beim Lesen weg.
bool werkzeugSkillGueltig(String eintrag) {
  final teile = eintrag.split('/');
  return teile.length == 2 && RegExp(r'^[a-z0-9]+$').hasMatch(teile[0]) && skillNameGueltig(teile[1]);
}

/// Die Skill-Namen in Einträgen der Form [werkzeugSkill].
Set<String> skillNamen(Iterable<String> eintraege) => {
  for (final e in eintraege)
    if (werkzeugSkillGueltig(e)) e.split('/')[1],
};

/// Die Ordner von Plugin-Skills, die die App in den KI-Werkzeugen installiert
/// hat, je Werkzeug ([werkzeugSkill], Einstellungen.pluginSkillOrdner), nach
/// der Prüfung [stand]: Dazu kommt jeder Skill eines Plugins, der in einem
/// Werkzeug genau so steht wie im Paket -- so installiert ihn die
/// Einrichtung --, und es bleibt jeder gemerkte, der in seinem Werkzeug noch
/// installiert ist. Vergessen wird ein Eintrag erst, wenn der Ordner dort
/// fehlt. Nur was hier steht, entfernt die App später ungefragt bei der
/// Deinstallation oder bietet es zum Entfernen an, wenn das Plugin fort ist,
/// und nur in diesem Werkzeug: Ein fremder Ordner gleichen Namens, der vom
/// Paket abweicht, kommt nicht hinein, auch wenn moocp denselben Skill in
/// einem anderen Werkzeug installiert hat.
Set<String> pluginSkillsGemerkt({
  required Set<String> gemerkt,
  required Einrichtungsstand stand,
  required List<KiWerkzeug> werkzeuge,
}) =>
    {
      for (final ws in stand.werkzeuge)
        for (final s in stand.skills)
          if (s.herkunft == SkillHerkunft.plugin && (ws.stand[s.name]?.aktuell ?? false))
            werkzeugSkill(ws.werkzeug.id, s.name),
      for (final e in gemerkt)
        if (werkzeugSkillGueltig(e) &&
            werkzeuge.any((w) => w.id == e.split('/')[0] && skillInstalliert(w, e.split('/')[1])))
          e,
    };
