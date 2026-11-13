// Die Skills eines Plugins in der Einrichtung der KI-Werkzeuge (E13, E35):
// gelesen aus dem Plugin-Ordner, ohne Code des Plugins auszuführen,
// installiert und entfernt wie die der App, wählbare mit Haken; die Skills
// eines abgelehnten oder entfernten Plugins kommen zum Entfernen, und ein
// unbrauchbares Paket hält nichts auf.
//
// Alles läuft in temporären Ordnern: Plugin-Ordner, Einstellungen (ohne
// Datei) und die Skill-Ordner der KI-Werkzeuge. Das Beispiel-Plugin
// (beispiele/plugin/) liefert Beschreibungsdatei und Skills; sein Programm
// wird nicht gebraucht und durch eine leere Datei ersetzt.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einrichtung.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/plugin/beschreibung.dart';
import 'package:moocp/plugin/plugins.dart';
import 'package:moocp/plugin/skills.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

class _EinstellungenOhneDatei extends Einstellungen {
  _EinstellungenOhneDatei() : super(schluessel: 'schluessel');

  @override
  Future<void> speichern() async {}
}

/// Die Skills der App, wie die Einrichtung sie kennt.
const _appNamen = {'moodle', 'moodle-fragen', 'lernsituation'};

void _kopieren(Directory von, Directory nach) {
  nach.createSync(recursive: true);
  for (final e in von.listSync(followLinks: false)) {
    final ziel = p.join(nach.path, p.basename(e.path));
    if (e is Directory) {
      _kopieren(e, Directory(ziel));
    } else if (e is File) {
      e.copySync(ziel);
    }
  }
}

