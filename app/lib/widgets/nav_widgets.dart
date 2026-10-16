import 'package:flutter/material.dart';

import '../models/route.dart';
import '../navigation/nav_engine.dart';

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
    case 18:
    case 20:
      return Icons.ramp_right;
    case 19:
    case 21:
      return Icons.ramp_left;
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

/// Zelená tabule s příštím manévrem (+ „pak …“ při blízkém dalším manévru).
class ManeuverBanner extends StatelessWidget {
  final Maneuver? maneuver;
  final double distance;
  final Maneuver? then;
  const ManeuverBanner({super.key, this.maneuver, required this.distance, this.then});

  @override
  Widget build(BuildContext context) {
    final m = maneuver;
    final title = m == null
        ? 'Cíl'
        : (m.streetNames.isNotEmpty ? m.streetNames.take(2).join(' / ') : m.instruction);
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      decoration: BoxDecoration(
        color: const Color(0xFF0B5D3B),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(blurRadius: 10, color: Colors.black38)],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
          child: Row(children: [
            Icon(maneuverIcon(m?.type ?? 4), color: Colors.white, size: 64),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(formatDistance(distance),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800, height: 1.1)),
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600, height: 1.15)),
              ]),
            ),
          ]),
        ),
        if (then != null)
          Container(
            color: const Color(0xFF06331F),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(children: [
              const Text('Pak', style: TextStyle(color: Colors.white70, fontSize: 16)),
              const SizedBox(width: 8),
              Icon(maneuverIcon(then!.type), color: Colors.white, size: 26),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    then!.streetNames.isNotEmpty ? then!.streetNames.first : then!.instruction,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ]),
          ),
      ]),
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
    if (w.type == WarningType.speedCamera) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            color: const Color(0xFFFFC107),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3)),
        child: Icon(Icons.photo_camera, size: size * 0.5, color: Colors.black87),
      );
    }
    final arrows = switch (w.type) {
      WarningType.height => const Icon(Icons.height, size: 16, color: Colors.black87),
      WarningType.width => const RotatedBox(
          quarterTurns: 1, child: Icon(Icons.height, size: 16, color: Colors.black87)),
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
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        arrows,
        FittedBox(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(w.label.replaceAll(' ', ''),
                style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.black)),
          ),
        ),
      ]),
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
        color: bad ? const Color(0xFFC62828) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
      ),
      child: Column(children: [
        WarningSign(w: w, size: 60),
        if (w.onBridge)
          Text('MOST',
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w800, color: bad ? Colors.white : Colors.black54)),
        const SizedBox(height: 4),
        Text(formatDistance(distance),
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: bad ? Colors.white : Colors.black87)),
      ]),
    );
  }
}

/// Rychlostní limit + aktuální rychlost (vlevo dole).
class SpeedWidget extends StatelessWidget {
  final int? limit;
  final double speedKmh;
  const SpeedWidget({super.key, required this.limit, required this.speedKmh});

  @override
  Widget build(BuildContext context) {
    final over = limit != null && speedKmh > limit! + 3;
    return Container(
      width: 84,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: over ? const Color(0xFFC62828) : Colors.white,
        borderRadius: BorderRadius.circular(42),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
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
            child: Text('$limit',
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.black)),
          ),
        const SizedBox(height: 4),
        Text('${speedKmh.round()}',
            style: TextStyle(
                fontSize: 28, fontWeight: FontWeight.w800, color: over ? Colors.white : Colors.black87)),
        Text('km/h', style: TextStyle(fontSize: 12, color: over ? Colors.white : Colors.black54)),
      ]),
    );
  }
}

class RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final Color? color;
  const RoundButton(
      {super.key, required this.icon, required this.onPressed, required this.tooltip, this.color});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          shape: const CircleBorder(),
          elevation: 4,
          child: IconButton(
            iconSize: 28,
            padding: const EdgeInsets.all(12),
            tooltip: tooltip,
            icon: Icon(icon, color: color),
            onPressed: onPressed,
          ),
        ),
      );
}
