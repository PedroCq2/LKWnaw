import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'http_headers.dart';

import '../models/route.dart';
import '../models/truck_profile.dart';

class RouteOption {
  final String label;
  final TruckRoute route;
  RouteOption(this.label, this.route);
}

class RoutingException implements Exception {
  final String message;
  RoutingException(this.message);
  @override
  String toString() => message;
}

/// Klient pro Valhalla `/route` s kamionovým profilem.
class ValhallaClient {
  final String baseUrl;
  ValhallaClient(this.baseUrl);

  Future<TruckRoute> route({
    required LatLng from,
    required LatLng to,
    required TruckProfile profile,
    double? heading,
    bool delivery = false,
    List<LatLng> exclude = const [],
  }) async =>
      (await _request(
              from: from, to: to, profile: profile, heading: heading, delivery: delivery, exclude: exclude))
          .first;

  /// Několik variant: nejrychlejší + alternativa, bez mýta, nejkratší (bez duplicit).
  Future<List<RouteOption>> routeOptions({
    required LatLng from,
    required LatLng to,
    required TruckProfile profile,
    double? heading,
    bool delivery = false,
    List<LatLng> exclude = const [],
  }) async {
    Future<List<TruckRoute>> safe(Future<List<TruckRoute>> f) => f.catchError((_) => <TruckRoute>[]);
    final main = _request(
        from: from, to: to, profile: profile, heading: heading, delivery: delivery, exclude: exclude,
        alternates: 2);
    final noToll = safe(_request(
        from: from, to: to, profile: profile, heading: heading, delivery: delivery, exclude: exclude,
        extra: {'use_tolls': 0.0, 'exclude_tolls': true}));
    final shortest = safe(_request(
        from: from, to: to, profile: profile, heading: heading, delivery: delivery, exclude: exclude,
        extra: {'shortest': true}));
    final res = await Future.wait([main, noToll, shortest]);
    final out = <RouteOption>[];
    void add(String label, TruckRoute r) {
      final dup = out.any((o) =>
          (o.route.lengthKm - r.lengthKm).abs() < r.lengthKm * 0.01 + 0.2 &&
          (o.route.timeSec - r.timeSec).abs() < r.timeSec * 0.02 + 30);
      if (!dup) out.add(RouteOption(label, r));
    }
    for (final (i, r) in res[0].indexed) {
      add(i == 0 ? 'Nejrychlejší' : 'Alternativa', r);
    }
    for (final r in res[1].take(1)) {
      if (!r.hasToll) add('Bez mýta', r);
    }
    for (final r in res[2].take(1)) {
      add('Nejkratší', r);
    }
    return out;
  }

