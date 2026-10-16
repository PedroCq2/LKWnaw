import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'http_headers.dart';
import 'offline_search.dart';

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
  static const searchUrl = '$_base/search-cz.sqlite.gz';
  static const _channel = MethodChannel('lkwnav/valhalla');

  bool ready = false; // balík je otevřený a lze počítat
  bool preferDevice = true; // Nastavení: počítat v telefonu (jinak server, telefon jen bez signálu)
  String? dataDate; // datum dat OSM v balíku (např. 2026-10-15)
  int? sizeBytes; // trasy + rejstřík míst v telefonu

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<File> _tarFile() async => File('${(await getApplicationSupportDirectory()).path}/cz-routing.tar');

  /// Po startu: otevřít už stažený balík.
  Future<void> init() async {
    if (!supported) return;
    try {
      final p = await SharedPreferences.getInstance();
      dataDate = p.getString('routingDate');
      await OfflineSearch.instance.open();
      final f = await _tarFile();
      if (await f.exists()) {
        sizeBytes = await f.length() + await _searchSize();
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
      return ('${j['date']}', (j['size'] as num? ?? 0).toInt() + (j['searchSize'] as num? ?? 0).toInt());
    } catch (_) {
      return null;
    }
  }

  Future<int> _searchSize() async {
    final f = await OfflineSearch.file();
    return await f.exists() ? await f.length() : 0;
  }

  /// Stáhne gzip soubor do `<target>.part` a vrátí ho (rozbalený).
  Future<File> _fetch(
    http.Client client,
    String url,
    File target, {
    required void Function(int got) onBytes,
    required void Function(int? total) onLength,
  }) async {
    final res = await client.send(http.Request('GET', Uri.parse(url))..headers.addAll(uaHeaders()));
    if (res.statusCode != 200) throw Exception('server vrátil ${res.statusCode}');
    onLength(res.contentLength);
    final part = File('${target.path}.part');
    final sink = part.openWrite();
    try {
      await sink.addStream(
        res.stream
            .map((chunk) {
              onBytes(chunk.length);
              return chunk;
            })
            .transform(gzip.decoder),
      );
    } finally {
      await sink.close();
    }
    if (await part.length() < 1000000) throw Exception('stažený soubor je poškozený');
    return part;
  }

  /// Stáhne celý balík tras (gzip → tar) a rejstřík míst pro hledání bez internetu,
  /// ověří je a vymění za staré až po úspěšném stažení.
  Future<void> download({required void Function(double progress) onProgress}) async {
    final meta = await latest();
    final client = http.Client();
    try {
      var total = meta?.$2 ?? 0;
      var got = 0;
      void bytes(int n) {
        got += n;
        if (total > 0) onProgress((got / total).clamp(0, 1));
      }

      final target = await _tarFile();
      final searchTarget = await OfflineSearch.file();
      final tarPart = await _fetch(
        client,
        packageUrl,
        target,
        onBytes: bytes,
        onLength: (l) {
          if (total == 0 && l != null) total = l;
        },
      );
      File? searchPart;
      try {
        searchPart = await _fetch(client, searchUrl, searchTarget, onBytes: bytes, onLength: (_) {});
      } catch (e) {
        // Rejstřík je doplněk – trasy fungují i bez něj.
        debugPrint('search db: $e');
      }
      // Staré soubory zavřít a nahradit novými.
      await _channel.invokeMethod('close');
      ready = false;
      if (await target.exists()) await target.delete();
      await tarPart.rename(target.path);
      if (searchPart != null) {
        OfflineSearch.instance.close();
        if (await searchTarget.exists()) await searchTarget.delete();
        await searchPart.rename(searchTarget.path);
      }
      await OfflineSearch.instance.open();
      sizeBytes = await target.length() + await _searchSize();
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
    OfflineSearch.instance.close();
    final sf = await OfflineSearch.file();
    if (await sf.exists()) await sf.delete();
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
