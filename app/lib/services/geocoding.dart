import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'http_headers.dart';
import 'restrictions.dart';

class Place {
  final String name;
  final LatLng point;
  final String? kind;
  final String? address;
  final List<String> features; // vybavenost (WC, sprchy, …)
  Place(this.name, this.point, {this.kind, this.address, this.features = const []});
}


/// Vyhledávání míst: Photon (OSM, toleruje názvy firem jako „kaufland dc olomouc“),
/// záložně Nominatim.
Future<List<Place>> searchPlaces(String query, {LatLng? near}) async {
  final q = query.trim();
  if (q.isEmpty) return [];
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
  try {
    final lists = await Future.wait(variants.map((v) => _photon(v, near)));
    for (final list in lists) {
      for (final p in list) {
        final key = '${p.name}|${p.point.latitude.toStringAsFixed(3)}|${p.point.longitude.toStringAsFixed(3)}';
        if (seen.add(key)) results.add(p);
      }
    }
  } catch (_) {}
  if (results.isNotEmpty) return _rank(results, low, near).take(12).toList();
  return _nominatim(q, near);
}

const _skipValues = {'bus_stop', 'tram_stop', 'stop_position', 'platform', 'station', 'halt'};

Future<List<Place>> _photon(String q, LatLng? near) async {
  final params = {'q': q, 'limit': '10'};
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
    final city = (p['city'] ?? p['town'] ?? p['village'] ?? p['county']) as String?;
    final address = [
      if (street.isNotEmpty) street,
      if (p['postcode'] != null) '${p['postcode']} ${city ?? ''}'.trim() else ?city,
    ].join(', ');
    final name = (p['name'] as String?) ?? (street.isNotEmpty ? street : (city ?? q));
    out.add(Place(name, LatLng(c[1].toDouble(), c[0].toDouble()),
        kind: _photonKind(p['osm_key'] as String?, p['osm_value'] as String?),
        address: address.isEmpty ? null : address));
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

/// Areály a sklady výš, pokud uživatel hledá „dc/sklad“; jinak blíž = výš.
List<Place> _rank(List<Place> list, String q, LatLng? near) {
  const dist = Distance();
  final wantsDepot = RegExp(r'\b(dc|sklad|centrum|areál|rampa)\b').hasMatch(q);
  double score(Place p) {
    var s = near == null ? 0.0 : dist(near, p.point) / 1000; // km
    if (wantsDepot &&
        const ['Sklad', 'Průmyslový areál', 'Logistika', 'Velkoobchod', 'Továrna', 'Komerční areál']
            .contains(p.kind)) {
      s -= 500;
    }
    return s;
  }
  // Photon už řadí podle relevance; stabilně upřednostni jen sklady/areály.
  if (!wantsDepot) return list;
  final idx = {for (var i = 0; i < list.length; i++) list[i]: i};
  return [...list]..sort((a, b) {
      final c = score(a).compareTo(score(b));
      return c != 0 ? c : idx[a]!.compareTo(idx[b]!);
    });
}

Future<List<Place>> _nominatim(String query, LatLng? near) async {
  final params = {
    'q': query,
    'format': 'jsonv2',
    'limit': '8',
    'accept-language': 'cs',
  };
  final uri = Uri.https('nominatim.openstreetmap.org', '/search', params);
  final res = await http.get(uri, headers: uaHeaders()).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) return [];
  final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
  return list
      .map((e) => Place(
            (e['name'] as String?)?.isNotEmpty == true ? e['name'] as String : e['display_name'] as String,
            LatLng(double.parse(e['lat'] as String), double.parse(e['lon'] as String)),
            address: e['display_name'] as String,
          ))
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
Future<List<Place>> findTruckPois(LatLng p, PoiKind kind, {int radiusM = 30000}) async {
  final a = '(around:$radiusM,${p.latitude},${p.longitude})';
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
  final els = await overpassQuery('[out:json][timeout:25];(${filters.join()});out center tags 80;');
  if (els == null) throw Exception('Overpass API nedostupné');
  const dist = Distance();
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
    places.add(Place(name, LatLng(lat.toDouble(), lon.toDouble()),
        kind: type, features: _features(t)));
  }
  places.sort((x, y) => dist(p, x.point).compareTo(dist(p, y.point)));
  return places;
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
