import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truck_nav/services/geocoding.dart';
import 'package:truck_nav/services/parking_network.dart';

/// Počká, až doběhne odesílání spuštěné na pozadí.
Future<void> settle(ParkingNetwork n) async {
  for (var i = 0; i < 20 && n.pending > 0; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const a = LatLng(49.30, 16.00);
  bool everywhere(LatLng _) => true;

  test('údaje z mapy jako výchozí hodnoty a zpět stejné popisky vybavení', () {
    final osm = Place(
      'Odpočívka Velké Meziříčí',
      a,
      kind: 'Odpočívka s ČS',
      features: const ['10 míst', 'zdarma', 'WC', 'sprchy', 'HGV nafta', 'hlídané/kamery'],
      id: 'osm:w42',
    );
    final p = NetPlace.fromPlace(osm);
    expect(p.id, 'osm:w42');
    expect(p.type, NetType.services);
    expect(p.capacity, 10);
    expect(p.fee, NetFee.free);
    expect(p.amenities, {NetAmenity.wc, NetAmenity.shower, NetAmenity.fuel, NetAmenity.guarded});
    expect(p.features, containsAll(osm.features));

    final back = NetPlace.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.features, p.features);
    expect(back.point, p.point);
    // Místo bez id z mapy dostane id řidiče.
    expect(NetPlace.fromPlace(Place('Parkoviště', a)).id, startsWith('u:'));
  });

  test('síť přepíše údaje z OSM, přidá chybějící místa a skryje zrušená', () async {
    final net = ParkingNetwork();
    final edited = NetPlace(id: 'osm:n1', name: 'Truckpark U Lípy', point: a, type: NetType.truckpark, capacity: 60);
    final added = NetPlace(id: 'u:abc123', name: 'Plac za halou', point: const LatLng(49.40, 16.10));
    // Řidič přidal místo, které je v mapě bez id → platí jeho verze, ne duplicita.
    final dup = NetPlace(id: 'u:def456', name: 'Parkoviště u pily', point: const LatLng(49.5002, 16.2));
    final far = NetPlace(id: 'u:far789', name: 'Jinde', point: const LatLng(50.5, 14.0));
    for (final p in [edited, added, dup, far]) {
      net.places[p.id] = p;
    }
    final osm = [
      Place('Parkoviště', a, id: 'osm:n1', kind: 'Parkoviště pro kamiony'),
      Place('Odpočívka', const LatLng(49.35, 16.05), id: 'osm:n2'),
      Place('Parkoviště', const LatLng(49.5, 16.2)),
      Place('Zrušené', const LatLng(49.36, 16.06), id: 'osm:n3'),
    ];
    await net.reportGone('osm:n3', const LatLng(49.36, 16.06));

    final out = net.merge(osm, (q) => q.latitude < 50);
    final names = out.map((p) => p.name).toList();
    expect(names, containsAll(['Truckpark U Lípy', 'Odpočívka', 'Plac za halou', 'Parkoviště u pily']));
    expect(names, isNot(contains('Zrušené')));
    expect(names, isNot(contains('Jinde')));
    expect(out.where((p) => p.name == 'Parkoviště'), isEmpty);
    expect(out.firstWhere((p) => p.id == 'osm:n1').features, contains('60 míst'));

    // Místo skryté serverem (tři hlášení „neexistuje“) zmizí i z mapy.
    net.places['osm:n2'] = NetPlace(id: 'osm:n2', name: 'Zrušené místo', point: a, hidden: true);
    expect(net.merge(osm, everywhere).map((p) => p.id), isNot(contains('osm:n2')));
    expect(net.near(const LatLng(49.4001, 16.1001))?.id, 'u:abc123');
  });

  test('obsazenost platí 3 hodiny', () async {
    var now = DateTime(2026, 10, 31, 18);
    final net = ParkingNetwork(clock: () => now);
    await net.report('osm:n1', a, Occupancy.full);
    expect(net.statusOf('osm:n1')?.level, Occupancy.full);
    expect(net.statusOf('osm:n1')?.mine, isTrue);
    now = now.add(const Duration(hours: 2, minutes: 59));
    expect(net.statusOf('osm:n1'), isNotNull);
    now = now.add(const Duration(minutes: 2));
    expect(net.statusOf('osm:n1'), isNull);
    expect(netAgo(DateTime(2026, 1, 1, 10), DateTime(2026, 1, 1, 10, 25)), 'před 25 min');
  });

  test('bez serveru zůstane vše v telefonu a čeká na odeslání', () async {
    final net = ParkingNetwork(url: '', key: '');
    expect(net.shared, isFalse);
    await net.save(NetPlace(id: newDriverId(), name: 'Truckpark', point: a));
    await net.report('osm:n1', a, Occupancy.free);
    expect(net.pending, 2);
    expect(net.mineCount, 1);
    // Po restartu aplikace je síť i fronta pořád v telefonu.
    final again = ParkingNetwork(url: '', key: '');
    await again.load();
    expect(again.mineCount, 1);
    expect(again.pending, 2);
    expect(again.statusOf('osm:n1')?.level, Occupancy.free);
  });

  test('odeslání přes funkce serveru; výpadek nic neztratí, neplatný údaj frontu neblokuje', () async {
    final calls = <(String, Map<String, dynamic>)>[];
    final headers = <Map<String, String>>[];
    var status = 500;
    final client = MockClient((r) async {
      calls.add((r.url.path, jsonDecode(r.body) as Map<String, dynamic>));
      headers.add(r.headers);
      return http.Response('', status);
    });
    final net = ParkingNetwork(client: client, url: 'https://x.supabase.co/rest/v1/', key: 'sb_publishable_test');
    final p = NetPlace(id: 'u:abc123', name: 'Truckpark', point: a, capacity: 30, amenities: {NetAmenity.wc});
    await net.save(p);
    await settle(net);
    expect(net.pending, 1); // server nedostupný → zůstává ve frontě
    expect(calls.single.$1, '/rest/v1/rpc/net_save_place');
    final row = calls.single.$2['p'] as Map<String, dynamic>;
    expect(row['id'], 'u:abc123');
    expect(row['amenities'], ['wc']);
    expect((row['device'] as String).length, 16);
    // Nový klíč Supabase jen v hlavičce apikey (Bearer jen u starých JWT klíčů).
    expect(headers.single['apikey'], 'sb_publishable_test');
    expect(headers.single.containsKey('Authorization'), isFalse);

    status = 204;
    await net.report('osm:n7', a, Occupancy.limited);
    await settle(net);
    expect(net.pending, 0);
    expect(calls.last.$1, '/rest/v1/rpc/net_report');
    expect((calls.last.$2['r'] as Map)['kind'], 'limited');

    status = 400; // server údaj odmítl → zahodit
    await net.reportGone('osm:n8', a);
    await settle(net);
    expect(net.pending, 0);
  });

  test('stažení ze serveru: místa, obsazenost, skrytá místa; vlastní neodeslaná úprava má přednost', () async {
    final now = DateTime.now();
    final client = MockClient((r) async {
      if (r.method == 'POST') return http.Response('', 503);
      if (r.url.path.endsWith('/net_places')) {
        expect(r.url.queryParameters['select'], contains('hidden'));
        return http.Response(
          jsonEncode([
            {
              'id': 'u:srv001',
              'name': 'Truckpark Jihlava',
              'lat': 49.31,
              'lon': 16.01,
              'type': 'truckpark',
              'capacity': 80,
              'fee': 'paid',
              'amenities': ['wc', 'shower', 'guarded'],
              'note': null,
              'updated_at': now.toUtc().toIso8601String(),
              'hidden': false,
            },
            {
              'id': 'osm:n9',
              'name': 'Zrušené místo',
              'lat': 49.32,
              'lon': 16.02,
              'type': 'other',
              'capacity': null,
              'fee': null,
              'amenities': <String>[],
              'note': null,
              'updated_at': now.toUtc().toIso8601String(),
              'hidden': true,
            },
            {
              'id': 'u:mine01',
              'name': 'Stará verze ze serveru',
              'lat': 49.33,
              'lon': 16.03,
              'type': 'parking',
              'amenities': <String>[],
              'updated_at': now.toUtc().toIso8601String(),
              'hidden': false,
            },
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      expect(r.url.path, endsWith('/rpc/net_status'));
      return http.Response(
        jsonEncode([
          {
            'place_id': 'u:srv001',
            'lat': 49.31,
            'lon': 16.01,
            'kind': 'full',
            'created_at': now.subtract(const Duration(minutes: 20)).toUtc().toIso8601String(),
          },
        ]),
        200,
      );
    });
    final net = ParkingNetwork(client: client, url: 'https://x.supabase.co/rest/v1', key: 'eyJtest');
    await net.save(NetPlace(id: 'u:mine01', name: 'Moje úprava', point: const LatLng(49.33, 16.03)));
    await settle(net);
    await net.pull((49.0, 50.0, 15.0, 17.0));

    expect(net.places['u:srv001']?.features, containsAll(['80 míst', 'placené', 'WC', 'sprchy']));
    expect(net.statusOf('u:srv001')?.level, Occupancy.full);
    expect(net.isGone('osm:n9'), isTrue);
    expect(net.places['u:mine01']?.name, 'Moje úprava');
    final merged = net.merge([Place('Parkoviště', const LatLng(49.32, 16.02), id: 'osm:n9')], everywhere);
    expect(merged.map((p) => p.id), containsAll(['u:srv001', 'u:mine01']));
    expect(merged.map((p) => p.id), isNot(contains('osm:n9')));
  });
}
