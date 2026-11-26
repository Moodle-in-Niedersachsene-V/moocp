// Einstellungen, die einen Neustart überleben: Moodle-Adressen der Profile,
// die gewählten Skills und die Update-Prüfung. Einen Zugangsschlüssel für die
// KI-Werkzeuge gibt es nicht (E6); die Datei gehört dem Konto allein (0600 auf
// Linux und Mac, [speichern]).
// Die Freigabestufe liegt je Moodle-Instanz im Profil; `bestaetigungen` bleibt
// für ältere Einstellungsdateien erhalten.
//
// Bewusst NICHT hier: Benutzername und Passwort. Die leben im Arbeitsspeicher,
// solange die App läuft -- und nur mit Haken „Anmeldedaten speichern" auch
// dauerhaft, siehe anmeldedaten.dart (Passwort mit DPAPI verschlüsselt).
// Ebenso wenig der Arbeitsordner: Der liegt fest und lebt nur so lange wie
// die App (arbeitsordner.dart).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'einrichtung.dart' show werkzeugSkillGueltig;
import 'einstellungen_ort.dart';
import 'freigabe.dart';
import 'plugin/entscheidung.dart';
import 'plattform/datei_rechte.dart';
import 'profil.dart';

class Einstellungen {
  static const _bekannt = {
    // `schluessel` und `schluesselPlatzhalter` gehören [_platzhalter]: kein
    // unbekanntes Feld, das beim Speichern unverändert zurückkäme.
    'moodleAdresse', 'profile', 'port', 'schluessel', 'schluesselPlatzhalter', 'bestaetigungen',
    'wahlSkills', 'werkzeugeAbgewaehlt', 'updatePruefen', 'updateZuletzt',
    'updateErwartet', 'plugins', 'pluginUpdates', 'pluginSkillOrdner',
    'fremdeSkillOrdner', 'skillFehlerGesehen', 'schnittstelleGesehen',
  };
  static const _pluginFelder = {'version', 'pruefsumme', 'zugestimmt', 'profile', 'werkzeuge'};
  static const _updateFelder = {'aus', 'zuletzt'};

  // Nur unbekannte Felder aufbewahren: bekannte, auch ungültige Werte dürfen
  // beim Speichern die validierten Werte oder deren Weglassen nicht überlagern.
  Map<String, Object?> _unbekannt = {};
  Map<String, Map<String, Object?>> _unbekanntePlugins = {};
  Map<String, Map<String, Object?>> _unbekannteUpdates = {};

  static Map<String, Object?> _rest(Object? wert, Set<String> bekannt) => wert is Map
      ? {for (final e in wert.entries) if (e.key is String && !bekannt.contains(e.key)) e.key as String: e.value}
      : {};

  static Map<String, Map<String, Object?>> _resteJeEintrag(Object? wert, Set<String> bekannt) => wert is Map
      ? {for (final e in wert.entries) if (e.key is String) e.key as String: _rest(e.value, bekannt)}
      : {};

  /// [moodleAdresse] ist der Altbestand eines einzelnen Moodle und wird zum
  /// ersten Profil ([profile]). Mit [profile] gewinnt die Liste.
  Einstellungen({
    String moodleAdresse = '',
    List<Profil>? profile,
    this.bestaetigungen = Bestaetigungen.vorgabe,
    this.wahlSkills,
    this.werkzeugeAbgewaehlt = const {},
    this.updatePruefen,
    this.updateZuletzt,
    this.updateErwartet,
    Map<String, PluginEntscheidung>? plugins,
    Map<String, PluginUpdateStand>? pluginUpdates,
    Set<String> pluginSkillOrdner = const {},
    Set<String> fremdeSkillOrdner = const {},
    Set<String> skillFehlerGesehen = const {},
    Set<String> schnittstelleGesehen = const {},
  })  : plugins = Map.of(plugins ?? const {}),
        pluginUpdates = Map.of(pluginUpdates ?? const {}),
        pluginSkillOrdner = {...pluginSkillOrdner},
        schnittstelleGesehen = {...schnittstelleGesehen},
        fremdeSkillOrdner = {...fremdeSkillOrdner},
        skillFehlerGesehen = {...skillFehlerGesehen},
        profile = _verteilt(profile ?? (moodleAdresse.isEmpty ? [] : [Profil.migriert(moodleAdresse)]));

