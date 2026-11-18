// Die Update-Prüfung: einmal täglich bei GitHub nachsehen, ob es eine neue
// Version gibt, sie auf Wunsch holen und den Installer starten.
//
// Drei Dinge sind hier wichtig:
//
//  1. Gefragt wird nur, wer Ja gesagt hat. Ohne „updatePruefen == true"
//     (einstellungen.dart) geht keine Anfrage raus; die Frage stellt die App
//     beim ersten Start (update_dialoge.dart).
//  2. Eigene Verbindung, nie die von MoodleZugang: Kein Sitzungscookie, kein
//     Moodle-Kopf und keine Moodle-Adresse gelangt zu GitHub. Erlaubt sind
//     nur die Adressen aus updateliste.dart, jedes Umleitungsziel einzeln
//     geprüft; jede Anfrage steht mit Status im Protokoll (A4 sinngemäß).
//  3. Geprüft wird nur in einer installierten App. Unter Windows nur, wer
//     sich selbst ersetzen kann (updateMoeglich): Der Installer legt die App
//     nach %LOCALAPPDATA%\Programs\moocp. Läuft die exe woanders --
//     Entwicklerversion aus build\, eine Kopie --, würde ein Update sie gar
//     nicht ersetzen, sondern eine zweite daneben installieren. Auf dem Mac
//     und unter Linux ersetzt sich die App nie selbst (E24): Dort sagt sie
//     nur Bescheid und öffnet auf Wunsch die Datei im Browser (updatePaket,
//     UpdatePaket); geprüft wird, wenn sie so läuft, wie eines der Pakete sie
//     hinlegt.
//
// Der Installer läuft sichtbar, mit dem Schalter /UPDATE: Er wartet dann
// still, bis die App zu ist (sie beendet sich gleich nach dem Start des
// Installers), lässt die Lizenzseite aus und startet die App am Ende wieder
// (installer/moocp.nsi).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../einstellungen.dart';
import '../installer/installer_logik.dart' show markeDatei;
import '../log.dart';
import '../plattform/kindprozess.dart';
import '../protokoll.dart';
import 'updateliste.dart';

/// Schalter auf der Kommandozeile: schaltet die Prüfung ab, auch wenn sie
/// eingeschaltet ist. tool/neustart.sh gibt ihn mit, und über die
/// Verknüpfung lässt sich die Prüfung so für einen Rechner abstellen.
const String keinUpdateSchalter = '--kein-update';

/// Zeitgrenze für die Abfrage bei GitHub. Lange genug für eine träge
/// Leitung, kurz genug, dass niemand auf den Start der App wartet.
const Duration abfragegrenze = Duration(seconds: 10);

class UpdateFehler implements Exception {
  UpdateFehler(this.meldung);
  final String meldung;
  @override
  String toString() => meldung;
}

/// Keine der Herkünfte der Prüfung (für moocp: updateliste.dart) taugt noch:
/// GitHub war erreichbar und hat für jede gesagt, dass es dort kein Release
/// mehr gibt. Vorübergehende Störungen sind das nie, sie bleiben ein
/// gewöhnlicher [UpdateFehler]; sonst bekäme jeder hinter einem Schulproxy
/// täglich eine falsche Warnung.
class UpdateAdressenWeg extends UpdateFehler {
  UpdateAdressenWeg() : super('Die hinterlegten Update-Adressen bei GitHub gibt es nicht mehr.');
}

/// Diese eine Herkunft taugt nicht mehr; die Prüfung versucht die nächste.
class _AdresseWeg implements Exception {}

/// Abgebrochen durch die Lehrkraft; kein Fehler, keine Meldung nötig.
class UpdateAbgebrochen implements Exception {}

/// Eine Version, die neuer ist als die laufende.
class NeueVersion {
  NeueVersion({
    required this.version,
    required this.datei,
    required this.dateiname,
    this.groesse,
    this.pruefsumme,
    this.beschreibung = '',
  });

  /// „0.9.5", ohne führendes „v".
  final String version;

  /// Adresse des Installers im Release.
  final Uri datei;
  final String dateiname;

  /// Größe in Byte, wie GitHub sie meldet; null, wenn das Feld fehlt.
  final int? groesse;

