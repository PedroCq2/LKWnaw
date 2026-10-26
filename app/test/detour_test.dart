import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truck_nav/models/route.dart';
import 'package:truck_nav/models/truck_profile.dart';
import 'package:truck_nav/services/detour.dart';
import 'package:truck_nav/services/ignored_restrictions.dart';
import 'package:truck_nav/services/offline_search.dart';
import 'package:truck_nav/services/valhalla.dart';

TruckRoute line(List<LatLng> pts, {double km = 0, double sec = 0, List<Maneuver> ms = const []}) =>
    TruckRoute(shape: pts, maneuvers: ms, lengthKm: km, timeSec: sec, hasToll: false, hasHighway: false);

Maneuver man(int type, int b, int e) => Maneuver(
  type: type,
  instruction: '$type',
  streetNames: const [],
  beginShapeIndex: b,
  endShapeIndex: e,
  lengthKm: 0,
);

RouteWarning bridge12({LatLng point = const LatLng(50.127064, 14.621999), int? wayId = 12833262}) =>
    RouteWarning(
      type: WarningType.weight,
      value: 12,
      atMeters: 0,
      point: point,
      violates: true,
      onBridge: true,
      road: 'Ve Žlíbku',
      wayId: wayId,
    );

void main() {
  test('objížďka stojí za vysvětlení jen když je znát', () {
    // P3 Horní Počernice → Hradec: 122,9 km / 72 min oklikou, 108,7 km / 65 min přes most.
    expect(
      significantDetour(line(const [], km: 122.9, sec: 4320), line(const [], km: 108.7, sec: 3900)),
      isTrue,
    );
    // Pár set metrů ve městě – ne.
    expect(
      significantDetour(line(const [], km: 12.4, sec: 1500), line(const [], km: 11.9, sec: 1400)),
      isFalse,
    );
    // 3 km na 300 km trase (1 %) – ne.
    expect(
      significantDetour(line(const [], km: 300, sec: 14000), line(const [], km: 297, sec: 13800)),
      isFalse,
    );
  });

  test('úseky zkratky mimo trasu', () {
    // Trasa jede rovně na východ; zkratka uprostřed uhne 100 m na sever a vrátí se.
    final main = line(const [LatLng(50, 14.000), LatLng(50, 14.010), LatLng(50, 14.020), LatLng(50, 14.030)]);
    final ref = line(const [
      LatLng(50, 14.000),
      LatLng(50, 14.010),
      LatLng(50.0009, 14.013),
      LatLng(50.0009, 14.017),
      LatLng(50, 14.020),
      LatLng(50, 14.030),
    ]);
    final s = divergentSections(ref, main);
    expect(s, [(1, 4)]);
    // Souběžný jízdní pás 20 m vedle se počítá jako jiná cesta, ne jako „stejná trasa“.
    final parallel = line(const [LatLng(50.00018, 14.000), LatLng(50.00018, 14.030)]);
    expect(divergentSections(parallel, main), [(0, 1)]);
    // Stejná trasa – nic.
    expect(divergentSections(main, main), isEmpty);
    // Most přes trasu (Ve Žlíbku nad D10): bod nad dálnicí není „na trase“.
    final over = line(const [LatLng(49.999, 14.015), LatLng(50, 14.015), LatLng(50.001, 14.015)]);
    expect(divergentSections(over, main), [(0, 2)]);
  });

  test('bod a směr po trase', () {
    final r = line(const [LatLng(50, 14.000), LatLng(50, 14.010), LatLng(50.009, 14.010)]);
    final p = pointAlong(r, r.cumulative[1] / 2);
    expect(p.longitude, closeTo(14.005, 1e-6));
    expect(headingAlong(r, 100), closeTo(90, 1));
    expect(headingAlong(r, r.cumulative[1] + 100), closeTo(0, 1));
  });

  test('spojení tras bez „Dorazili jste“ uprostřed', () {
    final a = line(
      const [LatLng(50, 14.0), LatLng(50, 14.01), LatLng(50, 14.02)],
      km: 1.4,
      sec: 100,
      ms: [man(1, 0, 1), man(10, 1, 2), man(4, 2, 2)],
    );
    final b = line(
      const [LatLng(50, 14.02), LatLng(50.01, 14.02)],
      km: 1.1,
      sec: 80,
      ms: [man(1, 0, 1), man(4, 1, 1)],
    );
    final c = TruckRoute.concat([a, b]);
    expect(c.shape.length, 4);
    expect(c.lengthKm, closeTo(2.5, 1e-9));
    expect(c.timeSec, 180);
    expect([for (final m in c.maneuvers) m.type], [1, 10, 4]);
    expect(c.maneuvers.last.beginShapeIndex, 3);
  });

  test('omezení označené jako neplatné', () {
    final ig = IgnoredRestriction.of(bridge12());
    expect(ig.matches(bridge12()), isTrue);
    // Stejný most po aktualizaci dat (jiný první bod, stejná cesta v OSM).
    expect(ig.matches(bridge12(point: const LatLng(50.1276, 14.6217))), isTrue);
    // Jiný most 12 t o kus dál – ne.
    expect(ig.matches(bridge12(point: const LatLng(50.14, 14.63), wayId: 1)), isFalse);
    final back = IgnoredRestriction.fromJson(ig.toJson());
    expect(back.title, 'Most 12 t (Ve Žlíbku)');
    expect(back.matches(bridge12()), isTrue);
    expect(bridge12().title, 'most 12 t (Ve Žlíbku)');
    expect(roadLabel('16'), 'silnice 16');
    final d = RouteDetour(extraKm: 14.2, extraMin: 7.2, causes: [bridge12()]);
    expect(d.short, 'Objížďka +14 km: most 12 t (Ve Žlíbku)');
  });

  // Celá trasa proti Valhalle s balíkem tras ČR a rejstříkem z telefonu:
  // VALHALLA_URL=http://localhost:8002 SEARCH_DB=…/search-cz.sqlite flutter test test/detour_test.dart
  final url = Platform.environment['VALHALLA_URL'];
  final db = Platform.environment['SEARCH_DB'];
  final skip = url == null || db == null || !File(db).existsSync() ? 'chybí VALHALLA_URL / SEARCH_DB' : null;
  group('P3 Horní Počernice → Hradec Králové (most Ve Žlíbku 12 t)', skip: skip, () {
    setUpAll(() => OfflineSearch.instance.open(db));
    const p3 = LatLng(50.124779, 14.6222684), hk = LatLng(50.2092, 15.8328);

    test('vysvětlí objížďku přes sjezd 10 Brandýs', () async {
      final r = await ValhallaClient(url!).route(from: p3, to: hk, profile: TruckProfile());
      expect(r.lengthKm, greaterThan(118));
      final d = r.detour!;
      expect(d.viaIgnored, isFalse);
      expect(d.extraKm, greaterThan(10));
      expect(d.causes.first.title, 'most 12 t (Ve Žlíbku)');
    });

    test('most označený jako neplatný → přes most rovnou na D10 směr Praha', () async {
      int uturns(TruckRoute t) => t.maneuvers.where((m) => m.type == 12 || m.type == 13).length;
      for (final delivery in [false, true]) {
        final plain = await ValhallaClient(url!)
            .route(from: p3, to: hk, profile: TruckProfile(), delivery: delivery, explain: false);
        final r = await ValhallaClient(url).route(
          from: p3,
          to: hk,
          profile: TruckProfile(),
          delivery: delivery,
          ignored: (w) => IgnoredRestriction.of(bridge12()).matches(w),
        );
        expect(r.lengthKm, lessThan(112), reason: 'zásobování: $delivery');
        expect(r.detour!.viaIgnored, isTrue);
        expect(uturns(r), lessThanOrEqualTo(uturns(plain)));
        // Nikde k sjezdu 10 u Brandýsa (50.170, 14.675).
        expect(r.shape.every((p) => const Distance()(p, const LatLng(50.1705, 14.6752)) > 2000), isTrue);
      }
    });

    test('opravdu jen ten most: jiné omezení zůstává', () async {
      final r = await ValhallaClient(url!)
          .route(from: p3, to: hk, profile: TruckProfile(), ignored: (w) => w.value == 6);
      expect(r.lengthKm, greaterThan(118));
      expect(r.detour!.viaIgnored, isFalse);
    });
  });
}
