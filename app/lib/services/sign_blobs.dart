import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;

/// Barevná plocha ve snímku, která může být značka / tabule.
class Blob {
  final String color; // red / yellow / green / blue
  final Rect raw; // v pixelech surového snímku senzoru
  final double fill; // podíl vyplnění obálky
  Blob(this.color, this.raw, this.fill);

  String get shape {
    final a = raw.width / raw.height;
    final square = a > 0.75 && a < 1.33;
    if (square && fill < 0.6 && color == 'red') return 'round';
    if (square && fill > 0.68 && fill < 0.86) return 'round';
    if (square && fill >= 0.4 && fill <= 0.6) return 'triangle';
    if (fill >= 0.86) return 'rect';
    return '?';
  }
}

const _colors = ['', 'red', 'yellow', 'green', 'blue'];

/// Barva bodu z YUV (NV21): 0 = nic, 1 červená, 2 žlutá/oranžová, 3 zelená, 4 modrá.
int colorClass(int y, int u, int v) {
  final r = (y + 1.402 * (v - 128)).clamp(0, 255) / 255;
  final g = (y - 0.344 * (u - 128) - 0.714 * (v - 128)).clamp(0, 255) / 255;
  final b = (y + 1.772 * (u - 128)).clamp(0, 255) / 255;
  final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  final d = mx - mn;
  if (mx < 0.18 || d < 0.01) return 0;
  final s = d / mx;
  double h;
  if (mx == r) {
    h = 60 * (((g - b) / d) % 6);
  } else if (mx == g) {
    h = 60 * ((b - r) / d + 2);
  } else {
    h = 60 * ((r - g) / d + 4);
  }
  if (h < 0) h += 360;
  if ((h < 12 || h > 340) && s > 0.45 && mx > 0.25) return 1;
  if (h >= 18 && h < 55 && s > 0.55 && mx > 0.4) return 2;
  if (h >= 95 && h < 170 && s > 0.45 && mx > 0.2) return 3;
  if (h >= 195 && h < 250 && s > 0.5 && mx > 0.2) return 4;
  return 0;
}

/// Najde barevné plochy (značky, tabule) v NV21 snímku na mřížce ~160 bodů na šířku.
List<Blob> findBlobs(Uint8List nv21, int w, int h, int stride) {
  final s = math.max(2, (w / 160).floor()) & ~1;
  final gw = w ~/ s, gh = h ~/ s;
  final cls = Uint8List(gw * gh);
  final uv0 = stride * h;
  for (var gy = 0; gy < gh; gy++) {
    final y = gy * s;
    for (var gx = 0; gx < gw; gx++) {
      final x = gx * s;
      final i = uv0 + (y >> 1) * stride + (x & ~1);
      if (i + 1 >= nv21.length) continue;
      cls[gy * gw + gx] = colorClass(nv21[y * stride + x], nv21[i + 1], nv21[i]);
    }
  }
  final seen = Uint8List(gw * gh);
  final out = <Blob>[];
  final stack = <int>[];
  for (var start = 0; start < cls.length; start++) {
    final c = cls[start];
    if (c == 0 || seen[start] == 1) continue;
    var n = 0, x0 = gw, x1 = 0, y0 = gh, y1 = 0;
    stack.add(start);
    seen[start] = 1;
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      final px = p % gw, py = p ~/ gw;
      n++;
      if (px < x0) x0 = px;
      if (px > x1) x1 = px;
      if (py < y0) y0 = py;
      if (py > y1) y1 = py;
      for (final q in [p - 1, p + 1, p - gw, p + gw]) {
        if (q < 0 || q >= cls.length || seen[q] == 1 || cls[q] != c) continue;
        if ((q == p - 1 || q == p + 1) && q ~/ gw != py) continue;
        seen[q] = 1;
        stack.add(q);
      }
    }
    final bw = x1 - x0 + 1, bh = y1 - y0 + 1;
    if (n < 6 || bw * bh > gw * gh * 0.08) continue;
    final a = bw / bh;
    if (a < 0.2 || a > 5) continue;
    final fill = n / (bw * bh);
    if (fill < (c == 1 ? 0.2 : 0.5)) continue;
    // Dotýká se okraje snímku → značka není celá.
    if (x0 == 0 || y0 == 0 || x1 == gw - 1 || y1 == gh - 1) continue;
    out.add(
      Blob(
        _colors[c],
        Rect.fromLTRB(x0 * s.toDouble(), y0 * s.toDouble(), (x1 + 1) * s.toDouble(), (y1 + 1) * s.toDouble()),
        fill,
      ),
    );
  }
  return out;
}

/// Obdélník ze surového snímku do vzpřímeného obrazu (jak ho vidí řidič a ML Kit).
Rect uprightRect(Rect r, int w, int h, int rot) {
  Offset m(double x, double y) => switch (rot) {
    90 => Offset(h - y, x),
    180 => Offset(w - x, h - y),
    270 => Offset(y, w - x),
    _ => Offset(x, y),
  };
  return Rect.fromPoints(m(r.left, r.top), m(r.right, r.bottom));
}

/// Opak [uprightRect].
Rect rawRect(Rect r, int w, int h, int rot) => switch (rot) {
  90 => uprightRect(r, h, w, 270),
  270 => uprightRect(r, h, w, 90),
  _ => uprightRect(r, w, h, rot),
};

/// Výřez ze snímku (s okrajem), nejvýš [maxSide] px, otočený vzpřímeně.
img.Image cropNv21(Uint8List nv21, int w, int h, int stride, int rot, Rect raw, {int maxSide = 224}) {
  final m = math.max(raw.width, raw.height) * 0.2;
  final l = (raw.left - m).clamp(0, w - 1).toInt(), t = (raw.top - m).clamp(0, h - 1).toInt();
  final r = (raw.right + m).clamp(1, w).toInt(), b = (raw.bottom + m).clamp(1, h).toInt();
  final cw = r - l, ch = b - t;
  final k = math.max(1.0, math.max(cw, ch) / maxSide);
  final ow = math.max(1, (cw / k).floor()), oh = math.max(1, (ch / k).floor());
  final out = img.Image(width: ow, height: oh);
  final uv0 = stride * h;
  for (var oy = 0; oy < oh; oy++) {
    final y = t + (oy * k).floor();
    for (var ox = 0; ox < ow; ox++) {
      final x = l + (ox * k).floor();
      final yy = nv21[y * stride + x];
      final i = uv0 + (y >> 1) * stride + (x & ~1);
      final v = nv21[i] - 128, u = nv21[i + 1] - 128;
      out.setPixelRgb(
        ox,
        oy,
        (yy + 1.402 * v).clamp(0, 255).toInt(),
        (yy - 0.344 * u - 0.714 * v).clamp(0, 255).toInt(),
        (yy + 1.772 * u).clamp(0, 255).toInt(),
      );
    }
  }
  return rot == 0 ? out : img.copyRotate(out, angle: rot);
}
