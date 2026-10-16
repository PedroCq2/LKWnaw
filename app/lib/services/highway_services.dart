import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/route.dart';
import 'restrictions.dart';

/// Bod dálničního úseku trasy: poloha, km po trase, směr a číslo silnice.
class _Sample {
  final LatLng p;
  final double at;
  final String? road;
  _Sample(this.p, this.at, this.road);
}

class _Hit {
  final Map<String, dynamic> tags;
  final LatLng p;
  final double at, off;
  _Hit(this.tags, this.p, this.at, this.off);
  String get kind {
    final h = tags['highway'], a = tags['amenity'], t = tags['tourism'];
    if (h == 'services' || h == 'rest_area') return h as String;
    if (a == 'fuel') return 'fuel';
    if (a == 'parking') return _hgv(tags) ? 'hgv_parking' : 'parking';
    if (t == 'hotel' || t == 'motel') return 'hotel';
    return '$a';
  }
}

bool _hgv(Map<String, dynamic> t) =>
    const ['yes', 'designated'].contains(t['hgv']) || t['capacity:hgv'] != null;

bool _yes(Map<String, dynamic> t, String k) => const ['yes', 'designated', 'customers'].contains(t[k]);

final _roadRef = RegExp(r'^(D\d+|I/\d+)$');

/// Odpočívky, čerpací stanice a parkoviště pro kamiony u dálnic a rychlostních silnic na trase.
/// Jen na pravé straně (ve směru jízdy), seřazené po trase; jedno místo = jedna odpočívka
/// se vším, co na ní je (pumpa, jídlo, WC, sprchy, AdBlue…).
Future<List<HighwayService>> findHighwayServices(
  TruckRoute route, {
  Future<List<dynamic>?> Function(String q) query = overpassQuery,
}) async {
  final cum = route.cumulative;
  // Dálniční úseky trasy (podle tříd silnic z trace_attributes) → body po ~250 m.
  final runs = <List<_Sample>>[];
  List<_Sample>? run;
  var next = 0.0;
  for (final e in route.edges) {
    final motorway = e.roadClass == 'motorway' || e.roadClass == 'trunk';
    if (!motorway || e.use == 'ramp') {
      run = null;
      continue;
    }
    final road = e.names.firstWhere((n) => _roadRef.hasMatch(n), orElse: () => '');
    if (run == null) {
      run = [];
      runs.add(run);
      next = 0;
    }
    for (var i = e.begin; i <= e.end && i < route.shape.length; i++) {
      if (cum[i] < next && i != e.end) continue;
      run.add(_Sample(route.shape[i], cum[i], road.isEmpty ? null : road));
      next = cum[i] + 250;
    }
  }
  // Dotazy po kusech do ~100 km (Overpass nemá rád dlouhé polygony).
  final chunks = <List<_Sample>>[];
  for (final r in runs) {
    if (r.length < 2) continue;
    for (var k = 0; k < r.length - 1; k += 400) {
      chunks.add(r.sublist(k, math.min(r.length, k + 401)));
    }
  }
  final hits = <_Hit>[];
  final seen = <String>{};
  for (final c in chunks) {
    final poly = c
        .map((s) => '${s.p.latitude.toStringAsFixed(5)},${s.p.longitude.toStringAsFixed(5)}')
        .join(',');
    final a = '(around:700,$poly)';
    final els = await query(
      '[out:json][timeout:25];('
      'nwr["highway"~"^(services|rest_area)\$"]$a;'
      'nwr["amenity"~"^(fuel|parking|restaurant|fast_food|cafe|toilets|shower)\$"]$a;'
      'nwr["tourism"~"^(hotel|motel)\$"]$a;'
      ');out center tags 400;',
    );
    for (final e in els ?? const []) {
      if (!seen.add('${e['type']}${e['id']}')) continue;
      final lat = (e['lat'] ?? e['center']?['lat']) as num?;
      final lon = (e['lon'] ?? e['center']?['lon']) as num?;
      if (lat == null || lon == null) continue;
      final p = LatLng(lat.toDouble(), lon.toDouble());
      // Průmět na celou dálniční část trasy (objekt může vrátit i sousední dotaz).
      var (at, off, right) = _project(c, p);
      for (final r in runs) {
        if (r.length < 2 || identical(r, c)) continue;
        final q = _project(r, p);
        if (q.$2 < off) (at, off, right) = q;
      }
      // Odpočívky na protisměru nejsou dostupné – kromě společných (těsně u trasy).
      if (!right && off > 40) continue;
      hits.add(_Hit(Map<String, dynamic>.from((e['tags'] as Map?) ?? const {}), p, at, off));
    }
  }
  return _buildServices(hits, roadAt: (at) => _roadAt(runs, at));
}

String? _roadAt(List<List<_Sample>> runs, double at) {
  for (final r in runs) {
    if (r.isEmpty || at < r.first.at - 500 || at > r.last.at + 500) continue;
    var best = r.first;
    for (final s in r) {
      if ((s.at - at).abs() < (best.at - at).abs()) best = s;
    }
    return best.road;
  }
  return null;
}

