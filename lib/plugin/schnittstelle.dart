// Welche Versionen der Plugin-Schnittstelle diese App bietet und ob ein Plugin
// dazu passt (E35). Geurteilt wird allein nach der Zahl in der
// Beschreibungsdatei (`schnittstelle`), ohne Code des Plugins auszuführen: beim
// Suchen der Plugins (plugins.dart), also vor der Zustimmung, und noch einmal
// unmittelbar vor jedem Start (laufende_plugins.dart); für ein
// Entwicklungs-Plugin beim Lesen seiner Beschreibungsdatei (entwicklung.dart).
//
// Passt es nicht, ist eine Seite zu alt: Verlangt das Plugin mehr, als moocp
// bietet, braucht es ein Update von moocp; verlangt es eine Version, die moocp
// nicht mehr bietet, braucht das Plugin eines. Ohne Update bleibt das Plugin
// aus, die App läuft ohne es weiter.

/// Die Version der Plugin-Schnittstelle, die diese App beim initialize nennt
/// (verbindung.dart).
const int schnittstellenVersion = 1;

/// Alle Versionen, die diese App bietet. Heute genau eine; bietet eine spätere
/// App eine neue Version und die alte noch eine Weile weiter, kommt sie hier
/// dazu, und alles andere fragt nur diese Menge.
const Set<int> angeboteneSchnittstellen = {schnittstellenVersion};

enum SchnittstellenUrteil {
  /// Die App bietet die verlangte Version.
  passt,

  /// Das Plugin verlangt eine neuere Version, als die App bietet: moocp ist zu
  /// alt.
  moocpZuAlt,

  /// Das Plugin verlangt eine Version, die die App nicht mehr bietet: das
  /// Plugin ist zu alt.
  pluginZuAlt,
}

/// Urteilt über die Version [verlangt] aus der Beschreibungsdatei. Eine Lücke
/// in [angeboten] (eine Version zwischen zwei angebotenen, die es nicht mehr
/// gibt) zählt wie eine zu alte: Neuer als die neueste ist sie nicht.
SchnittstellenUrteil schnittstelleUrteil(int verlangt, {Set<int> angeboten = angeboteneSchnittstellen}) {
  if (angeboten.contains(verlangt)) return SchnittstellenUrteil.passt;
  final hoechste = angeboten.reduce((a, b) => a > b ? a : b);
  return verlangt > hoechste ? SchnittstellenUrteil.moocpZuAlt : SchnittstellenUrteil.pluginZuAlt;
}

/// Ein Satz für die Lehrkraft und das Protokoll: welche Seite zu alt ist. Er
/// enthält nur Zahlen aus der Beschreibungsdatei, keinen Text daraus (E11).
String schnittstelleGrund(SchnittstellenUrteil urteil, int verlangt, {Set<int> angeboten = angeboteneSchnittstellen}) {
  final liste = (angeboten.toList()..sort()).join(', ');
  return switch (urteil) {
    SchnittstellenUrteil.passt => 'Die Plugin-Schnittstelle passt.',
    SchnittstellenUrteil.moocpZuAlt =>
      'moocp ist zu alt für dieses Plugin: Es braucht die Plugin-Schnittstelle in Version $verlangt, '
          'diese Version von moocp bietet $liste.',
    SchnittstellenUrteil.pluginZuAlt =>
      'Das Plugin ist zu alt für diese Version von moocp: Es braucht die Plugin-Schnittstelle in Version '
          '$verlangt, moocp bietet $liste.',
  };
}
