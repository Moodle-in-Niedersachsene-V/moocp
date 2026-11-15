// Gemeinsames für die Tests der Adresse der App für Plugins, die ein Plugin
// mit einem HTTP-Client im Test spielen: test/plugin_download_test.dart,
// test/plugin_lauf_test.dart, test/plugin_moodle_test.dart und
// test/plugin_schreiben_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:moocp/plugin/app_adresse.dart' show aufrufKopf;

/// Der Schlüssel, mit dem die Tests das Beispiel-Plugin an der Adresse der
/// App anmelden; erfunden.
const beispielSchluessel = 'schluessel-des-beispiels-0123456789abcdefghijkl';

/// Die Antwort der Adresse: Status, Inhalt als JSON, Kopfzeilen und der Text,
/// wie er ankam.
typedef AdresseAntwort = ({int status, Map json, HttpHeaders kopf, String roh});

/// Ein `POST` an [pfad] der Adresse der App, wie von einem Plugin mit
/// [schluessel] und, wenn genannt, dem Token [token] des laufenden Aufrufs.
Future<AdresseAntwort> anAdresse(
  Uri adresse,
  String pfad,
  Map<String, Object?> daten, {
  String? token,
  String schluessel = beispielSchluessel,
}) async {
  final http = HttpClient();
  try {
    final r = await http.postUrl(adresse.resolve(pfad));
    r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $schluessel');
    if (token != null) r.headers.set(aufrufKopf, token);
    r.headers.contentType = ContentType.json;
    r.add(utf8.encode(jsonEncode(daten)));
    final antwort = await r.close();
    final text = await utf8.decoder.bind(antwort).join();
    return (status: antwort.statusCode, json: jsonDecode(text) as Map, kopf: antwort.headers, roh: text);
  } finally {
    http.close(force: true);
  }
}
