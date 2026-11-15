// Schnittstelle und Updates der Plugins beim Start (E35, E19): nach dem
// Update von moocp und vor der Zustimmung (anmeldung.dart, startBisAnmeldung).
//
// Für jedes Plugin, je für sich:
//
//  1. Passt die Schnittstellenversion nicht (schnittstelle.dart), sagt ein
//     Dialog, welche Seite zu alt ist, und bietet deren Update an: von moocp,
//     wenn moocp zu alt ist, vom Plugin, wenn das Plugin zu alt ist. Ohne
//     Update bleibt das Plugin aus; die App läuft ohne es weiter. Ohne
//     Angebot eines Updates erscheint dieser Dialog einmal je Stand des
//     Plugins (Version, Prüfsumme) und Version der App
//     (Einstellungen.schnittstelleGesehen); danach steht der Grund nur noch
//     im Dialog „Plugins“ und bei jedem Start im Protokoll. Mit einem Angebot
//     erscheint er, wann immer die Suche eines findet.
//  2. Sonst wird nach einem Update des Plugins gesucht, nach denselben Regeln
//     wie für moocp: nur nach dem Ja zur täglichen Suche (dieselbe Einstellung
//     wie für moocp, kein eigenes Ja), nicht auf dem Mac und nicht mit
//     --kein-update (pluginUpdateMoeglich) -- aber auch dort, wo sich moocp
//     nicht selbst ersetzen kann, etwa im Entwicklerbau --,
//     höchstens einmal am Tag je Plugin, und nur für ein Plugin, dessen
//     jetzigem Stand die Lehrkraft zugestimmt hat. Die Repositorys stehen in
//     seiner Beschreibungsdatei, und die zählt erst mit der Zustimmung: Ein
//     Plugin, das niemand angenommen hat, bringt die App nicht dazu, irgendwo
//     anzufragen. Die Lehrkraft kann die Suche je Plugin abschalten (Dialog
//     „Plugins“, Plugins.updateSchalten).
//
// Gesucht wird mit der Prüfung von moocp (update.dart), nur mit den
// Repositorys des Plugins als Herkünften: dieselbe Positivliste
// (updateliste.dart), dieselbe eigene Verbindung ohne Sitzung, jede Anfrage
// im Protokoll; ein späteres Repository nur, wenn das frühere kein Release
// hat. Erwartet wird im Release der Installer `<kurzname>_setup_<Version>.exe`.
// Er läuft sichtbar und erst nach dem ausdrücklichen Ja der Lehrkraft; die App
// wartet, bis er fertig ist, und liest die Plugins danach neu. Der neue Stand
// hat eine andere Version und Prüfsumme, also fragt die Zustimmung neu
// (entscheidung.dart) -- das ist kein eigener Mechanismus, sondern die Regel,
// dass eine Zustimmung nur für genau einen Stand gilt.
//
// Ein Fehler hält nichts auf: weder das Update von moocp, das schon vorher
// lief, noch ein anderes Plugin. Er steht als „Plugin „X“: Update nicht
// möglich (Grund)“ im Protokoll. Wie bei moocp bleibt Vorübergehendes (Netz,
// Proxy, 403, 429, Serverfehler) still; nur wenn GitHub für jedes Repository
// des Plugins sagt, dass es dort nichts mehr gibt, sagt es auch ein Dialog --
// von selbst käme niemand darauf, dass dieses Plugin keine Updates mehr
// bekommt.
//
// Ein Entwicklungs-Plugin (entwicklung.dart) steht nicht in [Plugins] und wird
// hier nie gesucht; seine Schnittstelle prüft entwicklungVorbereiten.
//
// Ein MCP-Werkzeug dafür gibt es nicht (E19): Updates sind Sache der
// Lehrkraft. Diese Datei wird von nichts unter lib/mcp eingebunden.

import 'dart:async';
import 'dart:io';

import '../einstellungen.dart';
import '../protokoll.dart';
import '../update/update.dart';
import 'beschreibung.dart';
import 'entscheidung.dart';
import 'plugins.dart';
import 'schnittstelle.dart';

/// Der Anfang des Dateinamens, unter dem der Installer eines Plugins im
/// Release liegt: `<kurzname>_setup_<Version>.exe` ([installerName]).
String pluginInstallerAnfang(String kurzname) => '${kurzname}_setup';

/// Womit jede Zeile der Update-Prüfung eines Plugins im Protokoll beginnt.
String pluginUpdateName(PluginBeschreibung b) => 'Plugin „${b.name}“, Update';

/// Die Prüfung für ein Plugin: die Prüfung von moocp mit den Repositorys aus
/// seiner Beschreibungsdatei, seinem Installernamen und eigenen Dateinamen im
/// Temp-Verzeichnis.
Update pluginUpdate(PluginBeschreibung b, Protokoll protokoll) => Update(
      protokoll,
      quellen: b.updateQuellen,
      installerAnfang: pluginInstallerAnfang(b.kurzname),
      dateiPraefix: '${pluginDateiPraefix}_${b.kurzname}_update',
      protokollName: pluginUpdateName(b),
    );

