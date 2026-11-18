// E37: Die Sperre lebt außerhalb des Arbeitsordners. Gespeichert werden nur
// Prüfsummen, keine Inhalte oder Sitzungsschlüssel. Ein fehlender Nachweis
// beendet einen Vorgang niemals, auch nicht nach einem Neustart.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'formular_lesen.dart';
import 'moodle_zugang.dart';

class Schreibvorgang {
  Schreibvorgang(this.moodle, this.ziel);
  final MoodleZugang moodle;
  final Formularziel ziel;

  String get id =>
      sha256.convert(utf8.encode('${moodle.basis}|${ziel.adresse}')).toString();
  File get datei => File(p.join(moodle.schreibvorgaengeOrdner, '$id.json'));

  Map<String, dynamic>? lesen() {
    if (!datei.existsSync()) return null;
    try {
      final j = jsonDecode(datei.readAsStringSync()) as Map<String, dynamic>;
      if (j['id'] != id ||
          j['vorher'] is! Map ||
          j['nachher'] is! Map ||
          j['offen'] is! bool) {
        throw const FormatException();
      }
      return j;
    } catch (_) {
      throw MoodleFehler(
        'Schreibvorgang $id ist beschädigt. Nicht erneut schreiben; Ablage durch die Verwaltung prüfen lassen.',
      );
    }
  }

  bool get offen => lesen()?['offen'] == true;
  String get hinweis =>
      'Ausgang unklar (verified: false). Vorgang $id. '
      'Nicht erneut schreiben. Mit aendern_status(vorgang: "$id") lesend prüfen; '
      'auch ein unveränderter Ausgangsstand erlaubt keine Wiederholung.';

  void beginnen(Map<String, String> vorher, Map<String, String> nachher) {
    if (offen) throw MoodleFehler(hinweis);
    _speichern({
      'id': id,
      'ziel': ziel.toJson(),
      'vorher': vorher,
      'nachher': nachher,
      'offen': true,
    });
  }

  void abschliessen() {
    final j = lesen();
    if (j != null) _speichern({...j, 'offen': false});
  }

  /// Nur bei einer ausdrücklichen Antwort, dass Moodle nicht gespeichert hat.
  void verwerfen() => datei.deleteSync();

  void _speichern(Map<String, Object?> j) {
    datei.parent.createSync(recursive: true);
    final temp = File('${datei.path}.tmp');
    temp.writeAsStringSync(jsonEncode(j), flush: true);
    temp.renameSync(datei.path);
  }
}

String schreibPruefsumme(String text) =>
    sha256.convert(utf8.encode(text)).toString();

/// Vollständiger lesbarer Stand: Editorfelder, Einstellungen und Dateien.
/// Die Adressen des Entwurfsbereichs ändern sich bei jedem Formularabruf.
Map<String, String> schreibStand(String stand) {
  String normal(String s) => s.replaceAll(
    RegExp(r'/draftfile\.php/\d+/user/draft/\d+/'),
    '/draftfile.php/U/user/draft/X/',
  );
  final result = <String, String>{};
  final d = Directory(stand);
  for (final f
      in d.listSync(recursive: true, followLinks: false).whereType<File>()) {
    final name = p.relative(f.path, from: stand).split(p.separator).join('/');
    if (!name.contains('/') &&
        name.endsWith('.html') &&
        name != 'formular.html') {
      result['text:$name'] = schreibPruefsumme(normal(f.readAsStringSync()));
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
