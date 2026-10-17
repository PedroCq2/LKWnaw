import 'package:flutter_test/flutter_test.dart';
import 'package:truck_nav/services/stop_order.dart';

void main() {
  test('zastávky na přímce se seřadí po sobě', () {
    // Body na ose: start 0, zastávky na 5, 1, 3, 2, 4.
    final x = <double>[0, 5, 1, 3, 2, 4];
    final m = [
      for (final a in x) [for (final b in x) (a - b).abs()],
    ];
    expect(bestOrder(m), [2, 4, 3, 5, 1]);
  });

  test('okruh se vrátí na start', () {
    final x = <double>[0, 2, -2, 1];
    final m = [
      for (final a in x) [for (final b in x) (a - b).abs()],
    ];
    final o = bestOrder(m, returnToStart: true);
    expect(o.length, 3);
    // Délka okruhu = 8 (na +2 a zpět přes −2).
    var s = m[0][o.first];
    for (var i = 0; i < o.length - 1; i++) {
      s += m[o[i]][o[i + 1]];
    }
    s += m[o.last][0];
    expect(s, 8);
  });
}
