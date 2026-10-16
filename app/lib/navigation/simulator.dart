import 'dart:async';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/route.dart';

typedef SimFix = void Function(LatLng pos, double speedMps, double heading);

/// Demo režim: „jede“ po trase rychlostí podle limitu (max. [maxKmh]).
class RouteSimulator {
  final TruckRoute route;
  final int maxKmh;
  final SimFix onFix;
  double _at;
  double _speed = 0; // m/s
  Timer? _timer;

  RouteSimulator(this.route, this.maxKmh, this.onFix, {double startAt = 0}) : _at = startAt;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _tick();
  }

  void stop() => _timer?.cancel();

  void _tick() {
    final cum = route.cumulative;
    final total = cum.last;
    var seg = _segAt(_at);
    final limit = route.speedLimitAt(seg) ?? 50;
    final target = math.min(limit, maxKmh) / 3.6;
    // Plynulé zrychlení / brzdění (~1 m/s²).
    _speed += (target - _speed).clamp(-1.5, 1.0);
    _at = math.min(total, _at + _speed);
    seg = _segAt(_at);
    final s = route.shape;
    final a = s[seg], b = s[math.min(seg + 1, s.length - 1)];
    final len = cum[math.min(seg + 1, s.length - 1)] - cum[seg];
    final t = len <= 0 ? 0.0 : (_at - cum[seg]) / len;
    final p = LatLng(a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t);
    var h = const Distance().bearing(a, b);
    if (h < 0) h += 360;
    onFix(p, _at >= total ? 0 : _speed, h);
    if (_at >= total) stop();
  }

  int _segAt(double d) {
    final cum = route.cumulative;
    var lo = 0, hi = cum.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= d) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
