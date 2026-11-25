part of 'main.dart';

// Die Dialoge der Plugins in der Oberfläche (plugin/dialoge.dart): Ein Plugin
// beschreibt, moocp zeigt. Oben steht immer das Plugin als Absender, alles,
// was das Plugin vorgibt, erscheint als schlichter Text -- keine Formatierung,
// keine Links --, und die Knöpfe beschriftet moocp.
//
// Ein Dialog eines Plugins ist keine Freigabe; trotzdem kommt er oft nach
// vorn, während die Lehrkraft woanders tippt. Deshalb nehmen seine Knöpfe
// erst nach der Sperrzeit etwas an und sind nicht über die Tastatur zu
// erreichen (beides Sperrzeit, nur_maus.dart): Ein Return, der gerade unterwegs ist,
// entscheidet nichts. NurMaus selbst umschließt den Dialog nicht, weil es
// auch die Leertaste im Such- und Eingabefeld schluckte.
//
// Das Fenster kommt nach vorn, bleibt aber nicht oben: Für eine Eingabe holt
// die Lehrkraft vielleicht erst einen Link aus dem Browser.

/// Zeigt den offenen Dialog der Plugins, immer genau einen. Die Antwort geht
/// an das wartende Plugin; beantwortet die App den Dialog selbst (Frist, Ende
/// des Aufrufs), schließt er sich, und der nächste wartende öffnet sich.
class PluginDialogAnzeige extends StatefulWidget {
  const PluginDialogAnzeige({
    super.key,
    required this.dialoge,
    required this.nachVorn,
    required this.child,
  });

  final PluginDialoge dialoge;

  /// Holt das Fenster nach vorn, ohne es oben zu halten.
  final Future<void> Function() nachVorn;

  final Widget child;

  @override
  State<PluginDialogAnzeige> createState() => _PluginDialogAnzeigeState();
}

class _PluginDialogAnzeigeState extends State<PluginDialogAnzeige> {
  PluginDialog? _gezeigt;
  Route<Map<String, Object?>>? _dialog;

  @override
  void initState() {
    super.initState();
    widget.dialoge.addListener(_zeigen);
    WidgetsBinding.instance.addPostFrameCallback((_) => _zeigen());
  }

