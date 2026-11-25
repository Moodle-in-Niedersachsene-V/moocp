// Linux und Mac: Der Browser bekommt seine Pipe als Dateinummern 3 (er liest)
// und 4 (er schreibt), wie --remote-debugging-pipe sie erwartet. Dart kann
// einem Kind keine weiteren Dateinummern mitgeben; deshalb startet eine
// Shell den Browser mit den Umleitungen und ersetzt sich durch ihn (`exec`):
//
//   /bin/sh -c 'exec "$0" "$@" 3<"$MOOCP_CDP_EIN" 4>"$MOOCP_CDP_AUS"' browser schalter…
//
// Die Pfade der beiden benannten Pipes (FIFO) stehen in der Umgebung, nie im
// Text der Shell: Kein Pfad und kein Schalter wird in Shell-Text eingesetzt.
// Die FIFO liegen im Profilordner, der privat ist (Rechte 700, dem aktuellen
// Benutzer gehörig, keine Verknüpfung), die FIFO selbst mit 600: Kein anderes
// Konto kann sie öffnen. Auf dem Mac und unter Linux gehört der Prozess nach
// `exec` dem Browser; seine Nummer ist die des gestarteten Prozesses.
//
// Das Öffnen einer FIFO wartet, bis die Gegenseite offen ist. Dart öffnet
// beide Seiten nebenläufig (File.open läuft nicht im Ereignisfaden). Startet
// der Browser nicht, bliebe das Öffnen für immer hängen; dann öffnet
// [_entsperren] die Gegenseite selbst.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'browser_start.dart';
import 'kindprozess.dart';

/// Die Rechte 700 und 600, wie `stat` sie liefert (nur die untersten neun Bit).
const _rechteOrdner = 448; // 0700
const _rechteFifo = 384; // 0600

/// Die Nummer des Benutzers dieses Prozesses (`id -u`), null, wenn sie sich
/// nicht ermitteln lässt.
Future<int?> aktuelleBenutzerNummer() async {
  try {
    final r = await prozessAusfuehren('id', ['-u']);
    return int.tryParse('${r.stdout}'.trim());
  } on ProcessException {
    return null;
  }
}

/// Der Besitzer von [pfad] (`stat`), ohne Verknüpfungen aufzulösen.
Future<int?> besitzerVon(String pfad) async {
  try {
    final r = await prozessAusfuehren(
      'stat',
      Platform.isMacOS ? ['-f', '%u', pfad] : ['-c', '%u', pfad],
    );
    return r.exitCode == 0 ? int.tryParse('${r.stdout}'.trim()) : null;
  } on ProcessException {
    return null;
  }
}

/// Prüft, dass [pfad] das ist, was wir angelegt haben: ein Ordner (oder mit
/// [fifo] eine FIFO), keine Verknüpfung, mit den Rechten 700 (FIFO 600) und im
/// Besitz von [benutzer]. Alles andere ist ein [BrowserStartFehler] -- dann
/// startet kein Browser mit seinem Profil an diesem Ort.
Future<void> privatPruefen(
  String pfad, {
  required int benutzer,
  bool fifo = false,
  Future<int?> Function(String) besitzer = besitzerVon,
}) async {
  final art = FileSystemEntity.typeSync(pfad, followLinks: false);
  if (art !=
      (fifo ? FileSystemEntityType.pipe : FileSystemEntityType.directory)) {
    throw BrowserStartFehler(
      'Das Profil des Browsers ist nicht privat angelegt (falsche Art: $art).',
    );
  }
  final rechte = FileStat.statSync(pfad).mode & 511;
  if (rechte != (fifo ? _rechteFifo : _rechteOrdner)) {
    throw BrowserStartFehler(
      'Das Profil des Browsers ist nicht privat angelegt (Rechte ${rechte.toRadixString(8)}).',
    );
  }
  if (await besitzer(pfad) != benutzer) {
    throw BrowserStartFehler(
      'Das Profil des Browsers gehört nicht dem aktuellen Benutzer.',
    );
  }
}

