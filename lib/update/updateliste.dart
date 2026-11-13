// Was die Update-Prüfung anfragen darf (update.dart).
//
// Nach demselben Muster wie die Positivliste für Moodle (moodle_zugang.dart)
// und die Liste für Bildschirmfotos (browserliste.dart): nicht „alles außer
// Verbotenem", sondern genau die Abfrage des neuesten Releases und der
// Download daraus -- und jede Adresse einzeln geprüft, auch jedes
// Umleitungsziel. GitHub schickt den Download auf einen Speicherdienst weiter,
// mit einer unterschriebenen Adresse; ohne Prüfung des Ziels wäre die Liste
// wertlos.
//
// Mehr als diese Liste gibt es nicht: keine Einstellung für eine andere
// Herkunft, kein Herunterladen beliebiger Adressen. Was hier nicht steht,
// fragt die App nicht an. Und was hier steht, bekommt nichts von Moodle zu
// sehen -- die Prüfung hat ihre eigene Verbindung, ohne das Sitzungscookie
// (update.dart).
//
// Veränderlich ist an einer Adresse nur das Repository (die Herkunft): Die
// erlaubten Rechner und die Form der Adresse stehen fest. Wer prüft, nennt die
// Herkünfte als Liste (`quellen`); ohne Angabe gilt die von moocp selbst. Die
// Update-Prüfung eines Plugins (plugin/plugin_update.dart) nennt die
// Repositorys aus seiner Beschreibungsdatei -- sie sind das Einzige, was ein
// Plugin an dieser Liste ändert, und gelten nur für seine eigene Prüfung.

/// Die Repositorys auf GitHub, aus denen die Versionen von moocp kommen, in
/// der Reihenfolge der Abfrage. Eine spätere Herkunft wird nur gefragt, wenn es
/// unter den früheren kein Release gibt (E19). Die höchste Version über alle
/// zu nehmen, wäre gefährlich: Der Installer ist nicht signiert, und wer eine
/// einzige dieser Adressen übernähme, könnte mit einer hohen Versionsnummer
/// ein Update unterschieben.
const List<String> herkuenfte = ['Moodle-in-Niedersachsene-V/moocp', 'topse/moocp'];

/// Ein Repository bei GitHub, wie es als Herkunft zulässig ist: schlicht
/// „Besitzer/Name“. Der Besitzer besteht aus Buchstaben, Ziffern und Bindestrichen
/// (nicht am Anfang oder Ende, höchstens 39 Zeichen), der Name aus Buchstaben,
/// Ziffern, Punkt, Unterstrich und Bindestrich.
///
/// Die Regel ist eng, weil ein Name unmittelbar in eine Adresse eingesetzt wird:
/// „x/y/../../../users/z“ ergäbe nach dem Einsetzen (Uri.parse faltet „..“
/// weg) die Adresse „/users/z/releases/latest“, und „?“ oder „#“ schnitten den
/// Rest der Adresse ab. Ein Name, der aus dem Muster ausbräche, bestimmte so
/// selbst, was die Liste erlaubt -- und die Liste wäre wertlos.
bool herkunftGueltig(String herkunft) {
  if (!_herkunftMuster.hasMatch(herkunft)) return false;
  // „.“ und „..“ sind erlaubte Zeichen, aber als ganzer Name Pfadsegmente.
  final name = herkunft.substring(herkunft.indexOf('/') + 1);
  return name != '.' && name != '..';
}

final RegExp _herkunftMuster =
    RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]{1,100}$');

/// Die Abfrage des neuesten Releases einer Herkunft. GitHub lässt Entwürfe und
/// Vorabversionen dabei von selbst aus, die Prüfung muss nicht filtern.
/// Wirft [ArgumentError], wenn [herkunft] keine gültige Herkunft ist
/// ([herkunftGueltig]): Aus einem solchen Namen entsteht nie eine Adresse.
Uri releaseAbfrage(String herkunft) {
  if (!herkunftGueltig(herkunft)) {
    throw ArgumentError.value(herkunft, 'herkunft', 'kein Repository der Form Besitzer/Name');
  }
  return Uri.parse('https://api.github.com/repos/$herkunft/releases/latest');
}

/// Prüft eine Adresse der Update-Prüfung -- vor jeder Anfrage und für jedes
/// Umleitungsziel. Rückgabe: null, wenn sie erlaubt ist, sonst der Grund
/// für Protokoll und Meldung.
///
/// [download] trennt die beiden Fälle: die Abfrage der Version (je Herkunft
/// genau eine Adresse) und das Holen der Datei (das Release einer Herkunft und
/// die Speicherdienste, auf die GitHub dabei umleitet). [quellen] sind die
/// Herkünfte, deren Adressen gelten; ein Name darin, der keine gültige Herkunft
/// ist ([herkunftGueltig]), zählt nicht.
String? updateGesperrt(Uri uri, {required bool download, List<String> quellen = herkuenfte}) {
  if (uri.scheme != 'https') return 'kein https';
  if (uri.userInfo.isNotEmpty) return 'Adresse mit Anmeldedaten';
  final gueltige = quellen.where(herkunftGueltig).toList();
  if (!download) {
    return gueltige.any((h) => uri == releaseAbfrage(h))
        ? null
        : 'nicht die Abfrage des neuesten Releases';
  }
  if (uri.host == 'github.com') {
    return gueltige.any((h) => uri.path.startsWith('/$h/releases/download/'))
        ? null
        : 'kein Download eines Releases aus den hinterlegten Repositorys';
  }
  // Die Speicherdienste, auf die GitHub weiterleitet (objects…,
  // release-assets…). Der Punkt vor dem Namen gehört dazu: Sonst passte
  // auch „githubusercontent.com.beispiel.test".
  if (uri.host.endsWith('.githubusercontent.com')) return null;
  return 'fremder Rechner (${uri.host})';
}
