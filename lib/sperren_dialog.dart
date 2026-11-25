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
  final Set<String> _geprueft = {};

  void _aufheben(OffeneSperre s) {
    if (!_geprueft.remove(s.vorgang)) return;
    sperreAufheben(widget.moodle, s.vorgang);
    setState(() => _sperren = offeneSperren(widget.moodle));
  }

  @override
  Widget build(BuildContext context) => NurMaus(
    child: AlertDialog(
      title: const Text('Offene Sperren'),
      content: SingleChildScrollView(child: SizedBox(
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
                    'nicht mehr gebraucht wird, heben Sie sie hier auf; danach wird frisch gelesen. Eine noch '
                    'laufende Anfrage kann später oder doppelt wirken; das Aufheben bestätigt keinen Speichererfolg.',
                  ),
                  const SizedBox(height: 12),
                  for (final s in _sperren)
                    Sperrzeit(
                      builder: (bereit) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          children: [
                            Row(children: [
                              Expanded(child: Text(s.ziel, style: const TextStyle(fontFamily: 'monospace'))),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                key: Key('aufheben-${s.vorgang}'),
                                onPressed: bereit && _geprueft.contains(s.vorgang) ? () => _aufheben(s) : null,
                                child: const Text('Sperre aufheben'),
                              ),
                            ]),
                            CheckboxListTile(
                              key: Key('geprueft-${s.vorgang}'),
                              title: const Text('Ich habe in Moodle nachgesehen und will dieses Objekt wieder ändern lassen.'),
                              value: _geprueft.contains(s.vorgang),
                              onChanged: (an) => setState(() {
                                if (an == true) {
                                  _geprueft.add(s.vorgang);
                                } else {
                                  _geprueft.remove(s.vorgang);
                                }
                              }),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      )),
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
