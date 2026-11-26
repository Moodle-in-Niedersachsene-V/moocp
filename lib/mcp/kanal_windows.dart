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
// Speicher einer überlappenden Ein- oder Ausgabe (OVERLAPPED, Ereignis, Puffer)
// gehört dem Kernel, solange der Vorgang läuft. Ob er läuft, steht darum nie
// in `GetLastError`: Dart garantiert nicht, dass der Fehlerwert des Threads
// zwischen zwei FFI-Aufrufen erhalten bleibt (der Isolate kann den Thread
// wechseln, die VM ruft dazwischen selbst Windows-Funktionen). Gelesen wird
// statt dessen `OVERLAPPED.Internal`, das der Kernel vor der Rückkehr des
// Aufrufs auf STATUS_PENDING setzt ([overlappedAusstehend]). Ein Vorgang, der
// laufen könnte, wird immer mit `GetOverlappedResult(…, warten)` abgeholt,
// bevor sein Speicher frei wird; ein Abbruch (`CancelIoEx`) ersetzt das nie.
//
// Nur die reine Logik (Namen, Zugriffsliste, Fehlernummern, Auswertung von
// `Internal`) lässt sich ohne Windows prüfen (test/kanal_test.dart); alles
// andere ist nur hier umgesetzt (test/kanal_windows_test.dart, nur unter
// Windows).
// Ohne Flutter: Die Brücke (mcp/bruecke.dart) bindet diese Datei ein.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'kanal.dart';
import 'schreiben_mit_frist.dart';

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
final _waitForSingleObject =
    _kernel32.lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>('WaitForSingleObject');
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
const _errorPipeBusy = 231;
const _pufferGroesse = 64 * 1024;

/// OVERLAPPED hat auf 64-Bit-Windows 32 Bytes: Internal, InternalHigh,
/// Offset/OffsetHigh (oder Pointer) und das Ereignis.
const _overlappedGroesse = 32;
const _overlappedEreignis = 24;

/// STATUS_PENDING: Der Kernel hat den Vorgang angenommen und noch nicht beendet.
const _statusPending = 0x103;

/// Ob der Vorgang laut `OVERLAPPED.Internal` (NTSTATUS in den unteren 32 Bit)
/// noch läuft. Nur dann darf sein Speicher nicht frei werden und ist zu
/// warten; jeder andere Wert heißt: fertig (mit Erfolg oder Fehler), auch wenn
/// der Aufruf selbst `0` lieferte. Der Wert ist nur nach der Rückkehr des
/// Aufrufs gültig, der den Vorgang gestartet hat.
bool overlappedAusstehend(int internal) => (internal & 0xFFFFFFFF) == _statusPending;

int _internal(Pointer ov) => Pointer<IntPtr>.fromAddress(ov.address).value;

const _waitTimeout = 0x102;

/// Wartet auf einen Vorgang, der ausstehend sein kann, und holt ihn ab: Erst
/// wenn diese Funktion zurückkehrt, gehört der Speicher wieder dem Aufrufer.
/// Das Ereignis wird in Schritten abgefragt; setzt jemand [stopp] (eine
/// Zahl im nativen Speicher, 0 = weiterlaufen), wird der Vorgang abgebrochen und
/// trotzdem abgeholt. Das ersetzt ein `CancelIoEx` von außen, das ins Leere
/// ginge, solange der Vorgang noch nicht gestartet ist. Liefert, ob der
/// Vorgang erfolgreich war (die Zahl der Bytes steht dann in [n]).
bool _abholen(int handle, Pointer ov, int ereignis, Pointer<Uint32> n, Pointer<Uint32>? stopp) {
  var abgebrochen = false;
  while (true) {
    final w = _waitForSingleObject(ereignis, 100);
    if (w == _waitObject0) break;
    if (w != _waitTimeout) break; // WAIT_FAILED: unten abholen, mehr geht nicht
    if (!abgebrochen && stopp != null && stopp.value != 0) {
      abgebrochen = true;
      _cancelIoEx(handle, ov);
    }
  }
  // Kehrt nach dem Ereignis sofort zurück; hat der Vorgang es nie gesetzt,
  // wartet es, bis er wirklich vorbei ist.
  return _getOverlappedResult(handle, ov, n, 1) != 0;
}

