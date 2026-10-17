import 'dart:math' as math;
import 'dart:ui';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'address_parser.dart';

/// Rozpoznání textu z fotky dodacího listu / štítku (Google ML Kit, v telefonu, bez internetu).
class LabelScanner {
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  /// Adresy a přečtené řádky (pro kontrolu, když se adresa nenajde).
  Future<(List<ParsedAddress>, List<String>)> addressesFromPhoto(String path) async {
    final text = await _recognizer.processImage(InputImage.fromFilePath(path));
    final rows = documentRows(text);
    return (parseAddresses(rows), rows);
  }

  void close() => _recognizer.close();
}

class _Piece {
  final String text;
  final Rect box;
  _Piece(this.text, this.box);
}

/// Složí rozpoznané řádky do řádků dokumentu: „Ulice:“ a „Modletice 91“ vedle sebe = jeden řádek.
/// Dva sloupce (odesílatel vlevo, příjemce vpravo) zůstanou oddělené.
List<String> documentRows(RecognizedText text) {
  final lines = [
    for (final b in text.blocks)
      for (final l in b.lines) l,
  ];
  if (lines.isEmpty) return const [];
  double median(List<double> v) => (v..sort())[v.length ~/ 2];
  final medH = median([for (final l in lines) l.boundingBox.height]);
  final medA = median([for (final l in lines) l.angle ?? 0]);
  // Šikmé razítko („KONTROLOVÁNO… 17. 10. 2026“) má obří rámeček a slilo by řádky dokumentu.
  final pieces = [
    for (final l in lines)
      if (((l.angle ?? medA) - medA).abs() < 20 && l.boundingBox.height < medH * 2.2)
        _Piece(l.text, l.boundingBox),
  ];
  if (pieces.isEmpty) return const [];
  pieces.sort((a, b) => a.box.center.dy.compareTo(b.box.center.dy));
  final rows = <List<_Piece>>[];
  for (final p in pieces) {
    final row = rows.isEmpty ? null : rows.last;
    if (row != null) {
      final ref = row.last.box;
      final overlap = math.min(ref.bottom, p.box.bottom) - math.max(ref.top, p.box.top);
      if (overlap > math.min(ref.height, p.box.height) * 0.5) {
        row.add(p);
        continue;
      }
    }
    rows.add([p]);
  }
  // Úseky řádků; sloupce podle levého okraje, aby se odesílatel a příjemce nepromíchali.
  final segs = <(String, double)>[];
  for (final row in rows) {
    row.sort((a, b) => a.box.left.compareTo(b.box.left));
    var cur = row.first.text;
    var left = row.first.box.left;
    for (var i = 1; i < row.length; i++) {
      final prev = row[i - 1], p = row[i];
      final gap = p.box.left - prev.box.right;
      final label = RegExp(r':\s*$').hasMatch(prev.text);
      if (label || gap < prev.box.height * 2.5) {
        cur = '$cur ${p.text}';
      } else {
        segs.add((cur, left));
        cur = p.text;
        left = p.box.left;
      }
    }
    segs.add((cur, left));
  }
  if (segs.isEmpty) return const [];
  final width = pieces.map((p) => p.box.right).reduce(math.max);
  final columns = <(double, List<String>)>[];
  for (final (t, left) in segs) {
    final c = columns.indexWhere((c) => (c.$1 - left).abs() < width * 0.2);
    if (c >= 0) {
      columns[c].$2.add(t);
    } else {
      columns.add((left, [t]));
    }
  }
  columns.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final c in columns) ...c.$2];
}
