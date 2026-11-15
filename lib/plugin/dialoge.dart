// Dialoge eines Plugins (E35): Ein Plugin öffnet keine Fenster. Es beschreibt
// über die Adresse der App (app_adresse.dart) einen Dialog, und moocp zeigt
// ihn (plugin_dialoge_ansicht.dart). Vier Arten: eine Auswahlliste mit
// Suchfeld und Haken, die Eingabe eines Texts oder Links, die Wahl eines
// Ordners oder einer Datei und ein Hinweis. Jeder Dialog liefert die Antwort
// oder „abgebrochen“.
//
// Hier stehen die Beschreibung eines Dialogs, wie sie aus dem JSON des
// Plugins gelesen wird, und die Warteschlange, die die Oberfläche beobachtet.
// Kein Material, keine Widgets: Die Adresse der App kennt nur dieses Modell,
// die Oberfläche hängt sich als Zuhörer daran.
//
// Alles, was das Plugin vorgibt, ist reiner Text (klartext.dart): Titel und
// Listeneinträge einzeilig, der Text darunter mehrzeilig, alles in der Länge
// begrenzt, ohne Steuer- und Richtungszeichen. Die Knöpfe beschriftet moocp,
// nicht das Plugin: Sonst stünde auf einem Knopf, was er nicht tut.
//
// Ein Dialog ist keine Freigabe und zählt nicht als solche: Aus einer Antwort
// entsteht kein Recht, in Moodle zu schreiben (README, Teil 4). Er hat die
// Frist einer Freigabe (Freigaben.fristVorgabe); danach, und wenn der Aufruf
// endet, zu dem er gehört, gilt er als abgebrochen und schließt sich.

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../freigabe.dart' show Freigaben;
import 'klartext.dart';
import 'namenssperre.dart';

export 'namenssperre.dart' show SperrStelle, SperrTreffer;

/// Höchstlänge des Titels eines Dialogs oder einer Freigabe in Zeichen.
const dialogTitelHoechstens = 120;

/// Höchstlänge des Texts unter dem Titel, auch der Zusammenfassung einer
/// Freigabe.
const dialogTextHoechstens = 2000;

/// Höchstens so viele Einträge hat eine Auswahlliste: genug für die Kurse
/// oder Aktivitäten, aus denen eine Lehrkraft wählt, und wenig genug, dass
/// die Liste mit Suchfeld noch durchzusehen ist.
const auswahlEintraegeHoechstens = 500;

/// Höchstlänge eines Eintrags der Auswahlliste.
const auswahlEintragHoechstens = 200;

/// Höchstlänge einer Eingabe, auch ihrer Vorgabe.
const eingabeHoechstens = 2000;

/// Höchstlänge eines Pfads, den das Plugin als Startordner vorschlägt.
const pfadHoechstens = 1000;

/// Ob [t] etwas enthält, das ein einzeiliges Feld der Oberfläche nicht
/// annimmt: Zeilenwechsel und andere Steuerzeichen.
bool _mitSteuerzeichen(String t) => RegExp('[\\x00-\\x1f\\x7f-\\x9f\\u2028\\u2029]').hasMatch(t);

/// Die Arten der Dialoge, mit dem Namen im Protokoll.
enum PluginDialogArt {
  auswahl('Auswahl'),
  eingabe('Eingabe'),
  pfad('Ordner- oder Dateiwahl'),
  hinweis('Hinweis');

  const PluginDialogArt(this.name);
  final String name;
}

/// Ein Dialog, den ein Plugin zeigen lässt. Die Antwort ist ein JSON-Objekt
/// mit den Feldern der Art (siehe die Unterklassen), oder null, wenn er
/// abgebrochen ist.
sealed class PluginDialog {
  PluginDialog._(this.absender, Map<String, Object?> json)
    : titel = _titel(json),
      text = _text(json, 'text');

  /// Das Plugin als Absender, wie es in Freigabe und Protokoll heißt
  /// („Plugin „Name““). Der Dialog zeigt es oben.
  final String absender;

  /// Einzeilig, höchstens [dialogTitelHoechstens] Zeichen.
  final String titel;

  /// Mehrzeilig, höchstens [dialogTextHoechstens] Zeichen; leer ohne Text.
  final String text;

  PluginDialogArt get art;

