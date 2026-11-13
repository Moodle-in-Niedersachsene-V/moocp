// Ein Entwicklungs-Plugin (E35, „Entwickeln“): `moocp --plugin-entwicklung
// <Ordner>` liest die Beschreibungsdatei aus diesem Ordner und verbindet sich
// mit dem Plugin, das auf seinem Entwicklungsport schon läuft, statt es zu
// starten. So läuft es im Debugger seines Entwicklers, und der braucht dafür
// nur die installierte App.
//
// Die Regeln, die das so sicher halten wie ein installiertes Plugin:
//
// - Die Beschreibungsdatei gilt wie sonst (plugins.dart, beschreibungLesen):
//   dieselben Prüfungen, auch der gesperrten Bereiche und der Länge des
//   Kurznamens; Zusatzadressen sind nur die dort angemeldeten. Ob das
//   Programm aus `programm` im Ordner liegt, prüft die App hier nicht: Sie
//   startet es nicht, und im Ordner eines Entwicklers liegt oft nur der
//   Quelltext.
// - Der Schlüssel kommt aus der Umgebungsvariablen der App
//   ([schluesselVariable], dieselbe, die ein gestartetes Plugin bekommt), nie
//   von der Kommandozeile, wo er in jeder Prozessliste stünde. Ohne Schlüssel
//   verbindet sich die App nicht: Sonst stünde die Adresse der App für das
//   Plugin jedem Programm auf dem Rechner offen. Er steht in keinem Protokoll
//   und in keinem Dialog.
// - Vor dem Verbinden fragt bei jedem Start der App ein Dialog
//   (einstellungen_dialog.dart, entwicklungSchritt); die Antwort wird nie
//   gespeichert. Die App weiß nicht, welcher Code hinter dem Port läuft, eine
//   gemerkte Zustimmung oder eine Prüfsumme wäre nichts wert: Der Dialog tritt
//   an ihre Stelle. Der Testbetrieb beantwortet ihn nie.
// - Verbunden wird nur mit 127.0.0.1 (verbindung.dart).
// - An der Adresse der App für Plugins (app_adresse.dart) gilt derselbe
//   Schlüssel, solange das Plugin angehängt ist.
//
// Gefragt wird einmal je Start: Wird das Plugin neu gebaut und neu
// gestartet, verbindet sich die laufende App wieder, ohne neuen Dialog, mit
// demselben Schlüssel, und liest die Werkzeugliste neu. Den einen Neustart
// und den Ausfall eines gestarteten Plugins (laufende_plugins.dart) gibt es
// hier nicht: Die App hat das Plugin nicht gestartet und beendet es auch
// nicht.
//
// Ob die Verbindung noch steht, erfährt die App nicht von einem Prozess wie
// bei einem gestarteten Plugin, sondern nur vom Plugin selbst: alle
// [AngehaengtesPlugin.intervall] ein `ping`. Ein neu gestartetes Plugin kennt
// die alte Sitzung nicht und weist ihn ab; so merkt die App auch einen
// Neustart, der schneller ging als ein Intervall.
//
// Die letzte Sperre gegen Namen (namenssperre.dart) gilt hier wie bei einem
// gestarteten Plugin: Die Namen, die das Plugin genannt hat, bleiben über das
// Wiederverbinden hinaus; seine Antworten prüft laufende_plugins.dart, die
// neu gelesene Werkzeugliste [AngehaengtesPlugin] beim Verbinden.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../mcp/werkzeugquelle.dart';
import '../moodle/moodle_zugang.dart' show MoodleFehler;
import '../protokoll.dart';
import 'app_adresse.dart';
import 'beschreibung.dart';
import 'namenssperre.dart';
import 'plugins.dart';
import 'schnittstelle.dart';
import 'verbindung.dart';

/// Der Schalter auf der Kommandozeile; danach steht der Ordner des Plugins.
const pluginEntwicklungSchalter = '--plugin-entwicklung';

/// Der Ordner hinter [pluginEntwicklungSchalter]: null, wenn der Schalter
/// fehlt; leer, wenn er da ist, aber kein Ordner folgt (am Ende oder vor dem
/// nächsten Schalter). Steht er mehrfach da, gilt der erste.
String? entwicklungsOrdnerAus(List<String> argumente) {
  final i = argumente.indexOf(pluginEntwicklungSchalter);
  if (i < 0) return null;
  if (i + 1 >= argumente.length) return '';
  final ordner = argumente[i + 1];
  return ordner.startsWith('--') ? '' : ordner.trim();
}

