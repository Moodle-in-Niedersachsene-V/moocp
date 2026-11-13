// Der Schlüssel eines Entwicklungs-Plugins vererbt sich an kein Programm, das
// moocp startet (plattform/kindprozess.dart): die Umgebung eines Kindes, ein
// echtes Kind mit Enkel, und der Quelltext, der keinen anderen Weg zum Starten
// eines Programms kennt.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/plattform/kindprozess.dart';
import 'package:path/path.dart' as p;

/// Das `dart` des Flutter-SDK, mit dem die Tests laufen (wie in
/// plugin_start_test.dart).
String _dart() {
  final exe = Platform.isWindows ? 'dart.exe' : 'dart';
  final wurzel = Platform.environment['FLUTTER_ROOT'];
  if (wurzel != null) {
    final f = File(p.join(wurzel, 'bin', 'cache', 'dart-sdk', 'bin', exe));
    if (f.existsSync()) return f.path;
  }
  var d = File(Platform.resolvedExecutable).parent;
  while (d.parent.path != d.path) {
    final f = File(p.join(d.path, 'dart-sdk', 'bin', exe));
    if (f.existsSync()) return f.path;
    d = d.parent;
  }
  throw StateError('Das dart des Flutter-SDK ist nicht zu finden.');
}

void main() {
  group('Umgebung eines Kindprozesses', () {
    test('ohne den Schlüssel, alles andere bleibt', () {
      final u = kindUmgebung(von: const {schluesselVariable: 'geheim', 'PATH': '/bin', 'HOME': '/home/erika'});
      expect(u.containsKey(schluesselVariable), isFalse);
      expect(u, {'PATH': '/bin', 'HOME': '/home/erika'});
    });

    test('unter Windows in jeder Schreibweise', () {
      final u = kindUmgebung(von: const {'moocp_plugin_schluessel': 'geheim', 'Path': 'C:\\'}, windows: true);
      expect(u, {'Path': 'C:\\'});
    });

    test('anderswo gilt nur die genaue Schreibweise', () {
      final u = kindUmgebung(von: const {'moocp_plugin_schluessel': 'x'}, windows: false);
      expect(u, {'moocp_plugin_schluessel': 'x'});
    });

    test('ein gestartetes Plugin bekommt seinen eigenen Schlüssel', () {
      final u = kindUmgebung(von: const {schluesselVariable: 'alt'}, dazu: const {schluesselVariable: 'frisch'});
      expect(u[schluesselVariable], 'frisch');
    });
  });

  test('ein echtes Kind erbt den Schlüssel nicht, ein Plugin bekommt seinen', () async {
    // Der Test selbst hat den Schlüssel nicht in der Umgebung; darum startet er
    // ein Programm mit Schlüssel, und das startet über kindprozess.dart seine
    // Enkel. Was die Enkel sehen, schreibt es auf stdout.
    final ordner = Directory.systemTemp.createTempSync('moocp_kind_');
    addTearDown(() async {
      for (var i = 0; i < 50 && ordner.existsSync(); i++) {
        try {
          ordner.deleteSync(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    });
    final pakete = File(p.join('.dart_tool', 'package_config.json')).absolute.path;
    final skript = File(p.join(ordner.path, 'kind.dart'))
      ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
import 'package:moocp/plattform/kindprozess.dart';
Future<void> main(List<String> a) async {
  if (a.first == 'enkel') {
    stdout.write('\${Platform.environment[schluesselVariable] ?? '-'}|\${Platform.environment['MOOCP_TEST_ANDERE'] ?? '-'}');
    return;
  }
  final dart = a[1], pakete = a[2];
  final argumente = ['--packages=\$pakete', Platform.script.toFilePath(), 'enkel'];
  final r = await prozessAusfuehren(dart, argumente);
  final s = await prozessStarten(dart, argumente, dazu: const {schluesselVariable: 'frisch'});
  final t = await s.stdout.transform(utf8.decoder).join();
  await s.exitCode;
  stdout.write('\${r.stdout}\\n\$t');
}
''');
    final r = await Process.run(
      _dart(),
      ['--packages=$pakete', skript.path, 'kind', _dart(), pakete],
      environment: {schluesselVariable: 'geheim', 'MOOCP_TEST_ANDERE': 'bleibt'},
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect('${r.stdout}'.trim().split('\n'), ['-|bleibt', 'frisch|bleibt']);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('kein Process.start oder Process.run in lib/ an kindprozess.dart vorbei', () {
    // Ohne die Kommentare: Die nennen die Aufrufe gerade, um zu sagen, wo sie
    // stehen dürfen.
    final aufruf = RegExp(r'\bProcess\s*\.\s*(start|run|runSync)\b');
    final vorbei = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final pfad = p.posix.joinAll(p.split(f.path));
      if (pfad == 'lib/plattform/kindprozess.dart') continue;
      final code = f.readAsLinesSync().where((z) => !z.trimLeft().startsWith('//')).join('\n');
      if (aufruf.hasMatch(code)) vorbei.add(pfad);
    }
    expect(vorbei, isEmpty, reason: 'Programme startet nur plattform/kindprozess.dart');
  });

  test('kindprozess.dart gibt jedem Aufruf die Umgebung ohne Schlüssel', () {
    final code = File('lib/plattform/kindprozess.dart')
        .readAsLinesSync()
        .where((z) => !z.trimLeft().startsWith('//'))
        .join('\n');
    final aufrufe = RegExp(r'\bProcess\s*\.\s*(start|run|runSync)\s*\(').allMatches(code).length;
    expect(aufrufe, 3);
    expect(RegExp(r'includeParentEnvironment:\s*false').allMatches(code).length, aufrufe);
    expect(RegExp(r'environment:\s*kindUmgebung\(').allMatches(code).length, aufrufe);
  });
}
