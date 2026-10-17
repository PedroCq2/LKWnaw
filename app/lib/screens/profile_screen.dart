import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/truck_profile.dart';
import '../services/problem_reports.dart';
import '../services/settings.dart';
import '../services/voice.dart';
import 'offline_section.dart';

class ProfileScreen extends StatefulWidget {
  final AppSettings settings;
  const ProfileScreen({super.key, required this.settings});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _form = GlobalKey<FormState>();
  late TruckProfile p = TruckProfile.fromJson(widget.settings.profile.toJson());
  late final _url = TextEditingController(text: widget.settings.valhallaUrl);
  late bool _voice = widget.settings.voice;
  late String? _voiceName = widget.settings.voiceName;
  late double _rate = widget.settings.speechRate;
  List<Map<String, String>> _voices = [];

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

  late bool _simulate = widget.settings.simulate;
  late int _speedTol = widget.settings.speedTolerance;
  late bool _speedSound = widget.settings.speedSound;
  late bool _bigText = widget.settings.bigText;
  late int _mapStyle = widget.settings.mapStyle;
  late bool _delivery = widget.settings.delivery;

  Widget _num(
    String label,
    String unit,
    double value,
    void Function(double) set, {
    double min = 0,
    double max = 100,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        initialValue: value.toString(),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, suffixText: unit, border: const OutlineInputBorder()),
        validator: (s) {
          final v = double.tryParse((s ?? '').replaceAll(',', '.'));
          if (v == null || v < min || v > max) return 'Zadejte $min – $max';
          return null;
        },
        onSaved: (s) => set(double.parse(s!.replaceAll(',', '.'))),
      ),
    );
  }

  void _save() async {
    if (!_form.currentState!.validate()) return;
    _form.currentState!.save();
    widget.settings
      ..profile = p
      ..valhallaUrl = _url.text.trim().isEmpty ? defaultValhallaUrl : _url.text.trim()
      ..voice = _voice
      ..voiceName = _voiceName
      ..speechRate = _rate
      ..simulate = _simulate
      ..speedTolerance = _speedTol
      ..speedSound = _speedSound
      ..bigText = _bigText
      ..mapStyle = _mapStyle
      ..delivery = _delivery;
    await widget.settings.save();
    await Voice.instance.applySettings();
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profil vozidla'),
        actions: [IconButton(icon: const Icon(Icons.check), onPressed: _save)],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  label: const Text('Tahač + návěs 40 t'),
                  onPressed: () => setState(() => p = TruckProfile()),
                ),
                ActionChip(
                  label: const Text('Sólo 18 t'),
                  onPressed: () => setState(
                    () => p = TruckProfile(height: 3.8, length: 10, weight: 18, axleLoad: 10, axleCount: 2),
                  ),
                ),
                ActionChip(
                  label: const Text('Dodávka 3,5 t'),
                  onPressed: () => setState(
                    () => p = TruckProfile(
                      height: 2.8,
                      width: 2.1,
                      length: 7,
                      weight: 3.5,
                      axleLoad: 2,
                      axleCount: 2,
                      maxSpeed: 130,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Key vynutí přestavění polí po výběru předvolby.
            KeyedSubtree(
              key: ValueKey(p),
              child: Column(
                children: [
                  _num('Výška', 'm', p.height, (v) => p.height = v, max: 6),
                  _num('Šířka', 'm', p.width, (v) => p.width = v, max: 4),
                  _num('Délka', 'm', p.length, (v) => p.length = v, max: 30),
                  _num('Celková hmotnost', 't', p.weight, (v) => p.weight = v, max: 80),
                  _num('Zatížení nápravy', 't', p.axleLoad, (v) => p.axleLoad = v, max: 20),
                  _num(
                    'Počet náprav',
                    '',
                    p.axleCount.toDouble(),
                    (v) => p.axleCount = v.round(),
                    min: 2,
                    max: 10,
                  ),
                  _num(
                    'Max. rychlost vozidla',
                    'km/h',
                    p.maxSpeed.toDouble(),
                    (v) => p.maxSpeed = v.round(),
                    min: 30,
                    max: 130,
                  ),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('Nebezpečný náklad (ADR)'),
              value: p.hazmat,
              onChanged: (v) => setState(() => p.hazmat = v),
            ),
            SwitchListTile(
              title: const Text('Zásobování (dopravní obsluha)'),
              subtitle: const Text(
                'Zákazy nad X t (mimo dopravní obsluhu) neplatí jen v obci vykládky (např. celé Teplice), '
                'cestou tam se dodržují. Výška, šířka, délka, náprava a mosty se hlídají vždy.',
              ),
              value: _delivery,
              onChanged: (v) => setState(() => _delivery = v),
            ),
            SwitchListTile(
              title: const Text('Vyhnout se mýtným úsekům'),
              value: p.avoidTolls,
              onChanged: (v) => setState(() => p.avoidTolls = v),
            ),
            SwitchListTile(
              title: const Text('Vyhnout se trajektům'),
              value: p.avoidFerries,
              onChanged: (v) => setState(() => p.avoidFerries = v),
            ),
            SwitchListTile(
              title: const Text('Vyhnout se nezpevněným cestám'),
              subtitle: const Text('Polní cesty, šotolina – pokud to jde'),
              value: p.avoidUnpaved,
              onChanged: (v) => setState(() => p.avoidUnpaved = v),
            ),
            const Divider(),
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
            SwitchListTile(
              title: const Text('Větší texty pokynů'),
              subtitle: const Text('Horní okénko s pokynem větším písmem'),
              value: _bigText,
              onChanged: (v) => setState(() => _bigText = v),
            ),
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
            SwitchListTile(
              title: const Text('Simulace jízdy (demo)'),
              subtitle: const Text('Po stisku Start jede kamion po trase sám – pro vyzkoušení'),
              value: _simulate,
              onChanged: (v) => setState(() => _simulate = v),
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
            const Divider(),
            OfflineRoutingSection(settings: widget.settings),
            const Divider(),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Valhalla server',
                helperText: 'Vlastní server viz backend/docker-compose.yml',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Uložit')),
            const SizedBox(height: 24),
            const Divider(),
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
