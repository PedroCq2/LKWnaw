import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truck_nav/screens/planner_screen.dart';
import 'package:truck_nav/services/plans.dart';
import 'package:truck_nav/services/saved_places.dart';
import 'package:truck_nav/theme.dart';

void main() {
  testWidgets('planner shows start, stops and destination', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.binding.setSurfaceSize(const Size(360, 800));
    await t.pumpWidget(MaterialApp(
      theme: Lkw.theme(),
      home: PlannerScreen(
        saved: SavedPlaces([]),
        initial: TripPlan(
          name: 'x',
          stops: [PlanPoint('Kaufland DC Velký Týnec', const LatLng(49.56, 17.31))],
          dest: PlanPoint('Ostrava', const LatLng(49.83, 18.28)),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('Moje poloha'), findsOneWidget);
    expect(find.text('Kaufland DC Velký Týnec'), findsOneWidget);
    expect(find.text('Ostrava'), findsOneWidget);
    expect(find.text('NAPLÁNOVAT TRASU'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
