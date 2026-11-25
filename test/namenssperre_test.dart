// Die Regel der Datenschutzprüfung gegen Namen (E36, lib/plugin/namenssperre.dart):
// Namensteile, ganze Wörter, kurze Namen, Groß- und Kleinschreibung, Umlaute
// und Akzente in beide Richtungen, Doppelnamen, Satzzeichen, Zeilenwechsel,
// Namen in JSON, HTML und Pfaden, einfach kodierte Namen (Unicode-Escapes,
// HTML-Zeichenreferenzen; keine Prozentkodierung), leere Eingaben und viele
// Namen. Alle Namen sind erfunden. Unsichtbare Zeichen stehen nur
// als Escape im Quelltext, nie wörtlich.
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/plugin/namenssperre.dart';

Namenssperre _sperre(List<String> namen) => Namenssperre()..hinzufuegen(namen);

/// Ein Unicode-Escape wie in JSON, als Text: Backslash, `u` und [hex]. So
/// zusammengesetzt, damit kein Werkzeug den Escape im Quelltext auflöst.
String _u(String hex) => '${r'\'}u$hex';

void main() {
  group('Namensteile', () {
    test('jeder Teil sperrt für sich, schon der Vorname allein', () {
      final s = _sperre(['Erika Mustermann']);
      expect(s.treffer('Erika hat abgegeben.'), 'Erika');
      expect(s.treffer('Abgabe von Mustermann fehlt'), 'Mustermann');
      expect(s.treffer('Erika Mustermann'), 'Erika');
      expect(s.treffer('Max Muster hat abgegeben.'), isNull);
    });

    test('ein Doppelname sperrt als Ganzes und in Teilen', () {
      final s = _sperre(['Lotte Müller-Lüdenscheidt']);
      expect(s.treffer('Frau Müller-Lüdenscheidt'), 'Müller');
      expect(s.treffer('nur Lüdenscheidt'), 'Lüdenscheidt');
      expect(s.treffer('Herr Müller'), 'Müller');
      expect(s.treffer('Lüdenscheid liegt im Sauerland'), isNull);
    });

    test('Komma, Apostroph, Punkt und Unterstrich trennen Teile', () {
      final s = _sperre(['Mustermann, Erika', "Sean O'Brien", 'J. Doe', 'max_muster']);
      expect(s.treffer('erika'), 'erika');
      expect(s.treffer('Brien'), 'Brien');
      expect(s.treffer('Muster war da'), 'Muster');
      expect(s.treffer('Doe'), 'Doe');
      expect(s.treffer('J'), 'J', reason: 'auch ein Teil aus einem Buchstaben sperrt');
    });

    test('leere Namen und reine Satzzeichen sperren nichts', () {
      final s = _sperre(['', '   ', '-', '...', "'"]);
      expect(s.leer, isTrue);
      expect(s.anzahl, 0);
      expect(s.treffer('- ... \' Text'), isNull);
      expect(Namenssperre.hatTeile(' - '), isFalse);
      expect(Namenssperre.hatTeile('Li'), isTrue);
    });

    test('gleiche Namen zählen einmal, auch anders geschrieben', () {
      final s = _sperre(['Erika Mustermann', 'erika  mustermann', 'ERIKA MUSTERMANN', 'Jürgen Muster', 'Juergen Muster']);
      expect(s.anzahl, 2);
    });
  });

  group('Ganze Wörter', () {
    test('kein Treffer mitten im Wort', () {
      final s = _sperre(['Max', 'Ina', 'Erika']);
      expect(s.treffer('Maximal 10 Punkte'), isNull);
      expect(s.treffer('Die Maxime gilt.'), isNull);
      expect(s.treffer('Eine Kinase'), isNull);
      expect(s.treffer('Erikas Heft'), isNull, reason: 'ein Name in einem längeren Wort ist nicht abgedeckt');
      expect(s.treffer('ErikaMustermann'), isNull);
    });

    test('falsche Treffer sind in Kauf genommen: „max.“ trifft Max', () {
      final s = _sperre(['Max']);
      expect(s.treffer('max. 10 Punkte'), 'max');
    });

    test('Satzzeichen, Klammern und Anführungszeichen um das Wort', () {
      final s = _sperre(['Erika']);
      for (final t in ['„Erika“', '(Erika)', 'Erika!', 'Erika?', '«Erika»', '-Erika-', 'Erika:', "'Erika'", '*Erika*']) {
        expect(s.treffer(t), 'Erika', reason: t);
      }
    });

    test('Zeilenwechsel und Tabulatoren trennen', () {
      final s = _sperre(['Erika Mustermann']);
      expect(s.treffer('Zeile eins\nMustermann\r\nZeile drei'), 'Mustermann');
      expect(s.treffer('a\tErika\tb'), 'Erika');
      expect(s.treffer('Zeile\u2028Erika'), 'Erika');
    });

    test('Ziffern gehören zum Wort', () {
      final s = _sperre(['Erika']);
      expect(s.treffer('Erika2'), isNull);
      expect(s.treffer('Erika 2'), 'Erika');
      final zahl = _sperre(['10']);
      expect(zahl.treffer('max. 10 Punkte'), '10');
      expect(zahl.treffer('100 Punkte'), isNull);
    });

    test('Wortgrenzen auch für Buchstaben außerhalb von ASCII', () {
      final s = _sperre(['Lea']);
      expect(s.treffer('Léa'), 'Léa');
      expect(s.treffer('Leaß'), isNull);
      expect(s.treffer('Ölea'), isNull);
      expect(s.treffer('Lea…'), 'Lea');
      expect(_sperre(['Ольга']).treffer('Привет, Ольга!'), 'Ольга');
      expect(_sperre(['Ольга']).treffer('Ольгаа'), isNull);
    });
  });

  group('Kurze Namen', () {
    test('ohne Mindestlänge: auch Li und Jo sperren', () {
      final s = _sperre(['Li', 'Jo']);
      expect(s.treffer('Gruppe von Li'), 'Li');
      expect(s.treffer('jo, passt'), 'jo');
      expect(s.treffer('Lineal'), isNull);
    });
  });

  group('Schreibweisen', () {
    test('Groß- und Kleinschreibung zählt nicht', () {
      final s = _sperre(['erika MUSTERMANN']);
      expect(s.treffer('ERIKA'), 'ERIKA');
      expect(s.treffer('Mustermann'), 'Mustermann');
      expect(s.treffer('mUsTeRmAnN'), 'mUsTeRmAnN');
    });

    test('Umlaute in beide Richtungen: ä = ae, ö = oe, ü = ue, ß = ss', () {
      expect(_sperre(['Jürgen Müller']).treffer('Juergen'), 'Juergen');
      expect(_sperre(['Jürgen Müller']).treffer('MUELLER'), 'MUELLER');
      expect(_sperre(['Juergen Mueller']).treffer('Jürgen'), 'Jürgen');
      expect(_sperre(['Juergen Mueller']).treffer('MÜLLER'), 'MÜLLER');
      expect(_sperre(['Jörg Bär']).treffer('Joerg Baer'), 'Joerg');
      expect(_sperre(['Joerg Baer']).treffer('Bär'), 'Bär');
      expect(_sperre(['Strauß']).treffer('Strauss'), 'Strauss');
      expect(_sperre(['Strauss']).treffer('Strauß'), 'Strauß');
      expect(_sperre(['Strauss']).treffer('STRAUẞ'), 'STRAUẞ');
    });

    test('Umlaute auch ohne e: Müller trifft Muller', () {
      expect(_sperre(['Müller']).treffer('Muller'), 'Muller');
      expect(_sperre(['Muller']).treffer('Müller'), 'Müller');
      expect(_sperre(['Gül']).treffer('Gul'), 'Gul');
      expect(_sperre(['Gül']).treffer('Guel'), 'Guel');
    });

    test('Akzente und andere diakritische Zeichen fallen weg', () {
      expect(_sperre(['René']).treffer('Rene'), 'Rene');
      expect(_sperre(['Rene']).treffer('RENÉ'), 'RENÉ');
      expect(_sperre(['François']).treffer('Francois'), 'Francois');
      expect(_sperre(['Łukasz Wójcik']).treffer('Lukasz'), 'Lukasz');
      expect(_sperre(['Ayşe Çelik']).treffer('Ayse Celik'), 'Ayse');
      expect(_sperre(['Øyvind']).treffer('Oyvind'), 'Oyvind');
      expect(_sperre(['Ștefan']).treffer('Stefan'), 'Stefan');
      expect(_sperre(['Zoë']).treffer('Zoe'), 'Zoe');
      expect(_sperre(['Ñuñez']).treffer('nunez'), 'nunez');
    });

    test('Unicode-Normalform: zerlegt (NFD) und zusammengesetzt (NFC) treffen sich', () {
      // „René“ mit e und kombinierendem Akut, „Müller“ mit u und
      // kombinierendem Trema.
      const reneZerlegt = 'Rene\u0301';
      const muellerZerlegt = 'Mu\u0308ller';
      expect(_sperre(['René']).treffer(reneZerlegt), reneZerlegt);
      expect(_sperre([reneZerlegt]).treffer('René'), 'René');
      expect(_sperre(['Müller']).treffer(muellerZerlegt), muellerZerlegt);
      expect(_sperre([muellerZerlegt]).treffer('Mueller'), 'Mueller');
      expect(_sperre([muellerZerlegt]).treffer('Muller'), 'Muller');
    });

    test('unsichtbare Formatzeichen im Wort trennen nicht', () {
      const weich = 'Eri\u00adka';
      const nullbreit = 'Mus\u200btermann';
      expect(_sperre(['Erika Mustermann']).treffer('Hallo $weich'), weich);
      expect(_sperre(['Erika Mustermann']).treffer(nullbreit), nullbreit);
      expect(_sperre(['Erika']).treffer('\u200b'), isNull);
    });
  });

  group('Namen in Formaten', () {
    final s = _sperre(['Erika Mustermann']);

    test('in JSON, HTML und Pfaden', () {
      expect(s.treffer('{"name":"Erika","punkte":3}'), 'Erika');
      expect(s.treffer('<p class="x">Abgabe: <b>Mustermann</b></p>'), 'Mustermann');
      expect(s.treffer('Erika&nbsp;Mustermann'), 'Erika');
      expect(s.treffer(r'C:\Users\lehrkraft\abgaben\mustermann_erika.pdf'), 'mustermann');
      expect(s.treffer('/pluginfile.php/12/mod_assign/Erika-Mustermann.pdf'), 'Erika');
      expect(s.treffer('https://moodle.schule.example/user/view.php?name=erika'), 'erika');
    });

    test('Prozentkodierung wird nicht aufgelöst, der Rest des Texts trifft weiter', () {
      expect(s.treffer('Erik%61'), isNull);
      expect(s.treffer('%45RIKA'), isNull);
      expect(s.treffer('name=Erika%20Mustermann'), 'Erika', reason: '„Erika“ steht als ganzes Wort davor');
      expect(_sperre(['Lotte Müller']).treffer('M%C3%BCller'), isNull);
      expect(s.treffer('100% von Erika%'), 'Erika');
    });

    test('Unicode-Escapes wie in JSON und JavaScript', () {
      expect(s.treffer('${_u('0045')}rika'), 'Erika');
      expect(s.treffer('Must${_u('0065')}rmann'), 'Mustermann');
      expect(_sperre(['Lotte Müller']).treffer('M${_u('00fc')}ller'), 'Müller');
      expect(_sperre(['Lotte Müller']).treffer('M${_u('00FC')}ller'), 'Müller');
      expect(s.treffer(r'\u{45}rika'), 'Erika');
      expect(s.treffer(r'\u{000045}rika'), 'Erika');
      // Ein Escape, das kein Zeichen ist, trennt; nichts wirft.
      expect(s.treffer('${_u('d800')}Erika'), 'Erika', reason: 'einzelnes Ersatzzeichen');
      expect(s.treffer(r'\u{110000}Erika'), 'Erika', reason: 'jenseits von Unicode');
      expect(s.treffer('${_u('00')} ${_u('{}')} ${_u('ZZZZ')}'), isNull);
      // Ein Ersatzpaar ergibt ein Zeichen (hier ein Smiley, kein Buchstabe).
      expect(s.treffer('${_u('d83d')}${_u('de00')}Erika'), 'Erika');
    });

    test('HTML-Zeichenreferenzen: dezimal, hexadezimal und benannt', () {
      expect(s.treffer('&#69;rika'), 'Erika');
      expect(s.treffer('&#x45;rika'), 'Erika');
      expect(s.treffer('&#X45;rika'), 'Erika');
      expect(s.treffer('&#69rika'), isNull, reason: 'ohne Semikolon keine Referenz');
      expect(_sperre(['Lotte Müller']).treffer('M&uuml;ller'), 'Müller');
      expect(_sperre(['Lotte Müller']).treffer('M&Uuml;LLER'), 'MÜLLER');
      expect(_sperre(['Gerd Strauß']).treffer('Strau&szlig;'), 'Strauß');
      expect(_sperre(['René Muster']).treffer('Ren&eacute;'), 'René');
      expect(_sperre(['Ana Muster']).treffer('A&ntilde;a'), 'Aña', reason: 'Akzente zählen nicht');
      expect(s.treffer('&#1114112;Erika &#xD800; &#;'), 'Erika', reason: 'ungültige Referenzen werfen nicht');
    });

    test('verschachtelt: Entität über Entität, bis zu einer festen Tiefe', () {
      expect(s.treffer('&amp;#69;rika'), 'Erika');
      expect(s.treffer('&amp;amp;#69;rika'), 'Erika');
      expect(s.treffer('&amp;amp;amp;amp;#69;rika'), isNull, reason: 'tiefer als die Grenze');
    });

    test('Base64 bleibt außen vor', () {
      expect(s.treffer('RXJpa2E='), isNull);
    });

    test('texteIn liefert jeden Schlüssel und Wert einzeln, auch mit Zeilenwechsel', () {
      final json = {
        'titel': 'Abgabe',
        'liste': [
          {'wer': 'Zeile\nMustermann', 3: 4.5},
        ],
        'Erika': null,
      };
      final texte = texteIn(json).toList();
      expect(texte, containsAll(['titel', 'Abgabe', 'Zeile\nMustermann', '3', '4.5', 'Erika']));
      expect(texte.map(s.treffer).whereType<String>(), ['Mustermann', 'Erika']);
    });
  });

  group('Leere Eingaben', () {
    test('ohne Namen und mit leerem Text: kein Treffer', () {
      expect(Namenssperre().treffer('Erika Mustermann'), isNull);
      expect(_sperre(['Erika']).treffer(''), isNull);
      expect(_sperre(['Erika']).treffer('   \n\t '), isNull);
    });
  });

  group('Laufzeit', () {
    test('viele Namen und ein langer Text bleiben schnell', () {
      // 20 000 erfundene Namen aus Silben, ein Text von gut 1 MB.
      const silben = ['ka', 'lo', 'mi', 'ne', 'ru', 'sa', 'ti', 'vo', 'ze', 'bu'];
      String wort(int i) => '${[for (var k = 0; k < 4; k++) silben[(i ~/ (k == 0 ? 1 : 10 * k)) % 10]].join()}x$i';
      final namen = [for (var i = 0; i < 20000; i++) '${wort(i)} ${wort(i + 7)}'];
      final s = Namenssperre();
      final uhr = Stopwatch()..start();
      s.hinzufuegen(namen);
      final text = List.filled(40000, 'Die Aufgabe hat zehn Punkte.').join(' ');
      expect(s.treffer(text), isNull);
      expect(s.treffer('$text ${wort(12345)}'), wort(12345));
      uhr.stop();
      expect(uhr.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}
