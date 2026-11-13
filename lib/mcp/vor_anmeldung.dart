// Was ein Aufruf bekommt, der eine Moodle-Anmeldung braucht, solange die
// Lehrkraft sich noch nicht angemeldet hat (E13, E35): Der MCP-Server eines
// Profils läuft dann schon, weil dort ein Plugin mit Werkzeugen ohne Anmeldung
// eingeschaltet ist (mcp_dienst.dart), und jedes andere Werkzeug antwortet mit
// [anmeldungFehltText]. Dieselbe Meldung gibt die Adresse der App einem Plugin,
// das Moodle anfragt, ohne dass die App angemeldet ist (plugin/app_adresse.dart).
//
// Ohne Abhängigkeiten, weil auch die Brücke (bruecke.dart) es liest: Sie ist
// ein eigenes Programm ohne Flutter.

/// Der feste Satz für die KI und das Plugin: was fehlt und was danach geht.
/// Kein Bedienhinweis für das Modell darüber hinaus (E21).
const anmeldungFehltText = 'Bitte melden Sie sich zuerst in moocp an (Fenster der App); danach geht dieser Aufruf.';

/// Der Schlüssel in `_meta` der Antwort auf einen solchen Aufruf, mit dem
/// Wert [anmeldungFehltWert]. Die Brücke erkennt daran, dass sie weiter auf
/// die Anmeldung warten kann, ohne den Text zu vergleichen; einen Client
/// stört eine Angabe in `_meta` nicht.
const anmeldungFehltMeta = 'moocp/anmeldung';
const anmeldungFehltWert = 'fehlt';
