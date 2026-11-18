// Der Zugang zu Moodle über HTTP, mit der Sitzung der Lehrkraft.
//
// Drei Dinge passieren hier und nirgends sonst:
//
//  1. Anmelden mit den Zugangsdaten, die die Lehrkraft in der App eingegeben
//     hat. Sie liegen nur im Arbeitsspeicher und nur, solange die App läuft;
//     sie werden nie gespeichert, nie protokolliert und nie an MCP gegeben.
//  2. Jede Anfrage prüfen, bevor sie rausgeht -- auch jedes Umleitungsziel:
//     zuerst gegen die Sperrliste (sperrliste.dart), dann gegen die
//     Positivliste. Geprüft werden Methode, Pfad, Parameter und bei
//     Schreibvorgängen die Formularwerte (etwa: ist es das Formular eines
//     Typs, den die App kennt?). Welche Kurse die Sitzung bearbeiten darf,
//     entscheidet Moodle selbst -- die App darf genau, was die Lehrkraft darf.
//     Was nicht auf der Liste steht, wird nicht angefragt. Das ist die Grenze,
//     die im Skill bisher nur beschrieben war; hier ist sie erzwungen.
//     Welche Listen gelten und wie die Zeile im Protokoll lautet, bestimmt der
//     Aufrufer der Anfrage ([Aufrufer]); den Download eingeschlossen, geht
//     jede Anfrage dafür durch dieselben zwei Stellen.
//  3. Eine abgelaufene Sitzung erkennen (Umleitung auf die Anmeldeseite),
//     genau einmal neu anmelden. Lesen wird wiederholt; Schreiben meldet
//     SitzungAbgelaufen, und das Werkzeug baut den ganzen Vorgang neu auf.
//     Schlägt die Neuanmeldung fehl, werden die Zugangsdaten verworfen --
//     keine Schleife, denn Moodle sperrt Konten nach mehreren Fehlversuchen.
//     Nur wenn Moodle schon vor dem Senden des Passworts nicht erreichbar
//     war, bleiben sie: Das ist kein Fehlversuch, und die nächste Anfrage
//     versucht es wieder (etwa nach dem Aufwachen aus dem Standby).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../protokoll.dart';
import '../testschalter.dart';
import 'browserliste.dart';
import 'sicherung_regeln.dart';
import 'wiederherstellung_regeln.dart';
import 'sperrliste.dart';

class MoodleFehler implements Exception {
  MoodleFehler(this.meldung);
  final String meldung;
  @override
  String toString() => meldung;
}

/// Eine Sicherung ist größer als die Grenze ([archivGrenzeStandard]); sie wird nicht
/// heruntergeladen, und was schon geladen war, verschwindet wieder.
class DownloadZuGross extends MoodleFehler {
  DownloadZuGross(int maxBytes)
      : super('Die Sicherung ist größer als die erlaubten ${maxBytes ~/ (1024 * 1024)} MB; nicht heruntergeladen. '
            'Eine kleinere Auswahl sichern.');
}

/// Eine Anfrage, die vor dem Senden abgewiesen wurde: fremder Rechner,
/// Sperrliste, Positivliste oder eine Regel des [Aufrufer]. Moodle hat sie nie
/// gesehen; ein neuer Versuch hilft nicht.
class AnfrageGesperrt extends MoodleFehler {
  AnfrageGesperrt(super.meldung);
}

/// Der Zugang ist nicht angemeldet: Die Lehrkraft muss sich in der App
/// anmelden. Nichts wurde gesendet.
class NichtAngemeldet extends MoodleFehler {
  NichtAngemeldet() : super('Nicht angemeldet. Bitte in der App anmelden.');
}

/// Eine Antwort ist größer als die Grenze, die der Aufrufer für Text gesetzt
/// hat ([MoodleZugang.lesenAls]); gelesen wird nur bis zur Grenze, dann bricht
/// die Anfrage ab.
class AntwortZuGross extends MoodleFehler {
  AntwortZuGross(int hoechstens)
    : super('Die Antwort von Moodle ist größer als ${hoechstens ~/ 1024} KB; als Text nicht geliefert.');
}

/// Moodle war nicht zu erreichen: keine Verbindung, Abbruch, TLS-Fehler oder
/// keine Antwort innerhalb der Zeitgrenze.
class MoodleNichtErreichbar extends MoodleFehler {
  MoodleNichtErreichbar(super.meldung);
}

/// Moodle hat die Zugangsdaten ausdrücklich abgelehnt: Das zählte bei Moodle
/// als Fehlversuch. Nur dann sind gespeicherte Zugangsdaten nachweislich
/// falsch und werden verworfen (E7); jede andere MoodleFehler-Art sagt nichts
/// über das Passwort -- auch eine abgebrochene Verbindung nach dem Senden, bei
/// der niemand weiß, ob es angekommen ist.
class MoodleAnmeldungAbgelehnt extends MoodleFehler {
  MoodleAnmeldungAbgelehnt(super.meldung);
}

/// Die Sitzung lief während eines Schreibvorgangs ab. Neu angemeldet ist
/// bereits; der Vorgang muss von vorn beginnen (frisches Formular).
class SitzungAbgelaufen extends MoodleFehler {
  SitzungAbgelaufen() : super('Sitzung während des Schreibens abgelaufen.');
}

/// Ein Schutzdienst vor der Instanz hat die Anfrage gleich abgewiesen, statt
/// Moodle antworten zu lassen. Die Sperre trifft den Inhalt (HTML-Code als Text
/// in einem Code-Beispiel), nicht die Anmeldung: Derselbe Inhalt wird auch im
/// Browser der Lehrkraft abgewiesen. Nichts gespeichert; die App sagt es klar
/// und übergibt es an die Lehrkraft.
///
/// [sperre]: Statt einer Prüfung hat der Schutzdienst die Anfrage abgewiesen.
/// Sich als Browser auszugeben, wäre eine Umgehung wie bei der Prüfung (E22).
class SchutzPruefung extends MoodleFehler {
  SchutzPruefung({this.sperre = false})
    : super(
        sperre
            ? 'Der Schutzdienst vor Moodle hat das Formular abgewiesen. Nichts gespeichert. Ein neuer Versuch '
                  'hilft nicht. Ausgelöst wird das vom Inhalt, meist von HTML- oder JavaScript-Code als Text in einem '
                  'Code-Beispiel, etwa einem Tag mit Attribut; oft weist er dasselbe auch aus dem Browser ab. Dann '
                  'hilft nur, das Beispiel anders zu schreiben, oder der Betreiber der Instanz lässt es zu.'
            : 'Der Schutzdienst vor Moodle hat das Formular angehalten: Er verlangt eine Prüfung, die nur '
                  'ein Mensch im Browser bestehen kann. Nichts gespeichert. Ein neuer Versuch hilft nicht. Meist '
                  'löst Code im Text das aus, etwa ein Ereignis-Attribut wie onclick= in einem Code-Beispiel.',
      );
  final bool sperre;
}

/// Was ein Schutzdienst vor der Instanz aus einer Antwort gemacht hat.
enum Schutz { pruefung, sperre }

/// Erkennt die Antwort eines Schutzdienstes. Cloudflare kennzeichnet seine
/// Prüfseite mit `cf-mitigated: challenge`; eine Sperre durch eine seiner
/// Regeln dagegen nicht, sie ist ein 403 mit `server: cloudflare` und einer
/// eigenen Seite. Dieselben Kopfzeilen trägt aber jede Antwort, die
/// Cloudflare von Moodle durchreicht, auch ein 403 von Moodle selbst (ein
/// Recht fehlt) -- deshalb gilt ein 403 nur dann als Sperre, wenn die Seite
/// keine von Moodle ist: Jede Moodle-Seite setzt `M.cfg`.
Schutz? schutzErkennen(
  int status, {
  String? server,
  String? mitigated,
  required String text,
}) {
  if (mitigated == 'challenge') return Schutz.pruefung;
  if (status == 403 &&
      server?.toLowerCase() == 'cloudflare' &&
      !text.contains('M.cfg')) {
    return Schutz.sperre;
  }
  return null;
}

typedef Felder = List<MapEntry<String, String>>;

/// Eine Antwort von Moodle.
class Antwort {
  Antwort(
    this.status,
    this.adresse,
    this.bytes,
    this.inhaltstyp, {
    this.ort,
    this.schutz,
  });
  final int status;
  final Uri adresse;
  final Uint8List bytes;
  final String? inhaltstyp;

  /// Location-Kopf einer Umleitung, sonst null.
  final String? ort;

  /// Ein Schutzdienst vor der Instanz hat statt Moodle geantwortet
  /// ([schutzErkennen]), sonst null.
  final Schutz? schutz;

  String get text => utf8.decode(bytes, allowMalformed: true);
}

/// Eine Datei für einen Upload.
class Anhang {
  Anhang(this.feld, this.dateiname, this.bytes, this.mime);
  final String feld;
  final String dateiname;
  final List<int> bytes;
  final String mime;
}

/// Eine Regel der Positivliste.
class Erlaubt {
  const Erlaubt(
    this.methode,
    this.pfad,
    this.zweck, {
    this.parameter,
    this.formular,
    this.inhalt,
    this.anhang,
    this.lesend = false,
    this.nurNamenssperre = false,
  });
  final String methode;
  final String pfad;
  final String zweck;

  /// Ob die Regel nur für den einen Aufrufer gilt, mit dem die App selbst die
  /// Namen der Teilnehmenden eines Kurses für die letzte Sperre liest (E36,
  /// [MoodleZugang.teilnehmendenseiteLesen]). Für die eingebauten Werkzeuge
  /// ([MoodleZugang.erlaubt]) und für Plugins ([MoodleZugang.erlaubtZumLesen])
  /// gibt es eine solche Regel nicht.
  final bool nurNamenssperre;

  /// Ob die Regel eine Seite oder Datei nur liest: ein GET, das Inhalt oder
  /// Einstellungen zeigt, ohne in Moodle etwas zu ändern, und nicht nur als
  /// Schritt eines Schreibvorgangs da ist (Formular für Neues, Rückfrage vor dem
  /// Löschen, Aktion mit sesskey). Nur solche Regeln gelten für Plugins
  /// ([MoodleZugang.erlaubtZumLesen]): Ein Plugin schreibt nur über die
  /// eingebauten Werkzeuge, mit Freigabe, Namensprüfung, Stand-Prüfung und
  /// Rücklesen (E36). Für die eingebauten Werkzeuge ändert die Angabe nichts.
  /// Im Zweifel bleibt sie false: Ein GET mit Nebenwirkung (eine Sperre, ein
  /// angelegter Datensatz) ist kein Lesen.
  final bool lesend;
  final bool Function(Map<String, String> q)? parameter;
  final bool Function(Felder f)? formular;

  /// Prüft die hochgeladene Datei. Eine Regel mit diesem Prüfer passt nur auf
  /// Anfragen mit Datei.
  final bool Function(Anhang a)? anhang;

  /// Prüft einen JSON-Rumpf (Moodle-AJAX-Dienste), mit den Parametern der Adresse.
  final bool Function(Map<String, String> q, String rumpf)? inhalt;
}

String? wertIn(Felder f, String name) {
  for (final e in f) {
    if (e.key == name) return e.value;
  }
  return null;
}

/// Ob eine Seite das Skript der Druckaufbereitung „Aufgabenblatt-Druck" trägt.
///
/// Das Skript steht unter „Zusätzliches HTML", vor dem Schließen des
/// BODY-Tags, und damit im Quelltext jeder Seite mit Standardlayout (nicht
/// im Layout `embedded`, dort gibt Moodle das Zusätzliche HTML nicht aus).
/// Erkannt an der id seines Druckcontainers: Die setzt nur das Skript, sie
/// steht in keiner Moodle-Seite ohne es. Wofür die Skills das brauchen:
/// skills/moodle/references/drucken.md.
bool druckaufbereitungErkannt(String html) => html.contains('ab-print-root');

/// Der Pfad des Theme-Stylesheets einer Seite
/// (`/theme/styles.php/<theme>/<revision>/all`), ohne Rechner. Die Revision ändert sich, wenn die
/// Administration die Caches leert; die App liest sie bei jeder Anmeldung neu.
String? themeStylesheetIn(dom.Document doc) {
  for (final l in doc.querySelectorAll('link[rel="stylesheet"]')) {
    final u = Uri.tryParse(l.attributes['href'] ?? '');
    if (u != null && u.path.startsWith('/theme/styles.php/')) {
      return u.hasQuery ? '${u.path}?${u.query}' : u.path;
    }
  }
  return null;
}

/// Die Namen der angemeldeten Person aus der Anmeldezeile einer Seite: der
/// Text jedes Links auf `/user/profile.php` im Element mit der Klasse
/// `logininfo` („Sie sind angemeldet als …“; bei „Anmelden als“ beide
/// Namen). Die Zeile setzt `core_renderer::login_info` in jede Seite mit
/// Standardlayout; im Theme Boost steht sie im Fuß. Der Text der Anmeldezeile
/// selbst hängt an der Sprache, der Link nicht; deshalb nur er. Ohne
/// Anmeldezeile leer. Gemessen ist der Aufbau nicht an einer Instanz: Findet
/// sich der Name nicht, bleibt die Liste leer, und für ein Plugin gilt dann nur,
/// dass es von einer Seite nur den Hauptbereich bekommt (E36).
List<String> lehrkraftNamenIn(String html) {
  if (!html.contains('logininfo')) return const [];
  final namen = <String>[];
  for (final m in RegExp(r'''<div\b[^>]*\bclass\s*=\s*["'][^"']*\blogininfo\b[^"']*["'][^>]*>''', caseSensitive: false)
      .allMatches(html)) {
    final ende = html.indexOf(RegExp('</div', caseSensitive: false), m.end);
    if (ende < 0) continue;
    for (final a in html_parser.parseFragment(html.substring(m.end, ende)).querySelectorAll('a[href]')) {
      final u = Uri.tryParse(a.attributes['href'] ?? '');
      if (u == null || !u.path.endsWith('/user/profile.php')) continue;
      final n = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (n.isNotEmpty && !namen.contains(n)) namen.add(n);
    }
  }
  return namen;
}

