// Ein Plugin schreibt über eine Zusatzadresse (E36): eine Seite der Instanz,
// die es in seiner Beschreibungsdatei mit der Art „schreiben“ angemeldet und
// der die Lehrkraft mit seinem Stand zugestimmt hat (E35). Für dieses Plugin
// hebt sie die Sperrliste der App auf, für kein anderes und nie für die
// eingebauten Werkzeuge. Die Funktionen der Adresse der App dazu stehen in
// app_adresse.dart; hier stehen die Regeln.
//
// Ablauf, beide Schritte nur mit dem Token eines laufenden Aufrufs:
//
//  1. Freigabe: Das Plugin nennt Methode (nur POST), Pfad samt Parametern,
//     die Formularfelder, Titel und Zusammenfassung. moocp prüft alles, was
//     sich ohne Dialog prüfen lässt, und lehnt ohne Dialog ab, was nicht
//     erlaubt ist. Dann fragt es die Lehrkraft, auf jeder Stufe (`ab: keine`),
//     und gibt bei Freigabe eine Kennung zurück.
//  2. Schreiben: Das Plugin nennt die Kennung und noch einmal Methode, Pfad
//     und Formularfelder; moocp sendet genau das, mit seiner Sitzung und dem
//     sesskey, den es selbst einsetzt.
//
// Woran die Freigabe gebunden ist: an den Aufruf, in dem sie erteilt wurde
// (die Kennung liegt bei ihm und verfällt mit ihm), an die Methode, an den
// Pfad samt Parametern als Text, Zeichen für Zeichen, und an eine
// SHA-256-Summe über die Formularfelder in ihrer Reihenfolge ([felderSumme]).
// Die Felder stehen also schon bei der Freigabe fest: Gesendet wird nur, wozu
// die Zusammenfassung gehört, die die Lehrkraft gelesen hat. Die Kennung gilt
// einmal; jeder Versuch mit ihr verbraucht sie, auch einer, der nicht passt.
// Sie ist zufällig (32 Bytes) und steht in keinem Protokoll.
//
// Geprüft wird die Adresse und jedes Umleitungsziel, in dieser Reihenfolge:
// die für jedes Plugin gesperrten Bereiche (adressmuster.dart), die
// Normalform des Pfads, Dateien unter `pluginfile.php/<Kontext>/user/`
// (moodle_lesen.dart), dann: Passt der normalisierte Pfad zu einer
// Zusatzadresse dieses Plugins mit der Art „schreiben“, gilt die Sperrliste
// nicht, sonst gilt sie unverändert. Was auf keiner Liste steht, lehnt moocp
// ohne Dialog ab, bevor es fragt.
//
// Umleitungen nach dem POST (Moodle antwortet auf ein Formular meist mit
// einer): Gefolgt wird mit GET, ohne sesskey, wenn das Ziel eine
// Zusatzadresse dieses Plugins mit der Art „schreiben“ ist oder nach den
// Regeln für das Lesen über die Adresse der App lesbar ist (der lesende Teil
// der Positivliste, moodle_lesen.dart). Eine Zusatzadresse mit der Art
// „schreiben“ genügt, weil die Lehrkraft dem Plugin diese Seite als Teil
// seines Schreibvorgangs zugestimmt hat und Moodle nach dem Speichern meist
// genau dorthin zurückführt. Eine mit der Art „lesen“ genügt nicht: Lesen
// über eine Zusatzadresse gibt es nur in einem Lauf, in dem moocp den Kurs
// kennt und die Namen seiner Teilnehmenden für die letzte Sperre geladen hat
// (E36); außerhalb eines Laufs wird solch einem Ziel nicht gefolgt. Wird
// einer Umleitung nicht gefolgt, sagt die Antwort, dass der Schreibvorgang
// schon gesendet ist.
//
// Der sesskey: moocp setzt ihn als Formularfeld ein. Ein Plugin schickt ihn
// nie selbst mit, weder als Feld noch als Parameter ([istSesskey]); es
// bekommt ihn auch nicht gesondert.
//
// Protokoll (A4): Methode, Pfad bis zum Skriptnamen ([skriptAdresse]), die
// Namen der Parameter und der Status; nie Werte, nie Formularfelder, nie der
// Rest des Pfads hinter dem Skriptnamen. Pfad, Parameter- und Feldnamen gehen
// vorher durch die letzte Sperre (app_adresse.dart).
//
// Zurücklesen und das Urteil `verified` (A3) sind Sache des Plugins: moocp
// kann den Inhalt fremder Formulare nicht beurteilen. Die Antwort an die KI
// kennzeichnet moocp deshalb ([zusatzKennzeichnung], laufende_plugins.dart).

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../moodle/moodle_zugang.dart';
import 'adressmuster.dart';
import 'beschreibung.dart';
import 'klartext.dart';
import 'moodle_lesen.dart';

