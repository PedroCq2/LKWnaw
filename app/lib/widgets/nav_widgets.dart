import 'package:flutter/material.dart';

import '../models/route.dart';
import '../navigation/nav_engine.dart';
import '../theme.dart';

IconData maneuverIcon(int type) {
  switch (type) {
    case 4:
    case 5:
    case 6:
      return Icons.flag;
    case 9:
    case 23:
      return Icons.turn_slight_right;
    case 10:
      return Icons.turn_right;
    case 11:
      return Icons.turn_sharp_right;
    case 12:
      return Icons.u_turn_right;
    case 13:
      return Icons.u_turn_left;
    case 14:
      return Icons.turn_sharp_left;
    case 15:
      return Icons.turn_left;
    case 16:
    case 24:
      return Icons.turn_slight_left;
    // Sjezd / nájezd: šipka mírně do strany (ikona „ramp“ vypadá jako připojení zleva).
    case 18:
    case 20:
      return Icons.turn_slight_right;
    case 19:
    case 21:
      return Icons.turn_slight_left;
    case 25:
      return Icons.merge;
    case 26:
    case 27:
      return Icons.roundabout_right;
    case 28:
    case 29:
      return Icons.directions_boat;
    default:
      return Icons.straight;
  }
}

/// Tabule s příštím manévrem (+ „Pak …“ při blízkém dalším manévru).
class ManeuverBanner extends StatelessWidget {
  final Maneuver? maneuver;
  final double distance;
  final Maneuver? then;

  /// Aktuální silnice a staničení (zobrazí se v liště tabule).
  final String? road;
  final double? roadKm;
  const ManeuverBanner({super.key, this.maneuver, required this.distance, this.then, this.road, this.roadKm});

