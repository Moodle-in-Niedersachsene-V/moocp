// Die Prüfung hinter der Datenschutzwarnung (E36, lib/plugin/datenschutz.dart):
// Was sie als Treffer liefert (Wort, Herkunft, Umgebung), wie Namen und Pfade
// zusammenkommen, was nicht mehr geprüft wird (Prozentkodierung) und dass
// nichts Konkretes in einer Ausgabe der Klassen steht. Alle Namen sind
// erfunden. Die Regel für Wörter selbst steht in namenssperre_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/plugin/datenschutz.dart';

void main() {
  const pfad = r'C:\Temp\moocp_plugin_downloads';

  Datenschutzpruefung pruefung() => Datenschutzpruefung()
    ..namenHinzufuegen('a', ['Erika Mustermann'], herkunft: const Herkunft.teilnehmende(12))
    ..namenHinzufuegen('a', ['Lotte Lehrerin'], herkunft: Herkunft.lehrkraft)
    ..namenHinzufuegen('a', ['Paula Probe'])
    ..pfadSperren(pfad);

  group('Treffer', () {
    test('ohne Treffer kommt nichts zurück', () {
      expect(pruefung().pruefen('a', ['Aufgabe 3: max. nicht nötig.']), isEmpty);
      expect(pruefung().pruefen('a', const []), isEmpty);
      expect(pruefung().pruefen('a', ['']), isEmpty);
    });

    test('ein Name: Wort wie im Text, Herkunft und Umgebung', () {
      final f = pruefung().pruefen('a', ['Abgabe von ERIKA liegt vor.']).single;

      expect(f.wort, 'ERIKA');
      expect(f.pfad, isFalse);
      expect(f.herkunft, [const Herkunft.teilnehmende(12)]);
      expect(f.davor, 'Abgabe von ');
      expect(f.danach, ' liegt vor.');
      expect(f.davorGekuerzt, isFalse);
      expect(f.danachGekuerzt, isFalse);
    });

    test('die Umgebung reicht 80 Zeichen nach beiden Seiten und zeigt das Kürzen', () {
      final davor = 'a ' * 60;
      final danach = ' b' * 60;
      final f = pruefung().pruefen('a', ['${davor}Erika$danach']).single;

      expect(f.davor.length, 80);
      expect(f.danach.length, 80);
      expect(davor.endsWith(f.davor), isTrue);
      expect('Erika$danach'.startsWith('Erika${f.danach}'), isTrue);
      expect(f.davorGekuerzt, isTrue);
      expect(f.danachGekuerzt, isTrue);
    });

    test('Zeilenwechsel in der Umgebung werden zu Leerzeichen', () {
      final f = pruefung().pruefen('a', ['Zeile 1\n\nErika\r\nZeile 3']).single;
      expect(f.davor, 'Zeile 1 ');
      expect(f.danach, ' Zeile 3');
    });

    test('ein Ersatzzeichen-Paar wird an der Grenze der Umgebung nicht zerrissen', () {
      final f = pruefung().pruefen('a', ['${'\u{1F600}' * 60}Erika']).single;
      expect(f.davor.codeUnits.first & 0xFC00, isNot(0xDC00), reason: 'beginnt nicht mit einer halben Emoji');
    });

    test('mehrere Treffer, jeder mit eigener Umgebung; gleicher Treffer im selben Satz zählt einmal je Stelle', () {
      final funde = pruefung().pruefen('a', ['Erika und Lotte, später Erika mit Paula.']);
      expect([for (final f in funde) f.wort], ['Erika', 'Lotte', 'Erika', 'Paula']);
      expect(funde[1].herkunft, [Herkunft.lehrkraft]);
      expect(funde[3].herkunft, [Herkunft.pluginName]);
    });

    test('mehrere Texte einer Antwort: Treffer aus jedem', () {
      final funde = pruefung().pruefen('a', ['Titel', 'Erika', 'nichts', 'Lotte']);
      expect([for (final f in funde) f.wort], ['Erika', 'Lotte']);
    });

    test('ein Teil, der aus mehreren Quellen stammt, nennt alle', () {
      final p = Datenschutzpruefung()
        ..namenHinzufuegen('a', ['Erika Mustermann'], herkunft: const Herkunft.teilnehmende(12))
        ..namenHinzufuegen('a', ['Erika Beispiel']);
      final f = p.pruefen('a', ['Erika']).single;
      expect(f.herkunft.toSet(), {const Herkunft.teilnehmende(12), Herkunft.pluginName});
    });

    test('Namen eines Plugins gelten nur für dessen Texte', () {
      expect(pruefung().pruefen('b', ['Erika']), isEmpty);
    });

    test('Unicode-Escapes und HTML-Referenzen werden aufgelöst, das Wort steht aufgelöst da', () {
      final funde = pruefung().pruefen('a', [r'{"name":"\u0045rika"}', 'Must&#101;rmann']);
      expect([for (final f in funde) f.wort], ['Erika', 'Mustermann']);
    });

    test('Prozentkodierung wird nicht mehr aufgelöst', () {
      expect(pruefung().pruefen('a', ['Erik%61', '%45rika', 'q=Erika%20Muster']).map((f) => f.wort), ['Erika']);
      expect(pruefung().pruefen('a', ['Erik%61 und M%C3%BCller']), isEmpty);
    });

    test('derselbe Treffer in Rohform und aufgelöster Form erscheint einmal', () {
      final funde = pruefung().pruefen('a', [r'Erika \u0045rika']);
      expect(funde.map((f) => f.wort), ['Erika', 'Erika']);
    });
  });

  group('Pfade', () {
    test('der Ordner für Downloads trifft für jedes Plugin, in jeder Schreibweise, mit Umgebung', () {
      for (final t in [
        'Datei: $pfad\\beispiel\\1.pdf fertig',
        'Datei: ${pfad.toUpperCase().replaceAll(r'\', '/')}/beispiel/1.pdf fertig',
        'Datei: ${pfad.replaceAll(r'\', r'\\')}\\\\x fertig',
      ]) {
        final f = pruefung().pruefen('b', [t]).single;
        expect(f.pfad, isTrue, reason: t);
        expect(f.wort.toLowerCase().replaceAll(RegExp(r'[\\/]+'), '/'), 'c:/temp/moocp_plugin_downloads', reason: t);
        expect(f.herkunft, [Herkunft.downloadOrdner]);
        expect(f.davor, 'Datei: ');
        expect(f.danach, endsWith(' fertig'));
      }
    });

    test('ein ähnlicher Pfad trifft nicht, ein Laufwerk allein sperrt nichts', () {
      expect(pruefung().pruefen('b', [r'C:\Temp\moocp_arbeit']), isEmpty);
      final p = Datenschutzpruefung()..pfadSperren(r'C:\');
      expect(p.pruefen('b', [r'C:\irgendwo']), isEmpty);
    });

    test('ein vom Plugin gemeldeter Pfad trifft nur dessen Texte und kommt als eigene Herkunft', () {
      final p = Datenschutzpruefung()..pfadHinzufuegen('a', '/home/lehrerin/Klasse 9b/Abgaben');
      final f = p.pruefen('a', ['siehe /home/lehrerin/klasse 9b/abgaben/x.pdf']).single;
      expect(f.pfad, isTrue);
      expect(f.herkunft, [Herkunft.pluginPfad]);
      expect(p.pruefen('b', ['siehe /home/lehrerin/klasse 9b/abgaben/x.pdf']), isEmpty);
    });

    test('Namen und Pfade in einem Text: beide Arten, in der Reihenfolge des Texts', () {
      final funde = pruefung().pruefen('a', ['Erika liegt in $pfad\\x']);
      expect([for (final f in funde) (f.wort == 'Erika', f.pfad)], [(true, false), (false, true)]);
    });
  });

  group('Nichts Konkretes in Ausgaben', () {
    test('toString nennt weder Wort noch Umgebung noch Pfad', () {
      final funde = pruefung().pruefen('a', ['Erika in $pfad']);
      final warnung = Datenschutzwarnung(plugin: 'Beispiel', werkzeug: 'beispiel_x', funde: funde);
      for (final s in [funde.first.toString(), funde.last.toString(), warnung.toString(), pruefung().toString()]) {
        expect(s.toLowerCase(), isNot(contains('erika')));
        expect(s.toLowerCase(), isNot(contains('moocp_plugin')));
      }
    });
  });

  group('Datenschutzwarnung', () {
    test('zählt Treffer und unterscheidet Namen und Pfade', () {
      final w = Datenschutzwarnung(
        plugin: 'Beispiel',
        werkzeug: 'beispiel_x',
        funde: pruefung().pruefen('a', ['Erika Lotte $pfad']),
      );
      expect(w.anzahl, 3);
      expect(w.hatNamen, isTrue);
      expect(w.hatPfade, isTrue);
      final nur = Datenschutzwarnung(plugin: 'B', werkzeug: null, funde: pruefung().pruefen('a', ['Erika']));
      expect([nur.hatNamen, nur.hatPfade], [true, false]);
    });
  });
}
