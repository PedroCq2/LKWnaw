import '../models/truck_profile.dart';
import 'restrictions.dart';

/// Hrana krátké trasy (z Valhalla trace_attributes, profil auto).
typedef ShortcutEdge = ({int? wayId, String? roadClass, String? use, double lengthM});

const _noValues = {'no', 'private', 'agricultural', 'forestry', 'permit'};
const _okValues = {'yes', 'designated', 'delivery', 'destination'};

/// Smí kamion při zásobování projet krátkou trasou?
/// - rozměry a náprava se dodrží vždy (výška, šířka, délka, zatížení nápravy),
/// - hmotnost „mimo dopravní obsluhu“ a hgv=delivery v obci vykládky platí pro zásobování,
/// - zákaz vjezdu kamionů (hgv=no, soukromé…) ne,
/// - žádné příjezdy k domům a uličky (kromě posledních metrů k rampě).
/// [tags] = štítky cest podle id. Vrací null = smí, jinak důvod.
String? shortcutProblem(List<ShortcutEdge> edges, Map<int, Map<String, dynamic>> tags, TruckProfile p) {
  final total = edges.fold(0.0, (s, e) => s + e.lengthM);
  var at = 0.0;
  for (final e in edges) {
    final nearEnd = total - at < 350;
    at += e.lengthM;
    if (!nearEnd && const {'driveway', 'alley', 'parking_aisle', 'track', 'living_street'}.contains(e.use)) {
      return 'úzká ulička';
    }
    if (!nearEnd && e.roadClass == 'service_other') return 'obslužná cesta';
    final t = e.wayId == null ? null : tags[e.wayId];
    if (t == null) continue;
    double num(String k, double Function(String) parse) => t[k] == null ? double.nan : parse('${t[k]}');
    if (num('maxheight', parseMeters) < p.height) return 'výška ${t['maxheight']}';
    if (num('maxheight:physical', parseMeters) < p.height) return 'výška ${t['maxheight:physical']}';
    if (num('maxwidth', parseMeters) < p.width) return 'šířka ${t['maxwidth']}';
    if (num('maxlength', parseMeters) < p.length) return 'délka ${t['maxlength']}';
    if (num('maxaxleload', parseTonnes) < p.axleLoad) return 'náprava ${t['maxaxleload']}';
    if (num('maxweight:physical', parseTonnes) < p.weight) return 'nosnost ${t['maxweight:physical']}';
    final hgv = t['hgv'] as String?;
    if (_okValues.contains(hgv)) continue;
    if (_noValues.contains(hgv)) return 'zákaz vjezdu kamionů';
    for (final k in const ['goods', 'motor_vehicle', 'vehicle', 'access']) {
      final v = t[k] as String?;
      if (_okValues.contains(v)) break;
      if (_noValues.contains(v)) return 'zákaz vjezdu';
    }
  }
  return null;
}