  @override
  Widget build(BuildContext context) {
    final m = maneuver;
    // U výjezdu z dálnice ukaž směr ze značení (jako zelená tabule), jinak ulici.
    final toward = m?.exitToward ?? const [];
    final title = m == null
        ? 'Cíl'
        : toward.isNotEmpty
        ? toward.take(2).join(', ')
        : (m.streetNames.isNotEmpty ? m.streetNames.take(2).join(' / ') : m.instruction);
    // Kruhový objezd: číslo výjezdu vždy vidět („3. výjezd · 13“).
    // Kruhový objezd: číslo výjezdu vždy vidět („3. výjezd · 13“).
    final shown = (m == null ? null : roundaboutLabel(m)) ?? title;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      decoration: BoxDecoration(
        color: Lkw.panel,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black45)],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
            child: Row(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(color: Lkw.amber, borderRadius: BorderRadius.circular(14)),
                  child: Icon(maneuverIcon(m?.type ?? 4), color: Colors.black, size: 58),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                formatDistance(distance),
                                style: const TextStyle(
                                  color: Lkw.amber,
                                  fontSize: 36,
                                  fontWeight: FontWeight.w900,
                                  height: 1.05,
                                ),
                              ),
                            ),
                          ),
                          if (m?.exitNumber != null) _exitTag(m!.exitNumber!),
                        ],
                      ),
                      Text(
                        shown,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Lkw.text,
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (m?.lanes != null && distance < 2500)
            Container(
              color: Lkw.graphite,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: LaneRow(lanes: m!.lanes!),
              ),
            ),
          if (road != null || (m?.exitBranch.isNotEmpty ?? false))
            Container(
              color: Lkw.graphite,
              padding: const EdgeInsets.fromLTRB(14, 6, 16, 6),
              child: Row(
                children: [
                  if (road != null) ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: RoadShield(name: road!),
                    ),
                    if (roadKm != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${roadKm!.toStringAsFixed(1).replaceAll('.', ',')} km',
                        style: const TextStyle(color: Lkw.text, fontSize: 17, fontWeight: FontWeight.w800),
                      ),
                    ],
                  ],
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 6,
                        children: [
                          for (final b in (m?.exitBranch ?? const <String>[]).take(2))
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 70),
                              child: RoadShield(name: b, small: true),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (then != null)
            Container(
              color: Lkw.graphite,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              child: Row(
                children: [
                  const Text(
                    'PAK',
                    style: TextStyle(color: Lkw.amber, fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: 10),
                  Icon(maneuverIcon(then!.type), color: Lkw.text, size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      roundaboutLabel(then!) ??
                          (then!.streetNames.isNotEmpty ? then!.streetNames.first : then!.instruction),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Lkw.text, fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Kruhový objezd krátce: „3. výjezd · 13“ (místo „Vjeďte na kruhový objezd a sjeďte na 3. výjezdu na 13.“).
String? roundaboutLabel(Maneuver m) {
  if (m.type != 26) return null;
  final n =
      m.roundaboutExit ?? int.tryParse(RegExp(r'(\d+)\. výjezd').firstMatch(m.instruction)?.group(1) ?? '');
  if (n == null) return null;
  final road = m.streetNames.isNotEmpty
      ? m.streetNames.first
      : RegExp(r'výjezdu na (.+?)\.?$').firstMatch(m.instruction)?.group(1);
  return '$n. výjezd${road != null ? ' · $road' : ''}';
}

Widget _exitTag(String n) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
  decoration: BoxDecoration(
    color: const Color(0xFF0B6B3A),
    borderRadius: BorderRadius.circular(6),
    border: Border.all(color: Colors.white, width: 2),
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.exit_to_app, color: Colors.white, size: 16),
      const SizedBox(width: 4),
      Text(
        n,
        style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900),
      ),
    ],
  ),
);

/// Označení silnice v barvách českého značení (D červeně, E zeleně, ostatní modře).
class RoadShield extends StatelessWidget {
  final String name;
  final bool small;
  const RoadShield({super.key, required this.name, this.small = false});

  static (Color, Color) _colors(String n) {
    if (RegExp(r'^D\s?\d').hasMatch(n)) return (const Color(0xFFC62828), Colors.white);
    if (RegExp(r'^E\s?\d').hasMatch(n)) return (const Color(0xFF1B7F3B), Colors.white);
    if (RegExp(r'^(I|II|III|R|S|A|B)?\s?/?\d+$').hasMatch(n)) return (const Color(0xFF1565C0), Colors.white);
    return (Lkw.panelHi, Lkw.text);
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _colors(name);
    return Container(
      constraints: const BoxConstraints(maxWidth: 190),
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 9, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Colors.white, width: small ? 1.5 : 2),
      ),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: fg, fontSize: small ? 13 : 16, fontWeight: FontWeight.w900),
      ),
    );
  }
}

/// Dopravní značka omezení (kruh s červeným okrajem) nebo radar.
class WarningSign extends StatelessWidget {
  final RouteWarning w;
  final double size;
  const WarningSign({super.key, required this.w, this.size = 64});

  @override
  Widget build(BuildContext context) {
    if (w.type == WarningType.noOvertakingHgv) {
      // Značka B22a – zákaz předjíždění pro nákladní automobily.
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFD50000), width: size * 0.11),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.local_shipping, size: size * 0.3, color: const Color(0xFFD50000)),
            Icon(Icons.directions_car, size: size * 0.26, color: Colors.black),
          ],
        ),
      );
    }
    if (w.type == WarningType.speedCamera) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFFFC107),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
        ),
        child: Icon(Icons.photo_camera, size: size * 0.5, color: Colors.black87),
      );
    }
    final arrows = switch (w.type) {
      WarningType.height => const Icon(Icons.height, size: 16, color: Colors.black87),
      WarningType.width => const RotatedBox(
        quarterTurns: 1,
        child: Icon(Icons.height, size: 16, color: Colors.black87),
      ),
      WarningType.length => const Icon(Icons.local_shipping, size: 14, color: Colors.black87),
      WarningType.axleLoad => const Icon(Icons.trip_origin, size: 14, color: Colors.black87),
      _ => const SizedBox.shrink(),
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFD50000), width: size * 0.11),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          arrows,
          FittedBox(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                w.label.replaceAll(' ', ''),
                style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.black),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Karta výstrahy v pravém sloupci: značka + vzdálenost.
