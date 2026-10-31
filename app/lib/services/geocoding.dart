import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/route.dart';
import 'http_headers.dart';
import 'offline_search.dart';
import 'parking_network.dart';
import 'restrictions.dart';

class Place {
  final String name;
  final LatLng point;
  final String? kind;
  final String? address;
  final List<String> features; // vybavenost (WC, sprchy, …)
  final String? id; // `osm:n123` (OpenStreetMap) / `u:…` (místo přidané řidičem do sítě parkovišť)
  Place(this.name, this.point, {this.kind, this.address, this.features = const [], this.id});
}

/// Id místa z OSM: `osm:n123`, `osm:w456`, `osm:r789`.
String? osmPlaceId(Object? type, Object? id) {
  final t = '${type ?? ''}'.toLowerCase();
  if (t.isEmpty || id == null) return null;
  return 'osm:${t[0]}$id';
}

/// Chyba hledání srozumitelná pro řidiče (bez technických detailů).
class SearchException implements Exception {
  final String message;
  SearchException(this.message);
  @override
  String toString() => message;
}

/// Druh výsledku „souřadnice“ – naviguje se přesně na bod (bez hledání rampy).
const coordinatesKind = 'Souřadnice';

/// Souřadnice z textu nebo odkazu: „50.0054241, 14.4723392“, „50,00542 14,47234“, „50.00542N, 14.47234E“,
/// „50°0'19.5"N 14°28'20.4"E“, odkazy z Google / Apple Map a Mapy.cz. null = nejsou to souřadnice.
LatLng? parseCoordinates(String text) {
  var t = text.trim();
  try {
    t = Uri.decodeFull(t);
  } catch (_) {}
  double n(String s) => double.parse(s.replaceAll(',', '.'));
  LatLng? ok(double lat, double lon) =>
      lat.abs() <= 90 && lon.abs() <= 180 && (lat != 0 || lon != 0) ? LatLng(lat, lon) : null;
  // Mapy.cz: x = zeměpisná délka, y = šířka.
  final mapy = RegExp(r'[?&]x=(-?\d+\.\d+)&(?:.*&)?y=(-?\d+\.\d+)').firstMatch(t);
  if (mapy != null) return ok(n(mapy[2]!), n(mapy[1]!));
  final link = RegExp(
    r'(?:@|[?&](?:q|ll|query|center|daddr|destination|sll)=)(-?\d{1,2}\.\d+),\s*(-?\d{1,3}\.\d+)',
  ).firstMatch(t);
  if (link != null) return ok(n(link[1]!), n(link[2]!));
  final dms = RegExp(
    r'''(\d{1,2})\s*°\s*(\d{1,2})\s*['′]\s*(\d{1,2}(?:[.,]\d+)?)\s*(?:["″]|'')?\s*([NS])[\s,;]+'''
    r'''(\d{1,3})\s*°\s*(\d{1,2})\s*['′]\s*(\d{1,2}(?:[.,]\d+)?)\s*(?:["″]|'')?\s*([EW])''',
    caseSensitive: false,
  ).firstMatch(t);
  if (dms != null) {
    double deg(int i) => n(dms[i]!) + n(dms[i + 1]!) / 60 + n(dms[i + 2]!) / 3600;
    final lat = deg(1) * (dms[4]!.toUpperCase() == 'S' ? -1 : 1);
    final lon = deg(5) * (dms[8]!.toUpperCase() == 'W' ? -1 : 1);
    return ok(lat, lon);
  }
  // Celý text = dvojice čísel (desetinná tečka i čárka), případně s N/S/E/W.
  final dec = RegExp(
    r'^([NS])?\s*(-?\d{1,2}[.,]\d{3,})\s*°?\s*([NS])?\s*[,;\s]\s*([EW])?\s*(-?\d{1,3}[.,]\d{3,})\s*°?\s*([EW])?$',
    caseSensitive: false,
  ).firstMatch(t);
  if (dec == null) return null;
  final south = (dec[1] ?? dec[3] ?? '').toUpperCase() == 'S';
  final west = (dec[4] ?? dec[6] ?? '').toUpperCase() == 'W';
  return ok(n(dec[2]!) * (south ? -1 : 1), n(dec[5]!) * (west ? -1 : 1));
}

