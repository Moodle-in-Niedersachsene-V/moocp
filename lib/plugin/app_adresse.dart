// Die Adresse der App für Plugins (E35): ein eigener kleiner HTTP-Server auf
// 127.0.0.1, getrennt vom MCP-Server der KI-Werkzeuge, ein Server für alle
// Plugins und alle Instanzprofile. Hier erreicht ein Plugin, was die App ihm
// bietet; die Adresse geht beim initialize an das Plugin
// (verbindung.dart, vertragBeimInitialize).
//
// Form: JSON über POST, je Funktion ein Pfad unter einem versionierten
// Präfix; die Antwort ist JSON, ein Fehler hat einen HTTP-Status und das Feld
// `fehler` mit einem deutschen Satz, den die KI lesen kann. Kein zweiter
// MCP-Kanal: Was das Plugin hier tut, ist kein Werkzeug, sondern ein Dienst
// der App für die Dauer eines Aufrufs.
//
// Anmeldung: Jede Anfrage trägt `Authorization: Bearer <Schlüssel>`, den
// Schlüssel, mit dem sich die App beim Plugin anmeldet (laufende_plugins.dart,
// entwicklung.dart). Er bestimmt das Plugin; nach einem Neustart des Plugins
// gilt der neue, der alte nicht mehr. Verglichen wird in konstanter Zeit.
// Ohne gültigen Schlüssel kommt 401, ohne Auskunft, welche Pfade es gibt.
//
// Ein Plugin handelt nur, während die KI eines seiner Werkzeuge aufruft: Jede
// Anfrage außer der Protokollzeile braucht im Kopf `Moocp-Aufruf` das Token
// eines Aufrufs (`moocp/aufruf` aus `_meta`), der noch läuft, nicht
// abgebrochen ist und diesem Plugin gilt. Das Token wählt das Instanzprofil:
// dessen Protokoll, Arbeitsordner und eingebaute Werkzeuge. Ein Token im Kopf,
// das nicht (mehr) gilt, lehnt auch die Protokollzeile ab.
//
// Schlüssel und Token stehen in keinem Protokoll und in keiner Antwort.
// Zum Schutz gegen DNS-Rebinding gilt dieselbe Prüfung von Host und Origin wie
// beim MCP-Server (E6): Ein offener Port auf localhost ist auch für jede
// Webseite im Browser erreichbar, die es darauf anlegt.
//
// Dialoge und Freigaben: Ein Plugin öffnet keine Fenster. Es beschreibt
// einen Dialog (dialoge.dart) oder bittet um eine Freigabe, und moocp zeigt
// sie. Je Aufruf ist höchstens einer davon zugleich offen; ein zweiter wird
// abgewiesen, bis der erste beantwortet ist. Beide schließen sich, wenn der
// Aufruf endet oder der Client abbricht, und haben die Frist einer Freigabe.
// Ins Protokoll gehen Plugin, Art und Ausgang, nie die Werte, die die
// Lehrkraft eingibt oder wählt (A4, E11). Im Testbetrieb kann eine
// vorbereitete Antwort an die Stelle des Dialogs treten (testantworten.dart).
//
// Moodle: Ein Plugin liest Seiten und lädt Dateien über die App, mit der
// Sitzung des Profils des Aufrufs und nur in den Grenzen des lesenden Teils
// der Positivliste (moodle_lesen.dart). Was die Positivliste erlaubt, ändert
// es nur über die eingebauten Werkzeuge. Darüber hinaus schreibt es nur über
// eine seiner Zusatzadressen mit der Art „schreiben“, und nur mit einer
// Freigabe der Lehrkraft auf jeder Stufe (moodle_schreiben.dart, zwei
// Schritte: Freigabe, dann Schreiben mit der Kennung). Über eine
// Zusatzadresse mit der Art „lesen“ liest es nur in einem Lauf (lauf.dart):
// Es beginnt ihn mit der Nummer einer Aktivität, die App ermittelt den Kurs,
// lädt die Namen seiner Teilnehmenden in die Datenschutzprüfung und bindet jede
// Anfrage des Laufs an Kurs und Aktivität. Was es dort herunterlädt, legt die
// App in den Ordner für Downloads (downloads.dart), nie in den Arbeitsordner;
// das Ende des Laufs löscht es. Die Antwort trägt nie Cookies oder
// Kopfzeilen von Moodle, nur Status, Inhaltstyp, den Pfad nach Umleitungen und
// den Inhalt, von einer Seite nur den Hauptbereich und nie den sesskey
// (moodle_lesen.dart, textFuerPlugin).
//
// Datenschutzprüfung (datenschutz.dart, E36): Ein Plugin nennt der App Namen
// zum Prüfen (/v1/namen), die App lädt beim Beginn eines Laufs die Namen der
// Teilnehmenden und, sobald sie ihn kennt, den Namen der angemeldeten
// Lehrkraft des Profils; von da an prüft sie bis zum Ende der App, was von
// diesem Plugin ins Protokoll ginge, gegen sie und gegen die Pfade, die nicht
// an die KI gehören (der Ordner für Downloads): Eine Protokollzeile des
// Plugins mit Treffer erscheint nur als gleichbleibender Platzhalter, ohne
// Rückfrage, und bleibt eine gewöhnliche Antwort (200). Anders der Name und die
// Argumente eines eingebauten Werkzeugs, das ein Plugin aufruft (beide stehen
// im Protokoll der Hülle), und Pfad, Parameternamen und Feldnamen einer
// Anfrage an Moodle: Sie lehnt die App bei einem Treffer ab, ohne Rückfrage,
// weil sie sonst unverändert im Protokoll stünden; dort steht nur, dass
// abgelehnt wurde. Was die App selbst schreibt (Dialog geöffnet, Ausgang einer
// Freigabe), prüft sie nicht: Darin steht kein Text des Plugins. Antworten an
// das Plugin prüft sie nicht, denn sie gehen nicht an die KI; was das Plugin
// daraus an die KI gibt, prüft laufende_plugins.dart und fragt dort die
// Lehrkraft (Datenschutzwarnung).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../freigabe.dart' show Bestaetigungen, testfreigabeHinweis;
import '../mcp/werkzeugquelle.dart';
import '../moodle/moodle_zugang.dart';
import '../moodle/sperrliste.dart' show adresseOhneWerte;
import '../moodle/wiederherstellung_regeln.dart' show archivGrenzeStandard;
import '../protokoll.dart';
import 'beschreibung.dart' show Zusatzadresse, ZugriffsArt;
import 'dialoge.dart';
import 'downloads.dart';
import 'klartext.dart';
import 'lauf.dart';
import 'moodle_lesen.dart';
import 'moodle_schreiben.dart';
import 'datenschutz.dart';
import 'namenssperre.dart' show Namenssperre, texteIn;
import 'testantworten.dart';

export 'klartext.dart' show einzeilig;

/// Der Kopf, in dem das Token des Aufrufs mitgeht.
const aufrufKopf = 'Moocp-Aufruf';

/// Die Funktionen der Adresse, je ein Pfad.
const pfadProtokoll = '/v1/protokoll';
const pfadArbeitsordner = '/v1/arbeitsordner';
const pfadWerkzeug = '/v1/werkzeug';
const pfadAuswahl = '/v1/dialog/auswahl';
const pfadEingabe = '/v1/dialog/eingabe';
const pfadPfadwahl = '/v1/dialog/pfad';
const pfadHinweis = '/v1/dialog/hinweis';
const pfadFreigabe = '/v1/freigabe';
const pfadMoodleLesen = '/v1/moodle/lesen';
const pfadMoodleDatei = '/v1/moodle/datei';
const pfadZusatzFreigabe = '/v1/moodle/zusatz/freigabe';
const pfadZusatzSchreiben = '/v1/moodle/zusatz/schreiben';
const pfadLaufBeginnen = '/v1/moodle/lauf/beginnen';
const pfadLaufBeenden = '/v1/moodle/lauf/beenden';
const pfadZusatzLesen = '/v1/moodle/zusatz/lesen';
const pfadZusatzDatei = '/v1/moodle/zusatz/datei';
const pfadNamen = '/v1/namen';

/// Höchstens so viele Namen nimmt /v1/namen in einer Anfrage: genug für alle
/// Teilnehmenden einer großen Schule auf einmal.
const namenJeAnfrageHoechstens = 5000;

/// Höchstlänge eines Namens in Zeichen: Ein Name ist kein Text.
const nameHoechstens = 200;

/// Höchstens so viele verschiedene Namen hält die App je Plugin, bis sie
/// endet. Sie liegen im Arbeitsspeicher; die Grenze hält ein Plugin davon ab,
/// ihn zu füllen, und reicht für viele Kurse.
const namenJePluginHoechstens = 100000;

/// Was statt einer Protokollzeile eines Plugins mit einem möglichen Namen oder
/// einem geschützten Pfad im Protokoll steht (E36). Immer derselbe Text: er
/// verrät weder Länge noch Anfang der Zeile.
const protokollPlatzhalterName = '[gesperrt: möglicher Name]';
const protokollPlatzhalterPfad = '[gesperrt: Pfad]';

/// So lang darf eine Protokollzeile eines Plugins höchstens werden; was
/// darüber hinausgeht, schneidet die App ab.
const protokollzeileHoechstens = 500;

class _Plugin {
  _Plugin(this.kurzname, this.name, this.schluessel, this.zusatzadressen);
  final String kurzname;
  final String name;

  /// Geheim: in keinem Protokoll und keiner Antwort.
  final List<int> schluessel;

  /// Die Zusatzadressen aus dem Stand, dem die Lehrkraft zugestimmt hat (beim
  /// Entwicklungs-Plugin: aus der Beschreibungsdatei, die der Dialog genannt
  /// hat). Sie gelten nur für dieses Plugin.
  final List<Zusatzadresse> zusatzadressen;

  /// Wie das Plugin in Protokoll und Freigabe als Aufrufer heißt.
  String get aufrufer => 'Plugin „$name“';
}

class _Aufruf {
  _Aufruf(this.kurzname, this.werkzeug, this.kontext, this.profil);
  final String kurzname;

  /// Die Kennung des Instanzprofils, über das der Aufruf kam; sie wählt den
  /// Ordner für Downloads (downloads.dart).
  final String profil;

  /// Das Werkzeug des Plugins, das die KI aufgerufen hat; für die Warnung
  /// der Datenschutzprüfung.
  final String werkzeug;
  final AufrufKontext kontext;

  /// Erfüllt sich, wenn der Aufruf endet oder abgebrochen wird; ab dann gilt
  /// das Token nicht mehr, und was das Plugin gerade über die Adresse tut,
  /// endet mit ihm.
  final _ende = Completer<void>();
  Future<void> get ende => _ende.future;
  bool get vorbei => _ende.isCompleted;

  void beenden() {
    if (!_ende.isCompleted) _ende.complete();
  }

  /// Ob gerade ein Dialog oder eine Freigabe dieses Aufrufs offen ist.
  bool dialogOffen = false;

  /// Die Freigaben zum Schreiben über eine Zusatzadresse, die die Lehrkraft
  /// in diesem Aufruf erteilt hat und die noch nicht benutzt sind, nach ihrer
  /// Kennung: woran sie gebunden sind (moodle_schreiben.dart). Sie verfallen
  /// mit dem Aufruf. Die Kennungen sind geheim wie das Token. [testlauf] ist
  /// bei einer automatischen Freigabe des Testbetriebs der Lauf, in dem sie
  /// erteilt wurde: Nur in ihm gilt sie.
  final kennungen = <String, ({String pfad, String summe, Lauf? testlauf})>{};

