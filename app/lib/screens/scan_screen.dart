import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import '../services/address_parser.dart';
import '../services/geocoding.dart';
import '../services/label_scanner.dart';
import '../services/plans.dart';
import '../services/settings.dart';
import '../services/stop_order.dart';
import '../theme.dart';

class _Item {
  ParsedAddress addr;
  Place? place;
  bool searching = true;
  bool use = true;
  _Item(this.addr);
}

/// Vyfoťte dodací listy / štítky balíků → adresy → nejlepší pořadí → plán trasy (pořadí lze změnit tažením).
class ScanScreen extends StatefulWidget {
  final AppSettings settings;
  final LatLng? start; // odkud se jede (moje poloha / začátek plánu)
  const ScanScreen({super.key, required this.settings, this.start});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _picker = ImagePicker();
  final _items = <_Item>[];
  LabelScanner? _scanner;
  bool _reading = false;
  bool _roundTrip = false;
  bool _ordering = false;

  @override
  void dispose() {
    _scanner?.close();
    super.dispose();
  }

  Future<void> _photo({required bool camera}) async {
    if (kIsWeb) {
      _toast('Focení adres funguje v aplikaci v telefonu.');
      return;
    }
    final files = camera
        ? [?await _picker.pickImage(source: ImageSource.camera, imageQuality: 92, maxWidth: 2600)]
        : await _picker.pickMultiImage(imageQuality: 92, maxWidth: 2600);
    if (files.isEmpty) return;
    setState(() => _reading = true);
    var found = 0;
    final read = <String>[];
    String? error;
    try {
      _scanner ??= LabelScanner();
      for (final f in files) {
        final (list, rows) = await _scanner!.addressesFromPhoto(f.path);
        read.addAll(rows);
        for (final a in list) {
          if (_items.any((i) => i.addr.query.toLowerCase() == a.query.toLowerCase())) continue;
          final item = _Item(a);
          _items.add(item);
          found++;
          _geocode(item);
        }
      }
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => _reading = false);
    }
    if (found == 0 && mounted) _showRead(read, error);
  }

  /// Adresa nenalezena: ukázat, co jsem z fotky přečetl (a případnou chybu), ať jde poslat k doladění.
  void _showRead(List<String> rows, String? error) {
    final text = [if (error != null) 'Chyba: $error', ...rows].join('\n');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(error != null ? 'Text z fotky se nepodařilo přečíst' : 'Adresu jsem na fotce nenašel'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              rows.isEmpty && error == null ? 'Na fotce jsem nepřečetl žádný text.' : text,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(ctx);
              _toast('Zkopírováno – můžete to poslat vývojáři.');
            },
            child: const Text('Zkopírovat text'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _geocode(_Item it) async {
    setState(() {
      it.searching = true;
      it.place = null;
    });
    Place? best;
    try {
      final r = await searchPlaces(it.addr.query, near: widget.start);
      best = r.firstOrNull;
      // Bez ulice nic? Aspoň obec podle PSČ.
      if (best == null && it.addr.postcode != null) {
        final r2 = await searchPlaces('${it.addr.postcode} ${it.addr.city ?? ''}', near: widget.start);
        best = r2.firstOrNull;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      it.place = best;
      it.searching = false;
      if (best == null) it.use = false;
    });
  }

  Future<void> _edit(_Item it) async {
    final c = TextEditingController(text: it.addr.query);
    final name = TextEditingController(text: it.addr.name ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Upravit adresu'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Příjemce'),
            ),
            TextField(
              controller: c,
              decoration: const InputDecoration(labelText: 'Adresa (ulice č., PSČ obec)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Zrušit')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hledat')),
        ],
      ),
    );
    if (ok != true) return;
    final parsed = parseAddresses([c.text]).firstOrNull ?? ParsedAddress(street: c.text.trim());
    parsed.name = name.text.trim().isEmpty ? null : name.text.trim();
    setState(() {
      it.addr = parsed;
      it.use = true;
    });
    _geocode(it);
  }

  Future<void> _plan() async {
    final stops = [
      for (final i in _items)
        if (i.use && i.place != null) i,
    ];
    if (stops.isEmpty) return;
    setState(() => _ordering = true);
    try {
      final start = widget.start ?? stops.first.place!.point;
      final pts = [start, for (final s in stops) s.place!.point];
      final m = await travelMatrix(
        pts,
        widget.settings.profile,
        valhallaUrl: widget.settings.valhallaUrl,
        delivery: widget.settings.delivery,
      );
      final order = bestOrder(m, returnToStart: _roundTrip);
      final points = [
        for (final k in order)
          PlanPoint(stops[k - 1].addr.name ?? stops[k - 1].addr.label, stops[k - 1].place!.point),
      ];
      final plan = _roundTrip && widget.start != null
          ? TripPlan(name: 'Rozvoz', stops: points, dest: PlanPoint('Zpět na start', widget.start!))
          : TripPlan(name: 'Rozvoz', stops: points.sublist(0, points.length - 1), dest: points.last);
      if (mounted) Navigator.pop(context, plan);
    } finally {
      if (mounted) setState(() => _ordering = false);
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final ready = _items.where((i) => i.use && i.place != null).length;
    final busy = _items.any((i) => i.searching);
    return Scaffold(
      appBar: AppBar(title: const Text('Adresy z fotek')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
        children: [
          const Text(
            'Vyfoťte dodací list nebo štítky balíků. Adresy přečtu přímo v telefonu, '
            'najdu je na mapě a seřadím zastávky, ať jedete co nejkratší cestu. '
            'Pořadí pak můžete v plánu změnit tažením.',
            style: TextStyle(color: Lkw.muted),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  onPressed: _reading ? null : () => _photo(camera: true),
                  icon: const Icon(Icons.photo_camera),
                  label: const Text('Vyfotit'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  onPressed: _reading ? null : () => _photo(camera: false),
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Z galerie'),
                ),
              ),
            ],
          ),
          if (_reading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Row(
                children: [
                  SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('Čtu text z fotky…'),
                ],
              ),
            ),
          const SizedBox(height: 8),
          for (final it in _items)
            Card(
              color: Lkw.panel,
              child: ListTile(
                leading: Checkbox(
                  value: it.use && it.place != null,
                  onChanged: it.place == null ? null : (v) => setState(() => it.use = v ?? false),
                ),
                title: Text(it.addr.name ?? it.addr.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [
                    if (it.addr.name != null) it.addr.label,
                    if (it.searching)
                      'hledám na mapě…'
                    else if (it.place == null)
                      'nenalezeno – klepněte a opravte'
                    else
                      '✓ ${it.place!.name}${it.place!.address != null ? ', ${it.place!.address}' : ''}',
                  ].join('\n'),
                  style: TextStyle(color: !it.searching && it.place == null ? Lkw.danger : null),
                ),
                isThreeLine: it.addr.name != null,
                onTap: () => _edit(it),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => _items.remove(it)),
                ),
              ),
            ),
          if (_items.isNotEmpty)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Vrátit se na start'),
              subtitle: const Text('Okruh – poslední zastávka zpět na místo, odkud vyjíždíte'),
              value: _roundTrip,
              onChanged: widget.start == null ? null : (v) => setState(() => _roundTrip = v),
            ),
        ],
      ),
      bottomNavigationBar: _items.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  onPressed: ready == 0 || busy || _ordering ? null : _plan,
                  icon: _ordering
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.alt_route),
                  label: Text(_ordering ? 'Počítám pořadí…' : 'Seřadit a naplánovat ($ready)'),
                ),
              ),
            ),
    );
  }
}