  /// Prüfsumme der Datei in der Form „sha256:…", wie GitHub sie meldet;
  /// null, wenn das Feld fehlt (ältere Releases).
  final String? pruefsumme;

  /// Der Text des Releases, also die Änderungen dieser Version. Reiner
  /// Anzeigetext für die Lehrkraft -- er kommt von außen und löst nichts
  /// aus.
  final String beschreibung;
}

/// Ob diese App sich selbst aktualisieren kann; siehe Kopf dieser Datei.
bool updateMoeglich(List<String> argumente, Map<String, String> umgebung) {
  // Der Installer (NSIS) gibt es nur unter Windows; ein Mac-Bau kennt keinen
  // Ort, an dem er sich selbst ersetzen könnte.
  if (!Platform.isWindows) return false;
  if (argumente.contains(keinUpdateSchalter)) return false;
  final lokal = umgebung['LOCALAPPDATA'];
  if (lokal == null || lokal.isEmpty) return false;
  try {
    final ziel = p.canonicalize(p.join(lokal, 'Programs', 'moocp'));
    return p.canonicalize(p.dirname(Platform.resolvedExecutable)) == ziel;
  } catch (_) {
    return false;
  }
}

/// Das Paket im Release, aus dem diese App auf dem Mac oder unter Linux
/// stammt (E24). Mit ihm wird sie auch aktualisiert: Die App lädt es nicht
/// selbst, sondern öffnet seine Adresse im Browser, und die Lehrkraft spielt
/// es ein wie bei der Installation.
enum UpdatePaket {
  /// Disk-Image für den Mac (tool/mac_dmg.sh).
  dmg,

  /// Installer je Benutzer für Linux (tool/linux_installer.sh).
  run,

  /// AppImage für Linux (tool/linux_appimage.sh).
  appImage,

  /// Debian-Paket, systemweit (tool/linux_deb.sh).
  deb;

  /// Der Name der Datei im Release, wie die Skripte sie bauen.
  String dateiname(String version) => switch (this) {
        UpdatePaket.dmg => 'moocp_${version}_macos.dmg',
        UpdatePaket.run => 'moocp_setup_$version.run',
        UpdatePaket.appImage => 'moocp_$version-x86_64.AppImage',
        UpdatePaket.deb => 'moocp_${version}_amd64.deb',
      };
}

/// Aus welchem Paket diese App stammt, wenn sie auf dem Mac oder unter Linux
/// installiert läuft; null sonst -- dann sucht sie nicht nach Updates. Ein
/// Entwicklungsbau sucht so nie, und eine App, die macOS aus dem Disk-Image
/// oder dem Download-Ordner heraus an einen Zufallsort verlegt hat
/// (App Translocation), auch nicht.
///
/// [system] und [programm] sind für Tests: ohne Angabe das laufende System und
/// die laufende Programmdatei. [gibtEs] prüft, ob eine Datei existiert.
UpdatePaket? updatePaket(
  List<String> argumente,
  Map<String, String> umgebung, {
  String? system,
  String? programm,
  bool Function(String pfad)? gibtEs,
}) {
  if (argumente.contains(keinUpdateSchalter)) return null;
  final datei = p.posix.normalize(programm ?? Platform.resolvedExecutable);
  final vorhanden = gibtEs ?? (String pfad) => File(pfad).existsSync();
  switch (system ?? Platform.operatingSystem) {
    case 'macos':
      // …/moocp.app/Contents/MacOS/moocp; installiert ist sie, wenn das
      // Bundle in einem der beiden Programme-Ordner liegt, wohin man es aus
      // dem Disk-Image zieht.
      final bundle = p.posix.dirname(p.posix.dirname(p.posix.dirname(datei)));
      if (!bundle.endsWith('.app')) return null;
      final ordner = p.posix.dirname(bundle);
      final heim = umgebung['HOME'];
      final programme = [
        '/Applications',
        if (heim != null && heim.isNotEmpty) p.posix.join(heim, 'Applications'),
      ];
      return programme.contains(ordner) ? UpdatePaket.dmg : null;
    case 'linux':
      // Das AppImage setzt APPIMAGE auf seinen eigenen Pfad, das .deb legt
      // die App nach /opt/moocp, der Installer je Benutzer hinterlässt seine
      // Marke im gewählten Zielordner (installer_logik.dart).
      final appImage = umgebung['APPIMAGE'];
      if (appImage != null && appImage.isNotEmpty) return UpdatePaket.appImage;
      final ordner = p.posix.dirname(datei);
      if (ordner == '/opt/moocp') return UpdatePaket.deb;
      if (vorhanden(p.posix.join(ordner, markeDatei))) return UpdatePaket.run;
      return null;
    default:
      return null;
  }
}

