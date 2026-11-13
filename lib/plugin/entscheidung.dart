// Was die Lehrkraft über ein Plugin entschieden hat, so, wie es in den
// Einstellungen steht (einstellungen.dart): je Plugin-Ordner Version und
// Prüfsumme des Stands, über den entschieden wurde, die Entscheidung selbst und
// die Instanzprofile, in denen das Plugin eingeschaltet ist (E35). Bei einer
// Zustimmung kommt die Werkzeugliste dazu, die das Plugin beim Start genannt hat.
//
// Die Entscheidung gilt für GENAU diesen Stand: Weicht Version oder Prüfsumme
// ab, ist sie nichts wert, und es wird neu gefragt. Das gilt für eine
// Ablehnung genauso wie für eine Zustimmung -- und für die Werkzeugliste, die
// an der Entscheidung hängt.

import 'dart:convert';

import '../mcp/werkzeugquelle.dart';

/// Die Entscheidung über einen Stand eines Plugins.
class PluginEntscheidung {
  const PluginEntscheidung({
    required this.version,
    required this.pruefsumme,
    required this.zugestimmt,
    this.profile = const {},
    this.werkzeuge,
  });

  final String version;

  /// SHA-256 über alle Dateien des Plugin-Ordners (pruefsumme.dart).
  final String pruefsumme;

  /// Zugestimmt oder abgelehnt.
  final bool zugestimmt;

  /// Die Kennungen (Profil.kennung) der Instanzprofile, in denen das Plugin
  /// eingeschaltet ist. Bei einer Ablehnung leer. Gespeichert wird die
  /// ausdrückliche Menge; ein Profil, das später angelegt wird, kommt bei
  /// jeder Zustimmung hinzu ([pluginEntscheidungenMitProfil]).
  final Set<String> profile;

  /// Die Werkzeuge, die das Plugin beim letzten Start dieses Stands nannte,
  /// damit `moocp.exe --werkzeugliste` sie ohne das Plugin ausgeben kann
  /// (werkzeugliste.dart). Null, solange es nicht gestartet war, und nach
  /// jeder neuen Entscheidung über einen anderen Stand; nur bei einer
  /// Zustimmung belegt.
  final List<WerkzeugBeschreibung>? werkzeuge;

  /// Ob die Entscheidung für diesen Stand gilt.
  bool gilt(String version, String pruefsumme) => this.version == version && this.pruefsumme == pruefsumme;

  /// Ob [liste] dieselben Werkzeuge beschreibt wie die gemerkten.
  bool hatWerkzeuge(List<WerkzeugBeschreibung> liste) =>
      werkzeuge != null && jsonEncode(_werkzeugeZuJson(werkzeuge!)) == jsonEncode(_werkzeugeZuJson(liste));

  PluginEntscheidung mitProfilen(Set<String> neu) => PluginEntscheidung(
        version: version,
        pruefsumme: pruefsumme,
        zugestimmt: zugestimmt,
        profile: neu,
        werkzeuge: werkzeuge,
      );

  /// Mit der Werkzeugliste [neu]; null verwirft sie.
  PluginEntscheidung mitWerkzeugen(List<WerkzeugBeschreibung>? neu) => PluginEntscheidung(
        version: version,
        pruefsumme: pruefsumme,
        zugestimmt: zugestimmt,
        profile: profile,
        werkzeuge: neu,
      );

  Map<String, Object?> toJson() => {
        'version': version,
        'pruefsumme': pruefsumme,
        'zugestimmt': zugestimmt,
        'profile': profile.toList()..sort(),
        if (werkzeuge != null) 'werkzeuge': _werkzeugeZuJson(werkzeuge!),
      };

  /// Null, wenn die Angabe beschädigt ist. Ein beschädigter Eintrag zählt als
  /// „nicht entschieden“ und wird nie zur Zustimmung: Die Lehrkraft wird
  /// gefragt, statt dass etwas Unleserliches als Ja gelesen wird. Eine
  /// beschädigte Werkzeugliste dagegen fällt allein weg: Sie ist nur ein
  /// Zwischenspeicher, und der nächste Start des Plugins legt sie neu an.
  static PluginEntscheidung? ausJson(Object? j) {
    if (j is! Map) return null;
    final version = j['version'];
    final summe = j['pruefsumme'];
    final zugestimmt = j['zugestimmt'];
    if (version is! String || version.isEmpty) return null;
    if (summe is! String || summe.isEmpty) return null;
    if (zugestimmt is! bool) return null;
    final profile = j['profile'];
    if (profile != null && profile is! List) return null;
    return PluginEntscheidung(
      version: version,
      pruefsumme: summe,
      zugestimmt: zugestimmt,
      profile: profile is List ? profile.whereType<String>().toSet() : const {},
      werkzeuge: _werkzeugeAus(j['werkzeuge']),
    );
  }
}

List<Map<String, Object?>> _werkzeugeZuJson(List<WerkzeugBeschreibung> liste) => [
      for (final w in liste)
        {
          'name': w.name,
          'beschreibung': w.beschreibung,
          'eingabeSchema': w.eingabeSchema,
          if (w.titel != null) 'titel': w.titel,
          if (w.nurLesen) 'nurLesen': true,
          if (w.zerstoerend) 'zerstoerend': true,
        },
    ];

