// Die Skills eines Plugins (E35) für die Einrichtung der KI-Werkzeuge (E13).
//
// Ein Plugin bringt seine Skills als Ordner `skills/<name>/` in seinem
// Plugin-Ordner mit; welche es gibt, nennt die Beschreibungsdatei (`skills`
// für die, die immer dabei sind, `wahlSkills` für die mit Haken). Die App liest
// sie von dort, ohne Code des Plugins auszuführen, und reicht sie der
// Einrichtung als Pakete wie die eigenen (einrichtung.dart, SkillPaket):
// Vergleich am Inhalt, Installieren und Entfernen je KI-Werkzeug.
//
// Die Regeln:
//
// - Angeboten werden nur die Skills von Plugins, denen die Lehrkraft für den
//   jetzigen Stand zugestimmt hat und die in mindestens einem Instanzprofil
//   eingeschaltet sind. In welchem, zählt nicht: Skills liegen je
//   KI-Werkzeug, nicht je Profil, wie die der App. Ist ein Plugin in keinem
//   Profil eingeschaltet, sind seine gemerkten Skills verwaist, und die
//   Einrichtung bietet sie zum Entfernen an -- Skills ohne ihre Werkzeuge
//   sollen nicht stehen bleiben.
// - Ein Entwicklungs-Plugin (entwicklung.dart): Das Ja im Dialog beim Start
//   mit `--plugin-entwicklung` zählt als Zustimmung. Seine Skills kommen aus
//   dem Entwicklungsordner, nach denselben Regeln, aber ohne Prüfsumme -- der
//   Dialog tritt bei jedem Start an ihre Stelle. Ein installiertes Plugin mit
//   demselben Kurznamen bringt in diesem Lauf keine Skills mit; es gelten die
//   des Entwicklungsordners. Ohne den Parameter nennt kein Plugin diese
//   Skills mehr, und sie sind verwaist, außer ein installiertes Plugin mit
//   Zustimmung bringt denselben mit. Gelesen wird einmal je Prüfung; ein
//   geänderter Skill zeigt sich beim nächsten Start der App als Abweichung,
//   ein Wiederverbinden des Plugins prüft nichts neu.
// - Vor dem Lesen bildet die App die Prüfsumme des Plugin-Ordners neu: Wurde
//   seit dem Start etwas ausgetauscht, galt die Zustimmung einem anderen
//   Stand, und kein Skill des Plugins wird angeboten.
// - Ein Skill heißt wie der Kurzname des Plugins oder beginnt mit
//   `<kurzname>-`, und nie wie ein Skill der App. Da Kurznamen nur aus
//   Buchstaben und Ziffern bestehen und eindeutig sind, überschreibt so kein
//   Plugin einen Skill der App oder eines anderen Plugins.
// - Kein Pfad führt aus dem Plugin-Ordner hinaus: Der Name ist ein Skill-Name
//   (einrichtung.dart, skillNameGueltig), und eine Verknüpfung im Skill-Ordner
//   macht das Paket unbrauchbar, statt ihr zu folgen.
// - Ein Paket, das eine Regel bricht oder sich nicht lesen lässt, wird nicht
//   installiert; die anderen schon. Der Grund ist ein Satz mit dem Plugin, ohne
//   Inhalte aus seinen Dateien (E11) -- einen Skill-Namen nennt er nur, wenn
//   der ein gültiger Skill-Name ist. Ein solches Paket öffnet den Dialog
//   „KI-Werkzeuge einrichten“ beim Start, aber nur einmal je Stand: Je Plugin
//   mit unbrauchbarem Paket gibt es einen Stand ([PluginSkills.fehlerStand]),
//   und was die Lehrkraft gesehen hat, merkt sich die App
//   (Einstellungen.skillFehlerGesehen, main.dart).
//
// Welche Plugin-Skills die App in welchem KI-Werkzeug installiert hat, merkt
// sie sich in den Einstellungen (Einstellungen.pluginSkillOrdner,
// einrichtung.dart pluginSkillsGemerkt). Fehlt das Plugin, ist es abgelehnt,
// in keinem Profil eingeschaltet oder nennt es einen gemerkten Skill nicht
// mehr, ist der Skill verwaist ([verwaisteSkills]), und die Einrichtung bietet
// ihn dort zum Entfernen an, wo sie ihn installiert hat. Einen fremden Ordner
// gleichen Namens im Skill-Ordner eines KI-Werkzeugs überschreibt und entfernt
// sie nie (einrichtung.dart, einrichtungPruefen).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../einrichtung.dart';
import 'beschreibung.dart';
import 'plugins.dart';
import 'pruefsumme.dart';

