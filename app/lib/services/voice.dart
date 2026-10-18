import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'settings.dart';
import 'speech.dart';

/// Hlasové pokyny: nejlepší český hlas v telefonu, navigační zvuk (ztlumí hudbu),
/// hlášky jdou za sebou a stejná hláška se během pár sekund neopakuje.
class Voice {
  Voice._();
  static final instance = Voice._();

  final _tts = FlutterTts();
  AppSettings? _settings;
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> init(AppSettings settings) async {
    _settings = settings;
    try {
      await _tts.setLanguage('cs-CZ');
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        await _tts.setAudioAttributesForNavigation();
        await _tts.setQueueMode(1); // QUEUE_ADD – nepřerušovat předchozí pokyn
      }
      await _tts.awaitSpeakCompletion(false);
      await applySettings();
    } catch (_) {}
  }

  Future<void> applySettings() async {
    final s = _settings;
    if (s == null) return;
    try {
      await _tts.setSpeechRate(kIsWeb ? 1.0 : s.speechRate);
      await _tts.setPitch(1.0);
      final voices = await czechVoices();
      final pick = voices.where((v) => v['name'] == s.voiceName).firstOrNull ?? _best(voices);
      if (pick != null) await _tts.setVoice({'name': pick['name']!, 'locale': pick['locale']!});
    } catch (_) {}
  }

  /// České hlasy dostupné v telefonu.
  Future<List<Map<String, String>>> czechVoices() async {
    try {
      final list = (await _tts.getVoices) as List? ?? const [];
      return [
        for (final v in list)
          if ('${(v as Map)['locale']}'.toLowerCase().startsWith('cs'))
            v.map((k, val) => MapEntry('$k', '$val')),
      ];
    } catch (_) {
      return [];
    }
  }

  /// Nejlepší hlas: vysoká kvalita a bez nutnosti internetu (v kabině často není signál).
  static Map<String, String>? _best(List<Map<String, String>> voices) {
    if (voices.isEmpty) return null;
    int score(Map<String, String> v) {
      var s = 0;
      if (v['network_required'] != 'true' && !(v['name'] ?? '').contains('network')) s += 100;
      final q = int.tryParse(v['quality'] ?? '') ?? (v['quality'] == 'very high' ? 500 : 300);
      return s + q ~/ 10;
    }

    return ([...voices]..sort((a, b) => score(b).compareTo(score(a)))).first;
  }

  /// Kdy naposledy zazněla hláška (navazující hlášky nechají předchozí doznít).
  DateTime get lastSpokenAt => _lastAt;

  Future<void> say(String text, {bool force = false}) async {
    final s = _settings;
    if (text.isEmpty || (s != null && !s.voice && !force)) return;
    final spoken = forSpeech(text);
    // Stejná hláška znovu do 8 s = zbytečné opakování.
    if (!force && spoken == _last && DateTime.now().difference(_lastAt) < const Duration(seconds: 8)) return;
    _last = spoken;
    _lastAt = DateTime.now();
    try {
      await _tts.speak(spoken);
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
