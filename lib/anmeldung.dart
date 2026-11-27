import 'dart:io';

import 'anmeldedaten.dart';
import 'freigabe.dart';
import 'mcp/kanal.dart';
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

/// Die Schritte des Starts bis zur Anmeldung in fester Reihenfolge (E13, E35):
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
///    mitbringen, die die Einrichtung behandelt.
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

/// Der letzte Schritt des Starts (E13, E31): Der MCP-Server eines Profils
/// startet erst, wenn die App eingerichtet ist ([eingerichtet]) und dieses
/// Profil angemeldet ist – ohne Ausnahme, auch wenn dort ein Plugin
/// eingeschaltet ist. Aufgerufen nach jeder Anmeldung (main.dart,
/// _mcpStarten); ein Server, der schon läuft, bleibt, wie er ist. Danach
/// bleibt er an, auch nach „Abmelden“: Ein Stopp risse laufenden Sitzungen
/// der KI-Werkzeuge die Verbindung ab; die Werkzeuge melden dann „Nicht
/// angemeldet“. Ein Server, der nicht startet, steht mit dem Typ des Fehlers
/// in [protokoll] und hält die übrigen nicht auf.
Future<void> mcpServerStarten(
  List<Instanz> instanzen, {
  required bool eingerichtet,
  required Protokoll protokoll,
}) async {
  if (!eingerichtet) return;
  for (final i in instanzen) {
    if (!i.moodle.angemeldet || i.dienst.laeuft) continue;
    try {
      await i.dienst.starten();
    } catch (e) {
      protokoll.eintrag(
        Art.fehler,
        'MCP-Server (${i.dienst.profil.name}) startet nicht: '
        // Die Meldungen des Kanals nennen nie einen Pfad (kanal.dart).
        '${e is KanalFehler ? e.text : e.runtimeType}',
      );
    }
  }
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

/// Meldet beim Start die Profile an, die nicht das sichtbare sind ([sichtbar]
/// meldet main.dart selbst an, mit den Feldern im Fenster): jedes mit Haken und
/// gespeicherten Anmeldedaten (E7, E32). Sonst wären sie erst erreichbar,
/// nachdem die Lehrkraft jedes einmal ausgewählt hat, und ihr MCP-Server
/// fehlte bis dahin. Es gelten dieselben Grenzen wie für das sichtbare Profil:
/// ein Versuch je Profil; lehnt Moodle das Passwort ab, wird es verworfen
/// ([passwortVerwerfen]), damit kein weiterer Start damit anmeldet; war Moodle
/// nicht erreichbar, bleibt es gespeichert. Ein Profil ohne Adresse, mit
/// Testzugang oder schon angemeldet bleibt, wie es ist. Ein Fehler steht mit
/// seiner Art im Protokoll des Profils, nie mit seinem Text, und hält die
/// übrigen Profile nicht auf. Den MCP-Server startet danach der Aufrufer.
Future<void> weitereProfileAnmelden(
  List<Instanz> instanzen, {
  required Instanz sichtbar,
  Future<Anmeldedaten> Function(Profil profil)? laden,
  Future<void> Function(Profil profil)? passwortVerwerfen,
  Future<void> Function(Instanz instanz, String adresse, String benutzer, String passwort)? anmelden,
}) async {
  laden ??= (p) => Anmeldedaten.laden(kennung: p.kennung, adresse: p.adresse);
  passwortVerwerfen ??= (p) => Anmeldedaten.passwortVerwerfen(kennung: p.kennung, adresse: p.adresse);
  anmelden ??= (i, adresse, benutzer, passwort) => i.moodle.anmelden(adresse, benutzer, passwort);
  for (final instanz in instanzen) {
    final profil = instanz.dienst.profil;
    if (identical(instanz, sichtbar) || instanz.moodle.angemeldet) continue;
    if (profil.adresse.isEmpty || Testzugang.fuer(profil) != null) continue;
    final protokoll = instanz.dienst.protokoll;
    final Anmeldedaten d;
    try {
      d = await laden(profil);
    } catch (e) {
      protokoll.eintrag(Art.fehler, 'Anmeldedaten: Speicher nicht erreichbar (${e.runtimeType})');
      continue;
    }
    if (!d.merken || d.benutzer == null) continue;
    if (d.passwort == null) {
      protokoll.eintrag(
        Art.anmeldung,
        d.herkunftHinweis != null
            ? 'Gespeichertes Passwort nicht verwendet: Adresse passt nicht zur gespeicherten Herkunft -- bitte in der App anmelden'
            : d.speicherProblem == null
                ? 'Kein gespeichertes Passwort (nicht lesbar oder verworfen) -- bitte in der App anmelden'
                : 'Gespeichertes Passwort nicht gelesen: ${d.speicherProblem}',
      );
      continue;
    }
    protokoll.eintrag(Art.anmeldung, 'Melde mit gespeicherten Anmeldedaten an');
    try {
      await anmelden(instanz, profil.adresse, d.benutzer!, d.passwort!);
    } on MoodleNichtErreichbar {
      protokoll.eintrag(Art.fehler, 'Anmeldung beim Start: Moodle nicht erreichbar -- im Profil „Anmelden“ versucht es erneut');
    } on MoodleAnmeldungAbgelehnt {
      try {
        await passwortVerwerfen(profil);
        protokoll.eintrag(
          Art.anmeldung,
          'Gespeichertes Passwort verworfen: Moodle hat es abgelehnt -- kein weiterer Versuch damit',
        );
      } catch (e) {
        protokoll.eintrag(
          Art.fehler,
          'Gespeichertes Passwort nicht verworfen: Speicher nicht erreichbar (${e.runtimeType})',
        );
      }
    } catch (e) {
      protokoll.eintrag(Art.fehler, 'Anmeldung beim Start fehlgeschlagen (${e.runtimeType})');
    }
  }
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
        KanalFehler() || SocketException() => 'MCP-Kanal nicht verfügbar; ${e is KanalFehler ? e.text : 'Ordner des Kanals prüfen'}',
        _ => 'Startvoraussetzung fehlgeschlagen (${e.runtimeType})',
      };
      protokoll.eintrag(Art.fehler, 'Testprofil „${profil.name}“ nicht bereit: $grund');
    }
  }
}
