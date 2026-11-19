// fragen_importieren mit Rundlaufprobe (E38) gegen das Moodle-Doppel mit
// Fragensammlung: Eine Frage, die die Probe nicht besteht, bleibt nicht stehen;
// jeder Typ darf zur Probe, auch einer, der in keiner Liste steht.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/moodle/fragen.dart';
import 'package:moocp/moodle/rundlaufprobe.dart';
import 'package:moocp/protokoll.dart';
import 'package:path/path.dart' as p;

import 'hilfen/fragenbank_doppel.dart';

void main() {
  late FragenbankDoppel moodle;
  late Directory ao;
  late Freigaben freigaben;

  setUp(() async {
    moodle = FragenbankDoppel();
    await moodle.starten();
    ao = Directory.systemTemp.createTempSync('import-probe-');
    freigaben = Freigaben(Protokoll(), stufe: Bestaetigungen.keine);
  });

  tearDown(() async {
    await moodle.stoppen();
    ao.deleteSync(recursive: true);
  });

  /// Der Weg des Werkzeugs: importieren, Nachweise, Rundlaufprobe.
  Future<({String text, bool verified})> importieren(String typ, String name, String idn) async {
    File(p.join(ao.path, 'f.xml')).writeAsStringSync(
        '<?xml version="1.0" encoding="UTF-8"?><quiz>${FragenbankDoppel.frageXml(typ, name, idn, 'A')}</quiz>');
    final zugang = await moodle.zugang();
    final i = await fragenImportieren(zugang, freigaben, ao.path, sammlung: FragenbankDoppel.sammlung, kategorie: 'ZZ Probe', datei: 'f.xml');
    final n = await importNachweise(zugang, FragenbankDoppel.sammlung, i.neu, (_) async => '');
    final r = await importProben(zugang, ao.path, FragenbankDoppel.sammlung, i, n.neueIds, i.xml);
    return (text: '${i.text}${r.text}', verified: i.ok && n.ok && r.verified);
  }

  test('Eine gute Frage wird angelegt und bleibt stehen, ohne Probeversion', () async {
    final r = await importieren('shortanswer', 'ZZ Neu', 'zz-neu');
    expect(r.verified, isTrue, reason: r.text);
    expect(moodle.eintraege, hasLength(1));
    expect(moodle.eintraege.single.versionen, hasLength(1));
  });

  test('Ein Typ, der in keiner Liste steht, geht zur Probe', () async {
    final r = await importieren('formulas', 'ZZ Formel', 'zz-f');
    expect(r.verified, isTrue, reason: r.text);
    expect(moodle.eintraege.single.typ, 'formulas');
  });

  test('Verliert Moodle beim Anlegen etwas, wird die neue Frage wieder gelöscht', () async {
    moodle.beimSpeichern = (x) => x.replaceAll(RegExp(r'<answer.*?</answer>', dotAll: true), '');
    final r = await importieren('shortanswer', 'ZZ Neu', 'zz-neu');
    expect(r.verified, isFalse);
    expect(r.text, contains('NICHT bestanden'));
    expect(moodle.eintraege.where((e) => e.versionen.isNotEmpty), isEmpty, reason: 'nichts Fehlerhaftes bleibt stehen');
    expect(moodle.geloescht, hasLength(1));
  });

  test('Eine vorhandene Frage wird nie angefasst', () async {
    final alt = moodle.legeAn('shortanswer', 'ZZ Alt', 'zz-alt');
    moodle.beimSpeichern = (x) => x.replaceAll(RegExp(r'<answer.*?</answer>', dotAll: true), '');
    await importieren('shortanswer', 'ZZ Neu', 'zz-neu');
    expect(alt.versionen, hasLength(1));
    expect(moodle.geloescht, isNot(contains(alt.neueste.id)));
  });
}
