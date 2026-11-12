// Werkzeugquellen: woher der MCP-Server außer den eingebauten Werkzeugen
// (mcp_dienst.dart) weitere bekommt.
//
// Eine Quelle nennt ihre Werkzeuge mit Name, Beschreibung und fertigem
// JSON-Schema der Eingabe, so wie sie über MCP laufen, und führt einen Aufruf
// aus. Der Server hängt jedes dieser Werkzeuge durch dieselbe Hülle ein wie
// die eingebauten (WerkzeugAufrufe: Protokoll, Abbruch, Fehlerantwort) und
// bricht ab, wenn ein Name zweimal vorkommt.

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

/// Eine Quelle weiterer Werkzeuge des MCP-Servers.
abstract interface class WerkzeugQuelle {
  /// Die Werkzeuge dieser Quelle. Gefragt wird bei jeder Sitzung und bei der
  /// Werkzeugliste für die Brücke (`moocp.exe --werkzeugliste`); die Antwort
  /// muss dort dieselbe sein und darf keine Sitzung oder Anmeldung brauchen.
  List<WerkzeugBeschreibung> werkzeuge();

  /// Führt das Werkzeug [name] aus der Liste mit [args] aus und liefert den
  /// Text der Antwort. Ein Fehler, den die KI lesen soll, ist ein
  /// `MoodleFehler`; jede andere Ausnahme meldet die Hülle als unerwarteten
  /// Fehler.
  Future<String> aufrufen(String name, Map<String, dynamic> args);
}
