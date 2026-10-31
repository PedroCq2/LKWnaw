import 'dart:async';
import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/route.dart';
import 'lanes.dart';
import 'parking_network.dart';

/// Opravy rychlostních limitů pro kamiony. Valhalla zná jen obecný limit z OSM (Jižní spojka 80),
/// značka pro kamiony (60) v mapě často chybí. Pořadí: co nahlásil řidič v tomto telefonu (platí hned),
/// co shodně nahlásili aspoň dva řidiči (server sítě), kamionový limit z OSM (`maxspeed:hgv`).
class SpeedFixes {
  SpeedFixes._();
  static final instance = SpeedFixes._();

  final Map<int, int> _mine = {}; // way id → km/h
  Future<void>? _loading;

  Future<void> load() => _loading ??= () async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString('speed.fixes');
      if (raw == null) return;
      (jsonDecode(raw) as Map).forEach((k, v) => _mine[int.parse('$k')] = (v as num).toInt());
    } catch (_) {}
  }();

  /// Řidič nahlásil, co je na značce: v telefonu platí hned, na server jde k ověření (a opravě mapy).
  Future<void> report({required int wayId, required LatLng at, required int? shown, required int kmh}) async {
    await load();
    _mine[wayId] = kmh;
    try {
      await (await SharedPreferences.getInstance()).setString(
        'speed.fixes',
        jsonEncode({for (final e in _mine.entries) '${e.key}': e.value}),
      );
    } catch (_) {}
    await ParkingNetwork.instance.submit('speed_report', 'r', {
      'way_id': wayId,
      'lat': double.parse(at.latitude.toStringAsFixed(6)),
      'lon': double.parse(at.longitude.toStringAsFixed(6)),
      'shown': shown,
      'kmh': kmh,
    });
  }

  /// Doplní do limitů trasy opravy (nejdřív hned ty z telefonu, pak ze serveru a z OSM).
  /// Vrací true, když se nějaký limit změnil.
  Future<bool> apply(TruckRoute route) async {
    await load();
    final ways = {for (final e in route.edges) ?e.wayId}.toList();
    if (ways.isEmpty) return false;
    final fixes = <int, int>{};
    // Kamionové limity z OSM jen na hlavních silnicích (tam bývají značky pro kamiony).
    final main = {
      for (final e in route.edges)
        if (e.wayId != null && const {'motorway', 'trunk', 'primary', 'secondary'}.contains(e.roadClass)) e.wayId!,
    }.take(400).toList();
    try {
      final tags = await osmWayTags(main).timeout(const Duration(seconds: 25));
      fixes.addAll(hgvLimits(tags));
    } catch (_) {}
    try {
      fixes.addAll(await ParkingNetwork.instance.speedFixes(ways));
    } catch (_) {}
    fixes.addAll({for (final w in ways) w: ?_mine[w]});
    return applySpeedFixes(route, fixes);
  }

  /// Jen opravy z tohoto telefonu (okamžitě po nahlášení, bez čekání na síť).
  Future<bool> applyMine(TruckRoute route) async {
    await load();
    return applySpeedFixes(route, _mine);
  }
}

/// `maxspeed:hgv` z tagů cest (číslo v km/h; směrové hodnoty a „mph“ se přeskočí).
Map<int, int> hgvLimits(Map<int, Map<String, String>> tags) => {
  for (final e in tags.entries)
    if (int.tryParse(e.value['maxspeed:hgv'] ?? '') case final v? when v >= 5 && v <= 150) e.key: v,
};

/// Přepíše limity úseků trasy, které leží na opravených cestách. Vrací true, když se něco změnilo.
bool applySpeedFixes(TruckRoute route, Map<int, int> fixes) {
  if (fixes.isEmpty || route.speedLimits.isEmpty) return false;
  final limits = [...route.speedLimits];
  var changed = false;
  for (final e in route.edges) {
    final v = e.wayId == null ? null : fixes[e.wayId];
    if (v == null) continue;
    for (var i = e.begin; i < e.end && i < limits.length; i++) {
      if (limits[i] != v) {
        limits[i] = v;
        changed = true;
      }
    }
  }
  if (changed) route.speedLimits = limits;
  return changed;
}