/// Kolmý průmět bodu na lomenou čáru: (m po trase, vzdálenost, vpravo?).
(double, double, bool) _project(List<_Sample> line, LatLng p) {
  var best = double.infinity;
  var at = line.first.at;
  var right = true;
  for (var i = 0; i < line.length - 1; i++) {
    final a = line[i], b = line[i + 1];
    final k = math.cos(a.p.latitude * math.pi / 180) * 111320;
    const m = 110540.0;
    final bx = (b.p.longitude - a.p.longitude) * k, by = (b.p.latitude - a.p.latitude) * m;
    final px = (p.longitude - a.p.longitude) * k, py = (p.latitude - a.p.latitude) * m;
    final len2 = bx * bx + by * by;
    final t = len2 == 0 ? 0.0 : ((px * bx + py * by) / len2).clamp(0.0, 1.0);
    final dx = px - bx * t, dy = py - by * t;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d < best) {
      best = d;
      at = a.at + (b.at - a.at) * t;
      right = bx * py - by * px < 0; // vektorový součin < 0 → bod vpravo od směru jízdy
    }
  }
  return (at, best, right);
}

/// Seskupí nalezené objekty do odpočívek.
List<HighwayService> _buildServices(List<_Hit> hits, {String? Function(double at)? roadAt}) {
  const dist = Distance();
  bool anchor(_Hit h) => switch (h.kind) {
    'services' || 'rest_area' => h.off < 800,
    'fuel' => h.off < 160,
    'hgv_parking' => h.off < 300,
    _ => false,
  };
  final anchors = hits.where(anchor).toList()..sort((a, b) => a.at.compareTo(b.at));
  final groups = <List<_Hit>>[];
  for (final h in anchors) {
    final g = groups.isEmpty ? null : groups.last;
    if (g != null && (h.at - g.first.at).abs() < 700 && dist(h.p, g.first.p) < 900) {
      g.add(h);
    } else {
      groups.add([h]);
    }
  }
  for (final h in hits.where((h) => !anchor(h))) {
    for (final g in groups) {
      if ((h.at - g.first.at).abs() < 700 && g.any((x) => dist(x.p, h.p) < 450)) {
        g.add(h);
        break;
      }
    }
  }
  final out = <HighwayService>[];
  for (final g in groups) {
    final main = g.firstWhere((h) => h.kind == 'services' || h.kind == 'rest_area', orElse: () => g.first);
    final kinds = g.map((h) => h.kind).toSet();
    final am = <ServiceAmenity>{};
    final brands = <String>[];
    final notes = <String>[];
    int? spaces;
    for (final h in g) {
      final t = h.tags;
      switch (h.kind) {
        case 'services' || 'rest_area' || 'parking' || 'hgv_parking':
          am.add(ServiceAmenity.parking);
        case 'fuel':
          am.add(ServiceAmenity.fuel);
          if (t['opening_hours'] == '24/7' && !notes.contains('nonstop')) notes.add('nonstop');
        case 'restaurant' || 'fast_food' || 'cafe':
          am.add(ServiceAmenity.food);
        case 'toilets':
          am.add(ServiceAmenity.wc);
        case 'shower':
          am.add(ServiceAmenity.shower);
        case 'hotel':
          am.add(ServiceAmenity.hotel);
      }
      if (_yes(t, 'toilets')) am.add(ServiceAmenity.wc);
      if (_yes(t, 'shower') || _yes(t, 'showers')) am.add(ServiceAmenity.shower);
      if (_yes(t, 'restaurant') || _yes(t, 'food')) am.add(ServiceAmenity.food);
      if (t['fuel:adblue'] == 'yes') am.add(ServiceAmenity.adblue);
      final cap = int.tryParse('${t['capacity:hgv'] ?? ''}');
      if (cap != null) spaces = math.max(spaces ?? 0, cap);
      if (h.kind != 'services' && h.kind != 'rest_area' && h.kind != 'parking' && h.kind != 'toilets') {
        final b = (t['brand'] ?? t['name'] ?? t['operator']) as String?;
        if (b != null && b.length < 30 && !brands.contains(b)) brands.add(b);
      }
      if (h.kind == 'hgv_parking' && t['fee'] == 'no' && !notes.contains('parkování zdarma')) {
        notes.add('parkování zdarma');
      }
      if ((_yes(t, 'supervised') || t['surveillance'] != null) && !notes.contains('hlídané')) {
        notes.add('hlídané');
      }
    }
    final fuel = am.contains(ServiceAmenity.fuel);
    final type = kinds.contains('services')
        ? (fuel ? 'Odpočívka s čerpací stanicí' : 'Odpočívka se službami')
        : kinds.contains('rest_area')
        ? (fuel ? 'Odpočívka s čerpací stanicí' : 'Odpočívka')
        : fuel
        ? 'Čerpací stanice'
        : 'Parkoviště pro kamiony';
    final mainName = (main.tags['name'] as String?)?.trim();
    out.add(
      HighwayService(
        name: mainName != null && mainName.isNotEmpty ? mainName : (brands.isNotEmpty ? brands.first : type),
        type: type,
        point: main.p,
        atM: g.map((h) => h.at).reduce(math.min),
        offM: main.off,
        amenities: am,
        brands: brands.take(5).toList(),
        hgvSpaces: spaces,
        notes: notes,
        road: roadAt?.call(main.at),
      ),
    );
  }
  out.sort((a, b) => a.atM.compareTo(b.atM));
  return out;
}

/// Pro testy: objekt z OSM v dané poloze na trase.
Object serviceHit(Map<String, dynamic> tags, LatLng p, double at, double off) => _Hit(tags, p, at, off);

/// Pro testy: [buildServices] nad seznamem z [serviceHit].
List<HighwayService> buildServicesFrom(List<Object> hits) => _buildServices(hits.cast<_Hit>());
