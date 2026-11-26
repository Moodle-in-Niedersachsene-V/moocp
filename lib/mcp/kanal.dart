// Der Kanal zwischen der Brücke eines KI-Werkzeugs und der App (E6).
//
// Eine Adresse auf 127.0.0.1 sagt nichts darüber, wer sie bedient: Ein anderes
// Konto auf demselben Rechner kann den Port vor der App belegen und bekäme
// dann, was ein KI-Werkzeug an die App schickt, und jedes Konto kann sich mit
// einem Port verbinden. Darum läuft jede Verbindung über einen Endpunkt, den
// nur das eigene Konto erreicht und dessen Gegenstelle beide Seiten prüfen,
// bevor ein Byte fließt:
//
// - Linux und macOS: ein Unix-Socket `<Profilname>.sock` in einem Ordner, der
//   dem Konto allein gehört (plattform/privater_ordner.dart). Die App prüft von
//   jeder angenommenen Verbindung die Kennung des Kontos auf der anderen Seite
//   (SO_PEERCRED unter Linux, LOCAL_PEERCRED auf dem Mac), die Brücke
//   Ordner und Socket (Besitzer, Rechte, keine Verknüpfung) und ebenso die
//   Kennung des Kontos, das den Socket bedient.
// - Windows: eine Named Pipe, nur für das eigene Konto (kanal_windows.dart).
//
// Je Instanzprofil ein Endpunkt, benannt nach dem technischen Profilnamen
// (E31): Eine Verbindung zum Endpunkt eines Profils erreicht nie ein anderes.
// Eine Verbindung ist eine MCP-Sitzung; darüber läuft JSON-RPC zeilenweise wie
// über stdio. Ein Geheimnis braucht keine Seite: Wer verbunden ist, ist das
// eigene Konto, sonst wurde die Verbindung nie aufgebaut.
//
// Ohne Flutter: Die Brücke (mcp/bruecke.dart) bindet diese Datei ein.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../einstellungen_ort.dart';
import '../plattform/datei_rechte.dart';
import '../plattform/privater_ordner.dart';
import 'kanal_windows.dart';

/// Ob [name] ein Profilname ist, aus dem sich ein Endpunkt bilden lässt: wie
/// Profil.mcpNameGueltig (Kleinbuchstaben, Ziffern, einzelne Bindestriche).
/// Hier eigens, weil profil.dart an Flutter hängt. Nichts anderes kommt in
/// einen Dateinamen oder Pipe-Namen.
bool kanalNameGueltig(String name) => RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$').hasMatch(name);

/// Grundlage der Fehler beim Aufbau eines Kanals. Die Texte nennen nie einen
/// Pfad (E11).
class KanalFehler implements Exception {
  KanalFehler(this.text);
  final String text;
  @override
  String toString() => text;
}

/// Auf der Gegenseite lauscht niemand: Die App läuft nicht (oder noch nicht).
class KanalNichtDa extends KanalFehler {
  KanalNichtDa() : super('moocp läuft nicht.');
}

/// Der Endpunkt gehört nicht dem eigenen Konto oder die Gegenstelle ist nicht
/// das eigene Konto. Es wurde nichts gesendet.
class KanalUnsicher extends KanalFehler {
  KanalUnsicher(super.text);
}

/// Eine aufgebaute Verbindung: nur zeilenweises JSON-RPC.
abstract interface class KanalVerbindung {
  /// Was die Gegenseite sendet; einmal abonnierbar.
  Stream<List<int>> get eingang;

  void senden(List<int> daten);

  /// Schließt die Verbindung; die Gegenseite sieht das Ende von [eingang].
  Future<void> schliessen();
}

/// Die Seite der App: nimmt Verbindungen an. Jede Verbindung in
/// [verbindungen] hat die Gegenstelle schon bestanden; eine andere wird
/// geschlossen, bevor irgendetwas von ihr gelesen wird.
abstract interface class KanalLauscher {
  Stream<KanalVerbindung> get verbindungen;

  Future<void> schliessen();
}

abstract class KanalOrt {
  /// Öffnet den Endpunkt des Profils [name]. [abgewiesen] hört den Grund jeder
  /// Verbindung, die die Prüfung der Gegenstelle nicht bestand (ohne Pfade
  /// und Namen).
  Future<KanalLauscher> lauschen(String name, {void Function(String grund)? abgewiesen});