  /// Wie viele Schreibvorgänge über eine Zusatzadresse in diesem Aufruf an
  /// Moodle gesendet sind (auch solche, bei denen unklar ist, ob sie
  /// ankamen); für die Kennzeichnung der Antwort an die KI.
  int zusatzSchreibvorgaenge = 0;

  /// Wie viele davon der Testbetrieb automatisch freigegeben hat.
  int zusatzTestSchreibvorgaenge = 0;

  /// Wie viele Dialoge der Testbetrieb in diesem Aufruf aus vorbereiteten
  /// Antworten beantwortet hat (testantworten.dart).
  int testDialogantworten = 0;

  /// Der Lauf dieses Aufrufs (lauf.dart); null ohne. Höchstens einer
  /// zugleich; er endet spätestens mit dem Aufruf.
  Lauf? lauf;

  /// Ob gerade ein Lauf beginnt; ein zweiter Beginn wartet nicht, sondern
  /// wird abgewiesen.
  bool laufBeginnt = false;

  /// Der Lauf, wenn einer läuft; sonst null.
  Lauf? get laufend => switch (lauf) {
    final l? when !l.vorbei => l,
    _ => null,
  };
}

/// Ein angemeldeter Aufruf ([AppAdresse.aufrufAnmelden]): [ende] beendet
/// ihn, und er sagt, ob das Plugin darin über eine Zusatzadresse geschrieben
/// hat.
class AngemeldeterAufruf {
  AngemeldeterAufruf._(this.ende, this._aufruf);

  /// Der Aufruf ist fertig; sein Token und seine Kennungen gelten nicht mehr.
  final void Function() ende;
  final _Aufruf? _aufruf;

  /// Wie viele Schreibvorgänge das Plugin in diesem Aufruf über eine
  /// Zusatzadresse an Moodle gesendet hat.
  int get zusatzSchreibvorgaenge => _aufruf?.zusatzSchreibvorgaenge ?? 0;

  /// Wie viele davon der Testbetrieb automatisch freigegeben hat.
  int get zusatzTestSchreibvorgaenge => _aufruf?.zusatzTestSchreibvorgaenge ?? 0;

  /// Wie viele Dialoge des Plugins der Testbetrieb in diesem Aufruf aus
  /// vorbereiteten Antworten beantwortet hat.
  int get testDialogantworten => _aufruf?.testDialogantworten ?? 0;
}

/// Eine Antwort: Status und JSON.
typedef _Antwort = ({int status, Map<String, Object?> json});

_Antwort _fehler(int status, String text) => (status: status, json: {'fehler': text});

/// Eine geprüfte Anfrage zum Schreiben über eine Zusatzadresse.
typedef _Geprueft = ({Uri uri, Felder felder, Zusatzadresse zusatzadresse});

/// Die Adresse der App für Plugins: der Server, die angemeldeten Plugins mit
/// ihren Schlüsseln und die laufenden Aufrufe mit ihren Token.
class AppAdresse {
  AppAdresse._(this._server, this._protokoll, this.anfrageHoechstens, this._dialoge, this.pruefung, this._downloads);

  /// Öffnet den Server auf 127.0.0.1 mit einem freien Port. [protokoll] ist
  /// das Protokoll der App ohne Profilbezug: Dorthin geht eine Protokollzeile
  /// ohne Token. [anfrageHoechstens] begrenzt den Inhalt einer Anfrage in
  /// Bytes. [dialoge] zeigt die Dialoge der Plugins; ohne sie lehnt die
  /// Adresse jeden Dialog ab. [pruefung] hält die Namen der Datenschutzprüfung für
  /// die ganze App (laufende_plugins.dart); ohne Angabe eine eigene.
  /// [downloads] ist der Ordner für Downloads über Zusatzadressen; sein Pfad
  /// kommt in die Datenschutzprüfung. Ohne ihn gibt es keinen solchen Download.
  static Future<AppAdresse> starten(
    Protokoll protokoll, {
    int anfrageHoechstens = 1024 * 1024,
    PluginDialoge? dialoge,
    Datenschutzpruefung? pruefung,
    PluginDownloads? downloads,
  }) async {
    final s = pruefung ?? Datenschutzpruefung();
    for (final f in downloads?.pfadformen ?? const <String>{}) {
      s.pfadSperren(f);
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final a = AppAdresse._(server, protokoll, anfrageHoechstens, dialoge, s, downloads);
    server.listen(a._bearbeiten, onError: (Object _) {});
    protokoll.eintrag(Art.info, 'Adresse der App für Plugins: ${a.adresse}');
    return a;
  }

  final HttpServer _server;
  final Protokoll _protokoll;
  final int anfrageHoechstens;
  final PluginDialoge? _dialoge;
  final PluginDownloads? _downloads;

  /// Die Namen und Pfade der Datenschutzprüfung, je Plugin; sie bleiben, auch wenn sich ein
  /// Plugin mit neuem Schlüssel anmeldet.
  final Datenschutzpruefung pruefung;

  /// Die Adresse, wie sie beim initialize an das Plugin geht.
  Uri get adresse => Uri.parse('http://127.0.0.1:${_server.port}');

  /// Die angemeldeten Plugins nach Kurzname.
  final _plugins = <String, _Plugin>{};

  /// Die laufenden Aufrufe nach Token.
  final _aufrufe = <String, _Aufruf>{};

  bool _beendet = false;

  /// Meldet das Plugin [kurzname] mit seinem [schluessel] an, unter [name]
  /// für Protokoll und Freigabe, mit den [zusatzadressen] seines
  /// zugestimmten Stands. Ein früherer Schlüssel desselben Plugins gilt danach
  /// nicht mehr.
  void pluginAnmelden(
    String kurzname,
    String name,
    String schluessel, {
    List<Zusatzadresse> zusatzadressen = const [],
  }) {
    _plugins[kurzname] = _Plugin(kurzname, name, utf8.encode(schluessel), List.unmodifiable(zusatzadressen));
  }

  /// Meldet das Plugin [kurzname] ab, wenn [schluessel] noch der angemeldete
  /// ist: Sein Programm ist zu Ende. Ein schon neu angemeldeter Schlüssel
  /// bleibt.
  void pluginAbmelden(String kurzname, String schluessel) {
    final pl = _plugins[kurzname];
    if (pl != null && _gleich(pl.schluessel, utf8.encode(schluessel))) _plugins.remove(kurzname);
  }

  /// Meldet einen Aufruf des Plugins [kurzname] an: Sein Token gilt von nun
  /// an für dieses Plugin, bis [AngemeldeterAufruf.ende] gerufen wird (der
  /// Aufruf ist fertig) oder der Client abbricht. Ohne [WerkzeugAufruf.kontext]
  /// gilt das Token nie.
  AngemeldeterAufruf aufrufAnmelden(String kurzname, WerkzeugAufruf aufruf) {
    final kontext = aufruf.kontext;
    if (kontext == null || aufruf.token.isEmpty || _beendet) return AngemeldeterAufruf._(() {}, null);
    final a = _Aufruf(kurzname, aufruf.name, kontext, aufruf.profil.kennung);
    _aufrufe[aufruf.token] = a;
    _lehrkraftSperren(kurzname, a);
    void ende() {
      a.beenden();
      a.lauf?.beenden();
      a.kennungen.clear();
      if (identical(_aufrufe[aufruf.token], a)) _aufrufe.remove(aufruf.token);
    }

    unawaited(aufruf.abbruch.then((_) => ende()));
    return AngemeldeterAufruf._(ende, a);
  }

  /// Schließt den Server; jedes Token und jeder Schlüssel gilt danach nicht
  /// mehr.
  Future<void> beenden() async {
    if (_beendet) return;
    _beendet = true;
    for (final a in _aufrufe.values) {
      a.beenden();
      a.lauf?.beenden();
      a.kennungen.clear();
    }
    _aufrufe.clear();
    _plugins.clear();
    await _server.close(force: true);
  }

  Future<void> _bearbeiten(HttpRequest r) async {
    _Antwort antwort;
    try {
      antwort = await _antwort(r);
    } catch (x) {
      // Nur der Typ (E11): Der Text eines Fehlers könnte Inhalte tragen.
      _protokoll.eintrag(Art.fehler, 'Adresse der App für Plugins: unerwarteter Fehler (${x.runtimeType})');
      antwort = _fehler(500, 'Unerwarteter Fehler in moocp.');
    }
    try {
      final res = r.response
        ..statusCode = antwort.status
        ..headers.contentType = ContentType.json
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (antwort.status == HttpStatus.unauthorized) {
        res.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
      }
      res.write(jsonEncode(antwort.json));
      await res.close();
    } catch (_) {
      // Das Plugin wartet nicht mehr auf die Antwort.
    }
  }

  Future<_Antwort> _antwort(HttpRequest r) async {
    if (!_hostErlaubt(r)) {
      _protokoll.eintrag(Art.gesperrt, 'Anfrage an die Adresse der App für Plugins abgewiesen (Host oder Origin)');
      r.response.persistentConnection = false;
      return _fehler(HttpStatus.forbidden, 'Abgewiesen: Host oder Origin ist nicht erlaubt.');
    }
    final plugin = _pluginAus(r);
    if (plugin == null) {
      _protokoll.eintrag(Art.gesperrt, 'Anfrage an die Adresse der App für Plugins ohne gültigen Schlüssel abgewiesen');
      r.response.persistentConnection = false;
      return _fehler(HttpStatus.unauthorized, 'Nicht angemeldet.');
    }
    final funktion = _funktionen[r.uri.path];
    if (funktion == null) {
      r.response.persistentConnection = false;
      return _fehler(HttpStatus.notFound, 'Diese Funktion gibt es nicht.');
    }
    if (r.method != 'POST') {
      r.response.persistentConnection = false;
      return _fehler(HttpStatus.methodNotAllowed, 'Nur POST.');
    }
    final daten = await _inhalt(r);
    if (daten case final _Antwort fehler) return fehler;
    final (token: token, aufruf: aufruf) = _aufrufAus(r, plugin);
    if (token != null && aufruf == null || token == null && funktion.mitAufruf) {
      _protokoll.eintrag(
        Art.gesperrt,
        '${plugin.aufrufer}: Anfrage an ${r.uri.path} ohne gültiges Aufruf-Token abgewiesen',
      );
      return _fehler(
        HttpStatus.forbidden,
        token == null
            ? 'Diese Funktion braucht im Kopf $aufrufKopf das Token des Aufrufs (moocp/aufruf aus _meta).'
            : 'Das Token gehört zu keinem laufenden Aufruf dieses Plugins; es gilt nur, solange der Aufruf '
                  'läuft und nicht abgebrochen ist.',
      );
    }
    return funktion.ausfuehren(this, plugin, aufruf, daten as Map<String, Object?>);
  }

  static const _erlaubteHosts = {'127.0.0.1', 'localhost'};

  /// Host und Origin wie beim MCP-Server (mcp_dart, allowedHosts): Der Host
  /// muss 127.0.0.1 oder localhost heißen; ein Origin, wenn es einen gibt,
  /// ebenso, und „null“ nie.
  static bool _hostErlaubt(HttpRequest r) {
    final host = r.headers.value(HttpHeaders.hostHeader)?.trim().toLowerCase();
    if (host == null || host.isEmpty) return false;
    final i = host.indexOf(':');
    final name = i >= 0 && i == host.lastIndexOf(':') ? host.substring(0, i) : host;
    if (!_erlaubteHosts.contains(name)) return false;
    final origin = r.headers.value('origin')?.trim();
    if (origin == null || origin.isEmpty) return true;
    if (origin.toLowerCase() == 'null') return false;
    final u = Uri.tryParse(origin);
    return u != null && u.host.isNotEmpty && _erlaubteHosts.contains(u.host.toLowerCase());
  }

  /// Das Plugin zum Schlüssel im Kopf; null ohne Schlüssel oder mit einem,
  /// den die App nicht kennt. Jeder angemeldete Schlüssel wird ganz
  /// verglichen, ohne früh abzubrechen.
  _Plugin? _pluginAus(HttpRequest r) {
    final kopf = r.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (!kopf.startsWith('Bearer ')) return null;
    final schluessel = utf8.encode(kopf.substring('Bearer '.length));
    if (schluessel.isEmpty) return null;
    _Plugin? treffer;
    for (final pl in _plugins.values) {
      if (_gleich(pl.schluessel, schluessel)) treffer = pl;
    }
    return treffer;
  }

  /// Das Token im Kopf und der Aufruf, für den es gilt: nur ein laufender,
  /// nicht abgebrochener Aufruf dieses Plugins.
  ({String? token, _Aufruf? aufruf}) _aufrufAus(HttpRequest r, _Plugin plugin) {
    final token = r.headers.value(aufrufKopf)?.trim();
    if (token == null || token.isEmpty) return (token: null, aufruf: null);
    final a = _aufrufe[token];
    return (token: token, aufruf: a != null && !a.vorbei && a.kurzname == plugin.kurzname ? a : null);
  }

  /// Der Inhalt der Anfrage als JSON-Objekt, höchstens [anfrageHoechstens]
  /// Bytes; ein leerer Inhalt gilt als `{}`. Sonst die Antwort mit dem Fehler.
  ///
  /// Wird die Grenze überschritten, auch ohne Längenangabe im Kopf (chunked),
  /// hört die App sofort auf zu lesen und antwortet mit 413; die Verbindung
  /// schließt sie danach (dart:io verwirft eine Verbindung, deren Inhalt nicht
  /// zu Ende gelesen ist). So kann ein Plugin sie nicht mit einem Inhalt ohne
  /// Ende beschäftigen. Angehalten wird das Lesen, nicht abgebrochen: Ein
  /// Abbruch schlösse die Verbindung, bevor die Antwort hinausgeht.
  Future<Object> _inhalt(HttpRequest r) async {
    if (r.contentLength > anfrageHoechstens) {
      r.response.persistentConnection = false;
      return _zuGross();
    }
    final bytes = BytesBuilder(copy: false);
    final fertig = Completer<bool>();
    late final StreamSubscription<List<int>> abo;
    abo = r.listen(
      (teil) {
        if (fertig.isCompleted) return;
        if (bytes.length + teil.length > anfrageHoechstens) {
          bytes.clear();
          abo.pause();
          fertig.complete(false);
          return;
        }
        bytes.add(teil);
      },
      onDone: () {
        if (!fertig.isCompleted) fertig.complete(true);
      },
      onError: (Object x) {
        if (!fertig.isCompleted) fertig.completeError(x);
      },
      cancelOnError: true,
    );
    if (!await fertig.future) {
      r.response.persistentConnection = false;
      return _zuGross();
    }
    if (bytes.isEmpty) return <String, Object?>{};
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      return _fehler(HttpStatus.badRequest, 'Der Inhalt der Anfrage ist kein gültiges JSON in UTF-8.');
    }
    if (json is! Map<String, Object?>) {
      return _fehler(HttpStatus.badRequest, 'Der Inhalt der Anfrage muss ein JSON-Objekt sein.');
    }
    return json;
  }

