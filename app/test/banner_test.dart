import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truck_nav/models/route.dart';
import 'package:truck_nav/theme.dart';
import 'package:truck_nav/widgets/nav_widgets.dart';

void main() {
  testWidgets('banner with lanes, exit and road fits a phone', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    final m =
        Maneuver(
            type: 22,
            instruction: 'Pokračujte rovně na D1.',
            streetNames: const ['D1'],
            beginShapeIndex: 0,
            endShapeIndex: 0,
            lengthKm: 0,
            exitNumber: '196',
            exitBranch: const ['D2', 'E 65'],
            exitToward: const ['Ostrava', 'Olomouc'],
            synthetic: true,
          )
          ..lanes = LaneInfo(
            [
              {'slight_left'},
              {'none'},
              {'none'},
            ],
            [false, true, true],
          );
    await tester.pumpWidget(
      MaterialApp(
        theme: Lkw.theme(),
        home: Scaffold(
          body: ManeuverBanner(maneuver: m, distance: 850, road: 'D1', roadKm: 194.3),
        ),
      ),
    );
    expect(find.text('Ostrava, Olomouc'), findsOneWidget);
    expect(find.text('196'), findsOneWidget);
    expect(find.text('194,3 km'), findsOneWidget);
    expect(find.byType(LaneRow), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
