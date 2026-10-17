import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:truck_nav/services/sign_blobs.dart';
import 'package:truck_nav/services/sign_camera.dart';
import 'package:truck_nav/services/sign_parse.dart';

void main() {
  test('text na značce', () {
    expect(parseSign('80')?.kind, SignKind.speed);
    expect(parseSign('8O')?.value, 80);
    expect(parseSign('85'), isNull);
    expect(parseSign('3,8 m')?.kind, SignKind.height);
    expect(parseSign('3.5m')?.value, 3.5);
    expect(parseSign('12 m')?.kind, SignKind.length);
    expect(parseSign('12 t')?.kind, SignKind.weight);
    expect(parseSign('7,5 t')?.value, 7.5);
    expect(parseSign('Praha'), isNull);
    expect(parseSign('2024'), isNull);
  });

  test('potvrdí jen značku, ke které se blížíme', () {
    final s = parseSign('60')!;
    final t = SignTracker();
    expect(t.add(s, 20, 0), isNull);
    expect(t.add(s, 24, 300), isNull);
    expect(t.add(s, 30, 600), isNotNull);
    expect(t.add(s, 40, 900), isNull); // už ohlášená
    // nálepka na kamionu: stejně velká
    final k = SignTracker();
    for (var i = 0; i < 5; i++) {
      expect(k.add(s, 20, i * 300), isNull);
    }
  });

  test('červený kruh v NV21', () {
    const w = 200, h = 200;
    Uint8List img(bool red) {
      final b = Uint8List(w * h * 3 ~/ 2)..fillRange(0, w * h, 200);
      for (var y = 0; y < h; y += 2) {
        for (var x = 0; x < w; x += 2) {
          final d = ((x - 100) * (x - 100) + (y - 100) * (y - 100));
          final ring = red && d > 25 * 25 && d < 50 * 50;
          final i = w * h + (y >> 1) * w + x;
          b[i] = ring ? 220 : 128; // V
          b[i + 1] = ring ? 100 : 128; // U
        }
      }
      return b;
    }

    final r = Rect.fromCenter(center: const Offset(100, 100), width: 30, height: 24);
    expect(redRing(img(true), w, h, w, 0, r), isTrue);
    expect(redRing(img(false), w, h, w, 0, r), isFalse);
    expect(redRing(img(true), w, h, w, 90, r), isTrue);
  });

  test('najde značky ve snímku', () {
    const w = 640, h = 480;
    final b = Uint8List(w * h * 3 ~/ 2)..fillRange(0, w * h, 120);
    b.fillRange(w * h, b.length, 128);
    void paint(bool Function(int x, int y) f, int y0, int u0, int v0) {
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (!f(x, y)) continue;
          b[y * w + x] = y0;
          final i = w * h + (y >> 1) * w + (x & ~1);
          b[i] = v0;
          b[i + 1] = u0;
        }
      }
    }

    // červený kruh (rychlost) a modrá tabule
    paint(
      (x, y) {
        final d = (x - 150) * (x - 150) + (y - 150) * (y - 150);
        return d > 30 * 30 && d < 40 * 40;
      },
      80,
      100,
      210,
    );
    paint((x, y) => x > 380 && x < 520 && y > 100 && y < 170, 60, 190, 110);
    final blobs = findBlobs(b, w, h, w);
    expect(blobs.map((x) => x.color).toSet(), {'red', 'blue'});
    final red = blobs.firstWhere((x) => x.color == 'red');
    expect(red.shape, 'round');
    expect(red.raw.center.dx, closeTo(150, 8));
    expect(blobs.firstWhere((x) => x.color == 'blue').shape, 'rect');
    final crop = cropNv21(b, w, h, w, 90, red.raw);
    expect(crop.width, greaterThan(50));
    // otočení obrazu tam a zpět
    final r = const Rect.fromLTRB(10, 20, 50, 80);
    final u = uprightRect(r, w, h, 90);
    expect(rawRect(u, w, h, 90), r);
  });
}