  _Antwort _zuGross() =>
      _fehler(HttpStatus.requestEntityTooLarge, 'Die Anfrage ist größer als $anfrageHoechstens Bytes.');

  /// Jede Protokollzeile, die mit dem Namen eines Plugins beginnt, geht hier
  /// durch, mit und ohne Token. Den Text, den das Plugin selbst schreibt,
  /// prüft [_protokollSchreiben] vorher gegen die Datenschutzprüfung; was die App
  /// hier selbst schreibt, trägt keinen Text des Plugins.
  void _protokollzeile(_Plugin plugin, Protokoll ziel, String zeile) {
    ziel.eintrag(Art.info, '${plugin.aufrufer}: $zeile');
  }

  /// Der Name der angemeldeten Lehrkraft des Profils des Aufrufs kommt in die
  /// Namen der Datenschutzprüfung dieses Plugins (E36), sobald die App ihn kennt
  /// (MoodleZugang.lehrkraftNamen): beim Anmelden eines Aufrufs, vor jeder
  /// Prüfung und nach jeder Anfrage an Moodle. Nur im Arbeitsspeicher, wie
  /// alle Namen der Prüfung. Kennt die App ihn nicht, bleibt es dabei, dass ein
  /// Plugin von einer Seite nur den Hauptbereich bekommt.
  void _lehrkraftSperren(String kurzname, _Aufruf aufruf) {
    final namen = aufruf.kontext.moodle.lehrkraftNamen;
    if (namen.isNotEmpty) pruefung.namenHinzufuegen(kurzname, namen, herkunft: Herkunft.lehrkraft);
  }

  /// Prüft [texte] des Plugins gegen seine Namen und Pfade (E36), wo ein
  /// Treffer nicht an die Lehrkraft gehen kann, weil der Text gleich ins
  /// Protokoll käme (Aufruf eines eingebauten Werkzeugs, Anfrage an Moodle).
  /// Bei einem Treffer steht im Protokoll [ziel], was abgelehnt ist, mit
  /// Plugin und Werkzeug, nie das Wort oder ein Auszug. Liefert true, wenn
  /// abgelehnt ist.
  bool _gesperrt(_Plugin plugin, _Aufruf? aufruf, Iterable<String> texte, String was, Protokoll ziel) {
    if (aufruf != null) _lehrkraftSperren(plugin.kurzname, aufruf);
    final t = pruefung.trifft(plugin.kurzname, texte);
    if (!t.name && !t.pfad) return false;
    ziel.eintrag(
      Art.gesperrt,
      '${plugin.aufrufer}${aufruf == null ? '' : ', Werkzeug ${aufruf.werkzeug}'}: '
      '$was abgelehnt (Datenschutzsperre: könnte personenbezogene Daten enthalten)',
    );
    return true;
  }

  static final _funktionen = <String, _Funktion>{
    pfadProtokoll: const _Funktion(mitAufruf: false, ausfuehren: _protokollSchreiben),
    pfadArbeitsordner: const _Funktion(mitAufruf: true, ausfuehren: _arbeitsordnerGeben),
    pfadWerkzeug: const _Funktion(mitAufruf: true, ausfuehren: _werkzeugAufrufen),
    for (final (pfad, art) in [
      (pfadAuswahl, PluginDialogArt.auswahl),
      (pfadEingabe, PluginDialogArt.eingabe),
      (pfadPfadwahl, PluginDialogArt.pfad),
      (pfadHinweis, PluginDialogArt.hinweis),
    ])
      pfad: _Funktion(mitAufruf: true, ausfuehren: (a, pl, au, d) => _dialogZeigen(art, a, pl, au, d)),
    pfadFreigabe: const _Funktion(mitAufruf: true, ausfuehren: _freigabeAnfragen),
    pfadMoodleLesen: const _Funktion(mitAufruf: true, ausfuehren: _moodleLesen),
    pfadMoodleDatei: const _Funktion(mitAufruf: true, ausfuehren: _moodleDatei),
    pfadZusatzFreigabe: const _Funktion(mitAufruf: true, ausfuehren: _zusatzFreigabeAnfragen),
    pfadZusatzSchreiben: const _Funktion(mitAufruf: true, ausfuehren: _zusatzSchreiben),
    pfadLaufBeginnen: const _Funktion(mitAufruf: true, ausfuehren: _laufBeginnen),
    pfadLaufBeenden: const _Funktion(mitAufruf: true, ausfuehren: _laufBeenden),
    pfadZusatzLesen: const _Funktion(mitAufruf: true, ausfuehren: _zusatzLesen),
    pfadZusatzDatei: const _Funktion(mitAufruf: true, ausfuehren: _zusatzDatei),
    pfadNamen: const _Funktion(mitAufruf: true, ausfuehren: _namenSperren),
  };

  /// Die Antwort, wenn die Datenschutzsperre etwas abgelehnt hat, das gleich
  /// ins Protokoll käme: ohne das Wort. Das Plugin kennt seine Namen.
  static _Antwort _sperrAntwort(String was) => _fehler(
    HttpStatus.unprocessableEntity,
    'Gesperrt: $was enthält ein Wort, das ein Name sein könnte, den dieses Plugin genannt hat, '
    'oder den Pfad eines Ordners, den die KI nicht kennen soll (etwa den Ordner, in dem moocp die Downloads '
    'über Zusatzadressen ablegt). Nichts davon steht im Protokoll.',
  );

  /// `POST /v1/namen` `{"namen": ["…", …]}`: Namen, die die App von nun an
  /// für dieses Plugin sperrt, bis sie endet (namenssperre.dart): in jeder
  /// Antwort an die KI und jeder Protokollzeile dieses Plugins, über alle
  /// Instanzprofile. Für ein Plugin, das ohne Moodle mit Personen arbeitet.
  /// Namen lassen sich nur hinzufügen, nie entfernen oder abfragen. Grenzen:
  /// [namenJeAnfrageHoechstens] je Anfrage, [nameHoechstens] Zeichen je Name,
  /// [namenJePluginHoechstens] verschiedene Namen je Plugin; darüber lehnt die
  /// App die ganze Anfrage ab und nimmt keinen davon auf. Ein Name ohne
  /// Buchstaben und Ziffern sperrt nichts und ist ein Fehler. Antwort `{}`;
  /// ins Protokoll geht nur die Zahl, keine Fehlermeldung nennt einen Namen.
  static Future<_Antwort> _namenSperren(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final liste = daten['namen'];
    if (liste is! List || liste.isEmpty) {
      return _fehler(HttpStatus.badRequest, 'namen fehlt: eine Liste mit mindestens einem Namen als Text.');
    }
    if (liste.length > namenJeAnfrageHoechstens) {
      return _fehler(
        HttpStatus.requestEntityTooLarge,
        'Zu viele Namen: höchstens $namenJeAnfrageHoechstens je Anfrage; nichts aufgenommen.',
      );
    }
    final namen = <String>[];
    for (final (i, n) in liste.indexed) {
      final nr = i + 1;
      if (n is! String) return _fehler(HttpStatus.badRequest, 'Name Nr. $nr ist kein Text; nichts aufgenommen.');
      if (n.length > nameHoechstens) {
        return _fehler(
          HttpStatus.badRequest,
          'Name Nr. $nr ist länger als $nameHoechstens Zeichen; nichts aufgenommen.',
        );
      }
      if (!Namenssperre.hatTeile(n)) {
        return _fehler(
          HttpStatus.badRequest,
          'Name Nr. $nr enthält keinen Buchstaben und keine Ziffer; nichts aufgenommen.',
        );
      }
      namen.add(n);
    }
    final neu = Namenssperre()..hinzufuegen(namen);
    if (a.pruefung.anzahl(plugin.kurzname) + neu.anzahl > namenJePluginHoechstens) {
      return _fehler(
        HttpStatus.requestEntityTooLarge,
        'Zu viele Namen: Je Plugin hält moocp höchstens $namenJePluginHoechstens verschiedene; nichts aufgenommen.',
      );
    }
    a.pruefung.namenHinzufuegen(plugin.kurzname, namen);
    aufruf!.kontext.protokoll.eintrag(
      Art.info,
      '${plugin.aufrufer}: ${namen.length} ${namen.length == 1 ? 'Name' : 'Namen'} zum Sperren genannt',
    );
    return (status: HttpStatus.ok, json: <String, Object?>{});
  }

