// Die Verbindung der App zu einem laufenden Plugin (E35): moocp ist der
// MCP-Client, das Plugin der Server auf 127.0.0.1. Hier steht der Vertrag der
// Schnittstelle, soweit er über MCP läuft -- was beim initialize mitgeht, was
// an jedem Werkzeugaufruf hängt, welche Werkzeugnamen gelten und was von einer
// Antwort an die KI weitergeht. Den Prozess startet und beendet
// laufende_plugins.dart; ein Entwicklungs-Plugin, das schon läuft, hängt
// entwicklung.dart an.

import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart';

import '../mcp/werkzeugquelle.dart';
import '../moodle/moodle_zugang.dart' show MoodleFehler;
import 'beschreibung.dart';
import 'schnittstelle.dart';

export '../plattform/kindprozess.dart' show schluesselVariable;
export 'schnittstelle.dart' show schnittstellenVersion;

/// Die Schlüssel in `_meta` eines Werkzeugaufrufs: das Instanzprofil (sein
/// technischer Name, `Profil.mcpName`) und das Token dieses Aufrufs.
const metaProfil = 'moocp/profil';
const metaAufruf = 'moocp/aufruf';

/// Höchstlänge eines Werkzeugnamens: Mit `mcp__<Profil>__` davor bleibt der
/// Name, den ein KI-Werkzeug sieht, bei einem Profilnamen bis 17 Zeichen (etwa
/// `moodle`; so lang ist höchstens der eines neuen Profils,
/// Profil.neuerMcpNameHoechstens) in den 64 Zeichen, die Claude Code zulässt.
/// Bei einem längeren Profilnamen prüft [werkzeugnameZuLang] je Werkzeug.
const werkzeugnameHoechstens = 40;

/// Die Zeichen eines Werkzeugnamens: Buchstaben, Ziffern, „_“ und „-“. MCP
/// selbst ließe auch den Punkt zu, Claude Code nimmt ihn in Werkzeugnamen
/// aber nicht an; ein Plugin soll in jedem KI-Werkzeug laufen (E21).
final _werkzeugnameZeichen = RegExp(r'^[A-Za-z0-9_-]+$');

/// Was beim initialize unter `capabilities.experimental.moocp` mitgeht: die
/// Version der Schnittstelle und die Adresse der App für Plugins
/// (app_adresse.dart), unter der das Plugin Protokoll, Arbeitsordner und
/// eingebaute Werkzeuge erreicht; ohne Adresse nur die Version (Tests).
Map<String, dynamic> vertragBeimInitialize({Uri? adresse}) => {
  'schnittstelle': schnittstellenVersion,
  'adresse': ?adresse?.toString(),
};

/// Ein Werkzeugfehler, dessen Text das Plugin geschrieben hat (`isError`).
/// Er geht an die KI wie eine Antwort und deshalb, wie sie, erst durch die
/// Datenschutzprüfung (laufende_plugins.dart); die Fehler, die moocp selbst
/// meldet, sind [MoodleFehler].
class PluginErgebnisFehler extends MoodleFehler {
  PluginErgebnisFehler(super.meldung);
}

/// Das Plugin kam nicht hoch: keine Antwort binnen der Startfrist, oder sein
/// Programm endete dabei. Anders als ein Verstoß gegen die Regeln kann hier
/// ein zweiter Versuch helfen (laufende_plugins.dart).
class PluginStartFehler extends PluginFehler {
  const PluginStartFehler(super.grund);
}

/// Prüft die Werkzeugnamen eines Plugins mit [kurzname] gegen die Regeln und
/// gegen [vergeben] (eingebaute Werkzeuge und die anderer Plugins). Wirft
/// [PluginFehler] mit dem ersten Verstoß. Der Grund nennt die Art des
/// Verstoßes, nie den Namen: Er kommt vom laufenden Plugin, steht gleich im
/// Protokoll und ist noch nicht durch die Datenschutzprüfung gegangen.
void werkzeugnamenPruefen(
  Iterable<String> namen,
  String kurzname,
  Set<String> vergeben,
) {
  final gesehen = <String>{};
  for (final name in namen) {
    if (!_werkzeugnameZeichen.hasMatch(name)) {
      throw const PluginFehler(
        'Ein Werkzeug hat Zeichen im Namen, die nicht erlaubt sind '
        '(erlaubt sind Buchstaben, Ziffern, „_“ und „-“).',
      );
    }
    if (!name.startsWith('${kurzname}_')) {
      throw PluginFehler('Ein Werkzeug beginnt nicht mit „${kurzname}_“.');
    }
    if (name.length > werkzeugnameHoechstens) {
      throw const PluginFehler('Der Name eines Werkzeugs ist länger als $werkzeugnameHoechstens Zeichen.');
    }
    if (vergeben.contains(name)) {
      throw const PluginFehler('Ein Werkzeug trägt einen Namen, den es bei moocp oder einem anderen Plugin schon gibt.');
    }
    if (!gesehen.add(name)) throw const PluginFehler('Zwei Werkzeuge tragen denselben Namen.');
  }
}