  /// Die Moodle-Instanzen, mit denen die App angemeldet sein kann. Das erste
  /// Profil hat die Kennung `standard` (profil.dart), wenn es aus dem
  /// Altbestand stammt oder als erstes angelegt wurde.
  List<Profil> profile;

  /// Port des MCP-Servers des ersten Profils, also des Altbestands (E31). Die
  /// weiteren Profile haben ihren Port in [profile].
  int get port => profile.isEmpty ? standardPort : profile.first.port;

  /// Vergibt fehlende Ports und Servernamen und macht beide eindeutig. Das
  /// erste Profil behält seinen Port; jedes weitere bekommt den nächsten freien
  /// Port ab [standardPort]. Doppelte Servernamen bekommen eine Zählnummer.
  /// Der Port dient dem MCP-Server nicht mehr (er hat einen Kanal nur für das
  /// Konto, mcp/kanal.dart), bleibt aber in der Datei und je Profil
  /// verschieden, damit auch die Version, zu der die Lehrkraft zurückkehrt
  /// (E39), die Datei so liest, wie sie sie braucht. Vollständige, eindeutige
  /// Profile bleiben unverändert.
  static List<Profil> _verteilt(List<Profil> liste) {
    final vergeben = <int>{for (final p in liste) if (p.port > 0) p.port};
    final namen = <String>{};
    int freierPort() {
      var n = standardPort;
      while (vergeben.contains(n)) {
        n++;
      }
      vergeben.add(n);
      return n;
    }

    final ergebnis = <Profil>[];
    for (final p in liste) {
      final port = p.port > 0 && !ergebnis.any((q) => q.port == p.port) ? p.port : freierPort();
      var mcp = p.mcpName;
      var zaehler = 2;
      final basis = mcp;
      while (namen.contains(mcp)) {
        mcp = '$basis-${zaehler++}';
      }
      namen.add(mcp);
      ergebnis.add(p.copyWith(port: port, mcpName: mcp));
    }
    return ergebnis;
  }

  /// Die Adresse des ersten Profils. Der Dialog und die Titelzeile arbeiten
  /// noch mit einer Adresse; ein zweites Profil kommt über [profile].
  String get moodleAdresse => profile.isEmpty ? '' : profile.first.adresse;

  set moodleAdresse(String a) {
    if (profile.isEmpty) {
      if (a.isNotEmpty) profile = [Profil.migriert(a)];
      return;
    }
    profile[0] = profile[0].copyWith(adresse: a);
  }

  /// Alte globale Freigabestufe, nur zur Migration und für ältere Versionen.
  Bestaetigungen bestaetigungen;

  /// Die gewählten unter den wählbaren Skills (einrichtung.dart,
  /// wahlSkills); null, solange im Dialog „KI-Werkzeuge einrichten" noch
  /// nichts gewählt wurde -- dann gilt gewaehltVorgabe.
  Set<String>? wahlSkills;

  /// Die KI-Werkzeuge, die die Lehrkraft im Dialog abgewählt hat
  /// (einrichtung.dart, KiWerkzeug.id). Gespeichert wird, was abgewählt
  /// ist, nicht was gewählt: So erscheint ein Werkzeug, das erst nach der
  /// App installiert wurde, von selbst im Dialog.
  Set<String> werkzeugeAbgewaehlt;

  /// Ob die App einmal täglich bei GitHub nach einer neuen Version sehen
  /// darf; null, solange nicht gefragt wurde (update.dart). Ohne
  /// ausdrückliches Ja fragt die App niemanden -- auch GitHub nicht.
  bool? updatePruefen;

  /// Tag der letzten Prüfung (`2026-10-03`), gesetzt auch nach einem
  /// Fehlversuch: Sonst wartete jemand ohne Netz bei jedem Start erneut auf
  /// die Zeitgrenze.
  String? updateZuletzt;

  /// Die Version, deren Installer gerade gestartet wurde; der nächste Start
  /// vergleicht sie mit der eigenen und meldet Erfolg oder Fehlschlag. Die
  /// App ist währenddessen beendet und sieht sonst nichts davon.
  String? updateErwartet;

