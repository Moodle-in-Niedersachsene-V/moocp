// Der Dialog „Einstellungen": was sich dauerhaft einstellen lässt, ohne
// Anmeldedaten -- die stehen auf der Hauptseite.
//
// Vier Abschnitte: die Update-Prüfung (update/update.dart), der Weg zum
// Dialog „KI-Werkzeuge einrichten", die Plugins (nur, wenn es welche gibt)
// und, ganz unten und unauffällig, das Verbinden einer weiteren
// Moodle-Instanz (E32). Wer nur eine hat -- fast jeder --, braucht den letzten
// nie und sieht von Profilen sonst nichts.
//
// Dazu die Dialoge zu Plugins (E35): „Plugin zulassen" beim Start und beim
// Ändern einer Zustimmung, „Plugins" mit dem Stand je Plugin und
// „Entwicklungs-Plugin anhängen" beim Start mit `--plugin-entwicklung`. Sie stehen
// hier, weil sie zu den Einstellungen gehören und Material nutzen: Jede Datei,
// die es einbindet, zeigt eine Meldung der Analyse zur Umstellung auf
// material_ui, und die Zahl der Dateien soll nicht wachsen.
// Der Zugangsschlüssel steht hier bewusst nicht: Eingetragen wird er nur von der App selbst (E13), und jede Anzeige
// wäre ein weiterer Weg, ihn aus Versehen weiterzugeben. Wer ihn braucht,
// findet ihn in der README.

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'einstellungen.dart';
import 'nur_maus.dart';
import 'plugin/beschreibung.dart';
import 'plugin/entwicklung.dart';
import 'plugin/laufende_plugins.dart';
import 'plugin/plugins.dart';
import 'profil.dart';
import 'protokoll.dart';
import 'update/update.dart';
import 'update/update_dialoge.dart';

enum EinstellungenErgebnis {
  /// Nichts weiter zu tun.
  fertig,

  /// Die Lehrkraft will zu „KI-Werkzeuge einrichten"; der Aufrufer öffnet ihn,
  /// damit nicht zwei Dialoge übereinanderliegen.
  einrichten,

  /// Ein Update wird installiert: Die App muss sich jetzt beenden.
  beenden,

  /// Das aktuell ausgewählte MCP-Profil entfernen.
  profilLoeschen,

  /// Eine weitere Moodle-Instanz verbinden: Der Aufrufer öffnet den
  /// Profil-Dialog.
  profilHinzufuegen,

  /// Die Plugins ansehen und ändern: Der Aufrufer öffnet [PluginsDialog].
  plugins,

  /// Offene Sperren nach unklaren Schreibvorgängen ansehen und aufheben: Der
  /// Aufrufer öffnet den Dialog (sperren_dialog.dart, E37).
  sperren,
}

class EinstellungenDialog extends StatefulWidget {
  const EinstellungenDialog({
    required this.einstellungen,
    required this.protokoll,
    required this.eigene,
    required this.updateMoeglich,
    this.updatePaket,
    this.imBrowserOeffnen,
    required this.sitzungLaeuft,
    this.profilname,
    this.mcpName,
    this.profilLoeschenMoeglich = false,
    this.weitereInstanzMoeglich = false,
    this.plugins,
    this.profile = const [],
    super.key,
  });

  final Einstellungen einstellungen;
  final Protokoll protokoll;

  /// Die laufende Version, etwa „0.9.4".
  final String eigene;

  /// Ob diese App nach Updates sucht: unter Windows, wenn sie sich selbst
  /// ersetzen kann, auf dem Mac und unter Linux, wenn sie aus einem Paket
  /// installiert ist (update.dart).
  final bool updateMoeglich;

  /// Mac und Linux: das Paket, aus dem die App stammt; dann sagt die Suche
  /// nur Bescheid und öffnet die Datei mit [imBrowserOeffnen].
  final UpdatePaket? updatePaket;
  final Future<void> Function(Uri adresse)? imBrowserOeffnen;

