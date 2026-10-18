import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/route.dart';
import 'http_headers.dart';

/// Směr manévru pro výběr pruhů.
enum _Dir { straight, left, right }

_Dir _dirOf(Maneuver m) {
  switch (m.type) {
    case 9:
    case 10:
    case 11:
    case 18:
    case 20:
    case 23:
      return _Dir.right;
    case 14:
    case 15:
    case 16:
    case 19:
    case 21:
    case 24:
      return _Dir.left;
    default:
      return _Dir.straight;
  }
}

const _highway = {'motorway', 'trunk'};
const _laneRoads = {'motorway', 'trunk', 'primary', 'secondary', 'tertiary'};

/// Doplní trasu o pokyny na dálničních rozdvojeních („Pokračujte rovně na D1 směr Ostrava“),
/// o jízdní pruhy a směry z OSM. Vyžaduje [TruckRoute.edges] (Valhalla trace_attributes).
Future<void> enrichManeuvers(TruckRoute route) async {
  final edges = route.edges;
  if (edges.isEmpty) return;

  // 1) Rozdvojení, kde trasa zůstává na dálnici a odbočuje jiná dálnice – Valhalla mlčí.
  final existing = route.maneuvers.map((m) => m.beginShapeIndex).toList();
  // Bez dat z Overpassu ověř sjezdy přes OSM API (vede sjezd na jinou dálnici?).
  if (route.interchangeLinks.isEmpty && !route.osmRampsChecked) {
    route.osmRampsChecked = true;
    route.interchangeLinks = await _interchangeRampsFromOsm(route);
  }
  final forks = <Maneuver>[];
  for (var k = 0; k + 1 < edges.length; k++) {
    final e = edges[k], next = edges[k + 1];
    if (!_highway.contains(e.roadClass) || e.use == 'ramp') continue;
    if (!_highway.contains(next.roadClass) || next.use == 'ramp') continue;
    // Jen skutečné dálniční křižovatky: dálnice se rozdělí (odbočka = hlavní pás),
    // nebo sjezd podle OSM vede na jinou dálnici. Obyčejné exity se nehlásí.
    final forkPoint = route.shape[e.end];
    bool isInterchangeRamp() => route.interchangeLinks.any((l) => const Distance()(l.$1, forkPoint) < 80);
    final branch = e.intersecting.where(
      (ie) =>
          ie['road_class'] == 'motorway' &&
          (ie['driveability'] == 'forward' || ie['driveability'] == 'both') &&
          (ie['use'] != 'ramp' || isInterchangeRamp()),
    );
    if (branch.isEmpty) continue;
    if (existing.any((i) => (i - e.end).abs() <= 3)) continue;
    // Rozdvojení blíž než 3 km od předchozího (i už vloženého) hlásíme jen jednou.
    final atM = route.cumulative[e.end];
    bool near(Maneuver m) => m.synthetic && (route.cumulative[m.beginShapeIndex] - atM).abs() < 3000;
    if (forks.any(near) || route.maneuvers.any(near)) continue;
    final ref = next.names.isNotEmpty ? next.names.first : (e.names.isNotEmpty ? e.names.first : null);
    final text = ref == null ? 'Pokračujte rovně.' : 'Pokračujte rovně po $ref.';
    forks.add(
      Maneuver(
        type: 22, // „stay straight“
        instruction: text,
        alertInstruction: text,
        preInstruction: text,
        streetNames: ref == null ? const [] : [ref],
        beginShapeIndex: e.end,
        endShapeIndex: e.end,
        lengthKm: 0,
        synthetic: true,
      ),
    );
  }
  route.maneuvers
    ..addAll(forks)
    ..sort((a, b) => a.beginShapeIndex.compareTo(b.beginShapeIndex));

  // 2) Pruhy a směry z OSM pro manévry na dálnicích a silnicích pro motorová vozidla.
  /// Až 3 úseky před manévrem (do 1,5 km) – pruhy bývají v OSM zapsané o kus dřív.
  List<EdgeAttr> approach(int idx) {
    final k = edges.indexWhere((e) => e.end == idx);
    if (k < 0) return const [];
    final out = <EdgeAttr>[];
    for (var j = k; j >= 0 && j > k - 3; j--) {
      if (route.cumulative[idx] - route.cumulative[edges[j].begin] > 1500) break;
      out.add(edges[j]);
    }
    return out;
  }

  EdgeAttr? after(int idx) {
    for (final e in edges) {
      if (e.begin == idx) return e;
    }
    return null;
  }

  final targets = <Maneuver, (List<EdgeAttr>, EdgeAttr?)>{};
  for (final m in route.maneuvers) {
    if (m.enriched) continue; // druhé volání (po načtení OSM dat) řeší jen nové pokyny
    m.enriched = true;
    final a = approach(m.beginShapeIndex);
    // Pruhy i ve městech (křižovatky na hlavních a vedlejších silnicích), ne v obytných ulicích.
    if (a.isEmpty || !_laneRoads.contains(a.first.roadClass)) continue;
    targets[m] = (a, after(m.beginShapeIndex));
  }
  final ids = <int>{
    for (final (a, b) in targets.values) ...[for (final e in a) ?e.wayId, ?b?.wayId],
  };
  final tags = await _osmWayTags(ids.toList());

  for (final entry in targets.entries) {
    final m = entry.key;
    final (a, b) = entry.value;
    // Nejbližší úsek před manévrem, který má pruhy zapsané.
    final at = a
        .map((e) => tags[e.wayId])
        .whereType<Map<String, String>>()
        .firstWhere(
          (t) => t.containsKey('turn:lanes') || t.containsKey('turn:lanes:forward'),
          orElse: () => tags[a.first.wayId] ?? const <String, String>{},
        );
    final bt = tags[b?.wayId] ?? const <String, String>{};
    final ref = b != null && b.names.isNotEmpty ? b.names.first : null;
    m.lanes = _lanes(at, _dirOf(m), ref);
    // Směr: značení v OSM (destination) – u vloženého pokynu i pro hlas.
    if (m.exitToward.isEmpty) {
      final dest = (bt['destination'] ?? _activeDestinations(at, m.lanes))
          ?.split(';')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .take(2)
          .toList();
      if (dest != null && dest.isNotEmpty) m.exitToward = _unique(dest);
    }
  }

  // 3) Vložené pokyny bez značení: směr = nejbližší větší město dál po trase.
  for (final m in forks) {
    m.exitToward = _unique(m.exitToward);
    if (m.exitToward.isEmpty) {
      final city = await _cityAhead(route, m.beginShapeIndex);
      if (city != null) m.exitToward = [city];
    }
    if (m.exitToward.isNotEmpty) {
      final ref = m.streetNames.isNotEmpty ? ' po ${m.streetNames.first}' : '';
      final t = 'Pokračujte rovně$ref směr ${m.exitToward.join(', ')}.';
      m
        ..alertInstruction = t
        ..preInstruction = t;
    }
  }
}

