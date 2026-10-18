import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truck_nav/screens/offline_section.dart';
import 'package:truck_nav/services/cz_cells.dart';
import 'package:truck_nav/theme.dart';

bool covered(double lat, double lon) =>
    czCells.any((c) => lat >= c[0] && lat <= c[2] && lon >= c[1] && lon <= c[3]);

void main() {
  test('mapa ČR: čtverce pokryjí celou republiku i okraje, ne sousední velkoměsta', () {
    const inside = {
      'Praha': (50.0755, 14.4378),
      'Brno': (49.1951, 16.6068),
      'Ostrava': (49.8209, 18.2625),
      'Aš (nejzápadnější)': (50.2238, 12.1951),
      'Hrčava (nejvýchodnější)': (49.5200, 18.8520),
      'Vyšší Brod (jih)': (48.6161, 14.3119),
      'Lobendava (sever)': (51.0389, 14.3167),
      'Teplice': (50.6404, 13.8245),
    };
    for (final e in inside.entries) {
      expect(covered(e.value.$1, e.value.$2), isTrue, reason: e.key);
    }
    const outside = {
      'Drážďany': (51.0504, 13.7373),
      'Vídeň': (48.2082, 16.3738),
      'Vratislav': (51.1079, 17.0385),
      'Mnichov': (48.1351, 11.5820),
      'Bratislava': (48.1486, 17.1077),
    };
    for (final e in outside.entries) {
      expect(covered(e.value.$1, e.value.$2), isFalse, reason: e.key);
    }
    expect(czCells.length, inInclusiveRange(120, 220));
  });

  Future<void> show(WidgetTester t, Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    await t.pumpWidget(
      MaterialApp(
        theme: Lkw.theme(),
        home: Scaffold(
          body: SingleChildScrollView(child: OfflineMapSection(key: UniqueKey())),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('nastavení mapy ČR: nestažená / rozstahovaná / hotová', (t) async {
    await show(t, {});
    expect(find.textContaining('není stažená'), findsOneWidget);
    expect(find.textContaining('Podrobná ~840 MB'), findsOneWidget);
    expect(find.textContaining('Základní ~350 MB'), findsOneWidget);

    await show(t, {
      'countryMap': jsonEncode({
        'detailed': true,
        'done': [-1, 0, 1, 2],
      }),
    });
    expect(find.textContaining('Staženo'), findsOneWidget);
    expect(find.text('Pokračovat ve stahování'), findsOneWidget);

    await show(t, {
      'countryMap': jsonEncode({
        'detailed': true,
        'done': [-1],
        'complete': true,
        'at': '2026-10-18T10:00:00',
      }),
    });
    expect(find.textContaining('Podrobná mapa ČR je stažená (18. 10. 2026)'), findsOneWidget);
    expect(find.byTooltip('Smazat mapu ČR'), findsOneWidget);
  });
}
