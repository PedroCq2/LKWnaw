import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/route.dart';
import 'offline_search.dart';
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
    if (h == 'motorway_junction') return 'junction';
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
  bool local = true, // false = jen online (Overpass) – doplní odpočívky bez jména
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
  // Nejdřív rejstřík v telefonu (okamžitě, bez internetu); Overpass jen když rejstřík nic nedá.
  // Starší balík bez služeb: aspoň pumpy z rejstříku hledání.
  final localPois = !local || OfflineSearch.instance.hasOsm
      ? const <(String, String, LatLng)>[]
      : OfflineSearch.instance.poisOfKinds(const {
          'Čerpací stanice',
          'Odpočívka',
          'Odpočívka s ČS',
          'Parkoviště',
        });
  if (localPois.isNotEmpty && runs.isNotEmpty) {
    var minLa = 90.0, maxLa = -90.0, minLo = 180.0, maxLo = -180.0;
    for (final r in runs) {
      for (final s in r) {
        minLa = math.min(minLa, s.p.latitude);
        maxLa = math.max(maxLa, s.p.latitude);
        minLo = math.min(minLo, s.p.longitude);
        maxLo = math.max(maxLo, s.p.longitude);
      }
    }
    for (final (name, kind, p) in localPois) {
      if (p.latitude < minLa - 0.01 || p.latitude > maxLa + 0.01) continue;
      if (p.longitude < minLo - 0.015 || p.longitude > maxLo + 0.015) continue;
      double at = 0, off = double.infinity;
      var right = true;
      for (final r in runs) {
        if (r.length < 2) continue;
        final q = _project(r, p);
        if (q.$2 < off) (at, off, right) = q;
      }
      if (off > 700 || (!right && off > 40)) continue;
      final tags = <String, dynamic>{
        'name': name,
        ...switch (kind) {
          'Čerpací stanice' => {'amenity': 'fuel'},
          'Odpočívka' => {'highway': 'rest_area'},
          'Odpočívka s ČS' => {'highway': 'services'},
          _ => {'amenity': 'parking'},
        },
      };
      hits.add(_Hit(tags, p, at, off));
    }
    if (hits.isNotEmpty) return _buildServices(hits, roadAt: (at) => _roadAt(runs, at));
  }
  final seen = <String>{};
  for (final c in chunks) {
    final poly = c
        .map((s) => '${s.p.latitude.toStringAsFixed(5)},${s.p.longitude.toStringAsFixed(5)}')
        .join(',');
    final a = '(around:700,$poly)';
    if (local && OfflineSearch.instance.hasOsm) {
      var la0 = 90.0, la1 = -90.0, lo0 = 180.0, lo1 = -180.0;
      for (final x in c) {
        la0 = math.min(la0, x.p.latitude);
        la1 = math.max(la1, x.p.latitude);
        lo0 = math.min(lo0, x.p.longitude);
        lo1 = math.max(lo1, x.p.longitude);
      }
      final els = OfflineSearch.instance.osmElements(la0 - 0.007, la1 + 0.007, lo0 - 0.01, lo1 + 0.01);
      _collect(els, c, runs, seen, hits);
      continue;
    }
    final els = await query(
      '[out:json][timeout:25];('
      'nwr["highway"~"^(services|rest_area)\$"]$a;'
      'nwr["amenity"~"^(fuel|parking|restaurant|fast_food|cafe|toilets|shower)\$"]$a;'
      'nwr["tourism"~"^(hotel|motel)\$"]$a;'
      'node["highway"="motorway_junction"]["ref"]$a;'
      ');out center tags 400;',
    );
    _collect(els ?? const [], c, runs, seen, hits);
  }
  return _buildServices(hits, roadAt: (at) => _roadAt(runs, at));
}

const _svcAmenity = {'fuel', 'parking', 'restaurant', 'fast_food', 'cafe', 'toilets', 'shower'};

