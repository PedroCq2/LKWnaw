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
  if (results.isNotEmpty) return rankPlaces(results, low).take(12).toList();
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

const _genericWords = {
  'dc', 'sklad', 'distribuční', 'distribucni', 'centrum', 'centrální', 'centralni', 'areál', 'areal',
  'rampa', 'logistika', 'logistické', 'a', 's', 'u', 'v', 'na',
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
  int match(Place p) {
    final hay = _fold('${p.name} ${p.address ?? ''}');
    return key.where(hay.contains).length;
  }
  final idx = {for (var i = 0; i < list.length; i++) list[i]: i};
  final sorted = [...list]..sort((a, b) {
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
  // Overpass (bohatá data o vybavenosti) a Photon (rychlý, spolehlivý) souběžně.
  final overpass = overpassQuery('[out:json][timeout:25];(${filters.join()});out center tags 80;');
  final photonF = _photonNearby(p, kind, radiusM ~/ 1000).catchError((_) => <Place>[]);
  final els = await overpass;
  final photon = await photonF;
  if (els == null && photon.isEmpty) throw Exception('servery s mapovými daty neodpovídají');
  const dist = Distance();
  final places = <Place>[];
  final seen = <String>{};
  for (final e in els ?? const []) {
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
  // Doplň z Photonu, co Overpass nemá (duplicita = do 120 m od existujícího).
  for (final ph in photon) {
    if (places.any((x) => dist(x.point, ph.point) < 120)) continue;
    places.add(ph);
  }
  places.sort((x, y) => dist(p, x.point).compareTo(dist(p, y.point)));
  return places;
}

Future<List<Place>> _photonNearby(LatLng p, PoiKind kind, int radiusKm) async {
  final tags = switch (kind) {
    PoiKind.parking => ['highway:services', 'highway:rest_area', 'amenity:parking'],
    PoiKind.service => ['shop:truck_repair', 'shop:truck', 'shop:tyres', 'craft:truck_repair', 'shop:car_repair'],
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
    out.add(Place(name.isEmpty ? type : name, LatLng(c[1].toDouble(), c[0].toDouble()),
        kind: type, address: pr['city'] as String?));
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
