import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/anmeldung.dart';

void main() {
  test('gebundenes Debug-Testprofil meldet sich vor wartender Einrichtung an', () async {
    final aufrufe = <String>[];

    final bereit = await testprofilVorEinrichtungStarten(
      gebunden: true,
      anmelden: () async => aufrufe.add('anmelden'),
      einrichtungPruefen: () async {
        aufrufe.add('einrichtung');
        return false;
      },
    );

    expect(bereit, isFalse);
    expect(aufrufe, ['anmelden', 'einrichtung']);
  });

  test('normaler Start meldet sich erst nach erfolgreicher Einrichtung an', () async {
    final aufrufe = <String>[];

    final bereit = await testprofilVorEinrichtungStarten(
      gebunden: false,
      anmelden: () async => aufrufe.add('anmelden'),
      einrichtungPruefen: () async {
        aufrufe.add('einrichtung');
        return true;
      },
    );

    expect(bereit, isTrue);
    expect(aufrufe, ['einrichtung', 'anmelden']);
  });

  test('abgelehnte Einrichtung startet kein ungebundenes Testprofil', () async {
    final aufrufe = <String>[];

    final bereit = await testprofilVorEinrichtungStarten(
      gebunden: false,
      anmelden: () async => aufrufe.add('anmelden'),
      einrichtungPruefen: () async {
        aufrufe.add('einrichtung');
        return false;
      },
    );

    expect(bereit, isFalse);
    expect(aufrufe, ['einrichtung']);
  });

  group('Die Reihenfolge bis zur Anmeldung', () {
    /// Der ganze Weg mit allen Schritten, wie _starten ihn geht: Update, Plugins,
    /// dann Einrichtung und Anmeldung (testprofilVorEinrichtungStarten).
    Future<StartAusgang> ablaufen(
      List<String> aufrufe, {
      bool updateBeendet = false,
      bool einrichtungGelingt = true,
      bool Function()? weiter,
    }) =>
        startBisAnmeldung(
          update: () async {
            aufrufe.add('update');
            return updateBeendet;
          },
          plugins: () async => aufrufe.add('plugins'),
          einrichtungUndAnmeldung: () => testprofilVorEinrichtungStarten(
            gebunden: false,
            anmelden: () async => aufrufe.add('anmelden'),
            einrichtungPruefen: () async {
              aufrufe.add('einrichtung');
              return einrichtungGelingt;
            },
          ),
          weiter: weiter ?? () => true,
        );

    test('erst das Update der App, dann die Zustimmung zu Plugins, dann die Einrichtung, dann die Anmeldung', () async {
      final aufrufe = <String>[];
      expect(await ablaufen(aufrufe), StartAusgang.bereit);
      expect(aufrufe, ['update', 'plugins', 'einrichtung', 'anmelden']);
    });

    test('läuft ein Update-Installer, endet der Start: keine Frage zu Plugins, keine Einrichtung', () async {
      final aufrufe = <String>[];
      expect(await ablaufen(aufrufe, updateBeendet: true), StartAusgang.beenden);
      expect(aufrufe, ['update']);
    });

    test('ohne Einrichtung keine Anmeldung, aber die Plugins sind davor schon gefragt', () async {
      final aufrufe = <String>[];
      expect(await ablaufen(aufrufe, einrichtungGelingt: false), StartAusgang.abgebrochen);
      expect(aufrufe, ['update', 'plugins', 'einrichtung']);
    });

    test('ist die Oberfläche weg, geht der Start nicht weiter', () async {
      final aufrufe = <String>[];
      var weg = false;
      final ausgang = await startBisAnmeldung(
        update: () async {
          aufrufe.add('update');
          weg = true;
          return false;
        },
        plugins: () async => aufrufe.add('plugins'),
        einrichtungUndAnmeldung: () async {
          aufrufe.add('einrichtung');
          return true;
        },
        weiter: () => !weg,
      );
      expect(ausgang, StartAusgang.abgebrochen);
      expect(aufrufe, ['update']);
    });
  });
}
