// Eigene Testdatei = eigener Testerprozess: Vor dem ersten fehlgeschlagenen
// Öffnen darf keine andere Kanalprobe GetLastError bereits gebunden haben.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/mcp/kanal.dart';
import 'package:moocp/mcp/kanal_windows.dart';

void main() {
  test('erster Öffnungsversuch ohne Lauscher meldet KanalNichtDa', () async {
    await expectLater(WindowsKanal().verbinden('zz-kaltstart-$pid'), throwsA(isA<KanalNichtDa>()));
  }, skip: Platform.isWindows ? null : 'Windows: erster fehlgeschlagener nativer Aufruf');
}
