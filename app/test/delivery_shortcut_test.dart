import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truck_nav/models/truck_profile.dart';
import 'package:truck_nav/services/delivery_shortcut.dart';
import 'package:truck_nav/services/restrictions.dart';
import 'package:truck_nav/services/valhalla.dart';

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

  test('výjimka z hmotnosti jen na úsecích trasy s výjimkou (obec vykládky)', () {
    final j = jsonDecode(File('test/fixtures/d8.json').readAsStringSync()) as Map<String, dynamic>;
    final trip = j['trip'] as Map<String, dynamic>;
    final leg = (trip['legs'] as List).first;
    // Dvě etapy: první s plnou hmotností, druhá (dojezd) s výjimkou.
    final r = ValhallaClient.parseTrip({
      ...trip,
      'legs': [leg, leg],
      '_exemptLegs': [false, true],
    });
    final half = r.cumulative[r.legShapes[1].$2];
    expect(r.exemptAt(half / 2), isFalse);
    expect(r.exemptAt(half + 100), isTrue);
    // Zóna 6 t: kamion 12 t při zásobování projede jen tam, kde trasa výjimku využívá.
    final t = TruckProfile(weight: 12);
    final zone = {'maxweight': '6'};
    expect(warningsFromTags(zone, 0, const LatLng(50, 14), t, true).single.violates, isFalse);
    expect(warningsFromTags(zone, 0, const LatLng(50, 14), t, false).single.violates, isTrue);
  });

  test('most 21 t s tabulkou „jednotlivé vozidlo 34 t“', () {
    final bridge = {'bridge': 'yes', 'maxweight': '21', 'maxweight:total': '34'};
    // 30 t: projede, ale jen sám na mostě → oranžově, ne červeně.
    var w = warningsFromTags(bridge, 0, const LatLng(50, 14), TruckProfile(weight: 30), false).single;
    expect(w.violates, isFalse);
    expect(w.tight, isTrue);
    expect(w.single, 34);
    expect(w.note, 'sám 34 t');
    expect(w.spokenValue, 'most s nosností 21 tun, jednotlivé vozidlo 34 tun');
    // 40 t: neprojede.
    w = warningsFromTags(bridge, 0, const LatLng(50, 14), TruckProfile(weight: 40), false).single;
    expect(w.violates, isTrue);
  });
}
