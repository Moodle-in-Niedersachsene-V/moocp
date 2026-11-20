// E37: Die Sperre lebt außerhalb des Arbeitsordners. Gespeichert werden nur
// Prüfsummen, keine Inhalte oder Sitzungsschlüssel. Ein fehlender Nachweis
// beendet einen Vorgang niemals, auch nicht nach einem Neustart.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'formular_lesen.dart';
import 'moodle_zugang.dart';

enum Schreibstatus { offen, bestaetigt, nichtGespeichert, rueckgelesen }

class Schreibstand {
  Schreibstand(this.vorher, this.nachher, this.status);
  final Map<String, String> vorher, nachher;
  final Schreibstatus status;
}

class Schreibvorgang {
  Schreibvorgang(this.moodle, this.ziel);
  final MoodleZugang moodle;
  final Formularziel ziel;
  String? _nummer;

  String get _objekt => schreibPruefsumme('${moodle.basis}|${ziel.adresse}');
  String get sperrpfad =>
      p.join(moodle.schreibvorgaengeOrdner, 'ziel-$_objekt.json');

  static bool _nummerGueltig(String s) => RegExp(r'^[a-f0-9]{64}$').hasMatch(s);

  String? get _aktuelleNummer {
    final f = File(sperrpfad);
    if (!f.existsSync()) return null;
    final j = _lesen(f);
    final nummer = j['id'];
    if (nummer is! String || !_nummerGueltig(nummer)) _beschaedigt();
    return nummer;
  }

  String get id =>
      _nummer ??
      _aktuelleNummer ??
      (throw StateError('Kein Schreibvorgang begonnen.'));
  File get _datei => File(p.join(moodle.schreibvorgaengeOrdner, '$id.json'));

  /// Lädt genau den genannten Vorgang, unabhängig von späteren Änderungen am Objekt.
  static Schreibvorgang laden(MoodleZugang moodle, String nummer) {
    if (!_nummerGueltig(nummer)) {
      throw MoodleFehler(
        'Ungültige Vorgangsnummer. Die Nummer aus der Fehlermeldung verwenden.',
      );
    }
    final j = _lesen(
      File(p.join(moodle.schreibvorgaengeOrdner, '$nummer.json')),
    );
    try {
      final v = Schreibvorgang(moodle, Formularziel.ausJson(j['ziel'] as Map))
        .._nummer = nummer;
      v.lesen();
      return v;
    } on TypeError {
      return _beschaedigt();
    } on ArgumentError {
      return _beschaedigt();
    }
  }

  static Never _beschaedigt() => throw MoodleFehler(
    'Schreibvorgang beschädigt. Nicht erneut schreiben; Ablage durch die Verwaltung prüfen lassen.',
  );

  static Map<String, dynamic> _lesen(File f) {
    if (!f.existsSync()) {
      throw MoodleFehler(
        'Schreibvorgang nicht gefunden. Nicht erneut schreiben.',
      );
    }
    try {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } on FormatException {
      return _beschaedigt();
    } on TypeError {
      return _beschaedigt();
    }
  }

  Schreibstand? lesen() {
    if (_nummer == null && _aktuelleNummer == null) return null;
    final j = _lesen(_datei);
    if (j['objekt'] != _objekt) {
      throw MoodleFehler(
        'Der Vorgang gehört zu einer anderen Instanz oder einem anderen Ziel. Nichts angefragt.',
      );
    }
    try {
      Map<String, String> pruefsummen(Object? roh) {
        final m = Map<String, String>.from(roh as Map);
        if (m.values.any((v) => !_nummerGueltig(v))) _beschaedigt();
        return m;
      }

      if (j['id'] != id) _beschaedigt();
      return Schreibstand(
        pruefsummen(j['vorher']),
        pruefsummen(j['nachher']),
        Schreibstatus.values.byName(j['status'] as String),
      );
    } on TypeError {
      return _beschaedigt();
    } on ArgumentError {
      return _beschaedigt();
    }
  }

  bool get offen => lesen()?.status == Schreibstatus.offen;
  String get hinweis =>
      'Ausgang unklar (verified: false). Vorgang $id. '
      'Nicht erneut schreiben. Mit aendern_status(vorgang: "$id") lesend prüfen; '
      'auch ein unveränderter Ausgangsstand erlaubt keine Wiederholung.';

  /// Wie lange ein abgeschlossener Vorgang abrufbar bleibt (Status nach Nummer).
  static const aufbewahrung = Duration(days: 30);