/// Nach einem Aufruf (ReadFile/WriteFile/ConnectNamedPipe), der `0` lieferte:
/// ob der Vorgang noch läuft ([ausstehend]), schon erfolgreich beendet ist
/// ([fertig], die Bytes stehen in [n]) oder gescheitert ist ([fehler]). Nie
/// aus `GetLastError`.
SchreibStart _startUrteil(int handle, Pointer ov, Pointer<Uint32> n) {
  if (overlappedAusstehend(_internal(ov))) return SchreibStart.ausstehend;
  // Nicht mehr ausstehend (auch wenn er es eben noch war): Das Ergebnis liegt
  // vor, es wird ohne Warten abgeholt.
  return _getOverlappedResult(handle, ov, n, 0) != 0 ? SchreibStart.fertig : SchreibStart.fehler;
}

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
/// `start[2]` ist die Adresse einer Zahl im nativen Speicher, die der Besitzer
/// der Verbindung auf 1 setzt, um das Lesen zu beenden; sie bleibt gültig, bis
/// dieser Isolate sein Ende gemeldet hat.
void _leser(List<Object> start) {
  final handle = start[0] as int;
  final aus = start[1] as SendPort;
  final stopp = Pointer<Uint32>.fromAddress(start[2] as int);
  final puffer = calloc<Uint8>(_pufferGroesse);
  final gelesen = calloc<Uint32>();
  final ov = calloc<Uint8>(_overlappedGroesse);
  final ereignis = _createEvent(nullptr, 1, 0, nullptr);
  try {
    while (stopp.value == 0) {
      ov.asTypedList(_overlappedGroesse).fillRange(0, _overlappedGroesse, 0);
      Pointer<IntPtr>.fromAddress(ov.address + _overlappedEreignis).value = ereignis;
      gelesen.value = 0;
      final ok = _readFile(handle, puffer, _pufferGroesse, gelesen, ov) != 0;
      final urteil = ok ? SchreibStart.fertig : _startUrteil(handle, ov, gelesen);
      if (urteil == SchreibStart.fehler) break;
      if (urteil == SchreibStart.ausstehend && !_abholen(handle, ov, ereignis, gelesen, stopp)) break;
      if (gelesen.value == 0) break;
      aus.send(Uint8List.fromList(puffer.asTypedList(gelesen.value)));
    }
  } finally {
    // Hier läuft kein Vorgang mehr: Jeder Weg aus der Schleife hat ihn
    // abgeholt oder gar nicht erst gestartet.
    aus.send(null);
    _closeHandle(ereignis);
    calloc.free(ov);
    calloc.free(gelesen);
    calloc.free(puffer);
  }
}

/// Wie lange ein Schreiben höchstens auf die Gegenseite wartet, die nichts
/// abnimmt (schreiben_mit_frist.dart). Die Gegenseite ist ein Prozess desselben
/// Kontos, der eine Zeile in Sekundenbruchteilen liest; wer nach einer Minute
/// nichts abgenommen hat, liest nicht mehr.
const _schreibFrist = Duration(seconds: 60);

const _waitObject0 = 0;

