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
///
/// Die Wartezeit beginnt neu, sobald der Dialog wieder der oberste ist: Die
/// Dialoge der App liegen als eigene Routen übereinander (Freigaben je
/// Profil, Dialoge der Plugins, die Warnung der Datenschutzprüfung). Geht einer
/// über einer offenen Freigabe auf und wieder zu, ist deren Wartezeit längst
/// um, und der zweite Klick eines Doppelklicks, der dem oberen galt, träfe
/// sonst sie (E4).
///
/// Die Knöpfe sind außerdem nicht über die Tastatur zu erreichen
/// ([ExcludeFocus]): Entschieden wird nur mit der Maus (E4), und ein Knopf
/// mit Fokus wartete nur auf eine Taste, die gerade unterwegs ist. Felder im
/// Dialog bleiben fokussierbar; nur was [builder] baut, ist ausgenommen.
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
  Timer? _uhr;

  /// Ob der Dialog zuletzt der oberste war; null vor dem ersten Blick.
  bool? _oben;

  // Ohne Route (etwa im Test) gilt der Dialog als oberster. ModalRoute.isCurrentOf
  // meldet jede Änderung als neue Abhängigkeit; so kommt sie hierher.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final oben = ModalRoute.isCurrentOf(context) ?? true;
    if (oben == _oben) return;
    _oben = oben;
    _uhr?.cancel();
    _uhr = null;
    _bereit = false;
    if (oben) {
      _uhr = Timer(widget.dauer, () {
        if (mounted) setState(() => _bereit = true);
      });
    }
  }

  @override
  void dispose() {
    _uhr?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(child: widget.builder(_bereit));
}
