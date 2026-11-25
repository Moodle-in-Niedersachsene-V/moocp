// Der Dialog „Über moocp": Version, Lizenz der App und die Lizenzen
// aller eingebundenen Pakete. Die Lizenzen der Pakete (MIT, BSD, Apache 2.0)
// verlangen, dass ihre Hinweise mit der fertigen App weitergegeben werden. Die Lizenzseite von
// Flutter zeigt sie alle; Flutter sammelt sie beim Bauen selbst ein (die
// Datei NOTICES in den Assets), auch die der Engine.

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

const appName = 'moocp';

/// Die eigene Lizenz als Asset (pubspec.yaml). Flutter nimmt nur Dateien, die
/// genau LICENSE heißen, von selbst in die Lizenzseite auf.
const lizenzAsset = 'LICENSE.md';

/// Meldet die Lizenz der App bei der Lizenzseite an. Vor
/// `WidgetsFlutterBinding.ensureInitialized()` aufrufen: Die Lizenzseite
/// stellt das zuerst gemeldete Paket an den Anfang, und die Bindung meldet
/// beim Start die gesammelten Lizenzen der Pakete.
void lizenzAnmelden() {
  LicenseRegistry.addLicense(() async* {
    // Ohne das BOM, mit dem die Datei beginnt (es steht dort für den
    // Installer, siehe installer/moocp.nsi).
    final text = await rootBundle.loadString(lizenzAsset);
    yield LicenseEntryWithLineBreaks([appName], text.replaceFirst('\uFEFF', ''));
  });
}

/// Die Version, wie sie in pubspec.yaml steht („1.0.0+1"). Unter Windows liest
/// package_info_plus sie aus der exe, in die Flutter sie beim Bauen schreibt;
/// der Installer nimmt sie von dort (installer/moocp.nsi).
///
/// Eine Nightly heißt auf jeder Plattform gleich, „0.13.0.20261124.2+2", ohne
/// „-nightly": macOS erlaubt in der Version der App nur Ziffern und Punkte, und
/// Flutter macht dort aus „0.13.0-nightly.20261124.2" schon beim Bauen
/// „0.13.0.20261124.2". Erkennbar ist die Nightly am Datum dahinter (E39).
/// Für den Vergleich mit einem Release ist das gleich: [versionVergleich]
/// liest in beiden Formen dieselben Zahlen.
String versionText(PackageInfo info) {
  final version = versionOhneBuild(info);
  return info.buildNumber.isEmpty ? version : '$version+${info.buildNumber}';
}

/// Die Version ohne Buildnummer, auf jeder Plattform gleich geschrieben (siehe
/// [versionText]); so steht sie im Protokoll und geht in die Update-Prüfung.
String versionOhneBuild(PackageInfo info) => info.version.replaceFirst('-nightly.', '.');

/// Zeigt den Dialog; „Lizenzen anzeigen" darin öffnet die Lizenzseite.
Future<void> ueberZeigen(BuildContext context) async {
  String? version;
  try {
    version = versionText(await PackageInfo.fromPlatform());
  } catch (_) {
    // Ohne Versionsangabe öffnet der Dialog trotzdem.
  }
  if (!context.mounted) return;
  showAboutDialog(
    context: context,
    applicationName: appName,
    applicationVersion: version == null ? null : 'Version $version',
    applicationLegalese: '© 2026 Tobias Steinmann\nGNU AGPLv3 oder später',
  );
}