/// Ein Entwicklungs-Plugin, dessen Beschreibungsdatei gelesen und dessen
/// Schlüssel da ist; noch nicht verbunden. Erst der Dialog entscheidet, ob
/// die App sich verbindet.
class EntwicklungsPlugin {
  /// [_schluessel] steht vorn, weil ein benannter Parameter nicht privat sein
  /// kann.
  EntwicklungsPlugin(
    this._schluessel, {
    required this.ordner,
    required this.beschreibung,
    required this.port,
  });

  /// Der Ordner des Plugins, absolut, wie der Dialog ihn nennt.
  final String ordner;
  final PluginBeschreibung beschreibung;

  /// Der Entwicklungsport aus der Beschreibungsdatei.
  final int port;

  /// Geheim: in keinem Protokoll, keinem Dialog, keinem `toString`.
  final String _schluessel;

  String get name => beschreibung.name;
  String get kurzname => beschreibung.kurzname;
}

/// Liest die Beschreibungsdatei aus [ordner] (von der Kommandozeile,
/// [entwicklungsOrdnerAus]) und den Schlüssel aus [umgebung]. Wirft
/// [PluginFehler] mit einem Satz für die Lehrkraft, ohne Inhalte der Datei
/// (E11) und ohne den Schlüssel: Ordner fehlt, Beschreibungsdatei unlesbar
/// oder ungültig, Schnittstelle passt nicht, kein Entwicklungsport, kein
/// Schlüssel.
EntwicklungsPlugin entwicklungVorbereiten(String ordner, Map<String, String> umgebung) {
  if (ordner.isEmpty) {
    throw const PluginFehler('Nach $pluginEntwicklungSchalter fehlt der Ordner des Plugins.');
  }
  final pfad = p.normalize(p.absolute(ordner));
  if (!Directory(pfad).existsSync()) {
    throw PluginFehler('Den Ordner „$pfad“ gibt es nicht.');
  }
  final beschreibung = beschreibungLesen(pfad);
  // Die Schnittstelle gilt wie für ein installiertes Plugin
  // (schnittstelle.dart); nach einem Update sucht die App für ein
  // Entwicklungs-Plugin nie, das baut sein Entwickler selbst.
  final urteil = schnittstelleUrteil(beschreibung.schnittstelle);
  if (urteil != SchnittstellenUrteil.passt) {
    throw PluginFehler(schnittstelleGrund(urteil, beschreibung.schnittstelle));
  }
  final port = beschreibung.entwicklungsPort;
  if (port == null) {
    throw const PluginFehler('Die Beschreibungsdatei nennt keinen Entwicklungsport (Feld „entwicklungsPort“).');
  }
  final schluessel = (umgebung[schluesselVariable] ?? '').trim();
  if (schluessel.isEmpty) {
    throw const PluginFehler(
      'Die Umgebungsvariable $schluesselVariable mit dem Schlüssel fehlt oder ist leer; '
      'ohne Schlüssel verbindet sich moocp nicht.',
    );
  }
  return EntwicklungsPlugin(schluessel, ordner: pfad, beschreibung: beschreibung, port: port);
}

/// Ein angehängtes Entwicklungs-Plugin: die Verbindung, die zuletzt bekannten
/// Werkzeuge und das Wiederverbinden. Eine Werkzeugquelle ist es nicht selbst;
/// laufende_plugins.dart bietet seine Werkzeuge neben denen der gestarteten
/// Plugins an, in jedem Instanzprofil.
class AngehaengtesPlugin {
  AngehaengtesPlugin(
    this.plugin,
    this._protokoll, {
    required this.vergeben,
    this.intervall = const Duration(seconds: 3),
    this.versuchsfrist = const Duration(seconds: 2),
    this.adresse,
    this.sperre,
  }) {
    // Derselbe Schlüssel wie für die Verbindung, solange die App läuft: Auch
    // ein neu gestartetes Plugin bekommt ihn von seinem Entwickler wieder.
    adresse?.pluginAnmelden(
      plugin.kurzname,
      plugin.name,
      plugin._schluessel,
      zusatzadressen: plugin.beschreibung.zusatzadressen,
    );
  }

