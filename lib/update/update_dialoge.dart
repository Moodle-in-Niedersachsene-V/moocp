// Die Oberfläche der Update-Prüfung: die Frage beim ersten Start, die
// Anzeige während der Prüfung und das Angebot mit dem Download -- für moocp
// und, mit denselben Dialogen, für Plugins (PluginPruefDialogeUi, dazu der
// Dialog, wenn die Schnittstelle eines Plugins nicht passt).
//
// Beim Start läuft das vor allem anderen (main.dart, _starten): Ein Update
// ersetzt auch die Skills, und würde die App vorher einrichten, installierte
// sie die Version, die gleich überschrieben wird (E13). Weil der MCP-Server
// zuletzt startet, reißt ein Update zu diesem Zeitpunkt auch keiner
// Sitzung eines KI-Werkzeugs die Verbindung ab.
//
// Die Anzeige „Prüfe auf Updates" erscheint erst nach einer kurzen Weile:
// Bei flottem Netz ist die Prüfung vorher durch, und niemand soll bei jedem
// Start ein Fenster aufblitzen sehen.

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../einstellungen.dart';
import '../plugin/plugin_update.dart';
import '../plugin/plugins.dart';
import '../plugin/schnittstelle.dart';
import '../protokoll.dart';
import 'update.dart';

/// Wie lange die Prüfung dauern darf, bevor die App sie anzeigt.
const Duration _anzeigeAb = Duration(milliseconds: 800);

/// Fragen (einmalig), prüfen und anbieten. Rückgabe: true, wenn ein
/// Installer gestartet wurde -- dann beendet der Aufrufer die App.
///
/// [manuell] ist der Weg über „Jetzt nach Updates suchen" in den
/// Einstellungen: Dann sagt die App auch, wenn es nichts Neues gibt oder
/// die Abfrage scheitert. Beim Start bleibt beides still im Protokoll --
/// wer die App öffnet, will arbeiten, nicht von GitHub hören.
Future<bool> updateSchritt(
  BuildContext context, {
  required Einstellungen einstellungen,
  required Protokoll protokoll,
  required String eigene,
  bool manuell = false,
  bool sitzungLaeuft = false,
}) async {
  if (einstellungen.updatePruefen == null) {
    final ja = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const UpdateFrageDialog(),
    );
    einstellungen.updatePruefen = ja == true;
    await _speichern(einstellungen, protokoll);
    protokoll.eintrag(
        Art.info,
        ja == true
            ? 'Update-Prüfung eingeschaltet: einmal täglich bei GitHub'
            : 'Update-Prüfung ausgeschaltet: keine Anfrage an GitHub');
  }
  // „Jetzt nach Updates suchen" ist für sich eine Zustimmung: Es sucht
  // auch, wenn die tägliche Suche aus ist, aber nur dieses eine Mal.
  if (!manuell && einstellungen.updatePruefen != true) return false;
  final jetzt = DateTime.now();
  if (!manuell && heuteSchonGeprueft(einstellungen, jetzt)) return false;
  einstellungen.updateZuletzt = tagesdatum(jetzt);
  await _speichern(einstellungen, protokoll);

  final update = Update(protokoll);
  NeueVersion? neu;
  String? fehler;
  var abgebrochen = false;
  var adressenWeg = false;
  BuildContext? anzeige;
  final uhr = Timer(_anzeigeAb, () {
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) {
        anzeige = c;
        return _PruefAnzeige(update.abbrechen);
      },
    );
  });
  try {
    neu = await update.pruefen(eigene);
  } on UpdateAbgebrochen {
    abgebrochen = true;
    protokoll.eintrag(Art.info, 'Update: Prüfung abgebrochen');
  } on UpdateAdressenWeg catch (e) {
    adressenWeg = true;
    protokoll.eintrag(Art.fehler, 'Update: ${e.meldung}');
  } on UpdateFehler catch (e) {
    fehler = e.meldung;
    protokoll.eintrag(Art.info, 'Update: Prüfung nicht möglich -- ${e.meldung}');
  } finally {
    uhr.cancel();
    final offen = anzeige;
    if (offen != null && offen.mounted) Navigator.of(offen).pop();
  }
  if (!context.mounted || abgebrochen) return false;

  // Anders als eine gescheiterte Abfrage auch beim Start sichtbar: Von selbst
  // käme niemand darauf, dass keine Updates mehr ankommen. Dass die Warnung
  // höchstens einmal am Tag kommt, regelt heuteSchonGeprueft oben.
  if (adressenWeg) {
    await showDialog<void>(context: context, builder: (_) => const UpdateAdressenWegDialog());
    return false;
  }

  if (neu == null) {
    if (manuell) {
      await _melden(context, fehler ?? 'moocp $eigene ist die neueste Version.');
    }
    return false;
  }
  final los = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AngebotDialog(
      neu: neu!,
      titel: 'Version ${neu.version} ist verfügbar',
      einleitung: 'Sie verwenden moocp $eigene.',
      hinweis: 'Der Installer wird von GitHub geladen und läuft sichtbar ab. moocp schließt '
          'sich dafür und startet danach wieder. Einstellungen, gespeicherte Anmeldedaten '
          'und die Einrichtung der KI-Werkzeuge bleiben erhalten.',
      update: update,
      protokoll: protokoll,
      sitzungLaeuft: sitzungLaeuft,
      installieren: (datei) => updateInstallerStarten(datei, neu!.version, einstellungen, protokoll),
    ),
  );
  // „Jetzt nicht" schreibt die App nicht weiter auf -- ins Protokoll gehört
  // es trotzdem: Es war ein Angebot da, und es wurde abgelehnt. Morgen
  // kommt es wieder.
  if (los != true) {
    protokoll.eintrag(Art.info, 'Update: Version ${neu.version} jetzt nicht installiert');
  }
  return los == true;
}

