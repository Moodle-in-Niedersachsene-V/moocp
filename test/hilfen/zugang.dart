// Ein Moodle-Zugang für Tests, die die Anmeldung schalten, ohne Moodle
// (test/plugin_start_test.dart).
import 'package:moocp/moodle/moodle_zugang.dart';

/// Ein Zugang, dessen Anmeldung der Test schaltet ([an]), ohne Moodle; er
/// zählt, ob jemand sich anzumelden versucht.
class SchaltbarerZugang extends MoodleZugang {
  SchaltbarerZugang(super.protokoll);

  var an = false;
  var anmeldeversuche = 0;

  @override
  bool get angemeldet => an;

  @override
  Future<void> anmelden(String adresse, String benutzer, String passwort) async => anmeldeversuche++;
}
