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

  /// Kumulativní vzdálenost (m) od začátku trasy pro každý bod `shape`.
  late final List<double> cumulative = _buildCumulative();

  TruckRoute({
    required this.shape,
    required this.maneuvers,
    required this.lengthKm,
    required this.timeSec,
    required this.hasToll,
    required this.hasHighway,
  });

  List<double> _buildCumulative() {
    const dist = Distance();
    final out = List<double>.filled(shape.length, 0);
    for (var i = 1; i < shape.length; i++) {
      out[i] = out[i - 1] + dist(shape[i - 1], shape[i]);
    }
    return out;
  }
}