Future<void> _speichern(Einstellungen e, Protokoll protokoll) async {
  try {
    await e.speichern();
  } catch (x) {
    protokoll.eintrag(Art.fehler, 'Einstellungen nicht gespeichert (${x.runtimeType})');
  }
}

Future<void> _melden(BuildContext context, String text) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nach Updates gesucht'),
        content: SizedBox(width: 420, child: Text(text)),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Schließen'))],
      ),
    );

/// Die Warnung, wenn keine der hinterlegten Update-Adressen mehr taugt.
class UpdateAdressenWegDialog extends StatelessWidget {
  const UpdateAdressenWegDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Automatische Updates sind anscheinend nicht mehr möglich.'),
      content: const SizedBox(
        width: 520,
        child: Text('Die hinterlegten Update-Adressen bei GitHub gibt es nicht mehr. moocp '
            'funktioniert weiter, findet aber keine neuen Versionen. Bitte besorgen Sie sich '
            'die aktuelle Version manuell.'),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Schließen'))],
    );
  }
}

/// Die Frage beim ersten Start. Sie steht vor jeder Anfrage: Ohne
/// ausdrückliches Ja nimmt die App keinen Kontakt zu GitHub auf.
class UpdateFrageDialog extends StatelessWidget {
  const UpdateFrageDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Automatisch nach Updates suchen?'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('moocp kann einmal täglich bei GitHub nachsehen, ob es eine neue Version '
              'gibt, und sie auf Wunsch gleich installieren.'),
          const SizedBox(height: 12),
          const Text('Dazu fragt die App bei GitHub nur nach dem neuesten Release von moocp und der '
              'Plugins, denen Sie zugestimmt haben. '
              'GitHub erfährt dabei Ihre IP-Adresse und den Zeitpunkt. Nichts aus Moodle wird übertragen, '
              'kein Benutzername, kein Passwort: Die Prüfung hat ihre eigene Verbindung, ohne '
              'Ihre Moodle-Sitzung.'),
          const SizedBox(height: 12),
          Text(
              'Ohne Prüfung bleibt alles, wie es ist; neue Versionen finden Sie dann selbst '
              'unter „Releases" im Repository. Ändern können Sie das jederzeit in den '
              'Einstellungen.',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Nicht suchen')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Täglich suchen')),
      ],
    );
  }
}