/// Wer eine Anfrage an Moodle stellt. Vom Aufrufer hängen ab, gegen welche
/// Listen die Adresse geprüft wird und in welcher Form das Protokoll die
/// Anfrage nennt; alles Übrige -- der Rechner der Instanz, die Sitzung, das
/// Senden -- ist für jeden Aufrufer dasselbe und bleibt in [MoodleZugang].
///
/// Jede Anfrage fragt ihren Aufrufer an denselben Stellen, auch ein Download:
/// die Prüfung vor dem Senden (`_pruefePositivliste`), die Zeile danach
/// (`_protokolliere`). Aufrufer sind die eingebauten Werkzeuge der App, für
/// die Sperrliste und Positivliste wie in E3 gelten, ein Plugin, das über die
/// Adresse der App liest oder schreibt (plugin/moodle_lesen.dart,
/// plugin/moodle_schreiben.dart), und die App selbst, wenn sie für die letzte
/// Sperre die Namen der Teilnehmenden eines Kurses liest
/// ([MoodleZugang.teilnehmendenseiteLesen]). Im Protokoll eines Plugins und
/// der letzten Sperre steht nie ein Wert (A4). Die Anmeldung stellt immer die
/// App selbst, nie ein Plugin.
abstract class Aufrufer {
  /// Die Regel der Sperrliste, die [uri] sperrt, sonst null. Sie wird vor
  /// [erlaubt] gefragt: Was sie sperrt, geht nie hinaus.
  String? gesperrtDurch(Uri uri);

  /// Ob die Positivliste diese Anfrage erlaubt.
  bool erlaubt(
    String methode,
    Uri uri,
    Felder? formular,
    String? rumpf,
    Anhang? anhang,
  );

  /// Die Protokollzeile einer Anfrage, die [gesperrtDurch] mit [regel] sperrt.
  String sperrzeile(String methode, Uri uri, String regel);

  /// Die Protokollzeile einer Anfrage, die [erlaubt] nicht durchlässt.
  String ablehnzeile(String methode, Uri uri, Felder? formular);

  /// Die Protokollzeile einer gestellten Anfrage ohne ihren Status.
  String anfragezeile(String methode, Uri uri, Anhang? anhang);

  /// Der Pfad in einer Fehlerzeile des Protokolls (nicht erreichbar,
  /// Zeitgrenze, Abbruch). Ein Aufrufer, in dessen Adressen hinter dem
  /// Skriptnamen Daten stehen können, kürzt ihn (plugin/moodle_schreiben.dart).
  String pfadImProtokoll(Uri uri) => uri.path;

  /// Die Meldung, wenn [gesperrtDurch] die Anfrage mit [regel] sperrt; ohne
  /// Parameterwerte.
  String sperrmeldung(Uri uri, String regel) =>
      'Gesperrt (Datenschutz): ${uri.path} zeigt personenbezogene Daten -- Bewertungen, '
      'Abgaben, Versuche, Profile oder Protokolle. Die App liest sie grundsätzlich nicht. '
      'Dem Nutzer sagen, dass dieser Teil der Aufgabe offen bleibt, oder -- falls die '
      'Adresse harmlos ist -- dass die Sperre zu weit ist (Regel $regel).';

  /// Die Meldung, wenn [erlaubt] die Anfrage nicht durchlässt; ohne
  /// Parameterwerte.
  String ablehnmeldung(String methode, Uri uri) =>
      'Gesperrt: $methode ${uri.path} steht nicht auf der Positivliste dieses Servers '
      '(oder die Werte passen nicht zu dem, was dort erlaubt ist).';
}

/// Die eingebauten Werkzeuge der App: Sperrliste (sperrliste.dart) und
/// Positivliste dieses Zugangs; im Protokoll stehen Methode, Pfad und Query
/// (ohne sesskey), bei gesperrten Anfragen nur die Namen der Parameter.
class _EingebauteWerkzeuge extends Aufrufer {
  _EingebauteWerkzeuge(this._zugang);

  final MoodleZugang _zugang;

  @override
  String? gesperrtDurch(Uri uri) => sperrregel(uri);

  @override
  bool erlaubt(
    String methode,
    Uri uri,
    Felder? formular,
    String? rumpf,
    Anhang? anhang,
  ) => _zugang.erlaubt(methode, uri, formular, rumpf, anhang);

  // Parameterwerte gehören nicht ins Protokoll: studentid=45 wäre genau das
  // Datum, um das es geht.
  @override
  String sperrzeile(String methode, Uri uri, String regel) =>
      'Datenschutz-Sperre: $methode ${adresseOhneWerte(uri)} (Regel $regel)';

  // Zur Fehlersuche die NAMEN der Parameter und Felder, nie ihre Werte.
  @override
  String ablehnzeile(String methode, Uri uri, Felder? formular) =>
      'Gesperrt: $methode ${adresseOhneWerte(uri)}'
      '${formular == null ? '' : ' (Felder: ${formular.map((e) => e.key).toSet().join(', ')})'}'
      '${formular == null || !const {'/backup/restore.php', '/group/assign.php'}.contains(uri.path) ? '' : ' (Wertformen: ${formular.map((e) => '${e.key}=${MoodleZugang._wertform(e.value)}').join(', ')})'}';

  @override
  String anfragezeile(String methode, Uri uri, Anhang? anhang) =>
      '$methode ${uri.path}${MoodleZugang.querySicher(uri)}'
      '${anhang != null ? " (${anhang.dateiname})" : ""}';
}

/// Die App selbst, wenn sie für die letzte Sperre die Namen der Teilnehmenden
/// eines Kurses liest (E36, [MoodleZugang.teilnehmendenseiteLesen]). Nur
/// dieser Aufrufer kommt an der Sperrliste vorbei zur Teilnehmendenseite, und
/// nur in der einen Form, die [sperrregelFuerNamenssperre] durchlässt; die
/// Positivliste hat dafür eine eigene Regel ([Erlaubt.nurNamenssperre]), die
/// für keinen anderen Aufrufer gilt. Privat, damit niemand sonst ihn benutzt.
/// Im Protokoll nur Methode, Pfad und die Namen der Parameter.
class _Namenssperre extends Aufrufer {
  _Namenssperre(this._zugang);

  final MoodleZugang _zugang;

  static const _wer = 'Letzte Sperre, Namen der Teilnehmenden';

  @override
  String? gesperrtDurch(Uri uri) => sperrregelFuerNamenssperre(uri);

  @override
  bool erlaubt(String methode, Uri uri, Felder? formular, String? rumpf, Anhang? anhang) =>
      methode == 'GET' &&
      formular == null &&
      rumpf == null &&
      anhang == null &&
      _zugang.erlaubtFuerNamenssperre(uri);

  @override
  String sperrzeile(String methode, Uri uri, String regel) =>
      '$_wer: Datenschutz-Sperre: $methode ${adresseOhneWerte(uri)} (Regel $regel)';

  @override
  String ablehnzeile(String methode, Uri uri, Felder? formular) =>
      '$_wer: Gesperrt: $methode ${adresseOhneWerte(uri)}';

  @override
  String anfragezeile(String methode, Uri uri, Anhang? anhang) => '$_wer: $methode ${adresseOhneWerte(uri)}';
}

class MoodleZugang {
  MoodleZugang(this.protokoll);

  /// Zeitgrenzen: Aufbau der Verbindung, und bis die Antwort vollständig da
  /// ist. Ohne sie kann eine hängende Anfrage ein Werkzeug beliebig lange
  /// blockieren.
  ///
  /// Moodle sperrt die Sitzung, solange eine Anfrage läuft; jede weitere
  /// Anfrage derselben Sitzung wartet dahinter (gemessen in den
  /// Browser-Skills: 50 ms wurden zu über 45 s, weil ein nicht abgewarteter
  /// Aufruf die Sperre hielt). Deshalb wird hier jede Anfrage abgewartet --
  /// nie eine abschicken und liegen lassen.
  static const Duration verbindungsgrenze = Duration(seconds: 20);
  static const Duration antwortgrenze = Duration(minutes: 2);

  final Protokoll protokoll;

  static bool _zahl(String? s) => istZahl(s);

  /// Nur die Form eines Werts für die Fehlersuche (nie der Wert): Zahl, Hex32, Text
  /// aus Buchstaben und Unterstrichen, sonst gemischt, jeweils mit Länge.
  static String _wertform(String v) {
    final art = v.isEmpty
        ? 'leer'
        : RegExp(r'^\d+$').hasMatch(v)
        ? 'Zahl'
        : RegExp(r'^[0-9a-f]{32}$').hasMatch(v)
        ? 'Hex32'
        : RegExp(r'^[A-Za-z_]+$').hasMatch(v)
        ? 'Text'
        : 'gemischt';
    return '$art(${v.length})';
  }
  static bool _gesetzt(String? s) => s != null && s.isNotEmpty;

  /// Das Formular trägt die Marke seiner Klasse (`_qf__<klasse>`). Die Klassen
  /// wandern zwischen Moodle-Versionen den Namensraum (question_export_form
  /// wurde qbank_exportquestions\form\export_form), deshalb ein Muster.
  static bool _marke(Felder f, RegExp muster) =>
      f.any((e) => muster.hasMatch(e.key));

  /// Dienste, die etwas ändern -- fürs Protokoll.
  static const Set<String> schreibendeDienste = {
    'core_courseformat_update_course',
    'mod_quiz_add_random_questions',
    'core_form_dynamic_form', //
    'mod_board_delete_column',
    'mod_board_move_column',
    'mod_board_lock_column',
    'mod_board_delete_note',
    'mod_kanban_add_column',
    'mod_kanban_delete_column',
    'mod_kanban_move_column',
    'mod_kanban_add_card',
    'mod_kanban_delete_card', 'mod_kanban_move_card',
  };

  /// Das versteckte Feld `id` eines Moodle-Formulars: leer oder 0 heißt, das
  /// Objekt wird neu angelegt; jede andere Nummer ändert ein bestehendes.
  static bool _neuesObjekt(String? id) => id != null && (id.isEmpty || id == '0');

  static bool _nurSchluessel(Map<String, String> q, Set<String> erlaubt) =>
      q.keys.every(erlaubt.contains);

  /// Fragennummern, durch Komma getrennt, wie delete.php sie nimmt.
  static bool _fragenListe(String? s) =>
      s != null && RegExp(r'^\d+(,\d+)*$').hasMatch(s);

  /// Die Rückfrage von delete.php: die Auswahl als `q<id>=1`, `deleteselected=1`.
  /// Dazu returnurl, genau die Fragenübersicht der Sammlung: Ohne sie bricht
  /// die Rückfrage in Moodle 5.1 mit einem PHP-Fehler ab (gemessen
  /// 30.09.2026, „out_as_local_url() on int"). Aufgerufen wird sie nie -- sie
  /// ist nur das Ziel der Umleitung nach dem Löschen, und der folgt die App
  /// nicht.
  static bool _loeschRueckfrage(Map<String, String> q) {
    final auswahl = RegExp(r'^q\d+$');
    return q.keys.every(
          (k) =>
              const {
                'cmid',
                'deleteselected',
                'deleteall',
                'returnurl',
              }.contains(k) ||
              auswahl.hasMatch(k),
        ) &&
        _zahl(q['cmid']) &&
        q['returnurl'] == '/question/edit.php?cmid=${q['cmid']}' &&
        q['deleteselected'] == '1' &&
        const {'0', '1'}.contains(q['deleteall'] ?? '1') &&
        q.keys.any(auswahl.hasMatch) &&
        q.entries
            .where((e) => auswahl.hasMatch(e.key))
            .every((e) => e.value == '1');
  }

  /// Die Bestätigung von delete.php: nur diese Felder, confirm ist der
  /// md5-Wert der Auswahl, den Moodle selbst in die Rückfrage schreibt.
  static bool _loeschBestaetigung(Map<String, String> w) =>
      w.keys.every(
        const {
          'cmid',
          'courseid',
          'deleteselected',
          'deleteall',
          'confirm',
          'sesskey',
          'returnurl',
        }.contains,
      ) &&
      _fragenListe(w['deleteselected']) &&
      RegExp(r'^[0-9a-f]{32}$').hasMatch(w['confirm'] ?? '') &&
      _gesetzt(w['sesskey']) &&
      (w['cmid'] == null || _zahl(w['cmid'])) &&
      (w['courseid'] == null || _zahl(w['courseid'])) &&
      const {'0', '1'}.contains(w['deleteall'] ?? '1');

  /// Aktivitätstypen, deren Formular die App kennt: anlegen und ändern.
  /// Ein Typ kommt erst hinein, wenn sein Formular im Testkurs gemessen ist.
  /// Die Übersicht „Unterstützte Aktivitäten und Fragetypen" in README.md
  /// (Teil 2) im selben Zug nachziehen.
  static const Set<String> schreibbareModule = {
    'page',
    'label',
    'assign',
    'folder',
    'subsection',
    'book',
    'quiz',
    'qbank', //
    'checklist', 'wiki', 'board', 'kanban', 'url', 'resource',
  };

  /// Aktivitätstypen, bei denen `aendern` ausschließlich Gruppenmodus und
  /// Gruppierung ändert -- keine Texte, Dateien oder anderen Einstellungen,
  /// kein Anlegen. Ein Typ kommt erst hinein, wenn sein Formular so im
  /// Testkurs gemessen ist (E33); `choicegroup` steht ungemessen darin, abgesichert
  /// durch den Vergleich aller übrigen Felder beim Zurücklesen. Die Positivliste und die Prüfungen in
  /// formular_schreiben.dart richten sich nach dieser einen Stelle.
  static const Set<String> nurGruppenModule = {'collabora', 'choicegroup'};

  /// Die Felder, die bei [nurGruppenModule] geändert werden dürfen.
  static const List<String> gruppenFelder = ['groupmode', 'groupingid'];

  /// Module, die das allgemeine Werkzeug anlegen kann. Lernlandkarten
  /// verwenden ihr eigenes, separat geprüftes Änderungswerkzeug.
  static const Set<String> anlegbareModule = {
    ...schreibbareModule,
    'learningmap',
  };

  /// Aktionen der Kursstruktur (core_courseformat_update_course), die die
  /// Werkzeuge benutzen. Andere sind nicht gemessen. `cm_stealth` ist die Aktion,
  /// mit der Moodle eine Aktivität „verfügbar, aber nicht auf der Kursseite" macht
  /// (visible 1, visibleoncoursepage 0); nur `sichtbarkeit_setzen` braucht sie, um den
  /// Zustand zu erhalten (kurs_aendern.dart). UNGEMESSEN: der Name der Aktion und ob die
  /// Instanz ihn erlaubt (die Verwaltung kann „verfügbar ohne Link" ausschalten).
  /// `cm_moveright` und `cm_moveleft` rücken eine Aktivität je Aufruf um eine Stufe ein
  /// oder aus (verschieben, aktivitaet_anlegen). UNGEMESSEN: Namen, Kursformate, Grenzen.
  static const Set<String> kursAktionen = {
    'section_add',
    'section_hide',
    'section_show',
    'section_move_after',
    'section_delete', //
    'section_duplicate',
    'cm_hide',
    'cm_show',
    'cm_stealth',
    'cm_move',
    'cm_moveright',
    'cm_moveleft',
    'cm_delete',
    'cm_duplicate',
  };

