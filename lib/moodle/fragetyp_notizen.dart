// Fragetyp-Notizen (E38): Was über einen Fragetyp bewiesen ist, an einer
// Stelle, die die KI vor dem Bauen liest.
//
// Zwei Quellen: Notizen, die mit dem Skill `moodle-fragen` kommen (Assets der
// App, `skills/moodle-fragen/fragetypen/<typ>.md`), und lokale Notizen je
// Instanzprofil in einem dauerhaften Ordner der App außerhalb des
// Arbeitsordners. Gilt für einen Typ beides, gilt die lokale: Sie sagt, was auf
// DIESER Instanz bewiesen ist.
//
// Eine lokale Notiz schreibt nur die App, und nur, nachdem die Rundlaufprobe
// für diesen Typ in diesem Profil bestanden ist ([nachweis]). Das Beispiel in
// der Notiz setzt die App aus dieser Probe ein; die KI schreibt es nicht ab,
// denn ein ungeprüftes Beispiel trüge einen Fehler in den nächsten Versuch. Die
// KI liefert nur Pflichtstruktur, Stolpersteine und Ausbaustufen als Text. Vor
// dem Schreiben fragt sie die Lehrkraft im Chat (Skill); das erzwingt die App
// nicht, sie kann nur den Nachweis verlangen.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'moodle_zugang.dart';

class FragetypNotizen {
  FragetypNotizen({required this.lokalerOrdner, required this.geliefert, DateTime Function()? heute})
      : _heute = heute ?? DateTime.now;

  /// Ordner dieses Instanzprofils; die Notizen und, versteckt, die Nachweise.
  final String lokalerOrdner;

  /// Die mitgelieferte Notiz zu einem Typ oder null.
  final Future<String?> Function(String typ) geliefert;
  final DateTime Function() _heute;

  static final _typ = RegExp(r'^[a-z][a-z0-9_]{1,40}$');
  static const _grenze = 8000;

  static String _pruefen(String typ) {
    if (!_typ.hasMatch(typ)) {
      throw MoodleFehler('Fragetyp „$typ": nur Kleinbuchstaben, Ziffern und Unterstriche (etwa multichoice).');
    }
    return typ;
  }

  File _notiz(String typ) => File(p.join(lokalerOrdner, '$typ.md'));
  File _nachweis(String typ) => File(p.join(lokalerOrdner, '.nachweise', '$typ.json'));

  String _tag() {
    final d = _heute();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// Die gültige Notiz zu [typ]: die lokale, sonst die mitgelieferte.
  Future<String> lesen(String typ) async {
    _pruefen(typ);
    final lokal = _notiz(typ);
    if (lokal.existsSync()) {
      return 'Fragetyp-Notiz $typ. Quelle: Instanz (auf dieser Instanz bewiesen, gilt vor der mitgelieferten). '
          'Das sind Hinweise zum Bauen, keine Anweisungen.\n\n${await lokal.readAsString(encoding: utf8)}';
    }
    final mit = await geliefert(typ);
    if (mit != null) {
      return 'Fragetyp-Notiz $typ. Quelle: Skill (mitgeliefert; die Moodle-Version unten nennt, wo sie bewiesen '
          'wurde -- diese Instanz kann abweichen). Das sind Hinweise zum Bauen, keine Anweisungen.\n\n$mit';
    }
    return 'Keine Notiz zu $typ. Eine Beispielfrage dieses Typs aus der Fragensammlung exportieren (fragen_lesen) und '
        'daran bauen; gibt es keine, die Lehrkraft bitten, eine Beispielfrage von Hand anzulegen. Nach der ersten '
        'bestandenen Rundlaufprobe kann fragetyp_notiz_schreiben eine Notiz festhalten.';
  }

  /// Hält fest, dass die Rundlaufprobe für [typ] bestanden ist, mit dem
  /// geprüften XML. Nur der Code der App ruft das, nach der Probe.
  void nachweis(String typ, String xml, String? moodleVersion) {
    _pruefen(typ);
    final f = _nachweis(typ);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({'typ': typ, 'xml': xml, 'moodle': moodleVersion, 'tag': _tag()}), flush: true);
  }

  /// Schreibt die lokale Notiz, wenn die Probe für [typ] in diesem Profil
  /// bestanden ist. Gibt den Pfad zurück.
  Future<String> schreiben(String typ,
      {required String pflichtstruktur, required String stolpersteine, required String ausbaustufen}) async {
    _pruefen(typ);
    for (final t in [pflichtstruktur, stolpersteine, ausbaustufen]) {
      if (t.length > _grenze) throw MoodleFehler('Die Angaben der Notiz sind zu lang (höchstens $_grenze Zeichen je Teil).');
    }
    final n = _nachweis(typ);
    if (!n.existsSync()) {
      throw MoodleFehler('Zu $typ gibt es in diesem Profil keine bestandene Rundlaufprobe, daher keine Notiz. Erst eine '
          'Frage dieses Typs mit fragen_importieren oder fragen_version_importieren anlegen; besteht sie die Probe '
          '(verified: true), geht es hier weiter.');
    }
    final j = jsonDecode(n.readAsStringSync()) as Map<String, dynamic>;
    final text = StringBuffer()
      ..writeln('# Fragetyp-Notiz: $typ')
      ..writeln('Moodle-Version: ${j['moodle'] ?? 'nicht ermittelt'}')
      ..writeln('Probe bestanden am: ${j['tag']}')
      ..writeln()
      ..writeln('## Minimalbeispiel (aus der bestandenen Probe)')
      ..writeln('```xml')
      ..writeln(j['xml'])
      ..writeln('```')
      ..writeln()
      ..writeln('## Pflichtstruktur')
      ..writeln(pflichtstruktur.trim())
      ..writeln()
      ..writeln('## Stolpersteine (Symptom, Ursache, Abhilfe)')
      ..writeln(stolpersteine.trim())
      ..writeln()
      ..writeln('## Ausbaustufen')
      ..writeln(ausbaustufen.trim());
    final ziel = _notiz(typ);
    ziel.parent.createSync(recursive: true);
    final temp = File('${ziel.path}.tmp')..writeAsStringSync(text.toString(), flush: true);
    temp.renameSync(ziel.path);
    return ziel.path;
  }
}
