import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Zjednodušené sledování doby řízení dle Nařízení (ES) č. 561/2006.
///
/// * max. 4,5 h nepřetržitého řízení, pak přestávka 45 min
///   (nebo dělená 15 + 30 min),
/// * max. 9 h denního řízení (2× týdně 10 h),
/// * denní odpočinek ≥ 9 h nuluje denní dobu řízení.
///
/// Řízení se odvozuje z GPS rychlosti – nenahrazuje tachograf.
class DriveTimer {
  static const maxContinuous = Duration(minutes: 270);
  static const maxDaily = Duration(hours: 9);
  static const _movingKmh = 5.0;
  static const _gapAsStop = Duration(minutes: 2);

  Duration continuous = Duration.zero;
  Duration daily = Duration.zero;
  bool partialBreakTaken = false;
  DateTime? stopStart;
  DateTime? _last;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  Duration get remainingContinuous => _clamp(maxContinuous - continuous);
  Duration get remainingDaily => _clamp(maxDaily - daily);

  /// Zbývá do povinné pauzy (menší z obou limitů).
  Duration get remaining =>
      remainingContinuous < remainingDaily ? remainingContinuous : remainingDaily;

  Duration currentStop(DateTime now) =>
      stopStart == null ? Duration.zero : now.difference(stopStart!);

  static Duration _clamp(Duration d) => d.isNegative ? Duration.zero : d;

  void update(double speedKmh, DateTime now) {
    final last = _last;
    _last = now;
    if (last == null) {
      if (speedKmh < _movingKmh) stopStart ??= now;
      return;
    }
    final dt = now.difference(last);
    if (dt > _gapAsStop) {
      // Aplikace nedostávala polohu – považuj mezeru za stání.
      stopStart ??= last;
    }
    if (speedKmh >= _movingKmh) {
      if (stopStart != null) {
        _applyBreak(now.difference(stopStart!));
        stopStart = null;
      } else {
        continuous += dt;
        daily += dt;
      }
    } else {
      stopStart ??= now;
    }
    if (now.difference(_lastSave) > const Duration(seconds: 30)) {
      _lastSave = now;
      save();
    }
  }

  void _applyBreak(Duration stop) {
    if (stop >= const Duration(hours: 9)) {
      continuous = Duration.zero;
      daily = Duration.zero;
      partialBreakTaken = false;
    } else if (stop >= const Duration(minutes: 45) ||
        (partialBreakTaken && stop >= const Duration(minutes: 30))) {
      continuous = Duration.zero;
      partialBreakTaken = false;
    } else if (stop >= const Duration(minutes: 15)) {
      partialBreakTaken = true;
    }
  }

  void reset() {
    continuous = Duration.zero;
    daily = Duration.zero;
    partialBreakTaken = false;
    stopStart = null;
    save();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'driveTimer',
        jsonEncode({
          'continuous': continuous.inSeconds,
          'daily': daily.inSeconds,
          'partial': partialBreakTaken,
          'stopStart': stopStart?.millisecondsSinceEpoch,
          'last': _last?.millisecondsSinceEpoch,
        }));
  }

  static Future<DriveTimer> load() async {
    final t = DriveTimer();
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString('driveTimer');
      if (s == null) return t;
      final j = jsonDecode(s) as Map<String, dynamic>;
      t.continuous = Duration(seconds: j['continuous'] as int? ?? 0);
      t.daily = Duration(seconds: j['daily'] as int? ?? 0);
      t.partialBreakTaken = j['partial'] as bool? ?? false;
      final ss = j['stopStart'] as int?;
      final last = j['last'] as int?;
      // Čas, kdy byla aplikace zavřená, se počítá jako stání.
      if (ss != null) {
        t.stopStart = DateTime.fromMillisecondsSinceEpoch(ss);
      } else if (last != null) {
        t.stopStart = DateTime.fromMillisecondsSinceEpoch(last);
      }
    } catch (_) {}
    return t;
  }
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h > 0 ? '$h h ${m.toString().padLeft(2, '0')} min' : '$m min';
}