  /// Die eigene Nutzer-ID, mitgelesen aus M.cfg. Dienste, die eine userid
  /// nehmen, dürfen nur mit dieser aufgerufen werden.
  int? _eigeneId;
  int? get eigeneId => _eigeneId;

  /// Die Aktivitäten, die die App seit der Anmeldung verborgen angelegt hat
  /// (aktivitaet_anlegen). Solange eine davon verborgen ist, gehört sie noch
  /// der Arbeitssitzung: Sie zu füllen fragt erst bei „alle", wie das Anlegen
  /// selbst ([fuellenAb] in kurs.dart). Nur im Speicher -- ein Neustart oder
  /// eine neue Anmeldung vergisst sie, dann fragt die App wieder ab „mittel".
  /// Kopien kommen nicht hinein: Bei ihnen ist der Zeilenvergleich zum
  /// Original der Sinn der Freigabe.
  final Set<int> selbstAngelegt = {};

  /// Die Aktivitäten, die `sichtbarkeit_setzen` verborgen hat, während sie „verfügbar
  /// ohne Link" waren. Verbergen hebt den Zustand in Moodle auf, und auch das
  /// Sichtbarmachen bringt ihn nicht zurück; beim nächsten Sichtbarmachen stellt die App ihn
  /// deshalb wieder her. Nur im Speicher und je Sitzung, wie [selbstAngelegt]: Ein
  /// Neustart oder eine neue Anmeldung vergisst ihn, dann macht die App sichtbar, ohne den
  /// Zustand zu kennen, und sagt das.
  final Set<int> ohneLinkVorherVerborgen = {};

  /// Moodle-AJAX-Dienste, die aufgerufen werden dürfen, mit einer Prüfung
  /// ihrer Argumente. Keiner liefert Daten anderer Personen.
  Map<String, bool Function(Map a)> get dienste => {
    // Kursstruktur: Abschnitte und Aktivitäten mit Name, Typ, Sichtbarkeit.
    'core_courseformat_get_state': (a) => _nur(a, {'courseid'}),
    // Kursstruktur ändern, nur mit den gemessenen Aktionen.
    'core_courseformat_update_course': (a) =>
        _nur(a, {
          'action',
          'courseid',
          'ids',
          'targetsectionid',
          'targetcmid',
        }) &&
        kursAktionen.contains(a['action']) &&
        a['ids'] is List,
    // Die eigenen Kurse (wie im Block „Meine Kurse") -- Name und Nummer.
    'core_course_get_enrolled_courses_by_timeline_classification': (a) =>
        _nur(a, {'classification', 'limit', 'offset', 'sort'}),
    // Die eigenen zuletzt besuchten Kurse, nur mit der eigenen userid.
    'core_course_get_recent_courses': (a) =>
        _nur(a, {'userid', 'limit', 'offset', 'sort'}) &&
        _eigeneId != null &&
        a['userid'] == _eigeneId,
    // Zufallsfragen in einen Test.
    'mod_quiz_add_random_questions': (a) =>
        _nur(a, {'cmid', 'addonpage', 'randomcount', 'filtercondition'}),
    // Board: lesen (Notizen anderer gibt die App nicht heraus), Spalten
    // löschen, verschieben, sperren, eigene Notizen löschen.
    'mod_board_get_board': (a) =>
        _nur(a, {'id', 'ownerid', 'groupid'}) && a['ownerid'] == 0,
    'mod_board_delete_column': (a) => _nur(a, {'id'}),
    'mod_board_move_column': (a) => _nur(a, {'id', 'sortorder'}),
    'mod_board_lock_column': (a) => _nur(a, {'id', 'status'}),
    'mod_board_delete_note': (a) => _nur(a, {'id'}),
    // Kanban: das gemeinsame Kursboard.
    'mod_kanban_get_kanban_content_init': (a) =>
        _nur(a, {'cmid', 'boardid', 'timestamp'}),
    for (final k in const [
      'add_column',
      'delete_column',
      'move_column',
      'add_card',
      'delete_card',
      'move_card',
    ])
      'mod_kanban_$k': (a) => _nur(a, {'cmid', 'boardid', 'data'}),
    // Dynamische Formulare, nur die gemessenen Klassen.
    'core_form_dynamic_form': (a) =>
        _nur(a, {'form', 'formdata'}) &&
        dynamischeFormulare.contains(a['form']),
    // Sicherung: Fortschritt lesen.
    // Operation „restore" ist UNGEMESSEN; ohne Schlüssel gilt die Sicherung.
    'core_backup_get_async_backup_progress': (a) =>
        _nur(a, {'backupids', 'contextid', 'operation'}) &&
        a['backupids'] is List &&
        a['contextid'] is num &&
        (a['operation'] == null ||
            a['operation'] == 'backup' ||
            a['operation'] == 'restore'),
  };

  /// Formularklassen für core_form_dynamic_form.
  static const Set<String> dynamischeFormulare = {
    r'qbank_managecategories\form\question_category_edit_form',
    r'mod_kanban\form\edit_card_form',
    r'mod_kanban\form\edit_column_form',
  };

  static bool _nur(Map a, Set<String> schluessel) =>
      a.keys.every(schluessel.contains);

  bool _dienstAufruf(Map<String, String> q, String rumpf) {
    final name = q['info'];
    final pruefen = dienste[name];
    if (pruefen == null) return false;
    try {
      final l = jsonDecode(rumpf);
      if (l is! List || l.length != 1) return false;
      final a = l.single;
      return a is Map &&
          a['methodname'] == name &&
          a['args'] is Map &&
          pruefen(a['args'] as Map);
    } catch (_) {
      return false;
    }
  }