/// Ob nach Updates von Plugins gesucht werden darf: unter Windows und ohne
/// `--kein-update`. Anders als bei moocp selbst (update.dart, updateMoeglich)
/// zählt nicht, ob die App aus dem Installationsverzeichnis läuft: Der
/// Installer eines Plugins ersetzt das Plugin, nicht die App, also auch im
/// Entwicklerbau. Auf dem Mac nicht: Für Plugins gibt es dort kein
/// Installer-Format (E24). [windows] nur für Tests.
bool pluginUpdateMoeglich(List<String> argumente, {bool? windows}) =>
    (windows ?? Platform.isWindows) && !argumente.contains(keinUpdateSchalter);

/// Warum für [e] jetzt nicht nach einem Update gesucht wird; null: es wird
/// gesucht. [updatefaehig] ist [pluginUpdateMoeglich].
String? pluginUpdateAusgelassen(
  Plugins plugins,
  PluginEintrag e,
  Einstellungen einstellungen, {
  required bool updatefaehig,
  required DateTime jetzt,
}) {
  final b = e.beschreibung;
  if (b == null) return 'Das Plugin wird nicht geladen.';
  if (!updatefaehig) return 'moocp sucht hier keine Updates von Plugins.';
  if (einstellungen.updatePruefen != true) return 'Die tägliche Suche nach Updates ist ausgeschaltet.';
  if (!plugins.zugestimmtFuerStand(e)) return 'Dem jetzigen Stand des Plugins ist nicht zugestimmt.';
  if (b.updateQuellen.isEmpty) return 'Das Plugin nennt keine Update-Quellen.';
  if (!plugins.updateEingeschaltet(e)) return 'Die Suche nach Updates ist für dieses Plugin ausgeschaltet.';
  if (einstellungen.pluginUpdates[e.ordner]?.zuletzt == tagesdatum(jetzt)) return 'Heute schon gesucht.';
  return null;
}

/// Der Stand, zu dem der Dialog „Plugin bleibt aus“ einmal erscheint: Ordner,
/// Version und Prüfsumme des Plugins und Version der App, je in einer Zeile
/// (Einstellungen.schnittstelleGesehen). Ein Update von moocp oder des
/// Plugins ändert ihn.
String schnittstelleStand(PluginEintrag e, String appVersion) =>
    [e.ordner, e.beschreibung?.version ?? '', e.pruefsumme ?? '', appVersion].join('\n');

/// Das Ergebnis der Suche für ein Plugin.
class PluginUpdatePruefung {
  const PluginUpdatePruefung(this.eintrag, this.update, {this.neu, this.fehler, this.adressenWeg = false});

  final PluginEintrag eintrag;

  /// Die Prüfung, mit der gesucht wurde; mit ihr wird auch geladen.
  final Update update;

  /// Eine neuere Version; null, wenn es keine gibt oder die Suche scheiterte.
  final NeueVersion? neu;

  /// Warum die Suche scheiterte, ein Satz für Protokoll und Dialog.
  final String? fehler;

  /// Ob GitHub für jedes Repository des Plugins gesagt hat, dass es dort
  /// nichts mehr gibt (UpdateAdressenWeg); dann zeigt es auch ein Dialog.
  final bool adressenWeg;
}

/// Die Meldung, wenn die Suche für ein Plugin scheitert.
String pluginUpdateNichtMoeglich(PluginBeschreibung b, String grund) =>
    'Plugin „${b.name}“: Update nicht möglich ($grund)';

