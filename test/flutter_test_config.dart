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
import 'package:moocp/mcp/kanal_windows.dart';
import 'package:moocp/plattform/linux_schluesselbund.dart';
import 'package:moocp/testschalter.dart';
import 'package:path/path.dart' as p;

/// Unter Windows gehört der Name einer Pipe dem ganzen Rechner: Zwei Testdateien
/// mit demselben Profilnamen (`test`, `moodle`) oder eine laufende moocp würden
/// einander den Namen wegnehmen. Jede Testdatei läuft in einem eigenen Prozess;
/// ihr Präfix `zz<pid>-` macht die Namen eindeutig, die Namen der App bleiben
/// unberührt.
class _PipesMitPraefix extends KanalOrt {
  _PipesMitPraefix(this._innen, this._praefix);
  final KanalOrt _innen;
  final String _praefix;

  String _n(String name) => '$_praefix$name';

  @override
  Future<KanalLauscher> lauschen(String name, {void Function(String grund)? abgewiesen, void Function(String text)? hinweis}) =>
      _innen.lauschen(_n(name), abgewiesen: abgewiesen, hinweis: hinweis);

  @override
  Future<KanalVerbindung> verbinden(String name) => _innen.verbinden(_n(name));

  @override
  Future<String?> listeLesen(String name) => _innen.listeLesen(_n(name));

  @override
  Future<void> listeAblegen(String name, String json) => _innen.listeAblegen(_n(name), json);

  @override
  Future<void> listeEntfernen(String name) => _innen.listeEntfernen(_n(name));
}

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
  if (Platform.isWindows) standardKanalOrt = _PipesMitPraefix(WindowsKanal(), 'zz$pid-');
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
