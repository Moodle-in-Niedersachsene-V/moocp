// Die Beschreibungsdatei eines Plugins (plugin.json, E35): Sie wird gelesen,
// ohne Code des Plugins auszuführen. Eine Datei, die sich nicht lesen lässt
// oder eine Regel bricht, hält das Plugin vom Laden ab, mit einem Grund auf
// Deutsch -- der nie Inhalte aus der Datei nennt (E11).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/plugin/beschreibung.dart';

Map<String, Object?> _vollstaendig() => {
      'name': 'Beispiel-Plugin',
      'kurzname': 'beispiel',
      'version': '1.2.3',
      'schnittstelle': 1,
      'programm': 'bin/beispiel.exe',
      'herkunft': 'Beispiel-Projekt',
      'updateQuellen': ['beispiel-verein/beispiel-plugin', 'beispiel/beispiel-plugin'],
      'zusatzadressen': [
        {'muster': '/mod/beispiel/*', 'art': 'lesen', 'grund': 'Liest die Seiten der Aktivität.'},
        {'muster': '/mod/beispiel/save.php', 'art': 'schreiben', 'grund': 'Speichert die Einstellungen.'},
      ],
      'wahlSkills': {'beispiel-skill': 'Ein wählbarer Skill.'},
      'entwicklungsPort': 47900,
    };

Map<String, Object?> _minimal() => {
      'name': 'Beispiel',
      'kurzname': 'beispiel',
      'version': '1',
      'schnittstelle': 1,
      'programm': 'beispiel.exe',
      'herkunft': 'Beispiel-Projekt',
    };

/// Der Grund, aus dem [j] abgewiesen wird; null, wenn die Datei gültig ist.
String? _grund(Map<String, Object?> j) {
  try {
    PluginBeschreibung.ausJson(j);
    return null;
  } on PluginFehler catch (e) {
    return e.grund;
  }
}

Map<String, Object?> _mit(Map<String, Object?> j, String feld, Object? wert) => {...j, feld: wert};

Map<String, Object?> _ohne(Map<String, Object?> j, String feld) => {...j}..remove(feld);

