import 'dart:math' as math;

/// Rozpozná zatřesení telefonem: tři silné záchvěvy (> 2 g bez tíže) během 1,5 s.
/// Otřesy kabiny (výmol, práh) bývají jeden ráz – ty to nespustí.
class ShakeCounter {
  final double threshold; // m/s²
  final int peaks;
  final Duration window, gap, cooldown;
  ShakeCounter({
    this.threshold = 20,
    this.peaks = 3,
    this.window = const Duration(milliseconds: 1500),
    this.gap = const Duration(milliseconds: 150),
    this.cooldown = const Duration(seconds: 3),
  });

  final _hits = <DateTime>[];
  DateTime? _last;

  /// Další měření zrychlení (bez tíže). true = právě zatřesení.
  bool add(double x, double y, double z, DateTime t) {
    if (_last != null && t.difference(_last!) < cooldown) return false;
    if (math.sqrt(x * x + y * y + z * z) < threshold) return false;
    // Jeden záchvěv = víc měření těsně po sobě; počítat ho jednou.
    if (_hits.isNotEmpty && t.difference(_hits.last) < gap) return false;
    _hits
      ..add(t)
      ..removeWhere((h) => t.difference(h) > window);
    if (_hits.length < peaks) return false;
    _hits.clear();
    _last = t;
    return true;
  }
}