  /// Prüft eine Antwort, die nicht aus der Oberfläche kommt (vorbereitete
  /// Antwort des Testbetriebs, testantworten.dart), wie die Oberfläche eine
  /// Eingabe der Lehrkraft (plugin_dialoge.dart): Liefert die Antwort so, wie
  /// die Oberfläche sie gäbe, oder null, wenn die Lehrkraft sie dort nicht
  /// übernehmen könnte.
  Map<String, Object?>? antwortPruefen(Map<String, Object?> roh);

  /// Wann die Frist endet; gesetzt von [PluginDialoge.zeigen].
  DateTime? get ablauf => _ablauf;
  DateTime? _ablauf;

  final _antwort = Completer<Map<String, Object?>?>();
  bool get offen => !_antwort.isCompleted;

  /// Liest einen Dialog der Art [art] aus dem JSON des Plugins. Wirft
  /// [FormatException] mit einem deutschen Satz, den das Plugin bekommt.
  static PluginDialog ausJson(PluginDialogArt art, String absender, Map<String, Object?> json) => switch (art) {
    PluginDialogArt.auswahl => AuswahlDialog._(absender, json),
    PluginDialogArt.eingabe => EingabeDialog._(absender, json),
    PluginDialogArt.pfad => PfadDialog._(absender, json),
    PluginDialogArt.hinweis => HinweisDialog._(absender, json),
  };

  static String _titel(Map<String, Object?> json) {
    final t = json['titel'];
    final titel = t is String ? einzeilig(t, dialogTitelHoechstens) : '';
    if (titel.isEmpty) throw const FormatException('titel fehlt: eine Zeile Text als Überschrift des Dialogs.');
    return titel;
  }

  static String _text(Map<String, Object?> json, String feld) {
    final t = json[feld];
    if (t == null) return '';
    if (t is! String) throw FormatException('$feld muss Text sein.');
    return mehrzeilig(t, dialogTextHoechstens);
  }
}

/// Eine Liste mit Suchfeld und Haken. Felder: `eintraege` (Liste von Texten,
/// 1 bis [auswahlEintraegeHoechstens]), `mehrfach` (ob mehrere gewählt werden
/// dürfen; ohne Angabe genau einer). Antwort: `gewaehlt`, die Nummern der
/// gewählten Einträge ab 0, aufsteigend, mindestens eine.
final class AuswahlDialog extends PluginDialog {
  AuswahlDialog._(String absender, Map<String, Object?> json)
    : eintraege = _eintraege(json),
      mehrfach = json['mehrfach'] == true,
      super._(absender, json) {
    if (json['mehrfach'] case final m? when m is! bool) {
      throw const FormatException('mehrfach muss true oder false sein.');
    }
  }

  final List<String> eintraege;
  final bool mehrfach;

  @override
  PluginDialogArt get art => PluginDialogArt.auswahl;

  /// Die Antwort mit den gewählten Nummern.
  static Map<String, Object?> antwort(Iterable<int> gewaehlt) => {'gewaehlt': gewaehlt.toList()..sort()};

  /// Mindestens ein Eintrag, jeder nur einmal und aus der Liste, ohne
  /// [mehrfach] genau einer.
  @override
  Map<String, Object?>? antwortPruefen(Map<String, Object?> roh) {
    final g = roh['gewaehlt'];
    if (g is! List || g.isEmpty || (!mehrfach && g.length != 1)) return null;
    final nummern = <int>{};
    for (final n in g) {
      if (n is! int || n < 0 || n >= eintraege.length || !nummern.add(n)) return null;
    }
    return antwort(nummern);
  }

  static List<String> _eintraege(Map<String, Object?> json) {
    final e = json['eintraege'];
    if (e is! List || e.isEmpty) {
      throw const FormatException('eintraege fehlt: eine Liste mit mindestens einem Text.');
    }
    if (e.length > auswahlEintraegeHoechstens) {
      throw const FormatException(
        'Zu viele Einträge: Eine Auswahlliste hat höchstens $auswahlEintraegeHoechstens.',
      );
    }
    return [
      for (final x in e)
        switch (x) {
          final String s when einzeilig(s, auswahlEintragHoechstens).isNotEmpty => einzeilig(s, auswahlEintragHoechstens),
          _ => throw const FormatException('Jeder Eintrag muss ein nicht leerer Text sein.'),
        },
    ];
  }
}

