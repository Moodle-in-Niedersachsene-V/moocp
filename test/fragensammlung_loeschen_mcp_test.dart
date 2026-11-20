// Das Löschen einer Fragensammlung durch den MCP-Dienst (E9, E20): Das Werkzeug `loeschen` bekommt den
// dauerhaften Sicherungsordner des Dienstes, und `status` nennt auf der Stufe „keine" das Löschen von
// Fragen und von Fragensammlungen unter dem, was weiter fragt. Nur Moodle ist ersetzt.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'hilfen/fragenbank_doppel.dart';
import 'mcp_client.dart';

void main() {
  late FragenbankDoppel moodle;
  late Directory ordner;
  late Directory sicherungen;
  late Freigaben freigaben;
  late McpDienst dienst;
  late McpTestClient client;

  setUp(() async {
    moodle = FragenbankDoppel();
    await moodle.starten();
    moodle.legeAn('shortanswer', 'ZZ Eins', 'zz-1');
    ordner = Directory.systemTemp.createTempSync('sammlung-mcp-');
    sicherungen = Directory.systemTemp.createTempSync('sammlung-mcp-sicherung-');
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final profil = Profil(
      kennung: 'stabil',
      name: 'Test',
      adresse: moodle.basis.toString(),
      port: port,
      mcpName: 'test',
      schluessel: 'test',
    );
    freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
    final zugang = await MoodleZugang.fuerTest(Protokoll(), moodle.basis,
        benutzer: FragenbankDoppel.benutzer, passwort: FragenbankDoppel.passwort, schreibvorgaengeOrdner: ordner.path);
    dienst = McpDienst(
      Einstellungen(schluessel: 'test', profile: [profil]),
      zugang,
      Protokoll(),
      freigaben,
      ordner.path,
      profil: profil,
      fragenSicherungsOrdner: sicherungen.path,
    );
    await dienst.starten();
    client = McpTestClient(port);
    await client.initialize();
  });

  tearDown(() async {
    await dienst.stoppen();
    client.http.close(force: true);
    await moodle.stoppen();
    for (final d in [ordner, sicherungen]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  test('loeschen einer Fragensammlung fragt auf Stufe „keine" mit Haken und sichert in den Ordner des Dienstes', () async {
    final antwort = client.tool('loeschen', {'kurs': 12, 'cmid': FragenbankDoppel.sammlung, 'name': 'ZZ Bank'});
    for (var i = 0; i < 400 && freigaben.aktuell == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final anfrage = freigaben.aktuell!;
    expect(anfrage.ab, Bestaetigungen.keine);
    expect(anfrage.abhaken, isNotEmpty);
    freigaben.entscheiden(true);
    final text = await antwort;
    expect(text, contains('verified: true'));
    final dateien = sicherungen.listSync(recursive: true).whereType<File>().toList();
    expect(dateien, hasLength(1));
    expect(text, contains(dateien.single.path));
    expect(p.dirname(dateien.single.path), sicherungen.path);
  });

  test('status nennt auf Stufe „keine" das Löschen von Fragen und von Fragensammlungen', () async {
    final text = await client.tool('status', {});
    expect(text, allOf(contains('Löschen von Fragen und von Fragensammlungen'), contains('Bestätigungen:')));
  });
}