/// Text bez úlomků souřadnic a dlouhých čísel (vložené „50.0054241, 14, SAPA, 148 00 4723392-Praha-Libuš“
/// → „14 SAPA 148 00 Praha-Libuš“).
String cleanSearchQuery(String q) => q
    .replaceAll(RegExp(r'-?\d{1,3}\.\d{4,}'), ' ')
    .replaceAll(RegExp(r'\d{6,}'), ' ')
    .split(RegExp(r'[\s,;]+'))
    .map((w) => w.replaceAll(RegExp(r'^[-.]+|[-.]+$'), ''))
    .where((w) => w.isNotEmpty)
    .join(' ');

/// Když server na celý dotaz nic nenajde: bez čísel (číslo popisné, PSČ), pak bez posledních slov
/// („tamda foods libušská 319“ → „tamda foods libušská“ → „tamda foods“).
List<String> relaxedQueries(String q) {
  final words = q.split(RegExp(r'[\s,]+')).where((w) => w.isNotEmpty).toList();
  final noNum = words.where((w) => !RegExp(r'\d').hasMatch(w)).toList();
  final out = <String>[];
  void add(List<String> ws) {
    final s = ws.join(' ');
    if (ws.isNotEmpty && s != words.join(' ') && !out.contains(s)) out.add(s);
  }

  add(noNum);
  for (var n = noNum.length - 1; n >= 2; n--) {
    add(noNum.sublist(0, n));
  }
  return out.take(3).toList();
}

/// Výsledky dál než 2 500 km (Florida, Filipíny…) kamionu v Evropě k ničemu nejsou.
const _maxResultKm = 2500;

/// Vyhledávání míst: Photon (OSM, toleruje názvy firem jako „kaufland dc olomouc“),
/// záložně Nominatim. Bez internetu (nebo když servery nic nenajdou) hledá
/// ve staženém rejstříku ČR v telefonu ([OfflineSearch]). Souřadnice a odkazy z map vedou rovnou na bod.
Future<List<Place>> searchPlaces(String query, {LatLng? near}) async {
  final at = parseCoordinates(query);
  if (at != null) {
    return [
      Place(
        '${at.latitude.toStringAsFixed(6)}, ${at.longitude.toStringAsFixed(6)}',
        at,
        kind: coordinatesKind,
      ),
    ];
  }
  final q = cleanSearchQuery(query.trim());
  if (q.isEmpty) return [];
  final local = OfflineSearch.instance.ready ? OfflineSearch.instance.search(q) : <Place>[];
  // Řidičský slang → jak bývá místo pojmenované v OSM.
  final variants = <String>{q};
  final low = q.toLowerCase();
  if (RegExp(r'\b(dc|dc\.|sklad)\b').hasMatch(low)) {
    variants.add(low.replaceAll(RegExp(r'\bdc\.?\b'), 'sklad'));
    variants.add(low.replaceAll(RegExp(r'\b(dc\.?|sklad)\b'), 'distribuční centrum'));
    variants.add(low.replaceAll(RegExp(r'\b(dc\.?|sklad)\b'), 'centrální sklad'));
  }
  final results = <Place>[];
  final seen = <String>{};
  var online = false;
  const dist = Distance();
  final from = near ?? const LatLng(49.8, 15.5);
  Future<void> photon(Iterable<String> qs) async {
    final lists = await Future.wait(
      qs.map((v) => _photon(v, near).timeout(Duration(seconds: local.isEmpty ? 12 : 6))),
    );
    online = true;
    for (final list in lists) {
      for (final p in list) {
        if (dist(from, p.point) > _maxResultKm * 1000) continue;
        final key =
            '${p.name}|${p.point.latitude.toStringAsFixed(3)}|${p.point.longitude.toStringAsFixed(3)}';
        if (seen.add(key)) results.add(p);
      }
    }
  }

  try {
    await photon(variants);
    for (final v in relaxedQueries(q)) {
      if (results.isNotEmpty) break;
      await photon([v]);
    }
  } catch (_) {}
  if (results.isNotEmpty) return _withLocal(rankPlaces(results, low).take(12).toList(), local);
  if (local.isNotEmpty) return local;
  try {
    return await _nominatim(q, near);
  } catch (_) {
    if (online) return [];
    throw SearchException(
      OfflineSearch.instance.ready
          ? 'Bez internetu. V rejstříku v telefonu se nic nenašlo.'
          : 'Bez internetu nelze hledat. Stáhněte si data ČR v Nastavení → Trasy v telefonu.',
    );
  }
}

