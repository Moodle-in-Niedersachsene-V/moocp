// Die Werkzeugliste für `moocp.exe --werkzeugliste` (main.dart), mit den
// Werkzeugen der Plugins (E35): Die Brücke (mcp/bruecke.dart, E21) beantwortet
// `initialize` und `tools/list` aus dieser Liste, auch wenn die App nicht läuft
// -- ein Plugin, das nie gestartet ist, kennt sie darum nur aus dem, was die App
// beim letzten Start von ihm gemerkt hat (plugins.dart, Plugins.werkzeugeMerken).
//
// Hier wird nur gelesen: die Einstellungsdatei, die Beschreibungsdatei und die
// Dateien des Plugin-Ordners für die Prüfsumme. Kein Plugin wird gestartet und
// kein Code von ihm ausgeführt -- die Datei bindet nichts ein, was einen
// Kindprogramm-Start kennt, und test/plugin_werkzeugliste_test.dart hält das
// fest. Auch Einstellungen, Protokoll und Arbeitsordner bleiben unberührt:
// Neben einer laufenden App verschränkten sich sonst die Zeilen im Protokoll,
// und die Einstellungsdatei schreibt nur die App.
//
// Ausgegeben wird die Liste eines Plugins nur, wenn
//   - ihm zugestimmt ist, für genau den Stand, den der Plugin-Ordner jetzt hat
//     (Version und Prüfsumme, wie beim Start der App), und
//   - es im Standardprofil eingeschaltet ist: Die Brücke kennt nur den Server
//     `moodle` (E21), und das ist das Standardprofil (E31), und
//   - seine Werkzeugnamen den Regeln genügen, wie beim Start der App (Kurzname
//     davor, kein Name eines eingebauten Werkzeugs oder eines früheren
//     Plugins). Ein einzelnes Werkzeug, dessen Name mit `mcp__<Profil>__`
//     davor länger als 64 Zeichen wäre, fehlt wie im Server der App
//     ([GemerkteWerkzeuge]).
//
// Sonst fehlen die Werkzeuge dieses Plugins; die eingebauten und die der
// übrigen Plugins bleiben. Ein Plugin, dessen Ordner fehlt, eine Verknüpfung
// ist oder sich nicht lesen lässt, hält darum nie die Liste der anderen auf.

import 'dart:convert';
import 'dart:io';

import '../einstellungen.dart';
import '../freigabe.dart';
import '../mcp/mcp_dienst.dart';
import '../mcp/werkzeugquelle.dart';
import '../moodle/moodle_zugang.dart';
import '../profil.dart';
import '../protokoll.dart';
import 'beschreibung.dart' show PluginFehler;
import 'entscheidung.dart';
import 'plugins.dart';
import 'verbindung.dart' show werkzeugnameZuLang, werkzeugnamenPruefen;

/// Die Werkzeugliste, die `moocp.exe --werkzeugliste` ausgibt: was der
/// MCP-Server des Standardprofils auf `initialize` und `tools/list` antwortet
/// ([McpDienst.werkzeugliste]), mit den gemerkten Werkzeugen der Plugins nach
/// den eingebauten.
///
/// [einstellungen] und [plugins] nennen die Einstellungsdatei und den
/// Plugin-Ordner als Funktionen: Sie zu ermitteln kann scheitern (fehlt
/// `%APPDATA%`), und auch dann soll die Liste der eingebauten Werkzeuge
/// erscheinen. Geht beim Lesen der Plugin-Werkzeuge irgendetwas schief, ist es
/// genau diese Liste; ohne gemerkte Werkzeuge ist sie Byte für Byte dieselbe wie
/// ohne Plugin-Unterstützung.
Future<Map<String, dynamic>> werkzeuglisteFuerBruecke({
  required File Function() einstellungen,
  required Directory Function() plugins,
}) async {
  final protokoll = Protokoll();
  final profil = Profil.migriert('');
  McpDienst dienst(List<WerkzeugQuelle> quellen) => McpDienst(
    Einstellungen(schluessel: ''),
    MoodleZugang(protokoll),
    protokoll,
    Freigaben(protokoll),
    '',
    profil: profil,
    werkzeugquellen: quellen,
  );
  try {
    final entscheidungen = _gemerkteEntscheidungen(einstellungen());
    if (entscheidungen.values.any((e) => e.zugestimmt && e.werkzeuge != null)) {
      final werkzeuge = await gemerkteWerkzeuge(
        entscheidungen: entscheidungen,
        pluginsOrdner: plugins(),
        eingebaut: await dienst(const []).eingebauteWerkzeugnamen(),
        profilKennung: profil.kennung,
      );
      if (werkzeuge.isNotEmpty) {
        return await dienst([GemerkteWerkzeuge(profil.kennung, werkzeuge)]).werkzeugliste();
      }
    }
  } catch (_) {
    // Ein Plugin, eine Einstellungsdatei oder ein Ordner, mit dem etwas nicht
    // stimmt, nimmt der Brücke nie die eingebauten Werkzeuge: Es bleibt bei
    // ihnen.
  }
  return dienst(const []).werkzeugliste();
}

