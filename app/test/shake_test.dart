import 'package:flutter_test/flutter_test.dart';
import 'package:truck_nav/services/shake.dart';

void main() {
  final t0 = DateTime(2026, 11, 1, 8);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  test('tři silné záchvěvy do 1,5 s = zatřesení', () {
    final s = ShakeCounter();
    expect(s.add(25, 0, 0, at(0)), isFalse);
    expect(s.add(0, -24, 0, at(300)), isFalse);
    expect(s.add(22, 5, 3, at(600)), isTrue);
    // Hned další záchvěvy (ještě třese) okno znovu neotevřou.
    expect(s.add(25, 0, 0, at(900)), isFalse);
    expect(s.add(25, 0, 0, at(1200)), isFalse);
    expect(s.add(25, 0, 0, at(1500)), isFalse);
  });

  test('výmol (jeden ráz, víc měření těsně po sobě) ani houpání kabiny nespustí', () {
    final s = ShakeCounter();
    // Jeden ráz: tři měření za 100 ms.
    expect(s.add(30, 0, 0, at(0)), isFalse);
    expect(s.add(28, 0, 0, at(50)), isFalse);
    expect(s.add(26, 0, 0, at(100)), isFalse);
    // Houpání pod hranicí.
    for (var ms = 200; ms < 3000; ms += 60) {
      expect(s.add(9, 6, 4, at(ms)), isFalse);
    }
    // Rázy daleko od sebe (každé 2 s) se nesečtou.
    final s2 = ShakeCounter();
    expect(s2.add(25, 0, 0, at(0)), isFalse);
    expect(s2.add(25, 0, 0, at(2000)), isFalse);
    expect(s2.add(25, 0, 0, at(4000)), isFalse);
  });
}
