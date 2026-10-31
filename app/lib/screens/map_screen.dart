import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart' show CameraPreview;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/route.dart';
import '../navigation/nav_engine.dart';
import '../navigation/simulator.dart';
import '../navigation/voice_guide.dart';
import '../services/geocoding.dart';
import '../services/restrictions.dart';
import '../services/lanes.dart';
import '../services/highway_services.dart';
import '../services/map_style.dart';
import '../services/problem_reports.dart';
import '../services/voice_commands.dart';
import '../services/offline_search.dart';
import '../services/ramp_finder.dart';
import '../services/sign_camera.dart';
import '../services/sign_parse.dart';
import 'scan_screen.dart';
import '../services/pip.dart';
import '../services/offline_maps.dart';
import '../services/parking_network.dart';
import '../services/plans.dart';
import '../services/saved_places.dart';
import '../services/settings.dart';
import '../services/voice.dart';
import '../services/valhalla.dart';
import '../theme.dart';
import '../widgets/nav_widgets.dart';
import 'net_place_screen.dart';
import 'planner_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';

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
  final _search = TextEditingController();
  StreamSubscription<Position>? _posSub;
  Size _screen = Size.zero;

  // Poslední GPS (nebo simulovaný) fix.
  LatLng? _pos;
  double _heading = 0;
  VoiceGuide? _guide;
  // Kamera čte značky (rychlost, výška, hmotnost, délka) a ukládá je s polohou.
  SignCamera? _cam;
  StreamSubscription<SignRead>? _camSub;
  (SignRead, DateTime)? _camSign;
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
  MapLayer? _styleLayer;
  Timer? _searchDebounce;
  int _searchSeq = 0;
  NavEngine? _engine;
  NavState? _nav;
  bool _navigating = false;
  bool _routing = false;
  bool _offline = false; // poslední požadavek na server tras selhal kvůli spojení
  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);
  bool _arrivedSpoken = false;
  RouteSimulator? _sim;
  final Set<RouteWarning> _warnSpoken = {};
  final List<LatLng> _excluded = []; // mosty, kterým se trasa vyhýbá (zásobování)

  List<Place> _results = [];
  SavedPlaces _saved = SavedPlaces([]);
  List<SavedPlace> _savedResults = [];
  SavedPlace? _destSaved; // cíl je uložené místo (vjezd + poznámka)
  LatLng? _destAddr; // adresa cíle (bez vjezdu)
  bool _pickGate = false; // čeká se na dlouhé podržení u vjezdu pro kamiony
  Ramp? _destRamp; // nalezená rampa u cíle (kamion jede k ní, ne na parkoviště)
  bool _noteSpoken = false;
  bool _approach = false; // přiblížení před cílem (letecký pohled) už proběhlo
  MapLayer? _layerOverride; // dočasný podklad (před cílem hybridní)
  final _stt = SpeechToText();
  bool _sttReady = false;
  bool _listening = false;
  String _heard = '';
  final List<(LatLng, String)> _stops = []; // zastávky po cestě (průjezdní body)
  LatLng? _planStart; // začátek naplánované trasy (null = moje poloha)
  String? _planStartName;
  double? _dlProgress; // stahování mapy trasy (0–1), null = nestahuje se
  List<Place> _parking = [];
  PoiKind _poiKind = PoiKind.parking;
  bool _searching = false;
  // Síť parkovišť: kamion stojí → „Je tu místo?“ / „Chybí tu parkoviště?“.
  DateTime? _stillSince;
  bool _stopChecked = false;
  bool _stopNear = false; // stojí u známého parkoviště
  bool _missingChecked = false;
  Place? _parkPrompt; // stojím na známém parkovišti
  LatLng? _missingPrompt; // stojím dlouho na místě, které v síti není
  final Map<String, DateTime> _asked = {}; // kdy jsme se u místa naposledy ptali
  List<LatLng> _declined = []; // „tady parkoviště není“ – už se neptat

  AppSettings get _settings => widget.settings;

  Future<void> _loadStyle() async {
    final night = _night;
    final layer = _layerOverride ?? _settings.mapLayer;
    if (_styleNight == night && _styleLayer == layer && _styleJson != null) return;
    _styleNight = night;
    _styleLayer = layer;
    final json = await lkwStyle(night: night, layer: layer);
    _styleReady = false; // nový vzhled: do mapy psát až po jeho načtení
    if (mounted) setState(() => _styleJson = json);
  }

  void _onPip() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    Pip.instance.active.addListener(_onPip);
    _loadStyle();
    SavedPlaces.load().then((v) {
      if (mounted) setState(() => _saved = v);
    });
    ParkingNetwork.instance.load().then((_) => ParkingNetwork.instance.flush());
    SharedPreferences.getInstance().then((p) {
      _declined = [
        for (final e in p.getStringList('net.declined') ?? const <String>[])
          if (e.split(',') case [final a, final b]) LatLng(double.parse(a), double.parse(b)),
      ];
    });
    // Den/noc podle Slunce – kontrola jednou za minutu.
    _nightTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _styleNight != _night) setState(() {});
    });
    _initTts();
    _initLocation();
  }

  @override
  void dispose() {
    Pip.instance.active.removeListener(_onPip);
    _posSub?.cancel();
    _camSub?.cancel();
    _cam?.dispose();
    _sim?.stop();
    _searchDebounce?.cancel();
    _nightTimer?.cancel();
    _anim.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ------------------------------------------------------------ hlas

  Future<void> _initTts() => Voice.instance.init(_settings);

  Future<void> _say(String text) => Voice.instance.say(text);

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
        intervalDuration: const Duration(milliseconds: 500),
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

  (LatLng, DateTime, double)? _prevRaw; // poslední poloha z GPS: místo, čas polohy, přesnost

  void _onPosition(Position p) {
    if (_sim != null) return; // v simulaci se skutečné GPS ignoruje
    final here = LatLng(p.latitude, p.longitude);
    final at = p.timestamp; // čas měření, ne čas doručení (poloha z mezipaměti bývá stará)
    final acc = p.accuracy.isFinite && p.accuracy > 0 ? p.accuracy : 50.0;
    var speed = p.speed.isFinite && p.speed > 0 ? p.speed : 0.0;
    double? heading = p.heading.isFinite && p.heading >= 0 ? p.heading : null;
    // Některé telefony (a web) rychlost / kurz občas nedají: dopočet z posledních dvou poloh –
    // jen z přesných poloh a jen když posun je větší než chyba GPS (stojící kamion „nejede“),
    // a nejvýš 40 m/s (skok polohy z mezipaměti / v tunelu není rychlost).
    final prev = _prevRaw;
    if (prev != null) {
      final dt = at.difference(prev.$2).inMilliseconds / 1000;
      final dm = const Distance()(prev.$1, here);
      final err = math.max(acc, prev.$3);
      final moved = err <= 20 && dm > math.max(8.0, err * 1.5);
      final v = dt > 0 ? dm / dt : 0.0;
      if (dt > 0.3 && dt < 4 && moved && v < 40) {
        if (speed == 0 && v > 1.5) speed = v;
        if (heading == null) {
          final b = const Distance().bearing(prev.$1, here);
          heading = b < 0 ? b + 360 : b;
        }
      }
    }
    _prevRaw = (here, at, acc);
    _onFix(here, speed, heading, accuracy: p.accuracy.isFinite ? p.accuracy : 10);
  }

  void _onFix(LatLng pos, double speedMps, double? heading, {bool simulated = false, double accuracy = 10}) {
    if (_pos == null && kIsWeb) _webDemo();
    if (_pos == null) Future.delayed(const Duration(seconds: 1), _offerResume);
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
      final nav = _engine!.update(
        pos,
        accuracy: accuracy,
        course: speed > 8 && heading != null ? heading : null,
      );
      _nav = nav;
      if (_navigating) {
        _voiceGuidance(nav);
        _warningVoice(nav);
        _speedWarning(nav, speed);
        // Projetá zastávka: odebrat (při přepočtu se už nepoužije).
        for (final st in [..._stops]) {
          if (const Distance()(pos, st.$1) < 80) {
            _stops.remove(st);
            _saveTrip();
            _say('Zastávka ${st.$2}.');
            _syncLayers();
          }
        }
        final note = _destSaved?.note;
        if (note != null && !_noteSpoken && nav.remaining < 1500) {
          _noteSpoken = true;
          _say('Poznámka k cíli: $note');
        }
        // Před cílem: hybridní pohled (vidět vjezd, rampu, dvůr) a připomenutí, kam přesně.
        if (!_approach && nav.remaining < 500 && nav.remaining > 30) {
          _approach = true;
          if ((_settings.mapLayer) == MapLayer.map) {
            _layerOverride = MapLayer.hybrid;
            _loadStyle();
          }
          final ramp = _destRamp;
          if (ramp != null) _say('Cíl: ${ramp.how.replaceAll(' (odhad)', '')}.');
          if (_destSaved?.gate != null) _say('Jedete k uloženému vjezdu.');
        }
        if (nav.arrived && !_arrivedSpoken) {
          _arrivedSpoken = true;
          _clearTrip();
          // „Cíl je vpravo“ právě zaznělo → nehlásit hned znovu.
          final ds = _guide?.destSpokenAt;
          if (ds == null || DateTime.now().difference(ds) > const Duration(seconds: 30)) _say('Jste v cíli.');
        }
        // Přepočet jen za jízdy; bez internetu zkoušet jednou za 30 s a vést dál po staré trase.
        if (_engine!.isOffRoute &&
            !_routing &&
            speed > 5 &&
            DateTime.now().difference(_lastReroute) > Duration(seconds: _offline ? 30 : 4)) {
          _lastReroute = DateTime.now();
          if (!_offline) _say('Přepočítávám trasu.');
          _computeRoute(reroute: true);
        }
      }
    }
    _watchParked(pos, speed, simulated);
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
    // Předpověď: šipka míří tam, kde kamion bude na konci animace (≈ do další polohy z GPS),
    // ne kde byl před vteřinou – mapa tak nejede pozadu.
    final lastFix = _lastFix;
    final gapSec = lastFix == null
        ? 1.0
        : (DateTime.now().difference(lastFix).inMilliseconds / 1000).clamp(0.3, 1.5);
    final mps = _speedKmh / 3.6;
    // + ~0,4 s: poloha z GPS je o chvilku starší, než když dorazí do aplikace.
    final lead = mps > 2 ? mps * (gapSec + 0.4) : 0.0;
    // Přichytit k trase jen do 25 m – při sjetí jinam je hned vidět skutečná poloha.
    if (_navigating && nav != null && route != null && nav.distanceFromRoute < 25) {
      // Na trase: přichycená poloha a směr podle trasy (bez GPS šumu), posunutá o předpověď po trase.
      final (p, seg) = _alongRoute(route, nav.traveled + lead, nav.segmentIndex);
      target = p;
      if (seg + 1 < route.shape.length) {
        heading = const Distance().bearing(route.shape[seg], route.shape[seg + 1]);
        if (heading < 0) heading += 360;
      }
    } else if (lead > 0 && _speedKmh > 8) {
      target = const Distance().offset(pos, lead, _heading);
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

  /// Bod na trase [m] metrů od začátku (hledá od segmentu [from]).
  (LatLng, int) _alongRoute(TruckRoute r, double m, int from) {
    final cum = r.cumulative;
    var i = from.clamp(0, r.shape.length - 2);
    while (i < r.shape.length - 2 && cum[i + 1] < m) {
      i++;
    }
    final a = r.shape[i], b = r.shape[i + 1];
    final len = cum[i + 1] - cum[i];
    final t = len <= 0 ? 0.0 : ((m - cum[i]) / len).clamp(0.0, 1.0);
    return (
      LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t),
      i,
    );
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
    // Rozpracované zápisy do starého vzhledu mapy už nedoběhnou – neblokovat jimi nové.
    _meBusy = false;
    _lineBusy = false;
    const empty = {'type': 'FeatureCollection', 'features': []};
    try {
      _lineRoute = null;
      _meHidden = false;
      for (final id in ['alts', 'route', 'routehead', 'warn', 'parking', 'dest', 'me']) {
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
      // Náběh od šipky k hlavní čáře (stejný vzhled).
      await m.addLineLayer(
        'routehead',
        'head-casing',
        const ml.LineLayerProperties(
          lineColor: Lkw.routeCasing,
          lineWidth: 14,
          lineJoin: 'round',
          lineCap: 'round',
        ),
        belowLayerId: 'route-line',
      );
      await m.addLineLayer(
        'routehead',
        'head-line',
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
          circleColor: [
            'case',
            [
              '==',
              ['get', 'stop'],
              true,
            ],
            '#FFB000',
            '#E53935',
          ],
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ),
      );
      await m.addCircleLayer(
        'parking',
        'parking-circle',
        const ml.CircleLayerProperties(
          circleRadius: 13,
          // Barva podle obsazenosti ze sítě (volno / omezeno / plno), jinak modrá.
          circleColor: ['get', 'c'],
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
          iconSize: 0.7,
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

  // Projetá část trasy mizí plynule přímo pod šipkou: dlouhá „hlavní“ čára začíná ~400 m před vozidlem
  // a mění se jen občas; krátký „náběh“ od šipky k ní se kreslí s každým snímkem animace.
  TruckRoute? _lineRoute;
  int _mainFrom = 0; // index bodu tvaru, kde začíná hlavní čára
  int _dispSeg = 0; // segment trasy pod animovanou šipkou
  bool _lineBusy = false;

  bool get _trimming => _navigating && _engine?.route == _route && _route != null;

  List<List<double>> _remainingLine(TruckRoute r) {
    if (!_trimming || _lineRoute != r) return r.shape.map(_xy).toList();
    return [for (var k = math.max(0, _mainFrom); k < r.shape.length; k++) _xy(r.shape[k])];
  }

  /// Segment trasy nejblíž bodu [p] (hledá kousek kolem posledního).
  int _locateSeg(TruckRoute r, LatLng p) {
    final n = r.shape.length;
    var best = _dispSeg.clamp(0, n - 2), bestD = double.infinity;
    final k = math.cos(p.latitude * math.pi / 180);
    for (var i = math.max(0, _dispSeg - 3); i < math.min(n - 1, _dispSeg + 80); i++) {
      final a = r.shape[i], b = r.shape[i + 1];
      final bx = (b.longitude - a.longitude) * k, by = b.latitude - a.latitude;
      final px = (p.longitude - a.longitude) * k, py = p.latitude - a.latitude;
      final l2 = bx * bx + by * by;
      final t = l2 == 0 ? 0.0 : ((px * bx + py * by) / l2).clamp(0.0, 1.0);
      final dx = px - bx * t, dy = py - by * t;
      final d = dx * dx + dy * dy;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  /// Volá se s každým snímkem animace šipky.
  Future<void> _updateRouteHead(LatLng pos) async {
    final m = _map, r = _route;
    if (m == null || r == null || !_styleReady || _lineBusy) return;
    if (!_trimming) {
      if (_lineRoute != null) {
        _lineRoute = null;
        _lineBusy = true;
        try {
          await m.setGeoJsonSource('routehead', _line(const []));
        } catch (_) {
        } finally {
          _lineBusy = false;
        }
      }
      return;
    }
    if (_lineRoute != r) {
      _lineRoute = r;
      _dispSeg = _nav?.segmentIndex ?? 0;
      _mainFrom = -1;
    }
    _lineBusy = true;
    try {
      final s = _dispSeg = _locateSeg(r, pos);
      final cum = r.cumulative;
      if (_mainFrom <= s || cum[_mainFrom] - cum[s] < 150) {
        var j = s + 1;
        while (j < r.shape.length - 1 && cum[j] - cum[s] < 400) {
          j++;
        }
        _mainFrom = j;
        await m.setGeoJsonSource('route', _line(_remainingLine(r)));
      }
      await m.setGeoJsonSource(
        'routehead',
        _line([_xy(pos), for (var k = s + 1; k <= _mainFrom && k < r.shape.length; k++) _xy(r.shape[k])]),
      );
    } catch (_) {
    } finally {
      _lineBusy = false;
    }
  }

  static Map<String, dynamic> _line(List<List<double>> coords) => {
    'type': 'FeatureCollection',
    'features': [
      if (coords.length >= 2)
        {
          'type': 'Feature',
          'properties': <String, dynamic>{},
          'geometry': {'type': 'LineString', 'coordinates': coords},
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
              'geometry': {'type': 'LineString', 'coordinates': _remainingLine(r)},
            },
        ],
      });
      await m.setGeoJsonSource(
        'warn',
        _points([
          for (final w in r?.warnings ?? const <RouteWarning>[])
            if (w.type != WarningType.noOvertakingHgv && w.relevant)
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
      final net = ParkingNetwork.instance;
      await m.setGeoJsonSource(
        'parking',
        _points([
          for (final p in _parking)
            (
              p.point,
              {
                'l': letter,
                'c': switch (net.statusOf(p.id)?.level) {
                  final o? => _occColor(o),
                  null => '#1565C0',
                },
              },
            ),
        ]),
      );
      await m.setGeoJsonSource(
        'dest',
        _points([
          if (_dest != null) (_dest!, {'stop': false}),
          // Obchod / adresa, když se jede k rampě jinam.
          if (_destAddr != null && _dest != null && const Distance()(_destAddr!, _dest!) > 25)
            (_destAddr!, {'stop': true}),
          for (final st in _stops) (st.$1, {'stop': true}),
        ]),
      );
      await _updateMeLayer();
    } catch (e) {
      debugPrint('sync layers: $e');
    }
  }

  /// Šipka vozidla jako vrstva mapy – vždy přesně na silnici, v 3D leží naplocho.
  Future<void> _updateMeLayer() async {
    final m = _map;
    final p = _dispPos ?? _pos;
    if (p != null) _updateRouteHead(p);
    if (m == null || !_styleReady || _meBusy) return;
    if (_fixedArrow && _meHidden) return;
    _meBusy = true;
    try {
      final hide = _fixedArrow;
      await m.setGeoJsonSource(
        'me',
        _points([
          if (p != null && !hide) (p, {'h': _dispHeading}),
        ]),
      );
      _meHidden = hide;
    } catch (_) {
    } finally {
      _meBusy = false;
    }
  }

  static Future<Uint8List> _arrowPng() async {
    const size = 120.0;
    final rec = ui.PictureRecorder();
    paintArrow(Canvas(rec), size);
    final img = await rec.endRecording().toImage(size.toInt(), size.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// Šipka kamionu (stejná na mapě i pevně na obrazovce).
  static void paintArrow(Canvas c, double size) {
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
  }

  /// Za jízdy se sledováním je šipka pevně na obrazovce (pod ní se točí mapa) – bez zpoždění
  /// za kamerou, které má šipka kreslená do mapy (nová data každý snímek přes kanál).
  bool get _fixedArrow => _follow && _driveView && _dispPos != null && _styleReady;
  bool _meHidden = false;

  // ------------------------------------------------------------ hlasové pokyny

  /// Hlasové pokyny (co a kdy říct) řeší VoiceGuide – tady se jen přehrají.
  void _voiceGuidance(NavState nav) {
    final g = _guide;
    if (g == null) return;
    for (final t in g.update(nav, _speedKmh, DateTime.now(), Voice.instance.lastSpokenAt)) {
      _say(t);
    }
  }

  DateTime? _overSince;
  bool _overWarned = false;

  /// Při každém překročení hranice (limit + tolerance z Nastavení, výchozí +10 → 90 při 80) déle než 2 s
  /// zazní „Pozor, rychlost“. Znovu po zpomalení pod hranici (o 2 km/h, ať to při kolísání neblbne)
  /// a dalším překročení.
  void _speedWarning(NavState nav, double speedKmh) {
    final raw = _route?.speedLimitAt(nav.segmentIndex);
    if (raw == null) return;
    final limit = math.min(raw, _settings.profile.maxSpeed);
    final threshold = limit + _settings.speedTolerance;
    final now = DateTime.now();
    if (speedKmh > threshold) {
      _overSince ??= now;
      if (_settings.speedSound && !_overWarned && now.difference(_overSince!) > const Duration(seconds: 2)) {
        _overWarned = true;
        _say('Pozor, rychlost. Limit $limit.');
      }
    } else {
      _overSince = null;
      if (speedKmh < threshold - 2) _overWarned = false;
    }
  }

  void _warningVoice(NavState nav) {
    for (final w in _route?.warnings ?? const <RouteWarning>[]) {
      final d = w.atMeters - nav.traveled;
      if (d < 0) continue;
      if (d > 1200) break;
      final speak = switch (w.type) {
        WarningType.speedCamera => d <= 500,
        WarningType.noOvertakingHgv => d <= 300,
        _ => w.violates && d <= 1000,
      };
      if (speak && _warnSpoken.add(w)) {
        final dist = VoiceGuide.spokenDistance(d);
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

  // ------------------------------------------------------------ trasa

  Future<void> _computeRoute({bool reroute = false}) async {
    // Naplánovaná trasa může začínat jinde než stojím (dokud se nevyjede).
    final from = (!_navigating ? _planStart : null) ?? _pos;
    final to = _dest;
    if (to == null) return;
    if (from == null) {
      _toast('Čekám na GPS polohu…');
      return;
    }
    setState(() => _routing = true);
    try {
      final client = ValhallaClient(_settings.valhallaUrl);
      final heading = (reroute || _speedKmh > 5) && from == _pos ? _heading : null;
      // Při navigaci jen jedna trasa (rychlý přepočet), jinak varianty na výběr.
      final opts = reroute || _navigating
          ? [
              RouteOption(
                'Trasa',
                await client
                    .route(
                      from: from,
                      to: to,
                      profile: _settings.profile,
                      heading: heading,
                      delivery: _settings.delivery,
                      exclude: _excluded,
                      via: [for (final st in _stops) st.$1],
                    )
                    .timeout(const Duration(seconds: 45)),
              ),
            ]
          : await client
                .routeOptions(
                  from: from,
                  to: to,
                  profile: _settings.profile,
                  heading: heading,
                  delivery: _settings.delivery,
                  exclude: _excluded,
                  via: [for (final st in _stops) st.$1],
                )
                .timeout(const Duration(seconds: 45));
      if (!mounted || opts.isEmpty) return;
      _offline = false;
      _options = opts;
      _extrasLoaded.clear();
      if (!reroute) _dlProgress = null;
      await _selectRoute(0, fit: !reroute && !_navigating);
      final miss = opts.first.route.unreachableM;
      if (miss > 60 && !reroute) {
        final msg =
            'Cíl je pro vaše vozidlo nedostupný (omezení výšky, šířky nebo délky na příjezdu). '
            'Navedu vás co nejblíž – zbývá ${formatDistance(miss)}.';
        _toast(msg);
        if (_navigating) _say(msg);
      }
    } on RoutingException catch (e) {
      if (e.network) {
        // Bez signálu: trasa zůstává, jen stav. Hlásit jednou, ne při každém pokusu.
        if (!_offline) {
          _say('Není připojení. Vedu podle uložené trasy.');
          _toast(_route != null ? 'Bez připojení – vedu podle uložené trasy.' : e.message);
        }
        setState(() => _offline = true);
      } else {
        _toast(e.message);
      }
    } on TimeoutException {
      _toast('Výpočet trasy trvá moc dlouho – zkuste to znovu (nebo vypněte zásobování).');
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
      _guide = VoiceGuide(r, _engine!);
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
      await client.loadEdgeAttributes(r, maxSpeedKmh: _settings.profile.maxSpeed);
      if (mounted) setState(() {});
      _loadServices(r);
      await enrichManeuvers(r);
      if (mounted) setState(() {});
    } catch (_) {}
    try {
      final w = await loadRouteWarnings(r, _settings.profile, delivery: _settings.delivery);
      if (!mounted || _route != r) return;
      setState(() => r.warnings = w);
      await _syncLayers();
      // Teď jsou známé sjezdy na jiné dálnice → doplnit pokyny na křižovatkách.
      if (r.interchangeLinks.isNotEmpty) {
        await enrichManeuvers(r);
        if (mounted) setState(() {});
      }
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

  /// Odpočívky a pumpy u dálnice na trase (pro okénko vpravo).
  Future<void> _loadServices(TruckRoute r) async {
    // Hned z rejstříku v telefonu (pumpy), pak doplnit z mapových dat online (i odpočívky bez jména).
    try {
      final list = await findHighwayServices(r);
      if (mounted && list.isNotEmpty) setState(() => r.services = list);
    } catch (_) {}
    if (OfflineSearch.instance.hasOsm) return; // balík dat má služby kompletně
    try {
      final online = await findHighwayServices(r, local: false);
      if (mounted && online.length >= r.services.length) setState(() => r.services = online);
    } catch (_) {}
  }

  /// Nejbližší služba před námi (projetá zmizí a ukáže se další).
  (HighwayService, double)? get _nextService {
    final r = _route, nav = _nav;
    if (r == null || nav == null || !_navigating) return null;
    for (final s in r.services) {
      final ahead = s.atM - nav.traveled;
      if (ahead < -30) continue;
      if (ahead > 250000) return null;
      return (s, math.max(0.0, ahead));
    }
    return null;
  }

  void _showService(HighwayService s) {
    final r = _route;
    showModalBottomSheet(
      context: context,
      backgroundColor: Lkw.panel,
      isScrollControlled: true,
      builder: (ctx) {
        final ahead = math.max(0.0, s.atM - (_nav?.traveled ?? 0));
        final speed = r != null && r.truckTimeSec > 0 ? r.lengthKm * 1000 / r.truckTimeSec : 22.0;
        final km = s.road != null ? r?.kilometerAt(s.atM, s.road!) : null;
        final upcoming = [
          for (final x in r?.services ?? const <HighwayService>[])
            if (x.atM > s.atM) x,
        ].take(4).toList();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(color: Lkw.muted, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: s.amenities.contains(ServiceAmenity.fuel)
                            ? Lkw.amber
                            : const Color(0xFF2F6FDE),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        amenityIcon(
                          s.amenities.contains(ServiceAmenity.fuel)
                              ? ServiceAmenity.fuel
                              : ServiceAmenity.parking,
                        ),
                        size: 34,
                        color: s.amenities.contains(ServiceAmenity.fuel) ? Lkw.graphite : Colors.white,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                          Text(s.type, style: const TextStyle(color: Lkw.muted)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  [
                    'za ${formatDistance(ahead)}',
                    '~${formatDuration(Duration(seconds: (ahead / speed).round()))}',
                    if (s.road != null) km != null ? '${s.road} km ${km.toStringAsFixed(0)}' : s.road!,
                    'vpravo',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 17, color: Lkw.amber, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in ServiceAmenity.values)
                      if (s.amenities.contains(a))
                        Chip(
                          avatar: Icon(amenityIcon(a), size: 18),
                          label: Text(
                            a == ServiceAmenity.parking && s.hgvSpaces != null
                                ? 'Parkování · ${s.hgvSpaces} míst pro kamiony'
                                : amenityLabel(a),
                          ),
                          backgroundColor: Lkw.panelHi,
                        ),
                    for (final n in s.notes) Chip(label: Text(n), backgroundColor: Lkw.panelHi),
                  ],
                ),
                if (s.brands.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(s.brands.join(' · '), style: const TextStyle(color: Lkw.text)),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    icon: const Icon(Icons.add_location_alt),
                    label: const Text('Přidat jako průjezdní bod'),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      setState(() => _stops.add((s.point, s.name)));
                      _say('Přidána zastávka ${s.name}.');
                      _saveTrip();
                      await _syncLayers();
                      await _computeRoute(reroute: _navigating);
                    },
                  ),
                ),
                if (upcoming.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text(
                    'DALŠÍ NA TRASE',
                    style: TextStyle(color: Lkw.muted, fontWeight: FontWeight.w800),
                  ),
                  for (final x in upcoming)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final a in [
                            ServiceAmenity.fuel,
                            ServiceAmenity.parking,
                            ServiceAmenity.food,
                            ServiceAmenity.wc,
                            ServiceAmenity.shower,
                          ])
                            if (x.amenities.contains(a)) Icon(amenityIcon(a), size: 18, color: Lkw.muted),
                        ],
                      ),
                      title: Text(x.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [
                          x.type,
                          ...x.brands.where((b) => b != x.name).take(2),
                          ...x.notes.take(2),
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Lkw.muted, fontSize: 13),
                      ),
                      trailing: Text(
                        formatDistance(math.max(0.0, x.atM - (_nav?.traveled ?? 0))),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _showService(x);
                      },
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
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

  // ------------------------------------------------------------ obnovení cesty po restartu

  Future<void> _saveTrip() async {
    final d = _dest;
    if (d == null) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        'activeTrip',
        jsonEncode({
          'lat': d.latitude,
          'lon': d.longitude,
          'name': _destName,
          'saved': _destSaved?.id,
          'stops': [
            for (final st in _stops) {'lat': st.$1.latitude, 'lon': st.$1.longitude, 'name': st.$2},
          ],
          'at': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (_) {}
  }

  Future<void> _clearTrip() async {
    try {
      (await SharedPreferences.getInstance()).remove('activeTrip');
    } catch (_) {}
  }

  /// Po spuštění: rozjetá cesta (max. 12 h stará) → nabídnout pokračování.
  Future<void> _offerResume() async {
    if (_dest != null || !mounted) return;
    Map<String, dynamic>? t;
    try {
      final raw = (await SharedPreferences.getInstance()).getString('activeTrip');
      if (raw != null) t = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}
    if (t == null || !mounted) return;
    final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch((t['at'] as num).toInt()));
    if (age > const Duration(hours: 12)) {
      await _clearTrip();
      return;
    }
    final name = (t['name'] as String?) ?? 'cíl';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pokračovat v navigaci?'),
        content: Text('Rozjetá cesta do: $name'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ne')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Pokračovat')),
        ],
      ),
    );
    if (ok != true) {
      await _clearTrip();
      return;
    }
    final saved = _saved.items.where((e) => e.id == t!['saved']).firstOrNull;
    _setDestination(LatLng((t['lat'] as num).toDouble(), (t['lon'] as num).toDouble()), name, saved: saved);
    for (final st in (t['stops'] as List? ?? const [])) {
      _stops.add((LatLng((st['lat'] as num).toDouble(), (st['lon'] as num).toDouble()), '${st['name']}'));
    }
    // Počkat na trasu a rovnou jet.
    for (var i = 0; i < 60 && (_route == null || _routing); i++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (_stops.isNotEmpty) await _computeRoute();
    if (_route != null && mounted) await _startNavigation();
  }

  Future<void> _startNavigation() async {
    _approach = false;
    // Plán začínal jinde: jedeme odsud → přepočítat z aktuální polohy (zastávky zůstanou).
    if (_planStart != null) {
      final far = _pos != null && const Distance()(_pos!, _planStart!) > 300;
      setState(() => _planStart = null);
      if (far) await _computeRoute();
    }
    final r = _route;
    if (r == null) return;
    _saveTrip();
    setState(() {
      _navigating = true;
      Pip.instance.setNavigating(true);
      _follow = true;
      _results = [];
      _options = [_options[_sel]];
      _sel = 0;
    });
    // Úvodní hláška hned – dřív, než může zaznít pokyn z první polohy (jinak dvakrát / v opačném pořadí).
    _say(_guide?.startPhrase(_nav?.traveled ?? 0, DateTime.now()) ?? 'Navigace spuštěna.');
    await _syncLayers();
    await _applyInsets();
    await _updateMeLayer();
    WakelockPlus.enable();
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

  /// Křížek během jízdy: nejdřív se zeptat, ať se trasa neukončí omylem.
  Future<void> _confirmStop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Lkw.panel,
        title: const Text('Ukončit aktuální trasu?'),
        content: Text(_destName != null ? 'Navigace do: $_destName se zastaví.' : 'Navigace se zastaví.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Pokračovat v jízdě')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Lkw.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ukončit'),
          ),
        ],
      ),
    );
    if (ok == true) await _stopNavigation();
  }

  Future<void> _stopNavigation() async {
    WakelockPlus.disable();
    _approach = false;
    if (_layerOverride != null) {
      _layerOverride = null;
      _loadStyle();
    }
    _clearTrip();
    _sim?.stop();
    _sim = null;
    setState(() {
      _navigating = false;
      Pip.instance.setNavigating(false);
      _stops.clear();
      _planStart = null;
      _route = null;
      _options = [];
      _engine = null;
      _guide = null;
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

  void _setDestination(LatLng p, String name, {SavedPlace? saved, bool compute = true, bool ramp = true}) {
    FocusScope.of(context).unfocus();
    _destRamp = null;
    _excluded.clear();
    _stops.clear();
    _planStart = null;
    final sp = saved ?? _saved.near(p);
    setState(() {
      _destSaved = sp;
      _destAddr = sp?.point ?? p;
      // Uložené místo s vjezdem pro kamiony → naviguj k bráně, ne na adresu.
      _dest = sp?.target ?? p;
      _destName = sp?.name ?? name;
      _results = [];
      _savedResults = [];
      _pickGate = false;
      _noteSpoken = false;
    });
    _syncLayers();
    // Bez uloženého vjezdu: najít rampu (zásobování bývá zezadu, ne z parkoviště před obchodem).
    if (ramp && _destSaved?.gate == null) {
      _findRampThen(p, compute);
    } else if (compute) {
      _computeRoute(reroute: _navigating);
    }
  }

  Future<void> _findRampThen(LatLng addr, bool compute) async {
    if (compute) setState(() => _routing = true);
    Ramp? r;
    try {
      r = await rampFor(addr);
    } catch (_) {}
    if (!mounted) return;
    if (r != null && _destAddr == addr && const Distance()(r.point, addr) > 25) {
      setState(() {
        _destRamp = r;
        _dest = r!.point;
      });
      await _syncLayers();
    }
    if (compute) {
      setState(() => _routing = false);
      await _computeRoute(reroute: _navigating);
    }
  }

  /// Volba cíle: k rampě / k adrese / označit rampu ručně / uložit rampu.
  Future<void> _rampMenu() async {
    final r = _destRamp;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Lkw.panel,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(r == null ? 'Kam přesně jedete?' : r.how),
              subtitle: Text(
                r == null
                    ? 'Rampu jsem u cíle nenašel.'
                    : r.sure
                    ? 'Podle mapových dat.'
                    : 'Odhad: obslužná cesta za budovou, na opačné straně než parkoviště.',
              ),
            ),
            if (r != null)
              ListTile(
                leading: const Icon(Icons.save, color: Lkw.amber),
                title: const Text('Sedí – uložit rampu k tomuto místu'),
                onTap: () => Navigator.pop(ctx, 'save'),
              ),
            ListTile(
              leading: const Icon(Icons.touch_app, color: Lkw.amber),
              title: const Text('Označit rampu na mapě'),
              subtitle: const Text('Dlouze podržte prst u rampy – uloží se natrvalo'),
              onTap: () => Navigator.pop(ctx, 'pick'),
            ),
            if (r != null)
              ListTile(
                leading: const Icon(Icons.storefront),
                title: const Text('Navigovat k adrese / obchodu'),
                onTap: () => Navigator.pop(ctx, 'addr'),
              ),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'save':
        await _setGate(r!.point);
      case 'pick':
        setState(() => _pickGate = true);
        _fitDestination();
      case 'addr':
        setState(() {
          _destRamp = null;
          _dest = _destAddr;
        });
        await _syncLayers();
        await _computeRoute(reroute: _navigating);
    }
  }

  /// Otevře plánování trasy (začátek, zastávky, cíl) a trasu podle plánu spočítá.
  /// Adresy z fotek dodacích listů / štítků → seřazené zastávky → plán (lze přeřadit tažením).
  Future<void> _openScan() async {
    final plan = await Navigator.push<TripPlan>(
      context,
      MaterialPageRoute(
        builder: (_) => ScanScreen(settings: _settings, start: _pos),
      ),
    );
    if (plan == null || !mounted) return;
    await _openPlanner(initial: plan);
  }

  Future<void> _openPlanner({TripPlan? initial}) async {
    final current =
        initial ??
        (_dest == null
            ? null
            : TripPlan(
                name: _destName ?? 'Cíl',
                start: _planStart == null ? null : PlanPoint(_planStartName ?? 'Začátek', _planStart!),
                stops: [for (final st in _stops) PlanPoint(st.$2, st.$1)],
                dest: PlanPoint(_destName ?? 'Cíl', _dest!),
              ));
    final plan = await Navigator.push<TripPlan>(
      context,
      MaterialPageRoute(
        builder: (_) => PlannerScreen(saved: _saved, myPosition: _pos, initial: current, settings: _settings),
      ),
    );
    if (plan == null || !mounted) return;
    _setDestination(plan.dest.point, plan.dest.name, compute: false, ramp: false);
    // Zastávky a cíl: k rampám (uložený vjezd, jinak předpočítaná rampa z rejstříku).
    Future<LatLng> toRamp(LatLng p) async {
      final sp = _saved.near(p);
      if (sp?.gate != null) return sp!.gate!;
      final r = OfflineSearch.instance.hasRamps ? await rampFor(p) : null;
      return r != null && const Distance()(r.point, p) > 25 ? r.point : p;
    }

    final stops = [for (final s in plan.stops) (await toRamp(s.point), s.name)];
    final destRamp = OfflineSearch.instance.hasRamps && _destSaved?.gate == null
        ? await rampFor(plan.dest.point)
        : null;
    setState(() {
      if (destRamp != null && const Distance()(destRamp.point, plan.dest.point) > 25) {
        _destRamp = destRamp;
        _dest = destRamp.point;
      }
      _stops.clear();
      _stops.addAll(stops);
      _planStart = plan.start?.point;
      _planStartName = plan.start?.name;
    });
    await _syncLayers();
    await _computeRoute();
  }

  /// Místo z hledání POI: s trasou nabídni „Přidat jako zastávku“ (cíl zůstane) nebo „Nový cíl“.
  Future<void> _pickTarget(LatLng p, String name) async {
    if (_dest == null) {
      _setDestination(p, name);
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ListTile(
              leading: const Icon(Icons.add_location_alt, color: Lkw.amber),
              title: const Text('Přidat jako zastávku'),
              subtitle: Text('Pak pokračovat do: ${_destName ?? 'cíl'}'),
              onTap: () => Navigator.pop(ctx, 'stop'),
            ),
            ListTile(
              leading: const Icon(Icons.flag),
              title: const Text('Nový cíl'),
              onTap: () => Navigator.pop(ctx, 'dest'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'dest') {
      _setDestination(p, name);
      if (_navigating) _say('Naviguji na $name.');
    } else if (choice == 'stop') {
      setState(() => _stops.add((p, name)));
      if (_navigating) {
        _say('Přidána zastávka $name.');
        _saveTrip();
      }
      await _syncLayers();
      await _computeRoute(reroute: _navigating);
    }
  }

  /// Dlouhé podržení: vjezd pro kamiony / objet místo na trase / nový cíl / přidat parkoviště.
  Future<void> _onLongPress(LatLng p) async {
    if (_pickGate) {
      await _setGate(p);
      return;
    }
    final r = _route;
    final onRoute = r != null && RouteIndex(r).locate(p, 80) != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onRoute)
              ListTile(
                leading: const Icon(Icons.block, color: Lkw.danger),
                title: const Text('Objet toto místo'),
                subtitle: const Text('Neprůjezdné, uzavírka, nízký most… – trasa se přepočítá kolem'),
                onTap: () => Navigator.pop(ctx, 'avoid'),
              ),
            ListTile(
              leading: const Icon(Icons.flag, color: Lkw.amber),
              title: const Text('Navigovat sem'),
              onTap: () => Navigator.pop(ctx, 'dest'),
            ),
            ListTile(
              leading: const Icon(Icons.add_location_alt, color: Lkw.amber),
              title: const Text('Přidat parkoviště sem'),
              subtitle: const Text('Do sítě parkovišť LKWnav'),
              onTap: () => Navigator.pop(ctx, 'park'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'avoid') {
      _excluded.add(p);
      _say('Objíždím označené místo.');
      await _computeRoute(reroute: _navigating);
      return;
    }
    if (choice == 'park') {
      await _addParking(at: p);
      return;
    }
    if (choice != 'dest') return;
    _setDestination(p, '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}', ramp: false);
  }

  /// Uloží vjezd pro kamiony k aktuálnímu cíli a naviguje k němu.
  Future<void> _setGate(LatLng gate) async {
    final addr = _destAddr ?? _dest;
    if (addr == null) return;
    final sp =
        _destSaved ??
        SavedPlace(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: _destName ?? 'Místo',
          point: addr,
        );
    sp.gate = gate;
    setState(() {
      _destRamp = null;
      _pickGate = false;
      _destSaved = sp;
      _dest = gate;
    });
    await _saved.upsert(sp);
    await _syncLayers();
    _toast('Vjezd pro kamiony uložen. Navigace povede k bráně.');
    await _editPlace(sp);
    _excluded.clear();
    await _computeRoute(reroute: _navigating);
  }

  /// Dialog: název a poznámka k uloženému místu.
  Future<void> _editPlace(SavedPlace sp) async {
    final name = TextEditingController(text: sp.name);
    final note = TextEditingController(text: sp.note ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Uložené místo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Název'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: note,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Poznámka pro příjezd',
                hintText: 'Příjezd zezadu, vrátnice u rampy 12.',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              sp.gate == null ? 'Vjezd pro kamiony: nenastaven' : 'Vjezd pro kamiony: nastaven ✓',
              style: const TextStyle(color: Lkw.muted),
            ),
          ],
        ),
        actions: [
          if (_saved.items.any((e) => e.id == sp.id))
            TextButton(
              onPressed: () async {
                await _saved.remove(sp.id);
                if (ctx.mounted) Navigator.pop(ctx, false);
                setState(() => _destSaved = null);
              },
              child: const Text('Smazat', style: TextStyle(color: Lkw.danger)),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Zrušit')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Uložit')),
        ],
      ),
    );
    if (ok != true) return;
    sp
      ..name = name.text.trim().isEmpty ? sp.name : name.text.trim()
      ..note = note.text.trim().isEmpty ? null : note.text.trim();
    await _saved.upsert(sp);
    setState(() {
      _destSaved = sp;
      _destName = sp.name;
    });
  }

  /// Přiblíží mapu na cíl (pro výběr brány).
  Future<void> _fitDestination() async {
    final d = _destAddr ?? _dest;
    if (d == null) return;
    setState(() => _follow = false);
    try {
      await _map?.updateContentInsets(EdgeInsets.zero, false);
      await _map?.animateCamera(
        ml.CameraUpdate.newCameraPosition(ml.CameraPosition(target: _ml(d), zoom: 17, tilt: 0, bearing: 0)),
        duration: const Duration(milliseconds: 600),
      );
    } catch (_) {}
  }

  /// Stáhne mapu podél trasy pro jízdu bez signálu.
  Future<void> _downloadRoute(TruckRoute r) async {
    setState(() => _dlProgress = 0);
    try {
      await downloadRouteMap(
        r,
        onProgress: (p) {
          if (mounted) setState(() => _dlProgress = p.clamp(0.0, 0.99));
        },
      );
      if (mounted) setState(() => _dlProgress = 1);
      _toast('Mapa podél trasy je stažená – pojede i bez signálu.');
    } catch (e) {
      if (mounted) setState(() => _dlProgress = null);
      _toast('Stažení mapy selhalo: ${'$e'.replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _saveCurrentDest() async {
    final addr = _destAddr ?? _dest;
    if (addr == null) return;
    await _editPlace(
      _destSaved ??
          SavedPlace(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            name: _destName ?? 'Místo',
            point: addr,
          ),
    );
  }

  // ------------------------------------------------------------ hlasová asistentka

  Future<void> _listen() async {
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      return;
    }
    try {
      _sttReady =
          _sttReady ||
          await _stt.initialize(
            onStatus: (st) {
              if ((st == 'done' || st == 'notListening') && mounted) setState(() => _listening = false);
            },
          );
    } catch (_) {
      _sttReady = false;
    }
    if (!_sttReady) {
      _toast('Rozpoznávání řeči není dostupné (povolte mikrofon / nainstalujte Google hlasové zadávání).');
      return;
    }
    Voice.instance.stop();
    setState(() {
      _listening = true;
      _heard = '';
    });
    await _stt.listen(
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.confirmation,
        partialResults: true,
        localeId: 'cs_CZ',
        pauseFor: const Duration(seconds: 2),
        listenFor: const Duration(seconds: 10),
      ),
      onResult: (r) {
        if (!mounted) return;
        setState(() => _heard = r.recognizedWords);
        if (r.finalResult) {
          setState(() => _listening = false);
          _handleVoice(r.recognizedWords);
        }
      },
    );
  }

  Future<void> _answer(String text) async {
    _toast(text);
    await Voice.instance.say(text, force: true);
  }

  Future<void> _handleVoice(String text) async {
    if (text.trim().isEmpty) return;
    final c = parseCommand(text);
    switch (c.action) {
      case VoiceAction.navigate:
      case VoiceAction.addStop:
        final q = c.arg!;
        List<Place> found;
        try {
          found = await searchPlaces(q, near: _pos);
        } catch (_) {
          found = [];
        }
        if (found.isEmpty) {
          await _answer('Nenašla jsem $q.');
          return;
        }
        final p = found.first;
        if (c.action == VoiceAction.addStop && _dest != null) {
          setState(() => _stops.add((p.point, p.name)));
          await _answer('Přidávám zastávku ${p.name}.');
          await _syncLayers();
          await _computeRoute(reroute: _navigating);
        } else {
          await _answer('Hledám trasu na ${p.name}${p.address != null ? ', ${p.address}' : ''}.');
          _setDestination(p.point, p.name);
        }
      case VoiceAction.start:
        if (_route != null && !_navigating) {
          await _startNavigation();
        } else {
          await _answer(
            _navigating ? 'Navigace už běží.' : 'Nejdřív řekněte cíl, třeba: naviguj na Kaufland Olomouc.',
          );
        }
      case VoiceAction.findParking:
        await _findPois(PoiKind.parking);
      case VoiceAction.findFuel:
        await _findPois(PoiKind.fuel);
      case VoiceAction.findService:
        await _findPois(PoiKind.service);
      case VoiceAction.remaining:
        final r = _route;
        if (r == null) {
          await _answer('Nemám žádnou trasu.');
          return;
        }
        final remM = _nav?.remaining ?? r.lengthKm * 1000;
        final sec = r.remainingSec(remM, _nav?.segmentIndex ?? 0);
        final eta = DateTime.now().add(Duration(seconds: sec.round()));
        final km = (remM / 1000).round();
        await _answer(
          'Do cíle zbývá ${km < 1 ? '${(remM / 100).round() * 100} metrů' : '$km kilometrů'}, '
          'asi ${formatDuration(Duration(seconds: sec.round()))}. Příjezd v ${eta.hour}:${eta.minute.toString().padLeft(2, '0')}.',
        );
      case VoiceAction.voiceOff:
        setState(() => _settings.voice = false);
        _settings.save();
        _toast('Hlas vypnutý.');
      case VoiceAction.voiceOn:
        setState(() => _settings.voice = true);
        _settings.save();
        await _answer('Hlas zapnutý.');
      case VoiceAction.reroute:
        await _answer('Přepočítávám trasu.');
        await _computeRoute(reroute: _navigating);
      case VoiceAction.stop:
        if (_navigating) {
          await _stopNavigation();
          await _answer('Navigace ukončena.');
        }
      case VoiceAction.aerial:
        setState(() => _settings.mapLayer = MapLayer.hybrid);
        _settings.save();
        _loadStyle();
      case VoiceAction.normalMap:
        setState(() => _settings.mapLayer = MapLayer.map);
        _settings.save();
        _loadStyle();
      case VoiceAction.report:
        await _reportProblem(note: text);
      case VoiceAction.help:
        await _answer(
          'Můžete říct: naviguj na Kaufland Olomouc, přidej zastávku, najdi parkoviště, kolik zbývá, '
          'přepočítej, zruš navigaci, nebo tady navigovala špatně.',
        );
      case VoiceAction.unknown:
        await _answer('Nerozuměla jsem: $text. Řekněte třeba: naviguj na Kaufland Olomouc.');
    }
  }

  // ------------------------------------------------------------ hlášení problému

  /// „Tady navigovala špatně“: uloží polohu, profil vozidla a okolní úsek trasy pro pozdější rozbor.
  /// Rychlé hlášení podle druhu (nehoda, policie, radar…). Ukládá se v telefonu; sdílení s ostatními
  /// řidiči přijde se serverem.
  Future<void> _quickReport() async {
    const kinds = [
      ('accident', Icons.car_crash, 'Nehoda'),
      ('danger', Icons.warning_amber, 'Nebezpečí'),
      ('police', Icons.local_police, 'Policie'),
      ('inspection', Icons.fact_check, 'Kontrola (ÚDI, celní)'),
      ('camera', Icons.photo_camera, 'Radar'),
      ('weather', Icons.ac_unit, 'Počasí (náledí, mlha)'),
      ('closure', Icons.do_not_disturb_on, 'Uzavírka'),
      ('maperror', Icons.wrong_location, 'Chyba mapy / navigace'),
    ];
    final kind = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Lkw.panel,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.1,
            children: [
              for (final (id, icon, label) in kinds)
                Material(
                  color: Lkw.panelHi,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => Navigator.pop(ctx, id),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 34, color: Lkw.amber),
                        const SizedBox(height: 6),
                        Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (kind == null) return;
    if (kind == 'maperror') {
      await _reportProblem();
    } else {
      await _reportProblem(note: kinds.firstWhere((k) => k.$1 == kind).$3, type: kind);
    }
  }

  Future<void> _reportProblem({String? note, String type = 'navigation'}) async {
    var text = note;
    if (text == null) {
      final c = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Tady navigovala špatně'),
          content: TextField(
            controller: c,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Co bylo špatně? (nepovinné) – např. zákaz vjezdu, úzká ulice',
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Zrušit')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Uložit')),
          ],
        ),
      );
      if (ok != true) return;
      text = c.text.trim();
    }
    final r = _route, nav = _nav;
    List<List<double>>? around;
    String? maneuver;
    if (r != null && nav != null) {
      final cum = r.cumulative;
      around = [
        for (var i = 0; i < r.shape.length; i++)
          if ((cum[i] - nav.traveled).abs() < 400)
            [
              double.parse(r.shape[i].latitude.toStringAsFixed(6)),
              double.parse(r.shape[i].longitude.toStringAsFixed(6)),
            ],
      ];
      if (nav.nextManeuverIndex >= 0) maneuver = r.maneuvers[nav.nextManeuverIndex].instruction;
    }
    await ProblemReports.add({
      'type': type,
      'time': DateTime.now().toIso8601String(),
      'note': text,
      if (_pos != null) 'pos': [_pos!.latitude, _pos!.longitude],
      'heading': _heading.round(),
      'speedKmh': _speedKmh.round(),
      'profile': _settings.profile.toJson(),
      'delivery': _settings.delivery,
      'dest': _destName,
      if (_dest != null) 'destPos': [_dest!.latitude, _dest!.longitude],
      'routeKm': r?.lengthKm,
      'nextManeuver': maneuver,
      'routeAround': around,
    });
    await _answer('Uloženo. Hlášení najdete v Nastavení.');
  }

  /// Nabídka (hamburger): na mapě zůstane jen okénko služeb, nabídka a „moje poloha“.
  /// Nabídka: rychlé přepínače nahoře, pod nimi skupiny Trasa / Na cestě / Nastavení.
  void _openMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Lkw.panel,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void go(VoidCallback f) {
            Navigator.pop(ctx);
            f();
          }

          Widget head(String t) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
            child: Text(
              t,
              style: const TextStyle(color: Lkw.muted, fontWeight: FontWeight.w800, letterSpacing: 1),
            ),
          );
          Widget item(IconData icon, String title, VoidCallback onTap, {String? subtitle}) => ListTile(
            leading: Icon(icon, color: Lkw.amber),
            title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            subtitle: subtitle == null ? null : Text(subtitle, style: const TextStyle(color: Lkw.muted)),
            onTap: () => go(onTap),
          );
          Widget quick(IconData icon, String label, VoidCallback onTap, {bool on = false}) => Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Material(
                color: on ? Lkw.amber : Lkw.panelHi,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      children: [
                        Icon(icon, size: 28, color: on ? Lkw.graphite : Lkw.text),
                        const SizedBox(height: 4),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: on ? Lkw.graphite : Lkw.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(top: 8, bottom: 12),
                      decoration: BoxDecoration(color: Lkw.muted, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        quick(_settings.voice ? Icons.volume_up : Icons.volume_off, 'Hlas', () {
                          setState(() => _settings.voice = !_settings.voice);
                          if (!_settings.voice) Voice.instance.stop();
                          _settings.save();
                          setSheet(() {});
                        }, on: _settings.voice),
                        quick(
                          _settings.view3d ? Icons.view_in_ar : Icons.map_outlined,
                          _settings.view3d ? '3D' : '2D',
                          () {
                            setState(() => _settings.view3d = !_settings.view3d);
                            _settings.save();
                            _applyCamera();
                            setSheet(() {});
                          },
                          on: _settings.view3d,
                        ),
                        quick(
                          switch (_settings.mapLayer) {
                            MapLayer.map => Icons.layers_outlined,
                            MapLayer.aerial => Icons.satellite_alt,
                            MapLayer.hybrid => Icons.layers,
                          },
                          switch (_settings.mapLayer) {
                            MapLayer.map => 'Mapa',
                            MapLayer.aerial => 'Letecká',
                            MapLayer.hybrid => 'Hybridní',
                          },
                          () => go(_chooseLayer),
                          on: _settings.mapLayer != MapLayer.map,
                        ),
                        quick(Icons.mic, 'Povely', () => go(() => _handleVoice('co umíš'))),
                        quick(Icons.videocam, 'Kamera', () => go(_toggleCamera), on: _cam != null),
                      ],
                    ),
                  ),
                  if (!_navigating) ...[
                    head('TRASA'),
                    item(Icons.route, 'Plán trasy', _openPlanner, subtitle: 'Start, zastávky, cíl'),
                    item(
                      Icons.document_scanner,
                      'Adresy z fotek',
                      _openScan,
                      subtitle: 'Dodací list, štítky, text od dispečera',
                    ),
                  ],
                  head('NA CESTĚ'),
                  item(Icons.local_parking, 'Truckparky, servisy, nafta', _choosePoi),
                  item(
                    Icons.add_location_alt,
                    'Přidat parkoviště',
                    _addParking,
                    subtitle: 'Truckpark, odpočívka, místo k přespání – do sítě LKWnav',
                  ),
                  item(
                    Icons.campaign,
                    'Nahlásit',
                    _quickReport,
                    subtitle: 'Nehoda, policie, kontrola, radar, uzavírka, chyba mapy',
                  ),
                  if (_navigating)
                    item(
                      Icons.report_problem,
                      'Tady navigovala špatně',
                      _reportProblem,
                      subtitle: 'Uloží místo a trasu k rozboru',
                    ),
                  head('NASTAVENÍ'),
                  item(
                    Icons.local_shipping,
                    'Vozidlo a trasa',
                    _openProfile,
                    subtitle: '${_settings.profile.summary}${_settings.delivery ? ' · zásobování' : ''}',
                  ),
                  item(
                    Icons.settings,
                    'Nastavení aplikace',
                    _openSettings,
                    subtitle: 'Rychlost, hlas, zobrazení, data v telefonu',
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _toggleCamera() async {
    if (_cam != null) {
      await _camSub?.cancel();
      final c = _cam;
      setState(() {
        _cam = null;
        _camSign = null;
      });
      await c?.dispose();
      return;
    }
    final c = SignCamera(() {
      final p = _pos;
      if (p == null) return null;
      return (
        lat: p.latitude,
        lon: p.longitude,
        acc: null,
        heading: _speedKmh > 5 ? _heading : null,
        speedKmh: _speedKmh,
      );
    });
    try {
      await c.start();
    } catch (e) {
      await c.dispose();
      _toast('Kameru se nepodařilo zapnout (povolte přístup ke kameře).');
      return;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    _camSub = c.signs.listen(_onCamSign);
    setState(() => _cam = c);
    _toast('Kamera ukládá značky a tabule. Telefon dejte objektivem na silnici.');
  }

  Future<void> _onCamSign(SignRead r) async {
    if (!mounted) return;
    setState(() => _camSign = (r, DateTime.now()));
    Future.delayed(const Duration(seconds: 15), () {
      if (mounted && _camSign?.$1 == r) setState(() => _camSign = null);
    });
    final pr = _settings.profile;
    final over = switch (r.kind) {
      SignKind.height => pr.height > r.value,
      SignKind.weight => pr.weight > r.value,
      SignKind.length => pr.length > r.value,
      SignKind.axle => pr.axleLoad > r.value,
      SignKind.speed => false,
    };
    if (over) {
      _say(
        'Pozor, kamera vidí značku ${r.kind.label.toLowerCase()} ${r.text.replaceAll(' m', ' metru').replaceAll(' t', ' tun')}.',
      );
    }
  }

  /// Okénko kamery s poslední rozpoznanou značkou.
  Widget _cameraView() {
    final c = _cam?.controller;
    final sign = _camSign?.$1;
    return GestureDetector(
      onTap: _toggleCamera,
      child: Container(
        width: 96,
        height: 128,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Lkw.panelHi, width: 2),
          boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black38)],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (c != null && c.value.isInitialized)
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: c.value.previewSize?.height ?? 96,
                  height: c.value.previewSize?.width ?? 128,
                  child: CameraPreview(c),
                ),
              ),
            if (sign != null)
              Center(
                child: Container(
                  width: 70,
                  height: 70,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFD7262E), width: 8),
                  ),
                  child: FittedBox(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(
                        sign.text,
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w900,
                          fontSize: 22,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 4,
              top: 4,
              child: Row(
                children: [
                  const Icon(Icons.fiber_manual_record, color: Color(0xFFD7262E), size: 12),
                  if (_cam case final cam?)
                    ValueListenableBuilder<int>(
                      valueListenable: cam.saved,
                      builder: (_, n, _) => Text(
                        ' $n',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(settings: _settings)));
    if (mounted) setState(() {});
  }

  Future<void> _chooseLayer() async {
    final v = await showModalBottomSheet<MapLayer>(
      context: context,
      backgroundColor: Lkw.panel,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (l, icon, title, sub) in [
              (MapLayer.map, Icons.map, 'Mapa', 'Klasická mapa se silnicemi a názvy'),
              (MapLayer.aerial, Icons.satellite_alt, 'Letecká', 'Letecké snímky ČR (ČÚZK)'),
              (
                MapLayer.hybrid,
                Icons.layers,
                'Hybridní',
                'Snímky s názvy ulic a silnicemi – vjezdy, rampy, dvůr skladu',
              ),
            ])
              ListTile(
                leading: Icon(icon, color: l == _settings.mapLayer ? Lkw.amber : null),
                title: Text(title),
                subtitle: Text(sub),
                trailing: l == _settings.mapLayer ? const Icon(Icons.check, color: Lkw.amber) : null,
                onTap: () => Navigator.pop(ctx, l),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Letecké snímky potřebují internet (nebo předem stažený úsek trasy).',
                style: TextStyle(color: Lkw.muted, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
    if (v == null || v == _settings.mapLayer) return;
    setState(() => _settings.mapLayer = v);
    _settings.save();
    _loadStyle();
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
      if (!mounted || seq != _searchSeq) return;
      _toast(e is SearchException ? e.message : 'Vyhledávání se nepovedlo, zkuste to znovu.');
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
    final pos = _pos;
    final route = _route;
    if (pos == null && route == null) {
      _toast('Čekám na GPS polohu…');
      return;
    }
    _toast('Hledám: ${kind.label.toLowerCase()}…');
    try {
      // S trasou: podél celé trasy před vozidlem; bez trasy: v okolí 30 km.
      final List<RoutePoi> items;
      if (route != null) {
        items = await findTruckPoisAlongRoute(route, _nav?.traveled ?? 0, kind);
      } else {
        const d = Distance();
        items = [for (final p in await findTruckPois(pos!, kind)) RoutePoi(p, d(pos, p.point), 0, -1)];
      }
      if (!mounted) return;
      setState(() {
        _parking = items.map((e) => e.place).toList();
        _poiKind = kind;
      });
      await _syncLayers();
      if (items.isEmpty) {
        _toast(route != null ? 'Podél trasy nic nenalezeno.' : 'V okolí 30 km nic nenalezeno.');
        return;
      }
      _showPoiSheet(items, kind, alongRoute: route != null);
    } catch (e) {
      _toast('Hledání se nepovedlo – zkontrolujte připojení k internetu.');
    }
  }

  static const _poiFilters = ['WC', 'sprchy', 'jídlo', 'zdarma', 'hlídané/kamery', 'AdBlue'];

  static const _notFull = 'není plno';

  void _showPoiSheet(List<RoutePoi> items, PoiKind kind, {required bool alongRoute}) {
    final active = <String>{};
    final net = ParkingNetwork.instance;
    bool ok(RoutePoi e, String f) =>
        f == _notFull ? net.statusOf(e.place.id)?.level != Occupancy.full : e.place.features.contains(f);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final shown = items.where((e) => active.every((f) => ok(e, f))).take(40).toList();
          final filters = [
            if (kind == PoiKind.parking && items.any((e) => net.statusOf(e.place.id) != null)) _notFull,
            ..._poiFilters.where((f) => items.any((e) => e.place.features.contains(f))),
          ];
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            builder: (ctx, scroll) => ListView(
              controller: scroll,
              children: [
                ListTile(
                  title: Text(kind.label, style: Theme.of(ctx).textTheme.titleMedium),
                  subtitle: Text(alongRoute ? 'Podél trasy, seřazeno podle dojezdu' : 'V okolí'),
                ),
                if (filters.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 6,
                      children: [
                        for (final f in filters)
                          FilterChip(
                            label: Text(f),
                            selected: active.contains(f),
                            selectedColor: Lkw.amberDark,
                            onSelected: (v) => setSheet(() => v ? active.add(f) : active.remove(f)),
                          ),
                      ],
                    ),
                  ),
                for (final e in shown)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: switch (net.statusOf(e.place.id)?.level) {
                        final o? => _occUi(o),
                        null => null,
                      },
                      child: Icon(_poiIcon(kind), size: 20),
                    ),
                    title: Text(e.place.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (net.statusOf(e.place.id) case final st?)
                          Text(
                            '${st.level.label} · ${netAgo(st.at, DateTime.now())}',
                            style: TextStyle(color: _occUi(st.level), fontWeight: FontWeight.w800),
                          ),
                        Text(
                          [
                            if (alongRoute) 'za ${formatDistance(e.aheadM)}' else formatDistance(e.aheadM),
                            if (alongRoute && e.etaSec >= 0)
                              '~${formatDuration(Duration(seconds: e.etaSec.round()))}',
                            if (alongRoute && e.offM > 150) '${formatDistance(e.offM)} od trasy',
                            if (e.place.kind != null) e.place.kind!,
                            if (e.place.id?.startsWith('u:') ?? false) 'síť LKWnav',
                          ].join(' · '),
                        ),
                        if (e.place.features.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: [
                                for (final f in e.place.features)
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
                    isThreeLine: e.place.features.isNotEmpty || net.statusOf(e.place.id) != null,
                    onTap: () {
                      Navigator.pop(ctx);
                      if (kind == PoiKind.parking) {
                        _showParkingCard(e.place);
                      } else {
                        _pickTarget(e.place.point, e.place.name);
                      }
                    },
                  ),
                if (shown.isEmpty) const ListTile(title: Text('Žádné místo neodpovídá filtru.')),
                if (kind == PoiKind.parking)
                  ListTile(
                    leading: const Icon(Icons.add_location_alt, color: Lkw.amber),
                    title: const Text('Chybí tu parkoviště? Přidejte ho'),
                    subtitle: const Text('Do sítě parkovišť LKWnav'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _addParking();
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------ síť parkovišť

  static String _occColor(Occupancy o) => switch (o) {
    Occupancy.free => '#43C46B',
    Occupancy.limited => '#F29900',
    Occupancy.full => '#E53935',
  };

  static Color _occUi(Occupancy o) => switch (o) {
    Occupancy.free => Lkw.ok,
    Occupancy.limited => const Color(0xFFF29900),
    Occupancy.full => Lkw.danger,
  };

  Widget _occButton(Occupancy o, VoidCallback? onTap) => FilledButton(
    style: FilledButton.styleFrom(
      backgroundColor: _occUi(o),
      foregroundColor: Colors.black,
      padding: const EdgeInsets.symmetric(vertical: 14),
    ),
    onPressed: onTap,
    child: Text(o.label),
  );

  /// Klepnutí na bod v mapě: nejbližší místo z ukázaného seznamu.
  void _onFeatureTap(math.Point<double> _, ml.LatLng c, String id, String layer, ml.Annotation? ann) {
    if (!layer.startsWith('parking') || _parking.isEmpty) return;
    const d = Distance();
    final at = LatLng(c.latitude, c.longitude);
    final p = _parking.reduce((a, b) => d(a.point, at) <= d(b.point, at) ? a : b);
    if (_poiKind == PoiKind.parking) {
      _showParkingCard(p);
    } else {
      _pickTarget(p.point, p.name);
    }
  }

  /// Karta parkoviště: obsazenost, vybavení, „Je tu místo?“, navigace, úprava údajů.
  Future<void> _showParkingCard(Place place) async {
    final net = ParkingNetwork.instance;
    await net.load();
    if (!mounted) return;
    const d = Distance();
    final here = _pos != null && d(_pos!, place.point) < 1500;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final st = net.statusOf(place.id);
        final np = place.id == null ? null : net.places[place.id];
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  place.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    ?place.kind,
                    if (_pos != null) formatDistance(d(_pos!, place.point)),
                    if (place.id?.startsWith('u:') ?? false)
                      'přidali řidiči LKWnav'
                    else if (np != null)
                      'údaje doplnili řidiči',
                  ].join(' · '),
                  style: const TextStyle(color: Lkw.muted),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: st == null ? Lkw.panelHi : _occUi(st.level),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    st == null
                        ? 'Obsazenost zatím nikdo nenahlásil'
                        : '${st.level.label} · nahlášeno ${netAgo(st.at, DateTime.now())}',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: st == null ? Lkw.text : Colors.black,
                    ),
                  ),
                ),
                if (place.features.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(spacing: 6, runSpacing: 6, children: [for (final f in place.features) Chip(label: Text(f))]),
                ],
                if (np?.note case final note? when note.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(note, style: const TextStyle(fontSize: 16)),
                ],
                const SizedBox(height: 16),
                const Text(
                  'JE TU TEĎ MÍSTO?',
                  style: TextStyle(color: Lkw.muted, fontWeight: FontWeight.w800, letterSpacing: 1),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final o in Occupancy.values)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: _occButton(o, here ? () => Navigator.pop(ctx, 'occ:${o.code}') : null),
                        ),
                      ),
                  ],
                ),
                if (!here)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'Obsazenost jde nahlásit jen na místě (do 1,5 km).',
                      style: TextStyle(color: Lkw.muted),
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, 'go'),
                  icon: const Icon(Icons.navigation),
                  label: Text(_dest == null ? 'Navigovat sem' : 'Zastávka nebo nový cíl'),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed: () => Navigator.pop(ctx, 'edit'),
                        icon: const Icon(Icons.edit),
                        label: const Text('Upravit údaje'),
                      ),
                    ),
                    Expanded(
                      child: TextButton.icon(
                        onPressed: () => Navigator.pop(ctx, 'gone'),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Už neexistuje'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || choice == null) return;
    if (choice == 'go') {
      await _pickTarget(place.point, place.name);
    } else if (choice == 'edit') {
      await _editParking(place);
    } else if (choice == 'gone') {
      await _reportGone(place);
    } else if (choice.startsWith('occ:')) {
      final o = occupancyOf(choice.substring(4));
      if (o != null) await _reportOccupancy(place, o);
    }
  }

  /// Id místa v síti; místo z mapy bez id se nejdřív do sítě uloží.
  Future<String> _netIdFor(Place p) async {
    if (p.id != null) return p.id!;
    final np = NetPlace.fromPlace(p);
    await ParkingNetwork.instance.save(np);
    _replaceParking(p, np.toPlace());
    return np.id;
  }

  void _replaceParking(Place old, Place now) {
    final i = _parking.indexWhere((x) => (old.id != null && x.id == old.id) || x.point == old.point);
    setState(() {
      if (i >= 0) {
        _parking[i] = now;
      } else if (_poiKind == PoiKind.parking) {
        _parking = [..._parking, now];
      } else {
        _parking = [now];
        _poiKind = PoiKind.parking;
      }
    });
  }

  Future<void> _reportOccupancy(Place p, Occupancy o) async {
    final net = ParkingNetwork.instance;
    final id = await _netIdFor(p);
    await net.report(id, p.point, o);
    _asked[id] = DateTime.now();
    if (!mounted) return;
    setState(() => _parkPrompt = null);
    await _syncLayers();
    _toast(net.shared ? 'Díky! „${o.label}“ teď uvidí ostatní řidiči.' : 'Uloženo: ${o.label}.');
  }

  Future<void> _reportGone(Place p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Místo už neexistuje?'),
        content: Text('${p.name}\nV telefonu se skryje. Z mapy pro všechny zmizí po třech hlášeních.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ne')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Neexistuje')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Místo z mapy bez id nemá v síti co skrývat – stačí ho vyřadit ze seznamu.
    if (p.id != null) await ParkingNetwork.instance.reportGone(p.id!, p.point);
    if (!mounted) return;
    setState(() => _parking = _parking.where((x) => x.point != p.point).toList());
    await _syncLayers();
    _toast('Díky, místo je nahlášené.');
  }

  Future<void> _editParking(Place p) async {
    final net = ParkingNetwork.instance;
    final base = (p.id == null ? null : net.places[p.id]) ?? NetPlace.fromPlace(p);
    final saved = await Navigator.push<NetPlace>(
      context,
      MaterialPageRoute(builder: (_) => NetPlaceScreen(place: base)),
    );
    if (saved == null || !mounted) return;
    _replaceParking(p, saved.toPlace());
    await _syncLayers();
    _toast(net.shared ? 'Uloženo. Díky – údaje uvidí ostatní řidiči.' : 'Uloženo do sítě v telefonu.');
  }

  /// Přidá parkoviště do sítě: na místě, kde stojím, nebo na podrženém bodu mapy.
  /// Když tam už nějaké je, nabídne doplnění jeho údajů místo duplicity.
  Future<void> _addParking({LatLng? at}) async {
    final p = at ?? _pos;
    if (p == null) {
      _toast('Čekám na GPS polohu…');
      return;
    }
    final net = ParkingNetwork.instance;
    await net.load();
    const d = Distance();
    Place? existing = net.near(p, maxM: 80)?.toPlace();
    existing ??= _parking.where((x) => d(x.point, p) < 80).firstOrNull;
    if (existing == null) {
      try {
        existing = (await findTruckPois(p, PoiKind.parking, radiusM: 120).timeout(const Duration(seconds: 8)))
            .where((x) => d(x.point, p) < 80)
            .firstOrNull;
      } catch (_) {}
    }
    if (!mounted) return;
    if (existing != null) {
      final found = existing;
      final edit = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Tady už parkoviště je'),
          content: Text('${found.name}\nDoplnit nebo opravit jeho údaje?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Přidat nové')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Upravit')),
          ],
        ),
      );
      if (edit == null || !mounted) return;
      if (edit) {
        await _editParking(found);
        return;
      }
    }
    final saved = await Navigator.push<NetPlace>(
      context,
      MaterialPageRoute(
        builder: (_) => NetPlaceScreen(
          place: NetPlace(id: newDriverId(), name: '', point: p),
          isNew: true,
        ),
      ),
    );
    if (saved == null || !mounted) return;
    setState(() => _missingPrompt = null);
    _replaceParking(saved.toPlace(), saved.toPlace());
    await _syncLayers();
    _toast(net.shared ? 'Parkoviště je v síti LKWnav. Díky!' : 'Parkoviště uloženo do sítě v telefonu.');
  }

  /// Kamion stojí: po 3 min na známém parkovišti „Je tu místo?“, po 10 min jinde „Chybí tu parkoviště?“.
  void _watchParked(LatLng pos, double speedKmh, bool simulated) {
    if (simulated) return;
    if (speedKmh > 6) {
      _stillSince = null;
      _stopChecked = false;
      _stopNear = false;
      _missingChecked = false;
      if (speedKmh > 15 && (_parkPrompt != null || _missingPrompt != null)) {
        setState(() {
          _parkPrompt = null;
          _missingPrompt = null;
        });
      }
      return;
    }
    final still = DateTime.now().difference(_stillSince ??= DateTime.now());
    if (!_stopChecked && still > const Duration(minutes: 3)) {
      _stopChecked = true;
      _checkParked(pos);
    }
    if (!_missingChecked && still > const Duration(minutes: 10)) {
      _missingChecked = true;
      _checkMissing(pos);
    }
  }

  Future<void> _checkParked(LatLng pos) async {
    const d = Distance();
    Place? p = ParkingNetwork.instance.near(pos)?.toPlace();
    p ??= _parking.where((x) => d(x.point, pos) < 150).firstOrNull;
    if (p == null) {
      try {
        p = (await findTruckPois(pos, PoiKind.parking, radiusM: 200).timeout(const Duration(seconds: 10)))
            .where((x) => d(x.point, pos) < 150)
            .firstOrNull;
      } catch (_) {}
    }
    if (!mounted || _stillSince == null || p == null) return;
    _stopNear = true;
    final key = p.id ?? '${p.point}';
    final last = _asked[key];
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 2)) return;
    _asked[key] = DateTime.now();
    setState(() => _parkPrompt = p);
  }

  void _checkMissing(LatLng pos) {
    const d = Distance();
    if (_stopNear || _parkPrompt != null) return; // stojí u známého parkoviště
    // Vykládka v cíli / u uložené firmy, kolona na trase, „tady parkoviště není“.
    if (_dest != null && d(pos, _dest!) < 500) return;
    if (_destAddr != null && d(pos, _destAddr!) < 500) return;
    if (_saved.near(pos) != null) return;
    if (_declined.any((x) => d(x, pos) < 300)) return;
    final nav = _nav;
    if (_navigating && nav != null && nav.distanceFromRoute < 40) return;
    setState(() => _missingPrompt = pos);
  }

  Future<void> _declineMissing() async {
    final at = _missingPrompt;
    setState(() => _missingPrompt = null);
    if (at == null) return;
    _declined = [at, ..._declined].take(100).toList();
    final p = await SharedPreferences.getInstance();
    await p.setStringList('net.declined', [
      for (final x in _declined) '${x.latitude.toStringAsFixed(5)},${x.longitude.toStringAsFixed(5)}',
    ]);
  }

  Widget _netPromptCard() {
    final p = _parkPrompt;
    return Material(
      color: Lkw.panel,
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.local_parking, color: Lkw.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p != null ? 'Je tu místo? ${p.name}' : 'Stojíte na parkovišti, které v síti chybí?',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _parkPrompt = null;
                    _missingPrompt = null;
                  }),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: p != null
                  ? Row(
                      children: [
                        for (final o in Occupancy.values)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: _occButton(o, () => _reportOccupancy(p, o)),
                            ),
                          ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              final at = _missingPrompt;
                              setState(() => _missingPrompt = null);
                              _addParking(at: at);
                            },
                            child: const Text('Přidat do sítě'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(onPressed: _declineMissing, child: const Text('Tady není')),
                        ),
                      ],
                    ),
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
    if (_styleNight != _night || _styleLayer != (_layerOverride ?? _settings.mapLayer)) _loadStyle();
    final limitRaw = nav != null ? route?.speedLimitAt(nav.segmentIndex) : null;
    final limit = limitRaw == null ? null : math.min(limitRaw, _settings.profile.maxSpeed);
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final pip = Pip.instance.active.value;
    final panelH = pip || route == null ? 0.0 : (_navigating ? 116.0 : 252.0);

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
                      _updateMeLayer(); // šipka hned do mapy (pevná na obrazovce zmizí)
                    }
                  },
                  child: ml.MapLibreMap(
                    styleString: _styleJson!,
                    initialCameraPosition: const ml.CameraPosition(target: ml.LatLng(49.8, 15.5), zoom: 6),
                    onMapCreated: (c) {
                      _map = c;
                      c.onFeatureTapped.add(_onFeatureTap);
                    },
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
                    onMapLongClick: (_, p) => _onLongPress(LatLng(p.latitude, p.longitude)),
                  ),
                ),
              if (_fixedArrow)
                Positioned(
                  // V malém okénku (obraz v obraze) menší šipka.
                  left: _screen.width / 2 - (pip ? 20 : 42),
                  top: _topInset + (_screen.height - _topInset) / 2 - (pip ? 20 : 42),
                  child: IgnorePointer(
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.0015)
                        ..rotateX(_settings.view3d ? 0.96 : 0.0),
                      child: SizedBox(
                        width: pip ? 40 : 84,
                        height: pip ? 40 : 84,
                        child: const CustomPaint(painter: _ArrowPainter()),
                      ),
                    ),
                  ),
                ),
              if (pip)
                _pipOverlay(route, nav, limit)
              else ...[
                SafeArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_navigating && route != null)
                        MediaQuery(
                          data: MediaQuery.of(context)
                              .copyWith(textScaler: TextScaler.linear(_settings.bigText ? 1.25 : 1.0)),
                          child: _banner(route, nav),
                        )
                      else
                        _searchBar(),
                      if (!_navigating && (_results.isNotEmpty || _savedResults.isNotEmpty)) _resultsList(),
                      if (_pickGate)
                        Container(
                          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Lkw.amber,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Text(
                            'Dlouze podržte mapu na místě vjezdu / brány pro kamiony.',
                            style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 16),
                          ),
                        ),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [const Spacer(), if (_navigating) _warningsColumn(route, nav)],
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
                      if (_nextService case (final svc, final ahead))
                        ServiceTile(service: svc, aheadM: ahead, onTap: () => _showService(svc)),
                      RoundButton(
                        icon: _listening ? Icons.mic : Icons.mic_none,
                        tooltip: 'Hlasový příkaz',
                        color: _listening ? Lkw.amber : null,
                        onPressed: _listen,
                      ),
                      RoundButton(icon: Icons.menu, tooltip: 'Nabídka', onPressed: _openMenu),
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
                if (_listening)
                  Positioned(
                    left: 16,
                    right: 90,
                    bottom: panelH + 90 + bottomPad,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: Lkw.panel, borderRadius: BorderRadius.circular(16)),
                      child: Row(
                        children: [
                          const Icon(Icons.mic, color: Lkw.amber),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _heard.isEmpty ? 'Poslouchám… (např. „naviguj na Kaufland Olomouc“)' : _heard,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_navigating && (limit != null || _speedKmh > 0))
                  Positioned(
                    left: 12,
                    bottom: panelH + 16 + bottomPad,
                    child: SpeedWidget(
                      limit: limit,
                      speedKmh: _speedKmh,
                      tolerance: _settings.speedTolerance,
                    ),
                  ),
                if (_cam != null && !pip)
                  Positioned(left: 12, bottom: panelH + 136 + bottomPad, child: _cameraView()),
                if (_offline)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: panelH + 16 + bottomPad,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(color: Lkw.danger, borderRadius: BorderRadius.circular(20)),
                        child: Text(
                          route != null ? 'Bez připojení – vedu podle uložené trasy' : 'Bez připojení',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                if (route != null) Positioned(left: 0, right: 0, bottom: 0, child: _bottomPanel(route)),
                if (_parkPrompt != null || _missingPrompt != null)
                  Positioned(
                    left: 12,
                    right: 84,
                    bottom: panelH + (_navigating ? 120 : 16) + bottomPad,
                    child: _netPromptCard(),
                  ),
                if (_routing) const Center(child: CircularProgressIndicator()),
              ],
            ],
          );
        },
      ),
    );
  }

  /// Malé okénko (obraz v obraze): jen mapa, šipka s dálkou a rychlost.
  Widget _pipOverlay(TruckRoute? route, NavState? nav, int? limit) {
    final i = nav?.nextManeuverIndex ?? -1;
    final m = route != null && i >= 0 ? route.maneuvers[i] : null;
    return Stack(
      children: [
        if (m != null && nav != null)
          Positioned(
            left: 6,
            top: 6,
            right: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(color: Lkw.panel, borderRadius: BorderRadius.circular(12)),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: Lkw.amber, borderRadius: BorderRadius.circular(8)),
                    child: Icon(maneuverIcon(m.type), color: Colors.black, size: 26),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      formatDistance(nav.distanceToNextManeuver),
                      maxLines: 1,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Lkw.amber),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_navigating && limit != null)
          Positioned(
            left: 6,
            bottom: 6,
            child: Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFD50000), width: 4),
              ),
              child: Text(
                '$limit',
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 14),
              ),
            ),
          ),
      ],
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
          if (!w.relevant) return false;
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
    setState(() => _savedResults = _saved.search(q).take(5).toList());
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
        // Prázdné pole: nabídni uložená místa (firmy s vjezdem pro kamiony).
        onTap: () {
          if (_search.text.isEmpty && _saved.items.isNotEmpty) {
            setState(() => _savedResults = _saved.items.take(8).toList());
          }
        },
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
                    _savedResults = [];
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
            itemCount: _savedResults.length + _results.length,
            separatorBuilder: (_, _) => const Divider(height: 1, color: Lkw.panelHi),
            itemBuilder: (_, i) {
              if (i < _savedResults.length) {
                final sp = _savedResults[i];
                return ListTile(
                  leading: Icon(sp.gate != null ? Icons.local_shipping : Icons.star, color: Lkw.amber),
                  title: Text(
                    sp.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Lkw.text, fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    [if (sp.gate != null) 'vjezd pro kamiony', ?sp.note].join(' · ').ifEmpty('uložené místo'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Lkw.muted),
                  ),
                  trailing: _pos == null
                      ? null
                      : Text(
                          formatDistance(dist(_pos!, sp.target)),
                          style: const TextStyle(color: Lkw.muted, fontSize: 13),
                        ),
                  onTap: () => _setDestination(sp.target, sp.name, saved: sp),
                );
              }
              final r = _results[i - _savedResults.length];
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
                // Souřadnice: přesně na bod, bez hledání rampy u budovy.
                onTap: () => _setDestination(r.point, r.name, ramp: r.kind != coordinatesKind),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Co je před námi na pruhu průběhu: zastávky, služby, radary, omezení (vzdálenost po trase).
  Widget _bottomPanel(TruckRoute route) {
    final nav = _nav;
    final remainingM = nav?.remaining ?? route.lengthKm * 1000;
    final remainingSec = route.remainingSec(remainingM, nav?.segmentIndex ?? 0);
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
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
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
                              if (_destSaved?.note != null && remainingM < 3000)
                                Text(
                                  _destSaved!.note!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Lkw.amber,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                                )
                              else
                                Text(
                                  '${_settings.delivery ? (route.deliveryKm > 0.05 && route.deliveryKm < route.lengthKm * 0.9 ? 'ZÁSOBOVÁNÍ v obci cíle (${route.deliveryKm.toStringAsFixed(1).replaceAll('.', ',')} km) · ' : 'ZÁSOBOVÁNÍ · ') : ''}${_settings.profile.summary}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _settings.delivery ? Lkw.amber : Lkw.muted,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        _panelButton(Icons.alt_route, 'Přehled trasy', () => _fitRoute(route), Lkw.panelHi),
                        const SizedBox(width: 10),
                        _panelButton(Icons.close, 'Ukončit navigaci', _confirmStop, Lkw.danger),
                      ],
                    ),
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
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _destName!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Lkw.text,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (_planStart != null)
                                    Text(
                                      'Začátek: ${_planStartName ?? ''}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Lkw.muted, fontSize: 13),
                                    ),
                                  if (_destRamp != null || (_destSaved?.gate == null && !_navigating))
                                    InkWell(
                                      onTap: _rampMenu,
                                      child: Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          _destRamp != null
                                              ? '🚚 ${_destRamp!.how} – klepněte pro změnu'
                                              : '🚚 Rampa nenalezena – klepněte a označte ji',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: _destRamp != null ? Lkw.amber : Lkw.muted,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (_destSaved?.gate != null)
                                    const Text(
                                      '🚚 Uložený vjezd / rampa',
                                      style: TextStyle(
                                        color: Lkw.amber,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  if (_destSaved?.note != null)
                                    Text(
                                      _destSaved!.note!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Lkw.amber, fontSize: 13),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Vjezd pro kamiony',
                              icon: Icon(
                                Icons.local_shipping,
                                color: _destSaved?.gate != null ? Lkw.amber : Lkw.muted,
                              ),
                              onPressed: () {
                                setState(() => _pickGate = true);
                                _fitDestination();
                              },
                            ),
                            IconButton(
                              tooltip: _destSaved == null ? 'Uložit místo' : 'Upravit místo',
                              icon: Icon(
                                _destSaved == null ? Icons.star_border : Icons.star,
                                color: Lkw.amber,
                              ),
                              onPressed: _saveCurrentDest,
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
                              base: _options.first.route,
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
                        if (!kIsWeb)
                          ActionChip(
                            avatar: Icon(
                              _dlProgress == 1 ? Icons.download_done : Icons.download,
                              size: 18,
                              color: Lkw.amber,
                            ),
                            label: Text(
                              _dlProgress == null
                                  ? 'Mapa offline'
                                  : _dlProgress! >= 1
                                  ? 'Staženo'
                                  : 'Stahuji ${(_dlProgress! * 100).round()} %',
                            ),
                            visualDensity: VisualDensity.compact,
                            onPressed: _dlProgress != null && _dlProgress! < 1
                                ? null
                                : () => _downloadRoute(route),
                          ),
                        ActionChip(
                          avatar: const Icon(Icons.local_shipping, size: 18, color: Lkw.amber),
                          label: Text(_settings.profile.summary),
                          visualDensity: VisualDensity.compact,
                          onPressed: _openProfile,
                        ),
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
                        for (final st in _stops)
                          InputChip(
                            avatar: const Icon(Icons.add_location_alt, size: 18, color: Lkw.amber),
                            label: Text('Zastávka: ${st.$2}', overflow: TextOverflow.ellipsis),
                            visualDensity: VisualDensity.compact,
                            onDeleted: () {
                              setState(() => _stops.remove(st));
                              _syncLayers();
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

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 120);
    _MapScreenState.paintArrow(canvas, 120);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => false;
}