class _PruefAnzeige extends StatelessWidget {
  const _PruefAnzeige(this.abbrechen);
  final void Function() abbrechen;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Prüfe auf Updates'),
      content: const SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('moocp fragt bei GitHub nach der neuesten Version.'),
          SizedBox(height: 16),
          LinearProgressIndicator(),
        ]),
      ),
      actions: [TextButton(onPressed: abbrechen, child: const Text('Abbrechen'))],
    );
  }
}

/// Das Angebot und, nach dem Ja, der Download. Beides in einem Dialog: Wer
/// „Herunterladen und installieren" wählt, soll nicht noch einmal gefragt
/// werden. Derselbe Dialog für moocp und für Plugins; was nach dem Download
/// geschieht, sagt [installieren] (bei moocp: Installer starten, die App
/// beendet sich; bei einem Plugin: Installer ausführen und warten).
class _AngebotDialog extends StatefulWidget {
  const _AngebotDialog({
    required this.neu,
    required this.titel,
    required this.einleitung,
    required this.hinweis,
    required this.update,
    required this.protokoll,
    required this.installieren,
    this.sitzungLaeuft = false,
    this.installerLaeuft,
  });

  final NeueVersion neu;
  final String titel;
  final String einleitung;

  /// Was beim Installieren geschieht, für die Lehrkraft.
  final String hinweis;
  final Update update;
  final Protokoll protokoll;
  final bool sitzungLaeuft;
  final Future<void> Function(File datei) installieren;

  /// Der Text, solange [installieren] läuft; null: kein eigener Zustand (bei
  /// moocp schließt sich der Dialog gleich nach dem Start des Installers).
  final String? installerLaeuft;

  @override
  State<_AngebotDialog> createState() => _AngebotDialogState();
}

class _AngebotDialogState extends State<_AngebotDialog> {
  bool _laedt = false;
  bool _installiert = false;
  int _geladen = 0;
  int? _gesamt;
  String? _fehler;

  /// Für den Kasten mit den Änderungen: Der Text eines Releases kann lang
  /// sein, und ohne sichtbaren Balken sieht niemand, dass darunter noch
  /// etwas steht.
  final _rollen = ScrollController();

  @override
  void dispose() {
    _rollen.dispose();
    super.dispose();
  }

  double? get _anteil {
    final g = _gesamt;
    if (g == null || g <= 0) return null;
    return (_geladen / g).clamp(0.0, 1.0);
  }

