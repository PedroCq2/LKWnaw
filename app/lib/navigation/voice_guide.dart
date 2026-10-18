import 'dart:math' as math;

import '../models/route.dart';
import 'nav_engine.dart';

/// Hlasové pokyny pro jednu trasu: co a kdy říct (přehrávání dělá Voice).
///
/// Jako u profi navigací: odpočet „Za kilometr… Za 500 metrů… Za 200 metrů…“, v místě manévru
/// „Sjeďte vpravo a poté se držte vlevo“, po manévru „Pokračujte rovně 12 kilometrů“.
/// Nic se neříká dvakrát za sebou: manévr řečený v „… a poté …“ se znovu nehlásí,
/// výjezd z kruhového objezdu je už v „vyjeďte druhým výjezdem“.
class VoiceGuide {
  final TruckRoute route;
  final NavEngine engine;
  VoiceGuide(this.route, this.engine);

  /// Kdy zaznělo „Cíl je vpravo“ (aby hned nezaznělo i „Jste v cíli“).
  DateTime? destSpokenAt;

  final _stageAt = <int, double>{}; // manévr → vzdálenost, při které zazněl poslední odpočet
  String? _lastText;
  DateTime? _lastTextAt;

  /// Hlášky pro aktuální polohu (viz [_update]); stejná věta pro další manévr hned po předchozí
  /// dostane „Znovu …“ – řidič pozná, že jde o další odbočku, ne o opakování.
  List<String> update(NavState nav, double speedKmh, DateTime now, DateTime lastSpokenAt) {
    final out = _update(nav, speedKmh, now, lastSpokenAt);
    for (var i = 0; i < out.length; i++) {
      final t = out[i];
      final last = _lastTextAt;
      if (t == _lastText && last != null && now.difference(last) < const Duration(seconds: 40)) {
        out[i] = 'Znovu ${t[0].toLowerCase()}${t.substring(1)}';
      }
      _lastText = t;
      _lastTextAt = now;
    }
    return out;
  }