  /// Ob der MCP-Server läuft; dann hängt womöglich eine Sitzung eines KI-Werkzeugs
  /// daran, die ein Update verlöre.
  final bool sitzungLaeuft;

  /// Profilname und MCP-Name, nur mit mehreren Profilen; sonst null, und der
  /// Titel heißt einfach „Einstellungen".
  final String? profilname;
  final String? mcpName;

  /// Ob es mehr als ein Profil gibt, also eines zu löschen ist (eines bleibt
  /// immer).
  final bool profilLoeschenMoeglich;

  /// Ob die App eine weitere Instanz anlegen kann (der Aufrufer weiß es).
  final bool weitereInstanzMoeglich;

  /// Die beim Start gefundenen Plugins; null oder leer, solange es keine gibt.
  /// Dann fehlt der Abschnitt „Plugins" ganz.
  final Plugins? plugins;

  /// Die Instanzprofile: Erst ab zwei ist von Profilen die Rede (E32).
  final List<Profil> profile;

  @override
  State<EinstellungenDialog> createState() => _EinstellungenDialogState();
}

class _EinstellungenDialogState extends State<EinstellungenDialog> {
  bool _sucht = false;

  Future<void> _umschalten(bool an) async {
    setState(() => widget.einstellungen.updatePruefen = an);
    try {
      await widget.einstellungen.speichern();
    } catch (e) {
      widget.protokoll.eintrag(
        Art.fehler,
        'Einstellungen nicht gespeichert (${e.runtimeType})',
      );
    }
    widget.protokoll.eintrag(
      Art.info,
      an
          ? 'Update-Prüfung eingeschaltet: einmal täglich bei GitHub'
          : 'Update-Prüfung ausgeschaltet: keine Anfrage an GitHub',
    );
  }

  Future<void> _suchen() async {
    setState(() => _sucht = true);
    final beenden = await updateSchritt(
      context,
      einstellungen: widget.einstellungen,
      protokoll: widget.protokoll,
      eigene: widget.eigene,
      manuell: true,
      sitzungLaeuft: widget.sitzungLaeuft,
      paket: widget.updatePaket,
      imBrowserOeffnen: widget.imBrowserOeffnen,
    );
    if (!mounted) return;
    setState(() => _sucht = false);
    if (beenden) Navigator.pop(context, EinstellungenErgebnis.beenden);
  }

