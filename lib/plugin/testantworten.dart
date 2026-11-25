// Vorbereitete Antworten auf Dialoge eines Plugins im Testbetrieb (E35):
// Damit läuft ein Ende-zu-Ende-Test mit einem Plugin ohne Klicks. Nur im
// Debug-Bau mit dem Bauschalter des Testbetriebs und nur für ein gebundenes
// Testprofil: Den Pfad der Datei nennt der MCP-Dienst des Profils
// (AufrufKontext.testDialogantworten, mcp/testbetrieb.dart), sonst gibt es
// keinen, und jeder Dialog erscheint.
//
// Die Datei heißt `plugin-dialoge.json` und liegt neben der Zugangsdatei des
// Testprofils. Form:
//
//   {"antworten": [
//     {"plugin": "beispiel", "art": "auswahl", "titel": "Kurs wählen",
//      "antwort": {"gewaehlt": [0]}},
//     {"plugin": "beispiel", "art": "eingabe", "titel": "Link",
//      "antwort": {"text": "https://moodle.schule.example/mod/page/view.php?id=7"}},
//     {"plugin": "beispiel", "art": "hinweis", "titel": "Fertig", "antwort": {}},
//     {"plugin": "beispiel", "art": "pfad", "titel": "Ordner", "antwort": null}
//   ]}
//
// Eine Antwort passt zu einem Dialog über den Kurznamen des Plugins, die Art
// (`auswahl`, `eingabe`, `pfad`, `hinweis`, wie im Pfad der Adresse der App)
// und den Titel, so wie der Dialog ihn zeigt (einzeilig, gekürzt). Eine
// eigene Kennung des Dialogs gibt es nicht: Die Schnittstelle bleibt, wie sie
// ist, und ein Plugin muss für den Testbetrieb nichts anders machen. Es gilt
// die erste passende Antwort, bei jedem Dialog neu aus der Datei gelesen.
// `antwort` hat die Felder, die der Dialog sonst an das Plugin gibt;
// `null` heißt abgebrochen. Sie durchläuft dieselbe Prüfung wie eine Eingabe
// der Lehrkraft (PluginDialog.antwortPruefen): Auswahl nur aus den
// angebotenen Einträgen, ein Pfad muss bestehen, ein Link ein Link sein.
//
// Ohne passende Antwort erscheint der Dialog wie sonst. Ist die Datei kein
// gültiges JSON in dieser Form, oder passt die gefundene Antwort nicht zum
// Dialog, erscheint er ebenfalls, und das Protokoll nennt den Grund, nie
// einen Wert aus der Datei (A4).
//
// Nur die Dialoge, die ein Plugin über die Adresse der App zeigen lässt,
// lassen sich so beantworten. Die Zustimmung zu einem Plugin, der Dialog
// eines Entwicklungs-Plugins, die Dialoge zu Schnittstelle und Update eines
// Plugins und die Freigaben lesen diese Datei nie. Die Datenschutzwarnung (E36)
// beantwortet mit ihr nur der MCP-Dienst, über einen eigenen Eintrag der Art
// `datenschutz` (mcp/testbetrieb.dart, datenschutzAntwort); diesen Dialogen
// gilt er nicht.

import 'dart:convert';
import 'dart:io';

import 'dialoge.dart';
import 'klartext.dart';

/// Größer ist eine Datei mit vorbereiteten Antworten nicht; was größer ist,
/// gilt als ungültig.
const testantwortenHoechstens = 1024 * 1024;

/// Was die Datei für einen Dialog vorsieht.
sealed class Testantwort {
  const Testantwort();
}

/// Eine passende, geprüfte Antwort; [antwort] null heißt abgebrochen.
final class TestantwortGegeben extends Testantwort {
  const TestantwortGegeben(this.antwort);
  final Map<String, Object?>? antwort;
}

/// Die Datei ist ungültig, oder die passende Antwort hielte der Prüfung der
/// Oberfläche nicht stand: Der Dialog erscheint. [grund] ist ein fester Satz
/// ohne Werte aus der Datei.
final class TestantwortUngueltig extends Testantwort {
  const TestantwortUngueltig(this.grund);
  final String grund;
}

/// Der Name der Art in der Datei, wie im Pfad der Adresse der App.
String testantwortArt(PluginDialogArt art) => switch (art) {
  PluginDialogArt.auswahl => 'auswahl',
  PluginDialogArt.eingabe => 'eingabe',
  PluginDialogArt.pfad => 'pfad',
  PluginDialogArt.hinweis => 'hinweis',
};

/// Sucht in [datei] die Antwort auf [dialog] des Plugins [kurzname]. Null,
/// wenn es die Datei nicht gibt oder keine Antwort passt.
Testantwort? testantwortSuchen(String datei, String kurzname, PluginDialog dialog) {
  final f = File(datei);
  final List<Object?> antworten;
  try {
    if (!f.existsSync()) return null;
    if (f.lengthSync() > testantwortenHoechstens) {
      return const TestantwortUngueltig('Die Datei mit vorbereiteten Dialogantworten ist zu groß');
    }
    final json = jsonDecode(f.readAsStringSync());
    if (json is! Map || json['antworten'] is! List) throw const FormatException();
    antworten = json['antworten'] as List;
  } on FileSystemException {
    return const TestantwortUngueltig('Die Datei mit vorbereiteten Dialogantworten ist nicht lesbar');
  } on FormatException {
    return const TestantwortUngueltig('Die Datei mit vorbereiteten Dialogantworten ist kein gültiges JSON der erwarteten Form');
  }
  final art = testantwortArt(dialog.art);
  for (final e in antworten) {
    if (e is! Map ||
        e['plugin'] is! String ||
        e['art'] is! String ||
        e['titel'] is! String ||
        !e.containsKey('antwort') ||
        (e['antwort'] != null && e['antwort'] is! Map)) {
      return const TestantwortUngueltig('Ein Eintrag der Datei mit vorbereiteten Dialogantworten ist ungültig');
    }
    if (e['plugin'] != kurzname || e['art'] != art || einzeilig(e['titel'] as String, dialogTitelHoechstens) != dialog.titel) {
      continue;
    }
    final roh = e['antwort'] as Map?;
    if (roh == null) return const TestantwortGegeben(null);
    final geprueft = dialog.antwortPruefen(roh.cast<String, Object?>());
    return geprueft == null
        ? const TestantwortUngueltig('Die vorbereitete Antwort hält der Prüfung des Dialogs nicht stand')
        : TestantwortGegeben(geprueft);
  }
  return null;
}