/// So lang darf der Name eines Werkzeugs sein, wie ein KI-Werkzeug ihn sieht
/// (`mcp__<Profil>__<Werkzeug>`): mehr lässt Claude Code nicht zu.
const mcpWerkzeugnameHoechstens = 64;

/// Ob das Werkzeug [werkzeug] im Server des Profils mit dem technischen Namen
/// [mcpName] zu lang wäre ([mcpWerkzeugnameHoechstens]). Der Kurzname eines
/// Plugins ist so begrenzt, dass es bei einem Profilnamen bis 17 Zeichen immer
/// passt; so lang ist höchstens der technische Name eines neuen Profils
/// (Profil.neuerMcpName). Ein Profil, das schon einen längeren hat, behält
/// ihn; dort fehlt ein zu langes Werkzeug (laufende_plugins.dart,
/// werkzeugliste.dart).
bool werkzeugnameZuLang(String mcpName, String werkzeug) =>
    'mcp__${mcpName}__$werkzeug'.length > mcpWerkzeugnameHoechstens;

/// Eine Verbindung zu einem Plugin, mit seiner Werkzeugliste vom Start.
class PluginVerbindung {
  PluginVerbindung._(this._client, this._transport, this.werkzeuge);

  final McpClient _client;
  final StreamableHttpClientTransport _transport;

  /// Die Werkzeuge, wie das Plugin sie beim Start nannte. Die Liste gilt für
  /// diese Verbindung, also bis die App oder das Plugin endet; ein späteres
  /// `tools/list_changed` beachtet sie nicht.
  final List<WerkzeugBeschreibung> werkzeuge;