  @override
  Widget build(BuildContext context) {
    final klein = Theme.of(context).textTheme.bodySmall;
    final e = widget.einstellungen;
    final an = e.updatePruefen == true;
    return AlertDialog(
      title: Text(widget.profilname == null
          ? 'Einstellungen'
          : 'Einstellungen — ${widget.profilname} (${widget.mcpName})'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Updates', style: Theme.of(context).textTheme.titleSmall),
              if (!widget.updateMoeglich)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    Platform.isWindows
                        ? 'Diese Version kann sich nicht selbst aktualisieren: Sie läuft nicht aus '
                              'dem Installationsverzeichnis, oder die Prüfung ist über die Kommandozeile '
                              'abgeschaltet ($keinUpdateSchalter).'
                        : 'Diese Version sucht nicht nach Updates: Sie ist nicht aus einem der Pakete '
                              'installiert (auf dem Mac: nicht aus „Programme“ gestartet), oder die '
                              'Prüfung ist über die Kommandozeile abgeschaltet ($keinUpdateSchalter).',
                    style: klein,
                  ),
                )
              else ...[
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: an,
                  onChanged: _sucht ? null : (v) => _umschalten(v ?? false),
                  title: const Text(
                    'Einmal täglich bei GitHub nach einer neuen Version sehen',
                  ),
                  subtitle: Text(
                    'GitHub erfährt dabei Ihre IP-Adresse und den Zeitpunkt. Nichts aus '
                    'Moodle wird übertragen.',
                    style: klein,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    e.updateZuletzt == null
                        ? 'Noch nicht gesucht. Sie verwenden moocp ${widget.eigene}.'
                        : 'Zuletzt gesucht am ${e.updateZuletzt}. Sie verwenden moocp ${widget.eigene}.',
                    style: klein,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton(
                    onPressed: _sucht ? null : _suchen,
                    child: Text(
                      _sucht ? 'Sucht …' : 'Jetzt nach Updates suchen',
                    ),
                  ),
                ),
              ],
              const Divider(height: 32),
              Text(
                'KI-Werkzeuge',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Claude Code, Codex CLI und LM Studio brauchen die Verbindung zu dieser App und '
                  'die Skills in der Version, die zu ihr gehört. Dort wählen Sie auch, welche '
                  'davon eingerichtet werden.',
                  style: klein,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton(
                  onPressed: _sucht
                      ? null
                      : () => Navigator.pop(
                          context,
                          EinstellungenErgebnis.einrichten,
                        ),
                  child: const Text('Verbindung und Skills prüfen'),
                ),
              ),
              const Divider(height: 32),
              Text('Offene Sperren', style: Theme.of(context).textTheme.titleSmall),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Blieb nach einer Änderung unklar, ob Moodle sie gespeichert hat, ändert moocp dasselbe '
                  'Objekt nicht noch einmal. Hier heben Sie eine solche Sperre auf, wenn Sie in Moodle '
                  'nachgesehen haben.',
                  style: klein,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton(
                  key: const Key('sperren'),
                  onPressed: _sucht ? null : () => Navigator.pop(context, EinstellungenErgebnis.sperren),
                  child: const Text('Offene Sperren ansehen …'),
                ),
              ),
              if (widget.plugins != null && widget.plugins!.eintraege.isNotEmpty) ...[
                const Divider(height: 32),
                Text('Plugins', style: Theme.of(context).textTheme.titleSmall),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'moocp hat Plugins gefunden: zusätzliche Erweiterungen aus eigenen Projekten. Hier sehen '
                    'Sie, welchen Sie zugestimmt haben${widget.profile.length > 1 ? ', und schalten sie je Moodle-Instanz ein oder aus' : ''}.',
                    style: klein,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton(
                    key: const Key('plugins'),
                    onPressed: _sucht
                        ? null
                        : () => Navigator.pop(context, EinstellungenErgebnis.plugins),
                    child: const Text('Plugins ansehen und ändern …'),
                  ),
                ),
              ],
              if (widget.weitereInstanzMoeglich || widget.profilLoeschenMoeglich) ...[
                const Divider(height: 32),
                Text(
                  'Mehrere Moodle-Instanzen',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (widget.weitereInstanzMoeglich) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Nur nötig, wenn Sie mit mehr als einer Moodle-Instanz arbeiten, etwa einer '
                      'Test- neben der Produktivinstanz. Jede bekommt eine eigene Anmeldung, '
                      'Freigabestufe und einen eigenen MCP-Server mit eigenem Schlüssel.',
                      style: klein,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton(
                      key: const Key('add-profile'),
                      onPressed: _sucht
                          ? null
                          : () => Navigator.pop(
                              context,
                              EinstellungenErgebnis.profilHinzufuegen,
                            ),
                      child: const Text('Weitere Moodle-Instanz verbinden …'),
                    ),
                  ),
                ],
                if (widget.profilLoeschenMoeglich)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton.icon(
                      key: const Key('delete-profile'),
                      onPressed: _sucht
                          ? null
                          : () => Navigator.pop(
                              context,
                              EinstellungenErgebnis.profilLoeschen,
                            ),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('MCP-Profil löschen'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _sucht
              ? null
              : () => Navigator.pop(context, EinstellungenErgebnis.fertig),
          child: const Text('Schließen'),
        ),
      ],
    );
  }
}

/// Die Antwort des Dialogs „Plugin zulassen“.
class PluginAntwort {
  const PluginAntwort({required this.zugestimmt, this.profile = const {}});

  final bool zugestimmt;