/// Das Entwicklungs-Plugin, soweit die Einrichtung es braucht: sein Ordner
/// und seine Beschreibungsdatei (entwicklung.dart, EntwicklungsPlugin). Nur
/// nach dem Ja im Dialog beim Start.
typedef EntwicklungsSkills = ({String ordner, PluginBeschreibung beschreibung});

/// Was die Einrichtung aus den Plugins an Skills bekommt.
class PluginSkills {
  const PluginSkills({
    this.pakete = const [],
    this.wahlSkills = const {},
    this.namen = const {},
    this.fehler = const [],
    this.fehlerStand = const {},
  });

  /// Die lesbaren Pakete der zugestimmten Plugins.
  final List<SkillPaket> pakete;

  /// Die wählbaren unter [pakete], mit dem Satz aus der Beschreibungsdatei.
  final Map<String, String> wahlSkills;

  /// Jeder Name, den ein zugestimmtes Plugin nennt, auch der eines Pakets,
  /// das sich nicht lesen lässt: Ein solcher Skill ist nicht verwaist, nur
  /// gerade nicht installierbar, und bleibt stehen, wie er ist.
  final Set<String> namen;

  /// Je unbrauchbarem Paket (oder Plugin, dessen Ordner sich geändert hat) ein
  /// Satz mit Plugin und Grund.
  final List<String> fehler;

  /// Je Plugin mit einem Satz in [fehler] ein Stand: eine Prüfsumme über den
  /// Stand des Plugins (seine Prüfsumme; beim Entwicklungs-Plugin der
  /// Kurzname) und seine Sätze. Gleich, solange sich weder das Plugin noch
  /// die Gründe ändern; so öffnet ein schon gesehener Hinweis den Dialog nicht
  /// bei jedem Start (Einstellungen.skillFehlerGesehen).
  final Set<String> fehlerStand;
}

/// Liest die Skills aller Plugins in [plugins], denen für den jetzigen Stand
/// zugestimmt ist und die in mindestens einem Profil eingeschaltet sind, und
/// die des angehängten Entwicklungs-Plugins
/// [entwicklung]. [appNamen] sind die Namen der Skills der App; so darf kein
/// Skill eines Plugins heißen. Ohne Plugins (null) und ohne
/// Entwicklungs-Plugin gibt es nichts.
Future<PluginSkills> pluginSkillsLesen(
  Plugins? plugins, {
  required Set<String> appNamen,
  EntwicklungsSkills? entwicklung,
}) async {
  final pakete = <SkillPaket>[];
  final wahl = <String, String>{};
  final namen = <String>{};
  final fehler = <String>[];
  final fehlerStand = <String>{};

  /// Liest die Skills eines Plugins; [unveraendert] null heißt: ohne Prüfsumme.
  Future<void> lesen(
    String pfad,
    PluginBeschreibung b, {
    required String satzAnfang,
    required String anzeigename,
    required String stand,
    Future<bool> Function()? unveraendert,
  }) async {
    final alle = [...b.skills, ...b.wahlSkills.keys];
    if (alle.isEmpty) return;
    namen.addAll(alle);
    final eigene = <String>[];
    String satz(String grund) => '$satzAnfang: $grund';
    if (unveraendert != null && !await unveraendert()) {
      eigene.add(satz('Der Plugin-Ordner hat sich seit dem Start geändert. Seine Skills werden erst nach dem '
          'nächsten Start der App angeboten, mit neuer Zustimmung.'));
    } else {
      for (final name in alle) {
        try {
          pakete.add(pluginSkillLesen(pfad, name, kurzname: b.kurzname, appNamen: appNamen, plugin: anzeigename));
          final text = b.wahlSkills[name];
          if (text != null) wahl[name] = text;
        } on PluginFehler catch (x) {
          eigene.add(satz(x.grund));
        }
      }
    }
    if (eigene.isEmpty) return;
    fehler.addAll(eigene);
    fehlerStand.add(sha256.convert(utf8.encode([stand, ...eigene].join('\n'))).toString());
  }

  for (final s in plugins?.staende ?? const <PluginStand>[]) {
    final e = s.eintrag;
    final b = e.beschreibung;
    if (s.zustand != PluginZustand.zugestimmt || b == null) continue;
    // In keinem Profil eingeschaltet: Seine Werkzeuge stehen nirgends, also
    // auch seine Skills nicht; gemerkte sind damit verwaist.
    if (s.profile.isEmpty) continue;
    // Solange ein Entwicklungs-Plugin mit demselben Kurznamen angehängt ist,
    // gelten dessen Skills.
    if (entwicklung != null && entwicklung.beschreibung.kurzname == b.kurzname) continue;
    await lesen(
      e.pfad,
      b,
      satzAnfang: 'Plugin „${e.anzeigename}“',
      anzeigename: e.anzeigename,
      stand: 'plugin:${e.ordner}:${e.pruefsumme}',
      unveraendert: () => _unveraendert(e),
    );
  }
  if (entwicklung != null) {
    final b = entwicklung.beschreibung;
    await lesen(
      entwicklung.ordner,
      b,
      satzAnfang: 'Entwicklungs-Plugin „${b.name}“',
      anzeigename: b.name,
      stand: 'entwicklung:${b.kurzname}',
    );
  }
  return PluginSkills(pakete: pakete, wahlSkills: wahl, namen: namen, fehler: fehler, fehlerStand: fehlerStand);
}

