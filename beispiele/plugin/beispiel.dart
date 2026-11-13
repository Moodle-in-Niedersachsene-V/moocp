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
//    an die KI weiter. Keine Namen von Personen in Antworten und
//    Protokollzeilen: Was einen Namen trifft, den das Plugin zum Sperren
//    genannt hat, hält moocp ganz an (`beispiel_namen`).
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
// Entwickeln (README, Teil 4, „Ein Plugin entwickeln“): Wer ein Plugin
// entwickelt, startet es selbst, im Debugger, auf dem Port aus
// `entwicklungsPort` in plugin.json, mit einem selbst erzeugten Schlüssel in
// MOOCP_PLUGIN_SCHLUESSEL, und startet dann die installierte App mit
// `--plugin-entwicklung <Ordner>` und derselben Variablen. moocp startet das
// Plugin dann nicht, sondern verbindet sich damit, und verbindet sich wieder,
// wenn es neu gebaut und neu gestartet wird. entwickeln.ps1 (Windows) und
// entwickeln.sh (Mac) tun das für dieses Beispiel. Dabei läuft es mit
// `--entwicklung`: Seine Standardeingabe gehört dann nicht moocp, und es endet
// nicht mit ihr (Punkt 6), sondern wenn sein Entwickler es beendet.
//
// Was moocp mitgibt:
// - beim `initialize` unter `capabilities.experimental.moocp` die Version der
//   Schnittstelle (`schnittstelle`) und die Adresse der App für Plugins
//   (`adresse`, etwa `http://127.0.0.1:<Port>`);
// - bei jedem `tools/call` unter `_meta` das Instanzprofil, über das der
//   Aufruf kam (`moocp/profil`, der technische Name wie `moodle`), und ein
//   Token für genau diesen Aufruf (`moocp/aufruf`). Das Token ist geheim wie
//   der Schlüssel: nie ausgeben, nie ins Protokoll.
// - Bricht die KI einen Aufruf ab, schickt moocp `notifications/cancelled`;
//   ein Werkzeug, das länger läuft, hört darauf (`extra.signal`).
//
// Die Adresse der App (README, Teil 4, „Die Adresse der App für Plugins“):
// JSON über POST, angemeldet mit demselben Schlüssel (`Authorization: Bearer
// <Schlüssel>`) und dem Token des laufenden Aufrufs im Kopf `Moocp-Aufruf`.
// Sie gilt nur, solange die KI ein Werkzeug des Plugins aufruft; danach lehnt
// moocp das Token ab. Die Hilfsfunktion [anMoocp] unten lässt sich in ein
// eigenes Plugin übernehmen. Je ein Werkzeug zeigt einen Weg:
// `beispiel_protokoll` (eine Zeile ins Protokoll von moocp),
// `beispiel_datei` (eine Datei im Arbeitsordner ablegen),
// `beispiel_status` (das eingebaute Werkzeug `status` aufrufen),
// `beispiel_auswahl`, `beispiel_eingabe`, `beispiel_pfad` und
// `beispiel_hinweis` (je eine Art Dialog), `beispiel_freigabe` (um eine
// Freigabe bitten), `beispiel_moodle_lesen` (eine erlaubte Seite von Moodle
// lesen), `beispiel_moodle_gesperrt` (eine Anfrage, die moocp ablehnt),
// `beispiel_moodle_schreiben` (über eine Zusatzadresse schreiben, mit
// Freigabe, und selbst prüfen), `beispiel_lauf` (in einem Lauf über eine
// Zusatzadresse lesen), `beispiel_download` (in einem Lauf über eine
// Zusatzadresse herunterladen) und `beispiel_namen` (Namen zum Sperren
// nennen; die letzte Sperre hält danach eine Antwort mit einem davon an).
//
// Übersetzen für die Installation: `dart compile exe beispiel.dart -o
// beispiel.exe` (der Name, den `programm` in plugin.json nennt). Dieses
// Beispiel benutzt die Pakete von moocp und hat deshalb keine eigene
// pubspec.yaml; ein echtes Plugin bringt seine eigene mit und kann in jeder
// Sprache geschrieben sein.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

/// Der Name der Umgebungsvariablen, in der moocp den Schlüssel mitgibt.
const schluesselVariable = 'MOOCP_PLUGIN_SCHLUESSEL';

/// Der Schlüssel aus der Umgebung; gilt für beide Richtungen.
late final String _schluessel;

