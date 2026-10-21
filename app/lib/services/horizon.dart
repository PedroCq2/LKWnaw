import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/route.dart';
import '../models/truck_profile.dart';
import 'offline_search.dart';
import 'restrictions.dart';
import 'valhalla.dart';

/// Omezení na silnici před námi při jízdě bez cíle.
class AheadWarning {
  final RouteWarning w; // atMeters = vzdálenost po silnici v okamžiku hledání
  final double odo; // kolik bylo ujeto (m), když se vzdálenost změřila
  final String road;
  AheadWarning(this.w, this.odo, this.road);

  /// Zbývá po silnici (m) při ujeté vzdálenosti [odoNow].
  double remaining(double odoNow) => w.atMeters - (odoNow - odo);

  String get key =>
      '${w.type.name}:${w.value}:${w.point.latitude.toStringAsFixed(4)},'
      '${w.point.longitude.toStringAsFixed(4)}';
}

/// Silnice z jmen úseku od Valhally: dálnice („D8“), číslo silnice („13“, „240“), jinak ulice.
String? roadOf(List<String> names) {
  final t = [for (final n in names) n.trim()];
  return t.where((n) => RegExp(r'^D\d+$').hasMatch(n)).firstOrNull ??
      t.where((n) => RegExp(r'^\d{1,5}$').hasMatch(n)).firstOrNull ??
      t.where((n) => !RegExp(r'^E ?\d+$').hasMatch(n)).firstOrNull;
}

bool _isNumbered(String road) => RegExp(r'^D?\d{1,5}$').hasMatch(road);

/// Leží cesta se štítky [tags] na silnici [road]? (ref „13“ / „D8“, u ulic jméno)
bool onRoad(Map<String, dynamic> tags, String road) {
  if (_isNumbered(road)) {
    return '${tags['ref'] ?? ''}'.split(';').map((r) => r.trim().replaceAll(' ', '')).contains(road);
  }
  return tags['name'] == road;
}

/// Zákaz vjezdu nákladních vozidel (B4), případně „jen dopravní obsluha“.
RouteWarning? hgvBan(Map<String, dynamic> tags, double at, LatLng p) {
  final hgv = tags['hgv'];
  if (hgv == 'no') {
    return RouteWarning(type: WarningType.noHgv, value: null, atMeters: at, point: p, violates: true);
  }
  if (hgv == 'destination' || hgv == 'delivery') {
    return RouteWarning(
      type: WarningType.noHgv,
      value: null,
      note: 'obsluha',
      atMeters: at,
      point: p,
      violates: false,
      tight: true,
    );
  }
  return null;
}

/// Jízda bez cíle: kamionová omezení na silnici, po které jedeme (nízký most, úzká silnice, hmotnost,
/// zákaz vjezdu kamionů), do [range] před námi – „za 20 km most 3,3 m“.
///
/// Silnici pozná z posledních poloh (Valhalla), omezení hledá na cestách se stejným číslem
/// (u ulic jménem) ve směru jízdy a vzdálenost změří trasou autem – jen když k nim vede po téže silnici.
class Horizon {
  static const range = 30000.0;
  final ValhallaClient client;

  /// Odkud brát cesty s omezením (testy); jinak balík v telefonu / Overpass.
  final Future<List<dynamic>> Function(LatLng pos, double r, String road) source;
  Horizon(this.client, {this.source = _elements});

