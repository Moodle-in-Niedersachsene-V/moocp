// Das Beispiel-Plugin von moocp: Vorlage für Plugin-Autoren und das Plugin,
// gegen das die Tests der App laufen. Es zeigt die Schnittstelle und kann
// sonst nichts.
//
// Ein Plugin ist ein eigenes Programm. moocp startet es nach der Zustimmung
// der Lehrkraft und verbindet sich als MCP-Client damit; die KI-Werkzeuge
// sehen seine Werkzeuge im MCP-Server von moocp und sprechen nie direkt mit
// dem Plugin. Was das Programm dafür tun muss:
//
// 1. Den Port aus der Kommandozeile lesen (`--port <Zahl>`) und MCP über
//    Streamable HTTP auf 127.0.0.1:<Port>/mcp anbieten -- nur dort, nie auf
//    einer anderen Adresse.
// 2. Den Schlüssel aus der Umgebungsvariablen MOOCP_PLUGIN_SCHLUESSEL lesen
//    und jede Anfrage ohne den Kopf `Authorization: Bearer <Schlüssel>`
//    abweisen. Der Schlüssel kommt nicht über die Kommandozeile, weil er dort
//    in jeder Prozessliste stünde; das Plugin schreibt ihn nirgends hin.
// 3. Spätestens 20 Sekunden nach dem Start auf `initialize` antworten, sonst
//    beendet moocp das Programm und versucht es noch einmal (Punkt 7).
// 4. Jedes Werkzeug mit dem Kurznamen aus plugin.json und einem Unterstrich
//    beginnen lassen (`beispiel_…`), höchstens 40 Zeichen lang, nur Buchstaben,
//    Ziffern, „_“ und „-“. Die Werkzeugliste liest moocp einmal beim
//    Start; spätere Änderungen beachtet es nicht.
// 5. Als Antwort Text liefern. Bilder und andere Inhalte gibt moocp nicht
//    an die KI weiter.
// 6. Sich beenden, wenn die Standardeingabe endet: Dann ist moocp fort, auch
//    wenn es sich nicht ordentlich beenden konnte. So bleibt kein Plugin
//    zurück.
// 7. Damit rechnen, nach einem Absturz neu gestartet zu werden: Endet das
//    Programm, ohne dass moocp es beendet hat, startet moocp es einmal neu,
//    mit neuem Port und neuem Schlüssel. Was das Plugin für sich behält,
//    muss es deshalb beim Start neu aufbauen; ein Aufruf, der beim Absturz
//    lief, wird nicht wiederholt. Endet es danach noch einmal, gilt es bis
//    zum nächsten Start von moocp als ausgefallen.
//
// Was moocp mitgibt:
// - beim `initialize` unter `capabilities.experimental.moocp` die Version der
//   Schnittstelle (`schnittstelle`);
// - bei jedem `tools/call` unter `_meta` das Instanzprofil, über das der
//   Aufruf kam (`moocp/profil`, der technische Name wie `moodle`), und ein
//   Token für genau diesen Aufruf (`moocp/aufruf`). Das Token ist geheim wie
//   der Schlüssel: nie ausgeben, nie ins Protokoll.
// - Bricht die KI einen Aufruf ab, schickt moocp `notifications/cancelled`;
//   ein Werkzeug, das länger läuft, hört darauf (`extra.signal`).
//
// Übersetzen für die Installation: `dart compile exe beispiel.dart -o
// beispiel.exe` (der Name, den `programm` in plugin.json nennt). Dieses
// Beispiel benutzt die Pakete von moocp und hat deshalb keine eigene
// pubspec.yaml; ein echtes Plugin bringt seine eigene mit und kann in jeder
// Sprache geschrieben sein.

import 'dart:async';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

/// Der Name der Umgebungsvariablen, in der moocp den Schlüssel mitgibt.
const schluesselVariable = 'MOOCP_PLUGIN_SCHLUESSEL';

