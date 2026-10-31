import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'offline_search.dart';
import 'parking_network.dart';
import 'settings.dart';

/// Druh zprávy od řidiče.
enum FeedbackKind { bug, improvement, feature }

extension FeedbackKindInfo on FeedbackKind {
  String get code => name;
  String get label => switch (this) {
    FeedbackKind.bug => 'Nahlásit chybu',
    FeedbackKind.improvement => 'Žádost o vylepšení',
    FeedbackKind.feature => 'Žádost o novou funkci',
  };
  String get hint => switch (this) {
    FeedbackKind.bug => 'Co nefunguje nebo kde je problém? Např. „Na D1 u Brna hlásil sjezd o exit dřív.“',
    FeedbackKind.improvement => 'Co by šlo udělat lépe? Např. „Větší šipka v noci.“',
    FeedbackKind.feature => 'Co v aplikaci chybí? Např. „Ceny nafty po trase.“',
  };
}

/// Zprávy o chybách a nápadech: text řidiče + systémové informace (telefon, verze aplikace,
/// nastavení, poloha a trasa). Odesílají se na server sítě; bez signálu počkají v telefonu.
class AppFeedback {
  /// Telefon a aplikace (model, Android, verze) + stav z obrazovky mapy ([state]).
  static Future<Map<String, dynamic>> systemInfo(AppSettings s, Map<String, dynamic> state) async {
    final info = <String, dynamic>{};
    try {
      final p = await PackageInfo.fromPlatform();
      info['app'] = '${p.version}+${p.buildNumber}';
    } catch (_) {}
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final a = await DeviceInfoPlugin().androidInfo;
        info['phone'] = '${a.manufacturer} ${a.model}';
        info['android'] = '${a.version.release} (SDK ${a.version.sdkInt})';
      } else {
        info['os'] = kIsWeb ? 'web' : defaultTargetPlatform.name;
      }
    } catch (_) {}
    final off = OfflineSearch.instance;
    info['settings'] = {
      'vehicle': s.profile.summary,
      'delivery': s.delivery,
      'voice': s.voiceMode.name,
      'routeOnDevice': s.routeOnDevice,
      'offlineData': off.ready,
      'server': s.valhallaUrl == defaultValhallaUrl ? 'výchozí' : 'vlastní',
    };
    info.addAll(state);
    return info;
  }

  static Future<void> send(FeedbackKind kind, String message, Map<String, dynamic>? info) =>
      ParkingNetwork.instance.submit('send_feedback', 'f', {
        'kind': kind.code,
        'message': message,
        'info': ?info,
        'app_version': info?['app'],
      });
}
