// Der Dialog „Offene Sperren" (E37): Nach einem Schreibvorgang mit unklarem
// Ausgang sperrt die App weitere Änderungen am selben Objekt. Klären lässt sich
// die Sperre nicht immer (Moodle zeigt weder den alten noch den neuen Stand
// eindeutig); dann hebt sie die Lehrkraft hier auf, mit der Maus und nach der
// Wartezeit wie bei einer Freigabe (E4), nie über MCP und nie auf ein Ja im
// Chat. Der Vorgang bleibt als Nachweis liegen, das Protokoll nennt das
// Aufheben; der nächste Vorgang liest frisch.

import 'package:material_ui/material_ui.dart';

import 'moodle/moodle_zugang.dart';
import 'moodle/schreibvorgang.dart';
import 'nur_maus.dart';

class SperrenDialog extends StatefulWidget {
  const SperrenDialog({required this.moodle, super.key});
  final MoodleZugang moodle;

  @override
  State<SperrenDialog> createState() => _SperrenDialogState();
}

class _SperrenDialogState extends State<SperrenDialog> {
  late List<OffeneSperre> _sperren = offeneSperren(widget.moodle);

  void _aufheben(OffeneSperre s) {
    sperreAufheben(widget.moodle, s.vorgang);
    setState(() => _sperren = offeneSperren(widget.moodle));
  }

  @override
  Widget build(BuildContext context) => NurMaus(
    child: AlertDialog(
      title: const Text('Offene Sperren'),
      content: SizedBox(
        width: 520,
        child: _sperren.isEmpty
            ? const Text('Es gibt keine offene Sperre.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Bei diesen Objekten blieb nach einer Änderung unklar, ob Moodle sie gespeichert hat. moocp '
                    'ändert sie deshalb nicht noch einmal. Wenn Sie in Moodle nachgesehen haben und die Sperre '
                    'nicht mehr gebraucht wird, heben Sie sie hier auf; danach wird frisch gelesen.',
                  ),
                  const SizedBox(height: 12),
                  for (final s in _sperren)
                    Sperrzeit(
                      builder: (bereit) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(child: Text(s.ziel, style: const TextStyle(fontFamily: 'monospace'))),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              key: Key('aufheben-${s.vorgang}'),
                              onPressed: bereit ? () => _aufheben(s) : null,
                              child: const Text('Sperre aufheben'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        Sperrzeit(
          builder: (bereit) => TextButton(
            onPressed: bereit ? () => Navigator.pop(context) : null,
            child: const Text('Schließen'),
          ),
        ),
      ],
    ),
  );
}
