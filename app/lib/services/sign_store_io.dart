import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Vlastní databáze značek a tabulí z kamery (signs/signs.db + výřezy signs/img/*.jpg).
/// Každý záznam = jedna značka / tabule viděná na několika snímcích: poloha a směr vozidla,
/// barva, velikost, přečtený text a (u rychlosti, výšky, hmotnosti, délky) rozpoznaná hodnota.
/// Výřez je jen značka (ne celý snímek) – kvůli velikosti i soukromí (lidé, SPZ).
class SignStore {
  SignStore._();
  static final instance = SignStore._();
  Database? _db;
  late String _dir;
  static const maxBytes = 400 * 1024 * 1024; // víc výřezů neukládat (místo v telefonu)

  Future<Database> _open() async {
    if (_db != null) return _db!;
    _dir = '${(await getApplicationDocumentsDirectory()).path}/signs';
    await Directory('$_dir/img').create(recursive: true);
    final db = sqlite3.open('$_dir/signs.db');
    db.execute('''
      CREATE TABLE IF NOT EXISTS sign(
        id INTEGER PRIMARY KEY,
        t INTEGER,          -- čas (ms od 1970)
        lat REAL, lon REAL, acc REAL, heading REAL, speed REAL,
        color TEXT,         -- red / blue / yellow / green / white
        shape TEXT,         -- round / rect / triangle / ?
        x REAL, y REAL, w REAL, h REAL,  -- poloha a velikost v obraze (0..1)
        frames INTEGER,     -- na kolika snímcích
        text TEXT,          -- přečtený text
        kind TEXT, value REAL,           -- rozpoznaná značka (speed / height / weight / length)
        img TEXT,           -- soubor výřezu
        bytes INTEGER
      )''');
    _db = db;
    return db;
  }

  Future<void> add({
    required int t,
    double? lat,
    double? lon,
    double? acc,
    double? heading,
    double? speed,
    required String color,
    required String shape,
    required List<double> box,
    required int frames,
    String? text,
    String? kind,
    double? value,
    Uint8List? jpeg,
  }) async {
    final db = await _open();
    String? img;
    if (jpeg != null && usedBytes(db) + jpeg.length < maxBytes) {
      img = '$t-${color[0]}.jpg';
      await File('$_dir/img/$img').writeAsBytes(jpeg);
    }
    db.execute(
      'INSERT INTO sign(t,lat,lon,acc,heading,speed,color,shape,x,y,w,h,frames,text,kind,value,img,bytes) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        t,
        lat,
        lon,
        acc,
        heading,
        speed,
        color,
        shape,
        box[0],
        box[1],
        box[2],
        box[3],
        frames,
        text,
        kind,
        value,
        img,
        img == null ? 0 : jpeg!.length,
      ],
    );
  }

  int usedBytes(Database db) => (db.select('SELECT COALESCE(SUM(bytes),0) b FROM sign').first['b'] as int);

  Future<(int, int, int)> stats() async {
    final db = await _open();
    final r = db.select('SELECT COUNT(*) n, COUNT(kind) k, COALESCE(SUM(bytes),0) b FROM sign').first;
    return (r['n'] as int, r['k'] as int, r['b'] as int);
  }

  /// Zip (signs.json + výřezy) k odeslání.
  Future<String> exportZip() async {
    final db = await _open();
    final rows = [for (final r in db.select('SELECT * FROM sign ORDER BY t')) Map<String, dynamic>.from(r)];
    final tmp = await getTemporaryDirectory();
    final path = '${tmp.path}/lkwnav-znacky-${DateTime.now().millisecondsSinceEpoch}.zip';
    final enc = ZipFileEncoder()..create(path);
    final json = utf8.encode(const JsonEncoder.withIndent(' ').convert(rows));
    enc.addArchiveFile(ArchiveFile('signs.json', json.length, json));
    for (final r in rows) {
      final f = File('$_dir/img/${r['img']}');
      if (r['img'] != null && await f.exists()) await enc.addFile(f, 'img/${r['img']}');
    }
    await enc.close();
    return path;
  }

  Future<void> clear() async {
    final db = await _open();
    db.execute('DELETE FROM sign');
    final d = Directory('$_dir/img');
    if (await d.exists()) await d.delete(recursive: true);
    await d.create(recursive: true);
  }
}
