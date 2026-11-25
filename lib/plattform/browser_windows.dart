// Windows: Der Browser bekommt seine Pipe als Dateinummern 3 (er liest) und 4
// (er schreibt) der C-Laufzeit, wie --remote-debugging-pipe sie erwartet.
// Process.start in Dart kann das nicht; deshalb ruft dieser Starter über
// dart:ffi CreatePipe und CreateProcessW selbst auf (kernel32.dll) und
// reicht die Pipe-Enden im Block `lpReserved2` der STARTUPINFO weiter -- so
// übergeben libuv und Puppeteer ihre Pipes an Kindprozesse.
//
// Aufbau von lpReserved2 (Laufzeit der MSVC, `_ioinit`): ein int mit der
// Zahl n der Dateinummern, dann n Bytes Flags, dann n Handles (je 8 Byte,
// ohne Ausrichtung). Dateinummer 0 bis 2 zeigen auf NUL, 3 und 4 auf die
// Pipe-Enden des Kindes.
//
// Nur diese drei Handles erbt das Kind (PROC_THREAD_ATTRIBUTE_HANDLE_LIST),
// kein anderes Handle der App. Die Enden der App sind nicht vererbbar, und die
// Kopien der Kind-Enden schließt die App gleich nach dem Start: Dann endet
// das Lesen, sobald der Browser weg ist. Die Umgebung des Kindes baut
// kindUmgebung (kindprozess.dart), nicht die der App.
//
// Das Lesen und Schreiben blockiert und läuft deshalb je in einem eigenen
// Isolate. Dieser Teil ließ sich nur unter Windows ausführen; der Rest der
// Pipe-Logik (cdp_pipe.dart, bildschirmfoto.dart) wird gegen einen
// nachgebauten Browser geprüft.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'browser_start.dart';
import 'kindprozess.dart';
import 'windows.dart' show prozessbaumBeendenWindows;

// Strukturen von kernel32.

final class _SecurityAttributes extends Struct {
  @Uint32()
  external int nLength;
  external Pointer<Void> lpSecurityDescriptor;
  @Int32()
  external int bInheritHandle;
}

/// STARTUPINFOEXW: STARTUPINFOW und die Liste der Attribute.
final class _StartupInfoEx extends Struct {
  @Uint32()
  external int cb;
  external Pointer<Utf16> lpReserved;
  external Pointer<Utf16> lpDesktop;
  external Pointer<Utf16> lpTitle;
  @Uint32()
  external int dwX;
  @Uint32()
  external int dwY;
  @Uint32()
  external int dwXSize;
  @Uint32()
  external int dwYSize;
  @Uint32()
  external int dwXCountChars;
  @Uint32()
  external int dwYCountChars;
  @Uint32()
  external int dwFillAttribute;
  @Uint32()
  external int dwFlags;
  @Uint16()
  external int wShowWindow;
  @Uint16()
  external int cbReserved2;
  external Pointer<Uint8> lpReserved2;
  external Pointer<Void> hStdInput;
  external Pointer<Void> hStdOutput;
  external Pointer<Void> hStdError;
  external Pointer<Void> lpAttributeList;
}

final class _ProcessInformation extends Struct {
  external Pointer<Void> hProcess;
  external Pointer<Void> hThread;
  @Uint32()
  external int dwProcessId;
  @Uint32()
  external int dwThreadId;
}

const _startfUseStdHandles = 0x100;
const _extendedStartupInfoPresent = 0x80000;
const _createUnicodeEnvironment = 0x400;
const _createNoWindow = 0x08000000;
const _procThreadAttributeHandleList = 0x00020002;
const _handleFlagInherit = 1;
const _genericReadWrite = 0xC0000000;
const _fileShareReadWrite = 3;
const _openExisting = 3;
const _stillActive = 259;

// Flags der C-Laufzeit je Dateinummer.
const _fOpen = 0x01, _fPipe = 0x08, _fDev = 0x40;

