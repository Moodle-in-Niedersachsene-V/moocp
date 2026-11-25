// Der Kanal unter Windows: eine Named Pipe, die nur das eigene Konto erreicht
// (kanal.dart).
//
// Der Name der Pipe enthält die SID des Kontos und den Profilnamen
// (`\\.\pipe\moocp-<SID>-<Profil>`). Der Name allein schützt nicht -- der
// Namensraum der Pipes gehört allen Konten, und jedes Konto kann ihn ausrechnen
// --, darum gilt:
//
// - Die App legt die erste Instanz mit FILE_FLAG_FIRST_PIPE_INSTANCE an: Hat
//   ein anderes Konto den Namen schon belegt, scheitert der Start, statt dass
//   die App neben einer fremden Pipe lauscht. Fernzugriffe sind ausgeschlossen
//   (PIPE_REJECT_REMOTE_CLIENTS).
// - Die Zugriffsliste (DACL) der Pipe erlaubt nur der SID des Kontos jeden
//   Zugriff; eine Vererbung gibt es nicht.
// - Die App prüft von jedem Client, der sich verbindet, die SID im Token seines
//   Prozesses (GetNamedPipeClientProcessId), bevor sie etwas liest; die Brücke
//   prüft ebenso die SID des Prozesses, der die Pipe bedient
//   (GetNamedPipeServerProcessId), bevor sie etwas sendet. Die Brücke öffnet die
//   Pipe mit SECURITY_IDENTIFICATION: Ein Server darf sie nicht nachahmen.
//
// Gelesen und geschrieben wird blockierend, je Richtung in einem eigenen
// Isolate (dart:ffi kennt keine Ereignisse der Pipe) und mit überlappender
// Ein- und Ausgabe: Auf einer Pipe ohne sie wartete ein Schreiben, solange ein
// Lesen auf demselben Handle hängt.
//
// Nur die reine Logik (Namen, Zugriffsliste, Fehlernummern) lässt sich ohne
// Windows prüfen (test/kanal_test.dart); alles andere ist nur hier umgesetzt.
// Ohne Flutter: Die Brücke (mcp/bruecke.dart) bindet diese Datei ein.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'kanal.dart';

/// Der Name der Pipe: SID des Kontos und Profilname. Die SID besteht nur aus
/// `S`, Ziffern und Bindestrichen, der Profilname nur aus Kleinbuchstaben,
/// Ziffern und Bindestrichen ([kanalNameGueltig]).
String pipeName(String sid, String profil) => r'\\.\pipe\moocp-' '$sid-$profil';

/// Ob [sid] wie eine SID aussieht (`S-1-5-21-…`): Nur sie kommt in einen
/// Pipe-Namen und in die Zugriffsliste.
bool sidGueltig(String sid) => RegExp(r'^S-\d+(-\d+)+$').hasMatch(sid);

/// Die Zugriffsliste (SDDL) der Pipe: geschützt (`P`, keine Vererbung), und
/// genau ein Eintrag, der der SID des Kontos jeden Zugriff erlaubt (`GA`).
String sddlNurKonto(String sid) {
  if (!sidGueltig(sid)) throw ArgumentError('keine SID');
  return 'D:P(A;;GA;;;$sid)';
}

/// Was ein Fehler beim Öffnen der Pipe bedeutet: niemand lauscht (die Pipe
/// gibt es nicht) oder der Zugriff ist verwehrt (die Pipe gehört nicht dem
/// Konto), null bei allem anderen. 2 = ERROR_FILE_NOT_FOUND, 3 =
/// ERROR_PATH_NOT_FOUND, 5 = ERROR_ACCESS_DENIED.
KanalFehler? verbindungsFehlerFuer(int code) => switch (code) {
  2 || 3 => KanalNichtDa(),
  5 => KanalUnsicher('Der Kanal gehört einem anderen Konto.'),
  _ => null,
};

// ---------------------------------------------------------------------------
// Die Windows-Aufrufe
// ---------------------------------------------------------------------------

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _advapi32 = DynamicLibrary.open('advapi32.dll');

final _getLastError = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
final _closeHandle = _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final _getCurrentProcess = _kernel32.lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
final _openProcess = _kernel32.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>(
  'OpenProcess',
);
final _localFree = _kernel32.lookupFunction<Pointer Function(Pointer), Pointer Function(Pointer)>('LocalFree');
final _createEvent = _kernel32.lookupFunction<
  IntPtr Function(Pointer, Int32, Int32, Pointer),
  int Function(Pointer, int, int, Pointer)
