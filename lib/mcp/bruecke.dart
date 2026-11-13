// Die Brücke für KI-Werkzeuge, die MCP nur über stdio sprechen (LM Studio,
// einrichtung.dart): `moocp-bruecke.exe` (bin/moocp_bruecke.dart) liest
// JSON-RPC-Nachrichten zeilenweise von stdin, reicht Werkzeugaufrufe an den
// MCP-Server der laufenden App weiter (http://127.0.0.1:<port>/mcp) und
// schreibt die Antworten zeilenweise nach stdout.
//
// Ein eigenes Programm ohne Flutter statt der App mit einem Schalter: Der
// Client hält die Brücke offen, solange er läuft, und ein laufendes Programm
// sperrt seine Dateien. Bei der App wären das exe, DLLs und data\ -- Update
// und Neubau scheiterten, solange der Client läuft. So ist es eine einzige
// Datei, und die lässt sich im laufenden Betrieb umbenennen
// (installer/moocp.nsi, windows/bruecke.cmake). Darum darf von hier aus
// nichts Flutter importieren.
//
// Wann der Client die Brücke startet, entscheidet er -- Bionic etwa beim
// eigenen Start, lange bevor jemand moocp öffnet. Darum hängt nur der
// Werkzeugaufruf an der App. initialize und tools/list beantwortet die
// Brücke immer selbst, mit dem, was die moocp.exe neben ihr dazu sagt
// (`moocp.exe --werkzeugliste`, Werkzeugliste) -- also genau die installierte
// Version, ob die App läuft oder nicht --, und ping ohnehin. Läuft die App
// beim Werkzeugaufruf nicht, startet die Brücke sie und wartet, bis sie
// angemeldet ist -- bei einem Werkzeug eines Plugins, das ohne Anmeldung
// arbeitet (`ohneAnmeldung` in der Werkzeugliste), nur, bis ihr Server
// lauscht. So geht moocp nicht bei jedem Start des Clients mit auf, und wer
// vergessen hat, es zu starten, merkt davon nur eine kurze Pause.
//
// Den Schlüssel liest die Brücke selbst aus den Einstellungen; im
// KI-Werkzeug steht deshalb nur der Pfad der Brücke und kein Geheimnis.
// Sie fragt genau eine Adresse an, mit dem Port aus den Einstellungen, und
// kann nichts, was der MCP-Server über HTTP nicht auch kann: Sperrliste,
// Freigaben und Protokoll liegen dort (E6).
//
// Kein Fenster und kein Protokolleintrag: Die laufende App protokolliert die
// Verbindung selbst („KI-Werkzeug verbunden"), und zwei Prozesse, die in
// dieselbe Datei schreiben, verschränkten ihre Zeilen. Auf stdout steht
// ausschließlich, was der MCP-Server und `--werkzeugliste` antworten, und
// was die Brücke an ihrer Stelle im Format von JSON-RPC sagt (E11) -- jede
// andere Ausgabe zerbräche das Protokoll des Clients.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../einrichtung.dart';
import '../einstellungen_ort.dart';
import '../plattform/kindprozess.dart';
import 'vor_anmeldung.dart';

/// Aufruf aus bin/moocp_bruecke.dart.
Future<int> brueckeStarten() async {
  var port = standardPort;
  String? schluessel;
  try {
    // Nur lesen: Einstellungen.laden() legte eine fehlende Datei an.
    final j = jsonDecode(einstellungenDatei.readAsStringSync());
    if (j is Map) {
      port = j['port'] as int? ?? port;
      schluessel = j['schluessel'] as String?;
    }
  } catch (_) {
    // dann eben nicht eingerichtet; jede Anfrage bekommt das als Antwort
  }
  final exe = File(p.join(p.dirname(Platform.resolvedExecutable), 'moocp.exe'));
  final bruecke = Bruecke(
    adresse: Uri.parse(mcpAdresse(port)),
    schluessel: schluessel,
    ausgabe: stdout.writeln,
    listeHolen: () => werkzeuglisteHolen(exe),
    appStarten: () => moocpStarten(exe),
  );
  await bruecke.laufen(stdin);
  await stdout.flush();
  return 0;
}