typedef _CreatePipeN = Int32 Function(
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
  Pointer<_SecurityAttributes>,
  Uint32,
);
typedef _CreatePipeD = int Function(
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
  Pointer<_SecurityAttributes>,
  int,
);
typedef _SetHandleInformationN = Int32 Function(Pointer<Void>, Uint32, Uint32);
typedef _SetHandleInformationD = int Function(Pointer<Void>, int, int);
typedef _CreateFileWN = Pointer<Void> Function(
  Pointer<Utf16>,
  Uint32,
  Uint32,
  Pointer<_SecurityAttributes>,
  Uint32,
  Uint32,
  Pointer<Void>,
);
typedef _CreateFileWD = Pointer<Void> Function(
  Pointer<Utf16>,
  int,
  int,
  Pointer<_SecurityAttributes>,
  int,
  int,
  Pointer<Void>,
);
typedef _CreateProcessWN = Int32 Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Void>,
  Pointer<Void>,
  Int32,
  Uint32,
  Pointer<Void>,
  Pointer<Utf16>,
  Pointer<_StartupInfoEx>,
  Pointer<_ProcessInformation>,
);
typedef _CreateProcessWD = int Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  int,
  Pointer<Void>,
  Pointer<Utf16>,
  Pointer<_StartupInfoEx>,
  Pointer<_ProcessInformation>,
);
typedef _InitAttrListN = Int32 Function(
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<IntPtr>,
);
typedef _InitAttrListD = int Function(Pointer<Void>, int, int, Pointer<IntPtr>);
typedef _UpdateAttrN = Int32 Function(
  Pointer<Void>,
  Uint32,
  IntPtr,
  Pointer<Void>,
  IntPtr,
  Pointer<Void>,
  Pointer<IntPtr>,
);
typedef _UpdateAttrD = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Void>,
  int,
  Pointer<Void>,
  Pointer<IntPtr>,
);
typedef _DeleteAttrListN = Void Function(Pointer<Void>);
typedef _DeleteAttrListD = void Function(Pointer<Void>);
typedef _CloseHandleN = Int32 Function(Pointer<Void>);
typedef _CloseHandleD = int Function(Pointer<Void>);
typedef _GetExitCodeN = Int32 Function(Pointer<Void>, Pointer<Uint32>);
typedef _GetExitCodeD = int Function(Pointer<Void>, Pointer<Uint32>);
typedef _TerminateN = Int32 Function(Pointer<Void>, Uint32);
typedef _TerminateD = int Function(Pointer<Void>, int);
typedef _ReadFileN = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _ReadFileD = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _WriteFileN = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _WriteFileD = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
);

/// Die Funktionen von kernel32, erst beim ersten Gebrauch geladen: Auf anderen
/// Plattformen wird die DLL nie angefasst.
class _Kernel32 {
  _Kernel32() : _l = DynamicLibrary.open('kernel32.dll');
  final DynamicLibrary _l;
  late final createPipe = _l.lookupFunction<_CreatePipeN, _CreatePipeD>(
    'CreatePipe',
  );
  late final setHandleInformation = _l
      .lookupFunction<_SetHandleInformationN, _SetHandleInformationD>(
        'SetHandleInformation',
      );
  late final createFile = _l.lookupFunction<_CreateFileWN, _CreateFileWD>(
    'CreateFileW',
  );
  late final createProcess = _l
      .lookupFunction<_CreateProcessWN, _CreateProcessWD>('CreateProcessW');
  late final initAttrList = _l.lookupFunction<_InitAttrListN, _InitAttrListD>(
    'InitializeProcThreadAttributeList',
  );
  late final updateAttr = _l.lookupFunction<_UpdateAttrN, _UpdateAttrD>(
    'UpdateProcThreadAttribute',
  );
  late final deleteAttrList = _l
      .lookupFunction<_DeleteAttrListN, _DeleteAttrListD>(
        'DeleteProcThreadAttributeList',
      );
  late final closeHandle = _l.lookupFunction<_CloseHandleN, _CloseHandleD>(
    'CloseHandle',
  );
  late final getExitCode = _l.lookupFunction<_GetExitCodeN, _GetExitCodeD>(
    'GetExitCodeProcess',
  );
  late final terminate = _l.lookupFunction<_TerminateN, _TerminateD>(
    'TerminateProcess',
  );
  late final readFile = _l.lookupFunction<_ReadFileN, _ReadFileD>('ReadFile');
  late final writeFile = _l.lookupFunction<_WriteFileN, _WriteFileD>(
    'WriteFile',
  );
}

