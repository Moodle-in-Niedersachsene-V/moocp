// Instanzprofile: Moodle-Instanzen, mit denen die App gleichzeitig angemeldet
// sein kann (E31). Ein Profil hat eine stabile Kennung, einen
// Anzeigenamen, die Adresse, einen eigenen Port und einen technischen
// Servernamen.
//
// Je Profil läuft ein eigener MCP-Server (mcp/mcp_dienst.dart) mit eigenem
// Endpunkt, nur für das Konto (mcp/kanal.dart), unter eigenem Namen
// (einrichtung.dart): Die KI-Werkzeuge sehen je Instanz eine eigene
// Werkzeugfamilie, etwa `moodle_…` und `moodle-test_…`. Es gibt keinen
// Parameter `instanz` (E31). Der Name des Profils ist der Name des Endpunkts
// und der Name des Eintrags in jedem KI-Werkzeug.
//
// Die Kennung ist der Schlüssel für alles, was je Instanz getrennt liegt:
// Zugangsdaten (anmeldedaten.dart), Registry (moodle/instanzen.dart) und
// Unterordner im Arbeitsordner, sobald mehrere Profile bestehen.
//
// Altbestand: Eine Einstellungsdatei mit nur `moodleAdresse` und `port` wird zu
// einem Profil mit der Kennung `standard`, Servername `moodle`, altem Port
// (Einstellungen.aus). Dessen Zugangsdaten liegen weiter unter den alten
// Schlüsseln, damit niemand neu eingeben muss.

import 'dart:math';

import 'einstellungen_ort.dart';
import 'freigabe.dart';

class Profil {
  Profil({
    required this.kennung,
    required this.name,
    required this.adresse,
    required this.port,
    required this.mcpName,
    this.bestaetigungen = Bestaetigungen.vorgabe,
    this.unbekannteFelder = const {},
  });

  /// Kennung des ersten Profils. Der Altbestand und der Testzugang gehören
  /// dazu (anmeldedaten.dart). Neue Profile bekommen eine zufällige Kennung.
  static const standardKennung = 'standard';

  /// Anzeigename des Altbestands. Bewusst kein Domainname (A11).
  static const standardName = 'Moodle';

  final String kennung;
  final String name;
  final String adresse;

  /// Port des Profils, den der MCP-Server nicht mehr braucht (sein Kanal liegt
  /// im Ordner des Kontos). Er bleibt je Profil verschieden in der Datei, damit
  /// die Version, zu der die Lehrkraft zurückkehrt (E39), sie lesen kann. Der
  /// Wert 0 heißt „noch nicht vergeben"; Einstellungen.aus setzt ihn.
  final int port;

  /// Technischer Servername für die KI-Werkzeuge, etwa `moodle-test`. Aus dem
  /// Anzeigenamen abgeleitet ([mcpNameAus]) und dann gespeichert, damit ein
  /// Umbenennen die Einrichtung in den Werkzeugen nicht still verstellt.
  final String mcpName;

  /// Freigabestufe für Schreibvorgänge auf dieser Moodle-Instanz (E20, E31).
  final Bestaetigungen bestaetigungen;

  /// Felder anderer Versionen, die dieses Profil nicht auswertet.
  final Map<String, Object?> unbekannteFelder;

  bool get istStandard => kennung == standardKennung;

  /// Ändert nur den Anzeigenamen, der Servername bleibt (siehe [mcpName]).
  Profil copyWith({String? name, String? adresse, String? mcpName, int? port}) => Profil(
        kennung: kennung,
        name: name ?? this.name,
        adresse: adresse ?? this.adresse,
        port: port ?? this.port,
        mcpName: mcpName ?? this.mcpName,
        bestaetigungen: bestaetigungen,
        unbekannteFelder: unbekannteFelder,
      );

  Profil mitBestaetigungen(Bestaetigungen neu) => Profil(
        kennung: kennung,
        name: name,
        adresse: adresse,
        port: port,
        mcpName: mcpName,
        bestaetigungen: neu,
        unbekannteFelder: unbekannteFelder,
      );

  Map<String, Object?> toJson() => {
        ...unbekannteFelder,
        'kennung': kennung,
        'name': name,
        'adresse': adresse,
        'port': port,
        'mcpName': mcpName,
        'bestaetigungen': bestaetigungen.text,
      };

