import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truck_nav/models/route.dart';
import 'package:truck_nav/models/truck_profile.dart';
import 'package:truck_nav/navigation/nav_engine.dart';
import 'package:truck_nav/services/restrictions.dart';
import 'package:truck_nav/services/geocoding.dart';
import 'package:truck_nav/services/sun.dart';
import 'package:truck_nav/services/speech.dart';
import 'package:truck_nav/services/saved_places.dart';
import 'package:truck_nav/services/plans.dart';
import 'package:truck_nav/services/valhalla.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('decodePolyline6', () {
    // Body (38.5, -120.2), (40.7, -120.95), (43.252, -126.453) v přesnosti 1e6.
    final pts = decodePolyline6('_izlhA~rlgdF_{geC~ywl@_kwzCn`{nI');
    expect(pts.length, 3);
    expect(pts[0].latitude, closeTo(38.5, 1e-6));
    expect(pts[2].longitude, closeTo(-126.453, 1e-6));
    expect(pts[1].longitude, closeTo(-120.95, 1e-6));
  });

  TruckRoute line() => TruckRoute(
    shape: [const LatLng(50, 14), const LatLng(50, 14.01), const LatLng(50, 14.02)],
    maneuvers: [
      Maneuver(
        type: 1,
        instruction: 'Start',
        streetNames: [],
        beginShapeIndex: 0,
        endShapeIndex: 1,
        lengthKm: 0.7,
      ),
      Maneuver(
        type: 10,
        instruction: 'Vpravo',
        streetNames: [],
        beginShapeIndex: 1,
        endShapeIndex: 2,
        lengthKm: 0.7,
      ),
      Maneuver(
        type: 4,
        instruction: 'Cíl',
        streetNames: [],
        beginShapeIndex: 2,
        endShapeIndex: 2,
        lengthKm: 0,
      ),
    ],
    lengthKm: 1.43,
    timeSec: 100,
    hasToll: false,
    hasHighway: false,
  );

  test('NavEngine snapping and maneuvers', () {
    final e = NavEngine(line());
    final s = e.update(const LatLng(50.0001, 14.005));
    expect(s.segmentIndex, 0);
    expect(s.nextManeuverIndex, 1);
    expect(s.distanceFromRoute, lessThan(20));
    expect(s.distanceToNextManeuver, closeTo(358, 10));
    expect(e.isOffRoute, isFalse);
  });

  test('NavEngine off-route detection', () {
    final e = NavEngine(line());
    final t0 = DateTime(2026, 1, 1, 12);
    for (var i = 0; i < 5; i++) {
      e.update(const LatLng(50.01, 14.005), now: t0.add(Duration(seconds: 2 * i)));
    }
    expect(e.isOffRoute, isTrue);
  });

  test('short GPS jump does not trigger reroute', () {
    final e = NavEngine(line());
    final t0 = DateTime(2026, 1, 1, 12);
    // 2 špatné polohy, pak zpět na trase
    e.update(const LatLng(50.01, 14.005), now: t0);
    e.update(const LatLng(50.01, 14.006), now: t0.add(const Duration(seconds: 1)));
    expect(e.isOffRoute, isFalse);
    e.update(const LatLng(50.0001, 14.007), now: t0.add(const Duration(seconds: 2)));
    expect(e.isOffRoute, isFalse);
    // Špatná přesnost GPS (±200 m) – 150 m od trasy ještě není sjetí
    for (var i = 0; i < 6; i++) {
      e.update(const LatLng(50.00135, 14.008), accuracy: 200, now: t0.add(Duration(seconds: 3 + 2 * i)));
    }
    expect(e.isOffRoute, isFalse);
  });

  test('parse OSM limits', () {
    expect(parseMeters('4.1'), 4.1);
    expect(parseMeters('3,8 m'), 3.8);
    expect(parseMeters("13'6\""), closeTo(4.11, 0.01));
    expect(parseMeters('default').isNaN, isTrue);
    expect(parseTonnes('7.5 t'), 7.5);
    expect(parseTonnes('3500 kg'), 3.5);
  });

  test('RouteIndex locates points along route', () {
    final idx = RouteIndex(line());
    final at = idx.locate(const LatLng(50.00005, 14.015), 15);
    expect(at, closeTo(1072, 15));
    expect(idx.locate(const LatLng(50.01, 14.015), 15), isNull);
  });

  test('mergeWarnings joins one zone', () {
    RouteWarning w(double at) => RouteWarning(
      type: WarningType.weight,
      value: 3.5,
      atMeters: at,
      point: const LatLng(50, 14),
      violates: true,
    );
    final m = mergeWarnings([w(100), w(300), w(650), w(2000)]);
    expect(m.map((e) => e.atMeters), [100, 2000]);
  });

  test('delivery mode drops weight but keeps dimensions', () {
    final p = TruckProfile(height: 4.1, weight: 40);
    expect(p.toValhallaCosting()['weight'], 40);
    final d = p.toValhallaCosting(delivery: true);
    expect(d['weight'], 0);
    expect(d['height'], 4.1);
    expect(d['length'], p.length);
    expect(d['axle_load'], p.axleLoad);
  });

  test('kilometerAt interpolates between motorway exits', () {
    final r = line()..kmPoints = [(0.0, 112.0, 'D1'), (1430.0, 113.4, 'D1')];
    expect(r.kilometerAt(715, 'D1'), closeTo(112.7, 0.01));
    expect(r.kilometerAt(715, 'D2'), isNull);
    // klesající staničení (jízda opačným směrem)
    r.kmPoints = [(0.0, 113.4, 'D1'), (1430.0, 112.0, 'D1')];
    expect(r.kilometerAt(1000, 'D1'), closeTo(112.42, 0.01));
  });

  test('search ranks the brand before other depots', () {
    final r = rankPlaces([
      Place('COOP družstvo HB Distribuční centrum', const LatLng(49, 15), kind: 'Průmyslový areál'),
      Place('Kaufland', const LatLng(49.58, 17.22), kind: 'Supermarket', address: 'Olomouc'),
      Place('Kaufland - Centrální sklad', const LatLng(49.56, 17.31), kind: 'Průmyslový areál'),
      Place('Distribuční centrum RAVAK', const LatLng(49.6, 17.9), kind: 'Průmyslový areál'),
    ], 'kaufland DC');
    expect(r.first.name, 'Kaufland - Centrální sklad');
    expect(r.map((p) => p.name), isNot(contains('Distribuční centrum RAVAK')));
  });

  test('sun elevation day/night in Prague', () {
    expect(isNight(50.08, 14.42, DateTime.utc(2026, 6, 21, 10)), isFalse);
    expect(isNight(50.08, 14.42, DateTime.utc(2026, 10, 16, 22)), isTrue);
    // 16. 10. zapadá v Praze ~16:15 UTC
    expect(isNight(50.08, 14.42, DateTime.utc(2026, 10, 16, 15, 30)), isFalse);
    expect(isNight(50.08, 14.42, DateTime.utc(2026, 10, 16, 16, 45)), isTrue);
  });

  test('saved place navigates to the truck gate and survives reload', () async {
    final sp = SavedPlaces([]);
    await sp.upsert(
      SavedPlace(
        id: '1',
        name: 'Kaufland DC Velký Týnec',
        point: const LatLng(49.5643, 17.3088),
        gate: const LatLng(49.5660, 17.3120),
        note: 'Příjezd zezadu, vrátnice u rampy 12.',
      ),
    );
    final again = await SavedPlaces.load();
    expect(again.items.single.target, const LatLng(49.5660, 17.3120));
    expect(again.near(const LatLng(49.5645, 17.3090))?.name, 'Kaufland DC Velký Týnec');
    expect(again.search('rampy').length, 1);
    expect(again.search('lidl'), isEmpty);
  });

  test('Czech speech for road numbers', () {
    expect(forSpeech('Pokračujte rovně po D46.'), 'Pokračujte rovně po dé čtyřicet šest.');
    expect(forSpeech('Vjeďte na D1 směr E 50'), 'Vjeďte na dé jedna směr E padesát');
    expect(forSpeech('E442'), 'E čtyři sta čtyřicet dva');
    expect(forSpeech('na I/35'), 'na jedna třicet pět');
    expect(czechNumber(602), 'šest set dva');
    expect(czechNumber(230), 'dvě stě třicet');
    expect(czechNumber(114), 'sto čtrnáct');
    expect(forSpeech('Sjeďte na výjezdu 226 na 430'), 'Sjeďte na výjezdu 226 na 430');
  });

  test('profile summary', () {
    expect(TruckProfile().summary, '4 m × 2,55 m × 16,5 m · 40 t');
    expect(TruckProfile(height: 3.8, weight: 7.5, hazmat: true).summary, '3,8 m × 2,55 m × 16,5 m · 7,5 t · ADR');
  });

  test('trip plans round-trip', () async {
    await TripPlans.save([
      TripPlan(
        name: 'Rozvoz Olomouc',
        stops: [PlanPoint('Kaufland DC', const LatLng(49.56, 17.31))],
        dest: PlanPoint('Ostrava', const LatLng(49.83, 18.28)),
      ),
    ]);
    final p = (await TripPlans.load()).single;
    expect(p.start, isNull);
    expect(p.stops.single.name, 'Kaufland DC');
    expect(p.dest.point, const LatLng(49.83, 18.28));
  });
}