  /// Die Kennungen der Instanzprofile, in denen das Plugin eingeschaltet sein
  /// soll; bei einer Ablehnung leer.
  final Set<String> profile;
}

/// Der Satz zur Verantwortung (E35). Er steht bei jeder Zustimmung da, auch
/// wenn das Plugin keine Zusatzadressen anmeldet: Er sagt, wofür moocp
/// einsteht und wofür nicht, und die Lehrkraft soll ihn nie überlesen können,
/// weil er „schon bekannt“ ist.
const pluginVerantwortung =
    'Die Zusagen von moocp gelten für moocp und für alles, was durch moocp zu Moodle geht. '
    'Für die Fehler des Plugins, für Schäden und für seine eigenen Datenwege steht sein Autor ein; '
    'moocp gibt dafür keine Gewähr.';

/// Der Dialog „Plugin zulassen“: Name, Version, Herkunft, die Zusatzadressen
/// mit Art und Grund und der Satz zur Verantwortung; mit mehreren
/// Instanzprofilen die Wahl, wo das Plugin eingeschaltet wird (alle
/// vorgewählt, E32). Rückgabe: [PluginAntwort]; sonst gibt es keinen Weg hinaus
/// (kein Escape, kein Klick daneben).
///
/// Er kommt beim Start nach vorn, oft während die Lehrkraft woanders schreibt,
/// und wird deshalb wie eine Freigabe nur mit der Maus und erst nach der
/// Wartezeit entschieden ([NurMaus], [Sperrzeit], E4). Eine Zustimmung ist
/// keine Freigabe: Freigabe heißt nur der Schreibvorgang (E4), Zustimmung das
/// Annehmen eines Plugins (E35).
class PluginZustimmungDialog extends StatefulWidget {
  const PluginZustimmungDialog({
    required this.eintrag,
    required this.profile,
    this.vorgewaehlt,
    super.key,
  });

  /// Das Plugin; es lädt (Beschreibung vorhanden).
  final PluginEintrag eintrag;

  /// Alle Instanzprofile. Mit nur einem gibt es keine Auswahl: Das Plugin gilt
  /// dort, die Zustimmung selbst ist der bewusste Schritt.
  final List<Profil> profile;

  /// Die Kennungen der vorgewählten Profile; null: alle. Beim Ändern einer
  /// Zustimmung die, in denen das Plugin eingeschaltet war.
  final Set<String>? vorgewaehlt;

  @override
  State<PluginZustimmungDialog> createState() => _PluginZustimmungDialogState();
}

class _PluginZustimmungDialogState extends State<PluginZustimmungDialog> {
  late final Set<String> _gewaehlt = widget.profile.length == 1
      ? {widget.profile.single.kennung}
      : {...(widget.vorgewaehlt ?? widget.profile.map((p) => p.kennung))};

