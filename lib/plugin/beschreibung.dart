// Die Beschreibungsdatei eines Plugins, `plugin.json` im Plugin-Ordner (E35).
//
// Die App liest sie, ohne Code des Plugins auszuführen: Sie entscheidet vor
// dem Start, ob die Lehrkraft gefragt wird und was in der Frage steht. Eine
// Datei, die sich nicht lesen lässt oder eine Regel bricht, hält das Plugin
// vom Laden ab; der Grund ([PluginFehler.grund]) ist ein Satz auf Deutsch, der
// das Feld nennt, nie dessen Inhalt -- er geht ins Protokoll (E11), und
// Steuerzeichen in den Texten könnten dort Zeilen fälschen, deshalb gibt es
// keine.
//
// Unbekannte Felder werden überlesen. Ob die Schnittstellenversion zu dieser
// App passt, beurteilt dieser Schritt nicht (schnittstelle.dart).

import 'dart:convert';

import '../update/updateliste.dart' show herkunftGueltig;
import 'adressmuster.dart';

/// Der Kurzname hat eine Höchstlänge, damit der Name, unter dem ein KI-Werkzeug
/// ein Werkzeug des Plugins sieht (`mcp__<Profil>__<Kurzname>_<Werkzeug>`), in
/// die 64 Zeichen passt, die Claude Code zulässt.
const int kurznameHoechstens = 12;

final RegExp _kurzname = RegExp(r'^[a-z][a-z0-9]*$');

/// Warum ein Plugin nicht geladen wird.
class PluginFehler implements Exception {
  const PluginFehler(this.grund);

  /// Ein Satz auf Deutsch für die Lehrkraft und das Protokoll, ohne Inhalte
  /// aus der Datei.
  final String grund;

  @override
  String toString() => grund;
}

enum ZugriffsArt {
  lesen,
  schreiben;

  static ZugriffsArt? ausText(String t) => values.where((a) => a.name == t).firstOrNull;
}

/// Eine Seite der Moodle-Instanz, die das Plugin über die Sperrliste der App
/// hinaus braucht (E36): ein Muster, ob es sie liest oder beschreibt, und ein
/// Grund in einem Satz, den die Lehrkraft vor ihrer Zustimmung liest.
class Zusatzadresse {
  const Zusatzadresse(this.muster, this.art, this.grund);

  final Adressmuster muster;
  final ZugriffsArt art;
  final String grund;
}

class PluginBeschreibung {
  const PluginBeschreibung({
    required this.name,
    required this.kurzname,
    required this.version,
    required this.schnittstelle,
    required this.programm,
    required this.herkunft,
    this.updateQuellen = const [],
    this.zusatzadressen = const [],
    this.skills = const [],
    this.wahlSkills = const {},
    this.ohneAnmeldung = const [],
    this.entwicklungsPort,
  });

  /// Der Anzeigename.
  final String name;

  /// Der technische Kurzname: jedes Werkzeug des Plugins beginnt mit
  /// `<kurzname>_`.
  final String kurzname;
  final String version;

  /// Die Version der Plugin-Schnittstelle, die das Plugin braucht.
  final int schnittstelle;

  /// Das Programm, relativ zum Plugin-Ordner, so geschrieben, wie es in der
  /// Datei steht (mit „/" oder „\"); es liegt sicher innerhalb des Ordners.
  final String programm;

  /// Wer das Plugin herausgibt; steht im Dialog der Zustimmung.
  final String herkunft;

  /// GitHub-Repositorys `Besitzer/Name` in fester Reihenfolge, aus denen die
  /// Updates des Plugins kommen (plugin_update.dart); jedes ist eine gültige
  /// Herkunft der Update-Prüfung (updateliste.dart, herkunftGueltig).
  final List<String> updateQuellen;
  final List<Zusatzadresse> zusatzadressen;

  /// Die Skills, die immer dabei sind, mit ihrem Namen; jeder liegt im
  /// Plugin-Ordner unter `skills/<name>/` (plugin/skills.dart). Ob ein Name
  /// den Regeln für Skills folgt (Kurzname vorn, kein Name eines Skills der
  /// App), prüft erst die Einrichtung: Ein falscher Name macht nur dieses
  /// Paket unbrauchbar, nicht das Plugin.
  final List<String> skills;

  /// Wählbare Skills: Name und Beschreibung, wie bei `appWahlSkills`; sie
  /// liegen wie [skills] unter `skills/<name>/`. Kein Name steht in beiden.
  final Map<String, String> wahlSkills;

