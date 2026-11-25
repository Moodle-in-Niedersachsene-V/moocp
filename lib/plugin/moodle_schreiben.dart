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
//     und gibt bei Freigabe eine Kennung zurück. Einzige Ausnahme ist der
//     Testbetrieb (E35): in einem Lauf, dessen Kurs ein gebundener Testkurs
//     ist und zu dem die Adresse passt (app_adresse.dart, McpDienst).
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
// genau dorthin zurückführt. Eine mit der Art „lesen“ genügt nur in einem
// Lauf (lauf.dart), in dem moocp den Kurs kennt und die Namen seiner
// Teilnehmenden für die Datenschutzprüfung geladen hat (E36), und nur, wenn das
// Ziel zu Kurs und Aktivität des Laufs passt; außerhalb eines Laufs wird
// solch einem Ziel nicht gefolgt. Wird einer Umleitung nicht gefolgt, sagt
// die Antwort, dass der Schreibvorgang schon gesendet ist.
//
// Den Inhalt der Antwort (die Seite nach dem POST oder das Ziel der
// Umleitung) bekommt das Plugin nur in einem Lauf und nur, wenn diese Seite
// zu Kurs und Aktivität des Laufs passt (laufBindungVerletzt, beim POST mit
// den Formularfeldern): Hinter einer Zusatzadresse ist mit Namen zu rechnen,
// und nur im Lauf stehen die Namen des Kurses in der Datenschutzprüfung. Sonst
// bekommt es nur Status und Pfad bis zum Skriptnamen ([inhaltNurImLauf]).
// Schreiben selbst geht auch ohne Lauf.
//
// Lesen über eine Zusatzadresse mit der Art „lesen“ ([ZusatzLeser]) gibt es
// nur in einem Lauf: mit GET, ohne sesskey, mit denselben Prüfungen wie oben
// und dazu der Bindung an Kurs und Aktivität des Laufs (laufBindungVerletzt)
// für die Adresse und jedes Umleitungsziel. Gefolgt wird einer Umleitung zu
// einer Zusatzadresse „lesen“ dieses Plugins oder zu einer Seite, die ein
// Plugin ohnehin lesen darf, beides nur, wenn sie zum Lauf passt.
//
// Der sesskey: moocp setzt ihn als Formularfeld ein. Ein Plugin schickt ihn
// nie selbst mit, weder als Feld noch als Parameter ([istSesskey]); es
// bekommt ihn auch nicht gesondert.
//
// Protokoll (A4): Methode, Pfad bis zum Skriptnamen ([skriptAdresse]), die
// Namen der Parameter und der Status; nie Werte, nie Formularfelder, nie der
// Rest des Pfads hinter dem Skriptnamen. Pfad, Parameter- und Feldnamen gehen
// vorher durch die Datenschutzprüfung (app_adresse.dart).
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
import 'lauf.dart';
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

/// Was das Plugin nach einem Schreibvorgang statt des Inhalts der Antwort
/// bekommt, wenn kein Lauf läuft oder die Seite nicht zu ihm passt
/// (app_adresse.dart): ein fester Satz ohne Werte.
const inhaltNurImLauf =
    'Geschrieben ist der Schreibvorgang; den Inhalt der Antwort liefert moocp nur in einem Lauf (/v1/moodle/lauf/beginnen '
    'mit der Nummer der Aktivität) und nur, wenn die Seite zu Kurs und Aktivität des Laufs passt. Hier stehen nur '
    'Status und Pfad bis zum Skriptnamen.';

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
/// [automatisch] davon hat der Testbetrieb freigegeben (E35); dann sagt der
/// Satz das statt „mit Freigabe der Lehrkraft“.
String zusatzKennzeichnung(String plugin, int anzahl, {int automatisch = 0}) {
  final freigabe = switch (automatisch) {
    <= 0 => 'mit Freigabe der Lehrkraft',
    _ when automatisch >= anzahl => 'im Debug-Testbetrieb automatisch freigegeben, ohne persönliche Freigabe der Lehrkraft',
    _ => 'davon $automatisch im Debug-Testbetrieb automatisch freigegeben, ohne persönliche Freigabe, die übrigen mit '
        'Freigabe der Lehrkraft',
  };
  return 'Hinweis von moocp: Über eine Zusatzadresse des Plugins „$plugin“ hat moocp in diesem Aufruf '
      '${anzahl == 1 ? 'einen Schreibvorgang' : '$anzahl Schreibvorgänge'} an Moodle gesendet, $freigabe. '
      'Geprüft vom Plugin, nicht von moocp: Ob und was Moodle gespeichert hat, hat moocp nicht zurückgelesen. '
      'Es folgt die Antwort des Plugins.';
}

