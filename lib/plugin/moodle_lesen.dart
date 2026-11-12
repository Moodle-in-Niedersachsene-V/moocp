// Ein Plugin liest Moodle über die Adresse der App (E36): mit der Sitzung des
// Instanzprofils des Aufrufs, in den Grenzen der Positivliste der App, und nur
// lesend.
//
// Nur lesend, weil die Positivliste Schreibpfade enthält, die die eingebauten
// Werkzeuge nur mit Freigabe, Namensprüfung, Stand-Prüfung und Rücklesen
// benutzen (A3, E4). Roh über die Adresse wären sie ein Weg an all dem vorbei.
// Ein Plugin, das etwas ändern will, ruft dafür ein eingebautes Werkzeug auf
// (/v1/werkzeug). Darum gilt für ein Plugin nur der lesende Teil der
// Positivliste ([Erlaubt.lesend]): GET, kein `sesskey` (mit ihm ist eine
// Adresse in Moodle eine Aktion), kein Schritt eines Schreibvorgangs.
//
// Geprüft wird jede Adresse und jedes Umleitungsziel, in dieser Reihenfolge:
//
//  1. die Bereiche, die für jedes Plugin gesperrt sind (adressmuster.dart,
//     [sperrbereichDerAdresse]): Adminbereich, Anmeldung, Zugangsdaten;
//  2. die Normalform des Pfads: kein „//“, „\“, „.“ oder „..“, auch nicht
//     prozentkodiert. Ein Server läse sie anders als die Listen, die den Pfad
//     als Text prüfen;
//  3. Dateien unter `pluginfile.php/<Kontext>/user/`: Die Sperrliste nimmt
//     davon nur die Sicherungsdatei aus, und die darf nur der Ablauf der
//     eingebauten Werkzeuge laden, der vorher sicherstellt, dass sie ohne
//     Nutzerdaten ist (E29);
//  4. die Sperrliste der App, auf der Adresse, wie sie gesendet wird, und noch
//     einmal mit aufgelöster Prozentkodierung -- Moodle löst sie auf, die
//     regulären Ausdrücke der Sperrliste nicht;
//  5. die Positivliste der App, nur ihr lesender Teil.
//
// Positivliste und Sperrliste werden für kein Plugin geweitet. Was nicht
// erlaubt ist, lehnt die App ohne Dialog ab; die Meldung nennt den Grund, nie
// Parameterwerte.

import '../moodle/moodle_zugang.dart';
import '../moodle/sperrliste.dart';
import 'adressmuster.dart';

/// So viele Bytes liefert die Adresse der App höchstens als Text. Größere
/// Inhalte (Dateien, große Exporte) gehen nur als Download in den Ordner des
/// Plugins; die Grenze hält die Antwort an das Plugin und den Speicher der App
/// klein. Eine Seite von Moodle ist weit darunter.
const textHoechstens = 2 * 1024 * 1024;

/// So lang darf der Pfad sein, den ein Plugin nennt.
const pfadHoechstens = 2048;

/// Dateien, die Personen gehören, und Sicherungen (Schritt 3 oben).
final RegExp _nutzerdateien = RegExp(r'^/pluginfile\.php/\d+/user/');

/// Ein Plugin als Aufrufer des Moodle-Zugangs: seine Listen und seine
/// Protokollzeilen, mit seinem Namen davor.
class PluginAufrufer extends Aufrufer {
  PluginAufrufer(this._zugang, this.name);

  final MoodleZugang _zugang;

  /// Wie das Plugin in Protokoll und Freigabe heißt (`Plugin „Name“`).
  final String name;

  static const _bereich = 'Bereich ';
  static const _normalform = 'Normalform';
  static const _nutzer = 'Dateien unter user/';

  @override
  String? gesperrtDurch(Uri uri) {
    final bereich = sperrbereichDerAdresse(uri.path);
    if (bereich != null) return '$_bereich${bereich.name}';
    final klar = prozentAufgeloest(uri.path);
    if (pfadNormalisieren(uri.path) != klar) return _normalform;
    if (_nutzerdateien.hasMatch(klar)) return _nutzer;
    return sperrregel(uri) ??
        sperrregel(Uri(path: klar, query: uri.hasQuery ? prozentAufgeloest(uri.query) : null));
  }

  @override
  bool erlaubt(String methode, Uri uri, Felder? formular, String? rumpf, Anhang? anhang) =>
      methode == 'GET' &&
      formular == null &&
      rumpf == null &&
      anhang == null &&
      !_mitSesskey(uri) &&
      _zugang.erlaubtZumLesen(uri);

  static bool _mitSesskey(Uri uri) =>
      uri.queryParametersAll.keys.any((k) => prozentAufgeloest(k).toLowerCase() == 'sesskey');

  bool _eigeneRegel(String regel) => regel.startsWith(_bereich) || regel == _normalform || regel == _nutzer;

  @override
  String sperrzeile(String methode, Uri uri, String regel) => _eigeneRegel(regel)
      ? '$name: Gesperrt für Plugins: $methode ${adresseOhneWerte(uri)} ($regel)'
      : '$name: Datenschutz-Sperre: $methode ${adresseOhneWerte(uri)} (Regel $regel)';

