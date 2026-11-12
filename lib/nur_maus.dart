// Die beiden Schutzmechanismen von Dialogen, die sich nach vorn holen und
// etwas entscheiden lassen: Freigaben (main.dart, FreigabeDialog) und die
// Zustimmung zu einem Plugin (einstellungen_dialog.dart). Beide kommen oft
// auf den Schirm, während die Lehrkraft woanders schreibt oder klickt; ein
// Return oder Klick, der gerade unterwegs ist, darf nichts entscheiden.
//
// Bewusst nur mit `widgets.dart` und `services.dart`, nicht mit Material:
// Beides lässt sich so von jedem Dialog nutzen, ohne dass ein Dialog den
// anderen einbinden müsste.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Hält Return, Enter und Leertaste von dem Dialog darunter fern: Der Dialog
/// kommt nach vorn, oft während die Lehrkraft woanders schreibt, und ein
/// Return oder Leerzeichen, das gerade unterwegs ist, löste sonst den Knopf mit
/// dem Fokus aus -- eine Entscheidung, die niemand getroffen hat. Entschieden
/// wird deshalb nur mit der Maus (E4).
class NurMaus extends StatelessWidget {
  const NurMaus({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): DoNothingAndStopPropagationIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): DoNothingAndStopPropagationIntent(),
          SingleActivator(LogicalKeyboardKey.space): DoNothingAndStopPropagationIntent(),
        },
        child: child,
      );
}

/// Die Knöpfe eines Dialogs, der sich nach vorn holt, nehmen erst nach
/// [dauer] etwas an: Ein Klick, der gerade einem anderen Fenster galt, träfe
/// sonst den Dialog, der darüber aufgeht. Ausgegraut, damit die Lehrkraft
/// sieht, dass es kurz dauert.
class Sperrzeit extends StatefulWidget {
  const Sperrzeit({
    super.key,
    required this.builder,
    this.dauer = dauerVorgabe,
  });
  final Widget Function(bool bereit) builder;
  final Duration dauer;

  static const dauerVorgabe = Duration(milliseconds: 1500);

  @override
  State<Sperrzeit> createState() => _SperrzeitState();
}

class _SperrzeitState extends State<Sperrzeit> {
  bool _bereit = false;
  late final Timer _uhr;

  @override
  void initState() {
    super.initState();
    _uhr = Timer(widget.dauer, () {
      if (mounted) setState(() => _bereit = true);
    });
  }

  @override
  void dispose() {
    _uhr.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_bereit);
}
