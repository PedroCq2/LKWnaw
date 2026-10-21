import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'road_anchors.dart';
import 'search_fold.dart';

/// Bod mezi startem a cílem, jak ho dostane Valhalla.
class ViaPoint {
  final LatLng point;

  /// Jen projet (město, dálnice) – bez zastavení a bez „Dorazili jste“; jinak zastávka.
  final bool through;

  /// Přichytit na dálnici, ne na sjezd ([heading] = pás ve směru jízdy).
  final bool motorway;

  /// Průjezd městem po hlavní silnici, ne uličkami centra.
  final bool mainRoad;
  final double? heading;

  const ViaPoint(
    this.point, {
    this.through = false,
    this.motorway = false,
    this.mainRoad = false,
    this.heading,
  });

  Map<String, dynamic> toJson() => {
    'lat': point.latitude,
    'lon': point.longitude,
    'type': through ? 'through' : 'break',
    if (heading != null) 'heading': heading!.round(),
    if (heading != null) 'heading_tolerance': 45,
    // Ne na přívoz / lodní linku (Mělník: „T91 Litoměřice – Mělník“ po Labi je nejblíž náměstí).
    if (motorway)
      'search_filter': {'min_road_class': 'motorway', 'exclude_ramp': true, 'exclude_ferry': true},
    if (mainRoad && !motorway)
      'search_filter': {'min_road_class': 'secondary', 'exclude_ramp': true, 'exclude_ferry': true},
  };
}

final _cache = <String, List<LatLng>>{};

/// Body na dálnici [ref] ve směru staničení (prázdné = dálnici neznáme).
List<LatLng> roadAnchors(String ref) => _cache.putIfAbsent(ref, () {
  final d = roadAnchorData[ref];
  if (d == null) return const [];
  return [for (var i = 0; i + 1 < d.length; i += 2) LatLng(d[i] / 1e5, d[i + 1] / 1e5)];
});

const _numbers = {
  'nula': 0,
  'jedna': 1,
  'jednick': 1,
  'dva': 2,
  'dvojk': 2,
  'tri': 3,
  'trojk': 3,
  'ctyri': 4,
  'ctyrk': 4,
  'pet': 5,
  'petk': 5,
  'sest': 6,
  'sestk': 6,
  'sedm': 7,
  'sedmick': 7,
  'osm': 8,
  'osmick': 8,
  'deset': 10,
  'desitk': 10,
  'jedenact': 11,
  'jedenactk': 11,
  'tricet pet': 35,
  'ctyricet sest': 46,
  'ctyricet osm': 48,
  'ctyricet devet': 49,
  'padesat dva': 52,
  'padesat pet': 55,
  'padesat sest': 56,
};

/// „d 8“, „D8“, „dé osm“, „dálnice 8“, „na osmičku“ → „D8“ (jen dálnice, které známe), jinak null.
String? roadRef(String text) {
  var t = fold(text.trim()).replaceAll(RegExp(r'\s+'), ' ');
  t = t.replaceFirst(RegExp(r'^(?:(?:a )?(?:pak|potom|dal|dale) )?(?:zpet |zpatky |zase )?(?:na|po) '), '');
  final word = RegExp(r'^dalnic\w*(?: cislo)? ').firstMatch(t);
  if (word != null) t = t.substring(word.end);
  int? number(String w) => int.tryParse(w.trim()) ?? _numbers[w.trim()];
  // Hovorově „na osmičku“, „po desítce“.
  final stem = RegExp(r'^([a-z]+?)(?:ce|ku|ka|ky|kou)$').firstMatch(t);
  var n = (word != null ? number(t) : null) ?? (stem == null ? null : _numbers['${stem[1]}k']);
  if (n == null) {
    final d = RegExp(r'^(?:de|d)\s*[-.]?\s*(.+)$').firstMatch(t);
    if (d != null) n = number(d[1]!);
  }
  if (n == null) return null;
  final ref = 'D$n';
  return roadAnchorData.containsKey(ref) ? ref : null;
}

double _bearing(LatLng a, LatLng b) {
  final b0 = const Distance().bearing(a, b);
  return b0 < 0 ? b0 + 360 : b0;
}

/// Jet po dálnici [ref] z [from] do [to] („přes Mělník a pak po D8“): průjezdní body uvnitř úseku
/// dálnice mezi místem nejblíž [from] a místem nejblíž [to], na pásu ve směru jízdy. Nájezd a sjezd
/// si vybere Valhalla – bod těsně u nájezdu by trasu stočil na otočku (sjezd z I/16 je až za ním)
/// a bod u cíle by ji vedl za vhodný sjezd (do Děčína se sjíždí v Ústí, ne až v Knínicích).
List<ViaPoint> roadVia(String ref, LatLng from, LatLng to) {
  final pts = roadAnchors(ref);
  if (pts.length < 2) return const [];
  const dist = Distance();
  int nearest(LatLng p) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < pts.length; i++) {
      final d = dist(p, pts[i]);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  final a = nearest(from), b = nearest(to);
  var dir = (b - a).sign;
  if (dir == 0) {
    // Start i cíl u stejného místa dálnice: směr podle toho, kam je cíl.
    final i = math.min(a, pts.length - 2);
    var diff = (_bearing(pts[i], pts[i + 1]) - _bearing(from, to)).abs() % 360;
    if (diff > 180) diff = 360 - diff;
    dir = diff <= 90 ? 1 : -1;
  }
  double heading(int i) {
    final j = i + dir;
    return j >= 0 && j < pts.length ? _bearing(pts[i], pts[j]) : _bearing(pts[i - dir], pts[i]);
  }

  // Body ~ po 40 km (1–3), rovnoměrně uvnitř úseku: trasa po dálnici nesjede a zase nenajede.
  // Bod blíž než 2,5 km od [from] vynechat – za jízdy po dálnici (přepočet) by mohl být za námi.
  final n = ((b - a).abs() / 20).round().clamp(1, 3);
  return [
    for (var k = 1; k <= n; k++)
      if ((a + (b - a) * k / (n + 1)).round() case final i when dist(from, pts[i]) > 2500)
        ViaPoint(pts[i], through: true, motorway: true, heading: heading(i)),
  ];
}