  Future<List<TruckRoute>> _request({
    required LatLng from,
    required LatLng to,
    required TruckProfile profile,
    double? heading,
    bool delivery = false,
    List<LatLng> exclude = const [],
    int alternates = 0,
    Map<String, dynamic> extra = const {},
  }) async {
    final origin = <String, dynamic>{'lat': from.latitude, 'lon': from.longitude};
    if (heading != null && heading >= 0) {
      origin['heading'] = heading.round();
      origin['heading_tolerance'] = 45;
    }
    final body = {
      'locations': [
        origin,
        {'lat': to.latitude, 'lon': to.longitude},
      ],
      'costing': 'truck',
      'costing_options': {
        'truck': {...profile.toValhallaCosting(delivery: delivery), ...extra}
      },
      if (alternates > 0) 'alternates': alternates,
      if (exclude.isNotEmpty)
        'exclude_locations': [
          for (final p in exclude) {'lat': p.latitude, 'lon': p.longitude}
        ],
      'language': 'cs-CZ',
      'units': 'kilometers',
      'directions_options': {'units': 'kilometers', 'language': 'cs-CZ'},
    };
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/route');
    final http.Response res;
    try {
      res = await http
          .post(uri,
              headers: uaHeaders({'Content-Type': 'application/json'}),
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw RoutingException('Server tras není dostupný: $e');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw RoutingException(
          'Trasu nelze vypočítat: ${data['error'] ?? res.statusCode}');
    }
    return [
      parseTrip(data['trip'] as Map<String, dynamic>),
      for (final a in (data['alternates'] as List? ?? const []))
        parseTrip((a as Map)['trip'] as Map<String, dynamic>),
    ];
  }

  /// Doplní k trase rychlostní limity a názvy silnic (Valhalla trace_attributes).
  Future<void> loadEdgeAttributes(TruckRoute route) async {
    final enc = route.encodedShape;
    if (enc == null) return;
    final body = {
      'encoded_polyline': enc,
      'costing': 'truck',
      'shape_match': 'edge_walk',
      'filters': {
        'attributes': [
          'edge.speed_limit',
          'edge.names',
          'edge.begin_shape_index',
          'edge.end_shape_index',
        ],
        'action': 'include',
      },
    };
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/trace_attributes');
    final res = await http
        .post(uri,
            headers: uaHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) return;
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final n = math.max(0, route.shape.length - 1);
    final limits = List<int?>.filled(n, null);
    final names = List<String?>.filled(n, null);
    for (final e in (data['edges'] as List? ?? const [])) {
      final b = (e['begin_shape_index'] as num?)?.toInt() ?? 0;
      final en = math.min(n, (e['end_shape_index'] as num?)?.toInt() ?? 0);
      final lim = (e['speed_limit'] as num?)?.toInt();
      final nm = (e['names'] as List?)?.isNotEmpty == true ? (e['names'] as List).first as String : null;
      for (var i = b; i < en; i++) {
        limits[i] = (lim != null && lim > 0 && lim < 200) ? lim : null;
        names[i] = nm;
      }
    }
    route.speedLimits = limits;
    route.roadNames = names;
  }

  static TruckRoute parseTrip(Map<String, dynamic> trip) {
    final shape = <LatLng>[];
    final maneuvers = <Maneuver>[];
    for (final leg in (trip['legs'] as List)) {
      final legMap = leg as Map<String, dynamic>;
      // Poslední bod předchozí etapy = první bod další, nezdvojovat.
      final offset = shape.isEmpty ? 0 : shape.length - 1;
      final pts = decodePolyline6(legMap['shape'] as String);
      shape.addAll(shape.isEmpty ? pts : pts.skip(1));
      for (final m in (legMap['maneuvers'] as List)) {
        final mj = Map<String, dynamic>.from(m as Map);
        mj['begin_shape_index'] = (mj['begin_shape_index'] as num) + offset;
        mj['end_shape_index'] = (mj['end_shape_index'] as num) + offset;
        maneuvers.add(Maneuver.fromJson(mj));
      }
    }
    final summary = trip['summary'] as Map<String, dynamic>;
    return TruckRoute(
      shape: shape,
      maneuvers: maneuvers,
      lengthKm: (summary['length'] as num).toDouble(),
      timeSec: (summary['time'] as num).toDouble(),
      hasToll: summary['has_toll'] as bool? ?? false,
      hasHighway: summary['has_highway'] as bool? ?? false,
      encodedShape: (trip['legs'] as List).length == 1
          ? (trip['legs'] as List).first['shape'] as String
          : null,
    );
  }
}

/// Dekóduje Google polyline s přesností 1e6 (formát Valhally).
///
/// Bez operátoru `~`: na webu (JS) dává nezáporný 32bitový výsledek.
List<LatLng> decodePolyline6(String encoded) {
  final out = <LatLng>[];
  var index = 0, lat = 0, lng = 0;
  while (index < encoded.length) {
    var result = 0, shift = 0, b = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lat += (result & 1) != 0 ? -(result >> 1) - 1 : (result >> 1);
    result = 0;
    shift = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lng += (result & 1) != 0 ? -(result >> 1) - 1 : (result >> 1);
    out.add(LatLng(lat / 1e6, lng / 1e6));
  }
  return out;
}
