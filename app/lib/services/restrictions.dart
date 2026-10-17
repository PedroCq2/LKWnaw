import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'http_headers.dart';

import '../models/route.dart';
import '../models/truck_profile.dart';

const _overpassMirrors = [
  'https://overpass-api.de/api/interpreter',
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
];

/// Stáhne z OSM kamionová omezení (maxheight/maxweight/…) a radary podél trasy.
///
/// Při [delivery] (zásobování) se hmotnostní limit počítá jako porušení jen na mostě.
Future<List<RouteWarning>> loadRouteWarnings(
  TruckRoute route,
  TruckProfile truck, {
  double maxMeters = 300000,
  bool delivery = false,
}) async {
  final index = RouteIndex(route);
  final routeWays = {for (final e in route.edges) ?e.wayId};
  final pts = _simplify(route.shape, route.cumulative, maxMeters, 10);
  final out = <RouteWarning>[];
  final seenWays = <int>{};
  final seenNodes = <int>{};
  final junctions = <(double, double, String?)>[];
  final links = <(LatLng, String)>[];
  const chunk = 200;
  for (var i = 0; i < pts.length - 1; i += chunk - 1) {
    final part = pts.sublist(i, math.min(pts.length, i + chunk));
    final poly = part
        .map((p) => '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}')
        .join(',');
    final q =
        '[out:json][timeout:60];('
        'way(around:12,$poly)[~"^(max(height|weight|width|axleload|length)|overtaking:hgv(:conditional)?)\$"~"."];'
        'node(around:25,$poly)["highway"="motorway_junction"]["ref"];'
        'way(around:30,$poly)["highway"="motorway_link"]["destination:ref"~"(^|;) *D *[0-9]"];'
        'node(around:20,$poly)["highway"="speed_camera"];'
        'node(around:12,$poly)["maxheight"];'
        ');out tags geom;';
    final els = await overpassQuery(q);
    if (els == null) continue;
    for (final e in els) {
      final id = (e['id'] as num).toInt();
      final tags = Map<String, dynamic>.from((e['tags'] as Map?) ?? const {});
      if (e['type'] == 'way') {
        if (!seenWays.add(id)) continue;
        final geom = (e['geometry'] as List?) ?? const [];
        if (tags['highway'] == 'motorway_link') {
          // Sjezd na jinou dálnici: zapamatuj jeho začátek, pokud leží na trase.
          if (geom.isEmpty) continue;
          final g0 = geom.first;
          final start = LatLng((g0['lat'] as num).toDouble(), (g0['lon'] as num).toDouble());
          if (index.locate(start, 25) != null) {
            links.add((start, '${tags['destination:ref']}'));
          }
          continue;
        }
        // Jen cesty, po kterých trasa opravdu vede: souběžná silnice 10 m vedle dálnice
        // (např. III/13036 vedle D1 u Koberovic) se nesmí počítat.
        // Neznámá cesta (chybí atributy úseku) → body musí ležet přímo na trase.
        final onRoute = routeWays.contains(id);
        // Cesta musí s trasou sdílet aspoň 2 body (ne jen křížení).
        final hits = <double>[];
        LatLng? first;
        for (final g in geom) {
          final p = LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble());
          final at = index.locate(p, onRoute ? 15 : 3);
          if (at != null) {
            hits.add(at);
            first ??= p;
          }
        }
        if (hits.length < 2) continue;
        final at = hits.reduce(math.min);
        out.addAll(_fromTags(tags, at, first!, truck, delivery));
      } else {
        if (!seenNodes.add(id)) continue;
        final p = LatLng((e['lat'] as num).toDouble(), (e['lon'] as num).toDouble());
        final at = index.locate(p, 25);
        if (at == null) continue;
        if (tags['highway'] == 'motorway_junction') {
          final km = double.tryParse(RegExp(r'^\d+').stringMatch('${tags['ref']}') ?? '');
          if (km != null) junctions.add((at, km, route.roadNameAt(index.segmentAt(p) ?? -1)));
        } else if (tags['highway'] == 'speed_camera') {
          out.add(
            RouteWarning(type: WarningType.speedCamera, value: null, atMeters: at, point: p, violates: false),
          );
        } else if (index.locate(p, 5) != null) {
          // Značka výšky jako bod musí ležet přímo na trase, ne na souběžné cestě.
          out.addAll(_fromTags(tags, at, p, truck, delivery));
        }
      }
    }
  }
  out.sort((a, b) => a.atMeters.compareTo(b.atMeters));
  junctions.sort((a, b) => a.$1.compareTo(b.$1));
  route.kmPoints = junctions;
  if (links.isNotEmpty) route.interchangeLinks = links;
  return mergeWarnings(out);
}