/// Höchstens so viele Formularfelder je Schreibvorgang; ein Formular von
/// Moodle hat weit weniger.
const felderHoechstens = 1000;

/// Höchstlänge eines Feldnamens in Zeichen.
const feldnameHoechstens = 200;

/// Ein Feldname: sichtbare ASCII-Zeichen ohne Leerraum. So liest PHP den
/// Namen so, wie er hier steht; Leerzeichen, Punkte und Klammern deutet PHP
/// sonst um, und ein Name hinter Leerraum könnte doch `sesskey` sein.
final RegExp _feldname = RegExp(r'^[\x21-\x7e]+$');

/// Ob [name] eines Formularfelds oder Parameters der sesskey ist, so wie PHP
/// ihn liest: Prozentkodierung aufgelöst, Leerraum am Rand weg, ohne Rücksicht
/// auf Groß- und Kleinschreibung, auch als Feld einer Liste (`sesskey[]`).
bool istSesskey(String name) =>
    prozentAufgeloest(name.replaceAll('+', ' ')).trim().toLowerCase().split('[').first == 'sesskey';

/// Die Namen der Parameter in der Adresse, wie sie gesendet werden.
Iterable<String> parameterNamen(Uri uri) =>
    uri.hasQuery ? uri.query.split('&').map((t) => t.split('=').first) : const <String>[];

/// Die Formularfelder, wie ein Plugin sie nennt: eine Liste von Objekten
/// `{"name": …, "wert": …}`, beides Text, in der Reihenfolge, in der sie
/// gesendet werden; fehlt die Liste, keine Felder. Wirft [FormatException]
/// mit dem Grund; der Grund nennt die Nummer des Felds, nie Name oder Wert.
Felder felderAusJson(Object? json) {
  if (json == null) return const [];
  const form = 'felder ist eine Liste von Objekten mit „name“ und „wert“, beides Text.';
  if (json is! List) throw const FormatException(form);
  if (json.length > felderHoechstens) {
    throw const FormatException('Zu viele Formularfelder: höchstens $felderHoechstens.');
  }
  final felder = <MapEntry<String, String>>[];
  for (final (i, e) in json.indexed) {
    final nr = i + 1;
    if (e is! Map || e['name'] is! String || e['wert'] is! String) {
      throw FormatException('Feld Nr. $nr: $form');
    }
    final name = e['name'] as String;
    if (name.length > feldnameHoechstens || !_feldname.hasMatch(name)) {
      throw FormatException(
        'Feld Nr. $nr: Der Name besteht aus 1 bis $feldnameHoechstens sichtbaren ASCII-Zeichen ohne Leerraum.',
      );
    }
    if (istSesskey(name)) {
      throw FormatException('Feld Nr. $nr heißt sesskey. Den setzt moocp selbst ein; ein Plugin schickt ihn nie mit.');
    }
    felder.add(MapEntry(name, e['wert'] as String));
  }
  return felder;
}

