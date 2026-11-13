// Werkzeugquellen: woher der MCP-Server außer den eingebauten Werkzeugen
// (mcp_dienst.dart) weitere bekommt.
//
// Eine Quelle nennt ihre Werkzeuge mit Name, Beschreibung und fertigem
// JSON-Schema der Eingabe, so wie sie über MCP laufen, und führt einen Aufruf
// aus. Der Server hängt jedes dieser Werkzeuge durch dieselbe Hülle ein wie
// die eingebauten (WerkzeugAufrufe: Protokoll, Abbruch, Fehlerantwort) und
// bricht ab, wenn ein Name zweimal vorkommt.

import 'dart:convert';
import 'dart:math';

import '../freigabe.dart' show Bestaetigungen;
import '../moodle/moodle_zugang.dart' show MoodleZugang;
import '../profil.dart';
import '../protokoll.dart';

/// Ein Werkzeug einer [WerkzeugQuelle], beschrieben wie in der MCP-Werkzeugliste.
class WerkzeugBeschreibung {
  const WerkzeugBeschreibung({
    required this.name,
    required this.beschreibung,
    required this.eingabeSchema,
    this.titel,
    this.nurLesen = false,
    this.zerstoerend = false,
    this.ohneAnmeldung = false,
  });

  /// Der Name, unter dem die KI das Werkzeug aufruft; auf dem Server eindeutig.
  final String name;

  /// Wofür das Werkzeug da ist und was es braucht -- was die KI zur Auswahl liest.
  final String beschreibung;

  /// JSON-Schema der Eingabe (`inputSchema` der MCP-Werkzeugliste). Die Wurzel
  /// ist ein Objekt; `required` darin gilt wie bei den eingebauten Werkzeugen.
  final Map<String, dynamic> eingabeSchema;

  /// Anzeigename für Clients; ohne ihn zeigen sie den Namen.
  final String? titel;

  /// Hinweise für Clients (MCP `readOnlyHint`, `destructiveHint`), von der
  /// Quelle wahrheitsgemäß gesetzt. Ohne Angabe gilt wie bei den eingebauten
  /// Werkzeugen: nicht nur lesend, nicht zerstörend.
  final bool nurLesen;
  final bool zerstoerend;

  /// Ob das Werkzeug ohne Moodle-Anmeldung arbeitet: Das Plugin nennt es in
  /// `ohneAnmeldung` seiner Beschreibungsdatei (plugin/verbindung.dart setzt
  /// es). Nur solche Werkzeuge laufen, solange der MCP-Server vor der
  /// Anmeldung gestartet ist (mcp_dienst.dart). Kein Teil der Werkzeugliste,
  /// die ein Client sieht, und nicht gemerkt: Es kommt jedes Mal aus der
  /// Beschreibungsdatei.
  final bool ohneAnmeldung;

  /// Dieselbe Beschreibung mit [ohneAnmeldung].
  WerkzeugBeschreibung mitOhneAnmeldung(bool ohne) => WerkzeugBeschreibung(
    name: name,
    beschreibung: beschreibung,
    eingabeSchema: eingabeSchema,
    titel: titel,
    nurLesen: nurLesen,
    zerstoerend: zerstoerend,
    ohneAnmeldung: ohne,
  );
}

/// Ein Aufruf eines Werkzeugs einer [WerkzeugQuelle], so wie er über den
/// MCP-Server eines Instanzprofils kam.
class WerkzeugAufruf {
  const WerkzeugAufruf({
    required this.name,
    required this.args,
    required this.profil,
    required this.token,
    required this.abbruch,
    this.kontext,
  });

  /// Das Werkzeug aus der Liste der Quelle.
  final String name;
  final Map<String, dynamic> args;

  /// Das Instanzprofil des Servers, über den der Aufruf kam.
  final Profil profil;

  /// Ein Token nur für diesen Aufruf ([aufrufToken]), zufällig und geheim:
  /// Es geht in kein Protokoll und in keine Antwort.
  final String token;

  /// Erfüllt sich, wenn der Client den Aufruf abbricht (sein Zeitlimit, ein
  /// Abbruch in der Sitzung); sonst nie.
  final Future<void> abbruch;

  /// Was der Server des Profils für diesen Aufruf bereithält, wenn ein Plugin
  /// während des Aufrufs die App nutzt (plugin/app_adresse.dart); null, wenn
  /// der Aufruf nicht über einen MCP-Server kam (Tests).
  final AufrufKontext? kontext;
}

/// Das Ergebnis eines eingebauten Werkzeugs: der Text, den ein KI-Werkzeug
/// bekäme, und ob es ein Werkzeugfehler ist (MCP `isError`).
typedef EingebautErgebnis = ({String text, bool fehlgeschlagen});

