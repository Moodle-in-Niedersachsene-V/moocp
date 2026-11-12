// Die laufenden Plugins (E35): starten, was die Lehrkraft angenommen hat,
// ihre Werkzeuge in den MCP-Servern der Profile anbieten, in denen sie
// eingeschaltet sind, nach einem Absturz einmal neu starten und beim Beenden
// der App wieder beenden.
//
// Ein Plugin läuft einmal je App, auch mit mehreren Instanzprofilen; jeder
// Aufruf trägt das Profil, über das er kam (verbindung.dart). Gestartet wird
// jedes zugestimmte Plugin, auch eines, das gerade in keinem Profil
// eingeschaltet ist: Das Einschalten im Dialog „Plugins“ wirkt für Aufrufe
// sofort, und dafür muss es schon laufen.
//
// Start: ein freier Port auf 127.0.0.1 als Kommandozeilenparameter
// (`--port <Zahl>`), ein bei jedem Start neu erzeugter Schlüssel in der
// Umgebung des Prozesses (verbindung.dart, schluesselVariable), nie auf der
// Kommandozeile. Gemessen unter Windows (test/plugin_start_test.dart): Die
// Kommandozeile des Plugin-Prozesses, wie Win32_Process sie jedem Programm
// des Benutzers zeigt, enthält den Port und nicht den Schlüssel. Die Umgebung
// eines Prozesses steht in keiner Prozessliste; lesen kann sie nur, wer den
// Speicher des Prozesses lesen darf.
//
// Mit dem Schlüssel eines Starts meldet sich das Plugin auch an der Adresse
// der App für Plugins an (app_adresse.dart), die vor dem ersten Plugin
// öffnet; nach einem Neustart gilt dort nur der neue. Solange ein Aufruf beim
// Plugin läuft, gilt sein Token dort für dieses Plugin.
//
// Was das Plugin auf stdout und stderr schreibt, liest die App und verwirft
// es (E11): weder Konsole noch Protokoll, und ein volles Rohr hält das Plugin
// nicht an. Die Standardeingabe bleibt offen; endet sie, weil die App fort
// ist, beendet sich ein Plugin selbst (README, Teil 4) -- so bleibt keines
// zurück, auch wenn die App nicht ordentlich enden konnte.
//
// Ein Entwicklungs-Plugin (entwicklung.dart) startet die App nicht, sie hängt
// es an ([anhaengen]); seine Werkzeuge bietet sie hier mit an, in jedem
// Instanzprofil. Ein installiertes Plugin mit demselben Kurznamen startet in
// diesem Lauf nicht; seine Zustimmung und seine gemerkte Werkzeugliste bleiben,
// wie sie sind. Neustart und Ausfall unten gelten für ein angehängtes Plugin
// nicht.
//
// Ausfall: Je Lauf der App bekommt jedes Plugin genau einen zweiten Start,
// gleich wofür -- weil es beim Start nicht binnen der Startfrist antwortete
// oder sich dabei beendete, oder weil sein Programm später unerwartet endete.
// Der zweite Start ist ein ganz neuer: neuer Port, neuer Schlüssel, und die
// Prüfsumme des Ordners wird wieder gegen die Zustimmung geprüft. Danach gilt
// das Plugin bis zum nächsten Start der App als ausgefallen. Nicht öfter, weil
// ein Plugin, das immer wieder abstürzt, sonst die App in einer Schleife
// beschäftigte und die KI Aufruf um Aufruf ins Leere schickte. Ein Aufruf,
// der beim Absturz lief, wird nicht wiederholt: Ein Schreibvorgang könnte
// schon halb gelaufen sein. Die Werkzeuge eines ausgefallenen Plugins bleiben
// in der Werkzeugliste und antworten mit einem Fehler, der das Plugin nennt:
// So bekommt die KI einen Grund, den sie der Lehrkraft sagen kann, statt
// „unbekanntes Werkzeug“. Ins Protokoll gehen Absturz (mit Exit-Code),
// Neustart und Ausfall, nie etwas aus stdout oder stderr des Plugins.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../mcp/werkzeugquelle.dart';
import '../moodle/moodle_zugang.dart' show MoodleFehler;
import '../plattform/plattform.dart';
import '../profil.dart';
import '../protokoll.dart';
import 'app_adresse.dart';
import 'beschreibung.dart';
import 'entwicklung.dart';
import 'plugins.dart';
import 'pruefsumme.dart';
import 'verbindung.dart';

