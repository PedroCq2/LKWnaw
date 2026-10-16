import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Obraz v obraze (Android): během navigace zůstane mapa vidět v malém okénku,
/// když řidič přepne do jiné aplikace.
class Pip {
  Pip._() {
    if (_supported) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'pip') active.value = call.arguments == true;
      });
    }
  }
  static final instance = Pip._();

  static const _channel = MethodChannel('lkwnav/pip');
  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Aplikace je právě v okénku.
  final active = ValueNotifier<bool>(false);

  Future<void> setNavigating(bool v) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('navigating', v);
    } catch (_) {}
  }
}
