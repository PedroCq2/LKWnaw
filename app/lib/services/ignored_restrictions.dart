import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/route.dart';

/// Omezení hmotnosti, o kterém řidič ví, že na místě neplatí (most po opravě bez značky,
/// zastaralý údaj v mapě). Navigace přes něj smí vést; uloženo jen v telefonu.
class IgnoredRestriction {
  final double value; // t
  final LatLng point;
  final int? wayId; // cesta v OSM
  final String? road;
  final bool bridge;
  final DateTime added;

  IgnoredRestriction({
    required this.value,
    required this.point,
    this.wayId,
    this.road,
    this.bridge = false,
    required this.added,
  });

  factory IgnoredRestriction.of(RouteWarning w) => IgnoredRestriction(
    value: w.value ?? 0,
    point: w.point,
    wayId: w.wayId,
    road: w.road,
    bridge: w.onBridge,
    added: DateTime.now(),
  );

  /// Totéž omezení: stejná cesta v OSM, nebo stejná hodnota do 80 m.
  bool matches(RouteWarning w) {
    if (w.type != WarningType.weight || w.value == null) return false;
    if ((w.value! - value).abs() > 0.05) return false;
    if (wayId != null && w.wayId == wayId) return true;
    return const Distance()(w.point, point) < 80;
  }

  String get title {
    String n(double x) => x.toStringAsFixed(x == x.roundToDouble() ? 0 : 1).replaceAll('.', ',');
    final what = bridge ? 'Most ${n(value)} t' : 'Zákaz nad ${n(value)} t';
    return road == null || road!.isEmpty ? what : '$what (${roadLabel(road!)})';
  }

  Map<String, dynamic> toJson() => {
    'value': value,
    'lat': point.latitude,
    'lon': point.longitude,
    if (wayId != null) 'way': wayId,
    if (road != null) 'road': road,
    'bridge': bridge,
    'added': added.toIso8601String(),
  };

  static IgnoredRestriction fromJson(Map<String, dynamic> j) => IgnoredRestriction(
    value: (j['value'] as num).toDouble(),
    point: LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
    wayId: (j['way'] as num?)?.toInt(),
    road: j['road'] as String?,
    bridge: j['bridge'] as bool? ?? false,
    added: DateTime.tryParse('${j['added']}') ?? DateTime.now(),
  );
}

/// Seznam omezení označených jako neplatná (Nastavení → Omezení, která neplatí).
class IgnoredRestrictions {
  IgnoredRestrictions._();
  static final instance = IgnoredRestrictions._();
  static const _key = 'ignoredRestrictions';

  final List<IgnoredRestriction> items = [];

  Future<void>? _loaded;

  /// Načte seznam (jednou; další volání čekají na totéž načtení).
  Future<void> load() => _loaded ??= _load();

  Future<void> _load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      items
        ..clear()
        ..addAll([
          if (raw != null)
            for (final e in jsonDecode(raw) as List)
              IgnoredRestriction.fromJson(Map<String, dynamic>.from(e as Map)),
        ]);
    } catch (_) {}
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(
    _key,
    jsonEncode([for (final e in items) e.toJson()]),
  );

  bool isIgnored(RouteWarning w) => items.any((i) => i.matches(w));

  Future<void> add(RouteWarning w) async {
    if (isIgnored(w)) return;
    items.insert(0, IgnoredRestriction.of(w));
    await _save();
  }

  Future<void> remove(IgnoredRestriction r) async {
    items.remove(r);
    await _save();
  }

  /// Omezení zase platí (podle omezení na trase).
  Future<void> restore(RouteWarning w) async {
    items.removeWhere((i) => i.matches(w));
    await _save();
  }
}
