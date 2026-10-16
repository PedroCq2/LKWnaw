import 'package:flutter/material.dart';

import '../models/truck_profile.dart';
import '../services/settings.dart';

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
  late bool _simulate = widget.settings.simulate;
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
      ..simulate = _simulate
      ..mapStyle = _mapStyle
      ..delivery = _delivery;
    await widget.settings.save();
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
                'Povolí vjezd do zón se zákazem nad X t (např. k obchodu). '
                'Výška, šířka, délka, náprava a mosty se hlídají dál.',
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
              title: const Text('Hlasové pokyny'),
              value: _voice,
              onChanged: (v) => setState(() => _voice = v),
            ),
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
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('O aplikaci LKWnav'),
              subtitle: Text(
                'Mapová data © přispěvatelé OpenStreetMap (ODbL)\n'
                'Vektorové mapy: OpenFreeMap / OpenMapTiles\n'
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