/// Was moocp vor die Antwort eines Werkzeugs eines Plugins an die KI setzt,
/// wenn der Testbetrieb in diesem Aufruf [anzahl] Dialoge des Plugins aus
/// vorbereiteten Antworten beantwortet hat (testantworten.dart).
String testantwortenKennzeichnung(String plugin, int anzahl) =>
    'Hinweis von moocp: Debug-Testbetrieb: ${anzahl == 1 ? 'Einen Dialog' : '$anzahl Dialoge'} des Plugins „$plugin“ '
    'hat moocp in diesem Aufruf aus vorbereiteten Antworten beantwortet, ohne die Lehrkraft.';

/// Was moocp vor die Antwort eines Werkzeugs eines Plugins an die KI setzt,
/// wenn der Testbetrieb die Datenschutzwarnung zu ihr aus einer vorbereiteten
/// Antwort beantwortet hat (E20). Ein fester Satz ohne Wort und ohne Pfad.
String datenschutzAutomatischKennzeichnung(String plugin, {required bool gesendet}) =>
    'Hinweis von moocp: Debug-Testbetrieb: Die Datenschutzwarnung zu dieser Antwort des Plugins „$plugin“ '
    'hat moocp aus einer vorbereiteten Antwort beantwortet, ohne die Lehrkraft: '
    '${gesendet ? 'Die Antwort geht unverändert hinaus.' : 'Die Antwort ist gesperrt.'}';

/// Ein Plugin, das über eine seiner Zusatzadressen schreibt, als Aufrufer des
/// Moodle-Zugangs: der freigegebene POST ([umleitung] false) oder das GET auf
/// ein Umleitungsziel danach ([umleitung] true). Regeln oben.
class ZusatzAufrufer extends PluginAufrufer {
  ZusatzAufrufer(super.zugang, super.name, this.zusatzadressen, {required this.umleitung, this.lauf});

  /// Alle Zusatzadressen des Plugins aus seinem zugestimmten Stand; wirksam
  /// sind hier die mit der Art „schreiben“ und, nur bei einer Umleitung in
  /// einem Lauf, die mit der Art „lesen“.
  final List<Zusatzadresse> zusatzadressen;
  final bool umleitung;

  /// Der Lauf des Aufrufs, in dem geschrieben wird; null ohne Lauf.
  final Lauf? lauf;

  /// Die Zusatzadresse mit der Art „schreiben“, zu der [uri] passt.
  Zusatzadresse? zusatzadresse(Uri uri) => zusatzadresseFuer(zusatzadressen, uri, ZugriffsArt.schreiben);

  /// Die Zusatzadresse mit der Art „lesen“, zu der ein Umleitungsziel [uri]
  /// passt, nur in einem Lauf, der noch läuft; sonst null.
  Zusatzadresse? leseadresse(Uri uri) {
    final l = lauf;
    if (!umleitung || l == null || l.vorbei || zusatzadresse(uri) != null) return null;
    return zusatzadresseFuer(zusatzadressen, uri, ZugriffsArt.lesen);
  }

  @override
  bool sperrlisteAufgehoben(Uri uri) => zusatzadresse(uri) != null || leseadresse(uri) != null;

  /// Ein Umleitungsziel, das nur als Zusatzadresse „lesen“ erreichbar ist,
  /// muss zu Kurs und Aktivität des Laufs passen.
  @override
  String? zusatzpruefung(Uri uri) {
    if (leseadresse(uri) == null) return null;
    final grund = laufBindungVerletzt(lauf!, uri);
    return grund == null ? null : '${PluginAufrufer.regelLauf}$grund';
  }

  static bool _sesskeyInAdresse(Uri uri) => parameterNamen(uri).any(istSesskey);