class WarningCard extends StatelessWidget {
  final RouteWarning w;
  final double distance;
  const WarningCard({super.key, required this.w, required this.distance});

  @override
  Widget build(BuildContext context) {
    final bad = w.violates;
    return Container(
      width: 92,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
      decoration: BoxDecoration(
        color: bad ? Lkw.danger : Lkw.panel,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black38)],
      ),
      child: Column(
        children: [
          WarningSign(w: w, size: 60),
          if (w.type == WarningType.noOvertakingHgv && w.note != null)
            Text(
              w.note!,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Lkw.muted),
            ),
          if (w.onBridge)
            Text(
              'MOST',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: bad ? Colors.white : Lkw.muted,
              ),
            ),
          const SizedBox(height: 4),
          Text(
            formatDistance(distance),
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Lkw.text),
          ),
        ],
      ),
    );
  }
}

/// Rychlostní limit + aktuální rychlost (vlevo dole).
class SpeedWidget extends StatelessWidget {
  final int? limit;
  final double speedKmh;
  final int tolerance; // červeně až nad limit + tolerance
  const SpeedWidget({super.key, required this.limit, required this.speedKmh, this.tolerance = 3});

  @override
  Widget build(BuildContext context) {
    final over = limit != null && speedKmh > limit! + tolerance;
    return Container(
      width: 84,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: over ? Lkw.danger : Lkw.panel,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black38)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (limit != null)
            Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFD50000), width: 7),
              ),
              alignment: Alignment.center,
              child: Text(
                '$limit',
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.black),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            '${speedKmh.round()}',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: Lkw.text),
          ),
          Text('km/h', style: TextStyle(fontSize: 12, color: over ? Colors.white : Lkw.muted)),
        ],
      ),
    );
  }
}

class RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final Color? color;
  const RoundButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.color,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Material(
      color: Lkw.panel,
      elevation: 6,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onPressed,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(width: 56, height: 56, child: Icon(icon, size: 28, color: color ?? Lkw.text)),
        ),
      ),
    ),
  );
}

/// Karta varianty trasy v přehledu.
class RouteCard extends StatelessWidget {
  final String label;
  final TruckRoute route;
  final bool selected;
  final VoidCallback onTap;

  /// Nejrychlejší varianta – karta ukáže rozdíl „+12 min · +7 km“.
  final TruckRoute? base;
  const RouteCard({
    super.key,
    required this.label,
    required this.route,
    required this.selected,
    required this.onTap,
    this.base,
  });

  String? get _diff {
    final b = base;
    if (b == null || identical(b, route)) return null;
    final dm = ((route.timeSec - b.timeSec) / 60).round();
    final dk = (route.lengthKm - b.lengthKm).round();
    String sign(int v) => v > 0 ? '+$v' : '$v';
    return '${sign(dm)} min · ${sign(dk)} km';
  }

  @override
  Widget build(BuildContext context) {
    final via = route.via;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 184,
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? Lkw.panelHi : Lkw.graphite,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? Lkw.amber : Lkw.panelHi, width: selected ? 3 : 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Lkw.amber : Lkw.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (_diff != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    _diff!,
                    style: const TextStyle(color: Lkw.text, fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(
              formatDuration(Duration(seconds: route.timeSec.round())),
              style: const TextStyle(color: Lkw.text, fontSize: 22, fontWeight: FontWeight.w900),
            ),
            Text(
              '${route.lengthKm.toStringAsFixed(route.lengthKm < 100 ? 1 : 0).replaceAll('.', ',')} km'
              '${route.hasToll ? ' · mýto' : ''}',
              style: const TextStyle(color: Lkw.muted, fontSize: 14),
            ),
            if (via.isNotEmpty)
              Text(
                'přes ${via.join(', ')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Lkw.text, fontSize: 13, fontWeight: FontWeight.w600),
              ),
          ],
        ),
      ),
    );
  }
}