/// Ob der Plugin-Ordner noch der Stand ist, dem zugestimmt wurde.
Future<bool> _unveraendert(PluginEintrag e) async {
  try {
    return await pluginPruefsumme(Directory(e.pfad)) == e.pruefsumme;
  } on PluginFehler {
    return false;
  } on FileSystemException {
    return false;
  }
}

/// Liest den Skill [name] aus `skills/<name>/` im Plugin-Ordner [pluginPfad];
/// wirft [PluginFehler] mit einem Satz ohne Inhalte, wenn er eine Regel bricht
/// oder sich nicht lesen lässt (siehe oben).
SkillPaket pluginSkillLesen(
  String pluginPfad,
  String name, {
  required String kurzname,
  required Set<String> appNamen,
  String? plugin,
}) {
  if (!skillNameGueltig(name)) {
    throw const PluginFehler('Ein Skill wird nicht installiert: Sein Name besteht nicht nur aus Kleinbuchstaben, '
        'Ziffern und einzelnen Bindestrichen.');
  }
  if (name != kurzname && !name.startsWith('$kurzname-')) {
    throw PluginFehler('Der Skill $name wird nicht installiert: Sein Name beginnt nicht mit dem Kurznamen des '
        'Plugins und einem Bindestrich.');
  }
  if (appNamen.contains(name)) {
    throw PluginFehler('Der Skill $name wird nicht installiert: So heißt ein Skill von moocp.');
  }
  final wurzel = p.join(pluginPfad, 'skills');
  final ordner = p.join(wurzel, name);
  if (FileSystemEntity.typeSync(wurzel, followLinks: false) != FileSystemEntityType.directory ||
      FileSystemEntity.typeSync(ordner, followLinks: false) != FileSystemEntityType.directory) {
    throw PluginFehler('Der Skill $name wird nicht installiert: Der Ordner skills/$name fehlt im Plugin-Ordner.');
  }
  final dateien = <String, List<int>>{};
  try {
    for (final x in Directory(ordner).listSync(recursive: true, followLinks: false)) {
      if (x is Link) {
        throw PluginFehler('Der Skill $name wird nicht installiert: Sein Ordner enthält eine Verknüpfung.');
      }
      if (x is File) dateien[p.posix.joinAll(p.split(p.relative(x.path, from: ordner)))] = x.readAsBytesSync();
    }
  } on FileSystemException catch (x) {
    throw PluginFehler('Der Skill $name wird nicht installiert: Seine Dateien lassen sich nicht lesen (${x.runtimeType}).');
  }
  if (!dateien.containsKey('SKILL.md')) {
    throw PluginFehler('Der Skill $name wird nicht installiert: Im Ordner skills/$name fehlt SKILL.md.');
  }
  return SkillPaket(name, dateien, herkunft: SkillHerkunft.plugin, plugin: plugin);
}

/// Die gemerkten Plugin-Skills [gemerkt], die kein zugestimmtes Plugin mehr
/// nennt: Das Plugin ist abgelehnt, fort oder nennt den Skill nicht mehr. Ein
/// Name der App ([appNamen]) ist nie verwaist.
Set<String> verwaisteSkills(Set<String> gemerkt, PluginSkills plugins, Set<String> appNamen) =>
    gemerkt.difference(plugins.namen).difference(appNamen);