/// Startet das Programm eines Plugins; die Vorgabe ist [Process.start].
typedef ProzessStarter =
    Future<Process> Function(
      String programm,
      List<String> argumente, {
      required Map<String, String> umgebung,
      required String arbeitsordner,
    });

Future<Process> _prozessStarten(
  String programm,
  List<String> argumente, {
  required Map<String, String> umgebung,
  required String arbeitsordner,
}) => Process.start(
  programm,
  argumente,
  environment: umgebung,
  workingDirectory: arbeitsordner,
);

/// Wie oft das Programm eines Plugins je Lauf der App starten darf: der
/// Start und ein zweiter Versuch.
const _startsHoechstens = 2;

/// Name und Version eines Plugins für das Protokoll.
String _name(PluginEintrag e) => '„${e.anzeigename}“ ${e.beschreibung!.version}';

/// Was die KI von jedem Werkzeug eines ausgefallenen Plugins bekommt, und
/// von dem Aufruf, der beim Absturz lief.
String _ausfallText(PluginEintrag e) =>
    'Das Plugin „${e.anzeigename}“ ist ausgefallen. Seine Werkzeuge stehen erst '
    'wieder zur Verfügung, wenn moocp neu gestartet wird.';

class _Laufend {
  _Laufend(this.eintrag, this.prozess, this.verbindung, this.beendet, this.schluessel);
  final PluginEintrag eintrag;
  final Process prozess;
  final PluginVerbindung verbindung;
  final Future<int> beendet;

  /// Der Schlüssel dieses Starts, für das Abmelden an der Adresse der App.
  /// Geheim: in keinem Protokoll.
  final String schluessel;

  /// Erfüllt sich, wenn das Programm unerwartet endet; ein laufender Aufruf
  /// bekommt dann sofort den Fehler, statt auf eine Antwort zu warten, die
  /// nicht mehr kommt.
  final abgestuerzt = Completer<void>();

  String get name => _name(eintrag);
}

/// Die laufenden Plugins und ihre Werkzeuge, als eine Werkzeugquelle für die
/// MCP-Server aller Profile.
class LaufendePlugins implements WerkzeugQuelle {
  LaufendePlugins(
    this._protokoll, {
    this.starter = _prozessStarten,
    this.startfrist = const Duration(seconds: 20),
    this.entwicklungsIntervall = const Duration(seconds: 3),
    this.entwicklungsFrist = const Duration(seconds: 2),
  });

  final Protokoll _protokoll;

  /// Wie das Programm eines Plugins gestartet wird; die Vorgabe ist
  /// [Process.start] mit Umgebung und Arbeitsordner.
  final ProzessStarter starter;

  /// So lange darf ein Plugin brauchen, bis es auf initialize antwortet und
  /// seine Werkzeuge nennt; danach gilt der Versuch als gescheitert.
  final Duration startfrist;

  /// Für ein Entwicklungs-Plugin: wie oft die App nachsieht, ob die
  /// Verbindung steht, und wie lange ein Versuch dauern darf
  /// ([AngehaengtesPlugin]).
  final Duration entwicklungsIntervall;
  final Duration entwicklungsFrist;

  Plugins? _plugins;

  /// Das angehängte Entwicklungs-Plugin; null ohne `--plugin-entwicklung` oder
  /// wenn die Lehrkraft es abgelehnt hat.
  AngehaengtesPlugin? _angehaengt;

  /// Die Namen der eingebauten Werkzeuge, aus [starten]; auch ein Neustart
  /// prüft die Werkzeugnamen dagegen.
  Set<String> _eingebaut = const {};

  final _laufend = <String, _Laufend>{};
  final _fehler = <String, String>{};

  /// Wie oft das Programm eines Plugins in diesem Lauf der App gestartet
  /// wurde (je Ordner); höchstens [_startsHoechstens].
  final _starts = <String, int>{};

  /// Plugins, die nach einem Absturz gerade neu starten: die Werkzeuge von
  /// vorher, damit sie in der Liste bleiben, und der Neustart, auf den ein
  /// Aufruf wartet.
  final _neustart = <String, ({PluginEintrag eintrag, List<WerkzeugBeschreibung> werkzeuge, Future<void> fertig})>{};

