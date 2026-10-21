import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
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

  testWidgets('značka omezení se vejde do vyhrazené výšky; vpravo nejvýš 2', (tester) async {
    final w = RouteWarning(
      type: WarningType.weight,
      value: 22,
      atMeters: 0,
      point: const LatLng(50, 14),
      violates: true,
      onBridge: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: Lkw.theme(),
        home: Scaffold(
          // Jako v aplikaci: sloupec karet vpravo nahoře.
          body: Align(
            alignment: Alignment.topRight,
            child: Column(children: [WarningCard(w: w, distance: 1200)]),
          ),
        ),
      ),
    );
    // Skutečná výška karty (i s mezerou) – aplikace ji měří stejně.
    final h = tester.getSize(find.byType(WarningCard)).height;
    expect(warningCardFit(free: 26 + 2 * h + 100, want: 3, rightBase: 100, cardH: h), (2, false));
    expect(warningCardFit(free: 26 + 2 * h + 99, want: 3, rightBase: 100, cardH: h), (1, false));
    // Telefon ze snímku: od tabule po spodek tlačítek 467 dp, tlačítka 132 dp + pumpa 101 dp.
    expect(warningCardFit(free: 467, want: 3, rightBase: 132, service: 101), (2, true));
    // Bez okénka pumpy, menší tabule: 2 značky.
    expect(warningCardFit(free: 600, want: 3, rightBase: 132), (2, false));
    // Místo i pro pumpu: nic se neschová.
    expect(warningCardFit(free: 600, want: 2, rightBase: 132, service: 101), (2, false));
    // Málo místa: aspoň jedna (nejbližší) značka.
    expect(warningCardFit(free: 300, want: 2, rightBase: 132, service: 101), (1, true));
    expect(warningCardFit(free: 500, want: 0, rightBase: 132, service: 101), (0, false));
  });
}
