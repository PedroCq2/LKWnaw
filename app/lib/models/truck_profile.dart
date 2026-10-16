import 'dart:convert';

/// Parametry vozidla předávané do Valhalla `truck` costingu.
class TruckProfile {
  double height; // m
  double width; // m
  double length; // m
  double weight; // t (celková hmotnost)
  double axleLoad; // t
  int axleCount;
  bool hazmat; // ADR náklad
  bool avoidTolls;
  bool avoidFerries;

  TruckProfile({
    this.height = 4.0,
    this.width = 2.55,
    this.length = 16.5,
    this.weight = 40.0,
    this.axleLoad = 11.5,
    this.axleCount = 5,
    this.hazmat = false,
    this.avoidTolls = false,
    this.avoidFerries = false,
  });

  Map<String, dynamic> toValhallaCosting() => {
        'height': height,
        'width': width,
        'length': length,
        'weight': weight,
        'axle_load': axleLoad,
        'axle_count': axleCount,
        'hazmat': hazmat,
        'use_tolls': avoidTolls ? 0.0 : 0.5,
        'use_ferry': avoidFerries ? 0.0 : 0.5,
      };

  Map<String, dynamic> toJson() => {
        'height': height,
        'width': width,
        'length': length,
        'weight': weight,
        'axleLoad': axleLoad,
        'axleCount': axleCount,
        'hazmat': hazmat,
        'avoidTolls': avoidTolls,
        'avoidFerries': avoidFerries,
      };

  factory TruckProfile.fromJson(Map<String, dynamic> j) {
    double d(String k, double def) => (j[k] as num?)?.toDouble() ?? def;
    return TruckProfile(
      height: d('height', 4.0),
      width: d('width', 2.55),
      length: d('length', 16.5),
      weight: d('weight', 40.0),
      axleLoad: d('axleLoad', 11.5),
      axleCount: (j['axleCount'] as num?)?.toInt() ?? 5,
      hazmat: j['hazmat'] as bool? ?? false,
      avoidTolls: j['avoidTolls'] as bool? ?? false,
      avoidFerries: j['avoidFerries'] as bool? ?? false,
    );
  }

  String encode() => jsonEncode(toJson());
  static TruckProfile decode(String s) =>
      TruckProfile.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
