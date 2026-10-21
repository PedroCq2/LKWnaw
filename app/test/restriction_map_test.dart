import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truck_nav/models/truck_profile.dart';
import 'package:truck_nav/services/restriction_map.dart';

void main() {
  test('zakázané ulice v mapě: co vozidlo překračuje červeně, obsluha oranžově, ne vysoké mosty', () {
    final t = TruckProfile(height: 4, width: 2.55, weight: 40);
    expect(restrictionLook({'highway': 'residential', 'maxweight': '3.5'}, t), (true, '3,5t'));
    expect(restrictionLook({'highway': 'tertiary', 'maxheight': '3.3'}, t), (true, '3,3m'));
    expect(restrictionLook({'highway': 'tertiary', 'hgv': 'no'}, t), (true, 'zákaz'));
    expect(restrictionLook({'highway': 'tertiary', 'hgv': 'destination'}, t), (false, 'obsl.'));
    expect(restrictionLook({'highway': 'primary', 'maxheight': '4.8'}, t), isNull);
    expect(restrictionLook({'maxweight': '3.5'}, t), isNull); // není silnice
    // Most 21 t, jednotlivé vozidlo 34 t: kamion 30 t projede sám → oranžově.
    expect(
      restrictionLook({
        'highway': 'secondary',
        'bridge': 'yes',
        'maxweight': '21',
        'maxweight:total': '34',
      }, TruckProfile(weight: 30))!.$1,
      isFalse,
    );
  });

  test('stejná značka na kouscích jedné ulice jen jednou', () {
    final ways = [
      for (var i = 0; i < 5; i++)
        RestrictedWay(i, [LatLng(50, 14 + i * 0.0005), LatLng(50, 14 + i * 0.0005 + 0.0004)], false, 'obsl.'),
      RestrictedWay(9, [const LatLng(50, 14.0010), const LatLng(50, 14.0014)], true, '3,5t'),
    ];
    final (lines, points) = restrictionGeoJson(ways);
    expect((lines['features'] as List).length, 6);
    final labels = [for (final f in points['features'] as List) (f as Map)['properties']['l']];
    expect(labels.where((l) => l == 'obsl.').length, 1);
    expect(labels, contains('3,5t'));
  });
}