  /// Verbindet mit dem Endpunkt des Profils [name], nachdem Endpunkt und
  /// Gegenstelle geprüft sind: [KanalNichtDa], wenn dort niemand lauscht,
  /// [KanalUnsicher], wenn etwas nicht stimmt.
  Future<KanalVerbindung> verbinden(String name);

  /// Die Werkzeugliste der App (bruecke.dart, Werkzeugliste), die sie für die
  /// Brücke ablegt, als JSON; null, wenn es keine gibt. Nur auf Linux und Mac:
  /// Dort kann die Brücke die App nicht nach der Liste fragen, ohne dass ein
  /// Fenster aufgeht (`moocp --werkzeugliste` startet die Oberfläche), und eine
  /// Datei im Ordner des Kontos kann sie lesen, ohne dass moocp läuft. Unter
  /// Windows fragt die Brücke `moocp.exe --werkzeugliste`.
  Future<String?> listeLesen(String name) async => null;

  Future<void> listeAblegen(String name, String json) async {}

  /// Löscht die abgelegte Liste des Profils [name], wenn es sie gibt: Ein
  /// gelöschtes Profil soll keine Liste hinterlassen, die ein späteres Profil
  /// mit demselben Namen erbte.
  Future<void> listeEntfernen(String name) async {}
}

/// Der Kanal dieses Systems. Austauschbar für die Tests, die die App nicht
/// neben einer laufenden App im Konto des Entwicklers lauschen lassen.
KanalOrt standardKanalOrt = Platform.isWindows ? WindowsKanal() : UnixKanal();

// ---------------------------------------------------------------------------
// Unix-Socket (Linux, macOS)
// ---------------------------------------------------------------------------

/// Die Ketten von Ordnern, in denen ein Kanal liegen kann, in der Reihenfolge,
/// in der die App die erste brauchbare nimmt und die Brücke sie der Reihe nach
/// durchsucht. Jeder Ordner einer Kette gehört dem Konto allein
/// (privater_ordner.dart); der letzte trägt die Sockets.
///
/// Linux: im Laufzeitordner der Sitzung (`$XDG_RUNTIME_DIR`, sonst der Ort,
/// an dem systemd ihn anlegt, `/run/user/<uid>`): `moocp/kanal`; er
/// verschwindet beim Abmelden und kann nicht veralten. Der Laufzeitordner
/// zählt nur, wenn er dem Konto allein gehört. Dahinter kommt der Ort ohne
/// Laufzeitordner, `/tmp/moocp-<uid>/kanal`, unabhängig vom `TMPDIR` des
/// Aufrufers (der Arbeitsordner liegt unter `<temp>/moocp-<uid>`, E5, und teilt
/// den Ort nur, wo `TMPDIR` nicht gesetzt ist). Wer die Brücke startet, hat die Variable vielleicht nicht, die App aber
/// schon (oder umgekehrt): Darum sucht die Brücke an allen Orten.
/// Mac: `kanal` im Einstellungsordner. Ein anderer Ordner im Temp-Bereich
/// kommt nie in Frage; die Kennung kommt vom System, nie aus $USER.
List<List<String>> kanalOrdnerKetten(
  Map<String, String> umgebung, {
  bool? macos,
  PrivatSystem? system,
  String? temp,
  String? kurzesTemp,
  String? einstellungen,
}) {
  final s = system ?? UnixPrivatSystem();
  final mac = macos ?? Platform.isMacOS;
  if (mac) {
    // Der Pfad eines Unix-Sockets hat nur gut 100 Zeichen Platz; unter einem langen
    // Benutzernamen und mit einem langen Profilnamen reicht der Einstellungsordner
    // nicht. Dann gilt der kurze Ort, ebenso geprüft wie unter Linux.
    final kurz = p.join(kurzesTemp ?? '/tmp', 'moocp-${s.uid}');
    return [
      [p.join(einstellungen ?? einstellungenOrdnerFuer(umgebung, macos: true), 'kanal')],
      [kurz, p.join(kurz, 'kanal')],
    ];
  }
  bool privat(String x) {
    try {
      privaterOrdnerPruefen(x, system: s);
      return true;
    } on PrivaterOrdnerFehler {
      return false;
    }
  }

  final laufzeit = <String>{
    if (umgebung['XDG_RUNTIME_DIR'] case final x? when p.posix.isAbsolute(x)) x,
    '/run/user/${s.uid}',
  };
  // Fest /tmp, nicht Directory.systemTemp: Die App und die Brücke, die ein Client
  // mit eigenem TMPDIR starten kann, müssen denselben Ort ableiten.
  final tempBasis = p.join(temp ?? '/tmp', 'moocp-${s.uid}');
  return [
    for (final x in laufzeit)
      if (privat(x)) [x, p.join(x, 'moocp'), p.join(x, 'moocp', 'kanal')],
    [tempBasis, p.join(tempBasis, 'kanal')],
  ];
}

