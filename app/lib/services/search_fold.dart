/// Malá písmena bez diakritiky („Týnecká“ → „tynecka“).
String fold(String s) {
  const from = 'áäčďéěëíňóöřšťúůüýžľĺŕ';
  const to = 'aacdeeeinoorstuuuyzllr';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString();
}
