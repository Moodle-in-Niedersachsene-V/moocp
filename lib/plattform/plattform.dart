import 'dart:io';

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
/// stehen in [windows.dart] und [macos.dart]; der Kern kennt nur diese
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

/// Die einzige Stelle, die nach dem Betriebssystem fragt.
final PlattformBrowser plattformBrowser = Platform.isMacOS ? MacBrowser() : WindowsBrowser();

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
