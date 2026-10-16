import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/route.dart';
import '../navigation/nav_engine.dart';
import '../navigation/simulator.dart';
import '../services/geocoding.dart';
import '../services/restrictions.dart';
import '../services/lanes.dart';
import '../services/map_style.dart';
import '../services/settings.dart';
import '../services/valhalla.dart';
import '../theme.dart';
import '../widgets/nav_widgets.dart';
import 'profile_screen.dart';

ml.LatLng _ml(LatLng p) => ml.LatLng(p.latitude, p.longitude);
List<double> _xy(LatLng p) => [p.longitude, p.latitude];

class MapScreen extends StatefulWidget {
  final AppSettings settings;
  const MapScreen({super.key, required this.settings});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with SingleTickerProviderStateMixin {
  ml.MapLibreMapController? _map;
  bool _styleReady = false;
  final _tts = FlutterTts();
  final _search = TextEditingController();
  StreamSubscription<Position>? _posSub;
  Size _screen = Size.zero;

  // Poslední GPS (nebo simulovaný) fix.
  LatLng? _pos;
  double _heading = 0;
  double _speedKmh = 0;
  bool _follow = true;
  // Volná jízda bez trasy: po rozjetí mapa ve směru jízdy (jako při navigaci).
  bool _freeDrive = false;
  bool get _driveView => _navigating || _freeDrive;
  bool get _night => _settings.nightAt(_pos?.latitude, _pos?.longitude);
  Timer? _nightTimer;

  // Plynulá animace polohy/kamery mezi fixy (1 Hz).
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..addListener(_onAnimTick);
  LatLng? _dispPos;
  double _dispHeading = 0;
  double _dispZoom = 16;
  LatLng? _fromPos, _toPos;
  double _fromHead = 0, _toHead = 0, _fromZoom = 16, _toZoom = 16;
  DateTime? _lastFix;
  bool _camBusy = false;
  bool _meBusy = false;

  LatLng? _dest;
  String? _destName;
  TruckRoute? _route;
  List<RouteOption> _options = [];
  int _sel = 0;
  final Set<TruckRoute> _extrasLoaded = {};
  String? _styleJson;
  bool? _styleNight;
  Timer? _searchDebounce;
  int _searchSeq = 0;
  NavEngine? _engine;
  NavState? _nav;
  bool _navigating = false;
  bool _routing = false;
  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);
  bool _arrivedSpoken = false;
  RouteSimulator? _sim;
  final Set<RouteWarning> _warnSpoken = {};
  final List<LatLng> _excluded = []; // mosty, kterým se trasa vyhýbá (zásobování)

  List<Place> _results = [];
  List<Place> _parking = [];
  PoiKind _poiKind = PoiKind.parking;
  bool _searching = false;

  AppSettings get _settings => widget.settings;

  Future<void> _loadStyle() async {
    final night = _night;
    if (_styleNight == night && _styleJson != null) return;
    _styleNight = night;
    final json = await lkwStyle(night: night);
    if (mounted) setState(() => _styleJson = json);
  }