/// Sloučí navazující stejná omezení (jedna zóna = mnoho úseků cesty v OSM).
List<RouteWarning> mergeWarnings(List<RouteWarning> sorted, {double gapM = 400}) {
  final lastAt = <String, double>{};
  final out = <RouteWarning>[];
  for (final w in sorted) {
    final key = '${w.type}:${w.value}:${w.note}';
    final prev = lastAt[key];
    lastAt[key] = w.atMeters;
    if (w.type != WarningType.speedCamera && prev != null && w.atMeters - prev < gapM) continue;
    out.add(w);
  }
  return out;
}

/// Dotaz na Overpass API se záložními servery; null = žádný neodpověděl.
Future<List<dynamic>?> overpassQuery(String q) async {
  for (final url in _overpassMirrors) {
    try {
      final res = await http
          .post(Uri.parse(url), headers: uaHeaders(), body: {'data': q})
          .timeout(const Duration(seconds: 25));
      if (res.statusCode == 200) {
        return (jsonDecode(utf8.decode(res.bodyBytes))['elements'] as List?) ?? const [];
      }
    } catch (_) {}
  }
  return null;
}

List<RouteWarning> _fromTags(Map<String, dynamic> tags, double at, LatLng p, TruckProfile t, bool delivery) {
  final out = <RouteWarning>[];
  final bridge = tags['bridge'] != null && tags['bridge'] != 'no';
  void add(String key, WarningType type, double Function(String) parse, double truckValue) {
    final raw = tags[key] ?? tags['$key:physical'];
    if (raw is! String) return;
    final v = parse(raw);
    if (v.isNaN || v <= 0) return;
    var violates = truckValue > v + 1e-6;
    // Zásobování: zóny se zákazem nad X t jsou pro dopravní obsluhu průjezdné, mosty ne.
    if (delivery && type == WarningType.weight && !bridge) violates = false;
    final margin = type == WarningType.weight || type == WarningType.axleLoad ? 1.0 : 0.3;
    final tight = !violates && v - truckValue < margin;
    out.add(
      RouteWarning(
        type: type,
        value: v,
        atMeters: at,
        point: p,
        violates: violates,
        tight: tight,
        onBridge: bridge,
      ),
    );
  }

  add('maxheight', WarningType.height, parseMeters, t.height);
  add('maxwidth', WarningType.width, parseMeters, t.width);
  add('maxlength', WarningType.length, parseMeters, t.length);
  add('maxweight', WarningType.weight, parseTonnes, t.weight);
  add('maxaxleload', WarningType.axleLoad, parseTonnes, t.axleLoad);
  // Zákaz předjíždění nákladních vozidel (i časově omezený, např. „no @ (06:00-22:00)“).
  final ov = tags['overtaking:hgv'], ovc = tags['overtaking:hgv:conditional'];
  String? note;
  var ban = ov == 'no';
  if (ovc is String && ovc.trim().startsWith('no')) {
    ban = true;
    final m = RegExp(r'(\d{1,2}):\d{2}\s*-\s*(\d{1,2}):\d{2}').firstMatch(ovc);
    if (m != null) note = '${int.parse(m.group(1)!)}–${int.parse(m.group(2)!)} h';
  }
  if (ban) {
    out.add(
      RouteWarning(
        type: WarningType.noOvertakingHgv,
        value: null,
        note: note,
        atMeters: at,
        point: p,
        violates: false,
      ),
    );
  }
  return out;
}

/// "4.1", "4.1 m", "4,1m", "13'6\"" → metry; jinak NaN.
double parseMeters(String s) {
  s = s.trim().replaceAll(',', '.');
  final ft = RegExp(r'''^(\d+)\s*'\s*(?:(\d+)\s*")?$''').firstMatch(s);
  if (ft != null) {
    return int.parse(ft.group(1)!) * 0.3048 + int.parse(ft.group(2) ?? '0') * 0.0254;
  }
  final m = RegExp(r'^(\d+(?:\.\d+)?)\s*(m)?$').firstMatch(s);
  return m == null ? double.nan : double.parse(m.group(1)!);
}