Future<void> main(List<String> argumente) async {
  final port = _port(argumente);
  final schluessel = _schluessel = Platform.environment[schluesselVariable] ?? '';
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

  // Zum Entwickeln von Hand gestartet: kein moocp am anderen Ende der
  // Standardeingabe; das Plugin läuft, bis sein Entwickler es beendet.
  if (argumente.contains('--entwicklung')) return;

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

  // Die drei Wege zur Adresse der App. Jeder braucht die Adresse aus dem
  // initialize dieser Sitzung und das Token des Aufrufs aus `_meta`.
  Uri? adresse() {
    final moocp = server.server.getClientCapabilities()?.experimental?['moocp'];
    final a = moocp is Map ? moocp['adresse'] : null;
    return a is String ? Uri.tryParse(a) : null;
  }

  String? token(RequestHandlerExtra extra) {
    final t = extra.meta?['moocp/aufruf'];
    return t is String ? t : null;
  }

  CallToolResult text(String t, {bool fehler = false}) =>
      CallToolResult(content: [TextContent(text: t)], isError: fehler);

  server.registerTool(
    'beispiel_protokoll',
    description:
        'Schreibt eine Zeile ins Protokoll von moocp. Zeigt nur die Schnittstelle der Plugins.',
    inputSchema: JsonSchema.object(
      properties: {'text': JsonSchema.string(description: 'Die Zeile.')},
      required: ['text'],
    ),
    annotations: const ToolAnnotations(
      title: 'Protokollzeile (Beispiel)',
      readOnlyHint: true,
      destructiveHint: false,
      openWorldHint: false,
    ),
    callback: (args, extra) async {
      try {
        await anMoocp(adresse(), '/v1/protokoll', {'text': args['text']}, aufruf: token(extra));
        return text('Die Zeile steht im Protokoll von moocp.');
      } on MoocpFehler catch (f) {
        return text(f.text, fehler: true);
      }
    },
  );

  server.registerTool(
    'beispiel_datei',
    description:
        'Legt den Text als Datei beispiel.txt im Arbeitsordner ab und nennt ihren Pfad. '
        'Zeigt nur die Schnittstelle der Plugins.',
    inputSchema: JsonSchema.object(
      properties: {'text': JsonSchema.string(description: 'Der Inhalt der Datei.')},
      required: ['text'],
    ),
    annotations: const ToolAnnotations(
      title: 'Datei ablegen (Beispiel)',
      readOnlyHint: true,
      destructiveHint: false,
      openWorldHint: false,
    ),
    callback: (args, extra) async {
      try {
        // moocp nennt den eigenen Unterordner im Arbeitsordner des Profils;
        // hineinschreiben tut das Plugin selbst.
        final antwort = await anMoocp(adresse(), '/v1/arbeitsordner', {}, aufruf: token(extra));
        final datei = File('${antwort['pfad']}${Platform.pathSeparator}beispiel.txt');
        await datei.writeAsString('${args['text']}');
        return text('Datei abgelegt: ${datei.path}');
      } on MoocpFehler catch (f) {
        return text(f.text, fehler: true);
      }
    },
  );

  server.registerTool(
    'beispiel_status',
    description:
        'Ruft das eingebaute Werkzeug status von moocp auf und gibt seine Antwort zurück. '
        'Zeigt nur die Schnittstelle der Plugins.',
    inputSchema: JsonSchema.object(properties: {}),
    annotations: const ToolAnnotations(
      title: 'Status über moocp (Beispiel)',
      readOnlyHint: true,
      destructiveHint: false,
      openWorldHint: false,
    ),
    callback: (args, extra) async {
      try {
        // Dieselben Regeln wie für ein KI-Werkzeug: Freigaben, Protokoll,
        // Rücklesen. In der Freigabe steht das Plugin als Aufrufer.
        final antwort = await anMoocp(
          adresse(),
          '/v1/werkzeug',
          {'name': 'status', 'argumente': <String, Object?>{}},
          aufruf: token(extra),
        );
        return text('${antwort['text']}', fehler: antwort['fehlgeschlagen'] == true);
      } on MoocpFehler catch (f) {
        return text(f.text, fehler: true);
      }
    },
  );

  // Dialoge: Ein Plugin öffnet keine Fenster, es beschreibt den Dialog, und
  // moocp zeigt ihn mit dem Plugin als Absender. Alles ist reiner Text; die
  // Knöpfe beschriftet moocp. Die Antwort enthält immer `abgebrochen`; ist es
  // false, stehen die Felder der Art daneben. Je Aufruf ist nur ein Dialog
  // zugleich offen. Ein Dialog ist keine Freigabe.
  const nurSchnittstelle = 'Zeigt nur die Schnittstelle der Plugins.';
  ToolAnnotations hinweise(String titel) =>
      ToolAnnotations(title: titel, readOnlyHint: true, destructiveHint: false, openWorldHint: false);

  server.registerTool(
    'beispiel_auswahl',
    description:
        'Lässt die Lehrkraft in moocp aus einer Liste mit Suchfeld wählen und nennt, was sie gewählt hat. '
        '$nurSchnittstelle',
    inputSchema: JsonSchema.object(
      properties: {'mehrfach': JsonSchema.boolean(description: 'Ob mehrere Einträge wählbar sind.')},
    ),
    annotations: hinweise('Auswahl (Beispiel)'),
    callback: (args, extra) async {
      const farben = ['Rot', 'Grün', 'Blau', 'Gelb', 'Schwarz', 'Weiß'];
      try {
        final antwort = await anMoocp(adresse(), '/v1/dialog/auswahl', {
          'titel': 'Farben wählen',
          'text': 'Welche Farben soll das Beispiel nennen?',
          'eintraege': farben,
          'mehrfach': args['mehrfach'] == true,
        }, aufruf: token(extra));
        if (antwort['abgebrochen'] == true) return text('Die Lehrkraft hat nichts gewählt.');
        // Gewählt sind Nummern in der Liste, ab 0.
        final gewaehlt = [for (final i in antwort['gewaehlt'] as List) farben[i as int]];
        return text('Gewählt: ${gewaehlt.join(', ')}');
      } on MoocpFehler catch (f) {
        return text(f.text, fehler: true);
      }
    },
  );

  server.registerTool(
    'beispiel_eingabe',
    description:
        'Lässt die Lehrkraft in moocp einen Text oder Link eingeben und gibt ihn zurück. $nurSchnittstelle',
    inputSchema: JsonSchema.object(
      properties: {'link': JsonSchema.boolean(description: 'Ob ein Link (http oder https) verlangt ist.')},
    ),
    annotations: hinweise('Eingabe (Beispiel)'),
    callback: (args, extra) async {
      final link = args['link'] == true;
      try {
        final antwort = await anMoocp(adresse(), '/v1/dialog/eingabe', {
          'titel': link ? 'Link eingeben' : 'Text eingeben',
          'art': link ? 'link' : 'text',
          'vorgabe': link ? 'https://' : '',
        }, aufruf: token(extra));
        if (antwort['abgebrochen'] == true) return text('Die Lehrkraft hat nichts eingegeben.');
        return text('Eingegeben: ${antwort['text']}');
      } on MoocpFehler catch (f) {
        return text(f.text, fehler: true);
      }
    },
  );

  server.registerTool(
    'beispiel_pfad',
    description:
        'Lässt die Lehrkraft in moocp einen Ordner oder eine Datei wählen und nennt, wie viele Einträge der '
        'Ordner hat oder wie groß die Datei ist. $nurSchnittstelle',
    inputSchema: JsonSchema.object(
      properties: {'datei': JsonSchema.boolean(description: 'Ob eine Datei statt eines Ordners gewählt wird.')},
    ),
    annotations: hinweise('Ordner oder Datei wählen (Beispiel)'),
    callback: (args, extra) async {
      final datei = args['datei'] == true;
      try {
        final antwort = await anMoocp(adresse(), '/v1/dialog/pfad', {
          'titel': datei ? 'Datei wählen' : 'Ordner wählen',
          'art': datei ? 'datei' : 'ordner',
        }, aufruf: token(extra));
        if (antwort['abgebrochen'] == true) return text('Die Lehrkraft hat nichts gewählt.');
        // moocp nennt nur den Pfad; lesen tut das Plugin selbst, mit den
        // Rechten der Lehrkraft. Den Pfad gibt dieses Beispiel nicht an die
        // KI weiter: Er kann Namen enthalten.
        final pfad = antwort['pfad'] as String;
        return text(
          datei
              ? 'Die gewählte Datei hat ${await File(pfad).length()} Bytes.'
              : 'Der gewählte Ordner hat ${await Directory(pfad).list().length} Einträge.',
        );
      } on MoocpFehler catch (f) {
        return text(f.text, fehler: true);
      } on FileSystemException {
        return text('Das Gewählte ließ sich nicht lesen.', fehler: true);
      }
    },
  );

  server.registerTool(
    'beispiel_hinweis',
    description: 'Zeigt der Lehrkraft in moocp einen Hinweis und wartet, bis sie ihn bestätigt. $nurSchnittstelle',
    inputSchema: JsonSchema.object(
      properties: {'text': JsonSchema.string(description: 'Der Text des Hinweises.')},
      required: ['text'],
    ),
    annotations: hinweise('Hinweis (Beispiel)'),
    callback: (args, extra) async {
      try {
        final antwort = await anMoocp(adresse(), '/v1/dialog/hinweis', {
          'titel': 'Hinweis des Beispiels',
          'text': '${args['text']}',
        }, aufruf: token(extra));
        return text(antwort['abgebrochen'] == true ? 'Der Hinweis wurde nicht bestätigt.' : 'Bestätigt.');
      } on MoocpFehler catch (f) {
        return text(f.text, fehler: true);
      }
    },
  );

  // Eine Freigabe: Das Plugin nennt Titel und Zusammenfassung und die Stufe,
  // ab der gefragt wird („mittel“, „alle“ oder „keine“ für jede Stufe). Es
  // gelten alle Regeln einer Freigabe von moocp; der Dialog kennzeichnet die
  // Zusammenfassung als vom Plugin, nicht von moocp geprüft. Hat die Stufe
  // der Lehrkraft die Frage ausgelassen, ist `ohneFrage` true.
  server.registerTool(
    'beispiel_freigabe',
    description:
        'Bittet die Lehrkraft in moocp um eine Freigabe und nennt den Ausgang. Ändert nichts. '
        '$nurSchnittstelle',
    inputSchema: JsonSchema.object(
      properties: {
        'ab': JsonSchema.string(
          description: 'Ab welcher Stufe gefragt wird: mittel, alle oder keine (auf jeder Stufe).',
        ),
      },
    ),
    annotations: hinweise('Freigabe (Beispiel)'),
    callback: (args, extra) async {
      try {
        final antwort = await anMoocp(adresse(), '/v1/freigabe', {
          'titel': 'Beispiel freigeben?',
          'zusammenfassung': 'Das Beispiel-Plugin fragt nur zur Probe.\nEs ändert nichts.',
          'ab': args['ab'] ?? 'mittel',
        }, aufruf: token(extra));
        return text(
          'Ausgang: ${antwort['ausgang']}${antwort['ohneFrage'] == true ? ' (ohne Frage, wegen der Stufe)' : ''}',
        );
      } on MoocpFehler catch (f) {
        return text(f.text, fehler: true);
      }
    },
  );

  // Moodle lesen: moocp stellt die Anfrage mit der Sitzung des Profils des
  // Aufrufs, nur GET und nur, was der lesende Teil seiner Positivliste
  // erlaubt; jedes Umleitungsziel prüft es genauso. Die Antwort hat `status`,
  // `inhaltstyp`, `pfad` (nach Umleitungen, ohne Rechner) und `text`, nie
  // Cookies; von einer Seite nur ihren Hauptbereich (`#region-main`), ohne
  // Kopf, Nutzermenü und Blöcke, und nie den sesskey. Was nicht erlaubt ist, lehnt moocp ohne Dialog ab und nennt den
  // Grund im Feld `fehler`. Schreiben geht nicht hier: Was die Positivliste
  // erlaubt, über die eingebauten Werkzeuge (`/v1/werkzeug`), mit Freigabe und
  // Rücklesen; was darüber hinausgeht, über eine Zusatzadresse
  // (`beispiel_moodle_schreiben`).
  server.registerTool(
    'beispiel_moodle_lesen',
    description:
        'Liest über moocp die Seite mit den Fragensammlungen eines Kurses und nennt Status, Inhaltstyp und Länge, '
        'nicht den Inhalt. $nurSchnittstelle',
    inputSchema: JsonSchema.object(
      properties: {'kurs': JsonSchema.integer(description: 'Kurs-ID, die Zahl hinter course/view.php?id=')},
      required: ['kurs'],
    ),
    annotations: hinweise('Moodle lesen (Beispiel)'),
    callback: (args, extra) async {
      try {
        final antwort = await anMoocp(adresse(), '/v1/moodle/lesen', {
          'pfad': '/question/banks.php?courseid=${(args['kurs'] as num).toInt()}',
        }, aufruf: token(extra));
        // Den Inhalt gibt das Beispiel nicht an die KI weiter: Auch im
        // Hauptbereich einer Seite können Namen stehen.
        return text(
          'Moodle antwortet mit Status ${antwort['status']} (${antwort['inhaltstyp']}, '
          '${(antwort['text'] as String).length} Zeichen).',
        );
      } on MoocpFehler catch (f) {
        return text(f.text, fehler: true);
      }
    },
  );

  server.registerTool(
    'beispiel_moodle_gesperrt',
    description:
        'Versucht über moocp den Adminbereich von Moodle zu lesen und gibt die Ablehnung von moocp zurück. '
        '$nurSchnittstelle',
    inputSchema: JsonSchema.object(properties: {}),
    annotations: hinweise('Moodle gesperrt (Beispiel)'),
    callback: (args, extra) async {
      try {
        await anMoocp(adresse(), '/v1/moodle/lesen', {'pfad': '/admin/index.php'}, aufruf: token(extra));
        return text('Unerwartet: moocp hat den Adminbereich gelesen.', fehler: true);
      } on MoocpFehler catch (f) {
        // Die Ablehnung ist hier das erwartete Ergebnis.
        return text('Abgelehnt (HTTP ${f.status}): ${f.text}');
      }
    },
  );

  // Über eine Zusatzadresse schreiben: Was über die Positivliste von moocp
  // hinausgeht, meldet ein Plugin in plugin.json unter `zusatzadressen` an
  // (Muster, Art „schreiben“, Grund); die Lehrkraft stimmt der Liste mit dem
  // Plugin zu. Geschrieben wird in zwei Schritten, beide mit dem Token des
  // Aufrufs:
  //
  // 1. `/v1/moodle/zusatz/freigabe` mit `methode` („POST“), `pfad` (mit
  //    Parametern), `felder` (Liste von `{"name", "wert"}` in der Reihenfolge,
  //    in der sie gesendet werden), `titel` und `zusammenfassung`. moocp
  //    fragt die Lehrkraft auf jeder Stufe; freigegeben, kommt eine `kennung`.
  // 2. `/v1/moodle/zusatz/schreiben` mit der `kennung` und genau denselben
  //    `methode`, `pfad` und `felder`. Die Kennung gilt einmal und nur in
  //    diesem Aufruf. Den sesskey setzt moocp ein; ein Plugin schickt ihn nie
  //    mit. Die Antwort hat `geschrieben`, `status`, `inhaltstyp`, `pfad`
  //    (nach Umleitungen) und `text`, und `umleitungNichtGelesen`, wenn moocp
  //    einer Umleitung nicht folgen durfte.
  //
  // Zurücklesen und Prüfen ist Sache des Plugins: moocp kennt die Seite nicht.
  // Vor seine Antwort an die KI setzt moocp, dass das Plugin geprüft hat,
  // nicht moocp.
  server.registerTool(
    'beispiel_moodle_schreiben',
    description:
        'Speichert über moocp eine Notiz auf einer erfundenen Seite (/mod/beispiel/speichern.php), mit Freigabe '
        'der Lehrkraft, und prüft selbst, ob sie danach dort steht. Zeigt das Schreiben über eine Zusatzadresse; '
        'in einem echten Moodle gibt es die Seite nicht. $nurSchnittstelle',
    inputSchema: JsonSchema.object(
      properties: {
        'id': JsonSchema.integer(description: 'Die Nummer, die an der Seite steht.'),
        'notiz': JsonSchema.string(description: 'Die Notiz.'),
      },
      required: ['id', 'notiz'],
    ),
    annotations: const ToolAnnotations(
      title: 'Moodle schreiben (Beispiel)',
      readOnlyHint: false,
      destructiveHint: false,
      openWorldHint: false,
    ),
    callback: (args, extra) async {
      final notiz = '${args['notiz']}';
      final schreibvorgang = {
        'methode': 'POST',
        'pfad': '/mod/beispiel/speichern.php?id=${(args['id'] as num).toInt()}',
        'felder': [
          {'name': 'notiz', 'wert': notiz},
        ],
      };
      try {
        final freigabe = await anMoocp(adresse(), '/v1/moodle/zusatz/freigabe', {
          ...schreibvorgang,
          'titel': 'Notiz speichern?',
          'zusammenfassung': 'Das Beispiel-Plugin speichert diese Notiz:\n$notiz',
        }, aufruf: token(extra));
        if (freigabe['ausgang'] != 'freigegeben') {
          return text('Nicht geschrieben: Die Lehrkraft hat nicht freigegeben (${freigabe['ausgang']}).');
        }
        final antwort = await anMoocp(adresse(), '/v1/moodle/zusatz/schreiben', {
          ...schreibvorgang,
          'kennung': freigabe['kennung'],
        }, aufruf: token(extra));
        // Selbst prüfen: Steht die Notiz auf der Seite, auf die Moodle nach
        // dem Speichern führt? Den Inhalt der Seite gibt das Beispiel nicht
        // weiter; er könnte Namen enthalten.
        if (antwort['umleitungNichtGelesen'] != null) {
          return text('Gesendet, aber nicht geprüft: Das Plugin konnte die Seite danach nicht lesen.', fehler: true);
        }
        final steht = '${antwort['text']}'.contains('Notiz: ${const HtmlEscape().convert(notiz)}') ||
            '${antwort['text']}'.contains('Notiz: $notiz');
        return steht
            ? text('Geschrieben und vom Plugin geprüft: Die Notiz steht auf der Seite.')
            : text('Gesendet, aber die Prüfung des Plugins hat die Notiz auf der Seite nicht gefunden.', fehler: true);
      } on MoocpFehler catch (f) {
        return text(f.text, fehler: true);
      }
    },
  );

  // Ein Lauf: Über eine Zusatzadresse mit der Art „lesen“ liest ein Plugin nur
  // in einem Lauf, den es mit der Nummer der Aktivität beginnt, um die es
  // geht. Hinter einer solchen Adresse ist mit Namen zu rechnen. Deshalb
  // ermittelt moocp beim Beginn selbst den Kurs der Aktivität, lädt die Namen
  // seiner Teilnehmenden in die letzte Sperre (das Plugin bekommt sie nicht)
  // und lehnt jede Anfrage des Laufs ab, deren Adresse eine andere Kurs- oder
  // Aktivitätsnummer trägt oder gar keine. Alle Schritte mit dem Token des
  // Aufrufs:
  //
  // 1. `/v1/moodle/lauf/beginnen` mit `cmid`; die Antwort nennt den Kurs.
  // 2. `/v1/moodle/zusatz/lesen` mit `pfad`; die Antwort hat `status`,
  //    `inhaltstyp`, `pfad` und `text`, von einer ganzen Seite nur ihren
  //    Hauptbereich, nie den sesskey.
  // 3. `/v1/moodle/lauf/beenden`. Endet der Aufruf, endet der Lauf mit ihm.
  //
  // Was das Plugin liest, kann Namen enthalten; es gibt nur Unbedenkliches an
  // die KI weiter. Tut es das doch, sperrt moocp die Antwort, auch nach dem
  // Ende des Laufs.
  server.registerTool(
    'beispiel_lauf',
    description:
        'Liest über moocp in einem Lauf den Bericht einer Aktivität auf einer erfundenen Seite '
        '(/mod/beispiel/bericht.php) und nennt nur, ob moocp vorher und nachher ablehnt, Status und Länge, nicht den '
        'Inhalt. Zeigt das Lesen über eine Zusatzadresse; in einem echten Moodle gibt es die Seite nicht. $nurSchnittstelle',
    inputSchema: JsonSchema.object(
      properties: {'cmid': JsonSchema.integer(description: 'Die Nummer der Aktivität, die Zahl hinter view.php?id=.')},
      required: ['cmid'],
    ),
    annotations: hinweise('Lauf (Beispiel)'),
    callback: (args, extra) async {
      final cmid = (args['cmid'] as num).toInt();
      final bericht = {'pfad': '/mod/beispiel/bericht.php?id=$cmid'};
      final zeilen = <String>[];
      try {
        // Ohne Lauf lehnt moocp ab.
        try {
          await anMoocp(adresse(), '/v1/moodle/zusatz/lesen', bericht, aufruf: token(extra));
          zeilen.add('Ohne Lauf: unerwartet gelesen.');
        } on MoocpFehler catch (f) {
          zeilen.add('Ohne Lauf: abgelehnt (HTTP ${f.status}).');
        }
        final lauf = await anMoocp(adresse(), '/v1/moodle/lauf/beginnen', {'cmid': cmid}, aufruf: token(extra));
        zeilen.add('Lauf begonnen für Kurs ${lauf['kurs']}.');
        final antwort = await anMoocp(adresse(), '/v1/moodle/zusatz/lesen', bericht, aufruf: token(extra));
        // Den Inhalt gibt das Beispiel nicht weiter: Er kann Namen enthalten.
        zeilen.add(
          'Im Lauf: Moodle antwortet mit Status ${antwort['status']} (${antwort['inhaltstyp']}, '
          '${(antwort['text'] as String).length} Zeichen).',
        );
        await anMoocp(adresse(), '/v1/moodle/lauf/beenden', {}, aufruf: token(extra));
        zeilen.add('Lauf beendet.');
        try {
          await anMoocp(adresse(), '/v1/moodle/zusatz/lesen', bericht, aufruf: token(extra));
          zeilen.add('Nach dem Lauf: unerwartet gelesen.');
        } on MoocpFehler catch (f) {
          zeilen.add('Nach dem Lauf: abgelehnt (HTTP ${f.status}).');
        }
        return text(zeilen.join('\n'));
      } on MoocpFehler catch (f) {
        return text([...zeilen, f.text].join('\n'), fehler: true);
      }
    },
  );

  // Herunterladen in einem Lauf: Eine Datei hinter einer Zusatzadresse mit der
  // Art „lesen“ lädt ein Plugin über `/v1/moodle/zusatz/datei` mit `pfad`,
  // nur in einem Lauf und mit denselben Prüfungen wie beim Lesen. moocp legt
  // sie nicht in den Arbeitsordner, sondern in einen eigenen Ordner je Plugin
  // und Instanzprofil, unter einem Namen, den moocp vergibt; die Antwort hat
  // `datei` (den Pfad) und `bytes`. Endet der Lauf oder der Aufruf, löscht
  // moocp die Datei; was das Plugin behalten will, verarbeitet es vorher.
  //
  // Den Pfad gibt ein Plugin nie weiter, weder an die KI noch ins Protokoll:
  // Wer ihn kennt, könnte die Dateien lesen. Nennt eine Antwort oder eine
  // Protokollzeile ihn doch, hält moocp sie an wie einen Namen.
  server.registerTool(
    'beispiel_download',
    description:
        'Lädt über moocp in einem Lauf den Export einer Aktivität von einer erfundenen Seite '
        '(/mod/beispiel/export.php) herunter, liest die Größe der Datei und beendet den Lauf. Nennt nur die Größe '
        'und ob die Datei danach gelöscht ist, nie den Pfad oder den Inhalt. Zeigt das Herunterladen über eine '
        'Zusatzadresse; in einem echten Moodle gibt es die Seite nicht. $nurSchnittstelle',
    inputSchema: JsonSchema.object(
      properties: {'cmid': JsonSchema.integer(description: 'Die Nummer der Aktivität, die Zahl hinter view.php?id=.')},
      required: ['cmid'],
    ),
    annotations: hinweise('Herunterladen (Beispiel)'),
    callback: (args, extra) async {
      final cmid = (args['cmid'] as num).toInt();
      final zeilen = <String>[];
      try {
        await anMoocp(adresse(), '/v1/moodle/lauf/beginnen', {'cmid': cmid}, aufruf: token(extra));
        final antwort = await anMoocp(adresse(), '/v1/moodle/zusatz/datei', {
          'pfad': '/mod/beispiel/export.php?id=$cmid',
        }, aufruf: token(extra));
        // Mit der Datei arbeiten, solange der Lauf läuft; hier nur ihre Größe.
        final datei = File(antwort['datei'] as String);
        zeilen.add('Im Lauf heruntergeladen: ${antwort['bytes']} Bytes, die Datei hat ${await datei.length()} Bytes.');
        await anMoocp(adresse(), '/v1/moodle/lauf/beenden', {}, aufruf: token(extra));
        zeilen.add(await datei.exists() ? 'Nach dem Lauf: Die Datei liegt noch da.' : 'Nach dem Lauf: Die Datei ist gelöscht.');
        return text(zeilen.join('\n'));
      } on MoocpFehler catch (f) {
        return text([...zeilen, f.text].join('\n'), fehler: true);
      } on FileSystemException {
        return text([...zeilen, 'Die Datei ließ sich nicht lesen.'].join('\n'), fehler: true);
      }
    },
  );

  // Die letzte Sperre: Arbeitet ein Plugin mit Personen, nennt es moocp die
  // Namen (`/v1/namen`, `{"namen": [...]}`). Von da an prüft moocp, bis es
  // endet, jede Antwort dieses Plugins an die KI und jede Protokollzeile
  // gegen sie: Jeder Teil eines Namens sperrt für sich, als ganzes Wort, ohne
  // Rücksicht auf Groß- und Kleinschreibung und auf die Schreibweise von
  // Umlauten und Akzenten. Bei einem Treffer geht nichts hinaus; die KI
  // erfährt nur, dass gesperrt wurde, die Lehrkraft sieht das Wort. Namen
  // lassen sich nicht wieder entfernen und nicht abfragen.
  //
  // Dieses Werkzeug tut absichtlich, was ein Plugin nie tun soll: Es nennt
  // den erfundenen Namen „Erika Mustermann“ und gibt ihn dann in einer
  // Protokollzeile (moocp lehnt sie mit 422 ab) und in seiner Antwort
  // zurück (moocp sperrt sie). Ein echtes Plugin baut seine Antworten so,
  // dass keine Namen darin stehen, und nennt die Namen nur, damit moocp sie
  // abfängt, falls doch einer durchrutscht.
  server.registerTool(
    'beispiel_namen',
    description:
        'Nennt moocp einen erfundenen Namen zum Sperren und gibt ihn dann zurück; moocp sperrt die Antwort. '
        '$nurSchnittstelle',
    inputSchema: JsonSchema.object(properties: {}),
    annotations: hinweise('Letzte Sperre (Beispiel)'),
    callback: (args, extra) async {
      const name = 'Erika Mustermann';
      try {
        await anMoocp(adresse(), '/v1/namen', {
          'namen': [name],
        }, aufruf: token(extra));
      } on MoocpFehler catch (f) {
        return text(f.text, fehler: true);
      }
      try {
        await anMoocp(adresse(), '/v1/protokoll', {'text': 'Bearbeitet: $name'}, aufruf: token(extra));
      } on MoocpFehler catch (f) {
        // Erwartet: 422, die Zeile steht nicht im Protokoll.
        if (f.status != 422) return text(f.text, fehler: true);
      }
      return text('Ergebnis für $name: 3 von 4 Punkten.');
    },
  );
  return server;
}

