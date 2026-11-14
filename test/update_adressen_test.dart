// Welche Update-Adresse gefragt wird und wann die App warnt, dass keine mehr
// taugt. GitHub ist hier nachgestellt (HttpOverrides); die Antworten sind die,
// die GitHub bei einem umgezogenen Repository und bei einem fehlenden
// Repository tatsächlich gibt.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen.dart';
import 'package:moocp/plugin/beschreibung.dart';
import 'package:moocp/plugin/plugin_update.dart';
import 'package:moocp/plugin/plugins.dart';
import 'package:moocp/plugin/schnittstelle.dart';
import 'package:moocp/protokoll.dart';
import 'package:moocp/update/update.dart';
import 'package:moocp/update/update_dialoge.dart';
import 'package:moocp/update/updateliste.dart';

final String _verein = releaseAbfrage('Moodle-in-Niedersachsene-V/moocp').toString();
final String _alt = releaseAbfrage('topse/moocp').toString();
const String _warnung = 'Automatische Updates sind anscheinend nicht mehr möglich.';

/// Eine vorbereitete Antwort von GitHub, oder [fehler] statt einer Antwort.
class _Soll {
  _Soll(this.status, {this.ort, this.text = '', this.fehler});
  final int status;
  final String? ort;
  final String text;
  final Object? fehler;
}

_Soll _release(String herkunft, String version) => _Soll(
      200,
      text: jsonEncode({
        'tag_name': 'v$version',
        'assets': [
          {
            'name': 'moocp_setup_$version.exe',
            'browser_download_url':
                'https://github.com/$herkunft/releases/download/v$version/moocp_setup_$version.exe',
          }
        ],
      }),
    );

_Soll _releaseMit(String herkunft, String version, String dateiname) => _Soll(
      200,
      text: jsonEncode({
        'tag_name': 'v$version',
        'assets': [
          {
            'name': dateiname,
            'browser_download_url': 'https://github.com/$herkunft/releases/download/v$version/$dateiname',
          }
        ],
      }),
    );

class _Kopf extends Fake implements HttpHeaders {
  _Kopf(this.ort);
  final String? ort;

  @override
  String? value(String name) => name == HttpHeaders.locationHeader ? ort : null;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _Antwort extends Stream<List<int>> implements HttpClientResponse {
  _Antwort(this.soll);
  final _Soll soll;

  @override
  int get statusCode => soll.status;

  @override
  HttpHeaders get headers => _Kopf(soll.ort);

  @override
  int get contentLength => -1;

  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream<List<int>>.fromIterable([utf8.encode(soll.text)])
          .listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Anfrage extends Fake implements HttpClientRequest {
  _Anfrage(this.soll);
  final _Soll soll;

  @override
  set followRedirects(bool wert) {}

  @override
  HttpHeaders get headers => _Kopf(null);

  @override
  Future<HttpClientResponse> close() async => _Antwort(soll);
}

class _Klient extends Fake implements HttpClient {
  _Klient(this.github);
  final _GitHub github;

  @override
  set connectionTimeout(Duration? wert) {}

  @override
  set userAgent(String? wert) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    github.gefragt.add(url.toString());
    final soll = github.antworten[url.toString()];
    if (soll == null) throw StateError('Unerwartete Anfrage: $url');
    if (soll.fehler != null) throw soll.fehler!;
    return _Anfrage(soll);
  }

  @override
  void close({bool force = false}) {}
}

class _GitHub extends HttpOverrides {
  _GitHub(this.antworten);
  final Map<String, _Soll> antworten;
  final List<String> gefragt = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Klient(this);
}

/// Speichert nicht: updateSchritt schriebe sonst in die echten Einstellungen.
class _Einstellungen extends Einstellungen {
  _Einstellungen() : super(schluessel: 'x', updatePruefen: true);

