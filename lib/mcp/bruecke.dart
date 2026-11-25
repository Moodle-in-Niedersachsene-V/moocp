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
// angemeldet ist. So geht moocp nicht bei jedem Start des Clients mit auf,
// und wer vergessen hat, es zu starten, merkt davon nur eine kurze Pause.
//
// Die Brücke ist der Weg jedes KI-Werkzeugs zur App, auf jedem System (E21):
// Im KI-Werkzeug steht nur ihr Pfad und der Name des Profils (`--profil`), kein
// Geheimnis. Zur App geht sie über den Kanal des Profils (kanal.dart), einen
// Endpunkt, den nur das eigene Konto erreicht. Bevor sie das Geringste sendet,
// prüft sie, dass Ordner und Socket (oder die Pipe) dem eigenen Konto gehören
// und dass auch die Gegenseite dieses Konto ist; fällt eine Prüfung durch,
// bekommt die KI den Grund als Ergebnis und nichts geht hinaus. Sie kann nichts,
// was der MCP-Server nicht auch kann: Sperrliste, Freigaben und Protokoll liegen
// dort (E6).
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
import '../plattform/kindprozess.dart';
import 'kanal.dart';

/// Der Servername, wenn der Aufruf keinen nennt: das Standardprofil (E31).
const standardProfilName = 'moodle';

/// Der Profilname aus den Argumenten der Brücke (`--profil <name>`); null, wenn
/// der Name fehlt oder sich nicht für einen Endpunkt eignet. Ohne Angabe gilt
/// [standardProfilName].
String? profilAusArgumenten(List<String> argumente) {
  final i = argumente.indexOf('--profil');
  if (i < 0) return standardProfilName;
  if (i + 1 >= argumente.length) return null;
  final name = argumente[i + 1];
  return kanalNameGueltig(name) ? name : null;
}

/// Aufruf aus bin/moocp_bruecke.dart.
Future<int> brueckeStarten(List<String> argumente) async {
  final profil = profilAusArgumenten(argumente);
  final exe = File(p.join(p.dirname(Platform.resolvedExecutable), _moocpDatei));
  final Bruecke bruecke;
  if (profil == null) {
    // Ein falscher Aufruf des KI-Werkzeugs: Jede Anfrage bekommt den Grund.
    bruecke = Bruecke(
      verbinden: () async => throw KanalFehler('Der Profilname der Brücke (--profil) ist ungültig.'),
      ausgabe: stdout.writeln,
      listeHolen: () => werkzeuglisteHolen(exe),
      appStarten: () async => false,
    );
  } else {
    bruecke = Bruecke(
      verbinden: () => standardKanalOrt.verbinden(profil),
      ausgabe: stdout.writeln,
      listeHolen: () => werkzeuglisteHolen(exe),
      appStarten: () => moocpStarten(exe),
    );
  }
  await bruecke.laufen(stdin);
  await stdout.flush();
  return 0;
}

