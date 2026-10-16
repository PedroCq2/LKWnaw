import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truck_nav/models/route.dart';
import 'package:truck_nav/navigation/nav_engine.dart';
import 'package:truck_nav/services/drive_timer.dart';
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

  test('DriveTimer breaks', () {
    final t = DriveTimer();
    var now = DateTime(2026, 1, 1, 6);
    t.update(60, now);
    for (var i = 0; i < 4 * 60; i++) {
      now = now.add(const Duration(minutes: 1));
      t.update(60, now);
    }
    expect(t.continuous.inMinutes, 240);
    expect(t.remainingContinuous.inMinutes, 30);
    // 15 min stání = první část dělené přestávky.
    t.update(0, now);
    now = now.add(const Duration(minutes: 16));
    t.update(60, now);
    expect(t.partialBreakTaken, isTrue);
    expect(t.continuous.inMinutes, 240);
    // 30 min stání dokončí přestávku.
    t.update(0, now);
    now = now.add(const Duration(minutes: 31));
    t.update(60, now);
    expect(t.continuous, Duration.zero);
    expect(t.daily.inMinutes, 240);
  });
}