  /// Die Werkzeuge, die ohne Moodle-Anmeldung arbeiten. Hier wird nur die Form
  /// geprüft; dass das Plugin jedes davon hat, prüft die Verbindung beim Start
  /// (verbindung.dart, ohneAnmeldungPruefen), sonst lädt es nicht.
  final List<String> ohneAnmeldung;

  /// Der feste Port, auf dem das Plugin im Debugger seines Entwicklers läuft.
  final int? entwicklungsPort;

  /// Liest den Text der Datei. Eine Byte-Order-Mark am Anfang, wie sie
  /// Editoren unter Windows schreiben, stört nicht.
  static PluginBeschreibung ausText(String text) {
    final Object? json;
    try {
      json = jsonDecode(text.startsWith('﻿') ? text.substring(1) : text);
    } on FormatException {
      throw const PluginFehler('Die Beschreibungsdatei ist keine gültige JSON-Datei.');
    }
    return ausJson(json);
  }

  /// Prüft den Inhalt der Datei; wirft [PluginFehler].
  static PluginBeschreibung ausJson(Object? json) {
    if (json is! Map) {
      throw const PluginFehler('Die Beschreibungsdatei enthält kein JSON-Objekt.');
    }
    final kurzname = _pflichtText(json, 'kurzname');
    if (kurzname.length > kurznameHoechstens) {
      throw const PluginFehler(
        'Der Kurzname ist zu lang: höchstens $kurznameHoechstens Zeichen, damit der Werkzeugname '
        'in die 64 Zeichen passt, die Claude Code zulässt.',
      );
    }
    if (!_kurzname.hasMatch(kurzname)) {
      throw const PluginFehler(
        'Der Kurzname besteht nur aus Kleinbuchstaben und Ziffern und beginnt mit einem Buchstaben.',
      );
    }
    final skills = _skills(json['skills']);
    final wahlSkills = _wahlSkills(json['wahlSkills']);
    if (skills.any(wahlSkills.containsKey)) {
      throw const PluginFehler('Ein Skill steht in „skills“ und in „wahlSkills“; er ist entweder immer dabei oder wählbar.');
    }
    return PluginBeschreibung(
      name: _pflichtText(json, 'name'),
      kurzname: kurzname,
      version: _pflichtText(json, 'version'),
      schnittstelle: _schnittstelle(json['schnittstelle']),
      programm: _programm(_pflichtText(json, 'programm')),
      herkunft: _pflichtText(json, 'herkunft'),
      updateQuellen: _updateQuellen(json['updateQuellen']),
      zusatzadressen: _zusatzadressen(json['zusatzadressen']),
      skills: skills,
      wahlSkills: wahlSkills,
      ohneAnmeldung: _ohneAnmeldung(json['ohneAnmeldung']),
      entwicklungsPort: _port(json['entwicklungsPort']),
    );
  }
}

bool _hatSteuerzeichen(String s) => s.codeUnits.any((c) => c < 0x20 || c == 0x7f);

/// Ein Text, der da sein muss, nicht leer ist und keine Steuerzeichen hat.
String _pflichtText(Map j, String feld) {
  final w = j[feld];
  if (w == null) throw PluginFehler('Das Feld „$feld“ fehlt.');
  if (w is! String) throw PluginFehler('Das Feld „$feld“ muss ein Text sein.');
  final t = w.trim();
  if (t.isEmpty) throw PluginFehler('Das Feld „$feld“ ist leer.');
  if (_hatSteuerzeichen(t)) throw PluginFehler('Das Feld „$feld“ enthält ein Steuerzeichen.');
  return t;
}

int _schnittstelle(Object? w) {
  if (w == null) throw const PluginFehler('Das Feld „schnittstelle“ fehlt.');
  if (w is! int || w < 1) throw const PluginFehler('Das Feld „schnittstelle“ muss eine ganze Zahl ab 1 sein.');
  return w;
}