  /// Ausgefallene Plugins mit den Werkzeugen, die sie zuletzt genannt haben;
  /// leer, wenn sie nie welche genannt haben.
  final _ausgefallen = <String, ({PluginEintrag eintrag, List<WerkzeugBeschreibung> werkzeuge})>{};

  /// Prozesse, deren Plugin gerade startet: [beenden] beendet auch sie, damit
  /// keines zurückbleibt, wenn die App während des Starts geschlossen wird.
  final _imStart = <Process, Future<int>>{};

  /// Gesetzt von [beenden]; danach startet nichts mehr, und ein endendes
  /// Programm ist kein Absturz.
  bool _beendet = false;

  /// Die Adresse der App für Plugins (app_adresse.dart): geöffnet vor dem
  /// ersten Plugin, geschlossen mit [beenden]. Ohne Plugin gibt es sie nicht.
  Future<AppAdresse>? _adresse;

  /// Die geöffnete Adresse, sobald [_adresse] sich erfüllt hat.
  AppAdresse? _offen;

  Future<AppAdresse> _adresseHolen() =>
      _adresse ??= AppAdresse.starten(_protokoll).then((a) => _offen = a);

  /// Die Adresse der App für Plugins; null, solange kein Plugin gestartet
  /// oder angehängt ist.
  Uri? get appAdresse => _offen?.adresse;

  /// Warum das Plugin nicht läuft, ein Satz auf Deutsch; null, wenn es läuft
  /// oder nicht gestartet werden sollte.
  String? startfehler(PluginEintrag e) => _fehler[e.ordner];

  /// Ob das Plugin läuft.
  bool laeuft(PluginEintrag e) => _laufend.containsKey(e.ordner);

  /// Ob das Plugin ausgefallen ist: Es läuft bis zum nächsten Start der App
  /// nicht mehr; der Grund steht in [startfehler].
  bool ausgefallen(PluginEintrag e) => _ausgefallen.containsKey(e.ordner);

  /// Die Namen der ausgefallenen Plugins, für die Titelzeile. Jeder Ausfall
  /// schreibt eine Zeile ins Protokoll; die Titelzeile folgt dem Protokoll
  /// und erfährt so davon.
  List<String> get ausgefalleneNamen => [for (final a in _ausgefallen.values) a.eintrag.anzeigename];

  /// Das angehängte Entwicklungs-Plugin für die Titelzeile: Name und ob es
  /// gerade verbunden ist; null, wenn keines angehängt ist. Jede Verbindung
  /// und jeder Verlust schreibt eine Zeile ins Protokoll, dem die Titelzeile
  /// folgt.
  ({String name, bool verbunden})? get entwicklung => switch (_angehaengt) {
    final a? => (name: a.plugin.name, verbunden: a.verbunden),
    null => null,
  };

  /// Hängt das Entwicklungs-Plugin an, dem die Lehrkraft in diesem Lauf
  /// zugestimmt hat (entwicklung.dart): einmal je App, vor [starten], damit
  /// ein installiertes Plugin mit demselben Kurznamen nicht startet. Wartet
  /// höchstens auf den ersten Versuch; ist das Plugin noch nicht erreichbar,
  /// verbindet sich die App später. Nichts davon geht in die Einstellungen.
  Future<void> anhaengen(EntwicklungsPlugin plugin, {required Set<String> eingebaut}) async {
    if (_angehaengt != null || _beendet) return;
    _eingebaut = eingebaut;
    AppAdresse? adresse;
    try {
      adresse = await _adresseHolen();
    } on SocketException {
      _protokoll.eintrag(Art.fehler, 'Die Adresse der App für Plugins ließ sich nicht öffnen.');
    }
    final a = AngehaengtesPlugin(
      plugin,
      _protokoll,
      vergeben: () => _vergeben(ohne: ''),
      intervall: entwicklungsIntervall,
      versuchsfrist: entwicklungsFrist,
      adresse: adresse,
    );
    _angehaengt = a;
    await a.starten();
  }