  /// Die Positivliste. Nur diese Anfragen gehen je raus -- auch als
  /// Umleitungsziel. Eine neue Funktion braucht hier einen Eintrag, und das
  /// soll auffallen.
  List<Erlaubt> get positivliste => [
    // ---- Letzte Sperre (E36): die Namen der Teilnehmenden eines Kurses, nur
    // für die App selbst, wenn ein Plugin einen Lauf beginnt
    // (plugin/lauf.dart). Genau diese vier Parameter: die Kursnummer, die
    // Seitengröße, mit der Moodle alle zeigt, und der Filter nach
    // Anfangsbuchstaben leer. Kein anderer Aufrufer bekommt diese Regel.
    Erlaubt(
      'GET',
      r'^/user/index\.php$',
      'Namen der Teilnehmenden eines Kurses für die letzte Sperre',
      parameter: (q) =>
          q.length == 4 &&
          _zahl(q['id']) &&
          q['perpage'] == '$teilnehmendeHoechstens' &&
          q['tifirst'] == '' &&
          q['tilast'] == '',
      nurNamenssperre: true,
    ),
    // ---- Anmelden
    Erlaubt(
      'GET',
      r'^/login/index\.php$',
      'Anmeldeseite',
      parameter: (q) => _nurSchluessel(q, {'testsession'}),
    ),
    Erlaubt(
      'POST',
      r'^/login/index\.php$',
      'Anmeldeformular',
      parameter: (q) => q.isEmpty,
    ),
    // ---- Lesen
    Erlaubt(
      'GET',
      r'^/course/modedit\.php$',
      'Bearbeitungsformular lesen',
      parameter: (q) => q.length == 1 && _zahl(q['update']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/course/editsection\.php$',
      'Abschnittsformular lesen',
      parameter: (q) => _nurSchluessel(q, {'id', 'sr'}) && _zahl(q['id']),
      lesend: true,
    ),
    // Nur lesen: Mit Formularwerten würde dieselbe Adresse Filter umschalten.
    Erlaubt(
      'GET',
      r'^/filter/manage\.php$',
      'Filtereinstellungen eines Kurses (kurs_filter)',
      parameter: (q) => q.length == 1 && _zahl(q['contextid']),
      lesend: true,
    ),
    // Fragen und Tests: nie die Fragenübersicht (question/edit.php) -- sie
    // zeigt „Erstellt von" mit Klarnamen.
    Erlaubt(
      'GET',
      r'^/question/banks\.php$',
      'Fragensammlungen eines Kurses',
      parameter: (q) => q.length == 1 && _zahl(q['courseid']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/question/bank/importquestions/import\.php$',
      'Kategorien, Importformular',
      parameter: (q) => q.length == 1 && _zahl(q['cmid']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/question/bank/exportquestions/export\.php$',
      'Exportformular',
      parameter: (q) => q.length == 1 && _zahl(q['cmid']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/question/bank/exporttoxml/exportone\.php$',
      'eine Frage als XML',
      parameter: (q) =>
          q.length == 3 &&
          _zahl(q['id']) &&
          _zahl(q['cmid']) &&
          _gesetzt(q['sesskey']),
    ),
    Erlaubt(
      'GET',
      r'^/question/bank/editquestion/question\.php$',
      'Bearbeitungsformular einer Frage',
      parameter: (q) =>
          _nurSchluessel(q, {
            'cmid',
            'id',
            'qtype',
            'category',
            'courseid',
            'returnurl',
          }) &&
          _zahl(q['cmid']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/mod/quiz/edit\.php$',
      'Zusammenstellung eines Tests',
      parameter: (q) => q.length == 1 && _zahl(q['cmid']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/question/type/stack/questiontestrun\.php$',
      'STACK: Fragetests und Varianten',
      parameter: (q) =>
          _nurSchluessel(q, {'questionid', 'cmid', 'seed'}) &&
          _zahl(q['questionid']),
    ),
    // Nur über eine Frage: Ohne questionid öffnet STACK den Notizblock nur
    // Administratoren (stack.dart, stackCas).
    Erlaubt(
      'GET',
      r'^/question/type/stack/adminui/caschat\.php$',
      'STACK: CAS-Notizblock',
      parameter: (q) =>
          q.length == 2 && _zahl(q['questionid']) && _zahl(q['cmid']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/mod/checklist/edit\.php$',
      'Fortschrittsliste: die Einträge',
      parameter: (q) => q.length == 1 && _zahl(q['id']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/mod/wiki/view\.php$',
      'Wiki: Startseite oder eine Seite',
      parameter: (q) => q.length == 1 && (_zahl(q['id']) || _zahl(q['pageid'])),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/mod/learningmap/view\.php$',
      'Lernlandkarte ansehen',
      parameter: (q) => q.length == 1 && _zahl(q['id']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/mod/wiki/map\.php$',
      'Wiki: Seitenliste (option 5; 1 und 6 zeigen Namen)',
      parameter: (q) =>
          q.length == 2 && _zahl(q['pageid']) && q['option'] == '5',
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/mod/board/view\.php$',
      'Board: die Board-ID',
      parameter: (q) => q.length == 1 && _zahl(q['id']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/mod/kanban/view\.php$',
      'Kanban: die Board-ID',
      parameter: (q) => q.length == 1 && _zahl(q['id']),
    ),
    Erlaubt(
      'GET',
      r'^/grade/grading/manage\.php$',
      'Bewertungsmethode einer Aufgabe (Definition, keine Bewertung)',
      parameter: (q) =>
          _nurSchluessel(q, {'contextid', 'component', 'area'}) &&
          _zahl(q['contextid']) &&
          q['component'] == 'mod_assign',
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/grade/grading/form/(rubric|guide)/edit\.php$',
      'Bewertungsschema: Definitionsformular',
      parameter: (q) => q.length == 1 && _zahl(q['areaid']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/mod/book/tool/print/index\.php$',
      'Buch: alle Kapitel mit chapterid',
      parameter: (q) => q.length == 1 && _zahl(q['id']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/mod/book/edit\.php$',
      'Buchkapitel: Formular',
      parameter: (q) =>
          _nurSchluessel(q, {'cmid', 'id', 'pagenum', 'subchapter'}) &&
          _zahl(q['cmid']) &&
          (_zahl(q['id']) || _zahl(q['pagenum'])),
      lesend: true,
    ),
    // Sicherung einer Aktivität (sicherung.dart). Nur die gemessenen Schritte
    // der Assistenten; Nutzerdaten bleiben aus (sicherung_regeln.dart).
    Erlaubt(
      'GET',
      r'^/backup/backup\.php$',
      'Sicherung: Einstiegsseite einer Aktivität',
      parameter: (q) =>
          _nurSchluessel(q, {'id', 'cm'}) &&
          _zahl(q['id']) &&
          (q['cm'] == null || _zahl(q['cm'])),
    ),
    Erlaubt(
      'GET',
      r'^/backup/restorefile\.php$',
      'Sicherung: Seite Wiederherstellen (Downloadlink suchen)',
      parameter: (q) =>
          _nurSchluessel(q, {'contextid'}) && _zahl(q['contextid']),
    ),
    Erlaubt(
      'GET',
      r'^/pluginfile\.php/\d+/user/backup/(?:\d+/)?[^/?#]+\.mbz$',
      'Sicherungsdatei',
      parameter: (q) => q.length == 1 && q['forcedownload'] == '1',
    ),
    Erlaubt(
      'GET',
      r'^/draftfile\.php/\d+/user/draft/\d+/.+',
      'Datei im Entwurfsbereich',
      lesend: true,
    ),
    Erlaubt('GET', r'^/pluginfile\.php/\d+/.+', 'Datei im Kurs', lesend: true),
    Erlaubt(
      'POST',
      r'^/lib/ajax/service\.php$',
      'Moodle-Dienst (nur lesend, siehe dienste)',
      parameter: (q) =>
          _nurSchluessel(q, {'sesskey', 'info'}) &&
          (q['sesskey'] ?? '').isNotEmpty &&
          dienste.containsKey(q['info']),
      inhalt: _dienstAufruf,
    ),
    // ---- Schreiben
    Erlaubt(
      'GET',
      r'^/course/modedit\.php$',
      'Formular „Aktivität anlegen"',
      parameter: (q) =>
          _nurSchluessel(q, {
            'add',
            'type',
            'course',
            'section',
            'return',
            'sr',
          }) &&
          anlegbareModule.contains(q['add']) &&
          _zahl(q['course']) &&
          _zahl(q['section']),
    ),
    Erlaubt(
      'POST',
      r'^/course/modedit\.php$',
      'Aktivität speichern',
      parameter: (q) => q.isEmpty,
      formular: (f) {
        final modul = wertIn(f, 'modulename');
        return _zahl(wertIn(f, 'course')) &&
            (schreibbareModule.contains(modul) &&
                    wertIn(f, '_qf__mod_${modul}_mod_form') != null ||
                nurGruppenModule.contains(modul) &&
                    wertIn(f, '_qf__mod_${modul}_mod_form') != null &&
                    _zahl(wertIn(f, 'update')) &&
                    const {'0', '1', '2'}.contains(wertIn(f, 'groupmode')) &&
                    _zahl(wertIn(f, 'groupingid')) ||
                modul == 'learningmap' &&
                    wertIn(f, '_qf__mod_learningmap_mod_form') != null &&
                    wertIn(f, 'placestore') != null &&
                    (wertIn(f, 'update') == null
                        ? _zahl(wertIn(f, 'section'))
                        : _zahl(wertIn(f, 'update'))));
      },
    ),
    // Sicherung: die Schritte 1, 2 und 4 des Assistenten, nur ohne
    // Nutzerdaten. Schritt 4 startet die Sicherung (sicherung.dart).
    Erlaubt(
      'POST',
      r'^/backup/backup\.php$',
      'Sicherung: Schritte 1, 2 und 4 (ohne Nutzerdaten)',
      parameter: (q) => q.isEmpty,
      formular: (f) {
        final schritt = wertIn(f, 'stage');
        return const {'1', '2', '4'}.contains(schritt) &&
            (_marke(
              f,
              RegExp(r'^_qf__backup_(initial|schema|confirmation)_form$'),
            )) &&
            _gesetzt(wertIn(f, 'sesskey')) &&
            // Anders als bei der Wiederherstellung reicht „fehlt = aus" hier nicht:
            // hat setting_root_users einen Wert, muss es 0 sein, und keine
            // Nutzerdaten-Option darf an sein (nutzerdatenPflichtFehler). Fehlt das
            // Feld, ist das das Konto ohne Nutzerdaten-Recht; das Archiv prüft dann.
            nutzerdatenPflichtFehler(f) == null &&
            ohneNutzerdaten(f);
      },
    ),
    Erlaubt(
      'POST',
      r'^/course/editsection\.php$',
      'Abschnitt speichern',
      parameter: (q) => q.isEmpty,
      formular: (f) =>
          _zahl(wertIn(f, 'id')) && f.any((e) => e.key.startsWith('_qf__')),
    ),
    // Gruppierungen (E33): lesen nur Namen; die Seiten index, members und
    // overview zeigen Mitglieder und bleiben gesperrt. Geschrieben wird nur
    // Neues (id 0) und das Zuordnen von Gruppen -- nie Entfernen, Umbenennen
    // oder Löschen.
    Erlaubt(
      'GET',
      r'^/group/groupings\.php$',
      'Gruppierungen eines Kurses (nur Namen)',
      parameter: (q) => q.length == 1 && _zahl(q['id']),
      lesend: true,
    ),
    Erlaubt(
      'GET',
      r'^/group/grouping\.php$',
      'Gruppierung: Formular lesen',
      parameter: (q) => q.length == 1 && (_zahl(q['id']) || _zahl(q['courseid'])),
    ),
    Erlaubt(
      'GET',
      r'^/group/group\.php$',
      'Neue Gruppe: Formular lesen',
      parameter: (q) => q.length == 1 && _zahl(q['courseid']),
    ),
    Erlaubt(
      'GET',
      r'^/group/assign\.php$',
      'Gruppen einer Gruppierung (nur Namen)',
      parameter: (q) => q.length == 1 && _zahl(q['id']),
      lesend: true,
    ),
    Erlaubt(
      'POST',
      r'^/group/grouping\.php$',
      'Neue Gruppierung speichern',
      parameter: (q) => _nurSchluessel(q, {'courseid', 'id'}),
      formular: (f) =>
          wertIn(f, '_qf__grouping_form') != null &&
          _neuesObjekt(wertIn(f, 'id')) &&
          _zahl(wertIn(f, 'courseid')),
    ),
    Erlaubt(
      'POST',
      r'^/group/group\.php$',
      'Neue Gruppe speichern',
      parameter: (q) => _nurSchluessel(q, {'courseid', 'id'}),
      formular: (f) =>
          wertIn(f, '_qf__group_form') != null &&
          _neuesObjekt(wertIn(f, 'id')) &&
          _zahl(wertIn(f, 'courseid')),
    ),
    Erlaubt(
      'POST',
      r'^/group/assign\.php$',
      'Gruppen einer Gruppierung zuordnen (nur Hinzufügen)',
      parameter: (q) => q.length == 1 && _zahl(q['id']),
      formular: (f) =>
          _gesetzt(wertIn(f, 'sesskey')) &&
          wertIn(f, 'add') != null &&
          wertIn(f, 'remove') == null &&
          // Die Werte der Auswahl stammen aus der Seite und sind keine reinen Zahlen
          // (gemessen: vier Zeichen, gemischt); hier nur eine kurze Kennung.
          f.where((e) => e.key == 'addselect[]').every((e) => RegExp(r'^[\w.-]{1,40}$').hasMatch(e.value)) &&
          f.every((e) => e.key != 'removeselect[]'),
    ),
    Erlaubt(
      'POST',
      r'^/question/bank/exportquestions/export\.php$',
      'Fragen exportieren',
      parameter: (q) => _nurSchluessel(q, {'cmid'}),
      formular: (f) =>
          _marke(f, RegExp(r'^_qf__.*export.*form$')) &&
          wertIn(f, 'format') == 'xml',
    ),
    Erlaubt(
      'POST',
      r'^/question/bank/importquestions/import\.php$',
      'Fragen importieren (Moodle-XML)',
      parameter: (q) => _nurSchluessel(q, {'cmid'}),
      formular: (f) =>
          _marke(f, RegExp(r'^_qf__.*import.*form$')) &&
          wertIn(f, 'format') == 'xml',
    ),
    // Speichern erzeugt eine neue Version -- nie mit makecopy, das legte
    // eine zweite Frage an.
    Erlaubt(
      'POST',
      r'^/question/bank/editquestion/question\.php$',
      'Frage speichern (neue Version)',
      parameter: (q) => _nurSchluessel(q, {'cmid', 'id', 'courseid'}),
      formular: (f) =>
          _zahl(wertIn(f, 'id')) &&
          f.any(
            (e) => RegExp(r'^_qf__qtype_[a-z]+_edit_form$').hasMatch(e.key),
          ) &&
          (wertIn(f, 'makecopy') ?? '0') == '0',
    ),
    // Fragen löschen (fragen.dart, fragenLoeschen). Ohne confirm zeigt
    // delete.php nur die Rückfrage und ändert nichts; bestätigt wird mit
    // deren Formular, so wie Moodle es ausgibt -- je nach Moodle als
    // Formular oder als Link, darum beide Wege, mit denselben Feldern.
    // Die Auswahl nimmt die Rückfrage wie das Formular der Sammlung als
    // q<id>=1 (gemessen 30.09.2026, Moodle 5.1: eine Liste in
    // deleteselected allein wählt nichts aus, Moodle leitet nur zurück).
    Erlaubt(
      'GET',
      r'^/question/bank/deletequestion/delete\.php$',
      'Fragen löschen: Rückfrage oder Bestätigung',
      parameter: (q) => _loeschRueckfrage(q) || _loeschBestaetigung(q),
    ),
    Erlaubt(
      'POST',
      r'^/question/bank/deletequestion/delete\.php$',
      'Fragen löschen: Bestätigung',
      parameter: (q) => q.isEmpty,
      formular: (f) => _loeschBestaetigung({for (final e in f) e.key: e.value}),
    ),
    Erlaubt(
      'GET',
      r'^/mod/quiz/edit\.php$',
      'Frage in einen Test einfügen',
      parameter: (q) =>
          q.length == 4 &&
          _zahl(q['cmid']) &&
          _zahl(q['addquestion']) &&
          _zahl(q['addonpage']) &&
          _gesetzt(q['sesskey']),
    ),
    Erlaubt(
      'POST',
      r'^/mod/quiz/edit\.php$',
      'Test: Seiten neu aufteilen oder Beste Bewertung',
      parameter: (q) => q.isEmpty,
      formular: (f) {
        final k = f.map((e) => e.key).toSet();
        return _zahl(wertIn(f, 'cmid')) &&
            _gesetzt(wertIn(f, 'sesskey')) &&
            (k.length == 4 &&
                    k.containsAll({'questionsperpage', 'repaginate'}) ||
                k.length == 4 && k.containsAll({'maxgrade', 'savechanges'}));
      },
    ),
    Erlaubt(
      'POST',
      r'^/mod/quiz/edit_rest\.php$',
      'Test: Punkte, Reihenfolge, Platz entfernen, Fragen mischen',
      parameter: (q) => q.isEmpty,
      formular: (f) {
        final k = f.map((e) => e.key).toSet();
        final klasse = wertIn(f, 'class'),
            feld = wertIn(f, 'field'),
            aktion = wertIn(f, 'action');
        return k.every(
              const {
                'class',
                'field',
                'action',
                'id',
                'maxmark',
                'previousid',
                'page',
                'newshuffle', //
                'sesskey', 'courseid', 'quizid',
              }.contains,
            ) &&
            _zahl(wertIn(f, 'id')) &&
            _zahl(wertIn(f, 'quizid')) &&
            _gesetzt(wertIn(f, 'sesskey')) &&
            ((klasse == 'resource' &&
                    !k.contains('newshuffle') &&
                    ((aktion == null &&
                            (feld == 'updatemaxmark' || feld == 'move')) ||
                        (aktion == 'DELETE' && feld == null))) ||
                (klasse == 'section' &&
                    aktion == null &&
                    feld == 'updateshufflequestions' &&
                    const {'0', '1'}.contains(wertIn(f, 'newshuffle'))));
      },
    ),
    // Das Formular der Testseite: mehrere zufällige oder genau eine
    // Variante, je nach Knopf (stack.dart, stackVarianten).
    Erlaubt(
      'GET',
      r'^/question/type/stack/deploy\.php$',
      'STACK: Varianten einsetzen',
      parameter: (q) =>
          _zahl(q['questionid']) &&
          _zahl(q['cmid']) &&
          _gesetzt(q['sesskey']) &&
          ((q.length == 5 &&
                  _zahl(q['deploy']) &&
                  q['deploysinglebtn'] == '1') ||
              (q.length == 6 &&
                  _zahl(q['deploymany']) &&
                  q['deploymanybtn'] == '1' &&
                  q['deployhalt'] == 'on')),
    ),
    // Der Notizblock rechnet nur. Mit questionid hat sein Formular auch
    // „Speichern" (action = savechat), das Variablen und Feedback ohne neue
    // Version in die Frage schreibt -- darum genau ein action, und das ist go.
    Erlaubt(
      'POST',
      r'^/question/type/stack/adminui/caschat\.php$',
      'STACK: Ausdruck ausrechnen',
      parameter: (q) =>
          q.length == 2 && _zahl(q['questionid']) && _zahl(q['cmid']),
      formular: (f) =>
          f.every(
            (e) =>
                const {'cas', 'maximavars', 'simp', 'action'}.contains(e.key),
          ) &&
          f.where((e) => e.key == 'action').map((e) => e.value).join('|') ==
              'go',
    ),
    Erlaubt(
      'POST',
      r'^/mod/checklist/edit\.php$',
      'Fortschrittsliste: Eintrag anlegen oder ändern',
      parameter: (q) => q.isEmpty,
      formular: (f) {
        final k = f.map((e) => e.key).toSet();
        return _zahl(wertIn(f, 'id')) &&
            _gesetzt(wertIn(f, 'sesskey')) &&
            (k.containsAll({
                      'action',
                      'indent',
                      'displaytext',
                      'linkurl',
                      'additem',
                    }) &&
                    wertIn(f, 'action') == 'additem' ||
                k.containsAll({
                      'itemid',
                      'displaytext',
                      'linkurl',
                      'updateitem',
                    }) &&
                    !k.contains('action')) &&
            k.every(
              const {
                'id',
                'sesskey',
                'action',
                'indent',
                'displaytext',
                'linkurl',
                'additem',
                'itemid',
                'updateitem',
              }.contains,
            );
      },
    ),
    Erlaubt(
      'GET',
      r'^/mod/checklist/edit\.php$',
      'Fortschrittsliste: Eintrag löschen, verschieben, einrücken, Art',
      parameter: (q) =>
          q.length == 4 &&
          _zahl(q['id']) &&
          _zahl(q['itemid']) &&
          _gesetzt(q['sesskey']) &&
          const {
            'deleteitem',
            'moveitemup',
            'moveitemdown',
            'indentitem',
            'unindentitem',
            'makerequired',
            'makeoptional',
            'makeheading',
          }.contains(q['action']),
    ),
    Erlaubt(
      'GET',
      r'^/mod/wiki/create\.php$',
      'Wiki: Formular für eine neue Seite',
      parameter: (q) =>
          (q.length == 3 &&
              _zahl(q['swid']) &&
              _gesetzt(q['title']) &&
              q['action'] == 'new') ||
          // Ohne erste Seite leitet view.php hierher um -- nur das gemeinsame Wiki (uid 0).
          (q.length == 4 &&
              _zahl(q['wid']) &&
              (q['group'] == '' || _zahl(q['group'])) &&
              q['uid'] == '0' &&
              q.containsKey('title')),
    ),
    Erlaubt(
      'POST',
      r'^/mod/wiki/(create|view)\.php$',
      'Wiki: neue Seite anlegen',
      parameter: (q) =>
          _nurSchluessel(q, {
            'action',
            'wid',
            'swid',
            'group',
            'uid',
            'title',
            'id',
            'pageid',
          }) &&
          (q['uid'] ?? '0') == '0',
      formular: (f) =>
          _gesetzt(wertIn(f, 'pagetitle')) &&
          _marke(f, RegExp(r'^_qf__mod_wiki_create_form$')),
    ),
    Erlaubt(
      'GET',
      r'^/mod/wiki/edit\.php$',
      'Wiki: Bearbeitungsformular (nur zum Speichern)',
      parameter: (q) => q.length == 1 && _zahl(q['pageid']),
    ),
    Erlaubt(
      'POST',
      r'^/mod/wiki/edit\.php$',
      'Wiki: Seite speichern',
      parameter: (q) =>
          _nurSchluessel(q, {'pageid', 'section', 'contentformat'}),
      formular: (f) =>
          wertIn(f, 'newcontent_editor[text]') != null &&
          _gesetzt(wertIn(f, 'editoption')),
    ),
    Erlaubt(
      'GET',
      r'^/mod/wiki/admin\.php$',
      'Wiki: Seite löschen',
      parameter: (q) =>
          q.length == 5 &&
          _zahl(q['pageid']) &&
          _zahl(q['delete']) &&
          q['option'] == '1' &&
          q['listall'] == '1' &&
          _gesetzt(q['sesskey']),
    ),
    Erlaubt(
      'POST',
      r'^/mod/board/column_(create|update)_ajax\.php$',
      'Board: Spalte anlegen oder umbenennen',
      parameter: (q) =>
          q.length == 1 && (_zahl(q['boardid']) || _zahl(q['id'])),
    ),
    Erlaubt(
      'POST',
      r'^/mod/board/note_(create|update)_ajax\.php$',
      'Board: eigene Notiz anlegen oder ändern',
      parameter: (q) =>
          (q.length == 1 && _zahl(q['id'])) ||
          (q.length == 3 &&
              _zahl(q['columnid']) &&
              q['ownerid'] == '0' &&
              _zahl(q['groupid'])),
    ),
    Erlaubt(
      'POST',
      r'^/grade/grading/form/(rubric|guide)/edit\.php$',
      'Bewertungsschema speichern (Definition)',
      parameter: (q) => _nurSchluessel(q, {'areaid'}),
      formular: (f) =>
          _marke(f, RegExp(r'^_qf__gradingform_(rubric|guide)_')) &&
          _zahl(wertIn(f, 'areaid')),
    ),
    Erlaubt(
      'POST',
      r'^/mod/book/edit\.php$',
      'Buchkapitel speichern',
      parameter: (q) => q.isEmpty,
      formular: (f) =>
          _zahl(wertIn(f, 'cmid')) &&
          wertIn(f, '_qf__book_chapter_edit_form') != null,
    ),
    Erlaubt(
      'GET',
      r'^/mod/book/delete\.php$',
      'Buchkapitel löschen',
      parameter: (q) =>
          q.length == 4 &&
          _zahl(q['id']) &&
          _zahl(q['chapterid']) &&
          q['confirm'] == '1' &&
          _gesetzt(q['sesskey']),
    ),
    Erlaubt(
      'GET',
      r'^/mod/book/move\.php$',
      'Buchkapitel einen Schritt verschieben',
      parameter: (q) =>
          q.length == 4 &&
          _zahl(q['id']) &&
          _zahl(q['chapterid']) &&
          (q['up'] == '0' || q['up'] == '1') &&
          _gesetzt(q['sesskey']),
    ),
    // Upload einer Datei in den Entwurfsbereich. Eine .mbz-Datei geht nur über
    // die Regel darunter. Die Regel kann nicht sehen, wohin hochgeladen wird; dass
    // eine .mbz nur aus der Wiederherstellung kommt (und nach archivPruefen in
    // wiederherstellen()), erzwingt `MoodleZugang.hochladen` mit seinem Parameter
    // `sicherung`: Der allgemeine Upload (Bilder und Dateien einer Aktivität) weist
    // jede .mbz ab, bevor etwas gesendet wird.
    Erlaubt(
      'POST',
      r'^/repository/repository_ajax\.php$',
      'Datei in den Entwurfsbereich',
      parameter: (q) => q.length == 1 && q['action'] == 'upload',
      anhang: (a) => !a.dateiname.toLowerCase().endsWith('.mbz'),
    ),
    Erlaubt(
      'POST',
      r'^/repository/repository_ajax\.php$',
      'Sicherungsdatei (.mbz) in den Entwurfsbereich',
      parameter: (q) => q.length == 1 && q['action'] == 'upload',
      formular: (f) =>
          _zahl(wertIn(f, 'itemid')) && _gesetzt(wertIn(f, 'sesskey')),
      // UNGEMESSEN: der MIME-Typ, den Moodle für .mbz erwartet.
      anhang: (a) =>
          a.feld == 'repo_upload_file' &&
          RegExp(r'^[A-Za-z0-9_.-]{1,120}\.mbz$').hasMatch(a.dateiname) &&
          (a.mime == 'application/octet-stream' ||
              a.mime == 'application/vnd.moodle.backup'),
    ),
    // Wiederherstellen (wiederherstellung.dart): die gemessenen Schritte.
    Erlaubt(
      'GET',
      r'^/course/view\.php$',
      'Kurs ansehen (Gegenlesen, Kontext; UNGEMESSEN)',
      parameter: (q) => _nurSchluessel(q, {'id'}) && _zahl(q['id']),
    ),
    // Nur diese Felder: Marke, Sitzung, Draft-Itemid und ggf. der Absendeknopf und die Kurs-ID.
    // Jedes andere Feld lehnt die Regel ab (UNGEMESSEN: Feldnamen).
    Erlaubt(
      'POST',
      r'^/backup/restorefile\.php$',
      'Wiederherstellen: Datei hochladen (Formular)',
      parameter: (q) =>
          _nurSchluessel(q, {'contextid'}) &&
          (q['contextid'] == null || _zahl(q['contextid'])),
      formular: (f) =>
          f.every(
            (e) => const {
              'contextid',
              'sesskey',
              '_qf__course_restore_form',
              'backupfile',
              'submitbutton',
            }.contains(e.key),
          ) &&
          _marke(f, RegExp(r'^_qf__course_restore_form$')) &&
          _gesetzt(wertIn(f, 'sesskey')) &&
          _zahl(wertIn(f, 'backupfile')) &&
          (wertIn(f, 'contextid') == null || _zahl(wertIn(f, 'contextid'))),
    ),
    Erlaubt(
      'GET',
      r'^/backup/restore\.php$',
      'Wiederherstellen: Seite des Assistenten',
      parameter: (q) =>
          _nurSchluessel(q, {'contextid', 'filename'}) &&
          _zahl(q['contextid']) &&
          RegExp(r'^[A-Za-z0-9_.-]{1,200}$').hasMatch(q['filename'] ?? ''),
    ),
    // Weiterleitung nach dem Hochladen (UNGEMESSEN): Moodle nennt die Datei über ihren Dateiablagen-Hash.
    Erlaubt(
      'GET',
      r'^/backup/restore\.php$',
      'Wiederherstellen: Weiterleitung nach dem Hochladen (UNGEMESSEN)',
      parameter: (q) =>
          _nurSchluessel(q, {
            'contextid',
            'pathnamehash',
            'component',
            'filearea',
          }) &&
          _zahl(q['contextid']) &&
          RegExp(r'^[a-f0-9]{40}$').hasMatch(q['pathnamehash'] ?? '') &&
          RegExp(r'^[a-z_]{1,50}$').hasMatch(q['component'] ?? 'backup') &&
          RegExp(r'^[a-z_]{1,50}$').hasMatch(q['filearea'] ?? 'draft'),
    ),
    // Sicherungsdetails (gemessen auf der Testinstanz): das Weiter-Formular trägt nur diese Felder und stage=2.
    Erlaubt(
      'POST',
      r'^/backup/restore\.php$',
      'Wiederherstellen: Sicherungsdetails bestätigen',
      parameter: (q) => _nurSchluessel(q, {'contextid', 'filename'}),
      formular: (f) =>
          f.every(
            (e) => const {
              'contextid',
              'filepath',
              'filename',
              'stage',
              'sesskey',
            }.contains(e.key),
          ) &&
          wertIn(f, 'stage') == '2' &&
          _gesetzt(wertIn(f, 'sesskey')),
    ),
    // Zielwahl je Zielweg (E9): jeder Weg hat eine eigene, enge Schlüsselmenge.
    // Der Wert target ist der gemessene Moodle-Wert des Weges; ein anderer wird abgelehnt.
    // Kein _qf__-Feld auf dieser Seite (gemessen). Die Felder search (Kurssuche) und
    // catsearch (Kategoriesuche) gehören je nur zu den Wegen, die sie brauchen.
    for (final ziel in Zielweg.values)
      Erlaubt(
        'POST',
        r'^/backup/restore\.php$',
        'Wiederherstellen: Ziel „${ziel.nennung}" (Formular mit stage=2 oder 4)',
        parameter: (q) => _nurSchluessel(q, {'contextid', 'filename'}),
        formular: (f) {
          final erlaubt = {
            'contextid',
            'filepath',
            'filename',
            'stage',
            'sesskey',
            'target',
            'targetid',
            if (ziel == Zielweg.neuerKurs) 'catsearch',
            if (ziel == Zielweg.anderKursVerschmelzen ||
                ziel == Zielweg.anderKursErsetzen)
              'search',
          };
          return const {'2', '4'}.contains(wertIn(f, 'stage')) &&
              wertIn(f, 'target') == '${ziel.moodle}' &&
              _zahl(wertIn(f, 'targetid')) &&
              _gesetzt(wertIn(f, 'sesskey')) &&
              f.every((e) => erlaubt.contains(e.key));
        },
      ),
    // Kursformular (nur für die Kategorie eines neuen Kurses): ohne Angabe oder mit category.
    Erlaubt(
      'GET',
      r'^/course/edit\.php$',
      'Kursformular lesen (Kategorie des neuen Kurses)',
      parameter: (q) =>
          _nurSchluessel(q, {'category'}) &&
          (q['category'] == null || _zahl(q['category'])),
    ),
    // Kursverwaltung der Kategorie (Kontext der Kategorie; UNGEMESSEN).
    Erlaubt(
      'GET',
      r'^/course/management\.php$',
      'Kategorie ansehen (Kontext; UNGEMESSEN)',
      parameter: (q) =>
          _nurSchluessel(q, {'categoryid'}) && _zahl(q['categoryid']),
    ),
    // Einstellungen, Schema und Prüfung: ohne Nutzerdaten, mit dem Schalter „restore".
    for (final (schritt, form) in const [
      ('4', 'settings'),
      ('8', 'schema'),
      ('16', 'review'),
    ])
      Erlaubt(
        'POST',
        r'^/backup/restore\.php$',
        'Wiederherstellen: Schritt $schritt ($form)',
        parameter: (q) => _nurSchluessel(q, {'contextid', 'filename'}),
        formular: (f) =>
            wertIn(f, 'stage') == schritt &&
            _marke(f, RegExp('^_qf__restore_${form}_form\$')) &&
            wertIn(f, 'restore') != null &&
            _gesetzt(wertIn(f, 'sesskey')) &&
            ohneNutzerdaten(f),
      ),
    // Rollenzuordnung nach dem Prüfen (gemessen auf einer Produktivinstanz): Moodle hält
    // an und wartet auf „Weiter". Nur die Felder dieser Seite; Moodle kann
    // technische Zuordnungskennungen statt reiner Rollennummern verwenden.
    // Die Werte bleiben auf kurze Kennungen begrenzt, Nutzerdaten ausgeschlossen.
    Erlaubt(
      'POST',
      r'^/backup/restore\.php$',
      'Wiederherstellen: Rollenzuordnung bestätigen',
      parameter: (q) => _nurSchluessel(q, {'contextid', 'filename'}),
      formular: (f) =>
          _zahl(wertIn(f, 'stage')) &&
          RegExp(r'^[A-Za-z0-9_.-]{1,40}$').hasMatch(wertIn(f, 'substage') ?? '') &&
          RegExp(r'^[0-9a-f]{32}$').hasMatch(wertIn(f, 'restore') ?? '') &&
          _gesetzt(wertIn(f, 'sesskey')) &&
          f.any((e) => e.key.startsWith('mapping')) &&
          f.every(
            (e) => switch (e.key) {
              'stage' || 'contextid' => _zahl(e.value),
              'substage' || 'restore' || 'sesskey' => true,
              'context' || 'q' || 'pageurl' => true,
              final k when RegExp(r'^mapping\d+$').hasMatch(k) =>
                RegExp(r'^[A-Za-z0-9_.-]{1,60}$').hasMatch(e.value),
              _ => false,
            },
          ) &&
          ohneNutzerdaten(f),
    ),
    Erlaubt(
      'POST',
      r'^/repository/draftfiles_ajax\.php$',
      'Unterordner eines Dateibereichs lesen',
      parameter: (q) => q.length == 1 && q['action'] == 'list',
      formular: (f) =>
          f.length == 4 &&
          _zahl(wertIn(f, 'itemid')) &&
          (wertIn(f, 'filepath') ?? '').startsWith('/') &&
          wertIn(f, 'client_id') != null &&
          (wertIn(f, 'sesskey') ?? '').isNotEmpty,
    ),
    Erlaubt(
      'POST',
      r'^/repository/draftfiles_ajax\.php$',
      'Datei im Entwurfsbereich ersetzen',
      parameter: (q) => q.length == 1 && q['action'] == 'delete',
      formular: (f) =>
          _zahl(wertIn(f, 'itemid')) &&
          (wertIn(f, 'filename') ?? '').isNotEmpty &&
          (wertIn(f, 'sesskey') ?? '').isNotEmpty,
    ),
  ];

  /// Prüft eine Anfrage gegen die Positivliste, ohne sie zu senden.
  bool erlaubt(
    String methode,
    Uri uri, [
    Felder? formular,
    String? rumpf,
    Anhang? anhang,
  ]) {
    for (final e in positivliste) {
      if (e.nurNamenssperre) continue;
      if (e.methode != methode || !RegExp(e.pfad).hasMatch(uri.path)) continue;
      if (e.parameter != null && !e.parameter!(uri.queryParameters)) continue;
      if (e.formular != null && (formular == null || !e.formular!(formular))) {
        continue;
      }
      if ((e.anhang == null) != (anhang == null)) continue;
      if (e.anhang != null && !e.anhang!(anhang!)) continue;
      if ((e.inhalt == null) != (rumpf == null)) continue;
      if (e.inhalt != null && !e.inhalt!(uri.queryParameters, rumpf!)) continue;
      return true;
    }
    return false;
  }

  /// Ob eine Regel der Positivliste, die nur liest ([Erlaubt.lesend]), ein GET
  /// auf [uri] erlaubt. Das ist die Positivliste eines Plugins (E36): dieselben
  /// Regeln wie für die eingebauten Werkzeuge, ohne die Schritte von
  /// Schreibvorgängen.
  bool erlaubtZumLesen(Uri uri) {
    for (final e in positivliste) {
      if (e.nurNamenssperre || !e.lesend || e.methode != 'GET' || !RegExp(e.pfad).hasMatch(uri.path)) continue;
      if (e.formular != null || e.anhang != null || e.inhalt != null) continue;
      if (e.parameter != null && !e.parameter!(uri.queryParameters)) continue;
      return true;
    }
    return false;
  }

  /// Ob die Regel für die letzte Sperre ([Erlaubt.nurNamenssperre]) ein GET
  /// auf [uri] erlaubt. Nur der Aufrufer der letzten Sperre fragt das.
  bool erlaubtFuerNamenssperre(Uri uri) {
    for (final e in positivliste) {
      if (!e.nurNamenssperre || e.methode != 'GET' || !RegExp(e.pfad).hasMatch(uri.path)) continue;
      // Die Parameter genau so, wie sie gesendet werden: Ein Name, der
      // doppelt vorkommt, fiele in queryParameters zusammen.
      if (uri.query.split('&').length != uri.queryParameters.length) continue;
      if (e.parameter != null && !e.parameter!(uri.queryParameters)) continue;
      return true;
    }
    return false;
  }

  /// So viele Teilnehmende zeigt die Teilnehmendenseite auf einmal: der Wert,
  /// den Moodle selbst für „alle zeigen“ benutzt. Ein Kurs mit mehr
  /// Teilnehmenden lässt sich für einen Lauf nicht vollständig lesen; dann
  /// beginnt der Lauf nicht (plugin/lauf.dart).
  static const teilnehmendeHoechstens = 5000;

  /// Höchstens so viele Bytes liest die App von der Teilnehmendenseite; bei
  /// [teilnehmendeHoechstens] Zeilen ist sie weit kleiner.
  static const teilnehmendenseiteHoechstens = 64 * 1024 * 1024;

  late final Aufrufer _namenssperre = _Namenssperre(this);

  /// Liest die Teilnehmendenseite des Kurses [kurs] für die letzte Sperre
  /// (E36), mit der Sitzung dieses Zugangs: `/user/index.php` mit der
  /// Kursnummer, der Seitengröße [teilnehmendeHoechstens] und leerem Filter
  /// nach Anfangsbuchstaben. Nur diese eine Adresse; jedes Umleitungsziel
  /// prüft derselbe Aufrufer, und was nicht genau diese Adresse ist, sperrt
  /// er. Der Inhalt trägt die Namen von Personen: Er geht nur an die Auswertung
  /// in plugin/lauf.dart, die daraus die Namen der letzten Sperre macht, und in
  /// kein Protokoll, keine Datei, keine Antwort.
  Future<Antwort> teilnehmendenseiteLesen(int kurs) async {
    _pruefeAngemeldet();
    return _lesen(
      _adresse('/user/index.php?id=$kurs&perpage=$teilnehmendeHoechstens&tifirst=&tilast='),
      _namenssperre,
      hoechstens: teilnehmendenseiteHoechstens,
    );
  }

  Uri? _basis;
  String? _benutzer;
  String? _passwort;
  final Map<String, String> _cookies = {};
  bool _angemeldet = false;
  Completer<void>? _anmeldungLaeuft;

  /// Nur gesetzt von [fuerTest]: Die Instanz ist eine lokale Testadresse mit
  /// http. Sonst gilt überall https.
  bool _testInstanz = false;

  /// Der Aufrufer jeder Anfrage dieses Zugangs ([Aufrufer]).
  late final Aufrufer _werkzeuge = _EingebauteWerkzeuge(this);

  /// Ein Zugang gegen eine lokale Testinstanz (Test-Doppel auf 127.0.0.1), mit
  /// derselben Anmeldung wie [anmelden], aber ohne die https-Pflicht. Der
  /// einzige Weg, http zu erlauben; die Positivliste lässt http nur für genau
  /// diese Adresse und diesen Port zu ([_schemeErlaubt]).
  ///
  /// Ohne den Bauschalter des Testbetriebs (testschalter.dart) wirft die Methode,
  /// bevor etwas geschieht -- im Release-Bau ohnehin, im Debug-Bau der
  /// Lehrkraft auch.
  @visibleForTesting
  static Future<MoodleZugang> fuerTest(
    Protokoll protokoll,
    Uri basis, {
    required String benutzer,
    required String passwort,
  }) async {
    if (!testbetriebAktiv) throw StateError('Testzugang nur im Testbau verfügbar.');
    if (basis.scheme != 'http' || basis.host != '127.0.0.1') {
      throw ArgumentError('Testzugang nur über http://127.0.0.1.');
    }
    final z = MoodleZugang(protokoll);
    z._testInstanz = true;
    z._basis = basis;
    z._benutzer = benutzer;
    z._passwort = passwort;
    await z._anmelden();
    return z;
  }

  /// Der sesskey der Sitzung, mitgelesen aus jeder HTML-Antwort (M.cfg).
  String? _sesskey;

  /// Der sesskey, soweit er schon bekannt ist, ohne eine Anfrage; null sonst.
  /// Nur, um ihn aus einer Antwort an ein Plugin zu entfernen
  /// (plugin/moodle_lesen.dart): Ein Plugin bekommt ihn auf keinem Weg.
  String? get sesskeyBekannt => _sesskey;

  /// Der Name der angemeldeten Lehrkraft, mitgelesen aus der ersten Seite mit
  /// der Anmeldezeile ([lehrkraftNamenIn]); bei „Anmelden als“ beide Namen.
  /// Nur im Arbeitsspeicher, bis zum Abmelden, und nur für die letzte Sperre
  /// der Plugins (E36, plugin/app_adresse.dart): nie in Protokoll, Datei,
  /// `status` oder einer Antwort.
  final Set<String> _lehrkraft = {};

  /// Siehe [_lehrkraft]; leer, solange keine Seite mit der Anmeldezeile
  /// gelesen ist.
  List<String> get lehrkraftNamen => List.unmodifiable(_lehrkraft);

  bool get angemeldet => _angemeldet;
  Uri? get basis => _basis;

  /// Ob die Instanz die Druckaufbereitung „Aufgabenblatt-Druck" hat, gesehen
  /// auf der Anmeldeseite ([druckaufbereitungErkannt]).
  bool get druckaufbereitung => _druckaufbereitung;
  bool _druckaufbereitung = false;

  /// Pfad des Theme-Stylesheets (/theme/styles.php/…), gesehen auf der
  /// Anmeldeseite ([themeStylesheetIn]); interaktive Elemente binden es ein
  /// (elemente.dart). null: keins gefunden.
  String? get themeStylesheet => _themeStylesheet;
  String? _themeStylesheet;

  // ---------------------------------------------------------------------
  // Anmelden und Abmelden
  // ---------------------------------------------------------------------

  Future<void> anmelden(
    String adresse,
    String benutzer,
    String passwort,
  ) async {
    final b = Uri.parse(adresse.trim());
    if (b.scheme != 'https' || b.host.isEmpty) {
      throw MoodleFehler('Die Moodle-Adresse muss mit https:// beginnen.');
    }
    // Ohne Angaben gar nicht erst fragen: Jeder Fehlversuch zählt bei Moodle
    // gegen die Kontosperre -- und eine bestehende Sitzung ginge verloren.
    if (benutzer.trim().isEmpty || passwort.isEmpty) {
      throw MoodleFehler('Benutzername und Passwort eingeben.');
    }
    _basis = Uri(
      scheme: b.scheme,
      host: b.host,
      port: b.hasPort ? b.port : null,
    );
    _benutzer = benutzer.trim();
    _passwort = passwort;
    try {
      await _anmelden();
    } catch (_) {
      abmelden(stillschweigend: true);
      rethrow;
    }
  }

  /// Verwirft Sitzung und Zugangsdaten.
  void abmelden({bool stillschweigend = false}) {
    _cookies.clear();
    _sesskey = null;
    _eigeneId = null;
    _lehrkraft.clear();
    selbstAngelegt.clear();
    ohneLinkVorherVerborgen.clear();
    _benutzer = null;
    _passwort = null;
    _angemeldet = false;
    _druckaufbereitung = false;
    _themeStylesheet = null;
    if (!stillschweigend) {
      protokoll.eintrag(Art.anmeldung, 'Abgemeldet, Zugangsdaten verworfen');
    }
  }

  /// Nur zum Testen der Neuanmeldung: vergisst die Sitzung, behält aber die
  /// Zugangsdaten. Die nächste Anfrage landet auf der Anmeldeseite.
  void sitzungVerwerfen() {
    _cookies.clear();
    _sesskey = null;
    protokoll.eintrag(
      Art.anmeldung,
      'Sitzung verworfen (Test) -- nächste Anfrage meldet neu an',
    );
  }

  Future<void> _anmelden() async {
    if (_benutzer == null || _passwort == null) {
      throw NichtAngemeldet();
    }
    _cookies.clear();
    _sesskey = null;
    _angemeldet = false;

    // 1. Anmeldeseite: setzt das Sitzungs-Cookie und liefert den logintoken.
    final Antwort seite;
    try {
      seite = await _roh('GET', _adresse('/login/index.php'));
    } on SchutzPruefung {
      // Das Passwort ist noch nicht gesendet: kein Fehlversuch (_neuAnmelden).
      throw MoodleNichtErreichbar(_schutzBeiAnmeldung);
    }
    final doc = html_parser.parse(seite.text);
    final token = doc
        .querySelector('input[name="logintoken"]')
        ?.attributes['value'];
    if (token == null) {
      throw MoodleFehler('Auf der Anmeldeseite fehlt das Anmeldeformular.');
    }
    // Die Anmeldeseite ist die einzige ganze Seite, die hier ohnehin geladen
    // wird; nachzusehen kostet keine weitere Anfrage.
    final druck = druckaufbereitungErkannt(seite.text);
    final stylesheet = themeStylesheetIn(doc);

    // 2. Formular senden. Moodle antwortet bei Erfolg mit einer Umleitung auf
    //    /login/index.php?testsession=…, bei Misserfolg wieder auf die
    //    Anmeldeseite ohne testsession.
    final formular = [
      MapEntry('username', _benutzer!),
      MapEntry('password', _passwort!),
      MapEntry('logintoken', token),
      const MapEntry('anchor', ''),
    ];
    Antwort r;
    try {
      r = await _roh('POST', _adresse('/login/index.php'), formular: formular);
    } on SchutzPruefung {
      // Antwortet der Schutzdienst, kam die Anfrage nie bei Moodle an: Das
      // Passwort wurde dort nicht geprüft, also auch nicht abgelehnt -- kein
      // Fehlversuch, die Zugangsdaten bleiben (_neuAnmelden).
      throw MoodleNichtErreichbar(_schutzBeiAnmeldung);
    } on MoodleNichtErreichbar catch (e) {
      // Ob das Passwort angekommen und abgelehnt worden ist, weiß hier niemand:
      // zählt wie ein Fehlversuch, nicht wie „nicht erreichbar" (_neuAnmelden).
      throw MoodleFehler(e.meldung);
    }
    final ziel = _umleitung(r);
    if (ziel == null ||
        ziel.path != '/login/index.php' ||
        !ziel.queryParameters.containsKey('testsession')) {
      protokoll.eintrag(Art.anmeldung, 'Anmeldung fehlgeschlagen');
      throw MoodleAnmeldungAbgelehnt(
        'Anmeldung fehlgeschlagen. Benutzername oder Passwort prüfen.',
      );
    }

    // 3. testsession bestätigt, dass das Cookie ankommt; danach leitet Moodle
    //    auf die Startseite um. Der wird NICHT gefolgt -- das Dashboard
    //    enthält Daten, die hier niemand braucht.
    try {
      r = await _roh('GET', ziel);
    } on SchutzPruefung {
      // Das Passwort ist hier schon angenommen (Moodle hat auf testsession
      // umgeleitet); der Schutzdienst hält nur den letzten Schritt an. Das ist
      // kein Fehlversuch und kein falsches Passwort: nicht erreichbar, die
      // Zugangsdaten bleiben (_neuAnmelden). Die Meldung sagt es anders als
      // bei den ersten beiden Schritten, wo das Passwort noch nicht geprüft ist.
      throw MoodleNichtErreichbar(_schutzBeimLetztenSchritt);
    }
    final weiter = _umleitung(r);
    if (weiter == null || weiter.path == '/login/index.php') {
      protokoll.eintrag(
        Art.anmeldung,
        'Anmeldung fehlgeschlagen (Sitzung nicht bestätigt)',
      );
      throw MoodleFehler(
        'Anmeldung fehlgeschlagen: Moodle hat die Sitzung nicht bestätigt.',
      );
    }
    _angemeldet = true;
    protokoll.eintrag(Art.anmeldung, 'Angemeldet bei ${_basis!.host}');
    if (druck != _druckaufbereitung || !_druckGemeldet) {
      protokoll.eintrag(
        Art.info,
        druck ? 'Druckaufbereitung „Aufgabenblatt-Druck" erkannt' : 'Keine Druckaufbereitung „Aufgabenblatt-Druck" auf dieser Instanz',
      );
      _druckGemeldet = true;
    }
    _druckaufbereitung = druck;
    _themeStylesheet = stylesheet;
  }

  static const _schutzBeiAnmeldung =
      'Der Schutzdienst vor Moodle lässt die App gerade nicht zur Anmeldung. '
      'Das Passwort ist nicht geprüft worden. Später noch einmal versuchen.';

  static const _schutzBeimLetztenSchritt =
      'Der Schutzdienst vor Moodle hat den letzten Schritt der Anmeldung angehalten. '
      'Das Passwort ist angenommen worden, die Anmeldung aber nicht abgeschlossen. '
      'Später noch einmal versuchen.';

  /// Nur einmal je Stand ins Protokoll, nicht bei jeder Neuanmeldung.
  bool _druckGemeldet = false;

  /// Genau eine Neuanmeldung, auch wenn mehrere Anfragen gleichzeitig
  /// merken, dass die Sitzung weg ist.
  Future<void> _neuAnmelden() async {
    final laufend = _anmeldungLaeuft;
    if (laufend != null) return laufend.future;
    final c = Completer<void>();
    _anmeldungLaeuft = c;
    try {
      protokoll.eintrag(Art.anmeldung, 'Sitzung abgelaufen -- melde neu an');
      await _anmelden();
      c.complete();
    } on MoodleNichtErreichbar catch (e) {
      // Das Passwort ist nicht gesendet (_anmelden): Die Zugangsdaten bleiben,
      // die App gilt weiter als angemeldet, und die nächste Anfrage meldet
      // neu an.
      _angemeldet = true;
      protokoll.eintrag(
        Art.anmeldung,
        'Neuanmeldung: Moodle nicht erreichbar -- die nächste Anfrage versucht es wieder',
      );
      c.completeError(e);
    } catch (e) {
      // Keine zweite Chance: Zugangsdaten verwerfen, damit kein Konto
      // durch wiederholte Fehlversuche gesperrt wird.
      abmelden(stillschweigend: true);
      protokoll.eintrag(
        Art.anmeldung,
        'Neuanmeldung fehlgeschlagen -- Zugangsdaten verworfen',
      );
      c.completeError(
        MoodleFehler(
          'Sitzung abgelaufen und Neuanmeldung fehlgeschlagen. Bitte in der App neu anmelden.',
        ),
      );
    } finally {
      _anmeldungLaeuft = null;
    }
    return c.future;
  }

  void _pruefeAngemeldet() {
    if (_basis == null || _passwort == null) throw NichtAngemeldet();
  }

  // ---------------------------------------------------------------------
  // Lesen
  // ---------------------------------------------------------------------

  /// Liest eine Adresse mit der Sitzung. Landet die Anfrage auf der
  /// Anmeldeseite, wird einmal neu angemeldet und wiederholt.
  Future<Antwort> lesen(String pfadMitQuery) async {
    _pruefeAngemeldet();
    final uri = pfadMitQuery.startsWith('http')
        ? Uri.parse(pfadMitQuery)
        : _adresse(pfadMitQuery);
    return _lesen(uri, _werkzeuge);
  }

  /// Liest [uri] wie [lesen], für [aufrufer]: Die Adresse und jedes
  /// Umleitungsziel prüft dessen Listen, und die Protokollzeilen nennt er. Mehr
  /// als [hoechstens] Bytes liest es nicht ([AntwortZuGross]). Eine abgelaufene
  /// Sitzung meldet die App selbst neu an, genau einmal, wie bei [lesen].
  Future<Antwort> lesenAls(Aufrufer aufrufer, Uri uri, {int? hoechstens}) async {
    _pruefeAngemeldet();
    return _lesen(uri, aufrufer, hoechstens: hoechstens);
  }

  Future<Antwort> _lesen(Uri uri, Aufrufer aufrufer, {int? hoechstens}) async {
    var r = await _mitUmleitungen(uri, aufrufer, hoechstens);
    if (_istAnmeldeseite(r.adresse)) {
      await _neuAnmelden();
      r = await _mitUmleitungen(uri, aufrufer, hoechstens);
      if (_istAnmeldeseite(r.adresse)) {
        throw MoodleFehler(
          'Nach der Neuanmeldung landet die Anfrage wieder auf der Anmeldeseite.',
        );
      }
    }
    return r;
  }

  /// Der sesskey der Sitzung. Steht er noch nicht fest, liefert ihn die
  /// Anmeldeseite: Angemeldeten zeigt sie nur „Sie sind bereits angemeldet"
  /// -- ohne Blöcke, ohne Kursdaten.
  Future<String> sesskey() async {
    _pruefeAngemeldet();
    final bekannt = _sesskey;
    if (bekannt != null) return bekannt;
    for (var versuch = 0; versuch < 2; versuch++) {
      final r = await _roh('GET', _adresse('/login/index.php'));
      if (r.text.contains('name="logintoken"')) {
        // Nicht (mehr) angemeldet: Die Seite zeigt das Anmeldeformular.
        await _neuAnmelden();
        continue;
      }
      final s = _sesskey;
      if (s != null) return s;
      break;
    }
    throw MoodleFehler('Der sesskey der Sitzung ist nicht zu ermitteln.');
  }

  /// Liest die eigene Nutzer-ID aus M.cfg der Anmeldeseite nach.
  Future<void> eigeneIdErmitteln() async {
    _sesskey = null;
    await sesskey();
  }

  /// Ruft einen Moodle-AJAX-Dienst auf (lib/ajax/service.php) und gibt das
  /// Ergebnis zurück. Nur Dienste aus [dienste]. Bei abgelaufener Sitzung
  /// einmal neu anmelden und wiederholen.
  Future<Object?> dienst(String name, Map<String, Object?> args) async {
    for (var versuch = 0; versuch < 2; versuch++) {
      final key = await sesskey();
      final rumpf = jsonEncode([
        {'index': 0, 'methodname': name, 'args': args},
      ]);
      final r = await _roh(
        'POST',
        _adresse('/lib/ajax/service.php?sesskey=$key&info=$name'),
        rumpf: rumpf,
      );
      Object? j;
      try {
        j = jsonDecode(r.text);
      } catch (_) {
        throw MoodleFehler('$name: keine JSON-Antwort (HTTP ${r.status}).');
      }
      final fehler =
          j is List &&
              j.isNotEmpty &&
              j.first is Map &&
              (j.first as Map)['error'] == true
          ? (j.first as Map)['exception'] as Map?
          : j is Map && j['error'] != null
          ? j
          : null;
      if (fehler == null && j is List && j.isNotEmpty) {
        return (j.first as Map)['data'];
      }
      final code = '${fehler?['errorcode'] ?? ''}';
      if (versuch == 0 &&
          const {
            'servicerequireslogin',
            'requireloginerror',
            'invalidsesskey',
          }.contains(code)) {
        _sesskey = null;
        await _neuAnmelden();
        continue;
      }
      throw MoodleFehler('$name abgelehnt: ${fehler?['message'] ?? r.text}');
    }
    throw MoodleFehler('$name: Sitzung nicht wiederherzustellen.');
  }

  // ---------------------------------------------------------------------
  // Schreiben
  // ---------------------------------------------------------------------

  /// Sendet ein Formular (application/x-www-form-urlencoded). Folgt keiner
  /// Umleitung -- die Antwort samt Location-Kopf geht an den Aufrufer.
  /// Landet es auf der Anmeldeseite: neu anmelden und SitzungAbgelaufen
  /// werfen; der Aufrufer baut den Vorgang neu auf.
  Future<Antwort> senden(String pfad, Felder formular) async {
    _pruefeAngemeldet();
    final r = await _roh('POST', _adresse(pfad), formular: formular);
    await _pruefeSitzungNachSchreiben(r);
    return r;
  }

  /// Sendet ein Formular wie [senden], für [aufrufer] (ein Plugin, das über
  /// eine Zusatzadresse schreibt, plugin/moodle_schreiben.dart): Dessen Listen
  /// prüfen die Adresse, seine Zeile steht im Protokoll, und mehr als
  /// [hoechstens] Bytes Antwort liest es nicht. Folgt keiner Umleitung und
  /// wiederholt nichts: Ob ein Formular angekommen ist, weiß nach einem Fehler
  /// niemand. Landet es auf der Anmeldeseite, meldet die App neu an und wirft
  /// [SitzungAbgelaufen]; gesendet wird dann nichts mehr.
  Future<Antwort> sendenAls(Aufrufer aufrufer, Uri uri, Felder formular, {int? hoechstens}) async {
    _pruefeAngemeldet();
    final r = await _roh('POST', uri, formular: formular, aufrufer: aufrufer, hoechstens: hoechstens);
    await _pruefeSitzungNachSchreiben(r);
    return r;
  }

  /// Ruft eine Adresse per GET auf, ohne Umleitungen zu folgen: für Aktionen,
  /// die Moodle als Link mit sesskey anbietet und nach denen es auf eine
  /// Ansichtsseite umleitet (etwa Buchkapitel löschen). Der Umleitung zu
  /// folgen hieße, eine Seite abzurufen, die niemand braucht.
  Future<Antwort> aufrufen(String pfadMitQuery) async {
    _pruefeAngemeldet();
    final r = await _roh('GET', _adresse(pfadMitQuery));
    await _pruefeSitzungNachSchreiben(r);
    return r;
  }

  /// Lädt eine Datei hoch (multipart/form-data). Eine Sicherungsdatei (.mbz) darf
  /// nur die Wiederherstellung hochladen ([sicherung]: true), und dann muss es auch
  /// eine sein: Sonst hinge der allgemeine Upload eine Sicherung an eine Aktivität,
  /// an der Prüfung des Archivs vorbei. Die Positivliste sieht das Ziel nicht.
  Future<Antwort> hochladen(
    String pfadMitQuery,
    Felder felder,
    Anhang datei, {
    bool sicherung = false,
  }) async {
    final istSicherung = datei.dateiname.toLowerCase().endsWith('.mbz');
    if (istSicherung != sicherung) {
      throw MoodleFehler(istSicherung
          ? 'Eine Sicherungsdatei (.mbz) lädt nur die Wiederherstellung hoch, nach der Prüfung des Archivs; '
              'an eine Aktivität gehört sie nicht. Nichts gesendet.'
          : 'Als Sicherung hochgeladen wird nur eine .mbz-Datei. Nichts gesendet.');
    }
    _pruefeAngemeldet();
    final r = await _roh(
      'POST',
      _adresse(pfadMitQuery),
      formular: felder,
      anhang: datei,
    );
    await _pruefeSitzungNachSchreiben(r);
    return r;
  }

  /// Lädt eine Sicherungsdatei (Pfad mit `?forcedownload=1`) als Stream nach
  /// [ziel]. Geschrieben wird zuerst nach `<ziel>.teil`; erst wenn die Größe
  /// mit der angekündigten übereinstimmt, wird umbenannt. Bei jedem Fehler
  /// verschwindet der Teil. Eine vorhandene Datei wird nie überschrieben.
  /// Gibt die Zahl der Bytes zurück. Mehr als [maxBytes] lädt sie nicht: Die angekündigte
  /// Größe wird vorher geprüft, und beim Laden zählt jedes Stück mit, damit eine
  /// Datei, die mehr liefert als angekündigt, den Speicherplatz nicht füllt
  /// ([DownloadZuGross]).
  ///
  Future<int> herunterladen(String pfadMitQuery, File ziel, {int maxBytes = archivGrenzeStandard}) async {
    _pruefeAngemeldet();
    return _herunterladen(_adresse(pfadMitQuery), ziel, maxBytes, _werkzeuge, null);
  }

  /// Wie [herunterladen], für [aufrufer] (ein Plugin, plugin/moodle_lesen.dart):
  /// Dessen Listen prüfen die Adresse, und seine Zeile steht im Protokoll.
  /// Erfüllt sich [abbruch], hört das Laden beim nächsten Stück auf, und der
  /// Teil verschwindet. Mit [groesseNoetig] false nimmt es auch eine Datei
  /// ohne angekündigte Größe an (ein Skript, das eine Datei erzeugt, nennt
  /// sie oft nicht); [maxBytes] zählt dann beim Laden mit. Mit
  /// [umleitungenFolgen] folgt es Umleitungen, höchstens
  /// [umleitungenHoechstens], und prüft jedes Ziel vor dem Senden mit den
  /// Listen des [aufrufer], wie die Adresse selbst; ein Ziel, das sie nicht
  /// zulassen, oder die Anmeldeseite beendet den Download als Fehler, bevor
  /// etwas abgelegt ist. Ohne folgt es keiner, wie [herunterladen].
  Future<int> herunterladenAls(
    Aufrufer aufrufer,
    Uri uri,
    File ziel, {
    int maxBytes = archivGrenzeStandard,
    Future<void>? abbruch,
    bool groesseNoetig = true,
    bool umleitungenFolgen = false,
  }) async {
    _pruefeAngemeldet();
    return _herunterladen(
      uri,
      ziel,
      maxBytes,
      aufrufer,
      abbruch,
      groesseNoetig: groesseNoetig,
      umleitungen: umleitungenFolgen ? umleitungenHoechstens : 0,
    );
  }

  /// Wie vielen Umleitungen ein Download mit `umleitungenFolgen` höchstens
  /// folgt; so viele wie das Lesen ([_mitUmleitungen]) und das Schreiben
  /// eines Plugins über eine Zusatzadresse.
  static const umleitungenHoechstens = 8;

  Future<int> _herunterladen(
    Uri uri,
    File ziel,
    int maxBytes,
    Aufrufer aufrufer,
    Future<void>? abbruch, {
    bool groesseNoetig = true,
    int umleitungen = 0,
  }) async {
    var abgebrochen = false;
    unawaited(abbruch?.then((_) => abgebrochen = true));
    _pruefePositivliste(aufrufer, 'GET', uri, null, null);
    if (await ziel.exists()) {
      throw MoodleFehler('Zieldatei existiert schon; nichts überschrieben.');
    }
    final teil = File('${ziel.path}.teil');
    final client = HttpClient()
      ..userAgent = 'moocp (lokal)'
      ..connectionTimeout = verbindungsgrenze;
    IOSink? senke;
    var fertig = false;
    // Die Adresse der Anfrage, die gerade läuft; nach einer Umleitung das Ziel.
    var aktuell = uri;
    try {
      HttpClientResponse res;
      for (var gefolgt = 0;; gefolgt++) {
        final req = await client.getUrl(aktuell);
        req.followRedirects = false;
        _cookies.forEach((k, v) => req.cookies.add(Cookie(k, v)));
        res = await req.close().timeout(antwortgrenze);
        _protokolliere(aufrufer, Art.moodle, 'GET', aktuell, res.statusCode);
        final ort = res.statusCode >= 300 && res.statusCode < 400 ? res.headers.value(HttpHeaders.locationHeader) : null;
        if (umleitungen == 0 || ort == null) break;
        await res.drain<void>().timeout(antwortgrenze);
        if (gefolgt >= umleitungen) throw MoodleFehler('Zu viele Umleitungen ab ${aufrufer.pfadImProtokoll(uri)}; nichts übernommen.');
        final naechste = aktuell.resolve(ort);
        if (_istAnmeldeseite(naechste)) {
          throw MoodleFehler('Der Download leitet auf die Anmeldeseite um (Sitzung abgelaufen?); nichts übernommen.');
        }
        // Jedes Ziel wie die Adresse selbst, bevor es gefragt wird.
        _pruefePositivliste(aufrufer, 'GET', naechste, null, null);
        aktuell = naechste;
      }
      if (res.statusCode != 200) {
        throw MoodleFehler('Download abgelehnt (HTTP ${res.statusCode}).');
      }
      if (res.headers.contentType?.mimeType == 'text/html') {
        throw MoodleFehler(
          'Download liefert eine Seite statt einer Datei (Anmeldung abgelaufen?).',
        );
      }
      final erwartet = res.contentLength;
      if (erwartet < 0 && groesseNoetig) {
        // Ohne angekündigte Größe gibt es keine Prüfung; dann wird nichts übernommen.
        throw MoodleFehler(
          'Moodle nennt die Größe der Datei nicht; nicht übernommen.',
        );
      }
      if (erwartet > maxBytes) throw DownloadZuGross(maxBytes);
      senke = teil.openWrite();
      var gelesen = 0;
      await for (final d in res.timeout(antwortgrenze)) {
        if (abgebrochen) throw MoodleFehler('Abgebrochen; nichts übernommen.');
        gelesen += d.length;
        if (gelesen > maxBytes) throw DownloadZuGross(maxBytes);
        senke.add(d);
      }
      final s = senke;
      senke = null;
      await s.close();
      if (erwartet >= 0 && gelesen != erwartet) {
        throw MoodleFehler(
          'Die Datei ist unvollständig ($gelesen von $erwartet Bytes).',
        );
      }
      if (abgebrochen) throw MoodleFehler('Abgebrochen; nichts übernommen.');
      await teil.rename(ziel.path);
      fertig = true;
      return gelesen;
    } on SocketException catch (e) {
      protokoll.eintrag(Art.fehler, 'GET ${aufrufer.pfadImProtokoll(aktuell)}: nicht erreichbar');
      throw MoodleNichtErreichbar('Moodle nicht erreichbar: ${e.message}');
    } on TimeoutException {
      protokoll.eintrag(
        Art.fehler,
        'GET ${aufrufer.pfadImProtokoll(aktuell)}: keine Antwort innerhalb der Zeitgrenze',
      );
      throw MoodleNichtErreichbar(
        'Moodle antwortet nicht (${uri.path}). Später noch einmal versuchen.',
      );
    } on IOException catch (e) {
      protokoll.eintrag(
        Art.fehler,
        'GET ${aufrufer.pfadImProtokoll(aktuell)}: Verbindung abgebrochen (${e.runtimeType})',
      );
      throw MoodleNichtErreichbar(
        'Verbindung zu Moodle abgebrochen (${e.runtimeType}). Später noch einmal versuchen.',
      );
    } finally {
      client.close(force: true);
      try {
        await senke?.close();
      } catch (_) {}
      if (!fertig && await teil.exists()) await teil.delete();
    }
  }

  Future<void> _pruefeSitzungNachSchreiben(Antwort r) async {
    final ziel = _umleitung(r);
    final json = (r.inhaltstyp ?? '').contains('json') ? r.text : '';
    if ((ziel != null && _istAnmeldeseite(ziel)) ||
        json.contains('requireloginerror') ||
        json.contains('invalidsesskey')) {
      await _neuAnmelden();
      throw SitzungAbgelaufen();
    }
  }

  bool _istAnmeldeseite(Uri u) => u.path == '/login/index.php';

  Future<Antwort> _mitUmleitungen(Uri start, Aufrufer aufrufer, int? hoechstens) async {
    var uri = start;
    // Die erste Anfrage und danach höchstens [umleitungenHoechstens] Ziele.
    for (var i = 0; i <= umleitungenHoechstens; i++) {
      final r = await _roh('GET', uri, aufrufer: aufrufer, hoechstens: hoechstens);
      final ziel = _umleitung(r);
      if (ziel == null) return r;
      // Umleitung auf die Anmeldeseite: nicht folgen, Aufrufer entscheidet.
      if (_istAnmeldeseite(ziel)) {
        return Antwort(r.status, ziel, Uint8List(0), null);
      }
      uri = ziel;
    }
    throw MoodleFehler('Zu viele Umleitungen ab ${start.path}');
  }

  Uri? umleitungsziel(Antwort r) => _umleitung(r);

  Uri? _umleitung(Antwort r) {
    if (r.status < 300 || r.status >= 400) return null;
    final ort = r.ort;
    if (ort == null) return null;
    return r.adresse.resolve(ort);
  }

  Uri _adresse(String pfadMitQuery) => _basis!.resolve(pfadMitQuery);

  // ---------------------------------------------------------------------
  // Eine einzelne Anfrage -- hier sitzt die Positivliste
  // ---------------------------------------------------------------------

  /// https ist Pflicht. Ausnahme nur die Testinstanz ([fuerTest]) auf ihrer
  /// eigenen Adresse und ihrem eigenen Port.
  bool _schemeErlaubt(Uri uri) =>
      uri.scheme == 'https' ||
      (_testInstanz &&
          _basis!.scheme == 'http' &&
          uri.scheme == 'http' &&
          uri.port == _basis!.port);

  /// Die Prüfung vor dem Senden, für jede Anfrage dieselbe -- auch für den
  /// Download. Der Rechner und das Schema sind Sache der Instanz; was auf den
  /// beiden Listen steht und wie die Ablehnung im Protokoll lautet, sagt der
  /// [aufrufer].
  void _pruefePositivliste(
    Aufrufer aufrufer,
    String methode,
    Uri uri,
    Felder? formular,
    String? rumpf, [
    Anhang? anhang,
  ]) {
    if (_basis == null || uri.host != _basis!.host || !_schemeErlaubt(uri)) {
      throw AnfrageGesperrt(
        'Gesperrt: fremder Rechner oder kein https (${uri.host}).',
      );
    }
    final regel = aufrufer.gesperrtDurch(uri);
    if (regel != null) {
      protokoll.eintrag(Art.gesperrt, aufrufer.sperrzeile(methode, uri, regel));
      throw AnfrageGesperrt(aufrufer.sperrmeldung(uri, regel));
    }
    if (aufrufer.erlaubt(methode, uri, formular, rumpf, anhang)) return;
    protokoll.eintrag(
      Art.gesperrt,
      aufrufer.ablehnzeile(methode, uri, formular),
    );
    throw AnfrageGesperrt(aufrufer.ablehnmeldung(methode, uri));
  }

  /// Trägt eine gestellte Anfrage ins Protokoll ein, für jede Anfrage
  /// dieselbe -- auch für den Download: die Zeile des [aufrufer], der Status
  /// und, was ein Schutzdienst dazu sagt ([hinweis]).
  void _protokolliere(
    Aufrufer aufrufer,
    Art art,
    String methode,
    Uri uri,
    int status, {
    Anhang? anhang,
    bool browser = false,
    String hinweis = '',
  }) {
    protokoll.eintrag(
      art,
      '${browser ? 'Browser: ' : ''}${aufrufer.anfragezeile(methode, uri, anhang)}'
      ' → $status$hinweis',
    );
  }

  /// Eine Anfrage des Browsers für ein Bildschirmfoto (bildschirmfoto.dart):
  /// geprüft gegen die Liste für Bildschirmfotos (browserliste.dart) statt
  /// gegen die Positivliste, gestellt mit der Sitzung der App -- das Cookie
  /// verlässt die App nicht. Umleitungen gehen an den Browser zurück; er
  /// folgt ihnen mit einer neuen Anfrage, die wieder hier geprüft wird.
  Future<Antwort> fuerBrowser(
    String methode,
    Uri uri, {
    required Set<String> seiten,
    String? rumpf,
    bool dokument = false,
  }) {
    _pruefeAngemeldet();
    final (weg, grund) = browserPruefen(
      methode,
      uri,
      basis: _basis!,
      seiten: seiten,
      dokument: dokument,
      rumpf: rumpf,
    );
    if (weg != BrowserWeg.ueberApp) {
      protokoll.eintrag(
        Art.gesperrt,
        'Browser gesperrt: $methode ${adresseOhneWerte(uri)} ($grund)',
      );
      throw MoodleFehler('Gesperrt: $methode ${uri.path} ($grund).');
    }
    return _roh(methode, uri, rumpf: rumpf, browser: true);
  }

  Future<Antwort> _roh(
    String methode,
    Uri uri, {
    Felder? formular,
    Anhang? anhang,
    String? rumpf,
    bool browser = false,
    Aufrufer? aufrufer,
    int? hoechstens,
  }) async {
    // Ohne Angabe die App selbst -- auch die Anmeldung, wenn ein Plugin sie
    // ausgelöst hat.
    aufrufer ??= _werkzeuge;
    // Anfragen des Browsers sind in fuerBrowser geprüft, gegen ihre eigene
    // Liste; die Sperrliste gilt dort zuerst wie hier.
    if (!browser) {
      _pruefePositivliste(aufrufer, methode, uri, formular, rumpf, anhang);
    }
    final client = HttpClient()
      ..userAgent = 'moocp (lokal)'
      ..connectionTimeout = verbindungsgrenze;
    try {
      final req = await client.openUrl(methode, uri);
      req.followRedirects = false;
      _cookies.forEach((k, v) => req.cookies.add(Cookie(k, v)));
      if (anhang != null) {
        final grenze =
            'moocp${Random.secure().nextInt(1 << 32).toRadixString(16)}';
        req.headers.contentType = ContentType(
          'multipart',
          'form-data',
          parameters: {'boundary': grenze},
        );
        final b = BytesBuilder();
        void zeile(String s) => b.add(utf8.encode('$s\r\n'));
        for (final e in formular ?? const <MapEntry<String, String>>[]) {
          zeile('--$grenze');
          zeile('Content-Disposition: form-data; name="${e.key}"');
          zeile('');
          zeile(e.value);
        }
        zeile('--$grenze');
        zeile(
          'Content-Disposition: form-data; name="${anhang.feld}"; '
          'filename="${anhang.dateiname.replaceAll('"', '')}"',
        );
        zeile('Content-Type: ${anhang.mime}');
        zeile('');
        b.add(anhang.bytes);
        zeile('');
        zeile('--$grenze--');
        final body = b.takeBytes();
        req.contentLength = body.length;
        req.add(body);
      } else if (rumpf != null) {
        final body = utf8.encode(rumpf);
        req.headers.contentType = ContentType(
          'application',
          'json',
          charset: 'utf-8',
        );
        req.contentLength = body.length;
        req.add(body);
      } else if (formular != null) {
        final body = utf8.encode(
          formular
              .map(
                (e) =>
                    '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
              )
              .join('&'),
        );
        req.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close().timeout(antwortgrenze);
      for (final c in res.cookies) {
        if (c.value.isEmpty || c.value == 'deleted') {
          _cookies.remove(c.name);
        } else {
          _cookies[c.name] = c.value;
        }
      }
      final bytes = BytesBuilder(copy: false);
      var zuGross = false;
      await for (final d in res.timeout(antwortgrenze)) {
        if (hoechstens != null && bytes.length + d.length > hoechstens) {
          // Nicht weiterlesen: Das Verlassen der Schleife beendet die Antwort,
          // und die Verbindung schließt finally.
          zuGross = true;
          break;
        }
        bytes.add(d);
      }
      if (zuGross) {
        _protokolliere(aufrufer, Art.moodle, methode, uri, res.statusCode, hinweis: ' (zu groß, abgebrochen)');
        throw AntwortZuGross(hoechstens!);
      }
      final roh = bytes.takeBytes();
      final schutz = schutzErkennen(
        res.statusCode,
        server: res.headers.value(HttpHeaders.serverHeader),
        mitigated: res.headers.value('cf-mitigated'),
        text: utf8.decode(roh, allowMalformed: true),
      );
      // Ray-ID nur aus dem Kopf, keine Werte aus Anfrage oder Antwort.
      final ray = res.headers.value('cf-ray');
      final a = Antwort(
        res.statusCode,
        uri,
        roh,
        res.headers.contentType?.mimeType,
        ort: res.headers.value(HttpHeaders.locationHeader),
        schutz: schutz,
      );
      if (a.inhaltstyp == 'text/html' && _angemeldet) {
        final s = RegExp(r'"sesskey":"(\w+)"').firstMatch(a.text)?.group(1);
        if (s != null) _sesskey = s;
        final id = int.tryParse(
          RegExp(r'"userId":(\d+)').firstMatch(a.text)?.group(1) ?? '',
        );
        if (id != null && id > 1) _eigeneId = id;
        if (_lehrkraft.isEmpty) _lehrkraft.addAll(lehrkraftNamenIn(a.text));
      }
      // Ins Protokoll: Methode, Pfad, Status. Keine Formularwerte, keine
      // Cookies, keine Parameterwerte der Anmeldung.
      // Lesende Dienstaufrufe (JSON-Rumpf) sind zwar POST, schreiben aber
      // nichts; ein GET mit sesskey dagegen ist eine Aktion.
      final dienst = uri.queryParameters['info'];
      final schreibt = rumpf != null
          ? schreibendeDienste.contains(dienst)
          : methode != 'GET' || uri.queryParameters.containsKey('sesskey');
      _protokolliere(
        aufrufer,
        schreibt ? Art.schreiben : Art.moodle,
        methode,
        uri,
        res.statusCode,
        anhang: anhang,
        browser: browser,
        hinweis:
            '${switch (schutz) {
              Schutz.pruefung => ' (Schutzdienst: Prüfung verlangt',
              Schutz.sperre => ' (Schutzdienst: abgewiesen',
              null => '',
            }}${schutz == null ? '' : '${ray == null ? '' : ', Ray-ID $ray'})'}',
      );
      // Die Seite des Schutzdienstes ist keine Antwort von Moodle; als solche
      // gelesen, sähe sie wie ein fehlendes Recht oder eine leere Seite aus.
      // Der Browser für Bildschirmfotos bekommt sie wie jede Antwort.
      if (schutz != null && !browser) {
        throw SchutzPruefung(sperre: schutz == Schutz.sperre);
      }
      return a;
    } on SocketException catch (e) {
      protokoll.eintrag(Art.fehler, '$methode ${aufrufer.pfadImProtokoll(uri)}: nicht erreichbar');
      throw MoodleNichtErreichbar('Moodle nicht erreichbar: ${e.message}');
    } on TimeoutException {
      protokoll.eintrag(
        Art.fehler,
        '$methode ${aufrufer.pfadImProtokoll(uri)}: keine Antwort innerhalb der Zeitgrenze',
      );
      throw MoodleNichtErreichbar(
        'Moodle antwortet nicht (${uri.path}, Zeitgrenze '
        '${antwortgrenze.inSeconds} s). Später noch einmal versuchen.',
      );
    } on IOException catch (e) {
      // Abbruch mitten in der Antwort (HttpException) oder TLS-Fehler
      // (HandshakeException): nur der Typ, der Text kann Adressen enthalten.
      protokoll.eintrag(
        Art.fehler,
        '$methode ${aufrufer.pfadImProtokoll(uri)}: Verbindung abgebrochen (${e.runtimeType})',
      );
      throw MoodleNichtErreichbar(
        'Verbindung zu Moodle abgebrochen (${e.runtimeType}). Später noch einmal versuchen.',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Die Query einer Adresse für das Protokoll, mit „?“ davor: der sesskey als
  /// „…“, die Query der Anmeldeseite ganz als „…“.
  static String querySicher(Uri uri) {
    if (uri.query.isEmpty) return '';
    if (uri.path == '/login/index.php') return '?…';
    // Der sesskey ist ein Schlüssel der Sitzung: nicht ins Protokoll.
    return '?${uri.query.replaceAll(RegExp(r'sesskey=[^&]*'), 'sesskey=…')}';
  }
}