/// Doplní výsledky z telefonu, které servery nevrátily (např. přesné číslo popisné).
List<Place> _withLocal(List<Place> online, List<Place> local) {
  const d = Distance();
  final out = [...online];
  for (final p in local.take(4)) {
    if (out.length >= 14) break;
    if (out.any((o) => d(o.point, p.point) < 300)) continue;
    out.add(p);
  }
  return out;
}

const _skipValues = {'bus_stop', 'tram_stop', 'stop_position', 'platform', 'station', 'halt'};

Future<List<Place>> _photon(String q, LatLng? near) async {
  // Jen Evropa – ať místa výsledků nezaberou firmy z Floridy a Filipín.
  final params = {'q': q, 'limit': '10', 'bbox': '-25,34,45,72'};
  if (near != null) {
    params['lat'] = near.latitude.toStringAsFixed(4);
    params['lon'] = near.longitude.toStringAsFixed(4);
  }
  final res = await http
      .get(Uri.https('photon.komoot.io', '/api/', params), headers: uaHeaders())
      .timeout(const Duration(seconds: 12));
  if (res.statusCode != 200) return [];
  final out = <Place>[];
  for (final f in (jsonDecode(utf8.decode(res.bodyBytes))['features'] as List)) {
    final p = Map<String, dynamic>.from(f['properties'] as Map);
    if (_skipValues.contains(p['osm_value'])) continue;
    final c = (f['geometry']['coordinates'] as List).cast<num>();
    final street = [p['street'], p['housenumber']].whereType<String>().join(' ');
    var city = (p['city'] ?? p['town'] ?? p['village'] ?? p['county']) as String?;
    // Část města jako na poště: „Praha-Libuš“, „Brno-Černovice“.
    final district = p['district'] as String?;
    if (city != null && district != null && district != city && !district.contains(city)) {
      city = '$city-$district';
    }
    final address = [
      if (street.isNotEmpty) street,
      if (p['postcode'] != null) '${p['postcode']} ${city ?? ''}'.trim() else ?city,
    ].join(', ');
    final name = (p['name'] as String?) ?? (street.isNotEmpty ? street : (city ?? q));
    out.add(
      Place(
        name,
        LatLng(c[1].toDouble(), c[0].toDouble()),
        kind: _photonKind(p['osm_key'] as String?, p['osm_value'] as String?),
        address: address.isEmpty ? null : address,
      ),
    );
  }
  return out;
}