>('CreateEventW');
final _createNamedPipe = _kernel32.lookupFunction<
  IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Uint32, Uint32, Uint32, Uint32, Pointer),
  int Function(Pointer<Utf16>, int, int, int, int, int, int, Pointer)
>('CreateNamedPipeW');
final _connectNamedPipe = _kernel32.lookupFunction<
  Int32 Function(IntPtr, Pointer),
  int Function(int, Pointer)
>('ConnectNamedPipe');
final _disconnectNamedPipe = _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DisconnectNamedPipe');
final _createFile = _kernel32.lookupFunction<
  IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer, Uint32, Uint32, IntPtr),
  int Function(Pointer<Utf16>, int, int, Pointer, int, int, int)
>('CreateFileW');
final _waitNamedPipe = _kernel32.lookupFunction<Int32 Function(Pointer<Utf16>, Uint32), int Function(Pointer<Utf16>, int)>(
  'WaitNamedPipeW',
);
final _readFile = _kernel32.lookupFunction<
  Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer),
  int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer)
>('ReadFile');
final _writeFile = _kernel32.lookupFunction<
  Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer),
  int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer)
>('WriteFile');
final _getOverlappedResult = _kernel32.lookupFunction<
  Int32 Function(IntPtr, Pointer, Pointer<Uint32>, Int32),
  int Function(int, Pointer, Pointer<Uint32>, int)
>('GetOverlappedResult');
final _cancelIoEx = _kernel32.lookupFunction<Int32 Function(IntPtr, Pointer), int Function(int, Pointer)>('CancelIoEx');
final _getClientPid = _kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
  'GetNamedPipeClientProcessId',
);
final _getServerPid = _kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
  'GetNamedPipeServerProcessId',
);
final _openProcessToken = _advapi32.lookupFunction<
  Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
  int Function(int, int, Pointer<IntPtr>)
>('OpenProcessToken');
final _getTokenInformation = _advapi32.lookupFunction<
  Int32 Function(IntPtr, Int32, Pointer, Uint32, Pointer<Uint32>),
  int Function(int, int, Pointer, int, Pointer<Uint32>)
>('GetTokenInformation');
final _sidToString = _advapi32.lookupFunction<
  Int32 Function(Pointer, Pointer<Pointer<Utf16>>),
  int Function(Pointer, Pointer<Pointer<Utf16>>)
>('ConvertSidToStringSidW');
final _sddlZuBeschreibung = _advapi32.lookupFunction<
  Int32 Function(Pointer<Utf16>, Uint32, Pointer<Pointer>, Pointer<Uint32>),
  int Function(Pointer<Utf16>, int, Pointer<Pointer>, Pointer<Uint32>)
>('ConvertStringSecurityDescriptorToSecurityDescriptorW');

const _invalidHandle = -1;
const _genericRead = 0x80000000;
const _genericWrite = 0x40000000;
const _openExisting = 3;
const _fileFlagOverlapped = 0x40000000;
const _securitySqosPresent = 0x00100000; // SECURITY_SQOS_PRESENT; mit 0 = SECURITY_ANONYMOUS
const _securityIdentification = 0x00010000;
const _pipeAccessDuplex = 3;
const _fileFlagFirstPipeInstance = 0x00080000;
const _pipeRejectRemoteClients = 8;
const _pipeUnlimitedInstances = 255;
const _tokenQuery = 8;
const _tokenUser = 1;
const _processQueryLimitedInformation = 0x1000;
const _errorIoPending = 997;
const _errorPipeConnected = 535;
const _errorPipeBusy = 231;
const _pufferGroesse = 64 * 1024;

/// OVERLAPPED hat auf 64-Bit-Windows 32 Bytes: Internal, InternalHigh,
/// Offset/OffsetHigh (oder Pointer) und das Ereignis.
const _overlappedGroesse = 32;
const _overlappedEreignis = 24;