void main() {
  group('Lesen', () {
    test('alle Felder der Schnittstelle 1 werden verstanden', () {
      final b = PluginBeschreibung.ausJson(_vollstaendig());
      expect(b.name, 'Beispiel-Plugin');
      expect(b.kurzname, 'beispiel');
      expect(b.version, '1.2.3');
      expect(b.schnittstelle, 1);
      expect(b.programm, 'bin/beispiel.exe');
      expect(b.herkunft, 'Beispiel-Projekt');
      expect(b.updateQuellen, ['beispiel-verein/beispiel-plugin', 'beispiel/beispiel-plugin']);
      expect(b.zusatzadressen, hasLength(2));
      expect(b.zusatzadressen[0].muster.text, '/mod/beispiel/*');
      expect(b.zusatzadressen[0].art, ZugriffsArt.lesen);
      expect(b.zusatzadressen[0].grund, 'Liest die Seiten der Aktivität.');
      expect(b.zusatzadressen[1].art, ZugriffsArt.schreiben);
      expect(b.wahlSkills, {'beispiel-skill': 'Ein wählbarer Skill.'});
      expect(b.entwicklungsPort, 47900);
    });

    test('ohne die freiwilligen Felder gelten leere Listen und kein Entwicklungsport', () {
      final b = PluginBeschreibung.ausJson(_minimal());
      expect(b.updateQuellen, isEmpty);
      expect(b.zusatzadressen, isEmpty);
      expect(b.wahlSkills, isEmpty);
      expect(b.skills, isEmpty);
      expect(b.entwicklungsPort, isNull);
    });

    test('Text mit Byte-Order-Mark, wie ihn Editoren unter Windows schreiben, wird gelesen', () {
      final b = PluginBeschreibung.ausText('\uFEFF${jsonEncode(_minimal())}');
      expect(b.kurzname, 'beispiel');
    });

    test('unbekannte Felder werden überlesen, auch eine höhere Schnittstellenversion', () {
      final b = PluginBeschreibung.ausJson({..._minimal(), 'schnittstelle': 7, 'irgendwas': true});
      expect(b.schnittstelle, 7, reason: 'ob die App sie bietet, prüft ein späterer Schritt');
    });

    test('Text, der kein JSON ist, und JSON, das kein Objekt ist, werden abgewiesen, ohne den Inhalt zu nennen', () {
      for (final text in ['das ist geheim', '[1, 2]', '"geheim"', '']) {
        try {
          PluginBeschreibung.ausText(text);
          fail('hätte abweisen müssen: $text');
        } on PluginFehler catch (e) {
          expect(e.grund, isNotEmpty);
          expect(e.grund, isNot(contains('geheim')));
        }
      }
    });
  });

  group('Pflichtfelder', () {
    for (final feld in ['name', 'kurzname', 'version', 'schnittstelle', 'programm', 'herkunft']) {
      test('„$feld" fehlt: abgewiesen, der Grund nennt das Feld', () {
        expect(_grund(_ohne(_minimal(), feld)), contains('„$feld“'));
      });
    }

    test('ein Text, der leer ist oder nur aus Leerzeichen besteht, zählt als fehlend', () {
      for (final feld in ['name', 'version', 'herkunft']) {
        expect(_grund(_mit(_minimal(), feld, '   ')), contains('„$feld“'), reason: feld);
        expect(_grund(_mit(_minimal(), feld, '')), contains('„$feld“'), reason: feld);
      }
    });

    test('ein Feld vom falschen Typ wird abgewiesen', () {
      expect(_grund(_mit(_minimal(), 'name', 5)), contains('„name“'));
      expect(_grund(_mit(_minimal(), 'schnittstelle', '1')), contains('„schnittstelle“'));
      expect(_grund(_mit(_minimal(), 'schnittstelle', 1.5)), contains('„schnittstelle“'));
    });

    test('Steuerzeichen in Texten werden abgewiesen: Sie könnten Zeilen im Protokoll fälschen', () {
      for (final feld in ['name', 'version', 'herkunft']) {
        expect(_grund(_mit(_minimal(), feld, 'Zeile 1\nZeile 2')), contains('Steuerzeichen'), reason: feld);
      }
    });

    // Umbruch-, Richtungs- und Nullbreitenzeichen: unsichtbar im Dialog der
    // Zustimmung, aber geeignet, dort Text umzustellen oder vorzutäuschen.
    final unsichtbar = <String, int>{
      'Wagenrücklauf': 0x0D,
      'NEL': 0x85,
      'Zeilentrenner': 0x2028,
      'Absatztrenner': 0x2029,
      'Links-rechts-Marke': 0x200E,
      'Rechts-links-Marke': 0x200F,
      'Rechts-links-Einbettung': 0x202B,
      'Richtungsüberschreibung': 0x202E,
      'Richtungsisolierung': 0x2066,
      'Ende der Isolierung': 0x2069,
      'Nullbreitenleerzeichen': 0x200B,
      'Nullbreitenverbinder': 0x200D,
      'Wortverbinder': 0x2060,
      'BOM im Text': 0xFEFF,
    };

    test('Umbruch-, Richtungs- und Nullbreitenzeichen in den angezeigten Texten werden abgewiesen', () {
      unsichtbar.forEach((art, c) {
        final z = 'Bei${String.fromCharCode(c)}spiel';
        for (final feld in ['name', 'version', 'herkunft']) {
          final g = _grund(_mit(_minimal(), feld, z));
          expect(g, contains('„$feld“'), reason: '$art in $feld');
          expect(g, isNot(contains('Bei')), reason: 'der Grund nennt keine Inhalte');
        }
        final adresse = {'muster': '/mod/beispiel/*', 'art': 'lesen', 'grund': z};
        expect(_grund(_mit(_minimal(), 'zusatzadressen', [adresse])), contains('„grund“'), reason: art);
        expect(_grund(_mit(_minimal(), 'wahlSkills', {'beispiel-x': z})), contains('„wahlSkills“'), reason: art);
      });
    });

    test('Höchstlängen: Name 60, Version 30, Herkunft 100, Grund und Skill-Beschreibung je 300 Zeichen', () {
      const grenzen = {'name': 60, 'version': 30, 'herkunft': 100};
      grenzen.forEach((feld, n) {
        expect(_grund(_mit(_minimal(), feld, 'x' * n)), isNull, reason: feld);
        final g = _grund(_mit(_minimal(), feld, 'x' * (n + 1)));
        expect(g, contains('„$feld“'), reason: feld);
        expect(g, contains('$n'), reason: feld);
      });
      Map<String, Object?> mitGrund(String grund) =>
          _mit(_minimal(), 'zusatzadressen', [{'muster': '/mod/beispiel/*', 'art': 'lesen', 'grund': grund}]);
      expect(_grund(mitGrund('x' * 300)), isNull);
      expect(_grund(mitGrund('x' * 301)), allOf(contains('Zusatzadresse 1'), contains('„grund“'), contains('300')));
      expect(_grund(_mit(_minimal(), 'wahlSkills', {'beispiel-x': 'x' * 300})), isNull);
      expect(_grund(_mit(_minimal(), 'wahlSkills', {'beispiel-x': 'x' * 301})), allOf(contains('„wahlSkills“'), contains('300')));
    });

    test('die Schnittstellenversion ist eine ganze Zahl ab 1', () {
      expect(_grund(_mit(_minimal(), 'schnittstelle', 1)), isNull);
      expect(_grund(_mit(_minimal(), 'schnittstelle', 0)), contains('„schnittstelle“'));
      expect(_grund(_mit(_minimal(), 'schnittstelle', -1)), contains('„schnittstelle“'));
    });
  });

  group('Kurzname', () {
    test('Kleinbuchstaben und Ziffern, mit einem Buchstaben am Anfang, höchstens zwölf Zeichen', () {
      for (final k in ['a', 'beispiel', 'abc123', 'abcdefghijkl']) {
        expect(_grund(_mit(_minimal(), 'kurzname', k)), isNull, reason: k);
      }
      expect(kurznameHoechstens, 12);
    });

    test('zu lang: Der Werkzeugname passte nicht mehr in die 64 Zeichen von Claude Code', () {
      final grund = _grund(_mit(_minimal(), 'kurzname', 'abcdefghijklm'));
      expect(grund, contains('12'));
      expect(grund, contains('64'));
    });

    test('Großbuchstaben, Ziffer am Anfang, Bindestrich, Unterstrich, Leerzeichen und Umlaute sind ungültig', () {
      for (final k in ['Beispiel', '1abc', 'ab-c', 'ab_c', 'ab c', 'bäume', '']) {
        expect(_grund(_mit(_minimal(), 'kurzname', k)), isNotNull, reason: k);
      }
    });

    test('der Grund nennt den Kurznamen nicht', () {
      expect(_grund(_mit(_minimal(), 'kurzname', 'Geheim!')), isNot(contains('Geheim')));
    });
  });

  group('Programm', () {
    test('ein relativer Pfad innerhalb des Plugin-Ordners', () {
      for (final p in ['beispiel.exe', 'bin/beispiel.exe', r'bin\beispiel.exe', './beispiel.exe', 'a/./b.exe']) {
        expect(_grund(_mit(_minimal(), 'programm', p)), isNull, reason: p);
      }
    });

    test('absolut, mit Laufwerk, mit „..", ein Ordner oder leer: abgewiesen', () {
      for (final p in [
        '/usr/bin/beispiel',
        r'\beispiel.exe',
        r'C:\beispiel.exe',
        'C:beispiel.exe',
        '../beispiel.exe',
        'bin/../../beispiel.exe',
        r'bin\..\..\beispiel.exe',
        'bin/',
        '.',
        '',
        'beispiel.exe:strom',
        'bei\u0000spiel.exe',
      ]) {
        expect(_grund(_mit(_minimal(), 'programm', p)), contains('„programm“'), reason: p);
      }
    });
  });

  group('Update-Quellen', () {
    test('nur GitHub-Repositorys der Form Besitzer/Name', () {
      expect(_grund(_mit(_minimal(), 'updateQuellen', ['verein/projekt'])), isNull);
      for (final q in ['https://github.com/verein/projekt', 'projekt', 'a/b/c', 'verein/../x', 'a/b?x', '']) {
        expect(_grund(_mit(_minimal(), 'updateQuellen', [q])), contains('„updateQuellen“'), reason: q);
      }
    });

    test('keine Liste oder ein Eintrag, der kein Text ist', () {
      expect(_grund(_mit(_minimal(), 'updateQuellen', 'verein/projekt')), contains('„updateQuellen“'));
      expect(_grund(_mit(_minimal(), 'updateQuellen', [1])), contains('„updateQuellen“'));
    });
  });

  group('Zusatzadressen', () {
    Map<String, Object?> mit(Map<String, Object?> adresse) => _mit(_minimal(), 'zusatzadressen', [adresse]);
    final gut = {'muster': '/mod/beispiel/*', 'art': 'lesen', 'grund': 'Liest die Seiten.'};

    test('Art „lesen" und „schreiben"', () {
      expect(_grund(mit(gut)), isNull);
      expect(_grund(mit({...gut, 'art': 'schreiben'})), isNull);
    });

    test('jede Angabe ist Pflicht, und die Art ist eine von beiden', () {
      for (final feld in ['muster', 'art', 'grund']) {
        final g = _grund(mit({...gut}..remove(feld)));
        expect(g, contains('Zusatzadresse 1'), reason: feld);
        expect(g, contains('„$feld“'), reason: feld);
      }
      expect(_grund(mit({...gut, 'art': 'löschen'})), contains('„art“'));
      expect(_grund(mit({...gut, 'art': 'Lesen'})), contains('„art“'));
      expect(_grund(mit({...gut, 'grund': ' '})), contains('„grund“'));
    });

    test('ein ungültiges Muster nennt den Grund und die Nummer der Zusatzadresse', () {
      final g = _grund(_mit(_minimal(), 'zusatzadressen', [
        gut,
        {...gut, 'muster': '/mod/x?geheim=1'},
      ]));
      expect(g, contains('Zusatzadresse 2'));
      expect(g, contains('Parameter'));
      expect(g, isNot(contains('geheim')));
    });

    test('ein Muster in einem gesperrten Bereich hält das Plugin vom Laden ab und nennt den Bereich', () {
      final erwartet = {
        '/admin/*': 'Adminbereich',
        '/login/index.php': 'Anmeldung',
        '/auth/*': 'Anmeldeverfahren',
        '/webservice/*': 'Web-Services',
        '/user/managetoken.php': 'Seite für Zugangsschlüssel',
        '/*': 'Adminbereich',
        '/a*': 'Adminbereich',
        '/*/x.php': 'Adminbereich',
        '/login*': 'Anmeldung',
      };
      erwartet.forEach((muster, bereich) {
        final g = _grund(mit({...gut, 'muster': muster}));
        expect(g, contains(bereich), reason: muster);
        expect(g, contains('Zusatzadresse 1'), reason: muster);
        expect(g, isNot(contains(muster)), reason: 'der Grund nennt das Muster nicht, nur die Nummer');
      });
    });

    test('harmlose Muster gehen durch', () {
      for (final muster in ['/mod/beispiel/view.php', '/pluginfile.php/*']) {
        expect(_grund(mit({...gut, 'muster': muster})), isNull, reason: muster);
      }
    });

    test('keine Liste oder ein Eintrag, der kein Objekt ist', () {
      expect(_grund(_mit(_minimal(), 'zusatzadressen', {'muster': '/x'})), contains('„zusatzadressen“'));
      expect(_grund(_mit(_minimal(), 'zusatzadressen', ['/mod/x'])), contains('Zusatzadresse 1'));
    });
  });

  group('Skills, Entwicklungsport', () {
    test('wählbare Skills: Name und Beschreibung, beide Text', () {
      expect(_grund(_mit(_minimal(), 'wahlSkills', {'a': 'b'})), isNull);
      expect(_grund(_mit(_minimal(), 'wahlSkills', ['a'])), contains('„wahlSkills“'));
      expect(_grund(_mit(_minimal(), 'wahlSkills', {'a': 1})), contains('„wahlSkills“'));
      expect(_grund(_mit(_minimal(), 'wahlSkills', {'a': ''})), contains('„wahlSkills“'));
    });

    test('Skills, die immer dabei sind: eine Liste von Namen, ohne Doppel und nicht zugleich wählbar', () {
      expect(_grund(_mit(_minimal(), 'skills', ['beispiel', 'beispiel-mehr'])), isNull);
      expect(PluginBeschreibung.ausJson(_mit(_minimal(), 'skills', ['beispiel'])).skills, ['beispiel']);
      expect(PluginBeschreibung.ausJson(_minimal()).skills, isEmpty);
      expect(_grund(_mit(_minimal(), 'skills', 'beispiel')), contains('„skills“'));
      expect(_grund(_mit(_minimal(), 'skills', [1])), contains('„skills“'));
      expect(_grund(_mit(_minimal(), 'skills', [''])), contains('„skills“'));
      expect(_grund(_mit(_minimal(), 'skills', ['a${String.fromCharCode(10)}b'])), contains('„skills“'));
      expect(_grund(_mit(_minimal(), 'skills', ['beispiel', 'beispiel'])), contains('zweimal'));
      final beides = _mit(_mit(_minimal(), 'skills', ['beispiel-x']), 'wahlSkills', {'beispiel-x': 'Text'});
      final grund = _grund(beides);
      expect(grund, contains('„wahlSkills“'));
      expect(grund, isNot(contains('beispiel-x')), reason: 'der Grund nennt keine Inhalte');
    });

    test('Entwicklungsport: eine Portnummer', () {
      for (final port in [1, 47900, 65535]) {
        expect(_grund(_mit(_minimal(), 'entwicklungsPort', port)), isNull, reason: '$port');
      }
      for (final port in [0, -5, 65536, '47900', 1.5]) {
        expect(_grund(_mit(_minimal(), 'entwicklungsPort', port)), contains('„entwicklungsPort“'), reason: '$port');
      }
    });
  });
}
