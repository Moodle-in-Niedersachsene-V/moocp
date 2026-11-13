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
//   jetzigen Stand zugestimmt hat. Ob ein Plugin in einem Profil eingeschaltet
//   ist, zählt nicht: Skills liegen je KI-Werkzeug, nicht je Profil, wie die
//   der App. Ein Entwicklungs-Plugin (entwicklung.dart) bringt keine Skills
//   mit: Es hat keine gemerkte Zustimmung, und seine Dateien ändern sich
//   ständig.
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
//   der ein gültiger Skill-Name ist.
//
// Welche Plugin-Skills die App installiert hat, merkt sie sich in den
// Einstellungen (Einstellungen.pluginSkills, einrichtung.dart
// pluginSkillsGemerkt). Fehlt das Plugin, ist es abgelehnt oder nennt es einen
// gemerkten Skill nicht mehr, ist der Skill verwaist ([verwaisteSkills]), und
// die Einrichtung bietet ihn zum Entfernen an.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../einrichtung.dart';
import 'beschreibung.dart';
import 'plugins.dart';
import 'pruefsumme.dart';

/// Was die Einrichtung aus den Plugins an Skills bekommt.
class PluginSkills {
  const PluginSkills({
    this.pakete = const [],
    this.wahlSkills = const {},
    this.namen = const {},
    this.fehler = const [],
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
}

/// Liest die Skills aller Plugins in [plugins], denen für den jetzigen Stand
/// zugestimmt ist. [appNamen] sind die Namen der Skills der App; so darf
/// kein Skill eines Plugins heißen. Ohne Plugins (null) gibt es nichts.
Future<PluginSkills> pluginSkillsLesen(Plugins? plugins, {required Set<String> appNamen}) async {
  if (plugins == null) return const PluginSkills();
  final pakete = <SkillPaket>[];
  final wahl = <String, String>{};
  final namen = <String>{};
  final fehler = <String>[];
  for (final s in plugins.staende) {
    final e = s.eintrag;
    final b = e.beschreibung;
    if (s.zustand != PluginZustand.zugestimmt || b == null) continue;
    final alle = [...b.skills, ...b.wahlSkills.keys];
    if (alle.isEmpty) continue;
    namen.addAll(alle);
    String satz(String grund) => 'Plugin „${e.anzeigename}“: $grund';
    if (!await _unveraendert(e)) {
      fehler.add(satz('Der Plugin-Ordner hat sich seit dem Start geändert. Seine Skills werden erst nach dem '
          'nächsten Start der App angeboten, mit neuer Zustimmung.'));
      continue;
    }
    for (final name in alle) {
      try {
        pakete.add(pluginSkillLesen(e.pfad, name, kurzname: b.kurzname, appNamen: appNamen, plugin: e.anzeigename));
        final text = b.wahlSkills[name];
        if (text != null) wahl[name] = text;
      } on PluginFehler catch (x) {
        fehler.add(satz(x.grund));
      }
    }
  }
  return PluginSkills(pakete: pakete, wahlSkills: wahl, namen: namen, fehler: fehler);
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