/// Sucht für [e] nach einem Update, wenn [pluginUpdateAusgelassen] nichts
/// dagegen hat; sonst null. Der Tag der Suche wird vorher gemerkt, auch wenn
/// sie scheitert -- wie bei moocp (update.dart, heuteSchonGeprueft). Wirft
/// nie: Jeder Fehler steht im Ergebnis und im Protokoll.
Future<PluginUpdatePruefung?> pluginUpdatePruefen(
  Plugins plugins,
  PluginEintrag e,
  Einstellungen einstellungen,
  Protokoll protokoll, {
  required bool updatefaehig,
  required DateTime jetzt,
  Update Function(PluginBeschreibung b, Protokoll protokoll) erzeugen = pluginUpdate,
}) async {
  if (pluginUpdateAusgelassen(plugins, e, einstellungen, updatefaehig: updatefaehig, jetzt: jetzt) != null) {
    return null;
  }
  final b = e.beschreibung!;
  final alt = einstellungen.pluginUpdates[e.ordner] ?? const PluginUpdateStand();
  einstellungen.pluginUpdates = {...einstellungen.pluginUpdates, e.ordner: alt.mit(zuletzt: tagesdatum(jetzt))};
  try {
    await einstellungen.speichern();
  } catch (x) {
    protokoll.eintrag(Art.fehler, 'Einstellungen nicht gespeichert (${x.runtimeType})');
  }
  final update = erzeugen(b, protokoll);
  try {
    final neu = await update.pruefen(b.version);
    return PluginUpdatePruefung(e, update, neu: neu);
  } on UpdateAdressenWeg catch (x) {
    protokoll.eintrag(Art.fehler, pluginUpdateNichtMoeglich(b, x.meldung));
    return PluginUpdatePruefung(e, update, fehler: x.meldung, adressenWeg: true);
  } on UpdateFehler catch (x) {
    protokoll.eintrag(Art.info, pluginUpdateNichtMoeglich(b, x.meldung));
    return PluginUpdatePruefung(e, update, fehler: x.meldung);
  } on UpdateAbgebrochen {
    protokoll.eintrag(Art.info, pluginUpdateNichtMoeglich(b, 'abgebrochen'));
    return PluginUpdatePruefung(e, update, fehler: 'Abgebrochen.');
  } catch (x) {
    final grund = 'unerwarteter Fehler (${x.runtimeType})';
    protokoll.eintrag(Art.fehler, pluginUpdateNichtMoeglich(b, grund));
    return PluginUpdatePruefung(e, update, fehler: grund);
  }
}

/// Startet den geladenen Installer eines Plugins sichtbar und wartet, bis er
/// fertig ist. Anders als der von moocp braucht er die App nicht beendet: Das
/// Plugin läuft zu diesem Zeitpunkt noch nicht (die Prüfung steht vor seinem
/// Start), und die App liest die Plugins danach neu. Den Exit-Code nennt das
/// Protokoll; ob das Update angekommen ist, zeigt erst der neue Stand.
Future<int> pluginInstallerAusfuehren(
  File installer,
  PluginBeschreibung b,
  String version,
  Protokoll protokoll, {
  InstallerStarter? starter,
}) async {
  final name = pluginUpdateName(b);
  final prozess = starter == null
      ? await installerStarten(installer, version,
          protokoll: protokoll, protokollName: name, modus: ProcessStartMode.normal)
      : await installerStarten(installer, version,
          protokoll: protokoll, protokollName: name, modus: ProcessStartMode.normal, starter: starter);
  // Was der Installer schreibt, liest niemand; ungelesen könnte es ihn
  // anhalten, sobald der Puffer voll ist.
  unawaited(prozess.stdout.drain<void>().catchError((_) {}));
  unawaited(prozess.stderr.drain<void>().catchError((_) {}));
  final code = await prozess.exitCode;
  protokoll.eintrag(Art.info, '$name: Installer beendet (Exit-Code $code)');
  wegwerfen(installer);
  return code;
}

/// Was die Prüfung beim Start die Lehrkraft fragt; die App zeigt dafür
/// Dialoge (update/update_dialoge.dart, PluginPruefDialogeUi), Tests setzen
/// ein Double ein.
abstract class PluginPruefDialoge {
  /// Die Schnittstelle von [e] passt nicht ([PluginEintrag.unpassend],
  /// [PluginEintrag.fehler] sagt, welche Seite zu alt ist). [moocpUpdate]: Die
  /// App kann nach einem Update von moocp suchen. [pruefung]: das Ergebnis der
  /// Suche nach einem Update des Plugins, null, wenn nicht gesucht wurde.
  /// Rückgabe: true, wenn die Lehrkraft das angebotene Update will.
  Future<bool> schnittstelle(PluginEintrag e, {bool moocpUpdate = false, PluginUpdatePruefung? pruefung});

  /// Sucht nach einem Update von moocp und bietet es an. Rückgabe: true, wenn
  /// sein Installer läuft und die App sich beenden muss.
  Future<bool> moocpAktualisieren();

  /// Bietet das Update [p] des Plugins an, lädt es nach dem Ja und führt den
  /// Installer aus. Rückgabe: true, wenn der Installer gelaufen ist.
  Future<bool> angebot(PluginUpdatePruefung p);

  /// GitHub kennt keines der Repositorys des Plugins mehr.
  Future<void> adressenWeg(PluginUpdatePruefung p);
}

/// Was die Prüfung beim Start ergab.
class PluginPruefErgebnis {
  const PluginPruefErgebnis({this.beenden = false, this.aktualisiert = const {}});

  /// Der Installer von moocp läuft; die App muss sich beenden.
  final bool beenden;

  /// Die Plugin-Ordner, deren Installer gelaufen ist; die App liest die
  /// Plugins danach neu, und die Zustimmung fragt nach dem neuen Stand.
  final Set<String> aktualisiert;
}

