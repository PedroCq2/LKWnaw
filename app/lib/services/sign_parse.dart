/// Rozpoznání dopravních značek z textu na snímku kamery (bez obrazu – kvůli testům).
enum SignKind { speed, height, weight, length, axle }

extension SignKindLabel on SignKind {
  String get label => switch (this) {
    SignKind.speed => 'Nejvyšší povolená rychlost',
    SignKind.height => 'Max. výška',
    SignKind.weight => 'Max. hmotnost',
    SignKind.length => 'Max. délka',
    SignKind.axle => 'Max. na nápravu',
  };

  String unit(double v) => switch (this) {
    SignKind.speed => '${v.round()}',
    SignKind.height || SignKind.length => '${_n(v)} m',
    SignKind.weight || SignKind.axle => '${_n(v)} t',
  };
}

String _n(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1).replaceAll('.', ',');

class SignRead {
  final SignKind kind;
  final double value;
  const SignRead(this.kind, this.value);
  String get key => '${kind.name}:$value';
  String get text => kind.unit(value);
}

final _speed = RegExp(r'^(5|[1-9]0|1[0-3]0)$');
final _meters = RegExp(r'^(\d{1,2})(?:[,.](\d{1,2}))?\s?m$', caseSensitive: false);
final _tons = RegExp(r'^(\d{1,2})(?:[,.](\d))?\s?t$', caseSensitive: false);

/// Text jednoho bloku („80“, „3,8 m“, „12 t“) → značka, nebo null.
SignRead? parseSign(String raw) {
  final t = raw.trim().replaceAll('O', '0').replaceAll(RegExp(r'\s+'), ' ');
  if (_speed.hasMatch(t)) return SignRead(SignKind.speed, double.parse(t));
  final m = _meters.firstMatch(t);
  if (m != null) {
    final v = double.parse('${m.group(1)}.${m.group(2) ?? 0}');
    // Desetinné a do 5 m = výška (nejčastější), celé od 6 m = délka.
    if (m.group(2) != null && v >= 2 && v < 5) return SignRead(SignKind.height, v);
    if (m.group(2) == null && v >= 6 && v <= 25) return SignRead(SignKind.length, v);
    return null;
  }
  final w = _tons.firstMatch(t);
  if (w != null) {
    final v = double.parse('${w.group(1)}.${w.group(2) ?? 0}');
    if (v >= 2 && v <= 60) return SignRead(SignKind.weight, v);
  }
  return null;
}

/// Potvrzení značky: stejná značka na několika snímcích po sobě a zvětšuje se (blížíme se k ní).
/// Nálepka „80“ na kamionu před námi zůstává stejně velká → nepotvrdí se.
class SignTracker {
  final _obs = <String, List<(int, double)>>{}; // klíč → (čas ms, výška v obraze)
  final _done = <String, int>{}; // klíč → kdy potvrzeno (nehlásit znovu hned)

  /// Vrátí značku, když je právě potvrzená.
  SignRead? add(SignRead s, double boxHeight, int nowMs) {
    final l = _obs.putIfAbsent(s.key, () => []);
    l.removeWhere((o) => nowMs - o.$1 > 3000);
    l.add((nowMs, boxHeight));
    _obs.removeWhere((k, v) => v.isEmpty || nowMs - v.last.$1 > 3000);
    if (l.length < 3) return null;
    if (nowMs - (_done[s.key] ?? -100000) < 20000) return null;
    final first = l.first.$2, last = l.last.$2;
    if (last < first * 1.2 && l.length < 6) return null;
    _done[s.key] = nowMs;
    l.clear();
    return s;
  }
}
