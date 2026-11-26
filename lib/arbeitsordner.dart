// Der Arbeitsordner: Hierhin schreibt die App, was sie aus Moodle liest, und
// von hier nimmt sie, was sie nach Moodle schreibt (imArbeitsordner in
// moodle/formular_schreiben.dart). Claude erfährt den Pfad über `status`.
//
// Er lebt so lange wie die App: beim Start geleert -- das fängt auch einen
// Absturz ab, nach dem das Leeren beim Beenden ausblieb -- und beim Beenden.
// So bleibt nichts aus Moodle auf dem Rechner liegen; alles darin lässt sich
// neu lesen oder steht in Claudes Verlauf.
//
// Ein fester Ort statt eines neuen je Start: Eine Claude-Sitzung kann einen
// Neustart der App überdauern und kennt den Pfad noch von `status`. Bei einem
// neuen Namen lehnte jedes Werkzeug den alten Pfad als „außerhalb des
// Arbeitsordners" ab, und das liest sich wie die Datensperre. So fehlt nach
// einem Neustart schlicht die Datei. Weil der Ort fest ist, läuft die App nur
// einmal (windows/runner/main.cpp, lib/einzelstart.dart).

import 'dart:io';

import 'package:path/path.dart' as p;

import 'plattform/privater_ordner.dart';

class Arbeitsordner {
  const Arbeitsordner(this.pfad, {this.pruefen});

  final String pfad;

  /// Wann geprüft wird (beim Einrichten und vor dem Leeren, nicht vor jedem
  /// Schreiben) und warum das genügt, steht in plattform/privater_ordner.dart.
  ///
  /// Prüft vor jedem Leeren, dass der Ordner noch der private des Benutzers
  /// ist (wirft [PrivaterOrdnerFehler]). Null, wo es keine Prüfung gibt
  /// (Windows, Mac und Tests ohne Linux-Prüfung).
  final void Function()? pruefen;

  /// Der Name des Ordners; unter Linux liegt er im privaten Grundordner der
  /// App (plattform/privater_ordner.dart), sonst im Temp-Verzeichnis.
  static const ordnername = 'moocp_arbeitsordner';

  /// Legt den Ordner an und leert ihn. Liefert ihn mit der Zahl der Einträge,
  /// die sich nicht löschen ließen.
  ///
  /// Der Pfad in langer Form: %TEMP% steht auf manchen Rechnern mit Kurznamen
  /// (C:\Users\LEHRKR~1\…). `status` soll die Form nennen, die Windows selbst
  /// anzeigt und Claude weiterverwendet.
  ///
  /// Unter Linux teilen sich alle Benutzer /tmp: Der Ordner liegt deshalb in
  /// einem privaten Grundordner des Benutzers ([privatesBasisverzeichnis]),
  /// wird mit Rechten 700 angelegt und vor jeder Benutzung geprüft. Besteht
  /// er die Prüfung nicht, wirft das [PrivaterOrdnerFehler], bevor etwas
  /// geschrieben oder gelöscht wird; sonst läse jeder auf dem Rechner mit,
  /// was die App aus Moodle holt. Ältere Orte unter /tmp rührt die App nicht an.
  static (Arbeitsordner, int) einrichten({
    String? temp,
    bool? linux,
    Map<String, String>? umgebung,
    PrivatSystem? system,
  }) {
    final istLinux = linux ?? Platform.isLinux;
    if (istLinux) {
      final s = system ?? UnixPrivatSystem();
      final basis = privatesBasisverzeichnis(umgebung: umgebung, temp: temp, system: s);
      final pfad = privaterOrdnerAnlegen(p.join(basis, ordnername), system: s, bezeichnung: 'Der Arbeitsordner');
      final a = Arbeitsordner(
        Directory(pfad).resolveSymbolicLinksSync(),
        pruefen: () => privaterOrdnerPruefen(pfad, system: s, bezeichnung: 'Der Arbeitsordner'),
      );
      return (a, a.leeren());
    }
    final d = Directory(p.join(temp ?? Directory.systemTemp.path, ordnername))..createSync(recursive: true);
    final a = Arbeitsordner(d.resolveSymbolicLinksSync());
    return (a, a.leeren());
  }

  /// Löscht alles im Ordner, Eintrag für Eintrag: Was gerade in Benutzung ist
  /// (etwa ein Unterordner, in dem eine Konsole steht), bleibt stehen, der
  /// Rest geht trotzdem. Verknüpfungen und Junctions löscht Dart als solche,
  /// ohne ihrem Ziel zu folgen, auch in Unterordnern -- gemessen. Liefert die
  /// Zahl der Einträge, die stehen blieben.
  int leeren() {
    pruefen?.call();
    final d = Directory(pfad);
    if (!d.existsSync()) return 0;
    var geblieben = 0;
    for (final e in d.listSync(followLinks: false)) {
      try {
        e.deleteSync(recursive: e is Directory);
      } on FileSystemException {
        geblieben++;
      }
    }
    return geblieben;
  }
}
