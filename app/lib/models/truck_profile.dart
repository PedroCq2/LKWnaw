import 'dart:convert';
import 'dart:math' as math;

/// Parametry vozidla předávané do Valhalla `truck` costingu.
class TruckProfile {
  double height; // m
  double width; // m
  double length; // m
  double weight; // t (celková hmotnost)
  double axleLoad; // t
  int axleCount;
  int maxSpeed; // km/h – omezovač / zákonný limit pro kamiony
  bool hazmat; // ADR náklad
  bool avoidTolls;
  bool avoidFerries;
  bool avoidUnpaved; // nezpevněné cesty (polní, šotolina)

  TruckProfile({
    this.height = 4.0,
    this.width = 2.55,
    this.length = 16.5,
    this.weight = 40.0,
    this.axleLoad = 11.5,
    this.axleCount = 5,
    this.maxSpeed = 80,
    this.hazmat = false,
    this.avoidTolls = false,
    this.avoidFerries = false,
    this.avoidUnpaved = true,
  });

  /// Zásobování: zóny „mimo dopravní obsluhu“ bývají od 6 t (Teplice 12 t). Ulice s omezením
  /// do 3,5 t se jim nepočítají – tam kamion jen když v ní je cíl.
  static const deliveryZoneMinT = 6.0;

  /// [delivery] = zásobování: hmotnostní zóny od [deliveryZoneMinT] („mimo dopravní obsluhu“) se
  /// neuplatní, užší ulice s menším limitem ano; [anyWeight] = poslední kousek k cíli v takové ulici.
  /// Výška/šířka/délka/náprava/ADR platí vždy. Mosty hlídá aplikace zvlášť.
  Map<String, dynamic> toValhallaCosting({bool delivery = false, bool anyWeight = false}) => {
    'height': height,
    'width': width,
    'length': length,
    'weight': anyWeight ? 0.0 : (delivery ? math.min(weight, deliveryZoneMinT - 0.1) : weight),
    'axle_load': axleLoad,
    'axle_count': axleCount,
    'hazmat': hazmat,
    'use_tolls': avoidTolls ? 0.0 : 0.5,
    'use_ferry': avoidFerries ? 0.0 : 0.5,
    if (avoidUnpaved) 'exclude_unpaved': true,
    // Kamion po hlavních silnicích: dálnice a „jedničky“ přednostně, obytné ulice a obslužné cesty
    // jen když jinak nelze. Bez toho Valhalla zkracuje přes III. třídy a vesnice
    // (Veltěže → Čertousy: přes Slavětín a obytné ulice místo Loun, D7 a I/16).
    'use_highways': 1.0,
    'low_class_penalty': 120,
    'service_penalty': 60,
    'service_factor': 2,
    'use_living_streets': 0.0,
  };

  /// Krátký přehled aktivního profilu (výška × šířka × délka · hmotnost): „4 m × 2,55 m × 16,5 m · 40 t“.
  String get summary {
    String n(double v) {
      var t = v.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '');
      if (t.endsWith('.')) t = t.substring(0, t.length - 1);
      return t.replaceAll('.', ',');
    }

    return '${n(height)} m × ${n(width)} m × ${n(length)} m · ${n(weight)} t${hazmat ? ' · ADR' : ''}';
  }

  Map<String, dynamic> toJson() => {
    'height': height,
    'width': width,
    'length': length,
    'weight': weight,
    'axleLoad': axleLoad,
    'axleCount': axleCount,
    'maxSpeed': maxSpeed,
    'hazmat': hazmat,
    'avoidTolls': avoidTolls,
    'avoidFerries': avoidFerries,
    'avoidUnpaved': avoidUnpaved,
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
      maxSpeed: (j['maxSpeed'] as num?)?.toInt() ?? 80,
      hazmat: j['hazmat'] as bool? ?? false,
      avoidTolls: j['avoidTolls'] as bool? ?? false,
      avoidFerries: j['avoidFerries'] as bool? ?? false,
      avoidUnpaved: j['avoidUnpaved'] as bool? ?? true,
    );
  }

  String encode() => jsonEncode(toJson());
  static TruckProfile decode(String s) => TruckProfile.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
