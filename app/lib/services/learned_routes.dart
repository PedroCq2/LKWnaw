import 'dart:convert';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'road_via.dart';

/// Trasa, kterou řidič projel a navigaci „naučil“ („v Děčíně z hlavní, na kruháči u Orlenu vpravo,
/// rovně a na konci vpravo – Kaufland“). Příště k cíli u jejího konce navigace pojede tudy.
class LearnedRoute {
  final String id;
  String name;
  final List<LatLng> points;
  final DateTime created;
  LearnedRoute({required this.id, required this.name, required this.points, required this.created});

  LatLng get end => points.last;

  /// Délka (m).
  double get length {
    const d = Distance();
    var s = 0.0;
    for (var i = 1; i < points.length; i++) {
      s += d(points[i - 1], points[i]);
    }
    return s;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'created': created.millisecondsSinceEpoch,
    'pts': [
      for (final p in points) ...[(p.latitude * 1e5).round(), (p.longitude * 1e5).round()],
    ],
  };

  static LearnedRoute fromJson(Map<String, dynamic> j) {
    final v = (j['pts'] as List).cast<num>();
    return LearnedRoute(
      id: j['id'] as String,
      name: j['name'] as String,
      created: DateTime.fromMillisecondsSinceEpoch((j['created'] as num).toInt()),
      points: [for (var i = 0; i + 1 < v.length; i += 2) LatLng(v[i] / 1e5, v[i + 1] / 1e5)],
    );
  }
}

class LearnedRoutes {
  static const _key = 'learnedRoutes';
  final List<LearnedRoute> items;
  LearnedRoutes(this.items);

  static Future<LearnedRoutes> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return LearnedRoutes([]);
      return LearnedRoutes([
        for (final e in jsonDecode(raw) as List) LearnedRoute.fromJson(Map<String, dynamic>.from(e as Map)),
      ]);
    } catch (_) {
      return LearnedRoutes([]);
    }
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode([for (final r in items) r.toJson()]));
  }

  /// Naučená trasa k cíli [dest]: končí do 300 m od něj (nejnovější).
  LearnedRoute? forDest(LatLng dest) {
    const d = Distance();
    LearnedRoute? best;
    for (final r in items) {
      if (r.points.length < 2 || d(r.end, dest) > 300) continue;
      if (best == null || r.created.isAfter(best.created)) best = r;
    }
    return best;
  }
}

/// Zjednoduší nahranou stopu (Douglas–Peucker, [tolM] m) – pár set bodů místo tisíců.
List<LatLng> simplifyTrack(List<LatLng> pts, {double tolM = 6}) {
  if (pts.length < 3) return [...pts];
  final keep = List<bool>.filled(pts.length, false)
    ..[0] = true
    ..[pts.length - 1] = true;
  final cosLat = math.cos(pts.first.latitude * math.pi / 180);
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    if (b - a < 2) continue;
    final ax = pts[a].longitude * cosLat, ay = pts[a].latitude;
    final dx = pts[b].longitude * cosLat - ax, dy = pts[b].latitude - ay;
    final len2 = dx * dx + dy * dy;
    var maxD = -1.0;
    var idx = a;
    for (var i = a + 1; i < b; i++) {
      final px = pts[i].longitude * cosLat - ax, py = pts[i].latitude - ay;
      final t = len2 == 0 ? 0.0 : ((px * dx + py * dy) / len2).clamp(0.0, 1.0);
      final d = math.sqrt(math.pow(px - t * dx, 2) + math.pow(py - t * dy, 2)) * 111320;
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (maxD > tolM) {
      keep[idx] = true;
      stack
        ..add((a, idx))
        ..add((idx, b));
    }
  }
  return [
    for (var i = 0; i < pts.length; i++)
      if (keep[i]) pts[i],
  ];
}

/// Průjezdní body podél naučené trasy [r] pro Valhallu: od místa trasy nejblíž [from] (kde se na ni
/// najede, za jízdy tam, kde zrovna jsme) do ~100 m před koncem, zhruba po 250 m, se směrem jízdy –
/// Valhalla pak jede přesně tudy. Nejvýš [maxPoints] bodů (u delší trasy řidší).
List<ViaPoint> learnedVia(LearnedRoute r, LatLng from, {int maxPoints = 12}) {
  final pts = r.points;
  if (pts.length < 2) return const [];
  const d = Distance();
  final cum = <double>[0];
  for (var i = 1; i < pts.length; i++) {
    cum.add(cum.last + d(pts[i - 1], pts[i]));
  }
  var start = 0;
  var best = double.infinity;
  for (var i = 0; i < pts.length; i++) {
    final x = d(from, pts[i]);
    if (x < best) {
      best = x;
      start = i;
    }
  }
  final endAt = cum.last - 100;
  // Jedeme po ní: kousek před námi. Jinak až 200 m za začátkem nahrávání – kudy se na ni najede,
  // vybere trasa (začátek nahrávky může být bokem, bod tam by trasu stočil na otočku).
  final fromAt = best < 300 ? cum[start] + 60 : math.max(cum[start], 200.0);
  if (endAt - fromAt < 50) return const [];
  final step = math.max(250.0, (endAt - fromAt) / maxPoints);
  final out = <ViaPoint>[];
  var i = start;
  for (var at = fromAt; at <= endAt; at += step) {
    // Úsek pts[i] → pts[i+1], na kterém leží místo [at] (zjednodušená stopa má řídké body).
    while (i < pts.length - 2 && cum[i + 1] < at) {
      i++;
    }
    final a = pts[i], b = pts[i + 1];
    final len = cum[i + 1] - cum[i];
    final t = len <= 0 ? 0.0 : ((at - cum[i]) / len).clamp(0.0, 1.0);
    final h = d.bearing(a, b);
    out.add(
      ViaPoint(
        LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t),
        through: true,
        dense: true,
        heading: h < 0 ? h + 360 : h,
      ),
    );
  }
  return out;
}
