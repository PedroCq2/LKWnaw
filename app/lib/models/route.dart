import 'package:latlong2/latlong.dart';

/// Jízdní pruhy před manévrem (z OSM `turn:lanes`); [active] = pruhy pro naši trasu.
class LaneInfo {
  final List<Set<String>> turns;
  final List<bool> active;
  LaneInfo(this.turns, this.active);
}

/// Úsek trasy s atributy z Valhally (trace_attributes).
class EdgeAttr {
  final int begin, end; // indexy do shape
  final int? wayId;
  final String? roadClass, use;
  final List<String> names;
  final int? beginHeading, endHeading;
  final List<Map<String, dynamic>> intersecting; // odbočky v koncovém uzlu
  EdgeAttr({
    required this.begin,
    required this.end,
    this.wayId,
    this.roadClass,
    this.use,
    this.names = const [],
    this.beginHeading,
    this.endHeading,
    this.intersecting = const [],
  });
}

class Maneuver {
  final int type;
  final String instruction;
  String? alertInstruction;
  String? preInstruction;
  final String? postInstruction;
  final List<String> streetNames;
  final int beginShapeIndex;
  final int endShapeIndex;
  final double lengthKm;

  /// Dopravní značení výjezdu (Valhalla `sign`): číslo exitu, silnice, směr.
  final String? exitNumber;
  final List<String> exitBranch;
  List<String> exitToward;

  /// Doplněno z OSM: jízdní pruhy a směr („Ostrava“).
  LaneInfo? lanes;

  /// Vložený pokyn „Pokračujte rovně“ na rozdvojení, které Valhalla nehlásí.
  final bool synthetic;

  Maneuver({
    required this.type,
    required this.instruction,
    this.alertInstruction,
    this.preInstruction,
    this.postInstruction,
    required this.streetNames,
    required this.beginShapeIndex,
    required this.endShapeIndex,
    required this.lengthKm,
    this.exitNumber,
    this.exitBranch = const [],
    this.exitToward = const [],
    this.synthetic = false,
  });

  static List<String> _signTexts(Map? sign, String key) =>
      ((sign?[key] as List?) ?? const []).map((e) => '${(e as Map)['text']}').toList();