/// Jízdní pruhy: pruhy pro naši trasu bíle na jantarovém podkladu, ostatní šedě.
class LaneRow extends StatelessWidget {
  final LaneInfo lanes;
  const LaneRow({super.key, required this.lanes});

  static IconData _icon(Set<String> t, [String? want]) {
    // Sdílený pruh (rovně + vpravo): u našeho pruhu šipka tam, kam jedeme.
    if (want != null && t.length > 1) {
      final mine = t.where((x) => want == 'through' ? (x == 'through' || x == 'none') : x.endsWith(want));
      if (mine.isNotEmpty) t = {mine.first};
    }
    const order = [
      'sharp_left',
      'left',
      'slight_left',
      'merge_to_left',
      'sharp_right',
      'right',
      'slight_right',
      'merge_to_right',
      'reverse',
    ];
    for (final o in order) {
      if (t.contains(o)) {
        return switch (o) {
          'sharp_left' => Icons.turn_sharp_left,
          'left' => Icons.turn_left,
          'slight_left' => Icons.turn_slight_left,
          'sharp_right' => Icons.turn_sharp_right,
          'right' => Icons.turn_right,
          'slight_right' => Icons.turn_slight_right,
          'reverse' => Icons.u_turn_left,
          _ => Icons.merge,
        };
      }
    }
    return Icons.straight;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < lanes.turns.length; i++) ...[
          if (i > 0)
            Container(
              width: 2,
              height: 30,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              color: Lkw.panelHi,
            ),
          Container(
            width: 44,
            height: 40,
            decoration: BoxDecoration(
              color: lanes.active[i] ? Lkw.amber : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _icon(lanes.turns[i], lanes.active[i] ? lanes.want : null),
              size: 32,
              color: lanes.active[i] ? Colors.black : const Color(0xFF5C6570),
            ),
          ),
        ],
      ],
    );
  }
}

IconData amenityIcon(ServiceAmenity a) => switch (a) {
  ServiceAmenity.parking => Icons.local_parking,
  ServiceAmenity.fuel => Icons.local_gas_station,
  ServiceAmenity.food => Icons.restaurant,
  ServiceAmenity.wc => Icons.wc,
  ServiceAmenity.shower => Icons.shower,
  ServiceAmenity.adblue => Icons.water_drop,
  ServiceAmenity.hotel => Icons.hotel,
};

String amenityLabel(ServiceAmenity a) => switch (a) {
  ServiceAmenity.parking => 'Parkování',
  ServiceAmenity.fuel => 'Nafta',
  ServiceAmenity.food => 'Jídlo',
  ServiceAmenity.wc => 'WC',
  ServiceAmenity.shower => 'Sprchy',
  ServiceAmenity.adblue => 'AdBlue',
  ServiceAmenity.hotel => 'Ubytování',
};

/// Okénko vpravo: nejbližší služba na dálnici (velká ikona, další drobně, vzdálenost).
class ServiceTile extends StatelessWidget {
  final HighwayService service;
  final double aheadM;
  final VoidCallback onTap;
  const ServiceTile({super.key, required this.service, required this.aheadM, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final am = service.amenities;
    // Hlavní ikona: pumpa, jinak parkoviště (řidič kamionu hledá hlavně tyhle dvě).
    final main = am.contains(ServiceAmenity.fuel) ? ServiceAmenity.fuel : ServiceAmenity.parking;
    final rest = [
      for (final a in ServiceAmenity.values)
        if (a != main && am.contains(a)) a,
    ].take(3).toList();
    return Material(
      color: Lkw.panel,
      elevation: 6,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Tooltip(
          message: service.name,
          child: SizedBox(
            width: 64,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: main == ServiceAmenity.parking ? const Color(0xFF2F6FDE) : Lkw.amber,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      amenityIcon(main),
                      size: 28,
                      color: main == ServiceAmenity.parking ? Colors.white : Lkw.graphite,
                    ),
                  ),
                  if (rest.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [for (final a in rest) Icon(amenityIcon(a), size: 15, color: Lkw.muted)],
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    formatDistance(aheadM),
                    maxLines: 1,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Lkw.text),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bod na pruhu průběhu trasy.