  /// Moodle braucht die Anmeldung, und das Profil ist nicht angemeldet
  /// (praktisch: nach einem Abmelden, denn vorher läuft kein MCP-Server und
  /// damit kein Aufruf, E13): 503 mit dem Satz, den dann auch die eingebauten
  /// Werkzeuge melden ([NichtAngemeldet]) -- ein Wortlaut aus einer Quelle.
  /// Moodle wird dabei nicht gefragt, und angemeldet wird auch nicht (A2, E7).
  static _Antwort _nichtAngemeldet() => _fehler(HttpStatus.serviceUnavailable, NichtAngemeldet().meldung);

  static _Antwort _abgebrochen() => _fehler(
    HttpStatus.conflict,
    'Abgebrochen: Der Aufruf, zu dem das Token gehört, ist zu Ende oder abgebrochen.',
  );

  /// Ein Fehler des Moodle-Zugangs als Antwort: abgewiesen (403), nicht
  /// angemeldet (503), zu groß (413), sonst ein Fehler von Moodle oder der
  /// Verbindung (502). Die Meldungen nennen keine Parameterwerte.
  static _Antwort _moodleFehler(MoodleFehler x) => switch (x) {
    AnfrageGesperrt() => _fehler(HttpStatus.forbidden, x.meldung),
    NichtAngemeldet() => _nichtAngemeldet(),
    AntwortZuGross() => _fehler(
      HttpStatus.requestEntityTooLarge,
      '${x.meldung} Größere Inhalte über $pfadMoodleDatei in den Ordner des Plugins laden.',
    ),
    DownloadZuGross() => _fehler(HttpStatus.requestEntityTooLarge, x.meldung),
    _ => _fehler(HttpStatus.badGateway, x.meldung),
  };

  /// Prüft `pfad` und `methode` einer Anfrage an Moodle und liefert die
  /// Adresse an der Instanz; sonst die Antwort mit dem Fehler. Eine andere
  /// Methode als GET lehnt die App ab, bevor sie etwas fragt: Ein Plugin liest
  /// hier nur.
  static Object _moodleAdresse(AppAdresse a, _Plugin plugin, _Aufruf aufruf, Map<String, Object?> daten) {
    final moodle = aufruf.kontext.moodle;
    final basis = moodle.basis;
    if (!moodle.angemeldet || basis == null) return _nichtAngemeldet();
    final Uri uri;
    try {
      uri = pluginAdresse(basis, daten['pfad']);
    } on FormatException catch (x) {
      aufruf.kontext.protokoll.eintrag(Art.gesperrt, '${plugin.aufrufer}: Anfrage an Moodle abgewiesen (Pfad ungültig)');
      return _fehler(HttpStatus.badRequest, x.message);
    }
    // Pfad und Parameternamen stehen gleich im Protokoll: Sie kommen vom
    // Plugin und gehen durch die Datenschutzprüfung, roh und dekodiert.
    final namen = uri.hasQuery ? uri.query.split('&').map((t) => t.split('=').first) : const <String>[];
    if (a._gesperrt(
      plugin,
      aufruf,
      [uri.path, _dekodiert(uri.path), for (final n in namen) ...[n, _dekodiert(n)]],
      'Anfrage an Moodle',
      aufruf.kontext.protokoll,
    )) {
      return _sperrAntwort('Der Pfad');
    }
    final methode = daten['methode'] ?? 'GET';
    if (methode != 'GET') {
      // Nur bekannte Methoden ins Protokoll: Der Text kommt vom Plugin.
      final m = _methoden.contains(methode) ? methode as String : '?';
      aufruf.kontext.protokoll.eintrag(
        Art.gesperrt,
        '${plugin.aufrufer}: Gesperrt: $m ${adresseOhneWerte(uri)} (nur Lesen)',
      );
      return _fehler(
        HttpStatus.methodNotAllowed,
        'Abgelehnt: Ein Plugin liest über die Adresse der App nur (GET). Ändern in Moodle geht über die '
        'eingebauten Werkzeuge ($pfadWerkzeug), mit Freigabe, Namensprüfung und Rücklesen.',
      );
    }
    return uri;
  }

  static const _methoden = {'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'};

  /// Prozentkodierung aufgelöst; was sich nicht auflösen lässt, bleibt roh.
  static String _dekodiert(String s) {
    try {
      return Uri.decodeComponent(s.replaceAll('+', ' '));
    } on ArgumentError {
      return s;
    } on FormatException {
      return s;
    }
  }

  /// `POST /v1/moodle/lesen` `{"pfad": "/…?…"}`: liest eine Seite oder Datei
  /// der Instanz des Profils des Aufrufs, mit dessen Sitzung, und folgt
  /// Umleitungen, jede geprüft wie die Adresse selbst. Antwort `{"status": …,
  /// "inhaltstyp": …, "pfad": …, "text": …}`: der Status von Moodle, der
  /// Inhaltstyp, der Pfad nach den Umleitungen (ohne Rechner) und der Inhalt
  /// als Text, höchstens [textHoechstens] Bytes: von einer HTML-Seite nur
  /// ihr Hauptbereich, aus jedem Text der sesskey entfernt
  /// (moodle_lesen.dart, [textFuerPlugin]); eine HTML-Seite ohne Hauptbereich
  /// gibt es nicht (502). Nie Cookies oder andere Kopfzeilen von Moodle.
  /// Endet der äußere Aufruf, geht nichts mehr hinaus.
  static Future<_Antwort> _moodleLesen(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final adresse = _moodleAdresse(a, plugin, aufruf!, daten);
    if (adresse case final _Antwort fehler) return fehler;
    final moodle = aufruf.kontext.moodle;
    try {
      final r = await Future.any<Antwort?>([
        moodle.lesenAls(PluginAufrufer(moodle, plugin.aufrufer), adresse as Uri, hoechstens: textHoechstens),
        aufruf.ende.then((_) => null),
      ]);
      if (aufruf.vorbei || r == null) return _abgebrochen();
      return _seiteFuerPlugin(a, plugin, aufruf, r, zusatzadresse: false);
    } on MoodleFehler catch (x) {
      return aufruf.vorbei ? _abgebrochen() : _moodleFehler(x);
    }
  }

  /// Die Antwort mit einer gelesenen Seite: Status, Inhaltstyp, Pfad nach den
  /// Umleitungen und der Text, wie ihn ein Plugin bekommt ([textFuerPlugin]).
  /// Vorher kommt der Name der Lehrkraft in die Datenschutzprüfung, falls die App
  /// ihn gerade auf dieser Seite erst gefunden hat.
  static _Antwort _seiteFuerPlugin(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf aufruf,
    Antwort r, {
    required bool zusatzadresse,
  }) {
    a._lehrkraftSperren(plugin.kurzname, aufruf);
    final String text;
    try {
      text = textFuerPlugin(r, zusatzadresse: zusatzadresse, sesskeys: [aufruf.kontext.moodle.sesskeyBekannt]);
    } on KeinHauptbereich {
      aufruf.kontext.protokoll.eintrag(
        Art.gesperrt,
        '${plugin.aufrufer}: Seite nicht geliefert (kein Hauptbereich): GET ${skriptPfad(r.adresse)}',
      );
      return _fehler(HttpStatus.badGateway, KeinHauptbereich.meldung);
    }
    return (
      status: HttpStatus.ok,
      json: {
        'status': r.status,
        'inhaltstyp': r.inhaltstyp,
        'pfad': '${r.adresse.path}${MoodleZugang.querySicher(r.adresse)}',
        'text': text,
      },
    );
  }

  /// `POST /v1/moodle/datei` `{"pfad": "/…", "dateiname": …}`: lädt eine
  /// Datei der Instanz in den Unterordner des Plugins im Arbeitsordner des
  /// Profils (`plugin-<Kurzname>`, wie /v1/arbeitsordner), mit denselben
  /// Prüfungen wie /v1/moodle/lesen und den Grenzen des Downloads der
  /// eingebauten Werkzeuge (Größe, keine Seite statt einer Datei, keine
  /// Umleitung). `dateiname` ist optional, sonst der letzte Teil des Pfads.
  /// Eine vorhandene Datei wird nie überschrieben. Antwort `{"datei": …,
  /// "bytes": …}`. Endet der äußere Aufruf, bricht das Laden ab, und es bleibt
  /// keine Datei liegen.
  static Future<_Antwort> _moodleDatei(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final adresse = _moodleAdresse(a, plugin, aufruf!, daten);
    if (adresse case final _Antwort fehler) return fehler;
    final uri = adresse as Uri;
    final name = _dateiname(daten['dateiname'], uri);
    if (name == null) {
      return _fehler(
        HttpStatus.badRequest,
        'dateiname ist ein einfacher Dateiname ohne Ordner, ohne Steuerzeichen und ohne \\ / : * ? " < > |, '
        'höchstens 120 Zeichen, nicht mit „.“ am Anfang.',
      );
    }
    final ordner = p.normalize(p.absolute(aufruf.kontext.arbeitsordner, 'plugin-${plugin.kurzname}'));
    final ziel = File(p.join(ordner, name));
    if (!p.isWithin(ordner, ziel.path)) return _fehler(HttpStatus.badRequest, 'dateiname ist ungültig.');
    try {
      await Directory(ordner).create(recursive: true);
      if (await ziel.exists()) {
        return _fehler(HttpStatus.conflict, 'Die Datei $name liegt schon im Ordner des Plugins; nichts überschrieben.');
      }
    } on FileSystemException catch (x) {
      return _fehler(HttpStatus.internalServerError, 'Der Ordner $ordner ließ sich nicht anlegen (${x.runtimeType}).');
    }
    final moodle = aufruf.kontext.moodle;
    final laden = moodle.herunterladenAls(PluginAufrufer(moodle, plugin.aufrufer), uri, ziel, abbruch: aufruf.ende);
    // Wurde die Datei im selben Augenblick fertig, in dem der Aufruf endete,
    // bleibt sie nicht liegen.
    unawaited(
      laden.then(
        (_) async {
          if (aufruf.vorbei) await ziel.delete().then((_) {}, onError: (Object _) {});
        },
        onError: (Object _) {},
      ),
    );
    try {
      final bytes = await Future.any<int?>([laden, aufruf.ende.then((_) => null)]);
      if (aufruf.vorbei || bytes == null) return _abgebrochen();
      return (status: HttpStatus.ok, json: {'datei': ziel.path, 'bytes': bytes});
    } on MoodleFehler catch (x) {
      return aufruf.vorbei ? _abgebrochen() : _moodleFehler(x);
    }
  }

