/// Adresa vyčtená z fotky dodacího listu nebo štítku balíku.
class ParsedAddress {
  String? name; // příjemce / firma („DC - Modletice“)
  String? street; // ulice a číslo („Týnecká 65“), u obcí bez ulic obec a č. p. („Modletice 91“)
  String? postcode; // PSČ bez mezery („77900“)
  String? city; // „Olomouc“
  int score; // > 0 = u slova „Příjemce“, „Místo vykládky“…; < 0 = u „Odesílatel“, „Dodavatel“…
  ParsedAddress({this.name, this.street, this.postcode, this.city, this.score = 0});

  /// Text pro vyhledání místa.
  String get query => [
    ?street,
    [?postcode, ?city].join(' '),
  ].where((s) => s.trim().isNotEmpty).join(', ');

  /// Jak adresu ukázat řidiči.
  String get label => [
    ?street,
    [if (postcode case final p?) '${p.substring(0, 3)} ${p.substring(3)}', ?city].join(' '),
  ].where((s) => s.trim().isNotEmpty).join(', ');
}

final _pc = RegExp(r'(?<![\d/])([1-7]\d{2}) ?(\d{2})(?![\d/])');
// Název ulice/obce a PRVNÍ číslo za ním („Modletice 91 123 91“ → „Modletice 91“, zbytek je šum z razítka).
final _street = RegExp(
  r'^(.*?\p{L}[^\d]*?)[ ,]+(?:č\. ?p\. ?|čp\. ?)?(\d{1,4}[a-zA-Z]?(?:/\d{1,4}[a-zA-Z]?)?)(?![\d.:])',
  unicode: true,
);

/// PSČ v řádku. „91 123 91“ za číslem domu není PSČ (číslo za číslem, bez obce za ním).
RegExpMatch? _findPc(String s) {
  for (final m in _pc.allMatches(s)) {
    final after = s.substring(m.end).trimLeft();
    final before = s.substring(0, m.start).trimRight();
    if (RegExp(r'^\p{L}', unicode: true).hasMatch(after)) return m;
    if (RegExp(r'\d$').hasMatch(before)) continue;
    if (after.isEmpty || RegExp(r'^[,;]').hasMatch(after)) return m;
  }
  return null;
}

final _labels = RegExp(
  r'^(příjemce|adresát|ulice|adresa|místo (vykládky|dodání|určení|doručení)|dodací adresa|doručovací adresa|'
  r'adresa doručení|doručit na|psč|obec|město|recipient|deliver to|ship to|empfänger|lieferadresse)\b\s*:?\s*',
  caseSensitive: false,
  unicode: true,
);
final _deliveryKw = RegExp(
  r'příjemce|adresát|místo (vykládky|dodání|určení|doručení)|dodací adresa|doručovací|doručit|recipient|'
  r'deliver|ship to|empfänger|lieferadresse',
  caseSensitive: false,
  unicode: true,
);
final _senderKw = RegExp(
  r'odesílatel|dodavatel|odběratel|fakturační|sídlo|sender|absender|from\b|vrátit|return',
  caseSensitive: false,
  unicode: true,
);
final _phoneOrId = RegExp(
  r'tel|mob|fax|e-?mail|@|www|ič[oa]?\b|dič|iban|účet|č\. ?ú|objedn|faktur|datum|\+\d|filiál|číslo|'
  r'interní|jednotk|hh:mm|dodání|obousměr',
  caseSensitive: false,
  unicode: true,
);