/// Prüft die Gegenseite einer Socket-Verbindung; null, wenn es das Konto mit
/// der Kennung [uid] ist, sonst der Grund.
typedef GegenstellePruefer = String? Function(Socket verbindung, int uid);

/// Die Kennung des Kontos auf der anderen Seite eines Unix-Sockets, vom
/// System beglaubigt: Linux liefert bei SO_PEERCRED `struct ucred` (pid, uid,
/// gid), macOS bei LOCAL_PEERCRED `struct xucred` (Version, uid, …). Kann die
/// Kennung nicht gelesen werden, gilt die Gegenstelle als nicht bestanden.
String? gegenstelleDesKontos(Socket verbindung, int uid) {
  try {
    final Uint8List roh;
    if (Platform.isMacOS) {
      // SOL_LOCAL = 0, LOCAL_PEERCRED = 1; xucred ist 76 Bytes: Version (4),
      // uid (4), Zahl der Gruppen und die Gruppen.
      roh = verbindung.getRawOption(RawSocketOption(0, 1, Uint8List(76)));
    } else {
      // SOL_SOCKET = 1, SO_PEERCRED = 17; ucred: pid (4), uid (4), gid (4).
      roh = verbindung.getRawOption(RawSocketOption(1, 17, Uint8List(12)));
    }
    final gegenueber = ByteData.sublistView(roh).getUint32(4, Endian.host);
    return gegenueber == uid ? null : 'Die Gegenseite gehört einem anderen Konto.';
  } catch (_) {
    return 'Das Konto der Gegenseite ließ sich nicht feststellen.';
  }
}

/// Die Länge, die ein Socket-Pfad höchstens haben darf: `sun_path` hat 104
/// Bytes auf dem Mac und 108 unter Linux, jeweils mit abschließender Null.
const _socketPfadHoechstens = 100;

class UnixKanal extends KanalOrt {
  UnixKanal({
    this.ketten,
    PrivatSystem? system,
    this.rechte = const UnixDateiRechte(),
    this.gegenstelle = gegenstelleDesKontos,
  }) : system = system ?? UnixPrivatSystem();

  /// Die Ordnerketten ([kanalOrdnerKetten]); ohne Angabe die des Systems.
  final List<List<String>> Function()? ketten;
  final PrivatSystem system;
  final DateiRechte rechte;
  final GegenstellePruefer gegenstelle;

  List<List<String>> _kettenJetzt() {
    try {
      return (ketten ?? () => kanalOrdnerKetten(Platform.environment, system: system))();
    } on StateError {
      return const []; // ohne Benutzerordner gibt es keinen Ort
    }
  }

  static String _socket(String ordner, String name) => p.join(ordner, '$name.sock');

  static InternetAddress _adresse(String pfad) => InternetAddress(pfad, type: InternetAddressType.unix);

  @override
  Future<KanalLauscher> lauschen(String name, {void Function(String grund)? abgewiesen}) async {
    if (!kanalNameGueltig(name)) throw KanalFehler('Der Profilname eignet sich nicht für einen Kanal.');
    String? ordner;
    String? grund;
    for (final kette in _kettenJetzt()) {
      if (_socket(kette.last, name).length > _socketPfadHoechstens) {
        grund ??= 'Der Pfad des Kanals ist zu lang für einen Unix-Socket.';
        continue;
      }
      try {
        for (final o in kette) {
          privaterOrdnerAnlegen(o, system: system, bezeichnung: 'Der Ordner für den Kanal', pfadNennen: false);
        }
        ordner = kette.last;
        break;
      } on PrivaterOrdnerFehler catch (x) {
        grund ??= x.meldung;
      }
    }
    if (ordner == null) throw KanalUnsicher(grund ?? 'Es gibt keinen Ordner für den Kanal.');
    final pfad = _socket(ordner, name);
    await _alteEntfernen(pfad);
    final server = await ServerSocket.bind(_adresse(pfad), 0);
    try {
      rechte.chmod(pfad, 0x180);
    } on FileSystemException {
      await server.close();
      throw KanalUnsicher('Der Kanal ließ sich nicht absichern.');
    }
    return _UnixLauscher(server, pfad, system.uid, gegenstelle, abgewiesen);
  }

