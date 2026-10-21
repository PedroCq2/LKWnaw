import 'package:flutter_test/flutter_test.dart';
import 'package:truck_nav/models/truck_profile.dart';
import 'package:truck_nav/services/delivery_shortcut.dart';

void main() {
  final p = TruckProfile(height: 4, width: 2.55, length: 16.5, weight: 40);
  ShortcutEdge e(int id, {String use = 'road', String cls = 'tertiary', double m = 200}) =>
      (wayId: id, roadClass: cls, use: use, lengthM: m);

  test('dopravní obsluha a podjezd 4,4 m: smí', () {
    expect(
      shortcutProblem(
        [e(1), e(2, cls: 'residential'), e(3, cls: 'service_other', use: 'parking_aisle', m: 80)],
        {
          1: {'hgv': 'delivery', 'highway': 'tertiary'},
          2: {'maxheight': '4.4'},
          3: {'maxweight': '3.5'},
        },
        p,
      ),
      isNull,
    );
  });

  test('nízký podjezd, zákaz kamionů, ulička: nesmí', () {
    expect(
      shortcutProblem(
        [e(1)],
        {
          1: {'maxheight': '3.8'},
        },
        p,
      ),
      contains('výška'),
    );
    expect(
      shortcutProblem(
        [e(1)],
        {
          1: {'hgv': 'no'},
        },
        p,
      ),
      isNotNull,
    );
    expect(
      shortcutProblem(
        [e(1)],
        {
          1: {'motor_vehicle': 'no'},
        },
        p,
      ),
      isNotNull,
    );
    expect(
      shortcutProblem(
        [e(1)],
        {
          1: {'access': 'no', 'hgv': 'delivery'},
        },
        p,
      ),
      isNull,
    );
    expect(shortcutProblem([e(1, use: 'alley'), e(2, m: 900)], const {}, p), isNotNull);
    expect(
      shortcutProblem(
        [e(1)],
        {
          1: {'maxwidth': '2.3'},
        },
        p,
      ),
      contains('šířka'),
    );
  });

  test('ulička 3,5 t cestou k cíli: jen s výjimkou zapsanou v mapě; zóna 12 t smí', () {
    final edges = [e(1), e(2, cls: 'residential', m: 300), e(3, m: 400)];
    expect(
      shortcutProblem(edges, {
        2: {'maxweight': '3.5'},
      }, p),
      contains('hmotnost'),
    );
    expect(
      shortcutProblem(edges, {
        2: {'maxweight': '3.5', 'maxweight:conditional': 'none @ delivery'},
      }, p),
      isNull,
    );
    expect(
      shortcutProblem(edges, {
        2: {'maxweight': '12'},
      }, p),
      isNull,
    );
  });
}