  Future<void> _holenUndStarten() async {
    setState(() {
      _laedt = true;
      _fehler = null;
    });
    try {
      final datei = await widget.update.herunterladen(widget.neu, (geladen, gesamt) {
        if (!mounted) return;
        setState(() {
          _geladen = geladen;
          _gesamt = gesamt;
        });
      });
      if (mounted) setState(() => _installiert = true);
      await widget.installieren(datei);
      if (mounted) Navigator.pop(context, true);
    } on UpdateAbgebrochen {
      widget.protokoll.eintrag(Art.info, '${widget.update.protokollName}: Download abgebrochen');
      if (mounted) Navigator.pop(context, false);
    } on UpdateFehler catch (e) {
      if (mounted) {
        setState(() {
          _laedt = false;
          _installiert = false;
          _fehler = e.meldung;
        });
      }
    } catch (e) {
      widget.protokoll.eintrag(
          Art.fehler, '${widget.update.protokollName}: Installer nicht gestartet (${e.runtimeType})');
      if (mounted) {
        setState(() {
          _laedt = false;
          _installiert = false;
          _fehler = 'Der Installer ließ sich nicht starten (${e.runtimeType}).';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final klein = Theme.of(context).textTheme.bodySmall;
    final text = widget.neu.beschreibung;
    return AlertDialog(
      title: Text(widget.titel),
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.einleitung),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Was sich ändert:', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: Scrollbar(
                controller: _rollen,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _rollen,
                  // Platz für den Balken, sonst liegt er auf dem Text.
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(text, style: klein),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(widget.hinweis, style: klein),
          if (widget.sitzungLaeuft) ...[
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline, size: 18),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                      'Eine laufende Sitzung im KI-Werkzeug verliert dabei die Verbindung zur App und '
                      'muss neu gestartet werden.',
                      style: klein)),
            ]),
          ],
          if (_fehler != null) ...[
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.error_outline, size: 18, color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 8),
              Expanded(child: Text(_fehler!)),
            ]),
          ],
          if (_installiert && widget.installerLaeuft != null) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 4),
            Text(widget.installerLaeuft!, style: klein),
          ] else if (_laedt) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _anteil),
            const SizedBox(height: 4),
            Text(
                _anteil == null
                    ? 'Lädt … ${(_geladen / (1024 * 1024)).toStringAsFixed(1)} MB'
                    : 'Lädt … ${(_anteil! * 100).round()} %',
                style: klein),
          ],
        ]),
      ),
      // Ein laufender Installer lässt sich von hier nicht abbrechen; der
      // Dialog wartet ohne Knopf, bis er fertig ist.
      actions: _installiert && widget.installerLaeuft != null
          ? const []
          : _laedt
          ? [TextButton(onPressed: widget.update.abbrechen, child: const Text('Abbrechen'))]
          : [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Jetzt nicht')),
              FilledButton(
                onPressed: _holenUndStarten,
                child: Text(_fehler == null ? 'Herunterladen und installieren' : 'Nochmal versuchen'),
              ),
            ],
    );
  }
}

/// Die Dialoge der Prüfung der Plugins beim Start (plugin/plugin_update.dart,
/// pluginsPruefen): Schnittstelle passt nicht, Angebot eines Updates samt
/// Installer, keine Update-Adresse mehr. Sie stehen hier neben denen von
/// moocp, weil sie dieselben sind, nur mit dem Plugin im Titel.
class PluginPruefDialogeUi implements PluginPruefDialoge {
  PluginPruefDialogeUi(
    this.context, {
    required this.einstellungen,
    required this.protokoll,
    required this.eigene,
    this.starter,
  });

  final BuildContext context;
  final Einstellungen einstellungen;
  final Protokoll protokoll;

  /// Die Version von moocp, für die Suche nach einem Update von moocp.
  final String eigene;

  /// Startet den Installer eines Plugins; null: der echte Prozess. Nur Tests
  /// setzen es.
  final InstallerStarter? starter;

