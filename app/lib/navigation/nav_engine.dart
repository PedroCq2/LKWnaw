import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/route.dart';

class NavState {
  final LatLng snapped;
  final int segmentIndex;
  final double distanceFromRoute; // m
  final double traveled; // m od začátku
  final double remaining; // m do cíle
  final int nextManeuverIndex; // -1 = žádný
  final double distanceToNextManeuver; // m
  final bool arrived;

  NavState({
    required this.snapped,
    required this.segmentIndex,
    required this.distanceFromRoute,
    required this.traveled,
    required this.remaining,
    required this.nextManeuverIndex,
    required this.distanceToNextManeuver,
    required this.arrived,
  });
}

/// Přichycení polohy k trase, výpočet postupu a detekce sjetí z trasy.
class NavEngine {
  final TruckRoute route;
  int _lastSegment = 0;
  int _offRouteCount = 0;

  /// Indexy manévrů, pro které už zazněla hlášení.
  final Set<int> alertSpoken = {};
  final Set<int> preSpoken = {};

  NavEngine(this.route);

  static const offRouteMeters = 60.0;

  NavState update(LatLng pos) {
    final shape = route.shape;
    // Hledej nejdřív v okně kolem posledního segmentu, pak globálně.
    var best = _search(pos, math.max(0, _lastSegment - 5),
        math.min(shape.length - 1, _lastSegment + 300));
    if (best.$2 > offRouteMeters) {
      final global = _search(pos, 0, shape.length - 1);
      if (global.$2 < best.$2) best = global;
    }
    final (seg, dist, t, snapped) = best;
    _lastSegment = seg;
    _offRouteCount = dist > offRouteMeters ? _offRouteCount + 1 : 0;

    final cum = route.cumulative;
    final segLen = seg + 1 < shape.length ? cum[seg + 1] - cum[seg] : 0.0;
    final traveled = cum[seg] + segLen * t;
    final total = cum.last;
    final remaining = math.max(0.0, total - traveled);

    var next = -1;
    for (var i = 0; i < route.maneuvers.length; i++) {
      if (route.maneuvers[i].beginShapeIndex > seg) {
        next = i;
        break;
      }
    }
    final toNext = next >= 0
        ? math.max(0.0, cum[route.maneuvers[next].beginShapeIndex] - traveled)
        : remaining;

    return NavState(
      snapped: snapped,
      segmentIndex: seg,
      distanceFromRoute: dist,
      traveled: traveled,
      remaining: remaining,
      nextManeuverIndex: next,
      distanceToNextManeuver: toNext,
      arrived: remaining < 30,
    );
  }

  /// Sjetí z trasy potvrzené několika po sobě jdoucími polohami.
  bool get isOffRoute => _offRouteCount >= 3;

  (int, double, double, LatLng) _search(LatLng p, int from, int to) {
    final shape = route.shape;
    if (shape.length < 2) return (0, _haversine(p, shape.first), 0.0, shape.first);
    var bestSeg = from;
    var bestDist = double.infinity;
    var bestT = 0.0;
    var bestPt = shape[from];
    final cosLat = math.cos(p.latitude * math.pi / 180);
    for (var i = from; i < to && i + 1 < shape.length; i++) {
      final a = shape[i], b = shape[i + 1];
      // Lokální rovinná aproximace (stačí na vzdálenosti desítek metrů).
      final ax = (a.longitude - p.longitude) * cosLat, ay = a.latitude - p.latitude;
      final bx = (b.longitude - p.longitude) * cosLat, by = b.latitude - p.latitude;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      var t = len2 == 0 ? 0.0 : -(ax * dx + ay * dy) / len2;
      t = t.clamp(0.0, 1.0);
      final px = ax + t * dx, py = ay + t * dy;
      final d2 = px * px + py * py;
      if (d2 < bestDist) {
        bestDist = d2;
        bestSeg = i;
        bestT = t;
        bestPt = LatLng(a.latitude + t * (b.latitude - a.latitude),
            a.longitude + t * (b.longitude - a.longitude));
      }
    }
    return (bestSeg, _haversine(p, bestPt), bestT, bestPt);
  }

  static double _haversine(LatLng a, LatLng b) => const Distance()(a, b);
}

String formatDistance(double m) {
  if (m >= 10000) return '${(m / 1000).round()} km';
  if (m >= 1000) return '${(m / 1000).toStringAsFixed(1)} km';
  if (m >= 100) return '${(m / 50).round() * 50} m';
  return '${(m / 10).round() * 10} m';
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h > 0 ? '$h h ${m.toString().padLeft(2, '0')} min' : '$m min';
}
