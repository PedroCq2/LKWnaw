/// Úsek trasy pro hodnocení (z Valhalla trace_attributes).
typedef EcoEdge = ({String? roadClass, double lengthM, double speedKmh});

// Skutečná cestovní rychlost kamionu podle třídy silnice (km/h) – Valhalla počítá s rychlostí
// silnice, kamion je na „dvojkách“ a „trojkách“ přes vesnice a zatáčky výrazně pomalejší.
const _cap = {
  'motorway': 80.0,
  'trunk': 75.0,
  'primary': 65.0,
  'secondary': 50.0,
  'tertiary': 40.0,
  'unclassified': 30.0,
  'residential': 25.0,
  'service_other': 15.0,
};

// Přirážka (s/km) mimo začátek a konec trasy: spotřeba (brzdění, rozjezdy), únava, úzké silnice.
const _surcharge = {
  'secondary': 30.0,
  'tertiary': 45.0,
  'unclassified': 60.0,
  'residential': 90.0,
  'service_other': 90.0,
};

/// Ekonomická doba jízdy kamionu v minutách – čím méně, tím lepší trasa pro kamion.
/// Začátek a konec trasy (prvních a posledních [endsM] m) bez přirážky: k nakládce a vykládce
/// se jinak než po menších silnicích často nedá.
double economyMinutes(List<EcoEdge> edges, int turns, {double maxSpeedKmh = 80, double endsM = 3000}) {
  final total = edges.fold(0.0, (s, e) => s + e.lengthM);
  var at = 0.0, sec = 0.0;
  for (final e in edges) {
    final cap = _cap[e.roadClass] ?? 25.0;
    final v = [e.speedKmh > 0 ? e.speedKmh : cap, cap, maxSpeedKmh].reduce((a, b) => a < b ? a : b);
    sec += e.lengthM / (v / 3.6);
    // Část úseku mimo začátek a konec trasy.
    final from = at < endsM ? endsM : at,
        to = at + e.lengthM > total - endsM ? total - endsM : at + e.lengthM;
    if (to > from) sec += (to - from) / 1000 * (_surcharge[e.roadClass] ?? 0);
    at += e.lengthM;
  }
  return (sec + turns * 15) / 60;
}

/// Odbočky, které se počítají (ne start, cíl, „pokračujte rovně“).
int countTurns(Iterable<int> maneuverTypes) =>
    maneuverTypes.where((t) => !const {1, 2, 3, 4, 5, 6, 8, 22}.contains(t)).length;