/// "7.5", "7.5 t", "3500 kg" → tuny; jinak NaN.
double parseTonnes(String s) {
  s = s.trim().replaceAll(',', '.');
  final m = RegExp(r'^(\d+(?:\.\d+)?)\s*(t|kg|st|lbs)?$').firstMatch(s);
  if (m == null) return double.nan;
  final v = double.parse(m.group(1)!);
  switch (m.group(2)) {
    case 'kg':
      return v / 1000;
    case 'st':
      return v * 0.907;
    case 'lbs':
      return v * 0.000453592;
    default:
      return v;
  }
}

/// Douglas–Peucker zjednodušení prvních [maxMeters] trasy s tolerancí [tolM].
List<LatLng> _simplify(List<LatLng> pts, List<double> cum, double maxMeters, double tolM) {
  var end = pts.length - 1;
  while (end > 1 && cum[end] > maxMeters) {
    end--;
  }
  if (end < 1) return pts;
  final keep = List<bool>.filled(end + 1, false)
    ..[0] = true
    ..[end] = true;
  final stack = <(int, int)>[(0, end)];
  final cosLat = math.cos(pts.first.latitude * math.pi / 180);
  const mPerDeg = 111320.0;
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    if (b - a < 2) continue;
    final ax = pts[a].longitude * cosLat, ay = pts[a].latitude;
    final bx = pts[b].longitude * cosLat, by = pts[b].latitude;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var maxD = -1.0;
    var idx = a;
    for (var i = a + 1; i < b; i++) {
      final px = pts[i].longitude * cosLat - ax, py = pts[i].latitude - ay;
      final t = len2 == 0 ? 0.0 : ((px * dx + py * dy) / len2).clamp(0.0, 1.0);
      final ex = px - t * dx, ey = py - t * dy;
      final d = math.sqrt(ex * ex + ey * ey) * mPerDeg;
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
    for (var i = 0; i <= end; i++)
      if (keep[i]) pts[i],
  ];
}

/// Mřížkový index segmentů trasy pro rychlé „jak daleko po trase je tento bod“.
class RouteIndex {
  final TruckRoute route;
  final Map<int, List<int>> _grid = {};
  static const _cell = 0.002; // ~200 m

  RouteIndex(this.route) {
    final s = route.shape;
    for (var i = 0; i + 1 < s.length; i++) {
      final steps = math.max(1, (const Distance()(s[i], s[i + 1]) / 50).ceil());
      final cells = <int>{};
      for (var k = 0; k <= steps; k++) {
        final t = k / steps;
        cells.add(
          _key(
            s[i].latitude + (s[i + 1].latitude - s[i].latitude) * t,
            s[i].longitude + (s[i + 1].longitude - s[i].longitude) * t,
          ),
        );
      }
      for (final c in cells) {
        (_grid[c] ??= []).add(i);
      }
    }
  }

  static int _key(double lat, double lon) =>
      ((lat / _cell).floor() + 100000) * 1000000 + ((lon / _cell).floor() + 100000);

  /// Index segmentu trasy nejbližšího bodu [p] (do 30 m).
  int? segmentAt(LatLng p) {
    final at = locate(p, 30);
    if (at == null) return null;
    final c = route.cumulative;
    var i = c.indexWhere((x) => x > at);
    if (i < 0) i = c.length - 1;
    return math.max(0, i - 1);
  }

  /// Vzdálenost bodu po trase (m) nebo null, pokud je bod dál než [tol] m.
  double? locate(LatLng p, double tol) {
    final la = (p.latitude / _cell).floor(), lo = (p.longitude / _cell).floor();
    final segs = <int>{};
    for (var a = -1; a <= 1; a++) {
      for (var b = -1; b <= 1; b++) {
        final k = (la + a + 100000) * 1000000 + (lo + b + 100000);
        segs.addAll(_grid[k] ?? const []);
      }
    }
    final s = route.shape;
    final cosLat = math.cos(p.latitude * math.pi / 180);
    double? best;
    var bestD = tol;
    for (final i in segs) {
      final ax = (s[i].longitude - p.longitude) * cosLat, ay = s[i].latitude - p.latitude;
      final bx = (s[i + 1].longitude - p.longitude) * cosLat, by = s[i + 1].latitude - p.latitude;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
      final ex = ax + t * dx, ey = ay + t * dy;
      final d = math.sqrt(ex * ex + ey * ey) * 111320;
      if (d <= bestD) {
        bestD = d;
        best = route.cumulative[i] + (route.cumulative[i + 1] - route.cumulative[i]) * t;
      }
    }
    return best;
  }
}