  /// Startet jedes Plugin, dem für seinen jetzigen Stand zugestimmt ist und
  /// das noch nicht läuft, nacheinander in der Reihenfolge von
  /// [Plugins.eintraege]. [eingebaut] sind die Namen der eingebauten
  /// Werkzeuge; ein Plugin, dessen Werkzeug einen davon oder den eines schon
  /// gestarteten Plugins trägt, lädt nicht. Was nicht startet, steht mit dem
  /// Grund im Protokoll und in [startfehler]; die App läuft ohne es. Antwortet
  /// ein Plugin nicht binnen der [startfrist] oder endet es dabei, bekommt es
  /// einen zweiten Versuch; scheitert auch der, ist es ausgefallen.
  ///
  /// Die Werkzeugliste eines gestarteten Plugins merkt sich die App in den
  /// Einstellungen ([Plugins.werkzeugeMerken]), damit `moocp.exe
  /// --werkzeugliste` sie ohne das Plugin ausgeben kann; vorher verwirft sie
  /// die gemerkten Listen, die zu keinem zugestimmten Stand mehr gehören
  /// ([Plugins.werkzeugeAufraeumen]). Aufgeräumt wird hier und nicht beim
  /// Suchen, weil erst jetzt feststeht, wem die Lehrkraft zugestimmt hat.
  Future<void> starten(Plugins plugins, {required Set<String> eingebaut}) async {
    _plugins = plugins;
    _eingebaut = eingebaut;
    await plugins.werkzeugeAufraeumen();
    for (final stand in plugins.staende) {
      if (_beendet) return;
      final e = stand.eintrag;
      if (stand.zustand != PluginZustand.zugestimmt || _bekannt(e.ordner)) continue;
      if (_angehaengt case final a? when a.plugin.kurzname == e.beschreibung!.kurzname) {
        const grund = 'In diesem Lauf ist ein Entwicklungs-Plugin mit demselben Kurznamen angehängt.';
        _fehler[e.ordner] = grund;
        _protokoll.eintrag(Art.info, 'Plugin „${e.anzeigename}“ nicht gestartet: $grund');
        continue;
      }
      while (true) {
        try {
          final laufend = await _starten(e);
          _einsetzen(laufend);
          _protokoll.eintrag(
            Art.info,
            'Plugin ${laufend.name} gestartet (${laufend.verbindung.werkzeuge.length} Werkzeuge)',
          );
          await plugins.werkzeugeMerken(e, laufend.verbindung.werkzeuge);
        } on PluginStartFehler catch (f) {
          if (_beendet) return;
          if (_nochEinStart(e)) {
            _protokoll.eintrag(
              Art.fehler,
              'Plugin „${e.anzeigename}“ nicht gestartet: ${f.grund} moocp versucht es noch einmal.',
            );
            continue;
          }
          _ausfallen(e, const [], f.grund);
        } on PluginFehler catch (f) {
          _fehler[e.ordner] = f.grund;
          _protokoll.eintrag(Art.fehler, 'Plugin „${e.anzeigename}“ nicht gestartet: ${f.grund}');
        }
        break;
      }
    }
  }

  bool _bekannt(String ordner) =>
      _laufend.containsKey(ordner) || _neustart.containsKey(ordner) || _ausgefallen.containsKey(ordner);

  bool _nochEinStart(PluginEintrag e) => (_starts[e.ordner] ?? 0) < _startsHoechstens;

