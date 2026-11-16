import 'dart:io';

import 'kindprozess.dart';
import 'linux.dart';
import 'macos.dart';
import 'windows.dart';

/// Eine Browserart, mit der die Bildschirmfotos laufen. Die Reihenfolge der
/// Aufzählung ist die Suchreihenfolge.
enum BrowserArt {
  edge('Microsoft Edge'),
  chrome('Google Chrome'),
  chromium('Chromium');

  const BrowserArt(this.anzeige);

  /// Der Name, wie ihn die Lehrkraft in Meldungen liest.
  final String anzeige;
}

/// Was die Bildschirmfotos vom Betriebssystem brauchen. Die Umsetzungen
/// stehen in [windows.dart], [macos.dart] und [linux.dart]; der Kern kennt nur diese
/// Schnittstelle (E29).
abstract interface class PlattformBrowser {
  /// Die Browserarten, die es auf diesem System gibt, in Suchreihenfolge.
  List<BrowserArt> get arten;

  /// Pfad des Programms der Art, oder null, wenn sie hier fehlt.
  Future<String?> programm(BrowserArt art);

  /// Ob die Verwaltung des Rechners die Fernsteuerung der Art abgeschaltet
  /// hat (RemoteDebuggingAllowed = 0). Fehlt die Richtlinie, ist sie erlaubt.
  Future<bool> fernsteuerungVerboten(BrowserArt art);

  /// Beendet hart alle Prozesse von [programm], die mit [profil] laufen, und
  /// liefert ihre Zahl (-1, wenn sie sich nicht ermitteln ließ). Andere
  /// Browserprozesse bleiben unberührt.
  Future<int> prozesseBeenden(Directory profil, String programm);
}

/// Beendet hart (`kill -9`) alle Prozesse, deren Aufruf [profil] enthält, und
/// liefert ihre Zahl (-1, wenn sie sich nicht ermitteln ließ). Gemeinsam für
/// Mac und Linux: `ps -axww -o pid=,command=` versteht beider `ps`. Fremde
/// Browserprozesse haben ein anderes Profil und bleiben unberührt.
Future<int> unixProzesseBeenden(Directory profil) async {
  try {
    final r = await prozessAusfuehren('ps', ['-axww', '-o', 'pid=,command=']);
    final pids = <String>[];
    for (final zeile in '${r.stdout}'.split('\n')) {
      final m = RegExp(r'^\s*(\d+)\s(.*)$').firstMatch(zeile);
      if (m == null || !m.group(2)!.contains(profil.path)) continue;
      pids.add(m.group(1)!);
    }
    for (final pid in pids) {
      await prozessAusfuehren('kill', ['-9', pid]);
    }
    return pids.length;
  } on ProcessException {
    return -1;
  }
}

/// Die einzige Stelle, die nach dem Betriebssystem fragt.
final PlattformBrowser plattformBrowser = Platform.isMacOS
    ? MacBrowser()
    : Platform.isLinux
    ? LinuxBrowser()
    : WindowsBrowser();

/// Ob die Zwischenablage hier HTML neben dem Text trägt (zwischenablage.dart):
/// unter Windows und macOS ja, sonst liegt nur der Quelltext als Text darin.
/// Hier statt dort, damit der Kern (lib/moodle/) danach fragen kann, ohne
/// Flutter und die native Bibliothek einzubinden.
bool get zwischenablageMitHtml => Platform.isWindows || Platform.isMacOS;

/// Beendet [prozess] hart, unter Windows samt den Prozessen, die er selbst
/// gestartet hat (windows.dart, prozessbaumBeendenWindows). Auf dem Mac nur
/// den Prozess selbst: Dart startet ihn nicht in einer eigenen
/// Prozessgruppe, ein Signal an die Gruppe träfe die App mit.
Future<void> prozessbaumBeenden(Process prozess) async {
  if (Platform.isWindows) await prozessbaumBeendenWindows(prozess.pid);
  prozess.kill(ProcessSignal.sigkill);
}

/// Der Benutzerordner aus [umgebung]: USERPROFILE unter Windows, sonst HOME;
/// null, wenn er nicht gesetzt ist. Dort beginnt die Wahl eines Ordners oder
/// einer Datei für ein Plugin, wenn es keinen Startordner nennt.
String? benutzerordner(Map<String, String> umgebung) {
  final o = umgebung[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  return o == null || o.isEmpty ? null : o;
}