  /// Prüft eine Anfrage zum Schreiben über eine Zusatzadresse
  /// (moodle_schreiben.dart), für die Freigabe wie für das Schreiben, in
  /// dieser Reihenfolge: angemeldet, Methode, Pfad, Formularfelder, die
  /// Datenschutzprüfung gegen Pfad, Parameter- und Feldnamen (sie stehen im
  /// Protokoll und im Dialog), sesskey vom Plugin, dann die Adresse
  /// ([ZusatzAufrufer]). Liefert Adresse, Felder und die passende
  /// Zusatzadresse; sonst die Antwort mit dem Fehler. Moodle wird dabei nicht
  /// gefragt, und niemand sieht einen Dialog.
  static Object _zusatzPruefen(AppAdresse a, _Plugin plugin, _Aufruf aufruf, Map<String, Object?> daten) {
    final moodle = aufruf.kontext.moodle;
    final basis = moodle.basis;
    final protokoll = aufruf.kontext.protokoll;
    if (!moodle.angemeldet || basis == null) return _nichtAngemeldet();
    if (daten['methode'] != 'POST') {
      protokoll.eintrag(Art.gesperrt, '${plugin.aufrufer}: Schreiben über eine Zusatzadresse abgewiesen (Methode)');
      return _fehler(
        HttpStatus.methodNotAllowed,
        'methode ist „POST“: Über eine Zusatzadresse schreibt ein Plugin nur mit POST und Formularfeldern. '
        'Dateien hochladen geht nicht.',
      );
    }
    final Uri uri;
    final Felder felder;
    try {
      uri = pluginAdresse(basis, daten['pfad']);
      felder = felderAusJson(daten['felder']);
    } on FormatException catch (x) {
      protokoll.eintrag(Art.gesperrt, '${plugin.aufrufer}: Schreiben über eine Zusatzadresse abgewiesen (Anfrage ungültig)');
      return _fehler(HttpStatus.badRequest, x.message);
    }
    if (a._gesperrt(
      plugin,
      aufruf,
      [
        uri.path,
        _dekodiert(uri.path),
        for (final n in parameterNamen(uri)) ...[n, _dekodiert(n)],
        for (final f in felder) f.key,
      ],
      'Anfrage an Moodle',
      protokoll,
    )) {
      return _sperrAntwort('Der Pfad, ein Parametername oder ein Feldname');
    }
    final pruefer = ZusatzAufrufer(moodle, plugin.aufrufer, plugin.zusatzadressen, umleitung: false);
    final regel = pruefer.gesperrtDurch(uri);
    if (regel != null) {
      protokoll.eintrag(Art.gesperrt, pruefer.sperrzeile('POST', uri, regel));
      return _fehler(HttpStatus.forbidden, pruefer.sperrmeldung(uri, regel));
    }
    final zusatzadresse = pruefer.zusatzadresse(uri);
    if (zusatzadresse == null || !pruefer.erlaubt('POST', uri, felder, null, null)) {
      protokoll.eintrag(Art.gesperrt, pruefer.ablehnzeile('POST', uri, felder));
      return _fehler(HttpStatus.forbidden, pruefer.ablehnmeldung('POST', uri));
    }
    return (uri: uri, felder: felder, zusatzadresse: zusatzadresse);
  }

  /// `POST /v1/moodle/zusatz/freigabe` `{"methode": "POST", "pfad": "/…?…",
  /// "felder": [{"name": …, "wert": …}, …], "titel": …, "zusammenfassung":
  /// …}`: Schritt 1 eines Schreibvorgangs über eine Zusatzadresse
  /// (moodle_schreiben.dart). Was nicht erlaubt ist, lehnt die App ohne Dialog
  /// ab. Sonst fragt sie die Lehrkraft, auf jeder Stufe, mit dem Plugin als
  /// Aufrufer. Antwort `{"ausgang": "freigegeben", "kennung": …}` oder
  /// `{"ausgang": "abgelehnt" | "abgebrochen"}`. Die Kennung gilt einmal, nur
  /// in diesem Aufruf.
  ///
  /// Testbetrieb (E35): Läuft ein Lauf und passen die Adresse und die
  /// Formularfelder zu seinem Kurs und seiner Aktivität
  /// (laufBindungVerletzt), geht der Kurs des Laufs mit
  /// an die Freigabe; ist er ein gebundener Testkurs, gibt der Testbetrieb
  /// frei (McpDienst). Dann trägt die Antwort `"testbetrieb": true` und einen
  /// Hinweis, und die Kennung gilt nur in diesem Lauf. Außerhalb eines Laufs
  /// kennt die App den Kurs nicht, und es kommt der Dialog.
  static Future<_Antwort> _zusatzFreigabeAnfragen(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final geprueft = _zusatzPruefen(a, plugin, aufruf!, daten);
    if (geprueft case final _Antwort fehler) return fehler;
    final (:uri, :felder, :zusatzadresse) = geprueft as _Geprueft;
    final t = daten['titel'];
    final z = daten['zusammenfassung'];
    final titel = t is String ? einzeilig(t, dialogTitelHoechstens) : '';
    final zusammenfassung = z is String ? mehrzeilig(z, dialogTextHoechstens) : '';
    if (titel.isEmpty) return _fehler(HttpStatus.badRequest, 'titel fehlt: eine Zeile Text als Überschrift.');
    if (zusammenfassung.isEmpty) {
      return _fehler(HttpStatus.badRequest, 'zusammenfassung fehlt: was geschrieben werden soll, als Text.');
    }
    return _einzeln(a, plugin, aufruf, () async {
      // Nur ein Lauf, zu dem Adresse und Formularfelder passen, bringt den
      // Kurs mit, den die App selbst ermittelt hat; nur dann kann der
      // Testbetrieb freigeben. Die Felder zählen mit, weil Moodle sie vor den
      // Parametern der Adresse liest.
      final lauf = switch (aufruf.laufend) {
        final l? when laufBindungVerletzt(l, uri, felder: felder) == null => l,
        _ => null,
      };
      final ausgang = await aufruf.kontext.pluginFreigabe(
        titel: titel,
        zusammenfassung: zusammenfassung,
        // Auf jeder Stufe: Was hinter einer Zusatzadresse geschieht, kann
        // moocp nicht beurteilen (E36).
        ab: Bestaetigungen.keine,
        abbruch: aufruf.ende,
        aufrufer: plugin.aufrufer,
        punkte: zusatzFreigabePunkte(uri, felder, zusatzadresse),
        protokolltitel: 'Schreiben über eine Zusatzadresse eines Plugins',
        laufKurs: lauf?.kurs,
      );
      // Mit „ab: keine“ lässt keine Stufe die Frage aus. Käme doch
      // `ohneFrage`, gälte das nicht als Freigabe. Die automatische Freigabe
      // des Testbetriebs gilt nur, solange der Lauf läuft, in dem sie kam.
      final automatisch = ausgang == PluginFreigabeAusgang.automatisch && lauf != null && !lauf.vorbei;
      final erteilt = (ausgang == PluginFreigabeAusgang.freigegeben || automatisch) && !aufruf.vorbei;
      final (wort, ausgangText) = switch (ausgang) {
        _ when erteilt && automatisch => ('im Testbetrieb automatisch erteilt', 'freigegeben'),
        _ when erteilt => ('erteilt', 'freigegeben'),
        PluginFreigabeAusgang.abgelehnt => ('abgelehnt', 'abgelehnt'),
        _ => ('abgebrochen', 'abgebrochen'),
      };
      a._protokollzeile(
        plugin,
        aufruf.kontext.protokoll,
        'Freigabe zum Schreiben über eine Zusatzadresse (POST ${skriptAdresse(uri)}) -- $wort',
      );
      if (!erteilt) return (status: HttpStatus.ok, json: <String, Object?>{'ausgang': ausgangText});
      final kennung = aufrufToken();
      aufruf.kennungen[kennung] = (
        pfad: daten['pfad'] as String,
        summe: felderSumme(felder),
        testlauf: automatisch ? lauf : null,
      );
      return (
        status: HttpStatus.ok,
        json: <String, Object?>{
          'ausgang': ausgangText,
          'kennung': kennung,
          if (automatisch) ...{'testbetrieb': true, 'hinweis': testfreigabeHinweis},
        },
      );
    });
  }

