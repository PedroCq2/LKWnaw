import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Uložené místo (firma, sklad): adresa, zvlášť vjezd pro kamiony a poznámka řidiče.
class SavedPlace {
  final String id;
  String name;
  LatLng point; // adresa / sídlo
  LatLng? gate; // brána / vjezd pro kamiony – sem se naviguje
  String? note; // „Příjezd zezadu, vrátnice u rampy 12.“

  SavedPlace({required this.id, required this.name, required this.point, this.gate, this.note});

  LatLng get target => gate ?? point;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'lat': point.latitude,
    'lon': point.longitude,
    if (gate != null) 'glat': gate!.latitude,
    if (gate != null) 'glon': gate!.longitude,
    if (note != null && note!.isNotEmpty) 'note': note,
  };

  static SavedPlace fromJson(Map<String, dynamic> j) => SavedPlace(
    id: j['id'] as String,
    name: j['name'] as String,
    point: LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
    gate: j['glat'] == null ? null : LatLng((j['glat'] as num).toDouble(), (j['glon'] as num).toDouble()),
    note: j['note'] as String?,
  );
}

class SavedPlaces {
  static const _key = 'savedPlaces';
  final List<SavedPlace> items;
  SavedPlaces(this.items);

  static Future<SavedPlaces> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null) return SavedPlaces([]);
      return SavedPlaces([
        for (final e in jsonDecode(raw) as List) SavedPlace.fromJson(Map<String, dynamic>.from(e as Map)),
      ]);
    } catch (_) {
      return SavedPlaces([]);
    }
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode([for (final e in items) e.toJson()]));
  }

  /// Uložené místo v okolí bodu (do 300 m od adresy nebo brány).
  SavedPlace? near(LatLng p) {
    const d = Distance();
    for (final s in items) {
      if (d(s.point, p) < 300 || (s.gate != null && d(s.gate!, p) < 300)) return s;
    }
    return null;
  }

  List<SavedPlace> search(String q) {
    final t = q.trim().toLowerCase();
    if (t.isEmpty) return List.of(items);
    return items
        .where((s) => s.name.toLowerCase().contains(t) || (s.note ?? '').toLowerCase().contains(t))
        .toList();
  }

  Future<void> upsert(SavedPlace s) async {
    items.removeWhere((e) => e.id == s.id);
    items.insert(0, s);
    await save();
  }

  Future<void> remove(String id) async {
    items.removeWhere((e) => e.id == id);
    await save();
  }
}
