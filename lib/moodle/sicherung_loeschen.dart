// Eine eigene Sicherungsdatei im persönlichen Sicherungsbereich von Moodle löschen
// (sicherung_loeschen, Issue #30).
//
// Jede Sicherung über moocp lässt im Bereich „user/backup" der Lehrkraft eine
// Datei zurück. Moodle bietet dafür nur den Dateimanager `backupfilesedit.php`
// an, und der arbeitet nicht auf einer Datei, sondern auf dem ganzen Bereich:
// Beim Aufruf legt er einen Entwurf mit Kopien ALLER Dateien an, das Speichern
// (`file_postupdate_standard_filemanager`) gleicht den Bereich mit dem Entwurf ab
// und löscht, was im Entwurf fehlt. Es gibt keinen Papierkorb. Eine Datei, die nach
// dem Anlegen des Entwurfs in den Bereich kommt (etwa eine zweite Sitzung der
// Lehrkraft sichert gerade), wäre mit dem Speichern gelöscht. Moodle bietet dafür
// keinen Standvergleich beim Speichern; die App kann ihn nicht atomar nachbauen.
//
// Was sie tut, damit das so selten wie möglich geschieht:
//   1. Nur ein Vorgang dieses Profils, der selbst eine Sicherung war und nicht
//      läuft; der Name muss dem Dateinamen des Vorgangs entsprechen und genau
//      einmal im Bereich stehen. Läuft in dieser App gerade eine Sicherung oder
//      Wiederherstellung, bricht sie ab (beide schreiben in diesen Bereich).
//   2. Stand lesen (Seite „Wiederherstellen", sie verlinkt jede Datei des
//      Bereichs), dann die Freigabe. Die Freigabe nennt, was bleibt, und dass
//      Moodle den ganzen Bereich neu schreibt.
//   3. Nach der Freigabe der Stand noch einmal; weicht er ab, wird nichts geschrieben.
//   4. Erst jetzt der Entwurf (frisch, nicht vor der Freigabe: Er hielte sonst
//      bis zu 30 Minuten einen alten Stand). Er muss genau dem Stand entsprechen.
//   5. Die Datei wird im ENTWURF entfernt (draftfiles_ajax, `delete`; das ändert den
//      Bereich noch nicht), der Entwurf gelesen: alle übrigen müssen drin sein.
//   6. Unmittelbar vor dem Speichern liest die App den Bereich ein letztes Mal. Nur wenn
//      er immer noch dem Stand entspricht, speichert sie. Zwischen diesem Lesen und
//      dem Speichern in Moodle bleibt eine Lücke von Millisekunden, die sich ohne
//      Unterstützung von Moodle nicht schließen lässt; die Freigabe sagt es.
//   7. Rückleseprobe: Der Bereich muss genau den Stand ohne die eine Datei zeigen.
//      Fehlt etwas anderes, nennt die Antwort es und `verified: false`.
//
// Gemessen ist der Ablauf an Moodles Quelltext (backup/backupfilesedit.php und
// repository/draftfiles_ajax.php, Moodle 4.5); die Antworten sind je Instanz noch
// nicht gemessen. Die Seiten und Felder, die sich als Annahme herausstellen, stehen
// als UNGEMESSEN im Code.

import 'dart:convert';

import '../freigabe.dart';
import 'formular_schreiben.dart';
import 'moodle_zugang.dart';
import 'sicherung.dart';
import 'sicherung_regeln.dart';
import 'wiederherstellung.dart';

/// Was die Seite „Wiederherstellen" an Dateien im persönlichen Sicherungsbereich
/// verlinkt: die Nummer des Benutzerkontexts (steht im Pfad jedes Links) und die
/// Dateinamen, ohne Doppelte. Der Benutzerkontext ist null, wenn kein Link da ist;
/// zeigen die Links auf verschiedene Kontexte, ist die Seite nicht eindeutig zu
/// lesen (Kontext -1).
({int? kontext, List<String> namen}) sicherungsBereich(String html) {
  final muster = RegExp('/pluginfile\\.php/(\\d+)/user/backup/(?:\\d+/)?([^/?#"\'\\s<>]+)\\?forcedownload=1(?=["\'\\s<>])');
  final kontexte = <int>{};
  final namen = <String>{};
  for (final m in muster.allMatches(html.replaceAll('&amp;', '&'))) {
    kontexte.add(int.parse(m.group(1)!));
    try {
      namen.add(Uri.decodeComponent(m.group(2)!));
    } on ArgumentError {
      namen.add(m.group(2)!);
    }
  }
  final liste = namen.toList()..sort();
  return (kontext: kontexte.length > 1 ? -1 : kontexte.firstOrNull, namen: liste);
}