  /// `POST /v1/moodle/zusatz/schreiben` `{"kennung": …, "methode": "POST",
  /// "pfad": "/…?…", "felder": [{"name": …, "wert": …}, …]}`: Schritt 2. Die
  /// Kennung muss zu einer Freigabe dieses Aufrufs gehören, und Methode, Pfad
  /// und Felder müssen genau dem entsprechen, was freigegeben ist; jeder
  /// Versuch verbraucht die Kennung. Ohne gültige Kennung sendet die App
  /// nichts, auf keiner Stufe. Gesendet wird mit der Sitzung des Profils, den
  /// sesskey setzt die App ein; einer Umleitung folgt sie nach den Regeln in
  /// moodle_schreiben.dart. Antwort `{"geschrieben": true, "status": …,
  /// "inhaltstyp": …, "pfad": …, "text": …}`, nie Cookies oder Kopfzeilen,
  /// mit Inhalt nur in einem Lauf, zu dem die Seite passt; sonst nur
  /// `status`, `pfad` bis zum Skriptnamen und `hinweis` ([inhaltNurImLauf]);
  /// dazu `umleitungNichtGelesen`, wenn einer Umleitung nicht gefolgt wurde,
  /// oder nur `{"geschrieben": true, "hinweis": …}`, wenn die Antwort zu groß
  /// war. Ein Fehler, nach dem nichts geschrieben ist: 403, 409, 502, 503;
  /// 502 auch, wenn unklar ist, ob der Schreibvorgang ankam (die Meldung sagt
  /// es). Wiederholt wird nichts, auch nicht nach einer Neuanmeldung.
  static Future<_Antwort> _zusatzSchreiben(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final protokoll = aufruf!.kontext.protokoll;
    final k = daten['kennung'];
    // Verbraucht, bevor irgendetwas anderes geprüft wird: Auch ein Versuch,
    // der nicht passt, kostet die Freigabe.
    final freigabe = k is String ? aufruf.kennungen.remove(k) : null;
    if (freigabe == null) {
      protokoll.eintrag(
        Art.gesperrt,
        '${plugin.aufrufer}: Schreiben über eine Zusatzadresse ohne gültige Freigabe abgewiesen',
      );
      return _fehler(
        HttpStatus.forbidden,
        'Abgelehnt: Ohne Freigabe der Lehrkraft schreibt moocp nicht über eine Zusatzadresse, auf keiner Stufe. '
        'Erst $pfadZusatzFreigabe; die Kennung daraus gilt einmal und nur in diesem Aufruf. Nichts gesendet.',
      );
    }
    final geprueft = _zusatzPruefen(a, plugin, aufruf, daten);
    if (geprueft case final _Antwort fehler) return fehler;
    final (:uri, :felder, zusatzadresse: _) = geprueft as _Geprueft;
    if (daten['pfad'] != freigabe.pfad || felderSumme(felder) != freigabe.summe) {
      protokoll.eintrag(
        Art.gesperrt,
        '${plugin.aufrufer}: Schreiben über eine Zusatzadresse abgewiesen: POST ${skriptAdresse(uri)} passt nicht '
        'zur Freigabe',
      );
      return _fehler(
        HttpStatus.forbidden,
        'Abgelehnt: Pfad, Parameter oder Formularfelder passen nicht zu dem, was die Lehrkraft freigegeben hat. '
        'Die Kennung ist verbraucht. Nichts gesendet.',
      );
    }
    final testlauf = freigabe.testlauf;
    if (testlauf != null && !identical(aufruf.laufend, testlauf)) {
      protokoll.eintrag(
        Art.gesperrt,
        '${plugin.aufrufer}: Schreiben über eine Zusatzadresse abgewiesen: Der Lauf der automatischen Freigabe '
        'des Testbetriebs ist zu Ende',
      );
      return _fehler(
        HttpStatus.forbidden,
        'Abgelehnt: Die automatische Freigabe des Testbetriebs galt nur in dem Lauf, in dem sie erteilt wurde, und '
        'der ist zu Ende. Die Kennung ist verbraucht. Nichts gesendet.',
      );
    }
    if (aufruf.vorbei) return _abgebrochen();
    final moodle = aufruf.kontext.moodle;
    final String sesskey;
    try {
      sesskey = await moodle.sesskey();
    } on MoodleFehler catch (x) {
      return aufruf.vorbei ? _abgebrochen() : _moodleFehler(x);
    }
    if (aufruf.vorbei) return _abgebrochen();
    final schreiber = ZusatzAufrufer(moodle, plugin.aufrufer, plugin.zusatzadressen, umleitung: false);
    // Ab hier gilt der Schreibvorgang als gesendet, bis feststeht, dass er
    // Moodle nicht erreicht hat.
    aufruf.zusatzSchreibvorgaenge++;
    if (testlauf != null) aufruf.zusatzTestSchreibvorgaenge++;
    const verbraucht = 'Die Freigabe ist verbraucht; ein neuer Versuch braucht eine neue.';
    _Antwort nichtGeschrieben(int status, String text) {
      aufruf.zusatzSchreibvorgaenge--;
      if (testlauf != null) aufruf.zusatzTestSchreibvorgaenge--;
      return _fehler(status, text);
    }

    final Antwort r;
    try {
      r = await moodle.sendenAls(schreiber, uri, [...felder, MapEntry('sesskey', sesskey)], hoechstens: textHoechstens);
    } on AntwortZuGross catch (x) {
      return _geschrieben(aufruf, {
        'hinweis': 'Geschrieben ist schon: Der Schreibvorgang ist gesendet, Moodle hat geantwortet. ${x.meldung}',
      });
    } on SitzungAbgelaufen {
      return nichtGeschrieben(
        HttpStatus.serviceUnavailable,
        'Nicht geschrieben: Die Sitzung war abgelaufen, Moodle hat auf die Anmeldung umgeleitet. moocp hat neu '
        'angemeldet und wiederholt nichts. $verbraucht',
      );
    } on SchutzPruefung catch (x) {
      return nichtGeschrieben(HttpStatus.badGateway, '${x.meldung} $verbraucht');
    } on AnfrageGesperrt catch (x) {
      return nichtGeschrieben(HttpStatus.forbidden, x.meldung);
    } on NichtAngemeldet catch (x) {
      return nichtGeschrieben(HttpStatus.serviceUnavailable, x.meldung);
    } on MoodleNichtErreichbar catch (x) {
      return _fehler(
        HttpStatus.badGateway,
        '${x.meldung} Ob der Schreibvorgang Moodle erreicht hat, ist unklar. moocp wiederholt ihn nicht; das Plugin '
        'prüft selbst nach. $verbraucht',
      );
    } on MoodleFehler catch (x) {
      // Nach einer Umleitung auf die Anmeldung, wenn die Neuanmeldung
      // scheiterte: Moodle hat das Formular nicht angenommen.
      return nichtGeschrieben(HttpStatus.badGateway, 'Nicht geschrieben. ${x.meldung} $verbraucht');
    }
    var ende = r;
    String? nichtGelesen;
    final ziel = moodle.umleitungsziel(r);
    if (ziel != null && !aufruf.vorbei) {
      try {
        ende = await moodle.lesenAls(
          ZusatzAufrufer(moodle, plugin.aufrufer, plugin.zusatzadressen, umleitung: true, lauf: aufruf.laufend),
          ziel,
          hoechstens: textHoechstens,
        );
      } on AnfrageGesperrt catch (x) {
        nichtGelesen =
            'Geschrieben ist schon: Der Schreibvorgang ist gesendet, Moodle hat mit einer Umleitung geantwortet. '
            'Deren Ziel durfte moocp nicht lesen. ${x.meldung}';
      } on MoodleFehler catch (x) {
        nichtGelesen =
            'Geschrieben ist schon: Der Schreibvorgang ist gesendet, Moodle hat mit einer Umleitung geantwortet. '
            'Deren Ziel ließ sich nicht lesen. ${x.meldung}';
      }
    }
    // Den Inhalt bekommt das Plugin nur in einem Lauf und nur, wenn die Seite,
    // deren Inhalt es bekäme, zu Kurs und Aktivität des Laufs passt: die
    // Antwort auf den POST (Adresse und Formularfelder) oder das Ziel der
    // Umleitung. Hinter einer Zusatzadresse ist mit Namen zu rechnen, und nur
    // im Lauf hat die App die Namen des Kurses für die Datenschutzprüfung geladen
    // (E36). Sonst nur Status und Pfad bis zum Skriptnamen; geschrieben ist
    // trotzdem.
    final lauf = aufruf.laufend;
    final passt =
        lauf != null &&
        (identical(ende, r)
            ? laufBindungVerletzt(lauf, uri, felder: felder) == null
            : laufBindungVerletzt(lauf, ende.adresse) == null);
    if (!passt) {
      return _geschrieben(aufruf, {
        'status': ende.status,
        'pfad': skriptPfad(ende.adresse),
        'hinweis': inhaltNurImLauf,
        'umleitungNichtGelesen': ?nichtGelesen,
      });
    }
    // Was das Plugin von der Seite bekommt, wie beim Lesen über eine
    // Zusatzadresse: von einer ganzen Seite nur der Hauptbereich, nie der
    // sesskey (moodle_lesen.dart).
    final seite = _seiteFuerPlugin(a, plugin, aufruf, ende, zusatzadresse: true);
    if (seite.status != HttpStatus.ok) {
      return _geschrieben(aufruf, {
        'hinweis': 'Geschrieben ist schon: Der Schreibvorgang ist gesendet, Moodle hat geantwortet. '
            '${KeinHauptbereich.meldung}',
      });
    }
    return _geschrieben(aufruf, {...seite.json, 'umleitungNichtGelesen': ?nichtGelesen});
  }

  /// Die Antwort nach einem gesendeten Schreibvorgang. Ist der Aufruf
  /// inzwischen zu Ende, sagt sie das und dass schon gesendet ist.
  static _Antwort _geschrieben(_Aufruf aufruf, Map<String, Object?> json) => aufruf.vorbei
      ? _fehler(
          HttpStatus.conflict,
          'Der Aufruf, zu dem das Token gehört, ist zu Ende oder abgebrochen. Der Schreibvorgang war da schon gesendet.',
        )
      : (status: HttpStatus.ok, json: {'geschrieben': true, ...json});

  /// `POST /v1/moodle/lauf/beginnen` `{"cmid": …}`: beginnt einen Lauf für
  /// die Aktivität `cmid` (lauf.dart). Die App ermittelt mit der Sitzung des
  /// Profils des Aufrufs selbst den Kurs der Aktivität und liest die Namen
  /// seiner Teilnehmenden in die Datenschutzprüfung dieses Plugins; ins Protokoll
  /// geht nur ihre Zahl, an das Plugin weder Namen noch Zahl. Antwort
  /// `{"kurs": …}`, die Nummer des Kurses. Der Lauf hängt am Aufruf-Token und
  /// braucht keine eigene Kennung; je Aufruf läuft höchstens einer (sonst
  /// 409). Gelingt etwas davon nicht sicher, beginnt kein Lauf (502 mit dem
  /// Grund), und lesende Zusatzadressen bleiben gesperrt.
  static Future<_Antwort> _laufBeginnen(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final protokoll = aufruf!.kontext.protokoll;
    final cmid = daten['cmid'];
    if (cmid is! int || cmid <= 0 || cmid > 9999999999) {
      return _fehler(
        HttpStatus.badRequest,
        'cmid fehlt: die Nummer der Aktivität als Zahl, etwa die Zahl hinter /mod/…/view.php?id=.',
      );
    }
    if (aufruf.laufend != null || aufruf.laufBeginnt) {
      return _fehler(
        HttpStatus.conflict,
        'In diesem Aufruf läuft schon ein Lauf; je Aufruf geht nur einer zugleich. Erst $pfadLaufBeenden.',
      );
    }
    final moodle = aufruf.kontext.moodle;
    if (!moodle.angemeldet || moodle.basis == null) return _nichtAngemeldet();
    aufruf.laufBeginnt = true;
    const ohne = 'Kein Lauf begonnen; lesende Zusatzadressen bleiben gesperrt.';
    try {
      final LaufBeginn? beginn;
      try {
        beginn = await Future.any<LaufBeginn?>([laufVorbereiten(moodle, cmid), aufruf.ende.then((_) => null)]);
      } on LaufFehler catch (x) {
        protokoll.eintrag(Art.info, '${plugin.aufrufer}: Kein Lauf begonnen (${x.grund})');
        return _fehler(HttpStatus.badGateway, '${x.grund} $ohne');
      } on AntwortZuGross {
        protokoll.eintrag(Art.info, '${plugin.aufrufer}: Kein Lauf begonnen (Teilnehmendenseite zu groß)');
        return _fehler(HttpStatus.badGateway, 'Die Teilnehmendenseite des Kurses ist zu groß. $ohne');
      } on AnfrageGesperrt {
        // Eine Umleitung auf eine andere Adresse: Die Sperre steht schon mit
        // ihrer Zeile im Protokoll; ihre Meldung ist für die KI geschrieben.
        if (aufruf.vorbei) return _abgebrochen();
        protokoll.eintrag(Art.info, '${plugin.aufrufer}: Kein Lauf begonnen (Umleitung auf eine gesperrte Adresse)');
        return _fehler(
          HttpStatus.badGateway,
          'Moodle hat beim Beginn auf eine Adresse umgeleitet, die moocp dafür nicht liest. $ohne',
        );
      } on MoodleFehler catch (x) {
        if (aufruf.vorbei) return _abgebrochen();
        final f = _moodleFehler(x);
        return _fehler(f.status, '${f.json['fehler']} $ohne');
      }
      if (beginn == null || aufruf.vorbei) return _abgebrochen();
      // Die Namen kommen in die Sperre, bevor das Plugin irgendetwas über den
      // Lauf liest; sie bleiben dort, bis die App endet.
      a.pruefung.namenHinzufuegen(plugin.kurzname, beginn.namen, herkunft: Herkunft.teilnehmende(beginn.lauf.kurs));
      a._lehrkraftSperren(plugin.kurzname, aufruf);
      aufruf.lauf = beginn.lauf;
      final n = beginn.namen.length;
      a._protokollzeile(plugin, protokoll, 'Lauf begonnen, $n ${n == 1 ? 'Name' : 'Namen'} zum Sperren geladen');
      return (status: HttpStatus.ok, json: <String, Object?>{'kurs': beginn.lauf.kurs});
    } finally {
      aufruf.laufBeginnt = false;
    }
  }

  /// `POST /v1/moodle/lauf/beenden` `{}`: beendet den Lauf dieses Aufrufs.
  /// Danach liest das Plugin keine Zusatzadresse mit der Art „lesen“ mehr;
  /// die Namen bleiben für die Datenschutzprüfung geladen. Ohne Lauf 409.
  static Future<_Antwort> _laufBeenden(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final lauf = aufruf!.laufend;
    if (lauf == null) return _fehler(HttpStatus.conflict, 'In diesem Aufruf läuft kein Lauf.');
    lauf.beenden();
    a._protokollzeile(plugin, aufruf.kontext.protokoll, 'Lauf beendet');
    return (status: HttpStatus.ok, json: <String, Object?>{});
  }