  @override
  Widget build(BuildContext context) {
    final b = widget.eintrag.beschreibung!;
    final theme = Theme.of(context);
    final klein = theme.textTheme.bodySmall;
    return PopScope(
      canPop: false,
      child: NurMaus(
        child: AlertDialog(
          title: const Text('Plugin zulassen'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(b.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  Text('Version ${b.version}'),
                  // „laut Plugin“: Die Angabe steht in der Beschreibungsdatei,
                  // geprüft ist sie nicht.
                  Text('Herkunft laut Plugin: ${b.herkunft}'),
                  const SizedBox(height: 16),
                  if (b.zusatzadressen.isEmpty)
                    const Text('Zusatzadressen: keine.')
                  else ...[
                    Text('Zusatzadressen', style: theme.textTheme.titleSmall),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(
                        'Diese Seiten Ihrer Moodle-Instanz darf das Plugin über moocp ansprechen, auch wenn '
                        'moocp sie sonst nicht freigibt. Hinter ihnen können Namen von Personen stehen.',
                        style: klein,
                      ),
                    ),
                    for (final z in b.zusatzadressen) _ZusatzadresseZeile(z),
                  ],
                  if (widget.profile.length > 1) ...[
                    const Divider(height: 32),
                    Text('In diesen Moodle-Instanzen einschalten', style: theme.textTheme.titleSmall),
                    for (final profil in widget.profile)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _gewaehlt.contains(profil.kennung),
                        title: Text('${profil.name} (${profil.mcpName})'),
                        onChanged: (an) => setState(
                          () => an == true ? _gewaehlt.add(profil.kennung) : _gewaehlt.remove(profil.kennung),
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: theme.colorScheme.outline),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(pluginVerantwortung),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Ihre Zustimmung gilt nur für genau diese Version und diesen Stand der Dateien. '
                    'Ändert sich etwas daran, fragt moocp neu.',
                    style: klein,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            // Die Knöpfe nehmen erst nach der Wartezeit etwas an (Sperrzeit).
            Sperrzeit(
              builder: (bereit) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(
                    onPressed: bereit ? () => Navigator.pop(context, const PluginAntwort(zugestimmt: false)) : null,
                    child: const Text('Ablehnen'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: bereit
                        ? () => Navigator.pop(context, PluginAntwort(zugestimmt: true, profile: {..._gewaehlt}))
                        : null,
                    child: const Text('Zustimmen'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZusatzadresseZeile extends StatelessWidget {
  const _ZusatzadresseZeile(this.adresse);

  final Zusatzadresse adresse;

  @override
  Widget build(BuildContext context) {
    final farben = Theme.of(context).colorScheme;
    final schreibt = adresse.art == ZugriffsArt.schreiben;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 84,
            padding: const EdgeInsets.symmetric(vertical: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: schreibt ? farben.errorContainer : farben.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              adresse.art.name,
              style: TextStyle(fontWeight: FontWeight.bold, color: schreibt ? farben.onErrorContainer : null),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(adresse.muster.text, style: const TextStyle(fontFamily: 'Consolas')),
                Text(adresse.grund),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Der Schritt beim Start (anmeldung.dart, startBisAnmeldung): Für jedes
/// Plugin, über dessen jetzigen Stand noch nichts entschieden ist, kommt der
/// Dialog „Plugin zulassen“. Die Antwort -- auch eine Ablehnung -- wird
/// gespeichert, damit nicht bei jedem Start gefragt wird; ein Plugin, das nicht
/// lädt, kommt nicht dran. Nichts hier startet ein Plugin.
///
/// [ohneKurzname]: Ist ein Entwicklungs-Plugin mit diesem Kurznamen
/// angehängt, fragt der Schritt nicht nach dem installierten mit demselben
/// Kurznamen; es startet in diesem Lauf ohnehin nicht, und seine Zustimmung
/// bleibt, wie sie ist.
Future<void> pluginSchritt(
  BuildContext context, {
  required Plugins plugins,
  required List<Profil> profile,
  String? ohneKurzname,
}) async {
  for (final stand in plugins.offene) {
    if (!context.mounted) return;
    if (ohneKurzname != null && stand.eintrag.beschreibung?.kurzname == ohneKurzname) continue;
    final antwort = await showDialog<PluginAntwort>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PluginZustimmungDialog(eintrag: stand.eintrag, profile: profile),
    );
    // Ohne Antwort (nicht möglich: der Dialog kennt nur seine zwei Knöpfe)
    // bleibt es bei „noch nicht entschieden“.
    if (antwort == null) continue;
    await plugins.entscheiden(stand.eintrag, zugestimmt: antwort.zugestimmt, profile: antwort.profile);
  }
}

/// Der Dialog „Entwicklungs-Plugin anhängen“ (plugin/entwicklung.dart): Er
/// kommt bei jedem Start mit `--plugin-entwicklung`, bevor die App sich mit
/// dem Plugin verbindet, und tritt an die Stelle von Zustimmung und
/// Prüfsumme. Er nennt Ordner, Port, Name und die Zusatzadressen, sagt, dass
/// ein Programm außerhalb der Installation angehängt wird, und dass ablehnen
/// soll, wer es nicht selbst so gestartet hat. Den Schlüssel nennt er nicht.
/// Rückgabe: true heißt anhängen; die Antwort gilt für diesen Lauf der App
/// und wird nie gespeichert.
///
/// Entschieden wird wie bei einer Freigabe nur mit der Maus und erst nach der
/// Wartezeit ([NurMaus], [Sperrzeit], E4); kein Escape, kein Klick daneben.
class EntwicklungsPluginDialog extends StatelessWidget {
  const EntwicklungsPluginDialog({required this.plugin, super.key});

  final EntwicklungsPlugin plugin;

  @override
  Widget build(BuildContext context) {
    final b = plugin.beschreibung;
    final theme = Theme.of(context);
    final klein = theme.textTheme.bodySmall;
    return PopScope(
      canPop: false,
      child: NurMaus(
        child: AlertDialog(
          title: const Text('Entwicklungs-Plugin anhängen'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'moocp wurde mit $pluginEntwicklungSchalter gestartet und soll ein Plugin anhängen, das schon '
                    'läuft. Das Programm liegt außerhalb der Installation von moocp; welcher Code dahinter läuft, '
                    'kann moocp nicht prüfen.',
                  ),
                  const SizedBox(height: 16),
                  Text(b.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  Text('Version ${b.version}'),
                  Text('Ordner: ${plugin.ordner}'),
                  Text('Port: 127.0.0.1:${plugin.port}'),
                  const SizedBox(height: 16),
                  if (b.zusatzadressen.isEmpty)
                    const Text('Zusatzadressen: keine.')
                  else ...[
                    Text('Zusatzadressen', style: theme.textTheme.titleSmall),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(
                        'Diese Seiten Ihrer Moodle-Instanz darf das Plugin über moocp ansprechen, auch wenn '
                        'moocp sie sonst nicht freigibt. Hinter ihnen können Namen von Personen stehen.',
                        style: klein,
                      ),
                    ),
                    for (final z in b.zusatzadressen) _ZusatzadresseZeile(z),
                  ],
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Hängen Sie das Plugin nur an, wenn Sie es selbst so gestartet haben. Sonst lehnen Sie ab: '
                      'Ein fremdes Programm bekäme hier über moocp Zugriff auf Ihre Moodle-Kurse.',
                      style: TextStyle(color: theme.colorScheme.onErrorContainer, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: theme.colorScheme.outline),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(pluginVerantwortung),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Die Antwort gilt, bis moocp endet, und wird nicht gespeichert; beim nächsten Start fragt moocp '
                    'wieder. Das Plugin ist in jedem Moodle-Profil eingeschaltet.',
                    style: klein,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            // Die Knöpfe nehmen erst nach der Wartezeit etwas an (Sperrzeit).
            Sperrzeit(
              builder: (bereit) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(
                    onPressed: bereit ? () => Navigator.pop(context, false) : null,
                    child: const Text('Ablehnen'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: bereit ? () => Navigator.pop(context, true) : null,
                    child: const Text('Anhängen'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Der Schritt beim Start mit `--plugin-entwicklung` (anmeldung.dart,
/// startBisAnmeldung, an der Stelle der Zustimmung zu Plugins). [vorbereiten]
/// liest Beschreibungsdatei und Schlüssel (plugin/entwicklung.dart,
/// entwicklungVorbereiten); scheitert das, sagt ein Hinweis den Grund, und
/// die App läuft ohne das Plugin. Sonst fragt [EntwicklungsPluginDialog].
/// Liefert das Plugin, wenn die Lehrkraft es anhängen will, sonst null.
/// Nichts davon wird gespeichert, und der Testbetrieb beantwortet nichts.
Future<EntwicklungsPlugin?> entwicklungSchritt(
  BuildContext context, {
  required EntwicklungsPlugin Function() vorbereiten,
  required Protokoll protokoll,
}) async {
  final EntwicklungsPlugin plugin;
  try {
    plugin = vorbereiten();
  } on PluginFehler catch (f) {
    protokoll.eintrag(Art.fehler, 'Entwicklungs-Plugin nicht angehängt: ${f.grund}');
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Entwicklungs-Plugin nicht angehängt'),
          content: SizedBox(
            width: 520,
            child: Text(
              'moocp wurde mit $pluginEntwicklungSchalter gestartet, kann das Plugin aber nicht anhängen: '
              '${f.grund} moocp läuft ohne dieses Plugin.',
            ),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    }
    return null;
  }
  protokoll.eintrag(
    Art.info,
    'Entwicklungs-Plugin angefragt: „${plugin.name}“ aus ${plugin.ordner}, Port ${plugin.port}',
  );
  if (!context.mounted) return null;
  final ja = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => EntwicklungsPluginDialog(plugin: plugin),
  );
  if (ja == true) {
    protokoll.eintrag(Art.info, 'Entwicklungs-Plugin „${plugin.name}“: angenommen, für diesen Lauf');
    return plugin;
  }
  protokoll.eintrag(Art.info, 'Entwicklungs-Plugin „${plugin.name}“: abgelehnt; moocp läuft ohne es');
  return null;
}

/// Was der Dialog „Plugins“ über den Lauf eines zugestimmten Plugins sagt,
/// das gerade nicht läuft, und ob es ein Fehler ist; null, wenn es läuft.
/// Während eines Neustarts nach einem Absturz läuft es nicht und hat keinen
/// Startfehler -- das ist weder „ab dem nächsten Start“ noch ein Ausfall.
({String text, bool fehler})? pluginLaufHinweis(LaufendePlugins laufende, PluginEintrag e) {
  if (laufende.laeuft(e)) return null;
  if (laufende.startetNeu(e)) {
    return (text: 'Das Plugin hat sich unerwartet beendet und wird gerade neu gestartet.', fehler: false);
  }
  return switch (laufende.startfehler(e)) {
    final String grund when laufende.ausgefallen(e) => (
      text: 'Ausgefallen: $grund Es läuft erst nach einem Neustart von moocp wieder.',
      fehler: true,
    ),
    final String grund => (text: 'Nicht gestartet: $grund', fehler: true),
    null => (text: 'Das Plugin läuft ab dem nächsten Start von moocp.', fehler: false),
  };
}

/// Der Dialog „Plugins“ (Einstellungen): je gefundenem Plugin der Stand, mit
/// Profilen, in denen es eingeschaltet ist, wenn es mehrere gibt (E32). Die
/// Zustimmung ändern führt in denselben Dialog wie beim Start; ein Profil ein-
/// oder ausschalten braucht keine neue Zustimmung und gilt für Aufrufe
/// gleich, in der Werkzeugliste eines KI-Werkzeugs ab seiner nächsten
/// Sitzung. Gestartet wird ein Plugin nur beim Start der App: Wer später
/// zustimmt, liest, dass es ab dem nächsten Start läuft.
class PluginsDialog extends StatefulWidget {
  const PluginsDialog({required this.plugins, required this.profile, this.laufende, super.key});

  final Plugins plugins;
  final List<Profil> profile;

  /// Die laufenden Plugins, für ihren Zustand; null, wenn die App keine
  /// startet.
  final LaufendePlugins? laufende;

  @override
  State<PluginsDialog> createState() => _PluginsDialogState();
}

class _PluginsDialogState extends State<PluginsDialog> {
  Future<void> _entscheiden(PluginStand stand) async {
    final antwort = await showDialog<PluginAntwort>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PluginZustimmungDialog(
        eintrag: stand.eintrag,
        profile: widget.profile,
        vorgewaehlt: stand.zustand == PluginZustand.zugestimmt ? stand.profile : null,
      ),
    );
    if (antwort == null) return;
    await widget.plugins.entscheiden(stand.eintrag, zugestimmt: antwort.zugestimmt, profile: antwort.profile);
    if (mounted) setState(() {});
  }

  Future<void> _schalten(PluginStand stand, Profil profil, bool an) async {
    await widget.plugins.profilSchalten(stand.eintrag, profil.kennung, an);
    if (mounted) setState(() {});
  }

  Future<void> _updateSchalten(PluginEintrag e, bool an) async {
    await widget.plugins.updateSchalten(e, an);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final klein = theme.textTheme.bodySmall;
    final mehrere = widget.profile.length > 1;
    Widget karte(PluginStand s) {
      final e = s.eintrag;
      final (zustand, farbe) = switch (s.zustand) {
        PluginZustand.zugestimmt => ('Zugestimmt', null),
        PluginZustand.abgelehnt => ('Abgelehnt', null),
        PluginZustand.offen => ('Noch nicht entschieden', theme.colorScheme.error),
        PluginZustand.nichtGeladen => ('Wird nicht geladen', theme.colorScheme.error),
      };
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(e.anzeigename, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Text(zustand, style: TextStyle(fontWeight: FontWeight.bold, color: farbe)),
              ],
            ),
            if (e.beschreibung != null) ...[
              Text('Version ${e.beschreibung!.version}', style: klein),
              Text('Herkunft laut Plugin: ${e.beschreibung!.herkunft}', style: klein),
            ],
            Text('Ordner: ${e.ordner}', style: klein),
            const SizedBox(height: 4),
            if (s.zustand == PluginZustand.zugestimmt && widget.laufende != null)
              if (pluginLaufHinweis(widget.laufende!, e) case final h?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(h.text, style: h.fehler ? TextStyle(color: theme.colorScheme.error) : klein),
                ),
            // Werkzeuge, deren Name mit einem langen Profilnamen davor zu lang
            // wäre, fehlen in diesem Profil (laufende_plugins.dart).
            for (final h in widget.laufende?.zuLangeWerkzeuge(e, widget.profile) ?? const <String>[])
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(h, style: TextStyle(color: theme.colorScheme.error)),
              ),
            switch (s.zustand) {
              PluginZustand.nichtGeladen => Text(e.fehler!, style: TextStyle(color: theme.colorScheme.error)),
              PluginZustand.abgelehnt => Text('moocp nutzt dieses Plugin nicht.', style: klein),
              PluginZustand.offen => Text('Über diesen Stand haben Sie noch nicht entschieden.', style: klein),
              PluginZustand.zugestimmt when !mehrere => Text('Eingeschaltet.', style: klein),
              PluginZustand.zugestimmt => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Eingeschaltet in:', style: klein),
                    for (final profil in widget.profile)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: s.profile.contains(profil.kennung),
                        title: Text('${profil.name} (${profil.mcpName})'),
                        onChanged: (an) => _schalten(s, profil, an == true),
                      ),
                  ],
                ),
            },
            if (e.beschreibung?.updateQuellen.isNotEmpty ?? false)
              CheckboxListTile(
                key: Key('plugin-update-${e.ordner}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: widget.plugins.updateEingeschaltet(e),
                onChanged: (an) => _updateSchalten(e, an == true),
                title: const Text('Bei der täglichen Suche auch nach Updates dieses Plugins sehen'),
                subtitle: Text(
                  'Nur wenn moocp täglich nach Updates sucht (Einstellungen, „Updates“), und nur, solange Sie dem '
                  'Plugin zugestimmt haben. Gefragt wird bei GitHub: ${e.beschreibung!.updateQuellen.join(', ')}.',
                  style: klein,
                ),
              ),
            if (e.ladbar)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton(
                  onPressed: () => _entscheiden(s),
                  child: Text(s.zustand == PluginZustand.offen ? 'Entscheiden …' : 'Zustimmung ändern …'),
                ),
              ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: const Text('Plugins'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final s in widget.plugins.staende) karte(s)],
          ),
        ),
      ),
      actions: [
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Schließen')),
      ],
    );
  }
}