LaneInfo? _lanes(Map<String, String> t, _Dir dir, String? ref) {
  final raw = t['turn:lanes'] ?? t['turn:lanes:forward'];
  if (raw == null) return null;
  final turns = raw.split('|').map((l) => l.split(';').map((x) => x.trim()).toSet()).toList();
  if (turns.length < 2) return null;
  // Podle čísla silnice v destination:ref:lanes, jinak podle šipek.
  final refs = t['destination:ref:lanes']?.split('|');
  List<bool> active;
  if (ref != null && refs != null && refs.length == turns.length) {
    active = [for (final r in refs) r.split(';').map((x) => x.trim()).contains(ref)];
  } else {
    bool isThrough(Set<String> s) =>
        s.any((x) => x.isEmpty || x == 'none' || x == 'through' || x == 'reverse');
    bool isSide(Set<String> s, String side) => s.any((x) => x.endsWith(side));
    active = [
      for (final s in turns)
        switch (dir) {
          _Dir.straight => isThrough(s),
          _Dir.left => isSide(s, 'left'),
          _Dir.right => isSide(s, 'right'),
        },
    ];
  }
  // Rozdvojení / sjezd bez šipek na naši stranu: krajní průběžné pruhy na té straně.
  if (!active.contains(true) && dir != _Dir.straight) {
    final n = turns.length;
    final keep = n >= 4 ? 2 : 1;
    active = [for (var i = 0; i < n; i++) dir == _Dir.left ? i < keep : i >= n - keep];
  }
  if (!active.contains(true)) return null;
  return LaneInfo(turns, active, want: dir.name == 'straight' ? 'through' : dir.name);
}

String? _activeDestinations(Map<String, String> t, LaneInfo? lanes) {
  final d = t['destination:lanes']?.split('|');
  if (d == null || lanes == null || d.length != lanes.active.length) return null;
  for (var i = 0; i < d.length; i++) {
    if (lanes.active[i] && d[i].trim().isNotEmpty) return d[i];
  }
  return null;
}