  /// `POST /v1/moodle/zusatz/lesen` `{"pfad": "/…?…"}`: liest in einem Lauf
  /// eine Zusatzadresse dieses Plugins mit der Art „lesen“, mit GET und der
  /// Sitzung des Profils des Aufrufs (moodle_schreiben.dart, [ZusatzLeser]).
  /// Die Adresse und jedes Umleitungsziel müssen zu Kurs und Aktivität des
  /// Laufs passen. Außerhalb eines Laufs lehnt die App jede solche Anfrage ab
  /// (403). Antwort wie bei /v1/moodle/lesen; von einer ganzen HTML-Seite nur
  /// der Hauptbereich, nie der sesskey. Größer als [textHoechstens] Bytes ist
  /// 413; heruntergeladen wird über /v1/moodle/zusatz/datei. Endet der Lauf
  /// oder der Aufruf, geht nichts mehr hinaus (409).
  static Future<_Antwort> _zusatzLesen(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final adresse = _moodleAdresse(a, plugin, aufruf!, daten);
    if (adresse case final _Antwort fehler) return fehler;
    final uri = adresse as Uri;
    final protokoll = aufruf.kontext.protokoll;
    final lauf = aufruf.laufend;
    if (lauf == null) {
      protokoll.eintrag(
        Art.gesperrt,
        '${plugin.aufrufer}: Lesen über eine Zusatzadresse außerhalb eines Laufs abgewiesen: GET ${skriptAdresse(uri)}',
      );
      return _fehler(
        HttpStatus.forbidden,
        'Abgelehnt: Über eine Zusatzadresse liest ein Plugin nur in einem Lauf ($pfadLaufBeginnen mit der Nummer '
        'der Aktivität). Erst dann kennt moocp den Kurs und hat die Namen seiner Teilnehmenden für die letzte '
        'Sperre geladen.',
      );
    }
    if (zusatzadresseFuer(plugin.zusatzadressen, uri, ZugriffsArt.lesen) == null) {
      protokoll.eintrag(
        Art.gesperrt,
        '${plugin.aufrufer}: Gesperrt: GET ${skriptAdresse(uri)} (keine Zusatzadresse „lesen“ dieses Plugins)',
      );
      return _fehler(
        HttpStatus.forbidden,
        'Abgelehnt: ${uri.path} ist keine Zusatzadresse dieses Plugins mit der Art „lesen“. Seiten, die die '
        'Positivliste von moocp erlaubt, liest ein Plugin über $pfadMoodleLesen.',
      );
    }
    final moodle = aufruf.kontext.moodle;
    try {
      final r = await Future.any<Antwort?>([
        moodle.lesenAls(ZusatzLeser(moodle, plugin.aufrufer, plugin.zusatzadressen, lauf), uri, hoechstens: textHoechstens),
        aufruf.ende.then((_) => null),
        lauf.ende.then((_) => null),
      ]);
      if (aufruf.vorbei) return _abgebrochen();
      if (lauf.vorbei || r == null) {
        return _fehler(HttpStatus.conflict, 'Abgebrochen: Der Lauf ist beendet; was danach kam, geht nicht hinaus.');
      }
      return _seiteFuerPlugin(a, plugin, aufruf, r, zusatzadresse: true);
    } on AntwortZuGross catch (x) {
      if (aufruf.vorbei) return _abgebrochen();
      return _fehler(
        HttpStatus.requestEntityTooLarge,
        '${x.meldung} Größere Inhalte einer Zusatzadresse lädt ein Plugin im Lauf über $pfadZusatzDatei.',
      );
    } on MoodleFehler catch (x) {
      return aufruf.vorbei ? _abgebrochen() : _moodleFehler(x);
    }
  }

  /// `POST /v1/moodle/zusatz/datei` `{"pfad": "/…?…"}`: lädt in einem Lauf
  /// eine Datei über eine Zusatzadresse dieses Plugins mit der Art „lesen“
  /// herunter, mit denselben Prüfungen wie /v1/moodle/zusatz/lesen, in den
  /// Ordner für Downloads (downloads.dart), nie in den Arbeitsordner: in den
  /// Unterordner dieses Plugins und des Profils des Aufrufs, unter einem
  /// Namen, den die App vergibt. Grenzen wie beim Download der eingebauten
  /// Werkzeuge (höchstens 200 MB, keine Seite statt einer Datei), nur darf die
  /// Größe ungenannt sein, und Umleitungen folgt er, jedes Ziel geprüft wie
  /// die Adresse selbst; ein Ziel, das nicht passt, ist ein Fehler, ohne dass
  /// etwas abgelegt wird. Antwort `{"datei": …,
  /// "bytes": …}`: Den Pfad bekommt nur das Plugin; er steht in keinem
  /// Protokoll, und die Datenschutzprüfung hält jeden Text an, der ihn nennt. Endet
  /// der Lauf, löscht er die Datei; endet er oder der Aufruf während des
  /// Ladens, bricht es ab (409), und keine Datei bleibt.
  static Future<_Antwort> _zusatzDatei(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final adresse = _moodleAdresse(a, plugin, aufruf!, daten);
    if (adresse case final _Antwort fehler) return fehler;
    final uri = adresse as Uri;
    final protokoll = aufruf.kontext.protokoll;
    final lauf = aufruf.laufend;
    if (lauf == null) {
      protokoll.eintrag(
        Art.gesperrt,
        '${plugin.aufrufer}: Herunterladen über eine Zusatzadresse außerhalb eines Laufs abgewiesen: '
        'GET ${skriptAdresse(uri)}',
      );
      return _fehler(
        HttpStatus.forbidden,
        'Abgelehnt: Über eine Zusatzadresse lädt ein Plugin nur in einem Lauf herunter ($pfadLaufBeginnen mit der '
        'Nummer der Aktivität). Erst dann kennt moocp den Kurs und hat die Namen seiner Teilnehmenden für die '
        'Datenschutzprüfung geladen.',
      );
    }
    if (zusatzadresseFuer(plugin.zusatzadressen, uri, ZugriffsArt.lesen) == null) {
      protokoll.eintrag(
        Art.gesperrt,
        '${plugin.aufrufer}: Gesperrt: GET ${skriptAdresse(uri)} (keine Zusatzadresse „lesen“ dieses Plugins)',
      );
      return _fehler(
        HttpStatus.forbidden,
        'Abgelehnt: ${skriptPfad(uri)} ist keine Zusatzadresse dieses Plugins mit der Art „lesen“. Dateien, die die '
        'Positivliste von moocp erlaubt, lädt ein Plugin über $pfadMoodleDatei.',
      );
    }
    final downloads = a._downloads;
    if (downloads == null) {
      return _fehler(HttpStatus.serviceUnavailable, 'moocp hat hier keinen Ordner für Downloads von Plugins.');
    }
    final File ziel;
    try {
      ziel = downloads.neueDatei(plugin.kurzname, aufruf.profil, uri);
    } on FileSystemException catch (x) {
      // Ohne Pfad: Auch die Meldung an das Plugin kann weitergehen.
      return _fehler(
        HttpStatus.internalServerError,
        'Der Ordner für Downloads ließ sich nicht anlegen (${x.runtimeType}).',
      );
    }
    // Gemerkt, bevor geladen wird: Endet der Lauf, ist auch ein halber Teil
    // weg.
    lauf.dateiMerken(ziel);
    final moodle = aufruf.kontext.moodle;
    final laden = moodle.herunterladenAls(
      ZusatzLeser(moodle, plugin.aufrufer, plugin.zusatzadressen, lauf),
      uri,
      ziel,
      abbruch: Future.any([aufruf.ende, lauf.ende]),
      groesseNoetig: false,
      // Skripte, die eine Datei erzeugen, leiten oft erst auf sie um. Jedes
      // Ziel prüft ZusatzLeser wie die Adresse selbst: Zusatzadresse „lesen“
      // dieses Plugins oder lesender Teil der Positivliste, hinter den
      // gesperrten Bereichen und passend zum Lauf.
      umleitungenFolgen: true,
    );
    // Wurde die Datei im selben Augenblick fertig, in dem Lauf oder Aufruf
    // endeten, bleibt sie nicht liegen.
    unawaited(
      laden.then(
        (_) async {
          if (lauf.vorbei || aufruf.vorbei) await ziel.delete().then((_) {}, onError: (Object _) {});
        },
        onError: (Object _) {},
      ),
    );
    try {
      final bytes = await Future.any<int?>([laden, aufruf.ende.then((_) => null), lauf.ende.then((_) => null)]);
      if (aufruf.vorbei) return _abgebrochen();
      if (lauf.vorbei || bytes == null) {
        return _fehler(HttpStatus.conflict, 'Abgebrochen: Der Lauf ist beendet; die Datei ist gelöscht.');
      }
      return (status: HttpStatus.ok, json: {'datei': ziel.path, 'bytes': bytes});
    } on DownloadZuGross {
      if (aufruf.vorbei) return _abgebrochen();
      return _fehler(
        HttpStatus.requestEntityTooLarge,
        'Die Datei ist größer als ${archivGrenzeStandard ~/ (1024 * 1024)} MB; nicht heruntergeladen.',
      );
    } on MoodleFehler catch (x) {
      if (aufruf.vorbei) return _abgebrochen();
      if (lauf.vorbei) return _fehler(HttpStatus.conflict, 'Abgebrochen: Der Lauf ist beendet; keine Datei geladen.');
      return _moodleFehler(x);
    }
  }

  /// Der Dateiname für einen Download: der genannte, wenn er gültig ist,
  /// sonst null; ohne Angabe der letzte Teil des Pfads, mit „_“ statt
  /// Zeichen, die in keinen Dateinamen gehören.
  static String? _dateiname(Object? genannt, Uri uri) {
    final verboten = RegExp(r'[\x00-\x1f\x7f\\/:*?"<>|]');
    bool gueltig(String n) => n.isNotEmpty && n.length <= 120 && !n.startsWith('.') && !verboten.hasMatch(n);
    if (genannt != null) return genannt is String && gueltig(genannt) ? genannt : null;
    final letzter = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
    var n = letzter.replaceAll(verboten, '_');
    while (n.startsWith('.')) {
      n = n.substring(1);
    }
    if (n.length > 120) n = n.substring(n.length - 120);
    return n.isEmpty ? 'datei' : n;
  }

  /// Höchstens ein Dialog oder eine Freigabe je Aufruf zugleich: Wer einen
  /// zweiten will, solange der erste offen ist, bekommt 409. Ein Plugin mit
  /// mehreren Fragen stellt sie nacheinander; die Lehrkraft sieht nie zwei
  /// Fenster eines Aufrufs übereinander.
  static Future<_Antwort> _einzeln(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf aufruf,
    Future<_Antwort> Function() f,
  ) async {
    if (aufruf.dialogOffen) {
      a._protokollzeile(plugin, aufruf.kontext.protokoll, 'zweiter Dialog im selben Aufruf abgewiesen');
      return _fehler(
        HttpStatus.conflict,
        'Es ist schon ein Dialog oder eine Freigabe dieses Aufrufs offen; je Aufruf geht nur einer zugleich. '
        'Erst die Antwort abwarten.',
      );
    }
    aufruf.dialogOffen = true;
    try {
      return await f();
    } finally {
      aufruf.dialogOffen = false;
    }
  }

