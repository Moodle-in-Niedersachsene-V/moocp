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
    /// Der ganze Weg mit allen Schritten, wie _starten ihn geht: Update der
    /// App, Prüfung je Plugin (Schnittstelle, Update), Zustimmung zu Plugins,
    /// Start der Plugins, dann Einrichtung und Anmeldung
    /// (testprofilVorEinrichtungStarten).
    Future<StartAusgang> ablaufen(
      List<String> aufrufe, {
      bool updateBeendet = false,
      bool pluginPruefungBeendet = false,
      bool einrichtungGelingt = true,
      bool Function()? weiter,
    }) =>
        startBisAnmeldung(
          update: () async {
            aufrufe.add('update');
            return updateBeendet;
          },
          pluginPruefung: () async {
            aufrufe.add('plugin-prüfung');
            return pluginPruefungBeendet;
          },
          pluginZustimmung: () async => aufrufe.add('zustimmung'),
          pluginsStarten: () async => aufrufe.add('plugins starten'),
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

    test('erst das Update der App, dann die Prüfung je Plugin, die Zustimmung, ihr Start, die Einrichtung, die Anmeldung', () async {
      final aufrufe = <String>[];
      expect(await ablaufen(aufrufe), StartAusgang.bereit);
      expect(aufrufe, ['update', 'plugin-prüfung', 'zustimmung', 'plugins starten', 'einrichtung', 'anmelden']);
    });

    test('läuft ein Update-Installer, endet der Start: keine Prüfung und keine Frage zu Plugins, keine Einrichtung', () async {
      final aufrufe = <String>[];
      expect(await ablaufen(aufrufe, updateBeendet: true), StartAusgang.beenden);
      expect(aufrufe, ['update']);
    });

    test('startet die Prüfung der Plugins den Installer von moocp, endet der Start dort', () async {
      final aufrufe = <String>[];
      expect(await ablaufen(aufrufe, pluginPruefungBeendet: true), StartAusgang.beenden);
      expect(aufrufe, ['update', 'plugin-prüfung']);
    });

    test('ohne Einrichtung keine Anmeldung, aber die Plugins sind davor schon geprüft, gefragt und gestartet', () async {
      final aufrufe = <String>[];
      expect(await ablaufen(aufrufe, einrichtungGelingt: false), StartAusgang.abgebrochen);
      expect(aufrufe, ['update', 'plugin-prüfung', 'zustimmung', 'plugins starten', 'einrichtung']);
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
        pluginPruefung: () async {
          aufrufe.add('plugin-prüfung');
          return false;
        },
        pluginZustimmung: () async => aufrufe.add('zustimmung'),
        pluginsStarten: () async => aufrufe.add('plugins starten'),
        einrichtungUndAnmeldung: () async {
          aufrufe.add('einrichtung');
          return true;
        },
        weiter: () => !weg,
      );
      expect(ausgang, StartAusgang.abgebrochen);
      expect(aufrufe, ['update']);
    });

    test('ist die Oberfläche nach der Zustimmung weg, startet kein Plugin', () async {
      final aufrufe = <String>[];
      var weg = false;
      final ausgang = await startBisAnmeldung(
        update: () async {
          aufrufe.add('update');
          return false;
        },
        pluginPruefung: () async {
          aufrufe.add('plugin-prüfung');
          return false;
        },
        pluginZustimmung: () async {
          aufrufe.add('zustimmung');
          weg = true;
        },
        pluginsStarten: () async => aufrufe.add('plugins starten'),
        einrichtungUndAnmeldung: () async {
          aufrufe.add('einrichtung');
          return true;
        },
        weiter: () => !weg,
      );
      expect(ausgang, StartAusgang.abgebrochen);
      expect(aufrufe, ['update', 'plugin-prüfung', 'zustimmung']);
    });

    /// Der ganze Weg bis zum MCP-Server, wie _starten und _anmelden ihn
    /// gehen: startBisAnmeldung, danach nachEinrichtung mit einem Profil,
    /// dessen Server vor der Anmeldung startet, wenn dort ein Plugin mit
    /// Werkzeugen ohne Anmeldung eingeschaltet ist; nach der Anmeldung
    /// startet jeder Server, der noch nicht läuft (_mcpStarten).
    Future<List<String>> bisZumServer({required bool ohneAnmeldung}) async {
      final aufrufe = <String>[];
      var laeuft = false;
      final ausgang = await startBisAnmeldung(
        update: () async {
          aufrufe.add('update');
          return false;
        },
        pluginPruefung: () async {
          aufrufe.add('plugin-prüfung');
          return false;
        },
        pluginZustimmung: () async => aufrufe.add('zustimmung'),
        pluginsStarten: () async => aufrufe.add('plugins starten'),
        einrichtungUndAnmeldung: () async {
          aufrufe.add('einrichtung');
          return true;
        },
        weiter: () => true,
      );
      expect(ausgang, StartAusgang.bereit);
      await nachEinrichtung(
        server: [
          (
            ohneAnmeldung: () => ohneAnmeldung && !laeuft,
            starten: () async {
              aufrufe.add('server vor der anmeldung');
              laeuft = true;
            },
          ),
        ],
        anmelden: () async {
          aufrufe.add('anmelden');
          if (!laeuft) {
            aufrufe.add('server');
            laeuft = true;
          }
        },
      );
      return aufrufe;
    }

    test('ohne Plugin mit Werkzeugen ohne Anmeldung: Einrichtung, Anmeldung, dann der Server', () async {
      expect(await bisZumServer(ohneAnmeldung: false), [
        'update',
        'plugin-prüfung',
        'zustimmung',
        'plugins starten',
        'einrichtung',
        'anmelden',
        'server',
      ]);
    });

    test('mit einem Plugin mit Werkzeugen ohne Anmeldung: der Server nach der Einrichtung, vor der Anmeldung', () async {
      expect(await bisZumServer(ohneAnmeldung: true), [
        'update',
        'plugin-prüfung',
        'zustimmung',
        'plugins starten',
        'einrichtung',
        'server vor der anmeldung',
        'anmelden',
      ]);
    });

    test('ist die Oberfläche nach der Prüfung der Plugins weg, fragt keine Zustimmung', () async {
      final aufrufe = <String>[];
      var weg = false;
      final ausgang = await startBisAnmeldung(
        update: () async {
          aufrufe.add('update');
          return false;
        },
        pluginPruefung: () async {
          aufrufe.add('plugin-prüfung');
          weg = true;
          return false;
        },
        pluginZustimmung: () async => aufrufe.add('zustimmung'),
        pluginsStarten: () async => aufrufe.add('plugins starten'),
        einrichtungUndAnmeldung: () async {
          aufrufe.add('einrichtung');
          return true;
        },
        weiter: () => !weg,
      );
      expect(ausgang, StartAusgang.abgebrochen);
      expect(aufrufe, ['update', 'plugin-prüfung']);
    });
  });
}
