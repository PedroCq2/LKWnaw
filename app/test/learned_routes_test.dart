import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truck_nav/services/learned_routes.dart';

/// Nahraná jízda: 2 km na sever, pak 1 km na východ (bod každých 10 m, s GPS šumem do 2 m).
List<LatLng> _drive() {
  final out = <LatLng>[];
  for (var m = 0; m <= 2000; m += 10) {
    out.add(LatLng(50.0 + m / 111320, 14.0 + ((m ~/ 10).isEven ? 1 : -1) * 2 / 71500));
  }
  for (var m = 10; m <= 1000; m += 10) {
    out.add(LatLng(50.0 + 2000 / 111320, 14.0 + m / 71500));
  }
  return out;
}

void main() {
  test('naučená trasa: zjednodušení, cíl u konce, body podél ní se směrem jízdy', () {
    final pts = simplifyTrack(_drive());
    expect(pts.length, lessThan(40)); // ze 300 bodů zůstane kostra
    final r = LearnedRoute(id: '1', name: 'Kaufland', points: pts, created: DateTime(2026));
    expect(r.length, closeTo(3000, 60));
    final lr = LearnedRoutes([r]);
    expect(lr.forDest(LatLng(r.end.latitude + 0.001, r.end.longitude)), r); // ~110 m od konce
    expect(lr.forDest(const LatLng(50.1, 14.1)), isNull);

    // Z dálky: najede se na začátek, body po ~250 m až skoro do cíle.
    final v = learnedVia(r, const LatLng(49.99, 14.0));
    expect(v.length, inInclusiveRange(10, 12));
    expect(v.every((p) => p.through), isTrue);
    expect(v.first.heading, closeTo(0, 15)); // na sever
    expect(v.last.heading, closeTo(90, 15)); // na východ
    // Z dálky první bod 200 m za začátkem nahrávání (kudy se najede, vybere trasa); typ „via“.
    expect(v.first.point.latitude, closeTo(50.0 + 200 / 111320, 30 / 111320));
    expect(v.first.toJson()['type'], 'via');

    // Za jízdy uprostřed trasy: jen zbytek před námi.
    final mid = learnedVia(r, LatLng(50.0 + 1500 / 111320, 14.0));
    expect(mid.length, lessThan(v.length));
    expect(mid.first.point.latitude, greaterThan(50.0 + 1500 / 111320));

    // U konce už nic.
    expect(learnedVia(r, r.end), isEmpty);
    // Uložení a načtení.
    final back = LearnedRoute.fromJson(r.toJson());
    expect(back.points.length, r.points.length);
    expect(back.length, closeTo(r.length, 5));
  });
}