  @override
  Future<bool> schnittstelle(PluginEintrag e, {bool moocpUpdate = false, PluginUpdatePruefung? pruefung}) async {
    if (!context.mounted) return false;
    final ja = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PluginSchnittstelleDialog(eintrag: e, moocpUpdate: moocpUpdate, pruefung: pruefung),
    );
    return ja == true;
  }

  @override
  Future<bool> moocpAktualisieren() async {
    if (!context.mounted) return false;
    // Wie „Jetzt nach Updates suchen“: Der Klick ist das Ja zu genau dieser
    // einen Suche.
    return updateSchritt(context, einstellungen: einstellungen, protokoll: protokoll, eigene: eigene, manuell: true);
  }

  @override
  Future<bool> angebot(PluginUpdatePruefung p) async {
    final neu = p.neu;
    final b = p.eintrag.beschreibung;
    if (neu == null || b == null || !context.mounted) return false;
    final los = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AngebotDialog(
        neu: neu,
        titel: 'Plugin „${b.name}“: Version ${neu.version} ist verfügbar',
        einleitung: 'Sie verwenden das Plugin „${b.name}“ in Version ${b.version}.',
        hinweis: 'Der Installer des Plugins wird von GitHub geladen und läuft sichtbar ab; moocp wartet, '
            'bis er fertig ist. Danach fragt moocp, ob Sie dem neuen Stand des Plugins zustimmen.',
        installerLaeuft: 'Der Installer des Plugins läuft. moocp wartet, bis er fertig ist.',
        update: p.update,
        protokoll: protokoll,
        installieren: (datei) => pluginInstallerAusfuehren(datei, b, neu.version, protokoll, starter: starter),
      ),
    );
    if (los != true) {
      protokoll.eintrag(Art.info, '${pluginUpdateName(b)}: Version ${neu.version} jetzt nicht installiert');
    }
    return los == true;
  }

  @override
  Future<void> adressenWeg(PluginUpdatePruefung p) async {
    final b = p.eintrag.beschreibung;
    if (b == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(pluginUpdateNichtMoeglich(b, 'keine Update-Adresse mehr')),
        content: SizedBox(
          width: 520,
          child: Text('${p.fehler ?? ''} Das Plugin funktioniert in seiner jetzigen Version weiter, '
              'moocp findet aber keine neuen Versionen. Bitte wenden Sie sich an den Autor des Plugins.'),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Schließen'))],
      ),
    );
  }
}

/// Der Dialog, wenn die Schnittstellenversion eines Plugins nicht passt: welche
/// Seite zu alt ist, dass das Plugin ausbleibt, und, wenn es eines gibt, das
/// Angebot eines Updates dieser Seite. Rückgabe: true, wenn die Lehrkraft das
/// Update will.
class PluginSchnittstelleDialog extends StatelessWidget {
  const PluginSchnittstelleDialog({required this.eintrag, this.moocpUpdate = false, this.pruefung, super.key});

  final PluginEintrag eintrag;
  final bool moocpUpdate;
  final PluginUpdatePruefung? pruefung;

  @override
  Widget build(BuildContext context) {
    final klein = Theme.of(context).textTheme.bodySmall;
    final neu = pruefung?.neu;
    final (String folge, String? knopf) = switch (eintrag.unpassend) {
      SchnittstellenUrteil.moocpZuAlt when moocpUpdate => (
          'Ein Update von moocp kann das beheben.',
          'Nach einem Update von moocp suchen',
        ),
      SchnittstellenUrteil.moocpZuAlt => ('Ein Update von moocp kann das beheben; diese Version von moocp '
            'sucht aber nicht selbst danach. Eine neue Version finden Sie unter „Releases“ im Repository.', null),
      _ when neu != null => (
          'Für das Plugin gibt es Version ${neu.version}; ein Update kann das beheben.',
          'Update des Plugins ansehen …',
        ),
      _ when pruefung?.fehler != null => (
          'Ein Update des Plugins kann das beheben, moocp konnte aber nicht danach suchen '
              '(${pruefung!.fehler}). Wenden Sie sich an den Autor des Plugins.',
          null,
        ),
      _ => (
          'Ein Update des Plugins kann das beheben; moocp kennt keine neuere Version. '
              'Wenden Sie sich an den Autor des Plugins.',
          null,
        ),
    };
    return AlertDialog(
      title: Text('Plugin „${eintrag.anzeigename}“ bleibt aus'),
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(eintrag.fehler ?? ''),
          const SizedBox(height: 12),
          Text(folge),
          const SizedBox(height: 12),
          Text('Ohne Update startet moocp das Plugin nicht und läuft ohne es weiter.', style: klein),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Ohne das Plugin weiter')),
        if (knopf != null) FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(knopf)),
      ],
    );
  }
}
