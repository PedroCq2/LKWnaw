import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truck_nav/models/route.dart';
import 'package:truck_nav/services/highway_services.dart';

void main() {
  test('odpočívka = jedna služba se vším, co na ní je', () {
    const a = LatLng(49.5, 15.3);
    final s = buildServicesFrom([
      serviceHit({'highway': 'services', 'name': 'Odpočívka Vystrkov'}, a, 1000, 120),
      serviceHit(
        {'amenity': 'fuel', 'brand': 'OMV', 'fuel:adblue': 'yes'},
        const LatLng(49.5005, 15.3),
        1050,
        90,
      ),
      serviceHit({'amenity': 'fast_food', 'brand': "McDonald's"}, const LatLng(49.5007, 15.3005), 1100, 150),
      serviceHit(
        {'amenity': 'parking', 'hgv': 'designated', 'capacity:hgv': '40'},
        const LatLng(49.501, 15.301),
        1200,
        200,
      ),
      // Restaurace ve městě u dálnice bez odpočívky se nehlásí.
      serviceHit({'amenity': 'restaurant', 'name': 'U Lípy'}, const LatLng(49.6, 15.4), 9000, 500),
    ]);
    expect(s, hasLength(1));
    final x = s.single;
    expect(x.name, 'Odpočívka Vystrkov');
    expect(x.type, 'Odpočívka s čerpací stanicí');
    expect(
      x.amenities,
      containsAll([ServiceAmenity.fuel, ServiceAmenity.food, ServiceAmenity.parking, ServiceAmenity.adblue]),
    );
    expect(x.brands, containsAll(['OMV', "McDonald's"]));
    expect(x.hgvSpaces, 40);
  });

  test('samostatná pumpa těsně u dálnice', () {
    final s = buildServicesFrom([
      serviceHit({'amenity': 'fuel', 'name': 'Shell'}, const LatLng(49.5, 15.3), 5000, 80),
      serviceHit({'amenity': 'fuel', 'name': 'Benzina Město'}, const LatLng(49.52, 15.3), 8000, 600),
    ]);
    expect(s.map((e) => e.name), ['Shell']);
  });
}
