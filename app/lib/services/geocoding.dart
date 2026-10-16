import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'http_headers.dart';
import 'restrictions.dart';

class Place {
  final String name;
  final LatLng point;
  final String? kind;
  final List<String> features; // vybavenost (WC, sprchy, …)
  Place(this.name, this.point, {this.kind, this.features = const []});
}


/// Vyhledávání adres přes Nominatim (OpenStreetMap).
Future<List<Place>> searchPlaces(String query, {LatLng? near}) async {
  final params = {
    'q': query,
    'format': 'jsonv2',
    'limit': '8',
    'accept-language': 'cs',
  };
  if (near != null) {
    // Upřednostní výsledky v okolí, ale nezakazuje vzdálené.
    params['viewbox'] =
        '${near.longitude - 2},${near.latitude + 2},${near.longitude + 2},${near.latitude - 2}';
  }
  final uri = Uri.https('nominatim.openstreetmap.org', '/search', params);
  final res = await http.get(uri, headers: uaHeaders()).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) return [];
  final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
  return list
      .map((e) => Place(
            e['display_name'] as String,
            LatLng(double.parse(e['lat'] as String), double.parse(e['lon'] as String)),
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