/// Der Tag eines Releases als Version: „v0.9.4" ergibt „0.9.4" (Schema der
/// Tags, E12); „github-v…" ist geduldet, weil die ersten Versionen so
/// veröffentlicht wurden. Alles andere ergibt null --
/// dann meldet die Prüfung, dass sie den Tag nicht lesen kann, statt zu
/// raten.
String? versionAusTag(String tag) =>
    RegExp(r'^(?:github-)?v?(\d+(?:\.\d+)*)$').firstMatch(tag.trim())?.group(1);

/// Vergleicht zwei Versionen Zahl für Zahl: -1, 0 oder 1. Die Buildnummer
/// hinter „+" zählt nicht mit, fehlende Stellen gelten als 0 („1.0" ist
/// „1.0.0").
int versionVergleich(String a, String b) {
  final x = _zahlen(a);
  final y = _zahlen(b);
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final links = i < x.length ? x[i] : 0;
    final rechts = i < y.length ? y[i] : 0;
    if (links != rechts) return links < rechts ? -1 : 1;
  }
  return 0;
}

List<int> _zahlen(String version) => version
    .split('+')
    .first
    .split('.')
    .map((t) => int.tryParse(RegExp(r'^\d+').firstMatch(t.trim())?.group(0) ?? '') ?? 0)
    .toList();

/// Der Anfang des Dateinamens, unter dem der Installer von moocp im Release
/// liegt (installer/moocp.nsi, OutFile).
const String moocpInstallerAnfang = 'moocp_setup';

/// Der Name, unter dem der Installer im Release liegt: `<anfang>_<Version>.exe`.
String installerName(String version, {String anfang = moocpInstallerAnfang}) =>
    '${anfang}_$version.exe';

/// Der Anfang der geladenen Datei von moocp im Temp-Verzeichnis
/// ([installerDatei]).
const String moocpDateiPraefix = 'moocp_update';

/// Der Anfang der geladenen Datei eines Plugins im Temp-Verzeichnis, vor dem
/// Kurznamen. Er beginnt nicht mit [moocpDateiPraefix]: Ein Plugin mit dem
/// Kurznamen „update“ bekäme sonst dieselben Dateinamen wie moocp.
const String pluginDateiPraefix = 'moocp_plugin';

/// Die heruntergeladene Datei liegt im Temp-Verzeichnis, nicht im
/// Arbeitsordner: Den leert die App beim Beenden -- also genau dann, wenn
/// der Installer gerade daraus läuft. [praefix] trennt moocp
/// ([moocpDateiPraefix]) von den Plugins.
File installerDatei(String version, {String praefix = moocpDateiPraefix}) =>
    File(p.join(Directory.systemTemp.path, '${praefix}_$version.exe'));

/// Sucht im Release die Datei, die zur Version gehört. [anfang] ist der Anfang
/// des Dateinamens (siehe [installerName]).
Map<String, dynamic>? releaseDatei(List<dynamic> anhaenge, String version,
    {String anfang = moocpInstallerAnfang}) {
  final passend = anhaenge.whereType<Map<String, dynamic>>().where((a) {
    final n = a['name'];
    return n is String && n.startsWith(anfang) && n.endsWith('.exe');
  }).toList();
  for (final a in passend) {
    if (a['name'] == installerName(version, anfang: anfang)) return a;
  }
  return passend.isEmpty ? null : passend.first;
}

