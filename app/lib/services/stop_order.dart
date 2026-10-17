import 'package:latlong2/latlong.dart';

import '../models/truck_profile.dart';
import 'valhalla.dart';

/// Nejlepší pořadí zastávek z bodu 0 (start): nejbližší soused + vylepšení 2-opt a přesuny.
/// [cost] je čtvercová matice (s nebo m). [returnToStart] = okruh zpět na start.
List<int> bestOrder(List<List<double>> cost, {bool returnToStart = false}) {
  final n = cost.length;
  if (n <= 2) return [for (var i = 1; i < n; i++) i];
  double len(List<int> p) {
    var s = cost[0][p.first];
    for (var i = 0; i < p.length - 1; i++) {
      s += cost[p[i]][p[i + 1]];
    }
    if (returnToStart) s += cost[p.last][0];
    return s;
  }

  // Nejbližší soused.
  final left = {for (var i = 1; i < n; i++) i};
  final path = <int>[];
  var cur = 0;
  while (left.isNotEmpty) {
    final next = left.reduce((a, b) => cost[cur][a] <= cost[cur][b] ? a : b);
    path.add(next);
    left.remove(next);
    cur = next;
  }
  var best = len(path);
  var improved = true;
  for (var round = 0; improved && round < 200; round++) {
    improved = false;
    // 2-opt: otočit úsek.
    for (var i = 0; i < path.length - 1; i++) {
      for (var k = i + 1; k < path.length; k++) {
        final cand = [...path.sublist(0, i), ...path.sublist(i, k + 1).reversed, ...path.sublist(k + 1)];
        final l = len(cand);
        if (l < best - 1e-6) {
          path.setAll(0, cand);
          best = l;
          improved = true;
        }
      }
    }
    // Přesun jedné zastávky jinam.
    for (var i = 0; i < path.length; i++) {
      for (var j = 0; j < path.length; j++) {
        if (i == j) continue;
        final cand = [...path]..removeAt(i);
        cand.insert(j, path[i]);
        final l = len(cand);
        if (l < best - 1e-6) {
          path.setAll(0, cand);
          best = l;
          improved = true;
        }
      }
    }
  }
  return path;
}

/// Matice dob jízdy kamionem (Valhalla v telefonu nebo server), bez spojení vzdušnou čarou.
Future<List<List<double>>> travelMatrix(
  List<LatLng> pts,
  TruckProfile profile, {
  required String valhallaUrl,
  bool delivery = false,
}) async {
  try {
    return await ValhallaClient(valhallaUrl).matrix(pts, profile, delivery: delivery);
  } catch (_) {
    const d = Distance();
    // ~ 60 km/h a 1,3× zajížďka oproti vzdušné čarě.
    return [
      for (final a in pts) [for (final b in pts) d(a, b) * 1.3 / (60 / 3.6)],
    ];
  }
}