  /// `POST /v1/dialog/<art>`: zeigt einen Dialog der Art [art] (dialoge.dart,
  /// Felder je Art) und wartet auf die Antwort: `{"abgebrochen": false, …}`
  /// mit den Feldern der Art, oder `{"abgebrochen": true}`, wenn die
  /// Lehrkraft abbricht, die Frist abläuft oder der Aufruf endet -- ein
  /// Ausgang, kein Fehler. Ins Protokoll gehen nur Plugin, Art und Ausgang.
  ///
  /// Testbetrieb (E35): Nennt der Kontext eine Datei mit vorbereiteten
  /// Antworten (AufrufKontext.testDialogantworten) und passt darin eine
  /// geprüfte Antwort (testantworten.dart), erscheint kein Dialog; die
  /// Antwort trägt `"testbetrieb": true`, das Protokoll sagt es, und die KI
  /// erfährt es (laufende_plugins.dart). Sonst erscheint er wie immer.
  static Future<_Antwort> _dialogZeigen(
    PluginDialogArt art,
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final dialoge = a._dialoge;
    if (dialoge == null) return _fehler(HttpStatus.serviceUnavailable, 'moocp kann hier keine Dialoge zeigen.');
    final PluginDialog dialog;
    try {
      dialog = PluginDialog.ausJson(art, plugin.aufrufer, daten);
    } on FormatException catch (x) {
      return _fehler(HttpStatus.badRequest, x.message);
    }
    return _einzeln(a, plugin, aufruf!, () async {
      final protokoll = aufruf.kontext.protokoll;
      final datei = aufruf.kontext.testDialogantworten;
      switch (datei == null ? null : testantwortSuchen(datei, plugin.kurzname, dialog)) {
        case TestantwortGegeben(:final antwort):
          aufruf.testDialogantworten++;
          a._protokollzeile(
            plugin,
            protokoll,
            'Dialog „${art.name}“ im Testbetrieb aus einer vorbereiteten Antwort '
            '${antwort == null ? 'abgebrochen' : 'beantwortet'}, ohne Lehrkraft',
          );
          return (status: HttpStatus.ok, json: {'abgebrochen': antwort == null, ...?antwort, 'testbetrieb': true});
        case TestantwortUngueltig(:final grund):
          a._protokollzeile(plugin, protokoll, 'Testbetrieb: $grund; der Dialog „${art.name}“ erscheint');
        case null:
      }
      a._protokollzeile(plugin, protokoll, 'Dialog „${art.name}“ geöffnet');
      final antwort = await dialoge.zeigen(dialog, ende: aufruf.ende);
      a._protokollzeile(plugin, protokoll, 'Dialog „${art.name}“ ${antwort == null ? 'abgebrochen' : 'beantwortet'}');
      return (status: HttpStatus.ok, json: {'abgebrochen': antwort == null, ...?antwort});
    });
  }

  /// `POST /v1/freigabe` `{"titel": …, "zusammenfassung": …, "ab": …}`: bittet
  /// um eine Freigabe im Profil des Aufrufs, durch die eine Stelle für
  /// Freigaben (AufrufKontext.pluginFreigabe), mit dem Plugin als Aufrufer.
  /// `ab` ist die Stufe, ab der gefragt wird: „mittel“, „alle“ oder „keine“
  /// (auf jeder Stufe). Antwort `{"ausgang": "freigegeben" | "abgelehnt" |
  /// "abgebrochen", "ohneFrage": …}`; `ohneFrage` ist true, wenn die Stufe
  /// der Lehrkraft die Frage ausgelassen hat und deshalb freigegeben ist.
  static Future<_Antwort> _freigabeAnfragen(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final t = daten['titel'];
    final z = daten['zusammenfassung'];
    final titel = t is String ? einzeilig(t, dialogTitelHoechstens) : '';
    final zusammenfassung = z is String ? mehrzeilig(z, dialogTextHoechstens) : '';
    final ab = Bestaetigungen.values.where((b) => b.text == daten['ab']).firstOrNull;
    if (titel.isEmpty) return _fehler(HttpStatus.badRequest, 'titel fehlt: eine Zeile Text als Überschrift.');
    if (zusammenfassung.isEmpty) {
      return _fehler(HttpStatus.badRequest, 'zusammenfassung fehlt: was freigegeben werden soll, als Text.');
    }
    if (ab == null) {
      return _fehler(HttpStatus.badRequest, 'ab fehlt: „mittel“, „alle“ oder „keine“ (auf jeder Stufe fragen).');
    }
    return _einzeln(a, plugin, aufruf!, () async {
      final ausgang = await aufruf.kontext.pluginFreigabe(
        titel: titel,
        zusammenfassung: zusammenfassung,
        ab: ab,
        abbruch: aufruf.ende,
        aufrufer: plugin.aufrufer,
      );
      final (wort, ausgangText) = switch (ausgang) {
        PluginFreigabeAusgang.freigegeben => ('erteilt', 'freigegeben'),
        PluginFreigabeAusgang.ohneFrage => ('ohne Frage erteilt', 'freigegeben'),
        PluginFreigabeAusgang.abgelehnt => ('abgelehnt', 'abgelehnt'),
        // Ohne laufKurs gibt der Testbetrieb eine Freigabe eines Plugins nie
        // frei (AufrufKontext.pluginFreigabe); käme es doch, gälte es nicht.
        PluginFreigabeAusgang.automatisch || PluginFreigabeAusgang.abgebrochen => ('abgebrochen', 'abgebrochen'),
      };
      a._protokollzeile(plugin, aufruf.kontext.protokoll, 'Freigabe ab Stufe „${ab.text}“ -- $wort');
      return (
        status: HttpStatus.ok,
        json: {'ausgang': ausgangText, 'ohneFrage': ausgang == PluginFreigabeAusgang.ohneFrage},
      );
    });
  }

  /// `POST /v1/protokoll` `{"text": …}`: eine Zeile ins Protokoll der App,
  /// mit dem Namen des Plugins davor, einzeilig und gekürzt. Mit Token ins
  /// Protokoll des Profils des Aufrufs, ohne ins Protokoll der App.
  static Future<_Antwort> _protokollSchreiben(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final text = daten['text'];
    final zeile = text is String ? einzeilig(text, protokollzeileHoechstens) : '';
    if (zeile.isEmpty) return _fehler(HttpStatus.badRequest, 'text fehlt: eine Zeile Text für das Protokoll.');
    final ziel = aufruf?.kontext.protokoll ?? a._protokoll;
    // Geprüft wird die Zeile, wie sie kam, nicht nur, was nach dem Kürzen
    // bliebe. Mit Treffer erscheint nur ein Platzhalter, der nichts verrät
    // (weder Länge noch Anfang), ohne Rückfrage; für das Plugin ist die Zeile
    // geschrieben.
    if (aufruf != null) a._lehrkraftSperren(plugin.kurzname, aufruf);
    final t = a.pruefung.trifft(plugin.kurzname, [text as String]);
    if (t.name || t.pfad) {
      a._protokollzeile(plugin, ziel, t.name ? protokollPlatzhalterName : protokollPlatzhalterPfad);
      return (status: HttpStatus.ok, json: <String, Object?>{});
    }
    a._protokollzeile(plugin, ziel, zeile);
    return (status: HttpStatus.ok, json: <String, Object?>{});
  }

  /// `POST /v1/arbeitsordner` `{}`: der Pfad des Unterordners dieses Plugins
  /// im Arbeitsordner des Profils des Aufrufs (`plugin-<Kurzname>`; die App
  /// legt dort sonst nichts mit diesem Anfang ab). Die App legt ihn an, das
  /// Plugin schreibt selbst hinein; er wird mit dem Arbeitsordner geleert
  /// (E5).
  static Future<_Antwort> _arbeitsordnerGeben(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final pfad = p.normalize(p.absolute(aufruf!.kontext.arbeitsordner, 'plugin-${plugin.kurzname}'));
    try {
      await Directory(pfad).create(recursive: true);
    } on FileSystemException catch (x) {
      return _fehler(HttpStatus.internalServerError, 'Der Ordner $pfad ließ sich nicht anlegen (${x.runtimeType}).');
    }
    return (status: HttpStatus.ok, json: {'pfad': pfad});
  }

  /// `POST /v1/werkzeug` `{"name": …, "argumente": {…}}`: ein eingebautes
  /// Werkzeug im Profil des Aufrufs, zu denselben Regeln wie für ein
  /// KI-Werkzeug (AufrufKontext.eingebautAufrufen), mit dem Plugin als
  /// Aufrufer. Endet der äußere Aufruf oder bricht der Client ab, endet auch
  /// dieser: Offene Freigaben verfallen, und die Antwort ist 409.
  static Future<_Antwort> _werkzeugAufrufen(
    AppAdresse a,
    _Plugin plugin,
    _Aufruf? aufruf,
    Map<String, Object?> daten,
  ) async {
    final name = daten['name'];
    final args = daten['argumente'] ?? <String, Object?>{};
    if (name is! String || name.isEmpty) {
      return _fehler(HttpStatus.badRequest, 'name fehlt: der Name eines eingebauten Werkzeugs.');
    }
    if (args is! Map<String, Object?>) {
      return _fehler(HttpStatus.badRequest, 'argumente muss ein JSON-Objekt sein.');
    }
    // Name und Argumente stehen im Protokoll der Hülle: nur, was die letzte
    // Sperre durchlässt.
    if (a._gesperrt(plugin, aufruf, [name, ...texteIn(args)], 'Aufruf eines Werkzeugs von moocp', aufruf!.kontext.protokoll)) {
      return _sperrAntwort('Der Aufruf');
    }
    final abgebrochen = _fehler(
      HttpStatus.conflict,
      'Abgebrochen: Der Aufruf, zu dem das Token gehört, ist zu Ende oder abgebrochen.',
    );
    try {
      final antwort = await Future.any<_Antwort>([
        aufruf.kontext
            .eingebautAufrufen(name, args, abbruch: aufruf.ende, aufrufer: plugin.aufrufer)
            .then((e) => (status: HttpStatus.ok, json: {'text': e.text, 'fehlgeschlagen': e.fehlgeschlagen})),
        aufruf.ende.then((_) => abgebrochen),
      ]);
      // Wie bei einem Client, der abbricht: Nach dem Ende geht kein Ergebnis
      // mehr hinaus, auch wenn das Werkzeug im selben Augenblick fertig wurde.
      return aufruf.vorbei ? abgebrochen : antwort;
    } on MoodleFehler catch (x) {
      return aufruf.vorbei ? abgebrochen : _fehler(HttpStatus.badRequest, x.meldung);
    }
  }
}

class _Funktion {
  const _Funktion({required this.mitAufruf, required this.ausfuehren});

  /// Ob die Funktion das Token eines laufenden Aufrufs verlangt.
  final bool mitAufruf;
  final Future<_Antwort> Function(AppAdresse a, _Plugin plugin, _Aufruf? aufruf, Map<String, Object?> daten)
  ausfuehren;
}

/// Vergleicht zwei Schlüssel in einer Zeit, die nur von der Länge von [a]
/// abhängt, nicht davon, wo sie sich unterscheiden.
bool _gleich(List<int> a, List<int> b) {
  if (a.isEmpty || b.isEmpty) return false;
  var d = a.length ^ b.length;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i < b.length ? i : 0];
  }
  return d == 0;
}