/// Eine Prüfung samt Download. Eine je Vorgang; [abbrechen] bricht ab, was
/// gerade läuft.
///
/// Mit [paket] (Mac, Linux) sucht die Prüfung statt des Installers dieses
/// Paket im Release; fehlt es, gibt es für dieses System keine neue Version.
/// Heruntergeladen wird dann nicht: Die Adresse des Pakets öffnet die
/// Lehrkraft im Browser (update_dialoge.dart).
///
/// [quellen] sind die Herkünfte (Repositorys bei GitHub), aus denen die
/// Versionen kommen, in der Reihenfolge der Abfrage; ohne Angabe die von
/// moocp selbst (updateliste.dart). [installerAnfang] ist der Anfang des
/// Dateinamens des Installers im Release ([installerName]), [dateiPraefix]
/// der Anfang der geladenen Datei im Temp-Verzeichnis ([installerDatei]) und
/// [protokollName] das, womit jede Zeile im Protokoll beginnt. Für moocp
/// gelten überall die Vorgaben; ein Plugin setzt alle vier
/// (plugin/plugin_update.dart, pluginUpdate).
class Update {
  Update(
    this.protokoll, {
    this.grenze = abfragegrenze,
    this.quellen = herkuenfte,
    this.installerAnfang = moocpInstallerAnfang,
    this.dateiPraefix = moocpDateiPraefix,
    this.protokollName = 'Update',
    this.paket,
  });

  final Protokoll protokoll;
  final Duration grenze;
  final List<String> quellen;
  final String installerAnfang;
  final String dateiPraefix;
  final String protokollName;
  final UpdatePaket? paket;

  HttpClient? _klient;
  bool _abgebrochen = false;

  void abbrechen() {
    _abgebrochen = true;
    _klient?.close(force: true);
  }

  /// Nur Rechner und Pfad ins Protokoll: Die Adresse der Datei trägt hinter
  /// dem „?" eine Unterschrift, die dort nichts zu suchen hat.
  String _kurz(Uri uri) => '${uri.host}${uri.path}';

  HttpClient _neuerKlient() {
    // Ohne User-Agent weist die GitHub-API die Anfrage ab.
    final k = HttpClient()
      ..connectionTimeout = grenze
      ..userAgent = 'moocp';
    _klient = k;
    return k;
  }

