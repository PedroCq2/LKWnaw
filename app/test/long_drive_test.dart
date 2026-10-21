import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truck_nav/models/route.dart';
import 'package:truck_nav/navigation/nav_engine.dart';
import 'package:truck_nav/navigation/voice_guide.dart';
import 'package:truck_nav/services/valhalla.dart';

/// Praha (Chodov) → Ostrava: 350 km po D1 s rozdvojeními u Vyškova a Hulína („držte se vlevo,
/// abyste zůstali na D1“). Trasa z Valhally a atributy silnic (trace_attributes) v test/fixtures.
TruckRoute _route() {
  final j = jsonDecode(File('test/fixtures/praha_ostrava.json').readAsStringSync()) as Map<String, dynamic>;
  final r = ValhallaClient.parseTrip(j['trip'] as Map<String, dynamic>);
  r.edges = [
    for (final e in (j['edges'] as List).cast<List>())
      EdgeAttr(
        begin: e[0] as int,
        end: e[1] as int,
        roadClass: e[2] as String?,
        use: e[3] as String?,
        names: (e[4] as List).cast<String>(),
      ),
  ];
  return r;
}

void main() {
  test('dálnice: kilometry až k sjezdu, „Pokračujte rovně“ jen jednou', () {
    final r = _route();
    final exitIdx = r.maneuvers.indexWhere((m) => m.instruction.contains('výjezdu 354'));
    final entryIdx = r.maneuvers.indexWhere((m) => m.instruction.contains('výjezdu 1 BRNO'));
    expect(exitIdx, greaterThan(entryIdx));
    // Mezi nájezdem na D1 a sjezdem 354 jen průjezdné manévry (rozdvojení na téže dálnici).
    for (var i = entryIdx + 1; i < exitIdx; i++) {
      expect(r.isPassThrough(i), isTrue, reason: r.maneuvers[i].instruction);
    }
    expect(r.isPassThrough(exitIdx), isFalse);
    expect(r.isPassThrough(entryIdx), isFalse);

    // Jízda: 80 km/h na dálnici, ve městě 36 km/h; poloha každou sekundu.
    final e = NavEngine(r);
    final g = VoiceGuide(r, e);
    final cum = r.cumulative;
    final said = <(double, String)>[];
    final actions = <int>{};
    var t = DateTime(2026, 1, 1, 8);
    var last = DateTime(2000);
    var at = 0.0, seg = 0;
    final onD1From = cum[r.maneuvers[entryIdx].beginShapeIndex] + 1500;
    final onD1To = cum[r.maneuvers[exitIdx].beginShapeIndex] - 100;
    while (at < cum.last - 20) {
      final v = at > onD1From - 1500 && at < onD1To ? 22.0 : 10.0;
      at = math.min(cum.last - 1, at + v);
      while (seg < cum.length - 2 && cum[seg + 1] < at) {
        seg++;
      }
      final a = r.shape[seg], b = r.shape[seg + 1];
      final f = cum[seg + 1] > cum[seg] ? (at - cum[seg]) / (cum[seg + 1] - cum[seg]) : 0.0;
      final pos = LatLng(
        a.latitude + (b.latitude - a.latitude) * f,
        a.longitude + (b.longitude - a.longitude) * f,
      );
      t = t.add(const Duration(seconds: 1));
      final course = const Distance().bearing(a, b);
      final nav = e.update(pos, accuracy: 5, now: t, course: course < 0 ? course + 360 : course);
      if (at > onD1From && at < onD1To) {
        actions.add(nav.nextActionIndex);
        // Okénko: kilometry k sjezdu 354, ne k nejbližšímu rozdvojení.
        expect(nav.distanceToNextAction, closeTo(onD1To + 100 - at, 60));
      }
      for (final p in g.update(nav, v * 3.6, t, last)) {
        said.add((at, p));
        last = t;
      }
    }
    // ignore: avoid_print
    print(said.map((s) => '${(s.$1 / 1000).toStringAsFixed(1).padLeft(6)} km  ${s.$2}').join('\n'));
    expect(actions, {exitIdx});
    final onD1 = said.where((s) => s.$1 > onD1From - 1500 && s.$1 < onD1To).toList();
    final km = onD1.where((s) => RegExp(r'Pokračujte rovně.* kilometr').hasMatch(s.$2)).toList();
    expect(km, hasLength(1), reason: '$km');
    // „… 350 kilometrů“ – celá cesta po D1 k sjezdu, ne k prvnímu rozdvojení.
    final n = int.parse(RegExp(r'(\d+) kilometr').firstMatch(km.single.$2)!.group(1)!);
    expect(n, closeTo((onD1To - onD1From) / 1000, 5));
    // Rozdvojení se ohlásí jednou krátce (pruh), bez odpočtu „Za kilometr…“.
    final forks = onD1.where((s) => s.$2.contains('držte vlevo')).toList();
    expect(forks, isNotEmpty);
    expect(forks.where((s) => s.$2.startsWith('Za ')), isEmpty);
    // Sjezd 354 se odpočítává normálně.
    expect(said.where((s) => s.$2.startsWith('Za kilometr') && s.$2.contains('sjeďte')), hasLength(1));
  });
}