class UnixBrowserStarter implements BrowserStarter {
  /// [shell] und [mkfifo] sind für Tests austauschbar.
  UnixBrowserStarter({
    this.oeffnenGrenze = const Duration(seconds: 15),
    this.shell = '/bin/sh',
    this.mkfifo = 'mkfifo',
  });

  final String shell, mkfifo;

  /// So lange darf es dauern, bis der Browser beide Enden seiner Pipe geöffnet hat.
  final Duration oeffnenGrenze;

  @override
  Future<Directory> profilAnlegen(String arbeitsordner) async {
    final benutzer = await aktuelleBenutzerNummer();
    if (benutzer == null) {
      throw BrowserStartFehler(
        'Der Benutzer dieses Prozesses ließ sich nicht ermitteln (id -u).',
      );
    }
    final zufall = math.Random.secure().nextInt(1 << 32).toRadixString(16);
    final pfad = p.join(
      arbeitsordner,
      '.browser-${DateTime.now().millisecondsSinceEpoch}-$zufall',
    );
    // Ohne -p: scheitert, wenn es den Pfad schon gibt, auch als Verknüpfung.
    final ProcessResult r;
    try {
      r = await prozessAusfuehren('mkdir', ['-m', '700', '--', pfad]);
    } on ProcessException {
      throw BrowserStartFehler(
        'Das Hilfsprogramm mkdir fehlt -- das Profil des Browsers ließ sich nicht privat anlegen.',
      );
    }
    if (r.exitCode != 0) {
      throw BrowserStartFehler(
        'Das Profil des Browsers ließ sich nicht privat anlegen.',
      );
    }
    final ordner = Directory(pfad);
    try {
      await privatPruefen(pfad, benutzer: benutzer);
    } catch (_) {
      await _loeschen(ordner);
      rethrow;
    }
    return ordner;
  }

  @override
  Future<BrowserProzess> starten(
    String programm,
    List<String> argumente,
    Directory profil,
  ) async {
    final benutzer = await aktuelleBenutzerNummer();
    if (benutzer == null) {
      throw BrowserStartFehler(
        'Der Benutzer dieses Prozesses ließ sich nicht ermitteln (id -u).',
      );
    }
    await privatPruefen(profil.path, benutzer: benutzer);
    final ein = p.join(profil.path, 'cdp-ein'),
        aus = p.join(profil.path, 'cdp-aus');
    final ProcessResult fifo;
    try {
      fifo = await prozessAusfuehren(mkfifo, ['-m', '600', '--', ein, aus]);
    } on ProcessException {
      throw BrowserStartFehler(
        'Das Hilfsprogramm mkfifo fehlt -- die Pipe zum Browser ließ sich nicht anlegen.',
      );
    }
    if (fifo.exitCode != 0) {
      throw BrowserStartFehler(
        'Die Pipe zum Browser ließ sich nicht anlegen (mkfifo).',
      );
    }
    await privatPruefen(ein, benutzer: benutzer, fifo: true);
    await privatPruefen(aus, benutzer: benutzer, fifo: true);

    final Process proz;
    try {
      proz = await prozessStarten(
        shell,
        [
          '-c',
          r'exec "$0" "$@" 3<"$MOOCP_CDP_EIN" 4>"$MOOCP_CDP_AUS"',
          programm,
          ...argumente,
        ],
        // Kein eigenes TMPDIR im Profil: Chrome legt dort einen Socket an
        // (com.google.Chrome.*/SingletonSocket), dessen Pfad höchstens 107
        // Zeichen haben darf; im Profil läge er bei langen Pfaden darüber.
        dazu: {'MOOCP_CDP_EIN': ein, 'MOOCP_CDP_AUS': aus},
      );
    } on ProcessException {
      throw BrowserStartFehler(
        'Die Shell ($shell) fehlt -- der Browser ließ sich nicht starten.',
      );
    }
    // Keine Ausgabe, nirgends (E11): Was der Browser schreibt, wird verworfen.
    unawaited(proz.stdout.drain<void>());
    unawaited(proz.stderr.drain<void>());

    final zuBrowser = File(ein).open(mode: FileMode.writeOnly);
    final vomBrowser = File(aus).open();
    var fertig = false;
    try {
      final offen = await Future.wait([zuBrowser, vomBrowser]).timeout(
        oeffnenGrenze,
        onTimeout: () => throw BrowserStartFehler(
          'Der Browser öffnet seine Pipe nicht (nach ${oeffnenGrenze.inSeconds} s). Möglich: Eine Richtlinie '
          'oder der Virenschutz verbietet die Fernsteuerung des Browsers.',
        ),
      );
      fertig = true;
      return _UnixProzess(proz, offen[0], offen[1]);
    } finally {
      if (!fertig) {
        proz.kill(ProcessSignal.sigkill);
        await _entsperren(ein, aus);
      }
    }
  }
}