/// Die Summe, an die eine Freigabe die Formularfelder bindet: SHA-256 über
/// Namen und Werte in ihrer Reihenfolge, als 64 Hexziffern. Die Reihenfolge
/// zählt mit, weil sie bei Feldern mit gleichem Namen (`tags[]`) die Bedeutung
/// trägt.
String felderSumme(Felder felder) =>
    sha256.convert(utf8.encode(jsonEncode([for (final f in felder) [f.key, f.value]]))).toString();

/// Der Pfad bis zum Skriptnamen: bis zum ersten Abschnitt, der auf „.php“
/// endet (auch prozentkodiert); was danach steht, fällt weg. Hinter dem
/// Skriptnamen stehen bei Moodle Dateinamen und Nummern (`pluginfile.php/…`).
/// Ohne „.php“ der ganze Pfad. Der Pfad bleibt, wie er gesendet wird,
/// prozentkodiert; so kommen keine Steuerzeichen ins Protokoll.
String skriptPfad(Uri uri) {
  final teile = <String>[];
  for (final t in uri.path.split('/')) {
    teile.add(t);
    if (prozentAufgeloest(t).toLowerCase().endsWith('.php')) break;
  }
  return teile.join('/');
}

/// Die Adresse für das Protokoll und den Dialog: [skriptPfad] und die Namen
/// der Parameter, nie ihre Werte (`/mod/x/speichern.php?id=…&seite=…`).
String skriptAdresse(Uri uri) {
  final pfad = skriptPfad(uri);
  if (!uri.hasQuery) return pfad;
  return '$pfad?${parameterNamen(uri).map((n) => '$n=…').join('&')}';
}

/// Die erste Zusatzadresse aus [liste] mit der Art [art], zu der der
/// normalisierte Pfad von [uri] passt; sonst null.
Zusatzadresse? zusatzadresseFuer(List<Zusatzadresse> liste, Uri uri, ZugriffsArt art) {
  final pfad = pfadNormalisieren(uri.path);
  for (final z in liste) {
    if (z.art == art && z.muster.passt(pfad)) return z;
  }
  return null;
}

/// Was der Freigabedialog außer Titel und Zusammenfassung des Plugins zeigt:
/// die Adresse ohne Werte, die Namen der Formularfelder und den Grund der
/// passenden Zusatzadresse aus der Beschreibungsdatei, dem die Lehrkraft mit
/// dem Plugin zugestimmt hat. Das Plugin als Aufrufer zeigt der Dialog selbst.
List<String> zusatzFreigabePunkte(Uri uri, Felder felder, Zusatzadresse zusatzadresse) => [
  'Schreibt in Moodle über eine Zusatzadresse des Plugins: POST ${skriptAdresse(uri)}',
  felder.isEmpty
      ? 'Formularfelder: keine'
      : 'Formularfelder (nur die Namen): ${einzeilig(felder.map((f) => f.key).toSet().join(', '), 600)}',
  'Grund dieser Zusatzadresse aus der Beschreibungsdatei, dem Sie bei der Zustimmung zum Plugin zugestimmt '
      'haben: ${einzeilig(zusatzadresse.grund, 300)}',
  'moocp prüft nicht, was das Plugin sendet, und liest nicht zurück; das tut das Plugin.',
];

/// Was moocp vor die Antwort eines Werkzeugs eines Plugins an die KI setzt,
/// wenn das Plugin in diesem Aufruf [anzahl] Schreibvorgänge über eine
/// Zusatzadresse gesendet hat (laufende_plugins.dart). Ein fester Satz ohne
/// Text des Plugins; er sagt, dass moocp nichts geprüft hat, und sieht nie wie
/// das `verified` der eingebauten Werkzeuge aus.
String zusatzKennzeichnung(String plugin, int anzahl) =>
    'Hinweis von moocp: Über eine Zusatzadresse des Plugins „$plugin“ hat moocp in diesem Aufruf '
    '${anzahl == 1 ? 'einen Schreibvorgang' : '$anzahl Schreibvorgänge'} an Moodle gesendet, mit Freigabe '
    'der Lehrkraft. Geprüft vom Plugin, nicht von moocp: Ob und was Moodle gespeichert hat, hat moocp nicht '
    'zurückgelesen. Es folgt die Antwort des Plugins.';