  /// Fragt bei GitHub nach dem neuesten Release, Herkunft für Herkunft.
  /// Rückgabe: die neue Version, oder null, wenn die laufende schon die
  /// neueste ist. Wirft [UpdateAdressenWeg], wenn keine Herkunft mehr taugt.
  Future<NeueVersion?> pruefen(String eigene) async {
    // Vor der ersten Anfrage: Eine leere Liste würde sonst als „keine Herkunft
    // mehr“ gemeldet, also als Warnung, obwohl nichts gefragt wurde, und ein
    // Name, der keine Herkunft ist, ließe sich nicht zu einer Adresse machen.
    if (quellen.isEmpty || !quellen.every(herkunftGueltig)) {
      throw UpdateFehler('Die hinterlegten Update-Adressen sind nicht brauchbar.');
    }
    final klient = _neuerKlient();
    try {
      HttpClientResponse? antwort;
      for (final herkunft in quellen) {
        try {
          antwort = await _holen(releaseAbfrage(herkunft), klient, download: false);
          break;
        } on _AdresseWeg {
          protokoll.eintrag(Art.info, '$protokollName: kein Release unter $herkunft');
        }
      }
      if (antwort == null) throw UpdateAdressenWeg();
      final text = await antwort.transform(utf8.decoder).join().timeout(grenze);
      final j = jsonDecode(text);
      if (j is! Map<String, dynamic>) throw UpdateFehler('GitHub hat unerwartet geantwortet.');
      final tag = j['tag_name'];
      if (tag is! String) throw UpdateFehler('Das Release auf GitHub hat keinen Tag.');
      final version = versionAusTag(tag);
      if (version == null) {
        throw UpdateFehler('Der Tag „$tag" des Releases passt nicht zum Schema „v0.9.4".');
      }
      if (versionVergleich(version, eigene) <= 0) {
        protokoll.eintrag(Art.info, '$protokollName: neueste Version ist $version, läuft bereits ($eigene)');
        return null;
      }
      final anhaenge = (j['assets'] as List?) ?? const [];
      final gesucht = paket;
      if (gesucht != null) {
        final name = gesucht.dateiname(version);
        final treffer = anhaenge.whereType<Map<String, dynamic>>().where((a) => a['name'] == name);
        if (treffer.isEmpty) {
          protokoll.eintrag(Art.info, '$protokollName: Version $version hat kein Paket $name für dieses System');
          return null;
        }
        final adresse = Uri.parse(treffer.first['browser_download_url'] as String);
        final grund = updateGesperrt(adresse, download: true, quellen: quellen);
        if (grund != null) {
          protokoll.eintrag(Art.gesperrt, '$protokollName gesperrt: ${_kurz(adresse)} ($grund)');
          throw UpdateFehler('Die Adresse des Pakets ist nicht erlaubt ($grund).');
        }
        protokoll.eintrag(Art.info, '$protokollName: Version $version verfügbar (läuft: $eigene)');
        return NeueVersion(
          version: version,
          datei: adresse,
          dateiname: name,
          beschreibung: (j['body'] as String?)?.trim() ?? '',
        );
      }
      final anhang = releaseDatei(anhaenge, version, anfang: installerAnfang);
      if (anhang == null) {
        throw UpdateFehler(
            'Im Release $version liegt kein Installer (${installerName(version, anfang: installerAnfang)}).');
      }
      final adresse = Uri.parse(anhang['browser_download_url'] as String);
      final grund = updateGesperrt(adresse, download: true, quellen: quellen);
      if (grund != null) {
        protokoll.eintrag(Art.gesperrt, '$protokollName gesperrt: ${_kurz(adresse)} ($grund)');
        throw UpdateFehler('Die Adresse des Installers ist nicht erlaubt ($grund).');
      }
      final pruefsumme = anhang['digest'];
      protokoll.eintrag(Art.info, '$protokollName: Version $version verfügbar (läuft: $eigene)');
      return NeueVersion(
        version: version,
        datei: adresse,
        dateiname: anhang['name'] as String,
        groesse: anhang['size'] as int?,
        pruefsumme: pruefsumme is String ? pruefsumme : null,
        beschreibung: (j['body'] as String?)?.trim() ?? '',
      );
    } on UpdateFehler {
      rethrow;
    } on UpdateAbgebrochen {
      rethrow;
    } catch (e, st) {
      throw _fehler('Abfrage', e, st);
    } finally {
      klient.close();
      _klient = null;
    }
  }

  /// Holt den Installer ins Temp-Verzeichnis und gibt die Datei zurück.
  /// [fortschritt] bekommt geladene und (soweit bekannt) gesamte Byte.
  Future<File> herunterladen(NeueVersion neu, void Function(int, int?) fortschritt) async {
    final klient = _neuerKlient();
    final ziel = installerDatei(neu.version, praefix: dateiPraefix);
    try {
      final antwort = await _holen(neu.datei, klient, download: true);
      final gesamt = antwort.contentLength >= 0 ? antwort.contentLength : neu.groesse;
      final senke = ziel.openWrite();
      var geladen = 0;
      try {
        await for (final stueck in antwort) {
          senke.add(stueck);
          geladen += stueck.length;
          fortschritt(geladen, gesamt);
        }
      } finally {
        await senke.close();
      }
      _pruefeDatei(ziel, neu);
      protokoll.eintrag(Art.info, '$protokollName: ${neu.dateiname} geladen ($geladen Byte, geprüft)');
      return ziel;
    } on UpdateFehler {
      wegwerfen(ziel);
      rethrow;
    } on UpdateAbgebrochen {
      wegwerfen(ziel);
      rethrow;
    } catch (e, st) {
      wegwerfen(ziel);
      throw _fehler('Download', e, st);
    } finally {
      klient.close();
      _klient = null;
    }
  }

  /// Größe und Prüfsumme gegen das, was GitHub im Release angegeben hat.
  /// Unterschrieben ist der Installer nicht; mehr als dieser Abgleich geht
  /// nicht, und ohne ihn wäre eine abgebrochene Übertragung nicht von einer
  /// vollständigen zu unterscheiden.
  void _pruefeDatei(File datei, NeueVersion neu) {
    final bytes = datei.readAsBytesSync();
    if (neu.groesse != null && bytes.length != neu.groesse) {
      throw UpdateFehler('Die geladene Datei ist unvollständig '
          '(${bytes.length} statt ${neu.groesse} Byte).');
    }
    final soll = neu.pruefsumme;
    if (soll != null && soll.toLowerCase().startsWith('sha256:')) {
      final ist = sha256.convert(bytes).toString();
      if (ist != soll.substring('sha256:'.length).toLowerCase()) {
        throw UpdateFehler('Die Prüfsumme der geladenen Datei stimmt nicht.');
      }
    }
  }

