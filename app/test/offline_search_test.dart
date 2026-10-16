import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truck_nav/services/offline_search.dart';

/// Ověřuje rejstřík postavený skriptem backend/search/build_search_db.py.
/// Cesta k souboru: proměnná SEARCH_DB (test se bez ní přeskočí).
void main() {
  final path = Platform.environment['SEARCH_DB'];
  final skip = path == null || !File(path).existsSync() ? 'chybí SEARCH_DB' : null;

  test('fold odstraní diakritiku', () {
    expect(fold('Týnecká Říčany'), 'tynecka ricany');
  });

  group('rejstřík ČR', skip: skip, () {
    setUpAll(() => OfflineSearch.instance.open(path));
    tearDownAll(OfflineSearch.instance.close);

    test('adresa z dodacího listu', () {
      final r = OfflineSearch.instance.search('Týnecká 65 77900 Olomouc');
      expect(r.first.name, 'Týnecká 65');
      expect(r.first.point.latitude, closeTo(49.56, 0.05));
    });

    test('místo vykládky Modletice 91', () {
      final r = OfflineSearch.instance.search('Modletice 91 25101 Říčany u Prahy');
      expect(r.first.name, 'Modletice 91');
      expect(r.first.point.longitude, closeTo(14.60, 0.02));
    });

    test('firma podle obce', () {
      final r = OfflineSearch.instance.search('kaufland modletice');
      expect(r.first.name.toLowerCase(), contains('kaufland'));
    });
  });
}
