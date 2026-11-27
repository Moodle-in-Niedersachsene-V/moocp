// Besitzer und Rechte einzelner Einträge, die nicht Ordner sind (Linux und
// macOS): die Socket-Datei eines Kanals (mcp/kanal.dart) und die Dateien, in
// denen das Konto Einstellungen ablegt. Ordner prüft privater_ordner.dart.
//
// `stat` statt der Struktur `struct stat` über dart:ffi: deren Aufbau ist je
// System und Architektur verschieden. Ohne -L folgt `stat` keiner Verknüpfung.
//
// Ohne Flutter: Die Brücke (mcp/bruecke.dart) bindet diese Datei ein.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'kindprozess.dart';

/// Was `lstat` über einen Eintrag sagt, [art] ohne Verknüpfungen zu folgen.
class DateiEintrag {
  const DateiEintrag({required this.art, required this.uid, required this.modus});

  final FileSystemEntityType art;

  /// Besitzer; -1, wenn er sich nicht feststellen ließ (gilt als fremd).
  final int uid;

  /// Die Rechtebits ohne Dateityp; 0x1ff, wenn sie sich nicht feststellen
  /// ließen (gilt als offen).
  final int modus;
}

/// Der absolute Pfad von `stat`: Besitzer und Rechte sagt ein Programm an einem
/// festen Ort, nie eines, das ein anderer Eintrag im PATH vortäuschen könnte
/// (die Prüfung soll nicht von der Umgebung abhängen). Null, wenn es dort keines
/// gibt; wer `stat` braucht, behandelt das als nicht geprüft. Dieselbe Suche
/// benutzt privater_ordner.dart.
String? statProgramm() {
  for (final f in ['/usr/bin/stat', '/bin/stat']) {
    if (File(f).existsSync()) return f;
  }
  return null;
}

/// Die Naht zum Dateisystem; die Tests stellen damit fremde Besitzer nach.
abstract interface class DateiRechte {
  /// Null, wenn es [pfad] nicht gibt.
  DateiEintrag? eintrag(String pfad);

  void chmod(String pfad, int modus);
}

class UnixDateiRechte implements DateiRechte {
  const UnixDateiRechte();

  @override
  DateiEintrag? eintrag(String pfad) {
    final art = FileSystemEntity.typeSync(pfad, followLinks: false);
    if (art == FileSystemEntityType.notFound) return null;
    if (art == FileSystemEntityType.link) return DateiEintrag(art: art, uid: -1, modus: 0x1ff);
    final stat = statProgramm();
    if (stat == null) return DateiEintrag(art: art, uid: -1, modus: 0x1ff);
    final r = Platform.isMacOS
        ? prozessAusfuehrenSync(stat, ['-f', '%u:%Lp', pfad])
        : prozessAusfuehrenSync(stat, ['-c', '%u:%a', '--', pfad]);
    final m = RegExp(r'^(\d+):(\d+)\s*$').firstMatch('${r.stdout}');
    if (r.exitCode != 0 || m == null) return DateiEintrag(art: art, uid: -1, modus: 0x1ff);
    return DateiEintrag(art: art, uid: int.parse(m.group(1)!), modus: int.parse(m.group(2)!, radix: 8));
  }

  @override
  void chmod(String pfad, int modus) {
    final c = pfad.toNativeUtf8();
    try {
      final f = DynamicLibrary.process()
          .lookupFunction<Int32 Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>('chmod');
      if (f(c, modus) != 0) throw FileSystemException('Rechte ließen sich nicht setzen', pfad);
    } finally {
      malloc.free(c);
    }
  }
}

/// Setzt eine Datei auf 0600: nur das Konto liest und schreibt sie. Unter
/// Windows ohne Wirkung (dort liegt alles im Benutzerprofil). Wirft nicht, und
/// verschweigt nichts: Gelingt es nicht, ist die Antwort ein Satz für das
/// Protokoll (mit Pfad und Art des Fehlers, nie Inhalten, E11), und die Datei
/// bleibt, wie sie ist; null, wenn es gelang.
String? dateiPrivat(String pfad, {DateiRechte rechte = const UnixDateiRechte()}) {
  if (Platform.isWindows) return null;
  try {
    rechte.chmod(pfad, 0x180);
    return null;
  } catch (e) {
    return 'Die Rechte von „$pfad“ ließen sich nicht auf „nur für dieses Konto“ setzen (${e.runtimeType}): '
        'die Datei kann für andere Konten dieses Rechners lesbar sein.';
  }
}