  /// Was die Lehrkraft über Plugins entschieden hat, je Plugin-Ordner
  /// (plugin/entscheidung.dart). Die Zustimmung steht hier und nicht neben dem
  /// Plugin: Sie gehört der Lehrkraft, und ein Plugin kann sie nicht selbst
  /// mitbringen. Wer die Map ändert, ersetzt sie als Ganzes (so lässt sich ein
  /// Speicherfehler zurückrollen).
  Map<String, PluginEntscheidung> plugins;

  /// Die Update-Prüfung je Plugin-Ordner (plugin/entscheidung.dart,
  /// PluginUpdateStand): ob sie abgeschaltet ist und wann zuletzt geprüft
  /// wurde. Ob überhaupt geprüft wird, entscheidet zuerst [updatePruefen]; ein
  /// eigenes Ja je Plugin gibt es nicht.
  Map<String, PluginUpdateStand> pluginUpdates;

  /// Die Ordner von Plugin-Skills, die die App in den KI-Werkzeugen
  /// installiert hat, je `<Werkzeug>/<Name>` (einrichtung.dart,
  /// pluginSkillsGemerkt, werkzeugSkill). Nur diese entfernt sie, wenn das
  /// Plugin abgelehnt, ausgeschaltet oder fort ist, und bei der
  /// Deinstallation (`--claude-entfernen`) -- die Plugins selbst sind dann
  /// vielleicht schon nicht mehr lesbar --, und nur im Werkzeug, in dem sie
  /// sie installiert hat. Beim Lesen fällt jeder Eintrag weg, der nicht diese
  /// Form hat: Aus ihm wird ein Pfad zum Löschen.
  Set<String> pluginSkillOrdner;

  /// Ordner in den Skill-Ordnern der KI-Werkzeuge, die den Namen eines
  /// Plugin-Skills tragen, aber nicht von moocp stammen, je `<Werkzeug>/<Name>`
  /// (einrichtung.dart, einrichtungPruefen, fremderOrdner). Die Einrichtung
  /// überschreibt und entfernt sie nicht.
  Set<String> fremdeSkillOrdner;

  /// Die Dialoge „Plugin bleibt aus“ (unpassende Schnittstelle), die die
  /// Lehrkraft schon gesehen hat: je Plugin-Ordner ein Eintrag aus Ordner,
  /// Version und Prüfsumme des Plugins und Version der App
  /// (plugin/plugin_update.dart, schnittstelleStand). Ein gesehener erscheint
  /// nicht noch einmal, außer er bietet ein Update an.
  Set<String> schnittstelleGesehen;

  /// Die unbrauchbaren Skill-Pakete von Plugins, die die Lehrkraft im Dialog
  /// „KI-Werkzeuge einrichten“ schon gesehen hat, je Plugin ein Stand
  /// (plugin/skills.dart, PluginSkills.fehlerStand). Ein Stand, der hier
  /// fehlt, öffnet den Dialog beim Start; ein gesehener nicht noch einmal.
  Set<String> skillFehlerGesehen;

  static File get _datei => einstellungenDatei;

  /// Zufallswerte, die nur für ältere Versionen in der Datei stehen (E39):
  /// Eine Version vor dem Kanal (E6) erzeugte ohne `schluessel` bei jedem
  /// Start einen neuen und trüge ihn in die Einträge der KI-Werkzeuge ein, die
  /// dann bei jedem Start veralteten. Mit den Platzhaltern bleibt der Wert
  /// stabil. **Sie sind kein Zugangsschlüssel**: Dieser Stand kennt keinen, kein
  /// Kanal und kein Server liest sie, und sie gewähren nichts; ein Wert aus einer
  /// früheren Datei wird nie übernommen, sondern ersetzt (bei der Rückkehr zu
  /// einer älteren Version gilt dann der Platzhalter, nicht ein alter Schlüssel).
  /// Der Schlüssel `''` ist der globale, sonst die Kennung des Profils.
  final Map<String, String> _platzhalter = {};

  static String _zufall() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Ergänzt fehlende Platzhalter und verwirft die von Profilen, die es nicht gibt.
  void _platzhalterErgaenzen() {
    _platzhalter.putIfAbsent('', _zufall);
    final kennungen = {for (final p in profile) if (!p.istStandard) p.kennung};
    _platzhalter.removeWhere((k, _) => k.isNotEmpty && !kennungen.contains(k));
    for (final k in kennungen) {
      _platzhalter.putIfAbsent(k, _zufall);
    }
  }