String? _photonKind(String? key, String? value) {
  const labels = {
    'supermarket': 'Supermarket',
    'wholesale': 'Velkoobchod',
    'warehouse': 'Sklad',
    'industrial': 'Průmyslový areál',
    'logistics': 'Logistika',
    'fuel': 'Čerpací stanice',
    'parking': 'Parkoviště',
    'city': 'Město',
    'town': 'Město',
    'village': 'Obec',
    'municipality': 'Obec',
    'house': 'Adresa',
    'yes': 'Budova',
    'company': 'Firma',
    'factory': 'Továrna',
    'commercial': 'Komerční areál',
    'retail': 'Obchodní zóna',
  };
  if (value != null && labels.containsKey(value)) return labels[value];
  if (key == 'highway') return 'Silnice';
  if (key == 'shop') return 'Obchod';
  return null;
}

const _genericWords = {
  'dc',
  'sklad',
  'distribuční',
  'distribucni',
  'centrum',
  'centrální',
  'centralni',
  'areál',
  'areal',
  'rampa',
  'logistika',
  'logistické',
  'a',
  's',
  'u',
  'v',
  'na',
};
const _depotKinds = {'Sklad', 'Průmyslový areál', 'Logistika', 'Velkoobchod', 'Továrna', 'Komerční areál'};

String _fold(String s) {
  const from = 'áčďéěíňóřšťúůýž';
  const to = 'acdeeinorstuuyz';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final k = from.indexOf(ch);
    b.write(k >= 0 ? to[k] : ch);
  }
  return b.toString();
}

/// Řazení: nejdřív výsledky obsahující hledanou značku/místo („kaufland“, „olomouc“),
/// při hledání „dc/sklad“ pak sklady a areály, jinak pořadí podle relevance Photonu.
List<Place> rankPlaces(List<Place> list, String q) {
  final words = _fold(q).split(RegExp(r'[\s,.-]+')).where((w) => w.length > 1).toSet();
  final key = words.where((w) => !_genericWords.contains(w)).toList();
  final wantsDepot = words.any(_genericWords.contains);
  // Slovo v názvu váží víc než v adrese, číslo (popisné, PSČ) jen celé a málo. Slovo, které má
  // většina výsledků (obec „Praha-Libuš“), rozhoduje méně než slovo jen u jednoho („SAPA“, „Tamda“).
  final folded = {for (final p in list) p: (_fold(p.name), _fold(p.address ?? ''))};
  bool isNum(String w) => RegExp(r'^\d+$').hasMatch(w);
  bool has(String hay, String w) =>
      isNum(w) ? RegExp(r'\d+').allMatches(hay).any((m) => m[0] == w) : hay.contains(w);
  final df = {
    for (final w in key) w: list.where((p) => has('${folded[p]!.$1} ${folded[p]!.$2}', w)).length,
  };
  double match(Place p) {
    final (name, addr) = folded[p]!;
    var s = 0.0;
    for (final w in key) {
      if (df[w] == 0) continue;
      final weight = isNum(w)
          ? (has('$name $addr', w) ? 0.5 : 0.0)
          : (has(name, w) ? 2.0 : (has(addr, w) ? 1.0 : 0.0));
      s += weight / df[w]!;
    }
    return s;
  }

  final idx = {for (var i = 0; i < list.length; i++) list[i]: i};
  final sorted = [...list]
    ..sort((a, b) {
      var c = match(b).compareTo(match(a));
      if (c != 0) return c;
      if (wantsDepot) {
        c = (_depotKinds.contains(b.kind) ? 1 : 0).compareTo(_depotKinds.contains(a.kind) ? 1 : 0);
        if (c != 0) return c;
      }
      return idx[a]!.compareTo(idx[b]!);
    });
  // Pokud něco obsahuje hledanou značku, nepleť výsledky cizími sklady.
  if (key.isNotEmpty && sorted.isNotEmpty && match(sorted.first) > 0) {
    return sorted.where((p) => match(p) > 0).toList();
  }
  return sorted;
}

