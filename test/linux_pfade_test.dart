import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/einstellungen_ort.dart';
import 'package:path/path.dart' as p;

void main() {
  String ort(Map<String, String> umgebung) =>
      einstellungenOrdnerFuer(umgebung, macos: false, linux: true);

  test('Linux: absolutes XDG_CONFIG_HOME geht vor HOME und APPDATA', () {
    expect(
      ort({'XDG_CONFIG_HOME': '/xdg', 'HOME': '/heim', 'APPDATA': '/windows'}),
      p.join('/xdg', 'moocp'),
    );
    expect(ort({'XDG_CONFIG_HOME': '/xdg'}), p.join('/xdg', 'moocp'));
  });

  test('Linux: ohne gültiges XDG_CONFIG_HOME unter HOME/.config', () {
    for (final xdg in [null, '', 'relativ']) {
      expect(
        ort({'HOME': '/heim', 'XDG_CONFIG_HOME': ?xdg}),
        p.join('/heim', '.config', 'moocp'),
      );
    }
  });

  test(
    'Linux: fehlendes oder relatives HOME führt nicht in den Arbeitsordner',
    () {
      for (final heim in [null, '', 'relativ']) {
        expect(
          () => ort({'HOME': ?heim, 'APPDATA': '/windows'}),
          throwsStateError,
        );
      }
    },
  );

  test('Linux: Sicherungen und Plugins liegen dauerhaft unter dem Einstellungsordner', () {
    const umgebung = {'HOME': '/heim'};
    expect(
      sicherungenOrdnerFuer(umgebung, macos: false, linux: true),
      p.join(ort(umgebung), 'sicherungen'),
    );
    expect(
      pluginsOrdnerFuer(umgebung, macos: false, linux: true),
      p.join(ort(umgebung), 'plugins'),
    );
  });
}
