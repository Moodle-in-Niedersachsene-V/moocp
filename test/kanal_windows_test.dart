// Die Named Pipe unter Windows (lib/mcp/kanal_windows.dart) gegen Gegenstellen,
// die sich verbinden und wieder gehen: Eine Pipe mit überlappender Ein- und
// Ausgabe darf davon weder abstürzen noch hängen, und die nächste echte
// Verbindung muss danach gehen. Läuft nur unter Windows; die Auswertung von
// OVERLAPPED.Internal prüft test/kanal_test.dart auf jeder Plattform.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/mcp/kanal.dart';
import 'package:moocp/mcp/kanal_windows.dart';

/// Ein roher Client ohne die Prüfungen der Brücke: öffnet die Pipe wie
/// PowerShell (`Get-Acl`) oder ein beliebiges Programm desselben Kontos.
class _Roh {
  _Roh() {
    final k = DynamicLibrary.open('kernel32.dll');
    _createFile = k.lookupFunction<
      IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer, Uint32, Uint32, IntPtr),
      int Function(Pointer<Utf16>, int, int, Pointer, int, int, int)
    >('CreateFileW');
    _close = k.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
    _getLastError = k.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  }
  late final int Function(Pointer<Utf16>, int, int, Pointer, int, int, int) _createFile;
  late final int Function(int) _close;
  late final int Function() _getLastError;

  /// Öffnet die Pipe; -1 bei einem Fehler (etwa „beschäftigt“, wenn gerade
  /// keine Instanz frei ist: dann kurz warten und noch einmal).
  Future<int> oeffnen(String pipe) async {
    final n = pipe.toNativeUtf16();
    try {
      for (var i = 0; i < 100; i++) {
        final h = _createFile(n, 0x80000000 | 0x40000000, 0, nullptr, 3, 0, 0);
        if (h != -1) return h;
        if (_getLastError() != 231) return -1;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return -1;
    } finally {
      malloc.free(n);
    }
  }

  void schliessen(int h) => _close(h);
}

void main() {
  final String? nurWindows = Platform.isWindows ? null : 'Windows: Named Pipe';
  var zaehler = 0;

  group('Named Pipe: Gegenstellen, die kommen und gehen', skip: nurWindows, () {
    late String name;
    late KanalLauscher lauscher;
    final angenommen = <KanalVerbindung>[];

    setUp(() async {
      name = 'zz-pipe-$pid-${zaehler++}';
      angenommen.clear();
      lauscher = await WindowsKanal().lauschen(name);
      // Jede angenommene Verbindung wird wie in der App benutzt: gelesen, und
      // was ankommt, kommt zurück.
      lauscher.verbindungen.listen((v) {
        angenommen.add(v);
        v.eingang.listen((d) => v.senden(d), onError: (_) {}, cancelOnError: false);
      });
    });
    tearDown(() async {
      for (final v in angenommen) {
        await v.schliessen();
      }
      await lauscher.schliessen();
    });

    Future<void> echoGeht() async {
      final c = await WindowsKanal().verbinden(name);
      final antwort = Completer<String>();
      final puffer = StringBuffer();
      c.eingang.transform(utf8.decoder).listen((t) {
        puffer.write(t);
        if (puffer.toString().contains('\n') && !antwort.isCompleted) antwort.complete(puffer.toString());
      });
      c.senden(utf8.encode('{"ping":1}\n'));
      expect(await antwort.future.timeout(const Duration(seconds: 10)), '{"ping":1}\n');
      await c.schliessen();
    }

    test('viele Clients, die sich sofort wieder trennen, und einer, der nie etwas sendet: die Pipe bleibt benutzbar', () async {
      final pipe = pipeName(eigeneSid(), name);
      final roh = _Roh();
      for (var i = 0; i < 60; i++) {
        final h = await roh.oeffnen(pipe);
        expect(h, isNot(-1), reason: 'Verbindung $i');
        roh.schliessen(h);
      }
      // Einer verbindet sich und schweigt.
      final stumm = await roh.oeffnen(pipe);
      expect(stumm, isNot(-1));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await echoGeht(); // eine normale Brückenverbindung daneben
      await echoGeht();

      // Die Pipe gibt es noch, und der stumme Client hält niemanden auf.
      final nochEiner = await roh.oeffnen(pipe);
      expect(nochEiner, isNot(-1));
      roh.schliessen(nochEiner);
      roh.schliessen(stumm);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await echoGeht();
    });

    test('Schließen des Lauschers mit offener, schweigender Gegenseite hängt nicht', () async {
      final roh = _Roh();
      final h = await roh.oeffnen(pipeName(eigeneSid(), name));
      expect(h, isNot(-1));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      for (final v in angenommen) {
        await v.schliessen();
      }
      await lauscher.schliessen().timeout(const Duration(seconds: 10));
      roh.schliessen(h);
      // Danach gibt es die Pipe nicht mehr.
      for (var i = 0; i < 100; i++) {
        try {
          await (await WindowsKanal().verbinden(name)).schliessen();
        } on KanalNichtDa {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('die Pipe ist nach dem Schließen noch da');
    });
  });
}
