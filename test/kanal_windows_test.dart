// Die Named Pipe unter Windows (lib/mcp/kanal_windows.dart) gegen Gegenstellen,
// die sich verbinden und wieder gehen: Eine Pipe mit überlappender Ein- und
// Ausgabe darf davon weder abstürzen noch hängen, und die nächste echte
// Verbindung muss danach gehen. Läuft nur unter Windows; die Auswertung des
// NTSTATUS prüft test/kanal_test.dart auf jeder Plattform.
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
    // Je angenommener Verbindung: wird vollständig, wenn ihr Eingang endet.
    final enden = <Completer<void>>[];

    setUp(() async {
      name = 'zz-pipe-$pid-${zaehler++}';
      angenommen.clear();
      enden.clear();
      lauscher = await WindowsKanal().lauschen(name);
      // Jede angenommene Verbindung wird wie in der App benutzt: gelesen, und
      // was ankommt, kommt zurück.
      lauscher.verbindungen.listen((v) {
        angenommen.add(v);
        final ende = Completer<void>();
        enden.add(ende);
        v.eingang.listen(
          (d) => v.senden(d),
          onError: (_) {},
          onDone: () => ende.complete(),
          cancelOnError: false,
        );
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

    /// Wartet, bis die App [n] Verbindungen angenommen hat.
    Future<void> bisAngenommen(int n) async {
      for (var i = 0; i < 200 && angenommen.length < n; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(angenommen.length, greaterThanOrEqualTo(n), reason: 'die App hat die Verbindung nicht angenommen');
    }

    test('schließt der Client, endet der Eingang der Verbindung (kein Hängen im Lesen)', () async {
      final roh = _Roh();
      final h = await roh.oeffnen(pipeName(eigeneSid(), name));
      expect(h, isNot(-1));
      await bisAngenommen(1);
      roh.schliessen(h);
      await enden.first.future.timeout(const Duration(seconds: 5));
      // Und die Pipe nimmt danach die nächste Verbindung an.
      await echoGeht();
    });

    test('ein Schreiben an einen nicht lesenden Client endet nach dessen Abbruch vollständig', () async {
      final roh = _Roh();
      final h = await roh.oeffnen(pipeName(eigeneSid(), name));
      expect(h, isNot(-1));
      await bisAngenommen(1);
      // Mehr als der Pipe-Puffer: Der Client liest nie, also bleibt der
      // Schreiber beschäftigt. Vor dem Trennen senden, solange der Leser die
      // Verbindung noch nicht geschlossen haben kann.
      angenommen.first.senden(List<int>.filled(8 * 1024 * 1024, 120));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      roh.schliessen(h);
      // Schließen bestätigt das Ende beider Arbeiter und des nativen Handles,
      // nicht bloß das unabhängig davon eintreffende Ende des Eingangs.
      await angenommen.first.schliessen().timeout(const Duration(seconds: 10));
      await enden.first.future.timeout(const Duration(seconds: 5));
      expect(enden.first.isCompleted, isTrue);
      await echoGeht();
    });

    test('Schließen des Lauschers mit offener, schweigender Gegenseite hängt nicht', () async {
      final roh = _Roh();
      final h = await roh.oeffnen(pipeName(eigeneSid(), name));
      expect(h, isNot(-1));
      await bisAngenommen(1);
      // Die angenommene Verbindung bleibt offen; der Lauscher schließt trotzdem zügig.
      final uhr = Stopwatch()..start();
      await lauscher.schliessen().timeout(const Duration(seconds: 10));
      expect(uhr.elapsed, lessThan(const Duration(seconds: 3)));
      for (final v in angenommen) {
        await v.schliessen();
      }
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