  static Future<Einstellungen> laden({File? datei}) async {
    final quelle = datei ?? _datei;
    final standard = Einstellungen(moodleAdresse: '');
    try {
      if (await quelle.exists()) {
        final j = jsonDecode(await quelle.readAsString()) as Map<String, dynamic>;
        final e = Einstellungen.aus(j, standard);
        // Zugangsschlüssel von früher (global und je Profil) gelten nicht mehr:
        // Die Datei wird mit neuen Platzhaltern geschrieben ([_platzhalter]), damit
        // die alten nirgends mehr gelten (E6). Auch eine Datei, die schon stimmt,
        // bekommt die Rechte, die ihr zustehen.
        if (schluesselErneuern(j)) {
          try {
            await e._speichern(quelle);
          } catch (_) {
            // Nicht schreibbar: Gelesen wird sie ohne die Schlüssel trotzdem.
          }
        } else {
          dateiRechteSetzen(quelle);
        }
        return e;
      }
    } catch (_) {
      // Kaputte Datei: mit den Standardwerten weiter und beim Speichern ersetzen.
    }
    await standard._speichern(quelle);
    return standard;
  }

  /// Ob die Datei neu geschrieben werden muss, damit die Werte für ältere
  /// Versionen stimmen: Ohne die Marke `schluesselPlatzhalter` stammt ein
  /// Schlüssel aus einer früheren Version, und es fehlt der globale oder der
  /// eines nicht-Standard-Profils.
  static bool schluesselErneuern(Map<String, dynamic> j) {
    if (j['schluesselPlatzhalter'] != true || j['schluessel'] is! String) return true;
    final liste = j['profile'];
    if (liste is! List) return false;
    return liste.any((e) =>
        e is Map && e['kennung'] != Profil.standardKennung && e['kennung'] is String && e['schluessel'] is! String);
  }

  /// Nur das Konto liest und schreibt die Datei und betritt ihren Ordner:
  /// 0600 und 0700 auf Linux und Mac (unter Windows liegt alles im
  /// Benutzerprofil). Ein Fehler lässt die Rechte, wie sie sind.
  static void dateiRechteSetzen(File ziel, {DateiRechte? rechte}) {
    if (Platform.isWindows) return;
    final r = rechte ?? const UnixDateiRechte();
    dateiPrivat(ziel.path, rechte: r);
    try {
      r.chmod(ziel.parent.path, 0x1c0);
    } catch (_) {
      // s. o.
    }
  }