/// Schreibt in einem eigenen Isolate, was es bekommt; `null` beendet es und
/// meldet `'ende'`, sobald alles Vorherige geschrieben ist. Es hat die Pipe zuletzt
/// benutzt: Erst nach dieser Meldung wird das Handle geschlossen, sonst ginge
/// ein Rest an ein Handle, das schon eine andere Verbindung bekommen hat.
/// Nimmt die Gegenseite binnen der Frist nichts ab oder scheitert das
/// Schreiben, beendet es sich ebenso von selbst und meldet `'ende'`: Die
/// Verbindung ist dann nicht zu retten, und das Handle darf nicht an einer
/// Gegenseite hängen, die nie liest.
void _schreiber(List<Object> start) {
  final handle = start[0] as int;
  final eingang = ReceivePort();
  final haupt = start[1] as SendPort;
  haupt.send(eingang.sendPort);
  final geschrieben = calloc<Uint32>();
  final ov = calloc<Uint8>(_overlappedGroesse);
  final ereignis = _createEvent(nullptr, 1, 0, nullptr);
  var fertig = false;
  void beenden() {
    if (fertig) return;
    fertig = true;
    _closeHandle(ereignis);
    calloc.free(ov);
    calloc.free(geschrieben);
    eingang.close();
    haupt.send('ende');
  }

  eingang.listen((m) {
    if (fertig) return;
    if (m is! Uint8List) {
      beenden();
      return;
    }
    final daten = calloc<Uint8>(m.length);
    try {
      daten.asTypedList(m.length).setAll(0, m);
      var sofort = false;
      final urteil = schreibenMitFrist(
        laenge: m.length,
        frist: _schreibFrist,
        beginnen: (offen) {
          ov.asTypedList(_overlappedGroesse).fillRange(0, _overlappedGroesse, 0);
          Pointer<IntPtr>.fromAddress(ov.address + _overlappedEreignis).value = ereignis;
          final ok = _writeFile(handle, daten + offen, m.length - offen, geschrieben, ov) != 0;
          final urteil = ok ? SchreibStart.fertig : _startUrteil(handle, ov, geschrieben);
          sofort = urteil == SchreibStart.fertig;
          return urteil;
        },
        warten: (frist) => _waitForSingleObject(ereignis, frist.inMilliseconds) == _waitObject0,
        ergebnis: () {
          if (sofort) return geschrieben.value;
          // Nach einem Abbruch kehrt das hier sofort zurück (mit einem Fehler).
          return _getOverlappedResult(handle, ov, geschrieben, 1) == 0 ? null : geschrieben.value;
        },
        abbrechen: () => _cancelIoEx(handle, ov),
      );
      if (urteil != SchreibUrteil.fertig) beenden();
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
  bool _leserEnde = false;
  bool _schreiberEnde = false;
  bool _geschlossen = false;

  /// Zahl im nativen Speicher, mit der die Verbindung dem Leser sagt, dass er
  /// aufhören soll. Sie wird erst frei, wenn der Leser sein Ende gemeldet hat.
  final Pointer<Uint32> _stopp = calloc<Uint32>();

  static Future<_PipeVerbindung> oeffnen(int handle, {required bool server}) async {
    final leserPort = ReceivePort();
    final schreiberPort = ReceivePort();
    await Isolate.spawn(_schreiber, [handle, schreiberPort.sendPort]);
    final antworten = StreamIterator(schreiberPort);
    await antworten.moveNext();
    final senden = antworten.current as SendPort;
    final v = _PipeVerbindung._(handle, server, senden);
    unawaited(() async {
      while (await antworten.moveNext()) {
        if (antworten.current == 'ende') break;
      }
      await antworten.cancel();
      v._schreiberEnde = true;
      // Auch wenn der Schreiber von selbst aufgegeben hat: Nichts mehr senden.
      v._zu = true;
      v._handleSchliessen();
    }());
    await Isolate.spawn(_leser, [handle, leserPort.sendPort, v._stopp.address]);
    leserPort.listen((m) {
      if (m is Uint8List) {
        if (!v._eingang.isClosed) v._eingang.add(m);
      } else {
        leserPort.close();
        v._leserEnde = true;
        calloc.free(v._stopp);
        if (!v._eingang.isClosed) unawaited(v._eingang.close());
        v._beenden();
        if (v._schreiberEnde) v._handleSchliessen();
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
    _beenden();
  }

  /// Beendet die Verbindung in der Reihenfolge, die das Handle schützt: Erst
  /// schreibt der Schreiber zu Ende (und meldet es), dann bricht das Lesen ab,
  /// und das Handle wird erst geschlossen, wenn beide Isolate es nicht mehr
  /// brauchen ([_handleSchliessen]).
  void _beenden() {
    if (_zu) return;
    _zu = true;
    _schreiberPort.send(null);
  }

  /// Wird gerufen, wenn der Schreiber fertig ist: Das Lesen ist dann der einzige
  /// Rest, und `CancelIoEx` trifft kein Schreiben mehr.
  void _handleSchliessen() {
    if (_geschlossen) return;
    if (!_leserEnde) {
      // Der Leser fragt die Zahl regelmäßig ab und bricht dann selbst ab, auch
      // wenn er sein Lesen noch gar nicht begonnen hatte; das `CancelIoEx` beschleunigt es.
      _stopp.value = 1;
      _cancelIoEx(_handle, nullptr);
      return; // der Leser meldet sein Ende, danach geht es hier weiter
    }
    _geschlossen = true;
    if (_server) _disconnectNamedPipe(_handle);
    _closeHandle(_handle);
  }
}

// ---------------------------------------------------------------------------
// Server und Client
// ---------------------------------------------------------------------------

class _PipeLauscher implements KanalLauscher {
  _PipeLauscher(this._name, this._sid, this._abgewiesen, this._sa, this._beschreibung, this._erste) {
    unawaited(_annehmen(_erste));
  }

  final String _name;
  final String _sid;
  final void Function(String)? _abgewiesen;
  final Pointer _sa;
  final Pointer _beschreibung;
  final int _erste;
  final _neu = StreamController<KanalVerbindung>();
  final _ende = Completer<void>();

  /// Zahl im nativen Speicher, mit der [schliessen] dem wartenden Isolate sagt,
  /// dass er aufgeben soll ([_abholen]).
  final Pointer<Uint32> _stopp = calloc<Uint32>();
  bool _zu = false;
  bool _frei = false;

  @override
  Stream<KanalVerbindung> get verbindungen => _neu.stream;

  /// Nur von [_annehmen] aus und nur, solange [_frei] nicht gesetzt ist: Die
  /// Zugriffsliste lebt, bis die Schleife dort zu Ende ist.
  int _instanz() {
    final n = _name.toNativeUtf16();
    try {
      return _createNamedPipe(
        n,
        _pipeAccessDuplex | _fileFlagOverlapped,
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
  /// die nächste Instanz an. Diese Schleife ist die einzige, die Handles der
  /// Instanzen schließt und die Zugriffsliste freigibt, und zwar erst, wenn
  /// kein Isolate mehr auf einer Instanz wartet.
  Future<void> _annehmen(int handle) async {
    // 0: kein Handle in der Hand (schon geschlossen oder weitergereicht).
    var aktuell = handle;
    try {
      while (!_zu) {
        final verbunden = await _warteAuf(aktuell, _stopp.address);
        if (_zu) {
          _closeHandle(aktuell);
          aktuell = 0;
          return;
        }
        final eigenes = aktuell;
        final naechste = _instanz();
        aktuell = naechste == _invalidHandle ? 0 : naechste;
        final pid = verbunden ? _clientPid(eigenes) : null;
        final sid = pid == null ? null : _sidVonPid(pid);
        if (verbunden && sid == _sid) {
          final v = await _PipeVerbindung.oeffnen(eigenes, server: true);
          if (_neu.isClosed) {
            unawaited(v.schliessen());
          } else {
            _neu.add(v);
          }
        } else {
          if (verbunden) _abgewiesen?.call('Die Gegenseite gehört einem anderen Konto oder ihr Konto ließ sich nicht feststellen.');
          _disconnectNamedPipe(eigenes);
          _closeHandle(eigenes);
        }
        if (naechste == _invalidHandle) {
          // Niemand kann sich mehr verbinden: Der Server meldet es, statt weiter
          // so zu tun, als lausche er.
          _abgewiesen?.call('Der Kanal ließ sich nicht neu öffnen.');
          if (!_neu.isClosed) {
            _neu.addError(KanalFehler('Der Kanal ließ sich nicht neu öffnen.'));
            unawaited(_neu.close());
          }
          return;
        }
      }
    } finally {
      if (aktuell != 0) _closeHandle(aktuell);
      _freigeben();
      if (!_ende.isCompleted) _ende.complete();
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

  /// `Isolate.run` in einer statischen Funktion, damit der Rückruf nichts außer
  /// den beiden Zahlen mitnimmt (nie `this` mit Handles und Zugriffsliste).
  static Future<bool> _warteAuf(int handle, int stoppAdresse) => Isolate.run(() => _auf(handle, stoppAdresse));

  /// Blockiert, bis sich ein Client verbindet; false, wenn das Warten
  /// abgebrochen wurde oder sich keiner verbunden hat. Kehrt erst zurück, wenn
  /// der Vorgang vorbei ist: Danach darf der Aufrufer das Handle schließen.
  static bool _auf(int handle, int stoppAdresse) {
    final ov = calloc<Uint8>(_overlappedGroesse);
    final ereignis = _createEvent(nullptr, 1, 0, nullptr);
    final n = calloc<Uint32>();
    final stopp = Pointer<Uint32>.fromAddress(stoppAdresse);
    try {
      if (stopp.value != 0) return false;
      Pointer<IntPtr>.fromAddress(ov.address + _overlappedEreignis).value = ereignis;
      if (_connectNamedPipe(handle, ov) != 0) return true;
      if (!overlappedAusstehend(_internal(ov))) {
        // Es läuft nichts: Entweder war schon ein Client da (ERROR_PIPE_CONNECTED,
        // er hat sich zwischen dem Anlegen der Instanz und diesem Aufruf
        // verbunden) oder der Aufruf ist gescheitert. Das unterscheidet kein
        // Fehlerwert, sondern die Frage, ob die Instanz einen Client hat; die
        // Prüfung des Kontos folgt danach ohnehin.
        return _clientPid(handle) != null;
      }
      return _abholen(handle, ov, ereignis, n, stopp);
    } finally {
      _closeHandle(ereignis);
      calloc.free(n);
      calloc.free(ov);
    }
  }

  /// Gibt die Zugriffsliste frei, mit der die Instanzen angelegt wurden, und die
  /// Stopp-Zahl; danach legt niemand mehr eine Instanz an. Nur aus [_annehmen].
  void _freigeben() {
    if (_frei) return;
    _frei = true;
    _localFree(_beschreibung);
    calloc.free(_sa);
    calloc.free(_stopp);
  }

  @override
  Future<void> schliessen() async {
    _zu = true;
    if (!_frei) _stopp.value = 1;
    if (!_neu.isClosed) unawaited(_neu.close());
    // Die Freigabe geschieht in [_annehmen], sobald der wartende Isolate
    // zurück ist (höchstens ein paar Zehntelsekunden).
    await _ende.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  }
}

class WindowsKanal extends KanalOrt {
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
      _localFree(beschreibung.value);
      calloc.free(beschreibung);
      calloc.free(sa);
      throw KanalFehler('Der Kanal ist schon belegt: moocp läuft in diesem Konto schon, oder ein anderes Konto hat den Namen belegt.');
    }
    final b = beschreibung.value;
    calloc.free(beschreibung);
    return _PipeLauscher(pipe, sid, abgewiesen, sa, b, erste);
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
            // Ein Prozess mit höheren Rechten (die App „als Administrator“) lässt sein
            // Token nicht lesen: Das ist nicht dasselbe wie ein fremdes Konto, die
            // Verbindung wird aber in beiden Fällen nicht benutzt.
            throw KanalUnsicher(serverSid == null
                ? 'Das Konto, das den Kanal bedient, ließ sich nicht feststellen (läuft moocp mit anderen Rechten?).'
                : 'Der Kanal wird von einem anderen Konto bedient.');
          }
          return await _PipeVerbindung.oeffnen(h, server: false);
        }
        // Die Fehlernummer dient nur der Meldung (und dem Warten bei „Pipe
        // beschäftigt“): Liest sie sich falsch, bleibt es bei einer Meldung
        // `KanalFehler`, nie bei einem Vorgang, dessen Speicher frei würde.
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
