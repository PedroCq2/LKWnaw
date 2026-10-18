import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truck_nav/navigation/nav_engine.dart';
import 'package:truck_nav/navigation/voice_guide.dart';
import 'package:truck_nav/services/valhalla.dart';

/// Simulovaná jízda bez internetu: skutečná trasa z Valhally (test/fixtures) a GPS stopa
/// po sekundách (poloha, rychlost m/s, kurz, ujetá vzdálenost). Vrací přepis hlášek.
class Drive {
  final List<(int, String)> said = [];
  int? offRouteAt; // sekunda prvního sjetí z trasy
  int? missAt; // sekunda, kdy stopa přejela odbočku (scénář „přejetá odbočka“)
  int? reroutedAt; // sekunda, kdy aplikace dostala novou trasu
  Drive(String name, {bool stopWhenOff = false}) {
    final j = jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;
    final r = ValhallaClient.parseTrip(j['trip'] as Map<String, dynamic>);
    var e = NavEngine(r);
    var g = VoiceGuide(r, e);
    final re = j['reroute'] as Map<String, dynamic>?;
    final fixes = (j['fixes'] as List).cast<List>();
    final missM = (j['missAt'] as num?)?.toDouble();
    var t = DateTime(2026, 1, 1, 8);
    var last = DateTime(2000);
    void say(int sec, String s) {
      said.add((sec, s));
      last = t;
    }

    for (var sec = 0; sec < fixes.length; sec++) {
      final f = fixes[sec];
      t = t.add(const Duration(seconds: 1));
      final kmh = (f[2] as num).toDouble() * 3.6;
      final h = (f[3] as num).toDouble();
      if (missM != null && missAt == null && (f[4] as num) >= missM) missAt = sec;
      final nav = e.update(
        LatLng((f[0] as num).toDouble(), (f[1] as num).toDouble()),
        accuracy: 5,
        now: t,
        course: kmh > 8 && h >= 0 ? h : null,
      );
      // Start navigace: jako v aplikaci, až se trasa vypočte (stojí se 20 s na místě).
      if (sec == 19) say(sec, g.startPhrase(nav.traveled, t));
      if (sec < 19) continue;
      if (e.isOffRoute) {
        offRouteAt ??= sec;
        if (stopWhenOff) break;
        if (re != null && reroutedAt == null) say(sec, 'Přepočítávám trasu.');
        e.resetOffRoute();
      }
      // Nová trasa z místa sjetí (v aplikaci dorazí ze serveru za 1–3 s).
      if (re != null && offRouteAt != null && reroutedAt == null && sec >= (re['at'] as int)) {
        reroutedAt = sec;
        final r2 = ValhallaClient.parseTrip(re['trip'] as Map<String, dynamic>);
        e = NavEngine(r2);
        g = VoiceGuide(r2, e);
        continue;
      }
      if (reroutedAt != null && (re?['stopAfter'] ?? 60) is int && sec - reroutedAt! > 60) break;
      for (final p in g.update(nav, kmh, t, last)) {
        say(sec, p);
      }
    }
  }

  String get transcript => [for (final (s, t) in said) '${s.toString().padLeft(5)} s  $t'].join('\n');
}

void main() {
  for (final name in ['teplice', 'd8']) {
    test('jízda $name: hlášky bez opakování a překrývání, žádné falešné sjetí', () {
      final d = Drive(name);
      // ignore: avoid_print
      print('--- $name (${d.said.length} hlášek)\n${d.transcript}');
      expect(d.offRouteAt, isNull, reason: 'jede po trase, sjetí hlášeno v ${d.offRouteAt}. s');
      for (var i = 1; i < d.said.length; i++) {
        final (a, ta) = d.said[i - 1];
        final (b, tb) = d.said[i];
        expect(tb, isNot(ta), reason: 'stejná hláška dvakrát za sebou v $b. s: $tb');
        expect(b - a, greaterThanOrEqualTo(3), reason: 'hlášky se překrývají ($a. a $b. s): „$ta“ / „$tb“');
      }
      expect(d.said.where((s) => s.$2.contains('Opusťte kruhový objezd')), isEmpty);
      expect(d.said.last.$2, startsWith('Cíl je'));
    });
  }

  test('po přepočtu hned řekne, kudy dál (skutečná vzdálenost)', () {
    final d = Drive('miss');
    // ignore: avoid_print
    print('--- miss\n${d.transcript}');
    expect(d.reroutedAt, isNotNull);
    final after = d.said.where((x) => x.$1 >= d.reroutedAt!).toList();
    expect(after, isNotEmpty);
    expect(
      after.first.$1 - d.reroutedAt!,
      lessThanOrEqualTo(3),
      reason: 'první pokyn po přepočtu: ${after.first}',
    );
    expect(after.first.$2, startsWith('Za '));
  });

  test('přejetá odbočka: sjetí z trasy do 8 s', () {
    final d = Drive('miss', stopWhenOff: true);
    expect(d.missAt, isNotNull);
    expect(d.offRouteAt, isNotNull);
    expect(
      d.offRouteAt! - d.missAt!,
      lessThanOrEqualTo(8),
      reason: 'přejeto v ${d.missAt}. s, sjetí v ${d.offRouteAt}. s',
    );
  });

  test('start až za první odbočkou: nehlásí odbočku, která je už za námi', () {
    final j = jsonDecode(File('test/fixtures/teplice.json').readAsStringSync()) as Map<String, dynamic>;
    final r = ValhallaClient.parseTrip(j['trip'] as Map<String, dynamic>);
    final g = VoiceGuide(r, NavEngine(r));
    final m1 = r.maneuvers[1];
    final past = r.cumulative[m1.beginShapeIndex] + 40; // těsně za první odbočkou
    final t = g.startPhrase(past, DateTime(2026));
    expect(t, isNot(g.nowInstruction(1, DateTime(2026))));
    // ozve se další manévr před námi (nebo obecné „Jeďte…“)
    final g2 = VoiceGuide(r, NavEngine(r));
    expect(g2.startPhrase(0, DateTime(2026)), isNotEmpty);
  });
}
