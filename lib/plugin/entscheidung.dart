// Was die Lehrkraft über ein Plugin entschieden hat, so, wie es in den
// Einstellungen steht (einstellungen.dart): je Plugin-Ordner Version und
// Prüfsumme des Stands, über den entschieden wurde, die Entscheidung selbst und
// die Instanzprofile, in denen das Plugin eingeschaltet ist (E35).
//
// Die Entscheidung gilt für GENAU diesen Stand: Weicht Version oder Prüfsumme
// ab, ist sie nichts wert, und es wird neu gefragt. Das gilt für eine
// Ablehnung genauso wie für eine Zustimmung.

/// Die Entscheidung über einen Stand eines Plugins.
class PluginEntscheidung {
  const PluginEntscheidung({
    required this.version,
    required this.pruefsumme,
    required this.zugestimmt,
    this.profile = const {},
  });

  final String version;

  /// SHA-256 über alle Dateien des Plugin-Ordners (pruefsumme.dart).
  final String pruefsumme;

  /// Zugestimmt oder abgelehnt.
  final bool zugestimmt;

  /// Die Kennungen (Profil.kennung) der Instanzprofile, in denen das Plugin
  /// eingeschaltet ist. Bei einer Ablehnung leer. Gespeichert wird die
  /// ausdrückliche Menge: Ein Profil, das später dazukommt, ist nicht darin
  /// und also aus, bis die Lehrkraft es einschaltet.
  final Set<String> profile;

  /// Ob die Entscheidung für diesen Stand gilt.
  bool gilt(String version, String pruefsumme) => this.version == version && this.pruefsumme == pruefsumme;

  PluginEntscheidung mitProfilen(Set<String> neu) => PluginEntscheidung(
        version: version,
        pruefsumme: pruefsumme,
        zugestimmt: zugestimmt,
        profile: neu,
      );

  Map<String, Object?> toJson() => {
        'version': version,
        'pruefsumme': pruefsumme,
        'zugestimmt': zugestimmt,
        'profile': profile.toList()..sort(),
      };

  /// Null, wenn die Angabe beschädigt ist. Ein beschädigter Eintrag zählt als
  /// „nicht entschieden“ und wird nie zur Zustimmung: Die Lehrkraft wird
  /// gefragt, statt dass etwas Unleserliches als Ja gelesen wird.
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
    );
  }
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

/// Die Entscheidungen ohne das gelöschte Profil [kennung]: Die Zustimmung
/// bleibt, das Plugin ist dort nur nicht mehr eingeschaltet. [alt] bleibt
/// unverändert, damit der Aufrufer zurückrollen kann, wenn das Speichern
/// scheitert.
Map<String, PluginEntscheidung> pluginEntscheidungenOhneProfil(Map<String, PluginEntscheidung> alt, String kennung) => {
      for (final MapEntry(:key, :value) in alt.entries)
        key: value.profile.contains(kennung) ? value.mitProfilen({...value.profile}..remove(kennung)) : value,
    };
