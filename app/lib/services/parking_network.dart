import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'geocoding.dart';
import 'http_headers.dart';

/// Obálka oblasti (minLat, maxLat, minLon, maxLon).
typedef NetBox = (double, double, double, double);

/// Druh místa v síti parkovišť.
enum NetType { truckpark, restArea, services, parking, industrial, other }

extension NetTypeInfo on NetType {
  String get code => switch (this) {
    NetType.truckpark => 'truckpark',
    NetType.restArea => 'rest_area',
    NetType.services => 'services',
    NetType.parking => 'parking',
    NetType.industrial => 'industrial',
    NetType.other => 'other',
  };

  /// Stejné názvy jako typy míst z OSM ([Place.kind]).
  String get label => switch (this) {
    NetType.truckpark => 'Truckpark',
    NetType.restArea => 'Odpočívka',
    NetType.services => 'Odpočívka s ČS',
    NetType.parking => 'Parkoviště pro kamiony',
    NetType.industrial => 'Průmyslová zóna',
    NetType.other => 'Jiné místo k zastavení',
  };
}

NetType netTypeOf(String? code) => NetType.values.firstWhere((t) => t.code == code, orElse: () => NetType.other);

/// Vybavení místa.
enum NetAmenity { wc, shower, food, shop, fuel, adblue, guarded, fenced, lit, wifi, hotel, nonstop }

extension NetAmenityInfo on NetAmenity {
  /// Stejné popisky jako vybavenost míst z OSM ([Place.features]) – filtry v seznamu platí pro obojí.
  String get label => switch (this) {
    NetAmenity.wc => 'WC',
    NetAmenity.shower => 'sprchy',
    NetAmenity.food => 'jídlo',
    NetAmenity.shop => 'obchod',
    NetAmenity.fuel => 'HGV nafta',
    NetAmenity.adblue => 'AdBlue',
    NetAmenity.guarded => 'hlídané/kamery',
    NetAmenity.fenced => 'oplocené',
    NetAmenity.lit => 'osvětlené',
    NetAmenity.wifi => 'Wi-Fi',
    NetAmenity.hotel => 'ubytování',
    NetAmenity.nonstop => 'nonstop',
  };
}

enum NetFee { unknown, free, paid }

/// Obsazenost hlášená řidiči.
enum Occupancy { free, limited, full }

extension OccupancyInfo on Occupancy {
  String get code => name;
  String get label => switch (this) {
    Occupancy.free => 'Volno',
    Occupancy.limited => 'Omezeno',
    Occupancy.full => 'Plno',
  };
}

Occupancy? occupancyOf(String? code) => Occupancy.values.where((o) => o.code == code).firstOrNull;

final _rnd = math.Random();

/// Id místa přidaného řidičem (místa z OSM mají `osm:n123`).
String newDriverId() =>
    'u:${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${_rnd.nextInt(1 << 30).toRadixString(36)}';

/// Místo v síti: buď přidané řidičem (`u:…`), nebo místo z OSM (`osm:…`) s údaji opravenými řidiči.
class NetPlace {
  final String id;
  String name;
  LatLng point;
  NetType type;
  int? capacity; // míst pro kamiony (odhad)
  NetFee fee;
  Set<NetAmenity> amenities;
  String? note; // „Vjezd z obce, v noci plno od 19 h“
  DateTime updated;
  bool mine; // přidané / upravené v tomto telefonu
  bool hidden; // server místo skryl (tři řidiči nahlásili, že neexistuje)

  NetPlace({
    required this.id,
    required this.name,
    required this.point,
    this.type = NetType.parking,
    this.capacity,
    this.fee = NetFee.unknown,
    Set<NetAmenity>? amenities,
    this.note,
    DateTime? updated,
    this.mine = false,
    this.hidden = false,
  }) : amenities = amenities ?? {},
       updated = updated ?? DateTime.now();

  bool get fromDriver => id.startsWith('u:');