/// Der Unterschied zweier Stände des Bereichs: Was fehlt jetzt, was ist neu.
({List<String> fehlt, List<String> neu}) bereichsUnterschied(List<String> soll, List<String> ist) => (
  fehlt: [for (final n in soll) if (!ist.contains(n)) n],
  neu: [for (final n in ist) if (!soll.contains(n)) n],
);

/// Die Dateinamen im Wurzelordner eines Entwurfs, wie `draftfiles_ajax.php?action=list`
/// oder der Dateimanager der Seite sie liefern. Ein Ordner oder ein unlesbarer Eintrag
/// macht den Entwurf unbrauchbar (null): Der Bereich kennt laut Formular keine Unterordner.
List<String>? entwurfsNamen(Object? liste) {
  if (liste is! List) return null;
  final namen = <String>[];
  for (final e in liste) {
    if (e is! Map) return null;
    if (e['type'] == 'folder') return null;
    final name = e['filename'];
    final pfad = e['filepath'] ?? '/';
    if (name is! String || name.isEmpty || pfad != '/') return null;
    namen.add(name);
  }
  namen.sort();
  return namen;
}

/// Ob zwei Namenslisten dieselben Namen genau einmal enthalten.
bool _gleich(List<String> a, List<String> b) {
  final x = [...a]..sort(), y = [...b]..sort();
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

String _bereichsAdresse(int kontext) => '/backup/restorefile.php?contextid=$kontext';

/// Die Adresse des Dateimanagers für den persönlichen Sicherungsbereich. `returnurl`
/// ist die Seite „Wiederherstellen" desselben Kontexts (PARAM_LOCALURL).
String dateimanagerAdresse({required int kontext, required int benutzerKontext}) =>
    '/backup/backupfilesedit.php?currentcontext=$kontext&contextid=$benutzerKontext'
    '&filearea=backup&component=user&returnurl=${Uri.encodeQueryComponent(_bereichsAdresse(kontext))}';

/// Liest den Bereich. [leerOk]: Eine Seite ohne jeden Link ist ein leerer Bereich (nur beim
/// Rücklesen nach dem Löschen); sonst bricht das Lesen ab, weil dann keine Datei zu löschen ist.
Future<({int benutzerKontext, List<String> namen})> _bereichLesen(MoodleZugang moodle, int kontext,
    {bool leerOk = false}) async {
  final r = await moodle.lesen(_bereichsAdresse(kontext));
  if (r.status != 200) {
    throw MoodleFehler('Moodle liefert für die Seite „Wiederherstellen" HTTP ${r.status}. Nichts gelöscht.');
  }
  final b = sicherungsBereich(r.text);
  if (leerOk && b.kontext == null) return (benutzerKontext: 0, namen: const <String>[]);
  if (b.kontext == null || b.kontext! < 0) {
    throw MoodleFehler(
      b.kontext == null
          ? 'Auf der Seite „Wiederherstellen" steht keine Datei im Sicherungsbereich. Nichts gelöscht.'
          : 'Die Dateien im Sicherungsbereich gehören zu mehr als einem Kontext. Nichts gelöscht.',
    );
  }
  return (benutzerKontext: b.kontext!, namen: b.namen);
}

/// Löscht die eine Datei, die der Sicherungsvorgang [id] in Moodle abgelegt hat, und
/// belegt durch Rücklesen, dass alle übrigen im Sicherungsbereich noch da sind.
Future<String> sicherungLoeschen(
  MoodleZugang moodle,
  Freigaben freigaben,
  Vorgaenge vorgaenge, {
  required String id,
  required String name,
}) async {
  if (sicherungLaeuft || wiederherstellungLaeuft) {
    throw MoodleFehler(
      'Abgebrochen, nichts gelöscht: In dieser App läuft gerade eine Sicherung oder Wiederherstellung. '
      'Beide schreiben in den Sicherungsbereich, den dieses Werkzeug neu schreibt. Später noch einmal.',
    );
  }
  final v = await vorgaenge.finde(id);
  if (v == null) throw MoodleFehler('Keine Sicherung mit der Nummer $id. Nichts gelöscht.');
  vorgaenge.pruefeBindung(v);
  if (v.wiederherstellung != null) {
    throw MoodleFehler('Nummer $id ist eine Wiederherstellung, keine Sicherung. Nichts gelöscht.');
  }
  if (v.stand != SicherungStand.fertig && v.stand != SicherungStand.fehlgeschlagen) {
    throw MoodleFehler(
      'Die Sicherung $id ist noch nicht abgeschlossen (${v.stand.text}). Erst sicherung_status abwarten. Nichts gelöscht.',
    );
  }
  final dateiname = v.dateiname, kontext = v.kontext;
  if (dateiname == null || kontext == null) {
    throw MoodleFehler(
      'Zu Sicherung $id fehlt der Dateiname in Moodle (sie kam nie bis zur Datei). Nichts gelöscht.',
    );
  }
  if (name != dateiname) {
    throw MoodleFehler(
      'Abgebrochen, nichts gelöscht: Die Datei zu Sicherung $id heißt in Moodle „$dateiname", nicht „$name". '
      'Den Namen aus sicherung_status oder der Antwort der Sicherung nehmen.',
    );
  }

  // 1. Stand lesen.
  final stand = await _bereichLesen(moodle, kontext);
  final treffer = stand.namen.where((n) => n == dateiname).length;
  if (treffer != 1) {
    throw MoodleFehler(
      treffer == 0
          ? 'Die Datei „$dateiname" liegt nicht (mehr) im Sicherungsbereich in Moodle. Nichts gelöscht.'
          : 'Der Name „$dateiname" steht mehrfach im Sicherungsbereich. Nichts gelöscht.',
    );
  }
  final bleiben = [for (final n in stand.namen) if (n != dateiname) n];

  // 2. Freigabe.
  final ja = await freigaben.anfragen(FreigabeAnfrage(
    titel: 'Sicherungsdatei in Moodle löschen?',
    punkte: [
      'Gelöscht wird genau eine Datei im persönlichen Sicherungsbereich in Moodle: $dateiname '
          '(Sicherung $id, Kurs ${v.kurs}). Die Kopie im Sicherungsordner der App bleibt.',
      if (bleiben.isEmpty)
        'Der Bereich enthält danach keine Datei mehr.'
      else
        'Diese ${bleiben.length} ${bleiben.length == 1 ? 'Datei bleibt' : 'Dateien bleiben'} erhalten:\n'
            '${bleiben.map((n) => '• $n').join('\n')}',
      'Moodle schreibt beim Speichern den ganzen Bereich neu und löscht, was im Entwurf fehlt. Die App '
          'vergleicht den Bereich deshalb noch einmal mit diesem Stand, bevor sie speichert, und liest danach '
          'zurück. Eine Datei, die in den letzten Sekunden von anderer Stelle dazukommt (etwa eine Sicherung '
          'in einem Browser), kann trotzdem verloren gehen; es gibt keinen Papierkorb.',
    ],
    vergleich: const [],
    knopf: 'Löschen',
    ohneEntscheidung: 'wird nichts gelöscht',
  ));
  if (!ja) {
    return 'Nicht gelöscht: in der App abgelehnt oder nicht innerhalb von ${freigaben.frist.inMinutes} Minuten '
        'freigegeben. Nichts geändert.';
  }
  if (sicherungLaeuft || wiederherstellungLaeuft) {
    throw MoodleFehler('Abgebrochen, nichts gelöscht: Während der Freigabe hat in der App eine Sicherung oder '
        'Wiederherstellung begonnen.');
  }

  // 3. Stand nach der Freigabe.
  final nachFreigabe = await _bereichLesen(moodle, kontext);
  if (!_gleich(nachFreigabe.namen, stand.namen) || nachFreigabe.benutzerKontext != stand.benutzerKontext) {
    throw MoodleFehler('Abgebrochen, nichts gelöscht: Der Sicherungsbereich hat sich seit der Freigabe geändert. '
        'Bitte noch einmal von vorn.');
  }

  // 4. Entwurf. UNGEMESSEN: die Feldnamen des Formulars folgen Moodles Quelltext.
  final f = await formularHolen(
    moodle,
    dateimanagerAdresse(kontext: kontext, benutzerKontext: stand.benutzerKontext),
    mitFeld: 'files_filemanager',
  );
  String? feld(String n) => wertIn(f.felder, n);
  if (feld('component') != 'user' ||
      feld('filearea') != 'backup' ||
      feld('contextid') != '${stand.benutzerKontext}' ||
      feld('currentcontext') != '$kontext') {
    throw MoodleFehler('Abgebrochen, nichts gelöscht: Der Dateimanager gehört nicht zum Sicherungsbereich.');
  }
  final bereich = f.bereiche['files_filemanager'];
  final itemid = '${bereich?['itemid'] ?? ''}';
  final clientId = '${bereich?['client_id'] ?? ''}';
  final sesskey = f.sesskey;
  if (bereich == null || itemid.isEmpty || clientId.isEmpty || sesskey == null || feld('files_filemanager') != itemid) {
    throw MoodleFehler('Abgebrochen, nichts gelöscht: Der Dateimanager liefert keinen Entwurf, den die App prüfen kann.');
  }
  final entwurf = entwurfsNamen(bereich['list']);
  if (entwurf == null || !_gleich(entwurf, stand.namen)) {
    throw MoodleFehler('Abgebrochen, nichts gelöscht: Der Entwurf des Dateimanagers entspricht nicht dem '
        'Sicherungsbereich.');
  }

  // 5. Im Entwurf entfernen und den Entwurf prüfen.
  await moodle.senden('/repository/draftfiles_ajax.php?action=delete', [
    MapEntry('itemid', itemid),
    const MapEntry('filepath', '/'),
    MapEntry('filename', dateiname),
    MapEntry('sesskey', sesskey),
  ]);
  final antwort = await moodle.senden('/repository/draftfiles_ajax.php?action=list', [
    MapEntry('itemid', itemid),
    const MapEntry('filepath', '/'),
    MapEntry('client_id', clientId),
    MapEntry('sesskey', sesskey),
  ]);
  List<String>? rest;
  try {
    final j = jsonDecode(antwort.text);
    rest = entwurfsNamen(j is Map ? j['list'] : null);
  } on FormatException {
    rest = null;
  }
  if (rest == null || !_gleich(rest, bleiben)) {
    throw MoodleFehler('Abgebrochen, nichts gelöscht: Der Entwurf zeigt nach dem Entfernen nicht genau die '
        'übrigen Dateien. Der Sicherungsbereich in Moodle blieb unverändert.');
  }

  // 6. Letzter Vergleich, dann speichern.
  final vorSpeichern = await _bereichLesen(moodle, kontext);
  if (!_gleich(vorSpeichern.namen, stand.namen)) {
    throw MoodleFehler('Abgebrochen, nichts gelöscht: Der Sicherungsbereich hat sich kurz vor dem Speichern '
        'geändert. Bitte noch einmal von vorn.');
  }
  try {
    await moodle.senden(f.aktion, [...f.felder, const MapEntry('submitbutton', 'Änderungen speichern')]);
  } on MoodleFehler {
    // Ob Moodle gespeichert hat, zeigt erst das Rücklesen.
    return await _ergebnis(moodle, kontext, id, dateiname, bleiben, ausgang: 'Moodle meldete beim Speichern einen Fehler.');
  }

  // 7. Rückleseprobe.
  return _ergebnis(moodle, kontext, id, dateiname, bleiben);
}

Future<String> _ergebnis(
  MoodleZugang moodle,
  int kontext,
  String id,
  String dateiname,
  List<String> bleiben, {
  String? ausgang,
}) async {
  ({int benutzerKontext, List<String> namen})? jetzt;
  try {
    jetzt = await _bereichLesen(moodle, kontext, leerOk: true);
  } on MoodleFehler {
    jetzt = null;
  }
  if (jetzt == null) {
    return 'Nicht geprüft: Der Sicherungsbereich ließ sich nach dem Speichern nicht lesen. '
        '${ausgang ?? ''} Mit sicherung_status und der Seite Wiederherstellen in Moodle nachsehen. verified: false';
  }
  final u = bereichsUnterschied(bleiben, jetzt.namen);
  final weg = !jetzt.namen.contains(dateiname);
  if (weg && u.fehlt.isEmpty && u.neu.isEmpty) {
    return 'Gelöscht: $dateiname (Sicherung $id). ${bleiben.isEmpty ? 'Der Sicherungsbereich enthält jetzt keine Datei mehr.' : 'Die übrigen ${bleiben.length} ${bleiben.length == 1 ? 'Datei ist' : 'Dateien sind'} im Sicherungsbereich zurückgelesen und unverändert.'} verified: true';
  }
  final teile = [
    if (!weg) 'Die Datei „$dateiname" steht noch im Sicherungsbereich.',
    if (u.fehlt.isNotEmpty)
      'Es fehlen jetzt ${u.fehlt.length} ${u.fehlt.length == 1 ? 'Datei' : 'Dateien'}, die vorher da '
          '${u.fehlt.length == 1 ? 'war' : 'waren'}: ${u.fehlt.join(', ')}.',
    if (u.neu.isNotEmpty)
      'Neu im Bereich (nicht von dieser Löschung): ${u.neu.join(', ')}.',
  ];
  return 'Abweichung beim Rücklesen (Sicherung $id): ${teile.join(' ')} ${ausgang ?? ''} verified: false';
}