  Future<_Laufend> _starten(PluginEintrag e) async {
    final b = e.beschreibung!;
    // Unmittelbar vor dem Start noch einmal, auch vor einem Neustart: Seit der
    // Suche kann jemand Dateien ausgetauscht haben. Weicht die Summe ab,
    // startet das Plugin nicht; beim nächsten Start fragt die Zustimmung neu.
    final String summe;
    try {
      summe = await pluginPruefsumme(Directory(e.pfad));
    } on FileSystemException catch (x) {
      throw PluginFehler('Die Dateien des Plugins lassen sich nicht lesen (${x.runtimeType}).');
    }
    if (summe != e.pruefsumme) {
      throw const PluginFehler(
        'Die Dateien des Plugins haben sich seit der Zustimmung geändert; moocp fragt beim nächsten Start neu.',
      );
    }
    if (_beendet) throw const PluginFehler('moocp wurde während des Starts beendet.');
    final AppAdresse adresse;
    try {
      adresse = await _adresseHolen();
    } on SocketException {
      throw const PluginFehler('Die Adresse der App für Plugins ließ sich nicht öffnen.');
    }
    final port = await _freierPort();
    final schluessel = _schluessel();
    _starts[e.ordner] = (_starts[e.ordner] ?? 0) + 1;
    // Mit dem Schlüssel dieses Starts meldet sich das Plugin an der Adresse
    // der App an; der Schlüssel eines früheren Starts gilt dort nicht mehr.
    adresse.pluginAnmelden(b.kurzname, e.anzeigename, schluessel);
    final Process prozess;
    try {
      prozess = await starter(
        e.programmPfad!,
        ['--port', '$port'],
        umgebung: {schluesselVariable: schluessel},
        arbeitsordner: e.pfad,
      );
    } on ProcessException {
      adresse.pluginAbmelden(b.kurzname, schluessel);
      throw const PluginFehler('Das Programm des Plugins ließ sich nicht starten.');
    }
    // E11: lesen und verwerfen.
    prozess.stdout.listen((_) {}, onError: (_) {});
    prozess.stderr.listen((_) {}, onError: (_) {});
    var lebt = true;
    final beendet = prozess.exitCode.whenComplete(() => lebt = false);
    _imStart[prozess] = beendet;
    try {
      final verbindung = await PluginVerbindung.verbinden(
        port: port,
        schluessel: schluessel,
        kurzname: b.kurzname,
        vergeben: _vergeben(ohne: e.ordner),
        frist: startfrist,
        weiter: () => lebt && !_beendet,
        adresse: adresse.adresse,
      );
      if (_beendet) {
        await verbindung.schliessen();
        throw const PluginFehler('moocp wurde während des Starts beendet.');
      }
      return _Laufend(e, prozess, verbindung, beendet, schluessel);
    } catch (_) {
      adresse.pluginAbmelden(b.kurzname, schluessel);
      await _prozessBeenden(prozess, beendet);
      rethrow;
    } finally {
      _imStart.remove(prozess);
    }
  }

  /// Die Werkzeugnamen der eingebauten Werkzeuge und aller anderen Plugins,
  /// auch der ausgefallenen: Deren Werkzeuge bleiben in der Liste. Für das
  /// Entwicklungs-Plugin selbst ist [ohne] leer; seine eigenen Werkzeuge
  /// zählen dann nicht, für jedes andere Plugin schon.
  Set<String> _vergeben({required String ohne}) => {
    ..._eingebaut,
    for (final (e, liste) in _alle())
      if (e.ordner != ohne) ...liste.map((w) => w.name),
    if (ohne.isNotEmpty) ...?_angehaengt?.werkzeuge.map((w) => w.name),
  };

  /// Jedes Plugin mit Werkzeugen in der Liste: laufend, im Neustart,
  /// ausgefallen.
  Iterable<(PluginEintrag, List<WerkzeugBeschreibung>)> _alle() sync* {
    for (final l in _laufend.values) {
      yield (l.eintrag, l.verbindung.werkzeuge);
    }
    for (final n in _neustart.values) {
      yield (n.eintrag, n.werkzeuge);
    }
    for (final a in _ausgefallen.values) {
      yield (a.eintrag, a.werkzeuge);
    }
  }

  /// Nimmt ein gestartetes Plugin auf und achtet von nun an darauf, ob sein
  /// Programm unerwartet endet.
  void _einsetzen(_Laufend l) {
    _laufend[l.eintrag.ordner] = l;
    _fehler.remove(l.eintrag.ordner);
    unawaited(l.beendet.then((code) => _abgestuerzt(l, code)));
  }

  /// Das Programm eines laufenden Plugins ist zu Ende. Hat die App es selbst
  /// beendet ([beenden] nimmt es vorher aus der Liste), ist das kein Absturz.
  void _abgestuerzt(_Laufend l, int code) {
    final e = l.eintrag;
    if (_beendet || !identical(_laufend[e.ordner], l)) return;
    _laufend.remove(e.ordner);
    l.abgestuerzt.complete();
    _offen?.pluginAbmelden(e.beschreibung!.kurzname, l.schluessel);
    unawaited(l.verbindung.schliessen());
    _protokoll.eintrag(Art.fehler, 'Plugin ${l.name} unerwartet beendet (Exit-Code $code)');
    final werkzeuge = l.verbindung.werkzeuge;
    if (!_nochEinStart(e)) {
      _ausfallen(e, werkzeuge, 'Es hat sich unerwartet beendet und hatte seinen zweiten Start schon.');
      return;
    }
    _neustart[e.ordner] = (eintrag: e, werkzeuge: werkzeuge, fertig: _neustarten(e, werkzeuge));
  }

