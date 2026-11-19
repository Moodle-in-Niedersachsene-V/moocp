// Werkzeugquellen des MCP-Servers: Neben den eingebauten Werkzeugen nimmt der
// Server die Werkzeuge weiterer Quellen auf, durch dieselbe Hülle (Protokoll,
// Abbruch, Fehlerantwort). Die Werkzeugliste der eingebauten Werkzeuge ist
// festgehalten: Sie ist, was die Brücke für LM Studio (E21) an ihre Clients
// weiterreicht, und darf sich durch die Quellen nicht ändern.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/freigabe.dart';
import 'package:moocp/mcp/mcp_dienst.dart';
import 'package:moocp/mcp/werkzeugquelle.dart';
import 'package:moocp/moodle/moodle_zugang.dart';
import 'package:moocp/profil.dart';
import 'package:moocp/protokoll.dart';

import 'mcp_client.dart';

/// Die eingebauten Werkzeuge in der Reihenfolge der Werkzeugliste. Ein neues
/// eingebautes Werkzeug trägt, wer es hinzufügt, hier ein: Die Brücke und die
/// Skills hängen an dieser Liste.
const _eingebaut = [
  'status',
  'meine_kurse',
  'kurs_uebersicht',
  'aktivitaet_lesen',
  'lernlandkarte_zielkontext',
  'lernlandkarte_verknuepfungen_setzen',
  'abschnitt_lesen',
  'aendern',
  'aendern_status',
  'aendern_mehrere',
  'links_setzen',
  'lernsituation_pruefen',
  'aktivitaet_anlegen',
  'abschnitt_anlegen',
  'sichtbarkeit_setzen',
  'verschieben',
  'duplizieren',
  'loeschen',
  'sichern_aktivitaet',
  'sicherung_status',
  'wiederherstellen_datei',
  'wiederherstellung_status',
  'anhaenge_reparieren',
  'sichern_auswahl',
  'uebertragen',
  'buch_lesen',
  'buchkapitel_anlegen',
  'buchkapitel_loeschen',
  'buchkapitel_verschieben',
  'buch_ordnen',
  'fragensammlungen',
  'fragetypen',
  'fragen_lesen',
  'frage_lesen',
  'fragen_importieren',
  'fragen_version_importieren',
  'fragetyp_notiz_lesen',
  'fragetyp_notiz_schreiben',
  'kategorie_anlegen',
  'fragen_loeschen',
  'frage_ersetzen',
  'stack_xml',
  'coderunner_xml',
  'stack_testen',
  'stack_varianten',
  'stack_cas',
  'kurs_hinweise',
  'claude_schreiben',
  'kurs_filter',
  'gruppierungen_lesen',
  'gruppierung_anlegen',
  'bildschirmfoto',
  'fortschrittsliste_lesen',
  'fortschrittsliste_aendern',
  'wiki_lesen',
  'wikiseite_schreiben',
  'wikiseite_loeschen',
  'board_lesen',
  'board_aendern',
  'kanban_lesen',
  'kanban_aendern',
  'bewertungsschema_lesen',
  'bewertungsschema_setzen',
  'test_lesen',
  'test_aendern',
];

/// Eine Quelle für Tests: ein Werkzeug je Beschreibung, aufgerufen wird
/// [verhalten] mit dem Namen und den Argumenten.
class _Quelle implements WerkzeugQuelle {
  _Quelle(this.beschreibungen, [this.verhalten]);

  final List<WerkzeugBeschreibung> beschreibungen;
  final Future<String> Function(String name, Map<String, dynamic> args)?
  verhalten;

  /// Die Aufrufe, wie sie bei der Quelle ankamen.
  final aufrufe = <WerkzeugAufruf>[];

  @override
  List<WerkzeugBeschreibung> werkzeuge(Profil profil) => beschreibungen;

  @override
  Future<String> aufrufen(WerkzeugAufruf aufruf) {
    aufrufe.add(aufruf);
    return verhalten!(aufruf.name, aufruf.args);
  }
}

WerkzeugBeschreibung _werkzeug(
  String name, {
  Map<String, dynamic>? schema,
  bool nurLesen = false,
  bool zerstoerend = false,
}) => WerkzeugBeschreibung(
  name: name,
  titel: 'Titel von $name',
  beschreibung: 'Beschreibung von $name.',
  eingabeSchema:
      schema ??
      {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'Wen grüßen.'},
        },
        'required': ['name'],
      },
  nurLesen: nurLesen,
  zerstoerend: zerstoerend,
);