  /// Údaje z mapy (OSM) jako výchozí hodnoty pro úpravu řidičem.
  factory NetPlace.fromPlace(Place p) {
    final f = p.features;
    final cap = f.map(RegExp(r'^(\d+) míst$').firstMatch).nonNulls.firstOrNull;
    return NetPlace(
      id: p.id ?? newDriverId(),
      name: p.name,
      point: p.point,
      type: NetType.values.firstWhere((t) => t.label == p.kind, orElse: () => NetType.parking),
      capacity: cap == null ? null : int.parse(cap.group(1)!),
      fee: f.contains('zdarma')
          ? NetFee.free
          : f.contains('placené')
          ? NetFee.paid
          : NetFee.unknown,
      amenities: {
        for (final a in NetAmenity.values)
          if (f.contains(a.label)) a,
      },
    );
  }

  List<String> get features => [
    if (capacity != null) '$capacity míst',
    if (fee == NetFee.free) 'zdarma',
    if (fee == NetFee.paid) 'placené',
    for (final a in NetAmenity.values)
      if (amenities.contains(a)) a.label,
  ];

  Place toPlace() => Place(name, point, id: id, kind: type.label, features: features);

  /// Řádek pro server (tabulka `net_places`).
  Map<String, dynamic> toRow(String device) => {
    'id': id,
    'name': name,
    'lat': double.parse(point.latitude.toStringAsFixed(6)),
    'lon': double.parse(point.longitude.toStringAsFixed(6)),
    'type': type.code,
    'capacity': capacity,
    'fee': switch (fee) {
      NetFee.free => 'free',
      NetFee.paid => 'paid',
      NetFee.unknown => null,
    },
    'amenities': [
      for (final a in NetAmenity.values)
        if (amenities.contains(a)) a.name,
    ],
    'note': (note?.isEmpty ?? true) ? null : note,
    'device': device,
    'updated_at': updated.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toJson() => {...toRow(''), 'mine': mine, 'hidden': hidden}..remove('device');

  static NetPlace fromJson(Map<String, dynamic> j) => NetPlace(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    point: LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
    type: netTypeOf(j['type'] as String?),
    capacity: (j['capacity'] as num?)?.toInt(),
    fee: switch (j['fee']) {
      'free' => NetFee.free,
      'paid' => NetFee.paid,
      _ => NetFee.unknown,
    },
    amenities: {for (final a in (j['amenities'] as List?) ?? const []) ...NetAmenity.values.where((x) => x.name == a)},
    note: j['note'] as String?,
    updated: DateTime.tryParse(j['updated_at'] as String? ?? '')?.toLocal(),
    mine: j['mine'] as bool? ?? false,
    hidden: j['hidden'] as bool? ?? false,
  );
}

/// Poslední hlášená obsazenost místa.
class NetStatus {
  final String placeId;
  final LatLng point;
  final Occupancy level;
  final DateTime at;
  final bool mine;
  const NetStatus(this.placeId, this.point, this.level, this.at, {this.mine = false});

  Map<String, dynamic> toJson() => {
    'place_id': placeId,
    'lat': point.latitude,
    'lon': point.longitude,
    'kind': level.code,
    'created_at': at.toUtc().toIso8601String(),
    'mine': mine,
  };