  final EntwicklungsPlugin plugin;
  final Protokoll _protokoll;

  /// Die Adresse der App für Plugins (app_adresse.dart); sie geht bei jeder
  /// Verbindung an das Plugin.
  final AppAdresse? adresse;

  /// Die Namen der letzten Sperre, gegen die die Werkzeugliste jeder
  /// Verbindung geprüft wird; null ohne Prüfung (Tests).
  final LetzteSperre? sperre;

  /// Die Werkzeugnamen, die schon vergeben sind (eingebaute, andere Plugins);
  /// gefragt bei jeder Verbindung, denn die Namensregeln gelten jedes Mal neu.
  final Set<String> Function() vergeben;

  /// So oft fragt die App, ob die Verbindung noch steht, und versucht es
  /// wieder, wenn nicht. Kurz, damit ein Neubau keine Wartezeit kostet; Tests
  /// stellen es kürzer.
  final Duration intervall;

  /// So lange darf ein Versuch dauern, bis das Plugin auf initialize und
  /// tools/list antwortet.
  final Duration versuchsfrist;

  PluginVerbindung? _verbindung;
  List<WerkzeugBeschreibung> _werkzeuge = const [];
  bool _jeVerbunden = false;
  bool _beendet = false;

  /// Der Grund des letzten gescheiterten Versuchs, der kein „nicht
  /// erreichbar“ war; nur damit derselbe Grund nicht alle paar Sekunden ins
  /// Protokoll geht.
  String? _letzterFehler;

  final _ende = Completer<void>();
  Future<void>? _schleife;

  /// Ob gerade eine Verbindung besteht.
  bool get verbunden => _verbindung != null;

  /// Die Werkzeuge der aktuellen Verbindung, sonst die zuletzt bekannten:
  /// Sie bleiben gelistet und antworten mit einem Fehler, bis die App wieder
  /// verbunden ist. Leer, solange es nie eine Verbindung gab.
  List<WerkzeugBeschreibung> get werkzeuge => _werkzeuge;

  String get _name => '„${plugin.name}“';

  String get _nichtVerbundenText =>
      'Das Entwicklungs-Plugin $_name ist gerade nicht verbunden. moocp verbindet sich wieder, '
      'sobald es auf Port ${plugin.port} erreichbar ist.';

  /// Versucht die erste Verbindung (höchstens [versuchsfrist]) und wacht ab
  /// dann über sie. Ist das Plugin noch nicht erreichbar, verbindet sich die
  /// App später; Werkzeuge gibt es dann ab der ersten Verbindung.
  Future<void> starten() async {
    await _versuchen();
    _schleife ??= _wachen();
  }

  Future<void> _wachen() async {
    while (!_beendet) {
      await _schlafen();
      if (_beendet) return;
      final v = _verbindung;
      if (v != null) {
        if (await v.lebt(frist: versuchsfrist)) continue;
        _verloren(v);
        if (_beendet) return;
      }
      await _versuchen();
    }
  }

  /// Wartet ein [intervall]; [beenden] weckt sofort, und die Uhr bleibt
  /// nicht stehen.
  Future<void> _schlafen() {
    final wach = Completer<void>();
    final uhr = Timer(intervall, () {
      if (!wach.isCompleted) wach.complete();
    });
    unawaited(_ende.future.then((_) {
      uhr.cancel();
      if (!wach.isCompleted) wach.complete();
    }));
    return wach.future;
  }

