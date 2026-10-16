import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class Place {
  final String name;
  final LatLng point;
  Place(this.name, this.point);
}

const _ua = {'User-Agent': 'LKWnaw/1.0 (truck navigation)'};

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
  final res = await http.get(uri, headers: _ua).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) return [];
  final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
  return list
      .map((e) => Place(
            e['display_name'] as String,
            LatLng(double.parse(e['lat'] as String), double.parse(e['lon'] as String)),
          ))
      .toList();
}

/// Odpočívky a parkoviště pro kamiony v okolí bodu (Overpass API).
Future<List<Place>> findTruckParking(LatLng p, {int radiusM = 30000}) async {
  final q = '''
[out:json][timeout:25];
(
  nwr["amenity"="parking"]["hgv"~"yes|designated"](around:$radiusM,${p.latitude},${p.longitude});
  nwr["highway"="rest_area"](around:$radiusM,${p.latitude},${p.longitude});
  nwr["highway"="services"](around:$radiusM,${p.latitude},${p.longitude});
);
out center 60;
''';
  final res = await http
      .post(Uri.parse('https://overpass-api.de/api/interpreter'),
          headers: _ua, body: {'data': q})
      .timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) return [];
  final els = (jsonDecode(utf8.decode(res.bodyBytes))['elements'] as List);
  const dist = Distance();
  final places = <Place>[];
  for (final e in els) {
    final lat = (e['lat'] ?? e['center']?['lat']) as num?;
    final lon = (e['lon'] ?? e['center']?['lon']) as num?;
    if (lat == null || lon == null) continue;
    final tags = (e['tags'] as Map?) ?? const {};
    final kind = tags['highway'] == 'services'
        ? 'Čerpací/odpočívka'
        : tags['highway'] == 'rest_area'
            ? 'Odpočívka'
            : 'Parkoviště HGV';
    final name = tags['name'] as String? ?? kind;
    places.add(Place('$name ($kind)', LatLng(lat.toDouble(), lon.toDouble())));
  }
  places.sort((a, b) => dist(p, a.point).compareTo(dist(p, b.point)));
  return places;
}