Future<List<Place>> _nominatim(String query, LatLng? near) async {
  final params = {'q': query, 'format': 'jsonv2', 'limit': '8', 'accept-language': 'cs'};
  final uri = Uri.https('nominatim.openstreetmap.org', '/search', params);
  final res = await http.get(uri, headers: uaHeaders()).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) return [];
  final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
  return list
      .map(
        (e) => Place(
          (e['name'] as String?)?.isNotEmpty == true ? e['name'] as String : e['display_name'] as String,
          LatLng(double.parse(e['lat'] as String), double.parse(e['lon'] as String)),
          address: e['display_name'] as String,
        ),
      )
      .toList();
}

enum PoiKind { parking, service, fuel }

extension PoiKindLabel on PoiKind {
  String get label => switch (this) {
    PoiKind.parking => 'Truckparky a odpočívky',
    PoiKind.service => 'Truck servisy a pneuservisy',
    PoiKind.fuel => 'Čerpací stanice pro kamiony',
  };
}

/// POI pro kamiony v okolí bodu z OpenStreetMap (Overpass API).
Future<List<Place>> findTruckPois(LatLng p, PoiKind kind, {int radiusM = 30000}) => _findPois(
  kind,
  '(around:$radiusM,${p.latitude},${p.longitude})',
  [p],
  radiusM ~/ 1000,
  p,
  [_box(p, radiusM.toDouble())],
  maxM: radiusM.toDouble(),
);

/// Obálka kolem bodu (minLat, maxLat, minLon, maxLon).
(double, double, double, double) _box(LatLng p, double m) {
  final dLat = m / 110540, dLon = m / (111320 * math.cos(p.latitude * math.pi / 180));
  return (p.latitude - dLat, p.latitude + dLat, p.longitude - dLon, p.longitude + dLon);
}

/// POI podél trasy: kolik km/min před vámi a jak daleko od trasy.
class RoutePoi {
  final Place place;
  final double aheadM; // vzdálenost po trase od aktuální polohy
  final double offM; // vzdušně od trasy (zajížďka ≈ 2×)
  final double etaSec;
  RoutePoi(this.place, this.aheadM, this.offM, this.etaSec);
}

/// Truckparky / pumpy / servisy na dalších [aheadM] m trasy (do 1,5 km od ní), seřazené po trase.
Future<List<RoutePoi>> findTruckPoisAlongRoute(
  TruckRoute route,
  double fromM,
  PoiKind kind, {
  double aheadM = 150000,
}) async {
  final cum = route.cumulative;
  final toM = (fromM + aheadM).clamp(0.0, cum.last);
  // Body trasy po ~300 m (stačí pro „around“ 1,5 km a pro výpočet polohy POI).
  final samples = <(LatLng, double)>[];
  var next = fromM;
  for (var i = 0; i < route.shape.length; i++) {
    if (cum[i] < fromM) continue;
    if (cum[i] > toM) break;
    if (cum[i] >= next) {
      samples.add((route.shape[i], cum[i]));
      next = cum[i] + 300;
    }
  }
  if (samples.length < 2) return [];
  final poly = samples
      .map((e) => '${e.$1.latitude.toStringAsFixed(5)},${e.$1.longitude.toStringAsFixed(5)}')
      .join(',');
  final centers = <LatLng>[
    for (var k = 0; k < samples.length; k += 66) samples[k].$1, // ~ každých 20 km
  ];
  // Obálky po ~6 km úsecích trasy (+1,5 km) pro data v telefonu.
  final boxes = <(double, double, double, double)>[];
  for (var k = 0; k < samples.length; k += 20) {
    final part = samples.sublist(k, math.min(k + 21, samples.length)).map((e) => e.$1);
    final a = _box(
      LatLng(part.map((q) => q.latitude).reduce(math.min), part.map((q) => q.longitude).reduce(math.min)),
      1500,
    );
    final b = _box(
      LatLng(part.map((q) => q.latitude).reduce(math.max), part.map((q) => q.longitude).reduce(math.max)),
      1500,
    );
    boxes.add((a.$1, b.$2, a.$3, b.$4));
  }
  final places = await _findPois(kind, '(around:1500,$poly)', centers, 6, samples.first.$1, boxes);
  const dist = Distance();
  final speed = route.timeSec > 0 ? route.lengthKm * 1000 / route.timeSec : 20.0; // m/s
  final out = <RoutePoi>[];
  for (final p in places) {
    var best = double.infinity;
    var at = 0.0;
    for (final (q, c) in samples) {
      final d = dist(p.point, q);
      if (d < best) {
        best = d;
        at = c;
      }
    }
    if (best > 2500) continue;
    final ahead = at - fromM;
    out.add(RoutePoi(p, ahead, best, ahead / speed));
  }
  out.sort((a, b) => a.aheadM.compareTo(b.aheadM));
  return out;
}