void main() {
  late Directory tmp;
  late Directory pluginsOrdner;
  late _EinstellungenOhneDatei einstellungen;
  late Map<String, String> umgebung;
  late CodexCli codex;
  late LmStudio lm;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('moocp_plugin_skills_');
    pluginsOrdner = Directory(p.join(tmp.path, 'plugins'))..createSync();
    einstellungen = _EinstellungenOhneDatei();
    final heim = p.join(tmp.path, 'heim');
    umgebung = {'USERPROFILE': heim, 'HOME': heim};
    codex = CodexCli(umgebung);
    lm = LmStudio(umgebung, bruecke: p.join(tmp.path, 'app', brueckeExe));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Legt das Beispiel-Plugin unter `plugins/beispiel` an, mit seiner
  /// Beschreibungsdatei (verändert durch [manifest]) und seinen Skills.
  Directory beispielAnlegen({Map<String, Object?> Function(Map<String, Object?>)? manifest}) {
    final ordner = Directory(p.join(pluginsOrdner.path, 'beispiel'))..createSync();
    _kopieren(Directory(p.join('beispiele', 'plugin', 'skills')), Directory(p.join(ordner.path, 'skills')));
    final m = jsonDecode(File(p.join('beispiele', 'plugin', 'plugin.json')).readAsStringSync()) as Map<String, Object?>;
    File(p.join(ordner.path, 'plugin.json')).writeAsStringSync(jsonEncode(manifest == null ? m : manifest(m)));
    File(p.join(ordner.path, 'beispiel.exe')).writeAsStringSync('');
    return ordner;
  }

  Future<Plugins> laden() => Plugins.laden(einstellungen, Protokoll(), pluginsOrdner);

  Future<Plugins> entschieden({required bool zugestimmt}) async {
    final plugins = await laden();
    await plugins.entscheiden(plugins.eintraege.single, zugestimmt: zugestimmt, profile: {'standard'});
    return plugins;
  }

  Directory skillOrdner(KiWerkzeug w, String name) => Directory(p.join(w.skillOrdner.path, name));

  /// Die Prüfung, wie die App sie beim Start macht (main.dart,
  /// _einrichtungsstand), danach das Merken der Plugin-Skills.
  Future<Einrichtungsstand> pruefen(Plugins? plugins, {Set<String>? gewaehlt, Set<String> abgewaehlt = const {}}) async {
    final ps = await pluginSkillsLesen(plugins, appNamen: _appNamen);
    final wahl = {...appWahlSkills, ...ps.wahlSkills};
    final stand = await einrichtungPruefen(
      umgebung: umgebung,
      port: 47811,
      schluessel: 'abc',
      skills: ps.pakete,
      wahlSkills: wahl,
      abgewaehlt: abgewaehlt,
      gewaehlt: gewaehlt ?? gewaehltVorgabe(umgebung, wahl.keys),
      verwaist: verwaisteSkills(einstellungen.pluginSkills, ps, _appNamen),
      pluginSkills: einstellungen.pluginSkills,
      fremd: einstellungen.fremdeSkillOrdner,
      skillFehler: ps.fehler,
      gefunden: [codex, lm],
      python: () async => true,
    );
    einstellungen.pluginSkills =
        pluginSkillsGemerkt(gemerkt: einstellungen.pluginSkills, stand: stand, werkzeuge: [codex, lm]);
    einstellungen.fremdeSkillOrdner = stand.fremdeOrdner;
    return stand;
  }

  /// Tut, was „Installieren" im Dialog mit den Skills tut.
  void installieren(Einrichtungsstand s) {
    for (final ws in s.werkzeuge) {
      for (final paket in ws.skills) {
        if (!ws.stand[paket.name]!.aktuell) skillInstallieren(paket, skillOrdner(ws.werkzeug, paket.name));
      }
      for (final name in ws.entfernen) {
        skillEntfernen(skillOrdner(ws.werkzeug, name));
      }
    }
  }

  group('Lesen aus dem Plugin-Ordner', () {
    test('das Beispiel-Plugin bringt einen Skill, der immer dabei ist, und einen wählbaren', () async {
      final manifest =
          PluginBeschreibung.ausText(File(p.join('beispiele', 'plugin', 'plugin.json')).readAsStringSync());
      expect(manifest.skills, ['beispiel']);
      expect(manifest.wahlSkills.keys, ['beispiel-vorlage']);
      for (final n in [...manifest.skills, ...manifest.wahlSkills.keys]) {
        expect(File(p.join('beispiele', 'plugin', 'skills', n, 'SKILL.md')).existsSync(), isTrue, reason: n);
      }

      beispielAnlegen();
      final ps = await pluginSkillsLesen(await entschieden(zugestimmt: true), appNamen: _appNamen);
      expect(ps.fehler, isEmpty);
      expect(ps.pakete.map((x) => x.name), ['beispiel', 'beispiel-vorlage']);
      expect(ps.pakete.every((x) => x.herkunft == SkillHerkunft.plugin && x.plugin == 'Beispiel'), isTrue);
      expect(ps.pakete.last.dateien.keys, unorderedEquals(['SKILL.md', 'references/hinweis.md']));
      expect(ps.wahlSkills.keys, ['beispiel-vorlage']);
      expect(ps.namen, {'beispiel', 'beispiel-vorlage'});
    });

    test('nur mit Zustimmung zum jetzigen Stand: abgelehnt oder offen gibt es keine Skills', () async {
      beispielAnlegen();
      expect((await pluginSkillsLesen(await laden(), appNamen: _appNamen)).pakete, isEmpty, reason: 'offen');
      final ps = await pluginSkillsLesen(await entschieden(zugestimmt: false), appNamen: _appNamen);
      expect(ps.pakete, isEmpty);
      expect(ps.namen, isEmpty);
      expect((await pluginSkillsLesen(null, appNamen: _appNamen)).pakete, isEmpty, reason: 'ohne Plugins');
    });

    test('nach der Zustimmung geändert: kein Skill, und der Grund nennt das Plugin', () async {
      final ordner = beispielAnlegen();
      final plugins = await entschieden(zugestimmt: true);
      File(p.join(ordner.path, 'skills', 'beispiel', 'SKILL.md')).writeAsStringSync('ausgetauscht');
      final ps = await pluginSkillsLesen(plugins, appNamen: _appNamen);
      expect(ps.pakete, isEmpty);
      expect(ps.fehler.single, allOf(contains('„Beispiel“'), contains('geändert')));
      expect(ps.namen, {'beispiel', 'beispiel-vorlage'}, reason: 'nicht verwaist, nur gerade nicht lesbar');
    });
  });

  group('Ein unbrauchbares Paket hält nichts auf', () {
    test('falscher Name, Name eines Skills der App, fehlender Ordner, fehlende SKILL.md: die übrigen gehen', () async {
      final ordner = beispielAnlegen(
        manifest: (m) => {
          ...m,
          'kurzname': 'moodle',
          'skills': ['moodle-fragen', 'anderer', 'moodle-fehlt', 'moodle-leer', 'moodle', 'moodle-ok'],
          'wahlSkills': {'../moodle-raus': 'Ein Weg nach draußen.'},
        },
      );
      for (final n in ['moodle-fragen', 'anderer', 'moodle', 'moodle-ok']) {
        File(p.join(ordner.path, 'skills', n, 'SKILL.md'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('Skill $n');
      }
      Directory(p.join(ordner.path, 'skills', 'moodle-leer', 'references')).createSync(recursive: true);
      File(p.join(ordner.path, 'skills', 'moodle-leer', 'references', 'a.md')).writeAsStringSync('A');
      // Wohin `skills/../moodle-raus` zeigte: neben den Skill-Ordner.
      File(p.join(ordner.path, 'moodle-raus', 'SKILL.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('außerhalb');

      final ps = await pluginSkillsLesen(await entschieden(zugestimmt: true), appNamen: {'moodle-fragen', 'lernsituation'});
      expect(ps.pakete.map((x) => x.name), ['moodle', 'moodle-ok']);
      expect(ps.wahlSkills, isEmpty);
      final fehler = ps.fehler.join('\n');
      expect(ps.fehler, hasLength(5));
      expect(ps.fehler.every((f) => f.startsWith('Plugin „Beispiel“: ')), isTrue);
      expect(fehler, contains('Der Skill moodle-fragen wird nicht installiert: So heißt ein Skill von moocp.'));
      expect(fehler, contains('Der Skill anderer wird nicht installiert: Sein Name beginnt nicht mit dem Kurznamen'));
      expect(fehler, contains('Der Ordner skills/moodle-fehlt fehlt'));
      expect(fehler, contains('Im Ordner skills/moodle-leer fehlt SKILL.md'));
      expect(fehler, contains('Sein Name besteht nicht nur aus Kleinbuchstaben'));
      expect(fehler, isNot(contains('..')), reason: 'ein ungültiger Name wird nicht genannt (E11)');
    });

    test('eine Verknüpfung im Skill-Ordner: nicht gefolgt, das Paket gilt als unbrauchbar', () {
      final plugin = Directory(p.join(tmp.path, 'x'))..createSync();
      File(p.join(plugin.path, 'skills', 'abc', 'SKILL.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('Skill');
      final draussen = Directory(p.join(tmp.path, 'draussen'))..createSync();
      File(p.join(draussen.path, 'geheim.md')).writeAsStringSync('geheim');
      try {
        Link(p.join(plugin.path, 'skills', 'abc', 'verweis')).createSync(draussen.path);
      } on FileSystemException {
        markTestSkipped('Verknüpfungen lassen sich hier nicht anlegen (fehlendes Recht).');
        return;
      }
      expect(
        () => pluginSkillLesen(plugin.path, 'abc', kurzname: 'abc', appNamen: _appNamen),
        throwsA(isA<PluginFehler>().having((e) => e.grund, 'grund', contains('Verknüpfung'))),
      );
    });

    test('ohne Skills im Plugin: nichts zu tun, kein Fehler', () async {
      beispielAnlegen(manifest: (m) => {...m}..remove('skills')..remove('wahlSkills'));
      final ps = await pluginSkillsLesen(await entschieden(zugestimmt: true), appNamen: _appNamen);
      expect(ps.pakete, isEmpty);
      expect(ps.fehler, isEmpty);
      expect(ps.namen, isEmpty);
    });
  });

  group('Installieren und Entfernen in jedem KI-Werkzeug', () {
    test('der Pflicht-Skill wird installiert und gemerkt, der wählbare nur mit Haken', () async {
      beispielAnlegen();
      final plugins = await entschieden(zugestimmt: true);
      var s = await pruefen(plugins);
      expect(s.gewollt.map((x) => x.name), ['beispiel'], reason: 'wählbar und nicht installiert: aus');
      expect(s.wahlSkills['beispiel-vorlage'], contains('Vorlage'));
      expect(s.brauchtEtwas, isTrue);
      expect(einstellungen.pluginSkills, isEmpty, reason: 'noch nichts installiert');

      installieren(s);
      s = await pruefen(plugins);
      for (final w in [codex, lm]) {
        expect(File(p.join(skillOrdner(w, 'beispiel').path, 'SKILL.md')).existsSync(), isTrue);
        expect(skillOrdner(w, 'beispiel-vorlage').existsSync(), isFalse);
      }
      expect(einstellungen.pluginSkills, {'beispiel'});

      // Mit Haken: installiert, gemerkt; die Vorgabe sieht ihn danach als gewählt.
      s = await pruefen(plugins, gewaehlt: {'beispiel-vorlage'});
      expect(s.gewollt.map((x) => x.name), ['beispiel', 'beispiel-vorlage']);
      installieren(s);
      s = await pruefen(plugins, gewaehlt: {'beispiel-vorlage'});
      // Die Verbindung ist hier nicht eingetragen; bei den Skills ist nichts mehr zu tun.
      expect(s.werkzeuge.every((w) => w.skills.every((x) => w.stand[x.name]!.aktuell) && w.entfernen.isEmpty), isTrue);
      expect(File(p.join(skillOrdner(codex, 'beispiel-vorlage').path, 'references', 'hinweis.md')).existsSync(), isTrue);
      expect(einstellungen.pluginSkills, {'beispiel', 'beispiel-vorlage'});
      expect(gewaehltVorgabe(umgebung, ['beispiel-vorlage']), {'beispiel-vorlage'});

      // Haken weg: entfernt, und vergessen, sobald er nirgends mehr steht.
      s = await pruefen(plugins, gewaehlt: {});
      expect(s.werkzeuge.map((w) => w.entfernen), [
        {'beispiel-vorlage'},
        {'beispiel-vorlage'},
      ]);
      installieren(s);
      await pruefen(plugins, gewaehlt: {});
      expect(skillOrdner(codex, 'beispiel-vorlage').existsSync(), isFalse);
      expect(einstellungen.pluginSkills, {'beispiel'});
    });

    for (final fall in ['abgelehnt', 'entfernt']) {
      test('Plugin $fall: seine Skills kommen in jedem Werkzeug zum Entfernen, auch im abgewählten', () async {
        final ordner = beispielAnlegen();
        var plugins = await entschieden(zugestimmt: true);
        var s = await pruefen(plugins, gewaehlt: {'beispiel-vorlage'});
        installieren(s);
        await pruefen(plugins, gewaehlt: {'beispiel-vorlage'});
        expect(einstellungen.pluginSkills, {'beispiel', 'beispiel-vorlage'});
        // Ein fremder Ordner, den die App nicht installiert hat, bleibt.
        File(p.join(skillOrdner(codex, 'beispiel-fremd').path, 'SKILL.md'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('fremd');

        if (fall == 'abgelehnt') {
          await plugins.entscheiden(plugins.eintraege.single, zugestimmt: false);
        } else {
          ordner.deleteSync(recursive: true);
          plugins = await laden();
        }
        s = await pruefen(plugins, gewaehlt: {'beispiel-vorlage'}, abgewaehlt: {'lmstudio'});
        expect(s.skills, isEmpty);
        expect(s.werkzeuge.map((w) => w.entfernen), [
          {'beispiel', 'beispiel-vorlage'},
          {'beispiel', 'beispiel-vorlage'},
        ]);
        expect(s.brauchtEtwas, isTrue);
        installieren(s);
        s = await pruefen(plugins, gewaehlt: {'beispiel-vorlage'}, abgewaehlt: {'lmstudio'});
        expect(s.werkzeuge.every((w) => w.entfernen.isEmpty), isTrue);
        expect(einstellungen.pluginSkills, isEmpty, reason: 'nirgends mehr installiert: vergessen');
        expect(File(p.join(skillOrdner(codex, 'beispiel-fremd').path, 'SKILL.md')).existsSync(), isTrue);
      });
    }

    test('ein fremder Ordner mit dem Namen eines Plugin-Skills wird nicht gemerkt', () async {
      beispielAnlegen();
      final plugins = await entschieden(zugestimmt: true);
      File(p.join(skillOrdner(codex, 'beispiel').path, 'SKILL.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('von jemand anderem');
      await pruefen(plugins, abgewaehlt: {'codex', 'lmstudio'});
      expect(einstellungen.pluginSkills, isEmpty);
    });

    test('ein fremder Ordner gleichen Namens wird nicht überschrieben; der Dialog nennt ihn, ohne aufzuhalten', () async {
      beispielAnlegen();
      final plugins = await entschieden(zugestimmt: true);
      final fremd = File(p.join(skillOrdner(codex, 'beispiel').path, 'SKILL.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('von jemand anderem');
      File(p.join(skillOrdner(codex, 'beispiel').path, 'notizen.md')).writeAsStringSync('eigene Notizen');

      var s = await pruefen(plugins);
      final codexStand = s.werkzeuge.firstWhere((w) => w.werkzeug.id == 'codex');
      expect(codexStand.skills.map((x) => x.name), isNot(contains('beispiel')));
      expect(codexStand.entfernen, isEmpty);
      final konflikt = s.skillFehler.where((f) => f.contains('stammt nicht von moocp')).single;
      expect(konflikt, allOf(contains('Codex CLI'), contains('beispiel'), contains('„Beispiel“')));
      expect(s.einrichtbar, isTrue, reason: 'in LM Studio ist etwas zu tun');

      installieren(s);
      s = await pruefen(plugins);
      expect(fremd.readAsStringSync(), 'von jemand anderem');
      expect(File(p.join(skillOrdner(codex, 'beispiel').path, 'notizen.md')).existsSync(), isTrue);
      expect(File(p.join(skillOrdner(lm, 'beispiel').path, 'SKILL.md')).existsSync(), isTrue);
      // Nichts hält auf: Bei den Skills ist in beiden Werkzeugen nichts mehr zu tun.
      expect(s.werkzeuge.every((w) => w.skills.every((x) => w.stand[x.name]!.aktuell) && w.entfernen.isEmpty), isTrue);
      expect(s.skillFehler.where((f) => f.contains('stammt nicht von moocp')), hasLength(1));
      // Gemerkt ist er, weil moocp ihn in LM Studio installiert hat; in Codex
      // bleibt der fremde Ordner trotzdem, solange moocp ihn nicht kennt.
      expect(einstellungen.pluginSkills, {'beispiel'});
    });

    test('ein fremder Ordner öffnet den Dialog einmal und bleibt bei der Deinstallation stehen', () async {
      beispielAnlegen();
      final plugins = await entschieden(zugestimmt: true);
      final fremd = File(p.join(skillOrdner(codex, 'beispiel').path, 'SKILL.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('von jemand anderem');
      final ps = await pluginSkillsLesen(plugins, appNamen: _appNamen);
      Future<Einrichtungsstand> mit(Set<String> gesehen) => einrichtungPruefen(
        umgebung: umgebung,
        port: 47811,
        schluessel: 'abc',
        skills: ps.pakete,
        wahlSkills: {...appWahlSkills, ...ps.wahlSkills},
        gesehen: gesehen,
        gefunden: [codex, lm],
        python: () async => true,
      );

      final erst = await mit(const {});
      expect(erst.skillFehlerNeu, isTrue);
      expect(erst.fremdeOrdner, {'codex/beispiel'});
      expect((await mit(erst.konfliktStand)).skillFehlerNeu, isFalse);

      installieren(await pruefen(plugins));
      await pruefen(plugins);
      expect(einstellungen.fremdeSkillOrdner, {'codex/beispiel'});
      await einrichtungEntfernen(
        umgebung: umgebung,
        skills: [...einstellungen.pluginSkills],
        werkzeuge: [codex, lm],
        auslassen: einstellungen.fremdeSkillOrdner,
      );
      expect(fremd.readAsStringSync(), 'von jemand anderem');
      expect(skillOrdner(lm, 'beispiel').existsSync(), isFalse);
    });

    test('ein fremder Ordner gleichen Namens in einem abgewählten Werkzeug wird nicht entfernt', () async {
      beispielAnlegen();
      final plugins = await entschieden(zugestimmt: true);
      final fremd = File(p.join(skillOrdner(codex, 'beispiel').path, 'SKILL.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('von jemand anderem');

      final s = await pruefen(plugins, abgewaehlt: {'codex'});
      expect(s.werkzeuge.firstWhere((w) => w.werkzeug.id == 'codex').entfernen, isEmpty);
      installieren(s);
      expect(fremd.readAsStringSync(), 'von jemand anderem');
    });

    test('ein Ordner, den moocp für das Plugin installiert hat, wird weiter aktualisiert', () async {
      beispielAnlegen();
      final plugins = await entschieden(zugestimmt: true);
      installieren(await pruefen(plugins));
      await pruefen(plugins);
      expect(einstellungen.pluginSkills, {'beispiel'});
      final datei = File(p.join(skillOrdner(codex, 'beispiel').path, 'SKILL.md'))..writeAsStringSync('veraltet');

      final s = await pruefen(plugins);
      expect(s.skillFehler, isEmpty);
      installieren(s);
      expect(datei.readAsStringSync(), isNot('veraltet'));
    });

    test('eine Verknüpfung an Stelle des Skill-Ordners: nicht gefolgt, nichts hineingeschrieben', () async {
      beispielAnlegen();
      final plugins = await entschieden(zugestimmt: true);
      final draussen = Directory(p.join(tmp.path, 'draussen'))..createSync();
      codex.skillOrdner.createSync(recursive: true);
      try {
        Link(skillOrdner(codex, 'beispiel').path).createSync(draussen.path);
      } on FileSystemException {
        markTestSkipped('Verknüpfungen lassen sich hier nicht anlegen (fehlendes Recht).');
        return;
      }

      final s = await pruefen(plugins);
      expect(s.skillFehler.where((f) => f.contains('stammt nicht von moocp')), hasLength(1));
      installieren(s);
      expect(draussen.listSync(), isEmpty);
    });

    test('eine Verknüpfung in einem installierten Skill: Aufräumen folgt ihr nicht, entfernt nur sie', () {
      final ziel = Directory(p.join(tmp.path, 'skills', 'moodle'))..createSync(recursive: true);
      final draussen = Directory(p.join(tmp.path, 'draussen'))..createSync();
      final geheim = File(p.join(draussen.path, 'geheim.md'))..writeAsStringSync('bleibt');
      try {
        Link(p.join(ziel.path, 'verweis')).createSync(draussen.path);
      } on FileSystemException {
        markTestSkipped('Verknüpfungen lassen sich hier nicht anlegen (fehlendes Recht).');
        return;
      }
      final paket = SkillPaket('moodle', {'SKILL.md': utf8.encode('Skill')}, herkunft: SkillHerkunft.app);

      expect(skillVergleichen(paket, ziel).ueberzaehlig, 0, reason: 'der Inhalt hinter der Verknüpfung zählt nicht');
      skillInstallieren(paket, ziel);
      expect(geheim.readAsStringSync(), 'bleibt');
      expect(FileSystemEntity.typeSync(p.join(ziel.path, 'verweis'), followLinks: false), FileSystemEntityType.notFound);
      skillEntfernen(ziel);
      expect(geheim.existsSync(), isTrue);
    });

    test('ein unbrauchbares Paket: Der Dialog nennt es, alles andere wird eingerichtet', () async {
      beispielAnlegen(manifest: (m) => {...m, 'skills': ['beispiel', 'beispiel-fehlt']});
      final s = await pruefen(await entschieden(zugestimmt: true));
      expect(s.skillFehler.single, contains('skills/beispiel-fehlt'));
      expect(s.gewollt.map((x) => x.name), ['beispiel']);
      expect(s.einrichtbar, isTrue);
    });
  });

  group('Entwicklungs-Plugin', () {
    /// Ein Entwicklungsordner mit Beschreibungsdatei und Skills des
    /// Beispiel-Plugins, außerhalb von `plugins/`; [text] steht in jeder
    /// SKILL.md, damit sich die Herkunft am Inhalt zeigt.
    EntwicklungsSkills entwicklungAnlegen({String text = 'aus der Entwicklung', List<String>? skills}) {
      final ordner = Directory(p.join(tmp.path, 'entwicklung'))..createSync(recursive: true);
      _kopieren(Directory(p.join('beispiele', 'plugin', 'skills')), Directory(p.join(ordner.path, 'skills')));
      for (final n in ['beispiel', 'beispiel-vorlage']) {
        File(p.join(ordner.path, 'skills', n, 'SKILL.md')).writeAsStringSync('$n $text');
      }
      final m = jsonDecode(File(p.join('beispiele', 'plugin', 'plugin.json')).readAsStringSync()) as Map<String, Object?>;
      if (skills != null) m['skills'] = skills;
      final text2 = jsonEncode(m);
      File(p.join(ordner.path, 'plugin.json')).writeAsStringSync(text2);
      return (ordner: ordner.path, beschreibung: PluginBeschreibung.ausText(text2));
    }

    Future<Einrichtungsstand> pruefenMit(Plugins? plugins, EntwicklungsSkills? entwicklung,
        {Set<String> gewaehlt = const {}}) async {
      final ps = await pluginSkillsLesen(plugins, appNamen: _appNamen, entwicklung: entwicklung);
      final stand = await einrichtungPruefen(
        umgebung: umgebung,
        port: 47811,
        schluessel: 'abc',
        skills: ps.pakete,
        wahlSkills: {...appWahlSkills, ...ps.wahlSkills},
        gewaehlt: gewaehlt,
        verwaist: verwaisteSkills(einstellungen.pluginSkills, ps, _appNamen),
        pluginSkills: einstellungen.pluginSkills,
        fremd: einstellungen.fremdeSkillOrdner,
        skillFehler: ps.fehler,
        gefunden: [codex, lm],
        python: () async => true,
      );
      einstellungen.pluginSkills =
          pluginSkillsGemerkt(gemerkt: einstellungen.pluginSkills, stand: stand, werkzeuge: [codex, lm]);
      einstellungen.fremdeSkillOrdner = stand.fremdeOrdner;
      return stand;
    }

    test('nach dem Ja: Skills aus dem Entwicklungsordner wie die eines installierten Plugins', () async {
      final ps = await pluginSkillsLesen(null, appNamen: _appNamen, entwicklung: entwicklungAnlegen());
      expect(ps.fehler, isEmpty);
      expect(ps.pakete.map((x) => x.name), ['beispiel', 'beispiel-vorlage']);
      expect(ps.pakete.every((x) => x.herkunft == SkillHerkunft.plugin && x.plugin == 'Beispiel'), isTrue);
      expect(utf8.decode(ps.pakete.first.dateien['SKILL.md']!), 'beispiel aus der Entwicklung');
      expect(ps.wahlSkills.keys, ['beispiel-vorlage']);
      expect(ps.namen, {'beispiel', 'beispiel-vorlage'});
    });

    test('abgelehnt oder ohne Parameter: keine Skills', () async {
      final ps = await pluginSkillsLesen(null, appNamen: _appNamen);
      expect(ps.pakete, isEmpty);
      expect(ps.namen, isEmpty);
    });

    test('dieselben Regeln: ein unbrauchbares Paket nennt das Entwicklungs-Plugin', () async {
      final ps = await pluginSkillsLesen(null,
          appNamen: _appNamen, entwicklung: entwicklungAnlegen(skills: ['beispiel', 'moodle', 'beispiel-fehlt']));
      expect(ps.pakete.map((x) => x.name), ['beispiel', 'beispiel-vorlage']);
      expect(ps.fehler, hasLength(2));
      expect(ps.fehler.every((f) => f.startsWith('Entwicklungs-Plugin „Beispiel“: ')), isTrue);
      expect(ps.fehlerStand, hasLength(1));
    });

    test('ein installiertes Plugin mit demselben Kurznamen: Es gelten die Skills des Entwicklungsordners', () async {
      beispielAnlegen();
      final plugins = await entschieden(zugestimmt: true);
      final ps = await pluginSkillsLesen(plugins, appNamen: _appNamen, entwicklung: entwicklungAnlegen());
      expect(ps.pakete.map((x) => x.name), ['beispiel', 'beispiel-vorlage'], reason: 'jeder Skill einmal');
      expect(ps.pakete.every((x) => utf8.decode(x.dateien['SKILL.md']!).endsWith('aus der Entwicklung')), isTrue);
    });

    test('installiert und gemerkt; ohne Parameter verwaist, außer ein installiertes Plugin bringt ihn mit', () async {
      final entwicklung = entwicklungAnlegen();
      var s = await pruefenMit(null, entwicklung, gewaehlt: {'beispiel-vorlage'});
      expect(s.gewollt.map((x) => x.name), ['beispiel', 'beispiel-vorlage']);
      installieren(s);
      await pruefenMit(null, entwicklung, gewaehlt: {'beispiel-vorlage'});
      expect(einstellungen.pluginSkills, {'beispiel', 'beispiel-vorlage'});
      expect(File(p.join(skillOrdner(codex, 'beispiel').path, 'SKILL.md')).readAsStringSync(),
          'beispiel aus der Entwicklung');

      // Ein installiertes Plugin mit Zustimmung bringt beispiel und
      // beispiel-vorlage mit, aber nur beispiel als Pflicht: Nichts ist verwaist.
      beispielAnlegen();
      final plugins = await entschieden(zugestimmt: true);
      s = await pruefenMit(plugins, null, gewaehlt: {'beispiel-vorlage'});
      expect(s.werkzeuge.every((w) => w.entfernen.isEmpty), isTrue);
      expect(s.werkzeuge.first.stand['beispiel']!.aktuell, isFalse, reason: 'Inhalt des installierten Plugins');

      // Ohne installiertes Plugin und ohne Parameter: beide verwaist.
      s = await pruefenMit(null, null, gewaehlt: {'beispiel-vorlage'});
      expect(s.werkzeuge.map((w) => w.entfernen), [
        {'beispiel', 'beispiel-vorlage'},
        {'beispiel', 'beispiel-vorlage'},
      ]);
      expect(s.brauchtEtwas, isTrue);
    });
  });

  group('Ein unbrauchbares Paket öffnet den Dialog einmal je Stand', () {
    test('der Stand bleibt gleich, solange sich nichts ändert, und wechselt mit dem Plugin', () async {
      final ordner = beispielAnlegen(manifest: (m) => {...m, 'skills': ['beispiel', 'beispiel-fehlt']});
      final a = (await pluginSkillsLesen(await entschieden(zugestimmt: true), appNamen: _appNamen)).fehlerStand;
      final b = (await pluginSkillsLesen(await laden(), appNamen: _appNamen)).fehlerStand;
      expect(a, hasLength(1));
      expect(b, a);

      File(p.join(ordner.path, 'skills', 'beispiel', 'SKILL.md')).writeAsStringSync('neue Version');
      final c = (await pluginSkillsLesen(await entschieden(zugestimmt: true), appNamen: _appNamen)).fehlerStand;
      expect(c, hasLength(1));
      expect(c, isNot(a), reason: 'anderer Stand des Plugins');

      beispielAnlegen(manifest: (m) => m);
      expect((await pluginSkillsLesen(await entschieden(zugestimmt: true), appNamen: _appNamen)).fehlerStand, isEmpty);
    });

    test('ungesehen: Der Dialog muss erscheinen, auch wenn sonst alles eingerichtet ist', () async {
      Future<Einrichtungsstand> stand({required bool neu, List<String> fehler = const ['Plugin „X“: kaputt']}) =>
          einrichtungPruefen(
            umgebung: umgebung,
            port: 47811,
            schluessel: 'abc',
            skills: const [],
            wahlSkills: const {},
            skillFehler: fehler,
            skillFehlerNeu: neu,
            gefunden: [codex],
            python: () async => true,
          );
      await codex.eintragen(47811, 'abc');
      final gesehen = await stand(neu: false);
      expect((gesehen.brauchtEinrichtung, gesehen.brauchtEtwas), (false, false));
      final ungesehen = await stand(neu: true);
      expect((ungesehen.brauchtEinrichtung, ungesehen.brauchtEtwas, ungesehen.einrichtbar), (false, true, false));
      expect((await stand(neu: true, fehler: const [])).brauchtEtwas, isFalse, reason: 'ohne Fehler nichts Neues');
    });

    test('gesehene Stände überstehen das Speichern', () {
      final e = Einstellungen(schluessel: 'k', skillFehlerGesehen: {'ab', 'cd'});
      final j = jsonDecode(jsonEncode(e.zuJson())) as Map<String, dynamic>;
      expect(Einstellungen.aus(j, Einstellungen(schluessel: 'x')).skillFehlerGesehen, {'ab', 'cd'});
      expect(Einstellungen(schluessel: 'k').zuJson().containsKey('skillFehlerGesehen'), isFalse);
    });
  });

  group('Deinstallation und Einstellungen', () {
    test('--claude-entfernen entfernt die gemerkten Skills der Plugins; ein Name, der keiner ist, bildet keinen Pfad',
        () async {
      for (final w in [codex, lm]) {
        File(p.join(skillOrdner(w, 'beispiel').path, 'SKILL.md'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('Skill');
      }
      final daneben = File(p.join(codex.skillOrdner.path, 'nicht-entfernen.md'))..writeAsStringSync('bleibt');
      final e = await einrichtungEntfernen(umgebung: umgebung, skills: ['beispiel', '..', '.'], werkzeuge: [codex, lm]);
      expect(e.code, 0);
      expect(skillOrdner(codex, 'beispiel').existsSync(), isFalse);
      expect(skillOrdner(lm, 'beispiel').existsSync(), isFalse);
      expect(daneben.existsSync(), isTrue);
    });

    test('die gemerkten Skills überstehen das Speichern; was kein Skill-Name ist, fällt beim Lesen weg', () {
      final e = Einstellungen(schluessel: 'k', pluginSkills: {'beispiel', 'beispiel-vorlage'});
      final j = jsonDecode(jsonEncode(e.zuJson())) as Map<String, dynamic>;
      expect(j['pluginSkills'], ['beispiel', 'beispiel-vorlage']);
      expect(Einstellungen.aus(j, Einstellungen(schluessel: 'x')).pluginSkills, {'beispiel', 'beispiel-vorlage'});
      j['pluginSkills'] = ['beispiel', '..', r'a\b', 'C:', 3];
      expect(Einstellungen.aus(j, Einstellungen(schluessel: 'x')).pluginSkills, {'beispiel'});
      expect(Einstellungen(schluessel: 'k').zuJson().containsKey('pluginSkills'), isFalse);
    });

    test('die fremden Ordner überstehen das Speichern', () {
      final e = Einstellungen(schluessel: 'k', fremdeSkillOrdner: {'codex/beispiel', 'claude/beispiel-vorlage'});
      final j = jsonDecode(jsonEncode(e.zuJson())) as Map<String, dynamic>;
      expect(j['fremdeSkillOrdner'], ['claude/beispiel-vorlage', 'codex/beispiel']);
      expect(
        Einstellungen.aus(j, Einstellungen(schluessel: 'x')).fremdeSkillOrdner,
        {'codex/beispiel', 'claude/beispiel-vorlage'},
      );
      expect(Einstellungen(schluessel: 'k').zuJson().containsKey('fremdeSkillOrdner'), isFalse);
    });

    test('Skill-Namen: wie die der App, nichts, was einen Pfad bildet', () {
      for (final n in ['moodle', 'moodle-fragen', 'beispiel-vorlage', 'a1']) {
        expect(skillNameGueltig(n), isTrue, reason: n);
      }
      for (final n in ['', '..', '.', 'a/b', r'a\b', 'A', 'a--b', '-a', 'a-', 'a b', 'ä', 'C:', 'x' * 65]) {
        expect(skillNameGueltig(n), isFalse, reason: n);
      }
    });
  });
}
