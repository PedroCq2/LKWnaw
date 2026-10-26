import 'package:latlong2/latlong.dart';

import '../models/route.dart';
import 'restrictions.dart';

/// Stojí objížďka za vysvětlení? Kratší cesta ušetří aspoň 2 km a 2 min, a k tomu 5 km nebo 5 % trasy
/// (P3 Horní Počernice → D11: 14 km přes sjezd 10 Brandýs a zpět kvůli mostu 12 t).
bool significantDetour(TruckRoute main, TruckRoute shorter) {
  final km = main.lengthKm - shorter.lengthKm;
  final sec = main.timeSec - shorter.timeSec;
  return km >= 2 && sec >= 120 && (km >= 5 || km >= main.lengthKm * 0.05);
}

/// Úseky kratší trasy [ref], kde nejede po trase [main]: (index bodu, kde se odpojí; index bodu, kde se
/// zase připojí). Bod je „na trase“, jen když leží do [tol] m od [main] a obě jedou stejným směrem –
/// souběžný jízdní pás dálnice (15–30 m) ani most nad trasou (Ve Žlíbku nad D10) se tak nepočítají
/// jako „stejná cesta“. Výkyvy kratší než [minM] se vynechají.
List<(int, int)> divergentSections(TruckRoute ref, TruckRoute main, {double tol = 8, double minM = 40}) {
  final idx = RouteIndex(main);
  final s = ref.shape;
  final cum = ref.cumulative;
  if (s.length < 2) return const [];
  bool onMain(LatLng p, double? h) {
    final at = idx.locate(p, tol);
    if (at == null) return false;
    final hm = headingAlong(main, at);
    if (h == null || hm == null) return true;
    final diff = (h - hm).abs() % 360;
    return (diff > 180 ? 360 - diff : diff) < 40;
  }

  final on = [for (var i = 0; i < s.length; i++) onMain(s[i], headingAlong(ref, cum[i]))];
  bool segOff(int i) {
    if (!on[i] || !on[i + 1]) return true;
    if (cum[i + 1] - cum[i] <= 2 * tol) return false;
    final a = s[i], b = s[i + 1];
    final mid = LatLng((a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2);
    return !onMain(mid, headingAlong(ref, (cum[i] + cum[i + 1]) / 2));
  }

  final out = <(int, int)>[];
  int? start;
  for (var i = 0; i < s.length - 1; i++) {
    if (segOff(i)) {
      start ??= i;
    } else if (start != null) {
      if (cum[i] - cum[start] >= minM) out.add((start, i));
      start = null;
    }
  }
  if (start != null && cum.last - cum[start] >= minM) out.add((start, s.length - 1));
  return out;
}

/// Bod na trase [r] ve vzdálenosti [m] od začátku.
LatLng pointAlong(TruckRoute r, double m) {
  final s = r.shape, c = r.cumulative;
  if (m <= 0) return s.first;
  if (m >= c.last) return s.last;
  // První bod dál než m (půlením – trasa má tisíce bodů).
  var lo = 1, hi = c.length - 1;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (c[mid] > m) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  final i = lo;
  final span = c[i] - c[i - 1];
  final t = span > 0 ? (m - c[i - 1]) / span : 0.0;
  final a = s[i - 1], b = s[i];
  return LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
}

/// Směr jízdy (0–360°) po trase [r] ve vzdálenosti [m] – podle bodu o 20 m dál.
double? headingAlong(TruckRoute r, double m) {
  final total = r.cumulative.last;
  if (total < 5) return null;
  final a = m + 20 <= total ? m : total - 20;
  final p = pointAlong(r, a < 0 ? 0 : a), q = pointAlong(r, (a < 0 ? 0 : a) + 20);
  if (const Distance()(p, q) < 2) return null;
  final b = const Distance().bearing(p, q);
  return b < 0 ? b + 360 : b;
}