  /// Hlášky pro aktuální polohu (většinou žádná, nejvýš dvě).
  /// [lastSpokenAt] = kdy naposledy zazněla jakákoli hláška (i varování) – navazující hlášky
  /// nechají předchozí doznít.
  List<String> _update(NavState nav, double speedKmh, DateTime now, DateTime lastSpokenAt) {
    final out = <String>[];
    final i = nav.nextManeuverIndex;
    if (i < 0) return out;
    final r = route, e = engine;
    final m = r.maneuvers[i];
    final d = nav.distanceToNextManeuver;
    final key = m.beginShapeIndex;
    final mps = speedKmh / 3.6;
    final roundaboutExit = m.type == 27;
    // „Teď“: ~4 s před manévrem, nejméně 50 m. Výjezd z kruháče až těsně u něj –
    // 50 m před ním je v kruhovém objezdu ještě předchozí výjezd.
    final nowDist = roundaboutExit ? math.max(8.0, mps * 1.2) : math.max(50.0, mps * 4);

    // Po manévru: dlouhý úsek bez pokynu → „Pokračujte rovně (po D1) 12 kilometrů.“
    if (i > 0 && d > 3000 && !e.preSpoken.contains(key) && !e.continueSpoken.contains(key)) {
      final prev = r.maneuvers[i - 1];
      final passed = nav.traveled - r.cumulative[prev.beginShapeIndex.clamp(0, r.shape.length - 1)];
      if (passed > 900) {
        e.continueSpoken.add(key);
      } else if (now.difference(lastSpokenAt) > const Duration(seconds: 7)) {
        // Až předchozí pokyn dozní – ne „Najeďte na nájezd.“ a hned „Pokračujte 7 km.“
        e.continueSpoken.add(key);
        final road = roadAhead(prev);
        out.add('Pokračujte rovně${road == null ? '' : _po(road)} ${kmWords(d)}.');
      }
    }

    // Už řečeno jako „… a poté …“ u předchozího manévru a jede se k němu jen pár sekund:
    // znovu nehlásit (jinak dvě hlášky hned za sebou).
    final ch = e.chained[key];
    if (ch != null) {
      // Odpočet („Za 200 metrů…“) už nedává smysl – manévr zazněl v „a poté“.
      for (var t = 0; t < 3; t++) {
        e.stageSpoken.add(key * 10 + t);
      }
      if (ch < math.max(150.0, mps * 8)) {
        e.preSpoken.add(key);
        return out;
      }
    }

    if (d <= nowDist) {
      if (e.preSpoken.add(key)) {
        e.alertSpoken.add(key);
        out.add(nowInstruction(i, now));
        _markChained(i);
      }
      return out;
    }
    if (roundaboutExit || m.synthetic && d < 300) return out;
    // Odpočet podle rychlosti: dálnice 1000/500/200 m, město 500/200 m, pomalu 200 m.
    final stages = speedKmh > 70
        ? const [1000.0, 500.0, 200.0]
        : speedKmh > 35
        ? const [500.0, 200.0]
        : const [200.0];
    // Pevné číslo stupně (1000 m = 0, 500 m = 1, 200 m = 2) – při zpomalení se seznam stupňů mění.
    int code(double st) => st >= 1000 ? 0 : (st >= 500 ? 1 : 2);
    // Nejmenší stupeň, do kterého už jsme vjeli: po „Za 500 metrů“ přijde i „Za 200“.
    for (var s = stages.length - 1; s >= 0; s--) {
      final st = stages[s];
      if (d > st) continue;
      final k = key * 10 + code(st);
      if (e.stageSpoken.contains(k)) return out;
      // Tento a větší stupně jsou vyřízené (zmeškané větší už nehlásit, např. po přepočtu trasy).
      for (var t = 0; t <= code(st); t++) {
        e.stageSpoken.add(key * 10 + t);
      }
      if (d - nowDist < 80) return out;
      // Před chvílí (po přepočtu) zaznělo „Za 250 metrů“ → „Za 200 metrů“ hned po něm ne.
      final prev = _stageAt[key];
      if (prev != null && prev - d < 120) return out;
      _stageAt[key] = d;
      // Návaznost („… a poté …“) jen v prvním odpočtu a v místě manévru – ne čtyřikrát dokola.
      final what = e.alertSpoken.contains(key) ? phrase(m) : withThen(i);
      e.alertSpoken.add(key);
      // Po přepočtu / zpožděná hláška: skutečná vzdálenost („Za 250 metrů“), ne „Za 500 metrů“.
      out.add('${spokenDistance(st - d > 40 ? d : st)} $what');
      return out;
    }
    return out;
  }

  /// Jedna hláška na startu. Blízko první odbočka → rovnou ona (a odpočet ji pak nehlásí znovu),
  /// jinak „Jeďte … po …“ z Valhally.
  String startPhrase(double traveled, DateTime now) {
    final t = _startPhrase(traveled, now);
    _lastText = t;
    _lastTextAt = now;
    return t;
  }

  String _startPhrase(double traveled, DateTime now) {
    final r = route;
    final first = r.maneuvers.isNotEmpty ? r.maneuvers.first : null;
    final fallback = (first?.preInstruction ?? 'Navigace spuštěna.').replaceAll(
      // „Jeďte na západ na 25833.“ → bez čísla místní silnice.
      RegExp(r' (na|po) \d{4,5}(?=[\s.,]|$)'),
      '',
    );
    // První manévr před námi (start mohl být až za první odbočkou – náhled trasy za jízdy).
    var i = -1;
    for (var k = 1; k < r.maneuvers.length; k++) {
      if (_at(r.maneuvers[k]) > traveled + 5) {
        i = k;
        break;
      }
    }
    if (i < 0) return fallback;
    final m = r.maneuvers[i];
    final d = _at(m) - traveled;
    if (d > 600) return fallback;
    final e = engine, key = m.beginShapeIndex;
    for (var t = 0; t < 3; t++) {
      e.stageSpoken.add(key * 10 + t);
    }
    e.alertSpoken.add(key);
    if (d < 80) {
      e.preSpoken.add(key);
      _markChained(i);
      return nowInstruction(i, now);
    }
    return '${spokenDistance(d)} ${withThen(i)}';
  }

