import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/route.dart';
import '../navigation/nav_engine.dart';
import '../services/drive_timer.dart';
import '../services/geocoding.dart';
import '../services/settings.dart';
import '../services/valhalla.dart';
import 'profile_screen.dart';

class MapScreen extends StatefulWidget {
  final AppSettings settings;
  final DriveTimer timer;
  const MapScreen({super.key, required this.settings, required this.timer});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  final _tts = FlutterTts();
  final _search = TextEditingController();
  StreamSubscription<Position>? _posSub;
  Timer? _ticker;

  LatLng? _pos;
  double _heading = 0;
  double _speedKmh = 0;
  bool _follow = true;

  LatLng? _dest;
  String? _destName;
  TruckRoute? _route;
  NavEngine? _engine;
  NavState? _nav;
  bool _navigating = false;
  bool _routing = false;
  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);
  bool _arrivedSpoken = false;

  List<Place> _results = [];
  List<Place> _parking = [];
  bool _searching = false;

  final Set<int> _breakWarnings = {};

  DriveTimer get _timer => widget.timer;

  @override
  void initState() {
    super.initState();
    _initTts();
    _initLocation();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _ticker?.cancel();
    _timer.save();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('cs-CZ');
      await _tts.setSpeechRate(0.5);
      await _tts.awaitSpeakCompletion(false);
    } catch (_) {}
  }

  Future<void> _say(String text) async {
    if (!widget.settings.voice || text.isEmpty) return;
    try {
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> _initLocation() async {
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
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 1),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'LKW Navi',
        notificationText: 'Navigace a sledování doby řízení běží',
        enableWakeLock: true,
      ),
    );
    _posSub = Geolocator.getPositionStream(locationSettings: settings)
        .listen(_onPosition, onError: (e) => _toast('Chyba GPS: $e'));
  }

  void _onPosition(Position p) {
    final pos = LatLng(p.latitude, p.longitude);
    final speed = p.speed.isFinite && p.speed > 0 ? p.speed * 3.6 : 0.0;
    // Kurz z GPS je spolehlivý jen za jízdy.
    if (speed > 3 && p.heading.isFinite && p.heading >= 0) _heading = p.heading;
    final first = _pos == null;
    _pos = pos;
    _speedKmh = speed;
    _timer.update(speed, DateTime.now());
    _checkBreakWarnings();

    if (_engine != null) {
      final nav = _engine!.update(pos);
      _nav = nav;
      if (_navigating) {
        _voiceGuidance(nav);
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

    if (first || _follow) _moveCamera();
    if (mounted) setState(() {});
  }

  void _moveCamera() {
    final pos = (_navigating ? _nav?.snapped : null) ?? _pos;
    if (pos == null) return;
    try {
      if (_navigating) {
        final zoom = _speedKmh > 80 ? 15.5 : (_speedKmh > 40 ? 16.5 : 17.5);
        // Poloha ve spodní třetině obrazovky, mapa natočená ve směru jízdy.
        _map.rotate(-_heading);
        _map.move(pos, zoom, offset: const Offset(0, 150));
      } else {
        _map.move(pos, math.max(_map.camera.zoom, 14));
      }
    } catch (_) {
      // Mapa ještě není vykreslená.
    }
  }

  void _checkBreakWarnings() {
    final rem = _timer.remaining.inMinutes;
    if (rem > 30) {
      _breakWarnings.clear();
      return;
    }
    if (_speedKmh < 5) return;
    for (final limit in [30, 15, 0]) {
      if (rem <= limit && _breakWarnings.add(limit)) {
        _say(limit == 0
            ? 'Překročena doba řízení. Zastavte a udělejte přestávku.'
            : 'Do povinné přestávky zbývá $rem minut.');
        break;
      }
    }
  }

  void _voiceGuidance(NavState nav) {
    final i = nav.nextManeuverIndex;
    if (i < 0) return;
    final m = _route!.maneuvers[i];
    final d = nav.distanceToNextManeuver;
    final mps = _speedKmh / 3.6;
    final pre = math.max(60.0, mps * 8);
    final alert = _speedKmh > 80 ? 1500.0 : (_speedKmh > 50 ? 800.0 : 300.0);
    if (d <= pre) {
      if (_engine!.preSpoken.add(i)) {
        _engine!.alertSpoken.add(i);
        _say(m.preInstruction ?? m.instruction);
      }
    } else if (d <= alert && d > pre + 150) {
      if (_engine!.alertSpoken.add(i)) {
        _say('${_spokenDistance(d)} ${m.alertInstruction ?? m.instruction}');
      }
    }
  }

  String _spokenDistance(double m) {
    if (m < 1000) return 'Za ${(m / 50).round() * 50} metrů,';
    final km = (m / 100).round() / 10;
    if (km == km.roundToDouble()) {
      final k = km.round();
      final w = k == 1 ? 'kilometr' : (k < 5 ? 'kilometry' : 'kilometrů');
      return 'Za $k $w,';
    }
    return 'Za ${km.toString().replaceAll('.', ',')} kilometru,';
  }

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
      final r = await ValhallaClient(widget.settings.valhallaUrl).route(
        from: from,
        to: to,
        profile: widget.settings.profile,
        heading: reroute || _speedKmh > 5 ? _heading : null,
      );
      if (!mounted) return;
      setState(() {
        _route = r;
        _engine = NavEngine(r);
        _nav = _engine!.update(from);
        _arrivedSpoken = false;
      });
      if (!reroute && !_navigating) _fitRoute(r);
    } on RoutingException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('Chyba výpočtu trasy: $e');
    } finally {
      if (mounted) setState(() => _routing = false);
    }
  }

  void _fitRoute(TruckRoute r) {
    _follow = false;
    try {
      _map.rotate(0);
      _map.fitCamera(CameraFit.coordinates(
          coordinates: r.shape,
          padding: const EdgeInsets.fromLTRB(40, 140, 40, 220)));
    } catch (_) {}
  }

  void _startNavigation() {
    if (_route == null) return;
    setState(() {
      _navigating = true;
      _follow = true;
    });
    WakelockPlus.enable();
    final first = _route!.maneuvers.isNotEmpty ? _route!.maneuvers.first : null;
    _say(first?.preInstruction ?? 'Navigace spuštěna.');
    _moveCamera();
  }

  void _stopNavigation() {
    WakelockPlus.disable();
    setState(() {
      _navigating = false;
      _route = null;
      _engine = null;
      _nav = null;
      _dest = null;
      _destName = null;
      _parking = [];
    });
    try {
      _map.rotate(0);
    } catch (_) {}
  }

  void _setDestination(LatLng p, String name) {
    FocusScope.of(context).unfocus();
    setState(() {
      _dest = p;
      _destName = name;
      _results = [];
    });
    _computeRoute();
  }

  Future<void> _doSearch(String q) async {
    if (q.trim().length < 3) return;
    setState(() => _searching = true);
    try {
      final r = await searchPlaces(q, near: _pos);
      if (mounted) setState(() => _results = r);
      if (r.isEmpty) _toast('Nic nenalezeno.');
    } catch (e) {
      _toast('Vyhledávání selhalo: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _findParking() async {
    // Hledej kolem bodu, kam kamion dojede před koncem doby řízení.
    LatLng? center = _pos;
    if (_navigating && _route != null && _nav != null) {
      final reachM = _timer.remaining.inSeconds *
          (_route!.lengthKm * 1000 / math.max(1, _route!.timeSec));
      final target = math.min(_nav!.traveled + reachM * 0.9, _route!.cumulative.last);
      final idx = _route!.cumulative.indexWhere((c) => c >= target);
      center = _route!.shape[idx < 0 ? _route!.shape.length - 1 : idx];
    }
    if (center == null) {
      _toast('Čekám na GPS polohu…');
      return;
    }
    _toast('Hledám parkoviště pro kamiony…');
    try {
      final places = await findTruckParking(center);
      if (!mounted) return;
      setState(() => _parking = places);
      if (places.isEmpty) {
        _toast('V okolí nebylo nalezeno parkoviště.');
        return;
      }
      _showParkingSheet(places);
    } catch (e) {
      _toast('Hledání parkovišť selhalo: $e');
    }
  }

  void _showParkingSheet(List<Place> places) {
    const dist = Distance();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => ListView(
        children: [
          const ListTile(title: Text('Parkoviště a odpočívky')),
          for (final p in places.take(25))
            ListTile(
              leading: const Icon(Icons.local_parking),
              title: Text(p.name),
              subtitle: _pos == null
                  ? null
                  : Text('vzdušnou čarou ${formatDistance(dist(_pos!, p.point))}'),
              onTap: () {
                Navigator.pop(ctx);
                final wasNavigating = _navigating;
                _setDestination(p.point, p.name);
                if (wasNavigating) _say('Naviguji na parkoviště.');
              },
            ),
        ],
      ),
    );
  }

  void _showTimerDialog() {
    final now = DateTime.now();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Doba řízení (561/2006)'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Nepřetržité řízení: ${formatDuration(_timer.continuous)} / 4 h 30 min'),
          Text('Do přestávky: ${formatDuration(_timer.remainingContinuous)}'),
          const SizedBox(height: 8),
          Text('Denní řízení: ${formatDuration(_timer.daily)} / 9 h'),
          Text('Zbývá dnes: ${formatDuration(_timer.remainingDaily)}'),
          const SizedBox(height: 8),
          if (_timer.stopStart != null)
            Text('Aktuální stání: ${formatDuration(_timer.currentStop(now))}'),
          if (_timer.partialBreakTaken)
            const Text('První část dělené přestávky (15 min) splněna – zbývá 30 min.'),
          const SizedBox(height: 12),
          const Text(
            'Orientační výpočet z GPS. Závazný je vždy údaj tachografu.',
            style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () {
                _timer.reset();
                Navigator.pop(ctx);
                setState(() {});
              },
              child: const Text('Vynulovat')),
          TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _findParking();
              },
              child: const Text('Najít parkoviště')),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _openProfile() async {
    final changed = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => ProfileScreen(settings: widget.settings)));
    if (changed == true && _dest != null) _computeRoute(reroute: _navigating);
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
    return Scaffold(
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: const LatLng(49.8, 15.5),
            initialZoom: 7,
            onLongPress: (_, p) => _setDestination(
                p, '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}'),
            onPositionChanged: (_, hasGesture) {
              if (hasGesture && _follow) setState(() => _follow = false);
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'cz.lkwnaw.truck_nav',
              maxZoom: 19,
            ),
            if (route != null)
              PolylineLayer(polylines: [
                Polyline(
                    points: route.shape,
                    strokeWidth: 9,
                    color: Colors.white,
                    borderStrokeWidth: 0),
                Polyline(points: route.shape, strokeWidth: 6, color: const Color(0xFF1565C0)),
              ]),
            MarkerLayer(markers: [
              for (final p in _parking)
                Marker(
                  point: p.point,
                  width: 30,
                  height: 30,
                  child: GestureDetector(
                    onTap: () => _setDestination(p.point, p.name),
                    child: const CircleAvatar(
                        backgroundColor: Color(0xFF0D47A1),
                        child: Text('P',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
                  ),
                ),
              if (_dest != null)
                Marker(
                  point: _dest!,
                  width: 44,
                  height: 44,
                  alignment: Alignment.topCenter,
                  child: const Icon(Icons.location_on, color: Colors.red, size: 44),
                ),
              if (_pos != null)
                Marker(
                  point: (_navigating ? _nav?.snapped : null) ?? _pos!,
                  width: 48,
                  height: 48,
                  child: Transform.rotate(
                    angle: _heading * math.pi / 180,
                    child: const Icon(Icons.navigation, color: Color(0xFFE65100), size: 44,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black54)]),
                  ),
                ),
            ]),
            const SimpleAttributionWidget(source: Text('© OpenStreetMap')),
          ],
        ),
        SafeArea(
          child: Column(children: [
            if (_navigating) _maneuverBanner() else _searchBar(),
            if (!_navigating && _results.isNotEmpty) _resultsList(),
            Align(alignment: Alignment.centerRight, child: _timerChip()),
          ]),
        ),
        Positioned(
          right: 12,
          bottom: route != null ? 170 : 24,
          child: Column(children: [
            FloatingActionButton.small(
              heroTag: 'parking',
              tooltip: 'Parkoviště pro kamiony',
              onPressed: _findParking,
              child: const Icon(Icons.local_parking),
            ),
            const SizedBox(height: 8),
            FloatingActionButton.small(
              heroTag: 'profile',
              tooltip: 'Profil vozidla',
              onPressed: _openProfile,
              child: const Icon(Icons.local_shipping),
            ),
            const SizedBox(height: 8),
            FloatingActionButton(
              heroTag: 'center',
              tooltip: 'Moje poloha',
              onPressed: () {
                setState(() => _follow = true);
                _moveCamera();
              },
              child: Icon(_follow ? Icons.gps_fixed : Icons.gps_not_fixed),
            ),
          ]),
        ),
        if (route != null)
          Positioned(left: 0, right: 0, bottom: 0, child: _bottomPanel(route)),
        if (_routing) const Center(child: CircularProgressIndicator()),
      ]),
    );
  }

  Widget _searchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(28),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onSubmitted: _doSearch,
            decoration: InputDecoration(
              hintText: 'Kam jedeme? (nebo dlouze podržte mapu)',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() {
                            _search.clear();
                            _results = [];
                          })),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      );

  Widget _resultsList() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final r in _results)
                  ListTile(
                    leading: const Icon(Icons.place),
                    title: Text(r.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => _setDestination(r.point, r.name),
                  ),
              ],
            ),
          ),
        ),
      );

  Widget _timerChip() {
    final rem = _timer.remaining;
    final color = rem.inMinutes <= 15
        ? Colors.red
        : rem.inMinutes <= 30
            ? Colors.orange
            : Colors.green.shade700;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: ActionChip(
        avatar: Icon(Icons.timer, color: color),
        label: Text('Řízení: ${formatDuration(rem)}'),
        onPressed: _showTimerDialog,
      ),
    );
  }

  Widget _maneuverBanner() {
    final nav = _nav;
    final route = _route!;
    final m = nav != null && nav.nextManeuverIndex >= 0
        ? route.maneuvers[nav.nextManeuverIndex]
        : null;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: const Color(0xFF1B5E20), borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Icon(maneuverIcon(m?.type ?? 4), color: Colors.white, size: 56),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(nav == null ? '' : formatDistance(nav.distanceToNextManeuver),
                style: const TextStyle(
                    color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
            Text(m?.instruction ?? 'Cíl',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 17)),
          ]),
        ),
      ]),
    );
  }

  Widget _bottomPanel(TruckRoute route) {
    final nav = _nav;
    final remainingM = nav?.remaining ?? route.lengthKm * 1000;
    final ratio = route.lengthKm > 0 ? remainingM / (route.lengthKm * 1000) : 0;
    final remainingSec = route.timeSec * ratio;
    final eta = DateTime.now().add(Duration(seconds: remainingSec.round()));
    final etaStr = '${eta.hour}:${eta.minute.toString().padLeft(2, '0')}';
    final needsBreak = Duration(seconds: remainingSec.round()) > _timer.remaining;

    return Material(
      elevation: 12,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!_navigating && _destName != null)
              Text(_destName!, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _stat(formatDuration(Duration(seconds: remainingSec.round())), 'čas'),
              _stat(formatDistance(remainingM), 'vzdálenost'),
              _stat(etaStr, 'příjezd'),
              if (_navigating) _stat('${_speedKmh.round()}', 'km/h'),
            ]),
            if (!_navigating)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(spacing: 6, children: [
                  if (route.hasToll) const Chip(label: Text('mýto'), visualDensity: VisualDensity.compact),
                  if (route.hasHighway) const Chip(label: Text('dálnice'), visualDensity: VisualDensity.compact),
                  if (needsBreak)
                    const Chip(
                        avatar: Icon(Icons.coffee, size: 16),
                        label: Text('cestou nutná přestávka'),
                        visualDensity: VisualDensity.compact),
                ]),
              ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _stopNavigation,
                  icon: const Icon(Icons.close),
                  label: Text(_navigating ? 'Ukončit' : 'Zrušit'),
                ),
              ),
              if (!_navigating) ...[
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: _startNavigation,
                    icon: const Icon(Icons.navigation),
                    label: const Text('Start'),
                  ),
                ),
              ],
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _stat(String value, String label) => Column(children: [
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]);
}

IconData maneuverIcon(int type) {
  switch (type) {
    case 4:
    case 5:
    case 6:
      return Icons.flag;
    case 9:
    case 23:
      return Icons.turn_slight_right;
    case 10:
      return Icons.turn_right;
    case 11:
      return Icons.turn_sharp_right;
    case 12:
      return Icons.u_turn_right;
    case 13:
      return Icons.u_turn_left;
    case 14:
      return Icons.turn_sharp_left;
    case 15:
      return Icons.turn_left;
    case 16:
    case 24:
      return Icons.turn_slight_left;
    case 18:
    case 20:
      return Icons.ramp_right;
    case 19:
    case 21:
      return Icons.ramp_left;
    case 25:
      return Icons.merge;
    case 26:
    case 27:
      return Icons.roundabout_right;
    case 28:
    case 29:
      return Icons.directions_boat;
    default:
      return Icons.straight;
  }
}
