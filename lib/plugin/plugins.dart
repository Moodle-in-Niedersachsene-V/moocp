// Die Plugins, die in `plugins/<name>` des Einstellungsordners liegen (E35):
// finden, ihre Beschreibungsdatei lesen, die Prüfsumme bilden und den Stand
// der Zustimmung festhalten. Nichts davon führt Code eines Plugins aus, und
// nichts davon startet eines: Das Gefundene ist nur das, worüber die
// Lehrkraft entscheidet und was spätere Schritte (Start, Werkzeuge, Skills)
// danach befragen -- [Plugins.aktivIn] sagt, welche Plugins in einem Profil
// zugestimmt und eingeschaltet sind.
//
// Die Zustimmung geben nur die Dialoge der App (einstellungen_dialog.dart),
// auf Klick der Lehrkraft. Es gibt keinen MCP-Weg dahin, und diese Datei wird
// von nichts unter lib/mcp oder lib/moodle eingebunden
// (test/plugin_zustimmung_test.dart).

import 'dart:io';

import 'package:path/path.dart' as p;

import '../einstellungen.dart';
import '../protokoll.dart';
import 'beschreibung.dart';
import 'entscheidung.dart';
import 'pruefsumme.dart';

/// Ein gefundener Plugin-Ordner: geladen oder mit dem Grund, warum nicht.
class PluginEintrag {
  const PluginEintrag({
    required this.ordner,
    required this.pfad,
    this.beschreibung,
    this.pruefsumme,
    this.fehler,
  });

  /// Der Name des Ordners unter `plugins/`: Er ist der Schlüssel der Zustimmung
  /// in den Einstellungen und das, was das Protokoll nennt.
  final String ordner;

  /// Der Pfad des Plugin-Ordners.
  final String pfad;

  /// Gesetzt, wenn das Plugin lädt.
  final PluginBeschreibung? beschreibung;

  /// Die Prüfsumme (pruefsumme.dart); gesetzt, wenn das Plugin lädt.
  final String? pruefsumme;

  /// Warum das Plugin nicht lädt, ein Satz auf Deutsch ohne Inhalte aus der
  /// Datei; null, wenn es lädt.
  final String? fehler;

  bool get ladbar => fehler == null;

  String get anzeigename => beschreibung?.name ?? ordner;

  /// Der Pfad des Programms, das ein Start ausführen würde; null, wenn das
  /// Plugin nicht lädt.
  String? get programmPfad => beschreibung == null ? null : p.join(pfad, beschreibung!.programm);
}

/// Sucht die Plugins in [ordner] (`plugins/` des Einstellungsordners): jeder
/// Unterordner ist eines, in der Reihenfolge der Namen ohne Rücksicht auf Groß-
/// und Kleinschreibung. Dateien daneben bleiben unbeachtet; ein Ordner, der
/// sich nicht lesen lässt oder eine Regel bricht, kommt mit dem Grund
/// ([PluginEintrag.fehler]) und lädt nicht. Gleicher Kurzname: Das spätere
/// Plugin in dieser Reihenfolge lädt nicht.
///
/// Ein Plugin, das nicht lädt, wird auch nicht gelesen: keine Prüfsumme.
Future<List<PluginEintrag>> pluginsFinden(Directory ordner) async {
  if (!ordner.existsSync()) return [];
  final namen = <String, FileSystemEntity>{};
  for (final e in ordner.listSync(followLinks: false)) {
    // Nach dem Namen im Ordner, nicht nach dem ganzen Pfad.
    if (e is Directory || e is Link) namen[p.basename(e.path)] = e;
  }
  final sortiert = namen.keys.toList()
    ..sort((a, b) {
      final c = a.toLowerCase().compareTo(b.toLowerCase());
      return c != 0 ? c : a.compareTo(b);
    });
  final ergebnis = <PluginEintrag>[];
  final kurznamen = <String, String>{};
  for (final name in sortiert) {
    final pfad = namen[name]!.path;
    PluginEintrag fehler(String grund) => PluginEintrag(ordner: name, pfad: pfad, fehler: grund);
    if (namen[name] is Link) {
      ergebnis.add(fehler('Der Eintrag ist eine Verknüpfung; ein Plugin liegt als echter Ordner da.'));
      continue;
    }
    try {
      final beschreibung = _lesen(pfad);
      final vorher = kurznamen[beschreibung.kurzname];
      if (vorher != null) {
        ergebnis.add(fehler('Der Kurzname gehört schon zum Plugin im Ordner „$vorher“.'));
        continue;
      }
      if (!File(p.join(pfad, beschreibung.programm)).existsSync()) {
        ergebnis.add(fehler('Das Programm, das „programm“ nennt, fehlt im Plugin-Ordner.'));
        continue;
      }
      final summe = await pluginPruefsumme(Directory(pfad));
      kurznamen[beschreibung.kurzname] = name;
      ergebnis.add(PluginEintrag(ordner: name, pfad: pfad, beschreibung: beschreibung, pruefsumme: summe));
    } on PluginFehler catch (e) {
      ergebnis.add(fehler(e.grund));
    } on FileSystemException catch (e) {
      ergebnis.add(fehler('Die Dateien des Plugins lassen sich nicht lesen (${e.runtimeType}).'));
    }
  }
  return ergebnis;
}