  Future<void> _versuchen() async {
    final PluginVerbindung v;
    try {
      v = await PluginVerbindung.verbinden(
        port: plugin.port,
        schluessel: plugin._schluessel,
        kurzname: plugin.kurzname,
        vergeben: vergeben(),
        frist: versuchsfrist,
        weiter: () => !_beendet,
        adresse: adresse?.adresse,
      );
    } on PluginStartFehler {
      // Nicht erreichbar oder keine Antwort in der Frist: Das Plugin läuft
      // gerade nicht. Steht schon im Protokoll (Verbindung verloren) oder
      // ist der Normalfall vor dem ersten Start; still weiter versuchen.
      return;
    } on PluginFehler catch (f) {
      if (f.grund != _letzterFehler && !_beendet) {
        _protokoll.eintrag(Art.fehler, 'Entwicklungs-Plugin $_name nicht verbunden: ${f.grund}');
      }
      _letzterFehler = f.grund;
      return;
    } catch (x) {
      final grund = 'Unerwarteter Fehler (${x.runtimeType}).';
      if (grund != _letzterFehler && !_beendet) {
        _protokoll.eintrag(Art.fehler, 'Entwicklungs-Plugin $_name nicht verbunden: $grund');
      }
      _letzterFehler = grund;
      return;
    }
    if (_beendet) {
      await v.schliessen();
      return;
    }
    // Die Beschreibungen gingen an die KI. Gewarnt und protokolliert wird
    // einmal, nicht bei jedem Versuch im Takt des Intervalls.
    final s = sperre;
    if (s != null && s.treffer(plugin.kurzname, werkzeuglisteTexte(v.werkzeuge)) != null) {
      await v.schliessen();
      if (_letzterFehler != werkzeuglisteGesperrt && !_beendet) {
        s.gesperrt(
          plugin.kurzname,
          werkzeuglisteTexte(v.werkzeuge),
          plugin: plugin.name,
          werkzeug: null,
          stelle: SperrStelle.werkzeugliste,
        );
        _protokoll.eintrag(
          Art.gesperrt,
          'Entwicklungs-Plugin $_name: Werkzeugliste gesperrt (letzte Sperre: könnte einen Namen enthalten)',
        );
      }
      _letzterFehler = werkzeuglisteGesperrt;
      return;
    }
    _verbindung = v;
    _werkzeuge = v.werkzeuge;
    _letzterFehler = null;
    final anzahl = '${v.werkzeuge.length} ${v.werkzeuge.length == 1 ? 'Werkzeug' : 'Werkzeuge'}';
    _protokoll.eintrag(
      Art.info,
      _jeVerbunden
          ? 'Entwicklungs-Plugin $_name wieder verbunden ($anzahl)'
          : 'Entwicklungs-Plugin $_name verbunden ($anzahl)',
    );
    _jeVerbunden = true;
  }

  void _verloren(PluginVerbindung v) {
    if (!identical(_verbindung, v)) return;
    _verbindung = null;
    unawaited(v.schliessen());
    if (_beendet) return;
    _protokoll.eintrag(
      Art.fehler,
      'Verbindung zum Entwicklungs-Plugin $_name verloren; moocp verbindet sich wieder, sobald es erreichbar ist',
    );
  }

  /// Ein Aufruf beim Plugin. Ohne Verbindung kommt sofort der Fehler, der
  /// sagt, dass das Entwicklungs-Plugin nicht verbunden ist; ebenso, wenn die
  /// Verbindung während des Aufrufs abreißt. Wiederholt wird nichts.
  Future<String> aufrufen(WerkzeugAufruf aufruf) async {
    final v = _verbindung;
    if (v == null) throw MoodleFehler(_nichtVerbundenText);
    if (!v.werkzeuge.any((w) => w.name == aufruf.name)) {
      throw MoodleFehler(
        'Das Entwicklungs-Plugin $_name hat das Werkzeug „${aufruf.name}“ nicht mehr; '
        'seine neue Werkzeugliste gilt ab der nächsten Sitzung.',
      );
    }
    try {
      return await v.aufrufen(aufruf);
    } on MoodleFehler {
      rethrow;
    } catch (_) {
      if (await v.lebt(frist: versuchsfrist)) rethrow;
      _verloren(v);
      throw MoodleFehler(_nichtVerbundenText);
    }
  }

  /// Trennt die Verbindung und hört auf, wieder zu verbinden. Das Plugin
  /// selbst beendet die App nicht: Es gehört seinem Entwickler.
  Future<void> beenden() async {
    if (_beendet) return;
    _beendet = true;
    _ende.complete();
    adresse?.pluginAbmelden(plugin.kurzname, plugin._schluessel);
    final v = _verbindung;
    _verbindung = null;
    if (v != null) {
      await v.schliessen();
      _protokoll.eintrag(Art.info, 'Verbindung zum Entwicklungs-Plugin $_name getrennt');
    }
    await _schleife;
  }
}
