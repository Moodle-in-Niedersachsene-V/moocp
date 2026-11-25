// Das Fenster, wenn der private Ordner fehlt (lib/start_fehler.dart): Es zeigt
// die Meldung und einen Knopf zum Beenden, und die Meldung nennt den Pfad des
// Ordners für Downloads nicht (E36).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moocp/plattform/privater_ordner.dart';
import 'package:moocp/plugin/downloads.dart';
import 'package:moocp/start_fehler.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('zeigt die Meldung und den Knopf „Beenden“', (t) async {
    const meldung = 'Der Arbeitsordner („/x/moocp-1000/moocp_arbeitsordner“) ist nicht privat: …';
    await t.pumpWidget(const StartFehlerApp(meldung));
    expect(find.text('moocp kann nicht starten'), findsOneWidget);
    expect(find.textContaining('ist nicht privat'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Beenden'), findsOneWidget);
  });

  test('die echte Meldung für den Ordner der Downloads nennt dessen Pfad nicht', () {
    final tmp = Directory.systemTemp.createTempSync('zz_start_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final grund = Directory(p.join(tmp.path, 'moocp-${UnixPrivatSystem().uid}'))..createSync();
    Process.runSync('chmod', ['755', grund.path]);
    final fehler = (() {
      try {
        PluginDownloads.einrichten(basis: tmp.path, linux: true, umgebung: const {});
      } on PrivaterOrdnerFehler catch (e) {
        return e;
      }
      return null;
    })();
    expect(fehler, isNotNull);
    expect(fehler!.meldung, isNot(contains(PluginDownloads.ordnername)));
  }, skip: Platform.isWindows ? 'POSIX' : null);
}
