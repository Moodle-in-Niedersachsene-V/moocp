import 'dart:io';

import 'package:path/path.dart' as p;

import 'kindprozess.dart';
import 'plattform.dart';

/// Windows: Browser über die Registrierung (App Paths) und die üblichen
/// Programmordner; Richtlinien in der Registry; Prozesse über PowerShell.
class WindowsBrowser implements PlattformBrowser {
  @override
  List<BrowserArt> get arten => const [BrowserArt.edge, BrowserArt.chrome];

  @override
  Future<String?> programm(BrowserArt art) => switch (art) {
        BrowserArt.edge => _finden('msedge.exe', const ['Microsoft', 'Edge', 'Application']),
        BrowserArt.chrome => _finden('chrome.exe', const ['Google', 'Chrome', 'Application']),
        BrowserArt.chromium => Future.value(null),
      };

  @override
  Future<bool> fernsteuerungVerboten(BrowserArt art) async {
    final richtlinie = switch (art) {
      BrowserArt.edge => r'SOFTWARE\Policies\Microsoft\Edge',
      BrowserArt.chrome => r'SOFTWARE\Policies\Google\Chrome',
      BrowserArt.chromium => null,
    };
    if (richtlinie == null) return false;
    for (final wurzel in ['HKLM', 'HKCU']) {
      final t = await _reg(['$wurzel\\$richtlinie', '/v', 'RemoteDebuggingAllowed']);
      if (RegExp(r'RemoteDebuggingAllowed\s+REG_DWORD\s+0x0+\s*$', multiLine: true).hasMatch(t)) return true;
    }
    return false;
  }

  @override
  Future<int> prozesseBeenden(Directory profil, String programm) async {
    final exe = p.basename(programm);
    String ps(String s) => s.replaceAll("'", "''");
    try {
      final r = await prozessAusfuehren('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "\$p = @(Get-CimInstance Win32_Process -Filter \"Name='${ps(exe)}'\" | Where-Object "
            "{ \$_.CommandLine -and \$_.CommandLine.Contains('${ps(profil.path)}') }); "
            r"$p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; $p.Count",
      ]);
      return int.tryParse('${r.stdout}'.trim()) ?? -1;
    } on ProcessException {
      return -1;
    }
  }
}

/// Beendet den Prozess [pid] und alle, die er gestartet hat (`taskkill /T`).
/// Windows beendet die Kinder eines Prozesses nicht mit ihm; `/T` geht den
/// Baum über die Elternnummer ab und muss deshalb laufen, solange [pid] noch
/// lebt. Fehlt taskkill, bleibt es beim Prozess selbst (plattform.dart).
Future<void> prozessbaumBeendenWindows(int pid) async {
  try {
    await prozessAusfuehren('taskkill',['/PID', '$pid', '/T', '/F']);
  } on ProcessException {
    // Ohne taskkill beendet der Aufrufer nur den Prozess selbst.
  }
}

Future<String> _reg(List<String> argumente) async {
  try {
    return '${(await prozessAusfuehren('reg',['query', ...argumente])).stdout}';
  } on ProcessException {
    return '';
  }
}

/// Wo ein Browser liegt: zuerst laut Registrierung (App Paths), sonst an den
/// üblichen Orten.
Future<String?> _finden(String exe, List<String> ordner) async {
  for (final wurzel in ['HKLM', 'HKCU']) {
    final m = RegExp(r'REG_SZ\s+(.+)')
        .firstMatch(await _reg(['$wurzel\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\$exe', '/ve']));
    final pfad = m?.group(1)?.trim();
    if (pfad != null && File(pfad).existsSync()) return pfad;
  }
  for (final v in ['ProgramFiles(x86)', 'ProgramFiles', 'LOCALAPPDATA']) {
    final b = Platform.environment[v];
    if (b == null) continue;
    final pfad = p.joinAll([b, ...ordner, exe]);
    if (File(pfad).existsSync()) return pfad;
  }
  return null;
}
