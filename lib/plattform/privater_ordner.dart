// Ein Ordner, der dem angemeldeten Konto allein gehört (Linux und macOS).
//
// Darin liegen die Kanäle zwischen KI-Werkzeug und App (mcp/kanal.dart): ein
// Unix-Socket ist nur so privat wie der Ordner, in dem er liegt. Geprüft wird
// mit lstat-Angaben, nie über eine Verknüpfung hinweg: Besitzer ist das
// laufende Konto, die Rechte sind genau 0700, und der Eintrag selbst ist ein
// Ordner, keine Verknüpfung. Jede Abweichung ist ein Fehler, den die Aufrufer
// nicht übergehen -- ein Ordner, den ein anderes Konto anlegen oder vertauschen
// kann, lässt dieses Konto an die Stelle des Empfängers treten.
//
// Die App stellt den Ordner her ([privatHerstellen]: anlegen, eigene zu weite
// Rechte zusammenziehen, dann prüfen); die Brücke prüft nur
// ([privatPruefen]) und ändert nichts. Die Meldungen nennen nie den Pfad (E11).
//
// Ohne Flutter: Die Brücke (mcp/bruecke.dart) bindet diese Datei ein.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'kindprozess.dart';

/// Was lstat über einen Eintrag sagt.
class PosixEintrag {
  const PosixEintrag({required this.uid, required this.modus, required this.art});

  /// Besitzer.
  final int uid;

  /// Die Rechtebits (nur die unteren neun, ohne Dateityp).
  final int modus;

  /// Ohne Verknüpfungen zu folgen: [FileSystemEntityType.link] für eine
  /// Verknüpfung, [FileSystemEntityType.directory] nur für einen echten Ordner.
  final FileSystemEntityType art;
}

/// Der Zugriff auf das Dateisystem, den die Prüfung braucht; austauschbar,
/// damit sich Besitzer anderer Konten ohne ein zweites Konto prüfen lassen.
abstract interface class PosixDatei {
  /// Die Kennung des laufenden Kontos (effektiv).
  int get uid;

  /// Null, wenn es [pfad] nicht gibt.
  PosixEintrag? lstat(String pfad);

  void ordnerAnlegen(String pfad);

  void chmod(String pfad, int modus);
}

/// Das echte Dateisystem. Die Kennung und chmod kommen aus der C-Bibliothek
/// (Linux und macOS), den Besitzer gibt `stat` an: Dart kennt ihn nicht, und
/// die Struktur von lstat unterscheidet sich je System und Architektur.
class EchtesPosix implements PosixDatei {
  const EchtesPosix();

  @override
  int get uid => DynamicLibrary.process().lookupFunction<Uint32 Function(), int Function()>('geteuid')();

  @override
  PosixEintrag? lstat(String pfad) {
    final art = FileSystemEntity.typeSync(pfad, followLinks: false);
    if (art == FileSystemEntityType.notFound) return null;
    if (art != FileSystemEntityType.directory) {
      return PosixEintrag(uid: -1, modus: 0, art: art);
    }
    final r = prozessAusfuehrenSync(
      '/usr/bin/stat',
      Platform.isMacOS ? ['-f', '%u', pfad] : ['-c', '%u', '--', pfad],
    );
    final besitzer = r.exitCode == 0 ? int.tryParse('${r.stdout}'.trim()) : null;
    return PosixEintrag(
      uid: besitzer ?? -1, // nicht feststellbar: gilt als fremd
      modus: FileStat.statSync(pfad).mode & 0x1ff,
      art: art,
    );
  }

  @override
  void ordnerAnlegen(String pfad) => Directory(pfad).createSync(recursive: true);

  @override
  void chmod(String pfad, int modus) {
    final f = DynamicLibrary.process()
        .lookupFunction<Int32 Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>('chmod');
    final zeiger = pfad.toNativeUtf8();
    try {
      if (f(zeiger, modus) != 0) throw const FileSystemException('chmod fehlgeschlagen');
    } finally {
      malloc.free(zeiger);
    }
  }
}

const _nurBesitzer = 0x1c0; // 0700

/// Null, wenn [pfad] ein Ordner des laufenden Kontos mit genau den Rechten
/// 0700 ist und keine Verknüpfung; sonst der Grund in einem Satz. Ändert
/// nichts.
String? privatPruefen(String pfad, {PosixDatei posix = const EchtesPosix()}) {
  final e = posix.lstat(pfad);
  if (e == null) return 'Der Ordner für den Kanal fehlt.';
  if (e.art == FileSystemEntityType.link) return 'Der Ordner für den Kanal ist eine Verknüpfung.';
  if (e.art != FileSystemEntityType.directory) return 'Der Kanal liegt nicht in einem Ordner.';
  if (e.uid != posix.uid) return 'Der Ordner für den Kanal gehört einem anderen Konto.';
  if (e.modus != _nurBesitzer) return 'Der Ordner für den Kanal ist nicht allein dem Konto zugänglich.';
  return null;
}

/// Legt [pfad] mit 0700 an, wenn er fehlt, zieht die Rechte eines eigenen
/// Ordners auf 0700 zusammen und prüft dann ([privatPruefen]). Einen fremden
/// Ordner und eine Verknüpfung fasst es nicht an. Null bei Erfolg.
String? privatHerstellen(String pfad, {PosixDatei posix = const EchtesPosix()}) {
  var e = posix.lstat(pfad);
  if (e == null) {
    try {
      posix.ordnerAnlegen(pfad);
      posix.chmod(pfad, _nurBesitzer);
    } on FileSystemException {
      return 'Der Ordner für den Kanal ließ sich nicht anlegen.';
    }
  } else if (e.art == FileSystemEntityType.directory && e.uid == posix.uid && e.modus != _nurBesitzer) {
    try {
      posix.chmod(pfad, _nurBesitzer);
    } on FileSystemException {
      return 'Der Ordner für den Kanal ließ sich nicht absichern.';
    }
  }
  return privatPruefen(pfad, posix: posix);
}

/// Setzt eine Datei des Kontos auf 0600 (Einstellungen und was sonst
/// Zugangsdaten tragen könnte). Auf Windows ohne Wirkung: Dort liegt alles im
/// Benutzerprofil. Wirft nicht; ein Fehler lässt die Datei, wie sie ist.
void dateiPrivat(String pfad, {PosixDatei posix = const EchtesPosix()}) {
  if (Platform.isWindows) return;
  try {
    posix.chmod(pfad, 0x180);
  } catch (_) {
    // Bleibt lesbar, wie sie war; der Aufrufer hat nichts davon zu melden.
  }
}
