// Die Werkzeugliste, die die App für die Brücke ablegt (nur Linux und Mac,
// KanalOrt.listeLesen): Ein gelöschtes Profil hinterlässt keine, damit ein
// späteres Profil mit demselben Namen sie nicht erbt. Das Anlegen und das
// Umschalten von Plugins steht in profile_ausblenden_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/main.dart';
import 'package:moocp/mcp/kanal.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

Profil _profil(String kennung, String name, String mcp, int port) =>
    Profil(kennung: kennung, name: name, adresse: 'https://$mcp.schule.example', port: port, mcpName: mcp);

void main() {
  test('ein gelöschtes Profil hinterlässt keine Liste, die anderen behalten ihre', () async {
    final wurzel = Directory.systemTemp.createTempSync('moocp_liste_');
    addTearDown(() => wurzel.deleteSync(recursive: true));
    final kanal = UnixKanal(ketten: () => [[p.join(wurzel.path, 'k')]]);
    final protokoll = Protokoll();
    final ort = WerkzeuglisteOrt(
      kanal: kanal,
      einstellungen: () => File(p.join(wurzel.path, 'nicht-da.json')),
      plugins: () => Directory(p.join(wurzel.path, 'plugins')),
    );
    final standard = _profil(Profil.standardKennung, 'Moodle', 'moodle', 47811);
    final zweites = _profil('k2', 'Moodle Test', 'moodle-test', 47812);
    await werkzeuglisteAblegen(protokoll, [standard, zweites], ort: ort);
    expect(await kanal.listeLesen('moodle-test'), isNotNull);

    await werkzeuglisteEntfernen(protokoll, zweites, ort: ort);

    expect(await kanal.listeLesen('moodle-test'), isNull);
    expect(File(p.join(wurzel.path, 'k', 'werkzeugliste-moodle-test.json')).existsSync(), isFalse);
    expect(await kanal.listeLesen('moodle'), isNotNull);
  }, skip: Platform.isWindows);
}
