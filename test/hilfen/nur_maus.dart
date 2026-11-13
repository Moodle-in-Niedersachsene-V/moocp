// Für die Widget-Tests der Dialoge, die nur mit der Maus entschieden werden
// (E4): Freigaben, Zustimmung zu einem Plugin, Entwicklungs-Plugin.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ob einer der Knöpfe mit den Beschriftungen [knoepfe] den Tastaturfokus
/// hat: Der nächste Fokus über der Beschriftung ist der des Knopfs.
bool knopfHatFokus(List<String> knoepfe) {
  final primaer = FocusManager.instance.primaryFocus;
  if (primaer == null || primaer is FocusScopeNode) return false;
  for (final k in knoepfe) {
    for (final e in find.text(k).evaluate()) {
      if (identical(Focus.maybeOf(e), primaer)) return true;
    }
  }
  return false;
}

/// Wie jemand, der mit der Tastatur an die Knöpfe will: mehrmals Tabulator,
/// danach jedes Mal Return, Enter und Leertaste. Erwartet, dass dabei keiner
/// der Knöpfe [knoepfe] den Fokus bekommt; ob etwas entschieden wurde, prüft
/// der Aufrufer.
Future<void> tabUndTasten(WidgetTester tester, List<String> knoepfe, {int mal = 6}) async {
  for (var i = 0; i < mal; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(knopfHatFokus(knoepfe), isFalse, reason: 'nach ${i + 1}× Tabulator hat ein Knopf den Fokus');
    for (final taste in [LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter, LogicalKeyboardKey.space]) {
      await tester.sendKeyEvent(taste);
      await tester.pumpAndSettle();
    }
  }
}