Future<List<Place>> _findPois(
  PoiKind kind,
  String a,
  List<LatLng> photonCenters,
  int photonRadiusKm,
  LatLng p,
  List<(double, double, double, double)> boxes, {
  double? maxM,
}) async {
  if (kind != PoiKind.parking) return _mapPois(kind, a, photonCenters, photonRadiusKm, p, boxes, maxM: maxM);
  // Parkoviště: mapa + vlastní síť (místa a údaje od řidičů, obsazenost).
  final net = ParkingNetwork.instance;
  await net.load();
  final all = (
    boxes.map((b) => b.$1).reduce(math.min),
    boxes.map((b) => b.$2).reduce(math.max),
    boxes.map((b) => b.$3).reduce(math.min),
    boxes.map((b) => b.$4).reduce(math.max),
  );
  final pulled = net.pull(all).catchError((_) {});
  List<Place> osm;
  try {
    osm = await _mapPois(kind, a, photonCenters, photonRadiusKm, p, boxes, maxM: maxM);
  } catch (_) {
    // Bez mapových dat aspoň místa ze sítě v telefonu.
    if (!net.places.values.any((e) => boxes.any((b) => _inBox(e.point, b)))) rethrow;
    osm = [];
  }
  await pulled.timeout(const Duration(seconds: 5), onTimeout: () {});
  const dist = Distance();
  final out = net.merge(osm, (q) => boxes.any((b) => _inBox(q, b)) && (maxM == null || dist(p, q) <= maxM));
  out.sort((x, y) => dist(p, x.point).compareTo(dist(p, y.point)));
  return out;
}

bool _inBox(LatLng q, (double, double, double, double) b) =>
    q.latitude >= b.$1 && q.latitude <= b.$2 && q.longitude >= b.$3 && q.longitude <= b.$4;

/// POI z OpenStreetMap: z dat v telefonu, jinak Overpass + Photon.
Future<List<Place>> _mapPois(
  PoiKind kind,
  String a,
  List<LatLng> photonCenters,
  int photonRadiusKm,
  LatLng p,
  List<(double, double, double, double)> boxes, {
  double? maxM,
}) async {
  final off = OfflineSearch.instance;
  if (off.hasOsm) return _localPois(kind, boxes, p, maxM);
  final filters = switch (kind) {
    PoiKind.parking => [
      'nwr["amenity"="parking"]["hgv"~"yes|designated"]$a;',
      'nwr["highway"~"^(rest_area|services)\$"]$a;',
    ],
    PoiKind.service => [
      'nwr["shop"~"^(truck_repair|truck|tyres)\$"]$a;',
      'nwr["craft"="truck_repair"]$a;',
      'nwr["shop"="car_repair"]["hgv"~"yes|designated"]$a;',
    ],
    PoiKind.fuel => [
      'nwr["amenity"="fuel"]["hgv"~"yes|designated"]$a;',
      'nwr["amenity"="fuel"]["fuel:HGV_diesel"="yes"]$a;',
      'nwr["amenity"="fuel"]["fuel:adblue"="yes"]$a;',
    ],
  };
  // Overpass (bohatá data o vybavenosti) a Photon (rychlý, spolehlivý) souběžně.
  final overpass = overpassQuery('[out:json][timeout:25];(${filters.join()});out center tags 80;');
  final photonF = Future.wait(
    photonCenters.map((c) => _photonNearby(c, kind, photonRadiusKm).catchError((_) => <Place>[])),
  );
  final els = await overpass;
  final photon = (await photonF).expand((l) => l).toList();
  if (els == null && photon.isEmpty) throw Exception('servery s mapovými daty neodpovídají');
  const dist = Distance();
  final places = _placesOf(els ?? const []);
  // Doplň z Photonu, co Overpass nemá (duplicita = do 120 m od existujícího).
  for (final ph in photon) {
    if (places.any((x) => dist(x.point, ph.point) < 120)) continue;
    places.add(ph);
  }
  places.sort((x, y) => dist(p, x.point).compareTo(dist(p, y.point)));
  return places;
}

