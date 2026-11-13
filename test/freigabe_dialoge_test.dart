import 'dart:async';
import 'dart:convert';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/main.dart'
    show
        FreigabeDialog,
        FreigabeDialoge,
        PluginDialogAnzeige,
        PluginDialogFenster,
        SperrHinweisAnzeige,
        Sperrzeit;
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/mcp/werkzeugquelle.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/plugin/adressmuster.dart';
import 'package:moocp/plugin/beschreibung.dart';
import 'package:moocp/plugin/dialoge.dart';
import 'package:moocp/plugin/moodle_schreiben.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

FreigabeAnfrage _anfrage(String titel) =>
    FreigabeAnfrage(titel: titel, punkte: const [], vergleich: const []);

Widget _fenster(Freigaben freigaben) => MaterialApp(
  home: FreigabeDialoge(
    freigaben: freigaben,
    nachVorn: (_) async {},
    child: const Scaffold(body: Text('Hauptfenster')),
  ),
);

/// Das Fenster der App mit den Dialogen der Plugins.
Widget _pluginFenster(PluginDialoge dialoge) => MaterialApp(
  home: PluginDialogAnzeige(
    dialoge: dialoge,
    nachVorn: () async {},
    child: const Scaffold(body: Text('Hauptfenster')),
  ),
);

PluginDialog _pluginDialog(PluginDialogArt art, Map<String, Object?> json) =>
    PluginDialog.ausJson(art, 'Plugin „Beispiel“', json);

/// Ob der Knopf mit [text] gerade etwas annimmt.
bool _knopfFrei(WidgetTester tester, String text) =>
    tester
        .widget<ButtonStyleButton>(find.ancestor(of: find.text(text), matching: find.bySubtype<ButtonStyleButton>()))
        .onPressed !=
    null;

