import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/route.dart';
import 'http_headers.dart';
import 'restrictions.dart';

/// Živá data zdarma a bez registrace:
/// * Německo – Autobahn GmbH API: uzavírky, práce na silnici, truckparky (s počtem míst),
/// * počasí – Open-Meteo: nárazy větru (plachtové návěsy) a riziko náledí.
Future<List<RouteWarning>> loadLiveWarnings(TruckRoute route) async {
  final results = await Future.wait([
    _autobahn(route).catchError((_) => <RouteWarning>[]),
    _weather(route).catchError((_) => <RouteWarning>[]),
  ]);
  final all = results.expand((l) => l).toList()..sort((a, b) => a.atMeters.compareTo(b.atMeters));
  return mergeWarnings(all, gapM: 2000);
}

/// Německé dálnice na trase (A9, A 93 …) podle názvů úseků z Valhally.
Set<String> autobahnsOnRoute(TruckRoute route) {
  final re = RegExp(r'^A\s?(\d{1,3})$');
  final out = <String>{};
  for (final e in route.edges) {
    for (final n in e.names) {
      final m = re.firstMatch(n.trim());
      if (m != null) out.add('A${m.group(1)}');
    }
  }
  return out;
}

Future<List<RouteWarning>> _autobahn(TruckRoute route) async {
  final roads = autobahnsOnRoute(route);
  if (roads.isEmpty) return [];
  final index = RouteIndex(route);
  final out = <RouteWarning>[];
  final parking = <(LatLng, String, int?)>[];
  for (final road in roads.take(8)) {
    for (final service in ['closure', 'roadworks', 'parking_lorry']) {
      final data = await _getJson('https://verkehr.autobahn.de/o/autobahn/$road/services/$service');
      final items = (data?[service] as List?) ?? const [];
      for (final it in items) {
        final p = _point(it);
        if (p == null) continue;
        if (service == 'parking_lorry') {
          final desc = (it['description'] as List?)?.join(' ') ?? '';
          final m = RegExp(r'LKW Stellplätze:\s*(\d+)').firstMatch(desc);
          final name = '${it['subtitle'] ?? it['title'] ?? 'Rastplatz'}'.trim();
          parking.add((p, name, m == null ? null : int.parse(m.group(1)!)));
          continue;
        }
        final at = index.locate(p, 60);
        if (at == null) continue;
        final closure = service == 'closure' || '${it['isBlocked']}' == 'true';
        // Krátkodobé noční práce bez omezení nejsou pro řidiče podstatné – jen uzavírky a dlouhodobé.
        if (!closure && '${it['display_type']}' == 'SHORT_TERM_ROADWORKS') continue;
        out.add(
          RouteWarning(
            type: closure ? WarningType.closure : WarningType.roadworks,
            value: null,
            note: '${it['title'] ?? ''}'.replaceFirst(RegExp(r'^A\d+\s*\|\s*'), '').trim(),
            atMeters: at,
            point: p,
            violates: closure && '${it['display_type']}' != 'CLOSURE_ENTRY_EXIT',
          ),
        );
      }
    }
  }
  route.autobahnParking = parking;
  return out;
}

LatLng? _point(dynamic it) {
  final c = it['coordinate'];
  if (c is Map) {
    if (c['lat'] != null) {
      return LatLng(double.parse('${c['lat']}'), double.parse('${c['long']}'));
    }
    final xy = c['coordinates'];
    if (xy is List && xy.length == 2) return LatLng((xy[1] as num).toDouble(), (xy[0] as num).toDouble());
  }
  return null;
}

/// Počasí podél trasy každých ~40 km (max. 12 bodů v jednom dotazu).
Future<List<RouteWarning>> _weather(TruckRoute route) async {
  final cum = route.cumulative;
  final pts = <(LatLng, double)>[];
  for (var d = 0.0; d <= cum.last && pts.length < 12; d += 40000) {
    final i = cum.indexWhere((c) => c >= d);
    pts.add((route.shape[i < 0 ? route.shape.length - 1 : i], d));
  }
  final lat = pts.map((p) => p.$1.latitude.toStringAsFixed(3)).join(',');
  final lon = pts.map((p) => p.$1.longitude.toStringAsFixed(3)).join(',');
  final data = await _getJsonAny(
    'https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon'
    '&current=wind_gusts_10m,temperature_2m,precipitation&wind_speed_unit=kmh',
  );
  final list = data is List ? data : (data == null ? const [] : [data]);
  final out = <RouteWarning>[];
  for (var i = 0; i < list.length && i < pts.length; i++) {
    final cur = (list[i] as Map)['current'] as Map?;
    if (cur == null) continue;
    final gust = (cur['wind_gusts_10m'] as num?)?.toDouble() ?? 0;
    final temp = (cur['temperature_2m'] as num?)?.toDouble() ?? 10;
    final rain = (cur['precipitation'] as num?)?.toDouble() ?? 0;
    final (p, at) = pts[i];
    if (gust >= 60) {
      out.add(
        RouteWarning(type: WarningType.wind, value: gust, atMeters: at, point: p, violates: gust >= 80),
      );
    }
    if (temp <= 1 && rain > 0) {
      out.add(RouteWarning(type: WarningType.ice, value: temp, atMeters: at, point: p, violates: true));
    }
  }
  return out;
}

Future<Map<String, dynamic>?> _getJson(String url) async {
  final v = await _getJsonAny(url);
  return v is Map<String, dynamic> ? v : null;
}

Future<dynamic> _getJsonAny(String url) async {
  try {
    final res = await http.get(Uri.parse(url), headers: uaHeaders()).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  } catch (_) {
    return null;
  }
}