void main() {
  late Protokoll protokoll;
  late Freigaben freigaben;
  final dienste = <McpDienst>[];
  final clients = <McpTestClient>[];

  setUp(() {
    protokoll = Protokoll();
    freigaben = Freigaben(protokoll);
  });

  tearDown(() async {
    for (final c in clients) {
      c.http.close(force: true);
    }
    clients.clear();
    for (final d in dienste) {
      await d.stoppen();
    }
    dienste.clear();
  });

  Profil profil(int port) => Profil(
    kennung: 'test',
    name: 'Test',
    adresse: 'https://moodle.schule.example',
    port: port,
    mcpName: 'test',
    schluessel: 'test',
  );

  McpDienst dienstMit(List<WerkzeugQuelle> quellen, {Profil? p}) => McpDienst(
    Einstellungen(schluessel: 'test'),
    MoodleZugang(protokoll),
    protokoll,
    freigaben,
    '',
    profil: p ?? profil(0),
    werkzeugquellen: quellen,
  );

  Future<McpTestClient> verbinden(List<WerkzeugQuelle> quellen) async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    final d = dienstMit(quellen, p: profil(port));
    dienste.add(d);
    await d.starten();
    final c = McpTestClient(port);
    clients.add(c);
    await c.initialize();
    return c;
  }

  List<Map<String, dynamic>> tools(Map<String, dynamic> liste) =>
      ((liste['tools'] as Map)['tools'] as List)
          .map((t) => (t as Map).cast<String, dynamic>())
          .toList();

  group('Werkzeugliste der eingebauten Werkzeuge', () {
    test('nennt genau diese Werkzeuge in dieser Reihenfolge', () async {
      final liste = await dienstMit(const []).werkzeugliste();

      expect(liste.keys, containsAll(['versionen', 'initialize', 'tools']));
      expect([for (final t in tools(liste)) t['name']], _eingebaut);
      expect(tools(liste), hasLength(_eingebaut.length));
    });

    test(
      'jedes Werkzeug hat Beschreibung, Eingabeschema und Hinweise',
      () async {
        final liste = await dienstMit(const []).werkzeugliste();

        for (final t in tools(liste)) {
          expect(t['description'], isA<String>(), reason: '${t['name']}');
          expect(
            (t['description'] as String).trim(),
            isNotEmpty,
            reason: '${t['name']}',
          );
          expect(
            (t['inputSchema'] as Map)['type'],
            'object',
            reason: '${t['name']}',
          );
          final hinweise = (t['annotations'] as Map).cast<String, dynamic>();
          expect(hinweise['title'], isA<String>(), reason: '${t['name']}');
          expect(hinweise['openWorldHint'], false, reason: '${t['name']}');
        }
      },
    );
  });

  group('Werkzeuge weiterer Quellen', () {
    test(
      'stehen nach den eingebauten in der Werkzeugliste, wie beschrieben',
      () async {
        final quelle = _Quelle([
          _werkzeug('probe_gruss', nurLesen: true),
          _werkzeug('probe_aufraeumen', zerstoerend: true),
        ]);

        final liste = await dienstMit([quelle]).werkzeugliste();

        final alle = tools(liste);
        expect(
          [for (final t in alle) t['name']],
          [..._eingebaut, 'probe_gruss', 'probe_aufraeumen'],
        );
        final gruss = alle.firstWhere((t) => t['name'] == 'probe_gruss');
        expect(gruss['description'], 'Beschreibung von probe_gruss.');
        expect(gruss['inputSchema'], {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': 'Wen grüßen.'},
          },
          'required': ['name'],
        });
        expect(gruss['annotations'], {
          'title': 'Titel von probe_gruss',
          'readOnlyHint': true,
          'destructiveHint': false,
          'idempotentHint': false,
          'openWorldHint': false,
        });
        final aufraeumen = alle.firstWhere(
          (t) => t['name'] == 'probe_aufraeumen',
        );
        expect((aufraeumen['annotations'] as Map)['destructiveHint'], true);
        expect((aufraeumen['annotations'] as Map)['readOnlyHint'], false);
      },
    );

    test('die Namen der eingebauten Werkzeuge sind genau diese, ohne die der Quellen', () async {
      final quelle = _Quelle([_werkzeug('probe_gruss')]);

      expect(await dienstMit([quelle]).eingebauteWerkzeugnamen(), _eingebaut.toSet());
    });

    test('ein Werkzeug mit dem Namen eines eingebauten bricht ab und nennt den Namen', () async {
      final quelle = _Quelle([_werkzeug('status')]);

      await expectLater(
        dienstMit([quelle]).werkzeugliste(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('„status"'),
          ),
        ),
      );
    });

    test('zwei Quellen mit demselben Werkzeugnamen brechen ab und nennen den Namen', () async {
      final eins = _Quelle([_werkzeug('probe_gruss')]);
      final zwei = _Quelle([_werkzeug('probe_gruss')]);

      await expectLater(
        dienstMit([eins, zwei]).werkzeugliste(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('„probe_gruss"'),
          ),
        ),
      );
    });

    test(
      'derselbe Name innerhalb einer Quelle bricht ab und nennt den Namen',
      () async {
        final quelle = _Quelle([
          _werkzeug('probe_gruss'),
          _werkzeug('probe_gruss'),
        ]);

        await expectLater(
          dienstMit([quelle]).werkzeugliste(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('„probe_gruss"'),
            ),
          ),
        );
      },
    );

    test('ein Eingabeschema, das kein Objekt beschreibt, bricht ab und nennt den Namen', () async {
      final quelle = _Quelle([
        _werkzeug('probe_gruss', schema: {'type': 'string'}),
      ]);

      await expectLater(
        dienstMit([quelle]).werkzeugliste(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('„probe_gruss"'),
          ),
        ),
      );
    });

    test(
      'ein Aufruf geht durch dieselbe Hülle: Protokoll und Antwort',
      () async {
        final quelle = _Quelle([
          _werkzeug('probe_gruss'),
        ], (name, args) async => 'Hallo ${args['name']}.\nZweite Zeile.');
        final client = await verbinden([quelle]);

        final antwort = await client.call('tools/call', {
          'name': 'probe_gruss',
          'arguments': {'name': 'Muster'},
        });

        expect(antwort['isError'], isNot(true));
        expect(
          ((antwort['content'] as List).single as Map)['text'],
          'Hallo Muster.\nZweite Zeile.',
        );
        final texte = [
          for (final e in protokoll.eintraege)
            if (e.art == Art.werkzeug || e.art == Art.info) (e.art, e.text),
        ];
        expect(
          texte,
          contains((Art.werkzeug, 'probe_gruss({"name":"Muster"})')),
        );
        expect(texte, contains((Art.info, 'probe_gruss: Hallo Muster.')));
      },
    );

    test(
      'ein Aufruf geht an die Quelle mit dem Namen, nicht an eine andere',
      () async {
        final gerufen = <String>[];
        final eins = _Quelle([_werkzeug('probe_eins')], (name, args) async {
          gerufen.add('eins:$name');
          return 'eins';
        });
        final zwei = _Quelle([_werkzeug('probe_zwei')], (name, args) async {
          gerufen.add('zwei:$name');
          return 'zwei';
        });
        final client = await verbinden([eins, zwei]);

        final text = await client.tool('probe_zwei', {'name': 'Muster'});

        expect(text, 'zwei');
        expect(gerufen, ['zwei:probe_zwei']);
      },
    );

    test('ein Fehler der Quelle kommt als Werkzeugfehler zurück, ins Protokoll mit seinem Text', () async {
      final quelle = _Quelle(
        [_werkzeug('probe_fehler'), _werkzeug('probe_ausnahme')],
        (name, args) async {
          if (name == 'probe_fehler') {
            throw MoodleFehler('Dafür fehlt das Recht.');
          }
          throw StateError('kaputt');
        },
      );
      final client = await verbinden([quelle]);

      final fehler = await client.call('tools/call', {
        'name': 'probe_fehler',
        'arguments': {'name': 'x'},
      });
      final ausnahme = await client.call('tools/call', {
        'name': 'probe_ausnahme',
        'arguments': {'name': 'x'},
      });

      expect(fehler['isError'], true);
      expect(
        ((fehler['content'] as List).single as Map)['text'],
        'Dafür fehlt das Recht.',
      );
      expect(ausnahme['isError'], true);
      expect(
        ((ausnahme['content'] as List).single as Map)['text'] as String,
        startsWith('Unerwarteter Fehler: '),
      );
      final fehlerzeilen = [
        for (final e in protokoll.eintraege)
          if (e.art == Art.fehler) e.text,
      ];
      expect(fehlerzeilen, contains('probe_fehler: Dafür fehlt das Recht.'));
      expect(
        fehlerzeilen.where((z) => z.startsWith('probe_ausnahme: ')),
        isNotEmpty,
      );
    });

    test('ein Aufruf bringt das Profil des Servers und je Aufruf ein eigenes Token mit, das nicht ins Protokoll geht', () async {
      final quelle = _Quelle([_werkzeug('probe_gruss')], (name, args) async => 'ok');
      final client = await verbinden([quelle]);

      await client.tool('probe_gruss', {'name': 'a'});
      await client.tool('probe_gruss', {'name': 'b'});

      expect(quelle.aufrufe, hasLength(2));
      expect(quelle.aufrufe.map((a) => a.profil.mcpName), ['test', 'test']);
      final tokens = quelle.aufrufe.map((a) => a.token).toList();
      expect(tokens.every((t) => t.length >= 40), isTrue, reason: '$tokens');
      expect(tokens.toSet(), hasLength(2), reason: 'je Aufruf ein neues Token');
      final zeilen = [for (final e in protokoll.eintraege) e.text].join('\n');
      for (final t in tokens) {
        expect(zeilen, isNot(contains(t)));
      }
    });

    test('bricht der Client ab, erfährt es die Quelle', () async {
      final laeuft = Completer<void>();
      late final _Quelle quelle;
      quelle = _Quelle([_werkzeug('probe_warten')], (name, args) async {
        laeuft.complete();
        await quelle.aufrufe.single.abbruch;
        return 'abgebrochen';
      });
      final client = await verbinden([quelle]);
      final verworfen = client
          .call('tools/call', {'name': 'probe_warten', 'arguments': {'name': 'x'}})
          .then<void>((_) {}, onError: (Object e) {
            if (e is! HttpException && e is! SocketException) throw e;
          });
      await laeuft.future;
      final aufruf = quelle.aufrufe.single;
      await client.notification('notifications/cancelled', {'requestId': client.id, 'reason': 'Testabbruch'});

      await aufruf.abbruch.timeout(const Duration(seconds: 10));
      client.http.close(force: true);
      await verworfen;
    });

    test('bricht der Client ab, verfällt die Freigabe des Aufrufs', () async {
      final laeuft = Completer<void>();
      final quelle = _Quelle([_werkzeug('probe_frage')], (name, args) async {
        laeuft.complete();
        final ja = await freigaben.anfragen(
          FreigabeAnfrage(
            titel: 'Probe freigeben?',
            punkte: const [],
            vergleich: const [],
          ),
        );
        return ja ? 'gespeichert' : 'abgelehnt';
      });
      final client = await verbinden([quelle]);
      // Das Ende des Aufrufs steht im Protokoll, auch wenn der Client keine
      // Antwort mehr bekommt.
      final beendet = Completer<void>();
      void geaendert() {
        if (!beendet.isCompleted &&
            protokoll.eintraege.any(
              (e) => e.text.startsWith('probe_frage: '),
            )) {
          beendet.complete();
        }
      }

      protokoll.addListener(geaendert);
      final verworfen = client
          .call('tools/call', {
            'name': 'probe_frage',
            'arguments': {'name': 'x'},
          })
          .then<void>(
            (_) {},
            onError: (Object e) {
              // Nach dem Abbruch gibt es keine Antwort mehr; der Test schließt
              // die Verbindung selbst.
              if (e is! HttpException && e is! SocketException) throw e;
            },
          );
      await laeuft.future;
      expect(freigaben.aktuell?.titel, 'Probe freigeben?');
      await client.notification('notifications/cancelled', {
        'requestId': client.id,
        'reason': 'Testabbruch',
      });
      await beendet.future.timeout(const Duration(seconds: 10));
      protokoll.removeListener(geaendert);

      final texte = [for (final e in protokoll.eintraege) e.text];
      expect(texte, contains('Die KI wartet nicht mehr -- nicht gespeichert'));
      expect(texte, contains('probe_frage: abgelehnt'));
      expect(freigaben.aktuell, isNull);
      client.http.close(force: true);
      await verworfen;
    });
  });
}