  /// Löscht abgeschlossene Vorgänge samt ihrer Objektsperre: die älter sind als
  /// [aelterAls], oder (mit [dieserInstanz]) alle der Instanz von [moodle], etwa beim
  /// Löschen ihres Profils. Offene Vorgänge bleiben immer: Sie sperren, bis jemand
  /// den Ausgang klärt. In den Dateien stehen Dateinamen und Prüfsummen von
  /// Einstellungen; sie sollen nicht länger liegen, als der Status sie braucht.
  static void abgeschlosseneLoeschen(
    MoodleZugang moodle, {
    Duration? aelterAls,
    bool dieserInstanz = false,
  }) {
    final ordner = Directory(moodle.schreibvorgaengeOrdner);
    if (!ordner.existsSync()) return;
    final basis = moodle.basis;
    final jetzt = DateTime.now();
    final weg = <String>{};
    try {
      for (final f in ordner.listSync(followLinks: false).whereType<File>()) {
        final name = p.basename(f.path);
        if (!RegExp(r'^[a-f0-9]{64}\.json$').hasMatch(name)) continue;
        try {
          final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
          if (j['status'] == Schreibstatus.offen.name) continue;
          final alt = aelterAls != null && jetzt.difference(f.lastModifiedSync()) >= aelterAls;
          final meine = dieserInstanz &&
              basis != null &&
              j['objekt'] == schreibPruefsumme('$basis|${Formularziel.ausJson(j['ziel'] as Map).adresse}');
          if (!alt && !meine) continue;
          f.deleteSync();
          weg.add(name.substring(0, 64));
        } on FormatException {
          continue; // Beschädigtes bleibt für die Verwaltung liegen.
        } on TypeError {
          continue;
        } on ArgumentError {
          continue;
        }
      }
      for (final f in ordner.listSync(followLinks: false).whereType<File>()) {
        if (!p.basename(f.path).startsWith('ziel-')) continue;
        try {
          final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
          if (weg.contains(j['id'])) f.deleteSync();
        } on FormatException {
          continue;
        } on TypeError {
          continue;
        }
      }
    } on FileSystemException {
      // Aufräumen ist nie Voraussetzung fürs Schreiben.
    }
  }

  void beginnen(Map<String, String> vorher, Map<String, String> nachher) {
    if (offen) throw MoodleFehler(hinweis);
    abgeschlosseneLoeschen(moodle, aelterAls: aufbewahrung);
    final zufall = Random.secure();
    _nummer = List.generate(
      32,
      (_) => zufall.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    // Erst der Datensatz, dann die Objektsperre, erst danach der POST. Ein
    // Abbruch zwischen den Dateien hat noch nichts nach Moodle gesendet.
    _speichern(_datei, {
      'id': id,
      'objekt': _objekt,
      'ziel': ziel.toJson(),
      'vorher': vorher,
      'nachher': nachher,
      'status': Schreibstatus.offen.name,
    });
    _speichern(File(sperrpfad), {'id': id});
  }

  void abschliessen() => _statusSetzen(Schreibstatus.bestaetigt);

  /// Nur bei einer ausdrücklichen Antwort, dass Moodle nicht gespeichert hat.
  void verwerfen() => _statusSetzen(Schreibstatus.nichtGespeichert);

  /// Moodle wurde nach dem Senden gelesen und weicht vom Ziel ab: Der Stand ist
  /// bekannt, der Vorgang sperrt nicht mehr.
  void rueckgelesen() => _statusSetzen(Schreibstatus.rueckgelesen);

  void _statusSetzen(Schreibstatus status) {
    final j = _lesen(_datei);
    _speichern(_datei, {...j, 'status': status.name});
  }

  static void _speichern(File datei, Map<String, Object?> j) {
    datei.parent.createSync(recursive: true);
    final temp = File('${datei.path}.tmp');
    temp.writeAsStringSync(jsonEncode(j), flush: true);
    temp.renameSync(datei.path);
  }
}

/// Entwurfsadressen ändern sich bei jedem Formularabruf, nicht der Inhalt.
String normalisiert(String html) => html.replaceAll(
  RegExp(r'/draftfile\.php/\d+/user/draft/\d+/'),
  '/draftfile.php/U/user/draft/X/',
);

String schreibPruefsumme(String text) =>
    sha256.convert(utf8.encode(text)).toString();

/// Vollständiger lesbarer Stand: Editorfelder, Einstellungen und Dateien.
/// Die Adressen des Entwurfsbereichs ändern sich bei jedem Formularabruf.
Map<String, String> schreibStand(String stand) {
  final result = <String, String>{};
  final d = Directory(stand);
  for (final f
      in d.listSync(recursive: true, followLinks: false).whereType<File>()) {
    final name = p.relative(f.path, from: stand).split(p.separator).join('/');
    if (!name.contains('/') &&
        name.endsWith('.html') &&
        name != 'formular.html') {
      result['text:$name'] = schreibPruefsumme(
        normalisiert(f.readAsStringSync()),
      );
    } else if (name.startsWith('dateien/') || name.startsWith('bereiche/')) {
      result['datei:$name'] = sha256.convert(f.readAsBytesSync()).toString();
    }
  }
  final einstellungen = File(p.join(stand, 'einstellungen.json'));
  for (final e in jsonDecode(einstellungen.readAsStringSync()) as List) {
    result['einstellung:${e['schluessel']}'] = schreibPruefsumme(
      '${e['auswahlwert'] ?? e['wert']}',
    );
  }
  return result;
}

bool schreibStandGleich(Map a, Map b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