  /// Eine Anfrage, Umleitungen von Hand -- jedes Ziel wird einzeln gegen
  /// updateliste.dart geprüft, so wie es die App bei Moodle tut.
  Future<HttpClientResponse> _holen(Uri start, HttpClient klient, {required bool download}) async {
    var uri = start;
    for (var i = 0; i < 5; i++) {
      final grund = updateGesperrt(uri, download: download, quellen: quellen);
      if (grund != null) {
        protokoll.eintrag(Art.gesperrt, '$protokollName gesperrt: GET ${_kurz(uri)} ($grund)');
        // Ein umgezogenes Repository leitet GitHub innerhalb der API auf eine
        // Adresse mit Nummer um (/repositories/…). Nur das heißt: Diese
        // Herkunft taugt nicht mehr. Ein anderes Ziel kann die Anmeldeseite
        // eines Schulproxys sein und sagt nichts über GitHub.
        if (!download && uri.scheme == 'https' && uri.host == 'api.github.com') {
          throw _AdresseWeg();
        }
        throw UpdateFehler('Die Adresse ist nicht erlaubt ($grund).');
      }
      final anfrage = await klient.getUrl(uri).timeout(grenze);
      anfrage.followRedirects = false;
      if (!download) anfrage.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final antwort = await anfrage.close().timeout(grenze);
      protokoll.eintrag(Art.info, '$protokollName: GET ${_kurz(uri)} → ${antwort.statusCode}');
      if (antwort.statusCode >= 300 && antwort.statusCode < 400) {
        final ort = antwort.headers.value(HttpHeaders.locationHeader);
        await antwort.drain<void>();
        if (ort == null) throw UpdateFehler('GitHub leitet um, ohne Ziel.');
        uri = uri.resolve(ort);
        continue;
      }
      if (antwort.statusCode != 200) {
        await antwort.drain<void>();
        // 404 auch bei einem Repository ohne Release: Für die Prüfung ist
        // das dasselbe, dort gibt es keine Version zu holen.
        if (!download && const {404, 410, 451}.contains(antwort.statusCode)) {
          throw _AdresseWeg();
        }
        // 403 und 429: zu viele Anfragen von dieser Adresse (an einer
        // Schule teilen sich alle eine). Kein Fehler der App.
        throw UpdateFehler(antwort.statusCode == 403 || antwort.statusCode == 429
            ? 'GitHub nimmt gerade keine Anfragen an (${antwort.statusCode}).'
            : 'GitHub antwortet mit ${antwort.statusCode}.');
      }
      return antwort;
    }
    throw UpdateFehler('Zu viele Umleitungen.');
  }

  /// Fehler nur mit Typ ins Protokoll (E11); die Meldung für die Lehrkraft
  /// sagt, was los ist, nicht was die Bibliothek geschrieben hat.
  Exception _fehler(String was, Object e, StackTrace st) {
    if (_abgebrochen) return UpdateAbgebrochen();
    protokoll.eintrag(Art.fehler, '$protokollName: $was fehlgeschlagen: ${fehlerBeschreibung(e, st)}');
    if (e is SocketException || e is HandshakeException) {
      return UpdateFehler('GitHub ist nicht erreichbar.');
    }
    if (e is TimeoutException) return UpdateFehler('GitHub antwortet nicht.');
    return UpdateFehler('$was fehlgeschlagen (${e.runtimeType}).');
  }
}

/// Eine halbe Datei ist schlimmer als keine: Was nicht durchkam, fliegt
/// sofort weg.
void wegwerfen(File datei) {
  try {
    if (datei.existsSync()) datei.deleteSync();
  } catch (_) {
    // Bleibt liegen; der nächste Start räumt auf (resteWegraeumen).
  }
}