/// Startet moocp losgelöst von der Brücke: ohne ihre Rohre zum Client, und
/// so, dass die App weiterläuft, wenn die Brücke endet. Läuft moocp schon,
/// holt der zweite Start nur ihr Fenster nach vorn (windows/runner/main.cpp)
/// -- genau richtig, wenn sie noch nicht angemeldet ist.
Future<bool> moocpStarten(File exe) async {
  if (!exe.existsSync()) return false;
  try {
    await prozessStarten(exe.path, const [], modus: ProcessStartMode.detached, arbeitsordner: exe.parent.path);
    return true;
  } catch (_) {
    return false;
  }
}

/// Fragt die moocp.exe neben der Brücke nach ihrer Werkzeugliste
/// (`--werkzeugliste`, main.dart). Null, wenn das nicht geht.
Future<Werkzeugliste?> werkzeuglisteHolen(File exe) async {
  if (!exe.existsSync()) return null;
  try {
    final r = await prozessAusfuehren(exe.path, const [
      werkzeuglisteSchalter,
    ], stdoutEncoding: utf8).timeout(const Duration(seconds: 30));
    if (r.exitCode != 0) return null;
    // Eine Zeile JSON. Eine Entwicklerversion schreibt davor noch die
    // Adresse ihres VM-Service.
    final zeilen = const LineSplitter().convert(r.stdout as String).where((z) => z.trim().isNotEmpty);
    return zeilen.isEmpty ? null : Werkzeugliste.ausJson(jsonDecode(zeilen.last));
  } catch (_) {
    return null;
  }
}

/// Die Werkzeugliste der App (McpDienst.werkzeugliste): die Antworten ihres
/// MCP-Servers auf initialize und tools/list und die Protokollversionen, die
/// er beim initialize annimmt. Darin stehen nur Namen, Beschreibungen und
/// Parameter der Werkzeuge -- keine Kursinhalte, kein Schlüssel.
class Werkzeugliste {
  Werkzeugliste({
    required this.versionen,
    required this.initialize,
    required this.tools,
    this.ohneAnmeldung = const {},
  });

  final List<String> versionen;
  final Map<String, dynamic> initialize;
  final Map<String, dynamic> tools;

  /// Die Werkzeuge der Plugins, die ohne Moodle-Anmeldung arbeiten
  /// (McpDienst.werkzeugliste, `ohneAnmeldung`). Für sie wartet die Brücke
  /// nur auf den Server, nicht auf die Anmeldung. Der Client sieht die Angabe
  /// nicht: An ihn gehen nur [initialize] und [tools].
  final Set<String> ohneAnmeldung;

  /// Die Version, die der Server der App einem Client zusagt, der
  /// [gewuenscht] verlangt (wie _oninitialize in mcp_dart): die gewünschte,
  /// wenn er sie kann, sonst seine erste.
  String version(Object? gewuenscht) =>
      gewuenscht is String && versionen.contains(gewuenscht) ? gewuenscht : versionen.first;

