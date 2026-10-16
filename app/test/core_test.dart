import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truck_nav/models/route.dart';
import 'package:truck_nav/models/truck_profile.dart';
import 'package:truck_nav/navigation/nav_engine.dart';
import 'package:truck_nav/services/restrictions.dart';
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
          Maneuver(type: 1, instruction: 'Start', streetNames: [], beginShapeIndex: 0, endShapeIndex: 1, lengthKm: 0.7),
          Maneuver(type: 10, instruction: 'Vpravo', streetNames: [], beginShapeIndex: 1, endShapeIndex: 2, lengthKm: 0.7),
          Maneuver(type: 4, instruction: 'Cíl', streetNames: [], beginShapeIndex: 2, endShapeIndex: 2, lengthKm: 0),
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
    for (var i = 0; i < 3; i++) {
      e.update(const LatLng(50.01, 14.005));
    }
    expect(e.isOffRoute, isTrue);
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
        type: WarningType.weight, value: 3.5, atMeters: at, point: const LatLng(50, 14), violates: true);
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
    final r = line()
      ..kmPoints = [(0.0, 112.0, 'D1'), (1430.0, 113.4, 'D1')];
    expect(r.kilometerAt(715, 'D1'), closeTo(112.7, 0.01));
    expect(r.kilometerAt(715, 'D2'), isNull);
    // klesající staničení (jízda opačným směrem)
    r.kmPoints = [(0.0, 113.4, 'D1'), (1430.0, 112.0, 'D1')];
    expect(r.kilometerAt(1000, 'D1'), closeTo(112.42, 0.01));
  });
}
