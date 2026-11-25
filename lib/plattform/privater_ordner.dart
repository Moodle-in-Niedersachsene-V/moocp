// Ein Ordner, den nur der angemeldete Benutzer betreten kann (Linux und Mac):
// Grundlage für alles, was die App im Temp-Bereich ablegt und was nicht an
// andere Konten auf demselben Rechner gehen darf -- der Arbeitsordner (E5),
// der Ordner für Downloads der Plugins (E36).
//
// Wo: unter Linux in `$XDG_RUNTIME_DIR/moocp`, wenn die Sitzung dieses
// Verzeichnis hat (absolut, ihr gehörend, Rechte 700, keine Verknüpfung);
// sonst im Temp-Verzeichnis unter einem Namen mit der Benutzernummer
// (`moocp-<uid>`). Die Nummer kommt vom Betriebssystem, nicht aus $USER: Wer
// die Umgebung setzt, bestimmt sonst, welchen Ordner die App benutzt.
//
// Angelegt wird mit Rechten 700 im selben Systemaufruf (`mkdir`, über
// dart:ffi), nie erst mit den Rechten der umask und dann per chmod: Es gibt
// keinen Moment, in dem ein anderes Konto hineinsehen könnte. Vor jeder
// Benutzung und jedem Leeren wird mit `lstat` (ohne Verknüpfungen
// aufzulösen) geprüft: ein echter Ordner, dem Benutzer gehörend, Rechte
// genau 700. Besteht ein vorhandener Ordner die Prüfung nicht, benutzt ihn
// die App nicht, übernimmt ihn nicht (kein chmod auf fremde Ordner) und
// räumt ihn nicht auf; sie bricht mit einer klaren Meldung ab
// ([PrivaterOrdnerFehler]), bevor etwas geschrieben oder gelöscht wird.
//
// Die Prüfung gilt dem Ordner, nicht dem Pfad davor: Ein fremdes Konto kann
// im klebrigen /tmp keinen Ordner eines anderen umbenennen oder ersetzen.
// Unter Windows gibt es das Problem nicht (das Temp-Verzeichnis gehört dem
// Konto), dort wird diese Datei nicht benutzt.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'kindprozess.dart';

/// Rechte, die ein privater Ordner genau haben muss: rwx für den Besitzer,
/// nichts für Gruppe und andere, keine Sonderbits.
const privaterModus = 448; // 0700

/// Der Ordner ist nicht privat oder ließ sich nicht anlegen. [meldung] ist
/// für die Lehrkraft gedacht (Deutsch, ohne Inhalte aus Moodle).
class PrivaterOrdnerFehler implements Exception {
  PrivaterOrdnerFehler(this.meldung);

  final String meldung;

  @override
  String toString() => meldung;
}

/// Was `lstat` über einen Eintrag sagt.
class DateiAngabe {
  const DateiAngabe({required this.ordner, required this.verknuepfung, required this.uid, required this.modus});

  /// Ein echter Ordner (keine Verknüpfung darauf).
  final bool ordner;
  final bool verknuepfung;
  final int uid;

  /// Die Rechtebits (ohne Dateityp), dezimal; 0700 ist [privaterModus].
  final int modus;
}

/// Die Naht zum Dateisystem: Tests setzen sie ein, um fremde Besitzer und
/// Rechte nachzustellen, ohne ein zweites Konto zu brauchen.
abstract interface class PrivatSystem {
  /// Die Benutzernummer des Prozesses.
  int get uid;

  /// `lstat` auf [pfad]; null, wenn es ihn nicht gibt.
  DateiAngabe? angabe(String pfad);

  /// Legt genau einen Ordner mit Rechten 700 an (kein `-p`, kein Übernehmen
  /// eines vorhandenen); wirft [FileSystemException], wenn das nicht geht.
  void anlegen(String pfad);
}

typedef _MkdirC = Int32 Function(Pointer<Utf8>, Uint32);
typedef _MkdirDart = int Function(Pointer<Utf8>, int);
typedef _GetuidC = Uint32 Function();
typedef _GetuidDart = int Function();

/// Die Umsetzung für Linux und Mac über libc (dart:ffi) und `stat`.
class UnixPrivatSystem implements PrivatSystem {
  UnixPrivatSystem();

  late final int _uid = DynamicLibrary.process().lookupFunction<_GetuidC, _GetuidDart>('getuid')();

  @override
  int get uid => _uid;

  @override
  DateiAngabe? angabe(String pfad) {
    final art = FileSystemEntity.typeSync(pfad, followLinks: false);
    if (art == FileSystemEntityType.notFound) return null;
    if (art == FileSystemEntityType.link) {
      return const DateiAngabe(ordner: false, verknuepfung: true, uid: -1, modus: 0);
    }
    if (art != FileSystemEntityType.directory) {
      return const DateiAngabe(ordner: false, verknuepfung: false, uid: -1, modus: 0);
    }
    // `stat` statt der Struktur `struct stat` über ffi: deren Aufbau ist je
    // Plattform und Architektur verschieden. Ohne -L folgt `stat` keiner
    // Verknüpfung; das Format ist unter GNU (-c) und BSD/Mac (-f) verschieden.
    final r = Platform.isMacOS
        ? prozessAusfuehrenSync('stat', ['-f', '%u:%Lp', pfad])
        : prozessAusfuehrenSync('stat', ['-c', '%u:%a', '--', pfad]);
    final m = RegExp(r'^(\d+):(\d+)\s*$').firstMatch('${r.stdout}');
    if (r.exitCode != 0 || m == null) {
      throw PrivaterOrdnerFehler('Die Rechte eines Ordners ließen sich nicht lesen.');
    }
    return DateiAngabe(
      ordner: true,
      verknuepfung: false,
      uid: int.parse(m.group(1)!),
      modus: int.parse(m.group(2)!, radix: 8),
    );
  }

