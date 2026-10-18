import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../models/route.dart';
import 'map_style.dart';

/// Stažení mapy podél trasy do telefonu (MapLibre offline regiony).
///
/// Trasa se rozdělí na úseky ~25 km; každý úsek = obdélník s okrajem ~2 km,
/// zoom 8–14 (bližší zoom MapLibre dopočítá zvětšením). Předchozí stažená trasa se smaže.
Future<void> downloadRouteMap(TruckRoute route, {void Function(double progress)? onProgress}) async {
  await ml.setOfflineTileCountLimit(200000);
  for (final r in await ml.getListOfRegions()) {
    if (r.metadata['app'] == 'lkwnav-route') await ml.deleteOfflineRegion(r.id);
  }
  final boxes = _corridor(route);
  final styleUrl = await downloadStyleUrl();
  for (var i = 0; i < boxes.length; i++) {
    await ml.downloadOfflineRegion(
      ml.OfflineRegionDefinition(bounds: boxes[i], mapStyleUrl: styleUrl, minZoom: 8, maxZoom: 14),
      metadata: {'app': 'lkwnav-route', 'part': i},
      onEvent: (e) {
        if (e is ml.InProgress) onProgress?.call((i + e.progress / 100) / boxes.length);
      },
    );
    onProgress?.call((i + 1) / boxes.length);
  }
}

List<ml.LatLngBounds> _corridor(TruckRoute route) {
  const stepM = 25000.0, margin = 0.02; // ~2 km
  final out = <ml.LatLngBounds>[];
  final cum = route.cumulative;
  var start = 0;
  while (start < route.shape.length - 1) {
    var end = start;
    while (end < route.shape.length - 1 && cum[end] - cum[start] < stepM) {
      end++;
    }
    var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
    for (var i = start; i <= end; i++) {
      final p = route.shape[i];
      s = math.min(s, p.latitude);
      n = math.max(n, p.latitude);
      w = math.min(w, p.longitude);
      e = math.max(e, p.longitude);
    }
    out.add(
      ml.LatLngBounds(
        southwest: ml.LatLng(s - margin, w - margin),
        northeast: ml.LatLng(n + margin, e + margin),
      ),
    );
    start = end;
  }
  return out;
}