/// Die SID (als Text) zu einem Token-Handle; null, wenn sie sich nicht lesen lässt.
String? _sidVonToken(int token) {
  final laenge = calloc<Uint32>();
  try {
    _getTokenInformation(token, _tokenUser, nullptr, 0, laenge);
    final n = laenge.value;
    if (n == 0) return null;
    final puffer = calloc<Uint8>(n);
    try {
      if (_getTokenInformation(token, _tokenUser, puffer, n, laenge) == 0) return null;
      // TOKEN_USER beginnt mit dem Zeiger auf die SID.
      final sid = Pointer<Uint8>.fromAddress(puffer.cast<IntPtr>().value);
      final text = calloc<Pointer<Utf16>>();
      try {
        if (_sidToString(sid, text) == 0) return null;
        final s = text.value.toDartString();
        _localFree(text.value.cast());
        return s;
      } finally {
        calloc.free(text);
      }
    } finally {
      calloc.free(puffer);
    }
  } finally {
    calloc.free(laenge);
  }
}

/// Die SID des Kontos, dem der Prozess [prozess] gehört; null, wenn sie sich
/// nicht feststellen lässt.
String? _sidVonProzess(int prozess) {
  final token = calloc<IntPtr>();
  try {
    if (_openProcessToken(prozess, _tokenQuery, token) == 0) return null;
    try {
      return _sidVonToken(token.value);
    } finally {
      _closeHandle(token.value);
    }
  } finally {
    calloc.free(token);
  }
}

/// Die SID des Kontos, das diese App ausführt.
String eigeneSid() {
  final s = _sidVonProzess(_getCurrentProcess());
  if (s == null || !sidGueltig(s)) throw KanalUnsicher('Das Konto ließ sich nicht feststellen.');
  return s;
}

/// Die SID des Kontos, dem der Prozess mit der Nummer [pid] gehört.
String? _sidVonPid(int pid) {
  final h = _openProcess(_processQueryLimitedInformation, 0, pid);
  if (h == 0) return null;
  try {
    return _sidVonProzess(h);
  } finally {
    _closeHandle(h);
  }
}

// ---------------------------------------------------------------------------
// Verbindung: ein Handle, ein Isolate je Richtung
// ---------------------------------------------------------------------------

/// Liest in einem eigenen Isolate und meldet jeden Block, am Ende `null`.
void _leser(List<Object> start) {
  final handle = start[0] as int;
  final aus = start[1] as SendPort;
  final puffer = calloc<Uint8>(_pufferGroesse);
  final gelesen = calloc<Uint32>();
  final ov = calloc<Uint8>(_overlappedGroesse);
  final ereignis = _createEvent(nullptr, 1, 0, nullptr);
  try {
    while (true) {
      ov.cast<Uint8>().asTypedList(_overlappedGroesse).fillRange(0, _overlappedGroesse, 0);
      Pointer<IntPtr>.fromAddress(ov.address + _overlappedEreignis).value = ereignis;
      var ok = _readFile(handle, puffer, _pufferGroesse, gelesen, ov);
      if (ok == 0) {
        if (_getLastError() != _errorIoPending) break;
        ok = _getOverlappedResult(handle, ov, gelesen, 1);
        if (ok == 0) break;
      }
      if (gelesen.value == 0) break;
      aus.send(Uint8List.fromList(puffer.asTypedList(gelesen.value)));
    }
  } finally {
    aus.send(null);
    _closeHandle(ereignis);
    calloc.free(ov);
    calloc.free(gelesen);
    calloc.free(puffer);
  }
}

/// Schreibt in einem eigenen Isolate, was es bekommt; `null` beendet es.
void _schreiber(List<Object> start) {
  final handle = start[0] as int;
  final eingang = ReceivePort();
  (start[1] as SendPort).send(eingang.sendPort);
  final geschrieben = calloc<Uint32>();
  final ov = calloc<Uint8>(_overlappedGroesse);
  final ereignis = _createEvent(nullptr, 1, 0, nullptr);
  eingang.listen((m) {
    if (m is! Uint8List) {
      _closeHandle(ereignis);
      calloc.free(ov);
      calloc.free(geschrieben);
      eingang.close();
      return;
    }
    final daten = calloc<Uint8>(m.length);
    try {
      daten.asTypedList(m.length).setAll(0, m);
      var offen = 0;
      while (offen < m.length) {
        ov.asTypedList(_overlappedGroesse).fillRange(0, _overlappedGroesse, 0);
        Pointer<IntPtr>.fromAddress(ov.address + _overlappedEreignis).value = ereignis;
        var ok = _writeFile(handle, daten + offen, m.length - offen, geschrieben, ov);
        if (ok == 0) {
          if (_getLastError() != _errorIoPending) return;
          ok = _getOverlappedResult(handle, ov, geschrieben, 1);
          if (ok == 0) return;
        }
        offen += geschrieben.value;
      }
    } finally {
      calloc.free(daten);
    }
  });
}

