import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truck_nav/models/route.dart';
import 'package:truck_nav/services/speed_fixes.dart';

void main() {
  // Jižní spojka: v mapě 80, pro kamiony značka 60 (way 26167827), vedlejší úsek beze změny.
  TruckRoute route() =>
      TruckRoute(
          shape: const [LatLng(50.04, 14.42), LatLng(50.04, 14.43), LatLng(50.04, 14.44), LatLng(50.04, 14.45)],
          maneuvers: const [],
          lengthKm: 2.1,
          timeSec: 100,
          hasToll: false,
          hasHighway: false,
        )
        ..speedLimits = [80, 80, 50]
        ..edges = [
          EdgeAttr(begin: 0, end: 2, wayId: 26167827, roadClass: 'trunk'),
          EdgeAttr(begin: 2, end: 3, wayId: 111, roadClass: 'residential'),
        ];

  test('nahlášená rychlost přepíše limit celé cesty, jiné cesty ne', () {
    final r = route();
    expect(applySpeedFixes(r, {26167827: 60}), isTrue);
    expect(r.speedLimits, [60, 60, 50]);
    expect(applySpeedFixes(r, {26167827: 60}), isFalse); // už platí
    expect(applySpeedFixes(r, {}), isFalse);
  });

  test('kamionový limit z OSM: jen číslo v km/h', () {
    expect(
      hgvLimits({
        1: {'maxspeed': '80', 'maxspeed:hgv': '60'},
        2: {'maxspeed': '80'},
        3: {'maxspeed:hgv': '40 mph'},
        4: {'maxspeed:hgv': 'CZ:urban'},
      }),
      {1: 60},
    );
  });
}
