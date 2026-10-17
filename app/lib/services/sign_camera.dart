import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

import 'sign_blobs.dart';
import 'sign_parse.dart';
import 'sign_store.dart';

/// Poloha vozidla v okamžiku snímku.
typedef VehicleFix = ({double lat, double lon, double? acc, double? heading, double speedKmh});

/// Jedna značka / tabule sledovaná přes několik snímků.
class _Track {
  final String color;
  Rect box; // vzpřímený obraz, 0..1
  final int firstMs;
  int lastMs;
  int frames = 1;
  double bestArea = 0;
  img.Image? crop;
  String shape;
  final texts = <String>{};
  SignRead? read;
  VehicleFix? fix;
  _Track(this.color, this.box, this.firstMs, this.shape) : lastMs = firstMs;
}

final _plate = RegExp(r'^\d[A-Z]{1,2}\d?\s?\d{4}$|^[A-Z]{1,3}\s?\d{3,5}$');

/// Kamera jako „palubní kamera“: zachytí všechny značky a tabule (barevné plochy + text),
/// uloží je s polohou do vlastní databáze a hned hlásí rychlost / výšku / hmotnost / délku.
class SignCamera {
  final VehicleFix? Function() fix;
  SignCamera(this.fix);

  CameraController? controller;
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final _tracker = SignTracker();
  final _tracks = <_Track>[];
  final _out = StreamController<SignRead>.broadcast();
  Stream<SignRead> get signs => _out.stream;
  final saved = ValueNotifier<int>(0); // uloženo v této jízdě
  bool _busy = false;
  int _lastMs = 0;

  Future<void> start() async {
    if (controller != null) return;
    final cams = await availableCameras();
    final back = cams.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cams.first,
    );
    final c = CameraController(
      back,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    controller = c;
    try {
      await c.initialize();
      await c.startImageStream(_onFrame);
    } catch (e) {
      controller = null;
      await c.dispose();
      rethrow;
    }
  }

  Future<void> stop() async {
    final c = controller;
    controller = null;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    await c.dispose();
    for (final t in [..._tracks]) {
      await _finish(t);
    }
    _tracks.clear();
  }