/// Die Eingabe eines Texts oder Links, einzeilig. Felder: `art` („text“ oder
/// „link“, ohne Angabe „text“), `vorgabe` (was schon im Feld steht).
/// Antwort: `text`, höchstens [eingabeHoechstens] Zeichen; bei „link“ eine
/// Adresse mit http oder https.
final class EingabeDialog extends PluginDialog {
  EingabeDialog._(super.absender, super.json)
    : link = _link(json),
      vorgabe = switch (json['vorgabe']) {
        null => '',
        final String v => einzeilig(v, eingabeHoechstens),
        _ => throw const FormatException('vorgabe muss Text sein.'),
      },
      super._();

  final bool link;
  final String vorgabe;

  @override
  PluginDialogArt get art => PluginDialogArt.eingabe;

  static Map<String, Object?> antwort(String text) => {'text': text};

  /// Ob [text] als Link taugt: eine Adresse mit http oder https und Host.
  static bool istLink(String text) {
    final u = Uri.tryParse(text.trim());
    return u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty;
  }

  /// Ob die Oberfläche [text] übernähme: nicht leer, bei [link] ein Link.
  bool gueltig(String text) => link ? istLink(text) : text.trim().isNotEmpty;

  /// Wie in der Oberfläche: eine Zeile, höchstens [eingabeHoechstens]
  /// Zeichen (das Feld nimmt nicht mehr an), getrimmt.
  @override
  Map<String, Object?>? antwortPruefen(Map<String, Object?> roh) {
    final t = roh['text'];
    if (t is! String || t.length > eingabeHoechstens || _mitSteuerzeichen(t)) return null;
    return gueltig(t) ? antwort(t.trim()) : null;
  }

  static bool _link(Map<String, Object?> json) => switch (json['art']) {
    null || 'text' => false,
    'link' => true,
    _ => throw const FormatException('art muss „text“ oder „link“ sein.'),
  };
}

/// Die Wahl eines Ordners oder einer Datei auf dem Rechner der Lehrkraft.
/// Felder: `art` („ordner“ oder „datei“, Pflicht), `start` (ein Ordner, in dem
/// die Wahl beginnt; fehlt er, im Benutzerordner). Antwort: `pfad`, der
/// absolute Pfad eines Ordners oder einer Datei, die es gibt. Lesen tut das
/// Plugin selbst.
final class PfadDialog extends PluginDialog {
  PfadDialog._(super.absender, super.json)
    : ordner = switch (json['art']) {
        'ordner' => true,
        'datei' => false,
        _ => throw const FormatException('art fehlt: „ordner“ oder „datei“.'),
      },
      start = _start(json),
      super._();

  final bool ordner;
  final String? start;

  @override
  PluginDialogArt get art => PluginDialogArt.pfad;

  static Map<String, Object?> antwort(String pfad) => {'pfad': pfad};

  /// Ob die Oberfläche [text] übernähme: ein absoluter Pfad eines Ordners
  /// (bei [ordner]) oder einer Datei, die es gibt.
  bool gueltig(String text) {
    final t = text.trim();
    if (t.isEmpty || !p.isAbsolute(t)) return false;
    return ordner ? Directory(t).existsSync() : File(t).existsSync();
  }

  @override
  Map<String, Object?>? antwortPruefen(Map<String, Object?> roh) {
    final t = roh['pfad'];
    if (t is! String || t.length > pfadHoechstens || _mitSteuerzeichen(t) || !gueltig(t)) return null;
    return antwort(p.normalize(t.trim()));
  }

  static String? _start(Map<String, Object?> json) {
    final s = json['start'];
    if (s == null) return null;
    if (s is! String || s.isEmpty || s.length > pfadHoechstens || einzeilig(s, pfadHoechstens) != s.trim()) {
      throw const FormatException(
        'start muss ein Pfad sein: Text ohne Steuerzeichen, höchstens $pfadHoechstens Zeichen.',
      );
    }
    return s;
  }
}

/// Ein Hinweis mit nur einem Knopf. Antwort: ein leeres Objekt, wenn die
/// Lehrkraft ihn bestätigt hat.
final class HinweisDialog extends PluginDialog {
  HinweisDialog._(super.absender, super.json) : super._();

