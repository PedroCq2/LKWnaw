import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'delivery_shortcut.dart';
import 'http_headers.dart';
import 'offline_search.dart';
import 'offline_routing.dart';
import 'restrictions.dart';
import 'route_economy.dart';
import 'town.dart';

import '../models/route.dart';
import '../models/truck_profile.dart';

/// Jeden dotaz na trasu (s plnou hmotností, nebo s výjimkou pro zásobování).
typedef RawRoute =
    Future<Map<String, dynamic>> Function(
      LatLng a,
      LatLng b,
      List<LatLng> via, {
      required bool exempt,
      double? head,
      int alt,
    });

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
    Map<String, dynamic> extra = const {},
  }) async => (await _request(
    via: via,
    from: from,
    to: to,
    profile: profile,
    heading: heading,
    delivery: delivery,
    exclude: exclude,
    extra: extra,
  )).first;

  /// Otočení kamionu po rozumných silnicích (kruhový objezd, velká křižovatka), ne objížďkou
  /// přes obytné ulice a obytnou zónu.
  static const calmTurn = {'low_class_penalty': 600, 'service_penalty': 600, 'use_living_streets': 0.0};

  /// Vede trasa z [from] nejdřív zpátky (otočení, nebo smyčka, která se do 4 km vrátí k místu startu)?
  static bool turnsBack(TruckRoute r, LatLng from) {
    final cum = r.cumulative;
    for (final m in r.maneuvers) {
      final i = m.beginShapeIndex.clamp(0, r.shape.length - 1);
      if (cum[i] > 3000) break;
      if (m.type == 12 || m.type == 13) return true;
    }
    const d = Distance();
    for (var i = 0; i < r.shape.length; i++) {
      if (cum[i] < 150) continue;
      if (cum[i] > 4000) break;
      if (d(r.shape[i], from) < 40) return true;
    }
    return false;
  }

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
    // Zásobování: výpočet je náročnější (obec vykládky) → jen hlavní trasa a její alternativy.
    if (delivery) {
      final out = <RouteOption>[];
      for (final (i, r) in (await main).indexed) {
        out.add(RouteOption(i == 0 ? 'Nejrychlejší' : 'Alternativa', r));
      }
      return _rank(out, profile);
    }
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
    return _rank(out, profile);
  }

  /// Pořadí variant: první je ta nejlepší pro kamion (ekonomická doba – třídy silnic, odbočky,
  /// vesnice), pokud není o víc než 15 % pomalejší než nejrychlejší. Nejrychlejší zůstává v nabídce.
  /// (Veltěže → Čertousy: Louny – D7 – I/16 místo III. tříd přes Slavětín a Velvary.)
  Future<List<RouteOption>> _rank(List<RouteOption> opts, TruckProfile profile) async {
    if (opts.length < 2) return opts;
    final scores = await Future.wait([for (final o in opts) _economy(o.route, profile)]);
    var best = 0;
    for (var i = 1; i < opts.length; i++) {
      if (scores[i] < scores[best]) best = i;
    }
    if (best == 0 || !scores[best].isFinite) return opts;
    if (opts[best].route.timeSec > opts.first.route.timeSec * 1.15) return opts;
    return [
      RouteOption('Doporučená', opts[best].route),
      for (final (i, o) in opts.indexed)
        if (i != best) o,
    ];
  }

  Future<double> _economy(TruckRoute r, TruckProfile profile) async {
    try {
      final legs = r.legShapes.isNotEmpty
          ? [for (final (enc, _) in r.legShapes) enc]
          : [if (r.encodedShape != null) r.encodedShape!];
      final edges = <EcoEdge>[];
      for (final enc in legs) {
        final data = await _call('trace_attributes', {
          'encoded_polyline': enc,
          'costing': 'truck',
          'costing_options': {'truck': profile.toValhallaCosting()},
          'shape_match': 'edge_walk',
          'filters': {
            'attributes': ['edge.road_class', 'edge.length', 'edge.speed'],
            'action': 'include',
          },
        });
        for (final e in (data['edges'] as List? ?? const [])) {
          edges.add((
            roadClass: e['road_class'] as String?,
            lengthM: ((e['length'] as num?)?.toDouble() ?? 0) * 1000,
            speedKmh: (e['speed'] as num?)?.toDouble() ?? 0,
          ));
        }
      }
      if (edges.isEmpty) return double.infinity;
      return economyMinutes(
        edges,
        countTurns(r.maneuvers.map((m) => m.type)),
        maxSpeedKmh: profile.maxSpeed.toDouble(),
      );
    } catch (_) {
      return double.infinity;
    }
  }

  /// Kamion se neotáčí: obsahuje-li trasa „Otočte se“, zkusit ji znovu s vyloučeným místem otočení
  /// a vzít variantu bez otáčení, pokud není výrazně delší.
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
    List<TruckRoute> r;
    try {
      r = await _requestOnce(
        from: from,
        to: to,
        profile: profile,
        heading: heading,
        delivery: delivery,
        exclude: exclude,
        alternates: alternates,
        extra: extra,
        via: via,
      );
    } on RoutingException catch (e) {
      // Cíl je pro kamion fyzicky nedostupný (výška, šířka, délka na příjezdu): navést co nejblíž.
      if (e.network || via.isNotEmpty) rethrow;
      final near = await _nearestReachable(from, to, profile, heading, delivery, exclude, extra);
      if (near == null) rethrow;
      r = [near];
    }
    final first = r.first;
    final uturns = [
      for (var i = 0; i < first.maneuvers.length - 1; i++)
        if (first.maneuvers[i].type == 12 || first.maneuvers[i].type == 13)
          first.shape[first.maneuvers[i].beginShapeIndex.clamp(0, first.shape.length - 1)],
    ];
    if (uturns.isEmpty) return r;
    try {
      final r2 = await _requestOnce(
        from: from,
        to: to,
        profile: profile,
        heading: heading,
        delivery: delivery,
        exclude: [...exclude, ...uturns],
        alternates: alternates,
        extra: extra,
        via: via,
      );
      final u2 = r2.first.maneuvers.where((m) => m.type == 12 || m.type == 13).length;
      if (u2 < uturns.length && r2.first.lengthKm < first.lengthKm * 1.5 + 2) return r2;
    } catch (_) {}
    return r;
  }

  /// Trasa co nejblíž k cíli, kam vozidlo projede: trasa pro malé auto do cíle, a na ní poslední bod,
  /// kam dojede kamion. [TruckRoute.unreachableM] = kolik zbývá vzdušně do cíle.
  Future<TruckRoute?> _nearestReachable(
    LatLng from,
    LatLng to,
    TruckProfile profile,
    double? heading,
    bool delivery,
    List<LatLng> exclude,
    Map<String, dynamic> extra,
  ) async {
    try {
      final small = TruckProfile(height: 2.5, width: 2.0, length: 7, weight: 3.5, axleLoad: 2, axleCount: 2);
      final ref = parseTrip(
        (await _routeData(
              from: from,
              to: to,
              profile: small,
              heading: heading,
              exclude: exclude,
              extra: extra,
            ))['trip']
            as Map<String, dynamic>,
      );
      final cum = ref.cumulative;
      LatLng at(double back) {
        final i = cum.indexWhere((c) => c >= cum.last - back);
        return ref.shape[i < 0 ? 0 : i];
      }

      Future<TruckRoute?> probe(double back) async {
        final m = at(back);
        try {
          final t = parseTrip(
            (await _routeData(
                  from: from,
                  to: m,
                  profile: profile,
                  heading: heading,
                  weightExempt: delivery,
                  exclude: exclude,
                  extra: extra,
                ))['trip']
                as Map<String, dynamic>,
          );
          return const Distance()(t.shape.last, m) < 150 ? t : null;
        } catch (_) {
          return null;
        }
      }

      TruckRoute? best;
      double? okBack, failBack = 0;
      for (var back = 150.0; back < cum.last * 0.95; back *= 2) {
        final t = await probe(back);
        if (t != null) {
          best = t;
          okBack = back;
          break;
        }
        failBack = back;
      }
      for (var i = 0; okBack != null && failBack != null && i < 3; i++) {
        final mid = (okBack + failBack) / 2;
        final t = await probe(mid);
        if (t != null) {
          best = t;
          okBack = mid;
        } else {
          failBack = mid;
        }
      }
      if (best == null) return null;
      best.unreachableM = const Distance()(best.shape.last, to);
      if (delivery) best.deliveryKm = 0;
      return best;
    } catch (_) {
      return null;
    }
  }

  Future<List<TruckRoute>> _requestOnce({
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
    DateTime? deadline; // zásobování: časový limit, ať výpočet nikdy neviset
    Future<Map<String, dynamic>> raw(
      LatLng a,
      LatLng b,
      List<LatLng> mid, {
      required bool exempt,
      double? head,
      int alt = 0,
    }) async {
      if (deadline != null && DateTime.now().isAfter(deadline)) throw TimeoutException('zásobování');
      return _routeData(
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
    }

    List<TruckRoute> parseAll(Map<String, dynamic> data) => [
      parseTrip(data['trip'] as Map<String, dynamic>),
      for (final a in (data['alternates'] as List? ?? const []))
        parseTrip((a as Map)['trip'] as Map<String, dynamic>),
    ];
    if (!delivery) return parseAll(await raw(from, to, via, exempt: false, head: heading, alt: alternates));

    Future<List<TruckRoute>> deliveryRoutes() async {
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
        // Menší zlo: 1) s plnou hmotností až do cíle (žádná výjimka) – pokud to není oklika, jinak
        // s plnou hmotností k vjezdu do obce vykládky a dál s výjimkou, 2) s plnou hmotností co nejblíž
        // cíli a s výjimkou jen nezbytný kousek, 3) teprve pak výjimka od vjezdu do obce vykládky.
        var leg = await _reachable(raw, a, b, head, alt);
        if (leg != null) {
          final better = await shorterViaTown(raw, a, b, head, alt, leg);
          if (better != null) {
            leg = better.leg;
            if (better.whole) exemptWhole.add(k);
          }
        }
        leg ??= await _closestReachable(raw, a, b, head);
        if (leg == null) {
          try {
            final ex = parseTrip(
              (await raw(a, b, const [], exempt: true, head: head))['trip'] as Map<String, dynamic>,
            );
            final entry = await _townEntry(ex).timeout(const Duration(seconds: 8));
            if (entry != null) leg = await _reachable(raw, a, entry, head, alt);
          } catch (_) {}
        }
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
            // Výjezd ze zóny u startu, pak dál s plnou hmotností – navazující směrem, bez otáčení.
            final p = await raw(pts[k], shape.first, const [], exempt: true, head: k == 0 ? heading : null);
            pre[k] = p;
            final pShape = decodePolyline6(
              (((p['trip'] as Map)['legs'] as List).last as Map)['shape'] as String,
            );
            final lastShape = decodePolyline6((legs.last as Map)['shape'] as String);
            try {
              fullLegs[k] = await raw(
                shape.first,
                lastShape.last,
                const [],
                exempt: false,
                head: _endHeading(pShape),
              );
            } catch (_) {}
          }
          final legsNow = ((fullLegs[k]['trip'] as Map)['legs'] as List);
          final endShape = decodePolyline6((legsNow.last as Map)['shape'] as String);
          if (d(endShape.last, pts[k + 1]) > 150) {
            // Dojezd s výjimkou navazuje směrem jízdy – žádné „otočte se“ na spoji.
            post[k] = await raw(
              endShape.last,
              pts[k + 1],
              const [],
              exempt: true,
              head: _endHeading(endShape),
            );
          }
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
            for (final l in (legTrips[k]['legs'] as List))
              (l as Map<String, dynamic>, exemptWhole.contains(k)),
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
      // Jediný cíl: dojezd v obci vykládky kratší cestou pro dopravní obsluhu, když ji kamion smí.
      if (legCount == 1) {
        try {
          final st = stitch(mainTrips);
          final sc = await _deliveryShortcut(
            st,
            from,
            to,
            profile,
            heading,
          ).timeout(const Duration(seconds: 12));
          if (sc != null) {
            return [parseTrip(sc)..deliveryKm = (st['_exemptKm'] as num).toDouble()];
          }
        } catch (_) {}
      }
      return [
        build(mainTrips),
        for (final a in alternatesData) build([(a as Map)['trip'] as Map<String, dynamic>]),
      ];
    }

    // Bez nekonečného čekání: když hledání obce / dosažitelných míst trvá moc dlouho,
    // jednodušší výpočet – plná hmotnost a s výjimkou jen dojezd od přichyceného místa k cíli.
    deadline = DateTime.now().add(const Duration(seconds: 15));
    try {
      return await deliveryRoutes();
    } on TimeoutException {
      deadline = null;
    }
    const d = Distance();
    try {
      final full = await raw(from, to, via, exempt: false, head: heading);
      final r = parseAll(full);
      final end = r.first.shape.last;
      if (via.isNotEmpty || d(end, to) < 150) return r;
      final postTrip = (await raw(end, to, const [], exempt: true))['trip'] as Map<String, dynamic>;
      final postKm = ((postTrip['summary'] as Map)['length'] as num).toDouble();
      if (postKm < 15) {
        return [parseTrip(_joinTrips(full['trip'] as Map<String, dynamic>, postTrip))..deliveryKm = postKm];
      }
    } catch (_) {}
    final r = parseAll(await raw(from, to, via, exempt: true, head: heading));
    for (final x in r) {
      x.deliveryKm = x.lengthKm;
    }
    return r;
  }

  /// Zásobování: Valhalla nepustí kamion na ulici „jen dopravní obsluha“ (hgv=delivery), když cíl
  /// neleží přímo na ní – a vede ho oklikou (Teplice: Alejní → Čs. dobrovolců ke Kauflandu).
  /// Proto v obci vykládky zkusí krátkou trasu jako auto a ověří ji pro kamion (rozměry, náprava,
  /// zákaz vjezdu kamionů, žádné uličky). Vrací spojenou trasu, nebo null (původní zůstane).
  Future<Map<String, dynamic>?> _deliveryShortcut(
    Map<String, dynamic> trip,
    LatLng from,
    LatLng to,
    TruckProfile profile,
    double? heading,
  ) async {
    const d = Distance();
    final shape = [for (final l in trip['legs'] as List) ...decodePolyline6((l as Map)['shape'] as String)];
    if (shape.length < 2 || d(shape.last, to) > 150) return null;
    final cum = <double>[0];
    for (var i = 1; i < shape.length; i++) {
      cum.add(cum.last + d(shape[i - 1], shape[i]));
    }
    final total = cum.last;
    final towns = TownLookup();
    final town = await towns.at(to);
    if (town == null) return null;
    // Místo odbočení ze trasy kamionu: co nejdál před cílem, ale už v obci vykládky.
    int? xi;
    for (final back in const [3000.0, 2200.0, 1500.0, 900.0]) {
      if (back >= total) continue;
      final i = cum.lastIndexWhere((c) => total - c >= back);
      if (i > 0 && await towns.at(shape[i]) == town) {
        xi = i;
        break;
      }
    }
    if (xi == null && total < 3000 && await towns.at(shape.first) == town) xi = 0;
    if (xi == null) return null;
    final x = shape[xi];
    final truckTail = total - cum[xi];
    double? head;
    for (var j = xi + 1; j < shape.length; j++) {
      if (d(x, shape[j]) > 15) {
        final b = d.bearing(x, shape[j]);
        head = b < 0 ? b + 360 : b;
        break;
      }
    }
    if (xi == 0) head = heading;
    final car = await _call('route', {
      'locations': [
        {
          'lat': x.latitude,
          'lon': x.longitude,
          if (head != null) 'heading': head.round(),
          'heading_tolerance': 45,
        },
        {'lat': to.latitude, 'lon': to.longitude},
      ],
      'costing': 'auto',
      'costing_options': {
        'auto': {'use_living_streets': 0.0, 'service_penalty': 120, 'use_tracks': 0.0},
      },
      'language': 'cs-CZ',
      'units': 'kilometers',
      'directions_options': {'units': 'kilometers', 'language': 'cs-CZ'},
    });
    final carTrip = car['trip'] as Map<String, dynamic>;
    final carLen = ((carTrip['summary'] as Map)['length'] as num).toDouble() * 1000;
    // Jen když je zkratka opravdu znát.
    if (carLen > truckTail - 300 || carLen > truckTail * 0.75) return null;
    final carLeg = (carTrip['legs'] as List).first as Map;
    final carShape = decodePolyline6(carLeg['shape'] as String);
    if (d(carShape.last, to) > 150) return null;
    final tr = await _call('trace_attributes', {
      'encoded_polyline': carLeg['shape'],
      'costing': 'auto',
      'shape_match': 'edge_walk',
      'filters': {
        'attributes': ['edge.way_id', 'edge.road_class', 'edge.use', 'edge.length'],
        'action': 'include',
      },
    });
    final edges = <ShortcutEdge>[
      for (final e in (tr['edges'] as List? ?? const []))
        (
          wayId: (e['way_id'] as num?)?.toInt(),
          roadClass: e['road_class'] as String?,
          use: e['use'] as String?,
          lengthM: ((e['length'] as num?)?.toDouble() ?? 0) * 1000,
        ),
    ];
    if (edges.isEmpty) return null;
    final ids = {for (final e in edges) ?e.wayId};
    final tags = <int, Map<String, dynamic>>{};
    final off = OfflineSearch.instance;
    if (off.hasAccess) {
      var la0 = 90.0, la1 = -90.0, lo0 = 180.0, lo1 = -180.0;
      for (final p in carShape) {
        la0 = math.min(la0, p.latitude);
        la1 = math.max(la1, p.latitude);
        lo0 = math.min(lo0, p.longitude);
        lo1 = math.max(lo1, p.longitude);
      }
      for (final e in off.osmElements(la0 - 0.002, la1 + 0.002, lo0 - 0.003, lo1 + 0.003)) {
        final id = e['id'] as int;
        if (e['type'] == 'way' && ids.contains(id)) tags[id] = (e['tags'] as Map).cast<String, dynamic>();
      }
    } else {
      // Starší balík dat: štítky cest z Overpass; bez nich zkratku nepoužít.
      final els = await overpassQuery('[out:json][timeout:10];way(id:${ids.join(',')});out tags;');
      if (els == null) return null;
      for (final e in els) {
        tags[(e['id'] as num).toInt()] = Map<String, dynamic>.from((e['tags'] as Map?) ?? const {});
      }
    }
    if (shortcutProblem(edges, tags, profile) != null) return null;
    // Kamionem k místu odbočení (stejná trasa jako dosud), dál krátkou cestou.
    if (xi == 0) return carTrip;
    final headTrip =
        (await _routeData(from: from, to: x, profile: profile, heading: heading))['trip']
            as Map<String, dynamic>;
    final headEnd = decodePolyline6(((headTrip['legs'] as List).last as Map)['shape'] as String).last;
    if (d(headEnd, x) > 60) return null;
    return _joinTrips(headTrip, carTrip);
  }

  /// Směr jízdy na konci tvaru trasy (stupně), pro navázání další části bez otáčení.
  static double? _endHeading(List<LatLng> shape) {
    if (shape.length < 2) return null;
    const d = Distance();
    // Poslední úsek delší než pár metrů (tvar končí často mikroskopickým kouskem).
    final last = shape.last;
    for (var j = shape.length - 2; j >= 0; j--) {
      if (d(shape[j], last) > 15) {
        final b = d.bearing(shape[j], last);
        return b < 0 ? b + 360 : b;
      }
    }
    return null;
  }

  /// Spojí dvě trasy za sebou do jedné (bez pokynu „Dorazili jste“ / „Vyjeďte“ na spoji).
  static Map<String, dynamic> _joinTrips(Map<String, dynamic> a, Map<String, dynamic> b) {
    final la = [...(a['legs'] as List)], lb = [...(b['legs'] as List)];
    Map<String, dynamic> trim(Object leg, {bool last = false, bool first = false}) {
      final m = Map<String, dynamic>.from(leg as Map);
      final ms = [...(m['maneuvers'] as List)];
      if (last && ms.length > 1) ms.removeLast();
      if (first && ms.length > 1) ms.removeAt(0);
      return {...m, 'maneuvers': ms};
    }

    la[la.length - 1] = trim(la.last, last: true);
    lb[0] = trim(lb.first, first: true);
    final sa = (a['summary'] as Map).cast<String, dynamic>(),
        sb = (b['summary'] as Map).cast<String, dynamic>();
    return {
      ...a,
      'legs': [...la, ...lb],
      'summary': {
        ...sa,
        'length': (sa['length'] as num) + (sb['length'] as num),
        'time': (sa['time'] as num) + (sb['time'] as num),
        'has_toll': sa['has_toll'] == true || sb['has_toll'] == true,
        'has_highway': sa['has_highway'] == true || sb['has_highway'] == true,
      },
    };
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

  /// Zásobování: s plnou hmotností do cíle jde dojet, ale oklikou? Výjimka „mimo dopravní obsluhu“
  /// platí v obci vykládky – když je s plnou hmotností jen k vjezdu do obce a dál s výjimkou výrazně
  /// rychlejší (SAPA Praha-Libuš: 160 m „3,5 t“ v Cholupicích místo okliky přes Vestec), vrátí etapu
  /// k vjezdu (dojezd s výjimkou se doplní potom). `whole` = celá trasa vede obcí cíle → celá
  /// s výjimkou. null = zůstává plná hmotnost až do cíle.
  @visibleForTesting
  static Future<({Map<String, dynamic> leg, bool whole})?> shorterViaTown(
    RawRoute raw,
    LatLng a,
    LatLng b,
    double? head,
    int alt,
    Map<String, dynamic> full, {
    Future<LatLng?> Function(TruckRoute) entryOf = _townEntry,
  }) async {
    double time(Map<String, dynamic> r) => (((r['trip'] as Map)['summary'] as Map)['time'] as num).toDouble();
    // Výjimku jen když se vyplatí: o víc než 10 % a 2 minuty rychlejší.
    bool muchFaster(double t) => time(full) > t * 1.1 + 120;
    try {
      final exData = await raw(a, b, const [], exempt: true, head: head, alt: alt);
      if (!muchFaster(time(exData))) return null;
      final ex = parseTrip(exData['trip'] as Map<String, dynamic>);
      final entry = await entryOf(ex).timeout(const Duration(seconds: 8));
      if (entry == null) return (leg: exData, whole: true);
      final toEntry = await _reachable(raw, a, entry, head, alt);
      if (toEntry == null) return null;
      // Zbytek od vjezdu do obce s výjimkou: poměrná část času trasy s výjimkou.
      const d = Distance();
      var i = 0;
      for (var j = 1; j < ex.shape.length; j++) {
        if (d(ex.shape[j], entry) < d(ex.shape[i], entry)) i = j;
      }
      final cum = ex.cumulative;
      final rest = cum.last <= 0 ? 0.0 : time(exData) * (cum.last - cum[i]) / cum.last;
      return muchFaster(time(toEntry) + rest) ? (leg: toEntry, whole: false) : null;
    } catch (_) {
      return null;
    }
  }

  /// Na trase s výjimkou najde místo nejblíž cíli, kam kamion s plnou hmotností dojede.
  /// Zapamatované „nejbližší dosažitelné místo“ u cíle – přepočet za jízdy ho nehledá znovu.
  static final _closestCache = <String, LatLng>{};

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
    final key = '${b.latitude.toStringAsFixed(4)},${b.longitude.toStringAsFixed(4)}';
    final known = _closestCache[key];
    if (known != null) {
      final r = await _reachable(raw, a, known, head, 0);
      if (r != null) return r;
    }
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
          _closestCache[key] = at(back);
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
          _closestCache[key] = at(mid);
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
      // Pozor: callback nesmí vrátit tuto future – čekala by sama na sebe.
      () => _findTownEntry(r).whenComplete(() {
        _entryInflight.remove(key);
      }),
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
    if (town == null || town.isEmpty) throw StateError('obec cíle neznámá');
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