  /// Liest den Inhalt der Datei. Ohne `profile` (Stand vor den Profilen) wird die
  /// Adresse `moodleAdresse` mit dem alten Port `port` zum ersten Profil; beim
  /// nächsten Speichern kommt `profile` dazu, `moodleAdresse` und `port`
  /// bleiben für ältere Versionen stehen.
  static Einstellungen aus(Map<String, dynamic> j, Einstellungen standard) {
    final liste = (j['profile'] as List?)?.map(Profil.ausJson).whereType<Profil>().toList();
    final altAdresse = j['moodleAdresse'] as String? ?? standard.moodleAdresse;
    final altPort = j['port'] as int?;
    final alteStufe = Bestaetigungen.ausText(j['bestaetigungen'] as String?);
    final profile = liste ??
        (altAdresse.isEmpty ? <Profil>[] : [Profil.migriert(altAdresse, port: altPort ?? standardPort)]);
    final gespeicherteProfile = j['profile'] as List?;
    for (var i = 0; i < profile.length; i++) {
      final gespeichertesProfil = gespeicherteProfile != null && i < gespeicherteProfile.length
          ? gespeicherteProfile[i]
          : null;
      if ((gespeichertesProfil is! Map || !gespeichertesProfil.containsKey('bestaetigungen')) &&
          alteStufe != Bestaetigungen.vorgabe) {
        profile[i] = profile[i].mitBestaetigungen(alteStufe);
      }
    }
    final ergebnis = Einstellungen(
      moodleAdresse: altAdresse,
      profile: profile,
      bestaetigungen: alteStufe,
      wahlSkills: (j['wahlSkills'] as List?)?.whereType<String>().toSet(),
      werkzeugeAbgewaehlt: (j['werkzeugeAbgewaehlt'] as List?)?.whereType<String>().toSet() ?? const {},
      updatePruefen: j['updatePruefen'] as bool?,
      updateZuletzt: j['updateZuletzt'] as String?,
      updateErwartet: j['updateErwartet'] as String?,
      plugins: pluginEntscheidungenAus(j['plugins']),
      pluginUpdates: pluginUpdatesAus(j['pluginUpdates']),
      pluginSkillOrdner:
          (j['pluginSkillOrdner'] as List?)?.whereType<String>().where(werkzeugSkillGueltig).toSet() ?? const {},
      fremdeSkillOrdner: (j['fremdeSkillOrdner'] as List?)?.whereType<String>().toSet() ?? const {},
      skillFehlerGesehen: (j['skillFehlerGesehen'] as List?)?.whereType<String>().toSet() ?? const {},
      schnittstelleGesehen: (j['schnittstelleGesehen'] as List?)?.whereType<String>().toSet() ?? const {},
    );
    if (!schluesselErneuern(j)) {
      ergebnis._platzhalter['' ] = j['schluessel'] as String;
      for (final e in (j['profile'] as List? ?? const [])) {
        if (e is Map && e['kennung'] is String && e['schluessel'] is String) {
          ergebnis._platzhalter[e['kennung'] as String] = e['schluessel'] as String;
        }
      }
    }
    ergebnis._unbekannt = _rest(j, _bekannt);
    ergebnis._unbekanntePlugins = _resteJeEintrag(j['plugins'], _pluginFelder);
    ergebnis._unbekannteUpdates = _resteJeEintrag(j['pluginUpdates'], _updateFelder);
    return ergebnis;
  }

  /// Der Inhalt der Datei, wie ihn [speichern] schreibt.
  Map<String, Object?> zuJson() {
    _platzhalterErgaenzen();
    return _json();
  }

  Map<String, Object?> _json() => {
        ..._unbekannt,
        'moodleAdresse': moodleAdresse,
        'profile': [
          for (final p in profile) {...p.toJson(), if (!p.istStandard) 'schluessel': _platzhalter[p.kennung]},
        ],
        'port': port,
        'schluessel': _platzhalter[''],
        'schluesselPlatzhalter': true,
        'bestaetigungen': bestaetigungen.text,
        if (wahlSkills != null) 'wahlSkills': (wahlSkills!.toList()..sort()),
        if (werkzeugeAbgewaehlt.isNotEmpty) 'werkzeugeAbgewaehlt': (werkzeugeAbgewaehlt.toList()..sort()),
        if (updatePruefen != null) 'updatePruefen': updatePruefen,
        if (updateZuletzt != null) 'updateZuletzt': updateZuletzt,
        if (updateErwartet != null) 'updateErwartet': updateErwartet,
        if (plugins.isNotEmpty) 'plugins': {for (final e in plugins.entries) e.key: {...?_unbekanntePlugins[e.key], ...e.value.toJson()}},
        if (pluginUpdates.isNotEmpty)
          'pluginUpdates': {for (final e in pluginUpdates.entries) e.key: {...?_unbekannteUpdates[e.key], ...e.value.toJson()}},
        if (pluginSkillOrdner.isNotEmpty) 'pluginSkillOrdner': (pluginSkillOrdner.toList()..sort()),
        if (fremdeSkillOrdner.isNotEmpty) 'fremdeSkillOrdner': (fremdeSkillOrdner.toList()..sort()),
        if (skillFehlerGesehen.isNotEmpty) 'skillFehlerGesehen': (skillFehlerGesehen.toList()..sort()),
        if (schnittstelleGesehen.isNotEmpty) 'schnittstelleGesehen': (schnittstelleGesehen.toList()..sort()),
      };

  Future<void> speichern() => _speichern(_datei);

  /// Wie [speichern], in eine andere Datei (für die Tests und [laden]).
  Future<void> speichernNach(File ziel) => _speichern(ziel);

  Future<void> _speichern(File ziel) async {
    await ziel.parent.create(recursive: true);
    await ziel.writeAsString(const JsonEncoder.withIndent('  ').convert(zuJson()));
    dateiRechteSetzen(ziel);
  }
}