/// Der Abschnitt `plugins` der Einstellungsdatei [datei], nur gelesen. Eine
/// fehlende, unlesbare oder zur Hälfte geschriebene Datei (die App speichert
/// gerade) ist: keine gemerkten Plugins.
Map<String, PluginEntscheidung> _gemerkteEntscheidungen(File datei) {
  try {
    final j = jsonDecode(datei.readAsStringSync());
    return j is Map ? pluginEntscheidungenAus(j['plugins']) : {};
  } catch (_) {
    return {};
  }
}

/// Die gemerkten Werkzeuge der Plugins in [pluginsOrdner], die für das Profil
/// mit der Kennung [profilKennung] gelten (Regeln in der Kopfzeile der Datei),
/// in der Reihenfolge der Ordner. [eingebaut] sind die Namen der eingebauten
/// Werkzeuge.
Future<List<WerkzeugBeschreibung>> gemerkteWerkzeuge({
  required Map<String, PluginEntscheidung> entscheidungen,
  required Directory pluginsOrdner,
  required Set<String> eingebaut,
  required String profilKennung,
}) async {
  // Dieselbe Suche und derselbe Stand der Zustimmung wie beim Start der App:
  // Was sie als zugestimmt und im Profil eingeschaltet nennt, gilt auch hier.
  final List<PluginEintrag> eintraege;
  try {
    eintraege = await pluginsFinden(pluginsOrdner);
  } on FileSystemException {
    return const [];
  }
  final plugins = Plugins(Einstellungen(schluessel: '', plugins: entscheidungen), Protokoll(), eintraege);
  final vergeben = {...eingebaut};
  final ergebnis = <WerkzeugBeschreibung>[];
  for (final stand in plugins.aktivIn(profilKennung)) {
    final liste = entscheidungen[stand.eintrag.ordner]?.werkzeuge;
    if (liste == null) continue;
    try {
      werkzeugnamenPruefen([for (final w in liste) w.name], stand.eintrag.beschreibung!.kurzname, vergeben);
    } on PluginFehler {
      continue;
    }
    vergeben.addAll(liste.map((w) => w.name));
    ergebnis.addAll(liste);
  }
  return ergebnis;
}

/// Die gemerkten Werkzeuge als Quelle für den MCP-Server der Werkzeugliste.
/// Sie nennt sie nur für das Profil, für das sie ermittelt wurden, und führt
/// nichts aus: Aufrufe gehen immer an die laufende App. Wie im Server der App
/// fehlt ein Werkzeug, dessen Name mit `mcp__<Profil>__` davor zu lang wäre
/// (verbindung.dart, werkzeugnameZuLang); beim Standardprofil `moodle` kommt
/// das nicht vor.
class GemerkteWerkzeuge implements WerkzeugQuelle {
  GemerkteWerkzeuge(this.profilKennung, this._liste);

  final String profilKennung;
  final List<WerkzeugBeschreibung> _liste;

  @override
  List<WerkzeugBeschreibung> werkzeuge(Profil profil) => profil.kennung == profilKennung
      ? [for (final w in _liste) if (!werkzeugnameZuLang(profil.mcpName, w.name)) w]
      : const [];

  @override
  Future<String> aufrufen(WerkzeugAufruf aufruf) =>
      throw StateError('Die gemerkte Werkzeugliste führt keine Aufrufe aus.');
}