  factory Maneuver.fromJson(Map<String, dynamic> j) => Maneuver(
        type: (j['type'] as num).toInt(),
        instruction: j['instruction'] as String? ?? '',
        alertInstruction: j['verbal_transition_alert_instruction'] as String?,
        preInstruction: j['verbal_pre_transition_instruction'] as String?,
        postInstruction: j['verbal_post_transition_instruction'] as String?,
        streetNames: ((j['street_names'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        beginShapeIndex: (j['begin_shape_index'] as num).toInt(),
        endShapeIndex: (j['end_shape_index'] as num).toInt(),
        lengthKm: (j['length'] as num?)?.toDouble() ?? 0,
        exitNumber: _signTexts(j['sign'] as Map?, 'exit_number_elements').firstOrNull,
        exitBranch: _signTexts(j['sign'] as Map?, 'exit_branch_elements'),
        exitToward: _signTexts(j['sign'] as Map?, 'exit_toward_elements'),
      );
}

class TruckRoute {
  final List<LatLng> shape;
  final List<Maneuver> maneuvers;
  final double lengthKm;
  final double timeSec;
  final bool hasToll;
  final bool hasHighway;

  /// Původní polyline6 (jen u jednoetapové trasy) pro dotaz na atributy silnic.
  final String? encodedShape;

  /// Rychlostní limit (km/h) a název silnice pro každý segment `shape[i]→shape[i+1]`.
  List<int?> speedLimits = const [];
  List<String?> roadNames = const [];
  List<EdgeAttr> edges = const [];

  /// Kamionová omezení a radary podél trasy (doplňuje se na pozadí).
  List<RouteWarning> warnings = const [];

  /// Exity dálnic na trase: (vzdálenost po trase m, kilometr dálnice, silnice).
  /// V ČR je číslo exitu = kilometr dálnice → staničení se dopočítá mezi nimi.
  List<(double, double, String?)> kmPoints = const [];

  /// Staničení dálnice (km) v místě [traveled] na silnici [road], nebo null.
  double? kilometerAt(double traveled, String road) {
    final pts = kmPoints.where((p) => p.$3 == road).toList();
    if (pts.length < 2) return null;
    var i = pts.lastIndexWhere((p) => p.$1 <= traveled);
    if (i < 0) i = 0;
    if (i >= pts.length - 1) i = pts.length - 2;
    final a = pts[i], b = pts[i + 1];
    final span = b.$1 - a.$1;
    if (span < 200) return null;
    // Exity musí sedět na délku úseku (jinak chybná data / přejezd na jinou dálnici).
    final dk = b.$2 - a.$2;
    if ((dk.abs() * 1000 - span).abs() > span * 0.25 + 1500) return null;
    final km = a.$2 + dk * (traveled - a.$1) / span;
    // Mimo interval (před 1. / za posledním exitem) extrapoluj nejvýš 15 km.
    if (traveled < a.$1 - 15000 || traveled > b.$1 + 15000) return null;
    return km < 0 ? null : km;
  }

  /// Kumulativní vzdálenost (m) od začátku trasy pro každý bod `shape`.
  late final List<double> cumulative = _buildCumulative();

  TruckRoute({
    required this.shape,
    required this.maneuvers,
    required this.lengthKm,
    required this.timeSec,
    required this.hasToll,
    required this.hasHighway,
    this.encodedShape,
  });

  /// Hlavní silnice, po kterých trasa vede (D1, D35, E 50…).
  List<String> get via {
    final out = <String>[];
    final re = RegExp(r'^(D|R|I|II|III|E|A|B|S|M)\s?\d+[a-z]?$');
    for (final m in maneuvers) {
      for (final n in m.streetNames) {
        final t = n.trim();
        if (re.hasMatch(t) && !out.contains(t)) out.add(t);
      }
    }
    // Evropská čísla (E…) jen když chybí národní.
    final national = out.where((e) => !e.startsWith('E')).toList();
    return (national.isNotEmpty ? national : out).take(3).toList();
  }

  int? speedLimitAt(int seg) => seg >= 0 && seg < speedLimits.length ? speedLimits[seg] : null;
  String? roadNameAt(int seg) => seg >= 0 && seg < roadNames.length ? roadNames[seg] : null;

  List<double> _buildCumulative() {
    const dist = Distance();
    final out = List<double>.filled(shape.length, 0);
    for (var i = 1; i < shape.length; i++) {
      out[i] = out[i - 1] + dist(shape[i - 1], shape[i]);
    }
    return out;
  }
}

enum WarningType { height, weight, width, length, axleLoad, speedCamera, noOvertakingHgv }

class RouteWarning {
  final WarningType type;
  final double? value; // m nebo t
  final double atMeters; // vzdálenost od začátku trasy
  final LatLng point;
  final bool violates; // vozidlo limit překračuje
  final bool onBridge; // omezení je na mostě (fyzická nosnost)

  /// Doplňující text (např. časové omezení „6–22 h“).
  final String? note;

  RouteWarning({
    required this.type,
    required this.value,
    this.note,
    required this.atMeters,
    required this.point,
    required this.violates,
    this.onBridge = false,
  });

  String get label {
    final v = value;
    String n(double x) => x.toStringAsFixed(x == x.roundToDouble() ? 0 : 1).replaceAll('.', ',');
    switch (type) {
      case WarningType.height:
        return '${n(v!)} m';
      case WarningType.width:
        return '${n(v!)} m';
      case WarningType.length:
        return '${n(v!)} m';
      case WarningType.weight:
        return '${n(v!)} t';
      case WarningType.axleLoad:
        return '${n(v!)} t';
      case WarningType.speedCamera:
        return 'radar';
      case WarningType.noOvertakingHgv:
        return note ?? '';
    }
  }

  String get spokenName {
    switch (type) {
      case WarningType.height:
        return 'omezení výšky';
      case WarningType.width:
        return 'omezení šířky';
      case WarningType.length:
        return 'omezení délky';
      case WarningType.weight:
        return onBridge ? 'most s nosností' : 'omezení hmotnosti';
      case WarningType.axleLoad:
        return 'omezení zatížení nápravy';
      case WarningType.speedCamera:
        return 'radar';
      case WarningType.noOvertakingHgv:
        return 'zákaz předjíždění nákladních vozidel';
    }
  }
}
