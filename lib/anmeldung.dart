import 'dart:io';

import 'anmeldedaten.dart';
import 'freigabe.dart';
import 'mcp/mcp_dienst.dart';
import 'moodle/moodle_zugang.dart';
import 'profil.dart';
import 'protokoll.dart';
import 'testschalter.dart';
import 'testzugang.dart';

/// Ein Profil zur Laufzeit: Zugang, Freigaben und MCP-Server (E31).
class Instanz {
  const Instanz(this.moodle, this.freigaben, this.dienst);
  final MoodleZugang moodle;
  final Freigaben freigaben;
  final McpDienst dienst;
}

/// Eingaben einer Anmeldung, festgehalten bevor sie asynchron beginnt.
class AnmeldeAuftrag {
  const AnmeldeAuftrag({
    required this.instanz,
    required this.profil,
    required this.adresse,
    required this.benutzer,
    required this.passwort,
    required this.merken,
  });
  final Instanz instanz;
  final Profil profil;
  final String adresse;
  final String benutzer;
  final String passwort;
  final bool merken;
}

/// Wie der Start bis zur Anmeldung ausgeht.
enum StartAusgang {
  /// Ein Update-Installer läuft: Die App beendet sich.
  beenden,

  /// Es geht nicht weiter: ohne Einrichtung (die App läuft dann nicht) oder
  /// weil die Oberfläche weg ist.
  abgebrochen,

  /// Eingerichtet; der Aufrufer meldet an.
  bereit,
}

/// Die Schritte des Starts vor der Anmeldung in fester Reihenfolge (E13, E35):
///
/// 1. [update] der App. Liefert true, wenn ein Installer läuft; dann endet der
///    Start. Ein Update bringt auch neue Skills, und die Einrichtung soll nicht
///    die Version einrichten, die gleich ersetzt wird.
/// 2. [pluginPruefung]: je Plugin Schnittstelle und Update
///    (plugin/plugin_update.dart), nach dem Update der App, weil eine neue App
///    eine andere Schnittstelle bieten kann, und vor der Zustimmung, damit sie
///    nach einem Update des Plugins gleich dem neuen Stand gilt. Liefert true,
///    wenn der Installer von moocp läuft (ein Plugin verlangte eine neuere
///    Schnittstelle); dann endet der Start.
/// 3. [pluginZustimmung]: die Lehrkraft entscheidet über Plugins, die neu
///    oder geändert sind. Vor der Einrichtung, weil Plugins eigene Skills
///    mitbringen, die die Einrichtung behandelt, und vor der Anmeldung, weil
///    ein Plugin ohne Anmeldung arbeiten kann.
/// 4. [pluginsStarten]: die angenommenen Plugins starten, einmal je App. Vor
///    der Einrichtung und vor dem MCP-Server, damit jede Sitzung ihre
///    Werkzeuge schon vorfindet.
/// 5. [einrichtungUndAnmeldung] ([testprofilVorEinrichtungStarten]): erst die
///    Einrichtung der KI-Werkzeuge, dann die Anmeldung.
///
/// [weiter] sagt vor jedem Schritt nach dem ersten, ob die Oberfläche noch da
/// ist; sonst stünde ein Dialog vor einem Fenster, das nicht mehr besteht.
Future<StartAusgang> startBisAnmeldung({
  required Future<bool> Function() update,
  required Future<bool> Function() pluginPruefung,
  required Future<void> Function() pluginZustimmung,
  required Future<void> Function() pluginsStarten,
  required Future<bool> Function() einrichtungUndAnmeldung,
  required bool Function() weiter,
}) async {
  if (await update()) return StartAusgang.beenden;
  if (!weiter()) return StartAusgang.abgebrochen;
  if (await pluginPruefung()) return StartAusgang.beenden;
  if (!weiter()) return StartAusgang.abgebrochen;
  await pluginZustimmung();
  if (!weiter()) return StartAusgang.abgebrochen;
  await pluginsStarten();
  if (!weiter()) return StartAusgang.abgebrochen;
  return await einrichtungUndAnmeldung() ? StartAusgang.bereit : StartAusgang.abgebrochen;
}