  Future<(String?, List<AheadWarning>)> scan({
    required List<LatLng> track,
    required double heading,
    required TruckProfile truck,
    required double odo,
    bool delivery = false,
  }) async {
    final pos = track.last;
    final road = roadOf(await client.roadNamesAt(track));
    if (road == null) return (null, <AheadWarning>[]);
    final r = _isNumbered(road) ? range : 5000.0;
    final els = await source(pos, r, road);
    const dist = Distance();
    final cands = <(double, RouteWarning)>[];
    for (final e in els) {
      final tags = Map<String, dynamic>.from((e['tags'] as Map?) ?? const {});
      if (!onRoad(tags, road)) continue;
      final geom = [
        for (final g
            in (e['geometry'] as List?) ??
                [
                  {
                    'lat': e['lat'] ?? (e['center'] as Map?)?['lat'],
                    'lon': e['lon'] ?? (e['center'] as Map?)?['lon'],
                  },
                ])
          if (g['lat'] != null) LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble()),
      ];
      if (geom.isEmpty) continue;
      // Kde na cestu najedeme: její bod nejblíž nám.
      var p = geom.first;
      var d = double.infinity;
      for (final g in geom) {
        final x = dist(pos, g);
        if (x < d) {
          d = x;
          p = g;
        }
      }
      // Po této cestě už jedeme, nebo je moc daleko.
      if (d < 40 || d > r) continue;
      var diff = (dist.bearing(pos, p) - heading).abs() % 360;
      if (diff > 180) diff = 360 - diff;
      if (diff > 70) continue; // za námi / do strany
      final ws = [
        for (final w in warningsFromTags(tags, d, p, truck, delivery))
          if (w.type != WarningType.noOvertakingHgv && w.relevant) w,
        ?hgvBan(tags, d, p),
      ];
      for (final w in ws) {
        cands.add((d, w));
      }
    }
    cands.sort((a, b) => a.$1.compareTo(b.$1));
    final out = <AheadWarning>[];
    final measured = <String, double?>{};
    for (final (d, w) in cands) {
      if (out.length >= 5 || measured.length >= 6) break;
      final k = '${w.point.latitude.toStringAsFixed(4)},${w.point.longitude.toStringAsFixed(4)}';
      if (!measured.containsKey(k)) measured[k] = await _along(pos, heading, w.point, d, road);
      final along = measured[k];
      if (along == null) continue;
      out.add(
        AheadWarning(
          RouteWarning(
            type: w.type,
            value: w.value,
            note: w.note,
            atMeters: along,
            point: w.point,
            violates: w.violates,
            tight: w.tight,
            onBridge: w.onBridge,
          ),
          odo,
          road,
        ),
      );
    }
    out.sort((a, b) => a.w.atMeters.compareTo(b.w.atMeters));
    // Jedna zóna = mnoho úseků cesty v OSM.
    final kept = mergeWarnings([for (final a in out) a.w]).toSet();
    return (
      road,
      [
        for (final a in out)
          if (kept.contains(a.w)) a,
      ],
    );
  }

  /// Vzdálenost po silnici k bodu [p] (m), nebo null, když k němu nevede po téže silnici.
  Future<double?> _along(LatLng pos, double heading, LatLng p, double straight, String road) async {
    final t = await client.carRoute(pos, heading, p);
    if (t == null) return null;
    final len = t.lengthKm * 1000;
    if (len > straight * 1.6 + 1000) return null;
    // Cestou žádná odbočka na jinou silnici (kruhový objezd na téže silnici nevadí).
    for (final m in t.maneuvers.skip(1)) {
      if (const {4, 5, 6, 26}.contains(m.type) || m.streetNames.isEmpty) continue;
      if (!m.streetNames.any((n) => n.trim().replaceAll(' ', '') == road || n.trim() == road)) return null;
    }
    return len;
  }

  /// Cesty s omezením v okruhu [r] m: balík dat v telefonu, jinak Overpass.
  static Future<List<dynamic>> _elements(LatLng pos, double r, String road) async {
    final off = OfflineSearch.instance;
    if (off.hasOsm) {
      final dLat = r / 110540, dLon = r / (111320 * math.cos(pos.latitude * math.pi / 180));
      return off.osmElements(
        pos.latitude - dLat,
        pos.latitude + dLat,
        pos.longitude - dLon,
        pos.longitude + dLon,
      );
    }
    final esc = road.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final filter = _isNumbered(road) ? '["ref"~"(^|;) *$esc *(;|\$)"]' : '["name"="$esc"]';
    final around =
        'around:${r.round()},${pos.latitude.toStringAsFixed(5)},${pos.longitude.toStringAsFixed(5)}';
    final q =
        '[out:json][timeout:25];('
        'way($around)$filter[~"^max(height|weight|width|length|axleload)(:physical)?\$"~"."];'
        'way($around)$filter["hgv"~"^(no|destination|delivery)\$"];'
        ');out tags geom;';
    return await overpassQuery(q) ?? const [];
  }
}
