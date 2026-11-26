// DevTools-Protokoll (CDP) über die Pipe des Browsers (--remote-debugging-pipe),
// ohne Betriebssystem und ohne Flutter: Der Kanal liefert Bytes, nimmt Bytes
// und kennt weder Prozess noch Datei -- so prüfen Tests Rahmen, Zuordnung und
// Sitzungen mit einem nachgebauten Browser (E18, E28).
//
// Rahmen: Jede Nachricht ist ein JSON-Text, mit einem NUL-Byte beendet. Ein
// NUL kommt in JSON nie roh vor (jsonEncode schreibt es als \u0000), das
// Trennzeichen ist also eindeutig; Nachrichten dürfen beliebig auf
// Lesevorgänge verteilt sein, mehrere dürfen in einem stecken.
//
// Eine einzige Verbindung trägt alles: Befehle an den Browser selbst (Anfragen
// anhalten, Beenden) ohne `sessionId`, Befehle an die Seite mit der
// `sessionId` aus Target.attachToTarget (flatten: true). [CdpSitzung] ist die
// Sicht auf eine Sitzung und sieht nur deren Ereignisse.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'moodle_zugang.dart' show MoodleFehler;

/// Eine Nachricht größer als das ist kein Bild einer Seite mehr, sondern ein
/// Fehler: Der Kanal wird beendet, statt den Speicher zu füllen.
const int cdpHoechstensNachricht = 256 * 1024 * 1024;

/// Was die Aufnahme von einem CDP-Kanal braucht: Befehle senden, Ereignisse
/// lesen. Die Wurzel ist der Browser selbst, eine [CdpSitzung] eine Seite.
abstract interface class CdpKanal {
  Future<Map<String, dynamic>> senden(String methode, [Map<String, Object?> params = const {}]);
  Stream<Map<String, dynamic>> get ereignisse;
}

/// Die Verbindung zum Browser: Rahmen, Zuordnung der Antworten zu den Befehlen
/// und Verteilung der Ereignisse.
class CdpPipe implements CdpKanal {
  /// [ein]: Bytes des Browsers (fd 4); [aus]: Bytes an den Browser (fd 3).
  CdpPipe(Stream<List<int>> ein, this._aus, {this.zeitgrenze = const Duration(seconds: 90)}) {
    _abo = ein.listen(
      _bytes,
      onError: (Object _) => _beenden(),
      onDone: _beenden,
      cancelOnError: true,
    );
  }

  final void Function(List<int>) _aus;

  /// So lange wartet ein Befehl auf seine Antwort.
  final Duration zeitgrenze;

  late final StreamSubscription<List<int>> _abo;
  final _puffer = BytesBuilder(copy: false);
  var _id = 0;
  final _offen = <int, Completer<Map<String, dynamic>>>{};
  final _ereignisse = StreamController<Map<String, dynamic>>.broadcast();
  var _zu = false;
  final _ende = Completer<void>();

  /// Erfüllt sich, wenn die Verbindung endet (der Browser schließt den Kanal
  /// oder sie wird geschlossen). So hört auch ein Warten auf ein Ereignis auf.
  Future<void> get ende => _ende.future;

  @override
  Stream<Map<String, dynamic>> get ereignisse => _ereignisse.stream.where((e) => e['sessionId'] == null);

  /// Alle Ereignisse mit der Nummer ihrer Sitzung (`sessionId`).
  Stream<Map<String, dynamic>> get alleEreignisse => _ereignisse.stream;

  /// Die Sicht auf die Sitzung [id] einer Seite.
  CdpSitzung sitzung(String id) => CdpSitzung._(this, id);

  /// Sendet [methode] an den Browser, mit [sitzung] an die Seite dieser Sitzung.
  /// Geschlossen scheitert es als [MoodleFehler], nie als StateError.
  Future<Map<String, dynamic>> _senden(
    String methode,
    Map<String, Object?> params,
    String? sitzung,
  ) {
    if (_zu) return Future.error(MoodleFehler('Browser: Verbindung beendet.'));
    final id = ++_id;
    final c = Completer<Map<String, dynamic>>();
    _offen[id] = c;
    try {
      _aus([
        ...utf8.encode(jsonEncode({'id': id, 'method': methode, 'params': params, 'sessionId': ?sitzung})),
        0,
      ]);
    } catch (_) {
      _offen.remove(id);
      _beenden();
      return Future.error(MoodleFehler('Browser: Verbindung beendet.'));
    }
    return c.future.timeout(
      zeitgrenze,
      onTimeout: () {
        _offen.remove(id);
        throw MoodleFehler('Browser antwortet nicht ($methode).');
      },
    );
  }

  @override
  Future<Map<String, dynamic>> senden(String methode, [Map<String, Object?> params = const {}]) =>
      _senden(methode, params, null);

  void _bytes(List<int> eingang) {
    final stueck = eingang is Uint8List ? eingang : Uint8List.fromList(eingang);
    var anfang = 0;
    for (var i = 0; i < stueck.length; i++) {
      if (stueck[i] != 0) continue;
      if (i > anfang) _puffer.add(Uint8List.sublistView(stueck, anfang, i));
      anfang = i + 1;
      final nachricht = _puffer.takeBytes();
      if (nachricht.isNotEmpty) _nachricht(nachricht);
    }
    if (anfang < stueck.length) {
      _puffer.add(Uint8List.sublistView(stueck, anfang));
    }
    if (_puffer.length > cdpHoechstensNachricht) {
      _puffer.clear();
      _beenden();
    }
  }

  void _nachricht(Uint8List bytes) {
    final Map<String, dynamic> m;
    try {
      final d = jsonDecode(utf8.decode(bytes));
      if (d is! Map<String, dynamic>) return;
      m = d;
    } on FormatException {
      // Keine Nachricht, die wir kennen: Was nicht lesbar ist, wird nicht geraten.
      return;
    }
    final id = m['id'];
    if (id is int) {
      final c = _offen.remove(id);
      if (c == null || c.isCompleted) return;
      final fehler = m['error'];
      if (fehler is Map) {
        c.completeError(MoodleFehler('Browser: ${fehler['message']}'));
      } else {
        c.complete((m['result'] as Map?)?.cast<String, dynamic>() ?? const {});
      }
    } else if (m['method'] is String && !_ereignisse.isClosed) {
      _ereignisse.add(m);
    }
  }

  void _beenden() {
    if (_zu) return;
    _zu = true;
    for (final c in _offen.values) {
      if (!c.isCompleted) c.completeError(MoodleFehler('Browser: Verbindung beendet.'));
    }
    _offen.clear();
    _ende.complete();
    if (!_ereignisse.isClosed) unawaited(_ereignisse.close());
  }

  /// Ob der Browser die Verbindung beendet hat oder sie geschlossen ist.
  bool get geschlossen => _zu;

  Future<void> schliessen() async {
    _beenden();
    await _abo.cancel();
  }
}

/// Die Befehle und Ereignisse einer Seite auf der Verbindung des Browsers.
class CdpSitzung implements CdpKanal {
  CdpSitzung._(this._pipe, this.id);

  final CdpPipe _pipe;
  final String id;

  @override
  Future<Map<String, dynamic>> senden(String methode, [Map<String, Object?> params = const {}]) =>
      _pipe._senden(methode, params, id);

  @override
  Stream<Map<String, dynamic>> get ereignisse => _pipe.alleEreignisse.where((e) => e['sessionId'] == id);
}
