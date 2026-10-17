import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'http_headers.dart';
import 'offline_search.dart';

/// Obec, ve které leží bod (pro zásobování: výjimka platí v obci vykládky).
/// Online Photon (správná obec i pro části jako Trnovany → Teplice), bez internetu nejbližší
/// obec z rejstříku v telefonu. Zdroj se zvolí jednou, ať se jména obcí nemíchají.
class TownLookup {
  bool? _online;
  final _cache = <String, String?>{};

  Future<String?> at(LatLng p) async {
    final key = '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}';
    if (_cache.containsKey(key)) return _cache[key];
    String? town;
    if (_online != false) {
      town = await _photon(p);
      _online ??= town != null;
    }
    if (_online == false) town = OfflineSearch.instance.nearestTown(p);
    return _cache[key] = town;
  }

  // Veřejný Photon při mnoha souběžných dotazech vrací 503 → nejvýš 2 najednou a opakování.
  static int _running = 0;

  static Future<String?> _photon(LatLng p) async {
    while (_running >= 2) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    _running++;
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        final r = await _photonOnce(p);
        if (r != null) return r.isEmpty ? null : r;
      }
      return null;
    } finally {
      _running--;
    }
  }

  /// null = chyba (zkusit znovu), '' = místo bez obce.
  static Future<String?> _photonOnce(LatLng p) async {
    try {
      final uri = Uri.parse(
        'https://photon.komoot.io/reverse?lat=${p.latitude.toStringAsFixed(5)}'
        '&lon=${p.longitude.toStringAsFixed(5)}&limit=1',
      );
      final res = await http.get(uri, headers: uaHeaders()).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final f = (jsonDecode(utf8.decode(res.bodyBytes))['features'] as List);
      if (f.isEmpty) return '';
      final pr = Map<String, dynamic>.from(f.first['properties'] as Map);
      final city = pr['city'] as String?;
      if (city != null && city.isNotEmpty) return city;
      if (const {'city', 'town', 'village'}.contains(pr['osm_value'])) return pr['name'] as String?;
      return pr['county'] != null ? '?${pr['county']}' : '';
    } catch (_) {
      return null;
    }
  }
}