  /// Der eine Neustart nach einem Absturz. Liefert das Plugin danach andere
  /// Werkzeuge, gelten sie ab der nächsten Sitzung eines KI-Werkzeugs (der
  /// MCP-Server fragt die Liste je Sitzung); die Namensregeln gelten neu.
  Future<void> _neustarten(PluginEintrag e, List<WerkzeugBeschreibung> vorher) async {
    // Erst nach einem Schritt, damit _abgestuerzt den Neustart eingetragen
    // hat, bevor er ihn wieder austrägt.
    await Future<void>.delayed(Duration.zero);
    final _Laufend l;
    try {
      l = await _starten(e);
    } on PluginFehler catch (f) {
      _neustart.remove(e.ordner);
      if (!_beendet) _ausfallen(e, vorher, f.grund);
      return;
    } catch (x) {
      _neustart.remove(e.ordner);
      if (!_beendet) _ausfallen(e, vorher, 'Der Neustart ist gescheitert (${x.runtimeType}).');
      return;
    }
    _neustart.remove(e.ordner);
    _einsetzen(l);
    _protokoll.eintrag(Art.info, 'Plugin ${l.name} neu gestartet (${l.verbindung.werkzeuge.length} Werkzeuge)');
    try {
      await _plugins?.werkzeugeMerken(e, l.verbindung.werkzeuge);
    } catch (x) {
      _protokoll.eintrag(Art.fehler, 'Werkzeugliste des Plugins ${l.name} nicht gemerkt (${x.runtimeType})');
    }
  }

  void _ausfallen(PluginEintrag e, List<WerkzeugBeschreibung> werkzeuge, String grund) {
    _ausgefallen[e.ordner] = (eintrag: e, werkzeuge: werkzeuge);
    _fehler[e.ordner] = grund;
    _protokoll.eintrag(
      Art.fehler,
      'Plugin ${_name(e)} ausgefallen: $grund Es läuft erst nach einem Neustart von moocp wieder.',
    );
  }

  @override
  List<WerkzeugBeschreibung> werkzeuge(Profil profil) => [
    for (final (e, liste) in _alle())
      if (_aktiv(e, profil)) ...liste,
    // Ein Entwicklungs-Plugin ist in jedem Profil eingeschaltet.
    ...?_angehaengt?.werkzeuge,
  ];

  bool _aktiv(PluginEintrag e, Profil profil) => _plugins?.stand(e).aktivIn(profil.kennung) ?? false;

  /// Führt den Aufruf beim Plugin aus. Solange er läuft, gilt sein Token an
  /// der Adresse der App für genau dieses Plugin (app_adresse.dart); danach
  /// und nach einem Abbruch nicht mehr.
  @override
  Future<String> aufrufen(WerkzeugAufruf aufruf) async {
    final angehaengt = _angehaengt;
    if (angehaengt != null && angehaengt.werkzeuge.any((w) => w.name == aufruf.name)) {
      return _mitToken(angehaengt.plugin.kurzname, aufruf, () => angehaengt.aufrufen(aufruf));
    }
    while (true) {
      final e = _besitzer(aufruf.name);
      if (e == null) throw MoodleFehler('Das Werkzeug „${aufruf.name}“ gehört zu keinem laufenden Plugin.');
      // Gefragt wird bei jedem Aufruf: Ausschalten im Dialog „Plugins“ wirkt
      // sofort, auch in einer Sitzung, die das Werkzeug noch in ihrer Liste
      // hat.
      if (!_aktiv(e, aufruf.profil)) {
        throw MoodleFehler(
          'Das Plugin „${e.anzeigename}“ ist im Profil „${aufruf.profil.name}“ nicht eingeschaltet; '
          'sein Werkzeug steht hier nicht zur Verfügung.',
        );
      }
      // Startet das Plugin gerade neu, wartet der Aufruf darauf und schaut
      // dann noch einmal: Danach läuft es, ist ausgefallen oder hat das
      // Werkzeug nicht mehr.
      final neustart = _neustart[e.ordner];
      if (neustart != null) {
        await neustart.fertig;
        continue;
      }
      final l = _laufend[e.ordner];
      if (l == null) throw MoodleFehler(_ausfallText(e));
      return _mitToken(e.beschreibung!.kurzname, aufruf, () => _aufrufenBei(l, aufruf));
    }
  }

