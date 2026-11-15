// Die Zwischenablage der Übergabe (lib/plattform/zwischenablage.dart): was
// als Text und was als HTML abgelegt wird, und der Rückfall auf Text. Die
// echte Zwischenablage des Rechners bleibt unberührt -- jeder Test baut die
// Naht mit eigenen Ablagen.
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/plattform/zwischenablage.dart';

void main() {
  const fragment = '<p>Prüfung: „Größe" &amp; Maß</p><pre class="language-html"><code>&lt;b&gt;</code></pre>';

  late List<(String, String)> alsHtml;
  late List<String> alsText;
  Zwischenablage ablage({bool mitHtml = true, bool Function()? ergebnis, int versuche = 10}) =>
      Zwischenablage(
        mitHtml: mitHtml,
        html: (t, h) {
          alsHtml.add((t, h));
          return (ergebnis ?? () => true)();
        },
        text: (t) async => alsText.add(t),
        versuche: versuche,
        pause: Duration.zero,
      );

  setUp(() {
    alsHtml = [];
    alsText = [];
  });

  test('Das Fragment geht unverpackt als HTML, der Quelltext daneben als Text', () async {
    expect(await ablage().ablegen(fragment), isTrue);
    // Den CF_HTML-Kopf setzt nativeapi selbst; ein schon verpacktes
    // Fragment stünde doppelt darin.
    expect(alsHtml, [(fragment, fragment)]);
    expect(alsText, isEmpty, reason: 'beides in einem Zug, kein zweites Ablegen');
  });

  test('Ein eigener Text geht neben dem HTML', () async {
    expect(await ablage().ablegen(fragment, quelltext: 'nur Text'), isTrue);
    expect(alsHtml, [('nur Text', fragment)]);
  });

  test('Ohne HTML auf der Plattform nur der Quelltext als Text', () async {
    expect(await ablage(mitHtml: false).ablegen(fragment), isFalse);
    expect(alsHtml, isEmpty);
    expect(alsText, [fragment]);
  });

  test('Belegt: noch einmal versuchen, dann HTML', () async {
    var n = 0;
    expect(await ablage(ergebnis: () => ++n == 3).ablegen(fragment), isTrue);
    expect(alsHtml, hasLength(3));
    expect(alsText, isEmpty);
  });

  test('Scheitert es jedes Mal, bleibt der Text', () async {
    expect(await ablage(ergebnis: () => false, versuche: 4).ablegen(fragment), isFalse);
    expect(alsHtml, hasLength(4));
    expect(alsText, [fragment]);
  });

  test('Wirft die native Bibliothek, bleibt der Text, ohne erneuten Versuch und ohne Absturz', () async {
    expect(await ablage(ergebnis: () => throw ArgumentError('keine Bibliothek')).ablegen(fragment), isFalse);
    expect(alsHtml, hasLength(1));
    expect(alsText, [fragment]);
  });
}