/// Eine Zeile der Kommandozeile nach den Regeln, die CommandLineToArgvW
/// umkehrt: Anführungszeichen nur, wo nötig; Schrägstriche vor einem
/// Anführungszeichen verdoppeln.
String windowsArgument(String a) {
  if (a.isNotEmpty && !RegExp(r'[\s"]').hasMatch(a)) return a;
  final b = StringBuffer('"');
  var striche = 0;
  for (final z in a.runes) {
    if (z == 0x5C) {
      striche++;
      continue;
    }
    if (z == 0x22) {
      b
        ..write('\\' * (striche * 2 + 1))
        ..write('"');
    } else {
      b
        ..write('\\' * striche)
        ..writeCharCode(z);
    }
    striche = 0;
  }
  b
    ..write('\\' * (striche * 2))
    ..write('"');
  return b.toString();
}

/// Der Umgebungsblock für CreateProcessW: `name=wert` je Eintrag, jeder mit
/// NUL beendet, am Ende ein weiteres NUL, UTF-16, nach Namen sortiert.
List<int> windowsUmgebungsblock(Map<String, String> umgebung) {
  final namen = umgebung.keys.toList()
    ..sort((a, b) => a.toUpperCase().compareTo(b.toUpperCase()));
  final u = <int>[];
  for (final n in namen) {
    u
      ..addAll('$n=${umgebung[n]}'.codeUnits)
      ..add(0);
  }
  u
    ..add(0)
    ..add(0);
  return u;
}

