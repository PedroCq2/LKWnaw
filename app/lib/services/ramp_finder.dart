import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'offline_search.dart';
import 'restrictions.dart';

/// Kam přesně kamion jede: rampa / zásobovací vjezd, ne parkoviště před obchodem.
class Ramp {
  final LatLng point;
  final String how; // co to je – ukáže se řidiči
  final bool sure; // zakreslená v mapě (true) / odhad zadního příjezdu (false)
  const Ramp(this.point, this.how, {required this.sure});
}

typedef _Geom = List<LatLng>;

/// Rampa u cíle: přednostně předpočítaná v rejstříku v telefonu (okamžitě, bez internetu),
/// jinak dotaz na mapová data online.
Future<Ramp?> rampFor(LatLng poi) async {
  final off = OfflineSearch.instance;
  if (off.hasRamps) {
    final r = off.rampAt(poi);
    if (r == null) return null;
    final (p, how) = r as (LatLng, int);
    return Ramp(
      p,
      const {1: 'Rampa', 2: 'Služební vchod', 3: 'Vjezd pro zásobování'}[how] ?? 'Zadní příjezd (odhad)',
      sure: how != 4,
    );
  }
  try {
    return await findRamp(poi).timeout(const Duration(seconds: 8));
  } catch (_) {
    return null;
  }
}

LatLng _ll(Map g) => LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble());

/// Hledá rampu u cíle [poi] (obchod, sklad, firma):
/// 1. rampa / služební vchod zakreslený v OSM (amenity=loading_dock, door=loading_dock, entrance=service),
/// 2. příjezdová cesta jen pro zásobování (access/motor_vehicle/hgv=delivery, service=delivery),
/// 3. odhad: obslužná cesta u budovy na straně odvrácené od parkoviště (zásobování bývá zezadu).
/// null = nic nenalezeno (řidič může rampu označit sám).
Future<Ramp?> findRamp(LatLng poi, {Future<List<dynamic>?> Function(String q) query = overpassQuery}) async {
  final a = '(around:260,${poi.latitude.toStringAsFixed(6)},${poi.longitude.toStringAsFixed(6)})';
  final els = await query(
    '[out:json][timeout:12];('
    'node$a["amenity"="loading_dock"];'
    'node$a["door"="loading_dock"];'
    'node$a["entrance"~"^(service|delivery|loading_dock)\$"];'
    'way$a["highway"="service"];'
    'way(around:150,${poi.latitude.toStringAsFixed(6)},${poi.longitude.toStringAsFixed(6)})["building"];'
    'nwr$a["amenity"="parking"];'
    ');out tags geom;',
  );
  if (els == null) return null;
  return pickRamp(poi, els);
}