/// Liest `plugin.json` im Plugin-Ordner [pfad].
PluginBeschreibung _lesen(String pfad) {
  final datei = File(p.join(pfad, 'plugin.json'));
  if (!datei.existsSync()) throw const PluginFehler('Die Beschreibungsdatei plugin.json fehlt.');
  final String text;
  try {
    text = datei.readAsStringSync();
  } on FormatException {
    throw const PluginFehler('Die Beschreibungsdatei ist kein gültiger UTF-8-Text.');
  } on FileSystemException {
    throw const PluginFehler('Die Beschreibungsdatei lässt sich nicht lesen.');
  }
  return PluginBeschreibung.ausText(text);
}

enum PluginZustand {
  /// Zugestimmt, für genau diesen Stand.
  zugestimmt,

  /// Abgelehnt, für genau diesen Stand.
  abgelehnt,

  /// Für diesen Stand gibt es keine Entscheidung: neu, geändert oder neue
  /// Version. Die App fragt.
  offen,

  /// Lädt nicht ([PluginEintrag.fehler]); es wird nicht gefragt.
  nichtGeladen,
}

/// Ein Plugin mit seinem Stand der Zustimmung.
class PluginStand {
  const PluginStand(this.eintrag, this.zustand, this.profile);

  final PluginEintrag eintrag;
  final PluginZustand zustand;

  /// Die Kennungen der Profile, in denen es eingeschaltet ist; nur bei
  /// [PluginZustand.zugestimmt] belegt.
  final Set<String> profile;

  /// Zugestimmt und in diesem Profil eingeschaltet.
  bool aktivIn(String profilKennung) => zustand == PluginZustand.zugestimmt && profile.contains(profilKennung);
}

/// Die gefundenen Plugins und die Entscheidungen der Lehrkraft darüber. Die
/// Entscheidungen stehen in [Einstellungen.plugins] und werden beim Ändern
/// gleich gespeichert.
class Plugins {
  Plugins(this._einstellungen, this._protokoll, this.eintraege);

  /// Sucht in [ordner] und schreibt ins Protokoll, was nicht lädt (Ordner und
  /// Grund, nie Inhalte).
  static Future<Plugins> laden(Einstellungen einstellungen, Protokoll protokoll, Directory ordner) async {
    final eintraege = await pluginsFinden(ordner);
    for (final e in eintraege.where((e) => !e.ladbar)) {
      protokoll.eintrag(Art.fehler, 'Plugin im Ordner „${e.ordner}“ nicht geladen: ${e.fehler}');
    }
    return Plugins(einstellungen, protokoll, eintraege);
  }

  final Einstellungen _einstellungen;
  final Protokoll _protokoll;

  /// Alles, was gefunden wurde, auch was nicht lädt, nach Ordnernamen
  /// geordnet.
  final List<PluginEintrag> eintraege;