  static NetStatus? fromJson(Map<String, dynamic> j) {
    final level = occupancyOf(j['kind'] as String?);
    final at = DateTime.tryParse(j['created_at'] as String? ?? '');
    if (level == null || at == null) return null;
    return NetStatus(
      j['place_id'] as String,
      LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
      level,
      at.toLocal(),
      mine: j['mine'] as bool? ?? false,
    );
  }
}

/// „před 25 min“
String netAgo(DateTime at, DateTime now) {
  final m = now.difference(at).inMinutes;
  if (m < 2) return 'právě teď';
  if (m < 60) return 'před $m min';
  return 'před ${m ~/ 60} h';
}

/// Vlastní síť parkovišť LKWnav: truckparky, odpočívky a místa k přespání, která řidiči přidávají
/// a opravují, a jejich obsazenost (volno / omezeno / plno).
///
/// Základem jsou místa z OpenStreetMap; řidiči k nim doplňují údaje a přidávají místa, která v mapě
/// chybí. Vše se ukládá v telefonu a funguje bez internetu. Se serverem sítě (PostgREST / Supabase,
/// `backend/network/schema.sql`) se sdílí s ostatními řidiči – adresa a klíč se zadají při sestavení:
/// `--dart-define=NET_URL=https://<projekt>.supabase.co/rest/v1 --dart-define=NET_KEY=<publishable key>`.
class ParkingNetwork {
  ParkingNetwork({this.client, DateTime Function()? clock, String? url, String? key})
    : _now = clock ?? DateTime.now,
      url = (url ?? const String.fromEnvironment('NET_URL')).replaceAll(RegExp(r'/+$'), ''),
      key = key ?? const String.fromEnvironment('NET_KEY');

  static final instance = ParkingNetwork();

  /// Obsazenost se ukazuje 3 hodiny, pak už neplatí (parkoviště se rychle mění).
  static const statusValid = Duration(hours: 3);
  static const _maxCached = 4000;

  final String url, key;
  final http.Client? client; // testy
  final DateTime Function() _now;

  final Map<String, NetPlace> places = {};
  final Map<String, NetStatus> _status = {};
  final Set<String> _gone = {}; // místa nahlášená jako zrušená (v tomto telefonu skrytá)
  final List<Map<String, dynamic>> _queue = []; // čeká na odeslání na server
  String _device = '';
  Future<void>? _loading;
  bool _flushing = false;
  (NetBox, DateTime)? _lastPull;

  /// Sdílí se s ostatními řidiči (je nastaven server sítě).
  bool get shared => url.isNotEmpty && key.isNotEmpty;
  int get pending => _queue.length;
  int get mineCount => places.values.where((p) => p.mine).length;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _device = p.getString('net.device') ?? '';
      if (_device.isEmpty) {
        _device = List.generate(16, (_) => _rnd.nextInt(16).toRadixString(16)).join();
        await p.setString('net.device', _device);
      }
      for (final e in jsonDecode(p.getString('net.places') ?? '[]') as List) {
        final np = NetPlace.fromJson(Map<String, dynamic>.from(e as Map));
        places[np.id] = np;
      }
      for (final e in jsonDecode(p.getString('net.status') ?? '[]') as List) {
        final s = NetStatus.fromJson(Map<String, dynamic>.from(e as Map));
        if (s != null && _fresh(s)) _status[s.placeId] = s;
      }
      _gone.addAll((jsonDecode(p.getString('net.gone') ?? '[]') as List).cast<String>());
      for (final e in jsonDecode(p.getString('net.queue') ?? '[]') as List) {
        _queue.add(Map<String, dynamic>.from(e as Map));
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    if (places.length > _maxCached) {
      final old = places.values.where((p) => !p.mine).toList()..sort((a, b) => a.updated.compareTo(b.updated));
      for (final p in old.take(places.length - _maxCached)) {
        places.remove(p.id);
      }
    }
    _status.removeWhere((_, s) => !_fresh(s));
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('net.places', jsonEncode([for (final e in places.values) e.toJson()]));
      await p.setString('net.status', jsonEncode([for (final s in _status.values) s.toJson()]));
      await p.setString('net.gone', jsonEncode(_gone.toList()));
      await p.setString('net.queue', jsonEncode(_queue));
    } catch (_) {}
  }

  bool _fresh(NetStatus s) => _now().difference(s.at) < statusValid;

  /// Platná obsazenost místa (nejvýš 3 h stará), jinak null.
  NetStatus? statusOf(String? id) {
    final s = id == null ? null : _status[id];
    return s != null && _fresh(s) ? s : null;
  }

  bool isGone(String? id) => id != null && (_gone.contains(id) || (places[id]?.hidden ?? false));