/// Vyhodnocení odpovědi Overpass (veřejné kvůli testům).
Ramp? pickRamp(LatLng poi, List<dynamic> els) {
  const d = Distance();
  final docks = <(LatLng, String)>[];
  final delivery = <_Geom>[];
  final service = <_Geom>[];
  final buildings = <_Geom>[];
  final parkings = <LatLng>[];
  for (final e in els) {
    final t = Map<String, dynamic>.from((e['tags'] as Map?) ?? const {});
    if (e['type'] == 'node') {
      final p = _ll(e as Map);
      if (t['amenity'] == 'parking') {
        parkings.add(p);
      } else if (t['amenity'] == 'loading_dock' || t['door'] == 'loading_dock') {
        docks.add((p, 'rampa'));
      } else if (t['entrance'] != null) {
        docks.add((p, 'služební vchod'));
      }
      continue;
    }
    final geom = [for (final g in (e['geometry'] as List? ?? const [])) _ll(g as Map)];
    if (geom.isEmpty) continue;
    if (t['amenity'] == 'parking') {
      parkings.add(_centroid(geom));
    } else if (t['building'] != null) {
      buildings.add(geom);
    } else if (t['highway'] == 'service') {
      const deliveryValues = {'delivery', 'destination', 'designated'};
      final isDelivery =
          t['service'] == 'delivery' ||
          t['service'] == 'loading' ||
          t['access'] == 'delivery' ||
          t['motor_vehicle'] == 'delivery' ||
          deliveryValues.contains(t['hgv']);
      if (t['service'] == 'parking_aisle' || t['service'] == 'drive-through') continue;
      if (t['access'] == 'private' && !isDelivery) {
        service.add(geom); // soukromé obslužné cesty bývají právě k rampám
      } else if (isDelivery) {
        delivery.add(geom);
      } else {
        service.add(geom);
      }
    }
  }

  // Budova cíle: ta, ve které POI leží, jinak nejbližší větší budova.
  _Geom? building;
  var best = double.infinity;
  for (final b in buildings) {
    if (b.length < 4) continue;
    final inside = _inside(b, poi);
    final dist = inside ? 0.0 : d(_centroid(b), poi);
    final area = _areaM2(b);
    if (area < 300) continue;
    if (dist < best) {
      best = dist;
      building = b;
    }
  }

  // 1) Zakreslená rampa – nejbližší k budově / cíli.
  if (docks.isNotEmpty) {
    final ref = building != null ? _centroid(building) : poi;
    docks.sort((x, y) => d(x.$1, ref).compareTo(d(y.$1, ref)));
    final (p, kind) = docks.first;
    if (d(p, ref) < 220) return Ramp(p, kind == 'rampa' ? 'Rampa' : 'Služební vchod', sure: true);
  }

  final ref = building != null ? _centroid(building) : poi;
  // 2) Cesta jen pro zásobování – bod nejblíž budově.
  if (delivery.isNotEmpty) {
    LatLng? bp;
    var bd = double.infinity;
    for (final w in delivery) {
      for (final p in w) {
        final dd = building != null ? _distToRing(building, p) : d(p, ref);
        if (dd < bd) {
          bd = dd;
          bp = p;
        }
      }
    }
    if (bp != null && bd < 120) return Ramp(bp, 'Vjezd pro zásobování', sure: true);
  }

  // 3) Odhad: obslužná cesta u budovy na opačné straně než parkoviště.
  if (building != null && service.isNotEmpty) {
    final b = _centroid(building);
    final k = math.cos(b.latitude * math.pi / 180);
    double vx = 0, vy = 0;
    if (parkings.isNotEmpty) {
      parkings.sort((x, y) => d(x, b).compareTo(d(y, b)));
      final p = parkings.first;
      vx = (b.longitude - p.longitude) * k;
      vy = b.latitude - p.latitude;
      final n = math.sqrt(vx * vx + vy * vy);
      if (n > 0) {
        vx /= n;
        vy /= n;
      }
    }
    LatLng? bp;
    var bs = -double.infinity;
    for (final w in service) {
      for (final p in w) {
        final dist = _distToRing(building, p);
        if (dist > 45) continue;
        // Bod za budovou (od parkoviště) a co nejblíž budově.
        final px = (p.longitude - b.longitude) * k, py = p.latitude - b.latitude;
        final behind = (px * vx + py * vy) * 111000;
        final score = (parkings.isEmpty ? 0 : behind) - dist * 0.5;
        if (score > bs) {
          bs = score;
          bp = p;
        }
      }
    }
    if (bp != null && (parkings.isEmpty || bs > 5)) {
      return Ramp(bp, 'Zadní příjezd (odhad)', sure: false);
    }
  }
  return null;
}

LatLng _centroid(_Geom g) {
  var la = 0.0, lo = 0.0;
  for (final p in g) {
    la += p.latitude;
    lo += p.longitude;
  }
  return LatLng(la / g.length, lo / g.length);
}

bool _inside(_Geom ring, LatLng p) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    if ((a.latitude > p.latitude) != (b.latitude > p.latitude) &&
        p.longitude <
            (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) +
                a.longitude) {
      inside = !inside;
    }
  }
  return inside;
}

double _areaM2(_Geom ring) {
  final k = math.cos(ring.first.latitude * math.pi / 180) * 111320, m = 110540.0;
  var s = 0.0;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    s += (ring[j].longitude * k) * (ring[i].latitude * m) - (ring[i].longitude * k) * (ring[j].latitude * m);
  }
  return s.abs() / 2;
}

/// Vzdálenost bodu od obvodu budovy (m).
double _distToRing(_Geom ring, LatLng p) {
  final k = math.cos(p.latitude * math.pi / 180) * 111320, m = 110540.0;
  var best = double.infinity;
  for (var i = 0; i < ring.length - 1; i++) {
    final ax = (ring[i].longitude - p.longitude) * k, ay = (ring[i].latitude - p.latitude) * m;
    final bx = (ring[i + 1].longitude - p.longitude) * k, by = (ring[i + 1].latitude - p.latitude) * m;
    final dx = bx - ax, dy = by - ay;
    final l2 = dx * dx + dy * dy;
    final t = l2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / l2).clamp(0.0, 1.0);
    final x = ax + t * dx, y = ay + t * dy;
    best = math.min(best, math.sqrt(x * x + y * y));
  }
  return _inside(ring, p) ? 0 : best;
}