bool _isTruckHgv(Map t) => t['hgv'] == 'yes' || t['hgv'] == 'designated';

/// Stejný výběr jako dotaz na Overpass, ale z dat v telefonu (bez internetu, okamžitě).
bool _matches(PoiKind kind, Map t, {bool anyFuel = false}) => switch (kind) {
  PoiKind.parking =>
    (t['amenity'] == 'parking' && (_isTruckHgv(t) || t['capacity:hgv'] != null)) ||
        t['highway'] == 'rest_area' ||
        t['highway'] == 'services',
  PoiKind.service =>
    const {'truck_repair', 'truck', 'tyres'}.contains(t['shop']) ||
        t['craft'] == 'truck_repair' ||
        (t['shop'] == 'car_repair' && _isTruckHgv(t)),
  PoiKind.fuel =>
    t['amenity'] == 'fuel' &&
        (anyFuel || _isTruckHgv(t) || t['fuel:HGV_diesel'] == 'yes' || t['fuel:adblue'] == 'yes'),
};

List<Place> _localPois(PoiKind kind, List<(double, double, double, double)> boxes, LatLng p, double? maxM) {
  const dist = Distance();
  final els = <dynamic>[];
  final seen = <String>{};
  for (final (a, b, c, d) in boxes) {
    for (final e in OfflineSearch.instance.osmElements(a, b, c, d)) {
      if (seen.add('${e['type']}${e['id']}')) els.add(e);
    }
  }
  List<Place> pick({bool anyFuel = false}) {
    final out = _placesOf([
      for (final e in els)
        if (_matches(kind, e['tags'] as Map, anyFuel: anyFuel)) e,
    ]);
    if (maxM != null) out.removeWhere((x) => dist(p, x.point) > maxM);
    return out;
  }

  var places = pick();
  // Pump s označením pro kamiony je v mapě málo – když chybí, ukaž všechny pumpy.
  if (kind == PoiKind.fuel && places.length < 3) places = pick(anyFuel: true);
  places.sort((x, y) => dist(p, x.point).compareTo(dist(p, y.point)));
  return places;
}

List<Place> _placesOf(List<dynamic> els) {
  final places = <Place>[];
  final seen = <String>{};
  for (final e in els) {
    final lat = (e['lat'] ?? e['center']?['lat']) as num?;
    final lon = (e['lon'] ?? e['center']?['lon']) as num?;
    if (lat == null || lon == null) continue;
    if (!seen.add('${e['type']}${e['id']}')) continue;
    final t = Map<String, dynamic>.from((e['tags'] as Map?) ?? const {});
    final type = _poiType(t);
    final name = (t['name'] ?? t['operator'] ?? t['brand']) as String? ?? type;
    places.add(
      Place(
        name,
        LatLng(lat.toDouble(), lon.toDouble()),
        kind: type,
        features: _features(t),
        id: osmPlaceId(e['type'], e['id']),
      ),
    );
  }
  return places;
}

