import 'package:latlong2/latlong.dart';

import '../models/route.dart';
import '../models/truck_profile.dart';
import 'horizon.dart';
import 'offline_search.dart';
import 'restrictions.dart';

/// Úsek silnice s omezením pro kamion v mapě: červeně, co vozidlo překračuje (nízký most, úzká
/// ulice, nosnost, zákaz vjezdu), oranžově těsné / jen dopravní obsluha.
class RestrictedWay {
  final int id;
  final List<LatLng> geom; // jen jeden bod, když balík v telefonu geometrii nemá
  final bool bad;
  final String label; // „3,5 t“, „3,3 m“, „zákaz“
  RestrictedWay(this.id, this.geom, this.bad, this.label);
}

/// Jak cestu se štítky [tags] ukázat kamionu [truck] (null = pro něj nic).
(bool, String)? restrictionLook(Map<String, dynamic> tags, TruckProfile truck, {bool delivery = false}) {
  if (tags['highway'] == null) return null;
  const p = LatLng(0, 0);
  final ws = [
    for (final w in warningsFromTags(tags, 0, p, truck, delivery))
      if (w.type != WarningType.noOvertakingHgv && (w.violates || w.tight)) w,
    ?hgvBan(tags, 0, p),
  ];
  if (ws.isEmpty) return null;
  // Nejhorší první: překročený limit před těsným.
  ws.sort((a, b) => (b.violates ? 1 : 0).compareTo(a.violates ? 1 : 0));
  final w = ws.first;
  final label = switch (w.type) {
    WarningType.noHgv => w.violates ? 'zákaz' : 'obsl.',
    _ => w.label.replaceAll(' ', ''),
  };
  return (w.violates, label);
}

/// Omezení v okolí po čtvercích ~4 km (načtené se pamatují): z balíku v telefonu, jinak Overpass.
class RestrictionMap {
  static const _cellLat = 0.04, _cellLon = 0.06;
  final _cells = <String, List<Map<String, dynamic>>>{};
  final _order = <String>[];
  final _loading = <String>{};

  static String _key(int a, int b) => '$a:$b';

  /// Načte čtverce kolem [center] (3 × 3). Vrací true, když přibylo něco nového.
  Future<bool> loadAround(LatLng center) async {
    final a0 = (center.latitude / _cellLat).floor(), b0 = (center.longitude / _cellLon).floor();
    var added = false;
    for (var da = -1; da <= 1; da++) {
      for (var db = -1; db <= 1; db++) {
        final a = a0 + da, b = b0 + db;
        final k = _key(a, b);
        if (_cells.containsKey(k) || !_loading.add(k)) continue;
        try {
          final els = await _fetch(a * _cellLat, (a + 1) * _cellLat, b * _cellLon, (b + 1) * _cellLon);
          if (els == null) continue; // bez dat – zkusit příště znovu
          _cells[k] = els;
          _order.add(k);
          added = true;
          // Paměť: nejvýš 40 čtverců (~650 km²).
          while (_order.length > 40) {
            _cells.remove(_order.removeAt(0));
          }
        } finally {
          _loading.remove(k);
        }
      }
    }
    return added;
  }

  /// Úseky s omezením pro [truck] v načtených čtvercích.
  List<RestrictedWay> ways(TruckProfile truck, {bool delivery = false}) {
    final out = <RestrictedWay>[];
    final seen = <int>{};
    for (final els in _cells.values) {
      for (final e in els) {
        if (e['type'] != 'way') continue;
        final id = (e['id'] as num).toInt();
        if (!seen.add(id)) continue;
        final tags = Map<String, dynamic>.from((e['tags'] as Map?) ?? const {});
        final look = restrictionLook(tags, truck, delivery: delivery);
        if (look == null) continue;
        final geom = <LatLng>[
          for (final g in (e['geometry'] as List?) ?? const [])
            LatLng(((g as Map)['lat'] as num).toDouble(), (g['lon'] as num).toDouble()),
        ];
        if (geom.isEmpty) {
          final c = (e['center'] as Map?) ?? e;
          if (c['lat'] == null) continue;
          geom.add(LatLng((c['lat'] as num).toDouble(), (c['lon'] as num).toDouble()));
        }
        out.add(RestrictedWay(id, geom, look.$1, look.$2));
      }
    }
    return out;
  }

  static Future<List<Map<String, dynamic>>?> _fetch(double s, double n, double w, double e) async {
    final off = OfflineSearch.instance;
    if (off.hasOsm) return off.osmElements(s, n, w, e);
    final bbox =
        '${s.toStringAsFixed(4)},${w.toStringAsFixed(4)},${n.toStringAsFixed(4)},${e.toStringAsFixed(4)}';
    final q =
        '[out:json][timeout:25];('
        'way($bbox)["highway"][~"^max(height|weight|width|length|axleload)(:physical)?\$"~"."];'
        'way($bbox)["highway"]["hgv"~"^(no|destination|delivery)\$"];'
        ');out tags geom;';
    final els = await overpassQuery(q);
    return els == null ? null : [for (final e in els) Map<String, dynamic>.from(e as Map)];
  }
}

/// GeoJSON pro mapu: čáry (úseky s geometrií) a body (bez ní), vlastnosti `bad` a `l` (popisek).
(Map<String, dynamic>, Map<String, dynamic>) restrictionGeoJson(List<RestrictedWay> ways) {
  List<double> xy(LatLng p) => [p.longitude, p.latitude];
  final lines = <Map<String, dynamic>>[], points = <Map<String, dynamic>>[];
  // Jedna ulice bývá v mapě rozdělená na mnoho kousků – stejná značka do 150 m jen jednou, jiná
  // značka do 60 m taky ne (na křižovatce by byly přes sebe; červené mají přednost).
  final marks = <(LatLng, String)>[];
  const dist = Distance();
  void mark(LatLng p, Map<String, dynamic> props) {
    final l = props['l'] as String;
    if (marks.any((m) => dist(m.$1, p) < (m.$2 == l ? 150 : 60))) return;
    marks.add((p, l));
    points.add({
      'type': 'Feature',
      'properties': props,
      'geometry': {'type': 'Point', 'coordinates': xy(p)},
    });
  }

  for (final w in [...ways.where((w) => w.bad), ...ways.where((w) => !w.bad)]) {
    final props = {'bad': w.bad, 'l': w.label};
    if (w.geom.length >= 2) {
      lines.add({
        'type': 'Feature',
        'properties': props,
        'geometry': {
          'type': 'LineString',
          'coordinates': [for (final p in w.geom) xy(p)],
        },
      });
      // Značka uprostřed úseku (i u krátkého mostu je vidět, co tam je).
      mark(w.geom[w.geom.length ~/ 2], props);
    } else {
      mark(w.geom.first, props);
    }
  }
  return (
    {'type': 'FeatureCollection', 'features': lines},
    {'type': 'FeatureCollection', 'features': points},
  );
}