  /// Nejbližší místo sítě do [maxM] m.
  NetPlace? near(LatLng p, {double maxM = 150}) {
    const d = Distance();
    NetPlace? best;
    var bestD = maxM;
    for (final e in places.values) {
      if (isGone(e.id)) continue;
      final x = d(e.point, p);
      if (x <= bestD) {
        bestD = x;
        best = e;
      }
    }
    return best;
  }

  /// Místa z mapy doplněná o síť: úpravy řidičů přepíšou údaje z OSM, místa, která v mapě chybí,
  /// se přidají, zrušená zmizí. [inArea] = hledaná oblast (pro místa sítě, která v mapě nejsou).
  List<Place> merge(List<Place> osm, bool Function(LatLng) inArea) {
    const d = Distance();
    final osmIds = {for (final p in osm) ?p.id};
    final extra = [
      for (final e in places.values)
        if (!osmIds.contains(e.id) && !isGone(e.id) && inArea(e.point)) e,
    ];
    final out = <Place>[];
    for (final p in osm) {
      if (isGone(p.id)) continue;
      final e = p.id == null ? null : places[p.id];
      if (e != null && !e.hidden) {
        out.add(e.toPlace());
        continue;
      }
      // Řidič stejné místo přidal sám (v mapě nemělo id nebo údaje) – platí jeho verze.
      if (extra.any((x) => d(x.point, p.point) < 60)) continue;
      out.add(p);
    }
    for (final e in extra) {
      out.add(e.toPlace());
    }
    return out;
  }

  /// Uloží nové / upravené místo (v telefonu hned, na server, až bude spojení).
  Future<void> save(NetPlace p) async {
    await load();
    p
      ..updated = _now()
      ..mine = true;
    places[p.id] = p;
    _gone.remove(p.id);
    _queue.removeWhere((o) => o['t'] == 'place' && (o['row'] as Map)['id'] == p.id);
    _queue.add({'t': 'place', 'row': p.toRow(_device)});
    await _save();
    unawaited(flush());
  }

  /// Nahlášení obsazenosti místa (i místa z OSM, které v síti ještě není).
  Future<void> report(String placeId, LatLng point, Occupancy level) async {
    await load();
    final s = NetStatus(placeId, point, level, _now(), mine: true);
    _status[placeId] = s;
    _queue.add({'t': 'report', 'row': _reportRow(placeId, point, level.code)});
    await _save();
    unawaited(flush());
  }

  /// „Místo už neexistuje“: v tomto telefonu se hned skryje, na serveru po třech hlášeních.
  Future<void> reportGone(String placeId, LatLng point) async {
    await load();
    _gone.add(placeId);
    _status.remove(placeId);
    _queue.add({'t': 'report', 'row': _reportRow(placeId, point, 'gone')});
    await _save();
    unawaited(flush());
  }

  Map<String, dynamic> _reportRow(String id, LatLng p, String kind) => {
    'place_id': id,
    'lat': double.parse(p.latitude.toStringAsFixed(6)),
    'lon': double.parse(p.longitude.toStringAsFixed(6)),
    'kind': kind,
    'device': _device,
    'created_at': _now().toUtc().toIso8601String(),
  };

  Map<String, String> _headers([Map<String, String> extra = const {}]) => uaHeaders({
    'apikey': key,
    // Starší klíče Supabase jsou JWT; nový „publishable“ klíč patří jen do hlavičky apikey.
    if (key.startsWith('eyJ')) 'Authorization': 'Bearer $key',
    'Content-Type': 'application/json',
    ...extra,
  });

  Future<http.Response> _post(Uri uri, String body, Map<String, String> h) {
    final c = client;
    return c != null ? c.post(uri, headers: h, body: body) : http.post(uri, headers: h, body: body);
  }

  Future<http.Response> _get(Uri uri, Map<String, String> h) {
    final c = client;
    return c != null ? c.get(uri, headers: h) : http.get(uri, headers: h);
  }

