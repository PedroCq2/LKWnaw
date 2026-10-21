import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Druh bodu na trase: zastávka (zastavit), průjezd městem („přes Mělník“), dálnice („pak po D8“).
enum PlanKind { stop, town, road }

class PlanPoint {
  final String name; // u dálnice její označení („D8“)
  final LatLng point; // u dálnice jen orientačně – vjezd a výjezd se určí podle sousedních bodů
  final String? address; // „Všebořická 2789/2a, 400 01 Ústí nad Labem“
  final PlanKind kind;
  PlanPoint(this.name, this.point, {this.address, this.kind = PlanKind.stop});

  bool get isStop => kind == PlanKind.stop;

  PlanPoint withAddress(String? a) => PlanPoint(name, point, address: a, kind: kind);

  Map<String, dynamic> toJson() => {
    'name': name,
    'lat': point.latitude,
    'lon': point.longitude,
    if (address != null) 'addr': address,
    if (kind != PlanKind.stop) 'kind': kind.name,
  };
  static PlanPoint fromJson(Map<String, dynamic> j) => PlanPoint(
    j['name'] as String,
    LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
    address: j['addr'] as String?,
    kind: PlanKind.values.where((k) => k.name == j['kind']).firstOrNull ?? PlanKind.stop,
  );
}

/// Naplánovaná trasa: začátek (null = moje poloha), zastávky, cíl.
class TripPlan {
  String name;
  PlanPoint? start;
  List<PlanPoint> stops;
  PlanPoint dest;
  TripPlan({required this.name, this.start, this.stops = const [], required this.dest});

  Map<String, dynamic> toJson() => {
    'name': name,
    if (start != null) 'start': start!.toJson(),
    'stops': [for (final s in stops) s.toJson()],
    'dest': dest.toJson(),
  };

  static TripPlan fromJson(Map<String, dynamic> j) => TripPlan(
    name: j['name'] as String,
    start: j['start'] == null ? null : PlanPoint.fromJson(Map<String, dynamic>.from(j['start'] as Map)),
    stops: [
      for (final s in (j['stops'] as List? ?? const []))
        PlanPoint.fromJson(Map<String, dynamic>.from(s as Map)),
    ],
    dest: PlanPoint.fromJson(Map<String, dynamic>.from(j['dest'] as Map)),
  );
}

class TripPlans {
  static const _key = 'tripPlans';

  static Future<List<TripPlan>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return [];
      return [
        for (final e in jsonDecode(raw) as List) TripPlan.fromJson(Map<String, dynamic>.from(e as Map)),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<TripPlan> plans) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode([for (final e in plans) e.toJson()]));
  }
}
