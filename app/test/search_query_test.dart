import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truck_nav/services/geocoding.dart';

void main() {
  // SAPA, Praha-Libuš.
  void sapa(String text) {
    final p = parseCoordinates(text);
    expect(p, isNotNull, reason: text);
    expect(p!.latitude, closeTo(50.00542, 1e-4), reason: text);
    expect(p.longitude, closeTo(14.47234, 1e-4), reason: text);
  }

  test('souřadnice v různých zápisech a odkazy z map', () {
    sapa('50.0054241, 14.4723392');
    sapa(' 50.0054241 14.4723392 ');
    sapa('50,0054241, 14,4723392');
    sapa('50.0054241N, 14.4723392E');
    sapa('N 50.0054241, E 14.4723392');
    sapa('50°0\'19.5"N 14°28\'20.4"E');
    sapa('https://www.google.com/maps/@50.0054241,14.4723392,17z');
    sapa('https://maps.google.com/?q=50.0054241,14.4723392');
    sapa('https://maps.apple.com/?ll=50.0054241,14.4723392&q=SAPA');
    sapa('https://mapy.cz/zakladni?x=14.4723392&y=50.0054241&z=17');
    expect(parseCoordinates('-33.8688, 151.2093')!.latitude, closeTo(-33.8688, 1e-6));
  });

  test('adresy a čísla nejsou souřadnice', () {
    expect(parseCoordinates('Libušská 319'), isNull);
    expect(parseCoordinates('tamda foods libušska 319'), isNull);
    expect(parseCoordinates('148 00 Praha'), isNull);
    expect(parseCoordinates('12,5 3,5'), isNull);
    // Rozbitě vložený text: souřadnice nejdou poskládat → hledá se text.
    expect(parseCoordinates('50.0054241, 14, SAPA, 148 00 4723392-Praha-Libuš'), isNull);
  });

  test('vložený text bez úlomků souřadnic, pak bez čísel', () {
    final q = cleanSearchQuery('50.0054241, 14, SAPA, 148 00 4723392-Praha-Libuš');
    expect(q, '14 SAPA 148 00 Praha-Libuš');
    expect(relaxedQueries(q).first, 'SAPA Praha-Libuš');
    expect(cleanSearchQuery('Kaufland DC Modletice'), 'Kaufland DC Modletice');
  });

  test('bez výsledku: bez čísla popisného, pak bez posledních slov', () {
    expect(relaxedQueries('tamda foods libušská 319'), ['tamda foods libušská', 'tamda foods']);
    expect(relaxedQueries('tamda foods'), isEmpty);
    expect(relaxedQueries('a b c d e f').length, 3);
  });

  test('řazení: hledaná firma před ostatními, i s číslem, které adresa nemá', () {
    final r = rankPlaces([
      Place('SAPA TRADE CENTER', const LatLng(50.0032, 14.4729), address: 'Libušská 319/126, 142 00 Praha-Libuš'),
      Place('Tamda Foods', const LatLng(50.0041, 14.4723), address: 'Ulice 02, 142 00 Praha-Libuš'),
    ], 'tamda foods libušská 319');
    expect(r.first.name, 'Tamda Foods');
    // Úlomky čísel z rozbitě vloženého textu nepřebijí název.
    final r2 = rankPlaces([
      Place('Libuš 148', const LatLng(50.0049, 14.4607), address: 'Libuš 148, 142 00 Praha-Libuš'),
      Place('Silmet Praha-Libuš', const LatLng(50.0099, 14.4708), address: 'U Rakovky, 148 00 Praha'),
      Place('SAPA TRADE CENTER', const LatLng(50.0032, 14.4729), address: 'Libušská 319/126, 142 00 Praha-Libuš'),
    ], '14 SAPA 148 00 Praha-Libuš');
    expect(r2.first.name, 'SAPA TRADE CENTER');
  });
}