/// Liest die gemerkte Werkzeugliste; null, wenn sie fehlt oder auch nur ein
/// Werkzeug unbrauchbar ist. Ein Werkzeug braucht einen Namen, eine
/// Beschreibung und ein Eingabeschema, dessen Wurzel ein Objekt ist (so
/// verlangt es der MCP-Server, werkzeug_aufrufe.dart): Eine halbe Liste gäbe
/// der Brücke Werkzeuge, die der Server nicht kennt.
List<WerkzeugBeschreibung>? _werkzeugeAus(Object? j) {
  if (j is! List) return null;
  final ergebnis = <WerkzeugBeschreibung>[];
  for (final w in j) {
    if (w is! Map) return null;
    final name = w['name'];
    final beschreibung = w['beschreibung'];
    final schema = w['eingabeSchema'];
    final titel = w['titel'];
    if (name is! String || name.isEmpty) return null;
    if (beschreibung is! String) return null;
    if (schema is! Map || schema['type'] != 'object') return null;
    if (titel != null && titel is! String) return null;
    ergebnis.add(
      WerkzeugBeschreibung(
        name: name,
        beschreibung: beschreibung,
        eingabeSchema: schema.cast<String, dynamic>(),
        titel: titel as String?,
        nurLesen: w['nurLesen'] == true,
        zerstoerend: w['zerstoerend'] == true,
      ),
    );
  }
  return ergebnis;
}

/// Liest den Abschnitt `plugins` der Einstellungen; Beschädigtes fällt weg.
Map<String, PluginEntscheidung> pluginEntscheidungenAus(Object? j) {
  if (j is! Map) return {};
  final ergebnis = <String, PluginEntscheidung>{};
  for (final MapEntry(:key, :value) in j.entries) {
    final e = PluginEntscheidung.ausJson(value);
    if (key is String && e != null) ergebnis[key] = e;
  }
  return ergebnis;
}

/// Die Update-Prüfung eines Plugins (plugin_update.dart), je Plugin-Ordner in
/// den Einstellungen unter `pluginUpdates`. Anders als [PluginEntscheidung]
/// hängt sie nicht an einem Stand: Wer die Prüfung für ein Plugin abschaltet,
/// will das auch nach dessen nächstem Update noch, und der Tag der letzten
/// Prüfung gilt für das Plugin, nicht für eine Version.
class PluginUpdateStand {
  const PluginUpdateStand({this.aus = false, this.zuletzt});

  /// Die Lehrkraft hat die Prüfung für dieses Plugin abgeschaltet (Dialog
  /// „Plugins“).
  final bool aus;

  /// Tag der letzten Prüfung (`2026-10-03`), wie `updateZuletzt` für moocp:
  /// gesetzt auch nach einem Fehlversuch.
  final String? zuletzt;

  PluginUpdateStand mit({bool? aus, String? zuletzt}) =>
      PluginUpdateStand(aus: aus ?? this.aus, zuletzt: zuletzt ?? this.zuletzt);

  Map<String, Object?> toJson() => {
        if (aus) 'aus': true,
        if (zuletzt != null) 'zuletzt': zuletzt,
      };

  /// Beschädigtes fällt auf die Vorgabe zurück: Prüfung an, noch nie geprüft.
  /// Mehr als eine Anfrage an GitHub am Tag, die die Lehrkraft erlaubt hat,
  /// kann daraus nicht werden.
  static PluginUpdateStand ausJson(Object? j) {
    if (j is! Map) return const PluginUpdateStand();
    final zuletzt = j['zuletzt'];
    return PluginUpdateStand(aus: j['aus'] == true, zuletzt: zuletzt is String ? zuletzt : null);
  }
}

/// Liest den Abschnitt `pluginUpdates` der Einstellungen.
Map<String, PluginUpdateStand> pluginUpdatesAus(Object? j) {
  if (j is! Map) return {};
  return {
    for (final MapEntry(:key, :value) in j.entries)
      if (key is String) key: PluginUpdateStand.ausJson(value),
  };
}

/// Die Entscheidungen mit dem neu angelegten Profil [kennung]: Jedes Plugin,
/// dem zugestimmt ist, ist dort eingeschaltet, wie bei der Zustimmung in jedem
/// Profil vorgewählt (E35); abschalten lässt es sich im Dialog „Plugins“. Ein
/// abgelehntes bleibt aus. [alt] bleibt unverändert, damit der Aufrufer
/// zurückrollen kann, wenn das Speichern scheitert.
Map<String, PluginEntscheidung> pluginEntscheidungenMitProfil(Map<String, PluginEntscheidung> alt, String kennung) => {
      for (final MapEntry(:key, :value) in alt.entries)
        key: value.zugestimmt ? value.mitProfilen({...value.profile, kennung}) : value,
    };

/// Die Entscheidungen ohne das gelöschte Profil [kennung]: Die Zustimmung
/// bleibt, das Plugin ist dort nur nicht mehr eingeschaltet. [alt] bleibt
/// unverändert, damit der Aufrufer zurückrollen kann, wenn das Speichern
/// scheitert.
Map<String, PluginEntscheidung> pluginEntscheidungenOhneProfil(Map<String, PluginEntscheidung> alt, String kennung) => {
      for (final MapEntry(:key, :value) in alt.entries)
        key: value.profile.contains(kennung) ? value.mitProfilen({...value.profile}..remove(kennung)) : value,
    };