/// Prvky (z Overpass nebo z balíku dat) → body služeb promítnuté na dálniční část trasy.
void _collect(
  List<dynamic> els,
  List<_Sample> c,
  List<List<_Sample>> runs,
  Set<String> seen,
  List<_Hit> hits,
) {
  for (final e in els) {
    final t = Map<String, dynamic>.from((e['tags'] as Map?) ?? const {});
    // Soukromé (odtahové, firemní) parkoviště a pumpy nejsou pro řidiče.
    if (const {'private', 'no'}.contains(t['access'])) continue;
    if (t['amenity'] == 'parking' &&
        RegExp(r'\bbus\b|autobus', caseSensitive: false).hasMatch('${t['name'] ?? ''}')) {
      continue;
    }
    final svc =
        (t['highway'] == 'motorway_junction' && t['ref'] != null) ||
        t['highway'] == 'services' ||
        t['highway'] == 'rest_area' ||
        _svcAmenity.contains(t['amenity']) ||
        t['tourism'] == 'hotel' ||
        t['tourism'] == 'motel';
    if (!svc) continue;
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
    if (off > 800) continue;
    // Odpočívky na protisměru nejsou dostupné – kromě společných (těsně u trasy).
    if (!right && off > 40) continue;
    hits.add(_Hit(t, p, at, off));
  }
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
    // Parkoviště těsně u dálnice je skoro vždy odpočívka.
    'parking' => h.off < 200,
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
    if (h.kind == 'junction') continue;
    for (final g in groups) {
      if ((h.at - g.first.at).abs() < 700 && g.any((x) => dist(x.p, h.p) < 300)) {
        g.add(h);
        break;
      }
    }
  }
  final out = <HighwayService>[];
  for (final g in groups) {
    // Jméno odpočívky; jinak pumpa, parkoviště pro kamiony (jméno běžného parkoviště bývá cizí firma).
    _Hit? named(bool Function(_Hit h) f) =>
        g.where((h) => f(h) && '${h.tags['name'] ?? h.tags['brand'] ?? ''}'.trim().isNotEmpty).firstOrNull;
    final main =
        named((h) => h.kind == 'services' || h.kind == 'rest_area') ??
        g.where((h) => h.kind == 'services' || h.kind == 'rest_area').firstOrNull ??
        named((h) => h.kind == 'fuel') ??
        g.where((h) => h.kind == 'fuel').firstOrNull ??
        named((h) => h.kind == 'hgv_parking') ??
        g.first;
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
          if (t['fuel:HGV_diesel'] == 'yes' && !notes.contains('stojan pro kamiony')) {
            notes.add('stojan pro kamiony');
          }
          if (t['fuel:HGV_diesel'] == 'no' && !notes.contains('bez stojanu pro kamiony')) {
            notes.add('bez stojanu pro kamiony');
          }
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
        : kinds.contains('hgv_parking')
        ? 'Parkoviště pro kamiony'
        : 'Parkoviště';
    // Pumpa / parkoviště mimo odpočívku u exitu: obvykle je nutné sjet z dálnice.
    final atG = g.map((h) => h.at).reduce(math.min);
    if (!kinds.contains('services') && !kinds.contains('rest_area')) {
      final j = hits
          .where((h) => h.kind == 'junction' && (h.at - atG).abs() < 1000)
          .fold<_Hit?>(null, (b, h) => b == null || (h.at - atG).abs() < (b.at - atG).abs() ? h : b);
      // Obyčejné parkoviště u exitu je ve městě / u obchodu, ne pro kamion.
      if (j != null && !fuel && !kinds.contains('hgv_parking')) continue;
      if (j != null) notes.insert(0, 'sjezd ${j.tags['ref']} – mimo dálnici');
    }
    final mainName =
        ((main.kind == 'fuel' ? main.tags['name'] ?? main.tags['brand'] : main.tags['name']) as String?)
            ?.trim();
    out.add(
      HighwayService(
        name: mainName != null && mainName.isNotEmpty
            ? mainName
            : (brands.isNotEmpty && (fuel || kinds.contains('hgv_parking')) ? brands.first : type),
        type: type,
        point: main.p,
        atM: atG,
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
