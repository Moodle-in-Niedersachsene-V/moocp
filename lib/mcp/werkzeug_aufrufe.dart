// MCP-Aufrufe: Validierung, Abbruch, Freigabehinweis und Fehlerantworten.
import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../freigabe.dart';
import '../log.dart';
import '../moodle/moodle_zugang.dart';
import '../protokoll.dart';
import 'werkzeugquelle.dart';

class WerkzeugAufrufe {
  WerkzeugAufrufe(this.protokoll, this.freigaben, {required this.ausfuehren});
  final Future<String> Function(
    String,
    Map<String, dynamic>,
    Future<String> Function(),
  )
  ausfuehren;
  final Protokoll protokoll;
  final Freigaben freigaben;

  /// Ein Werkzeug: Aufruf ins Protokoll, Fehler als Werkzeugfehler zurück.
  void registrieren(
    McpServer server,
    String name, {
    required String titel,
    required String beschreibung,
    Map<String, JsonSchema> parameter = const {},
    List<String> pflicht = const [],
    bool nurLesen = false,
    bool zerstoerend = false,
    required Future<String> Function(Map<String, dynamic> a) ausfuehren,
  }) => _anmelden(
    server,
    name,
    titel: titel,
    beschreibung: beschreibung,
    eingabeSchema: JsonSchema.object(properties: parameter, required: pflicht),
    pflicht: pflicht,
    nurLesen: nurLesen,
    zerstoerend: zerstoerend,
    ausfuehren: (a, _) => ausfuehren(a),
  );

  /// Ein Werkzeug, das nur mit Name, Beschreibung und fertigem JSON-Schema
  /// beschrieben ist (eine [WerkzeugQuelle]): dieselbe Hülle wie bei
  /// [registrieren]. Ein Schema, das kein Objekt beschreibt, bricht ab -- die
  /// Eingabe eines MCP-Werkzeugs ist immer ein Objekt. [ausfuehren] bekommt
  /// neben den Argumenten, was sich erfüllt, wenn der Client abbricht.
  void registrierenBeschrieben(
    McpServer server,
    WerkzeugBeschreibung werkzeug, {
    required Future<String> Function(Map<String, dynamic> a, Future<void> abbruch) ausfuehren,
  }) {
    final JsonSchema schema;
    try {
      schema = JsonSchema.fromJson(werkzeug.eingabeSchema);
    } on FormatException catch (x) {
      throw StateError(
        'Das Eingabeschema des Werkzeugs „${werkzeug.name}" ist ungültig: ${x.message}',
      );
    }
    if (schema is! JsonObject) {
      throw StateError(
        'Das Eingabeschema des Werkzeugs „${werkzeug.name}" beschreibt kein Objekt.',
      );
    }
    _anmelden(
      server,
      werkzeug.name,
      titel: werkzeug.titel,
      beschreibung: werkzeug.beschreibung,
      eingabeSchema: schema,
      pflicht: schema.required ?? const [],
      nurLesen: werkzeug.nurLesen,
      zerstoerend: werkzeug.zerstoerend,
      ausfuehren: ausfuehren,
    );
  }

  /// Die Namen, die je Server schon vergeben sind. mcp_dart wiese einen
  /// doppelten Namen auch ab, aber mit einem englischen ArgumentError; so
  /// meldet die Hülle jeden Fall gleich, deutsch und mit dem Namen.
  final _namen = Expando<Set<String>>('Werkzeugnamen je Server');

  /// Die eine Hülle für alle Werkzeuge: Aufruf ins Protokoll, Abbruch,
  /// Fehlerantwort. [registrieren] und [registrierenBeschrieben] führen
  /// beide hierher; was sich daran ändert, ändert sich für alle Werkzeuge.
  void _anmelden(
    McpServer server,
    String name, {
    required String? titel,
    required String beschreibung,
    required JsonObject eingabeSchema,
    required List<String> pflicht,
    required bool nurLesen,
    required bool zerstoerend,
    required Future<String> Function(Map<String, dynamic> a, Future<void> abbruch) ausfuehren,
  }) {
    if (!(_namen[server] ??= {}).add(name)) {
      throw StateError(
        'Das Werkzeug „$name" ist schon registriert: Werkzeugnamen müssen auf dem Server eindeutig sein.',
      );
    }
    server.registerTool(
      name,
      description: beschreibung,
      inputSchema: eingabeSchema,
      annotations: ToolAnnotations(
        title: titel,
        readOnlyHint: nurLesen,
        destructiveHint: zerstoerend,
        openWorldHint: false,
      ),
      callback: (args, extra) async {
        final aufruf = jsonEncode(args);
        protokoll.eintrag(
          Art.werkzeug,
          '$name(${aufruf.length > 200 ? '${aufruf.substring(0, 199)}…' : aufruf})',
        );
        for (final p in pflicht) {
          if (args[p] == null) return _fehler('$p fehlt.');
        }
        // Hat das Werkzeug wegen der eingestellten Stufe ohne Freigabe
        // geschrieben, erfährt Claude das hier -- an einer Stelle für alle
        // Werkzeuge. Sonst kündigte der Skill eine Rückfrage an, die nie kommt.
        // Der Zähler gehört diesem Aufruf allein (Freigaben.mitAbbruch): Ein
        // gleichzeitiger zweiter Aufruf bekommt die Auslassung des ersten nicht
        // gemeldet.
        final zaehler = AufrufZaehler();
        // Bricht der Client ab (sein Zeitlimit, ein Abbruch in der Sitzung),
        // verfallen die offenen Freigaben dieses Aufrufs (Freigaben.mitAbbruch).
        final abbruch = Completer<void>();
        void abbrechen() {
          if (!abbruch.isCompleted) abbruch.complete();
        }

        if (extra.signal.aborted) abbrechen();
        final horcht = extra.signal.onAbort.listen((_) => abbrechen());
        try {
          final text = await Freigaben.mitAbbruch(
            abbruch.future,
            () => this.ausfuehren(name, args, () => ausfuehren(args, abbruch.future)),
            zaehler: zaehler,
          );
          protokoll.eintrag(Art.info, '$name: ${text.split('\n').first}');
          return CallToolResult.fromContent([
            TextContent(
              text:
                  '$text${_ohneFreigabe(zaehler.ausgelassen)}'
                  '${zaehler.testfreigaben > 0 ? '\nDebug-Testbetrieb: automatisch freigegeben, ohne persönliche Freigabe.' : ''}',
            ),
          ]);
        } on MoodleFehler catch (x) {
          protokoll.eintrag(Art.fehler, '$name: ${x.meldung}');
          return _fehler(x.meldung);
        } catch (x, st) {
          final b = fehlerBeschreibung(x, st);
          protokoll.eintrag(Art.fehler, '$name: $b');
          return _fehler('Unerwarteter Fehler: $b');
        } finally {
          await horcht.cancel();
        }
      },
    );
  }

  /// Angehängt an die Antwort eines Werkzeugs, das [n] Freigaben wegen der
  /// eingestellten Stufe ausgelassen hat.
  String _ohneFreigabe(int n) => n <= 0
      ? ''
      : '\n\nOhne Freigabe ausgeführt ($n ${n == 1 ? 'Vorgang' : 'Vorgänge'}): Die Lehrkraft hat '
            'die Bestätigungen in der App auf „${freigaben.stufe.text}" gestellt. Kündige keine '
            'Freigabe an, die nicht kommt, und schlage nicht vor, die Stufe zu ändern -- das ist '
            'ihre Entscheidung.';

  CallToolResult _fehler(String text) =>
      CallToolResult(content: [TextContent(text: text)], isError: true);
}
