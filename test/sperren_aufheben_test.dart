// Offene Sperren aufheben (E37): Kern, Dialog (nur Maus, Wartezeit) und die
// Gewissheit, dass die KI keine Sperre ohne Entscheidung in der App aufhebt.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/moodle/formular_lesen.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/moodle/schreibvorgang.dart';
import 'package:moocp/nur_maus.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';
import 'package:moocp/sperren_dialog.dart';

void main() {
  late Directory ordner;
  late Protokoll protokoll;
  late MoodleZugang moodle;
  late Schreibvorgang vorgang;

  setUp(() async {
    ordner = Directory.systemTemp.createTempSync('sperren-');
    protokoll = Protokoll();
    moodle = MoodleZugang(protokoll, schreibvorgaengeOrdner: ordner.path);
    vorgang = Schreibvorgang(moodle, Formularziel.frage(12, 5001));
    final h = '0' * 64;
    vorgang.beginnen({'a': h}, {'a': h});
  });
  tearDown(() => ordner.deleteSync(recursive: true));

  test('Eine Sperre nach unklarem Ausgang erscheint und lässt sich aufheben', () {
    final liste = offeneSperren(moodle);
    expect(liste, hasLength(1));
    expect(liste.single.ziel, allOf(contains('5001'), isNot(contains('name'))));
    expect(vorgang.offen, isTrue);
    sperreAufheben(moodle, liste.single.vorgang);
    expect(offeneSperren(moodle), isEmpty);
    expect(Schreibvorgang(moodle, Formularziel.frage(12, 5001)).offen, isFalse, reason: 'ein neuer Vorgang darf beginnen');
    expect(protokoll.eintraege.map((e) => e.text).join(' '), contains('Sperre aufgehoben'));
  });

  test('Der Vorgang bleibt als Nachweis liegen', () {
    sperreAufheben(moodle, vorgang.id);
    expect(Schreibvorgang.laden(moodle, vorgang.id).lesen()!.status, Schreibstatus.aufgehoben);
  });

  testWidgets('Der Dialog nimmt erst nach der Wartezeit etwas an, und nur mit der Maus', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SperrenDialog(moodle: moodle))));
    final knopf = find.byKey(Key('aufheben-${vorgang.id}'));
    expect(knopf, findsOneWidget);
    await tester.tap(knopf);
    await tester.pump();
    expect(offeneSperren(moodle), hasLength(1), reason: 'vor der Wartezeit wirkt der Klick nicht');
    await tester.pump(Sperrzeit.dauerVorgabe);
    await tester.tap(knopf);
    await tester.pump();
    expect(offeneSperren(moodle), hasLength(1), reason: 'Wartezeit allein ersetzt nicht das ausdrückliche Abhaken');
    await tester.ensureVisible(find.byKey(Key('geprueft-${vorgang.id}')));
    await tester.tap(find.byKey(Key('geprueft-${vorgang.id}')));
    await tester.pump();
    // Return und Leertaste entscheiden nichts.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(offeneSperren(moodle), hasLength(1));
    await tester.tap(knopf);
    await tester.pump();
    expect(offeneSperren(moodle), isEmpty);
    expect(find.text('Es gibt keine offene Sperre.'), findsOneWidget);
  });

  test('Über MCP gibt es kein Werkzeug, das eine Sperre aufhebt', () async {
    final dienst = McpDienst(Einstellungen(schluessel: ''), moodle, protokoll, Freigaben(protokoll), ordner.path,
        profil: Profil.migriert(''));
    final namen = await dienst.eingebauteWerkzeugnamen();
    expect(namen.where((n) => n.contains('sperre') || n.contains('aufheb')), isEmpty);
    expect(namen, contains('aendern_status'), reason: 'die KI darf den Stand prüfen oder eine menschliche Entscheidung in der App anfordern');
  });
}