class _PipeVerbindung implements KanalVerbindung {
  _PipeVerbindung._(this._handle, this._server, this._schreiberPort);

  final int _handle;
  final bool _server;
  final SendPort _schreiberPort;
  final _eingang = StreamController<List<int>>();
  bool _zu = false;

  static Future<_PipeVerbindung> oeffnen(int handle, {required bool server}) async {
    final leserPort = ReceivePort();
    final schreiberPort = ReceivePort();
    await Isolate.spawn(_schreiber, [handle, schreiberPort.sendPort]);
    final senden = await schreiberPort.first as SendPort;
    final v = _PipeVerbindung._(handle, server, senden);
    await Isolate.spawn(_leser, [handle, leserPort.sendPort]);
    leserPort.listen((m) {
      if (m is Uint8List) {
        if (!v._eingang.isClosed) v._eingang.add(m);
      } else {
        leserPort.close();
        v._abschliessen();
      }
    });
    return v;
  }

  @override
  Stream<List<int>> get eingang => _eingang.stream;

  @override
  void senden(List<int> daten) {
    if (_zu) return;
    _schreiberPort.send(Uint8List.fromList(daten));
  }

  @override
  Future<void> schliessen() async {
    if (_zu) return;
    _zu = true;
    _schreiberPort.send(null);
    _cancelIoEx(_handle, nullptr);
  }

  /// Das Lesen ist zu Ende (die Gegenseite ist weg oder wir haben geschlossen).
  void _abschliessen() {
    if (!_eingang.isClosed) unawaited(_eingang.close());
    if (_handle != 0) {
      _zu = true;
      _schreiberPort.send(null);
      if (_server) _disconnectNamedPipe(_handle);
      _closeHandle(_handle);
    }
  }
}

// ---------------------------------------------------------------------------
// Server und Client
// ---------------------------------------------------------------------------

class _PipeLauscher implements KanalLauscher {
  _PipeLauscher(this._name, this._sid, this._abgewiesen, this._sa, this._erste) {
    unawaited(_annehmen(_erste));
  }

  final String _name;
  final String _sid;
  final void Function(String)? _abgewiesen;
  final Pointer _sa;
  final int _erste;
  final _neu = StreamController<KanalVerbindung>();
  bool _zu = false;
  int _warten = 0;

  @override
  Stream<KanalVerbindung> get verbindungen => _neu.stream;

  int _instanz({bool erste = false}) {
    final n = _name.toNativeUtf16();
    try {
      return _createNamedPipe(
        n,
        _pipeAccessDuplex | _fileFlagOverlapped | (erste ? _fileFlagFirstPipeInstance : 0),
        _pipeRejectRemoteClients,
        _pipeUnlimitedInstances,
        _pufferGroesse,
        _pufferGroesse,
        0,
        _sa,
      );
    } finally {
      malloc.free(n);
    }
  }

  /// Wartet in einem Isolate auf einen Client, prüft ihn und legt vorher schon
  /// die nächste Instanz an.
  Future<void> _annehmen(int handle) async {
    while (!_zu) {
      _warten = handle;
      final verbunden = await Isolate.run(() => _auf(handle));
      _warten = 0;
      if (_zu) {
        _closeHandle(handle);
        return;
      }
      final naechste = _instanz();
      final pid = verbunden ? _clientPid(handle) : null;
      final sid = pid == null ? null : _sidVonPid(pid);
      if (verbunden && sid == _sid) {
        _neu.add(await _PipeVerbindung.oeffnen(handle, server: true));
      } else {
        if (verbunden) _abgewiesen?.call('Die Gegenseite gehört einem anderen Konto oder ihr Konto ließ sich nicht feststellen.');
        _disconnectNamedPipe(handle);
        _closeHandle(handle);
      }
      if (naechste == _invalidHandle) {
        _abgewiesen?.call('Der Kanal ließ sich nicht neu öffnen.');
        return;
      }
      handle = naechste;
    }
  }

