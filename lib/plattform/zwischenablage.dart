// HTML und Text zugleich in die Zwischenablage, für die Übergabe an die
// Lehrkraft (E34). Flutter selbst kennt nur Text; mit HTML fügt Strg+V in
// einem Editor wie dem von Moodle formatiert ein, der Text daneben dient
// Feldern, die nur Text nehmen.
//
// Abgelegt wird über `nativeapi`, die Grundlage des Fensterpakets
// (window_manager), in einem Zug: Die Bibliothek leert die Zwischenablage
// erst, wenn beide Formate vorbereitet sind, und legt dann beide ab.
// - Windows (cnativeapi, platform/windows/clipboard_windows.cpp,
//   Clipboard::Impl::Write): Text als CF_UNICODETEXT, HTML als „HTML Format"
//   (CF_HTML). Den Kopf mit den Stellen in Bytes von UTF-8 setzt die
//   Bibliothek selbst (Html()); hier geht deshalb nur das Fragment hinein,
//   nie ein schon fertiges CF_HTML -- es stünde sonst doppelt verpackt darin.
// - macOS (platform/macos/clipboard_macos.mm): ein Eintrag mit
//   NSPasteboardTypeString und NSPasteboardTypeHTML, wie ihn ein Browser
//   beim Kopieren ablegt.
// Andere Plattformen (zwischenablageMitHtml) bekommen nur den Text.
//
// Scheitert das Ablegen, bleibt es beim Text, ohne Absturz. Fehlertexte
// gibt es keine: nativeapi meldet nur, ob es ging (E11).

import 'package:flutter/services.dart' as flutter;
import 'package:nativeapi/nativeapi.dart' as nativ;

import 'plattform.dart';

/// Legt [text] und [html] zusammen ab; true, wenn es ging.
typedef HtmlAblegen = bool Function(String text, String html);

/// Legt nur [text] ab.
typedef TextAblegen = Future<void> Function(String text);

bool _nativAblegen(String text, String html) =>
    nativ.Clipboard.instance.write(nativ.ClipboardData(text: text, html: html));

Future<void> _textAblegen(String text) =>
    flutter.Clipboard.setData(flutter.ClipboardData(text: text));

/// Die Zwischenablage der App. Im Test mit eigenen [mitHtml], [html] und
/// [text] gebaut, damit die echte des Rechners unberührt bleibt.
class Zwischenablage {
  const Zwischenablage({
    this.mitHtml,
    this.html = _nativAblegen,
    this.text = _textAblegen,
    this.versuche = 10,
    this.pause = const Duration(milliseconds: 20),
  });

  /// Ob HTML mitgeht; ohne Angabe nach der Plattform (zwischenablageMitHtml).
  final bool? mitHtml;
  final HtmlAblegen html;
  final TextAblegen text;

  /// Hält ein anderes Programm die Zwischenablage gerade offen, scheitert
  /// das Ablegen; dann so oft mit kurzer Pause noch einmal.
  final int versuche;
  final Duration pause;

  /// Legt [fragment] als HTML und [quelltext] (ohne Angabe: [fragment]
  /// selbst) als Text ab. Gibt zurück, ob HTML dabei ist; bei `false` liegt
  /// nur der Text in der Zwischenablage.
  Future<bool> ablegen(String fragment, {String? quelltext}) async {
    final t = quelltext ?? fragment;
    if (mitHtml ?? zwischenablageMitHtml) {
      try {
        for (var i = 0; i < versuche; i++) {
          if (i > 0) await Future<void>.delayed(pause);
          if (html(t, fragment)) return true;
        }
      } on Object {
        // Absichtlich alles: Fehlt die native Bibliothek oder wirft sie, ist
        // das kein Grund für einen Absturz -- der Text geht trotzdem.
      }
    }
    await text(t);
    return false;
  }
}

/// Die Übergabe (FreigabeDialog): [html] als HTML und als Text, so dass der
/// Editor formatiert einfügt und ein Textfeld den Quelltext bekommt.
Future<bool> alsHtmlKopieren(String html) => const Zwischenablage().ablegen(html);
