// Was die Datenschutzwarnung (E36) der Lehrkraft zeigt und was sie entscheidet:
// die Herkunft eines Namens oder Pfads, ein Treffer mit seiner Umgebung, die
// Warnung zu einer Antwort und der Ausgang. Reine Daten, ohne Flutter und ohne
// Regel; geprüft wird in plugin/datenschutz.dart, gefragt über die Freigaben
// (freigabe.dart), gezeigt in datenschutz_dialog.dart. Die Klassen liegen hier
// und nicht im Ordner plugin/, weil die MCP-Schicht (lib/mcp) sie kennt und
// sonst nichts aus plugin/ kennen darf.
//
// Keine Klasse hier hat ein `toString`, das ein Wort, eine Umgebung oder einen
// Pfad nennt.

/// Woher ein Name oder Pfad stammt, den die App prüft; die Datenschutzwarnung
/// nennt es der Lehrkraft (datenschutz.dart) und der Testbetrieb entscheidet
/// danach, ob das Wort ins Protokoll darf (E20).
enum HerkunftArt {
  /// Vor- und Nachname der Teilnehmenden eines Kurses, geladen beim Beginn
  /// eines Laufs ([Herkunft.kurs]).
  teilnehmende('Teilnehmende des Kurses'),

  /// Die angemeldete Lehrkraft des Instanzprofils.
  lehrkraft('angemeldete Lehrkraft'),

  /// Ein Name, den das Plugin selbst gemeldet hat.
  pluginName('vom Plugin gemeldeter Name'),

  /// Der Ordner, in dem die App die Downloads der Plugins ablegt.
  downloadOrdner('Ordner für Downloads von Plugins'),

  /// Ein Pfad, den das Plugin selbst gemeldet hat.
  pluginPfad('vom Plugin gemeldeter Pfad');

  const HerkunftArt(this.text);
  final String text;
}

/// Die Herkunft eines Namens oder Pfads: Art und, bei Teilnehmenden, der Kurs.
class Herkunft {
  const Herkunft(this.art, {this.kurs});

  static const lehrkraft = Herkunft(HerkunftArt.lehrkraft);
  static const pluginName = Herkunft(HerkunftArt.pluginName);
  static const downloadOrdner = Herkunft(HerkunftArt.downloadOrdner);
  static const pluginPfad = Herkunft(HerkunftArt.pluginPfad);
  const Herkunft.teilnehmende(int this.kurs) : art = HerkunftArt.teilnehmende;

  final HerkunftArt art;
  final int? kurs;

  /// So steht es in der Warnung.
  String get text => kurs == null ? art.text : '${art.text} $kurs';

  @override
  bool operator ==(Object other) => other is Herkunft && other.art == art && other.kurs == kurs;

  @override
  int get hashCode => Object.hash(art, kurs);

  @override
  String toString() => 'Herkunft(${art.name})';
}

/// Wie viele Zeichen Umgebung die Warnung vor und nach dem Treffer zeigt.
const umgebungZeichen = 80;

/// Ein Treffer in einem Text: ein Wort, das einen Namen trifft, oder ein
/// Pfad, den ein Plugin nicht an die KI geben soll.
class Fund {
  const Fund({
    required this.wort,
    required this.pfad,
    required this.herkunft,
    required this.davor,
    required this.danach,
    this.davorGekuerzt = false,
    this.danachGekuerzt = false,
  });

  /// Das Wort, so wie es im Text stand (bei einem kodierten Text in
  /// aufgelöster Form), oder der genannte Pfad, wie er dort stand.
  final String wort;

  /// Ob nicht ein Name getroffen hat, sondern ein Pfad.
  final bool pfad;

  /// Woher der Name oder Pfad stammt, ohne Doppelte.
  final List<Herkunft> herkunft;

  /// Bis zu [umgebungZeichen] Zeichen vor und nach dem Treffer, einzeilig.
  final String davor;
  final String danach;

  /// Ob die Umgebung dort gekürzt ist (die Warnung setzt dann „…“).
  final bool davorGekuerzt;
  final bool danachGekuerzt;

  /// Ohne das Wort: Ein Treffer, der versehentlich in einer Ausgabe landet,
  /// trägt nichts Konkretes mit.
  @override
  String toString() => 'Fund(${pfad ? 'pfad' : 'name'})';
}

/// Was die Lehrkraft vor einer Antwort eines Plugins sieht: Plugin, Werkzeug
/// und alle Treffer in dieser einen Antwort. Eine Entscheidung gilt für die
/// ganze Antwort.
class Datenschutzwarnung {
  Datenschutzwarnung({required this.plugin, required this.werkzeug, required this.funde});

  /// Der Anzeigename des Plugins.
  final String plugin;

  /// Das Werkzeug, dessen Antwort angehalten ist; null, wenn es keinen Aufruf
  /// gab.
  final String? werkzeug;
  final List<Fund> funde;

  int get anzahl => funde.length;
  bool get hatNamen => funde.any((f) => !f.pfad);
  bool get hatPfade => funde.any((f) => f.pfad);

  @override
  String toString() => 'Datenschutzwarnung($anzahl)';
}

/// Wie die Lehrkraft über eine Datenschutzwarnung entschieden hat. Ohne
/// Entscheidung (Frist, Abbruch des Clients) gilt [sperren].
enum DatenschutzAusgang {
  /// „Kein Name – trotzdem an die KI geben“: Die Antwort geht unverändert
  /// hinaus.
  senden,

  /// „Sperren“, oder keine Entscheidung: Die KI erfährt nur, dass gesperrt
  /// wurde.
  sperren,
}