void main() {
  for (final ja in [true, false]) {
    testWidgets(
      'fachliche Kandidatenentscheidung bei keine: ${ja ? 'bestätigen' : 'ablehnen'}',
      (tester) async {
        final freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
        await tester.pumpWidget(_fenster(freigaben));
        final antwort = freigaben.anfragen(
          FreigabeAnfrage(
            titel: 'Lernlandkarte ändern?',
            punkte: const [
              'Ort p1: ZZ Quelle → ZZ Vertiefung (cmid 72)',
              'Begründung der KI (Vorschlag): Gleicher Lerngegenstand.',
            ],
            vergleich: const [],
            ab: Bestaetigungen.keine,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('ZZ Vertiefung'), findsOneWidget);
        expect(find.textContaining('Gleicher Lerngegenstand'), findsOneWidget);
        await tester.pump(Sperrzeit.dauerVorgabe);
        await tester.tap(find.text(ja ? 'Speichern' : 'Abbrechen'));
        await tester.pumpAndSettle();
        expect(await antwort, ja);
        expect(freigaben.ausgelassen, 0);
      },
    );
  }

  // Ruft ein Plugin ein eingebautes Werkzeug auf (E35), sieht die Lehrkraft
  // im Dialog, dass nicht die KI direkt fragt.
  for (final plugin in [true, false]) {
    testWidgets('der Dialog nennt ${plugin ? 'das Plugin als Aufrufer' : 'keinen Aufrufer, wenn die KI direkt fragt'}',
        (tester) async {
      final freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.mittel);
      await tester.pumpWidget(_fenster(freigaben));
      final antwort = Freigaben.mitAbbruch(
        Completer<void>().future,
        () => freigaben.anfragen(_anfrage('Änderung speichern?')),
        aufrufer: plugin ? 'Plugin „Beispiel“' : null,
      );
      await tester.pumpAndSettle();
      expect(find.text('Änderung speichern?'), findsOneWidget);
      expect(
        find.text('Aufgerufen vom Plugin „Beispiel“, nicht direkt von der KI'),
        plugin ? findsOneWidget : findsNothing,
      );
      expect(find.textContaining('Aufgerufen vom'), plugin ? findsOneWidget : findsNothing);
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(await antwort, isFalse);
    });
  }

  testWidgets('Bild außerhalb des erneut geprüften Testumfangs braucht persönliche Freigabe', (tester) async {
    final freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
    await tester.pumpWidget(_fenster(freigaben));
    final anfrage = FreigabeAnfrage(titel: 'ZZ Bild?', punkte: const [], vergleich: const [],
      ab: Bestaetigungen.keine,
      bilder: [base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')]);
    final antwort = freigaben.imTest(() => freigaben.anfragen(anfrage), pruefen: () async => false);
    await tester.pumpAndSettle();
    expect(find.text('ZZ Bild?'), findsOneWidget);
    await tester.pump(Sperrzeit.dauerVorgabe);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(await antwort, isFalse);
    expect(freigaben.testfreigaben, 0);
  });

  for (final fall in ['Zustimmung', 'Ablehnung', 'Fristablauf', 'Abbruch']) {
    testWidgets('realer Dialog: $fall beendet die Anfrage korrekt', (
      tester,
    ) async {
      final freigaben = Freigaben(
        Protokoll(),
        frist: const Duration(seconds: 3),
      );
      await tester.pumpWidget(_fenster(freigaben));
      final abbruch = Completer<void>();
      final antwort = Freigaben.mitAbbruch(
        abbruch.future,
        () => freigaben.anfragen(_anfrage('ZZ Änderung?')),
      );
      await tester.pumpAndSettle();
      expect(find.text('ZZ Änderung?'), findsOneWidget);
      switch (fall) {
        case 'Zustimmung':
          await tester.pump(Sperrzeit.dauerVorgabe);
          await tester.tap(find.text('Speichern'));
        case 'Ablehnung':
          await tester.pump(Sperrzeit.dauerVorgabe);
          await tester.tap(find.text('Abbrechen'));
        case 'Fristablauf':
          await tester.pump(const Duration(seconds: 3));
        case 'Abbruch':
          abbruch.complete();
      }
      await tester.pumpAndSettle();
      expect(await antwort, fall == 'Zustimmung');
      expect(find.text('ZZ Änderung?'), findsNothing);
      expect(freigaben.aktuell, isNull);
      expect(freigaben.testfreigaben, 0);
    });
  }

  testWidgets(
    'wechselt den Listener bei Profilwechsel auch mit offenem Dialog',
    (tester) async {
      final alt = Freigaben(Protokoll());
      final neu = Freigaben(Protokoll());
      await tester.pumpWidget(_fenster(alt));
      alt.anfragen(_anfrage('Altes Profil'));
      await tester.pumpAndSettle();
      expect(find.text('Altes Profil'), findsOneWidget);

      await tester.pumpWidget(_fenster(neu));
      await tester.pumpAndSettle();
      expect(find.text('Altes Profil'), findsNothing);
      alt.entscheiden(false);
      neu.anfragen(_anfrage('Neues Profil'));
      await tester.pumpAndSettle();

      expect(find.text('Neues Profil'), findsOneWidget);
      neu.entscheiden(false);
    },
  );

  group('Freigabe vor dem Löschen eines Kurses: Liste mit Links, Hervorhebung, Bestätigung', () {
    const knopf = 'Löschen und wiederherstellen';
    const bestaetigung =
        'Ich habe die Liste geprüft. Alle Inhalte des Kurses „ZZ Kurs" werden gelöscht, '
        'auch Abgaben, Beiträge und Bewertungen der Lernenden.';
    final forum = Uri.parse('https://moodle.schule.example/mod/forum/view.php?id=6');
    final seite = Uri.parse('https://moodle.schule.example/mod/page/view.php?id=5');

    FreigabeAnfrage loeschen({List<String> abhaken = const [bestaetigung]}) => FreigabeAnfrage(
      titel: 'Vorhandene Inhalte löschen und wiederherstellen?',
      punkte: const ['Profil: Test', 'Kurs 12 „ZZ Kurs" (bestehender Kurs)'],
      vergleich: const [],
      knopf: knopf,
      abhaken: abhaken,
      links: [
        FreigabeLinkGruppe(
          'Zuerst ansehen (1): kann Daten von Lernenden enthalten oder wird von moocp nicht unterstützt',
          [FreigabeLink('„ZZ Forum" (Forum)', forum, warnung: 'kann Daten von Lernenden enthalten')],
          warnung: true,
        ),
        FreigabeLinkGruppe('Weitere Aktivitäten, die gelöscht werden (1)', [FreigabeLink('„ZZ Seite" (Textseite)', seite)]),
      ],
      ab: Bestaetigungen.keine,
    );

    testWidgets('der Knopf geht erst nach dem Haken; Links öffnen im Browser und ersetzen den Haken nicht', (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
      final antwort = f.anfragen(loeschen());
      expect(f.aktuell, isNotNull, reason: 'Löschen fragt auch bei „keine"');
      final geoeffnet = <Uri>[];
      for (final skala in [1.0, 1.25]) {
        await tester.pumpWidget(MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(skala)),
              child: Scaffold(body: FreigabeDialog(f.aktuell!, f, browser: (u) async => geoeffnet.add(u))),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'kein Überlauf bei ${(skala * 100).round()} %');
      }
      await tester.pump(Sperrzeit.dauerVorgabe);
      bool frei() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, knopf)).onPressed != null;

      // Keine Übergabe: kein orangenes Band, keine nummerierten Schritte.
      expect(find.textContaining('Jetzt sind Sie dran'), findsNothing);
      expect(find.text(bestaetigung), findsOneWidget);
      expect(frei(), isFalse, reason: 'noch nichts bestätigt');

      // Die Warngruppe steht oben, mit Warnzeichen; die übrigen darunter.
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      final warnung = tester.getTopLeft(find.textContaining('Zuerst ansehen')).dy;
      final rest = tester.getTopLeft(find.textContaining('Weitere Aktivitäten')).dy;
      expect(warnung, lessThan(rest));
      expect(find.textContaining('kann Daten von Lernenden enthalten', findRichText: true), findsWidgets);

      // Ein Link öffnet die Aktivität im Browser; das ersetzt die Bestätigung nicht.
      await tester.tap(find.textContaining('„ZZ Forum" (Forum)', findRichText: true));
      await tester.tap(find.textContaining('„ZZ Seite" (Textseite)', findRichText: true));
      expect(geoeffnet, [forum, seite]);
      expect(frei(), isFalse);

      // Haken setzen, zurücknehmen, wieder setzen.
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(frei(), isTrue);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(frei(), isFalse, reason: 'ein zurückgenommener Haken sperrt den Knopf wieder');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(frei(), isTrue);
      f.entscheiden(true);
      expect(await antwort, isTrue);
    });

    testWidgets('im echten Dialog der App: Knopf gesperrt, dann Haken, dann Klick gibt frei', (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
      await tester.pumpWidget(_fenster(freigaben));
      final antwort = freigaben.anfragen(loeschen());
      await tester.pumpAndSettle();
      expect(find.text('Vorhandene Inhalte löschen und wiederherstellen?'), findsOneWidget);
      await tester.pump(Sperrzeit.dauerVorgabe);
      // Gesperrt: ein Klick tut nichts.
      await tester.tap(find.text(knopf));
      await tester.pumpAndSettle();
      expect(freigaben.aktuell, isNotNull);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text(knopf));
      await tester.pumpAndSettle();
      expect(await antwort, isTrue);
      expect(freigaben.aktuell, isNull);
    });

    testWidgets('Ablehnen geht ohne Haken', (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
      await tester.pumpWidget(_fenster(freigaben));
      final antwort = freigaben.anfragen(loeschen());
      await tester.pumpAndSettle();
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(await antwort, isFalse);
    });

    testWidgets('mit mehreren Aktivitäten scrollt die Liste für sich; die Bestätigung bleibt sichtbar', (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
      final antwort = f.anfragen(FreigabeAnfrage(
        titel: 'Vorhandene Inhalte löschen und wiederherstellen?',
        punkte: const ['Profil: Test'],
        vergleich: const [],
        knopf: knopf,
        abhaken: const [bestaetigung],
        links: [
          FreigabeLinkGruppe('Weitere Aktivitäten, die gelöscht werden (80)', [
            for (var i = 1; i <= 80; i++)
              FreigabeLink('„ZZ Seite $i" (Textseite)', Uri.parse('https://moodle.schule.example/mod/page/view.php?id=$i')),
          ]),
        ],
        ab: Bestaetigungen.keine,
      ));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: FreigabeDialog(f.aktuell!, f))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(bestaetigung), findsOneWidget, reason: 'sichtbar, ohne zu scrollen');
      expect(find.text(knopf), findsOneWidget);
      f.entscheiden(false);
      expect(await antwort, isFalse);
    });

    testWidgets('ohne abhaken ist der Knopf bei Links nach der Sperrzeit frei', (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = Freigaben(Protokoll());
      final antwort = f.anfragen(loeschen(abhaken: const []));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: FreigabeDialog(f.aktuell!, f))));
      await tester.pump(Sperrzeit.dauerVorgabe);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, knopf)).onPressed, isNotNull);
      f.entscheiden(true);
      expect(await antwort, isTrue);
    });
  });

  group('Dialoge eines Plugins', () {
    late PluginDialoge dialoge;
    setUp(() => dialoge = PluginDialoge());

    /// Zeigt [d] im Fenster der App; liefert die Antwort und das Ende des
    /// Aufrufs, zu dem er gehört.
    Future<({Future<Map<String, Object?>?> antwort, Completer<void> ende})> zeigen(
      WidgetTester tester,
      PluginDialog d,
    ) async {
      await tester.pumpWidget(_pluginFenster(dialoge));
      final ende = Completer<void>();
      final antwort = dialoge.zeigen(d, ende: ende.future);
      await tester.pumpAndSettle();
      return (antwort: antwort, ende: ende);
    }

    testWidgets('Auswahl, einfach: das Plugin oben als Absender, das Suchfeld filtert, ein Haken, die Nummer zurück', (tester) async {
      final z = await zeigen(
        tester,
        _pluginDialog(PluginDialogArt.auswahl, {
          'titel': 'Farbe wählen',
          'eintraege': ['Rot', 'Grün', 'Blau', 'Grau'],
        }),
      );

      expect(find.text('Absender: Plugin „Beispiel“'), findsOneWidget);
      expect(find.text('Farbe wählen'), findsOneWidget);
      expect(find.text('Rot'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'gr');
      await tester.pump();
      expect(find.text('Rot'), findsNothing);
      expect(find.text('Blau'), findsNothing);
      expect(find.text('Grün'), findsOneWidget);
      expect(find.text('Grau'), findsOneWidget);

      await tester.tap(find.text('Grün'));
      await tester.tap(find.text('Grau'));
      await tester.pump();
      expect(_knopfFrei(tester, 'Übernehmen'), isFalse, reason: 'Sperrzeit');
      await tester.pump(Sperrzeit.dauerVorgabe);
      expect(_knopfFrei(tester, 'Übernehmen'), isTrue);
      await tester.tap(find.text('Übernehmen'));
      await tester.pumpAndSettle();

      expect(await z.antwort, {
        'gewaehlt': [3],
      }, reason: 'einfach: der zweite Haken ersetzt den ersten');
      expect(find.text('Farbe wählen'), findsNothing);
      expect(dialoge.aktuell, isNull);
    });

    testWidgets('Auswahl, mehrfach: mehrere Haken, auch über die Suche hinweg; ohne Haken geht Übernehmen nicht', (tester) async {
      final z = await zeigen(
        tester,
        _pluginDialog(PluginDialogArt.auswahl, {
          'titel': 'Farben wählen',
          'eintraege': ['Rot', 'Grün', 'Blau'],
          'mehrfach': true,
        }),
      );
      await tester.pump(Sperrzeit.dauerVorgabe);
      expect(_knopfFrei(tester, 'Übernehmen'), isFalse);

      await tester.tap(find.text('Blau'));
      await tester.enterText(find.byType(TextField), 'rot');
      await tester.pump();
      await tester.tap(find.text('Rot'));
      await tester.pump();
      expect(find.text('Mehrere wählbar, 2 gewählt'), findsOneWidget);
      await tester.tap(find.text('Übernehmen'));
      await tester.pumpAndSettle();

      expect(await z.antwort, {
        'gewaehlt': [0, 2],
      });
    });

    testWidgets('Text des Plugins erscheint roh: kein Markdown, kein HTML, kein Link', (tester) async {
      const roh = 'Siehe **fett** und <b>dick</b>, [Link](https://moodle.schule.example)\nzweite Zeile';
      final z = await zeigen(tester, _pluginDialog(PluginDialogArt.hinweis, {'titel': '# Kein Titel', 'text': roh}));

      expect(find.text(roh), findsOneWidget);
      expect(find.text('# Kein Titel'), findsOneWidget);
      expect(
        find.ancestor(of: find.text(roh), matching: find.byType(InkWell)),
        findsNothing,
        reason: 'nichts im Text ist anklickbar',
      );
      dialoge.beantworten(dialoge.aktuell!, null);
      await tester.pumpAndSettle();
      expect(await z.antwort, isNull);
    });

    testWidgets('Hinweis: nur „OK“, die Antwort ist leer; Return, Leertaste und Tabulator entscheiden nichts', (tester) async {
      final z = await zeigen(tester, _pluginDialog(PluginDialogArt.hinweis, {'titel': 'Fertig', 'text': 'Erledigt.'}));
      expect(find.text('Abbrechen'), findsNothing);
      await tester.pump(Sperrzeit.dauerVorgabe);

      for (final taste in [
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.enter,
      ]) {
        await tester.sendKeyEvent(taste);
        await tester.pumpAndSettle();
      }
      expect(find.text('Fertig'), findsOneWidget);
      expect(dialoge.aktuell?.offen, isTrue);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(await z.antwort, <String, Object?>{});
    });

    testWidgets('Eingabe: Text mit Vorgabe; Abbrechen liefert abgebrochen', (tester) async {
      var z = await zeigen(tester, _pluginDialog(PluginDialogArt.eingabe, {'titel': 'Name', 'vorgabe': 'ZZ'}));
      expect(find.text('ZZ'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '  ZZ Probe  ');
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Übernehmen'));
      await tester.pumpAndSettle();
      expect(await z.antwort, {'text': 'ZZ Probe'});

      z = await zeigen(tester, _pluginDialog(PluginDialogArt.eingabe, {'titel': 'Name'}));
      await tester.pump(Sperrzeit.dauerVorgabe);
      expect(_knopfFrei(tester, 'Übernehmen'), isFalse, reason: 'leer');
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(await z.antwort, isNull);
    });

    testWidgets('Eingabe eines Links: erst eine Adresse mit http oder https gilt', (tester) async {
      final z = await zeigen(tester, _pluginDialog(PluginDialogArt.eingabe, {'titel': 'Link', 'art': 'link'}));
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.enterText(find.byType(TextField), 'moodle.schule.example');
      await tester.pump();
      expect(_knopfFrei(tester, 'Übernehmen'), isFalse);
      expect(find.text('Ein Link beginnt mit https:// oder http://.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'https://moodle.schule.example/course/view.php?id=12');
      await tester.pump();
      await tester.tap(find.text('Übernehmen'));
      await tester.pumpAndSettle();
      expect(await z.antwort, {'text': 'https://moodle.schule.example/course/view.php?id=12'});
    });

    group('Wahl eines Ordners oder einer Datei', () {
      late Directory start;
      setUp(() {
        start = Directory.systemTemp.createTempSync('moocp_pfadwahl_');
        Directory(p.join(start.path, 'Unterordner')).createSync();
        File(p.join(start.path, 'a.txt')).writeAsStringSync('a');
      });
      tearDown(() => start.deleteSync(recursive: true));

      testWidgets('Ordner: beginnt im Startordner, ein Klick öffnet den Unterordner, Übernehmen nennt ihn', (tester) async {
        final z = await zeigen(
          tester,
          _pluginDialog(PluginDialogArt.pfad, {'titel': 'Ordner wählen', 'art': 'ordner', 'start': start.path}),
        );
        expect(find.text('Unterordner'), findsOneWidget);
        expect(find.text('a.txt'), findsNothing, reason: 'bei der Ordnerwahl keine Dateien');

        await tester.tap(find.text('Unterordner'));
        await tester.pump(Sperrzeit.dauerVorgabe);
        await tester.tap(find.text('Übernehmen'));
        await tester.pumpAndSettle();

        expect(await z.antwort, {'pfad': p.join(start.path, 'Unterordner')});
      });

      testWidgets('Datei: ein Klick wählt sie; ein Pfad, den es nicht gibt, gilt nicht', (tester) async {
        final z = await zeigen(
          tester,
          _pluginDialog(PluginDialogArt.pfad, {'titel': 'Datei wählen', 'art': 'datei', 'start': start.path}),
        );
        await tester.pump(Sperrzeit.dauerVorgabe);
        expect(_knopfFrei(tester, 'Übernehmen'), isFalse);
        await tester.enterText(find.byType(TextField), p.join(start.path, 'fehlt.txt'));
        await tester.pump();
        expect(_knopfFrei(tester, 'Übernehmen'), isFalse);
        expect(find.text('Diese Datei gibt es nicht.'), findsOneWidget);

        await tester.tap(find.text('a.txt'));
        await tester.pump();
        await tester.tap(find.text('Übernehmen'));
        await tester.pumpAndSettle();

        expect(await z.antwort, {'pfad': p.join(start.path, 'a.txt')});
      });

      testWidgets('ohne Startordner im Benutzerordner', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PluginDialogFenster(
                _pluginDialog(PluginDialogArt.pfad, {'titel': 'Ordner wählen', 'art': 'ordner'}),
                umgebung: {'USERPROFILE': start.path, 'HOME': start.path},
              ),
            ),
          ),
        );
        expect(find.text('Unterordner'), findsOneWidget);
        expect(find.widgetWithText(TextField, p.normalize(start.path)), findsOneWidget);
      });
    });

    testWidgets('endet der Aufruf oder läuft die Frist ab, schließt sich der Dialog: abgebrochen', (tester) async {
      var z = await zeigen(tester, _pluginDialog(PluginDialogArt.hinweis, {'titel': 'Eins'}));
      z.ende.complete();
      await tester.pumpAndSettle();
      expect(find.text('Eins'), findsNothing);
      expect(await z.antwort, isNull);

      dialoge = PluginDialoge(frist: const Duration(seconds: 3));
      z = await zeigen(tester, _pluginDialog(PluginDialogArt.hinweis, {'titel': 'Zwei'}));
      expect(find.text('Zwei'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Zwei'), findsNothing);
      expect(await z.antwort, isNull);
    });

    testWidgets('zwei Dialoge verschiedener Aufrufe: der zweite kommt nach dem ersten', (tester) async {
      final eins = await zeigen(tester, _pluginDialog(PluginDialogArt.hinweis, {'titel': 'Eins'}));
      final zwei = dialoge.zeigen(
        _pluginDialog(PluginDialogArt.hinweis, {'titel': 'Zwei'}),
        ende: Completer<void>().future,
      );
      await tester.pumpAndSettle();
      expect(find.text('Eins'), findsOneWidget);
      expect(find.text('Zwei'), findsNothing);
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(await eins.antwort, <String, Object?>{});
      expect(find.text('Zwei'), findsOneWidget);
      dialoge.beantworten(dialoge.aktuell!, null);
      await tester.pumpAndSettle();
      expect(await zwei, isNull);
    });
  });

  group('Freigabe eines Plugins im Dialog', () {
    late Freigaben freigaben;
    late McpDienst dienst;
    setUp(() {
      final protokoll = Protokoll();
      freigaben = Freigaben(protokoll);
      dienst = McpDienst(
        Einstellungen(schluessel: 'test'),
        MoodleZugang(protokoll),
        protokoll,
        freigaben,
        '',
        profil: Profil.migriert(''),
      );
    });

    Future<PluginFreigabeAusgang> bitten() => dienst.pluginFreigabe(
      titel: 'Beispiel freigeben?',
      zusammenfassung: 'Das Beispiel ändert **nichts**.\n<i>Probe</i>',
      ab: Bestaetigungen.mittel,
      abbruch: Completer<void>().future,
      aufrufer: 'Plugin „Beispiel“',
    );

    testWidgets('die Zusammenfassung erscheint roh und als vom Plugin, ungeprüft; nur Maus, erst nach der Wartezeit', (tester) async {
      await tester.pumpWidget(_fenster(freigaben));
      final ausgang = bitten();
      await tester.pumpAndSettle();

      expect(find.text('Beispiel freigeben?'), findsOneWidget);
      expect(find.text('Aufgerufen vom Plugin „Beispiel“, nicht direkt von der KI'), findsOneWidget);
      expect(
        find.text('Titel und Beschreibung stammen vom Plugin „Beispiel“; moocp hat sie nicht geprüft:'),
        findsOneWidget,
      );
      expect(find.text('Das Beispiel ändert **nichts**.\n<i>Probe</i>'), findsOneWidget);
      expect(find.text('Ohne Entscheidung innerhalb von 30 Minuten wird nichts freigegeben.'), findsOneWidget);

      await tester.tap(find.text('Freigeben'));
      await tester.pumpAndSettle();
      expect(freigaben.aktuell, isNotNull, reason: 'vor der Wartezeit nimmt der Knopf nichts an');
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(freigaben.aktuell, isNotNull, reason: 'Return und Leertaste entscheiden nichts');

      await tester.tap(find.text('Freigeben'));
      await tester.pumpAndSettle();
      expect(await ausgang, PluginFreigabeAusgang.freigegeben);
    });

    testWidgets('Schreiben über eine Zusatzadresse: Adresse ohne Werte, Feldnamen, Grund und der Kasten des Plugins', (tester) async {
      freigaben.stufe = Bestaetigungen.keine;
      await tester.pumpWidget(_fenster(freigaben));
      final uri = Uri.parse('https://moodle.schule.example/mod/beispiel/speichern.php?id=7&seite=2');
      final punkte = zusatzFreigabePunkte(
        uri,
        [const MapEntry('notiz', 'Erika'), const MapEntry('farbe', 'rot')],
        Zusatzadresse(Adressmuster.parsen('/mod/beispiel/speichern.php'), ZugriffsArt.schreiben, 'Speichert die Notiz.'),
      );
      final ausgang = dienst.pluginFreigabe(
        titel: 'Notiz speichern?',
        zusammenfassung: 'Speichert die Notiz.',
        ab: Bestaetigungen.keine,
        abbruch: Completer<void>().future,
        aufrufer: 'Plugin „Beispiel“',
        punkte: punkte,
        protokolltitel: 'Schreiben über eine Zusatzadresse eines Plugins',
      );
      await tester.pumpAndSettle();

      expect(find.text('Notiz speichern?'), findsOneWidget);
      expect(find.text('Aufgerufen vom Plugin „Beispiel“, nicht direkt von der KI'), findsOneWidget);
      expect(
        find.text('Titel und Beschreibung stammen vom Plugin „Beispiel“; moocp hat sie nicht geprüft:'),
        findsOneWidget,
      );
      expect(find.text('Speichert die Notiz.'), findsOneWidget);
      expect(
        find.text('•  Schreibt in Moodle über eine Zusatzadresse des Plugins: POST /mod/beispiel/speichern.php?id=…&seite=…'),
        findsOneWidget,
      );
      expect(find.text('•  Formularfelder (nur die Namen): notiz, farbe'), findsOneWidget);
      expect(find.textContaining('Grund dieser Zusatzadresse aus der Beschreibungsdatei'), findsOneWidget);
      expect(find.textContaining('Erika'), findsNothing);
      expect(find.textContaining('rot'), findsNothing);

      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Freigeben'));
      await tester.pumpAndSettle();
      expect(await ausgang, PluginFreigabeAusgang.freigegeben);
    });

    testWidgets('Ablehnen', (tester) async {
      await tester.pumpWidget(_fenster(freigaben));
      final ausgang = bitten();
      await tester.pumpAndSettle();
      await tester.pump(Sperrzeit.dauerVorgabe);
      await tester.tap(find.text('Ablehnen'));
      await tester.pumpAndSettle();
      expect(await ausgang, PluginFreigabeAusgang.abgelehnt);
    });
  });

  group('Warnung der letzten Sperre', () {
    SperrTreffer treffer(String wort, {String? werkzeug = 'beispiel_namen', SperrStelle stelle = SperrStelle.ergebnis}) =>
        SperrTreffer(plugin: 'Beispiel', werkzeug: werkzeug, stelle: stelle, wort: wort, zeit: DateTime(2026, 1, 2, 9, 5, 7));

    Widget fenster(SperrHinweise h) => MaterialApp(
      home: SperrHinweisAnzeige(
        hinweise: h,
        nachVorn: () async {},
        child: const Scaffold(body: Text('Hauptfenster')),
      ),
    );

    testWidgets('zeigt Plugin, Werkzeug, Stelle und Wort; der einzige Knopf schließt, keiner sendet', (tester) async {
      final h = SperrHinweise();
      await tester.pumpWidget(fenster(h));

      h.melden(treffer('Erika'));
      await tester.pumpAndSettle();

      expect(find.text('Gesperrt: möglicher Name aus einem Plugin'), findsOneWidget);
      expect(find.text('09:05:07  Plugin „Beispiel“, Werkzeug beispiel_namen, Antwort an die KI: Wort „Erika“'), findsOneWidget);
      expect(find.textContaining('lässt sich nicht doch senden'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is ButtonStyleButton), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Schließen'), findsOneWidget);
      for (final wort in ['Senden', 'Freigeben', 'Trotzdem', 'Übernehmen']) {
        expect(find.textContaining(wort), findsNothing, reason: wort);
      }
    });

    testWidgets('ein Treffer auf den Ordner für Downloads nennt den Ordner, nicht ein Wort', (tester) async {
      final h = SperrHinweise();
      await tester.pumpWidget(fenster(h));

      h.melden(
        SperrTreffer(
          plugin: 'Beispiel',
          werkzeug: 'beispiel_download',
          stelle: SperrStelle.ergebnis,
          wort: '/tmp/moocp_plugin_downloads',
          pfad: true,
          zeit: DateTime(2026, 1, 2, 9, 5, 7),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          '09:05:07  Plugin „Beispiel“, Werkzeug beispiel_download, Antwort an die KI: '
          'der Pfad des Ordners für Downloads',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Wort „'), findsNothing);
    });

    testWidgets('mehrere Treffer kurz hintereinander: ein Fenster, das mitwächst; danach ein neues', (tester) async {
      final h = SperrHinweise(hoechstens: 3);
      await tester.pumpWidget(fenster(h));

      h.melden(treffer('Erika'));
      await tester.pump();
      h.melden(treffer('Mustermann', werkzeug: null, stelle: SperrStelle.protokollzeile));
      for (var i = 0; i < 4; i++) {
        h.melden(treffer('Max$i'));
      }
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('09:05:07  Plugin „Beispiel“, Protokollzeile: Wort „Mustermann“'), findsOneWidget);
      expect(find.textContaining('Wort „Max0“'), findsOneWidget);
      expect(find.textContaining('Wort „Max1“'), findsNothing);
      expect(find.text('… und 3 weitere.'), findsOneWidget);

      await tester.tap(find.text('Schließen'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(h.offen, isEmpty);
      expect(h.weitere, 0);

      h.melden(treffer('Jo'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('Wort „Jo“'), findsOneWidget);
      expect(find.textContaining('Wort „Erika“'), findsNothing);
    });
  });
}