  @override
  void initState() {
    super.initState();
    _loadStyle();
    // Den/noc podle Slunce – kontrola jednou za minutu.
    _nightTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _styleNight != _night) setState(() {});
    });
    _initTts();
    _initLocation();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _sim?.stop();
    _searchDebounce?.cancel();
    _nightTimer?.cancel();
    _anim.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ------------------------------------------------------------ hlas

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('cs-CZ');
      await _tts.setSpeechRate(kIsWeb ? 1.0 : 0.5);
      await _tts.awaitSpeakCompletion(false);
    } catch (_) {}
  }

  Future<void> _say(String text) async {
    if (!_settings.voice || text.isEmpty) return;
    try {
      await _tts.speak(text);
    } catch (_) {}
  }

  // ------------------------------------------------------------ poloha

  Future<void> _initLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _toast('Zapněte prosím polohu (GPS).');
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        _toast('Bez oprávnění k poloze navigace nefunguje.');
        return;
      }
      // Poslední známá poloha hned – nečekat na první přesný GPS fix.
      if (!kIsWeb) {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null && _pos == null) _onPosition(last);
      }
    } catch (_) {}
    final LocationSettings settings;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'LKWnav',
          notificationText: 'Kamionová navigace běží',
          enableWakeLock: true,
        ),
      );
    } else {
      settings = const LocationSettings(accuracy: LocationAccuracy.bestForNavigation);
    }
    _posSub = Geolocator.getPositionStream(locationSettings: settings)
        .listen(_onPosition, onError: (e) => _toast('Chyba GPS: $e'));
  }

  void _onPosition(Position p) {
    if (_sim != null) return; // v simulaci se skutečné GPS ignoruje
    final speed = p.speed.isFinite && p.speed > 0 ? p.speed : 0.0;
    _onFix(LatLng(p.latitude, p.longitude), speed, p.heading.isFinite && p.heading >= 0 ? p.heading : null);
  }

  void _onFix(LatLng pos, double speedMps, double? heading, {bool simulated = false}) {
    if (_pos == null && kIsWeb) _webDemo();
    final speed = speedMps * 3.6;
    // Kurz z GPS je spolehlivý jen za jízdy.
    if (speed > 3 && heading != null) _heading = heading;
    _pos = pos;
    _speedKmh = speed;
    if (!_freeDrive && speed > 10 && _follow) {
      _freeDrive = true;
      _applyInsets();
    }

    if (_engine != null) {
      final nav = _engine!.update(pos);
      _nav = nav;
      if (_navigating) {
        _voiceGuidance(nav);
        _warningVoice(nav);
        if (nav.arrived && !_arrivedSpoken) {
          _arrivedSpoken = true;
          _say('Jste v cíli.');
        }
        if (_engine!.isOffRoute &&
            !_routing &&
            DateTime.now().difference(_lastReroute) > const Duration(seconds: 10)) {
          _lastReroute = DateTime.now();
          _say('Přepočítávám trasu.');
          _computeRoute(reroute: true);
        }
      }
    }
    _animateTo();
  }

  /// Web/test: `?dest=lat,lon&go=1` nastaví cíl (a spustí navigaci).
  void _webDemo() {
    final q = Uri.base.queryParameters;
    final d = q['dest']?.split(',');
    if (d == null || d.length != 2) return;
    final p = LatLng(double.parse(d[0]), double.parse(d[1]));
    Future.delayed(const Duration(seconds: 2), () async {
      _setDestination(p, q['name'] ?? 'Cíl');
      if (q['go'] == '1') {
        for (var i = 0; i < 40 && _route == null; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
        await Future.delayed(const Duration(seconds: 3));
        _startNavigation();
      }
    });
  }

  // ------------------------------------------------------------ kamera

  /// Cílová poloha/natočení/zoom pro aktuální stav a spuštění animace k nim.
  void _animateTo() {
    final pos = _pos;
    if (pos == null) return;
    var target = pos;
    var heading = _heading;
    final nav = _nav;
    final route = _route;
    if (_navigating && nav != null && route != null && nav.distanceFromRoute < NavEngine.offRouteMeters) {
      // Na trase: přichycená poloha a směr podle trasy (bez GPS šumu).
      target = nav.snapped;
      final seg = nav.segmentIndex;
      if (seg + 1 < route.shape.length) {
        heading = const Distance().bearing(route.shape[seg], route.shape[seg + 1]);
        if (heading < 0) heading += 360;
      }
    }
    var zoom = _toZoom;
    if (_driveView) {
      // Hystereze, aby zoom neskákal kolem hranic rychlosti.
      final keep = _toZoom < 15 ? 16.5 : _toZoom;
      zoom = _speedKmh > 85 ? 16.0 : (_speedKmh > 45 ? 16.8 : (_speedKmh < 35 ? 17.6 : keep));
    } else {
      zoom = _map?.cameraPosition?.zoom ?? 16;
      if (zoom < 12) zoom = 16;
    }

    final now = DateTime.now();
    final last = _lastFix;
    _lastFix = now;
    if (_dispPos == null) {
      _dispPos = _toPos = target;
      _dispHeading = _toHead = heading;
      _dispZoom = _toZoom = zoom;
      _applyCamera();
      if (mounted) setState(() {});
      return;
    }
    _fromPos = _dispPos;
    _fromHead = _dispHeading;
    _fromZoom = _dispZoom;
    _toPos = target;
    _toHead = heading;
    _toZoom = zoom;
    final gapMs = last == null ? 1000 : now.difference(last).inMilliseconds;
    _anim.duration = Duration(milliseconds: gapMs.clamp(300, 1500));
    _anim.forward(from: 0);
  }

  void _onAnimTick() {
    final t = _anim.value;
    final a = _fromPos, b = _toPos;
    if (a == null || b == null) return;
    _dispPos = LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
    var dh = (_toHead - _fromHead) % 360;
    if (dh > 180) dh -= 360;
    _dispHeading = (_fromHead + dh * t) % 360;
    _dispZoom = _fromZoom + (_toZoom - _fromZoom) * t;
    if (_follow) _applyCamera();
    _updateMeLayer();
    if (mounted) setState(() {});
  }

  void _applyCamera() {
    final map = _map;
    final pos = _dispPos;
    if (map == null || pos == null || _camBusy) return;
    final cam = _driveView
        ? ml.CameraPosition(
            target: _ml(pos),
            zoom: _dispZoom,
            bearing: _dispHeading,
            tilt: _settings.view3d ? 55 : 0,
          )
        : ml.CameraPosition(target: _ml(pos), zoom: _dispZoom, bearing: 0, tilt: 0);
    _camBusy = true;
    map.moveCamera(ml.CameraUpdate.newCameraPosition(cam)).whenComplete(() => _camBusy = false);
  }

  /// Horní odsazení, aby byl kamion ve spodní části obrazovky.
  double get _topInset => _driveView && _screen.height > 0 ? _screen.height * 0.42 : 0;

  Future<void> _applyInsets() async {
    try {
      await _map?.updateContentInsets(EdgeInsets.only(top: _topInset), false);
    } catch (_) {}
  }

  void _recenter() {
    setState(() => _follow = true);
    _applyInsets().then((_) => _applyCamera());
  }

  // ------------------------------------------------------------ vrstvy mapy

  Future<void> _onStyleLoaded() async {
    final m = _map;
    if (m == null) return;
    _styleReady = false;
    const empty = {'type': 'FeatureCollection', 'features': []};
    try {
      for (final id in ['alts', 'route', 'warn', 'parking', 'dest', 'me']) {
        await m.addGeoJsonSource(id, empty);
      }
      await m.addLineLayer(
        'route',
        'route-casing',
        const ml.LineLayerProperties(
          lineColor: Lkw.routeCasing,
          lineWidth: 14,
          lineJoin: 'round',
          lineCap: 'round',
        ),
      );
      await m.addLineLayer(
        'route',
        'route-line',
        const ml.LineLayerProperties(
          lineColor: Lkw.routeLine,
          lineWidth: 9,
          lineJoin: 'round',
          lineCap: 'round',
        ),
      );
      // Alternativy vždy pod vybranou trasou.
      await m.addLineLayer(
        'alts',
        'alts-casing',
        const ml.LineLayerProperties(
          lineColor: Lkw.altCasing,
          lineWidth: 11,
          lineJoin: 'round',
          lineCap: 'round',
        ),
        belowLayerId: 'route-casing',
      );
      await m.addLineLayer(
        'alts',
        'alts-line',
        const ml.LineLayerProperties(
          lineColor: Lkw.altLine,
          lineWidth: 7,
          lineJoin: 'round',
          lineCap: 'round',
        ),
        belowLayerId: 'route-casing',
      );
      await m.addCircleLayer(
        'dest',
        'dest-circle',
        const ml.CircleLayerProperties(
          circleRadius: 10,
          circleColor: '#E53935',
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ),
      );
      await m.addCircleLayer(
        'parking',
        'parking-circle',
        const ml.CircleLayerProperties(
          circleRadius: 13,
          circleColor: '#1565C0',
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2,
        ),
      );
      await m.addSymbolLayer(
        'parking',
        'parking-label',
        const ml.SymbolLayerProperties(
          textField: ['get', 'l'],
          textSize: 16,
          textColor: '#FFFFFF',
          textFont: ['Noto Sans Bold'],
          textAllowOverlap: true,
          textIgnorePlacement: true,
        ),
      );
      await m.addCircleLayer(
        'warn',
        'warn-circle',
        const ml.CircleLayerProperties(
          circleRadius: 17,
          circleColor: [
            'case',
            [
              '==',
              ['get', 'cam'],
              true,
            ],
            '#FFC107',
            '#FFFFFF',
          ],
          circleStrokeColor: [
            'case',
            [
              '==',
              ['get', 'cam'],
              true,
            ],
            '#FFFFFF',
            '#D50000',
          ],
          circleStrokeWidth: 4,
          circlePitchAlignment: 'viewport',
        ),
      );
      await m.addSymbolLayer(
        'warn',
        'warn-label',
        const ml.SymbolLayerProperties(
          textField: ['get', 'label'],
          textSize: 11,
          textColor: '#000000',
          textFont: ['Noto Sans Bold'],
          textAllowOverlap: true,
          textIgnorePlacement: true,
        ),
      );
      await m.addImage('truck-arrow', await _arrowPng());
      await m.addSymbolLayer(
        'me',
        'me-arrow',
        const ml.SymbolLayerProperties(
          iconImage: 'truck-arrow',
          iconSize: 0.55,
          iconRotate: ['get', 'h'],
          iconRotationAlignment: 'map',
          iconPitchAlignment: 'map',
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
      );
      _styleReady = true;
      await _syncLayers();
      await _applyInsets();
      if (_follow) _applyCamera();
    } catch (e) {
      debugPrint('style layers: $e');
    }
  }

  Map<String, dynamic> _points(Iterable<(LatLng, Map<String, dynamic>)> pts) => {
    'type': 'FeatureCollection',
    'features': [
      for (final (p, props) in pts)
        {
          'type': 'Feature',
          'properties': props,
          'geometry': {'type': 'Point', 'coordinates': _xy(p)},
        },
    ],
  };

  Future<void> _syncLayers() async {
    final m = _map;
    if (m == null || !_styleReady) return;
    try {
      final r = _route;
      List<double> xy(LatLng p) => _xy(p);
      await m.setGeoJsonSource('alts', {
        'type': 'FeatureCollection',
        'features': [
          for (final o in _options)
            if (o.route != r)
              {
                'type': 'Feature',
                'properties': <String, dynamic>{},
                'geometry': {'type': 'LineString', 'coordinates': o.route.shape.map(xy).toList()},
              },
        ],
      });
      await m.setGeoJsonSource('route', {
        'type': 'FeatureCollection',
        'features': [
          if (r != null)
            {
              'type': 'Feature',
              'properties': <String, dynamic>{},
              'geometry': {'type': 'LineString', 'coordinates': r.shape.map(_xy).toList()},
            },
        ],
      });
      await m.setGeoJsonSource(
        'warn',
        _points([
          for (final w in r?.warnings ?? const <RouteWarning>[])
            if (w.type != WarningType.noOvertakingHgv)
              (
                w.point,
                {
                  'label': w.type == WarningType.speedCamera || w.type == WarningType.noOvertakingHgv
                      ? ''
                      : w.label.replaceAll(' ', ''),
                  'cam': w.type == WarningType.speedCamera,
                },
              ),
        ]),
      );
      final letter = switch (_poiKind) {
        PoiKind.parking => 'P',
        PoiKind.service => 'S',
        PoiKind.fuel => 'D',
      };
      await m.setGeoJsonSource(
        'parking',
        _points([
          for (final p in _parking) (p.point, {'l': letter}),
        ]),
      );
      await m.setGeoJsonSource('dest', _points([if (_dest != null) (_dest!, {})]));
      await _updateMeLayer();
    } catch (e) {
      debugPrint('sync layers: $e');
    }
  }

  /// Šipka vozidla jako vrstva mapy – vždy přesně na silnici, v 3D leží naplocho.
  Future<void> _updateMeLayer() async {
    final m = _map;
    final p = _dispPos ?? _pos;
    if (m == null || !_styleReady || _meBusy) return;
    _meBusy = true;
    try {
      await m.setGeoJsonSource(
        'me',
        _points([
          if (p != null) (p, {'h': _dispHeading}),
        ]),
      );
    } catch (_) {
    } finally {
      _meBusy = false;
    }
  }

  static Future<Uint8List> _arrowPng() async {
    const size = 120.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final path = ui.Path()
      ..moveTo(size / 2, 8)
      ..lineTo(size - 16, size - 12)
      ..lineTo(size / 2, size - 34)
      ..lineTo(16, size - 12)
      ..close();
    c.drawPath(
      path.shift(const Offset(0, 4)),
      Paint()
        ..color = const Color(0x55000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    c.drawPath(path, Paint()..color = const Color(0xFFFF3D00));
    c.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeJoin = StrokeJoin.round,
    );
    final img = await rec.endRecording().toImage(size.toInt(), size.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  // ------------------------------------------------------------ hlasové pokyny

  void _voiceGuidance(NavState nav) {
    final i = nav.nextManeuverIndex;
    if (i < 0) return;
    final m = _route!.maneuvers[i];
    final d = nav.distanceToNextManeuver;
    final mps = _speedKmh / 3.6;
    final pre = math.max(60.0, mps * 8);
    final alert = _speedKmh > 80 ? 1500.0 : (_speedKmh > 50 ? 800.0 : 300.0);
    if (d <= pre) {
      // Klíč = místo manévru (indexy se mění, když se doplní pokyny na rozdvojení).
      if (_engine!.preSpoken.add(m.beginShapeIndex)) {
        _engine!.alertSpoken.add(m.beginShapeIndex);
        _say(m.preInstruction ?? m.instruction);
      }
    } else if (d <= alert && d > pre + 150) {
      if (_engine!.alertSpoken.add(m.beginShapeIndex)) {
        _say('${_spokenDistance(d)} ${m.alertInstruction ?? m.instruction}');
      }
    }
  }

  void _warningVoice(NavState nav) {
    for (final w in _route?.warnings ?? const <RouteWarning>[]) {
      final d = w.atMeters - nav.traveled;
      if (d < 0) continue;
      if (d > 1200) break;
      final speak = w.violates
          ? d <= 1000
          : (w.type == WarningType.speedCamera && d <= 500) ||
                (w.type == WarningType.noOvertakingHgv && d <= 300);
      if (speak && _warnSpoken.add(w)) {
        final dist = _spokenDistance(d).replaceAll(',', '');
        if (w.type == WarningType.speedCamera) {
          _say('$dist radar.');
        } else if (w.type == WarningType.noOvertakingHgv) {
          _say(
            'Zákaz předjíždění nákladních vozidel${w.note != null ? ', ${w.note!.replaceAll('–', ' až ').replaceAll(' h', ' hodin')}' : ''}.',
          );
        } else {
          final unit = w.type == WarningType.weight || w.type == WarningType.axleLoad ? 'tun' : 'metru';
          final v = w.value!.toStringAsFixed(1).replaceAll('.', ',');
          _say('Pozor! $dist ${w.spokenName} $v $unit. Vaše vozidlo limit překračuje.');
        }
      }
    }
  }

  String _spokenDistance(double m) {
    if (m < 1000) return 'Za ${math.max(50, (m / 50).round() * 50)} metrů,';
    final km = (m / 100).round() / 10;
    if (km == km.roundToDouble()) {
      final k = km.round();
      final w = k == 1 ? 'kilometr' : (k < 5 ? 'kilometry' : 'kilometrů');
      return 'Za $k $w,';
    }
    return 'Za ${km.toString().replaceAll('.', ',')} kilometru,';
  }

  // ------------------------------------------------------------ trasa

  Future<void> _computeRoute({bool reroute = false}) async {
    final from = _pos;
    final to = _dest;
    if (to == null) return;
    if (from == null) {
      _toast('Čekám na GPS polohu…');
      return;
    }
    setState(() => _routing = true);
    try {
      final client = ValhallaClient(_settings.valhallaUrl);
      final heading = reroute || _speedKmh > 5 ? _heading : null;
      // Při navigaci jen jedna trasa (rychlý přepočet), jinak varianty na výběr.
      final opts = reroute || _navigating
          ? [
              RouteOption(
                'Trasa',
                await client.route(
                  from: from,
                  to: to,
                  profile: _settings.profile,
                  heading: heading,
                  delivery: _settings.delivery,
                  exclude: _excluded,
                ),
              ),
            ]
          : await client.routeOptions(
              from: from,
              to: to,
              profile: _settings.profile,
              heading: heading,
              delivery: _settings.delivery,
              exclude: _excluded,
            );
      if (!mounted || opts.isEmpty) return;
      _options = opts;
      _extrasLoaded.clear();
      await _selectRoute(0, fit: !reroute && !_navigating);
    } on RoutingException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('Chyba výpočtu trasy: $e');
    } finally {
      if (mounted) setState(() => _routing = false);
    }
  }

  Future<void> _selectRoute(int i, {bool fit = false}) async {
    if (i >= _options.length) return;
    final r = _options[i].route;
    setState(() {
      _sel = i;
      _route = r;
      _engine = NavEngine(r);
      _nav = _pos == null ? null : _engine!.update(_pos!);
      _arrivedSpoken = false;
      _warnSpoken.clear();
    });
    await _syncLayers();
    if (fit) _fitRoute(r, all: true);
    if (_extrasLoaded.add(r)) _loadRouteExtras(ValhallaClient(_settings.valhallaUrl), r);
  }

  /// Rychlostní limity a kamionové výstrahy – na pozadí, trasa je použitelná hned.
  Future<void> _loadRouteExtras(ValhallaClient client, TruckRoute r) async {
    try {
      await client.loadEdgeAttributes(r);
      if (mounted) setState(() {});
      await enrichManeuvers(r);
      if (mounted) setState(() {});
    } catch (_) {}
    try {
      final w = await loadRouteWarnings(r, _settings.profile, delivery: _settings.delivery);
      if (!mounted || _route != r) return;
      setState(() => r.warnings = w);
      await _syncLayers();
      // Zásobování: trasa nesmí přes most s nižší nosností → vyhnout se mu a přepočítat.
      final bridges = w.where((x) => x.onBridge && x.violates).toList();
      if (_settings.delivery && bridges.isNotEmpty && _excluded.length < 10) {
        _excluded.addAll(bridges.map((b) => b.point));
        _toast('Vyhýbám se mostu s nosností ${bridges.first.label} – přepočítávám trasu.');
        await _computeRoute(reroute: _navigating);
        return;
      }
      final bad = w.where((x) => x.violates).length;
      if (bad > 0) _toast('Pozor: na trase je $bad omezení, která vaše vozidlo překračuje.');
    } catch (_) {}
  }

  Future<void> _fitRoute(TruckRoute r, {bool all = false}) async {
    setState(() => _follow = false);
    await _updateMeLayer();
    var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
    for (final p in [
      for (final o in all ? _options.map((o) => o.route) : [r]) ...o.shape,
    ]) {
      s = math.min(s, p.latitude);
      n = math.max(n, p.latitude);
      w = math.min(w, p.longitude);
      e = math.max(e, p.longitude);
    }
    try {
      await _map?.updateContentInsets(EdgeInsets.zero, false);
      await _map?.moveCamera(ml.CameraUpdate.bearingTo(0));
      await _map?.moveCamera(ml.CameraUpdate.tiltTo(0));
      await _map?.animateCamera(
        ml.CameraUpdate.newLatLngBounds(
          ml.LatLngBounds(southwest: ml.LatLng(s, w), northeast: ml.LatLng(n, e)),
          left: 40,
          top: 110,
          right: 90,
          bottom: 330,
        ),
        duration: const Duration(milliseconds: 700),
      );
    } catch (_) {}
  }

  Future<void> _startNavigation() async {
    final r = _route;
    if (r == null) return;
    setState(() {
      _navigating = true;
      _follow = true;
      _results = [];
      _options = [_options[_sel]];
      _sel = 0;
    });
    await _syncLayers();
    await _applyInsets();
    await _updateMeLayer();
    WakelockPlus.enable();
    final first = r.maneuvers.isNotEmpty ? r.maneuvers.first : null;
    _say(first?.preInstruction ?? 'Navigace spuštěna.');
    if (_settings.simulate) {
      _sim?.stop();
      _sim = RouteSimulator(
        r,
        _settings.profile.maxSpeed,
        (p, s, h) => _onFix(p, s, h, simulated: true),
        startAt: _nav?.traveled ?? 0,
      )..start();
    }
    _animateTo();
  }

  Future<void> _stopNavigation() async {
    WakelockPlus.disable();
    _sim?.stop();
    _sim = null;
    setState(() {
      _navigating = false;
      _route = null;
      _options = [];
      _engine = null;
      _nav = null;
      _dest = null;
      _destName = null;
      _parking = [];
      _follow = true;
    });
    await _applyInsets();
    await _syncLayers();
    _applyCamera();
  }

  void _setDestination(LatLng p, String name) {
    FocusScope.of(context).unfocus();
    _excluded.clear();
    setState(() {
      _dest = p;
      _destName = name;
      _results = [];
    });
    _syncLayers();
    _computeRoute(reroute: _navigating);
  }

  Future<void> _doSearch(String q, {bool quiet = false}) async {
    if (q.trim().length < 3) return;
    _searchDebounce?.cancel();
    final seq = ++_searchSeq;
    setState(() => _searching = true);
    try {
      final r = await searchPlaces(q, near: _pos);
      if (!mounted || seq != _searchSeq) return;
      setState(() => _results = r);
      if (r.isEmpty && !quiet) _toast('Nic nenalezeno.');
    } catch (e) {
      _toast('Vyhledávání selhalo: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  static IconData _poiIcon(PoiKind k) => switch (k) {
    PoiKind.parking => Icons.local_parking,
    PoiKind.service => Icons.build,
    PoiKind.fuel => Icons.local_gas_station,
  };

  void _choosePoi() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final k in PoiKind.values)
              ListTile(
                leading: Icon(_poiIcon(k)),
                title: Text(k.label),
                onTap: () {
                  Navigator.pop(ctx);
                  _findPois(k);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _findPois(PoiKind kind) async {
    // Při navigaci hledej ~15 km před vozidlem po trase, jinak kolem polohy.
    LatLng? center = _pos;
    if (_navigating && _route != null && _nav != null) {
      final target = math.min(_nav!.traveled + 15000, _route!.cumulative.last);
      final idx = _route!.cumulative.indexWhere((c) => c >= target);
      center = _route!.shape[idx < 0 ? _route!.shape.length - 1 : idx];
    }
    if (center == null) {
      _toast('Čekám na GPS polohu…');
      return;
    }
    _toast('Hledám: ${kind.label.toLowerCase()}…');
    try {
      final places = await findTruckPois(center, kind);
      if (!mounted) return;
      setState(() {
        _parking = places;
        _poiKind = kind;
      });
      await _syncLayers();
      if (places.isEmpty) {
        _toast('V okolí 30 km nic nenalezeno.');
        return;
      }
      _showPoiSheet(places, kind);
    } catch (e) {
      _toast('Hledání selhalo: $e');
    }
  }

  void _showPoiSheet(List<Place> places, PoiKind kind) {
    const dist = Distance();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          children: [
            ListTile(title: Text(kind.label, style: Theme.of(ctx).textTheme.titleMedium)),
            for (final p in places.take(30))
              ListTile(
                leading: CircleAvatar(child: Icon(_poiIcon(kind), size: 20)),
                title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        if (p.kind != null) p.kind!,
                        if (_pos != null) formatDistance(dist(_pos!, p.point)),
                      ].join(' · '),
                    ),
                    if (p.features.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            for (final f in p.features)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Theme.of(ctx).colorScheme.secondaryContainer,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(f, style: const TextStyle(fontSize: 12)),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
                isThreeLine: p.features.isNotEmpty,
                onTap: () {
                  Navigator.pop(ctx);
                  _setDestination(p.point, p.name);
                  if (_navigating) _say('Naviguji na ${p.name}.');
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openProfile() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => ProfileScreen(settings: _settings)),
    );
    if (changed == true) {
      setState(() {});
      if (_dest != null) _computeRoute(reroute: _navigating);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final route = _route;
    final nav = _nav;
    if (_styleNight != _night) _loadStyle();
    final limitRaw = nav != null ? route?.speedLimitAt(nav.segmentIndex) : null;
    final limit = limitRaw == null ? null : math.min(limitRaw, _settings.profile.maxSpeed);
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final panelH = route == null ? 0.0 : (_navigating ? 104.0 : 270.0);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(
        builder: (context, box) {
          if (box.biggest != _screen) {
            _screen = box.biggest;
            WidgetsBinding.instance.addPostFrameCallback((_) => _applyInsets());
          }
          return Stack(
            children: [
              if (_styleJson == null)
                const ColoredBox(
                  color: Lkw.graphite,
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Listener(
                  onPointerMove: (e) {
                    if (_follow && e.delta.distance > 1.5) {
                      setState(() => _follow = false);
                    }
                  },
                  child: ml.MapLibreMap(
                    styleString: _styleJson!,
                    initialCameraPosition: const ml.CameraPosition(target: ml.LatLng(49.8, 15.5), zoom: 6),
                    onMapCreated: (c) => _map = c,
                    onStyleLoadedCallback: _onStyleLoaded,
                    trackCameraPosition: true,
                    compassEnabled: false,
                    rotateGesturesEnabled: true,
                    tiltGesturesEnabled: true,
                    attributionButtonPosition: ml.AttributionButtonPosition.bottomLeft,
                    // Atribuce OSM je v Nastavení → O aplikaci, na mapě nepřekáží.
                    attributionButtonMargins: const math.Point(-200, -200),
                    attributionButtonColor: Colors.transparent,
                    logoEnabled: false,
                    webPreserveDrawingBuffer: true,
                    onMapLongClick: (_, p) => _setDestination(
                      LatLng(p.latitude, p.longitude),
                      '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}',
                    ),
                  ),
                ),
              SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_navigating && route != null) _banner(route, nav) else _searchBar(),
                    if (!_navigating && _results.isNotEmpty) _resultsList(),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                                  const Spacer(),
                          if (_navigating) _warningsColumn(route, nav),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Pravý sloupec tlačítek
              Positioned(
                right: 12,
                bottom: panelH + 16 + bottomPad,
                child: Column(
                  children: [
                    if (!_navigating)
                      RoundButton(
                        icon: Icons.local_shipping,
                        tooltip: 'Profil vozidla',
                        onPressed: _openProfile,
                      ),
                    RoundButton(
                      icon: Icons.local_parking,
                      tooltip: 'Truckparky, servisy, nafta',
                      onPressed: _choosePoi,
                    ),
                    RoundButton(
                      icon: _settings.voice ? Icons.volume_up : Icons.volume_off,
                      tooltip: 'Hlas',
                      onPressed: () {
                        setState(() => _settings.voice = !_settings.voice);
                        if (!_settings.voice) _tts.stop();
                        _settings.save();
                      },
                    ),
                    RoundButton(
                      icon: _settings.view3d ? Icons.view_in_ar : Icons.map_outlined,
                      tooltip: '2D / 3D',
                      onPressed: () {
                        setState(() => _settings.view3d = !_settings.view3d);
                        _settings.save();
                        _applyCamera();
                      },
                    ),
                    if (!_follow)
                      RoundButton(
                        icon: Icons.my_location,
                        tooltip: 'Moje poloha',
                        onPressed: _recenter,
                        color: Lkw.amber,
                      ),
                  ],
                ),
              ),
              if (_navigating && (limit != null || _speedKmh > 0))
                Positioned(
                  left: 12,
                  bottom: panelH + 16 + bottomPad,
                  child: SpeedWidget(limit: limit, speedKmh: _speedKmh),
                ),
              if (route != null) Positioned(left: 0, right: 0, bottom: 0, child: _bottomPanel(route)),
              if (_routing) const Center(child: CircularProgressIndicator()),
            ],
          );
        },
      ),
    );
  }

  Widget _banner(TruckRoute route, NavState? nav) {
    final i = nav?.nextManeuverIndex ?? -1;
    final m = i >= 0 ? route.maneuvers[i] : null;
    Maneuver? then;
    if (m != null && i + 1 < route.maneuvers.length) {
      final gap =
          route.cumulative[route.maneuvers[i + 1].beginShapeIndex] - route.cumulative[m.beginShapeIndex];
      if (gap < 500) then = route.maneuvers[i + 1];
    }
    final road = nav == null ? null : route.roadNameAt(nav.segmentIndex);
    return ManeuverBanner(
      maneuver: m,
      distance: nav?.distanceToNextManeuver ?? 0,
      then: then,
      road: road == null || road.isEmpty ? null : road,
      roadKm: road == null || nav == null ? null : route.kilometerAt(nav.traveled, road),
    );
  }

  Widget _warningsColumn(TruckRoute? route, NavState? nav) {
    if (route == null || nav == null) return const SizedBox.shrink();
    final ahead = route.warnings
        .where((w) {
          final d = w.atMeters - nav.traveled;
          return d > -5 && d < (w.type == WarningType.speedCamera ? 1500 : 3000);
        })
        .take(3)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(top: 10, right: 8),
      child: Column(
        children: [
          for (final w in ahead) WarningCard(w: w, distance: math.max(0, w.atMeters - nav.traveled)),
        ],
      ),
    );
  }

  void _onSearchChanged(String q) {
    _searchDebounce?.cancel();
    if (q.trim().length < 3) {
      if (_results.isNotEmpty) setState(() => _results = []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 400), () => _doSearch(q, quiet: true));
  }

  Widget _searchBar() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: Material(
      color: Lkw.panel,
      elevation: 8,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(16),
      child: TextField(
        controller: _search,
        textInputAction: TextInputAction.search,
        onChanged: _onSearchChanged,
        onSubmitted: (q) => _doSearch(q),
        style: const TextStyle(color: Lkw.text, fontSize: 17),
        cursorColor: Lkw.amber,
        decoration: InputDecoration(
          hintText: 'Firma, sklad, adresa… (např. kaufland dc olomouc)',
          hintStyle: const TextStyle(color: Lkw.muted, fontSize: 15),
          prefixIcon: const Icon(Icons.search, color: Lkw.amber),
          suffixIcon: _searching
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  icon: const Icon(Icons.clear, color: Lkw.muted),
                  onPressed: () => setState(() {
                    _search.clear();
                    _results = [];
                  }),
                ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    ),
  );

  Widget _resultsList() {
    const dist = Distance();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Material(
        color: Lkw.panel,
        elevation: 8,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: _screen.height * 0.5),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: _results.length,
            separatorBuilder: (_, _) => const Divider(height: 1, color: Lkw.panelHi),
            itemBuilder: (_, i) {
              final r = _results[i];
              final sub = [
                if (r.kind != null) r.kind!,
                if (r.address != null && r.address != r.name) r.address!,
              ].join(' · ');
              return ListTile(
                leading: const Icon(Icons.place, color: Lkw.amber),
                title: Text(
                  r.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Lkw.text, fontWeight: FontWeight.w700),
                ),
                subtitle: sub.isEmpty
                    ? null
                    : Text(
                        sub,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Lkw.muted),
                      ),
                trailing: _pos == null
                    ? null
                    : Text(
                        formatDistance(dist(_pos!, r.point)),
                        style: const TextStyle(color: Lkw.muted, fontSize: 13),
                      ),
                onTap: () => _setDestination(r.point, r.name),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _bottomPanel(TruckRoute route) {
    final nav = _nav;
    final remainingM = nav?.remaining ?? route.lengthKm * 1000;
    final ratio = route.lengthKm > 0 ? remainingM / (route.lengthKm * 1000) : 0;
    final remainingSec = route.timeSec * ratio;
    final eta = DateTime.now().add(Duration(seconds: remainingSec.round()));
    final etaStr = '${eta.hour}:${eta.minute.toString().padLeft(2, '0')}';
    final bad = route.warnings.where((w) => w.violates).length;

    return Container(
      decoration: const BoxDecoration(
        color: Lkw.panel,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [BoxShadow(blurRadius: 16, color: Colors.black54)],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: _navigating
              ? Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            formatDuration(Duration(seconds: remainingSec.round())),
                            style: const TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w900,
                              color: Lkw.amber,
                            ),
                          ),
                          Text(
                            '${formatDistance(remainingM)} · příjezd $etaStr',
                            style: const TextStyle(fontSize: 17, color: Lkw.text),
                          ),
                          if (_settings.delivery)
                            const Text(
                              'ZÁSOBOVÁNÍ',
                              style: TextStyle(color: Lkw.amber, fontSize: 12, fontWeight: FontWeight.w800),
                            ),
                        ],
                      ),
                    ),
                    _panelButton(Icons.alt_route, 'Přehled trasy', () => _fitRoute(route), Lkw.panelHi),
                    const SizedBox(width: 10),
                    _panelButton(Icons.close, 'Ukončit navigaci', _stopNavigation, Lkw.danger),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_destName != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            const Icon(Icons.flag, color: Lkw.amber, size: 20),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _destName!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Lkw.text,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    SizedBox(
                      height: 108,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final (i, o) in _options.indexed)
                            RouteCard(
                              label: o.label,
                              route: o.route,
                              selected: i == _sel,
                              onTap: () => _selectRoute(i),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        FilterChip(
                          avatar: const Icon(Icons.storefront, size: 18),
                          label: const Text('Zásobování'),
                          selected: _settings.delivery,
                          selectedColor: Lkw.amberDark,
                          visualDensity: VisualDensity.compact,
                          onSelected: (v) {
                            setState(() => _settings.delivery = v);
                            _settings.save();
                            _excluded.clear();
                            _computeRoute();
                          },
                        ),
                        if (bad > 0)
                          Chip(
                            avatar: const Icon(Icons.warning, size: 16, color: Lkw.danger),
                            label: Text('$bad omezení'),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (_settings.simulate)
                          const Chip(
                            avatar: Icon(Icons.play_circle, size: 16),
                            label: Text('simulace'),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            onPressed: _stopNavigation,
                            child: const Text('Zrušit'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                            onPressed: _startNavigation,
                            icon: const Icon(Icons.navigation),
                            label: const Text('JEDEME'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _panelButton(IconData icon, String tip, VoidCallback onTap, Color bg) => Material(
    color: bg,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Tooltip(
        message: tip,
        child: SizedBox(width: 60, height: 60, child: Icon(icon, color: Lkw.text, size: 30)),
      ),
    ),
  );
}