/// Der MCP-Server eines Profils, den der Start vor der Anmeldung starten
/// könnte: [ohneAnmeldung] sagt, ob in diesem Profil ein Plugin mit
/// Werkzeugen ohne Anmeldung eingeschaltet ist und sein Server noch nicht
/// läuft; [starten] startet ihn vor der Anmeldung.
typedef ServerVorAnmeldung = ({bool Function() ohneAnmeldung, Future<void> Function() starten});

/// Der Start nach der Einrichtung (E13, E35): Zuerst startet der MCP-Server
/// jedes Profils, in dem ein Plugin mit Werkzeugen ohne Anmeldung
/// eingeschaltet ist, dann kommt die Anmeldung ([anmelden]), nach der die
/// übrigen Server starten (main.dart, _mcpStarten). Ohne ein solches Plugin
/// bleibt es bei Einrichtung, Anmeldung, Server. Ein Server, der vor der
/// Anmeldung startet, bleibt danach an, wie jeder andere.
Future<void> nachEinrichtung({
  required List<ServerVorAnmeldung> server,
  required Future<void> Function() anmelden,
}) async {
  for (final s in server) {
    if (s.ohneAnmeldung()) await s.starten();
  }
  await anmelden();
}

/// Hält den normalen Start bei der Einrichtung an; nur eine explizite
/// Testprofilbindung darf die Testanmeldung vor dem Einrichtungsdialog starten.
Future<bool> testprofilVorEinrichtungStarten({
  required bool gebunden,
  required Future<void> Function() anmelden,
  required Future<bool> Function() einrichtungPruefen,
}) async {
  if (gebunden) await anmelden();
  if (!await einrichtungPruefen()) return false;
  if (!gebunden) await anmelden();
  return true;
}

/// Gibt gespeicherte Zugangsdaten nur zurück, wenn das Profil nach dem Laden
/// noch ausgewählt ist.
Future<Anmeldedaten?> gespeicherteAnmeldedatenVerwenden({
  required Future<Anmeldedaten> Function() laden,
  required bool Function() zielIstAktiv,
  required void Function(Anmeldedaten) anwenden,
}) async {
  final daten = await laden();
  if (!zielIstAktiv()) return null;
  anwenden(daten);
  return daten;
}

/// Meldet gebundene Debug-Testprofile unabhängig von der sichtbaren Auswahl an.
/// Ohne den Bauschalter des Testbetriebs (testschalter.dart) tut es nichts.
Future<void> testprofileStarten(
  List<Instanz> instanzen,
  Protokoll protokoll,
) async {
  if (!testbetriebAktiv) return;
  for (final instanz in instanzen) {
    final profil = instanz.dienst.profil;
    if (Testzugang.fuer(profil) == null) continue;
    try {
      final daten = await Anmeldedaten.laden(
        kennung: profil.kennung,
        adresse: profil.adresse,
      );
      if (daten.benutzer == null || daten.passwort == null) {
        throw StateError('Gebundener Testzugang fehlt');
      }
      await instanz.moodle.anmelden(
        profil.adresse,
        daten.benutzer!,
        daten.passwort!,
      );
      await instanz.dienst.starten();
      protokoll.eintrag(
        Art.anmeldung,
        'Testprofil „${profil.name}“: Anmeldung und MCP-Server bereit [${profil.kennung}]',
      );
    } catch (e) {
      // Feste Kategorien nennen Voraussetzungen, ohne Dateiinhalte oder Eingaben zu übernehmen.
      final grund = switch (e) {
        FileSystemException() => 'Zugangsdatei fehlt oder ist nicht lesbar; Pfad und Dateirechte prüfen',
        StateError() => 'Zugangsdatei unvollständig; TEACHER_USERNAME und TEACHER_PASSWORD müssen gesetzt sein',
        MoodleNichtErreichbar() => 'Moodle nicht erreichbar; Instanzadresse und Netzwerkzugang prüfen',
        MoodleFehler() => 'Moodle-Anmeldung abgelehnt; Dateizugang und Anmeldemöglichkeit prüfen',
        SocketException() => 'MCP-Port nicht verfügbar; Portbelegung prüfen',
        _ => 'Startvoraussetzung fehlgeschlagen (${e.runtimeType})',
      };
      protokoll.eintrag(Art.fehler, 'Testprofil „${profil.name}“ nicht bereit: $grund');
    }
  }
}