  @override
  void didUpdateWidget(covariant PluginDialogAnzeige oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.dialoge, widget.dialoge)) return;
    oldWidget.dialoge.removeListener(_zeigen);
    widget.dialoge.addListener(_zeigen);
    _zeigen();
  }

  @override
  void dispose() {
    widget.dialoge.removeListener(_zeigen);
    super.dispose();
  }

  void _zeigen() {
    final d = widget.dialoge.aktuell;
    if (identical(d, _gezeigt)) return;
    // Die App hat den gezeigten Dialog selbst beantwortet: genau dessen
    // Route entfernen (wie bei den Freigaben, _FreigabeDialogeState._zeigen).
    final alt = _dialog;
    _gezeigt = null;
    _dialog = null;
    if (alt != null && alt.isActive) alt.navigator!.removeRoute(alt);
    if (d == null || !mounted) return;
    _gezeigt = d;
    widget.nachVorn();
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<Map<String, Object?>>(
      context: context,
      builder: (_) => PluginDialogFenster(d, frist: widget.dialoge.frist),
      barrierDismissible: false,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    );
    _dialog = route;
    navigator.push(route).then((antwort) {
      // Oben entfernt: Der Dialog ist schon beantwortet.
      if (!identical(_dialog, route)) return;
      _gezeigt = null;
      _dialog = null;
      widget.dialoge.beantworten(d, antwort);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Ein Dialog eines Plugins. Schließt mit der Antwort (siehe die Arten in
/// plugin/dialoge.dart) oder mit null, wenn die Lehrkraft abbricht.
class PluginDialogFenster extends StatefulWidget {
  const PluginDialogFenster(this.dialog, {this.frist = Freigaben.fristVorgabe, this.umgebung, super.key});

  final PluginDialog dialog;

  /// Für den Satz zur Frist, wenn der Dialog nicht über PluginDialoge kam.
  final Duration frist;

  /// Die Umgebung für den Benutzerordner, in dem die Wahl eines Ordners oder
  /// einer Datei beginnt; ohne Angabe die des Prozesses.
  final Map<String, String>? umgebung;

  @override
  State<PluginDialogFenster> createState() => _PluginDialogFensterState();
}

class _PluginDialogFensterState extends State<PluginDialogFenster> {
  PluginDialog get dialog => widget.dialog;

  // Auswahl
  final _suche = TextEditingController();
  final _gewaehlt = <int>{};

  // Eingabe, Pfad
  late final _eingabe = TextEditingController(
    text: switch (dialog) {
      final EingabeDialog e => e.vorgabe,
      _ => '',
    },
  );

  // Pfad: der Ordner, dessen Inhalt die Liste zeigt.
  String? _ordner;

  @override
  void initState() {
    super.initState();
    if (dialog case final PfadDialog d) {
      final start = d.start;
      final heim = benutzerordner(widget.umgebung ?? Platform.environment);
      _ordner = [?start, ?heim].map((o) => p.normalize(p.absolute(o))).where((o) => Directory(o).existsSync()).firstOrNull;
      if (d.ordner && _ordner != null) _eingabe.text = _ordner!;
    }
  }

  @override
  void dispose() {
    _suche.dispose();
    _eingabe.dispose();
    super.dispose();
  }

  /// Ob die Antwort so gilt: Erst dann geht „Übernehmen“. Dieselben Regeln
  /// gelten für vorbereitete Antworten des Testbetriebs
  /// (PluginDialog.antwortPruefen).
  bool get _gueltig => switch (dialog) {
    AuswahlDialog() => _gewaehlt.isNotEmpty,
    final EingabeDialog e => e.gueltig(_eingabe.text),
    final PfadDialog d => d.gueltig(_eingabe.text),
    HinweisDialog() => true,
  };

  Map<String, Object?> get _antwort => switch (dialog) {
    AuswahlDialog() => AuswahlDialog.antwort(_gewaehlt),
    EingabeDialog() => EingabeDialog.antwort(_eingabe.text.trim()),
    PfadDialog() => PfadDialog.antwort(p.normalize(_eingabe.text.trim())),
    HinweisDialog() => const {},
  };

  /// Was von der Frist bleibt, wie bei einer Freigabe.
  String _restfrist() {
    final rest = dialog.ablauf?.difference(DateTime.now()) ?? widget.frist;
    final minuten = (rest.inSeconds / 60).round();
    return minuten <= 1 ? 'einer Minute' : '$minuten Minuten';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hinweis = dialog is HinweisDialog;
    final gross = dialog is AuswahlDialog || dialog is PfadDialog;
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Der Absender, deutlich und vor allem anderen: Was folgt, schreibt
          // das Plugin, nicht moocp.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            color: theme.colorScheme.secondaryContainer,
            child: Row(
              children: [
                Icon(Icons.extension, size: 18, color: theme.colorScheme.onSecondaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Absender: ${dialog.absender}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(dialog.titel),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: gross ? 440 : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (dialog.text.isNotEmpty) ...[
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: gross ? 120 : 240),
                child: SingleChildScrollView(child: Text(dialog.text)),
              ),
              const SizedBox(height: 10),
            ],
            ...switch (dialog) {
              final AuswahlDialog d => _auswahl(d),
              final EingabeDialog d => _eingabeFeld(d),
              final PfadDialog d => _pfadwahl(d),
              HinweisDialog() => const <Widget>[],
            },
            const SizedBox(height: 8),
            Text(
              hinweis
                  ? 'Ohne Bestätigung innerhalb von ${_restfrist()} schließt sich der Hinweis.'
                  : 'Ohne Antwort innerhalb von ${_restfrist()} gilt der Dialog als abgebrochen.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        // Sperrzeit nimmt die Knöpfe auch aus dem Tastaturfokus.
        Sperrzeit(
          builder: (bereit) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!hinweis) ...[
                OutlinedButton(
                  onPressed: bereit ? () => Navigator.of(context).pop() : null,
                  child: const Text('Abbrechen'),
                ),
                const SizedBox(width: 8),
              ],
              FilledButton(
                onPressed: bereit && _gueltig ? () => Navigator.of(context).pop(_antwort) : null,
                child: Text(hinweis ? 'OK' : 'Übernehmen'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _auswahl(AuswahlDialog d) {
    final suche = _suche.text.trim().toLowerCase();
    final sichtbar = [
      for (final (i, e) in d.eintraege.indexed)
        if (suche.isEmpty || e.toLowerCase().contains(suche)) i,
    ];
    return [
      TextField(
        controller: _suche,
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search),
          hintText: 'Suchen',
          isDense: true,
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 6),
      Text(
        d.mehrfach ? 'Mehrere wählbar, ${_gewaehlt.length} gewählt' : 'Einen Eintrag wählen',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      Expanded(
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border.all(color: Colors.black12)),
          child: ListView.builder(
            itemCount: sichtbar.length,
            itemBuilder: (context, n) {
              final i = sichtbar[n];
              return CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _gewaehlt.contains(i),
                title: Text(d.eintraege[i]),
                onChanged: (an) => setState(() {
                  if (!d.mehrfach) _gewaehlt.clear();
                  if (an == true) {
                    _gewaehlt.add(i);
                  } else {
                    _gewaehlt.remove(i);
                  }
                }),
              );
            },
          ),
        ),
      ),
    ];
  }

  List<Widget> _eingabeFeld(EingabeDialog d) {
    final t = _eingabe.text.trim();
    return [
      TextField(
        controller: _eingabe,
        maxLength: eingabeHoechstens,
        decoration: InputDecoration(
          labelText: d.link ? 'Link (https://…)' : 'Text',
          errorText: d.link && t.isNotEmpty && !EingabeDialog.istLink(t)
              ? 'Ein Link beginnt mit https:// oder http://.'
              : null,
        ),
        onChanged: (_) => setState(() {}),
      ),
    ];
  }

  /// Höchstens so viele Einträge zeigt die Liste eines Ordners; wer mehr
  /// hat, gibt den Pfad ein.
  static const _eintraegeHoechstens = 1000;

  List<Widget> _pfadwahl(PfadDialog d) {
    final ordner = _ordner;
    List<FileSystemEntity>? inhalt;
    if (ordner != null) {
      try {
        inhalt =
            Directory(ordner)
                .listSync(followLinks: false)
                .where((e) => e is Directory || (!d.ordner && e is File))
                .toList()
              ..sort((a, b) {
                if ((a is Directory) != (b is Directory)) return a is Directory ? -1 : 1;
                return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
              });
      } on FileSystemException {
        inhalt = null;
      }
    }
    final eltern = ordner == null ? null : p.dirname(ordner);
    return [
      TextField(
        controller: _eingabe,
        maxLength: pfadHoechstens,
        decoration: InputDecoration(
          labelText: d.ordner ? 'Ordner' : 'Datei',
          isDense: true,
          helperText: _eingabe.text.trim().isEmpty || d.gueltig(_eingabe.text)
              ? null
              : d.ordner
              ? 'Diesen Ordner gibt es nicht.'
              : 'Diese Datei gibt es nicht.',
        ),
        onChanged: (t) => setState(() {
          final o = t.trim();
          if (p.isAbsolute(o) && Directory(o).existsSync()) _ordner = p.normalize(o);
        }),
      ),
      Row(
        children: [
          TextButton.icon(
            icon: const Icon(Icons.arrow_upward, size: 18),
            label: const Text('Übergeordneter Ordner'),
            onPressed: eltern == null || eltern == ordner ? null : () => _ordnerOeffnen(d, eltern),
          ),
          Expanded(
            child: Text(
              ordner ?? '',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
      Expanded(
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border.all(color: Colors.black12)),
          child: inhalt == null
              ? const Center(child: Text('Dieser Ordner lässt sich nicht lesen.'))
              : ListView(
                  children: [
                    for (final e in inhalt.take(_eintraegeHoechstens))
                      ListTile(
                        dense: true,
                        leading: Icon(e is Directory ? Icons.folder : Icons.description_outlined, size: 20),
                        title: Text(p.basename(e.path)),
                        selected: p.equals(e.path, _eingabe.text.trim()),
                        onTap: () => e is Directory
                            ? _ordnerOeffnen(d, e.path)
                            : setState(() => _eingabe.text = e.path),
                      ),
                  ],
                ),
        ),
      ),
    ];
  }

  void _ordnerOeffnen(PfadDialog d, String ordner) => setState(() {
    _ordner = p.normalize(ordner);
    if (d.ordner) _eingabe.text = _ordner!;
  });
}
