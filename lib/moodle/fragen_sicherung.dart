// Die XML-Sicherung vor dem Löschen von Fragen (E9, E20): jede Frage als
// Moodle-XML ihrer aktuellen Version, zusammen in einer Datei in einem
// dauerhaften Ordner außerhalb des Arbeitsordners (E5, E29).
//
// Gesichert wird nur die aktuelle Version je Frage: Ältere Versionen kennt die
// App nicht (der Verlauf der Frage ist gesperrt, A1). Wiederherstellen heißt:
// die Datei mit fragen_importieren in eine Kategorie einspielen. Die Datei
// enthält, was Moodles Export ausliefert (Autorenangaben gehören nicht dazu;
// nachgemessen in fragen.dart).

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'fragen_xml.dart';
import 'moodle_zugang.dart';

/// Obergrenze der Sicherungsdatei, wie für jede Datei dieser Art (E29).
const sicherungGrenzeBytes = 200 * 1024 * 1024;

/// Führt die Exporte einzelner Fragen zu einem `<quiz>` zusammen; die
/// Kommentare `<!-- question: id -->` bleiben erhalten, weil an ihnen die
/// questionid hängt.
String xmlZusammenfuehren(List<String> xmls) {
  final b = XmlBuilder();
  b.processing('xml', 'version="1.0" encoding="UTF-8"');
  final knoten = <XmlNode>[];
  for (final x in xmls) {
    for (final n in XmlDocument.parse(x).rootElement.children) {
      if (n is XmlElement || n is XmlComment) knoten.add(n.copy());
    }
  }
  b.element('quiz', nest: () {
    for (final n in knoten) {
      b.xml(n.toXmlString());
    }
  });
  return b.buildDocument().toXmlString();
}

/// Schreibt die Sicherung und liest sie zurück: Die Datei muss da und
/// nicht leer sein, sich lesen lassen und jede Frage enthalten. Gibt ihren
/// Pfad zurück; scheitert etwas, wird die Datei entfernt und
/// [MoodleFehler] geworfen -- dann wird nichts gelöscht.
Future<String> fragenSichern(String ordner, int sammlung, List<({int id, String xml})> fragen,
    {DateTime? jetzt}) async {
  try {
    final xml = xmlZusammenfuehren([for (final f in fragen) f.xml]);
    final bytes = utf8.encode(xml);
    if (bytes.length > sicherungGrenzeBytes) {
      throw MoodleFehler('Die Sicherung wäre größer als ${sicherungGrenzeBytes ~/ (1024 * 1024)} MB.');
    }
    await Directory(ordner).create(recursive: true);
    final t = jetzt ?? DateTime.now();
    String z(int n) => n.toString().padLeft(2, '0');
    final stempel = '${t.year}${z(t.month)}${z(t.day)}-${z(t.hour)}${z(t.minute)}${z(t.second)}';
    var datei = File(p.join(ordner, 'geloescht-$stempel-sammlung$sammlung.xml'));
    for (var i = 2; datei.existsSync(); i++) {
      datei = File(p.join(ordner, 'geloescht-$stempel-sammlung$sammlung-$i.xml'));
    }
    await datei.writeAsBytes(bytes, flush: true);
    try {
      final zurueck = await datei.readAsString(encoding: utf8);
      final ids = {for (final f in fragenAusXml(zurueck)) f.id};
      final fehlt = [for (final f in fragen) if (!ids.contains(f.id)) f.id];
      if (zurueck.isEmpty || fehlt.isNotEmpty) {
        throw MoodleFehler('Die Sicherung enthält nicht alle Fragen (fehlt: ${fehlt.join(', ')}).');
      }
    } catch (_) {
      if (datei.existsSync()) datei.deleteSync();
      rethrow;
    }
    return datei.path;
  } on MoodleFehler catch (e) {
    throw MoodleFehler('Abgebrochen, nichts gelöscht: Die Sicherung vor dem Löschen ist gescheitert (${e.meldung}).');
  } on FileSystemException catch (e) {
    throw MoodleFehler('Abgebrochen, nichts gelöscht: Die Sicherung vor dem Löschen ist gescheitert '
        '(${e.osError?.message ?? e.message}, ${p.basename(e.path ?? ordner)}).');
  } on XmlException {
    throw MoodleFehler('Abgebrochen, nichts gelöscht: Die Sicherung vor dem Löschen ist gescheitert '
        '(Moodles Export ist kein lesbares XML).');
  }
}
