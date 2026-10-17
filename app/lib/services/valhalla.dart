import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'http_headers.dart';
import 'offline_routing.dart';
import 'town.dart';

import '../models/route.dart';
import '../models/truck_profile.dart';

class RouteOption {
  final String label;
  final TruckRoute route;
  RouteOption(this.label, this.route);
}

class RoutingException implements Exception {
  final String message;
  final bool network; // server nedostupný (bez internetu)
  RoutingException(this.message, {this.network = false});
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
    List<LatLng> via = const [],
  }) async => (await _request(
    via: via,
    from: from,
    to: to,
    profile: profile,
    heading: heading,
    delivery: delivery,
    exclude: exclude,
  )).first;

  /// Několik variant: nejrychlejší + alternativa, bez mýta, nejkratší (bez duplicit).
  Future<List<RouteOption>> routeOptions({
    required LatLng from,
    required LatLng to,
    required TruckProfile profile,
    double? heading,
    bool delivery = false,
    List<LatLng> exclude = const [],
    List<LatLng> via = const [],
  }) async {
    Future<List<TruckRoute>> safe(Future<List<TruckRoute>> f) => f.catchError((_) => <TruckRoute>[]);
    final main = _request(
      from: from,
      to: to,
      profile: profile,
      heading: heading,
      delivery: delivery,
      exclude: exclude,
      via: via,
      // Valhalla počítá alternativy jen pro trasu bez zastávek.
      alternates: via.isEmpty ? 2 : 0,
    );
    final noToll = safe(
      _request(
        from: from,
        to: to,
        profile: profile,
        heading: heading,
        delivery: delivery,
        exclude: exclude,
        via: via,
        extra: {'use_tolls': 0.0, 'exclude_tolls': true},
      ),
    );
    final shortest = safe(
      _request(
        from: from,
        to: to,
        profile: profile,
        heading: heading,
        delivery: delivery,
        exclude: exclude,
        via: via,
        extra: {'shortest': true},
      ),
    );
    final res = await Future.wait([main, noToll, shortest]);
    final out = <RouteOption>[];
    void add(String label, TruckRoute r) {
      final dup = out.any(
        (o) =>
            (o.route.lengthKm - r.lengthKm).abs() < r.lengthKm * 0.01 + 0.2 &&
            (o.route.timeSec - r.timeSec).abs() < r.timeSec * 0.02 + 30,
      );
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
    List<LatLng> via = const [],
  }) async {
    Future<Map<String, dynamic>> raw(
      LatLng a,
      LatLng b,
      List<LatLng> mid, {
      required bool exempt,
      double? head,
      int alt = 0,
    }) => _routeData(
      from: a,
      to: b,
      via: mid,
      profile: profile,
      heading: head,
      weightExempt: exempt,
      exclude: exclude,
      alternates: alt,
      extra: extra,
    );
    List<TruckRoute> parseAll(Map<String, dynamic> data) => [
      parseTrip(data['trip'] as Map<String, dynamic>),
      for (final a in (data['alternates'] as List? ?? const []))
        parseTrip((a as Map)['trip'] as Map<String, dynamic>),
    ];
    if (!delivery) return parseAll(await raw(from, to, via, exempt: false, head: heading, alt: alternates));

    // Zásobování: výjimka z hmotnostních zákazů („mimo dopravní obsluhu“) platí jen v obci vykládky
    // (např. Teplice), ne pro tranzit (zóna 12 t v Praze). Každá etapa: s plnou hmotností k vjezdu
    // do obce cíle, odtud s výjimkou.
    const d = Distance();
    final pts = [from, ...via, to];
    final legCount = pts.length - 1;
    final fullLegs = <Map<String, dynamic>>[]; // etapy s plnou hmotností (do vjezdu do obce cíle)
    final exemptWhole = <int>{}; // etapy celé s výjimkou (celé v obci cíle / jinak nelze)
    List<dynamic> alternatesData = const [];
    for (var k = 0; k < legCount; k++) {
      final a = pts[k], b = pts[k + 1];
      final head = k == 0 ? heading : null;
      final alt = legCount == 1 ? alternates : 0;
      Map<String, dynamic>? leg;
      try {
        final ex = parseTrip(
          (await raw(a, b, const [], exempt: true, head: head))['trip'] as Map<String, dynamic>,
        );
        final entry = await _townEntry(ex);
        if (entry == null) {
          // Celá etapa vede obcí vykládky.
          leg = await raw(a, b, const [], exempt: true, head: head);
          exemptWhole.add(k);
        } else {
          leg = await _reachable(raw, a, entry, head, alt);
        }
      } catch (_) {}
      // Obec nejde zjistit / vjezd není dosažitelný: s plnou hmotností co nejblíž cíli.
      leg ??= await _reachable(raw, a, b, head, alt) ?? await _closestReachable(raw, a, b, head);
      if (leg == null) {
        leg = await raw(a, b, const [], exempt: true, head: head);
        exemptWhole.add(k);
      }
      if (legCount == 1) alternatesData = (leg['alternates'] as List?) ?? const [];
      fullLegs.add(leg);
    }

    // Výjezd ze zóny u startu (start přichycen jinam) a dojezd od vjezdu do obce k cíli – s výjimkou.
    final pre = <int, Map<String, dynamic>>{}, post = <int, Map<String, dynamic>>{};
    for (var k = 0; k < legCount; k++) {
      if (exemptWhole.contains(k)) continue;
      final legs = ((fullLegs[k]['trip'] as Map)['legs'] as List);
      final shape = decodePolyline6((legs.first as Map)['shape'] as String);
      if (shape.length < 2) continue;
      try {
        if (d(pts[k], shape.first) > 150) {
          pre[k] = await raw(pts[k], shape.first, const [], exempt: true, head: k == 0 ? heading : null);
        }
        final end = decodePolyline6((legs.last as Map)['shape'] as String).last;
        if (d(end, pts[k + 1]) > 150) post[k] = await raw(end, pts[k + 1], const [], exempt: true);
      } catch (_) {}
    }

    Map<String, dynamic> stitch(List<Map<String, dynamic>> legTrips) {
      final out = <Map<String, dynamic>>[];
      var length = 0.0, time = 0.0, exemptKm = 0.0;
      var toll = false, highway = false;
      for (var k = 0; k < legTrips.length; k++) {
        final parts = <(Map<String, dynamic>, bool)>[
          if (pre[k] case final p?)
            (((p['trip'] as Map)['legs'] as List).first as Map<String, dynamic>, true),
          for (final l in (legTrips[k]['legs'] as List)) (l as Map<String, dynamic>, exemptWhole.contains(k)),
          if (post[k] case final p?)
            (((p['trip'] as Map)['legs'] as List).first as Map<String, dynamic>, true),
        ];
        for (var i = 0; i < parts.length; i++) {
          final (leg, exempt) = parts[i];
          final ms = [...(leg['maneuvers'] as List)];
          // Napojení částí: bez „Dorazili jste“ / „Vyjeďte“ uprostřed etapy.
          if (i < parts.length - 1 && ms.length > 1) ms.removeLast();
          if (i > 0 && ms.length > 1) ms.removeAt(0);
          out.add({...leg, 'maneuvers': ms});
          final sm = (leg['summary'] as Map?) ?? const {};
          final len = (sm['length'] as num?)?.toDouble() ?? 0;
          length += len;
          time += (sm['time'] as num?)?.toDouble() ?? 0;
          if (exempt) exemptKm += len;
          toll |= sm['has_toll'] == true;
          highway |= sm['has_highway'] == true;
        }
      }
      return {
        ...legTrips.first,
        'legs': out,
        'summary': {
          ...?(legTrips.first['summary'] as Map?)?.cast<String, dynamic>(),
          'length': length,
          'time': time,
          'has_toll': toll,
          'has_highway': highway,
        },
        '_exemptKm': exemptKm,
      };
    }

    TruckRoute build(List<Map<String, dynamic>> legTrips) {
      final st = stitch(legTrips);
      return parseTrip(st)..deliveryKm = (st['_exemptKm'] as num).toDouble();
    }

    final mainTrips = [for (final l in fullLegs) l['trip'] as Map<String, dynamic>];
    return [
      build(mainTrips),
      for (final a in alternatesData) build([(a as Map)['trip'] as Map<String, dynamic>]),
    ];
  }

  /// Trasa s plnou hmotností z [a] do [b], jen pokud opravdu dojede k [b] (ne k přichycenému bodu jinde).
  static Future<Map<String, dynamic>?> _reachable(
    Future<Map<String, dynamic>> Function(
      LatLng,
      LatLng,
      List<LatLng>, {
      required bool exempt,
      double? head,
      int alt,
    })
    raw,
    LatLng a,
    LatLng b,
    double? head,
    int alt,
  ) async {
    try {
      final r = await raw(a, b, const [], exempt: false, head: head, alt: alt);
      final legs = ((r['trip'] as Map)['legs'] as List);
      final end = decodePolyline6((legs.last as Map)['shape'] as String).last;
      return const Distance()(end, b) < 150 ? r : null;
    } catch (_) {
      return null;
    }
  }

  /// Na trase s výjimkou najde místo nejblíž cíli, kam kamion s plnou hmotností dojede.
  static Future<Map<String, dynamic>?> _closestReachable(
    Future<Map<String, dynamic>> Function(
      LatLng,
      LatLng,
      List<LatLng>, {
      required bool exempt,
      double? head,
      int alt,
    })
    raw,
    LatLng a,
    LatLng b,
    double? head,
  ) async {
    try {
      final ex = parseTrip(
        (await raw(a, b, const [], exempt: true, head: head))['trip'] as Map<String, dynamic>,
      );
      final cum = ex.cumulative;
      LatLng at(double back) {
        final i = cum.indexWhere((c) => c >= cum.last - back);
        return ex.shape[i < 0 ? 0 : i];
      }

      Map<String, dynamic>? best;
      double? okBack, failBack = 0;
      for (var back = 500.0; back < cum.last * 0.95; back *= 2) {
        final r = await _reachable(raw, a, at(back), head, 0);
        if (r != null) {
          best = r;
          okBack = back;
          break;
        }
        failBack = back;
      }
      for (var i = 0; okBack != null && failBack != null && i < 3; i++) {
        final mid = (okBack + failBack) / 2;
        final r = await _reachable(raw, a, at(mid), head, 0);
        if (r != null) {
          best = r;
          okBack = mid;
        } else {
          failBack = mid;
        }
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  /// Zapamatovaný vjezd do obce cíle (klíč = cíl) – přepočet během jízdy ho nehledá znovu.
  static final _entryCache = <String, (String, LatLng?)>{};

  /// Bod na trase [r], kde trasa vjíždí do obce cíle (null = celá trasa vede obcí cíle).
  /// Hází výjimku, když obec nejde zjistit.
  static final _entryInflight = <String, Future<LatLng?>>{};

  static Future<LatLng?> _townEntry(TruckRoute r) {
    final dest = r.shape.last;
    // Varianty trasy (nejrychlejší / bez mýta / nejkratší) se počítají souběžně → hledat jednou.
    final key =
        '${dest.latitude.toStringAsFixed(4)},${dest.longitude.toStringAsFixed(4)}|'
        '${r.shape.first.latitude.toStringAsFixed(3)},${r.shape.first.longitude.toStringAsFixed(3)}';
    return _entryInflight.putIfAbsent(
      key,
      () => _findTownEntry(r).whenComplete(() => _entryInflight.remove(key)),
    );
  }

  static Future<LatLng?> _findTownEntry(TruckRoute r) async {
    const d = Distance();
    final dest = r.shape.last, start = r.shape.first;
    final key = '${dest.latitude.toStringAsFixed(4)},${dest.longitude.toStringAsFixed(4)}';
    final towns = TownLookup();
    final cached = _entryCache[key];
    if (cached != null) {
      // Už jsme v obci cíle → celá zbývající cesta s výjimkou; jinak dřív nalezený vjezd.
      final (town, entry) = cached;
      if (entry == null || await towns.at(start) == town) return null;
      if (d(start, dest) > d(entry, dest)) return entry;
    }
    final cum = r.cumulative;
    LatLng at(double back) {
      final i = cum.indexWhere((c) => c >= cum.last - back);
      return r.shape[i < 0 ? 0 : i];
    }

    // Obec cíle a obce bodů 0,4 / 0,8 / 1,6 … km před cílem – vše najednou.
    final backs = [for (var b = 400.0; b < cum.last; b *= 2) b];
    final res = await Future.wait([towns.at(dest), towns.at(start), for (final b in backs) towns.at(at(b))]);
    final town = res[0];
    if (town == null) throw StateError('obec cíle neznámá');
    double inside = 0, outside = cum.last;
    var found = false;
    for (var i = 0; i < backs.length; i++) {
      if (res[i + 2] != town) {
        outside = backs[i];
        found = true;
        break;
      }
      inside = backs[i];
    }
    if (!found && res[1] == town) {
      _entryCache[key] = (town, null);
      return null;
    }
    // Zpřesnit hranici obce (~150 m).
    for (var i = 0; i < 5 && outside - inside > 150; i++) {
      final mid = (inside + outside) / 2;
      if (await towns.at(at(mid)) == town) {
        inside = mid;
      } else {
        outside = mid;
      }
    }
    final entry = at(inside);
    _entryCache[key] = (town, entry);
    return entry;
  }

  Future<Map<String, dynamic>> _routeData({
    required LatLng from,
    required LatLng to,
    required TruckProfile profile,
    double? heading,
    bool weightExempt = false,
    List<LatLng> exclude = const [],
    int alternates = 0,
    Map<String, dynamic> extra = const {},
    List<LatLng> via = const [],
  }) async {
    final origin = <String, dynamic>{'lat': from.latitude, 'lon': from.longitude};
    if (heading != null && heading >= 0) {
      origin['heading'] = heading.round();
      origin['heading_tolerance'] = 45;
    }
    final body = {
      'locations': [
        origin,
        for (final v in via) {'lat': v.latitude, 'lon': v.longitude, 'type': 'break'},
        {'lat': to.latitude, 'lon': to.longitude},
      ],
      'costing': 'truck',
      'costing_options': {
        'truck': {...profile.toValhallaCosting(delivery: weightExempt), ...extra},
      },
      if (alternates > 0) 'alternates': alternates,
      if (exclude.isNotEmpty)
        'exclude_locations': [
          for (final p in exclude) {'lat': p.latitude, 'lon': p.longitude},
        ],
      'language': 'cs-CZ',
      'units': 'kilometers',
      'directions_options': {'units': 'kilometers', 'language': 'cs-CZ'},
    };
    return _call('route', body);
  }

  /// Dotaz na Valhallu: v telefonu (stažený balík ČR), jinak na server.
  /// Bez internetu se použije telefon, i když je nastaven server.
  Future<Map<String, dynamic>> _call(String action, Map<String, dynamic> body) async {
    final device = OfflineRouting.instance;
    Object? deviceError;
    if (device.ready && device.preferDevice) {
      try {
        return await device.call(action, body);
      } catch (e) {
        deviceError = e; // např. místo mimo ČR → zkusit server
      }
    }
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/$action');
    final http.Response res;
    try {
      res = await http
          .post(uri, headers: uaHeaders({'Content-Type': 'application/json'}), body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      if (device.ready && deviceError == null) {
        try {
          return await device.call(action, body);
        } catch (e2) {
          throw RoutingException('Trasu nelze vypočítat: $e2');
        }
      }
      throw RoutingException(
        deviceError != null ? 'Trasu nelze vypočítat: $deviceError' : 'Server tras není dostupný: $e',
        network: deviceError == null,
      );
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw RoutingException('Trasu nelze vypočítat: ${data['error'] ?? res.statusCode}');
    }
    return data;
  }

  /// Doby jízdy kamionem mezi všemi body (s) – pro seřazení zastávek.
  Future<List<List<double>>> matrix(List<LatLng> pts, TruckProfile profile, {bool delivery = false}) async {
    final locs = [
      for (final p in pts) {'lat': p.latitude, 'lon': p.longitude},
    ];
    final data = await _call('sources_to_targets', {
      'sources': locs,
      'targets': locs,
      'costing': 'truck',
      'costing_options': {'truck': profile.toValhallaCosting(delivery: delivery)},
    });
    final rows = data['sources_to_targets'] as List;
    const d = Distance();
    return [
      for (var i = 0; i < pts.length; i++)
        [
          for (var j = 0; j < pts.length; j++)
            // Nedosažitelné → velká penalizace podle vzdušné vzdálenosti.
            ((((rows[i] as List)[j] as Map)['time']) as num?)?.toDouble() ?? d(pts[i], pts[j]) * 10,
        ],
    ];
  }

  /// Doplní k trase rychlostní limity a názvy silnic (Valhalla trace_attributes).
  Future<void> loadEdgeAttributes(TruckRoute route, {int maxSpeedKmh = 80}) async {
    // Každá etapa (mezi zastávkami) zvlášť – přes zastávku Valhalla trasu „neprojde“.
    final legs = route.legShapes.isNotEmpty
        ? route.legShapes
        : [if (route.encodedShape != null) (route.encodedShape!, 0)];
    final legEdges = <(List, int)>[];
    for (final (enc, offset) in legs) {
      final body = {
        'encoded_polyline': enc,
        'costing': 'truck',
        'shape_match': 'edge_walk',
        'filters': {
          'attributes': [
            'edge.speed_limit',
            'edge.speed',
            'edge.length',
            'edge.names',
            'edge.begin_shape_index',
            'edge.end_shape_index',
            'edge.way_id',
            'edge.road_class',
            'edge.use',
            'edge.begin_heading',
            'edge.end_heading',
            'node.intersecting_edge.road_class',
            'node.intersecting_edge.begin_heading',
            'node.intersecting_edge.driveability',
            'node.intersecting_edge.use',
          ],
          'action': 'include',
        },
      };
      final Map<String, dynamic> data;
      try {
        data = await _call('trace_attributes', body);
      } catch (_) {
        continue;
      }
      legEdges.add(((data['edges'] as List?) ?? const [], offset));
    }
    if (legEdges.isEmpty) return;
    final n = math.max(0, route.shape.length - 1);
    final limits = List<int?>.filled(n, null);
    final names = List<String?>.filled(n, null);
    final edges = <EdgeAttr>[];
    final cum = route.cumulative;
    final segTime = List<double>.filled(n, 0);
    var edgeSec = 0.0; // Valhallou odhadnutý čas samotné jízdy po hranách
    var covered = 0.0;
    for (final (list, off) in legEdges) {
      for (final e in list) {
        final b = ((e['begin_shape_index'] as num?)?.toInt() ?? 0) + off;
        // Čas na hraně rychlostí kamionu: min(rychlost silnice, omezovač).
        final v = (e['speed'] as num?)?.toDouble();
        final lenM = ((e['length'] as num?)?.toDouble() ?? 0) * 1000;
        final eEnd = math.min(n, ((e['end_shape_index'] as num?)?.toInt() ?? 0) + off);
        if (v != null && v > 0 && lenM > 0 && eEnd > b) {
          edgeSec += lenM / (v / 3.6);
          covered += lenM;
          final sec = lenM / (math.min(v, maxSpeedKmh.toDouble()) / 3.6);
          final span = cum[eEnd] - cum[b];
          for (var i = b; i < eEnd; i++) {
            segTime[i] = span > 0 ? sec * (cum[i + 1] - cum[i]) / span : sec / (eEnd - b);
          }
        }
        edges.add(
          EdgeAttr(
            begin: b,
            end: ((e['end_shape_index'] as num?)?.toInt() ?? 0) + off,
            wayId: (e['way_id'] as num?)?.toInt(),
            roadClass: e['road_class'] as String?,
            use: e['use'] as String?,
            names: ((e['names'] as List?) ?? const []).map((x) => '$x').toList(),
            beginHeading: (e['begin_heading'] as num?)?.toInt(),
            endHeading: (e['end_heading'] as num?)?.toInt(),
            intersecting: [
              for (final ie in ((e['end_node'] as Map?)?['intersecting_edges'] as List? ?? const []))
                Map<String, dynamic>.from(ie as Map),
            ],
          ),
        );
        final en = math.min(n, ((e['end_shape_index'] as num?)?.toInt() ?? 0) + off);
        // Číslo, nebo „unlimited“ (německé dálnice) → limit dá jen max. rychlost kamionu.
        final sl = e['speed_limit'];
        final lim = sl is num ? sl.toInt() : (sl == 'unlimited' ? 199 : null);
        final nm = (e['names'] as List?)?.isNotEmpty == true ? (e['names'] as List).first as String : null;
        for (var i = b; i < en; i++) {
          limits[i] = (lim != null && lim > 0 && lim < 200) ? lim : null;
          names[i] = nm;
        }
      }
    }
    route.speedLimits = limits;
    route.roadNames = names;
    route.edges = edges;
    // Jen když atributy pokryly skoro celou trasu, jinak zůstane odhad Valhally.
    if (covered > route.lengthKm * 1000 * 0.9) {
      final t = List<double>.filled(n + 1, 0);
      for (var i = 0; i < n; i++) {
        t[i + 1] = t[i] + segTime[i];
      }
      route.truckTime = t;
      route.truckOverheadSec = math.max(0, route.timeSec - edgeSec);
    }
  }

  static TruckRoute parseTrip(Map<String, dynamic> trip) {
    final legShapes = <(String, int)>[];
    final shape = <LatLng>[];
    final maneuvers = <Maneuver>[];
    for (final leg in (trip['legs'] as List)) {
      final legMap = leg as Map<String, dynamic>;
      // Poslední bod předchozí etapy = první bod další, nezdvojovat.
      final offset = shape.isEmpty ? 0 : shape.length - 1;
      legShapes.add((legMap['shape'] as String, offset));
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
      encodedShape: legShapes.length == 1 ? legShapes.first.$1 : null,
      legShapes: legShapes,
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
