// E37: Die Sperre lebt außerhalb des Arbeitsordners. Gespeichert werden nur
// Prüfsummen, keine Inhalte oder Sitzungsschlüssel. Ein fehlender Nachweis
// beendet einen Vorgang niemals, auch nicht nach einem Neustart.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../protokoll.dart';
import 'formular_lesen.dart';
import 'moodle_zugang.dart';

/// [aufgehoben]: Die Lehrkraft hat die Sperre nach einem unklaren Ausgang in der
/// App selbst gelöst ([sperreAufheben]). Das heißt nicht „gespeichert" oder
/// „nicht gespeichert", sondern: Der nächste Vorgang beginnt mit frischem Lesen.
enum Schreibstatus { offen, bestaetigt, nichtGespeichert, aufgehoben }

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

  void beginnen(Map<String, String> vorher, Map<String, String> nachher) {
    if (offen) throw MoodleFehler(hinweis);
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

/// Eine offene Sperre: ein Objekt, an dem ein Schreibvorgang mit unklarem
/// Ausgang steht.
class OffeneSperre {
  OffeneSperre(this.vorgang, this.ziel);
  final String vorgang;

  /// Nur Pfad und Nummern des Objekts, nie ein Name (A1).
  final String ziel;
}

/// Die offenen Sperren dieser Instanz, für die Anzeige in der App (E37). Kein
/// MCP-Werkzeug ruft das auf.
List<OffeneSperre> offeneSperren(MoodleZugang moodle) {
  final ordner = Directory(moodle.schreibvorgaengeOrdner);
  if (!ordner.existsSync()) return const [];
  final aus = <OffeneSperre>[];
  for (final f in ordner.listSync().whereType<File>()) {
    if (!p.basename(f.path).startsWith('ziel-') || !f.path.endsWith('.json')) continue;
    try {
      final nummer = (jsonDecode(f.readAsStringSync()) as Map)['id'];
      if (nummer is! String || !Schreibvorgang._nummerGueltig(nummer)) continue;
      final v = Schreibvorgang.laden(moodle, nummer);
      if (v.offen) aus.add(OffeneSperre(nummer, v.ziel.adresse));
    } on MoodleFehler {
      continue; // Gehört zu einer anderen Instanz oder ist beschädigt: nicht anzeigen, nicht anfassen.
    } on FormatException {
      continue;
    }
  }
  return aus;
}

/// Löst die Sperre eines Vorgangs. Nur die App ruft das, auf einen Mausklick der
/// Lehrkraft (sperren_dialog.dart); über MCP ist es nicht erreichbar und nie auf
/// ein Ja im Chat. Der Vorgang bleibt als Nachweis liegen. Danach liest der
/// nächste Vorgang frisch.
void sperreAufheben(MoodleZugang moodle, String nummer) {
  final v = Schreibvorgang.laden(moodle, nummer);
  if (!v.offen) return;
  v._statusSetzen(Schreibstatus.aufgehoben);
  moodle.protokoll.eintrag(Art.schreiben, 'Sperre aufgehoben (Vorgang ${nummer.substring(0, 8)}), von der Lehrkraft in der App');
}
