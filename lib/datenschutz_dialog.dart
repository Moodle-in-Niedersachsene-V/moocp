// Das Fenster der Datenschutzwarnung (E36, plugin/datenschutz.dart): Die Antwort
// eines Plugins enthält ein Wort, das der Name einer Person sein könnte, oder
// den Pfad eines Ordners, in dem Daten von Personen liegen können, und die
// Lehrkraft entscheidet für diese eine Antwort: „Sperren“ (Datenschutzsperre)
// oder „Kein Name – trotzdem an die KI geben“.
//
// Es kommt durch die Freigaben (freigabe.dart, `FreigabeAnfrage.datenschutz`)
// und erbt damit alles, was dort gilt: eine Anfrage nach der anderen, die Frist,
// das Schließen beim Abbruch des Clients. Entschieden wird nur mit der Maus
// ([NurMaus]) und erst nach der Wartezeit ([Sperrzeit]). Es sieht anders aus
// als jede andere Freigabe (roter Rahmen, rote Titelzeile, Warnzeichen), damit
// niemand es aus Gewohnheit bestätigt. Es zeigt Text, keine Bilder; die Wörter
// stehen nur hier, nie im Protokoll.

import 'package:material_ui/material_ui.dart';

import 'freigabe.dart';
import 'nur_maus.dart';
import 'datenschutzwarnung.dart';

/// So viele Treffer zeigt das Fenster einzeln; die übrigen zählt es nur.
const datenschutzTrefferHoechstens = 20;

const _rot = Color(0xFFB71C1C);

/// Der Titel der Warnung: der für Namen, sobald einer getroffen hat, sonst der
/// für Pfade.
String datenschutzTitel(Datenschutzwarnung w) => w.hatNamen
    ? 'Achtung: Möglicherweise personenbezogene Daten'
    : 'Achtung: Möglicherweise Speicherort personenbezogener Daten';

/// Der Satz oder die beiden Sätze unter dem Titel.
List<String> datenschutzTexte(Datenschutzwarnung w) => [
  if (w.hatNamen)
    'Diese Antwort von Plugin „${w.plugin}“ enthält Wörter, die Namen von Personen sein könnten (rot markiert). '
        'Wenn Sie senden, erfährt die KI den ganzen Text. Senden Sie nur, wenn Sie sicher sind, '
        'dass hier keine Person genannt ist.',
  if (w.hatPfade)
    'Diese Antwort von Plugin „${w.plugin}“ nennt einen Ordner, in dem Daten von Personen liegen können '
        '(rot markiert). Kennt die KI den Ordner, kann sie die Dateien darin mit eigenen Mitteln lesen, '
        'an moocp vorbei. Senden Sie nur, wenn die KI diesen Ort kennen darf.',
];

class DatenschutzwarnungDialog extends StatelessWidget {
  const DatenschutzwarnungDialog(this.anfrage, this.freigaben, {this.profilname, this.mcpName, super.key});

  /// Die Anfrage der Freigaben; [FreigabeAnfrage.datenschutz] ist gesetzt.
  final FreigabeAnfrage anfrage;
  final Freigaben freigaben;
  final String? profilname;
  final String? mcpName;

  Datenschutzwarnung get warnung => anfrage.datenschutz!;

  String _restfrist() {
    final rest = anfrage.ablauf?.difference(DateTime.now()) ?? freigaben.frist;
    final minuten = (rest.inSeconds / 60).round();
    return minuten <= 1 ? 'einer Minute' : '$minuten Minuten';
  }

  static String _herkunft(Fund f) {
    final texte = {for (final h in f.herkunft) h.text};
    return f.pfad ? 'Pfad: ${texte.join(', ')}' : texte.join(', ');
  }

  Widget _fund(BuildContext context, Fund f, int nr) {
    final theme = Theme.of(context);
    return Container(
      key: ValueKey('datenschutz-fund-$nr'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black26),
        borderRadius: BorderRadius.circular(4),
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Quelle: ${_herkunft(f)}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          SelectableText.rich(
            TextSpan(
              children: [
                TextSpan(text: '${f.davorGekuerzt ? '…' : ''}${f.davor}'),
                TextSpan(
                  text: f.wort,
                  style: const TextStyle(color: _rot, fontWeight: FontWeight.bold),
                ),
                TextSpan(text: '${f.danach}${f.danachGekuerzt ? '…' : ''}'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final w = warnung;
    final gezeigt = w.funde.take(datenschutzTrefferHoechstens).toList();
    final weitere = w.anzahl - gezeigt.length;
    // Entschieden wird nur mit der Maus (nur_maus.dart).
    return NurMaus(
      child: AlertDialog(
        // Roter Rahmen und rote Titelzeile: Das Fenster soll auf den ersten
        // Blick keine der gewöhnlichen Freigaben sein.
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: _rot, width: 4),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        titlePadding: EdgeInsets.zero,
        contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        title: Container(
          color: _rot,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      datenschutzTitel(w),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
                    ),
                  ),
                ],
              ),
              if (profilname != null)
                Text('$profilname ($mcpName)', style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
        content: SizedBox(
          width: 760,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final t in datenschutzTexte(w)) ...[Text(t), const SizedBox(height: 8)],
                      Text(
                        'Plugin „${w.plugin}“${w.werkzeug == null ? '' : ', Werkzeug ${w.werkzeug}'}'
                        ' – ${w.anzahl} ${w.anzahl == 1 ? 'Treffer' : 'Treffer'}',
                        style: theme.textTheme.titleSmall,
                      ),
                      for (final (i, f) in gezeigt.indexed) _fund(context, f, i),
                      if (weitere > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text('… und $weitere weitere Treffer.', style: theme.textTheme.bodySmall),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Ohne Entscheidung innerhalb von ${_restfrist()} wird die Antwort gesperrt.',
                style: theme.textTheme.bodySmall,
              ),
              // Nach der Entscheidung kommt der nächste Dialog -- die Lehrkraft
              // soll das vorher wissen.
              ListenableBuilder(
                listenable: freigaben,
                builder: (context, _) => switch (freigaben.wartend) {
                  0 => const SizedBox.shrink(),
                  final n => Text(
                    n == 1 ? '1 weitere Anfrage wartet.' : '$n weitere Anfragen warten.',
                    style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                },
              ),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        actions: [
          // Die Knöpfe nehmen erst nach der Wartezeit etwas an (Sperrzeit).
          Sperrzeit(
            builder: (bereit) => SizedBox(
              width: double.infinity,
              // Bei schmalem Fenster rutscht der rote Knopf in die nächste Zeile,
              // statt dass etwas abgeschnitten wird.
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 24,
                runSpacing: 8,
                children: [
                  // Ruhig und zuerst: die vorgesehene Antwort.
                  FilledButton(
                    key: const ValueKey('datenschutz-sperren'),
                    onPressed: bereit ? () => Navigator.of(context).pop(false) : null,
                    child: Text(anfrage.ablehnen),
                  ),
                  // Abgesetzt, rot, mit Warnzeichen: Senden ist eine bewusste Tat.
                  FilledButton.icon(
                    key: const ValueKey('datenschutz-senden'),
                    style: FilledButton.styleFrom(backgroundColor: _rot, foregroundColor: Colors.white),
                    icon: const Icon(Icons.warning_amber_rounded),
                    onPressed: bereit ? () => Navigator.of(context).pop(true) : null,
                    label: Text(anfrage.knopf),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