  static const _orient = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  Future<void> _onFrame(CameraImage frame) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_busy || now - _lastMs < 300) return; // ~3 snímky za sekundu
    final c = controller;
    if (c == null) return;
    _busy = true;
    _lastMs = now;
    try {
      final comp = _orient[c.value.deviceOrientation] ?? 0;
      final rot = (c.description.sensorOrientation - comp + 360) % 360;
      final bytes = frame.planes.first.bytes;
      final stride = frame.planes.first.bytesPerRow;
      final w = frame.width, h = frame.height;
      final uw = rot % 180 == 0 ? w : h, uh = rot % 180 == 0 ? h : w;
      final f = fix();
      final moving = f != null && f.speedKmh > 6;

      final text = await _recognizer.processImage(
        InputImage.fromBytes(
          bytes: bytes,
          metadata: InputImageMetadata(
            size: Size(w.toDouble(), h.toDouble()),
            rotation: InputImageRotationValue.fromRawValue(rot) ?? InputImageRotation.rotation0deg,
            format: InputImageFormat.nv21,
            bytesPerRow: stride,
          ),
        ),
      );
      final lines = [for (final b in text.blocks) ...b.lines];

      // Kandidáti: barevné plochy (značky, směrové tabule) + bílé tabule s textem.
      final cands = <(String, Rect, String, Rect)>[]; // barva, vzpřímeně 0..1, tvar, surově px
      for (final b in findBlobs(bytes, w, h, stride)) {
        final u = uprightRect(b.raw, w, h, rot);
        cands.add((b.color, _norm(u, uw, uh), b.shape, b.raw));
      }
      for (final b in text.blocks) {
        final r = b.boundingBox;
        final t = b.text.replaceAll('\n', ' ').trim();
        if (t.length < 2 || r.height < uh * 0.012 || _plate.hasMatch(t)) continue;
        final n = _norm(r, uw, uh);
        if (cands.any((c) => c.$2.inflate(0.01).contains(n.center))) continue;
        cands.add(('white', n, 'rect', rawRect(r, w, h, rot)));
      }

      for (final (color, box, shape, raw) in cands) {
        final inside = <String>[];
        for (final l in lines) {
          if (box.inflate(box.longestSide * 0.3).contains(_norm(l.boundingBox, uw, uh).center)) {
            inside.add(l.text.trim());
          }
        }
        // Přiřadit ke sledované značce (stejná barva, blízko poslední polohy).
        _Track? t;
        var best = double.infinity;
        for (final x in _tracks) {
          if (x.color != color || now - x.lastMs > 1200) continue;
          final d = (x.box.center - box.center).distance;
          if (d < math.max(x.box.longestSide, box.longestSide) * 1.5 + 0.03 && d < best) {
            best = d;
            t = x;
          }
        }
        if (t == null) {
          t = _Track(color, box, now, shape);
          _tracks.add(t);
        } else {
          t
            ..box = box
            ..lastMs = now
            ..frames += 1;
          if (shape != '?') t.shape = shape;
        }
        t.texts.addAll(inside.where((s) => s.isNotEmpty));
        if (f != null) t.fix = f;
        final area = box.width * box.height;
        if (area > t.bestArea * 1.15 && moving) {
          t.bestArea = area;
          t.crop = cropNv21(bytes, w, h, stride, rot, raw);
        }
        // Zákazové značky s číslem: hned ohlásit (potvrzení podle zvětšování).
        if (color == 'red') {
          for (final s in inside) {
            final p = parseSign(s);
            if (p == null) continue;
            t.read = p;
            final ok = _tracker.add(p, box.height * uh, now);
            if (ok != null) _out.add(ok);
          }
        }
      }
      // Hotové značky (už nejsou vidět) → uložit.
      for (final t in [..._tracks]) {
        if (now - t.lastMs > 1200) {
          _tracks.remove(t);
          await _finish(t);
        }
      }
    } catch (e) {
      debugPrint('sign camera: $e');
    } finally {
      _busy = false;
    }
  }

  static Rect _norm(Rect r, int w, int h) => Rect.fromLTRB(r.left / w, r.top / h, r.right / w, r.bottom / h);

  Future<void> _finish(_Track t) async {
    // Šum: jen jednou zahlédnuté; dlouho stejně velké = auto před námi, ne značka u cesty.
    final life = t.lastMs - t.firstMs;
    if (t.frames < (t.texts.isEmpty ? 3 : 2) || t.crop == null) return;
    if (life > 10000) return;
    final f = t.fix;
    final jpeg = await compute((img.Image i) => img.encodeJpg(i, quality: 80), t.crop!);
    await SignStore.instance.add(
      t: t.lastMs,
      lat: f?.lat,
      lon: f?.lon,
      acc: f?.acc,
      heading: f?.heading,
      speed: f?.speedKmh,
      color: t.color,
      shape: t.shape,
      box: [t.box.left, t.box.top, t.box.width, t.box.height],
      frames: t.frames,
      text: t.texts.isEmpty ? null : t.texts.join(' | '),
      kind: t.read?.kind.name,
      value: t.read?.value,
      jpeg: jpeg,
    );
    saved.value++;
  }

  Future<void> dispose() async {
    await stop();
    await _recognizer.close();
    await _out.close();
  }
}

/// Je kolem textu červený kruh (zákazová značka)? Vzorky na kružnici kolem čísla v NV21.
/// [r] je v souřadnicích otočeného (vzpřímeného) obrazu, [rot] otočení snímku senzoru.
bool redRing(Uint8List nv21, int w, int h, int stride, int rot, Rect r) {
  final cx = r.center.dx, cy = r.center.dy;
  final base = math.max(r.width, r.height) * 0.5;
  var red = 0, n = 0;
  for (final k in const [1.35, 1.6, 1.85]) {
    final rad = base * k;
    for (var a = 0; a < 16; a++) {
      final t = a * math.pi / 8;
      final ux = cx + rad * math.cos(t), uy = cy + rad * math.sin(t);
      // vzpřímený obraz → surový snímek senzoru
      final (x, y) = switch (rot) {
        90 => (uy, h - 1 - ux),
        180 => (w - 1 - ux, h - 1 - uy),
        270 => (w - 1 - uy, ux),
        _ => (ux, uy),
      };
      final xi = x.round(), yi = y.round();
      if (xi < 0 || yi < 0 || xi >= w || yi >= h) continue;
      final i = stride * h + (yi >> 1) * stride + (xi & ~1);
      if (i + 1 >= nv21.length) continue;
      final v = nv21[i], u = nv21[i + 1]; // NV21: V, U
      n++;
      if (v > 160 && u < 135 && v - u > 40) red++;
    }
  }
  return n >= 12 && red >= n * 0.18;
}