  /// Null, wenn [j] keine Werkzeugliste ist.
  static Werkzeugliste? ausJson(Object? j) {
    try {
      final versionen = ((j as Map)['versionen'] as List).cast<String>();
      if (versionen.isEmpty) return null;
      final ohne = j['ohneAnmeldung'];
      return Werkzeugliste(
        versionen: versionen,
        initialize: (j['initialize'] as Map).cast<String, dynamic>(),
        tools: (j['tools'] as Map).cast<String, dynamic>(),
        // Eine unbrauchbare Angabe ist keine: Dann wartet jeder Aufruf auf
        // die Anmeldung, wie ohne Plugin.
        ohneAnmeldung: ohne is List ? ohne.whereType<String>().toSet() : const {},
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'versionen': versionen,
    'initialize': initialize,
    'tools': tools,
    if (ohneAnmeldung.isNotEmpty) 'ohneAnmeldung': ohneAnmeldung.toList(),
  };
}

const _nochNichtBereit =
    'moocp ist gestartet, aber noch nicht bereit: in moocp bei Moodle anmelden (und einen offenen '
    'Dialog dort abschließen), dann noch einmal versuchen.';
const _nochNichtBereitOhneAnmeldung =
    'moocp ist gestartet, aber noch nicht bereit: einen offenen Dialog in moocp abschließen, dann noch '
    'einmal versuchen.';
const _keineListe = 'moocp gibt seine Werkzeuge nicht heraus: moocp neu installieren.';
const _laeuftNicht = 'moocp läuft nicht: die App starten und bei Moodle anmelden.';
const _schluesselFalsch =
    'moocp lehnt den Schlüssel ab: die App einmal neu starten, dann im KI-Werkzeug neu verbinden.';
const _abgerissen = 'Die Verbindung zu moocp ist abgerissen; im KI-Werkzeug neu verbinden.';

/// Reicht Nachrichten zwischen einem stdio-Client und dem MCP-Server der App
/// weiter. Ohne stdin und stdout, damit sie sich prüfen lässt
/// (test/bruecke_test.dart).
class Bruecke {
  Bruecke({
    required this.adresse,
    required this.schluessel,
    required this.ausgabe,
    required this.listeHolen,
    required this.appStarten,
    // Kürzer als das Zeitlimit des Clients (einrichtung.dart): Die KI soll den Hinweis
    // „moocp ist noch nicht bereit" bekommen, nicht nur eine Zeitüberschreitung.
    this.aufAppWarten = const Duration(minutes: 5),
    this.anmeldungsTakt = const Duration(seconds: 2),
    HttpClient? client,
  }) : _client = client ?? (HttpClient()..connectionTimeout = const Duration(milliseconds: 500));

  final Uri adresse;

  /// null, wenn die App nicht eingerichtet ist.
  final String? schluessel;

  /// Schreibt eine Zeile an den Client.
  final void Function(String zeile) ausgabe;

  /// Holt die Werkzeugliste der App (werkzeuglisteHolen); null, wenn das
  /// nicht geht.
  final Future<Werkzeugliste?> Function() listeHolen;

  /// Startet moocp; false, wenn das nicht ging.
  final Future<bool> Function() appStarten;

  /// Wie lange ein Werkzeugaufruf nach dem Start der App auf ihren
  /// MCP-Server und auf die Anmeldung wartet. Der Server läuft erst nach der
  /// Anmeldung (E13): mit gespeicherten Anmeldedaten nach wenigen Sekunden,
  /// sonst, sobald die Lehrkraft sich angemeldet hat, nach einem Update auch
  /// erst nach dem Dialog „KI-Werkzeuge einrichten". Ist in seinem Profil ein
  /// Plugin mit Werkzeugen ohne Anmeldung eingeschaltet, läuft er schon nach
  /// der Einrichtung: Ein Werkzeug aus [Werkzeugliste.ohneAnmeldung] wartet
  /// dann nur auf ihn; jedes andere fragt, solange die App antwortet, dass die
  /// Anmeldung fehlt (vor_anmeldung.dart), alle [anmeldungsTakt] wieder, bis
  /// diese Frist um ist. Kürzer als das Zeitlimit, das die App in ein
  /// KI-Werkzeug einträgt ([clientZeitlimit]): So bekommt die KI den Hinweis,
  /// dass moocp noch nicht bereit ist, statt nur einer Zeitüberschreitung.
  final Duration aufAppWarten;

  /// Wie oft ein Werkzeugaufruf, der auf die Anmeldung wartet, die App
  /// wieder fragt. Jede Frage steht im Protokoll der App; seltener
  /// hielte die Lehrkraft nach der Anmeldung länger auf.
  final Duration anmeldungsTakt;

  /// Die Werkzeugliste vom letzten initialize oder tools/list; daraus die
  /// Werkzeuge ohne Anmeldung.
  Werkzeugliste? _liste;

  /// Mit kurzer Frist für den Verbindungsaufbau: Lauscht die App, nimmt
  /// Windows die Verbindung auf 127.0.0.1 sofort an, auch wenn sie gerade
  /// beschäftigt ist. Lauscht sie nicht, wiederholt Windows den Versuch und
  /// gibt erst nach rund 2 Sekunden auf -- so lange soll das Warten auf die
  /// gerade gestartete App nicht zwischen zwei Versuchen hängen.
  final HttpClient _client;

  String? _sitzung;
  String? _protokollVersion;

  /// Die initialize-Anfrage des Clients: Mit ihr meldet sich die Brücke bei
  /// der App an, sobald sie eine Sitzung braucht.
  Map<String, dynamic>? _anmeldung;

  Future<String?>? _verbindet;

  /// Anfragen, die gerade auf die App warten oder bei ihr laufen, und
  /// darunter die, die der Client inzwischen abgebrochen hat: Die gehen nicht
  /// mehr an die App, falls sie noch nicht dort sind. Sonst führte die App,
  /// sobald sie bereit ist, einen Aufruf aus, auf den niemand mehr wartet.
  final _offen = <Object>{};
  final _abgebrochen = <Object>{};

  /// Liest, bis der Client stdin schließt, und beendet dann die Sitzung.
  /// Nachrichten laufen nebeneinander: Ein Werkzeug, das auf eine Freigabe
  /// wartet, kann eine halbe Stunde brauchen, und so lange darf weder ein ping
  /// noch ein Abbruch hängen bleiben.
  Future<void> laufen(Stream<List<int>> eingabe) async {
    final offen = <Future<void>>[];
    await for (final zeile in eingabe.transform(utf8.decoder).transform(const LineSplitter())) {
      if (zeile.trim().isNotEmpty) offen.add(_nachricht(zeile));
    }
    await Future.wait(offen);
    await _beenden();
    _client.close(force: true);
  }

  Future<void> _nachricht(String zeile) async {
    final Object? n;
    try {
      n = jsonDecode(zeile);
    } catch (_) {
      _fehler(null, -32700, 'Keine gültige JSON-Nachricht.');
      return;
    }
    if (n is! Map) return;
    final id = n['id'];
    final methode = n['method'];
    if (schluessel == null) {
      if (id != null) {
        _fehler(id, -32000, 'moocp ist auf diesem Rechner nicht eingerichtet: die App einmal starten und einrichten.');
      }
      return;
    }
    switch (methode) {
      case 'initialize':
        _anmeldung = n.cast<String, dynamic>();
        return _ausDerListe(id, initialize: true);
      case 'tools/list':
        return _ausDerListe(id, initialize: false);
      case 'ping':
        // Für den Client ist die Brücke der Server: Ob sie lebt, sagt sie
        // selbst.
        if (id != null) ausgabe(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': {}}));
        return;
      case 'notifications/initialized':
        // Gilt dem initialize, das die Brücke beantwortet hat; bei der App
        // meldet sie sich beim Verbinden selbst als initialisiert.
        return;
      case String():
        if (id != null) {
          final werkzeug = methode == 'tools/call';
          return _aufruf(zeile, id, werkzeug: werkzeug, ohneAnmeldung: werkzeug && _ohneAnmeldung(n['params']));
        }
        if (methode == 'notifications/cancelled') {
          final r = (n['params'] as Map?)?['requestId'];
          if (r != null && _offen.contains(r)) _abgebrochen.add(r);
        }
        // Andere Benachrichtigungen (auch der Abbruch einer Anfrage, die schon
        // bei der App ist) nur an eine verbundene App.
        if (_sitzung != null) await _senden(zeile, null);
        return;
    }
    // Sonst eine Antwort des Clients auf eine Anfrage des Servers: Die App
    // stellt keine (enableJsonResponse in mcp_dienst.dart).
  }

  /// initialize und tools/list: die Antwort, die `moocp.exe --werkzeugliste`
  /// dafür gibt, durchgereicht. Bei initialize mit der Protokollversion, die
  /// die App dem Client zusagen würde.
  Future<void> _ausDerListe(Object? id, {required bool initialize}) async {
    if (id == null) return;
    final l = await listeHolen();
    if (l == null) {
      _fehler(id, -32000, _keineListe);
      return;
    }
    _liste = l;
    final Map<String, dynamic> ergebnis;
    if (initialize) {
      final params = _anmeldung?['params'];
      ergebnis = {...l.initialize, 'protocolVersion': l.version(params is Map ? params['protocolVersion'] : null)};
    } else {
      ergebnis = l.tools;
    }
    ausgabe(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': ergebnis}));
  }

  /// Alles andere braucht die App. Für einen Werkzeugaufruf startet die
  /// Brücke sie, wenn sie nicht läuft; scheitert das, bekommt das Modell
  /// den Grund als Ergebnis des Werkzeugs und kann ihn der Lehrkraft sagen.
  Future<void> _aufruf(String zeile, Object id, {required bool werkzeug, required bool ohneAnmeldung}) async {
    _offen.add(id);
    try {
      await _aufrufen(zeile, id, werkzeug: werkzeug, ohneAnmeldung: ohneAnmeldung);
    } finally {
      _offen.remove(id);
      _abgebrochen.remove(id);
    }
  }

  /// Ob der Werkzeugaufruf mit [params] einem Werkzeug ohne Anmeldung gilt
  /// (Werkzeugliste.ohneAnmeldung).
  bool _ohneAnmeldung(Object? params) {
    final name = params is Map ? params['name'] : null;
    return name is String && (_liste?.ohneAnmeldung.contains(name) ?? false);
  }

  /// Ein Aufruf an die App. Ein Werkzeug ohne Anmeldung ([ohneAnmeldung])
  /// wartet nur, bis ihr Server lauscht. Jedes andere wartet außerdem, solange
  /// die App antwortet, dass die Anmeldung fehlt, und fragt alle
  /// [anmeldungsTakt] wieder -- die App hat den Aufruf dann nicht ausgeführt,
  /// und erst nach der Anmeldung geht er. Beides zusammen höchstens
  /// [aufAppWarten]; danach bekommt der Client die letzte Antwort der App.
  Future<void> _aufrufen(String zeile, Object id, {required bool werkzeug, required bool ohneAnmeldung}) async {
    final bis = DateTime.now().add(aufAppWarten);
    String? grund;
    var versuche = 0;
    while (versuche < 2) {
      if (_sitzung == null) {
        grund = await _verbinden(starten: werkzeug);
        if (grund != null) break;
      }
      // Abgebrochen, während die Brücke auf die App wartete: nicht mehr
      // senden und nicht antworten -- der Client will keine Antwort mehr.
      if (_abgebrochen.contains(id)) return;
      final (ergebnis, zurueckgehalten) = await _senden(zeile, id, anmeldungAbwarten: werkzeug && !ohneAnmeldung);
      switch (ergebnis) {
        case _Ergebnis.erledigt:
          return;
        case _Ergebnis.anmeldungFehlt:
          if (!DateTime.now().isBefore(bis)) {
            _weiter(zurueckgehalten!);
            return;
          }
          await Future<void>.delayed(anmeldungsTakt);
          if (_abgebrochen.contains(id)) return;
        case _Ergebnis.nichtErreichbar:
          // Die App ist inzwischen weg: neu verbinden, notfalls starten.
          _sitzung = null;
          grund = _laeuftNicht;
          versuche++;
      }
    }
    if (_abgebrochen.contains(id)) return;
    var text = grund ?? _laeuftNicht;
    if (ohneAnmeldung && text == _nochNichtBereit) text = _nochNichtBereitOhneAnmeldung;
    if (werkzeug) {
      ausgabe(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'content': [
              {'type': 'text', 'text': text},
            ],
            'isError': true,
          },
        }),
      );
    } else {
      _fehler(id, -32000, text);
    }
  }

  /// Meldet die Brücke bei der App an, mit der initialize-Anfrage des
  /// Clients. Null bei Erfolg, sonst der Grund. Mit [starten] startet sie die
  /// App, wenn die nicht lauscht, und wartet auf sie. Laufen mehrere
  /// Anfragen zugleich ins Leere, meldet sie sich nur einmal an.
  Future<String?> _verbinden({required bool starten}) async {
    final laufend = _verbindet;
    if (laufend != null) {
      final grund = await laufend;
      if (_sitzung != null) return null;
      if (!starten) return grund;
    }
    final f = _verbindet = _verbindenJetzt(starten: starten);
    try {
      return await f;
    } finally {
      if (identical(_verbindet, f)) _verbindet = null;
    }
  }

  Future<String?> _verbindenJetzt({required bool starten}) async {
    final anmeldung = _anmeldung;
    if (anmeldung == null) return _abgerissen;
    var gestartet = false;
    final bis = DateTime.now().add(aufAppWarten);
    while (true) {
      try {
        final antwort = await _post(jsonEncode({...anmeldung, 'id': 'moocp-bruecke-anmeldung'}), mitSitzung: false);
        final sitzung = antwort.headers.value('mcp-session-id');
        final status = antwort.statusCode;
        final inhalt = _json(await utf8.decodeStream(antwort));
        if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) return _schluesselFalsch;
        if (status != HttpStatus.ok || sitzung == null) return _abgerissen;
        _sitzung = sitzung;
        final ergebnis = inhalt is Map ? inhalt['result'] : null;
        if (ergebnis is Map && ergebnis['protocolVersion'] is String) {
          _protokollVersion = ergebnis['protocolVersion'] as String;
        }
        final bestaetigt = await _post(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
          mitSitzung: true,
        );
        await bestaetigt.drain<void>();
        return null;
      } on SocketException {
        if (!starten) return _laeuftNicht;
        if (!gestartet) {
          gestartet = true;
          if (!await appStarten()) {
            return 'moocp läuft nicht und ließ sich nicht starten: die App starten und bei Moodle anmelden.';
          }
        }
        if (!DateTime.now().isBefore(bis)) return _nochNichtBereit;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } catch (x) {
        return 'moocp nicht erreichbar (${x.runtimeType}).';
      }
    }
  }

