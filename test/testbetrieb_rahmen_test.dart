// Der Testbetrieb ist im Fenster nicht zu übersehen; der Normalbetrieb zeigt nichts.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/testbetrieb_rahmen.dart';
import 'package:moocp/testschalter.dart';

void main() {
  tearDown(() => testbetriebFuerTestsSetzen(true));

  testWidgets('Testbetrieb: roter Hinweis über dem Inhalt', (tester) async {
    testbetriebFuerTestsSetzen(true);
    await tester.pumpWidget(const MaterialApp(home: TestbetriebRahmen(kind: Text('Inhalt'))));
    expect(find.textContaining('DEBUG – TESTBETRIEB'), findsOneWidget);
    expect(find.text('Inhalt'), findsOneWidget);
  });

  testWidgets('Normalbetrieb: kein Hinweis', (tester) async {
    testbetriebFuerTestsSetzen(false);
    await tester.pumpWidget(const MaterialApp(home: TestbetriebRahmen(kind: Text('Inhalt'))));
    expect(find.textContaining('DEBUG'), findsNothing);
    expect(find.text('Inhalt'), findsOneWidget);
  });
}