  /// Verbindet sich mit dem Plugin auf [port] und liest seine Werkzeuge.
  /// Ein Plugin, das noch nicht lauscht, wird bis [frist] immer wieder
  /// versucht; ebenso, solange [weiter] nicht false liefert (der Prozess
  /// lebt noch). Danach, bei verletzten Namensregeln ([werkzeugnamenPruefen])
  /// oder bei einer unbrauchbaren Werkzeugliste wirft es [PluginFehler].
  /// [adresse] ist die Adresse der App für Plugins, die beim initialize
  /// mitgeht ([vertragBeimInitialize]).
  static Future<PluginVerbindung> verbinden({
    required int port,
    required String schluessel,
    required String kurzname,
    required Set<String> vergeben,
    required Duration frist,
    bool Function()? weiter,
    Uri? adresse,
  }) async {
    final ende = DateTime.now().add(frist);
    final zeitGrund = PluginStartFehler(
      'Das Plugin hat nicht binnen ${frist.inSeconds} Sekunden auf die Verbindung geantwortet.',
    );
    while (true) {
      final rest = ende.difference(DateTime.now());
      if (rest <= Duration.zero) throw zeitGrund;
      if (weiter != null && !weiter()) {
        throw const PluginStartFehler('Das Programm des Plugins hat sich beim Start beendet.');
      }
      final transport = StreamableHttpClientTransport(
        Uri.parse('http://127.0.0.1:$port/mcp'),
        opts: StreamableHttpClientTransportOptions(
          requestInit: {
            'headers': {'Authorization': 'Bearer $schluessel'},
          },
          // Bricht die Verbindung ab, versucht moocp sie nicht im Hintergrund
          // neu: Ein Aufruf meldet dann den Fehler.
          reconnectionOptions: const StreamableHttpReconnectionOptions(
            maxReconnectionDelay: 1000,
            initialReconnectionDelay: 1000,
            reconnectionDelayGrowFactor: 1,
            maxRetries: 0,
          ),
        ),
      );
      final client = McpClient(
        const Implementation(name: 'moocp', version: '1'),
        options: McpClientOptions(
          // Der Ablauf mit initialize: Nur dort gibt es die capabilities, in
          // denen der Vertrag mitgeht.
          protocol: McpProtocol.legacy,
          capabilities: ClientCapabilities(
            experimental: {'moocp': vertragBeimInitialize(adresse: adresse)},
          ),
        ),
      );
      try {
        await client.connect(transport).timeout(rest);
      } catch (_) {
        // Lauscht das Plugin noch nicht, oder antwortet es nicht: nach einer
        // kurzen Pause wieder. Was es genau war, sagt nichts über das Plugin,
        // das die Lehrkraft lesen könnte.
        await _schliessen(client, transport);
        if (DateTime.now().add(const Duration(milliseconds: 100)).isAfter(ende)) {
          throw zeitGrund;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        continue;
      }
      try {
        final werkzeuge = await _werkzeugeLesen(client).timeout(
          ende.difference(DateTime.now()) > Duration.zero
              ? ende.difference(DateTime.now())
              : Duration.zero,
        );
        werkzeugnamenPruefen([for (final w in werkzeuge) w.name], kurzname, vergeben);
        return PluginVerbindung._(client, transport, werkzeuge);
      } on TimeoutException {
        await _schliessen(client, transport);
        throw zeitGrund;
      } catch (_) {
        await _schliessen(client, transport);
        rethrow;
      }
    }
  }

  static Future<List<WerkzeugBeschreibung>> _werkzeugeLesen(McpClient client) async {
    final ergebnis = <WerkzeugBeschreibung>[];
    String? cursor;
    do {
      final ListToolsResult seite;
      try {
        seite = await client.listTools(
          params: cursor == null ? null : ListToolsRequest(cursor: cursor),
        );
      } on McpError {
        throw const PluginFehler('Das Plugin hat keine gültige Werkzeugliste geliefert.');
      } on FormatException {
        throw const PluginFehler('Das Plugin hat keine gültige Werkzeugliste geliefert.');
      }
      for (final t in seite.tools) {
        ergebnis.add(
          WerkzeugBeschreibung(
            name: t.name,
            beschreibung: t.description ?? '',
            eingabeSchema: t.inputSchema.toJson(),
            titel: t.annotations?.title ?? t.title,
            nurLesen: t.annotations?.readOnlyHint ?? false,
            zerstoerend: t.annotations?.destructiveHint ?? false,
          ),
        );
      }
      cursor = seite.nextCursor;
    } while (cursor != null);
    return ergebnis;
  }

  /// Reicht einen Aufruf an das Plugin weiter, mit Profil und Token in
  /// `_meta`. Bricht der Client ab, geht `notifications/cancelled` an das
  /// Plugin. Ohne Zeitlimit: Wie lange ein Aufruf dauert, begrenzt der
  /// Client (E21) und die Frist einer Freigabe (E4).
  ///
  /// Zurück geht nur Text. Andere Inhalte (Bilder, Ressourcen) gibt moocp
  /// nicht an die KI weiter -- was ein KI-Werkzeug zu sehen bekommt, soll die
  /// App lesen können --, und die Antwort sagt, dass etwas fehlt. Meldet das
  /// Plugin einen Fehler (`isError`), wird daraus ein Werkzeugfehler mit
  /// seinem Text ([PluginErgebnisFehler]). Strukturierte Inhalte
  /// (`structuredContent`) und `_meta` der Antwort gehen nicht weiter. Was
  /// zurückgeht, prüft die Datenschutzprüfung, bevor es die KI erreicht
  /// (laufende_plugins.dart).
  Future<String> aufrufen(WerkzeugAufruf aufruf) async {
    final steuerung = BasicAbortController();
    unawaited(aufruf.abbruch.then((_) => steuerung.abort('Die KI wartet nicht mehr.')));
    final CallToolResult ergebnis;
    try {
      ergebnis = await _client.request<CallToolResult>(
        JsonRpcCallToolRequest(
          id: -1,
          params: CallToolRequest(name: aufruf.name, arguments: aufruf.args).toJson(),
          meta: {metaProfil: aufruf.profil.mcpName, metaAufruf: aufruf.token},
        ),
        CallToolResult.fromJson,
        RequestOptions(signal: steuerung.signal, timeoutEnabled: false),
      );
    } catch (_) {
      // mcp_dart meldet den Abbruch mit dem Grund, den moocp mitgegeben hat;
      // alles andere geht an die Hülle.
      if (!steuerung.signal.aborted) rethrow;
      throw MoodleFehler('Abgebrochen: Die KI wartet nicht mehr auf das Werkzeug.');
    }
    final texte = <String>[];
    var andere = 0;
    for (final c in ergebnis.content) {
      if (c is TextContent) {
        texte.add(c.text);
      } else {
        andere++;
      }
    }
    final text = [
      ...texte,
      if (andere > 0)
        '(Das Plugin hat außer Text noch $andere ${andere == 1 ? 'Inhalt' : 'Inhalte'} geliefert, '
            'etwa ein Bild; moocp gibt nur Text weiter, deshalb fehlt das hier.)',
    ].join('\n');
    if (ergebnis.isError) throw PluginErgebnisFehler(text.isEmpty ? 'Das Plugin meldet einen Fehler.' : text);
    return text;
  }

  /// Ob das Plugin auf dieser Verbindung noch antwortet: ein `ping` binnen
  /// [frist]. Ein Plugin, das neu gestartet wurde, kennt die Sitzung nicht
  /// mehr und weist den ping ab; auch das heißt false.
  Future<bool> lebt({Duration frist = const Duration(seconds: 2)}) async {
    try {
      await _client.ping().timeout(frist);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Beendet die Sitzung beim Plugin und schließt die Verbindung. Antwortet
  /// das Plugin nicht mehr, wartet das nicht.
  Future<void> schliessen() => _schliessen(_client, _transport);

  static Future<void> _schliessen(McpClient client, StreamableHttpClientTransport transport) async {
    try {
      await transport.terminateSession().timeout(const Duration(seconds: 1));
    } catch (_) {
      // Ohne Sitzung oder ohne Antwort: Es bleibt beim Schließen.
    }
    try {
      await client.close().timeout(const Duration(seconds: 1));
    } catch (_) {
      // Schon zu.
    }
  }
}
