import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Hlášení „tady navigovala špatně“ – uložená v telefonu, dají se zkopírovat a poslat k rozboru.
class ProblemReports {
  static const _key = 'problemReports';

  static Future<List<Map<String, dynamic>>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return [];
      return [for (final e in jsonDecode(raw) as List) Map<String, dynamic>.from(e as Map)];
    } catch (_) {
      return [];
    }
  }

  static Future<void> add(Map<String, dynamic> report) async {
    final list = await load();
    list.insert(0, report);
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(list.take(50).toList()));
  }

  static Future<void> clear() async => (await SharedPreferences.getInstance()).remove(_key);

  /// Text k odeslání (JSON).
  static Future<String> export() async => const JsonEncoder.withIndent(' ').convert(await load());
}