/// Eine Antwort der Adresse der App mit einem Fehlerstatus: [text] ist der
/// deutsche Satz aus dem Feld `fehler`.
class MoocpFehler implements Exception {
  const MoocpFehler(this.status, this.text);
  final int status;
  final String text;
}

/// Eine Anfrage an die Adresse der App für Plugins: [pfad] ist die Funktion
/// (`/v1/…`), [daten] der Inhalt als JSON-Objekt, [aufruf] das Token des
/// laufenden Aufrufs (nur die Protokollzeile geht ohne). Liefert die Antwort
/// als JSON-Objekt; ein Fehlerstatus wird zu [MoocpFehler]. Zum Übernehmen in
/// ein eigenes Plugin: Schlüssel und Token sind geheim und gehen nur hierhin.
Future<Map<String, dynamic>> anMoocp(
  Uri? adresse,
  String pfad,
  Map<String, Object?> daten, {
  String? aufruf,
}) async {
  if (adresse == null) {
    throw const MoocpFehler(0, 'moocp hat beim Verbinden keine Adresse für Plugins genannt.');
  }
  final http = HttpClient();
  try {
    final anfrage = await http.postUrl(adresse.resolve(pfad));
    anfrage.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $_schluessel')
      ..contentType = ContentType.json;
    if (aufruf != null) anfrage.headers.set('Moocp-Aufruf', aufruf);
    anfrage.add(utf8.encode(jsonEncode(daten)));
    final antwort = await anfrage.close();
    final json = jsonDecode(await utf8.decoder.bind(antwort).join());
    if (antwort.statusCode != HttpStatus.ok) {
      throw MoocpFehler(antwort.statusCode, json is Map ? '${json['fehler']}' : 'Fehler ${antwort.statusCode}');
    }
    return (json as Map).cast<String, dynamic>();
  } on IOException {
    throw const MoocpFehler(0, 'moocp ist unter seiner Adresse für Plugins nicht erreichbar.');
  } finally {
    http.close(force: true);
  }
}
