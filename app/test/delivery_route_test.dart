import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truck_nav/services/valhalla.dart';

/// Google polyline s přesností 1e6 (formát Valhally).
String encode6(List<LatLng> pts) {
  final out = StringBuffer();
  var pLat = 0, pLon = 0;
  void enc(int v) {
    var x = v < 0 ? ~(v << 1) : v << 1;
    while (x >= 0x20) {
      out.writeCharCode((0x20 | (x & 0x1f)) + 63);
      x >>= 5;
    }
    out.writeCharCode(x + 63);
  }

  for (final p in pts) {
    final lat = (p.latitude * 1e6).round(), lon = (p.longitude * 1e6).round();
    enc(lat - pLat);
    enc(lon - pLon);
    pLat = lat;
    pLon = lon;
  }
  return out.toString();
}

Map<String, dynamic> trip(List<LatLng> pts, double timeSec) {
  const d = Distance();
  var len = 0.0;
  for (var i = 1; i < pts.length; i++) {
    len += d(pts[i - 1], pts[i]) / 1000;
  }
  return {
    'trip': {
      'legs': [
        {'shape': encode6(pts), 'maneuvers': <dynamic>[]},
      ],
      'summary': {'length': len, 'time': timeSec},
    },
  };
}

void main() {
  // Jesenice → SAPA Praha-Libuš. S plnou hmotností oklikou přes Vestec (Vestecká, Inovační),
  // s výjimkou po D0 a 160 m „3,5 t“ (III/0031) v Praze-Cholupicích.
  const a = LatLng(49.9600, 14.5130);
  const b = LatLng(50.0041, 14.4723);
  const vestec = LatLng(49.9870, 14.4950);
  const entry = LatLng(49.9860, 14.4680); // vjezd do Prahy na trase s výjimkou
  final full = trip([a, vestec, b], 27 * 60);

  RawRoute fake({double exemptMin = 21, bool entryReachable = true}) =>
      (from, to, via, {required exempt, head, alt = 0}) async {
        if (exempt && to == b) return trip([from, entry, b], exemptMin * 60);
        if (!exempt && to == entry) {
          // Kamion s plnou hmotností se k vjezdu nedostane → Valhalla skončí jinde.
          return trip([from, entryReachable ? entry : vestec], 14 * 60);
        }
        if (!exempt && to == b) return full;
        throw StateError('neočekávaný dotaz $from → $to ($exempt)');
      };

  test('plná hmotnost oklikou: k vjezdu do obce s plnou hmotností, dál s výjimkou', () async {
    final r = await ValhallaClient.shorterViaTown(fake(), a, b, null, 0, full, entryOf: (_) async => entry);
    expect(r, isNotNull);
    expect(r!.whole, isFalse);
    final end = decodePolyline6((((r.leg['trip'] as Map)['legs'] as List).last as Map)['shape'] as String).last;
    expect(const Distance()(end, entry), lessThan(5));
  });

  test('start i cíl v obci vykládky: celá trasa s výjimkou', () async {
    final r = await ValhallaClient.shorterViaTown(fake(), a, b, null, 0, full, entryOf: (_) async => null);
    expect(r?.whole, isTrue);
  });

  test('malý rozdíl: zůstává plná hmotnost bez výjimky', () async {
    final r = await ValhallaClient.shorterViaTown(
      fake(exemptMin: 25.5),
      a,
      b,
      null,
      0,
      full,
      entryOf: (_) async => entry,
    );
    expect(r, isNull);
  });

  test('k vjezdu do obce se s plnou hmotností nedá dojet: zůstává plná hmotnost', () async {
    final r = await ValhallaClient.shorterViaTown(
      fake(entryReachable: false),
      a,
      b,
      null,
      0,
      full,
      entryOf: (_) async => entry,
    );
    expect(r, isNull);
  });
}