  static int? _clientPid(int handle) {
    final p = calloc<Uint32>();
    try {
      return _getClientPid(handle, p) == 0 ? null : p.value;
    } finally {
      calloc.free(p);
    }
  }

  /// Blockiert, bis sich ein Client verbindet; false, wenn das Warten
  /// abgebrochen wurde.
  static bool _auf(int handle) {
    final ov = calloc<Uint8>(_overlappedGroesse);
    final ereignis = _createEvent(nullptr, 1, 0, nullptr);
    final n = calloc<Uint32>();
    try {
      Pointer<IntPtr>.fromAddress(ov.address + _overlappedEreignis).value = ereignis;
      if (_connectNamedPipe(handle, ov) != 0) return true;
      final fehler = _getLastError();
      if (fehler == _errorPipeConnected) return true;
      if (fehler != _errorIoPending) return false;
      return _getOverlappedResult(handle, ov, n, 1) != 0;
    } finally {
      _closeHandle(ereignis);
      calloc.free(n);
      calloc.free(ov);
    }
  }

  @override
  Future<void> schliessen() async {
    _zu = true;
    if (_warten != 0) _cancelIoEx(_warten, nullptr);
    await _neu.close();
  }
}

class WindowsKanal implements KanalOrt {
  @override
  Future<KanalLauscher> lauschen(String name, {void Function(String grund)? abgewiesen}) async {
    if (!kanalNameGueltig(name)) throw KanalFehler('Der Profilname eignet sich nicht für einen Kanal.');
    final sid = eigeneSid();
    final pipe = pipeName(sid, name);
    final sddl = sddlNurKonto(sid).toNativeUtf16();
    final beschreibung = calloc<Pointer>();
    if (_sddlZuBeschreibung(sddl, 1, beschreibung, nullptr) == 0) {
      malloc.free(sddl);
      calloc.free(beschreibung);
      throw KanalUnsicher('Der Kanal ließ sich nicht absichern.');
    }
    malloc.free(sddl);
    // SECURITY_ATTRIBUTES: Länge, Zeiger auf die Beschreibung, nicht vererbbar.
    final sa = calloc<Uint8>(24);
    sa.cast<Uint32>().value = 24;
    Pointer<IntPtr>.fromAddress(sa.address + 8).value = beschreibung.value.address;
    final n = pipe.toNativeUtf16();
    final erste = _createNamedPipe(
      n,
      _pipeAccessDuplex | _fileFlagOverlapped | _fileFlagFirstPipeInstance,
      _pipeRejectRemoteClients,
      _pipeUnlimitedInstances,
      _pufferGroesse,
      _pufferGroesse,
      0,
      sa,
    );
    malloc.free(n);
    if (erste == _invalidHandle) {
      throw KanalFehler('Der Kanal ist schon belegt: moocp läuft in diesem Konto schon, oder ein anderes Konto hat den Namen belegt.');
    }
    return _PipeLauscher(pipe, sid, abgewiesen, sa, erste);
  }

  @override
  Future<KanalVerbindung> verbinden(String name) async {
    if (!kanalNameGueltig(name)) throw KanalFehler('Der Profilname eignet sich nicht für einen Kanal.');
    final sid = eigeneSid();
    final pipe = pipeName(sid, name);
    final n = pipe.toNativeUtf16();
    try {
      for (var versuch = 0; versuch < 5; versuch++) {
        final h = _createFile(
          n,
          _genericRead | _genericWrite,
          0,
          nullptr,
          _openExisting,
          _fileFlagOverlapped | _securitySqosPresent | _securityIdentification,
          0,
        );
        if (h != _invalidHandle) {
          final pid = calloc<Uint32>();
          final serverSid = _getServerPid(h, pid) == 0 ? null : _sidVonPid(pid.value);
          calloc.free(pid);
          if (serverSid != sid) {
            _closeHandle(h);
            throw KanalUnsicher('Der Kanal wird von einem anderen Konto bedient.');
          }
          return await _PipeVerbindung.oeffnen(h, server: false);
        }
        final fehler = _getLastError();
        if (fehler == _errorPipeBusy) {
          _waitNamedPipe(n, 1000);
          continue;
        }
        throw verbindungsFehlerFuer(fehler) ?? KanalFehler('moocp nicht erreichbar.');
      }
      throw KanalNichtDa();
    } finally {
      malloc.free(n);
    }
  }
}