  /// Odešle čekající místa a hlášení. false = zkusit později (bez spojení, server nedostupný).
  Future<bool> flush() async {
    await load();
    if (!shared || _queue.isEmpty) return true;
    if (_flushing) return false;
    _flushing = true;
    try {
      while (_queue.isNotEmpty) {
        final op = _queue.first;
        // Zápis jen přes funkce serveru (kontrola údajů, limity, historie) – ne přímo do tabulek.
        final place = op['t'] == 'place';
        final res = await _post(
          Uri.parse('$url/rpc/${place ? 'net_save_place' : 'net_report'}'),
          jsonEncode({place ? 'p' : 'r': op['row']}),
          _headers(),
        ).timeout(const Duration(seconds: 12));
        final c = res.statusCode;
        // Chybná konfigurace / přetížení / výpadek: nechat ve frontě, nic se neztratí.
        if (c == 401 || c == 403 || c == 404 || c == 429 || c >= 500) return false;
        // 2xx hotovo; 400/409/422 = server údaj odmítl (neplatný) – zahodit, jinak by blokoval frontu.
        _queue.removeAt(0);
        await _save();
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      _flushing = false;
    }
  }

  /// Stáhne místa a obsazenost v oblasti ze serveru (nejvýš jednou za minutu pro stejnou oblast).
  Future<void> pull(NetBox box) async {
    await load();
    if (!shared) return;
    final last = _lastPull;
    if (last != null && _contains(last.$1, box) && _now().difference(last.$2) < const Duration(minutes: 1)) {
      return;
    }
    unawaited(flush());
    final (a, b, c, d) = box;
    String f(double v) => v.toStringAsFixed(4);
    // Supabase vrací nejvýš 1000 řádků na dotaz.
    final q = 'lat=gte.${f(a)}&lat=lte.${f(b)}&lon=gte.${f(c)}&lon=lte.${f(d)}&limit=$_pageSize';
    final h = _headers();
    final res = await Future.wait([
      _get(Uri.parse('$url/net_places?select=$_columns&$q'), h),
      _get(Uri.parse('$url/rpc/net_status?a=${f(a)}&b=${f(b)}&c=${f(c)}&d=${f(d)}'), h),
    ]).timeout(const Duration(seconds: 8));
    if (res.any((r) => r.statusCode != 200)) return;
    final rows = jsonDecode(utf8.decode(res[0].bodyBytes)) as List;
    final st = jsonDecode(utf8.decode(res[1].bodyBytes)) as List;
    final queued = {
      for (final o in _queue)
        if (o['t'] == 'place') (o['row'] as Map)['id'],
    };
    final seen = <String>{};
    for (final r in rows) {
      final p = NetPlace.fromJson(Map<String, dynamic>.from(r as Map));
      seen.add(p.id);
      if (queued.contains(p.id)) continue; // vlastní neodeslaná úprava má přednost
      p.mine = places[p.id]?.mine ?? false;
      places[p.id] = p;
    }
    // Co server v oblasti už nemá (smazané), zmizí i z telefonu.
    if (rows.length < _pageSize) {
      places.removeWhere((id, p) => !seen.contains(id) && !queued.contains(id) && _inBox(p.point, box) && !p.mine);
    }
    for (final r in st) {
      final s = NetStatus.fromJson(Map<String, dynamic>.from(r as Map));
      if (s == null) continue;
      final cur = _status[s.placeId];
      if (cur == null || s.at.isAfter(cur.at)) _status[s.placeId] = s;
    }
    _lastPull = (box, _now());
    await _save();
  }

  static const _columns = 'id,name,lat,lon,type,capacity,fee,amenities,note,updated_at,hidden';
  static const _pageSize = 1000;

  static bool _inBox(LatLng p, NetBox b) =>
      p.latitude >= b.$1 && p.latitude <= b.$2 && p.longitude >= b.$3 && p.longitude <= b.$4;

  static bool _contains(NetBox outer, NetBox inner) =>
      inner.$1 >= outer.$1 && inner.$2 <= outer.$2 && inner.$3 >= outer.$3 && inner.$4 <= outer.$4;
}