  Future<HttpClientResponse> _post(String text, {required bool mitSitzung}) async {
    final anfrage = await _client.postUrl(adresse);
    anfrage.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set(HttpHeaders.acceptHeader, 'application/json, text/event-stream')
      ..set(HttpHeaders.authorizationHeader, mcpKopf(schluessel!));
    if (mitSitzung && _sitzung != null) anfrage.headers.set('mcp-session-id', _sitzung!);
    if (mitSitzung && _protokollVersion != null) anfrage.headers.set('mcp-protocol-version', _protokollVersion!);
    anfrage.add(utf8.encode(text));
    return anfrage.close();
  }

  /// Schickt eine Nachricht an die App und gibt ihre Antwort an den Client.
  /// [_Ergebnis.nichtErreichbar], wenn die App nicht lauscht -- dann hat der
  /// Client noch nichts bekommen, und der Aufrufer entscheidet. Mit
  /// [anmeldungAbwarten] hält es eine Antwort, die sagt, dass die Anmeldung
  /// fehlt (vor_anmeldung.dart), zurück und gibt sie dem Aufrufer mit
  /// [_Ergebnis.anmeldungFehlt].
  Future<(_Ergebnis, String?)> _senden(
    String text,
    Object? id, {
    bool nochmal = true,
    bool anmeldungAbwarten = false,
  }) async {
    const erledigt = (_Ergebnis.erledigt, null);
    final HttpClientResponse antwort;
    try {
      antwort = await _post(text, mitSitzung: true);
    } on SocketException {
      return (_Ergebnis.nichtErreichbar, null);
    } catch (x) {
      if (id != null) _fehler(id, -32000, 'moocp nicht erreichbar (${x.runtimeType}).');
      return erledigt;
    }
    final status = antwort.statusCode;
    // Die App wurde neu gestartet und kennt die Sitzung nicht mehr: neu
    // anmelden und einmal wiederholen. Der Client merkt davon nichts.
    if (status == HttpStatus.notFound && nochmal && _anmeldung != null) {
      await antwort.drain<void>();
      _sitzung = null;
      final grund = await _verbinden(starten: false);
      if (grund == null) return _senden(text, id, nochmal: false, anmeldungAbwarten: anmeldungAbwarten);
      if (grund == _laeuftNicht) return (_Ergebnis.nichtErreichbar, null);
      if (id != null) _fehler(id, -32000, grund);
      return erledigt;
    }
    if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
      await antwort.drain<void>();
      if (id != null) _fehler(id, -32000, _schluesselFalsch);
      return erledigt;
    }
    if (antwort.headers.contentType?.mimeType == 'text/event-stream') {
      await _ereignisse(antwort);
      return erledigt;
    }
    final inhalt = await utf8.decodeStream(antwort);
    if (anmeldungAbwarten && _anmeldungFehlt(inhalt)) return (_Ergebnis.anmeldungFehlt, inhalt);
    if (inhalt.trim().isNotEmpty) {
      _weiter(inhalt);
    } else if (status >= 400 && id != null) {
      _fehler(id, -32000, 'moocp antwortet mit Status $status.');
    }
    return erledigt;
  }

  /// Ob [json] die Antwort der App auf einen Werkzeugaufruf ist, der vor der
  /// Anmeldung nicht ausgeführt wurde: die Angabe in `_meta` des Ergebnisses
  /// (vor_anmeldung.dart).
  static bool _anmeldungFehlt(String json) {
    final n = _json(json);
    final ergebnis = n is Map ? n['result'] : null;
    final meta = ergebnis is Map ? ergebnis['_meta'] : null;
    return meta is Map && meta[anmeldungFehltMeta] == anmeldungFehltWert;
  }

  /// Ereignisse einer SSE-Antwort: jedes `data:` ist eine Nachricht. Die App
  /// antwortet zwar mit JSON (enableJsonResponse in mcp_dienst.dart), aber
  /// der Standard erlaubt beides.
  Future<void> _ereignisse(HttpClientResponse antwort) async {
    final daten = <String>[];
    await for (final zeile in antwort.transform(utf8.decoder).transform(const LineSplitter())) {
      if (zeile.isEmpty) {
        if (daten.isNotEmpty) _weiter(daten.join('\n'));
        daten.clear();
      } else if (zeile.startsWith('data:')) {
        daten.add(zeile.substring(5).trimLeft());
      }
    }
    if (daten.isNotEmpty) _weiter(daten.join('\n'));
  }

  /// Eine Antwort als JSON, ob als JSON oder als SSE gekommen; null, wenn sie
  /// sich nicht lesen lässt.
  static Object? _json(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      final daten = [
        for (final z in const LineSplitter().convert(text))
          if (z.startsWith('data:')) z.substring(5).trimLeft(),
      ];
      try {
        return daten.isEmpty ? null : jsonDecode(daten.join('\n'));
      } catch (_) {
        return null;
      }
    }
  }

  /// Gibt eine Antwort an den Client, neu kodiert: Über stdio darf eine
  /// Nachricht keinen Zeilenumbruch enthalten.
  void _weiter(String json) {
    final Object? n;
    try {
      n = jsonDecode(json);
    } catch (_) {
      return;
    }
    ausgabe(jsonEncode(n));
  }

  /// Beendet die Sitzung, damit die App sie nicht bis zu ihrem Ende hält.
  Future<void> _beenden() async {
    final sitzung = _sitzung;
    if (sitzung == null || schluessel == null) return;
    try {
      final anfrage = await _client.deleteUrl(adresse).timeout(const Duration(seconds: 2));
      anfrage.headers
        ..set(HttpHeaders.authorizationHeader, mcpKopf(schluessel!))
        ..set('mcp-session-id', sitzung);
      final antwort = await anfrage.close().timeout(const Duration(seconds: 2));
      await antwort.drain<void>();
    } catch (_) {
      // Die App ist schon zu oder antwortet nicht; dann gibt es nichts zu beenden.
    }
  }

  void _fehler(Object? id, int code, String text) => ausgabe(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': text},
    }),
  );
}

enum _Ergebnis { erledigt, nichtErreichbar, anmeldungFehlt }