String _clean(String s) => s
    .replaceAll(_labels, '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'^[\s,;:.\-–]+|[\s,;:\-–]+$'), '')
    .trim();

/// Ulice s číslem z textu, nebo null.
String? _streetOf(String s) {
  final t = _clean(s);
  if (t.length < 3 || t.length > 70 || _findPc(t) != null || _phoneOrId.hasMatch(t)) return null;
  final m = _street.firstMatch(t);
  if (m == null) return null;
  final name = m.group(1)!.replaceAll(RegExp(r'[\s,]+$'), '').trim();
  return name.length < 2 ? null : '$name ${m.group(2)}';
}

bool _isStreet(String s) => _streetOf(s) != null;

bool _isName(String s) {
  final t = _clean(s);
  if (t.length < 2 || t.length > 60 || _phoneOrId.hasMatch(t) || _findPc(t) != null) return false;
  if (RegExp(r'\d{3,}').hasMatch(t)) return false;
  // Popisek formuláře („Datum dodání:“, „Pož. Dodání: 00:00“) není jméno.
  if (t.contains(':') || RegExp(r'\d{1,2}\.\s?\d{1,2}\.').hasMatch(t)) return false;
  return RegExp(r'\p{L}{2,}', unicode: true).hasMatch(t) && !_senderKw.hasMatch(t);
}

/// Najde adresy (ulice + PSČ + obec) v řádcích textu z fotky.
/// Řádky ideálně po řádcích dokumentu („Ulice: Modletice 91“ jako jeden řádek).
List<ParsedAddress> parseAddresses(List<String> rawLines) {
  final lines = [for (final l in rawLines) l.trim()].where((l) => l.isNotEmpty).toList();
  final out = <ParsedAddress>[];
  final usedStreet = <int>{};
  for (var r = 0; r < lines.length; r++) {
    final line = lines[r];
    // Řádek s telefonem / IČ (ne celý dokument – „Tel.“ může být i v sousedním sloupci).
    if (RegExp(
      r'^\s*(tel|mob|fax|ič|dič|iban|účet)|\+\d{3}',
      caseSensitive: false,
      unicode: true,
    ).hasMatch(line)) {
      continue;
    }
    final m = _findPc(line);
    if (m == null) continue;
    final pc = '${m.group(1)}${m.group(2)}';
    final cleaned = _clean(line);
    final cm = _findPc(cleaned);
    var before = cm == null ? '' : cleaned.substring(0, cm.start);
    var after = cm == null ? '' : cleaned.substring(cm.end);
    after = after.replaceAll(
      RegExp(r'[,;]?\s*(CZ|ČR|Česká republika|Czech Republic)\s*$', caseSensitive: false),
      '',
    );
    after = after.replaceAll(RegExp(r'^[\s,;\-–]+|[\s,;\-–]+$'), '').split(RegExp(r'[,;]')).first.trim();
    String? street;
    String? name;
    var streetRow = -1;
    // „Týnecká 65, 77900 Olomouc“ – ulice na stejném řádku.
    final parts = before.split(RegExp(r'[,;]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (parts.isNotEmpty && _isStreet(parts.last)) {
      street = _streetOf(parts.last);
      streetRow = r;
      if (parts.length > 1 && _isName(parts[parts.length - 2])) name = _clean(parts[parts.length - 2]);
    }
    // Jinak ulice na některém z předchozích řádků (štítek: jméno / ulice / PSČ obec).
    if (street == null) {
      for (var k = r - 1; k >= 0 && k >= r - 3; k--) {
        if (usedStreet.contains(k)) break;
        if (_findPc(lines[k]) != null) break;
        final segs = lines[k].split(RegExp(r'[,;]')).map((s) => s.trim()).where((s) => s.isNotEmpty);
        final st = segs.lastWhere(_isStreet, orElse: () => '');
        if (st.isNotEmpty) {
          street = _streetOf(st);
          streetRow = k;
          break;
        }
      }
    }
    // Obec bez názvu za PSČ („Olomouc 77900“).
    if (after.isEmpty && street == null && before.isNotEmpty && _isName(before)) after = _clean(before);
    if (streetRow >= 0) usedStreet.add(streetRow);
    // Jméno příjemce: řádek nad ulicí.
    final top = streetRow >= 0 ? streetRow : r;
    if (name == null && top > 0 && top - 1 >= 0) {
      final cand = lines[top - 1];
      if (_isName(cand) && _findPc(cand) == null && !_isStreet(cand)) name = _clean(cand);
    }
    if (street == null && after.isEmpty) continue;
    // Okolí: u příjemce / místa vykládky +, u odesílatele / dodavatele −.
    var score = 0;
    for (var k = r; k >= 0 && k >= top - 3; k--) {
      final l = lines[k];
      if (_deliveryKw.hasMatch(l)) {
        score = 3;
        break;
      }
      if (_senderKw.hasMatch(l)) {
        score = -3;
        break;
      }
    }
    out.add(
      ParsedAddress(
        name: name,
        street: street,
        postcode: pc,
        city: after.isEmpty ? null : after,
        score: score,
      ),
    );
  }
  // Je-li označený příjemce / místo vykládky, ostatní (fakturační, odesílatel) vynechat.
  final best = out.isEmpty ? 0 : out.map((a) => a.score).reduce((a, b) => a > b ? a : b);
  final keep = out.where((a) => best > 0 ? a.score > 0 : a.score >= 0).toList();
  // Bez duplicit (stejný štítek vyfocený dvakrát).
  final seen = <String>{};
  return [
    for (final a in keep)
      if (seen.add('${a.street?.toLowerCase()}|${a.postcode}')) a,
  ];
}