/// Die Programmdatei der App neben der Brücke: `moocp.exe` unter Windows,
/// `moocp` auf dem Mac und unter Linux.
String get _moocpDatei => Platform.isWindows ? 'moocp.exe' : 'moocp';

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
  Werkzeugliste({required this.versionen, required this.initialize, required this.tools});

  final List<String> versionen;
  final Map<String, dynamic> initialize;
  final Map<String, dynamic> tools;

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
      return Werkzeugliste(
        versionen: versionen,
        initialize: (j['initialize'] as Map).cast<String, dynamic>(),
        tools: (j['tools'] as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {'versionen': versionen, 'initialize': initialize, 'tools': tools};
}

const _keineListe = 'moocp gibt seine Werkzeuge nicht heraus: moocp neu installieren.';
const _laeuftNicht = 'moocp läuft nicht: die App starten und bei Moodle anmelden.';
const _abgerissen = 'Die Verbindung zu moocp ist abgerissen; den Aufruf noch einmal versuchen.';

/// Die Nummer der Anfrage, mit der sich die Brücke bei der App anmeldet.
const _anmeldeNummer = 'moocp-bruecke-anmeldung';

/// Reicht Nachrichten zwischen einem stdio-Client und dem MCP-Server der App
/// weiter. Ohne stdin und stdout, damit sie sich prüfen lässt
/// (test/bruecke_test.dart).
///
/// Eine Verbindung zur App ist eine MCP-Sitzung: Die Brücke meldet sich mit
/// dem initialize des Clients an, sobald sie eine braucht, und reicht danach
/// jede Nachricht und jede Antwort Zeile für Zeile durch. Reißt die Verbindung
/// ab (die App wurde beendet oder neu gestartet), bekommt jede Anfrage, die
/// noch auf eine Antwort wartete, eine Fehlerantwort und wird nie
/// wiederholt: Ob die App sie schon ausgeführt hat, ist nicht bekannt, und ein
/// Werkzeug schreibt in Moodle. Die nächste Anfrage baut die Verbindung neu
/// auf, notfalls startet sie die App.
class Bruecke {
  Bruecke({
    required this.verbinden,
    required this.ausgabe,
    required this.listeHolen,
    required this.appStarten,
    // Kürzer als das Zeitlimit des Clients (einrichtung.dart): Die KI soll den Hinweis
    // „moocp ist noch nicht bereit" bekommen, nicht nur eine Zeitüberschreitung.
    this.aufAppWarten = const Duration(minutes: 5),
    this.anmeldeFrist = const Duration(seconds: 30),
  });

  /// Baut die Verbindung zur App auf, nachdem Endpunkt und Gegenstelle geprüft
  /// sind (kanal.dart): [KanalNichtDa], wenn die App nicht läuft,
  /// [KanalUnsicher], wenn etwas nicht stimmt -- dann ist nichts gesendet
  /// worden und wird auch nichts gesendet.
  final Future<KanalVerbindung> Function() verbinden;

  /// Schreibt eine Zeile an den Client.
  final void Function(String zeile) ausgabe;

  /// Holt die Werkzeugliste der App (werkzeuglisteHolen); null, wenn das
  /// nicht geht.
  final Future<Werkzeugliste?> Function() listeHolen;

  /// Startet moocp; false, wenn das nicht ging.
  final Future<bool> Function() appStarten;

  /// Wie lange ein Werkzeugaufruf nach dem Start der App auf ihren
  /// MCP-Server wartet. Der läuft erst nach der Anmeldung (E13): mit
  /// gespeicherten Anmeldedaten nach wenigen Sekunden, sonst, sobald die
  /// Lehrkraft sich angemeldet hat, nach einem Update auch erst nach dem
  /// Dialog „KI-Werkzeuge einrichten". Kürzer als das Zeitlimit, das die App
  /// in ein KI-Werkzeug einträgt ([clientZeitlimit]): So bekommt die KI den Hinweis,
  /// dass moocp noch nicht bereit ist, statt nur einer Zeitüberschreitung.
  final Duration aufAppWarten;

  /// Wie lange die App für die Antwort auf die Anmeldung brauchen darf.
  final Duration anmeldeFrist;

  KanalVerbindung? _kanal;
  Completer<void>? _angemeldet;

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

  /// Anfragen, die bei der App sind und noch keine Antwort haben.
  final _ausstehend = <Object>{};

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
        if (id != null) return _aufruf(zeile, id, werkzeug: methode == 'tools/call');
        if (methode == 'notifications/cancelled') {
          final r = (n['params'] as Map?)?['requestId'];
          if (r != null && _offen.contains(r)) _abgebrochen.add(r);
        }
        // Andere Benachrichtigungen (auch der Abbruch einer Anfrage, die schon
        // bei der App ist) nur an eine verbundene App.
        _senden(zeile);
        return;
    }
    // Sonst eine Antwort des Clients auf eine Anfrage des Servers: Die App
    // stellt keine.
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
  Future<void> _aufruf(String zeile, Object id, {required bool werkzeug}) async {
    _offen.add(id);
    try {
      await _aufrufen(zeile, id, werkzeug: werkzeug);
    } finally {
      _offen.remove(id);
      _abgebrochen.remove(id);
    }
  }

  Future<void> _aufrufen(String zeile, Object id, {required bool werkzeug}) async {
    String? grund;
    if (_kanal == null) {
      grund = await _verbinden(starten: werkzeug);
    }
    // Abgebrochen, während die Brücke auf die App wartete: nicht mehr
    // senden und nicht antworten -- der Client will keine Antwort mehr.
    if (_abgebrochen.contains(id)) return;
    if (grund == null && _kanal != null) {
      _ausstehend.add(id);
      _senden(zeile);
      return;
    }
    final text = grund ?? _laeuftNicht;
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
      if (_kanal != null) return null;
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
      final KanalVerbindung v;
      try {
        v = await verbinden();
      } on KanalNichtDa {
        if (!starten) return _laeuftNicht;
        if (!gestartet) {
          gestartet = true;
          if (!await appStarten()) {
            return 'moocp läuft nicht und ließ sich nicht starten: die App starten und bei Moodle anmelden.';
          }
        }
        if (!DateTime.now().isBefore(bis)) {
          return 'moocp ist gestartet, aber noch nicht bereit: in moocp bei Moodle anmelden (und einen offenen '
              'Dialog dort abschließen), dann noch einmal versuchen.';
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      } on KanalUnsicher catch (x) {
        return 'moocp wurde nicht angesprochen, weil der Kanal nicht sicher ist: ${x.text} '
            'Es wurde nichts gesendet. moocp im eigenen Konto neu starten.';
      } on KanalFehler catch (x) {
        return 'moocp nicht erreichbar: ${x.text}';
      } catch (x) {
        return 'moocp nicht erreichbar (${x.runtimeType}).';
      }
      return _anmelden(v, anmeldung);
    }
  }

  /// Meldet die Brücke auf der geprüften Verbindung [v] an: das initialize des
  /// Clients, die Antwort abwarten, dann „initialisiert".
  Future<String?> _anmelden(KanalVerbindung v, Map<String, dynamic> anmeldung) async {
    final angemeldet = Completer<void>();
    _angemeldet = angemeldet;
    unawaited(_lesen(v));
    v.senden(utf8.encode('${jsonEncode({...anmeldung, 'id': _anmeldeNummer})}\n'));
    try {
      await angemeldet.future.timeout(anmeldeFrist);
    } catch (_) {
      _kanal = null;
      await v.schliessen();
      return _abgerissen;
    }
    _kanal = v;
    v.senden(utf8.encode('${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'})}\n'));
    return null;
  }

  /// Liest die Antworten der App und gibt sie dem Client. Das Ende der
  /// Verbindung beantwortet jede Anfrage, die noch wartete.
  Future<void> _lesen(KanalVerbindung v) async {
    try {
      await for (final zeile in v.eingang.transform(utf8.decoder).transform(const LineSplitter())) {
        final Object? n;
        try {
          n = jsonDecode(zeile);
        } catch (_) {
          continue;
        }
        if (n is! Map) continue;
        if (n['id'] == _anmeldeNummer) {
          if (n['error'] != null) {
            _angemeldet?.completeError(StateError('abgelehnt'));
          } else {
            _angemeldet?.complete();
          }
          continue;
        }
        final id = n['id'];
        if (id != null && n['method'] == null) _ausstehend.remove(id);
        // Neu kodiert: Über stdio darf eine Nachricht keinen Zeilenumbruch
        // enthalten.
        ausgabe(jsonEncode(n));
      }
    } catch (_) {
      // Wie ein Ende der Verbindung.
    }
    if (identical(_kanal, v)) _kanal = null;
    final a = _angemeldet;
    if (a != null && !a.isCompleted) a.completeError(StateError('abgerissen'));
    final verwaist = [..._ausstehend];
    _ausstehend.clear();
    for (final id in verwaist) {
      if (!_abgebrochen.contains(id)) _fehler(id, -32000, _abgerissen);
    }
  }

  void _senden(String zeile) {
    final k = _kanal;
    if (k != null) k.senden(utf8.encode('$zeile\n'));
  }

  /// Beendet die Sitzung, damit die App sie nicht bis zu ihrem Ende hält.
  Future<void> _beenden() async {
    final k = _kanal;
    _kanal = null;
    if (k != null) await k.schliessen();
  }

  void _fehler(Object? id, int code, String text) => ausgabe(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': text},
    }),
  );
}
