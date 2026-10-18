import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:shared_preferences/shared_preferences.dart';

import 'cz_cells.dart';
import 'map_style.dart';

/// Mapa celé ČR v telefonu (MapLibre offline regiony): bez signálu je vidět celá mapa,
/// ne jen okolí uložené trasy.
///
/// Stahuje se jen území ČR – čtverce podél hranice (cz_cells.dart), ne obdélník i s půlkou
/// Německa a Polska. Hrubé měřítko (zoom 0–10) jednou pro celou zemi, podrobné po čtvercích.
/// Hotové čtverce se pamatují: po přerušení (bez signálu, zavřená aplikace) se pokračuje.
class CountryMap {
  CountryMap._();
  static final instance = CountryMap._();

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  static const _key = 'countryMap';
  static const _app = 'lkwnav-cz';

  /// Průběh stahování 0–1, null = neběží.
  final progress = ValueNotifier<double?>(null);
  String? error;
  bool _cancel = false;

  /// Odhad velikosti v MB (podle průměrné velikosti dlaždic OpenFreeMap v ČR).
  static int estimateMb({required bool detailed}) => detailed ? czDetailedMb : czBasicMb;

  Future<CountryMapState> state() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return const CountryMapState();
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return CountryMapState(
      detailed: j['detailed'] == true,
      done: ((j['done'] as List?) ?? const []).cast<int>().toSet(),
      complete: j['complete'] == true,
      at: j['at'] == null ? null : DateTime.tryParse(j['at'] as String),
    );
  }

  Future<void> _save(CountryMapState s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key,
      jsonEncode({
        'detailed': s.detailed,
        'done': s.done.toList(),
        'complete': s.complete,
        if (s.at != null) 'at': s.at!.toIso8601String(),
      }),
    );
  }

  /// Stáhne (nebo dostáhne) mapu ČR. [detailed] = i zoom 14 (čísla domů, všechny názvy ulic).
  Future<void> download({required bool detailed}) async {
    if (progress.value != null) return;
    _cancel = false;
    error = null;
    var st = await state();
    // Jiná úroveň podrobnosti → začít znovu (zoom 14 se dostahuje do stejných čtverců).
    if (st.detailed != detailed) st = CountryMapState(detailed: detailed);
    final cells = czCells;
    final total = cells.length + 1;
    progress.value = st.done.length / total;
    try {
      await ml.setOfflineTileCountLimit(1000000);
      // Hrubé měřítko pro celou zemi najednou (index -1).
      if (!st.done.contains(-1)) {
        await _region(czBounds, 0, 10, -1, (p) => progress.value = p / total);
        st = st.copyWith(done: {...st.done, -1});
        await _save(st);
      }
      for (var i = 0; i < cells.length; i++) {
        if (_cancel) break;
        if (st.done.contains(i)) continue;
        final c = cells[i];
        final bounds = ml.LatLngBounds(southwest: ml.LatLng(c[0], c[1]), northeast: ml.LatLng(c[2], c[3]));
        await _region(
          bounds,
          11,
          detailed ? 14 : 13,
          i,
          (p) => progress.value = (st.done.length + p) / total,
        );
        st = st.copyWith(done: {...st.done, i});
        await _save(st);
        progress.value = st.done.length / total;
      }
      if (!_cancel) {
        st = st.copyWith(complete: true, at: DateTime.now());
        await _save(st);
      }
    } catch (e) {
      error = '$e';
      await _save(st);
    } finally {
      progress.value = null;
    }
  }

  /// Jeden region; čeká na dokončení (nativní volání se vrací hned po založení regionu).
  Future<void> _region(
    ml.LatLngBounds b,
    double minZ,
    double maxZ,
    int part,
    void Function(double) onP,
  ) async {
    final done = Completer<void>();
    // Hlídač: 3 minuty bez zprávy o průběhu (spadlé spojení) → chyba, pokračuje se tlačítkem.
    Timer? idle;
    void watch() {
      idle?.cancel();
      idle = Timer(const Duration(minutes: 3), () {
        if (!done.isCompleted) {
          done.completeError(TimeoutException('stahování se zastavilo – zkontrolujte připojení'));
        }
      });
    }

    watch();
    await ml.downloadOfflineRegion(
      ml.OfflineRegionDefinition(bounds: b, mapStyleUrl: baseStyleUrl, minZoom: minZ, maxZoom: maxZ),
      metadata: {'app': _app, 'part': part},
      onEvent: (e) {
        watch();
        if (e is ml.InProgress) onP(e.progress / 100);
        if (e is ml.Success && !done.isCompleted) done.complete();
        if (e is ml.Error && !done.isCompleted) done.completeError(e.cause.message ?? e.cause.code);
      },
    );
    try {
      await done.future;
    } finally {
      idle?.cancel();
    }
  }

  /// Zastaví stahování po dokončení rozpracovaného čtverce (hotové zůstanou).
  void cancel() => _cancel = true;

  Future<void> delete() async {
    _cancel = true;
    for (final r in await ml.getListOfRegions()) {
      if (r.metadata['app'] == _app) await ml.deleteOfflineRegion(r.id);
    }
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
  }
}

class CountryMapState {
  final bool detailed;
  final Set<int> done;
  final bool complete;
  final DateTime? at;
  const CountryMapState({this.detailed = false, this.done = const {}, this.complete = false, this.at});

  /// Podíl hotových čtverců (0–1).
  double get share => done.length / (czCells.length + 1);

  CountryMapState copyWith({Set<int>? done, bool? complete, DateTime? at}) => CountryMapState(
    detailed: detailed,
    done: done ?? this.done,
    complete: complete ?? this.complete,
    at: at ?? this.at,
  );
}
