import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truck_nav/models/route.dart';
import 'package:truck_nav/models/truck_profile.dart';
import 'package:truck_nav/services/horizon.dart';
import 'package:truck_nav/services/valhalla.dart';

/// Silnice I/8 na sever (rovná čára), trasa autem = přímka po ní.
class _FakeClient extends ValhallaClient {
  _FakeClient() : super('http://x');

  @override
  Future<List<String>> roadNamesAt(List<LatLng> track) async => ['8', 'E 442'];

  @override
  Future<TruckRoute?> carRoute(LatLng from, double? heading, LatLng to) async {
    final shape = [from, to];
    final km = const Distance()(from, to) / 1000;
    // K mostu na silnici 254 se odbočuje.
    final other = to.longitude > 13.9;
    return TruckRoute(
      shape: shape,
      maneuvers: [
        Maneuver(
          type: 1,
          instruction: '',
          streetNames: const ['8'],
          beginShapeIndex: 0,
          endShapeIndex: 1,
          lengthKm: km,
        ),
        if (other)
          Maneuver(
            type: 10,
            instruction: '',
            streetNames: const ['254'],
            beginShapeIndex: 0,
            endShapeIndex: 1,
            lengthKm: 0,
          ),
        Maneuver(
          type: 4,
          instruction: '',
          streetNames: const [],
          beginShapeIndex: 1,
          endShapeIndex: 1,
          lengthKm: 0,
        ),
      ],
      lengthKm: km * 1.1,
      timeSec: 0,
      hasToll: false,
      hasHighway: false,
    );
  }
}

Map<String, dynamic> _way(double lat, double lon, Map<String, String> tags) => {
  'type': 'way',
  'id': lat.hashCode,
  'tags': tags,
  'geometry': [
    {'lat': lat, 'lon': lon},
    {'lat': lat + 0.0005, 'lon': lon},
  ],
};

void main() {
  test('bez cíle: nízký most na silnici před námi „za 20 km“, ne za námi ani na jiné silnici', () async {
    const lon = 13.85;
    final track = [for (var i = 0; i < 6; i++) LatLng(50.50 + i * 0.0005, lon)];
    final els = [
      _way(50.68, lon, {'ref': '8', 'maxheight': '3.3'}), // ~20 km před námi
      _way(50.60, lon, {'ref': '8', 'maxheight': '4.8'}), // vysoký – nehlásit
      _way(50.40, lon, {'ref': '8', 'maxheight': '3.0'}), // za námi
      _way(50.55, 13.95, {'ref': '254', 'maxheight': '3.2'}), // jiná silnice
      _way(50.62, lon, {'ref': '8', 'bridge': 'yes', 'maxweight': '12'}), // most 12 t
      _way(50.64, lon, {'ref': '8', 'hgv': 'no'}), // zákaz vjezdu kamionů
    ];
    final h = Horizon(_FakeClient(), source: (_, _, _) async => els);
    final (road, ahead) = await h.scan(
      track: track,
      heading: 0,
      truck: TruckProfile(height: 4, weight: 40),
      odo: 1000,
    );
    expect(road, '8');
    expect(ahead.map((a) => a.w.type), [WarningType.weight, WarningType.noHgv, WarningType.height]);
    final low = ahead.last;
    expect(low.w.value, 3.3);
    expect(low.w.violates, isTrue);
    expect(low.remaining(1000) / 1000, closeTo(21.7, 0.5)); // 19,7 km vzdušně, po silnici o 10 % víc
    // Po 5 km jízdy zbývá o 5 km méně.
    expect(low.remaining(6000), closeTo(low.remaining(1000) - 5000, 1));
  });

  test('silnice z jmen úseku', () {
    expect(roadOf(['8', 'E 442']), '8');
    expect(roadOf(['E 55', 'D8']), 'D8');
    expect(roadOf(['Teplická', '13']), '13');
    expect(roadOf(['Na Stínadlech']), 'Na Stínadlech');
    expect(onRoad({'ref': '13;E442'}, '13'), isTrue);
    expect(onRoad({'ref': '113'}, '13'), isFalse);
    expect(onRoad({'ref': 'D 8'}, 'D8'), isTrue);
  });
}