  PluginStand stand(PluginEintrag e) {
    final summe = e.pruefsumme;
    final b = e.beschreibung;
    if (!e.ladbar || summe == null || b == null) return PluginStand(e, PluginZustand.nichtGeladen, const {});
    final entscheidung = _einstellungen.plugins[e.ordner];
    if (entscheidung == null || !entscheidung.gilt(b.version, summe)) {
      return PluginStand(e, PluginZustand.offen, const {});
    }
    return entscheidung.zugestimmt
        ? PluginStand(e, PluginZustand.zugestimmt, entscheidung.profile)
        : PluginStand(e, PluginZustand.abgelehnt, const {});
  }

  List<PluginStand> get staende => [for (final e in eintraege) stand(e)];

  /// Die Plugins, über deren jetzigen Stand noch nicht entschieden ist.
  List<PluginStand> get offene => staende.where((s) => s.zustand == PluginZustand.offen).toList();

  /// Die Plugins, die in dem Profil mit dieser Kennung zugestimmt und
  /// eingeschaltet sind. Gefragt wird nach der Prüfsumme, die beim Start
  /// gebildet wurde: Wer ein Plugin startet, bildet sie unmittelbar davor noch
  /// einmal und vergleicht, denn in der Zeit dazwischen kann jemand Dateien
  /// austauschen.
  List<PluginStand> aktivIn(String profilKennung) => staende.where((s) => s.aktivIn(profilKennung)).toList();

  /// Hält die Entscheidung über den jetzigen Stand von [e] fest und speichert
  /// sie. [profile] sind bei einer Zustimmung die Profile, in denen das Plugin
  /// eingeschaltet ist. Scheitert das Speichern, gilt die Entscheidung für
  /// diesen Lauf, das Protokoll nennt den Fehlertyp, und beim nächsten Start
  /// wird wieder gefragt.
  Future<void> entscheiden(PluginEintrag e, {required bool zugestimmt, Set<String> profile = const {}}) async {
    final b = e.beschreibung;
    final summe = e.pruefsumme;
    if (!e.ladbar || b == null || summe == null) {
      throw StateError('Über ein Plugin, das nicht lädt, wird nicht entschieden.');
    }
    _einstellungen.plugins = {
      ..._einstellungen.plugins,
      e.ordner: PluginEntscheidung(
        version: b.version,
        pruefsumme: summe,
        zugestimmt: zugestimmt,
        profile: zugestimmt ? {...profile} : const {},
      ),
    };
    _protokoll.eintrag(Art.info, 'Plugin im Ordner „${e.ordner}“: ${zugestimmt ? 'Zustimmung erteilt' : 'abgelehnt'}');
    await _speichern();
  }

  /// Schaltet ein zugestimmtes Plugin in einem Profil ein oder aus, ohne neue
  /// Zustimmung. Ohne Zustimmung für den jetzigen Stand geschieht nichts: Was
  /// nicht angenommen ist, lässt sich auch nicht einschalten.
  Future<void> profilSchalten(PluginEintrag e, String profilKennung, bool an) async {
    final s = stand(e);
    if (s.zustand != PluginZustand.zugestimmt || s.profile.contains(profilKennung) == an) return;
    final neu = {...s.profile};
    an ? neu.add(profilKennung) : neu.remove(profilKennung);
    _einstellungen.plugins = {
      ..._einstellungen.plugins,
      e.ordner: _einstellungen.plugins[e.ordner]!.mitProfilen(neu),
    };
    _protokoll.eintrag(
      Art.info,
      'Plugin im Ordner „${e.ordner}“: in Profil $profilKennung ${an ? 'eingeschaltet' : 'ausgeschaltet'}',
    );
    await _speichern();
  }

  Future<void> _speichern() async {
    try {
      await _einstellungen.speichern();
    } catch (e) {
      _protokoll.eintrag(Art.fehler, 'Plugin-Entscheidung nicht gespeichert (${e.runtimeType})');
    }
  }
}