  /// Ein Socket aus einem früheren Lauf liegt noch da, wenn die App nicht
  /// regulär beendet wurde: Antwortet niemand darauf, wird er ersetzt;
  /// antwortet jemand, läuft die App dieses Kontos schon (E27), und der Start
  /// bricht ab. Nur im eigenen, privaten Ordner (privaterOrdnerAnlegen).
  Future<void> _alteEntfernen(String pfad) async {
    final art = FileSystemEntity.typeSync(pfad, followLinks: false);
    if (art == FileSystemEntityType.notFound) return;
    if (art == FileSystemEntityType.unixDomainSock) {
      try {
        (await Socket.connect(_adresse(pfad), 0)).destroy();
        throw KanalFehler('moocp läuft in diesem Konto schon.');
      } on SocketException {
        // Niemand lauscht: ein Rest.
      }
    }
    File(pfad).deleteSync();
  }

  @override
  Future<KanalVerbindung> verbinden(String name) async {
    if (!kanalNameGueltig(name)) throw KanalFehler('Der Profilname eignet sich nicht für einen Kanal.');
    String? unsicher;
    for (final kette in _kettenJetzt()) {
      // Eine Kette, die es nicht gibt, ist nur ein Ort, an dem die App nicht
      // lauscht; eine, die es gibt und nicht dem Konto gehört, ist ein Fehler.
      if (system.angabe(kette.first) == null || _socket(kette.last, name).length > _socketPfadHoechstens) continue;
      try {
        for (final o in kette) {
          privaterOrdnerPruefen(o, system: system, bezeichnung: 'Der Ordner für den Kanal', pfadNennen: false);
        }
      } on PrivaterOrdnerFehler catch (x) {
        // „fehlt“: Die Kette ist nur nicht ganz aufgebaut, die App lauscht dort nicht.
        if (!x.meldung.endsWith('fehlt.')) unsicher ??= x.meldung;
        continue;
      }
      final pfad = _socket(kette.last, name);
      final e = rechte.eintrag(pfad);
      if (e == null) continue;
      if (e.art != FileSystemEntityType.unixDomainSock) {
        unsicher ??= 'Der Kanal ist kein Socket.';
        continue;
      }
      if (e.uid != system.uid) {
        unsicher ??= 'Der Kanal gehört einem anderen Konto.';
        continue;
      }
      if (e.modus & 0x3f != 0) {
        unsicher ??= 'Der Kanal ist für andere Konten zugänglich.';
        continue;
      }
      final Socket s;
      try {
        s = await Socket.connect(_adresse(pfad), 0);
      } on SocketException {
        continue; // ein Rest, auf dem niemand lauscht
      }
      final g2 = gegenstelle(s, system.uid);
      if (g2 != null) {
        s.destroy();
        unsicher ??= g2;
        continue;
      }
      return _SocketVerbindung(s);
    }
    throw unsicher != null ? KanalUnsicher(unsicher) : KanalNichtDa();
  }

  /// Je Profil eine Datei: Die Werkzeuge eines Plugins hängen am Profil (E35).
  static String _listeDatei(String name) => 'werkzeugliste-$name.json';

  /// Höchstens so viel liest die Brücke von der Liste.
  static const _listeHoechstens = 8 * 1024 * 1024;

  /// Schreibt die Liste in den Kanalordner des Kontos, über eine Zwischendatei
  /// und mit 0600; der Ordner ist derselbe, in dem [lauschen] den Socket anlegt.
  @override
  Future<void> listeAblegen(String name, String json) async {
    if (!kanalNameGueltig(name)) throw KanalFehler('Der Profilname eignet sich nicht für einen Kanal.');
    for (final kette in _kettenJetzt()) {
      try {
        for (final o in kette) {
          privaterOrdnerAnlegen(o, system: system, bezeichnung: 'Der Ordner für den Kanal', pfadNennen: false);
        }
      } on PrivaterOrdnerFehler {
        continue;
      }
      final ziel = p.join(kette.last, _listeDatei(name));
      final zwischen = File('$ziel.neu');
      zwischen.writeAsStringSync(json, flush: true);
      rechte.chmod(zwischen.path, 0x180);
      zwischen.renameSync(ziel);
      return;
    }
    throw KanalUnsicher('Die Werkzeugliste ließ sich nicht ablegen.');
  }

