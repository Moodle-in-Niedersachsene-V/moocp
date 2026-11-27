import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/bruecke_bauen.dart';

void main() {
  test('paketKonfigurationOhneHooks entfernt Pakete mit hook/build.dart und loest relative Pfade auf', () {
    final wurzel = Directory.systemTemp.createTempSync('bruecke-bauen-test-');
    addTearDown(() => wurzel.deleteSync(recursive: true));

    final dartTool = Directory.fromUri(Uri.directory(wurzel.path).resolve('.dart_tool/'))..createSync();
    final mitHook = Directory.fromUri(Uri.directory(wurzel.path).resolve('mit_hook/'))..createSync();
    File.fromUri(Uri.directory(mitHook.path).resolve('hook/build.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
    final ohneHook = Directory.fromUri(Uri.directory(wurzel.path).resolve('ohne_hook/'))..createSync();

    final eingabe = <String, Object?>{
      'configVersion': 2,
      'packages': [
        {'name': 'moocp', 'rootUri': '../', 'packageUri': 'lib/'},
        {'name': 'mit_hook', 'rootUri': Uri.directory(mitHook.path).toString(), 'packageUri': 'lib/'},
        {'name': 'ohne_hook', 'rootUri': '../ohne_hook', 'packageUri': 'lib/'},
      ],
    };

    final ergebnis = paketKonfigurationOhneHooks(eingabe, dartTool);
    final pakete = (ergebnis['packages'] as List).cast<Map<String, Object?>>();

    expect(pakete.map((e) => e['name']), ['moocp', 'ohne_hook']);
    expect(pakete[0]['rootUri'], startsWith('file://'));
    expect(pakete[1]['rootUri'], startsWith('file://'));
    expect(Directory.fromUri(Uri.parse(pakete[1]['rootUri'] as String)).resolveSymbolicLinksSync(),
        ohneHook.resolveSymbolicLinksSync());
  });
}
