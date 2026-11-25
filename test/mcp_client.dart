import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/mcp/kanal.dart';
import 'package:moocp/mcp/mcp_dienst.dart';

/// Ein MCP-Client wie eine Brücke: Er verbindet sich über den Kanal des
/// laufenden Servers, dessen Profil [port] hat (die Nummer des Profils dient
/// nur noch dazu, den Server zu finden), und spricht zeilenweises JSON-RPC.
/// Eine Verbindung ist eine MCP-Sitzung.
class McpTestClient {
  McpTestClient(this.port);
  final int port;
  int id = 0;
  KanalVerbindung? _verbindung;
  final _antworten = <Object?, Completer<Map>>{};

  Future<KanalVerbindung> _offen() async {
    final bestehend = _verbindung;
    if (bestehend != null) return bestehend;
    final name = McpDienst.kanalNameFuerTest(port);
    if (name == null) fail('Auf Profil-Nummer $port läuft kein MCP-Server.');
    final v = await standardKanalOrt.verbinden(name);
    v.eingang.transform(utf8.decoder).transform(const LineSplitter()).listen((zeile) {
      final n = jsonDecode(zeile);
      if (n is Map) _antworten.remove(n['id'])?.complete(n);
    });
    return _verbindung = v;
  }

  /// Schließt die Verbindung, wie ein Client, der sich beendet.
  Future<void> schliessen() async {
    final v = _verbindung;
    _verbindung = null;
    await v?.schliessen();
  }

  Future<Map> call(String method, [Map<String, Object?>? params, int? fehlercode]) async {
    final v = await _offen();
    final nummer = ++id;
    final antwort = _antworten[nummer] = Completer<Map>();
    v.senden(
      utf8.encode('${jsonEncode({'jsonrpc': '2.0', 'id': nummer, 'method': method, 'params': ?params})}\n'),
    );
    final decoded = await antwort.future.timeout(const Duration(seconds: 120));
    if (fehlercode != null) {
      final fehler = decoded['error'] as Map;
      expect(fehler['code'], fehlercode, reason: jsonEncode(decoded));
      return fehler;
    }
    expect(decoded['error'], isNull, reason: jsonEncode(decoded));
    return decoded['result'] as Map;
  }

  Future<void> initialize() async {
    await call('initialize', {
      'protocolVersion': '2025-06-18',
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'contract-test', 'version': '1'},
    });
    await notification('notifications/initialized');
  }

  Future<void> notification(String method, [Map<String, Object?>? params]) async {
    final v = await _offen();
    v.senden(utf8.encode('${jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': ?params})}\n'));
  }

  Future<String> tool(String name, Map<String, Object?> args) async {
    final r = await call('tools/call', {'name': name, 'arguments': args});
    return (r['content'] as List).map((e) => (e as Map)['text']).join('\n');
  }

  Future<String> waitStatus(
    String toolName,
    String number,
    bool Function(String) ready,
  ) async {
    var result = '';
    for (var i = 0; i < 100; i++) {
      result = await tool(toolName, {'id': number});
      if (ready(result)) return result;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('Status wurde nicht erreicht: $result');
  }
}
