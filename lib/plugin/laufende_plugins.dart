// Die laufenden Plugins (E35): starten, was die Lehrkraft angenommen hat,
// ihre Werkzeuge in den MCP-Servern der Profile anbieten, in denen sie
// eingeschaltet sind, und beim Beenden der App wieder beenden.
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
// Was das Plugin auf stdout und stderr schreibt, liest die App und verwirft
// es (E11): weder Konsole noch Protokoll, und ein volles Rohr hält das Plugin
// nicht an. Die Standardeingabe bleibt offen; endet sie, weil die App fort
// ist, beendet sich ein Plugin selbst (README, Teil 4) -- so bleibt keines
// zurück, auch wenn die App nicht ordentlich enden konnte.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../mcp/werkzeugquelle.dart';
import '../moodle/moodle_zugang.dart' show MoodleFehler;
import '../plattform/plattform.dart';
import '../profil.dart';
import '../protokoll.dart';
import 'beschreibung.dart';
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

class _Laufend {
  _Laufend(this.eintrag, this.prozess, this.verbindung, this.beendet);
  final PluginEintrag eintrag;
  final Process prozess;
  final PluginVerbindung verbindung;
  final Future<int> beendet;

  String get name => '„${eintrag.anzeigename}“ ${eintrag.beschreibung!.version}';
}

/// Die laufenden Plugins und ihre Werkzeuge, als eine Werkzeugquelle für die
/// MCP-Server aller Profile.
class LaufendePlugins implements WerkzeugQuelle {
  LaufendePlugins(
    this._protokoll, {
    this.starter = _prozessStarten,
    this.startfrist = const Duration(seconds: 20),
  });

  final Protokoll _protokoll;

  /// Wie das Programm eines Plugins gestartet wird; die Vorgabe ist
  /// [Process.start] mit Umgebung und Arbeitsordner.
  final ProzessStarter starter;

  /// So lange darf ein Plugin brauchen, bis es auf initialize antwortet und
  /// seine Werkzeuge nennt; danach gilt es als nicht gestartet.
  final Duration startfrist;

  Plugins? _plugins;
  final _laufend = <String, _Laufend>{};
  final _fehler = <String, String>{};

  /// Prozesse, deren Plugin gerade startet: [beenden] beendet auch sie, damit
  /// keines zurückbleibt, wenn die App während des Starts geschlossen wird.
  final _imStart = <Process, Future<int>>{};

  /// Gesetzt von [beenden]; danach startet nichts mehr.
  bool _beendet = false;

  /// Warum das Plugin nicht läuft, ein Satz auf Deutsch; null, wenn es läuft
  /// oder nicht gestartet werden sollte.
  String? startfehler(PluginEintrag e) => _fehler[e.ordner];

  /// Ob das Plugin läuft.
  bool laeuft(PluginEintrag e) => _laufend.containsKey(e.ordner);

  /// Startet jedes Plugin, dem für seinen jetzigen Stand zugestimmt ist und
  /// das noch nicht läuft, nacheinander in der Reihenfolge von
  /// [Plugins.eintraege]. [eingebaut] sind die Namen der eingebauten
  /// Werkzeuge; ein Plugin, dessen Werkzeug einen davon oder den eines schon
  /// gestarteten Plugins trägt, lädt nicht. Was nicht startet, steht mit dem
  /// Grund im Protokoll und in [startfehler]; die App läuft ohne es.
  ///
  /// Die Werkzeugliste eines gestarteten Plugins merkt sich die App in den
  /// Einstellungen ([Plugins.werkzeugeMerken]), damit `moocp.exe
  /// --werkzeugliste` sie ohne das Plugin ausgeben kann; vorher verwirft sie
  /// die gemerkten Listen, die zu keinem zugestimmten Stand mehr gehören
  /// ([Plugins.werkzeugeAufraeumen]). Aufgeräumt wird hier und nicht beim
  /// Suchen, weil erst jetzt feststeht, wem die Lehrkraft zugestimmt hat.
  Future<void> starten(Plugins plugins, {required Set<String> eingebaut}) async {
    _plugins = plugins;
    await plugins.werkzeugeAufraeumen();
    for (final stand in plugins.staende) {
      if (_beendet) return;
      final e = stand.eintrag;
      if (stand.zustand != PluginZustand.zugestimmt || _laufend.containsKey(e.ordner)) continue;
      try {
        final laufend = await _starten(e, eingebaut);
        _laufend[e.ordner] = laufend;
        _fehler.remove(e.ordner);
        _protokoll.eintrag(
          Art.info,
          'Plugin ${laufend.name} gestartet (${laufend.verbindung.werkzeuge.length} Werkzeuge)',
        );
        await plugins.werkzeugeMerken(e, laufend.verbindung.werkzeuge);
      } on PluginFehler catch (f) {
        _fehler[e.ordner] = f.grund;
        _protokoll.eintrag(Art.fehler, 'Plugin „${e.anzeigename}“ nicht gestartet: ${f.grund}');
      }
    }
  }

