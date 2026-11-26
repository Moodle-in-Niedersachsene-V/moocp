// Der Ordner für Downloads der Plugins (E36): Was ein Plugin in einem Lauf
// über eine Zusatzadresse herunterlädt, legt die App hier ab, nie im
// Arbeitsordner. Dort liest die KI ohnehin (E5), und hinter einer
// Zusatzadresse ist mit Namen zu rechnen.
//
// Ein Ordner im Temp-Verzeichnis, getrennt vom Arbeitsordner, mit einem
// Unterordner je Plugin und darin je Instanzprofil: So teilen zwei Profile nie
// Dateien. Er lebt so kurz wie möglich: Die App leert ihn beim Start (das
// fängt auch einen Absturz ab, nach dem das Leeren beim Beenden ausblieb) und
// beim Beenden (laufende_plugins.dart), und am Ende eines Laufs löscht sie,
// was der Lauf geladen hat (lauf.dart).
//
// Den Namen einer Datei vergibt die App: eine laufende Nummer und eine Endung
// aus einer festen Liste ([endungen]), sonst `bin`. Der Dateiname aus Moodle
// (Pfad, Content-Disposition) kommt nicht in den Pfad: Er trägt oft den
// Namen einer Person.
//
// Der Pfad des Ordners geht nie an die KI: Wer ihn kennt, kann die Dateien
// mit eigenen Mitteln lesen. Das Plugin bekommt den Pfad einer Datei, weil es
// mit ihr arbeitet. Die App schreibt den Pfad in kein Protokoll, und die
// Datenschutzprüfung (namenssperre.dart, LetzteSperre.pfadSperren) hält jede
// Antwort und jede Protokollzeile eines Plugins an, die ihn nennt.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../plattform/privater_ordner.dart';

/// Die Endungen, die eine heruntergeladene Datei tragen kann; alles andere
/// heißt `bin`. Eine feste Liste, damit kein Teil eines Dateinamens aus
/// Moodle in den Pfad kommt.
const endungen = {
  'pdf', 'csv', 'txt', 'json', 'xml', 'html', 'htm', 'md', 'rtf', //
  'odt', 'ods', 'odp', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx',
  'zip', 'gz', 'tgz', 'mbz', '7z',
  'png', 'jpg', 'jpeg', 'gif', 'svg', 'webp', 'bmp',
  'mp3', 'mp4', 'm4a', 'ogg', 'wav', 'webm',
  'py', 'java', 'c', 'cpp', 'js', 'ipynb',
};

/// Der Ordner für Downloads der Plugins.
class PluginDownloads {
  PluginDownloads._(this.wurzel, this.pfadformen, this._pruefen);

  /// Der Name des Ordners: im Temp-Verzeichnis, unter Linux im privaten
  /// Grundordner der App (plattform/privater_ordner.dart), neben dem
  /// Arbeitsordner und nie darin.
  static const ordnername = 'moocp_plugin_downloads';

  /// Legt den Ordner unter [basis] an (ohne Angabe im Temp-Verzeichnis) und
  /// leert ihn. Liefert ihn mit der Zahl der Einträge, die sich nicht löschen
  /// ließen. Der Pfad in langer Form wie beim Arbeitsordner (arbeitsordner.dart).
  ///
  /// Unter Linux liegt er im privaten Grundordner des Benutzers, mit Rechten
  /// 700 angelegt und vor jeder Benutzung und jedem Leeren geprüft; besteht er
  /// die Prüfung nicht, wirft das [PrivaterOrdnerFehler], bevor etwas
  /// geschrieben oder gelöscht wird. Die Meldung nennt seinen Pfad nicht (E36).
  static (PluginDownloads, int) einrichten({
    String? basis,
    bool? linux,
    Map<String, String>? umgebung,
    PrivatSystem? system,
  }) {
    if (linux ?? Platform.isLinux) {
      final s = system ?? UnixPrivatSystem();
      final grund = privatesBasisverzeichnis(umgebung: umgebung, temp: basis, system: s);
      const name = 'Der Ordner für Downloads von Plugins';
      final roh = privaterOrdnerAnlegen(p.join(grund, ordnername), system: s, bezeichnung: name, pfadNennen: false);
      final lang = Directory(roh).resolveSymbolicLinksSync();
      final pd = PluginDownloads._(
        lang,
        {lang, roh},
        () => privaterOrdnerPruefen(roh, system: s, bezeichnung: name, pfadNennen: false),
      );
      return (pd, pd.leeren());
    }
    final roh = p.normalize(p.absolute(basis ?? Directory.systemTemp.path, ordnername));
    final d = Directory(roh)..createSync(recursive: true);
    final lang = d.resolveSymbolicLinksSync();
    final pd = PluginDownloads._(lang, {lang, roh}, null);
    return (pd, pd.leeren());
  }

  final void Function()? _pruefen;

  final String wurzel;

  /// Die Schreibweisen des Pfads, die die App kennt: die lange Form und die,
  /// unter der das Temp-Verzeichnis gemeldet wurde (unter Windows oft mit
  /// Kurznamen, auf dem Mac ohne `/private`). Beide sperrt die Datenschutzprüfung.
  final Set<String> pfadformen;

  /// Löscht alles im Ordner, Eintrag für Eintrag, wie Arbeitsordner.leeren:
  /// Was gerade in Benutzung ist, bleibt stehen, der Rest geht trotzdem.
  /// Liefert die Zahl der Einträge, die stehen blieben.
  int leeren() {
    _pruefen?.call();
    final d = Directory(wurzel);
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

  /// Der Ordner des Plugins [kurzname] im Instanzprofil mit der Kennung
  /// [profil]. Der Kurzname ist schon ein Ordnername (beschreibung.dart);
  /// eine Kennung, die keiner ist, ersetzt eine feste Ableitung aus ihr.
  String ordner(String kurzname, String profil) => p.join(wurzel, kurzname, _profilteil(profil));

  static String _profilteil(String kennung) => RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(kennung)
      ? kennung
      : 'p-${sha256.convert(utf8.encode(kennung)).toString().substring(0, 16)}';

  var _nummer = 0;

  /// Eine neue Datei im Ordner des Plugins [kurzname] und des Profils
  /// [profil] für den Download von [uri]: laufende Nummer und [endungFuer].
  /// Legt den Ordner an, nicht die Datei. Wirft [FileSystemException] und,
  /// wenn der Ordner nicht mehr privat ist, [PrivaterOrdnerFehler].
  File neueDatei(String kurzname, String profil, Uri uri) {
    _pruefen?.call();
    final o = Directory(ordner(kurzname, profil))..createSync(recursive: true);
    final endung = endungFuer(uri);
    while (true) {
      final f = File(p.join(o.path, '${++_nummer}.$endung'));
      if (!f.existsSync() && !File('${f.path}.teil').existsSync()) return f;
    }
  }

  /// Die Endung für den Download von [uri]: die des letzten Teils des Pfads,
  /// wenn sie in [endungen] steht, klein geschrieben; sonst `bin`.
  static String endungFuer(Uri uri) {
    final letzter = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
    final i = letzter.lastIndexOf('.');
    final e = i < 0 ? '' : letzter.substring(i + 1).toLowerCase();
    return endungen.contains(e) ? e : 'bin';
  }
}
