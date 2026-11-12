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

import '../profil.dart';

/// Ein Werkzeug einer [WerkzeugQuelle], beschrieben wie in der MCP-Werkzeugliste.
class WerkzeugBeschreibung {
  const WerkzeugBeschreibung({
    required this.name,
    required this.beschreibung,
    required this.eingabeSchema,
    this.titel,
    this.nurLesen = false,
    this.zerstoerend = false,
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
