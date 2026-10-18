// Úpravy textu pro český hlas (TTS čte „D46“ jako „dé čtyři šest“).

const _units = ['nula', 'jedna', 'dva', 'tři', 'čtyři', 'pět', 'šest', 'sedm', 'osm', 'devět'];
const _teens = [
  'deset',
  'jedenáct',
  'dvanáct',
  'třináct',
  'čtrnáct',
  'patnáct',
  'šestnáct',
  'sedmnáct',
  'osmnáct',
  'devatenáct',
];
const _tens = [
  '',
  '',
  'dvacet',
  'třicet',
  'čtyřicet',
  'padesát',
  'šedesát',
  'sedmdesát',
  'osmdesát',
  'devadesát',
];

/// Číslo slovy (0–9999), např. 46 → „čtyřicet šest“, 602 → „šest set dva“.
String czechNumber(int n) {
  if (n < 0 || n > 9999) return '$n';
  if (n < 10) return _units[n];
  if (n < 20) return _teens[n - 10];
  if (n < 100) return n % 10 == 0 ? _tens[n ~/ 10] : '${_tens[n ~/ 10]} ${_units[n % 10]}';
  if (n < 1000) {
    final h = n ~/ 100;
    final hs = switch (h) {
      1 => 'sto',
      2 => 'dvě stě',
      3 || 4 => '${_units[h]} sta',
      _ => '${_units[h]} set',
    };
    return n % 100 == 0 ? hs : '$hs ${czechNumber(n % 100)}';
  }
  final t = n ~/ 1000;
  final ts = switch (t) {
    1 => 'tisíc',
    2 => 'dva tisíce',
    3 || 4 => '${_units[t]} tisíce',
    _ => '${_units[t]} tisíc',
  };
  return n % 1000 == 0 ? ts : '$ts ${czechNumber(n % 1000)}';
}

final _roadRef = RegExp(r'\b([DER])\s?(\d{1,3})\b');
// Písmeno se čte jako písmeno („E“ = é, ne „dlouhé é“), číslo jako celé číslo.
const _letters = {'D': 'dé', 'E': 'E', 'R': 'er'};
final _iRoad = RegExp(r'\b(I{1,3})/(\d{1,3})\b');

/// Připraví text pro hlas: „D46“ → „dé čtyřicet šest“, „E422“ → „E čtyři sta dvacet dva“,
/// „I/35“ → „jedna třicet pět“.
String forSpeech(String text) => text
    .replaceAllMapped(
      _iRoad,
      (m) => '${czechNumber(m.group(1)!.length)} ${czechNumber(int.parse(m.group(2)!))}',
    )
    .replaceAllMapped(_roadRef, (m) => '${_letters[m.group(1)]} ${czechNumber(int.parse(m.group(2)!))}')
    .replaceAll(' km/h', ' kilometrů za hodinu')
    // Valhalla: „Poté Odbočte vpravo.“ → „poté odbočte“
    .replaceAllMapped(RegExp(r'([Pp]oté) (\p{Lu})', unicode: true), (m) => '${m[1]} ${m[2]!.toLowerCase()}');