/// Wie ein Installer gestartet wird; Tests setzen ein Double ein, damit nie ein
/// echter Installer läuft.
typedef InstallerStarter = Future<Process> Function(String pfad, List<String> argumente,
    {ProcessStartMode mode});

Future<Process> _prozessStarten(String pfad, List<String> argumente,
        {ProcessStartMode mode = ProcessStartMode.normal}) =>
    prozessStarten(pfad, argumente, modus: mode);

/// Startet einen geladenen Installer, sichtbar -- der gemeinsame Weg für
/// moocp ([updateInstallerStarten]) und für Plugins
/// (plugin/plugin_update.dart). Die Zeile im Protokoll beginnt mit
/// [protokollName] wie die der Prüfung ([Update.protokollName]).
Future<Process> installerStarten(
  File installer,
  String version, {
  required Protokoll protokoll,
  String protokollName = 'Update',
  List<String> argumente = const [],
  ProcessStartMode modus = ProcessStartMode.detached,
  InstallerStarter starter = _prozessStarten,
}) async {
  protokoll.eintrag(Art.info, '$protokollName: Installer für Version $version gestartet');
  return starter(installer.path, argumente, mode: modus);
}

/// Startet den geladenen Installer von moocp und merkt sich die Version.
/// Danach muss der Aufrufer die App regulär beenden -- erst dann gibt sie die
/// exe frei, und nur so leert sie ihren Arbeitsordner.
Future<void> updateInstallerStarten(
    File installer, String version, Einstellungen einstellungen, Protokoll protokoll,
    {InstallerStarter starter = _prozessStarten}) async {
  einstellungen.updateErwartet = version;
  await einstellungen.speichern();
  await installerStarten(installer, version,
      protokoll: protokoll, argumente: const ['/UPDATE'], modus: ProcessStartMode.detached, starter: starter);
}

/// Beim Start: War ein Update angekündigt, sagen, ob es angekommen ist.
/// Mehr geht nicht -- währenddessen war die App beendet, sie sieht nur das
/// Ergebnis.
Future<void> updateStandMelden(Einstellungen einstellungen, String eigene, Protokoll protokoll) async {
  final erwartet = einstellungen.updateErwartet;
  if (erwartet == null) return;
  einstellungen.updateErwartet = null;
  try {
    await einstellungen.speichern();
  } catch (_) {
    // Dann steht es beim nächsten Start noch einmal da; harmlos.
  }
  if (versionVergleich(eigene, erwartet) >= 0) {
    protokoll.eintrag(Art.info, 'Update: auf Version $eigene aktualisiert');
  } else {
    protokoll.eintrag(
        Art.fehler,
        'Update: Version $erwartet wurde nicht installiert (es läuft weiter $eigene). '
        'Der Installer liegt unter ${installerDatei(erwartet).path}');
  }
}

/// Reste früherer Updates von moocp und von Plugins aus dem Temp-Verzeichnis
/// räumen. Was noch in Benutzung ist -- der Installer, der die App gerade neu
/// gestartet hat -- bleibt liegen und ist beim nächsten Start weg.
void resteWegraeumen() {
  try {
    for (final e in Directory.systemTemp.listSync(followLinks: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      final eigene = name.startsWith('${moocpDateiPraefix}_') || name.startsWith('${pluginDateiPraefix}_');
      if (eigene && name.endsWith('.exe')) wegwerfen(e);
    }
  } catch (_) {
    // Temp nicht lesbar: dann eben nicht.
  }
}

/// Der Tag als „2026-10-03", wie er in den Einstellungen steht.
String tagesdatum(DateTime jetzt) => '${jetzt.year.toString().padLeft(4, '0')}-'
    '${jetzt.month.toString().padLeft(2, '0')}-${jetzt.day.toString().padLeft(2, '0')}';

/// Ob heute schon geprüft wurde. Gesetzt wird das Datum auch nach einem
/// Fehlversuch, sonst wartet jemand ohne Netz bei jedem Start erneut auf
/// die Zeitgrenze.
bool heuteSchonGeprueft(Einstellungen einstellungen, DateTime jetzt) =>
    einstellungen.updateZuletzt == tagesdatum(jetzt);