/// Öffnet die Gegenseiten der beiden FIFO, damit ein hängendes Öffnen endet
/// (der Browser ist dann nicht gestartet oder tot). Auch ohne wartendes
/// Gegenüber darf das nicht hängen: Die Gegenseite wird nur mit Grenze
/// abgewartet.
Future<void> _entsperren(String ein, String aus) async {
  Future<void> gegenseite(String pfad, FileMode modus) async {
    try {
      final f = await File(pfad)
          .open(mode: modus)
          .timeout(const Duration(seconds: 2));
      await f.close();
    } catch (_) {
      // Nichts wartete mehr oder die Datei ist schon weg.
    }
  }

  await Future.wait([
    gegenseite(ein, FileMode.read),
    gegenseite(aus, FileMode.writeOnly),
  ]);
}

Future<void> _loeschen(Directory ordner) async {
  try {
    if (ordner.existsSync()) await ordner.delete(recursive: true);
  } on FileSystemException {
    // Der Aufrufer meldet, was bleibt.
  }
}

class _UnixProzess implements BrowserProzess {
  _UnixProzess(this._proz, this._schreiben, this._lesen) {
    _schleife = _lesenSchleife();
  }

  late final Future<void> _schleife;

  final Process _proz;
  final RandomAccessFile _schreiben;
  final RandomAccessFile _lesen;
  final _ein = StreamController<List<int>>();
  var _zu = false;
  Future<void> _kette = Future<void>.value();

  @override
  int get pid => _proz.pid;

  @override
  Stream<List<int>> get eingang => _ein.stream;

  @override
  Future<int> get beendet => _proz.exitCode;

  Future<void> _lesenSchleife() async {
    try {
      while (!_zu) {
        final stueck = await _lesen.read(64 * 1024);
        if (stueck.isEmpty) {
          break; // EOF: Der Browser hat den Kanal geschlossen.
        }
        _ein.add(stueck);
      }
    } on FileSystemException {
      // Geschlossen oder Browser weg: gleich wie EOF.
    }
    if (!_ein.isClosed) await _ein.close();
  }

  /// Schreibt der Reihe nach; ein Schreibfehler (Browser weg) beendet den
  /// Kanal still, die Antwort scheitert dann an der beendeten Verbindung.
  @override
  void senden(List<int> bytes) {
    if (_zu) return;
    final b = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    _kette = _kette.then((_) async {
      if (_zu) return;
      try {
        await _schreiben.writeFrom(b);
      } on FileSystemException {
        // Der Browser liest nicht mehr.
      }
    });
  }

  @override
  Future<void> beenden() async {
    _zu = true;
    _proz.kill(ProcessSignal.sigkill);
    // Ein Lesevorgang in der Schwebe hindert das Schließen; mit dem Prozess
    // endet er (EOF).
    await _schleife.timeout(const Duration(seconds: 3), onTimeout: () {});
    for (final f in [_schreiben, _lesen]) {
      try {
        await f.close();
      } on FileSystemException {
        // schon zu
      }
    }
    if (!_ein.isClosed) await _ein.close();
  }
}
