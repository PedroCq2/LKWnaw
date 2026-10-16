import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'http_headers.dart';

/// Výpočet tras přímo v telefonu nad staženým balíkem tras ČR (Valhalla Mobile).
///
/// Balík staví GitHub Actions z čerstvých dat OpenStreetMap a zveřejňuje ho jako
/// vydání `routing-cz` (soubory `cz-routing.tar.gz` + `routing-cz.json` s datem dat).
class OfflineRouting {
  OfflineRouting._();
  static final instance = OfflineRouting._();

  static const _base = 'https://github.com/PedroCq2/LKWnaw/releases/download/routing-cz';
  static const metaUrl = '$_base/routing-cz.json';
  static const packageUrl = '$_base/cz-routing.tar.gz';
  static const _channel = MethodChannel('lkwnav/valhalla');

  bool ready = false; // balík je otevřený a lze počítat
  bool preferDevice = true; // Nastavení: počítat v telefonu (jinak server, telefon jen bez signálu)
  String? dataDate; // datum dat OSM v balíku (např. 2026-10-15)
  int? sizeBytes;

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<File> _tarFile() async => File('${(await getApplicationSupportDirectory()).path}/cz-routing.tar');

  /// Po startu: otevřít už stažený balík.
  Future<void> init() async {
    if (!supported) return;
    try {
      final p = await SharedPreferences.getInstance();
      dataDate = p.getString('routingDate');
      final f = await _tarFile();
      if (await f.exists()) {
        sizeBytes = await f.length();
        await _channel.invokeMethod('open', {'tar': f.path});
        ready = true;
      }
    } catch (e) {
      debugPrint('offline routing: $e');
      ready = false;
    }
  }

  /// Informace o nejnovějším balíku na serveru: (datum dat, velikost ke stažení).
  Future<(String, int?)?> latest() async {
    try {
      final res = await http
          .get(Uri.parse(metaUrl), headers: uaHeaders())
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return ('${j['date']}', (j['size'] as num?)?.toInt());
    } catch (_) {
      return null;
    }
  }

  /// Stáhne celý balík (gzip → tar), ověří a vymění za starý až po úspěšném stažení.
  Future<void> download({required void Function(double progress) onProgress}) async {
    final meta = await latest();
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(packageUrl))..headers.addAll(uaHeaders()));
      if (res.statusCode != 200) throw Exception('server vrátil ${res.statusCode}');
      final total = res.contentLength ?? meta?.$2 ?? 0;
      final target = await _tarFile();
      final part = File('${target.path}.part');
      final sink = part.openWrite();
      var got = 0;
      await sink.addStream(
        res.stream
            .map((chunk) {
              got += chunk.length;
              if (total > 0) onProgress(got / total);
              return chunk;
            })
            .transform(gzip.decoder),
      );
      await sink.close();
      if (await part.length() < 1000000) throw Exception('stažený balík je poškozený');
      // Starý balík zavřít a nahradit novým.
      await _channel.invokeMethod('close');
      ready = false;
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      sizeBytes = await target.length();
      dataDate = meta?.$1;
      final p = await SharedPreferences.getInstance();
      if (dataDate != null) await p.setString('routingDate', dataDate!);
      await _channel.invokeMethod('open', {'tar': target.path});
      ready = true;
    } finally {
      client.close();
    }
  }

  Future<void> remove() async {
    try {
      await _channel.invokeMethod('close');
    } catch (_) {}
    ready = false;
    final f = await _tarFile();
    if (await f.exists()) await f.delete();
    dataDate = null;
    sizeBytes = null;
    (await SharedPreferences.getInstance()).remove('routingDate');
  }

  /// Dotaz na Valhallu v telefonu – stejný JSON jako pro server (`route`, `trace_attributes`).
  Future<Map<String, dynamic>> call(String action, Map<String, dynamic> body) async {
    final out = await _channel.invokeMethod<String>(action, {'json': jsonEncode(body)});
    return jsonDecode(out!) as Map<String, dynamic>;
  }
}
