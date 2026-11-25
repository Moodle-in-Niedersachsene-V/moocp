// Gilt für jede Testdatei unter test/. Die Tests brauchen den Testbetrieb (die
// Testdoppel für Moodle laufen über MoodleZugang.fuerTest, die Tests des
// Testbetriebs binden Testzugänge von Hand). Den Bauschalter
// `--dart-define=MOOCP_TESTBETRIEB=true` müsste sonst jeder Aufruf von
// `flutter test` mitbringen; so läuft ein einfaches `flutter test`. Tests, die
// den Normalbetrieb ohne Schalter prüfen, legen ihn selbst um
// (test/testschalter_test.dart).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moocp/anmeldedaten.dart';
import 'package:moocp/mcp/kanal.dart';
import 'package:moocp/plattform/linux_schluesselbund.dart';
import 'package:moocp/testschalter.dart';
import 'package:path/path.dart' as p;

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  testbetriebFuerTestsSetzen(true);
  // Die Tests ersetzen den sicheren Speicher durch einen Kanal; den Secret
  // Service von Linux gibt es auf dem Testrechner nicht (anmeldedaten.dart).
  Anmeldedaten.schluesselbundPruefer = () async => Schluesselbund.bereit;
  Anmeldedaten.schluesselbundEntsperrer = () async => Schluesselbund.bereit;
  // Jede Testdatei lauscht in einem eigenen Ordner: nicht im Laufzeitordner
  // des Kontos, in dem womöglich eine echte App ihren Endpunkt hat, und nicht
  // neben den Tests anderer Dateien, die gleichzeitig laufen.
  final kanalWurzel = Platform.isWindows ? null : Directory.systemTemp.createTempSync('moocp_kanal_');
  if (kanalWurzel != null) {
    standardKanalOrt = UnixKanal(ketten: () => [[p.join(kanalWurzel.path, 'k')]]);
  }
  await testMain();
  // Nach den Tests der Datei: Der Lauf beginnt erst, wenn dies hier zurückkehrt.
  tearDownAll(() {
    try {
      kanalWurzel?.deleteSync(recursive: true);
    } on FileSystemException {
      // Ein Test hat den Ordner schon entfernt oder hält ihn noch offen.
    }
  });
}