/// Prüft jedes Plugin, je für sich, in der Reihenfolge von
/// [Plugins.eintraege]: erst die Schnittstelle, dann das Update. [nur]
/// beschränkt die Prüfung auf diese Plugin-Ordner (nach einem Update eines
/// Plugins: nur die aktualisierten). [moocpUpdateMoeglich]: Die App kann sich
/// selbst aktualisieren und kennt ihre Version. [appVersion] ist die
/// laufende Version der App, für [schnittstelleStand].
Future<PluginPruefErgebnis> pluginsPruefen({
  required Plugins plugins,
  required Einstellungen einstellungen,
  required Protokoll protokoll,
  required bool updatefaehig,
  required bool moocpUpdateMoeglich,
  required String appVersion,
  required PluginPruefDialoge dialoge,
  DateTime Function() uhr = DateTime.now,
  Update Function(PluginBeschreibung b, Protokoll protokoll) erzeugen = pluginUpdate,
  Set<String>? nur,
  bool Function() weiter = _immer,
}) async {
  final aktualisiert = <String>{};
  Future<PluginUpdatePruefung?> suchen(PluginEintrag e) => pluginUpdatePruefen(
        plugins,
        e,
        einstellungen,
        protokoll,
        updatefaehig: updatefaehig,
        jetzt: uhr(),
        erzeugen: erzeugen,
      );

  // Ob der Dialog zur Schnittstelle für diesen Stand schon erschienen ist;
  // [gesehen] merkt ihn, sobald er erschienen ist.
  final stand = {for (final e in plugins.eintraege) e.ordner: schnittstelleStand(e, appVersion)};
  bool schonGesehen(PluginEintrag e) => einstellungen.schnittstelleGesehen.contains(stand[e.ordner]);
  Future<void> gesehen(PluginEintrag e) async {
    final s = stand[e.ordner]!;
    if (einstellungen.schnittstelleGesehen.contains(s)) return;
    final alt = einstellungen.schnittstelleGesehen;
    // Je Plugin nur der letzte Stand: Ein früherer kommt nicht wieder.
    einstellungen.schnittstelleGesehen = {
      for (final x in alt)
        if (!x.startsWith('${e.ordner}\n')) x,
      s,
    };
    try {
      await einstellungen.speichern();
    } catch (x) {
      // Gilt für diesen Lauf; der nächste Start zeigt den Dialog noch einmal.
      protokoll.eintrag(Art.fehler, 'Gesehener Hinweis zu einem Plugin nicht gespeichert (${x.runtimeType})');
    }
  }

  for (final e in plugins.eintraege) {
    if (!weiter()) break;
    if (nur != null && !nur.contains(e.ordner)) continue;
    final b = e.beschreibung;
    if (b == null) continue;
    try {
      switch (e.unpassend) {
        case SchnittstellenUrteil.moocpZuAlt:
          protokoll.eintrag(Art.fehler, 'Plugin „${b.name}“ bleibt aus: ${e.fehler}');
          if (schonGesehen(e)) break;
          final ja = await dialoge.schnittstelle(e, moocpUpdate: moocpUpdateMoeglich);
          await gesehen(e);
          if (ja && moocpUpdateMoeglich) {
            if (await dialoge.moocpAktualisieren()) return PluginPruefErgebnis(beenden: true, aktualisiert: aktualisiert);
          }
        case SchnittstellenUrteil.pluginZuAlt:
          protokoll.eintrag(Art.fehler, 'Plugin „${b.name}“ bleibt aus: ${e.fehler}');
          final p = await suchen(e);
          if (!weiter()) break;
          // Mit einem Angebot erscheint er, wann immer die Suche eines findet.
          if (p?.neu == null && schonGesehen(e)) break;
          final ja = await dialoge.schnittstelle(e, pruefung: p);
          await gesehen(e);
          if (ja && p?.neu != null) {
            if (await dialoge.angebot(p!)) aktualisiert.add(e.ordner);
          }
        case SchnittstellenUrteil.passt:
          // Kommt nicht vor: Ein passendes Plugin hat kein Urteil.
          break;
        case null:
          if (!e.ladbar) continue;
          final p = await suchen(e);
          if (p == null || !weiter()) continue;
          if (p.neu != null) {
            if (await dialoge.angebot(p)) aktualisiert.add(e.ordner);
          } else if (p.adressenWeg) {
            await dialoge.adressenWeg(p);
          }
      }
    } catch (x) {
      // Auch ein Fehler im Dialog oder beim Installer hält kein anderes Plugin
      // auf.
      protokoll.eintrag(Art.fehler, pluginUpdateNichtMoeglich(b, 'unerwarteter Fehler (${x.runtimeType})'));
    }
  }
  return PluginPruefErgebnis(aktualisiert: aktualisiert);
}

bool _immer() => true;