Future<List<Place>> _photonNearby(LatLng p, PoiKind kind, int radiusKm) async {
  final tags = switch (kind) {
    PoiKind.parking => ['highway:services', 'highway:rest_area', 'amenity:parking'],
    PoiKind.service => [
      'shop:truck_repair',
      'shop:truck',
      'shop:tyres',
      'craft:truck_repair',
      'shop:car_repair',
    ],
    PoiKind.fuel => ['amenity:fuel'],
  };
  final q = [
    'lat=${p.latitude.toStringAsFixed(5)}',
    'lon=${p.longitude.toStringAsFixed(5)}',
    'radius=${radiusKm.clamp(1, 50)}',
    'limit=40',
    for (final t in tags) 'osm_tag=${Uri.encodeQueryComponent(t)}',
  ].join('&');
  final res = await http
      .get(Uri.parse('https://photon.komoot.io/reverse?$q'), headers: uaHeaders())
      .timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) return [];
  final truckish = RegExp(r'tir|kamion|truck|lkw|hgv|nákladn|odpočív|autohof', caseSensitive: false);
  final out = <Place>[];
  for (final f in (jsonDecode(utf8.decode(res.bodyBytes))['features'] as List)) {
    final pr = Map<String, dynamic>.from(f['properties'] as Map);
    final value = pr['osm_value'] as String?;
    final name = (pr['name'] as String?) ?? '';
    // Běžná parkoviště a autoservisy jen pokud se tváří jako pro kamiony.
    if (value == 'parking' && !truckish.hasMatch(name)) continue;
    if (value == 'car_repair' && !truckish.hasMatch(name)) continue;
    final c = (f['geometry']['coordinates'] as List).cast<num>();
    final type = switch (value) {
      'services' => 'Odpočívka s ČS',
      'rest_area' => 'Odpočívka',
      'parking' => 'Parkoviště pro kamiony',
      'fuel' => 'Čerpací stanice',
      'tyres' => 'Pneuservis',
      _ => 'Servis nákladních vozidel',
    };
    out.add(
      Place(
        name.isEmpty ? type : name,
        LatLng(c[1].toDouble(), c[0].toDouble()),
        kind: type,
        address: pr['city'] as String?,
        id: osmPlaceId(pr['osm_type'], pr['osm_id']),
      ),
    );
  }
  return out;
}

String _poiType(Map<String, dynamic> t) {
  if (t['highway'] == 'services') return 'Odpočívka s ČS';
  if (t['highway'] == 'rest_area') return 'Odpočívka';
  if (t['amenity'] == 'parking') return 'Parkoviště pro kamiony';
  if (t['amenity'] == 'fuel') return 'Čerpací stanice';
  if (t['shop'] == 'tyres') return 'Pneuservis';
  return 'Servis nákladních vozidel';
}

List<String> _features(Map<String, dynamic> t) {
  bool yes(String k) => const ['yes', 'designated', 'customers'].contains(t[k]);
  final f = <String>[];
  final cap = t['capacity:hgv'] ?? t['capacity:truck'] ?? (t['amenity'] == 'parking' ? t['capacity'] : null);
  if (cap != null) f.add('$cap míst');
  if (t['fee'] == 'no') f.add('zdarma');
  if (t['fee'] == 'yes') f.add('placené');
  if (yes('supervised') || t['surveillance'] != null) f.add('hlídané/kamery');
  if (t['barrier'] == 'fence' || yes('fenced')) f.add('oplocené');
  if (yes('toilets')) f.add('WC');
  if (yes('shower') || yes('showers')) f.add('sprchy');
  if (yes('restaurant') || yes('food')) f.add('jídlo');
  if (t['fuel:adblue'] == 'yes') f.add('AdBlue');
  if (t['fuel:HGV_diesel'] == 'yes') f.add('HGV nafta');
  if (t['opening_hours'] == '24/7') f.add('nonstop');
  return f;
}