/// Der Block `lpReserved2`: Dateinummern 0 bis 2 auf [nul], 3 auf [lesen]
/// (das Kind liest), 4 auf [schreiben] (das Kind schreibt). Handles als Zahlen.
Uint8List windowsReserved2({
  required int nul,
  required int lesen,
  required int schreiben,
}) {
  const n = 5;
  final b = ByteData(4 + n + n * 8);
  b.setInt32(0, n, Endian.little);
  final flags = [
    _fOpen | _fDev,
    _fOpen | _fDev,
    _fOpen | _fDev,
    _fOpen | _fPipe,
    _fOpen | _fPipe,
  ];
  final handles = [nul, nul, nul, lesen, schreiben];
  for (var i = 0; i < n; i++) {
    b.setUint8(4 + i, flags[i]);
    b.setInt64(4 + n + i * 8, handles[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

class WindowsBrowserStarter implements BrowserStarter {
  /// Der Profilordner liegt im Arbeitsordner im Temp-Verzeichnis des
  /// Benutzers; dessen Rechte erbt er, und kein anderes Konto liest ihn.
  @override
  Future<Directory> profilAnlegen(String arbeitsordner) async {
    final d = Directory(
      p.join(
        arbeitsordner,
        '.browser-${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    await d.create(recursive: true);
    return d;
  }

  @override
  Future<BrowserProzess> starten(
    String programm,
    List<String> argumente,
    Directory profil,
  ) async {
    final k = _Kernel32();
    final angelegt =
        <Pointer<Void>>[]; // Handles, die dieser Aufruf schließen muss
    void zu(Pointer<Void> h) {
      if (h.address != 0 && h.address != -1) k.closeHandle(h);
    }

    final sa = calloc<_SecurityAttributes>()
      ..ref.nLength = sizeOf<_SecurityAttributes>()
      ..ref.bInheritHandle = 1;
    final h = calloc<Pointer<Void>>(4);
    final liste = calloc<Pointer<Void>>(3);
    final reserviert = calloc<Uint8>(4 + 5 + 5 * 8);
    final info = calloc<_StartupInfoEx>();
    final pi = calloc<_ProcessInformation>();
    final nulName = 'NUL'.toNativeUtf16();
    Pointer<Void> attribute = nullptr;
    Pointer<Utf16> befehl = nullptr;
    Pointer<Uint16> umgebung = nullptr;
    Pointer<Utf16> programmZeiger = nullptr;
    try {
      // fd 3: Das Kind liest (kindLesen), die App schreibt (appSchreiben).
      if (k.createPipe(h, h + 1, sa, 0) == 0) {
        throw BrowserStartFehler(
          'Die Pipe zum Browser ließ sich nicht anlegen.',
        );
      }
      final kindLesen = h[0], appSchreiben = h[1];
      angelegt
        ..add(kindLesen)
        ..add(appSchreiben);
      // fd 4: Das Kind schreibt (kindSchreiben), die App liest (appLesen).
      if (k.createPipe(h + 2, h + 3, sa, 0) == 0) {
        throw BrowserStartFehler(
          'Die Pipe vom Browser ließ sich nicht anlegen.',
        );
      }
      final appLesen = h[2], kindSchreiben = h[3];
      angelegt
        ..add(appLesen)
        ..add(kindSchreiben);
      // Die Enden der App gehören nur der App.
      k.setHandleInformation(appSchreiben, _handleFlagInherit, 0);
      k.setHandleInformation(appLesen, _handleFlagInherit, 0);
      final nul = k.createFile(
        nulName,
        _genericReadWrite,
        _fileShareReadWrite,
        sa,
        _openExisting,
        0,
        nullptr,
      );
      if (nul.address == -1) {
        throw BrowserStartFehler('NUL ließ sich nicht öffnen.');
      }
      angelegt.add(nul);

      final r2 = windowsReserved2(
        nul: nul.address,
        lesen: kindLesen.address,
        schreiben: kindSchreiben.address,
      );
      reserviert.asTypedList(r2.length).setAll(0, r2);

      liste[0] = nul;
      liste[1] = kindLesen;
      liste[2] = kindSchreiben;
      final groesse = calloc<IntPtr>();
      k.initAttrList(nullptr, 1, 0, groesse); // liefert die nötige Größe
      attribute = calloc<Uint8>(groesse.value).cast();
      if (k.initAttrList(attribute, 1, 0, groesse) == 0 ||
          k.updateAttr(
                attribute,
                0,
                _procThreadAttributeHandleList,
                liste.cast(),
                3 * sizeOf<IntPtr>(),
                nullptr,
                nullptr,
              ) ==
              0) {
        calloc.free(groesse);
        throw BrowserStartFehler(
          'Die Handles des Browsers ließen sich nicht festlegen.',
        );
      }
      calloc.free(groesse);

      info.ref
        ..cb = sizeOf<_StartupInfoEx>()
        ..dwFlags = _startfUseStdHandles
        ..cbReserved2 = r2.length
        ..lpReserved2 = reserviert
        ..hStdInput = nul
        ..hStdOutput = nul
        ..hStdError = nul
        ..lpAttributeList = attribute;

      befehl = [
        programm,
        ...argumente,
      ].map(windowsArgument).join(' ').toNativeUtf16();
      final block = windowsUmgebungsblock(kindUmgebung());
      umgebung = calloc<Uint16>(block.length);
      umgebung.asTypedList(block.length).setAll(0, block);
      programmZeiger = programm.toNativeUtf16(allocator: calloc);
      final ok = k.createProcess(
        programmZeiger,
        befehl,
        nullptr,
        nullptr,
        1,
        _extendedStartupInfoPresent |
            _createUnicodeEnvironment |
            _createNoWindow,
        umgebung.cast(),
        nullptr,
        info,
        pi,
      );
      if (ok == 0) {
        throw BrowserStartFehler(
          'Der Browser ließ sich nicht starten (CreateProcessW).',
        );
      }
      // Die Kind-Enden gehören jetzt dem Browser; unsere Kopien schließen, sonst
      // endet das Lesen nie.
      zu(kindLesen);
      zu(kindSchreiben);
      zu(nul);
      zu(pi.ref.hThread);
      angelegt.clear();
      final proz = pi.ref.hProcess;
      // Der Browser läuft schon: Scheitert der Rest des Aufbaus, wird er
      // beendet und alles geschlossen, sonst bliebe er ohne Besitzer.
      return await beiFehlerAufraeumen(
        () => _WindowsProzess.start(
          k,
          proz,
          pi.ref.dwProcessId,
          appSchreiben,
          appLesen,
        ),
        () {
          k.terminate(proz, 1);
          zu(proz);
          zu(appSchreiben);
          zu(appLesen);
        },
      );
    } finally {
      for (final x in angelegt) {
        zu(x);
      }
      if (attribute.address != 0) {
        k.deleteAttrList(attribute);
        calloc.free(attribute);
      }
      if (befehl.address != 0) calloc.free(befehl);
      if (umgebung.address != 0) calloc.free(umgebung);
      if (programmZeiger.address != 0) calloc.free(programmZeiger);
      calloc
        ..free(sa)
        ..free(h)
        ..free(liste)
        ..free(reserviert)
        ..free(info)
        ..free(pi)
        ..free(nulName);
    }
  }
}

/// Liest [handle] in einem eigenen Isolate und schickt die Stücke an [an];
/// null am Ende (Pipe geschlossen oder Fehler).
void _lesen((SendPort, int) a) {
  final k = _Kernel32();
  final h = Pointer<Void>.fromAddress(a.$2);
  final puffer = calloc<Uint8>(65536);
  final n = calloc<Uint32>();
  try {
    while (k.readFile(h, puffer, 65536, n, nullptr) != 0 && n.value > 0) {
      a.$1.send(
        TransferableTypedData.fromList([
          Uint8List.fromList(puffer.asTypedList(n.value)),
        ]),
      );
    }
  } finally {
    calloc
      ..free(puffer)
      ..free(n);
    k.closeHandle(h);
    a.$1.send(null);
  }
}

/// Schreibt, was ankommt, in [handle]; null schließt das Ende.
void _schreiben((SendPort, int) a) {
  final k = _Kernel32();
  final h = Pointer<Void>.fromAddress(a.$2);
  final empfang = ReceivePort();
  a.$1.send(empfang.sendPort);
  final n = calloc<Uint32>();
  empfang.listen((m) {
    if (m is TransferableTypedData) {
      final b = m.materialize().asUint8List();
      final p = calloc<Uint8>(b.length);
      p.asTypedList(b.length).setAll(0, b);
      var weg = 0;
      while (weg < b.length &&
          k.writeFile(h, p + weg, b.length - weg, n, nullptr) != 0 &&
          n.value > 0) {
        weg += n.value;
      }
      calloc.free(p);
    } else {
      calloc.free(n);
      k.closeHandle(h);
      empfang.close();
      Isolate.exit();
    }
  });
}

class _WindowsProzess implements BrowserProzess {
  _WindowsProzess._(this._k, this._proz, this.pid, this._an, this._ein);

  static Future<_WindowsProzess> start(
    _Kernel32 k,
    Pointer<Void> proz,
    int pid,
    Pointer<Void> appSchreiben,
    Pointer<Void> appLesen,
  ) async {
    final lese = ReceivePort(), schreibe = ReceivePort();
    final ein = StreamController<List<int>>();
    await Isolate.spawn(_lesen, (lese.sendPort, appLesen.address));
    await Isolate.spawn(_schreiben, (schreibe.sendPort, appSchreiben.address));
    final an = Completer<SendPort>();
    schreibe.listen((m) {
      if (m is SendPort && !an.isCompleted) an.complete(m);
    });
    lese.listen((m) {
      if (m is TransferableTypedData) {
        ein.add(m.materialize().asUint8List());
      } else {
        lese.close();
        if (!ein.isClosed) unawaited(ein.close());
      }
    });
    return _WindowsProzess._(k, proz, pid, await an.future, ein);
  }

  final _Kernel32 _k;
  final Pointer<Void> _proz;
  final SendPort _an;
  final StreamController<List<int>> _ein;
  var _zu = false;

  @override
  final int pid;

  @override
  Stream<List<int>> get eingang => _ein.stream;

  @override
  void senden(List<int> bytes) {
    if (_zu) return;
    _an.send(
      TransferableTypedData.fromList([
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      ]),
    );
  }

  /// Einmal berechnet und mit [beenden] zu Ende: Danach wird das Handle nie
  /// mehr abgefragt (geschlossen kann seine Nummer wieder vergeben sein).
  @override
  late final Future<int> beendet = _warten();

  Future<int> _warten() async {
    final code = calloc<Uint32>();
    try {
      while (!_zu) {
        if (_k.getExitCode(_proz, code) == 0) return -1;
        if (code.value != _stillActive) return code.value;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return -1;
    } finally {
      calloc.free(code);
    }
  }

  @override
  Future<void> beenden() async {
    if (_zu) return;
    _zu = true;
    // Zuerst der Baum (taskkill /T geht über die Elternnummer und braucht den
    // lebenden Prozess), dann der Prozess selbst.
    await prozessbaumBeendenWindows(pid);
    _k.terminate(_proz, 1);
    _an.send(null);
    _k.closeHandle(_proz);
  }
}
