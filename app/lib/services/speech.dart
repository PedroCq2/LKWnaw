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

// Zkratky z dopravních tabulí – hlas je jinak čte doslova („Ml tečka Boleslav“).
const _abbrev = {
  'Ml. Boleslav': 'Mladá Boleslav',
  'Hr. Králové': 'Hradec Králové',
  'Č. Budějovice': 'České Budějovice',
  'Č. Krumlov': 'Český Krumlov',
  'Č. Lípa': 'Česká Lípa',
  'Č. Třebová': 'Česká Třebová',
  'K. Vary': 'Karlovy Vary',
  'M. Lázně': 'Mariánské Lázně',
  'Fr. Lázně': 'Františkovy Lázně',
  'Kr. Dvůr': 'Králův Dvůr',
  'Val. Meziříčí': 'Valašské Meziříčí',
  'Uh. Hradiště': 'Uherské Hradiště',
  'Uh. Brod': 'Uherský Brod',
  'Ž. n. Sázavou': 'Žďár nad Sázavou',
  'Žďár n. S.': 'Žďár nad Sázavou',
  'Ústí n. L.': 'Ústí nad Labem',
  'Ústí n. Orl.': 'Ústí nad Orlicí',
  'Brandýs n. L.': 'Brandýs nad Labem',
  'Nové M. n. M.': 'Nové Město na Moravě',
  'Ostrava-Jih': 'Ostrava jih',
};
final _nadRiver = RegExp(
  r'\bn\. (L\.|Lab\.|Labem|Vlt\.|Ohří|Orl\.|Sáz\.|Sázavou|Mor\.|Odrou|Jiz\.|Jizerou|Metují|Nisou|Svit\.)',
);
const _rivers = {
  'L.': 'Labem',
  'Lab.': 'Labem',
  'Labem': 'Labem',
  'Vlt.': 'Vltavou',
  'Ohří': 'Ohří',
  'Orl.': 'Orlicí',
  'Sáz.': 'Sázavou',
  'Sázavou': 'Sázavou',
  'Mor.': 'Moravou',
  'Odrou': 'Odrou',
  'Jiz.': 'Jizerou',
  'Jizerou': 'Jizerou',
  'Metují': 'Metují',
  'Nisou': 'Nisou',
  'Svit.': 'Svitavou',
};

/// Připraví text pro hlas: „D46“ → „dé čtyřicet šest“, „E422“ → „E čtyři sta dvacet dva“,
/// „I/35“ → „jedna třicet pět“, „Ml. Boleslav“ → „Mladá Boleslav“.
String forSpeech(String text) => _abbrev.entries
    .fold(text, (t, e) => t.replaceAll(e.key, e.value))
    .replaceAllMapped(_nadRiver, (m) => 'nad ${_rivers[m[1]] ?? m[1]}')
    .replaceAllMapped(
      _iRoad,
      (m) => '${czechNumber(m.group(1)!.length)} ${czechNumber(int.parse(m.group(2)!))}',
    )
    .replaceAllMapped(_roadRef, (m) => '${_letters[m.group(1)]} ${czechNumber(int.parse(m.group(2)!))}')
    .replaceAll(' km/h', ' kilometrů za hodinu')
    // Valhalla: „Poté Odbočte vpravo.“ → „poté odbočte“
    .replaceAllMapped(RegExp(r'([Pp]oté) (\p{Lu})', unicode: true), (m) => '${m[1]} ${m[2]!.toLowerCase()}');