  @override
  bool erlaubt(String methode, Uri uri, Felder? formular, String? rumpf, Anhang? anhang) {
    if (rumpf != null || anhang != null || _sesskeyInAdresse(uri)) return false;
    if (!umleitung) return methode == 'POST' && formular != null && zusatzadresse(uri) != null;
    return methode == 'GET' &&
        formular == null &&
        (zusatzadresse(uri) != null || leseadresse(uri) != null || super.erlaubt(methode, uri, null, null, null));
  }

  /// Die Adresse, auf den Skriptnamen gekürzt: Damit nennen auch die Zeilen
  /// der Ablehnung den Rest des Pfads nicht.
  static Uri _gekuerzt(Uri uri) => uri.replace(path: skriptPfad(uri));

  @override
  String pfadImProtokoll(Uri uri) => skriptPfad(uri);

  @override
  String anfragezeile(String methode, Uri uri, Anhang? anhang) =>
      zusatzadresse(uri) != null || leseadresse(uri) != null
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

/// Ein Plugin, das in einem Lauf über eine Zusatzadresse mit der Art „lesen“
/// liest (lauf.dart), als Aufrufer des Moodle-Zugangs: nur GET, ohne
/// sesskey; die Adresse und jedes Umleitungsziel müssen zu Kurs und Aktivität
/// des Laufs passen ([laufBindungVerletzt]) und eine Zusatzadresse „lesen“
/// dieses Plugins sein, für die die Sperrliste nicht gilt, oder nach den
/// Regeln für das Lesen über die Adresse der App lesbar sein. Dass die erste
/// Adresse eine Zusatzadresse „lesen“ ist, prüft app_adresse.dart vorher.
/// Endet der Lauf, lehnt der Aufrufer jede weitere Anfrage ab.
class ZusatzLeser extends PluginAufrufer {
  ZusatzLeser(super.zugang, super.name, this.zusatzadressen, this.lauf);

  final List<Zusatzadresse> zusatzadressen;
  final Lauf lauf;

  /// Die Zusatzadresse mit der Art „lesen“, zu der [uri] passt.
  Zusatzadresse? leseadresse(Uri uri) => zusatzadresseFuer(zusatzadressen, uri, ZugriffsArt.lesen);

  @override
  bool sperrlisteAufgehoben(Uri uri) => leseadresse(uri) != null;

  @override
  String? zusatzpruefung(Uri uri) {
    if (lauf.vorbei) return '${PluginAufrufer.regelLauf}Der Lauf ist beendet.';
    final grund = laufBindungVerletzt(lauf, uri);
    return grund == null ? null : '${PluginAufrufer.regelLauf}$grund';
  }

  @override
  bool erlaubt(String methode, Uri uri, Felder? formular, String? rumpf, Anhang? anhang) =>
      methode == 'GET' &&
      formular == null &&
      rumpf == null &&
      anhang == null &&
      !parameterNamen(uri).any(istSesskey) &&
      (leseadresse(uri) != null || super.erlaubt(methode, uri, null, null, null));

  static Uri _gekuerzt(Uri uri) => uri.replace(path: skriptPfad(uri));

  @override
  String pfadImProtokoll(Uri uri) => skriptPfad(uri);

  @override
  String anfragezeile(String methode, Uri uri, Anhang? anhang) => leseadresse(uri) != null
      ? '$name, Zusatzadresse: $methode ${skriptAdresse(uri)}'
      : super.anfragezeile(methode, uri, anhang);

  @override
  String sperrzeile(String methode, Uri uri, String regel) => regel.startsWith(PluginAufrufer.regelLauf)
      ? '$name: Im Lauf abgewiesen: $methode ${skriptAdresse(uri)} (passt nicht zum Lauf)'
      : super.sperrzeile(methode, _gekuerzt(uri), regel);

  @override
  String ablehnzeile(String methode, Uri uri, Felder? formular) =>
      super.ablehnzeile(methode, _gekuerzt(uri), formular);

  @override
  String ablehnmeldung(String methode, Uri uri) {
    if (methode != 'GET') return 'Abgelehnt: $methode. In einem Lauf liest ein Plugin über eine Zusatzadresse nur.';
    if (parameterNamen(uri).any(istSesskey)) {
      return 'Abgelehnt: Die Adresse trägt den Parameter sesskey; mit ihm löst eine Adresse in Moodle eine Aktion '
          'aus. Lesen geht ohne ihn.';
    }
    return super.ablehnmeldung(methode, uri);
  }
}
