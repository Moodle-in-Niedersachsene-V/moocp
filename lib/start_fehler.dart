// Das Fenster, wenn die App nicht starten kann, weil ein Ordner nicht privat
// ist (plattform/privater_ordner.dart): Ohne ein Fenster sähe die Lehrkraft nur,
// dass nichts passiert. Es zeigt die Meldung und kann beendet werden; bis
// dahin hat die App nichts geschrieben und nichts gelöscht.

import 'dart:io';

import 'package:material_ui/material_ui.dart';

class StartFehlerApp extends StatelessWidget {
  const StartFehlerApp(this.meldung, {super.key});

  final String meldung;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'moocp',
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('moocp kann nicht starten', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                SelectableText(meldung),
                const SizedBox(height: 20),
                FilledButton(onPressed: () => exit(1), child: const Text('Beenden')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