  /// Zapamatuje si navazující manévr, který zazněl v „… a poté …“.
  void _markChained(int i) {
    final r = route;
    if (i + 1 >= r.maneuvers.length) return;
    final m = r.maneuvers[i], n = r.maneuvers[i + 1];
    final gap = _at(n) - _at(m);
    if (m.type == 26 && n.type == 27) {
      engine.chained[n.beginShapeIndex] = 0; // výjezd z kruháče už je v „vyjeďte druhým výjezdem“
    } else if (gap < 350 && n.type != 27 && !const {4, 5, 6}.contains(n.type)) {
      engine.chained[n.beginShapeIndex] = gap;
    }
  }

  double _at(Maneuver m) => route.cumulative[m.beginShapeIndex.clamp(0, route.cumulative.length - 1)];

  /// Pokyn v místě manévru, s návazností: „Odbočte vpravo a poté se držte vlevo na D35.“
  String nowInstruction(int i, DateTime now) {
    final m = route.maneuvers[i];
    if (const {4, 5, 6}.contains(m.type)) {
      destSpokenAt = now;
      return switch (m.type) {
        5 => 'Cíl je vpravo.',
        6 => 'Cíl je vlevo.',
        _ => 'Jste v cíli.',
      };
    }
    return '${_capital(withThen(i))}.';
  }

  /// Manévr + navazující manévr do 350 m („… a poté …“).
  String withThen(int i) {
    final r = route;
    final m = r.maneuvers[i];
    var text = phrase(m);
    if (i + 1 < r.maneuvers.length) {
      final n = r.maneuvers[i + 1];
      final gap = _at(n) - _at(m);
      if (m.type == 26 && n.type == 27) {
        // Kruhový objezd: „vyjeďte třetím výjezdem a poté pokračujte po I/35“.
        final road = roadAhead(n);
        if (road != null) text += ' a poté pokračujte${_po(road)}';
      } else if (gap < 350 && n.type != 27 && !const {4, 5, 6}.contains(n.type)) {
        final same = roadAhead(n) != null && roadAhead(n) == roadAhead(m);
        text += ' a poté ${phrase(n, noRoad: same)}';
      }
    }
    return text;
  }

  static bool _isStreet(String road) => !RegExp(r'^(D\d|I+/|E\d|silnici )').hasMatch(road);
  // Ulice: „do ulice Na Stínadlech“, „po ulici …“; silnice: „na D1“, „po silnici 13“.
  static String _on(String road) => _isStreet(road) ? ' do ulice $road' : ' na $road';
  static String _po(String road) => _isStreet(road) ? ' po ulici $road' : ' po $road';