  Future<_Laufend> _starten(PluginEintrag e, Set<String> eingebaut) async {
    final b = e.beschreibung!;
    // Unmittelbar vor dem Start noch einmal: Zwischen der Suche und jetzt
    // kann jemand Dateien ausgetauscht haben. Weicht die Summe ab, startet
    // das Plugin nicht; beim nächsten Start fragt die Zustimmung neu.
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
    final port = await _freierPort();
    final schluessel = _schluessel();
    final Process prozess;
    try {
      prozess = await starter(
        e.programmPfad!,
        ['--port', '$port'],
        umgebung: {schluesselVariable: schluessel},
        arbeitsordner: e.pfad,
      );
    } on ProcessException {
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
        vergeben: {
          ...eingebaut,
          for (final l in _laufend.values) ...l.verbindung.werkzeuge.map((w) => w.name),
        },
        frist: startfrist,
        weiter: () => lebt && !_beendet,
      );
      if (_beendet) {
        await verbindung.schliessen();
        throw const PluginFehler('moocp wurde während des Starts beendet.');
      }
      return _Laufend(e, prozess, verbindung, beendet);
    } catch (_) {
      await _prozessBeenden(prozess, beendet);
      rethrow;
    } finally {
      _imStart.remove(prozess);
    }
  }

  @override
  List<WerkzeugBeschreibung> werkzeuge(Profil profil) => [
    for (final l in _laufend.values)
      if (_aktiv(l, profil)) ...l.verbindung.werkzeuge,
  ];

  bool _aktiv(_Laufend l, Profil profil) =>
      _plugins?.stand(l.eintrag).aktivIn(profil.kennung) ?? false;

  @override
  Future<String> aufrufen(WerkzeugAufruf aufruf) async {
    for (final l in _laufend.values) {
      if (!l.verbindung.werkzeuge.any((w) => w.name == aufruf.name)) continue;
      // Gefragt wird bei jedem Aufruf: Ausschalten im Dialog „Plugins“ wirkt
      // sofort, auch in einer Sitzung, die das Werkzeug noch in ihrer Liste
      // hat.
      if (!_aktiv(l, aufruf.profil)) {
        throw MoodleFehler(
          'Das Plugin „${l.eintrag.anzeigename}“ ist im Profil „${aufruf.profil.name}“ nicht eingeschaltet; '
          'sein Werkzeug steht hier nicht zur Verfügung.',
        );
      }
      return l.verbindung.aufrufen(aufruf);
    }
    throw MoodleFehler('Das Werkzeug „${aufruf.name}“ gehört zu keinem laufenden Plugin.');
  }

  /// Beendet alle laufenden Plugins: Verbindung schließen, Standardeingabe
  /// schließen, höchstens drei Sekunden warten, dann hart beenden
  /// (plattform.dart, unter Windows samt den Prozessen, die das Plugin selbst
  /// gestartet hat). Alle zugleich, damit das Beenden der App nicht je Plugin
  /// wartet; ebenso ein Plugin, das gerade startet.
  Future<void> beenden() async {
    _beendet = true;
    final alle = _laufend.values.toList();
    _laufend.clear();
    await Future.wait([
      for (final MapEntry(key: prozess, value: beendet) in _imStart.entries.toList())
        _prozessBeenden(prozess, beendet),
      for (final l in alle)
        () async {
          await l.verbindung.schliessen();
          await _prozessBeenden(l.prozess, l.beendet);
          _protokoll.eintrag(Art.info, 'Plugin ${l.name} beendet');
        }(),
    ]);
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
