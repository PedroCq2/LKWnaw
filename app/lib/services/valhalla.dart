import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/route.dart';
import '../models/truck_profile.dart';

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
      'costing_options': {'truck': profile.toValhallaCosting()},
      'language': 'cs-CZ',
      'units': 'kilometers',
      'directions_options': {'units': 'kilometers', 'language': 'cs-CZ'},
    };
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/route');
    final http.Response res;
    try {
      res = await http
          .post(uri,
              headers: {
                'Content-Type': 'application/json',
                'User-Agent': 'LKWnaw/1.0 (truck navigation)',
              },
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
    return parseTrip(data['trip'] as Map<String, dynamic>);
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
    );
  }
}

/// Dekóduje Google polyline s přesností 1e6 (formát Valhally).
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
    lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    result = 0;
    shift = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    out.add(LatLng(lat / 1e6, lng / 1e6));
  }
  return out;
}