  @override
  void anlegen(String pfad) {
    final c = pfad.toNativeUtf8();
    try {
      final f = DynamicLibrary.process().lookupFunction<_MkdirC, _MkdirDart>('mkdir');
      if (f(c, privaterModus) != 0) {
        throw FileSystemException('Ordner ließ sich nicht anlegen', pfad);
      }
    } finally {
      malloc.free(c);
    }
  }
}

bool _privat(DateiAngabe? a, int uid) =>
    a != null && a.ordner && !a.verknuepfung && a.uid == uid && a.modus == privaterModus;

/// Prüft, dass [pfad] ein echter Ordner des Benutzers mit Rechten genau 700
/// ist, sonst wirft es [PrivaterOrdnerFehler]. [bezeichnung] steht in der
/// Meldung; der Pfad nur, wenn [pfadNennen] gilt (der Ordner für Downloads
/// der Plugins gehört in keine Meldung, E36).
void privaterOrdnerPruefen(String pfad, {PrivatSystem? system, String bezeichnung = 'Der Ordner', bool pfadNennen = true}) {
  final s = system ?? UnixPrivatSystem();
  final a = s.angabe(pfad);
  if (a == null) throw PrivaterOrdnerFehler('$bezeichnung fehlt.');
  if (_privat(a, s.uid)) return;
  final grund = a.verknuepfung
      ? 'er ist eine Verknüpfung'
      : !a.ordner
      ? 'dort liegt kein Ordner'
      : a.uid != s.uid
      ? 'er gehört einem anderen Benutzer'
      : 'andere Benutzer dürfen darauf zugreifen oder er hat unerwartete Rechte';
  final wo = pfadNennen ? ' („$pfad“)' : '';
  throw PrivaterOrdnerFehler(
    '$bezeichnung$wo ist nicht privat: $grund. moocp benutzt ihn nicht und schreibt und löscht dort nichts, '
    'damit nichts aus Moodle für andere Benutzer dieses Rechners sichtbar wird. '
    'Bitte den Ordner entfernen oder umbenennen und moocp neu starten.',
  );
}

/// Legt [pfad] mit Rechten 700 an, wenn es ihn nicht gibt (das Elternverzeichnis
/// muss da sein), und prüft ihn dann wie [privaterOrdnerPruefen]. Ein
/// vorhandener Ordner wird nur geprüft, nie angepasst. Liefert [pfad].
String privaterOrdnerAnlegen(
  String pfad, {
  PrivatSystem? system,
  String bezeichnung = 'Der Ordner',
  bool pfadNennen = true,
}) {
  final s = system ?? UnixPrivatSystem();
  if (s.angabe(pfad) == null) {
    try {
      s.anlegen(pfad);
    } on FileSystemException {
      // Ein anderer Prozess kann ihn eben angelegt haben; die Prüfung unten
      // entscheidet, ob er benutzbar ist.
      if (s.angabe(pfad) == null) {
        throw PrivaterOrdnerFehler(
          '$bezeichnung${pfadNennen ? ' („$pfad“)' : ''} ließ sich nicht anlegen. moocp schreibt dort nichts.',
        );
      }
    }
  }
  privaterOrdnerPruefen(pfad, system: s, bezeichnung: bezeichnung, pfadNennen: pfadNennen);
  return pfad;
}

/// Der Pfad des privaten Grundordners der App unter Linux und Mac, ohne ihn
/// anzulegen: `$XDG_RUNTIME_DIR/moocp`, wenn dieses Verzeichnis absolut, privat
/// und ein Ordner des Benutzers ist, sonst `<temp>/moocp-<uid>`. Der Ort ist
/// über Neustarts der App stabil (E5), solange die Sitzung dieselbe bleibt.
String privatesBasisPfad({Map<String, String>? umgebung, String? temp, PrivatSystem? system}) {
  final s = system ?? UnixPrivatSystem();
  final x = (umgebung ?? Platform.environment)['XDG_RUNTIME_DIR'];
  if (x != null && p.isAbsolute(x) && _privat(s.angabe(x), s.uid)) return p.join(x, 'moocp');
  return p.join(temp ?? Directory.systemTemp.path, 'moocp-${s.uid}');
}

/// Legt den privaten Grundordner an und prüft ihn ([privatesBasisPfad]).
/// Hier hängen die Ordner, die nur dem Benutzer gehören sollen; wer einen
/// weiteren braucht (etwa eine Socket-Datei), legt ihn darunter mit
/// [privaterOrdnerAnlegen] an.
String privatesBasisverzeichnis({Map<String, String>? umgebung, String? temp, PrivatSystem? system}) {
  final s = system ?? UnixPrivatSystem();
  return privaterOrdnerAnlegen(
    privatesBasisPfad(umgebung: umgebung, temp: temp, system: s),
    system: s,
    bezeichnung: 'Der private Ordner von moocp',
  );
}