  /// Null, wenn die Angabe unbrauchbar ist; die Einstellungen fallen dann auf
  /// die übrigen Profile zurück, statt die ganze Datei zu verwerfen. Fehlt der
  /// Port oder der Servername, kommen 0 bzw. der aus dem Namen abgeleitete Name.
  static Profil? ausJson(Object? j) {
    if (j is! Map) return null;
    final kennung = j['kennung'];
    final name = j['name'];
    final adresse = j['adresse'];
    if (kennung is! String || kennung.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    if (adresse is! String) return null;
    final port = j['port'];
    final mcpName = j['mcpName'];
    return Profil(
      kennung: kennung,
      name: name,
      adresse: adresse,
      port: port is int && port > 0 ? port : 0,
      mcpName: mcpName is String && mcpNameGueltig(mcpName) ? mcpName : mcpNameFuer(name, kennung),
      bestaetigungen: Bestaetigungen.ausText(j['bestaetigungen'] as String?),
      unbekannteFelder: {
        for (final e in j.entries)
          if (e.key is String && !const {'kennung', 'name', 'adresse', 'port', 'mcpName', 'bestaetigungen', 'schluessel' /* nur noch Altbestand */}.contains(e.key))
            e.key as String: e.value,
      },
    );
  }

  /// Das Profil für eine einzelne Adresse aus dem Altbestand.
  static Profil migriert(String adresse, {int port = standardPort}) => Profil(
        kennung: standardKennung,
        name: standardName,
        adresse: adresse,
        port: port,
        mcpName: mcpNameAus(standardName),
      );

  /// Eine neue Kennung: acht Hexziffern, zufällig. Die Kennung bleibt danach
  /// unverändert, auch wenn der Name geändert wird.
  static String neueKennung([Random? zufall]) {
    final r = zufall ?? Random.secure();
    return List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  /// Der technische Servername aus dem Anzeigennamen: Kleinbuchstaben, Ziffern
  /// und Bindestriche, keine Leerzeichen. Leer, wenn der Name nichts davon
  /// hergibt; Einstellungen.aus setzt dann die Kennung als Ersatz.
  static String mcpNameAus(String name) => name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  /// Ob ein Servername gültig ist: wie [mcpNameAus] liefert, nicht leer.
  static bool mcpNameGueltig(String n) => RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$').hasMatch(n);

  /// Die Höchstlänge des technischen Namens eines neuen Profils. So bleibt der
  /// Name jedes Werkzeugs, wie ein KI-Werkzeug ihn sieht
  /// (`mcp__<Profil>__<Werkzeug>`), in den 64 Zeichen, die Claude Code
  /// zulässt: 64 weniger `mcp__` und `__` weniger die 40 Zeichen, die ein
  /// Werkzeug eines Plugins höchstens hat (plugin/verbindung.dart). Ein
  /// Profil, das schon einen längeren Namen hat, behält ihn; dort fehlen
  /// Werkzeuge, deren Name zu lang wäre.
  static const neuerMcpNameHoechstens = 17;

  /// Der technische Name eines neuen Profils aus [basis] (ein gültiger Name,
  /// [mcpNameFuer]): auf [neuerMcpNameHoechstens] Zeichen gekürzt und, wenn
  /// er unter [vergeben] schon steht, mit `-2`, `-3` … unterschieden -- auch
  /// dann höchstens [neuerMcpNameHoechstens] Zeichen. Ein Bindestrich am Ende
  /// einer Kürzung fällt weg.
  static String neuerMcpName(String basis, Set<String> vergeben) {
    String kuerzen(String s, int n) => s.length <= n ? s : s.substring(0, n).replaceAll(RegExp(r'-+$'), '');
    final kurz = kuerzen(basis, neuerMcpNameHoechstens);
    if (!vergeben.contains(kurz)) return kurz;
    for (var i = 2;; i++) {
      final anhang = '-$i';
      final name = '${kuerzen(kurz, neuerMcpNameHoechstens - anhang.length)}$anhang';
      if (!vergeben.contains(name)) return name;
    }
  }

  /// Der Servername, wenn er nicht gespeichert ist: aus dem Namen, und wenn
  /// der nichts hergibt, aus der Kennung.
  static String mcpNameFuer(String name, String kennung) {
    final a = mcpNameAus(name);
    if (a.isNotEmpty) return a;
    final k = mcpNameAus(kennung);
    return k.isEmpty ? 'moodle' : 'moodle-$k';
  }
}
