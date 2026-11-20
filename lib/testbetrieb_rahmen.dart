// Der Debug-Bau mit Testbetrieb (lib/testschalter.dart) ist nie für Lehrkräfte:
// Er gibt Freigaben automatisch, schreibt in Testkurse und läuft ohne die
// Sicherheitsabfragen des Normalbetriebs. Damit niemand ihn für die normale App hält,
// trägt jedes Fenster oben einen roten Balken und einen roten Rahmen; der Normalbau
// zeigt nichts davon.
import 'package:material_ui/material_ui.dart';

import 'testschalter.dart';

/// Umgibt [kind] im Testbetrieb mit dem roten Hinweis, sonst nicht.
class TestbetriebRahmen extends StatelessWidget {
  const TestbetriebRahmen({super.key, required this.kind});

  final Widget kind;

  static const _rot = Color(0xFFC62828);

  @override
  Widget build(BuildContext context) {
    if (!testbetriebAktiv) return kind;
    return DecoratedBox(
      decoration: BoxDecoration(border: Border.all(color: _rot, width: 4)),
      child: Column(
        children: [
          Material(
            color: _rot,
            child: const SizedBox(
              width: double.infinity,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                child: Text(
                  'DEBUG – TESTBETRIEB: nicht die normale App. Freigaben laufen automatisch, '
                  'nur für Testkurse; nie für den Unterricht.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: kind),
        ],
      ),
    );
  }
}