  /// Löscht die Liste in jeder Kette, in der Ordner und Datei dem Konto allein
  /// gehören (wie beim Lesen); eine fremde Datei bleibt stehen.
  @override
  Future<void> listeEntfernen(String name) async {
    if (!kanalNameGueltig(name)) return;
    for (final kette in _kettenJetzt()) {
      if (system.angabe(kette.first) == null) continue;
      try {
        for (final o in kette) {
          privaterOrdnerPruefen(o, system: system, bezeichnung: 'Der Ordner für den Kanal', pfadNennen: false);
        }
      } on PrivaterOrdnerFehler {
        continue;
      }
      final pfad = p.join(kette.last, _listeDatei(name));
      final e = rechte.eintrag(pfad);
      if (e == null || e.art != FileSystemEntityType.file || e.uid != system.uid) continue;
      try {
        File(pfad).deleteSync();
      } on FileSystemException {
        continue;
      }
    }
  }

  /// Liest die Liste, wenn Ordner und Datei dem Konto allein gehören.
  @override
  Future<String?> listeLesen(String name) async {
    if (!kanalNameGueltig(name)) return null;
    for (final kette in _kettenJetzt()) {
      if (system.angabe(kette.first) == null) continue;
      try {
        for (final o in kette) {
          privaterOrdnerPruefen(o, system: system, bezeichnung: 'Der Ordner für den Kanal', pfadNennen: false);
        }
      } on PrivaterOrdnerFehler {
        continue;
      }
      final pfad = p.join(kette.last, _listeDatei(name));
      final e = rechte.eintrag(pfad);
      if (e == null || e.art != FileSystemEntityType.file || e.uid != system.uid || e.modus & 0x3f != 0) continue;
      try {
        final datei = File(pfad);
        if (datei.lengthSync() > _listeHoechstens) continue;
        return datei.readAsStringSync();
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }
}

class _UnixLauscher implements KanalLauscher {
  _UnixLauscher(this._server, this._pfad, int uid, GegenstellePruefer pruefer, void Function(String)? abgewiesen) {
    _abo = _server.listen((s) {
      // Vor dem ersten Lesen: Ein Socket liefert nichts, solange ihn niemand
      // abonniert.
      final g = pruefer(s, uid);
      if (g != null) {
        s.destroy();
        abgewiesen?.call(g);
        return;
      }
      _neu.add(_SocketVerbindung(s));
    });
  }

  final ServerSocket _server;
  final String _pfad;
  late final StreamSubscription<Socket> _abo;
  final _neu = StreamController<KanalVerbindung>();

  @override
  Stream<KanalVerbindung> get verbindungen => _neu.stream;

  @override
  Future<void> schliessen() async {
    await _abo.cancel();
    await _server.close();
    // Ohne Zuhörer meldet close() das Ende erst, wenn jemand zuhört.
    unawaited(_neu.close());
    try {
      File(_pfad).deleteSync();
    } on FileSystemException {
      // Schon weg.
    }
  }
}

class _SocketVerbindung implements KanalVerbindung {
  _SocketVerbindung(this._socket) {
    // Ein Schreibfehler, nachdem die Gegenseite weg ist, darf nicht als
    // unbehandelter Fehler enden: Er zeigt sich am Ende von [eingang].
    _socket.done.then<void>((_) {}, onError: (_) {});
  }

  final Socket _socket;

  @override
  Stream<List<int>> get eingang => _socket.cast<List<int>>();

  @override
  void senden(List<int> daten) {
    try {
      _socket.add(daten);
    } catch (_) {
      // Die Gegenseite ist weg; das Ende von [eingang] meldet es.
    }
  }

  @override
  Future<void> schliessen() async {
    try {
      await _socket.close();
    } catch (_) {
      // s. o.
    }
    _socket.destroy();
  }
}