  Future<String> _mitToken(String kurzname, WerkzeugAufruf aufruf, Future<String> Function() f) async {
    final ende = _offen?.aufrufAnmelden(kurzname, aufruf);
    try {
      return await f();
    } finally {
      ende?.call();
    }
  }

  PluginEintrag? _besitzer(String werkzeug) {
    for (final (e, liste) in _alle()) {
      if (liste.any((w) => w.name == werkzeug)) return e;
    }
    return null;
  }

  /// Ein Aufruf bei einem laufenden Plugin. Endet sein Programm dabei, kommt
  /// der Fehler des Ausfalls sofort; der Aufruf wird nicht wiederholt, auch
  /// wenn der Neustart gelingt.
  Future<String> _aufrufenBei(_Laufend l, WerkzeugAufruf aufruf) async {
    final text = _ausfallText(l.eintrag);
    try {
      return await Future.any([
        l.verbindung.aufrufen(aufruf),
        l.abgestuerzt.future.then<String>((_) => throw MoodleFehler(text)),
      ]);
    } on MoodleFehler {
      rethrow;
    } catch (_) {
      // Endet das Programm, bricht oft zuerst die Verbindung ab, und das Ende
      // des Prozesses kommt einen Augenblick später. Ist es dann zu Ende,
      // war es der Absturz; sonst bleibt es beim Fehler der Verbindung.
      final weg = await l.abgestuerzt.future
          .then((_) => true)
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
      if (weg) throw MoodleFehler(text);
      rethrow;
    }
  }

  /// Beendet alle laufenden Plugins: Verbindung schließen, Standardeingabe
  /// schließen, höchstens drei Sekunden warten, dann hart beenden
  /// (plattform.dart, unter Windows samt den Prozessen, die das Plugin selbst
  /// gestartet hat). Alle zugleich, damit das Beenden der App nicht je Plugin
  /// wartet; ebenso ein Plugin, das gerade startet oder neu startet. Das ist
  /// kein Absturz: kein Neustart, kein Ausfall.
  Future<void> beenden() async {
    _beendet = true;
    final alle = _laufend.values.toList();
    _laufend.clear();
    await Future.wait([
      ?_angehaengt?.beenden(),
      for (final MapEntry(key: prozess, value: beendet) in _imStart.entries.toList())
        _prozessBeenden(prozess, beendet),
      for (final l in alle)
        () async {
          await l.verbindung.schliessen();
          await _prozessBeenden(l.prozess, l.beendet);
          _protokoll.eintrag(Art.info, 'Plugin ${l.name} beendet');
        }(),
    ]);
    final adresse = _adresse;
    if (adresse != null) {
      try {
        await (await adresse).beenden();
      } catch (_) {
        // Ließ sie sich nicht öffnen, ist nichts zu schließen.
      }
    }
  }

  static Future<void> _prozessBeenden(Process prozess, Future<int> beendet) async {
    try {
      await prozess.stdin.close();
    } catch (_) {
      // Das Rohr ist schon zu, weil der Prozess fort ist.
    }
    try {
      await beendet.timeout(const Duration(seconds: 3));
      return;
    } on TimeoutException {
      await prozessbaumBeenden(prozess);
    }
    // Hart beendet endet er gleich; wartet die App nicht darauf, bliebe
    // er in Tests noch einen Augenblick in der Prozessliste.
    await beendet.timeout(const Duration(seconds: 3), onTimeout: () => -1);
  }

  static Future<int> _freierPort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  /// 32 Bytes aus dem sicheren Zufall. Steht in keinem Protokoll.
  static String _schluessel() {
    final zufall = Random.secure();
    return base64Url.encode([for (var i = 0; i < 32; i++) zufall.nextInt(256)]).replaceAll('=', '');
  }
}
