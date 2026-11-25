// Wie der Browser der Bildschirmfotos gestartet wird und wie die App mit ihm
// spricht: über eine Pipe, die nur der Browser und die App kennen
// (--remote-debugging-pipe), nie über einen Port. Ein Port auf 127.0.0.1
// erreicht jedes Konto des Rechners; eine Pipe gehört den beiden Prozessen,
// die sie erben (E18, E28).
//
// Der Kern (lib/moodle/bildschirmfoto.dart) kennt nur diese Schnittstelle; die
// Umsetzungen stehen in browser_unix.dart (Linux, Mac) und
// browser_windows.dart. Tests setzen einen nachgebauten Browser ein.

import 'dart:io';

/// Ein gestarteter Browser mit seinem Kanal: [eingang] liefert, was der
/// Browser schreibt (fd 4), [senden] gibt ihm Bytes (fd 3).
abstract interface class BrowserProzess {
  int get pid;

  /// Bytes des Browsers; endet, wenn der Browser den Kanal schließt.
  Stream<List<int>> get eingang;

  /// Bytes an den Browser. Wirft nie; ist der Kanal zu, gehen sie verloren
  /// (die Antwort scheitert dann an der beendeten Verbindung).
  void senden(List<int> bytes);

  /// Erfüllt sich mit dem Ende des gestarteten Prozesses. Edge startet sich
  /// bisweilen neu und läuft in einem anderen weiter; das Ende heißt dann
  /// nicht, dass der Browser weg ist (bildschirmfoto.dart, _beenden).
  Future<int> get beendet;

  /// Beendet den gestarteten Prozess hart, unter Windows samt seinen Kindern,
  /// und schließt den Kanal.
  Future<void> beenden();
}

/// Startet den Browser mit seiner Pipe.
abstract interface class BrowserStarter {
  /// Legt das Wegwerf-Profil des Browsers in [arbeitsordner] an. Unter Linux
  /// und auf dem Mac privat (Rechte 700, dem aktuellen Benutzer gehörig, keine
  /// Verknüpfung): Dort liegt auch die Pipe.
  Future<Directory> profilAnlegen(String arbeitsordner);

  /// Startet [programm] mit [argumente] (ohne Pipe-Schalter, den setzt die
  /// Umsetzung nicht, er steht schon in [argumente]) und dem Profil [profil]
  /// aus [profilAnlegen]. Scheitert mit [BrowserStartFehler], wenn der
  /// Browser nicht startet oder den Kanal nicht öffnet.
  Future<BrowserProzess> starten(String programm, List<String> argumente, Directory profil);
}

/// Der Browser ließ sich nicht starten oder bekam seinen Kanal nicht.
class BrowserStartFehler implements Exception {
  BrowserStartFehler(this.meldung);
  final String meldung;
  @override
  String toString() => meldung;
}

/// Die Schalter des Browsers für ein Bildschirmfoto. Nie ein Port: Die
/// Steuerung läuft über die Pipe (`--remote-debugging-pipe`, fd 3 und 4).
List<String> browserArgumente({required Directory profil, required int breite}) => [
  '--headless=new',
  '--remote-debugging-pipe',
  '--user-data-dir=${profil.path}',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-extensions',
  '--disable-sync',
  '--disable-background-networking',
  '--disable-component-update',
  '--disable-default-apps',
  '--mute-audio',
  '--hide-scrollbars',
  '--window-size=$breite,900',
  'about:blank',
];
