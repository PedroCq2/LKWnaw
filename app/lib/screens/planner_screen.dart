import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/geocoding.dart';
import '../services/plans.dart';
import '../services/saved_places.dart';
import '../services/settings.dart';
import '../theme.dart';
import 'scan_screen.dart';

/// Plánování trasy: začátek, zastávky (přeřazení tažením), cíl; uložené plány.
class PlannerScreen extends StatefulWidget {
  final SavedPlaces saved;
  final LatLng? myPosition;
  final TripPlan? initial;
  final AppSettings? settings; // pro focení adres (profil vozidla, server tras)
  const PlannerScreen({super.key, required this.saved, this.myPosition, this.initial, this.settings});

  @override
  State<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends State<PlannerScreen> {
  PlanPoint? _start; // null = moje poloha
  final List<PlanPoint> _stops = [];
  PlanPoint? _dest;
  List<TripPlan> _plans = [];

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    if (p != null) _load(p);
    TripPlans.load().then((v) {
      if (mounted) setState(() => _plans = v);
    });
  }

  void _load(TripPlan p) {
    _start = p.start;
    _stops
      ..clear()
      ..addAll(p.stops);
    _dest = p.dest;
  }

  Future<PlanPoint?> _pick(String title) => showModalBottomSheet<PlanPoint>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PlaceSearch(title: title, saved: widget.saved, near: widget.myPosition),
  );

  /// Vyfocené adresy: seřazené zastávky nahradí plán (start zůstane), pořadí lze dál měnit tažením.
  Future<void> _scan() async {
    final plan = await Navigator.push<TripPlan>(
      context,
      MaterialPageRoute(
        builder: (_) => ScanScreen(settings: widget.settings!, start: _start?.point ?? widget.myPosition),
      ),
    );
    if (plan == null || !mounted) return;
    setState(() {
      _stops
        ..clear()
        ..addAll(plan.stops);
      _dest = plan.dest;
    });
  }

  Future<void> _savePlan() async {
    final dest = _dest;
    if (dest == null) return;
    final name = TextEditingController(text: dest.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Uložit plán'),
        content: TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'Název plánu'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Zrušit')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Uložit')),
        ],
      ),
    );
    if (ok != true) return;
    final plan = TripPlan(
      name: name.text.trim().isEmpty ? dest.name : name.text.trim(),
      start: _start,
      stops: [..._stops],
      dest: dest,
    );
    _plans
      ..removeWhere((p) => p.name == plan.name)
      ..insert(0, plan);
    await TripPlans.save(_plans);
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Plán „${plan.name}“ uložen.')));
    }
  }

  Widget _row({
    required Key key,
    required IconData icon,
    required Color color,
    required String label,
    required String? value,
    required VoidCallback onTap,
    VoidCallback? onDelete,
    bool reorder = false,
    int index = 0,
  }) => Material(
    key: key,
    color: Lkw.panel,
    child: ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        value ?? label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: value == null ? Lkw.muted : Lkw.text, fontWeight: FontWeight.w700),
      ),
      subtitle: value == null ? null : Text(label, style: const TextStyle(color: Lkw.muted)),
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onDelete != null) IconButton(icon: const Icon(Icons.close), onPressed: onDelete),
          if (reorder) ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plán trasy'),
        actions: [
          if (widget.settings != null)
            IconButton(icon: const Icon(Icons.document_scanner), tooltip: 'Adresy z fotek', onPressed: _scan),
          if (_dest != null)
            IconButton(icon: const Icon(Icons.save), tooltip: 'Uložit plán', onPressed: _savePlan),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          _row(
            key: const ValueKey('start'),
            icon: Icons.my_location,
            color: Lkw.amber,
            label: 'Začátek',
            value: _start?.name ?? 'Moje poloha',
            onTap: () async {
              final p = await _pick('Začátek trasy');
              if (p != null) setState(() => _start = p);
            },
            onDelete: _start == null ? null : () => setState(() => _start = null),
          ),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (a, b) => setState(() => _stops.insert(b, _stops.removeAt(a))),
            children: [
              for (final (i, s) in _stops.indexed)
                _row(
                  key: ValueKey('stop$i${s.name}'),
                  icon: Icons.add_location_alt,
                  color: Lkw.amber,
                  label: 'Zastávka ${i + 1}',
                  value: s.name,
                  reorder: true,
                  index: i,
                  onTap: () async {
                    final p = await _pick('Zastávka ${i + 1}');
                    if (p != null) setState(() => _stops[i] = p);
                  },
                  onDelete: () => setState(() => _stops.removeAt(i)),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Přidat zastávku'),
              onPressed: () async {
                final p = await _pick('Nová zastávka');
                if (p != null) setState(() => _stops.add(p));
              },
            ),
          ),
          _row(
            key: const ValueKey('dest'),
            icon: Icons.flag,
            color: Lkw.danger,
            label: 'Cíl',
            value: _dest?.name,
            onTap: () async {
              final p = await _pick('Cíl trasy');
              if (p != null) setState(() => _dest = p);
            },
          ),
          if (_plans.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(
                'ULOŽENÉ PLÁNY',
                style: TextStyle(color: Lkw.amber, fontWeight: FontWeight.w800),
              ),
            ),
            for (final p in _plans)
              ListTile(
                leading: const Icon(Icons.route, color: Lkw.amber),
                title: Text(p.name),
                subtitle: Text(
                  [p.start?.name ?? 'Moje poloha', ...p.stops.map((s) => s.name), p.dest.name].join(' → '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => setState(() => _load(p)),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    setState(() => _plans.remove(p));
                    await TripPlans.save(_plans);
                  },
                ),
              ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            icon: const Icon(Icons.alt_route),
            label: const Text('NAPLÁNOVAT TRASU'),
            onPressed: _dest == null
                ? null
                : () => Navigator.pop(
                    context,
                    TripPlan(name: _dest!.name, start: _start, stops: [..._stops], dest: _dest!),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Výběr místa: uložená místa + vyhledávání (Photon/OSM).
class _PlaceSearch extends StatefulWidget {
  final String title;
  final SavedPlaces saved;
  final LatLng? near;
  const _PlaceSearch({required this.title, required this.saved, this.near});

  @override
  State<_PlaceSearch> createState() => _PlaceSearchState();
}

class _PlaceSearchState extends State<_PlaceSearch> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<Place> _results = [];
  bool _busy = false;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    setState(() {});
    if (q.trim().length < 3) return;
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final seq = ++_seq;
      setState(() => _busy = true);
      try {
        final r = await searchPlaces(q, near: widget.near);
        if (mounted && seq == _seq) setState(() => _results = r);
      } catch (_) {
      } finally {
        if (mounted && seq == _seq) setState(() => _busy = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final saved = widget.saved.search(_q.text).take(6).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            ListTile(title: Text(widget.title, style: Theme.of(context).textTheme.titleMedium)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _q,
                autofocus: true,
                onChanged: _changed,
                decoration: InputDecoration(
                  hintText: 'Firma, sklad, adresa…',
                  prefixIcon: const Icon(Icons.search, color: Lkw.amber),
                  suffixIcon: _busy
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                ),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final s in saved)
                    ListTile(
                      leading: Icon(s.gate != null ? Icons.local_shipping : Icons.star, color: Lkw.amber),
                      title: Text(s.name),
                      subtitle: s.note == null
                          ? null
                          : Text(s.note!, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(context, PlanPoint(s.name, s.target)),
                    ),
                  for (final r in _results)
                    ListTile(
                      leading: const Icon(Icons.place, color: Lkw.amber),
                      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [?r.kind, ?r.address].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(context, PlanPoint(r.name, r.point)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