/// Tagy cest z oficiálního OSM API (rychlé, dotaz podle ID).
Future<Map<int, Map<String, String>>> _osmWayTags(List<int> ids) async {
  final out = <int, Map<String, String>>{};
  for (var i = 0; i < ids.length; i += 100) {
    final chunk = ids.sublist(i, (i + 100).clamp(0, ids.length));
    try {
      final res = await http
          .get(
            Uri.parse('https://api.openstreetmap.org/api/0.6/ways.json?ways=${chunk.join(',')}'),
            headers: uaHeaders(),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) continue;
      for (final e in (jsonDecode(utf8.decode(res.bodyBytes))['elements'] as List)) {
        out[(e['id'] as num).toInt()] = ((e['tags'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {}
  }
  return out;
}

/// Směr pro „Pokračujte rovně … směr X“: velké město dál po trase (jako na
/// dálničních tabulích), jinak menší město, nakonec místo cíle.
Future<String?> _cityAhead(TruckRoute route, int fromIdx) async {
  final cum = route.cumulative;
  final candidates = <(double, String)>[
    if (cum[fromIdx] + 80000 <= cum.last) (cum[fromIdx] + 80000, 'place:city'),
    for (final ahead in [50000.0, 30000.0, 15000.0])
      if (cum[fromIdx] + ahead <= cum.last) (cum[fromIdx] + ahead, 'place:town'),
    (cum.last, 'place:town&osm_tag=place:village'),
  ];
  for (final (at, tag) in candidates) {
    final idx = cum.indexWhere((c) => c >= at);
    final LatLng p = route.shape[idx < 0 ? route.shape.length - 1 : idx];
    try {
      final res = await http
          .get(
            Uri.parse(
              'https://photon.komoot.io/reverse?lat=${p.latitude}&lon=${p.longitude}'
              '&radius=25&limit=1&osm_tag=$tag',
            ),
            headers: uaHeaders(),
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) continue;
      final f = jsonDecode(utf8.decode(res.bodyBytes))['features'] as List;
      if (f.isNotEmpty) return f.first['properties']['name'] as String?;
    } catch (_) {}
  }
  return null;
}

/// Bez opakování („Olomouc, Olomouc“) a nejvýš 2 směry.
List<String> _unique(List<String> xs) {
  final seen = <String>{};
  return [
    for (final x in xs)
      if (seen.add(x.toLowerCase())) x,
  ].take(2).toList();
}

/// Záloha bez Overpassu: u sjezdů z dálnice zjistí z oficiálního OSM API, zda vedou na jinou
/// dálnici (`destination:ref` = D…). Vrací začátky takových sjezdů (prvních ~300 km trasy).
Future<List<(LatLng, String)>> _interchangeRampsFromOsm(TruckRoute route) async {
  final edges = route.edges;
  final cands = <(int, LatLng)>[]; // (wayId přijezdu, bod rozdvojení)
  for (var k = 0; k + 1 < edges.length; k++) {
    final e = edges[k];
    if (e.roadClass != 'motorway' || e.use == 'ramp' || e.wayId == null) continue;
    if (route.cumulative[e.end] > 300000) break;
    final ramp = e.intersecting.any(
      (ie) =>
          ie['road_class'] == 'motorway' &&
          ie['use'] == 'ramp' &&
          (ie['driveability'] == 'forward' || ie['driveability'] == 'both'),
    );
    if (ramp) cands.add((e.wayId!, route.shape[e.end]));
  }
  if (cands.isEmpty) return [];
  // Uzly přijezdových cest + jejich souřadnice (dávkově).
  final wayNodes = <int, List<int>>{};
  final ids = cands.map((c) => c.$1).toSet().toList();
  for (var i = 0; i < ids.length; i += 100) {
    final chunk = ids.sublist(i, (i + 100).clamp(0, ids.length));
    final j = await _osmGet('ways.json?ways=${chunk.join(',')}');
    for (final w in (j?['elements'] as List? ?? const [])) {
      wayNodes[(w['id'] as num).toInt()] = [for (final n in (w['nodes'] as List)) (n as num).toInt()];
    }
  }
  final nodeIds = wayNodes.values.expand((l) => l).toSet().toList();
  final coords = <int, LatLng>{};
  for (var i = 0; i < nodeIds.length; i += 300) {
    final chunk = nodeIds.sublist(i, (i + 300).clamp(0, nodeIds.length));
    final j = await _osmGet('nodes.json?nodes=${chunk.join(',')}');
    for (final n in (j?['elements'] as List? ?? const [])) {
      coords[(n['id'] as num).toInt()] = LatLng((n['lat'] as num).toDouble(), (n['lon'] as num).toDouble());
    }
  }
  const dist = Distance();
  final out = <(LatLng, String)>[];
  final checked = <int>{};
  // Po 4 souběžně, ať nepřetěžujeme OSM API.
  final queue = [...cands];
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final (wayId, fork) = queue.removeLast();
      int? best;
      var bestD = 40.0;
      for (final n in wayNodes[wayId] ?? const <int>[]) {
        final c = coords[n];
        if (c == null) continue;
        final d = dist(c, fork);
        if (d < bestD) {
          bestD = d;
          best = n;
        }
      }
      if (best == null || !checked.add(best)) continue;
      final j = await _osmGet('node/$best/ways.json');
      for (final w in (j?['elements'] as List? ?? const [])) {
        final t = (w['tags'] as Map?) ?? const {};
        final ref = '${t['destination:ref'] ?? ''}';
        if (t['highway'] == 'motorway_link' && RegExp(r'(^|;)\s*D\s*\d').hasMatch(ref)) {
          out.add((coords[best]!, ref));
          break;
        }
      }
    }
  }

  await Future.wait(List.generate(4, (_) => worker()));
  return out;
}

Future<Map<String, dynamic>?> _osmGet(String path) async {
  try {
    final res = await http
        .get(Uri.parse('https://api.openstreetmap.org/api/0.6/$path'), headers: uaHeaders())
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return null;
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}
