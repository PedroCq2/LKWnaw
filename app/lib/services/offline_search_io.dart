import 'dart:io';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'geocoding.dart';
import 'search_fold.dart';

/// Vyhledávání míst ČR v telefonu bez internetu (rejstřík z OSM: obce, ulice, adresy, firmy, sklady).
///
/// Rejstřík `search-cz.sqlite` se stahuje spolu s balíkem tras (viz [OfflineRouting]).
class OfflineSearch {
  OfflineSearch._();
  static final instance = OfflineSearch._();

  Database? _db;
  bool get ready => _db != null;

  static Future<File> file() async =>
      File('${(await getApplicationSupportDirectory()).path}/search-cz.sqlite');

  Future<void> open([String? path]) async {
    close();
    try {
      final p = path ?? (await file()).path;
      if (!File(p).existsSync()) return;
      _db = sqlite3.open(p, mode: OpenMode.readOnly);
    } catch (_) {
      _db = null;
    }
  }

  List<(String, double, double, double)>? _towns; // jméno, lat, lon, váha (město > obec)

  /// Nejbližší obec/město k bodu (bez internetu). Město „přitahuje“ silněji než vesnice,
  /// aby např. Trnovany (část Teplic) patřily Teplicím, ne sousední vesnici.
  String? nearestTown(LatLng p) {
    final db = _db;
    if (db == null) return null;
    try {
      _towns ??= [
        for (final r in db.select("SELECT name, kind, lat, lon FROM poi WHERE kind IN ('Město', 'Obec')"))
          (
            r['name'] as String,
            (r['lat'] as num).toDouble(),
            (r['lon'] as num).toDouble(),
            r['kind'] == 'Město' ? 3.0 : 1.0,
          ),
      ];
    } catch (_) {
      return null;
    }
    String? best;
    var bestD = double.infinity;
    final k = math.cos(p.latitude * math.pi / 180);
    for (final (name, lat, lon, w) in _towns!) {
      final dy = lat - p.latitude, dx = (lon - p.longitude) * k;
      if (dy.abs() > 0.2 || dx.abs() > 0.2) continue;
      final dd = math.sqrt(dx * dx + dy * dy) / w;
      if (dd < bestD) {
        bestD = dd;
        best = name;
      }
    }
    return best;
  }

  void close() {
    _towns = null;
    try {
      _db?.close();
    } catch (_) {}
    _db = null;
  }

  static const _skip = {'dc', 'sklad', 'ul', 'ulice', 'u', 'a', 'cz', 'cr'};
  static final _pc = RegExp(r'\b\d{3}\s?\d{2}\b');
  static final _num = RegExp(r'\b\d{1,4}[a-zA-Z]?\b');
  static final _word = RegExp(r'\p{L}{2,}', unicode: true);
  static final _tok = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  /// Hledá adresy („Týnecká 65 77900 Olomouc“, „Modletice 91 25101“) i firmy/místa („kaufland modletice“).
  List<Place> search(String query, {int limit = 12}) {
    final db = _db;
    if (db == null) return [];
    final pcs = _pc.allMatches(query).map((m) => m.group(0)!.replaceAll(' ', '')).toSet();
    final rest = query.replaceAll(_pc, ' ');
    final nums = _num.allMatches(rest).map((m) => m.group(0)!).toList();
    final words = [
      for (final m in _word.allMatches(rest))
        if (!_skip.contains(fold(m.group(0)!))) fold(m.group(0)!),
    ];
    if (words.isEmpty) return [];
    final expr = words.map((w) => '"$w"*').join(' OR ');
    final scored = <(int, Place)>[];

    int score(String name, String city) {
      final toks = _tok.allMatches(fold(name)).map((m) => m.group(0)!).toList();
      final ctoks = _tok.allMatches(fold(city)).map((m) => m.group(0)!).toSet();
      var s = 0;
      for (final w in words) {
        if (toks.contains(w)) {
          s += 4;
        } else if (toks.any((t) => t.startsWith(w))) {
          s += 1;
        }
        if (ctoks.contains(w) && !toks.any((t) => t.startsWith(w))) s += 3;
      }
      return s;
    }

    try {
      if (nums.isNotEmpty) {
        // Ulice podle názvu (ne podle obce – „Olomouc“ by jinak vrátilo všechny ulice města),
        // přednostně ve stejném PSČ; vzácnější slova (bm25) první.
        const sql =
            'SELECT s.id, s.name, s.city, s.postcode FROM street_fts f JOIN street s ON s.id = f.rowid '
            'WHERE street_fts MATCH ? ORDER BY rank LIMIT ?';
        final all = words.map((w) => '"$w"*').join(' ');
        final pc = pcs.map((p) => '"$p"').join(' OR ');
        final streets = [
          if (pcs.isNotEmpty) ...db.select(sql, ['name : ($expr) AND postcode : ($pc)', 200]),
          // „783 72 Velký Týnec 1“ – číslo popisné v obci, ulice se jmenuje jinak.
          if (pcs.isNotEmpty) ...db.select(sql, ['city : ($all) AND postcode : ($pc)', 300]),
          ...db.select(sql, ['{name city} : ($all)', 200]),
          ...db.select(sql, ['name : ($expr)', 300]),
        ];
        final seenStreet = <int>{};
        final addr = db.prepare('SELECT num, lat, lon FROM addr WHERE sid = ? AND num = ? LIMIT 1');
        for (final r in streets) {
          if (!seenStreet.add(r['id'] as int)) continue;
          final name = r['name'] as String, city = r['city'] as String, pc = r['postcode'] as String;
          for (final n in nums) {
            final a = addr.select([r['id'], n]);
            if (a.isEmpty) continue;
            var s = score(name, city) + 5;
            if (pcs.contains(pc)) s += 6;
            scored.add((
              s,
              Place(
                '$name $n',
                LatLng((a.first['lat'] as int) / 1e6, (a.first['lon'] as int) / 1e6),
                kind: 'Adresa',
                address: [if (pc.isNotEmpty) pc, city].join(' ').trim(),
              ),
            ));
            break;
          }
        }
        addr.close();
      }
      const poiSql =
          'SELECT rowid, name, city, kind, lat, lon FROM poi WHERE poi MATCH ? ORDER BY rank LIMIT ?';
      final seenPoi = <int>{};
      final pois = [
        if (words.length > 1) ...db.select(poiSql, [words.map((w) => '"$w"*').join(' '), 200]),
        ...db.select(poiSql, [expr, 300]),
      ];
      for (final r in pois) {
        if (!seenPoi.add(r['rowid'] as int)) continue;
        final name = r['name'] as String, city = r['city'] as String, kind = r['kind'] as String;
        var s = score(name, city);
        if (kind == 'Město' || kind == 'Obec') s += 1;
        scored.add((
          s,
          Place(
            name,
            LatLng((r['lat'] as num).toDouble(), (r['lon'] as num).toDouble()),
            kind: kind,
            address: city.isEmpty ? null : city,
          ),
        ));
      }
    } catch (_) {
      return [];
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    final out = <Place>[];
    const dist = Distance();
    for (final (_, p) in scored) {
      if (out.any((o) => o.name == p.name && dist(o.point, p.point) < 150)) continue;
      out.add(p);
      if (out.length >= limit) break;
    }
    return out;
  }
}
