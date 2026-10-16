import 'package:latlong2/latlong.dart';

class Maneuver {
  final int type;
  final String instruction;
  final String? alertInstruction;
  final String? preInstruction;
  final String? postInstruction;
  final List<String> streetNames;
  final int beginShapeIndex;
  final int endShapeIndex;
  final double lengthKm;

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
  });

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

  /// Kamionová omezení a radary podél trasy (doplňuje se na pozadí).
  List<RouteWarning> warnings = const [];

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

  int? speedLimitAt(int seg) => seg < speedLimits.length ? speedLimits[seg] : null;
  String? roadNameAt(int seg) => seg < roadNames.length ? roadNames[seg] : null;

  List<double> _buildCumulative() {
    const dist = Distance();
    final out = List<double>.filled(shape.length, 0);
    for (var i = 1; i < shape.length; i++) {
      out[i] = out[i - 1] + dist(shape[i - 1], shape[i]);
    }
    return out;
  }
}

enum WarningType { height, weight, width, length, axleLoad, speedCamera }

class RouteWarning {
  final WarningType type;
  final double? value; // m nebo t
  final double atMeters; // vzdálenost od začátku trasy
  final LatLng point;
  final bool violates; // vozidlo limit překračuje

  RouteWarning({
    required this.type,
    required this.value,
    required this.atMeters,
    required this.point,
    required this.violates,
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
        return 'omezení hmotnosti';
      case WarningType.axleLoad:
        return 'omezení zatížení nápravy';
      case WarningType.speedCamera:
        return 'radar';
    }
  }
}