/// Wie eine Freigabe ausging, um die ein Plugin gebeten hat
/// ([AufrufKontext.pluginFreigabe]).
enum PluginFreigabeAusgang {
  /// Die Lehrkraft hat freigegeben.
  freigegeben,

  /// Die eingestellte Stufe lässt die Frage aus; das gilt als freigegeben,
  /// und die KI erfährt es wie bei jeder ausgelassenen Freigabe.
  ohneFrage,

  /// Die Lehrkraft hat abgelehnt.
  abgelehnt,

  /// Ohne Entscheidung: Frist abgelaufen, oder der Aufruf ist zu Ende oder
  /// abgebrochen.
  abgebrochen,
}

/// Was ein Aufruf aus dem MCP-Server seines Instanzprofils mitbringt, damit
/// ein Plugin während des Aufrufs die App nutzen kann (Adresse der App,
/// plugin/app_adresse.dart): Protokoll und Arbeitsordner dieses Profils, seine
/// eingebauten Werkzeuge und seine Freigaben. Umgesetzt vom MCP-Dienst des
/// Profils.
abstract interface class AufrufKontext {
  /// Das Protokoll des Profils (die Sicht aus `Protokoll.fuer`).
  Protokoll get protokoll;

  /// Der Arbeitsordner des Profils.
  String get arbeitsordner;

  /// Der Moodle-Zugang des Profils: Sitzung, Listen und Protokoll dieser
  /// Instanz. Ein Plugin liest darüber nur (plugin/moodle_lesen.dart).
  MoodleZugang get moodle;

  /// Ruft das eingebaute Werkzeug [name] mit [args] auf, durch dieselbe Hülle
  /// wie ein Aufruf eines KI-Werkzeugs (Protokoll, Freigaben, Abbruch,
  /// Fehlerantwort), mit [aufrufer] als Aufrufer in Freigabe, Protokoll und
  /// im Hinweis „ohne Freigabe ausgeführt“. Erfüllt sich [abbruch], verfallen
  /// seine offenen Freigaben. Wirft `MoodleFehler`, wenn [name] kein
  /// eingebautes Werkzeug ist; Werkzeuge der Plugins sind es nie.
  Future<EingebautErgebnis> eingebautAufrufen(
    String name,
    Map<String, dynamic> args, {
    required Future<void> abbruch,
    required String aufrufer,
  });

  /// Stellt eine Freigabe, um die das Plugin [aufrufer] bittet, durch die
  /// Freigaben dieses Profils (Freigaben.anfragen): mit [titel] und
  /// [zusammenfassung] des Plugins (schon bereinigt), gefragt ab der Stufe
  /// [ab], mit allen Regeln einer Freigabe (nur Maus, Wartezeit, Frist,
  /// Protokoll). Der Testbetrieb gibt sie nie automatisch frei. Lässt die
  /// Stufe der Lehrkraft die Frage aus, zählt das für den Aufruf des Plugins
  /// wie jede ausgelassene Freigabe. Erfüllt sich [abbruch], verfällt sie.
  /// [punkte] sind Zeilen, die moocp selbst dazusetzt (beim Schreiben über
  /// eine Zusatzadresse: Adresse, Feldnamen, Grund); [protokolltitel] ersetzt
  /// den Namen der Anfrage im Protokoll.
  Future<PluginFreigabeAusgang> pluginFreigabe({
    required String titel,
    required String zusammenfassung,
    required Bestaetigungen ab,
    required Future<void> abbruch,
    required String aufrufer,
    List<String> punkte = const [],
    String? protokolltitel,
  });
}

/// Ein frisches Token für einen Aufruf: 32 Bytes aus dem sicheren Zufall,
/// Base64url ohne Auffüllung.
String aufrufToken() {
  final zufall = Random.secure();
  return base64Url
      .encode([for (var i = 0; i < 32; i++) zufall.nextInt(256)])
      .replaceAll('=', '');
}

/// Eine Quelle weiterer Werkzeuge des MCP-Servers.
abstract interface class WerkzeugQuelle {
  /// Die Werkzeuge dieser Quelle im Server von [profil]. Gefragt wird bei
  /// jeder Sitzung und bei der Werkzeugliste für die Brücke (`moocp.exe
  /// --werkzeugliste`); die Antwort darf keine Sitzung oder Anmeldung
  /// brauchen.
  List<WerkzeugBeschreibung> werkzeuge(Profil profil);

  /// Führt den Aufruf eines Werkzeugs aus der Liste aus und liefert den Text
  /// der Antwort. Ein Fehler, den die KI lesen soll, ist ein `MoodleFehler`;
  /// jede andere Ausnahme meldet die Hülle als unerwarteten Fehler.
  Future<String> aufrufen(WerkzeugAufruf aufruf);
}