/// Das Programm muss innerhalb des Plugin-Ordners liegen: relativ, ohne
/// Laufwerk oder Datenstrom („:"), ohne „..", und eine Datei, kein Ordner.
/// Beide Schrägstriche gelten als Trenner; sonst käme „bin\..\..\x" an einer
/// Prüfung vorbei, die nur „/" kennt.
String _programm(String p) {
  const regel = 'Das Feld „programm“ nennt eine Datei innerhalb des Plugin-Ordners, relativ und ohne „..“.';
  if (p.contains(':') || p.startsWith('/') || p.startsWith(r'\') || p.endsWith('/') || p.endsWith(r'\')) {
    throw const PluginFehler(regel);
  }
  final segmente = p.split(RegExp(r'[/\\]'));
  if (segmente.contains('..')) throw const PluginFehler(regel);
  if (segmente.every((s) => s.isEmpty || s == '.')) throw const PluginFehler(regel);
  return p;
}

List<String> _updateQuellen(Object? w) {
  if (w == null) return const [];
  const regel = 'Das Feld „updateQuellen“ ist eine Liste von GitHub-Repositorys der Form Besitzer/Name.';
  if (w is! List) throw const PluginFehler(regel);
  final quellen = <String>[];
  for (final q in w) {
    if (q is! String || !herkunftGueltig(q)) throw const PluginFehler(regel);
    quellen.add(q);
  }
  return quellen;
}

List<Zusatzadresse> _zusatzadressen(Object? w) {
  if (w == null) return const [];
  if (w is! List) throw const PluginFehler('Das Feld „zusatzadressen“ ist eine Liste.');
  final ergebnis = <Zusatzadresse>[];
  for (final (i, eintrag) in w.indexed) {
    try {
      ergebnis.add(_zusatzadresse(eintrag));
    } on PluginFehler catch (e) {
      throw PluginFehler('Zusatzadresse ${i + 1}: ${e.grund}');
    }
  }
  return ergebnis;
}

Zusatzadresse _zusatzadresse(Object? w) {
  if (w is! Map) throw const PluginFehler('Eine Zusatzadresse ist ein Objekt mit „muster“, „art“ und „grund“.');
  final Adressmuster muster;
  try {
    muster = Adressmuster.parsen(_pflichtText(w, 'muster'));
  } on FormatException catch (e) {
    throw PluginFehler(e.message);
  }
  final bereich = sperrbereichBeruehrt(muster);
  if (bereich != null) {
    throw PluginFehler(
      'Das Muster kann Adressen im gesperrten Bereich „${bereich.name}“ treffen; '
      'dorthin darf kein Plugin.',
    );
  }
  final art = ZugriffsArt.ausText(_pflichtText(w, 'art'));
  if (art == null) throw const PluginFehler('Das Feld „art“ ist „lesen“ oder „schreiben“.');
  return Zusatzadresse(muster, art, _pflichtText(w, 'grund'));
}

List<String> _skills(Object? w) {
  if (w == null) return const [];
  const regel = 'Das Feld „skills“ ist eine Liste von Skill-Namen.';
  if (w is! List) throw const PluginFehler(regel);
  final namen = <String>[];
  for (final n in w) {
    if (n is! String || n.isEmpty || _hatSteuerzeichen(n)) throw const PluginFehler(regel);
    if (namen.contains(n)) throw const PluginFehler('Das Feld „skills“ nennt einen Skill zweimal.');
    namen.add(n);
  }
  return namen;
}

Map<String, String> _wahlSkills(Object? w) {
  if (w == null) return const {};
  const regel = 'Das Feld „wahlSkills“ ist ein Objekt aus Skill-Name und Beschreibung, beides Text.';
  if (w is! Map) throw const PluginFehler(regel);
  final ergebnis = <String, String>{};
  for (final MapEntry(:key, :value) in w.entries) {
    if (key is! String || key.isEmpty || value is! String || value.trim().isEmpty) throw const PluginFehler(regel);
    if (_hatSteuerzeichen(key) || _hatSteuerzeichen(value)) throw const PluginFehler(regel);
    ergebnis[key] = value.trim();
  }
  return ergebnis;
}

List<String> _ohneAnmeldung(Object? w) {
  if (w == null) return const [];
  const regel = 'Das Feld „ohneAnmeldung“ ist eine Liste von Werkzeugnamen.';
  if (w is! List) throw const PluginFehler(regel);
  final namen = <String>[];
  for (final n in w) {
    if (n is! String || n.trim().isEmpty || _hatSteuerzeichen(n)) throw const PluginFehler(regel);
    namen.add(n.trim());
  }
  return namen;
}

int? _port(Object? w) {
  if (w == null) return null;
  if (w is! int || w < 1 || w > 65535) {
    throw const PluginFehler('Das Feld „entwicklungsPort“ ist eine Portnummer von 1 bis 65535.');
  }
  return w;
}
