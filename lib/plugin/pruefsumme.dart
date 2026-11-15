// Die Prüfsumme eines Plugin-Ordners (E35): SHA-256 über jede Datei darin.
//
// Eine Zustimmung gilt für genau den Stand, über den entschieden wurde. Eine
// Prüfsumme nur über das Programm ließe eine ausgetauschte Skill-Datei durch,
// eine nur über die Beschreibungsdatei ein ausgetauschtes Programm; deshalb
// zählt jede Datei, mit ihrem Pfad (eine Umbenennung ändert die Summe).
//
// Ein Plugin schreibt nichts in seinen Ordner (dafür gibt es den
// Arbeitsordner): Sonst änderte es seine eigene Prüfsumme und fragte bei jedem
// Start neu.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'beschreibung.dart' show PluginFehler;

/// Die Prüfsumme über alle Dateien in [ordner], als 64 Hexziffern. Berechnet
/// wird sie bei jedem Start neu.
///
/// Je Datei ein Digest, aus Pfad (immer mit „/") und Digests, nach Pfad
/// sortiert, der Gesamtwert: So lassen sich Pfad und Inhalt nicht
/// gegeneinander verschieben, und die Dateien müssen nicht im Speicher stehen.
///
/// Eine Verknüpfung (Symlink, Junction) im Ordner wirft [PluginFehler]: Ihr
/// Ziel läge außerhalb des Ordners, könnte sich ändern, ohne dass die Summe
/// es merkt, und wäre doch Teil des Plugins.
Future<String> pluginPruefsumme(Directory ordner) async {
  final dateien = <String, File>{};
  await for (final e in ordner.list(recursive: true, followLinks: false)) {
    if (e is Link) {
      throw const PluginFehler(
        'Der Plugin-Ordner enthält eine Verknüpfung; die Prüfsumme der Zustimmung '
        'könnte ihr Ziel nicht erfassen.',
      );
    }
    if (e is File) dateien[p.posix.joinAll(p.split(p.relative(e.path, from: ordner.path)))] = e;
  }
  // Nach Code-Einheiten sortiert, unabhängig von Sprache und Rechner.
  final pfade = dateien.keys.toList()..sort();
  final gesamt = StringBuffer();
  for (final pfad in pfade) {
    final digest = await sha256.bind(dateien[pfad]!.openRead()).first;
    gesamt
      ..write(pfad)
      ..write('\u0000')
      ..write(digest)
      ..write('\n');
  }
  return sha256.convert(utf8.encode(gesamt.toString())).toString();
}