Future<void> main(List<String> argumente) async {
  final port = _port(argumente);
  final schluessel = Platform.environment[schluesselVariable] ?? '';
  // Ohne Port oder Schlüssel gibt es nichts anzubieten: Ein Plugin ohne
  // Schlüssel stünde jedem Programm auf dem Rechner offen.
  if (port == null || schluessel.isEmpty) exit(2);

  final server = StreamableMcpServer(
    serverFactory: (sitzung) => _server(),
    host: '127.0.0.1',
    port: port,
    path: '/mcp',
    enableJsonResponse: true,
    allowedHosts: const {'127.0.0.1', 'localhost'},
    authenticator: (anfrage) =>
        anfrage.headers.value(HttpHeaders.authorizationHeader) ==
        'Bearer $schluessel',
  );
  await server.start();

  // Endet die Standardeingabe, ist moocp fort: aufräumen und enden.
  stdin.listen(
    (_) {},
    onDone: () async {
      await server.stop();
      exit(0);
    },
  );
}

int? _port(List<String> argumente) {
  final i = argumente.indexOf('--port');
  if (i < 0 || i + 1 >= argumente.length) return null;
  final port = int.tryParse(argumente[i + 1]);
  return port != null && port > 0 && port < 65536 ? port : null;
}

/// Ein MCP-Server je Sitzung, mit dem einen Werkzeug des Beispiels.
McpServer _server() {
  final server = McpServer(
    const Implementation(name: 'beispiel', version: '1.0.0'),
  );
  server.registerTool(
    'beispiel_echo',
    description:
        'Gibt den Text zurück, dazu das Instanzprofil des Aufrufs und ob ein '
        'Aufruf-Token angekommen ist. Zeigt nur die Schnittstelle der Plugins.',
    inputSchema: JsonSchema.object(
      properties: {'text': JsonSchema.string(description: 'Der Text.')},
      required: ['text'],
    ),
    annotations: const ToolAnnotations(
      title: 'Echo (Beispiel)',
      readOnlyHint: true,
      destructiveHint: false,
      openWorldHint: false,
    ),
    callback: (args, extra) async {
      final meta = extra.meta ?? const {};
      final profil = meta['moocp/profil'];
      final token = meta['moocp/aufruf'];
      // Was moocp beim initialize mitgegeben hat.
      final moocp = server.server.getClientCapabilities()?.experimental?['moocp'];
      final schnittstelle = moocp is Map ? moocp['schnittstelle'] : null;
      return CallToolResult.fromContent([
        TextContent(
          text:
              'Echo: ${args['text']}\n'
              'Profil: ${profil is String ? profil : 'fehlt'}\n'
              // Nur, ob es da ist -- das Token selbst gibt ein Plugin nie aus.
              'Aufruf-Token: ${token is String && token.isNotEmpty ? 'erhalten' : 'fehlt'}\n'
              'Schnittstelle: ${schnittstelle ?? 'unbekannt'}',
        ),
      ]);
    },
  );
  // Nur für das Beispiel und die Tests der App: ein Absturz auf Bestellung.
  // Das Programm endet mitten im Aufruf mit Exit-Code 3, ohne zu antworten;
  // so lässt sich sehen, was moocp dann tut (Punkt 7 oben). Ein echtes Plugin
  // hat so ein Werkzeug nicht.
  server.registerTool(
    'beispiel_absturz',
    description:
        'Beendet das Beispiel-Plugin sofort, ohne zu antworten. Zeigt, wie '
        'moocp einen Absturz behandelt: ein Neustart, danach ausgefallen.',
    inputSchema: JsonSchema.object(properties: {}),
    annotations: const ToolAnnotations(
      title: 'Absturz (Beispiel)',
      readOnlyHint: true,
      destructiveHint: false,
      openWorldHint: false,
    ),
    callback: (args, extra) async => exit(3),
  );
  return server;
}