/// Ein Plugin, das über eine seiner Zusatzadressen schreibt, als Aufrufer des
/// Moodle-Zugangs: der freigegebene POST ([umleitung] false) oder das GET auf
/// ein Umleitungsziel danach ([umleitung] true). Regeln oben.
class ZusatzAufrufer extends PluginAufrufer {
  ZusatzAufrufer(super.zugang, super.name, this.zusatzadressen, {required this.umleitung});

  /// Alle Zusatzadressen des Plugins aus seinem zugestimmten Stand; wirksam
  /// sind hier nur die mit der Art „schreiben“.
  final List<Zusatzadresse> zusatzadressen;
  final bool umleitung;

  /// Die Zusatzadresse mit der Art „schreiben“, zu der [uri] passt.
  Zusatzadresse? zusatzadresse(Uri uri) => zusatzadresseFuer(zusatzadressen, uri, ZugriffsArt.schreiben);

  @override
  bool sperrlisteAufgehoben(Uri uri) => zusatzadresse(uri) != null;

  static bool _sesskeyInAdresse(Uri uri) => parameterNamen(uri).any(istSesskey);

  @override
  bool erlaubt(String methode, Uri uri, Felder? formular, String? rumpf, Anhang? anhang) {
    if (rumpf != null || anhang != null || _sesskeyInAdresse(uri)) return false;
    if (!umleitung) return methode == 'POST' && formular != null && zusatzadresse(uri) != null;
    return methode == 'GET' &&
        formular == null &&
        (zusatzadresse(uri) != null || super.erlaubt(methode, uri, null, null, null));
  }

  /// Die Adresse, auf den Skriptnamen gekürzt: Damit nennen auch die Zeilen
  /// der Ablehnung den Rest des Pfads nicht.
  static Uri _gekuerzt(Uri uri) => uri.replace(path: skriptPfad(uri));

  @override
  String pfadImProtokoll(Uri uri) => skriptPfad(uri);

  @override
  String anfragezeile(String methode, Uri uri, Anhang? anhang) => zusatzadresse(uri) != null
      ? '$name, Zusatzadresse: $methode ${skriptAdresse(uri)}'
      : super.anfragezeile(methode, uri, anhang);

  @override
  String sperrzeile(String methode, Uri uri, String regel) => super.sperrzeile(methode, _gekuerzt(uri), regel);

  @override
  String ablehnzeile(String methode, Uri uri, Felder? formular) =>
      super.ablehnzeile(methode, _gekuerzt(uri), formular);

  @override
  String ablehnmeldung(String methode, Uri uri) {
    if (umleitung) return super.ablehnmeldung(methode, uri);
    if (_sesskeyInAdresse(uri)) {
      return 'Abgelehnt: Die Adresse trägt den Parameter sesskey. Den setzt moocp selbst ein; ein Plugin schickt '
          'ihn nie mit.';
    }
    if (zusatzadresseFuer(zusatzadressen, uri, ZugriffsArt.lesen) != null) {
      return 'Abgelehnt: ${uri.path} ist eine Zusatzadresse dieses Plugins mit der Art „lesen“. Geschrieben wird '
          'nur über eine Zusatzadresse mit der Art „schreiben“.';
    }
    return 'Abgelehnt: ${uri.path} ist keine Zusatzadresse dieses Plugins mit der Art „schreiben“. Über die '
        'Adresse der App schreibt ein Plugin nur dorthin, mit Freigabe der Lehrkraft; was die Positivliste von '
        'moocp erlaubt, ändert es über die eingebauten Werkzeuge (/v1/werkzeug).';
  }
}