  @override
  Future<void> speichern() async {}
}

void main() {
  Future<NeueVersion?> pruefen(_GitHub github) => HttpOverrides.runWithHttpOverrides(
      () => Update(Protokoll()).pruefen('0.10.0'), github);

  group('Welche Adresse gilt', () {
    test('hat der Verein ein Release, wird die alte Adresse nicht gefragt', () async {
      final github = _GitHub({_verein: _release('Moodle-in-Niedersachsene-V/moocp', '0.11.0')});
      final neu = await pruefen(github);
      expect(neu?.version, '0.11.0');
      expect(neu?.datei.path, startsWith('/Moodle-in-Niedersachsene-V/moocp/'));
      expect(github.gefragt, [_verein]);
    });

    test('ohne Release beim Verein gilt die alte Adresse', () async {
      final github = _GitHub({
        _verein: _Soll(404),
        _alt: _release('topse/moocp', '0.11.0'),
      });
      final neu = await pruefen(github);
      expect(neu?.version, '0.11.0');
      expect(neu?.datei.path, startsWith('/topse/moocp/'));
    });
  });

  group('Wann keine Adresse mehr taugt', () {
    test('beide 404', () async {
      final github = _GitHub({_verein: _Soll(404), _alt: _Soll(404)});
      await expectLater(pruefen(github), throwsA(isA<UpdateAdressenWeg>()));
    });

    test('Umleitung innerhalb der API, wie bei einem umgezogenen Repository', () async {
      final umzug = 'https://api.github.com/repositories/401025/releases/latest';
      final github = _GitHub({
        _verein: _Soll(301, ort: umzug),
        _alt: _Soll(301, ort: umzug),
      });
      await expectLater(pruefen(github), throwsA(isA<UpdateAdressenWeg>()));
      expect(github.gefragt, isNot(contains(umzug)), reason: 'das Ziel steht nicht auf der Liste');
    });
  });

  group('Was nichts über die Adressen sagt', () {
    Matcher nurFehler = throwsA(allOf(isA<UpdateFehler>(), isNot(isA<UpdateAdressenWeg>())));

    for (final status in [403, 429, 500, 503]) {
      test('$status: keine Warnung, und die alte Adresse wird nicht gefragt', () async {
        final github = _GitHub({_verein: _Soll(status)});
        await expectLater(pruefen(github), nurFehler);
        expect(github.gefragt, [_verein]);
      });
    }

    test('kein Netz bei der zweiten Adresse', () async {
      final github = _GitHub({
        _verein: _Soll(404),
        _alt: _Soll(0, fehler: const SocketException('kein Netz')),
      });
      await expectLater(pruefen(github), nurFehler);
    });

    test('ein Schulproxy leitet auf seine Anmeldeseite um', () async {
      final github = _GitHub({_verein: _Soll(302, ort: 'http://proxy.schule.example/anmelden')});
      await expectLater(pruefen(github), nurFehler);
    });
  });

  group('Was die Lehrkraft sieht', () {
    late HttpOverrides? vorher;
    setUp(() => vorher = HttpOverrides.current);
    tearDown(() => HttpOverrides.global = vorher);

    Future<void> lauf(WidgetTester tester, _GitHub github, {bool manuell = false}) async {
      HttpOverrides.global = github;
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      final context = tester.element(find.byType(Scaffold));
      unawaited(updateSchritt(
        context,
        einstellungen: _Einstellungen(),
        protokoll: Protokoll(),
        eigene: '0.10.0',
        manuell: manuell,
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('die Warnung beim Start, wenn keine Adresse mehr taugt', (tester) async {
      await lauf(tester, _GitHub({_verein: _Soll(404), _alt: _Soll(404)}));
      expect(find.text(_warnung), findsOneWidget);
      expect(find.textContaining('Bitte besorgen Sie sich die aktuelle Version manuell.'), findsOneWidget);
      await tester.tap(find.text('Schließen'));
      await tester.pumpAndSettle();
      expect(find.text(_warnung), findsNothing);
    });

    testWidgets('die Warnung auch bei der Suche von Hand', (tester) async {
      await lauf(tester, _GitHub({_verein: _Soll(404), _alt: _Soll(404)}), manuell: true);
      expect(find.text(_warnung), findsOneWidget);
    });

    testWidgets('beim Start still, wenn GitHub nur gerade nicht will', (tester) async {
      await lauf(tester, _GitHub({_verein: _Soll(403)}));
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('bei einem Release das Angebot statt der Warnung', (tester) async {
      await lauf(tester, _GitHub({_verein: _Soll(404), _alt: _release('topse/moocp', '0.11.0')}));
      expect(find.text(_warnung), findsNothing);
      expect(find.text('Version 0.11.0 ist verfügbar'), findsOneWidget);
    });
  });

  group('Eine andere Liste von Herkünften und ein anderes Namensmuster', () {
    const erste = 'beispiel-org/zusatz';
    const zweite = 'beispiel-org/zusatz-alt';
    final abfrageErste = releaseAbfrage(erste).toString();
    final abfrageZweite = releaseAbfrage(zweite).toString();
    const quellen = [erste, zweite];
    const anfang = 'zusatz_setup';

    Future<NeueVersion?> pruefenMit(_GitHub github,
            {List<String> liste = quellen, String eigene = '1.0.0'}) =>
        HttpOverrides.runWithHttpOverrides(
            () => Update(Protokoll(), quellen: liste, installerAnfang: anfang).pruefen(eigene), github);

    _Soll release(String herkunft, String version) =>
        _releaseMit(herkunft, version, '${anfang}_$version.exe');

    test('die erste Herkunft zuerst; hat sie ein Release, wird die zweite nicht gefragt', () async {
      final github = _GitHub({abfrageErste: release(erste, '1.2.0')});
      final neu = await pruefenMit(github);
      expect(neu?.version, '1.2.0');
      expect(neu?.dateiname, 'zusatz_setup_1.2.0.exe');
      expect(neu?.datei.path, startsWith('/$erste/'));
      expect(github.gefragt, [abfrageErste]);
    });

    test('ohne Release bei der ersten gilt die zweite, die von moocp werden nie gefragt', () async {
      final github = _GitHub({abfrageErste: _Soll(404), abfrageZweite: release(zweite, '1.2.0')});
      final neu = await pruefenMit(github);
      expect(neu?.datei.path, startsWith('/$zweite/'));
      expect(github.gefragt, [abfrageErste, abfrageZweite]);
      expect(github.gefragt, isNot(contains(_verein)));
      expect(github.gefragt, isNot(contains(_alt)));
    });

    test('ist die laufende Version schon die neueste, gibt es nichts Neues', () async {
      final github = _GitHub({abfrageErste: release(erste, '1.2.0')});
      expect(await pruefenMit(github, eigene: '1.2.0'), isNull);
    });

    test('keine Herkunft der Liste mehr: die Warnung, nach genau diesen Anfragen', () async {
      final github = _GitHub({abfrageErste: _Soll(404), abfrageZweite: _Soll(410)});
      await expectLater(pruefenMit(github), throwsA(isA<UpdateAdressenWeg>()));
      expect(github.gefragt, [abfrageErste, abfrageZweite]);
    });

    test('Umleitung innerhalb der API: diese Herkunft taugt nicht mehr, die nächste wird gefragt', () async {
      const umzug = 'https://api.github.com/repositories/401025/releases/latest';
      final github = _GitHub({
        abfrageErste: _Soll(301, ort: umzug),
        abfrageZweite: release(zweite, '1.2.0'),
      });
      final neu = await pruefenMit(github);
      expect(neu?.datei.path, startsWith('/$zweite/'));
      expect(github.gefragt, isNot(contains(umzug)), reason: 'das Ziel steht nicht auf der Liste');
    });

    test('was nichts über die Adressen sagt, ist keine Warnung, und die zweite wird nicht gefragt', () async {
      final github = _GitHub({abfrageErste: _Soll(403)});
      await expectLater(pruefenMit(github),
          throwsA(allOf(isA<UpdateFehler>(), isNot(isA<UpdateAdressenWeg>()))));
      expect(github.gefragt, [abfrageErste]);
    });

    test('der Installer muss aus einer Herkunft der Liste kommen', () async {
      // Ein Release, das auf den Installer eines anderen Repositorys zeigt.
      final github = _GitHub({
        abfrageErste: _Soll(200,
            text: jsonEncode({
              'tag_name': 'v1.2.0',
              'assets': [
                {
                  'name': 'zusatz_setup_1.2.0.exe',
                  'browser_download_url':
                      'https://github.com/topse/moocp/releases/download/v1.2.0/zusatz_setup_1.2.0.exe',
                }
              ],
            })),
      });
      await expectLater(
          pruefenMit(github),
          throwsA(isA<UpdateFehler>().having((e) => e.meldung, 'meldung', contains('nicht erlaubt'))));
    });

    test('der Installer wird nach dem Namensmuster gesucht, nicht nach dem von moocp', () async {
      final github = _GitHub({
        abfrageErste: _releaseMit(erste, '1.2.0', 'moocp_setup_1.2.0.exe'),
      });
      await expectLater(
          pruefenMit(github),
          throwsA(isA<UpdateFehler>()
              .having((e) => e.meldung, 'meldung', contains('zusatz_setup_1.2.0.exe'))));
    });

    test('ohne Herkunft oder mit einem Namen, der keine ist, wird nichts gefragt', () async {
      for (final liste in [
        <String>[],
        ['x/y/../../../users/z'],
        [erste, 'topse/moocp?x=1'],
      ]) {
        final github = _GitHub({abfrageErste: release(erste, '1.2.0')});
        await expectLater(pruefenMit(github, liste: liste),
            throwsA(allOf(isA<UpdateFehler>(), isNot(isA<UpdateAdressenWeg>()))),
            reason: '$liste');
        expect(github.gefragt, isEmpty, reason: '$liste');
      }
    });

    test('der Download folgt der Umleitung auf den Speicherdienst, aber nur aus der Liste', () async {
      final github = _GitHub({
        'https://github.com/$erste/releases/download/v1.2.0/zusatz_setup_1.2.0.exe':
            _Soll(302, ort: 'https://objects.githubusercontent.com/x?token=abc'),
        'https://objects.githubusercontent.com/x?token=abc': _Soll(200, text: 'Installer'),
      });
      final neu = NeueVersion(
        version: 'nur-fuer-den-test',
        datei: Uri.parse('https://github.com/$erste/releases/download/v1.2.0/zusatz_setup_1.2.0.exe'),
        dateiname: 'zusatz_setup_1.2.0.exe',
      );
      addTearDown(() => wegwerfen(installerDatei(neu.version)));
      final datei = await HttpOverrides.runWithHttpOverrides(
          () => Update(Protokoll(), quellen: quellen, installerAnfang: anfang)
              .herunterladen(neu, (_, _) {}),
          github);
      expect(datei.readAsStringSync(), 'Installer');

      // Dieselbe Adresse bei einem Update, das sie nicht in der Liste hat.
      final fremd = _GitHub({});
      await expectLater(
          HttpOverrides.runWithHttpOverrides(
              () => Update(Protokoll(), quellen: const ['andere-org/zusatz'], installerAnfang: anfang)
                  .herunterladen(neu, (_, _) {}),
              fremd),
          throwsA(isA<UpdateFehler>()));
      expect(fremd.gefragt, isEmpty);
    });
  });

  group('Die Update-Prüfung eines Plugins', () {
    // Die Prüfung von moocp mit den Repositorys aus der Beschreibungsdatei
    // (plugin/plugin_update.dart, pluginUpdate). Erfundene Repositorys.
    PluginBeschreibung beschreibung(String name, String kurzname, List<String> quellen, {String version = '1.0.0'}) =>
        PluginBeschreibung.ausJson({
          'name': name,
          'kurzname': kurzname,
          'version': version,
          'schnittstelle': 1,
          'programm': 'plugin.exe',
          'herkunft': 'Beispiel-Projekt',
          'updateQuellen': quellen,
        });

    const erste = 'beispiel-org/beispiel-plugin';
    const zweite = 'beispiel-alt/beispiel-plugin';
    final b = beschreibung('Beispiel', 'beispiel', const [erste, zweite]);

    Future<NeueVersion?> pruefenMit(_GitHub github, {PluginBeschreibung? fuer}) =>
        HttpOverrides.runWithHttpOverrides(() {
          final x = fuer ?? b;
          return pluginUpdate(x, Protokoll()).pruefen(x.version);
        }, github);

    test('in der Reihenfolge der Beschreibungsdatei; hat das erste ein Release, wird das zweite nicht gefragt', () async {
      final github = _GitHub({releaseAbfrage(erste).toString(): _releaseMit(erste, '1.1.0', 'beispiel_setup_1.1.0.exe')});
      final neu = await pruefenMit(github);
      expect(neu?.dateiname, 'beispiel_setup_1.1.0.exe');
      expect(github.gefragt, [releaseAbfrage(erste).toString()]);
    });

    test('das zweite nur ohne Release im ersten, nie die höchste Version über beide, nie die Repositorys von moocp', () async {
      final github = _GitHub({
        releaseAbfrage(erste).toString(): _releaseMit(erste, '1.1.0', 'beispiel_setup_1.1.0.exe'),
        releaseAbfrage(zweite).toString(): _releaseMit(zweite, '9.0.0', 'beispiel_setup_9.0.0.exe'),
      });
      expect((await pruefenMit(github))?.version, '1.1.0', reason: 'das erste gilt, auch wenn das zweite höher ist');

      final ohneErstes = _GitHub({
        releaseAbfrage(erste).toString(): _Soll(404),
        releaseAbfrage(zweite).toString(): _releaseMit(zweite, '1.2.0', 'beispiel_setup_1.2.0.exe'),
      });
      final neu = await pruefenMit(ohneErstes);
      expect(neu?.datei.path, startsWith('/$zweite/'));
      expect(ohneErstes.gefragt, [releaseAbfrage(erste).toString(), releaseAbfrage(zweite).toString()]);
      expect(ohneErstes.gefragt, isNot(contains(_verein)));
      expect(ohneErstes.gefragt, isNot(contains(_alt)));
    });

    test('der Installer muss aus einem Repository des Plugins kommen, nicht aus dem von moocp', () async {
      final github = _GitHub({
        releaseAbfrage(erste).toString(): _Soll(200,
            text: jsonEncode({
              'tag_name': 'v1.1.0',
              'assets': [
                {
                  'name': 'beispiel_setup_1.1.0.exe',
                  'browser_download_url':
                      'https://github.com/topse/moocp/releases/download/v1.1.0/beispiel_setup_1.1.0.exe',
                }
              ],
            })),
      });
      await expectLater(pruefenMit(github),
          throwsA(isA<UpdateFehler>().having((e) => e.meldung, 'meldung', contains('nicht erlaubt'))));
    });

    test('ein scheiterndes Plugin-Update neben einem funktionierenden, über die echte Prüfung', () async {
      final wurzel = Directory.systemTemp.createTempSync('moocp_plugin_update_');
      addTearDown(() => wurzel.deleteSync(recursive: true));
      for (final (ordner, name, kurzname, quelle) in [
        ('a', 'Alpha', 'alpha', 'beispiel-org/alpha'),
        ('b', 'Beta', 'beta', 'beispiel-org/beta'),
      ]) {
        final d = Directory('${wurzel.path}/$ordner')..createSync();
        File('${d.path}/plugin.json').writeAsStringSync(jsonEncode({
          'name': name,
          'kurzname': kurzname,
          'version': '1.0.0',
          'schnittstelle': 1,
          'programm': 'plugin.exe',
          'herkunft': 'Beispiel-Projekt',
          'updateQuellen': [quelle],
        }));
        File('${d.path}/plugin.exe').writeAsStringSync(name);
      }
      final einstellungen = _Einstellungen();
      final protokoll = Protokoll();
      final plugins = await Plugins.laden(einstellungen, protokoll, wurzel);
      for (final e in plugins.eintraege) {
        await plugins.entscheiden(e, zugestimmt: true, profile: {'standard'});
      }
      final github = _GitHub({
        releaseAbfrage('beispiel-org/alpha').toString(): _Soll(503),
        releaseAbfrage('beispiel-org/beta').toString():
            _releaseMit('beispiel-org/beta', '1.1.0', 'beta_setup_1.1.0.exe'),
      });
      final angeboten = <String>[];
      final ergebnis = await HttpOverrides.runWithHttpOverrides(
          () => pluginsPruefen(
                plugins: plugins,
                einstellungen: einstellungen,
                protokoll: protokoll,
                updatefaehig: true,
                moocpUpdateMoeglich: true,
                appVersion: '0.11.0',
                dialoge: _PluginDialoge(angeboten),
              ),
          github);
      expect(angeboten, ['Beta 1.1.0']);
      expect(ergebnis.beenden, isFalse);
      expect(protokoll.eintraege.map((e) => e.text),
          contains('Plugin „Alpha“: Update nicht möglich (GitHub antwortet mit 503.)'));
      expect(github.gefragt, [
        releaseAbfrage('beispiel-org/alpha').toString(),
        releaseAbfrage('beispiel-org/beta').toString(),
      ]);
    });
  });

  group('Was die Lehrkraft bei einem Plugin sieht', () {
    PluginEintrag eintrag(SchnittstellenUrteil urteil) {
      final b = PluginBeschreibung.ausJson({
        'name': 'Beispiel',
        'kurzname': 'beispiel',
        'version': '1.0.0',
        'schnittstelle': urteil == SchnittstellenUrteil.moocpZuAlt ? 2 : 1,
        'programm': 'plugin.exe',
        'herkunft': 'Beispiel-Projekt',
      });
      return PluginEintrag(
        ordner: 'beispiel',
        pfad: '/nirgends',
        beschreibung: b,
        pruefsumme: 'x',
        fehler: schnittstelleGrund(urteil, b.schnittstelle, angeboten: {urteil == SchnittstellenUrteil.moocpZuAlt ? 1 : 2}),
        unpassend: urteil,
      );
    }

    Future<bool?> zeigen(WidgetTester tester, Widget dialog) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      final context = tester.element(find.byType(Scaffold));
      bool? antwort;
      unawaited(showDialog<bool>(context: context, builder: (_) => dialog).then((a) => antwort = a));
      await tester.pumpAndSettle();
      return antwort;
    }

    testWidgets('moocp zu alt: welche Seite, und das Angebot, nach moocp zu suchen', (tester) async {
      await zeigen(tester, PluginSchnittstelleDialog(eintrag: eintrag(SchnittstellenUrteil.moocpZuAlt), moocpUpdate: true));
      expect(find.text('Plugin „Beispiel“ bleibt aus'), findsOneWidget);
      expect(find.textContaining('moocp ist zu alt'), findsOneWidget);
      expect(find.text('Nach einem Update von moocp suchen'), findsOneWidget);
      expect(find.text('Ohne das Plugin weiter'), findsOneWidget);
    });

    testWidgets('Plugin zu alt mit gefundenem Update: das Angebot des Plugins', (tester) async {
      final e = eintrag(SchnittstellenUrteil.pluginZuAlt);
      final p = PluginUpdatePruefung(e, pluginUpdate(e.beschreibung!, Protokoll()),
          neu: NeueVersion(version: '2.0.0', datei: Uri.parse('https://github.com/x/y'), dateiname: 'beispiel_setup_2.0.0.exe'));
      await zeigen(tester, PluginSchnittstelleDialog(eintrag: e, pruefung: p));
      expect(find.textContaining('Das Plugin ist zu alt'), findsOneWidget);
      expect(find.textContaining('Version 2.0.0'), findsOneWidget);
      expect(find.text('Update des Plugins ansehen …'), findsOneWidget);
    });

    testWidgets('Plugin zu alt ohne Update: nur der Hinweis, kein Knopf für ein Update', (tester) async {
      await zeigen(tester, PluginSchnittstelleDialog(eintrag: eintrag(SchnittstellenUrteil.pluginZuAlt)));
      expect(find.textContaining('Wenden Sie sich an den Autor'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      await tester.tap(find.text('Ohne das Plugin weiter'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}

/// Nimmt jedes Angebot an, ohne etwas zu laden.
class _PluginDialoge implements PluginPruefDialoge {
  _PluginDialoge(this.angeboten);
  final List<String> angeboten;

  @override
  Future<bool> schnittstelle(PluginEintrag e, {bool moocpUpdate = false, PluginUpdatePruefung? pruefung}) async => false;

  @override
  Future<bool> moocpAktualisieren() async => false;

  @override
  Future<bool> angebot(PluginUpdatePruefung p) async {
    angeboten.add('${p.eintrag.beschreibung!.name} ${p.neu!.version}');
    return false;
  }

  @override
  Future<void> adressenWeg(PluginUpdatePruefung p) async {}
}
