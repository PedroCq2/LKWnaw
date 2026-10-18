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
  DateTime? _offSince;

  /// Indexy manévrů, pro které už zazněla hlášení.
  final Set<int> alertSpoken = {};
  final Set<int> preSpoken = {};

  /// Odpočet před manévrem (klíč = místo manévru × 10 + stupeň) a „pokračujte X km“.
  final Set<int> stageSpoken = {};
  final Set<int> continueSpoken = {};

  /// Manévry už řečené jako „… a poté …“ u předchozího (klíč → vzdálenost od něj v m).
  final Map<int, double> chained = {};

  NavEngine(this.route);

  static const offRouteMeters = 60.0;

  /// [accuracy] = přesnost GPS (m); při horším signálu se práh sjetí zvětší.
  /// [course] = směr jízdy z GPS (jen za jízdy) – jede-li vozidlo jinam než trasa, sjetí se pozná hned.
  NavState update(LatLng pos, {double accuracy = 10, DateTime? now, double? course}) {
    final shape = route.shape;
    final t0 = now ?? DateTime.now();
    final cum0 = route.cumulative;
    // Hledej jen tam, kam kamion od minulé polohy mohl dojet (max ~140 km/h): trasa se může
    // vracet blízko sebe (podjezd pod mostem, po kterém se pojede za chvíli) – bez okna by poloha
    // „skočila“ dopředu a navigace by přeskočila odbočky a hlásila sjetí z trasy.
    final dt = _lastFixAt == null ? 20.0 : t0.difference(_lastFixAt!).inMilliseconds / 1000;
    final fromM = _lastTraveled - 40, toM = _lastTraveled + 80 + 40 * dt;
    var lo = _lastSegment;
    while (lo > 0 && cum0[lo] > fromM) {
      lo--;
    }
    var hi = _lastSegment;
    while (hi < shape.length - 1 && cum0[hi] < toM) {
      hi++;
    }
    var best = _search(pos, lo, math.min(shape.length - 1, hi + 1));
    if (best.$2 > offRouteMeters) {
      final global = _search(pos, 0, shape.length - 1);
      if (global.$2 < best.$2) best = global;
    }
    final (seg, dist, t, snapped) = best;
    _lastSegment = seg;
    _lastFixAt = t0;
    final limit = math.max(offRouteMeters, accuracy * 1.5);
    if (dist > limit) {
      _offRouteCount++;
      _offSince ??= t0;
    } else {
      _offRouteCount = 0;
      _offSince = null;
    }
    // Odbočil jinam: 30 m od trasy a jede jiným směrem než trasa (> 45°).
    var diverging = false;
    if (course != null && dist > math.max(30.0, accuracy) && seg + 1 < shape.length) {
      var b = _bearing(shape[seg], shape[seg + 1]);
      var diff = ((course - b) % 360 + 360) % 360;
      if (diff > 180) diff = 360 - diff;
      diverging = diff > 45;
    }
    // Přejetá odbočka: vzdálenost od trasy roste poloha za polohou (sjezd se od dálnice odklání pozvolna).
    if (dist > math.max(18.0, accuracy) && dist > _prevDist + 0.5) {
      _growCount++;
    } else if (dist < 12) {
      _growCount = 0;
    }
    _prevDist = dist;
    if (diverging) {
      _divergeCount++;
      _divergeSince ??= t0;
    } else {
      _divergeCount = 0;
      _divergeSince = null;
    }
    _lastNow = t0;

    final cum = route.cumulative;
    final segLen = seg + 1 < shape.length ? cum[seg + 1] - cum[seg] : 0.0;
    final traveled = cum[seg] + segLen * t;
    _lastTraveled = traveled;
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

  DateTime _lastNow = DateTime.now();
  DateTime? _lastFixAt;
  double _lastTraveled = 0;

  int _divergeCount = 0;
  int _growCount = 0;
  double _prevDist = 0;
  DateTime? _divergeSince;

  /// Sjetí z trasy: jiným směrem než trasa 2 polohy / 1,5 s, jinak 3 polohy a 3 s mimo trasu
  /// (krátký výkyv GPS nestačí).
  bool get isOffRoute =>
      _growCount >= 4 ||
      (_divergeCount >= 2 &&
          _divergeSince != null &&
          _lastNow.difference(_divergeSince!) >= const Duration(milliseconds: 1500)) ||
      (_offRouteCount >= 3 &&
          _offSince != null &&
          _lastNow.difference(_offSince!) >= const Duration(seconds: 3));

  /// Po přepočtu: počítat znovu od nuly.
  void resetOffRoute() {
    _offRouteCount = _divergeCount = _growCount = 0;
    _offSince = _divergeSince = null;
  }

  static double _bearing(LatLng a, LatLng b) {
    final la1 = a.latitude * math.pi / 180, la2 = b.latitude * math.pi / 180;
    final dl = (b.longitude - a.longitude) * math.pi / 180;
    final y = math.sin(dl) * math.cos(la2);
    final x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(dl);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

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
        bestPt = LatLng(
          a.latitude + t * (b.latitude - a.latitude),
          a.longitude + t * (b.longitude - a.longitude),
        );
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