  /// Jedna věta pokynu (malým písmenem): podle druhu manévru, se silnicí a směrem.
  String phrase(Maneuver m, {bool noRoad = false}) {
    if (m.synthetic) {
      final t = m.preInstruction ?? m.instruction;
      return t.isEmpty ? t : t[0].toLowerCase() + t.substring(1).replaceAll(RegExp(r'\.$'), '');
    }
    final road = noRoad ? null : roadAhead(m);
    final toward = m.exitToward.take(2).join(', ');
    final on = road == null ? '' : _on(road);
    final po = road == null ? '' : _po(road);
    final dir = toward.isNotEmpty ? ' směr $toward' : '';
    switch (m.type) {
      case 26:
        return roundaboutText(m);
      case 27:
        return 'opusťte kruhový objezd';
      case 9:
        return 'odbočte mírně vpravo$on';
      case 10:
        return 'odbočte vpravo$on';
      case 11:
        return 'odbočte ostře vpravo$on';
      case 16:
        return 'odbočte mírně vlevo$on';
      case 15:
        return 'odbočte vlevo$on';
      case 14:
        return 'odbočte ostře vlevo$on';
      case 8:
      case 22:
        return 'pokračujte rovně$po$dir';
      case 23:
        return 'na rozdvojení se držte vpravo${road != null ? ' a pokračujte$po' : ''}$dir';
      case 24:
        return 'na rozdvojení se držte vlevo${road != null ? ' a pokračujte$po' : ''}$dir';
      case 17:
      case 18:
        return 'najeďte vpravo na nájezd$on$dir';
      case 19:
        return 'najeďte vlevo na nájezd$on$dir';
      case 20:
        return 'sjeďte vpravo$on$dir';
      case 21:
        return 'sjeďte vlevo$on$dir';
      case 25:
      case 37:
      case 38:
        return 'připojte se${road != null ? ' na $road' : ' do provozu'}';
      case 4:
        return 'dorazíte do cíle';
      case 5:
        return 'cíl bude vpravo';
      case 6:
        return 'cíl bude vlevo';
      case 12:
      case 13:
        return 'otočte se';
    }
    final t = (m.preInstruction ?? m.instruction).split('. Poté').first.trim().replaceAll(RegExp(r'\.$'), '');
    return t.isEmpty ? t : t[0].toLowerCase() + t.substring(1);
  }

  static String roundaboutText(Maneuver m) {
    final n =
        m.roundaboutExit ?? int.tryParse(RegExp(r'(\d+)\. výjezd').firstMatch(m.instruction)?.group(1) ?? '');
    const ord = ['prvním', 'druhým', 'třetím', 'čtvrtým', 'pátým', 'šestým', 'sedmým', 'osmým'];
    final names = m.streetNames.where((s) => !RegExp(r'^\d{4,5}$').hasMatch(s));
    final road = names.isNotEmpty ? ' na ${names.first}' : '';
    if (n == null || n < 1 || n > ord.length) return 'na kruhovém objezdu vyjeďte$road';
    return 'na kruhovém objezdu vyjeďte ${ord[n - 1]} výjezdem$road';
  }

  static String _capital(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Silnice za manévrem: číslo (D1, I/35, 635) má přednost před názvem ulice.
  static String? roadAhead(Maneuver m) {
    // Silnice III. třídy (čtyř- a pětimístná čísla) řidič na značení nevidí – hlas je nečte.
    final names = m.streetNames.where((n) => !RegExp(r'^\d{4,5}$').hasMatch(n)).toList();
    final refs = names.where((n) => RegExp(r'^(D\d+|I+/\d+|\d{1,3})$').hasMatch(n)).toList();
    final ref = refs.isNotEmpty ? refs.first : (names.isNotEmpty ? names.first : null);
    if (ref == null) return null;
    // Holé číslo silnice → „silnici 635“ (D a I/ se čtou samy).
    return RegExp(r'^\d{1,3}$').hasMatch(ref) ? 'silnici $ref' : ref;
  }

  static String kmWords(double m) {
    if (m < 1000) return '${(m / 100).round() * 100} metrů';
    final k = (m / 1000).round();
    return '$k ${k == 1 ? 'kilometr' : (k < 5 ? 'kilometry' : 'kilometrů')}';
  }

  /// „Za 200 metrů“, „Za kilometr“, „Za 1,5 kilometru“.
  static String spokenDistance(double m) {
    if (m < 1000) {
      final r = m >= 300 ? (m / 100).round() * 100 : math.max(50, (m / 50).round() * 50);
      return 'Za $r metrů';
    }
    final km = (m / 100).round() / 10;
    if (km == km.roundToDouble()) {
      final k = km.round();
      if (k == 1) return 'Za kilometr';
      return 'Za $k ${k < 5 ? 'kilometry' : 'kilometrů'}';
    }
    return 'Za ${km.toString().replaceAll('.', ',')} kilometru';
  }
}