  @override
  PluginDialogArt get art => PluginDialogArt.hinweis;

  /// Nur „OK“: ein leeres Objekt.
  @override
  Map<String, Object?>? antwortPruefen(Map<String, Object?> roh) => roh.isEmpty ? const {} : null;
}

/// Die Warnungen der letzten Sperre (namenssperre.dart), die die Lehrkraft
/// noch nicht gesehen hat. Eine Warnung ist ein Hinweis: Sie hält keinen
/// Aufruf auf und verlangt keine Entscheidung, und es gibt keinen Weg, das
/// Gesperrte doch zu senden. Die Oberfläche zeigt alle offenen Treffer in
/// einem Fenster; kommen weitere, solange es offen ist, erscheinen sie darin,
/// statt ein neues zu öffnen. Mehr als [hoechstens] behält sie nicht einzeln,
/// sondern zählt sie nur ([weitere]). Nur im Arbeitsspeicher.
class SperrHinweise extends ChangeNotifier {
  SperrHinweise({this.hoechstens = 50});

  /// So viele Treffer zeigt das Fenster einzeln.
  final int hoechstens;

  final _offen = <SperrTreffer>[];
  int _weitere = 0;

  /// Die Treffer seit dem letzten Schließen, der älteste zuerst.
  List<SperrTreffer> get offen => List.unmodifiable(_offen);

  /// Wie viele Treffer darüber hinaus kamen.
  int get weitere => _weitere;

  /// Nimmt einen Treffer auf; für [LetzteSperre.melden].
  void melden(SperrTreffer t) {
    if (_offen.length < hoechstens) {
      _offen.add(t);
    } else {
      _weitere++;
    }
    notifyListeners();
  }

  /// Die Lehrkraft hat das Fenster geschlossen: Was sie gesehen hat, ist weg.
  void gesehen() {
    if (_offen.isEmpty && _weitere == 0) return;
    _offen.clear();
    _weitere = 0;
    notifyListeners();
  }
}

/// Die Dialoge der Plugins, die gerade zu zeigen sind: immer einer offen, die
/// übrigen in der Reihenfolge, in der sie kamen. Die Oberfläche hört zu und
/// zeigt [aktuell]; beantwortet die App einen Dialog selbst (Frist, Ende des
/// Aufrufs), schließt sie ihn.
class PluginDialoge extends ChangeNotifier {
  PluginDialoge({this.frist = Freigaben.fristVorgabe});

  /// Die Frist eines Dialogs: dieselbe wie bei einer Freigabe, damit sie vor
  /// dem Zeitlimit endet, das die App in die KI-Werkzeuge einträgt.
  final Duration frist;

  PluginDialog? _aktuell;
  PluginDialog? get aktuell => _aktuell;

  final _warteschlange = Queue<PluginDialog>();

  /// Wie viele Dialoge hinter dem offenen warten.
  int get wartend => _warteschlange.length;

  /// Zeigt [d] und wartet auf die Antwort, höchstens [frist] und nur, bis
  /// [ende] sich erfüllt (der Aufruf, zu dem der Dialog gehört, ist zu Ende
  /// oder abgebrochen). Null heißt abgebrochen. Die Frist läuft ab hier, auch
  /// solange der Dialog hinter einem anderen wartet.
  Future<Map<String, Object?>?> zeigen(PluginDialog d, {required Future<void> ende}) async {
    d._ablauf = DateTime.now().add(frist);
    final uhr = Timer(frist, () => beantworten(d, null));
    unawaited(ende.then((_) => beantworten(d, null)));
    if (_aktuell == null) {
      _aktuell = d;
    } else {
      _warteschlange.add(d);
    }
    notifyListeners();
    try {
      return await d._antwort.future;
    } finally {
      uhr.cancel();
    }
  }

  /// Beantwortet [d], ob offen oder wartend; null heißt abgebrochen. Ist er
  /// der offene, ist der nächste wartende dran, im selben Zug.
  void beantworten(PluginDialog d, Map<String, Object?>? antwort) {
    if (!d.offen) return;
    d._antwort.complete(antwort);
    if (identical(d, _aktuell)) {
      _aktuell = _warteschlange.isEmpty ? null : _warteschlange.removeFirst();
    } else {
      _warteschlange.remove(d);
    }
    notifyListeners();
  }
}