  @override
  String ablehnzeile(String methode, Uri uri, Felder? formular) =>
      '$name: Gesperrt: $methode ${adresseOhneWerte(uri)}';

  // Ohne Parameterwerte, anders als bei den eingebauten Werkzeugen: Die Werte
  // wählt das Plugin, und die Positivliste prüft nicht bei jeder Adresse jeden
  // Parameter (Dateien unter pluginfile.php).
  @override
  String anfragezeile(String methode, Uri uri, Anhang? anhang) => '$name: $methode ${adresseOhneWerte(uri)}';

  @override
  String sperrmeldung(Uri uri, String regel) {
    if (regel.startsWith(_bereich)) {
      return 'Gesperrt für jedes Plugin: ${uri.path} liegt im ${regel.substring(_bereich.length)}. '
          'Adminbereich, Anmeldung und Seiten zu Passwort und Zugangsdaten erreicht kein Plugin.';
    }
    if (regel == _normalform) {
      return 'Abgelehnt: Der Pfad enthält „//“, „\\“, „.“ oder „..“, auch prozentkodiert. '
          'Ein Plugin nennt Pfade in Normalform.';
    }
    if (regel == _nutzer) {
      return 'Gesperrt für Plugins: Dateien unter pluginfile.php/<Kontext>/user/ (Profilbilder, private Dateien, '
          'Sicherungen) liest kein Plugin. Eine Sicherung kann Nutzerdaten enthalten; nur der Ablauf der '
          'eingebauten Werkzeuge lädt sie, nachdem er das ausgeschlossen hat.';
    }
    return super.sperrmeldung(uri, regel);
  }

  @override
  String ablehnmeldung(String methode, Uri uri) {
    const schreiben =
        'Ein Plugin liest über die Adresse der App nur. Ändern in Moodle geht über die eingebauten Werkzeuge '
        '(/v1/werkzeug), mit Freigabe, Namensprüfung und Rücklesen.';
    if (methode != 'GET') return 'Abgelehnt: $methode. $schreiben';
    if (_mitSesskey(uri)) {
      return 'Abgelehnt: Die Anfrage trägt den Parameter sesskey; mit ihm löst eine Adresse in Moodle eine '
          'Aktion aus. $schreiben';
    }
    if (_zugang.erlaubt(methode, uri)) {
      return 'Abgelehnt: GET ${uri.path} gehört nicht zum lesenden Teil der Positivliste von moocp. Die '
          'eingebauten Werkzeuge rufen diese Adresse nur als Schritt eines Schreibvorgangs ab, oder weil die '
          'Seite etwas ändert oder mehr zeigt, als ein Plugin roh lesen soll. $schreiben';
    }
    return 'Abgelehnt: GET ${uri.path} steht nicht auf der Positivliste von moocp, oder die Parameter passen '
        'nicht zu dem, was dort erlaubt ist. Für Plugins gilt der lesende Teil der Positivliste der '
        'eingebauten Werkzeuge, ohne Erweiterung.';
  }
}

/// Die Adresse an der Instanz [basis] zu dem Pfad, den ein Plugin nennt: ein
/// Pfad mit Parametern, relativ zur Instanz, ohne Schema, Rechnernamen und
/// Anker. Wirft [FormatException] mit dem Grund; der Grund nennt nie den Pfad.
Uri pluginAdresse(Uri basis, Object? pfad) {
  if (pfad is! String || pfad.isEmpty) {
    throw const FormatException('pfad fehlt: der Pfad an der Instanz mit Parametern, etwa „/mod/page/view.php?id=5“.');
  }
  if (pfad.length > pfadHoechstens) throw const FormatException('pfad ist länger als $pfadHoechstens Zeichen.');
  if (pfad.codeUnits.any((c) => c <= 0x20 || c == 0x7f)) {
    throw const FormatException('pfad enthält Leer- oder Steuerzeichen; sie gehören prozentkodiert hinein.');
  }
  if (!pfad.startsWith('/') || pfad.startsWith('//')) {
    throw const FormatException(
      'pfad beginnt mit genau einem „/“: ein Pfad an der Instanz des Profils, ohne Schema und Rechnernamen.',
    );
  }
  if (pfad.contains('#')) throw const FormatException('pfad trägt keinen Anker („#“).');
  final nurPfad = pfad.split('?').first;
  final klar = prozentAufgeloest(nurPfad);
  if (pfadNormalisieren(nurPfad) != klar || klar.contains(r'\')) {
    throw const FormatException(
      'pfad enthält „//“, „\\“, „.“ oder „..“, auch prozentkodiert; ein Plugin nennt Pfade in Normalform.',
    );
  }
  final Uri u;
  try {
    u = Uri.parse(pfad);
  } on FormatException {
    throw const FormatException('pfad ist keine gültige Adresse.');
  }
  if (u.hasScheme || u.hasAuthority) {
    throw const FormatException('pfad nennt kein Schema und keinen Rechner; die Instanz ist die des Profils.');
  }
  return basis.replace(path: u.path, query: u.hasQuery ? u.query : null);
}
