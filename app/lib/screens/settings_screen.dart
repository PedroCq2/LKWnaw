import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/problem_reports.dart';
import '../services/settings.dart';
import '../services/voice.dart';
import 'offline_section.dart';

/// Nastavení aplikace (hlas, rychlost, zobrazení, data v telefonu) – odděleně od profilu vozidla.
class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  const SettingsScreen({super.key, required this.settings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _url = TextEditingController(text: widget.settings.valhallaUrl);
  late bool _voice = widget.settings.voice;
  late String? _voiceName = widget.settings.voiceName;
  late double _rate = widget.settings.speechRate;
  List<Map<String, String>> _voices = [];
  late bool _simulate = widget.settings.simulate;
  late int _speedTol = widget.settings.speedTolerance;
  late bool _speedSound = widget.settings.speedSound;
  late bool _bigText = widget.settings.bigText;
  late int _mapStyle = widget.settings.mapStyle;

  @override
  void initState() {
    super.initState();
    Voice.instance.czechVoices().then((v) {
      if (mounted) setState(() => _voices = v);
    });
  }

  /// Čitelný název hlasu: „cs-cz-x-jfs-local“ → „Hlas 1 (bez internetu)“.
  String _voiceLabel(Map<String, String> v, int i) {
    final net = v['network_required'] == 'true' || (v['name'] ?? '').contains('network');
    return 'Hlas ${i + 1}${net ? ' (online)' : ' (bez internetu)'}';
  }

  Future<void> _testVoice() async {
    widget.settings
      ..voiceName = _voiceName
      ..speechRate = _rate;
    await Voice.instance.applySettings();
    await Voice.instance.say('Za 800 metrů sjeďte na výjezdu 230 na D46 směr Olomouc. E 442.', force: true);
  }

  Future<void> _save() async {
    widget.settings
      ..valhallaUrl = _url.text.trim().isEmpty ? defaultValhallaUrl : _url.text.trim()
      ..voice = _voice
      ..voiceName = _voiceName
      ..speechRate = _rate
      ..simulate = _simulate
      ..speedTolerance = _speedTol
      ..speedSound = _speedSound
      ..bigText = _bigText
      ..mapStyle = _mapStyle;
    await widget.settings.save();
    await Voice.instance.applySettings();
  }

  Widget _head(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      t,
      style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w800),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _save();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Nastavení')),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _head('RYCHLOST'),
            ListTile(
              title: const Text('Varování před překročením rychlosti'),
              subtitle: Text(
                _speedTol == 0
                    ? 'Hned po překročení limitu'
                    : 'Když jedete o víc než $_speedTol km/h nad limit',
              ),
            ),
            Slider(
              value: _speedTol.toDouble(),
              min: 0,
              max: 30,
              divisions: 30,
              label: '+$_speedTol km/h',
              onChanged: (v) => setState(() => _speedTol = v.round()),
            ),
            SwitchListTile(
              title: const Text('Hlasité varování „Pozor, rychlost“'),
              value: _speedSound,
              onChanged: (v) => setState(() => _speedSound = v),
            ),
            _head('HLAS'),
            SwitchListTile(
              title: const Text('Hlasové pokyny'),
              value: _voice,
              onChanged: (v) => setState(() => _voice = v),
            ),
            if (_voice) ...[
              ListTile(
                title: const Text('Hlas'),
                subtitle: _voices.isEmpty
                    ? const Text(
                        'V telefonu není český hlas – nainstalujte ho v Nastavení → Převod textu na řeč.',
                      )
                    : null,
                trailing: _voices.isEmpty
                    ? null
                    : DropdownButton<String?>(
                        value: _voices.any((v) => v['name'] == _voiceName) ? _voiceName : null,
                        items: [
                          const DropdownMenuItem(value: null, child: Text('Automaticky')),
                          for (final (i, v) in _voices.indexed)
                            DropdownMenuItem(value: v['name'], child: Text(_voiceLabel(v, i))),
                        ],
                        onChanged: (v) => setState(() => _voiceName = v),
                      ),
              ),
              ListTile(
                title: Text('Rychlost řeči: ${(_rate * 200).round()} %'),
                subtitle: Slider(
                  value: _rate,
                  min: 0.3,
                  max: 0.8,
                  divisions: 10,
                  onChanged: (v) => setState(() => _rate = v),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.play_circle, size: 36),
                  tooltip: 'Vyzkoušet hlas',
                  onPressed: _testVoice,
                ),
              ),
            ],
            _head('ZOBRAZENÍ'),
            SwitchListTile(
              title: const Text('Větší texty pokynů'),
              subtitle: const Text('Horní okénko s pokynem větším písmem'),
              value: _bigText,
              onChanged: (v) => setState(() => _bigText = v),
            ),
            ListTile(
              title: const Text('Vzhled mapy'),
              trailing: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Auto')),
                  ButtonSegment(value: 1, label: Text('Den')),
                  ButtonSegment(value: 2, label: Text('Noc')),
                ],
                selected: {_mapStyle},
                onSelectionChanged: (v) => setState(() => _mapStyle = v.first),
              ),
            ),
            _head('DATA V TELEFONU'),
            OfflineRoutingSection(settings: widget.settings),
            _head('HLÁŠENÍ'),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: ProblemReports.load(),
              builder: (ctx, snap) {
                final n = snap.data?.length ?? 0;
                return ListTile(
                  leading: const Icon(Icons.report_problem_outlined),
                  title: Text('Hlášení „navigovala špatně“ ($n)'),
                  subtitle: const Text('Zkopírujte a pošlete – podle nich se navigace opraví'),
                  trailing: n == 0
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Zkopírovat',
                              icon: const Icon(Icons.copy),
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: await ProblemReports.export()));
                                if (ctx.mounted) {
                                  ScaffoldMessenger.of(ctx)
                                      .showSnackBar(const SnackBar(content: Text('Zkopírováno.')));
                                }
                              },
                            ),
                            IconButton(
                              tooltip: 'Smazat',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                await ProblemReports.clear();
                                setState(() {});
                              },
                            ),
                          ],
                        ),
                );
              },
            ),
            _head('POKROČILÉ'),
            SwitchListTile(
              title: const Text('Simulace jízdy (demo)'),
              subtitle: const Text('Po stisku Start jede kamion po trase sám – pro vyzkoušení'),
              value: _simulate,
              onChanged: (v) => setState(() => _simulate = v),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Valhalla server',
                  helperText: 'Vlastní server viz backend/docker-compose.yml',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('O aplikaci LKWnav'),
              subtitle: Text(
                'Mapová data © přispěvatelé OpenStreetMap (ODbL)\n'
                'Vektorové mapy: OpenFreeMap / OpenMapTiles\n'
                'Letecké snímky: Ortofoto ČR © ČÚZK (CC BY 4.0)\n'
                'Výpočet tras: Valhalla, vyhledávání: Nominatim, POI a omezení: Overpass API',
              ),
              isThreeLine: true,
            ),
          ],
        ),
      ),
    );
  }
}
